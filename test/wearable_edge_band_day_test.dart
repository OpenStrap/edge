// A band day is judged on the band's own data edge, never the wearable's.
// With a flag-on wearable synced hours past the band, today's band day must
// not count the band's unsynced hours as off-wrist, store the wearable's
// edge as its data edge, or call a half-drained night settled: the day
// derives exactly as it does with the wearable's flag off.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const String _day = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'wearable_edge_band_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    // The band has drained only up to 10-04 12:00.
    final cut = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
    for (final (raws, samples)
        in SyntheticDay(DateTime(2026, 10, 4)).primaryBatches()) {
      if (raws.first.recTs! >= cut) break;
      await LocalDb.commitSyncBatch(raws, samples);
    }
    // A watch synced eight hours further.
    await LocalDb.upsertDevice(
        id: 'garmin-x', adapterId: 'garmin', label: 'garmin');
    final late = SyntheticDay.sec(DateTime(2026, 10, 4, 20));
    await (await LocalDb.instance).insert('decoded_onehz', {
      'device_id': 'garmin-x',
      'ts_ms': late * 1000,
      'rec_ts': late,
      'counter': 1,
      'hr': 70,
      'device_family': 'garmin',
      'source': 'garmin',
    });
    await LocalDb.setCursor(kActiveWearableCursor, 'garmin-x');
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<Map> derive() async {
    await DerivationEngine().runDays(_profile, {_day}, force: true);
    return jsonDecode((await LocalDb.dayResult(_day))!['payload_json']
        as String) as Map;
  }

  test('a flag-on wearable ahead of the band leaves the band day unchanged',
      () async {
    final off = await derive();
    final bandEdge = await LocalDb.lastDecodedRecTs();
    expect(off['data_edge_sec'], bandEdge);

    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '1');
    expect(await wearableLastTs(), greaterThan(bandEdge!));
    final on = await derive();
    expect(on['data_edge_sec'], bandEdge,
        reason: 'the band day\'s edge is the band\'s, not the watch\'s');
    expect(on['wear']?['coverage_pct'], off['wear']?['coverage_pct'],
        reason: 'the band\'s unsynced afternoon is not off-wrist');
    expect(on['wear']?['longest_off_min'], off['wear']?['longest_off_min']);
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '0');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an imported band day keeps its own edge with a flag-on wearable',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '1');
    final bandEdge = await LocalDb.lastDecodedRecTs();
    // Two hours of imported band rows, two days past the live band's edge.
    const day = '2026-10-06';
    final start = SyntheticDay.sec(DateTime(2026, 10, 6, 9));
    const n = 2 * 3600;
    final sub = Substrate(
      tsSec: [for (var i = 0; i < n; i++) start + i],
      hr: [for (var i = 0; i < n; i++) 82 + i % 7],
      rrTsMs: const [],
      rrMs: const [],
      ax: [for (var i = 0; i < n; i++) 0.05 * ((i % 60) / 60.0)],
      ay: [for (var i = 0; i < n; i++) 0.05 * ((i % 30) / 30.0)],
      az: List<double>.filled(n, 0.98),
      spo2Red: List<int>.filled(n, 0),
      spo2Ir: List<int>.filled(n, 0),
      skinTemp: List<int>.filled(n, 3000),
      skinContact: List<int>.filled(n, 0),
      deviceFamily: 'gen4',
    );
    await DerivationEngine().deriveImportedDays(sub, _profile, {day});
    final got = jsonDecode(
        (await LocalDb.dayResult(day))!['payload_json'] as String) as Map;
    expect(got['data_edge_sec'], sub.lastTs,
        reason: 'the import\'s edge, not the live band\'s ($bandEdge)');
    expect(got['wear']?['coverage_pct'], isNotNull,
        reason: 'the wear window does not collapse at the stale band edge');
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '0');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a ring day ages on the ring\'s edge with the band ahead of it',
      () async {
    await LocalDb.upsertDevice(id: 'oura-x', adapterId: 'oura', label: 'oura');
    final ringEdge = SyntheticDay.sec(DateTime(2026, 10, 4, 8));
    await (await LocalDb.instance).insert('decoded_onehz', {
      'device_id': 'oura-x',
      'ts_ms': ringEdge * 1000,
      'rec_ts': ringEdge,
      'counter': 1,
      'hr': 60,
      'device_family': 'oura',
      'source': 'oura',
    });
    await LocalDb.setCursor(kActiveWearableCursor, 'oura-x');
    await LocalDb.setCursor(wearableEnabledCursor('oura'), '1');
    final bandEdge = (await LocalDb.lastDecodedRecTs())!;
    expect(bandEdge, greaterThan(ringEdge));
    expect(await debugAgingEdge('oura', bandEdge), ringEdge,
        reason: 'a WHOOP-absent ring day is judged on the ring\'s edge');
    expect(await debugAgingEdge('gen4', ringEdge), bandEdge);
    await LocalDb.setCursor(wearableEnabledCursor('oura'), '0');
    expect(await debugAgingEdge('oura', bandEdge), bandEdge,
        reason: 'flag off: no wearable edge at all');
    await LocalDb.setCursor(kActiveWearableCursor, 'garmin-x');
  });
}
