// The Lefun HOST: banks archive rows and gates forget/sync against a live
// session, the two things only a host (not the adapter) can get wrong.
//
// NOTHING HERE HAS MET HARDWARE. `lefun_adapter_test.dart` already proves the
// adapter's own frame/session behaviour via `ReplayBandLink`; this file exists
// for `_buildArchiveRow`'s counter/rec_ts invariants, `_syncOne`'s primary-id
// refusal, and `HrsLink.forgetDevice`'s kLefun branch.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/lefun_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'lefun-0a1b2c3d';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'lefun_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('a battery reply is banked with counter and rec_ts both null',
      () async {
    // NULL, not 0 / not a decoded second — this envelope has no flash-record
    // counter and no clock, and a 0 would make every row `0 % 60 == 0` (i.e.
    // permanently exempt from raw-archive thinning), which is accidental
    // policy, not a decode.
    //
    // A real device-to-host battery reply (marker 0x5A, report 0x03, value
    // 87 = 0x57, checksum verified) — `buildLefunFrame` builds the other
    // direction (host-to-device, marker 0xAB) and would fail to parse here.
    await LefunLink.instance.ingestForTest(
      _deviceId,
      (i, v) => const [
        [0x5A, 0x05, 0x03, 0x57, 0xFB]
      ],
    );
    final db = await LocalDb.instance;
    final rows = await db.query('raw_archive', orderBy: 'captured_at, hex');
    expect(rows, hasLength(1));
    expect(rows.single['counter'], isNull);
    expect(rows.single['rec_ts'], isNull);
    expect(rows.single['reason'], 'lefun_report_0x03');
  });

  test('nothing paired means nothing to sync', () async {
    expect(await LefunLink.instance.sync(), isFalse);
  });

  test('a row claiming the primary device id is refused, not synced',
      () async {
    // This must return before ever touching BLE — a real connect attempt in
    // a plugin-less test isolate is the failure mode this test would catch.
    await LocalDb.upsertDevice(
      id: LocalDb.kPrimaryDeviceId,
      adapterId: kLefun.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
      label: 'Ring',
    );
    expect(await LefunLink.instance.sync(), isFalse);
  });

  group('forgetDevice', () {
    test('drops the device row when no session is live for it', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kLefun.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Ring',
      );
      await HrsLink.forgetDevice(_deviceId);
      final rows = await LocalDb.deviceRows();
      expect(rows.where((r) => r['id'] == _deviceId), isEmpty);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      await HrsLink.forgetDevice('lefun-never-paired');
      final rows = await LocalDb.deviceRows();
      expect(rows.where((r) => r['id'] == 'lefun-never-paired'), isEmpty);
    });

    test('currentDeviceId is null once a session has finished', () async {
      // `forgetDevice`'s kLefun branch only calls `stop()` when
      // `currentDeviceId` matches the row being forgotten — proving the
      // getter clears after a session is what keeps a later, unrelated
      // forget from stopping a session that already ended.
      await LefunLink.instance.ingestForTest(
        _deviceId,
        (i, v) => const [
          [0x5A, 0x05, 0x03, 0x57, 0xFB]
        ],
      );
      expect(LefunLink.instance.currentDeviceId, isNull);
    });
  });
}
