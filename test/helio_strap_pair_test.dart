// `pairHelioStrapWithTypedKey`'s key-validation path, which runs and
// returns BEFORE any BLE call — the only part of this function testable
// without a real strap. `flutter_blue_plus` has no simulator path, so the
// connect/discover/handshake body is untested here, same as every other
// link's typed-key pairing function in this repo (none of
// `pairOuraRing`/`pairOuraRingWithKey`/`pairOuraRingWithTypedKey` has a test
// either) — verified only by real hardware (ASSUMPTIONS R6).

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/helio_strap_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // The pairing reads the device table before its BLE call.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_helio_pair_test.db';
  });
  tearDownAll(LocalDb.close);

  final device = BluetoothDevice.fromId('00:00:00:00:00:00');

  test('a key that is not 32 hex characters is rejected before any BLE call',
      () async {
    expect(await pairHelioStrapWithTypedKey(device, 'too short'),
        contains('32 hex characters'));
    expect(await pairHelioStrapWithTypedKey(device, 'x' * 32),
        contains('32 hex characters'));
    expect(await pairHelioStrapWithTypedKey(device, 'a' * 31),
        contains('32 hex characters'));
  });

  test('a 0x-prefixed key of the right length passes validation (and then '
      'fails on the real BLE call, which is expected without a strap)',
      () async {
    final result =
        await pairHelioStrapWithTypedKey(device, '0x${'ab' * 16}');
    // Validation passed (no "32 hex characters" complaint); whatever comes
    // back is from the real connect attempt, which has nothing to connect
    // to here.
    expect(result, isNot(contains('32 hex characters')));
  });
}
