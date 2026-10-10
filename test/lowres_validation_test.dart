// LOW-RESOLUTION VALIDATION (PLAN_multidevice_analytics §4), on SYNTHETIC
// days only: no real night is in here, and no number below is a claim about
// anyone's physiology.
//
// Each subject is four synthetic days (test/support/synthetic_day.dart) with
// its own physiology: bedtime, wake, waking and sleeping HR, the run, HRV,
// noise. The same days go through the real engine twice:
//   * as a WHOOP strap's 1 Hz samples, the reference;
//   * as each device profile stores them, through that device's real link
//     and its column of the table: 1-min HR + device stages (Garmin; its
//     sleep window is our HR-led one, no stages), 5-min HR + RMSSD + skin
//     temperature + activity with no device stages (Ultrahuman, our stager),
//     and 5-min HR + device stages (Colmi).
// Every served cell that is ours or estimated is compared with the same
// quantity off the 1 Hz day: bias, mean absolute error and the share within
// tolerance, per row x profile. The test fails when a method's MAE passes
// the band its confidence text quotes ([kMethodBand]), or when a band has
// nothing measured behind it.
//
// LOWRES_VALIDATION_OUT=<path> writes the table as markdown.

import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart'
    show miBand234AuthResponse;
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/ble/pebble_link.dart';
import 'package:openstrap_edge/ble/ultrahuman_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart' show at;
import 'package:openstrap_edge/compute/inputs/pebble_inputs.dart'
    show rhrOnlyReadiness;
import 'package:openstrap_edge/compute/inputs/validation_bands.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart' show RawRecord, Sample;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/synthetic_day.dart';

const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);
const List<String> _dayIds = [
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  '2026-10-04',
];

/// Night HR offsets day by day, so resting HR moves against its baseline.
const List<double> _nightSteps = [0, 3, -2, 5];

/// The subjects: SyntheticDay's knobs, one physiology each.
final List<List<SyntheticDay> Function()> _subjects = [
  () => _days(seed: 11),
  () => _days(seed: 12, bed: 45, wake: -30, dayHr: 6, peak: 165, runMin: 60,
      rsa: 0.6, nightHr: 8),
  () => _days(seed: 13, bed: -30, wake: 40, peak: 135, runMin: 25, rsa: 1.4,
      nightHr: -4),
  () => _days(seed: 14, bed: 90, wake: 60, dayHr: -4, peak: 175, runMin: 30,
      nightHr: 2),
  () => _days(seed: 15, bed: 120, wake: -60, dayHr: 10, peak: 155,
      runMin: 50, rsa: 0.8, nightHr: 4),
  () => _days(seed: 16, bed: 20, wake: 15, dayHr: -8, peak: 145, runMin: 75,
      rsa: 1.2, nightHr: -7),
];

List<SyntheticDay> _days({
  required int seed,
  int bed = 0,
  int wake = 0,
  double dayHr = 0,
  int peak = 150,
  int runMin = 40,
  double rsa = 1,
  double nightHr = 0,
}) => [
  for (var d = 1; d <= 4; d++)
    SyntheticDay(DateTime(2026, 10, d),
        seed: seed * 10 + d,
        bedShiftMin: bed,
        wakeShiftMin: wake,
        dayHrOffset: dayHr,
        runPeakBpm: peak,
        runMin: runMin,
        rsaScale: rsa,
        nightHrOffset: nightHr + _nightSteps[d - 1]),
];

/// The same quantity each compared row serves, read off the 1 Hz day.
final Map<String, num? Function(Map day, Map crossDay)> _reference = {
  'sleep_window': (d, _) => nightInBedMin(d),
  'efficiency_awakenings': (d, _) => scalar(d, 'efficiency'),
  'sleep_stages': (d, _) => scalar(d, 'deep_min'),
  'resting_hr': (d, _) => scalar(d, 'rhr'),
  'nadir_dip': (d, _) => scalar(d, 'sleeping_hr_nadir'),
  // Our partial score off the 1 Hz baseline: the resolution's effect on it.
  'readiness': (d, _) => rhrOnlyReadiness(d),
  'strain': (d, _) => scalar(d, 'strain'),
  'calories': (d, _) => scalar(d, 'calories'),
  'baselines_load_illness': (d, _) =>
      at(d, ['baselines', 'resting_hr', 'baseline']),
  'sleep_debt_need_sri': (_, x) => at(x, ['sleep_debt', 'value', 'debt_hours']),
  'circadian': (_, x) => at(x, ['circadian_cosinor', 'value', 'acrophase_hours']),
};

