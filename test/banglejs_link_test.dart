// The DB-only slice of BangleJsLink that needs no real radio: pairedRow,
// sync's "nothing paired" refusal, and forget's three cases. Mirrors
// oura_link_test.dart's own non-BLE coverage.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/banglejs_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _deviceId = 'banglejs-deadbeef';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'banglejs_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('nothing paired means nothing to sync', () async {
    expect(await BangleJsLink.pairedRow(), isNull);
    expect(await BangleJsLink.instance.sync(), isFalse);
  });

  group('forget', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kBangleJs.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Bangle.js',
      );
      expect(await BangleJsLink.pairedRow(), isNotNull);
      final ok = await BangleJsLink.forget(_deviceId);
      expect(ok, isTrue);
      expect(await BangleJsLink.pairedRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await BangleJsLink.forget(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await BangleJsLink.forget('banglejs-never-paired');
      expect(ok, isTrue);
      expect(await BangleJsLink.pairedRow(), isNull);
    });
  });
}
