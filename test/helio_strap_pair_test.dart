// `pairHelioStrapWithTypedKey`'s key-validation path, which runs and
// returns BEFORE any BLE call — the only part of this function testable
// without a real strap. `flutter_blue_plus` has no simulator path, so the
// connect/discover/handshake body is untested here, same as every other
// link's typed-key pairing function in this repo (none of
// `pairOuraRing`/`pairOuraRingWithKey`/`pairOuraRingWithTypedKey` has a test
// either) — verified only by real hardware (ASSUMPTIONS R6).

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:collection';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart'
    show kHelioStrapSecureStorageKey;
import 'package:openstrap_edge/ble/helio_strap_link.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
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

  test('a pairing begun during a reset is refused before it reads anything',
      () async {
    ResetGate.enter();
    try {
      expect(await pairHelioStrapWithTypedKey(device, 'ab' * 16),
          kHelioPairResetText);
    } finally {
      ResetGate.leave();
    }
  });

  group('persisting an accepted key', () {
    Future<Map<String, Object?>?> row() => LocalDb.deviceRow('helio-test');
    Future<String?> persist({String? prior}) => persistHelioPairing(
          deviceId: 'helio-test',
          remoteId: 'AA:BB',
          hex: 'ab' * 16,
          priorHex: prior,
          resetGen: ResetGate.generation,
        );

    setUp(() async => LocalDb.deleteDevice('helio-test'));

    test('no reset: the key and the row land', () async {
      final store = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(store);
      expect(await persist(), isNull);
      expect(store[kHelioStrapSecureStorageKey], 'ab' * 16);
      expect(await row(), isNotNull);
    });

    test('a reset since the pairing began: nothing is written', () async {
      final store = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(store);
      final gen = ResetGate.generation;
      ResetGate.enter();
      ResetGate.leave();
      expect(
          await persistHelioPairing(
              deviceId: 'helio-test',
              remoteId: 'AA:BB',
              hex: 'ab' * 16,
              priorHex: null,
              resetGen: gen),
          kHelioPairResetText);
      expect(store, isEmpty);
      expect(await row(), isNull);
    });

    test('a reset whose key undo fails says a key may remain', () async {
      FlutterSecureStorage.setMockInitialValues(_ResetOnWriteUndeletable());
      expect(await persist(), kHelioPairResetLeftoverText);
      expect(await row(), isNull);
    });

    test('a reset that lands during the key write takes the key back out',
        () async {
      final store = _ResetOnWrite();
      FlutterSecureStorage.setMockInitialValues(store);
      expect(await persist(prior: 'cd' * 16), kHelioPairResetText);
      expect(store.containsKey(kHelioStrapSecureStorageKey), isFalse,
          reason: 'neither the new key nor the pre-reset one survives');
      expect(await row(), isNull);
    });
  });
}

/// A keychain whose writes coincide with a "delete everything".
class _ResetOnWrite extends MapBase<String, String> {
  final _m = <String, String>{};
  @override
  String? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, String value) {
    ResetGate.enter();
    ResetGate.leave();
    _m[key] = value;
  }

  @override
  void clear() => _m.clear();
  @override
  Iterable<String> get keys => _m.keys;
  @override
  String? remove(Object? key) => _m.remove(key);
}

/// [_ResetOnWrite] whose deletes fail, as a locked keychain's would.
class _ResetOnWriteUndeletable extends _ResetOnWrite {
  @override
  String? remove(Object? key) => throw StateError('keychain locked');
}
