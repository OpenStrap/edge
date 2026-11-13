// "Compact database": prune per policy, VACUUM, truncate the WAL — only with
// twice the database free, and never alongside a derive pass.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

/// Fill a scratch table and delete it, leaving free pages behind.
Future<void> _bloat() async {
  final db = await LocalDb.instance;
  await db.execute('CREATE TABLE IF NOT EXISTS _bloat (x BLOB)');
  final blob = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 7);
  await db.transaction((txn) async {
    for (var i = 0; i < 160; i++) {
      await txn.insert('_bloat', {'x': blob});
    }
  });
  await db.execute('DROP TABLE _bloat');
}

Future<int> _walBytes() async {
  final path = p.join(await getDatabasesPath(), LocalDb.dbName);
  final f = File('$path-wal');
  return await f.exists() ? await f.length() : 0;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DerivationEngine.debugRunning = false;
    await LocalDb.close();
  });

  test('vacuums and truncates the WAL when there is room', () async {
    await _useFreshDb('compact_room.db');
    await _bloat();
    final steps = <CompactStep>[];
    final r = await DerivationEngine().compactStorage(
      freeDiskBytes: () async => 1 << 40,
      onStep: steps.add,
    );
    expect(r.vacuumed, isTrue);
    expect(steps, [CompactStep.prune, CompactStep.vacuum]);
    expect(r.freedBytes, greaterThan(5 << 20));
    expect(r.afterBytes, await LocalDb.databaseBytesOnDisk());
    expect(await _walBytes(), 0);
    expect(await LocalDb.freelistBytes(), 0);
  });

  test('refuses the VACUUM under twice the database free', () async {
    await _useFreshDb('compact_tight.db');
    await _bloat();
    final size = await LocalDb.databaseBytesOnDisk();
    final r = await DerivationEngine().compactStorage(
      freeDiskBytes: () async => 2 * size - 1,
    );
    expect(r.vacuumed, isFalse);
    expect(r.neededBytes, greaterThanOrEqualTo(r.freeBytes!));
    expect(await LocalDb.freelistBytes(), greaterThan(0));
  });

  test('skips the VACUUM when a sync started while the prune ran', () async {
    await _useFreshDb('compact_busy.db');
    await _bloat();
    final steps = <CompactStep>[];
    final r = await DerivationEngine().compactStorage(
      freeDiskBytes: () async => 1 << 40,
      onStep: steps.add,
      busy: () => true,
    );
    expect(r.vacuumed, isFalse);
    expect(r.deferred, isTrue);
    expect(steps, [CompactStep.prune]);
    expect(await LocalDb.freelistBytes(), greaterThan(0));
  });

  test('unknown free space counts as not enough', () async {
    await _useFreshDb('compact_unknown.db');
    await _bloat();
    final r = await DerivationEngine().compactStorage(
      freeDiskBytes: () async => null,
    );
    expect(r.vacuumed, isFalse);
    expect(r.freeBytes, isNull);
  });

  test('waits for a derive pass in flight instead of running beside it',
      () async {
    await _useFreshDb('compact_latch.db');
    DerivationEngine.debugRunning = true;
    var done = false;
    final f = DerivationEngine()
        .compactStorage(freeDiskBytes: () async => 1 << 40)
        .then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(done, isFalse);
    DerivationEngine.debugRunning = false;
    await f;
    expect(done, isTrue);
  });
}
