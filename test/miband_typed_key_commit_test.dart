// The Mi Band typed-key commit against a "delete everything": a reset seen
// before, during or after the key and row writes leaves neither behind.

import 'dart:collection';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _id = 'huami_kongming-test';
const _item = 'miband234_pairing_key:$_id';
const _hex = '00112233445566778899aabbccddeeff';

Future<void> _row() => LocalDb.upsertDevice(
    id: _id, adapterId: 'huami_kongming', remoteId: 'AA:BB', label: 'band');

Future<bool> _hasRow() async =>
    (await LocalDb.deviceRows()).any((r) => r['id'] == _id);

void _reset() {
  ResetGate.enter();
  ResetGate.leave();
}

class _Undeletable extends MapBase<String, String> {
  final Map<String, String> _m = {};
  @override
  String? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, String value) => _m[key] = value;
  @override
  void clear() => throw StateError('keychain locked');
  @override
  Iterable<String> get keys => _m.keys;
  @override
  String? remove(Object? key) => throw StateError('keychain locked');
}

void main() {
  late Map<String, String> store;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'miband_typed_key_commit_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(LocalDb.close);

  setUp(() async {
    ResetGate.resetForTest();
    store = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(store);
    await LocalDb.deleteDevice(_id);
  });

  Future<String?> commit(int gen, {String? prior, Future<void> Function()? upsert}) =>
      commitMiBandTypedKey(
          resetGen: gen, deviceId: _id, hex: _hex, priorHex: prior,
          upsert: upsert ?? _row);

  test('no reset: the key and the row', () async {
    expect(await commit(ResetGate.generation), isNull);
    expect(store[_item], _hex);
    expect(await _hasRow(), isTrue);
  });

  test('a reset during the reads before it: nothing is written', () async {
    final gen = ResetGate.generation;
    _reset();
    expect(await commit(gen), contains('reset'));
    expect(store.containsKey(_item), isFalse);
    expect(await _hasRow(), isFalse);
  });

  test('a reset during the row write: the row and the key come back out',
      () async {
    expect(
        await commit(ResetGate.generation, upsert: () async {
          await _row();
          _reset(); // the wipe ran while the row was being written
        }),
        contains('reset'));
    expect(store.containsKey(_item), isFalse);
    expect(await _hasRow(), isFalse);
  });

  test('a failed row write after a reset deletes, never restores', () async {
    store[_item] = 'old';
    expect(
        await commit(ResetGate.generation, prior: 'old', upsert: () async {
          _reset();
          throw StateError('db closed');
        }),
        contains('reset'));
    expect(store.containsKey(_item), isFalse);
  });

  test('an undo the keychain refuses says a key may remain', () async {
    FlutterSecureStorage.setMockInitialValues(_Undeletable());
    expect(
        await commit(ResetGate.generation, upsert: () async {
          await _row();
          _reset();
        }),
        contains('may remain'));
  });

  test('a failed row write with no reset puts the old key back', () async {
    store[_item] = 'old';
    expect(
        await commit(ResetGate.generation,
            prior: 'old', upsert: () async => throw StateError('disk full')),
        contains('Could not save'));
    expect(store[_item], 'old');
  });
}
