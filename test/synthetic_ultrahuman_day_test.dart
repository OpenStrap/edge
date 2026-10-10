// An Ultrahuman Ring Air as the ACTIVE WEARABLE, no primary band at all: four
// synthetic days (test/support/synthetic_day.dart) synced through the real
// Ultrahuman link, derived by the real engine off the ring's 5-minute
// records, and served cell by cell as Ultrahuman's column of the metric x
// device table (lib/compute/inputs/ultrahuman_inputs.dart). Each cell must
// come back in its class (ours / device / estimated / unavailable) with a
// value the truth makes plausible.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/ultrahuman_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart' show kHrCadenceSec;
import 'package:openstrap_edge/compute/inputs/ultrahuman_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/strap_day.dart';
import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
final SyntheticDay _truth = _days.last;
const String _dayId = '2026-10-04';
const Set<String> _dayIds = {
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  _dayId,
};
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Map _payload(Map<String, Object?> row) =>
    jsonDecode(row['payload_json'] as String) as Map;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_ultrahuman_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: 'ultrahuman-synthetic',
        adapterId: 'ultrahuman',
        remoteId: 'AA:BB:CC:00:00:04',
        label: 'ultrahuman');
    final records = SyntheticDay.ultrahumanDays(_days);
    // One turnover 25 minutes into the night that begins on 2 October: the
    // still stretch before it is that night's first sleep, not a nap.
    final turn = SyntheticDay.sec(DateTime(2026, 10, 2, 23, 35));
    for (final r in records) {
      final b = ByteData.sublistView(Uint8List.fromList(r));
      if (b.getUint32(0, Endian.little) == turn) r[26] = 5; // steps
    }
    final now = DateTime(2026, 10, 4, 22, 30);
    await UltrahumanLink.instance.ingestForTest('ultrahuman-synthetic',
        (_, w) => SyntheticDay.ultrahumanRingReply(records, w),
        nowSeconds: () => SyntheticDay.sec(now));
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the ring moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    // The ring keeps no night of its own, so nothing at all is derived.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: every Ultrahuman cell derives, stores and serves in its '
      'class', () async {
    await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
    // Twice: the first pass derives the days concurrently, so the baselines
    // and the cross-day rollup only see each other on the second.
    for (var i = 0; i < 2; i++) {
      expect(
          await DerivationEngine().runDays(_profile, _dayIds, force: true), 4);
    }
    final cells = (await dayCells(_dayId))!;
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(cells));
    String cls(String row) => cells[row]!['class'] as String;
    num v(String row) => cells[row]!['value'] as num;

    expect({for (final r in cells.keys) r: cls(r)}, {
      'sleep_window': 'ours',
      'efficiency_awakenings': 'ours',
      'sleep_stages': 'estimated',
      'naps': 'estimated',
      'sleep_debt_need_sri': 'ours',
      'resting_hr': 'ours',
      'nadir_dip': 'ours',
      'hrv': 'device',
      'respiratory_rate': 'unavailable',
      'spo2': 'device',
      'stress': 'unavailable',
      'skin_temp': 'ours',
      'readiness': 'estimated',
      'irregular_rhythm': 'unavailable',
      'steps': 'device',
      'strain': 'estimated',
      'calories': 'estimated',
      'movement': 'estimated',
      'auto_workouts': 'unavailable',
      'workouts_with_strap': 'unavailable',
      'hrr': 'unavailable',
      'baselines_load_illness': 'ours',
      'circadian': 'ours',
    });
    for (final r in cells.keys) {
      if (cls(r) == 'unavailable') {
        expect(cells[r]!['reason'], isNotEmpty, reason: r);
      }
    }

    // Ours, at the ring's resolution.
    expect(cells['resting_hr']!['method'], 'hr_5min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(v('nadir_dip'), inInclusiveRange(40, v('resting_hr')));
    expect(v('baselines_load_illness'), closeTo(v('resting_hr'), 3));
    // A minute or two of surplus is the turnover night's: the need averages
    // in its shorter sleep.
    expect(v('sleep_debt_need_sri'), inInclusiveRange(-0.1, 2));
    expect(v('circadian'), inInclusiveRange(0, 24));

    // The night is ours: staged off the ring's records, not the ring's.
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    expect(full['sleep_source'], 'auto');
    expect(full['device_family'], 'ultrahuman');
    // The row is the night's in-bed span, as on every device; its edges sit
    // at the truth's onset and wake, within the bounds the watches get.
    final win = ((full['sleep'] as Map)['window'] as Map)['value'] as Map;
    expect(v('sleep_window'), nightInBedMin(full));
    expect(((win['onset_ms'] as num) ~/ 1000 -
            SyntheticDay.sec(_truth.sleepOnset)).abs(),
        lessThanOrEqualTo(25 * 60));
    expect(((win['offset_ms'] as num) ~/ 1000 -
            SyntheticDay.sec(_truth.sleepOffset)).abs(),
        lessThanOrEqualTo(20 * 60));
    // Time asleep inside it: one record per 5 minutes reads a brief wake as
    // a whole record, so the stager may under-count, but never by more than
    // 50 minutes of the truth, and never past the window.
    final tst = (full['scalars'] as Map)['tst_min'] as num;
    expect(tst, inInclusiveRange(_truth.tstMin - 50, v('sleep_window')));
    // Skin temperature covers the night at the ring's cadence, not 1 Hz.
    expect((full['scalars'] as Map)['skin_temp_coverage_frac'],
        inInclusiveRange(0.8, 1.0));
    expect(v('efficiency_awakenings'), inInclusiveRange(85, 100));

    // Estimated where the ring gives nothing: deep minutes off our 5-minute
    // stager, no nap in a day that has none, a still night, and strain and
    // calories off one HR every 5 minutes.
    expect(cells['sleep_stages']!['method'], 'hr_5min_stager');
    expect((v('sleep_stages') - _truth.deepMin).abs(), lessThanOrEqualTo(45));
    expect(v('naps'), 0);
    // Every other day too: tonight's sleep starting before midnight, turned
    // over once on 2 October, is not a daytime nap.
    for (final d in _dayIds) {
      expect((_payload((await LocalDb.dayResult(d))!)['ring_day']
              as Map)['nap_min'],
          0,
          reason: d);
    }
    expect(v('movement'), lessThan(0.1));
    expect(cells['strain']!['method'], 'hr_5min');
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm');
    expect(v('calories'), inInclusiveRange(200, 1500));

    // Skin temperature: ours is the deviation off the ring's own nights in
    // °C, the ring's daily mean beside it.
    expect(cells['skin_temp']!['method'], 'skin_temp_c_5min');
    expect(v('skin_temp').abs(), lessThan(3));
    expect(cells['skin_temp']!['device_value'] as num,
        inInclusiveRange(33, 36));
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(v('readiness'), closeTo(50, 15),
        reason: 'four nights of the same physiology: no deviation to score');

    // The ring's own values, labelled, over the night (RMSSD 48 and SpO2 96
    // asleep, 32 and 98 awake): not its calendar-day means, which take the
    // waking hours in and sit nowhere near the nightly value beside them.
    expect(v('hrv'), inInclusiveRange(45, 48));
    expect(v('spo2'), inInclusiveRange(96, 96.5));
    expect(cells['hrv']!['value'],
        ((full['ring_day'] as Map)['device_night'] as Map)['rmssd']);
    expect(v('steps'), _truth.stepsOn(_truth.day));
    // Our stager's wake, against the truth night (10 min of wake, one
    // sustained awakening). One record per 5 minutes reads part of REM as
    // wake, so it over-counts both; asserted here only as consistent, the
    // gap to the truth is open (see ringNapMin's and stageRingEpoch's notes).
    final acct = ((((full)['sleep'] as Map)['accounting'] as Map)['value'] as Map);
    expect((acct['tst_sec'] as int) + (acct['waso_sec'] as int),
        acct['in_bed_sec']);
    expect(acct['awakenings'], greaterThanOrEqualTo(1));
    // Sleep need and regularity on the device's epochs: four nights on the
    // same clock regularise to 100 (less the one turnover's wake epoch), and
    // with no debt and no nap the need is the habitual night, the stored one
    // within a quarter hour.
    final xm = await crossDayAsOf(_dayId);
    expect(((xm['regularity'] as Map)['value'] as Map)['sri'],
        inInclusiveRange(97, 100));
    expect(((xm['sleep_debt'] as Map)['value'] as Map)['debt_hours'],
        inInclusiveRange(-0.1, 0));
    expect(
        ((((xm['sleep_coach'] as Map)['need'] as Map)['value'] as Map)[
                    'need_sec'] as num) /
                60 -
            ((full['scalars'] as Map)['tst_min'] as num),
        inInclusiveRange(-15, 15));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with 14 nights behind it, readiness is ours: the partial composite '
      'over resting HR and skin temperature, scored only against the ring\'s '
      'own nights', () async {
    // Fourteen ring nights before the four synced ones, stamped as the ring's
    // days, and three older days of a band in between whose skin temperature
    // is a different sensor's number (ADC counts, ~10x the ring's centi-°C).
    final db = await LocalDb.instance;
    Future<void> stamp(String date, String family) => db.insert(
        'metric_series_version',
        {'date': date, 'algo_version': kAlgoVersion, 'device_family': family},
        conflictAlgorithm: ConflictAlgorithm.replace);
    for (var i = 1; i <= 14; i++) {
      final date = DateTime(2026, 10, 1 - i).toIso8601String().substring(0, 10);
      final w = (i % 5) - 2;
      await LocalDb.putMetricSeriesValue(date, 'rhr', 48.0 + w);
      await LocalDb.putMetricSeriesValue(date, 'skin_temp_adc', 3530.0 + 5 * w);
      await stamp(date, 'ultrahuman');
    }
    for (final date in ['2026-09-11', '2026-09-12', '2026-09-13']) {
      await LocalDb.putMetricSeriesValue(date, 'skin_temp_adc', 30395.0);
      await stamp(date, 'gen5');
    }
    // Another ring at the same 5-minute resolution: its resting HR may share
    // the baseline, its finger temperature is another sensor's.
    for (final date in ['2026-09-14', '2026-09-15', '2026-09-16']) {
      await LocalDb.putMetricSeriesValue(date, 'skin_temp_adc', 3000.0);
      await stamp(date, 'colmi');
    }
    // A day written before days were stamped with a family: most likely a
    // band's, so a ring's temperature baseline never takes it.
    await LocalDb.putMetricSeriesValue('2026-09-10', 'skin_temp_adc', 805.0);
    // The rings' newest days take no part in the band's family seam (they
    // used to mask every band day out of its own baseline).
    expect(await LocalDb.foreignFamilyDates(ignore: kHrCadenceSec.keys),
        isEmpty);
    Future<Set<double>> tempBase(String family) async =>
        (await debugSweepBaselineWindows('skin_temp_adc', [_dayId],
                deviceFamily: family))
            .single
            .toSet();
    final ring = await tempBase('ultrahuman');
    expect(ring, isNot(contains(3000.0)));
    expect(ring, isNot(contains(30395.0)));
    expect(ring, isNot(contains(805.0)));
    expect(ring.length, greaterThanOrEqualTo(5));
    expect(await tempBase('colmi'), {3000.0});
    // A band still reads an unstamped day as its own, as it always has.
    expect(await tempBase('gen5'), {805.0, 30395.0});

    for (var i = 0; i < 2; i++) {
      await DerivationEngine().runDays(_profile, _dayIds, force: true);
    }
    final cells = (await dayCells(_dayId))!;
    expect(cells['readiness']!['class'], 'ours');
    expect(cells['readiness']!['method'], kPartialReadinessMethod);
    expect(cells['readiness']!['value'] as num, inInclusiveRange(20, 80),
        reason: 'a night inside its own baseline');
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    final env = (full['clinical'] as Map)['readiness_composite'] as Map;
    expect(env['inputs_used'], ['RHR', 'temp'],
        reason: 'the band days\' counts never reach the ring\'s baseline');
    expect(env['class'], 'ours');
    expect(env['method'], kPartialReadinessMethod);
    // Its temperature gate rests on the ring's provisional settle band, so
    // the composite's 0.6 (two inputs) is halved and says why, on the stored
    // envelope and on the served cells alike.
    expect(env['provisional'], isTrue);
    expect(env['confidence'], 0.3);
    expect(cells['readiness']!['provisional'], isTrue);
    expect(cells['skin_temp']!['provisional'], isTrue);
    expect(((full['wellness'] as Map)['skin_temp'] as Map)['confidence'], 0.25);
    // The ring's own RMSSD stays a device value: nothing of it is in the
    // HRV series our baselines read.
    final hrv = await db.rawQuery(
        "SELECT * FROM metric_series WHERE key IN ('rmssd', 'ln_rmssd') "
        'AND date >= ?',
        ['2026-10-01']);
    expect(hrv.where((r) => r['value'] != null), isEmpty);
    expect(cells['hrv']!['class'], 'device');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap's session on the ring's day: its workout and heart-rate "
      'recovery are ours, off the strap at 1 Hz', () async {
    const strap = 'hrs-ultrahuman-synthetic';
    await LocalDb.upsertDevice(id: strap, adapterId: 'ble_hrs');
    // 20 minutes at 140 bpm at noon, then 30 bpm a minute of recovery: the
    // drop 60 s after the end is 30. The ring saw none of it at that rate.
    final start = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
    final end = start + 20 * 60;
    int bpm(int t) =>
        t <= end ? 140 : (140 - 30 * (t - end) / 60).round().clamp(95, 140);
    await HrsLink.instance.ingestForTest(strap, [
      for (var t = start; t <= end + kStrapTailSec; t++) (t, [0x00, bpm(t)]),
    ]);
    await LocalDb.putSession({
      'id': 'strap-session',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'created_at': end,
    });
    Future<Map<String, Map<String, Object?>>> cells() async {
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
      return (await dayCells(_dayId))!;
    }

    var c = await cells();
    expect(c['workouts_with_strap']!['class'], 'unavailable');
    expect(c['hrr']!['class'], 'unavailable');

    await useDevice(strap, 'ble_hrs', true);
    c = await cells();
    expect(c['workouts_with_strap'],
        allOf(containsPair('class', 'ours'), containsPair('value', 1),
            containsPair('method', 'hr_1hz')));
    expect(c['hrr']!['class'], 'ours');
    expect(c['hrr']!['method'], 'hr_1hz');
    expect(c['hrr']!['value'] as num, closeTo(30, 3));
    // The ring's own night and numbers are untouched by the session.
    expect(c['resting_hr']!['method'], 'hr_5min');
    await useDevice(strap, 'ble_hrs', false);
    // useDevice made the strap's flag the only change; the ring stays active.
    expect((await activeWearable())?.$2, 'ultrahuman');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('band rows left from before the ring do not hold its days back: the '
      'data edge is the later of the two', () async {
    // One band second a month before the ring's days, as a user who moved
    // from the band to the ring keeps.
    final db = await LocalDb.instance;
    final old = SyntheticDay.sec(DateTime(2026, 9, 1, 12));
    await db.insert('decoded_onehz', {
      'device_id': 'band-old',
      'ts_ms': old * 1000,
      'rec_ts': old,
      'counter': 1,
      'hr': 60,
      'device_family': 'gen4',
    });
    expect(await LocalDb.lastDecodedRecTs(), old);
    await DerivationEngine().runDays(_profile, _dayIds, force: true);
    // Aged off the ring's edge, as on a ring-only install; off the band's
    // stale edge nothing would ever finalize.
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains('2026-10-01'));
    // But a band day ages only on the band's own edge, however far the ring
    // has run ahead: a backlog the band has not drained yet may still hold
    // its rows. Unstamped (strap-swap) days are the band's too.
    final ringEdge = (await wearableLastTs())!;
    expect(await debugAgingEdge('gen4', ringEdge), old);
    expect(await debugAgingEdge(null, ringEdge), old);
    expect(await debugAgingEdge('ultrahuman', ringEdge + 999), ringEdge);
    // And a baseline change rescans the ring's recent days (the four, and
    // 30 Sep, where the first night began), not only the band's (which are
    // past the rescan window here).
    await LocalDb.setCursor('baseline_sig', 'stale');
    expect(await DerivationEngine().rescanRecent(_profile), 5);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the 5-minute stager reads a record against the night\'s levels', () {
    UltrahumanRecord rec(int hr,
            {int hrv = 40, int steps = 0, int activity = 0}) =>
        UltrahumanRecord(
          tsA: 0,
          hr: hr,
          hrv: hrv,
          spo2: 97,
          hrQuality: kUltrahumanHrQualityLegacy,
          tsB: 0,
          skinTempC: 35,
          ambientTempC: 22,
          tsC: 0,
          activity: activity,
          steps: steps,
          hrvSdnn: 0,
          tempQuality: 1,
          index: 1,
        );
    String st(UltrahumanRecord r) =>
        stageRingEpoch(r, hrBase: 52, hrvMedian: 40, tempMedian: 35);
    expect(st(rec(50, hrv: 45)), 'deep');
    expect(st(rec(55)), 'light');
    expect(st(rec(58, hrv: 30)), 'rem');
    expect(st(rec(63)), 'wake');
    expect(st(rec(50, steps: 3)), 'wake');
    // The activity field has no stated scale: a ring resting above zero on
    // it is still asleep.
    expect(st(rec(50, hrv: 45, activity: 2)), 'deep');
    expect(st(rec(50, hrv: 30)), 'light', reason: 'low HR, low RMSSD');
  });

  test("the engine's own nap and active minutes keep their own label, not "
      "the ring rows' estimates", () {
    final of = seriesMethodFor(kUltrahumanFamily)!;
    for (final k in ['nap_min', 'active_min']) {
      expect(of(k).cls, 'ours', reason: k);
      expect(of(k).method, isNot(anyOf('hr_5min_rest', 'steps_5min')),
          reason: k);
    }
    expect(of('strain').cls, 'estimated');
  });

  test('daytime rest counts only runs that end in the day, 20 min to 3 h', () {
    UltrahumanRecord rec(int hr, {int steps = 0}) => UltrahumanRecord(
          tsA: 0,
          hr: hr,
          hrv: 40,
          spo2: 97,
          hrQuality: kUltrahumanHrQualityLegacy,
          tsB: 0,
          skinTempC: 35,
          ambientTempC: 22,
          tsC: 0,
          activity: 0,
          steps: steps,
          hrvSdnn: 0,
          tempQuality: 1,
          index: 1,
        );
    List<UltrahumanRecord> rest(int n) => [for (var i = 0; i < n; i++) rec(54)];
    List<UltrahumanRecord> awake(int n) =>
        [for (var i = 0; i < n; i++) rec(72, steps: 10)];
    // A 45-minute nap between two awake stretches.
    expect(ringNapMin([...awake(20), ...rest(9), ...awake(20)], 54), 45);
    // 15 minutes is not a nap.
    expect(ringNapMin([...awake(20), ...rest(3), ...awake(20)], 54), 0);
    // Rest still running at the day's last record is tonight's sleep.
    expect(ringNapMin([...awake(20), ...rest(12)], 54), 0);
    // A rest over 3 h is a night, not a nap.
    expect(ringNapMin([...awake(5), ...rest(40), ...awake(5)], 54), 0);
    // A still lie-in right after the night is its tail, not a nap; a nap
    // later the same day still counts.
    expect(ringNapMin([...rest(9), ...awake(20)], 54), 0);
    expect(ringNapMin([...rest(9), ...awake(20), ...rest(9), ...awake(5)], 54),
        45);
    // HR above the night's median + 5 is not rest.
    expect(ringNapMin([...awake(5), ...[for (var i = 0; i < 9; i++) rec(60)],
        ...awake(5)], 54), 0);
  });

  test("a strap worn at rest overnight on the ring's day: its HRV is ours "
      "off the beats, the ring's own beside it", () async {
    await checkStrapDay('hrs-ultrahuman-night', _truth, _dayId, _profile,
        deviceHrv: true);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a band worn into the afternoon before the ring\'s night does not '
      'leave that night unstaged', () async {
    // The band until 15:00 the day before, then the ring overnight: the day
    // is the ring's (no band row on it), and so is its night, though the
    // band's afternoon sits inside the night's search window.
    await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
    final db = await LocalDb.instance;
    final from = SyntheticDay.sec(DateTime(2026, 10, 3, 13));
    final batch = db.batch();
    for (var t = from; t < from + 2 * 3600; t++) {
      batch.insert('decoded_onehz', {
        'device_id': 'band-handover',
        'ts_ms': t * 1000,
        'rec_ts': t,
        'counter': t - from,
        'hr': 72,
        'device_family': 'gen4',
      });
    }
    await batch.commit(noResult: true);
    try {
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
      final full = _payload((await LocalDb.dayResult(_dayId))!);
      expect(full['device_family'], 'ultrahuman');
      expect(nightInBedMin(full), isNotNull);
      expect((await dayCells(_dayId))!['sleep_window']!['class'], 'ours');
    } finally {
      await db.delete('decoded_onehz',
          where: 'device_id = ?', whereArgs: ['band-handover']);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("the native cards never show the ring's estimates bare; a band's day "
      'comes back as it is', () async {
    await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    final full = _payload((await LocalDb.dayResult(_dayId))!)
        .cast<String, dynamic>();
    expect((full['scalars'] as Map)['strain'], isNotNull);
    final shown = withoutWearableEstimates(full);
    final scalars = shown['scalars'] as Map;
    // Estimated on the ring's column: strain, calories, stages.
    for (final k in ['strain', 'calories', 'deep_min']) {
      expect(scalars.containsKey(k), isFalse, reason: k);
    }
    expect((shown['series'] as Map?)?['hypnogram'], isNull);
    expect(shown['zones'], isNull);
    // Ours stays.
    expect(scalars['rhr'], (full['scalars'] as Map)['rhr']);
    expect(scalars['tst_min'], (full['scalars'] as Map)['tst_min']);
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getDayStrain(_dayId))['strain'], isNull);
    // A band's day is untouched.
    final band = <String, dynamic>{
      'device_family': 'gen4',
      'scalars': {'strain': 9.0, 'deep_min': 80},
      'zones': {'z1': 3},
    };
    expect(identical(withoutWearableEstimates(band), band), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('switching the ring off, or away and back: off, nothing of it stays '
      'served; back, its days derive again from its own records', () async {
    await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
    await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    await DerivationEngine().runDays(_profile, _dayIds, force: true);
    expect(await dayCells(_dayId), isNotNull);
    final rederived = <String>{};
    onWearableDaysChanged = (days) async {
      rederived.addAll(days);
      await DerivationEngine().runDays(_profile, days, force: true);
    };
    try {
      // Flag off (rule R6): every day only the ring decided is cleared.
      await setWearableEnabled('ultrahuman', false);
      expect(await LocalDb.dayResult(_dayId), isNull);
      expect(await dayCells(_dayId), isNull);
      // A re-derive takes nothing of the ring either. (A day the earlier
      // tests logged a session on may still derive, off no ring record.)
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
      final off = await LocalDb.dayResult(_dayId);
      if (off != null) {
        final p = _payload(off);
        expect(p['device_family'], isNot('ultrahuman'));
        expect(p['ring_day'], isNull);
        expect(nightInBedMin(p), isNull);
        expect((p['scalars'] as Map?)?['rhr'], isNull);
      }
      expect(await dayCells(_dayId), isNull);
      // Back on, then away to no wearable, then back to the ring.
      await setWearableEnabled('ultrahuman', true);
      expect(rederived, containsAll(_dayIds));
      expect(_payload((await LocalDb.dayResult(_dayId))!)['device_family'],
          'ultrahuman');
      await setActiveWearable(null);
      expect(await LocalDb.dayResult(_dayId), isNull);
      rederived.clear();
      await setActiveWearable('ultrahuman-synthetic');
      expect(rederived, containsAll(_dayIds));
      final full = _payload((await LocalDb.dayResult(_dayId))!);
      expect(full['device_family'], 'ultrahuman');
      expect(full['ring_day'], isNotNull);
      expect((await dayCells(_dayId))!['sleep_window']!['class'], 'ours');
    } finally {
      onWearableDaysChanged = null;
      await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
      await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test("the ring's estimates and day means stay off every native surface; "
      'a dropped day mean says no night', () async {
    await LocalDb.setCursor(kActiveWearableCursor, 'ultrahuman-synthetic');
    await LocalDb.setCursor(wearableEnabledCursor('ultrahuman'), '1');
    // Twice, so the skin deviation has its baseline nights (see above).
    for (var i = 0; i < 2; i++) {
      await DerivationEngine().runDays(_profile, _dayIds, force: true);
    }
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    final night =
        (full['ring_day'] as Map)['device_night'] as Map<String, dynamic>;

    // Stage minutes are the stager's estimate, like deep_min: not on the
    // Sleep screen's stage block, nor on the main period.
    final sleep = await repo.getDaySleepV2(_dayId);
    for (final k in ['light_min', 'deep_min', 'rem_min', 'nrem_min']) {
      expect(sleep[k], isNull, reason: k);
    }
    for (final p in (sleep['periods'] as List).cast<Map>()) {
      expect(p['stages'], isNull);
    }
    // The skin deviation rests on a provisional settle band: it says so.
    expect(((await repo.getDayHeart(_dayId))['skin_temp'] as Map)['provisional'],
        isTrue);
    // getToday's block, the one the Health row reads, carries it too.
    expect(((await repo.getToday())['skin_temp'] as Map)['provisional'],
        isTrue);
    // The load counts the ring's estimated TRIMP: it says so where shown,
    // and so does the strain target built on it.
    expect(((await repo.getInsights())['load'] as Map)['estimated'], isTrue);
    expect(
        coachToday({
          'strain_coach': {
            'value': {'target_min': 8, 'target_max': 12},
            'estimated': true,
          },
        })!['strain_target']['estimated'],
        isTrue);
    // Trend charts draw no estimated point; ours still draw.
    expect((await repo.getChart('strain'))['points'], isEmpty);
    expect((await repo.getChart('deep'))['points'], isEmpty);
    expect((await repo.getChart('resting_hr'))['points'], isNotEmpty);
    // The movement row is named for what it reads: records with steps.
    expect((await dayCells(_dayId))!['movement']!['method'], 'steps_5min');

    // The timeline shows the night's means the column serves, not the
    // calendar day's.
    Future<Map<String, num>> timeline() async => {
          for (final o in await timelineObservations(
              await LocalDb.observationsForDay(_dayId)))
            if (o['device_id'] == 'ultrahuman-synthetic' &&
                o['vendor_key'] != null)
              o['vendor_key'] as String: o['value'] as num,
        };
    final shown = await timeline();
    expect(shown['hrv_avg'], night['rmssd']);
    expect(shown['spo2_avg'], night['spo2']);

    // A day with no night block: the ring's day means are dropped, and the
    // rows say no night, not that the ring gave nothing.
    final db = await LocalDb.instance;
    final noNight = {
      ...full,
      'ring_day': {...full['ring_day'] as Map}..remove('device_night'),
    };
    await db.update('day_result', {'payload_json': jsonEncode(noNight)},
        where: 'day_id = ?', whereArgs: [_dayId]);
    try {
      // Beside the window we served, the reason is the ring's night giving
      // no reading, never "staged no night" (the ring stages none).
      Future<void> noReading() async {
        final cells = (await dayCells(_dayId))!;
        expect(cells['sleep_window']!['class'], isNot('unavailable'));
        for (final row in ['hrv', 'spo2']) {
          expect(cells[row]!['class'], 'unavailable', reason: row);
          expect(cells[row]!['reason'], Why.noNightReading.name, reason: row);
        }
      }

      await noReading();
      // A night block whose worn records gave neither value: the same.
      await db.update(
          'day_result',
          {
            'payload_json': jsonEncode({
              ...full,
              'ring_day': {
                ...full['ring_day'] as Map,
                'device_night': {
                  ...night,
                  'rmssd': null,
                  'spo2': null,
                },
              },
            })
          },
          where: 'day_id = ?',
          whereArgs: [_dayId]);
      await noReading();
      await db.update('day_result', {'payload_json': jsonEncode(noNight)},
          where: 'day_id = ?', whereArgs: [_dayId]);
      final gone = await timeline();
      expect(gone.keys, isNot(contains('hrv_avg')));
      expect(gone.keys, isNot(contains('spo2_avg')));
      // Not derived yet (right after a sync): no stored night, so neither
      // the cells nor the timeline serve the calendar day's means.
      await db.delete('day_result', where: 'day_id = ?', whereArgs: [_dayId]);
      final fresh = (await dayCells(_dayId))!;
      for (final row in ['hrv', 'spo2']) {
        expect(fresh[row]!['class'], 'unavailable', reason: row);
        expect(fresh[row]!['reason'], Why.noNight.name, reason: row);
      }
      expect((await timeline()).keys, isNot(contains('hrv_avg')));
    } finally {
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a band's re-derive over a ring-derived day with no method stamp "
      "leaves no 'estimated' class behind to hide its values", () async {
    const day = '2026-09-20';
    Future<void> put(double strain, SeriesMethod Function(String)? m) =>
        LocalDb.putDayResult(
            dayId: day,
            algoVersion: kAlgoVersion,
            payloadJson: '{}',
            windowJson: '{}',
            seriesMethod: m,
            series: {'strain': strain});
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    Future<List> points() async => [
          for (final p in (await repo.getChart('strain'))['points'] as List)
            if ((p as Map)['v'] == 12.0) p,
        ];
    final db = await LocalDb.instance;
    try {
      await put(9, seriesMethodFor(kUltrahumanFamily));
      expect(await LocalDb.metricNotOursDates('strain'), contains(day));
      // A window spanning two straps: no family, so no method.
      await put(12, null);
      expect(await LocalDb.metricNotOursDates('strain'), isNot(contains(day)));
      expect(await points(), hasLength(1));
    } finally {
      for (final t in ['day_result', 'metric_series', 'metric_method',
          'metric_series_version']) {
        await db.delete(t,
            where: '${t == 'day_result' ? 'day_id' : 'date'} = ?',
            whereArgs: [day]);
      }
    }
  });

  test("an estimated TRIMP older than 42 days but inside the load's input "
      'still labels the load and the strain target on Today', () async {
    final db = await LocalDb.instance;
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final now = DateTime.now();
    String ago(int d) => dayLabelOf(DateTime(now.year, now.month, now.day - d));
    final saved = await db.query('metric_method', where: "key = 'trimp'");
    final savedBase = {
      for (final k in ['crossday', 'crossday_input'])
        k: (await LocalDb.baseline(k))?['payload_json'] as String?,
    };
    Future<void> estimatedOn(String day) async {
      await db.delete('metric_method', where: "key = 'trimp'");
      await db.insert('metric_method', {
        'date': day,
        'key': 'trimp',
        'method': 'ring',
        'family': kUltrahumanFamily,
        'class': 'estimated',
      });
    }

    Future<Object?> target() async =>
        ((await repo.getToday())['coach'] as Map?)?['strain_target'];
    final today = LocalDb.localDayLabelNow();
    try {
      // A day on Today to carry the coach block.
      await LocalDb.putDayResult(
          dayId: today,
          algoVersion: kAlgoVersion,
          payloadJson: jsonEncode({
            'scalars': {'steps': 300},
          }),
          windowJson: '{}');
      await LocalDb.refreshComputeFreshness();
      await LocalDb.putBaseline(
          'crossday',
          jsonEncode({
            'algo_version': kAlgoVersion,
            'built_for_day': today,
            'load': {'value': <String, dynamic>{}},
            'strain_coach': {
              'value': {'target_min': 8, 'target_max': 12},
            },
          }));
      await LocalDb.putBaseline(
          'crossday_input',
          jsonEncode({
            'days': [
              {'date': ago(120)},
            ],
          }));
      // 60 days back: past tau, still about a quarter of the fitness weight.
      await estimatedOn(ago(60));
      expect(((await repo.getInsights())['load'] as Map)['estimated'], isTrue);
      expect((await target() as Map)['estimated'], isTrue);
      // 100 days back: older than 90, but the input reaches further back.
      await estimatedOn(ago(100));
      expect((await target() as Map)['estimated'], isTrue);
      // Older than the input's first day: the load never saw it.
      await estimatedOn(ago(200));
      expect((await target() as Map)['estimated'], isNull);
      expect(((await repo.getInsights())['load'] as Map)['estimated'], isNull);
    } finally {
      for (final t in ['day_result', 'metric_series', 'metric_method',
          'metric_series_version']) {
        await db.delete(t,
            where: '${t == 'day_result' ? 'day_id' : 'date'} = ?',
            whereArgs: [today]);
      }
      await LocalDb.refreshComputeFreshness();
      await db.delete('metric_method', where: "key = 'trimp'");
      for (final r in saved) {
        await db.insert('metric_method', r);
      }
      for (final e in savedBase.entries) {
        e.value == null
            ? await db.delete('baselines', where: 'key = ?', whereArgs: [e.key])
            : await LocalDb.putBaseline(e.key, e.value!);
      }
    }
  });
}
