// A night the primary band never saw (test/support/synthetic_day.dart, with NO
// primary batches seeded): the Colmi ring's own hypnogram, synced through its
// real link, becomes the day's main sleep (`vendor_staged`) and the day
// derives its sleep scores from it. The night WITH primary data is pinned by
// synthetic_e2e_test.dart (our derivation stays primary there).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final SyntheticDay _truth = SyntheticDay(DateTime(2026, 10, 4));
const String _dayId = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_vendor_night_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async => LocalDb.close());

  test('no primary band that night: the ring stages it and scores exist',
      () async {
    final now = DateTime(2026, 10, 4, 22, 30);
    await LocalDb.upsertDevice(
        id: 'colmi-synthetic',
        adapterId: 'colmi',
        remoteId: 'AA:BB:CC:00:00:01',
        label: 'colmi');
    await ColmiLink.instance.ingestForTest(
      'colmi-synthetic',
      (_, w) => _truth.colmiReply(w, now),
      nowSeconds: () => SyntheticDay.sec(now),
    );
    expect(await LocalDb.lastDecodedRecTs(), isNull,
        reason: 'no primary band rows at all');

    final done =
        await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    expect(done, 1, reason: 'a day with only a device night still derives');
    final full = jsonDecode((await LocalDb.dayResult(_dayId))!['payload_json']
        as String) as Map;
    final s = (full['scalars'] as Map).cast<String, dynamic>();
    // ignore: avoid_print
    print('vendor-only night scalars: $s');

    expect(full['sleep_source'], 'vendor_staged');
    final window = ((full['sleep'] as Map)['window'] as Map)['value'] as Map;
    expect((window['onset_ms'] as num) ~/ 1000,
        SyntheticDay.sec(_truth.sleepOnset));
    expect((window['offset_ms'] as num) ~/ 1000,
        SyntheticDay.sec(_truth.sleepOffset));
    expect((s['deep_min'], s['rem_min']), (_truth.deepMin, _truth.remMin),
        reason: "the stages are the ring's, minute for minute");
    expect(((s['tst_min'] as num) - _truth.tstMin).abs(), lessThanOrEqualTo(1));
    expect(s['efficiency'], isNotNull);
    expect(s['awakenings'], isNotNull);
    expect(s['rmssd'], isNull,
        reason: 'no beat-to-beat data that night: absent, never fabricated');
  });
}
