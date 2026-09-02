// POWER-LOSS DURABILITY of the ACK-gating commit. `commitSyncBatch` is the one
// commit the safe-trim invariant hangs on: it must be durable (fsynced) BEFORE
// the caller writes the BLE batch-ACK that lets the band trim its flash. The DB
// otherwise runs WAL + synchronous=NORMAL (durable only at a checkpoint), so
// this path raises synchronous=FULL for its single transaction and restores
// NORMAL afterward — leaving every other (recomputable) path fast. This test
// pins that bracket: FULL is set around the commit, NORMAL is restored after,
// AND the restore still happens when the commit THROWS (a leaked FULL would
// fsync every subsequent write on the connection forever).
//
// We spy the real SQL stream via SqfliteDatabaseFactoryLogger (synchronous is
// per-connection and invisible from a second connection, so the log is the only
// honest observation point) and also read `PRAGMA synchronous` on LocalDb's own
// connection — the same one commitSyncBatch uses — to confirm the resting value.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  // Every `synchronous=…` statement executed on any connection, in order.
  final syncStmts = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    // ignore: experimental_member_use — stable enough to spy SQL in a test.
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        log: (event) {
          if (event is SqfliteLoggerSqlEvent) {
            final sql = event.sql.toLowerCase();
            if (sql.contains('pragma synchronous=')) syncStmts.add(sql);
          }
        },
      ),
    );
    LocalDb.dbName = 'openstrap_ack_sync_full_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    // Force the open now so its onConfigure PRAGMAs aren't counted in per-test
    // windows — each test clears syncStmts against an already-open connection.
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<int> restingSynchronous() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery('PRAGMA synchronous');
    return rows.first.values.first as int; // FULL=2, NORMAL=1
  }

  RawRecord recAt(int counter) => RawRecord(
        counter: counter,
        packetType: 0x2F,
        hex: '2f18aabbccdd',
        capturedAt: 1750000000000 + counter,
        recTs: 1750000000 + counter,
      );

  test('commitSyncBatch brackets synchronous=FULL and restores NORMAL', () async {
    expect(await restingSynchronous(), 1, reason: 'connection opens at NORMAL');

    syncStmts.clear();
    await LocalDb.commitSyncBatch(
      [recAt(5001)],
      <Sample?>[Sample(tsEpoch: 1750005001, counter: 5001, hr: 60)],
      trimToken: 'deadbeef',
    );

    expect(syncStmts, ['pragma synchronous=full', 'pragma synchronous=normal'],
        reason: 'FULL is set before the commit and NORMAL restored right after');
    expect(await restingSynchronous(), 1, reason: 'connection left at NORMAL');
  });

  test('synchronous is restored to NORMAL even when the commit throws', () async {
    syncStmts.clear();
    // raws non-empty but samples empty → samples[i] throws RangeError INSIDE the
    // db.transaction, after FULL is set. The finally must still restore NORMAL.
    await expectLater(
      LocalDb.commitSyncBatch([recAt(6001)], const <Sample?>[]),
      throwsA(isA<RangeError>()),
    );

    expect(syncStmts, ['pragma synchronous=full', 'pragma synchronous=normal'],
        reason: 'a thrown commit must not leak FULL');
    expect(await restingSynchronous(), 1,
        reason: 'FULL did not leak past the throwing commit');
  });

  test('two overlapping commits do not interleave their FULL/NORMAL brackets',
      () async {
    // Same deviceId (primary) on purpose: as of this commit db.dart's
    // deviceId StateError still refuses a non-primary caller (that refusal
    // is deleted in the very next commit of this milestone, per
    // spec-m0-m2.md §3's strict ordering), so a genuinely second DEVICE isn't
    // reachable here yet. The mutex itself doesn't look at deviceId — it
    // serialises ANY two overlapping commitSyncBatch calls on this
    // connection — so two primary commits already exercise the property this
    // test exists for.
    syncStmts.clear();
    await Future.wait([
      LocalDb.commitSyncBatch([recAt(7001)], <Sample?>[
        Sample(tsEpoch: 1750007001, counter: 7001, hr: 60),
      ], trimToken: 'aa'),
      LocalDb.commitSyncBatch([recAt(7002)], <Sample?>[
        Sample(tsEpoch: 1750007002, counter: 7002, hr: 61),
      ], trimToken: 'bb'),
    ]);
    // Serialised: one complete bracket, then the next. NOT
    // [full, full, normal, normal], which is the interleave that silently
    // downgrades the first commit while its transaction is still open.
    expect(syncStmts, [
      'pragma synchronous=full',
      'pragma synchronous=normal',
      'pragma synchronous=full',
      'pragma synchronous=normal',
    ]);
    expect(await restingSynchronous(), 1);
  });
}
