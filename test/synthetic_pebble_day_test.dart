// A Pebble 2 as the ACTIVE WEARABLE, no primary band at all: four synthetic
// days (test/support/synthetic_day.dart) synced through the real Pebble
// link, derived by the real engine off the watch's one-a-minute HR and its
// own light/deep overlays, and served cell by cell as Pebble's column of the
// metric x device table (lib/compute/inputs/pebble_inputs.dart). Each cell
// must come back in its class (ours / device / estimated / unavailable) with
// a value the truth makes plausible.

import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/pebble_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/pebble_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart' show sourceLine;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

// The three nights before the day under test run 6 bpm lower, so the
// resting-HR-only readiness has a real rise to score on the 4th.
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

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_pebble_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: 'pebble-synthetic',
        adapterId: 'pebble',
        remoteId: 'AA:BB:CC:00:00:03',
        label: 'pebble');
    final now = DateTime(2026, 10, 4, 22, 30);
    await PebbleLink.instance.ingestForTest(
        'pebble-synthetic', SyntheticDay.pebbleDays(_days),
        nowSeconds: () => SyntheticDay.sec(now));
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the watch moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, 'pebble-synthetic');
    // Rule R6: not even its own hypnogram stages the night it alone saw.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: every Pebble cell derives, stores and serves in its class',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('pebble'), '1');
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
      'efficiency_awakenings': 'unavailable',
      'sleep_stages': 'device',
      'naps': 'unavailable',
      'sleep_debt_need_sri': 'ours',
      'resting_hr': 'ours',
      'nadir_dip': 'ours',
      'hrv': 'unavailable',
      'respiratory_rate': 'unavailable',
      'spo2': 'unavailable',
      'stress': 'unavailable',
      'skin_temp': 'unavailable',
      'readiness': 'estimated',
      'irregular_rhythm': 'unavailable',
      'steps': 'device',
      'strain': 'ours',
      'calories': 'ours',
      'movement': 'unavailable',
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
    expect(cells['resting_hr']!['device_value'], isNull,
        reason: 'the watch keeps no resting HR of its own');
    expect(v('nadir_dip'), inInclusiveRange(40, v('resting_hr')));
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm');
    expect(v('calories'), inInclusiveRange(200, 1500));
    expect(v('auto_workouts'), 1, reason: 'the run, found off 1-min HR');
    expect(v('sleep_debt_need_sri'), inInclusiveRange(0, 2));
    // Off the watch's own nights, and quoted with that method's band.
    expect(cells['sleep_debt_need_sri']!['method'], 'device_stages');
    expect(cells['sleep_debt_need_sri']!['band'], 0.1);
    expect(v('resting_hr') - v('baselines_load_illness'), inInclusiveRange(3, 9),
        reason: 'the baseline is the three nights before, 6 bpm lower');
    expect(v('circadian'), inInclusiveRange(0, 24));

    // Our window off the watch's HR opens around sleep onset and closes at
    // the wake: its threshold sits under the waking HR of the day around the
    // night, so the slow synthetic morning (66-68 bpm until about 09:00) is
    // not read as sleep. The watch's own night sits beside it; it reports no
    // wake, so that is the whole sleep period.
    final hrNight = (jsonDecode((await LocalDb.dayResult(_dayId))![
        'payload_json'] as String) as Map)['hr_sleep_window'] as Map;
    expect(cells['sleep_window']!['method'], 'hr_1min');
    expect(v('sleep_window'), hrNight['in_bed_min']);
    expect(((hrNight['onset_ts'] as int) - SyntheticDay.sec(_truth.sleepOnset))
        .abs(), lessThanOrEqualTo(25 * 60));
    expect(((hrNight['offset_ts'] as int) -
            SyntheticDay.sec(_truth.sleepOffset)).abs(),
        lessThanOrEqualTo(20 * 60));
    final night = _truth.sleepOffset.difference(_truth.sleepOnset).inMinutes;
    expect(((cells['sleep_window']!['device_value'] as num) - night).abs(),
        lessThanOrEqualTo(1));
    // The watch's value is the same quantity as ours, its night's in-bed
    // span, so the two differ by no more than the edge bounds above allow.
    expect((v('sleep_window') - (cells['sleep_window']!['device_value'] as num))
        .abs(), lessThanOrEqualTo(25 + 20));
    expect(cells['efficiency_awakenings']!['value'], isNull,
        reason: 'a night with no wake in it would read 100 by construction');
    // Nor is it stored: no screen reading the day's scalars sees a 100.
    final stored = jsonDecode((await LocalDb.dayResult(_dayId))!['payload_json']
        as String) as Map;
    expect((stored['scalars'] as Map)['efficiency'], isNull);
    expect(v('sleep_stages'), _truth.deepMin);
    expect(v('steps'), _truth.stepsOn(_truth.day));

    // Estimated only where the watch gives nothing: readiness off resting HR
    // alone, the full composite having abstained.
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(v('readiness'), lessThan(30),
        reason: 'resting HR 6 bpm over the three nights before it');
    expect(((stored['baselines'] as Map)['resting_hr'] as Map)['z'] as num,
        greaterThan(0));

    // Stored with the watch's family, so baselines never mix with a band's.
    final full = jsonDecode((await LocalDb.dayResult(_dayId))!['payload_json']
        as String) as Map;
    expect(full['device_family'], 'pebble');
    expect(full['sleep_source'], 'vendor_staged');
    // No wake reported: no WASO and no awakenings either, not 0.
    final acct = ((((full)['sleep'] as Map)['accounting'] as Map)['value'] as Map);
    expect(acct['waso_sec'], isNull);
    expect(acct['awakenings'], isNull);
    expect((full['scalars'] as Map)['awakenings'], isNull);
    // No REM reported either: none stored, rather than a REM of 0 served as
    // the watch's.
    expect((full['scalars'] as Map)['rem_min'], isNull);
    final db = await LocalDb.instance;
    expect(await db.query('metric_series', where: "key = 'rem_min' AND value IS NOT NULL"), isEmpty);
    // The night's window is the watch's own on these days, and is stored as
    // its value, not as ours.
    final tags = {
      for (final r in await db
          .query('metric_method', where: 'date = ?', whereArgs: [_dayId]))
        r['key'] as String: r['class'],
    };
    expect(tags['tst_min'], 'device');
    expect(tags['midsleep_sec'], 'device');
    expect(tags['rhr'], 'ours');
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
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a night the watch split in two serves both halves\' minutes',
      () async {
    // A second sleep period ending the same date, its own row beside the
    // first (keyed on its wake time): the served stage minutes are the sum.
    final at = DateTime(2026, 10, 4, 13);
    await LocalDb.putObservations([
      Observation(
          at: at,
          sourceKind: ObservationSource.vendor,
          vendorKey: 'sleep_deep_min',
          value: 20,
          unit: 'min',
          attribution: 'Pebble'),
    ], deviceId: 'pebble-synthetic');
    final cells = (await dayCells(_dayId))!;
    expect(cells['sleep_stages']!['value'], _truth.deepMin + 20);
  });

  test('a strap night\'s composite readiness is served as ours', () {
    final cells = resolveCells(kPebbleColumn,
        day: {
          'scalars': {'readiness': 74},
          'baselines': {
            'resting_hr': {'z': 0.5},
          },
        },
        crossDay: const {},
        deviceValues: const {},
        method: 'hr_1min',
        family: kPebbleFamily);
    expect(cells['readiness']!['class'], 'ours');
    expect(cells['readiness']!['value'], 74);
    expect(seriesMethodFor(kPebbleFamily)!('readiness').cls, 'ours');
    // Made of the watch's resting HR and the strap's beats, not of 1-min HR.
    expect(cells['readiness']!['method'], kStrapReadinessMethod);
    expect(seriesMethodFor(kPebbleFamily)!('readiness').method,
        kStrapReadinessMethod);
    expect(
        sourceLine(lookupAppLocalizations(const Locale('en')), MetricClass.ours,
            kStrapReadinessMethod, 'Pebble'),
        "From your Pebble · resting heart rate and a strap's beat-to-beat "
        'intervals');
  });

  test('a watch with no HR sensor (2 SE) still serves its own night, steps '
      'and stages', () async {
    await LocalDb.upsertDevice(
        id: 'pebble-se',
        adapterId: 'pebble',
        remoteId: 'AA:BB:CC:00:00:04',
        label: 'pebble');
    final wake = DateTime(2026, 10, 6, 7);
    Observation o(String name, num v, {bool ours = false}) => Observation(
        at: ours ? DateTime(2026, 10, 6) : wake,
        sourceKind: ObservationSource.vendor,
        key: ours ? name : null,
        vendorKey: ours ? null : name,
        value: v,
        unit: 'min',
        attribution: 'Pebble');
    await LocalDb.putObservations([
      o('sleep_in_bed_min', 450),
      o('sleep_deep_min', 80),
      o('sleep_light_min', 370),
      o('steps', 5000, ours: true),
    ], deviceId: 'pebble-se');
    await LocalDb.setCursor(kActiveWearableCursor, 'pebble-se');
    final cells = (await dayCells('2026-10-06'))!;
    expect(cells['sleep_window']!['class'], 'device');
    expect(cells['sleep_window']!['value'], 450);
    expect(cells['sleep_stages']!['value'], 80);
    expect(cells['steps']!['value'], 5000);
    expect(cells['resting_hr']!['class'], 'unavailable');
    // No HR sensor, so no derived day ever: nothing from the other
    // watch's days, and the reason says so, not "needs three nights",
    // which would never clear.
    expect(cells['sleep_debt_need_sri']!['class'], 'unavailable');
    expect(cells['sleep_debt_need_sri']!['reason'], Why.noNightHr.name);
    expect(cells['circadian']!['reason'], Why.noWakeHr.name);
    await LocalDb.setCursor(kActiveWearableCursor, 'pebble-synthetic');
  });

  test("two walks are two timeline rows, never one 'own score'", () async {
    Observation walk(int hour, int min) => Observation(
        at: DateTime(2026, 10, 7, hour),
        sourceKind: ObservationSource.vendor,
        vendorKey: 'walk_min',
        value: min,
        unit: 'min',
        attribution: 'Pebble');
    await LocalDb.putObservations([walk(9, 25), walk(18, 40)],
        deviceId: 'pebble-synthetic');
    expect(await deviceOwnScores('pebble-synthetic', '2026-10-07'), isEmpty);
    final rows = await timelineObservations(
        await LocalDb.observationsForDay('2026-10-07'));
    expect([for (final r in rows) if (r['vendor_key'] == 'walk_min') r['value']],
        unorderedEquals([25, 40]));
  });

  test('the resting-HR-only readiness falls as resting HR rises', () {
    Map day(num z) => {
          'baselines': {
            'resting_hr': {'z': z},
          },
        };
    expect(rhrOnlyReadiness(day(0)), 50);
    expect(rhrOnlyReadiness(day(1))!, lessThan(50));
    expect(rhrOnlyReadiness(day(-1))!, greaterThan(50));
    expect(rhrOnlyReadiness(day(2))!, lessThan(rhrOnlyReadiness(day(1))!));
    expect(rhrOnlyReadiness(const {}), isNull);
  });
}
