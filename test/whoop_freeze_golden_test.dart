// P0 WHOOP FREEZE. Pins everything the band path stores for a day, byte for
// byte, so any later change that moves a WHOOP number fails here first.
//
// two_device_fixture_test.dart pins deriveDayBundle alone, with an empty
// profile and empty histories, so strain/TRIMP/zones/calories/readiness, the
// day blocks (steps, movement, naps, workouts, HRR, HR ceiling, daytime
// curves), the wake-day features and the cross-day rollup were not pinned.
// This test is the rest: three consecutive synthetic days
// (test/support/synthetic_day.dart) per family (gen4, gen5) go through the
// SAME write a drain uses and the REAL `DerivationEngine.runDays`, against a
// full profile and 14 seeded days of baseline history; then the stored rows
// and `buildCrossDayBundle` over them are compared to the committed golden.
//
// Branches the plain synthetic day would leave unpinned are forced on purpose:
//   * zones: gen5's seeded ceiling sits under its age line ('tanaka'); gen4's
//     sits over it with 12 days of resting HR, so its days walk 'observed'
//     (12, 13 days) into 'karvonen' (14, `reserveMinDays`).
//   * HR ceiling: a saved run on the middle day, so `_dayHrCeiling` scores a
//     real session and the other two days keep the auto-detected bout path.
//   * naps: a still, low-HR 45 min at 13:30 on the middle day ([_addNap]),
//     confirmed after the first pass and that day re-derived.
//   * activity_suggestions: the review cutoff is moved to 0, or every July
//     candidate predates `activated_at` (wall clock) and is dropped.
//
// Wall clock: the derive path's DateTime.now reads only feed `*_at` stamps
// (dropped below), run diagnostics, the timezone-travel baseline, the stored
// crossday artifact (not pinned; [_snapshot] rebuilds it with `today` fixed)
// and today-only branches a July day never takes. So the goldens hold on any
// later run date; a new now-read that reaches a pinned column fails here.
//
// SyntheticDay is built in LOCAL time and day labels are local, so each
// timezone is its own golden. Run once per zone:
//   TZ=UTC flutter test test/whoop_freeze_golden_test.dart
//   TZ=Asia/Kolkata flutter test test/whoop_freeze_golden_test.dart
//   TZ=America/New_York flutter test test/whoop_freeze_golden_test.dart
// Any other zone skips. GENERATE_GOLDEN=1 rewrites the zone's golden; do that
// only with owner approval (see test/fixtures/whoop_freeze/README.md).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/data/series_codec.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart' show RawRecord, Sample;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

