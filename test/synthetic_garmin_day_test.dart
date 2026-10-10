// A Garmin watch as the ACTIVE WEARABLE, no primary band at all: four
// synthetic days (test/support/synthetic_day.dart) synced through the real
// Garmin link, derived by the real engine off the watch's one-a-minute HR
// and its own hypnogram, and served cell by cell as Garmin's column of the
// metric x device table (lib/compute/inputs/garmin_inputs.dart). Each cell
// must come back in its class (ours / device / estimated / unavailable) with
// a value the truth makes plausible.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart' show at;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/strap_day.dart';
import 'support/synthetic_day.dart';

// The three nights before the day under test run 6 bpm lower, so a baseline
// that took the day under test in would sit off the earlier nights'.
final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++)
    SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
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

Map<String, dynamic> _scalars(Map<String, Object?> row) =>
    ((jsonDecode(row['payload_json'] as String) as Map)['scalars'] as Map)
        .cast<String, dynamic>();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_garmin_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: 'garmin-synthetic',
        adapterId: 'garmin',
        remoteId: 'AA:BB:CC:00:00:02',
        label: 'garmin');
    final now = DateTime(2026, 10, 4, 22, 30);
    await GarminLink.instance.ingestForTest('garmin-synthetic',
        GarminWatchScript(SyntheticDay.garminDays(_days)).reply,
        nowSeconds: () => SyntheticDay.sec(now));
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the watch moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, 'garmin-synthetic');
    // Rule R6: not even its own hypnogram stages the night it alone saw.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: every Garmin cell derives, stores and serves in its class',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '1');
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
      'sleep_stages': 'device',
      'naps': 'unavailable',
      'sleep_debt_need_sri': 'ours',
      'resting_hr': 'ours',
      'nadir_dip': 'ours',
      'hrv': 'device',
      'respiratory_rate': 'device',
      'spo2': 'device',
      'stress': 'device',
      'skin_temp': 'unavailable',
      'readiness': 'estimated',
      'irregular_rhythm': 'unavailable',
      'steps': 'device',
      'strain': 'ours',
      'calories': 'ours',
      'movement': 'estimated',
      'auto_workouts': 'ours',
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

    // Ours, at the watch's resolution.
    expect(cells['resting_hr']!['method'], 'hr_1min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(cells['resting_hr']!['device_value'], SyntheticDay.garminRestingHr,
        reason: "the watch's own value rides beside ours");
    expect(v('nadir_dip'), inInclusiveRange(40, v('resting_hr')));
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm');
    expect(v('calories'), inInclusiveRange(200, 1500));
    expect(v('auto_workouts'), 1, reason: 'the run, found off 1-min HR');
    expect(v('sleep_debt_need_sri'), inInclusiveRange(0, 2));
    expect(cells['sleep_debt_need_sri']!['method'], 'device_stages');
    // The baseline is the nights BEFORE the day: theirs, 6 bpm under today's.
    final prior = [
      for (final d in _dayIds.where((d) => d != _dayId))
        _scalars((await LocalDb.dayResult(d))!)['rhr'] as num,
    ]..sort();
    expect(v('baselines_load_illness'), closeTo(prior[1], 1.5));
    expect(v('resting_hr') - v('baselines_load_illness'), greaterThan(3));
    expect(v('circadian'), inInclusiveRange(0, 24));
    // Resting HR is the one readiness input we measure on this watch, so the
    // composite abstains and the partial part is estimated: a resting HR
    // above its baseline reads as less ready.
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(v('readiness'), lessThan(30));

    // Our HR-led window off the watch's one-a-minute HR, the watch's own
    // night beside it.
    final hrNight = (jsonDecode((await LocalDb.dayResult(_dayId))![
        'payload_json'] as String) as Map)['hr_sleep_window'] as Map;
    expect(cells['sleep_window']!['method'], 'hr_1min');
    expect(v('sleep_window'), hrNight['in_bed_min']);
    expect(((hrNight['onset_ts'] as int) - SyntheticDay.sec(_truth.sleepOnset))
        .abs(), lessThanOrEqualTo(25 * 60));
    expect(((hrNight['offset_ts'] as int) -
            SyntheticDay.sec(_truth.sleepOffset)).abs(),
        lessThanOrEqualTo(20 * 60));

    // The watch's own values, labelled as its.
    final night = _truth.sleepOffset.difference(_truth.sleepOnset).inMinutes;
    expect(((cells['sleep_window']!['device_value'] as num) - night).abs(),
        lessThanOrEqualTo(1));
    // The watch's value is the same quantity as ours, its night's in-bed
    // span, so the two differ by no more than the edge bounds above allow.
    expect((v('sleep_window') - (cells['sleep_window']!['device_value'] as num))
        .abs(), lessThanOrEqualTo(25 + 20));
    expect(v('sleep_stages'), _truth.deepMin);
    final stored = jsonDecode((await LocalDb.dayResult(_dayId))![
        'payload_json'] as String) as Map;
    expect((stored['scalars'] as Map)['rem_min'], _truth.remMin);
    expect(v('hrv'), SyntheticDay.garminHrv);
    expect(v('respiratory_rate'), SyntheticDay.garminRespRate);
    expect(v('spo2'), SyntheticDay.garminSpo2);
    expect(v('stress'), SyntheticDay.garminStress);
    expect(v('steps'), _truth.stepsOn(_truth.day));

    // A past day's sleep debt, regularity and rhythm are its own nights',
    // not today's: up to 10-02 there are two nights, under the minimum.
    final past = (await dayCells('2026-10-02'))!;
    expect(past['sleep_debt_need_sri']!['class'], 'unavailable');
    expect(past['circadian']!['class'], 'unavailable');
    final third = await crossDayAsOf('2026-10-03');
    expect(((third['recent'] as List).last as Map)['date'], '2026-10-03');
    expect(at(third, ['sleep_debt', 'value', 'debt_hours']), isNotNull);

    // Estimated only where the watch gives nothing.
    expect(v('movement'), inInclusiveRange(40, 50),
        reason: 'the 40-minute run and its ramps, in zone minutes');
    expect(cells['movement']!['method'], 'hr_1min_zone_minutes');

    // Stored with the watch's family, so baselines never mix with a band's.
    final full = jsonDecode((await LocalDb.dayResult(_dayId))!['payload_json']
        as String) as Map;
    expect(full['device_family'], 'garmin');
    expect(full['sleep_source'], 'vendor_staged');
    // WASO and awakenings off the device's own stages, against the truth
    // night: a 4-min and a 6-min wake inside it, the 6-min one the only
    // sustained awakening, and efficiency the truth's asleep share.
    final acct = ((((full)['sleep'] as Map)['accounting'] as Map)['value'] as Map);
    expect(acct['waso_sec'], 10 * 60);
    expect(acct['awakenings'], 1);
    expect((full['scalars'] as Map)['awakenings'], 1);
    expect(v('efficiency_awakenings'),
        closeTo(100 * _truth.tstMin / night, 0.1));
    // Sleep need and regularity on the device's epochs: four nights on the
    // same clock regularise to 100, and with no debt and no nap the need is
    // the habitual night, the stored one within a quarter hour.
    final xm = await crossDayAsOf(_dayId);
    expect(((xm['regularity'] as Map)['value'] as Map)['sri'], 100);
    expect(((xm['sleep_debt'] as Map)['value'] as Map)['debt_hours'], 0);
    expect(
        ((((xm['sleep_coach'] as Map)['need'] as Map)['value'] as Map)[
                    'need_sec'] as num) /
                60 -
            ((full['scalars'] as Map)['tst_min'] as num),
        inInclusiveRange(-15, 15));

    // Last, since it spoils the stored inputs: inputs another algorithm
    // version wrote are never rebuilt into a past day's rollup.
    final input = jsonDecode((await LocalDb.baseline('crossday_input'))![
        'payload_json'] as String) as Map;
    input['algo_version'] = kAlgoVersion - 1;
    expect(
        await LocalDb.putReviewedBaseline('crossday_input', jsonEncode(input),
            await LocalDb.activityReviewRevision()),
        isTrue);
    expect(await crossDayAsOf('2026-10-03'), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap's session on the watch's day: its workout and heart-rate "
      'recovery are ours, off the strap at 1 Hz', () async {
    const strap = 'hrs-garmin-synthetic';
    await LocalDb.upsertDevice(id: strap, adapterId: 'ble_hrs');
    // 20 minutes at 140 bpm at noon, then 30 bpm a minute of recovery: the
    // drop 60 s after the end is 30. The watch saw none of it at that rate.
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

    // Flag off: the strap is not admitted, so nothing is ours from it.
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
    // The watch's own night and numbers are untouched by the session.
    expect(c['resting_hr']!['class'], 'ours');
    expect(c['resting_hr']!['method'], 'hr_1min');
    await useDevice(strap, 'ble_hrs', false);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap's session on a day the watch was off is still the watch's "
      'day, and only while the strap is on', () async {
    const strap = 'hrs-garmin-offday';
    const offDay = '2026-10-05';
    await LocalDb.upsertDevice(id: strap, adapterId: 'ble_hrs');
    final start = SyntheticDay.sec(DateTime(2026, 10, 5, 12));
    final end = start + 20 * 60;
    int bpm(int t) =>
        t <= end ? 140 : (140 - 30 * (t - end) / 60).round().clamp(95, 140);
    await HrsLink.instance.ingestForTest(strap, [
      for (var t = start; t <= end + kStrapTailSec; t++) (t, [0x00, bpm(t)]),
    ]);
    await LocalDb.putSession({
      'id': 'strap-offday',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'created_at': end,
    });
    final watch = (await activeWearable())!;
    expect(await wearableRecTsMaxByDay(watch), isNot(contains(offDay)),
        reason: 'strap off: the watch saw no row that day');

    await useDevice(strap, 'ble_hrs', true);
    try {
      expect(await wearableRecTsMaxByDay(watch), contains(offDay),
          reason: 'the strap session puts the day in derive scope');
      await DerivationEngine().runDays(_profile, {offDay}, force: true);
      final c = (await dayCells(offDay))!;
      expect(c['workouts_with_strap'],
          allOf(containsPair('class', 'ours'), containsPair('value', 1)));
      expect(c['hrr']!['class'], 'ours');
      expect(c['hrr']!['value'] as num, closeTo(30, 3));
    } finally {
      await useDevice(strap, 'ble_hrs', false);
    }
    expect(await LocalDb.dayResult(offDay), isNull,
        reason: 'strap off: nothing of it stays');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap worn at rest overnight on the watch's day: its HRV is ours "
      "off the beats, the watch's own beside it", () async {
    await checkStrapDay('hrs-garmin-night', _truth, _dayId, _profile,
        deviceHrv: true);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('turning the watch off leaves nothing of it, re-derive included',
      () async {
    expect(await LocalDb.dayResult(_dayId), isNotNull);
    // The app's re-derive of the moved days (AppState.rederiveDays).
    onWearableDaysChanged = (days) async =>
        DerivationEngine().runDays(_profile, days, force: true);
    try {
      await setWearableEnabled('garmin', false);
    } finally {
      onWearableDaysChanged = null;
    }
    for (final d in _dayIds) {
      expect(await LocalDb.dayResult(d), isNull,
          reason: "$d: the watch's own night must not stage it");
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
