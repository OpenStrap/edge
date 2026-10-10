// The multi-device platform under the device columns
// (lib/compute/inputs/canonical.dart): device categories, the active
// wearable and its migration, the per-wearable flag and the re-derive it
// triggers, sparse-HR coverage and ownership, a strap's per-beat timing, the
// workout-sensor session override, and the per-(date, key) method that keeps
// baselines per method family. A Garmin watch is the wearable throughout; no
// primary band rows exist except the history seeded for the baseline check.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart' show InputSignal;
import 'package:openstrap_edge/ble/adapters/host.dart' show beatEndTimesMs;
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const Set<String> _dayIds = {
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  '2026-10-04',
};
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
const String _watch = 'garmin-synthetic';
const String _strap = 'hrs-0a1b2c3d';

/// 120 bpm with two beats (488 ms, 500 ms): a standard 0x2A37 notification.
const List<int> _hrWithTwoRr = <int>[0x16, 120, 0xF4, 0x01, 0x00, 0x02];

void main() {
  test('every registry entry carries its category', () {
    expect({for (final e in kBandRegistry) e.id: e.category}, {
      'gen4': DeviceCategory.wearable,
      'gen5': DeviceCategory.wearable,
      'ble_hrs': DeviceCategory.workoutSensor,
      'oura': DeviceCategory.wearable,
      'polar_pmd': DeviceCategory.workoutSensor,
      'coros': DeviceCategory.workoutSensor,
      'ultrahuman': DeviceCategory.wearable,
      'miband234': DeviceCategory.wearable,
      'pebble': DeviceCategory.wearable,
      'colmi': DeviceCategory.wearable,
      'garmin': DeviceCategory.wearable,
      'thermometer': DeviceCategory.healthMeasurement,
      'miscale_bc': DeviceCategory.healthMeasurement,
      'miscale2': DeviceCategory.healthMeasurement,
    });
    expect(categoryOf('nothing-we-speak'), isNull);
  });

  test("a strap's beats chain off one another, re-anchored on a gap", () {
    // First notification: no chain yet, so the last beat lands mid-second.
    final a = beatEndTimesMs([488, 500], 100, null);
    expect(a, [99988 + 12, 100500]);
    // The next one continues the chain exactly.
    expect(beatEndTimesMs([510], 101, a.last), [101010]);
    // A gap (a dropped notification) no longer fits: re-anchored.
    expect(beatEndTimesMs([510], 109, a.last), [109500]);
  });

  test('method family and class per stored key', () {
    expect(seriesMethodFor('gen4')!('rhr'),
        (method: 'hr_1hz', family: 'hr_1hz', cls: 'ours'));
    final g = seriesMethodFor('garmin')!;
    expect(g('rhr'), (method: 'hr_1min', family: 'hr_1min', cls: 'ours'));
    expect(g('deep_min'), (method: 'device', family: 'device', cls: 'device'));
    expect(g('dyn_p90'), (method: 'hr_1min', family: 'hr_1min', cls: 'ours'));
    expect(seriesMethodFor('ultrahuman')!('strain').cls, 'estimated');
    expect(seriesMethodFor('miband234')!('rhr').method, 'hr_1min');
    // Efficiency and wake-ups are off the device's stages only on a night it
    // staged; on our HR-led night they are ours off its HR.
    for (final k in ['efficiency', 'awakenings']) {
      expect(seriesMethodFor('miband234', vendorNight: true)!(k).method,
          'device_stages', reason: k);
      expect(seriesMethodFor('miband234')!(k).method, 'hr_1min', reason: k);
    }
    expect(seriesMethodFor('ble_hrs'), isNull,
        reason: 'no validated method yet: abstain');
  });

  group('with a synced Garmin and a strap', () {
    final moved = <Set<String>>[];

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'wearable_platform_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
          id: _watch,
          adapterId: 'garmin',
          remoteId: 'AA:BB:CC:00:00:02',
          label: 'garmin');
      final now = DateTime(2026, 10, 4, 22, 30);
      await GarminLink.instance.ingestForTest(
          _watch, GarminWatchScript(SyntheticDay.garminDays(_days)).reply,
          nowSeconds: () => SyntheticDay.sec(now));
      // Fourteen prior days a WHOOP band measured, resting HR far above the
      // watch's: a baseline that mixed the two would sit near 75.
      final db = await LocalDb.instance;
      for (var d = 17; d <= 30; d++) {
        final date = '2026-09-$d';
        await db.insert('metric_series', {'date': date, 'key': 'rhr', 'value': 75.0});
        await db.insert('metric_series_version',
            {'date': date, 'algo_version': 109, 'device_family': 'gen4'});
      }
      onWearableDaysChanged = (days) async => moved.add(days);
    });

    tearDownAll(() async {
      onWearableDaysChanged = null;
      LocalDb.sessionSensorSources = const {};
      await LocalDb.close();
    });

    test('a sparse watch covers hrSparse, merged, never hr1Hz', () async {
      final db = await LocalDb.instance;
      final rows = await db.query('device_coverage',
          where: 'device_id = ?', whereArgs: [_watch]);
      expect({for (final r in rows) r['signal']}, {'hrSparse'});
      expect(rows.length, lessThan(40),
          reason: 'spans tolerate two of its own gaps, not one row a minute');
    });

    test('migration: the most recently synced wearable becomes active',
        () async {
      // A strap seen later is a workout sensor, never the wearable.
      await LocalDb.upsertDevice(id: _strap, adapterId: 'ble_hrs');
      expect(await LocalDb.getCursor(kActiveWearableCursor), isNull);
      expect(await activeWearableId(), _watch);
      expect(await LocalDb.getCursor(kActiveWearableCursor), _watch,
          reason: 'written back, so the choice then stays put');
      // Flag off (rule R6): chosen, but nothing derives from it.
      expect(await activeWearable(), isNull);
    });

    test('turning the flag on re-derives the watch days; off does too',
        () async {
      // Every day the watch has rows for (the first night starts the
      // evening before the first day), and only those.
      final days = await useDevice(_watch, 'garmin', true);
      expect(days, containsAll(_dayIds));
      expect(days.every((d) => d.compareTo('2026-09-30') >= 0), isTrue);
      expect(moved.last, days);
      expect(await activeWearable(), (_watch, 'garmin'));
      expect(await setWearableEnabled('garmin', false), days);
      expect(await activeWearable(), isNull);
      // Choosing no wearable sticks: the migration does not pick it again.
      await setActiveWearable(null);
      expect(await activeWearableId(), isNull);
      await useDevice(_watch, 'garmin', true);
      expect(await activeWearableId(), _watch);
    });

    test('hrSparse is owned by the active wearable, and unranked it stays '
        'out of the priority hash', () async {
      for (var i = 0; i < 2; i++) {
        expect(await DerivationEngine().runDays(_profile, _dayIds, force: true),
            4);
      }
      final db = await LocalDb.instance;
      final v = await db.query('metric_series_version',
          where: 'date = ?', whereArgs: ['2026-10-04']);
      expect(v.single['priority_hash'], isNot(contains('hrSparse')));
    });

    test('a flag-off watch with hrSparse coverage owns none of a ranked day',
        () async {
      // Pebble paired, flag off, covering the evening after the Garmin
      // stopped; the user ranked only the Garmin.
      const pebble = 'pebble-flag-off';
      await useDevice(_watch, 'garmin', true);
      await LocalDb.upsertDevice(id: pebble, adapterId: 'pebble');
      final db = await LocalDb.instance;
      await db.insert('device_coverage', {
        'device_id': pebble,
        'signal': InputSignal.hrSparse.name,
        'start_ts': SyntheticDay.sec(DateTime(2026, 10, 4, 22, 40)),
        'end_ts': SyntheticDay.sec(DateTime(2026, 10, 4, 23, 50)),
      });
      await LocalDb.setSignalPriority(InputSignal.hrSparse, [_watch]);
      try {
        expect(await DerivationEngine()
            .runDays(_profile, {'2026-10-04'}, force: true), 1);
        final payload = (await LocalDb.dayResult('2026-10-04'))![
            'payload_json'] as String;
        expect(payload, isNot(contains(pebble)),
            reason: 'rule R6: a flag-off device contributes nothing');
      } finally {
        await LocalDb.setSignalPriority(InputSignal.hrSparse, const []);
        await db.delete('device_coverage',
            where: 'device_id = ?', whereArgs: [pebble]);
        await LocalDb.deleteDevice(pebble);
      }
    });

    test('a Coros flag left on reads off and ranks the watch nowhere',
        () async {
      // The toggle is gone, so a flag switched on before could not be
      // switched off; the watch feeds no number either way.
      const coros = 'coros-flag-left-on';
      await LocalDb.upsertDevice(id: coros, adapterId: 'coros');
      await LocalDb.setCursor(wearableEnabledCursor('coros'), '1');
      try {
        expect(await wearableEnabled('coros'), isFalse);
        expect(await flagOnOrPrimary([coros, _watch]), [_watch]);
      } finally {
        await LocalDb.setCursor(wearableEnabledCursor('coros'), '0');
        await LocalDb.deleteDevice(coros);
      }
    });

    test('per-(date, key) method is stored and baselines stay per family',
        () async {
      final db = await LocalDb.instance;
      final m = {
        for (final r in await db.query('metric_method',
            where: 'date = ?', whereArgs: ['2026-10-04']))
          r['key']: (r['method'], r['family'], r['class']),
      };
      expect(m['rhr'], ('hr_1min', 'hr_1min', 'ours'));
      expect(m['deep_min'], ('device', 'device', 'device'));
      expect(await LocalDb.metricFamilies('rhr'), {
        for (final d in _dayIds) d: 'hr_1min',
      });
      final day = jsonDecode((await LocalDb.dayResult('2026-10-04'))![
          'payload_json'] as String) as Map;
      final rhr = (day['scalars'] as Map)['rhr'] as num;
      final base =
          ((day['baselines'] as Map)['resting_hr'] as Map)['baseline'] as num;
      expect(base, closeTo(rhr, 5),
          reason: "the band's 75 bpm days are another method family");
      // Every envelope says how it was made.
      final clinical = day['clinical'] as Map;
      expect(clinical['resting_hr'], containsPair('method', 'hr_1min'));
      expect(clinical['resting_hr'], containsPair('family', 'hr_1min'));
      expect(clinical['resting_hr'], containsPair('class', 'ours'));
      for (final e in clinical.values.whereType<Map>()) {
        expect(e['class'], e['value'] == '—' ? 'unavailable' : isNotNull);
      }
    });

    test("a band day of no single family baselines against the band's days "
        "only, never the watch's", () async {
      Future<Set<double>> base(String? family) async =>
          (await debugSweepBaselineWindows('rhr', ['2026-10-05'],
                  deviceFamily: family))
              .single
              .toSet();
      expect(await base(null), {75.0},
          reason: 'a strap-swap or unstamped band day is a band day');
      expect(await base('gen5'), {75.0});
      expect(await base('garmin'), isNot(contains(75.0)));
    });

    test('a flagged-on strap takes its session window, and only then',
        () async {
      const t0 = 1_800_000_000;
      await HrsLink.instance.ingestForTest(_strap, const [
        (t0, _hrWithTwoRr),
        (t0 + 1, _hrWithTwoRr),
      ]);
      expect(await LocalDb.hrSamplesInRange(t0, t0 + 1), isEmpty,
          reason: 'flag off: the strap is not admitted');
      await useDevice(_strap, 'ble_hrs', true);
      expect(LocalDb.sessionSensorSources, {'ble_hrs'});
      expect([for (final r in await LocalDb.hrSamplesInRange(t0, t0 + 1)) r['hr']],
          [120, 120]);
      await useDevice(_strap, 'ble_hrs', false);
      expect(LocalDb.sessionSensorSources, isEmpty);
      expect(await LocalDb.hrSamplesInRange(t0, t0 + 1), isEmpty,
          reason: 'no sensor on: the band-only read');
    });

    test('turning the watch off clears the days only it decided', () async {
      for (final d in _dayIds) {
        expect(await LocalDb.dayResult(d), isNotNull);
      }
      await setWearableEnabled('garmin', false);
      final db = await LocalDb.instance;
      for (final d in _dayIds) {
        expect(await LocalDb.dayResult(d), isNull, reason: d);
        for (final t in const ['metric_series', 'metric_method']) {
          expect(await db.query(t, where: 'date = ?', whereArgs: [d]),
              isEmpty, reason: '$t $d');
        }
      }
      // The band's own history is untouched.
      expect(await db.query('metric_series',
          where: 'date = ?', whereArgs: ['2026-09-20']), isNotEmpty);
    });

    test('forgetting the active wearable hands over to the next one',
        () async {
      await LocalDb.upsertDevice(
          id: 'garmin-gone', adapterId: 'garmin', label: 'garmin');
      await LocalDb.setCursor(kActiveWearableCursor, 'garmin-gone');
      await LocalDb.deleteDevice('garmin-gone');
      expect(await activeWearableId(), _watch);
    });
  });

  group('a WHOOP band and a Garmin watch on the same days', () {
    // The band records 10-03 18:00 to 10-04 22:00; the watch every day.
    final band = SyntheticDay(DateTime(2026, 10, 4));
    const bandDays = {'2026-10-03', '2026-10-04'};

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'wearable_platform_mixed_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      for (final (raws, samples) in band.primaryBatches()) {
        await LocalDb.commitSyncBatch(raws, samples);
      }
      await LocalDb.upsertDevice(
          id: _watch,
          adapterId: 'garmin',
          remoteId: 'AA:BB:CC:00:00:02',
          label: 'garmin');
      await GarminLink.instance.ingestForTest(
          _watch, GarminWatchScript(SyntheticDay.garminDays(_days)).reply,
          nowSeconds: () => SyntheticDay.sec(DateTime(2026, 10, 4, 22, 30)));
    });

    tearDownAll(() async {
      onWearableDaysChanged = null;
      await LocalDb.close();
    });

    Future<Map<String, Object?>> bandPayloads() async {
      await DerivationEngine().runDays(_profile, bandDays, force: true);
      final db = await LocalDb.instance;
      return {
        for (final d in bandDays) ...{
          d: (await LocalDb.dayResult(d))!['payload_json'],
          '$d series': (await db.query('metric_series',
                  where: 'date = ?', whereArgs: [d], orderBy: 'key'))
              .toString(),
          '$d version': (await db.query('metric_series_version',
                  columns: ['device_family', 'coverage_devices', 'priority_hash'],
                  where: 'date = ?', whereArgs: [d]))
              .toString(),
        },
      };
    }

    test("the watch's flag leaves the band's nights exactly as they were",
        () async {
      // A day converges over passes (tonight's sleep, trailing history), so
      // the comparison starts from a settled pass with the flag off.
      await bandPayloads();
      await bandPayloads();
      final off = await bandPayloads();
      expect(off.length, 6);
      expect(await bandPayloads(), off, reason: 'settled');
      await useDevice(_watch, 'garmin', true);
      expect(await activeWearable(), (_watch, 'garmin'));
      final on = await bandPayloads();
      // 10-04's night is the band's: nothing of the watch's moves it.
      Map<String, Object?> night4(Map<String, Object?> p) => {
            for (final k in p.keys)
              if (k.startsWith('2026-10-04')) k: p[k],
          };
      expect(night4(on), night4(off));
      // 10-03's night the band never saw: the watch's own night stages it
      // with its flag on, and nothing does with it off (rule R6).
      String? source(Map<String, Object?> p) =>
          (jsonDecode(p['2026-10-03']! as String) as Map)['sleep_source']
              as String?;
      expect(source(off), isNot('vendor_staged'));
      expect(source(on), 'vendor_staged');
      final day = jsonDecode(on['2026-10-04']! as String) as Map;
      expect((day['series'] as Map).containsKey('coverage'), isFalse);
      expect(day['device_family'], isNot('garmin'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test("a flagged-on strap never takes a session window off the band's "
        'rows, so the workout and the day read the same seconds', () async {
      final t0 = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
      final band = [
        for (final r in await LocalDb.hrSamplesInRange(t0, t0 + 1)) r['hr'],
      ];
      expect(band, hasLength(2), reason: 'the band was worn then');
      await LocalDb.upsertDevice(id: _strap, adapterId: 'ble_hrs');
      await HrsLink.instance.ingestForTest(_strap, [
        (t0, _hrWithTwoRr),
        (t0 + 1, _hrWithTwoRr),
      ]);
      await useDevice(_strap, 'ble_hrs', true);
      try {
        expect([
          for (final r in await LocalDb.hrSamplesInRange(t0, t0 + 1)) r['hr'],
        ], band);
      } finally {
        await useDevice(_strap, 'ble_hrs', false);
      }
    });

    test('turning the watch off through the app\'s re-derive leaves nothing '
        "of it: its own days stay empty, the band's lose its night", () async {
      onWearableDaysChanged = (days) =>
          DerivationEngine().runDays(_profile, days, force: true);
      Future<String?> sleepSource(String day) async =>
          (jsonDecode((await LocalDb.dayResult(day))!['payload_json'] as String)
              as Map)['sleep_source'] as String?;
      await setWearableEnabled('garmin', false);
      await useDevice(_watch, 'garmin', true);
      for (final d in _dayIds) {
        expect(await LocalDb.dayResult(d), isNotNull, reason: d);
      }
      expect(await sleepSource('2026-10-03'), 'vendor_staged');
      await setWearableEnabled('garmin', false);
      for (final d in const ['2026-10-01', '2026-10-02']) {
        expect(await LocalDb.dayResult(d), isNull,
            reason: '$d: a WHOOP-only install has no row for it');
      }
      expect(await sleepSource('2026-10-03'), isNot('vendor_staged'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