/// The fewest days each banded row must be measured on, per family/method:
/// today's count less one (24 for the HR rows, 23 on Ultrahuman; readiness
/// 18, 17 on Ultrahuman; baselines 18; debt 12). A method that starts
/// abstaining on more days fails here instead of keeping its band on what is
/// left.
const Map<String, int> _minDays = {
  'sleep_window': 23,
  'resting_hr': 22,
  'nadir_dip': 22,
  'strain': 22,
  'calories': 22,
  'readiness': 16,
  'baselines_load_illness': 17,
  'sleep_debt_need_sri': 11,
};

/// What counts as agreeing with the 1 Hz value, in the row's unit.
const Map<String, num> _tolerance = {
  'sleep_window': 20,
  'efficiency_awakenings': 5,
  'sleep_stages': 20,
  'resting_hr': 3,
  'nadir_dip': 3,
  'readiness': 10,
  'strain': 1.5,
  'calories': 150,
  'baselines_load_illness': 3,
  'sleep_debt_need_sri': 0.5,
  'circadian': 1,
};

const Map<String, String> _profiles = {
  'garmin': '1-min HR + device stages',
  'pebble': '1-min HR + device light/deep, no wake',
  'miband234': '1-min HR + device light/deep',
  'ultrahuman': '5-min HR, RMSSD, temp, activity; no device stages',
  'colmi': '5-min HR + device stages',
};

String _label(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map _decode(Object? s) => s is String ? jsonDecode(s) as Map : const {};

/// Opens [name] empty, deleting the run's previous DB (each is read in full
/// before the next opens; a subject's WHOOP DB alone is ~95 MB).
Future<void> _freshDb(String? name) async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  if (LocalDb.dbName.startsWith('lowres_validation_')) {
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  }
  if (name == null) return;
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(p.join(dir, name));
  // Strain is priced against at least three prior days' quiet-waking levels
  // (analytics `personalQuietWakingHrr`), so a four-day subject would price
  // it on its last day only. Three seeded days before the first, the same
  // level for the 1 Hz reference and the device, price every day.
  for (final d in ['2026-09-28', '2026-09-29', '2026-09-30']) {
    await LocalDb.putMetricSeriesValue(d, 'quiet_hrr', 0.2);
  }
}

/// The days' 1 Hz samples, contiguous, as a WHOOP drain commits them (each
/// day's window picks up where the last one ended).
Iterable<(List<RawRecord>, List<Sample>)> _whoopBatches(
    List<SyntheticDay> days) sync* {
  final t0 = SyntheticDay.sec(days.first.start);
  for (var k = 0; k < days.length; k++) {
    final d = days[k];
    final from = SyntheticDay.sec(k == 0 ? d.start : days[k - 1].end);
    final to = SyntheticDay.sec(d.end);
    for (var b = from; b < to; b += 3600) {
      final raws = <RawRecord>[];
      final samples = <Sample>[];
      for (var t = b; t < to && t < b + 3600; t++) {
        final counter = t - t0 + 1;
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
        ));
      }
      yield (raws, samples);
    }
  }
}

/// {date -> {row -> 1 Hz value}} for [days] as a WHOOP strap.
Future<Map<String, Map<String, num?>>> _whoop(
    int subject, List<SyntheticDay> days) async {
  await _freshDb('lowres_validation_${subject}_whoop.db');
  for (final (raws, samples) in _whoopBatches(days)) {
    await LocalDb.commitSyncBatch(raws, samples, deviceFamily: 'gen4');
  }
  // One day per pass, oldest first: each baseline holds the day before.
  for (final d in _dayIds) {
    await DerivationEngine().runDays(_profile, {d}, force: true);
  }
  return {
    for (final d in _dayIds)
      d: await () async {
        final day = _decode((await LocalDb.dayResult(d))?['payload_json']);
        final x = await crossDayAsOf(d);
        final truth = days.firstWhere((t) => _label(t.day) == d);
        for (final (row, v) in [
          ('sleep_window', nightInBedMin(day)),
          ('sleep_stages', scalar(day, 'deep_min')),
          ('total sleep', scalar(day, 'tst_min')),
        ]) {
          _addTruth('1 Hz reference', row, v, truth);
        }
        return {for (final e in _reference.entries) e.key: e.value(day, x)};
      }(),
  };
}

