// DB integrity regressions, run against the REAL LocalDb over sqflite_ffi:
//
//  1. decoded_rr REC_TS KEY — a post-reboot rec_ts collision (two counters, one
//     second) keeps exactly the winner's beats; the write path DELETEs the
//     second's beats before reinserting, so a shrinking beat count strands none.
//  2. prune BY REC_TS — pruneDecodedBeforeRecTs deletes decoded_rr by its rec_ts
//     key (no counter subquery, no orphan sweep) and keeps recent beats.
//  3. importFromDbFile FINALIZED protection — a foreign export never overwrites
//     a locally-finalized (day_id, algo_version) day_result row; non-finalized
//     rows keep the merge-REPLACE behavior.
//  4. schema smoke — a fresh onCreate database passes schemaHealth(). (A true
//     old-version fixture upgrade is too brittle to hand-build here; the
//     fresh-create + health assertion is the sanctioned fallback.)

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

Sample _sample(int ts, int counter, List<int> rr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 70,
      rrIntervalsMs: rr,
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'feed$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_integrity_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await databaseFactory.deleteDatabase(p.join(dir, 'foreign_export_test.db'));
  });

  test('fresh schema passes schemaHealth (migration smoke)', () async {
    final health = await LocalDb.schemaHealth();
    expect(health['ok'], isTrue, reason: '$health');
  });

  test('rec_ts collision leaves exactly the winner\'s beats', () async {
    const ts = 1780000000;
    // Two records for the SAME second, different counters (a reboot straddle).
    // THREE beats then TWO. REPLACE on the rec_ts key keeps the newest row; the
    // write path DELETEs the second's beats before reinserting, so no stale
    // high-index beat survives.
    await LocalDb.insertRecord(_raw(ts, 100), _sample(ts, 100, [800, 810, 820]));
    await LocalDb.insertRecord(_raw(ts, 5), _sample(ts, 5, [900, 910]));

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [ts]);
    expect(onehz.length, 1);
    expect(onehz.first['counter'], 5); // newest-wins

    // Only the winner's two beats remain, keyed by rec_ts.
    final beats = await db.query('decoded_rr',
        where: 'rec_ts = ?', whereArgs: [ts], orderBy: 'beat_index ASC');
    expect([for (final b in beats) b['rr_ms']], [900, 910]);

    // Globally: zero orphans (every beat's rec_ts owns a decoded row).
    final orphans = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_rr '
      'WHERE rec_ts NOT IN (SELECT rec_ts FROM decoded_onehz)',
    );
    expect(orphans.first['c'], 0);

    // The RR read path sees ONLY the winner's beats.
    final rr = await LocalDb.decodedRrByRecTsRange(fromRecTs: ts, toRecTs: ts);
    expect([for (final r in rr) r['rr_ms']], [900, 910]);
  });

  // CV-11 ORDERING INVARIANT. The `source` column landed BEFORE the first
  // 0x180D byte, and the derive/baseline read paths filter on it while the
  // answer is still trivially "all of them". Resting HR from a chest strap and
  // from wrist PPG differ systematically; a quiet merge puts a step change into
  // every baseline the app keeps with no visible cause. This test fails the
  // moment `source IS NULL` is dropped from either read.
  test('a non-band source row is excluded from the derive read paths',
      () async {
    const ts = 1781000000;
    await LocalDb.insertRecord(_raw(ts, 700), _sample(ts, 700, [800]));

    final db = await LocalDb.instance;
    // Written straight in: nothing in the app writes a non-NULL source to
    // these tables today, and that is exactly the state the filter guards.
    await db.insert('decoded_onehz', {
      // v47 key — see _createDecodedStore.
      'ts_ms': (ts + 1) * 1000,
      'counter': 701,
      'rec_ts': ts + 1,
      'hr': 155,
      'source': 'Chest strap',
    });
    await db.insert('decoded_rr', {
      'ts_ms': (ts + 1) * 1000,
      'rec_ts': ts + 1,
      'beat_index': 0,
      'rr_ts_ms': (ts + 1) * 1000,
      'rr_ms': 390,
      'source': 'Chest strap',
    });

    final page = await LocalDb.decodedOneHzBatchByRecTsRange(
      limit: 100,
      fromRecTs: ts,
      toRecTs: ts + 1,
    );
    expect([for (final r in page) r['rec_ts']], [ts]);

    final rr = await LocalDb.decodedRrByRecTsRange(
      fromRecTs: ts,
      toRecTs: ts + 1,
    );
    expect([for (final r in rr) r['rr_ms']], [800]);

    // The onboarding/day-walk anchor too — a chest-strap second is not "when
    // your data starts".
    final (_, hi) = await LocalDb.firstAndLastRecordTs();
    expect(hi, isNot(ts + 1));
  });

  test('prune deletes decoded_rr by rec_ts, keeps recent beats', () async {
    const oldTs = 1700000000; // strictly before the cutoff below
    final db = await LocalDb.instance;
    // An old beat (its owning row absent — e.g. a leftover) is still deleted by
    // the plain rec_ts-range prune; no counter subquery, no orphan sweep needed.
    await db.insert('decoded_rr', {
      'ts_ms': oldTs * 1000,
      'rec_ts': oldTs,
      'beat_index': 0,
      'rr_ts_ms': oldTs * 1000,
      'rr_ms': 850,
    });
    // A live (post-cutoff) substrate row + beat that must SURVIVE the prune.
    const keepTs = 1780000500;
    await LocalDb.insertRecord(_raw(keepTs, 7), _sample(keepTs, 7, [700]));

    final deleted = await LocalDb.pruneDecodedBeforeRecTs(oldTs + 1000);

    final old = await db.query('decoded_rr', where: 'rec_ts = ?', whereArgs: [oldTs]);
    expect(old, isEmpty, reason: 'the pruned window\'s beats must be deleted');
    final kept = await db.query('decoded_rr', where: 'rec_ts = ?', whereArgs: [keepTs]);
    expect(kept.length, 1);
    // used to always come back 0 even when rows genuinely got pruned - none
    // of the txn.delete() counts were ever added up.
    expect(deleted, greaterThan(0),
        reason: 'the returned count must reflect the rows actually deleted');
  });

  test('dayResultIds excludes skipped days - a failed derivation must not look "done" to the pruning guard', () async {
    const v = 9001; // scratch version, wont collide with other tests in this file
    await LocalDb.putDayResult(
      dayId: '2026-08-01',
      algoVersion: v,
      payloadJson: '{"real": true}',
      windowJson: '{}',
    );
    await LocalDb.putDayResult(
      dayId: '2026-08-02',
      algoVersion: v,
      payloadJson: '{"skipped": true, "reason": "test threw"}',
      windowJson: '{}',
      skipped: true,
    );

    final ids = await LocalDb.dayResultIds(v);
    expect(ids.contains('2026-08-01'), isTrue,
        reason: 'a real derived day must still count as derived');
    expect(ids.contains('2026-08-02'), isFalse,
        reason: 'a skip-marker day must NOT count as derived - counting it '
            'is exactly the bug that let the pruning guard delete raw data '
            'for a day that never actually finished deriving');
  });

  test('importFromDbFile never overwrites a locally-FINALIZED day_result', () async {
    const v = 30;
    await LocalDb.putDayResult(
      dayId: '2026-07-01',
      algoVersion: v,
      payloadJson: '{"src":"local-finalized"}',
      windowJson: '{}',
      finalized: true,
    );
    await LocalDb.putDayResult(
      dayId: '2026-07-02',
      algoVersion: v,
      payloadJson: '{"src":"local-open"}',
      windowJson: '{}',
      finalized: false,
    );

    // Build a foreign export carrying: a collision with the finalized day, a
    // collision with the open day, and a brand-new day.
    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'foreign_export_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute('''
      CREATE TABLE day_result (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        window_json TEXT NOT NULL DEFAULT '{}',
        computed_at INTEGER NOT NULL,
        finalized INTEGER NOT NULL DEFAULT 0,
        rhr REAL, rmssd REAL, readiness REAL,
        PRIMARY KEY (day_id, algo_version)
      )
    ''');
    for (final day in ['2026-07-01', '2026-07-02', '2026-06-30']) {
      await src.insert('day_result', {
        'day_id': day,
        'algo_version': v,
        'payload_json': '{"src":"foreign"}',
        'window_json': '{}',
        'computed_at': 1,
        'finalized': 1,
      });
    }
    await src.close();

    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['day_result'], 2); // finalized collision skipped

    Future<String> payload(String day) async =>
        (await LocalDb.dayResult(day))!['payload_json'] as String;
    // Locally finalized → protected.
    expect(await payload('2026-07-01'), '{"src":"local-finalized"}');
    // Non-finalized → merge-REPLACE (import wins).
    expect(await payload('2026-07-02'), '{"src":"foreign"}');
    // New day → imported.
    expect(await payload('2026-06-30'), '{"src":"foreign"}');
  });

  test('import keeps a finalized day\'s series + baselines, merges step windows',
      () async {
    // 2026-07-01 is locally finalized (previous test); 2026-07-03 is not.
    await LocalDb.putMetricSeriesValue('2026-07-01', 'readiness', 62);
    await LocalDb.putMetricSeriesValue('2026-07-03', 'readiness', 40);
    await LocalDb.putBaseline('movement_floor', '{"src":"local"}');
    // A 3-night local profile vs a backup's 30: the accumulator with more
    // folded nights survives, finalized history or not.
    String profile(int n) => '{"folded_days":[${[
          for (var i = 0; i < n; i++) '"2026-05-${'${i + 1}'.padLeft(2, '0')}"'
        ].join(',')}]}';
    await LocalDb.putBaseline('sleep_user_profile', profile(3));
    await LocalDb.addLiveCoverage(1782900000, 1782900600, 500, '2026-07-01');

    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'foreign_export_series_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE metric_series (date TEXT, key TEXT, value REAL, '
      'PRIMARY KEY (date, key))',
    );
    await src.execute(
      'CREATE TABLE baselines (key TEXT PRIMARY KEY, payload_json TEXT, '
      'updated_at INTEGER)',
    );
    await src.execute(
      'CREATE TABLE live_coverage (id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'start_ts INTEGER, end_ts INTEGER, steps INTEGER, day TEXT, '
      "source TEXT DEFAULT 'band', device_id TEXT DEFAULT '')",
    );
    for (final d in ['2026-07-01', '2026-07-03']) {
      await src.insert('metric_series', {'date': d, 'key': 'readiness', 'value': 55});
    }
    await src.insert('baselines', {
      'key': 'movement_floor',
      'payload_json': '{"src":"foreign"}',
      'updated_at': 1,
    });
    await src.insert('baselines', {
      'key': 'sleep_user_profile',
      'payload_json': profile(30),
      'updated_at': 1,
    });
    // id 1 collides with the local row's id; the first window is a replay of
    // the local one, the second is new.
    for (final w in [(1782900000, 1782900600), (1782904000, 1782904600)]) {
      await src.insert('live_coverage', {
        'start_ts': w.$1,
        'end_ts': w.$2,
        'steps': 500,
        'day': '2026-07-01',
      });
    }
    await src.close();
    await LocalDb.importFromDbFile(srcPath);
    await databaseFactory.deleteDatabase(srcPath);

    final db = await LocalDb.instance;
    Future<Object?> readiness(String d) async => (await db.query(
          'metric_series',
          where: 'date = ? AND key = ?',
          whereArgs: [d, 'readiness'],
        ))
            .single['value'];
    expect(await readiness('2026-07-01'), 62); // finalized: ours
    expect(await readiness('2026-07-03'), 55); // not finalized: import wins
    expect((await LocalDb.baseline('movement_floor'))!['payload_json'],
        '{"src":"local"}');
    expect((await LocalDb.baseline('sleep_user_profile'))!['payload_json'],
        profile(30));
    final cov = await db.query('live_coverage',
        where: 'day = ?', whereArgs: ['2026-07-01'], orderBy: 'start_ts');
    expect([for (final r in cov) r['start_ts']], [1782900000, 1782904000]);
  });

  test('import keeps a day\'s local phone snapshot, no partial-hour stacking',
      () async {
    // Local already wrote the full 10:00 hour; the backup holds the partial
    // hour it saw mid-sync. Same device, same rank: summing them double counts.
    const h = 1783000800;
    await LocalDb.replacePhoneCoverageForDay('2026-07-02', [
      (startTs: h, endTs: h + 3600, steps: 900),
    ]);

    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'foreign_export_phone_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE live_coverage (id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'start_ts INTEGER, end_ts INTEGER, steps INTEGER, day TEXT, '
      "source TEXT DEFAULT 'band', device_id TEXT DEFAULT '')",
    );
    for (final r in [
      (h, h + 2220, 400, '2026-07-02'),
      (h + 86400, h + 86400 + 3600, 700, '2026-07-04'),
    ]) {
      await src.insert('live_coverage', {
        'start_ts': r.$1,
        'end_ts': r.$2,
        'steps': r.$3,
        'day': r.$4,
        'source': 'phone',
      });
    }
    await src.close();
    await LocalDb.importFromDbFile(srcPath);
    await databaseFactory.deleteDatabase(srcPath);

    final db = await LocalDb.instance;
    Future<List<Object?>> phone(String d) async => [
          for (final r in await db.query('live_coverage',
              where: 'day = ? AND source = ?', whereArgs: [d, 'phone']))
            r['steps'],
        ];
    expect(await phone('2026-07-02'), [900]);
    expect(await phone('2026-07-04'), [700]); // no local snapshot: backup's
  });

  group('sync_ledger real per-chunk rows + sync_quarantine reader', () {
    test('distinct chunk_ids do not collide (the old "capture"-only bug)',
        () async {
      // Previously every call site defaulted to chunk_id='capture', so two
      // different historical batches would overwrite the same row instead of
      // each getting their own history.
      await LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:aa',
        kind: 'historical_batch',
        status: 'acked',
        metaPatch: {'records': 10},
      );
      await LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:bb',
        kind: 'historical_batch',
        status: 'ack_failed',
        lastError: 'ack_write_exhausted',
        metaPatch: {'ack_failures': 2},
      );

      final a = await LocalDb.syncLedgerEntry('batch:aa');
      final b = await LocalDb.syncLedgerEntry('batch:bb');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!['status'], 'acked');
      expect(b!['status'], 'ack_failed');

      final all = await LocalDb.syncLedger();
      expect(
        all.where((r) => r['chunk_id'] == 'batch:aa'
            || r['chunk_id'] == 'batch:bb').length,
        2,
      );
    });

    test('a chunk_id survives repeated updates (persistent failure trail)',
        () async {
      await LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:cc',
        kind: 'historical_batch',
        status: 'ack_failed',
        metaPatch: {'ack_failures': 1},
      );
      await LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:cc',
        kind: 'historical_batch',
        status: 'ack_failed',
        metaPatch: {'ack_failures': 2},
      );
      await LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:cc',
        kind: 'historical_batch',
        status: 'ack_failed',
        metaPatch: {'ack_failures': 3},
      );

      final row = await LocalDb.syncLedgerEntry('batch:cc');
      expect(row, isNotNull);
      // meta_json patches merge (shallow), so the latest failure count wins
      // while created_at is preserved across the updates.
      expect(row!['status'], 'ack_failed');
      final meta = row['meta_json'] as String;
      expect(meta.contains('"ack_failures":3'), isTrue);
    });

    test('quarantined chunks are retrievable (previously write-only)',
        () async {
      await LocalDb.quarantineSyncChunk(
        kind: 'historical_batch',
        payloadJson: '{"token":"deadbeef","ack_failures":3}',
        reason: 'persistent_ack_failure',
      );
      final quarantined = await LocalDb.quarantinedSyncChunks();
      expect(quarantined, isNotEmpty);
      expect(
        quarantined.any((r) => r['reason'] == 'persistent_ack_failure'),
        isTrue,
      );
    });
  });

  group('commitSyncBatch onCheckpoint (per-phase diagnostic logging)', () {
    test('fires all three checkpoints in order on a normal commit', () async {
      const ts = 1790000000;
      final messages = <String>[];
      await LocalDb.commitSyncBatch(
        [_raw(ts, 9001)],
        [_sample(ts, 9001, [800])],
        trimToken: 'deadbeef',
        onCheckpoint: messages.add,
      );
      expect(messages.length, 3);
      expect(messages[0], startsWith('decoded_archive_queued'));
      expect(messages[1], 'decoded_archive_committed');
      expect(messages[2], startsWith('cursor_advanced'));
      expect(messages[2], contains('trim=true'));

      // The commit itself actually happened — checkpoints are observability,
      // not a gate.
      final db = await LocalDb.instance;
      final rows =
          await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [9001]);
      expect(rows, isNotEmpty);
    });

    test('a throwing onCheckpoint callback never aborts the commit', () async {
      const ts = 1790000100;
      var calls = 0;
      await LocalDb.commitSyncBatch(
        [_raw(ts, 9002)],
        [_sample(ts, 9002, [810])],
        onCheckpoint: (_) {
          calls++;
          throw StateError('a misbehaving logger must not break the commit');
        },
      );
      expect(calls, 3); // still fired at every phase despite always throwing

      final db = await LocalDb.instance;
      final rows =
          await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [9002]);
      expect(rows, isNotEmpty); // the commit succeeded regardless
    });

    test('with no onCheckpoint given, nothing is called and commit still works',
        () async {
      const ts = 1790000200;
      await LocalDb.commitSyncBatch(
        [_raw(ts, 9003)],
        [_sample(ts, 9003, [820])],
      );
      final db = await LocalDb.instance;
      final rows =
          await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [9003]);
      expect(rows, isNotEmpty);
    });
  });
}
