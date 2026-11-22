// Policy exception PE-1 end to end: a Helio strap alone, sixteen synthetic
// nights, its own RMSSD readings banked as raw samples. Once both readiness
// inputs have their fourteen nights, the composite scores off resting HR (our
// minute HR) and the strap's readings (our night mean of them), and every
// layer says the HRV was the device's: the envelope's `hrv_source`, the served
// cell's method, the series' own key and family.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show TimeAnchor;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/device_night_samples.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const int _nights = 16;
final List<SyntheticDay> _days = [
  // Resting HR wanders a couple of bpm night to night, as a real one does: a
  // flat baseline has no spread, and the RHR input rightly refuses it.
  for (var d = 1; d <= _nights; d++)
    SyntheticDay(DateTime(2026, 9, d),
        nightHrOffset: ((d * 37) % 5 - 2).toDouble()),
];
String _label(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
final Set<String> _dayIds = {for (final d in _days) _label(d.day)};
final String _today = _label(_days.last.day);
final String _thin = _label(_days[_nights - 2].day);
const String _id = 'helio-hrv';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

void main() {
  group('the night value (pure)', () {
    const on = 1000, off = 1000 + 8 * 3600;
    test('ln of the mean of the plausible readings inside the night', () {
      final r = deviceNightLnRmssd([
        for (var i = 0; i < 6; i++) (on + i * 120, 40.0 + i * 4),
        (on - 60, 90), // before the night
        (on + 600, 255), // a pinned u8, not a reading
      ], onsetSec: on, offsetSec: off);
      expect(r.lnRmssd, closeTo(math.log(50), 1e-9));
      expect(r.refusal, isNull);
    });
    test('under six readings: no value, and the note says so', () {
      final r = deviceNightLnRmssd(
          [for (var i = 0; i < 5; i++) (on + i * 120, 50.0)],
          onsetSec: on, offsetSec: off);
      expect(r.lnRmssd, isNull);
      expect(r.refusal, 'device_rmssd:n=5,need=6');
      expect(deviceNightLnRmssd(const [], onsetSec: on, offsetSec: off).lnRmssd,
          isNull);
    });
  });

  group('derived', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'helio_device_hrv_readiness_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
          id: _id, adapterId: 'helio_strap', label: 'Helio');
      await LocalDb.upsertDevice(
          id: 'garmin-x', adapterId: 'garmin', label: 'garmin');
      final minuteHr = <int, int>{};
      for (final d in _days) {
        for (final MapEntry(key: t, value: bpm) in d.hr.entries) {
          if (t % 60 == 0) minuteHr[t] = bpm;
        }
      }
      final samples = <NeutralSample>[
        for (final t in (minuteHr.keys.toList()..sort()))
          NeutralSample(
              anchor: TimeAnchor.measured, tsEpoch: t, hr: minuteHr[t]),
      ];
      final rnd = math.Random(7);
      for (var i = 0; i < _nights; i++) {
        final d = _days[i];
        final on = SyntheticDay.sec(d.sleepOnset);
        final off = SyntheticDay.sec(d.sleepOffset);
        // A usual night between 50 and 62 ms; the last night under it. The night
        // before it carries only five readings: under the gate.
        final usual = 50 + rnd.nextDouble() * 12;
        final step = i == _nights - 2 ? (off - on) ~/ 5 : 120;
        var n = 0;
        for (var t = on + 61; t < off && (i != _nights - 2 || n < 5);
            t += step, n++) {
          samples.add(NeutralSample(
              anchor: TimeAnchor.measured,
              tsEpoch: t,
              deviceRmssdMs: i == _nights - 1
                  ? 44 + rnd.nextDouble() * 4
                  : usual + rnd.nextDouble() * 4 - 2));
        }
        await LocalDb.putVendorSleepEpochs([
          for (final (a, b, st) in d.hypnogramBlocks())
            VendorEpoch(a, b, st.name),
        ], deviceId: _id, source: 'helio_strap');
      }
      await LocalDb.commitSyncBatch(const [], const [],
          deviceId: _id, deviceFamily: 'helio_strap', neutrals: samples);
      // A family not admitted under PE-1, with readings of its own on disk.
      await LocalDb.commitSyncBatch(const [], const [],
          deviceId: 'garmin-x',
          deviceFamily: 'garmin',
          neutrals: [
            NeutralSample(
                anchor: TimeAnchor.measured,
                tsEpoch: SyntheticDay.sec(_days.last.sleepOnset) + 600,
                deviceRmssdMs: 40),
          ]);
      await LocalDb.setCursor(kActiveWearableCursor, _id);
      await LocalDb.setCursor(wearableEnabledCursor('helio_strap'), '1');
      for (var i = 0; i < 2; i++) {
        await DerivationEngine().runDays(_profile, _dayIds, force: true);
      }
    });

    tearDownAll(() async => LocalDb.close());

    test("readiness scores off resting HR and the strap's own readings, "
        'labelled as such everywhere', () async {
      final stored = _payload((await LocalDb.dayResult(_today))!);
      final rc = (stored['clinical'] as Map)['readiness_composite'] as Map;
      expect(rc['hrv_source'], 'device_rmssd');
      expect(rc['inputs_used'], containsAll(['HRV', 'RHR']));
      final scalars = stored['scalars'] as Map;
      expect(scalars['ln_rmssd'], isNull, reason: 'no beats: not ours at 1 Hz');
      expect(scalars['ln_rmssd_dev'], closeTo(math.log(46), 0.1));
      expect(rc['method'], kDeviceHrvReadinessMethod,
          reason: 'the envelope itself carries the device-HRV method');
      expect(scalars['readiness'], isA<num>());
      expect(scalars['readiness'] as num, lessThan(50),
          reason: 'the night sat far under its usual HRV');

      final cells = (await dayCells(_today))!;
      expect(cells['readiness']!['class'], 'ours');
      expect(cells['readiness']!['method'], kDeviceHrvReadinessMethod);
      expect(cells['readiness']!['value'], scalars['readiness']);
      expect(cells['hrv']!['class'], 'ours');
      expect(cells['hrv']!['method'], kDeviceRmssdMethod);
      expect(cells['hrv']!['value'] as num, closeTo(46, 3));

      final db = await LocalDb.instance;
      final m = await db.query('metric_method',
          where: 'date = ? AND key IN (?, ?)',
          whereArgs: [_today, 'ln_rmssd_dev', 'readiness']);
      final byKey = {for (final r in m) r['key']: r};
      expect(byKey['ln_rmssd_dev']?['family'], 'helio_strap');
      expect(byKey['readiness']?['method'], kDeviceHrvReadinessMethod);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a night under the gate takes no device HRV, and says why', () async {
      final stored = _payload((await LocalDb.dayResult(_thin))!);
      final rc = (stored['clinical'] as Map)['readiness_composite'] as Map;
      expect(rc['hrv_source'], isNull);
      expect(rc['device_rmssd_refusal'], startsWith('device_rmssd:n=5'));
      expect((stored['scalars'] as Map)['ln_rmssd_dev'], isNull);
    });

    test('an unadmitted family never reaches the readings', () async {
      final on = SyntheticDay.sec(_days.last.sleepOnset);
      expect(
          await deviceRmssdSamples('garmin', 'garmin-x', on, on + 3600), isEmpty);
      expect(await deviceRmssdSamples('helio_strap', _id, on, on + 3600),
          isNotEmpty);
    });

    test('re-deriving moves no stored readiness or device HRV', () async {
      Future<Map<String, Object?>> snap() async => {
            for (final d in _dayIds)
              d: {
                for (final k in ['readiness', 'readiness_z', 'ln_rmssd_dev'])
                  k: (_payload((await LocalDb.dayResult(d))!)['scalars']
                      as Map)[k],
              },
          };
      final before = await snap();
      for (var i = 0; i < 2; i++) {
        await DerivationEngine().runDays(_profile, _dayIds, force: true);
      }
      expect(await snap(), before);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