/// {date -> served cells} for [days] as [adapter] stores them.
Future<Map<String, Map<String, Map<String, Object?>>>> _device(
    int subject, String adapter, List<SyntheticDay> days) async {
  await _freshDb('lowres_validation_${subject}_$adapter.db');
  final id = '$adapter-validation-$subject';
  await LocalDb.upsertDevice(
      id: id, adapterId: adapter, remoteId: 'AA:BB:CC:00:01:0$subject',
      label: adapter);
  int now() => SyntheticDay.sec(_now);
  switch (adapter) {
    case 'garmin':
      await GarminLink.instance.ingestForTest(
          id, GarminWatchScript(SyntheticDay.garminDays(days)).reply,
          nowSeconds: now);
    case 'pebble':
      await PebbleLink.instance.ingestForTest(id, SyntheticDay.pebbleDays(days),
          nowSeconds: now);
    case 'miband234':
      final key = List<int>.generate(16, (i) => i + 1);
      final challenge = List<int>.generate(16, (i) => 0xa0 + i);
      await MiBand234Link.instance.ingestForTest(
        id,
        key,
        (_, w) => switch (w[0]) {
          0x02 => [
              [0x10, 0x02, 0x01, ...challenge],
            ],
          0x03 => [
              [
                0x10,
                0x03,
                w.sublist(2).toString() ==
                        miBand234AuthResponse(key, challenge).toString()
                    ? 0x01
                    : 0x04,
              ],
            ],
          _ => const <List<int>>[],
        },
        history: SyntheticDay.miBandHistory(days, _now),
        nowSeconds: now,
        window: const Duration(seconds: 5),
      );
    case 'ultrahuman':
      final records = SyntheticDay.ultrahumanDays(days);
      await UltrahumanLink.instance.ingestForTest(
          id, (_, w) => SyntheticDay.ultrahumanRingReply(records, w),
          nowSeconds: now);
    case 'colmi':
      await ColmiLink.instance.ingestForTest(
          id, (_, w) => SyntheticDay.colmiRingReply(days, w, _now),
          nowSeconds: now);
  }
  await LocalDb.setCursor(kActiveWearableCursor, id);
  await LocalDb.setCursor(wearableEnabledCursor(adapter), '1');
  for (final d in _dayIds) {
    await DerivationEngine().runDays(_profile, {d}, force: true);
  }
  return {for (final d in _dayIds) d: (await dayCells(d)) ?? const {}};
}

/// The 1 Hz reference against the synthetic truth, so the table also says
/// how far the reference itself sits from what the days were built with.
final truthErrors = <String, _Errors>{};

/// [v] against what [truth] was built with, for [row]: the in-bed span
/// (bed to wake), deep minutes or minutes asleep.
void _addTruth(String who, String row, num? v, SyntheticDay truth) {
  if (v == null) return;
  final want = switch (row) {
    'sleep_window' =>
      (SyntheticDay.sec(truth.sleepOffset) - SyntheticDay.sec(truth.inBed)) ~/
          60,
    'sleep_stages' => truth.deepMin,
    _ => truth.tstMin,
  };
  truthErrors
      .putIfAbsent('$who/$row', () => _Errors(null))
      .diffs
      .add((v - want).toDouble());
}

class _Errors {
  final String? method;
  final diffs = <double>[];
  _Errors(this.method);
  int get n => diffs.length;
  double get bias => diffs.reduce((a, b) => a + b) / n;
  double get mae => diffs.map((e) => e.abs()).reduce((a, b) => a + b) / n;
  double within(num tol) => diffs.where((e) => e.abs() <= tol).length / n;
}

