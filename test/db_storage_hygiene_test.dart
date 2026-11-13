// Storage hygiene:
//  1. decoded_rr is keyed (device_id, ts_ms, beat_index) since v47, so the
//     rec_ts-range derive read is served by ONE secondary index on
//     (rec_ts, beat_index) — seek, not scan, and no sort.
//  2. Superseded generations of the recomputable per-day intermediates are
//     pruned. They are keyed (day_id, algo_version), so every kAlgoVersion
//     bump wrote a whole new generation beside the old one and nothing
//     removed it.
//  3. A VACUUM does not leave the -wal the size of the whole database: in WAL
//     mode it writes every page through the -wal, and without a size limit
//     the file is reused but never shrunk, doubling what the app holds.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_storage_hygiene_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('decoded_rr carries exactly ONE secondary index', () async {
    final db = await LocalDb.instance;
    final idx = await _rrIndexes(db);
    // Since v47 the key is (device_id, ts_ms, beat_index), so the PK auto-index
    // no longer starts with rec_ts and CANNOT serve the derive read path. One
    // index on (rec_ts, beat_index) buys it back — and it is the ONLY one this
    // hot insert path may carry.
    expect(
      idx.where((n) => !n.startsWith('sqlite_autoindex')),
      ['idx_decoded_rr_rects'],
      reason: 'unexpected secondary index on decoded_rr: $idx',
    );
  });

  test('rec_ts-range reads on decoded_rr seek, and sort from the index',
      () async {
    // decoded_rr still shares its RANGE key with decoded_onehz, so the derive
    // read path (decodedRrByRecTsRange) is an index range scan — never a
    // full-table read, and never a sort.
    final db = await LocalDb.instance;
    final detail = (await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM decoded_rr WHERE rec_ts BETWEEN 1 AND 9 '
      'ORDER BY rec_ts ASC, beat_index ASC',
    )).map((r) => r['detail'].toString()).join(' | ');
    // Assert the SHAPE of the plan, not its wording. `sqlite_autoindex_
    // decoded_rr_1` is an internal name SQLite is free to change, and the
    // property under test is only "seek, don't scan, and don't sort" — which
    // SEARCH + no temp b-tree says on every version.
    final plan = detail.toUpperCase();
    expect(
      plan,
      contains('SEARCH'),
      reason: 'planner fell back to a full scan: $detail',
    );
    expect(
      plan,
      isNot(contains('USE TEMP B-TREE')),
      reason: 'ordering should come from the index: $detail',
    );
  });

  test(
    'superseded intermediate generations are pruned, recent ones kept',
    () async {
      final db = await LocalDb.instance;
      for (final table in const [
        'sleep_session_candidates',
        'wake_day_features',
      ]) {
        for (final v in const [48, 49, 50]) {
          for (final day in const ['2026-07-01', '2026-07-02']) {
            await db.insert(table, {
              'day_id': day,
              'algo_version': v,
              'payload_json': '{}',
              'computed_at': 0,
            });
          }
        }
      }

      final deleted = await LocalDb.pruneSupersededIntermediates();
      expect(deleted, 4, reason: 'two days x v48, in both tables');

      for (final table in const [
        'sleep_session_candidates',
        'wake_day_features',
      ]) {
        final left = (await db.rawQuery(
          'SELECT DISTINCT algo_version FROM $table ORDER BY algo_version',
        )).map((r) => r['algo_version'] as int).toList();
        expect(left, [49, 50], reason: '$table keeps current + previous');
      }
    },
  );

  test('pruning is a no-op when there is nothing superseded', () async {
    expect(await LocalDb.pruneSupersededIntermediates(), 0);
  });

  test('a day stuck on an old version (raw aged out, never re-derived) is not '
      'orphaned just because OTHER days reached newer versions', () async {
    final db = await LocalDb.instance;
    // '2026-06-01' only ever got derived once, at v48 — its raw substrate is
    // long gone (raw retention is `rawRetentionDays`) so it can never write a
    // v49/v50 row of its own. Two unrelated recent days churn through v49 then
    // v50.
    await db.insert('sleep_session_candidates', {
      'day_id': '2026-06-01',
      'algo_version': 48,
      'payload_json': '{"stale":true}',
      'computed_at': 0,
    });
    for (final v in const [49, 50]) {
      for (final day in const ['2026-07-28', '2026-07-29']) {
        await db.insert('sleep_session_candidates', {
          'day_id': day,
          'algo_version': v,
          'payload_json': '{}',
          'computed_at': 0,
        });
      }
    }

    await LocalDb.pruneSupersededIntermediates();

    final stale = await LocalDb.sleepSessionCandidate('2026-06-01', 48);
    expect(
      stale,
      isNotNull,
      reason:
          'a table-wide "keep the 2 highest versions present anywhere" '
          'cutoff would delete this the moment two OTHER days reach v49/50 '
          '— it must be scoped per day_id instead',
    );
    expect(stale!['payload_json'], '{"stale":true}');

    // The recent days still get their own per-day retention (49/50 kept,
    // nothing older present to prune here).
    final recent = (await db.rawQuery(
      "SELECT DISTINCT algo_version FROM sleep_session_candidates "
      "WHERE day_id = '2026-07-28' ORDER BY algo_version",
    )).map((r) => r['algo_version'] as int).toList();
    expect(recent, [49, 50]);
  });

  test('the -wal is size-limited, so a VACUUM does not leave it the size of '
      'the database', () async {
    final db = await LocalDb.instance;
    final limit =
        (await db.rawQuery('PRAGMA journal_size_limit')).first.values.first;
    expect(limit, LocalDb.walSizeLimitBytes);

    // 48 MB to keep and 16 MB to free: the VACUUM then writes ~48 MB of pages
    // through the -wal, more than the limit.
    await db.execute('CREATE TABLE wal_probe (b BLOB)');
    for (var i = 0; i < 64; i++) {
      await db.rawInsert('INSERT INTO wal_probe VALUES (randomblob(1048576))');
    }
    await db.delete('wal_probe', where: 'rowid > 48');
    expect(await LocalDb.vacuumIfBloated(minFreeBytes: 1), greaterThan(0));

    final wal = File(
      p.join(await databaseFactory.getDatabasesPath(), '${LocalDb.dbName}-wal'),
    );
    final walBytes = wal.existsSync() ? wal.lengthSync() : 0;
    expect(walBytes, lessThanOrEqualTo(LocalDb.walSizeLimitBytes),
        reason: 'the -wal kept ${walBytes >> 20} MB after the VACUUM');
    await db.execute('DROP TABLE wal_probe');
  });
}

Future<List<String>> _rrIndexes(Database db) async => (await db.rawQuery(
  "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='decoded_rr'",
)).map((r) => r["name"] as String?).whereType<String>().toList();
