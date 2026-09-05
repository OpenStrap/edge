// The Pebble HOST: scripted PPoGATT bytes in, `raw_archive` out.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Pebble (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the watch below
// is a script. `pebble_adapter_test.dart` already proves the transport state
// machine (ACKs, resets); this file exists for the one thing only a host can
// get wrong: whether a byte the adapter yields actually reaches the database.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/pebble_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'pebble-0a1b2c3d';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'pebble_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('a banked data packet reaches raw_archive, undecoded', () async {
    await PebbleLink.instance.ingestForTest(_deviceId, [
      // header = (serial 0 << 3) | command 0 = 0x00, payload [0xAA, 0xBB].
      <int>[0x00, 0xAA, 0xBB],
    ]);
    final db = await LocalDb.instance;
    final rows = await db.query('raw_archive');
    expect(rows, hasLength(1));
    expect(rows.single['hex'], 'aabb');
    expect(rows.single['reason'], 'pebble_ppogatt');
    // NOT re-drivable: `redriveArchivedRecords` replays a row's hex through
    // the WHOOP R24 chain, which would be the wrong decoder over these bytes.
    expect(LocalDb.redrivableArchiveReasons, isNot(contains('pebble_ppogatt')));
    // The band-only readers cannot see this row.
    expect(rows.single['counter'], isNull, reason: 'no flash-record counter');
  });

  test('an ACK-only reply banks nothing', () async {
    await PebbleLink.instance.ingestForTest(_deviceId, [
      <int>[0x09], // (1<<3)|1 — an ack for a serial we sent
    ]);
    final db = await LocalDb.instance;
    expect(await db.query('raw_archive'), isEmpty);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await PebbleLink.pairedWatchRow(), isNull);
    expect(await PebbleLink.instance.sync(), isFalse);
  });

  group('forgetPebble', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kPebble.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Pebble',
      );
      expect(await PebbleLink.pairedWatchRow(), isNotNull);
      final ok = await PebbleLink.forgetPebble(_deviceId);
      expect(ok, isTrue);
      expect(await PebbleLink.pairedWatchRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await PebbleLink.forgetPebble(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await PebbleLink.forgetPebble('pebble-never-paired');
      expect(ok, isTrue);
      expect(await PebbleLink.pairedWatchRow(), isNull);
    });
  });
}