void main() {
  // {'family/row/method' -> errors}
  final errors = <String, _Errors>{};
  final missing = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() => _freshDb(null));

  // One test per subject's 1 Hz reference (it derives four full days) and
  // one per subject x profile, so each stays well inside its timeout under
  // load; the bands are checked over all of them below.
  for (var s = 0; s < _subjects.length; s++) {
    // Built when its first test runs, dropped after its last.
    List<SyntheticDay>? subject;
    late final Map<String, Map<String, num?>> ref;
    test('subject $s: the 1 Hz reference', () async {
      ref = await _whoop(s, subject ??= _subjects[s]());
    }, timeout: const Timeout(Duration(minutes: 4)));
    for (final adapter in _profiles.keys) {
      test('subject $s: $adapter', () async {
        final days = subject ??= _subjects[s]();
        if (adapter == _profiles.keys.last) subject = null;
        final served = await _device(s, adapter, days);
        for (final d in _dayIds) {
          for (final row in _reference.keys) {
            final cell = served[d]?[row];
            final cls = cell?['class'];
            if (cls != 'ours' && cls != 'estimated') continue;
            final r = ref[d]![row];
            if (r == null) {
              missing.add('$adapter $row $d: no 1 Hz value');
              continue;
            }
            if (row == 'sleep_window' || row == 'sleep_stages') {
              _addTruth(adapter, row, cell!['value'] as num,
                  days.firstWhere((t) => _label(t.day) == d));
            }
            final method = cell!['method'] as String?;
            // The served cell carries the band this run measures (canonical
            // wiring, not a measurement).
            expect(cell['band'], methodBand(adapter, row, method));
            errors
                .putIfAbsent('$adapter/$row/$method', () => _Errors(method))
                .diffs
                .add((cell['value'] as num) - r.toDouble());
          }
        }
      }, timeout: const Timeout(Duration(minutes: 4)));
    }
  }

  test('every low-res method sits inside the band its confidence text quotes',
      () {
    final lines = <String>[
      '| Row | Profile | Method | n | Bias | MAE | Tolerance | Within |',
      '|---|---|---|---|---|---|---|---|',
    ];
    for (final MapEntry(key: k, value: e) in errors.entries) {
      final [adapter, row, _] = k.split('/');
      final tol = _tolerance[row]!;
      lines.add('| $row | $adapter (${_profiles[adapter]}) | ${e.method} | '
          '${e.n} | ${e.bias.toStringAsFixed(2)} | '
          '${e.mae.toStringAsFixed(2)} | ±$tol | '
          '${(100 * e.within(tol)).round()}% |');
    }
    lines
      ..add('')
      ..add('| Against the synthetic truth | Row | n | Bias | MAE |')
      ..add('|---|---|---|---|---|');
    for (final MapEntry(key: k, value: e) in truthErrors.entries) {
      final [who, row] = k.split('/');
      lines.add('| $who | $row | ${e.n} | ${e.bias.toStringAsFixed(2)} | '
          '${e.mae.toStringAsFixed(2)} |');
    }
    final table = lines.join('\n');
    // ignore: avoid_print
    print('$table\n${missing.join('\n')}');
    final out = Platform.environment['LOWRES_VALIDATION_OUT'];
    if (out != null) File(out).writeAsStringSync('$table\n');

    for (final MapEntry(key: k, value: e) in errors.entries) {
      final band = kMethodBand[k];
      if (band == null) continue;
      final [adapter, row, _] = k.split('/');
      // A sleep band is against the truth the nights were built with: the
      // 1 Hz reference itself sits half an hour off it.
      final m = kTruthBandRows.contains(row)
          ? truthErrors['$adapter/$row']!
          : e;
      expect(m.mae, lessThanOrEqualTo(band), reason: k);
      expect(m.n, greaterThanOrEqualTo(_minDays[row]!),
          reason: '$k measured on too few days');
    }
    expect(missing, isEmpty, reason: 'a served cell with no 1 Hz value');
    expect(kMethodBand.keys.where((k) => !errors.containsKey(k)), isEmpty,
        reason: 'every band in kMethodBand must be measured here');
  });
}
