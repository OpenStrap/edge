// M0 §1: `LocalDb.cursorKeyFor` namespaces the three per-offloading-device
// sync_cursor keys (counter_hw, rec_ts_hw, strap_trim) while leaving the
// primary's bare keys untouched forever.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  group('cursorKeyFor (pure)', () {
    test('the primary keeps every bare key, unchanged', () {
      expect(LocalDb.cursorKeyFor('rec_ts_hw', LocalDb.kPrimaryDeviceId),
          'rec_ts_hw');
      expect(LocalDb.cursorKeyFor('counter_hw', LocalDb.kPrimaryDeviceId),
          'counter_hw');
      expect(LocalDb.cursorKeyFor('strap_trim', LocalDb.kPrimaryDeviceId),
          'strap_trim');
    });

    test('a non-primary device gets a suffixed key', () {
      expect(LocalDb.cursorKeyFor('rec_ts_hw', 'oura-a1b2'),
          'rec_ts_hw:oura-a1b2');
    });
  });

  group('cursorKeyFor (through commitSyncBatch)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'cursor_namespace_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.instance;
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    RawRecord raw(int counter, int recTs) => RawRecord(
          counter: counter,
          packetType: 0x2F,
          hex: '2f18aabbccdd',
          capturedAt: recTs * 1000,
          recTs: recTs,
        );

    test('deviceId "" writes the bare key, never a new empty ":" key',
        () async {
      await LocalDb.commitSyncBatch(
        [raw(1, 1750000001)],
        <Sample?>[Sample(tsEpoch: 1750000001, counter: 1, hr: 60)],
        trimToken: 'aa',
      );
      expect(await LocalDb.getCursor('rec_ts_hw'), isNotNull);
      expect(await LocalDb.getCursor('rec_ts_hw:'), isNull,
          reason: 'the naive "\$base:\$deviceId" form for the primary would '
              'render a NEW, EMPTY key — asserted absent');
    });

    // Two devices at different rec_ts don't cross-clobber each other's cursor,
    // AND a non-primary device commits and lands its row under its own
    // device_id — both need deviceId != kPrimaryDeviceId to reach
    // commitSyncBatch without throwing, which is exactly what db.dart's
    // StateError (spec §3) still forbids at this point in M0. These cases are
    // added to this file in the StateError-deletion commit instead of here —
    // see the fixture test's case 2 (test/two_device_fixture_test.dart) for
    // the RED version of the same scenario, and this file's own follow-up
    // group below once the StateError is gone.
  });

  group('after the StateError deletion (spec §3): non-primary deviceId', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'cursor_namespace_test_2.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.instance;
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    RawRecord raw(int counter, int recTs) => RawRecord(
          counter: counter,
          packetType: 0x2F,
          hex: '2f18aabbccdd',
          capturedAt: recTs * 1000,
          recTs: recTs,
        );

    test('two devices at different rec_ts do not cross-clobber each other\'s '
        'cursor', () async {
      await LocalDb.commitSyncBatch(
        [raw(2, 1750000100)],
        <Sample?>[Sample(tsEpoch: 1750000100, counter: 2, hr: 61)],
      );
      await LocalDb.commitSyncBatch(
        [raw(1, 1750000050)],
        <Sample?>[Sample(tsEpoch: 1750000050, counter: 1, hr: 62)],
        deviceId: 'oura-a1b2',
      );
      expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000100,
          reason: 'a lower second from another device must not roll the '
              'primary\'s cursor back');
      expect(await LocalDb.getCursorInt('rec_ts_hw:oura-a1b2'), 1750000050);
    });

    test('a non-primary device commits and lands its row under its own '
        'device_id (the StateError used to forbid this)', () async {
      await LocalDb.commitSyncBatch(
        [raw(3, 1750000200)],
        <Sample?>[Sample(tsEpoch: 1750000200, counter: 3, hr: 63)],
        deviceId: 'oura-a1b2',
      );
      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'rec_ts = ? AND device_id = ?',
          whereArgs: [1750000200, 'oura-a1b2']);
      expect(rows, hasLength(1));
    });
  });

  group('structural: no naive interpolation of these three keys', () {
    test('no lib/ file writes \'rec_ts_hw:\$x\' etc. by hand', () {
      final naive = RegExp(r"'(rec_ts_hw|counter_hw|strap_trim):\$");
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final text = f.readAsStringSync();
        for (final line in text.split('\n')) {
          if (naive.hasMatch(line)) offenders.add('${f.path}: $line');
        }
      }
      expect(offenders, isEmpty,
          reason: 'use LocalDb.cursorKeyFor instead of hand interpolation:\n'
              '${offenders.join('\n')}');
    });
  });
}
