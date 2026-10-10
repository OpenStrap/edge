// A Colmi ring as the ACTIVE WEARABLE, no primary band at all: four synthetic
// days (test/support/synthetic_day.dart) synced through the real Colmi link,
// derived by the real engine off the ring's 5-minute HR, its temperature
// slots and its own hypnogram, and served cell by cell as Colmi's column of
// the metric x device table (lib/compute/inputs/colmi_inputs.dart). Each cell
// must come back in its class (ours / device / estimated / unavailable) with
// a value the truth makes plausible.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/colmi_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show colmiBigDataRequest, kColmiBigTemperature;
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
    LocalDb.dbName = 'synthetic_colmi_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: 'colmi-synthetic',
        adapterId: 'colmi',
        remoteId: 'AA:BB:CC:00:00:05',
        label: 'colmi');
    final now = DateTime(2026, 10, 4, 22, 30);
    await ColmiLink.instance.ingestForTest('colmi-synthetic',
        (_, w) => SyntheticDay.colmiRingReply(_days, w, now),
        nowSeconds: () => SyntheticDay.sec(now));
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the ring moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, 'colmi-synthetic');
    // Rule R6: not even its own hypnogram stages the night it alone saw.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: every Colmi cell derives, stores and serves in its class',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
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
      'respiratory_rate': 'unavailable',
      'spo2': 'device',
      'stress': 'device',
      'skin_temp': 'ours',
      'readiness': 'estimated',
      'irregular_rhythm': 'unavailable',
      'steps': 'device',
      'strain': 'estimated',
      'calories': 'device',
      'movement': 'unavailable',
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
    expect(v('sleep_debt_need_sri'), inInclusiveRange(0, 2));
    // Off the ring's staged nights, as on every device that stages its own.
    expect(cells['sleep_debt_need_sri']!['method'], 'device_stages');
    expect(v('circadian'), inInclusiveRange(0, 24));

    // The night is the ring's own hypnogram; our HR-led window sits beside
    // it, and efficiency is ours off the ring's stages (it reports wake).
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    expect(full['sleep_source'], 'vendor_staged');
    expect(full['device_family'], 'colmi');
    final night = _truth.sleepOffset.difference(_truth.sleepOnset).inMinutes;
    final hrNight = full['hr_sleep_window'] as Map;
    expect(cells['sleep_window']!['method'], 'hr_5min');
    expect(v('sleep_window'), hrNight['in_bed_min']);
    expect(((hrNight['onset_ts'] as int) - SyntheticDay.sec(_truth.sleepOnset))
        .abs(), lessThanOrEqualTo(25 * 60));
    // It closes at the wake, not hours into a slow morning.
    expect(((hrNight['offset_ts'] as int) -
            SyntheticDay.sec(_truth.sleepOffset)).abs(),
        lessThanOrEqualTo(20 * 60));
    expect(((cells['sleep_window']!['device_value'] as num) - night).abs(),
        lessThanOrEqualTo(5), reason: 'onset to wake, at 5-minute slots');
    // The ring's value is the same quantity as ours, its night's in-bed
    // span, so the two differ by no more than the edge bounds above allow.
    expect((v('sleep_window') - (cells['sleep_window']!['device_value'] as num))
        .abs(), lessThanOrEqualTo(25 + 20));
    expect(cells['efficiency_awakenings']!['method'], 'device_stages');
    expect((v('sleep_stages') - _truth.deepMin).abs(), lessThanOrEqualTo(2));

    // Skin temperature: ours is the deviation off the ring's own nights in
    // °C, the ring's daily mean beside it.
    expect(cells['skin_temp']!['method'], 'skin_temp_c_slot');
    expect(v('skin_temp'), closeTo(0, 0.25),
        reason: 'the 4th night sits on the mean of the nights before it');
    expect(cells['skin_temp']!['device_value'] as num,
        inInclusiveRange(33.5, 35.5));

    // Estimated only where the ring gives nothing: it gives calories, so
    // those are its own (PLAN §3b: never C when V exists).
    expect(cells['strain']!['method'], 'hr_5min');
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm');
    expect(cells['calories']!['method'], 'device');
    expect(cells['calories']!.containsKey('band'), isFalse);
    expect((v('calories') - _truth.stepsOn(_truth.day) / 20).abs(),
        lessThanOrEqualTo(96), reason: 'one per 20 steps, per quarter hour');
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(v('readiness'), closeTo(50, 15),
        reason: 'four nights of the same physiology: no deviation to score');

    // The ring's own values, labelled.
    // The ring's HRV over its own night (45 asleep), not the calendar day's
    // mean with the waking 30s in it.
    expect(v('hrv'), 45);
    expect(v('stress'), inInclusiveRange(15, 35));
    expect(v('spo2'), inInclusiveRange(96, 98));
    expect(v('steps'), _truth.stepsOn(_truth.day));
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
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with 14 nights behind it, readiness is ours: the partial composite '
      'over resting HR and skin temperature', () async {
    final db = await LocalDb.instance;
    for (var i = 1; i <= 14; i++) {
      final date = DateTime(2026, 10, 1 - i).toIso8601String().substring(0, 10);
      final w = (i % 5) - 2;
      await LocalDb.putMetricSeriesValue(date, 'rhr', 48.0 + w);
      await LocalDb.putMetricSeriesValue(date, 'skin_temp_adc', 3530.0 + 5 * w);
      await db.insert(
          'metric_series_version',
          {'date': date, 'algo_version': kAlgoVersion, 'device_family': 'colmi'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
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
    expect(env['inputs_used'], ['RHR', 'temp']);
    expect(env['provisional'], isTrue);
    expect(env['confidence'], 0.3);
    expect(cells['readiness']!['provisional'], isTrue);
    expect(cells['skin_temp']!['provisional'], isTrue);
    expect(((full['wellness'] as Map)['skin_temp'] as Map)['provisional'],
        isTrue);
    expect(cells['hrv']!['class'], 'device');
    expect(cells['stress']!['class'], 'device');
    expect(cells['spo2']!['class'], 'device');
    // The trend charts draw neither the provisional readiness nor the
    // estimated strain as a measured point.
    expect(await LocalDb.metricNotOursDates('readiness'), contains(_dayId));
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getChart('strain'))['points'], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('each HR row takes the skin temperature of the slot it falls in',
      () async {
    final from = SyntheticDay.sec(DateTime(2026, 10, 4, 1));
    final sub = await colmiSubstrate('colmi-synthetic', from, from + 3599);
    expect(sub.tsSec.length, 12, reason: 'one HR every 5 minutes');
    expect(sub.skinTemp.toSet(), {3530},
        reason: 'asleep, 35.2 + 0.1 °C for the 4th');
    // Every reply carries the session's clock, the day its "days ago"
    // counts from.
    final db = await LocalDb.instance;
    final stamps = await db.rawQuery(
        "SELECT DISTINCT rec_ts FROM raw_archive WHERE reason LIKE 'colmi_big_%' "
        "AND device_id = 'colmi-synthetic'");
    expect(stamps.map((r) => r['rec_ts']),
        [SyntheticDay.sec(DateTime(2026, 10, 4, 22, 30))]);
  });

  test('a sync running past midnight keeps each reply on the day the ring '
      'meant', () async {
    // Asked at 23:59:50, banked 30 s later on the next date: "today" in the
    // reply is the 5th, the day the session's clock counted from.
    final reply = colmiBigDataRequest(
        kColmiBigTemperature, [0, 30, for (var k = 0; k < 48; k++) 150]);
    final db = await LocalDb.instance;
    await db.insert('raw_archive', {
      'device_id': 'colmi-midnight',
      'hex': [for (final b in reply) b.toRadixString(16).padLeft(2, '0')]
          .join(),
      'packet_type': reply[0],
      'rec_ts': SyntheticDay.sec(DateTime(2026, 10, 5, 23, 59, 50)),
      'captured_at': SyntheticDay.sec(DateTime(2026, 10, 6, 0, 0, 20)) * 1000,
      'reason': 'colmi_big_0x${kColmiBigTemperature.toRadixString(16)}',
    });
    final day5 = SyntheticDay.sec(DateTime(2026, 10, 5));
    final day6 = SyntheticDay.sec(DateTime(2026, 10, 6));
    final on5 = await colmiSkinTemps('colmi-midnight', day5, day6 - 1);
    expect(on5.length, 48);
    expect(on5.first, (day5, day5 + 1800, 3500));
    expect(await colmiSkinTemps('colmi-midnight', day6, day6 + 86399),
        isEmpty);
  });

  test("a strap's session and its night at rest on the ring's day: the "
      "session is ours at 1 Hz, the night's HRV ours off the beats with the "
      "ring's own beside it", () async {
    await checkStrapDay('hrs-colmi-night', _truth, _dayId, _profile,
        deviceHrv: true, session: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
