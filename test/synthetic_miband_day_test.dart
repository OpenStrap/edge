// A Mi Band 2/3 as the ACTIVE WEARABLE, no primary band at all: four
// synthetic days (test/support/synthetic_day.dart) synced through the real
// Mi Band link (auth handshake, then the activity fetch), derived by the
// real engine off the band's one-a-minute HR and its own per-minute sleep
// kind, and served cell by cell as Mi Band's column of the metric x device
// table (lib/compute/inputs/miband_inputs.dart). Each cell must come back in
// its class (ours / device / estimated / unavailable) with a value the truth
// makes plausible.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/miband_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart' show VendorEpoch;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/strap_day.dart';
import 'support/synthetic_day.dart';

// The three nights before the day under test run 6 bpm lower, so the
// resting-HR-only readiness has a real rise to score on the 4th.
final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++)
    SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
];
final SyntheticDay _truth = _days.last;
const String _band = 'miband-synthetic';
const String _dayId = '2026-10-04';
const Set<String> _dayIds = {
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  _dayId,
};
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

/// Home's wearable card, loaded off the real database for [_dayId].
Future<void> _pumpHomeCard(WidgetTester t) async {
  await t.runAsync(() async {
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: ListView(children: const [
        WearableCells(kHomeWearableRows, date: _dayId),
      ])),
    ));
    await Future<void>.delayed(const Duration(seconds: 2));
  });
  await t.pump();
}

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_miband_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _band,
        adapterId: 'miband234',
        remoteId: 'AA:BB:CC:00:00:04',
        label: 'miband234');
    // Another device's night over the same hours, banked but never switched
    // on (rule R6): it must not stage the band's day. Its id sorts first.
    await LocalDb.upsertDevice(
        id: 'colmi-other',
        adapterId: 'colmi',
        remoteId: 'AA:BB:CC:00:00:05',
        label: 'colmi');
    final foreignOnset = SyntheticDay.sec(DateTime(2026, 10, 3, 22, 50));
    await LocalDb.putVendorSleepEpochs([
      for (var k = 0; k < 16; k++)
        VendorEpoch(foreignOnset + k * 1800, foreignOnset + (k + 1) * 1800,
            k.isEven ? 'light' : 'deep'),
    ], deviceId: 'colmi-other', source: 'colmi');
    final now = DateTime(2026, 10, 4, 22, 30);
    final key = List<int>.generate(16, (i) => i + 1);
    final challenge = List<int>.generate(16, (i) => 0xa0 + i);
    await MiBand234Link.instance.ingestForTest(
      _band,
      key,
      (_, w) => switch (w[0]) {
        0x02 => [
            [0x10, 0x02, 0x01, ...challenge],
          ],
        0x03 => w.sublist(2).toString() ==
                miBand234AuthResponse(key, challenge).toString()
            ? [
                [0x10, 0x03, 0x01],
              ]
            : [
                [0x10, 0x03, 0x04],
              ],
        _ => const <List<int>>[],
      },
      history: SyntheticDay.miBandHistory(_days, now),
      nowSeconds: () => SyntheticDay.sec(now),
      window: const Duration(seconds: 5),
    );
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the band moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, _band);
    // Rule R6: not even its own hypnogram stages the night it alone saw.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  testWidgets('flag off: no wearable card on Home', (t) async {
    await _pumpHomeCard(t);
    expect(find.byType(WearableCell), findsNothing);
  });

  test('flag on: every Mi Band cell derives, stores and serves in its class',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('miband234'), '1');
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
    // It records movement each minute; we just do not turn it into naps.
    expect(cells['naps']!['reason'], 'notDecoded');

    // Ours, at the band's resolution.
    expect(cells['resting_hr']!['method'], 'hr_1min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(cells['resting_hr']!['device_value'], isNull,
        reason: 'the band keeps no resting HR of its own');
    expect(v('nadir_dip'), inInclusiveRange(40, v('resting_hr')));
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm');
    expect(v('calories'), inInclusiveRange(200, 1500));
    expect(v('auto_workouts'), 1, reason: 'the run, found off 1-min HR');
    expect(v('sleep_debt_need_sri'), inInclusiveRange(0, 2));
    expect(v('resting_hr') - v('baselines_load_illness'), inInclusiveRange(3, 9),
        reason: 'the baseline is the three nights before, 6 bpm lower');
    expect(v('circadian'), inInclusiveRange(0, 24));

    // Our HR-led window beside the band's own night (the same quantity, its
    // in-bed span). The band's night runs from its first sleep minute to its
    // last, so it is the truth's onset to wake.
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    final hrNight = full['hr_sleep_window'] as Map;
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

    // The band reports wake inside the night, so efficiency is ours off its
    // epochs and is NOT 100 by construction: the truth's two brief wakes.
    expect(cells['efficiency_awakenings']!['method'], 'device_stages');
    expect(v('efficiency_awakenings'),
        closeTo(100 * _truth.tstMin / night, 0.2));
    final acct = ((full['sleep'] as Map)['accounting'] as Map)['value'] as Map;
    expect(acct['waso_sec'], 10 * 60);
    // The 4-minute wake is under the awakening floor; the 6-minute one counts.
    expect(acct['awakenings'], 1);

    // Device values: deep minutes (its light holds REM) and the day's steps.
    expect(v('sleep_stages'), _truth.deepMin);
    expect(v('steps'), _truth.stepsOn(_truth.day));

    // Estimated only where the band gives nothing.
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(v('readiness'), lessThan(30),
        reason: 'resting HR 6 bpm over the three nights before it');
    expect(cells['movement']!['method'], 'hr_1min_zone_minutes');
    expect(v('movement'), greaterThanOrEqualTo(30),
        reason: 'at least the 40-minute run sits in a zone');

    // Stored with the band's family, so baselines never mix with a WHOOP's.
    expect(full['device_family'], 'miband234');
    expect(full['sleep_source'], 'vendor_staged');
    // The window was the band's own night, not our 1 Hz streams.
    expect(((full['sleep'] as Map)['window'] as Map)['inputs_used'],
        ['vendor_sleep_epoch']);
    // Its light holds REM: no REM figure, not a REM of 0.
    final db = await LocalDb.instance;
    final series = {
      for (final r in await db.query('metric_series',
          where: 'date = ?', whereArgs: [_dayId]))
        r['key'] as String: r['value'],
    };
    expect(series['rem_min'], isNull);
    expect(series['deep_min'], _truth.deepMin);
    // Wake-ups come off the band's epochs, as efficiency does.
    final methods = {
      for (final r in await db.query('metric_method',
          where: 'date = ?', whereArgs: [_dayId]))
        r['key'] as String: r['method'],
    };
    expect(methods['efficiency'], 'device_stages');
    expect(methods['awakenings'], 'device_stages');
    expect((await LocalDb.metricFamilies('rhr'))[_dayId], 'hr_1min');
    final xm = await crossDayAsOf(_dayId);
    expect(((xm['regularity'] as Map)['value'] as Map)['sri'], 100);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("flag on: Home's card draws the band's served cells",
      (t) async {
    await _pumpHomeCard(t);
    expect(find.text('Mi Band 2/3'), findsOneWidget);
    expect(
        [for (final w in t.widgetList<WearableCell>(find.byType(WearableCell)))
          w.row],
        kHomeWearableRows);
    expect(find.text('Estimated'), findsOneWidget, reason: 'readiness');
    expect(find.text('From your Mi Band 2/3 · 1-min heart rate'),
        findsWidgets);
    expect(find.text("Your Mi Band 2/3's own value"), findsOneWidget,
        reason: 'its own steps');
  });

  test("a daytime sleep block's minutes stay out of the night's stages",
      () async {
    final db = await LocalDb.instance;
    final row = await db.insert('observation', {
      'device_id': _band,
      'ts_ms': DateTime(2026, 10, 4, 15).millisecondsSinceEpoch,
      'date': _dayId,
      'source_kind': 'vendor',
      'vendor_key': 'sleep_deep_min',
      'value': 40,
      'unit': 'min',
      'attribution': kMiBandAttribution,
    });
    final cells = (await dayCells(_dayId))!;
    await db.delete('observation', where: 'rowid = ?', whereArgs: [row]);
    expect(cells['sleep_stages']!['value'], _truth.deepMin,
        reason: "the staged night's deep minutes, not the nap's on top");
  });

  test("a strap's session on the band's day: its workout and heart-rate "
      'recovery are ours, off the strap at 1 Hz', () async {
    const strap = 'hrs-miband-synthetic';
    await LocalDb.upsertDevice(id: strap, adapterId: 'ble_hrs');
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
    await useDevice(strap, 'ble_hrs', true);
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    final c = (await dayCells(_dayId))!;
    expect(c['workouts_with_strap'],
        allOf(containsPair('class', 'ours'), containsPair('value', 1),
            containsPair('method', 'hr_1hz')));
    expect(c['hrr']!['method'], 'hr_1hz');
    expect(c['hrr']!['value'] as num, closeTo(30, 3));
    expect(c['resting_hr']!['method'], 'hr_1min');
    await useDevice(strap, 'ble_hrs', false);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap worn at rest overnight on the band's day: its HRV is ours "
      'off the beats', () async {
    await checkStrapDay('hrs-miband-night', _truth, _dayId, _profile,
        deviceHrv: false);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap night's composite readiness is served as ours", () {
    final cells = resolveCells(kMiBandColumn,
        day: {
          'scalars': {'readiness': 74},
          'baselines': {
            'resting_hr': {'z': 0.5},
          },
        },
        crossDay: const {},
        deviceValues: const {},
        method: 'hr_1min',
        family: kMiBandFamily);
    expect(cells['readiness']!['class'], 'ours');
    expect(cells['readiness']!['value'], 74);
    expect(cells['readiness']!['method'], kStrapReadinessMethod);
    expect(seriesMethodFor(kMiBandFamily)!('readiness').method,
        kStrapReadinessMethod);
  });
}
