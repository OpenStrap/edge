// END TO END on a synthetic but plausible day (test/support/synthetic_day.dart):
//
//  1. The primary band's night goes through the SAME write a WHOOP drain uses
//     (`LocalDb.commitSyncBatch`), then the REAL `DerivationEngine.runDays`.
//     The derived day is checked against the known truth — sleep window,
//     total sleep, resting HR, HRV, respiration, strain — which is the test
//     of our analytics, not of a fixture.
//  2. A Colmi ring and an Ultrahuman ring that wore the same day sync through
//     their REAL adapters, hosts and sqlite. Their data must reach the app
//     (decoded rows, the ring's sleep stages, the day's attributed vendor
//     values) and must NOT move the derived day: neither is admitted to
//     derivation (`kDerivableSources`, owner ruling R6).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/garmin.dart' show garminDecodeReadFiles;
import 'package:openstrap_edge/ble/adapters/miband234.dart' show miBand234AuthResponse;
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/ble/garmin_link.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/ble/ultrahuman_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show kGarminEventHandshakeComplete;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/garmin_watch.dart';
import 'support/synthetic_day.dart';

final SyntheticDay _truth = SyntheticDay(DateTime(2026, 10, 4));
const String _dayId = '2026-10-04';
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
    LocalDb.dbName = 'synthetic_e2e_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (raws, samples) in _truth.primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples);
    }
  });

  tearDownAll(() async => LocalDb.close());

  late Map<String, Object?> firstRow;

  test('the primary night derives, and the analytics recover the truth',
      () async {
    final done = await DerivationEngine()
        .runDays(_profile, {_dayId}, force: true);
    expect(done, 1, reason: 'the day must derive, not be skipped');
    firstRow = (await LocalDb.dayResult(_dayId))!;
    final s = _scalars(firstRow);

    final full = jsonDecode(firstRow['payload_json'] as String) as Map;
    final window = ((full['sleep'] as Map)['window'] as Map)['value'] as Map;
    final onset = (window['onset_ms'] as num) ~/ 1000;
    final offset = (window['offset_ms'] as num) ~/ 1000;
    String hm(int t) => DateTime.fromMillisecondsSinceEpoch(t * 1000)
        .toString()
        .substring(11, 19);
    // A readable report: what the app derived against what was true.
    // ignore: avoid_print
    print('''
SYNTHETIC DAY $_dayId — derived vs truth
  sleep onset   ${hm(onset)}  (truth ${hm(SyntheticDay.sec(_truth.sleepOnset))})
  sleep offset  ${hm(offset)}  (truth ${hm(SyntheticDay.sec(_truth.sleepOffset))})
  total sleep   ${s['tst_min']} min  (truth ${_truth.tstMin})
  deep / rem    ${s['deep_min']} / ${s['rem_min']} min  (truth ${_truth.deepMin} / ${_truth.remMin})
  resting HR    ${(s['rhr_nocturnal'] as num?)?.toStringAsFixed(1)}  (truth 5-min nadir ${_truth.nightHrNadir.toStringAsFixed(1)})
  RMSSD         ${(s['rmssd'] as num?)?.toStringAsFixed(1)} ms  (truth ${_truth.nightRmssd.toStringAsFixed(1)})
  resp rate     ${(s['resp_rate'] as num?)?.toStringAsFixed(2)}  (truth ${SyntheticDay.sleepRespRate})
  strain        ${s['strain']}   active ${s['active_min']} min
  sleep source  ${full['sleep_source']}''');

    expect((onset - SyntheticDay.sec(_truth.sleepOnset)).abs(),
        lessThanOrEqualTo(15 * 60));
    expect((offset - SyntheticDay.sec(_truth.sleepOffset)).abs(),
        lessThanOrEqualTo(15 * 60));
    expect(((s['tst_min'] as num) - _truth.tstMin).abs(),
        lessThanOrEqualTo(60));
    expect(((s['rhr_nocturnal'] as num) - _truth.nightHrNadir).abs(),
        lessThanOrEqualTo(6));
    final rmssd = (s['rmssd'] as num).toDouble();
    expect(rmssd, inInclusiveRange(_truth.nightRmssd * 0.5,
        _truth.nightRmssd * 1.5));
    final resp = s['resp_rate'] as num?;
    if (resp != null) {
      expect((resp - SyntheticDay.sleepRespRate).abs(), lessThanOrEqualTo(2));
    }
    expect((s['strain'] as num?) ?? 0, greaterThan(0),
        reason: 'a 40-minute run at 150 bpm is real load');
  });

  test('Colmi, Ultrahuman, Mi Band and Garmin data reach the app and leave '
      'the day '
      'untouched',
      () async {
    final now = DateTime(2026, 10, 4, 22, 30);
    int nowSec() => SyntheticDay.sec(now);
    // PAIRING: each device has its own row, as the pairing screen writes it.
    const ids = {
      'colmi-synthetic': 'colmi',
      'ultrahuman-synthetic': 'ultrahuman',
      'miband-synthetic': 'miband234',
      'garmin-synthetic': 'garmin',
    };
    for (final MapEntry(:key, :value) in ids.entries) {
      await LocalDb.upsertDevice(
          id: key, adapterId: value, remoteId: 'AA:BB:CC:00:00:0${key.length % 10}',
          label: value);
    }
    final pairedAt = {
      for (final r in await LocalDb.deviceRows()) r['id']: r['last_seen'],
    };
    await ColmiLink.instance.ingestForTest(
      'colmi-synthetic',
      (_, w) => _truth.colmiReply(w, now),
      nowSeconds: nowSec,
    );
    await UltrahumanLink.instance.ingestForTest(
      'ultrahuman-synthetic',
      (_, w) => _truth.ultrahumanReply(w),
      nowSeconds: nowSec,
    );
    // Mi Band 2/3: real auth handshake, then the activity fetch, resuming
    // from yesterday's midnight so today and last night are read whole.
    final key = List<int>.generate(16, (i) => i + 1);
    final challenge = List<int>.generate(16, (i) => 0xa0 + i);
    await LocalDb.setCursor('miband_since:miband-synthetic',
        '${SyntheticDay.sec(DateTime(2026, 10, 3))}');
    await MiBand234Link.instance.ingestForTest(
      'miband-synthetic',
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
      history: (char, w) => _truth.miBandReply(char, w, now),
      nowSeconds: nowSec,
      window: const Duration(seconds: 5),
    );
    // Garmin: real handshake, directory, then each health FIT file in
    // chunks with a running CRC.
    final watch = GarminWatchScript(_truth.garminFiles());
    await GarminLink.instance.ingestForTest('garmin-synthetic', watch.reply,
        nowSeconds: nowSec);
    expect(watch.downloaded, [0, 2, 3, 1],
        reason: 'the directory, then each health file oldest first');

    final db = await LocalDb.instance;
    final perSource = {
      for (final r in await db.rawQuery(
          'SELECT source, COUNT(*) n FROM decoded_onehz GROUP BY source'))
        r['source']: r['n'],
    };
    // ignore: avoid_print
    print('decoded_onehz rows per source: $perSource');
    expect(perSource['colmi'], greaterThan(200), reason: '5-min HR history');
    expect(perSource['ultrahuman'], greaterThan(200));
    expect(perSource['miband234'], greaterThan(1000), reason: 'per-minute HR');
    expect(perSource['garmin'], greaterThan(1000), reason: 'monitoring HR');

    final epochs = await db.query('vendor_sleep_epoch',
        where: 'source = ?', whereArgs: ['colmi']);
    expect(epochs, isNotEmpty, reason: "the ring's own hypnogram is banked");

    final obs = await LocalDb.observationsForDay(_dayId);
    final byVendor = <String, Map<String, num>>{};
    for (final o in obs) {
      (byVendor[o['attribution'] as String] ??= {})[
              (o['vendor_key'] ?? o['key']) as String] =
          o['value'] as num;
    }
    // ignore: avoid_print
    print('observations on $_dayId: $byVendor');
    expect(byVendor['Colmi']?['steps'], _truth.stepsOn(_truth.day));
    expect(byVendor['Ultrahuman']?['steps'], _truth.stepsOn(_truth.day));
    expect(byVendor['Colmi']?['sleep_deep_min'], isNotNull);
    expect(byVendor['Ultrahuman']?['hrv_avg'], isNotNull);
    expect(byVendor['Mi Band']?['steps'], _truth.stepsOn(_truth.day));
    expect(byVendor['Garmin']?['steps'], _truth.stepsOn(_truth.day));
    expect(byVendor['Garmin']?['sleep_deep_min'], _truth.deepMin);
    expect(byVendor['Garmin']?['sleep_rem_min'], _truth.remMin);
    expect(byVendor['Garmin']?['hrv_last_night_avg'], 45);
    expect(
        garminDecodeReadFiles(
                await LocalDb.getCursor('garmin_fit_files:garmin-synthetic'))
            .keys,
        unorderedEquals([1, 2, 3]),
        reason: 'every file read, two of them sharing a timestamp');
    expect(watch.systemEvents, [kGarminEventHandshakeComplete],
        reason: 'the watch asked for it in its configuration');
    expect(byVendor['Mi Band']?['sleep_deep_min'], _truth.deepMin,
        reason: "the band's own deep-sleep minutes, as it reported them");
    expect(
        await LocalDb.getCursorInt('miband_since:miband-synthetic'),
        SyntheticDay.sec(DateTime(2026, 10, 3)),
        reason: 'resume from the start of the day before the last minute');

    // SHOWING: every device row now says when it last synced, Colmi its
    // battery (the device detail screen and the list row read these), and
    // the day timeline can draw each device's own HR curve.
    final rows = {for (final r in await LocalDb.deviceRows()) r['id']: r};
    for (final id in ids.keys) {
      expect(rows[id]!['last_seen'], greaterThanOrEqualTo(pairedAt[id] as int),
          reason: '$id last_seen stamped by the sync');
    }
    expect(rows['colmi-synthetic']!['battery_pct'], 80);
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    for (final id in ids.keys) {
      final chart = await repo.getDeviceChart('hr', deviceId: id, date: _dayId);
      expect((chart['points'] as List), isNotEmpty,
          reason: '$id HR curve for the timeline');
      expect(declaredSignals(ids[id]), contains(InputSignal.hrSparse),
          reason: '$id is selectable in the timeline device filter');
    }
    final repoObs = await repo.getDayObservations(_dayId);
    expect(repoObs.map((o) => o['attribution']).toSet(),
        containsAll(['Colmi', 'Ultrahuman', 'Mi Band', 'Garmin']),
        reason: 'the day timeline notes, as the screen reads them');

    // THE SLEEP SCREEN'S DEVICE SWITCHER reads each device's own night.
    final nights = {
      for (final n in await repo.getDeviceNights(_dayId)) n['device_id']: n,
    };
    expect(nights.keys,
        containsAll(['colmi-synthetic', 'miband-synthetic', 'garmin-synthetic']));
    for (final id in ['colmi-synthetic', 'garmin-synthetic']) {
      final m = nights[id]!['stage_min'] as Map;
      expect((m['deep'], m['rem']), (_truth.deepMin, _truth.remMin),
          reason: '$id night as that device staged it');
      expect(nights[id]!['wake_ts'], SyntheticDay.sec(_truth.sleepOffset));
    }
    expect((nights['miband-synthetic']!['stage_min'] as Map)['rem'], isNull,
        reason: 'Mi Band reports no REM; its light holds it');

    // Re-derive: the secondary rings must not have moved a single number.
    final done = await DerivationEngine()
        .runDays(_profile, {_dayId}, force: true);
    expect(done, 1);
    final again = (await LocalDb.dayResult(_dayId))!;
    expect(_scalars(again), _scalars(firstRow),
        reason: 'unadmitted sources are filtered at substrate load');
    expect(_scalars(again)['sleep_source'], isNot('vendor_staged'),
        reason: 'a ring that does not own hr1Hz may not stage the night');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
