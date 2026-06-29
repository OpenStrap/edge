// Integration test for the on-device V2 compute path:
//   real raw frames (whoop_hist.jsonl) → decodeSubstrate (ONE decode point)
//   → physiologicalDays (wake-to-wake segmentation) → DayBundleInput
//   → deriveDayBundle (the pure isolate entry, called SYNCHRONOUSLY)
//   → assert a sane derived bundle (RHR, an HRV value, no crash).
//
// Also shapes the bundle the way LocalRepositoryImpl.getToday() does and asserts
// it is a well-formed Today map.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  File? fixtureFile() {
    final candidates = [
      '../whoop_hist.jsonl',
      '../../whoop_hist.jsonl',
      'whoop_hist.jsonl',
    ];
    for (final c in candidates) {
      final file = File(c);
      if (file.existsSync()) return file;
    }
    return null;
  }

  // The backfill/insert fix: rec_ts must come from the frame's REAL device time,
  // never from receive time. decodeRecTs is the pure resolver used at insert AND
  // in the v6 migration backfill — if it returned the fallback (≈now) the whole
  // multi-day backfill would collapse into one "today" bucket and hang derivation.
  test('decodeRecTs reads the frame\'s real ts, not the fallback', () {
    final f = fixtureFile();
    expect(f, isNotNull, reason: 'whoop_hist.jsonl fixture not found');

    const sentinelFallback = 111; // a value the real ts can never equal
    final dayLabels = <String>{};
    var decodedCount = 0;
    for (final line in f!.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final hex = (jsonDecode(line) as Map<String, dynamic>)['hex'] as String?;
      if (hex == null) continue;
      final ts = LocalDb.decodeRecTs(hex, fallbackSec: sentinelFallback);
      if (ts == sentinelFallback) continue; // undecodable frame (events etc.)
      decodedCount++;
      expect(
        ts,
        greaterThan(1600000000),
        reason: 'a real 2020+ epoch, not fallback',
      );
      final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: false);
      dayLabels.add('${d.year}-${d.month}-${d.day}');
    }
    expect(decodedCount, greaterThan(50), reason: 'decoded real frames');
    // Every decoded frame bucketed by its own real day (here all one day).
    expect(dayLabels, isNotEmpty);
  });

  test('V2 path: decodeSubstrate → segmentation → deriveDayBundle is sane', () {
    final f = fixtureFile();
    expect(f, isNotNull, reason: 'whoop_hist.jsonl fixture not found');

    final hexes = <String>[];
    for (final line in f!.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final m = jsonDecode(line) as Map<String, dynamic>;
      final hex = m['hex'] as String?;
      if (hex != null) hexes.add(hex);
    }
    expect(hexes.length, greaterThan(100), reason: 'expected real frames');

    // ── ONE decode point: raw hex → Substrate ────────────────────────────────
    final sub = decodeSubstrate(hexes);
    expect(sub.length, greaterThan(50), reason: 'decoded 1 Hz substrate');
    expect(
      sub.hr.where((h) => h > 0).length,
      greaterThan(50),
      reason: 'valid HR samples',
    );
    expect(sub.rrMs.length, greaterThan(50), reason: 'decoded RR beats');

    // ── calendar-day segmentation: a day always exists when there's data ──────
    // The fixture is ~9 min — too short to qualify as a ≥3 h main sleep, so the
    // day is emitted with no sleep (flag NO_SLEEP_DETECTED).
    final days = calendarDays(sub);
    expect(days, isNotEmpty, reason: 'a calendar day always exists');
    final day = days.first;

    // ── coordinator slice → DayBundleInput → deriveDayBundle (synchronous) ────
    // The fixture is ~9 min. Nocturnal RHR needs ≥~15 min (half its 30-min
    // window) of valid HR. Tile the REAL decoded HR/RR forward in time to ~30 min
    // so the night-grade clinical metrics exercise on genuine values — no
    // synthetic numbers, just real samples repeated along a continuous timeline.
    // Treat the whole tiled capture as both the day span AND the HRV/RHR window
    // (in lieu of a qualifying sleep), mirroring the engine's slicing without a DB.
    final n0 = sub.length;
    final tiles = (1800 / n0).ceil() + 1;
    final dayTs = <int>[], dayHr = <int>[];
    final sRed = <int>[], sIr = <int>[], sTemp = <int>[];
    final rrTs = <double>[], rrMs = <double>[];
    final base = sub.tsSec.first;
    for (var t = 0; t < tiles; t++) {
      final shift = t * (n0 + 1);
      for (var i = 0; i < n0; i++) {
        dayTs.add(base + shift + i);
        dayHr.add(sub.hr[i]);
        sRed.add(sub.spo2Red[i]);
        sIr.add(sub.spo2Ir[i]);
        sTemp.add(sub.skinTemp[i]);
      }
      // Re-anchor each RR beat into this tile's second (preserves order/spacing).
      for (var i = 0; i < sub.rrMs.length; i++) {
        rrTs.add(sub.rrTsMs[i] + shift * 1000.0);
        rrMs.add(sub.rrMs[i]);
      }
    }
    final hypno = <String>[
      for (final s in day.sleep.stages)
        s == ana.SleepStage.wake
            ? 'wake'
            : (s == ana.SleepStage.rem ? 'rem' : 'nrem'),
    ];
    final input = DayBundleInput(
      date: day.date,
      dayTsSec: dayTs,
      dayHr: dayHr,
      sleepTsSec: dayTs,
      sleepHr: dayHr,
      sleepRrTsMs: rrTs,
      sleepRrMs: rrMs,
      sleepSpo2Red: sRed,
      sleepSpo2Ir: sIr,
      sleepSkinTemp: sTemp,
      sleepJson: day.sleep.toJson(),
      hypnoStages: hypno,
      sleepOnsetSec: dayTs.first,
      sleepOffsetSec: dayTs.last + 1,
      profile: const {'age': 30, 'sex': 'm', 'weight': 75, 'height': 178},
      dayConfidence: day.confidence,
      dayFlags: day.flags,
    ).toJson();

    final bundle = deriveDayBundle(input);

    // Bundle is well-formed + JSON-serializable.
    expect(bundle['date'], day.date);
    expect(() => jsonEncode(bundle), returnsNormally);

    final scalars = (bundle['scalars'] as Map).cast<String, dynamic>();
    // RHR present + physiologically plausible.
    expect(scalars['rhr'], isNotNull, reason: 'nocturnal RHR computed');
    expect(scalars['rhr'] as num, inInclusiveRange(25, 220));
    // An HRV value present + positive.
    expect(scalars['rmssd'], isNotNull, reason: 'RMSSD computed');
    expect(scalars['rmssd'] as num, greaterThan(0));

    // Clinical envelopes carry the honest {value,confidence,tier} shape.
    final clinical = (bundle['clinical'] as Map).cast<String, dynamic>();
    final hrvTime = (clinical['hrv_time'] as Map).cast<String, dynamic>();
    expect(hrvTime['tier'], anyOf('HIGH', 'AUTH'));
    expect(hrvTime['confidence'] as num, greaterThan(0));

    // Coverage diagnostics.
    final cov = (bundle['coverage'] as Map).cast<String, dynamic>();
    expect(cov['nn_clean'] as num, greaterThan(0));

    // (The secondary Edwards "effort" strain block was removed in the PR#25
    // pipeline refactor; the headline 0–21 strain remains via scalars['strain'].)

    // Winsorized-EWMA personal baselines for rhr/hrv/resp, each carrying the
    // BaselineState fields + a cold-start status (calibrating on a single night).
    final baselines = (bundle['baselines'] as Map).cast<String, dynamic>();
    for (final k in const ['resting_hr', 'hrv', 'resp']) {
      final b = (baselines[k] as Map).cast<String, dynamic>();
      expect(b.containsKey('baseline'), isTrue, reason: '$k baseline');
      expect(b.containsKey('spread'), isTrue, reason: '$k spread');
      expect(
          b['status'],
          anyOf('calibrating', 'provisional', 'trusted', 'stale'),
          reason: '$k status');
    }
    // Whole bundle still JSON-serializable with the new blocks.
    expect(() => jsonEncode(bundle['baselines']), returnsNormally);

    // ── shape it like getToday() and assert a well-formed Today map ──────────
    final today = _shapeToday(bundle);
    expect(today['daily'], isA<Map>());
    final daily = (today['daily'] as Map).cast<String, dynamic>();
    final rhrMetric = (daily['resting_hr'] as Map).cast<String, dynamic>();
    expect(rhrMetric['value'], isNotNull);
    expect(rhrMetric['value'], isNot('—'));
  });
}

/// Minimal mirror of LocalRepositoryImpl.getToday() shaping (no DB).
Map<String, dynamic> _shapeToday(Map<String, dynamic> b) {
  final scalars = (b['scalars'] as Map).cast<String, dynamic>();
  num? sc(String k) => scalars[k] as num?;
  Map<String, dynamic> m(num? v, String tier) => {
    'value': v ?? '—',
    'confidence': v == null ? 0 : 0.8,
    'tier': tier,
    'inputs_used': const [],
  };
  return {
    'daily': {
      'readiness': m(sc('readiness'), 'HIGH'),
      'resting_hr': m(sc('rhr')?.round(), 'HIGH'),
      'strain': m(sc('trimp'), 'ESTIMATE'),
    },
    'sleep': const {},
    'hrv': {'rmssd': sc('rmssd'), 'sdnn': sc('sdnn')},
    'step_goal': 10000,
  };
}
