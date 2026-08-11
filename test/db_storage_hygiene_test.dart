// Storage hygiene:
//  1. decoded_rr's rr_ts_ms lookups are still index-served after dropping
//     idx_decoded_rr_ts, which was a strict prefix of the (rr_ts_ms,
//     beat_index) unique index and only added write cost.
//  2. Superseded generations of the recomputable per-day intermediates are
//     pruned. They are keyed (day_id, algo_version), so every kAlgoVersion
//     bump wrote a whole new generation beside the old one and nothing
//     removed it.
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

  test('the redundant single-column rr index is gone', () async {
    final db = await LocalDb.instance;
    final idx = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='decoded_rr'",
    )).map((r) => r['name'] as String?).whereType<String>().toList();
    expect(idx, isNot(contains('idx_decoded_rr_ts')));
    expect(idx, contains('idx_decoded_rr_ts_beat_unique'));
  });

  test('an existing duplicate-of-primary-key rr index is dropped on open', () async {
    // idx_decoded_rr_counter(counter, beat_index) duplicated, column for column,
    // the index PRIMARY KEY (counter, beat_index) already creates. Measured on a
    // 3-day fill: both b-trees 3,264,512 bytes — ~1.09 MB/day of pure
    // duplication plus a second b-tree write per beat on the hottest insert
    // path in the app.
    //
    // PLANTED FIRST, then reopened. A fresh database never creates the index
    // any more, so simply asserting it is absent asserts nothing — deleting the
    // DROP leaves the test green. The installs that have the index are the ones
    // that were created before it stopped being written, and the only thing
    // that removes it for them is `_repairOpenSchema` on the next open. That is
    // the path this reproduces.
    var db = await LocalDb.instance;
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_decoded_rr_counter '
      'ON decoded_rr(counter, beat_index)',
    );
    expect(
      await _rrIndexes(db),
      contains('idx_decoded_rr_counter'),
      reason: 'the fixture must actually plant the index',
    );

    await LocalDb.close();
    db = await LocalDb.instance;
    expect(await _rrIndexes(db), isNot(contains('idx_decoded_rr_counter')));
  });

  test('counter lookups are still index-served without it', () async {
    // Dropping an index is only safe if the planner has another. The PK's
    // auto-index covers exactly the same columns in the same order.
    final db = await LocalDb.instance;
    for (final sql in const [
      'EXPLAIN QUERY PLAN SELECT * FROM decoded_rr WHERE counter = 42 '
          'ORDER BY beat_index',
      'EXPLAIN QUERY PLAN SELECT * FROM decoded_rr WHERE counter BETWEEN 1 AND 9',
    ]) {
      final detail = (await db.rawQuery(
        sql,
      )).map((r) => r['detail'].toString()).join(' | ');
      expect(
        detail.toUpperCase(),
        contains('USING'),
        reason: 'planner fell back to a full scan: $detail',
      );
      expect(
        detail,
        contains('sqlite_autoindex_decoded_rr_1'),
        reason: 'expected the primary key auto-index: $detail',
      );
    }
  });

  test('rr_ts_ms range scans are still served by an index', () async {
    final db = await LocalDb.instance;
    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM decoded_rr WHERE rr_ts_ms < 1000 '
      'ORDER BY rr_ts_ms ASC, beat_index ASC',
    );
    final detail = plan.map((r) => r['detail'].toString()).join(' | ');
    expect(
      detail,
      contains('idx_decoded_rr_ts_beat_unique'),
      reason: 'planner fell back to a scan: $detail',
    );
    expect(
      detail.toUpperCase(),
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
    // long gone (raw retention is 3 days) so it can never write a v49/v50
    // row of its own. Two unrelated recent days churn through v49 then v50.
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
}

Future<List<String>> _rrIndexes(Database db) async => (await db.rawQuery(
  "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='decoded_rr'",
)).map((r) => r["name"] as String?).whereType<String>().toList();
