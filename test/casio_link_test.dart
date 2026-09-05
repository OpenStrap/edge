// The Casio HOST wrapper: DB-only tests, the same surface
// `oura_link_test.dart` covers for its own host — no radio touched, because
// every path here that matters returns before `sync()` reaches BLE.
//
// `casio_adapter_test.dart` already proves the session state machine (probe
// order, verbatim banking, timeout). This file exists for what only the host
// can get wrong: refusing to sync with nothing paired, refusing to write
// under the primary band's device id, picking the right row when two Casio
// watches are paired, and the shape of the archive row it builds.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/casio_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'casio_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('nothing paired means nothing to sync', () async {
    expect(await CasioLink.pairedRow(), isNull);
    expect(await CasioLink.instance.sync(), isFalse);
  });

  test('refuses to sync a row that claims the primary device id', () async {
    await LocalDb.upsertDevice(
      id: LocalDb.kPrimaryDeviceId,
      adapterId: kCasio.id,
      remoteId: 'AA:BB:CC:DD:EE:01',
      label: 'Casio',
    );
    // The guard fires before any connect attempt, so this is safe without a
    // real BLE stack behind it.
    expect(await CasioLink.instance.sync(), isFalse);
  });

  group('pairedRow', () {
    test('with one paired watch and no id given, returns it', () async {
      await LocalDb.upsertDevice(
        id: 'casio-aaaa',
        adapterId: kCasio.id,
        remoteId: 'AA:BB:CC:DD:EE:01',
        label: 'G-Shock',
      );
      final row = await CasioLink.pairedRow();
      expect(row?['id'], 'casio-aaaa');
    });

    test('with two paired watches, an id selects exactly that row', () async {
      await LocalDb.upsertDevice(
        id: 'casio-aaaa',
        adapterId: kCasio.id,
        remoteId: 'AA:BB:CC:DD:EE:01',
        label: 'G-Shock 1',
      );
      await LocalDb.upsertDevice(
        id: 'casio-bbbb',
        adapterId: kCasio.id,
        remoteId: 'AA:BB:CC:DD:EE:02',
        label: 'G-Shock 2',
      );
      final first = await CasioLink.pairedRow(deviceId: 'casio-aaaa');
      final second = await CasioLink.pairedRow(deviceId: 'casio-bbbb');
      expect(first?['id'], 'casio-aaaa');
      expect(first?['remote_id'], 'AA:BB:CC:DD:EE:01');
      expect(second?['id'], 'casio-bbbb');
      expect(second?['remote_id'], 'AA:BB:CC:DD:EE:02');
    });

    test('an id that matches no row, or a different family, is null',
        () async {
      await LocalDb.upsertDevice(
        id: 'casio-aaaa',
        adapterId: kCasio.id,
        remoteId: 'AA:BB:CC:DD:EE:01',
        label: 'G-Shock',
      );
      expect(await CasioLink.pairedRow(deviceId: 'casio-never-paired'), isNull);
      // A row that exists but is not this family must never be picked up by
      // the no-id default path either.
      await LocalDb.upsertDevice(
        id: 'other-family',
        adapterId: 'some_other_adapter',
        remoteId: 'AA:BB:CC:DD:EE:99',
        label: 'Not a Casio',
      );
      final row = await CasioLink.pairedRow(deviceId: 'other-family');
      expect(row, isNull);
    });
  });

  group('the archive row builder', () {
    test('bytes hex-encode verbatim, with a null counter and a null rec_ts',
        () {
      final row = CasioLink.buildArchiveRowForTest(<int>[0x20, 0xAA, 0xBB], 1786000000);
      expect(row, isNotNull);
      expect(row!.hex, '20aabb');
      expect(row.counter, isNull, reason: 'this wire has no flash counter');
      expect(row.recTs, isNull, reason: 'this wire carries no wall-clock second');
      expect(row.capturedAt, 1786000000);
    });

    test('packetType is the tag byte, and the reason names that tag', () {
      final row = CasioLink.buildArchiveRowForTest(<int>[0x22, 0x01], 1786000000);
      expect(row!.packetType, 0x22);
      expect(row.reason, 'casio_tag_0x22');
    });

    test('an empty frame builds no row', () {
      expect(CasioLink.buildArchiveRowForTest(<int>[], 1786000000), isNull);
    });
  });
}