// Mid-July: no DST edge in any of the three zones.
final List<DateTime> _days = [
  DateTime(2026, 7, 13),
  DateTime(2026, 7, 14),
  DateTime(2026, 7, 15),
];
String _label(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Golden name for the zone this process runs in, or null (skip).
String? _zoneKey() {
  final off = DateTime(2026, 7, 14, 12).timeZoneOffset.inMinutes;
  return const {0: 'utc', 330: 'plus0530', -240: 'minus0400'}[off];
}

const _profiles = {
  'gen4': Profile(ageYears: 34, weightKg: 78, heightCm: 181, sex: 'm'),
  'gen5': Profile(ageYears: 29, weightKg: 61, heightCm: 167, sex: 'f'),
};

/// The three days' 1 Hz samples, contiguous: each day's window runs to its
/// own end (22:00 local) and the next one picks up from there, so every run
/// and its recovery stay whole. Skin temperature
/// and, for gen5 only (gen4 has no counter), a cumulative step counter are
/// added on top of what SyntheticDay renders.
Iterable<(List<RawRecord>, List<Sample>)> _batches(
    List<SyntheticDay> truth, String family) sync* {
  final t0 = SyntheticDay.sec(truth.first.start);
  var steps = 0;
  for (var k = 0; k < truth.length; k++) {
    final d = truth[k];
    final from = SyntheticDay.sec(k == 0 ? d.start : truth[k - 1].end);
    final to = SyntheticDay.sec(d.end);
    for (var b = from; b < to; b += 3600) {
      final raws = <RawRecord>[];
      final samples = <Sample>[];
      for (var t = b; t < to && t < b + 3600; t++) {
        final counter = t - t0 + 1;
        steps += d.steps[t] ?? 0;
        raws.add(RawRecord(
          counter: counter,
          packetType: 0x2F,
          hex: 'synthetic${counter.toRadixString(16)}',
          capturedAt: t * 1000,
          recTs: t,
        ));
        final (ax, ay, az) = d.accel[t]!;
        samples.add(Sample(
          tsEpoch: t,
          counter: counter,
          hr: d.hr[t]!,
          rrIntervalsMs: d.rr[t]!,
          ax: ax,
          ay: ay,
          az: az,
          skinTempRaw:
              d.stage.containsKey(t) ? 30400 + t % 13 : 30150 + t % 7,
          stepCount: family == 'gen5' ? steps % 65536 : null,
        ));
      }
      yield (raws, samples);
    }
  }
}

/// Overwrites 13:30-14:15 local of [d] with a nap: a fixed wrist (z-angle
/// still), no steps, HR at 58 against a ~72 awake baseline, beats to match.
/// A 75 min arm swing either side (past `napChainGapSec`) keeps it its own
/// bout. Without it the day's low-noise desk time chains it to last night's
/// sleep at the record edge (dropped as yesterday's) or to tonight's
/// unfinished one (deferred). Test-local so the shared SyntheticDay stays as
/// it is.
void _addNap(SyntheticDay d) {
  final from = SyntheticDay.sec(
      DateTime(d.day.year, d.day.month, d.day.day, 13, 30));
  final to = from + 45 * 60;
  for (final (a, b) in [(from - 75 * 60, from), (to, to + 75 * 60)]) {
    for (var t = a; t < b; t++) {
      d.accel[t] = (0.7 * math.sin(t * 1.3), -0.2, 0.7 * math.cos(t * 1.3));
    }
  }
  var beatMs = from * 1000;
  for (var t = from; t < to; t++) {
    d.hr[t] = 58 + t % 3 - 1;
    d.accel[t] = (0.30, -0.90, 0.12);
    d.steps.remove(t);
    final beats = <int>[];
    while (beatMs < (t + 1) * 1000) {
      final ms = 1034 + (t % 7) * 4 - 12;
      beatMs += ms;
      beats.add(ms);
    }
    d.rr[t] = beats;
  }
}

/// 14 days of prior baseline history before the first derived day, so every
/// readiness component, the EWMA baselines and the movement baseline have
/// something to score against. Plain formulas, not anyone's physiology.
///
/// The ceiling and resting-HR depth differ by family to pin all three zone
/// sources (see the header): gen5 171 ± 2 under its 187.7 age line; gen4
/// 190 ± 2 over its 184.2 line, with resting HR only for the last 12 days.
Future<void> _seedHistory(String family) async {
  final gen4 = family == 'gen4';
  for (var i = 14; i >= 1; i--) {
    final date = _label(DateTime(2026, 7, 13 - i));
    final w = (i % 5) - 2; // -2..2, a small day-to-day wobble
    final rmssd = 34.0 + 1.5 * w;
    await LocalDb.putMetricSeriesValue(date, 'rmssd', rmssd);
    await LocalDb.putMetricSeriesValue(date, 'ln_rmssd', math.log(rmssd));
    if (!gen4 || i <= 12) {
      await LocalDb.putMetricSeriesValue(date, 'rhr', 51.0 - 0.6 * w);
    }
    await LocalDb.putMetricSeriesValue(date, 'resp_rate', 13.6 + 0.1 * w);
    await LocalDb.putMetricSeriesValue(date, 'skin_temp_adc', 30395.0 + 2 * w);
    await LocalDb.putMetricSeriesValue(
        date, 'hr_ceiling_bpm', (gen4 ? 190.0 : 171.0) + w);
    await LocalDb.putMetricSeriesValue(date, 'dyn_p90', 0.11 + 0.01 * w);
  }
}

/// Everything the derive stored for the window, wall-clock stamps
/// (`computed_at` and the like) dropped: those are when, not what.
Future<Map<String, dynamic>> _snapshot(Profile profile) async {
  final db = await LocalDb.instance;
  final first = _label(_days.first);
  Map<String, dynamic> clean(Map<String, Object?> row) => {
        for (final e in row.entries)
          if (!e.key.endsWith('_at')) e.key: e.value,
      };
  Future<List<Map<String, dynamic>>> rows(String sql) async =>
      [for (final r in await db.rawQuery(sql, [first])) clean(r)];

  final dayResults = await rows(
      'SELECT * FROM day_result WHERE day_id >= ? ORDER BY day_id, algo_version');
  // The stored bytes are pinned by hash and the values decoded beside it, so
  // a wire-encoding change fails here even with identical values, and a value
  // change still shows as a readable diff.
  String sha(Object? stored) =>
      sha256.convert(utf8.encode(stored as String)).toString();
  for (final r in dayResults) {
    r['payload_sha256'] = sha(r['payload_json']);
    r['payload_json'] = SeriesCodec.decodePayloadJson(r['payload_json']);
    r['window_json'] = jsonDecode(r['window_json'] as String);
  }
  final wake = await rows(
      'SELECT * FROM wake_day_features WHERE day_id >= ? ORDER BY day_id');
  for (final r in wake) {
    r['payload_sha256'] = sha(r['payload_json']);
    r['payload_json'] = jsonDecode(r['payload_json'] as String);
  }

  // The rollup over the stored rows, through the same record builder the
  // engine uses. `today` is fixed past the window so no row is today's.
  final crossDayDays = <Map<String, dynamic>>[];
  for (final row in (await LocalDb.recentDayResults(90)).reversed) {
    final payload = SeriesCodec.decodePayloadJson(row['payload_json']);
    if (payload == null || payload['skipped'] == true) continue;
    final rec = DerivationEngine.crossDayInputRecord(
        Map<String, dynamic>.from(row), payload,
        today: '2026-07-16', imported: const {});
    if (rec != null) crossDayDays.add(rec);
  }

  return {
    'day_result': dayResults,
    'metric_series': await rows(
        'SELECT * FROM metric_series WHERE date >= ? ORDER BY date, key'),
    'metric_series_version': await rows(
        'SELECT * FROM metric_series_version WHERE date >= ? ORDER BY date'),
    'wake_day_features': wake,
    'activity_suggestions': await rows(
        'SELECT * FROM activity_suggestions WHERE day_id >= ? '
        'ORDER BY start_ts, kind'),
    'sessions': [
      for (final r in await db.query('sessions', orderBy: 'start_ts')) clean(r)
    ],
    'sleep_nap': await rows(
        'SELECT * FROM sleep_nap WHERE day_id >= ? ORDER BY start_ts'),
    'crossday_input': crossDayDays,
    'crossday': buildCrossDayBundle(crossDayDays, profile.toMap()),
  };
}

void main() {
  final zone = _zoneKey();
  final truth = [for (final d in _days) SyntheticDay(d)];
  _addNap(truth[1]);

  for (final family in const ['gen4', 'gen5']) {
    group('$family freeze', () {
      final profile = _profiles[family]!;

      setUpAll(() async {
        if (zone == null) return;
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        await LocalDb.close();
        LocalDb.dbName = 'whoop_freeze_${family}_test.db';
        final dir = await databaseFactory.getDatabasesPath();
        await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
        await _seedHistory(family);
        // A saved run on the middle day: the ceiling's session path.
        final run = truth[1];
        await LocalDb.putSession({
          'id': 'freeze-run-${_label(run.day)}',
          'start_ts': SyntheticDay.sec(run.runStart),
          'end_ts': SyntheticDay.sec(run.runEnd),
          'type': 'run',
          'status': 'done',
          'source': 'manual',
          'device_family': family,
          'created_at': 0,
        });
        // Review cutoff at 0 so July candidates are kept, not dropped as
        // older than the wall-clock `activated_at`.
        await (await LocalDb.instance)
            .update('activity_review_meta', {'activated_at': 0});
        for (final (raws, samples) in _batches(truth, family)) {
          await LocalDb.commitSyncBatch(raws, samples, deviceFamily: family);
        }
        // One day per pass, oldest first: each day's baseline must already
        // hold the day before it, whatever the engine's concurrency.
        for (final d in _days) {
          await DerivationEngine().runDays(profile, {_label(d)}, force: true);
        }
        // Confirm the detected nap as the review card would and re-derive
        // its day, so the accepted-nap output (naps, nap_min, sleep periods)
        // is pinned and not just the pending proposal.
        final store = ActivityStore(await LocalDb.instance);
        final nap = (await store.pending())
            .singleWhere((s) => s.kind == ActivityKind.nap);
        await store.confirm(nap, startTs: nap.startTs, endTs: nap.endTs);
        await DerivationEngine()
            .runDays(profile, {_label(truth[1].day)}, force: true);
      });

      tearDownAll(() async {
        if (zone == null) return;
        await LocalDb.close();
        final dir = await databaseFactory.getDatabasesPath();
        await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      });

      test('stored output matches the committed golden byte for byte',
          () async {
        if (zone == null) {
          markTestSkipped('goldens exist for TZ=UTC, Asia/Kolkata and '
              'America/New_York only; see the header.');
          return;
        }
        final snap = await _snapshot(profile);
        final file = File('test/fixtures/whoop_freeze/${family}_$zone.json');
        if (Platform.environment['GENERATE_GOLDEN'] == '1') {
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
              '${const JsonEncoder.withIndent(' ').convert(snap)}\n');
          return;
        }
        expect(file.existsSync(), isTrue,
            reason: '${file.path} is missing; see the header.');
        final golden = jsonDecode(file.readAsStringSync());
        expect(jsonEncode(snap), jsonEncode(golden),
            reason: 'WHOOP output must stay byte-identical. Do NOT '
                'regenerate this golden to make a change pass.');
      });
    });
  }
}
