// `finalizedDayIds` reads an indexed `day_result.imported` flag instead of
// LIKE-scanning every finalized bundle. The answer must be the same set the
// scan gave, for rows written before the column existed (backfill) and after
// (triggers), on every write path.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

const _algo = 7;

Future<Set<String>> _likeScan(Database db) async => {
  for (final r in await db.query(
    'day_result',
    columns: ['day_id'],
    where:
        'algo_version = ? AND finalized = 1 '
        "AND payload_json NOT LIKE '%\"imported\":true%'",
    whereArgs: [_algo],
  ))
    r['day_id'] as String,
};

Future<bool> _indexed(Database db) async => (await db.rawQuery(
  "SELECT 1 FROM sqlite_master WHERE type = 'index' "
  "AND name = 'idx_day_result_finalized'",
)).isNotEmpty;

Future<void> _put(String day, String payload, {bool finalized = true}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: _algo,
      payloadJson: payload,
      windowJson: '{}',
      finalized: finalized,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await LocalDb.close();
  });

  test('same set as the LIKE scan, through the triggers', () async {
    await _useFreshDb('finalized_ids_triggers.db');
    await _put('2026-01-01', '{"scalars":{}}');
    await _put('2026-01-02', '{"imported":true,"source":"whoop_export"}');
    await _put('2026-01-03', '{"scalars":{}}', finalized: false);
    await _put('2026-01-04', '{"imported":false}');
    final db = await LocalDb.instance;
    expect(await LocalDb.finalizedDayIds(_algo), {'2026-01-01', '2026-01-04'});
    expect(await _indexed(db), isTrue);

    // A measured re-derive replacing the import, and an import replacing a
    // measured row, both flip the flag.
    await _put('2026-01-02', '{"scalars":{"rhr":50}}');
    await _put('2026-01-04', '{"imported":true}');
    // A raw payload rewrite (the shape `_scrubImportedSkinTempZ` uses).
    await db.rawUpdate(
      "UPDATE day_result SET payload_json = '{\"imported\":true}' "
      "WHERE day_id = '2026-01-01'",
    );
    final ids = await LocalDb.finalizedDayIds(_algo);
    expect(ids, {'2026-01-02'});
    expect(ids, await _likeScan(db));
  });

  test('backfills rows written before the column existed', () async {
    await _useFreshDb('finalized_ids_backfill.db');
    final db = await LocalDb.instance;
    // Emulate a pre-column database: no triggers, no index, stale flags.
    await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_ins');
    await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_upd');
    await db.execute('DROP INDEX IF EXISTS idx_day_result_finalized');
    for (var i = 0; i < 450; i++) {
      final day =
          '2025-${(1 + i ~/ 28).toString().padLeft(2, '0')}-'
          '${(1 + i % 28).toString().padLeft(2, '0')}';
      await db.insert('day_result', {
        'day_id': day,
        'algo_version': _algo,
        'payload_json': i % 3 == 0 ? '{"imported":true}' : '{"x":$i}',
        'window_json': '{}',
        'computed_at': 0,
        'finalized': i % 5 == 0 ? 0 : 1,
        // Deliberately wrong, so only a real backfill passes.
        'imported': i % 3 == 0 ? 0 : 1,
      });
    }
    final expected = await _likeScan(db);
    expect(expected, isNotEmpty);
    // Reopen: the repair pass restores the triggers, the first read backfills.
    await LocalDb.close();
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    final reopened = await LocalDb.instance;
    expect(await _indexed(reopened), isTrue);
    final plan = await reopened.rawQuery(
      'EXPLAIN QUERY PLAN SELECT day_id FROM day_result '
      'WHERE algo_version = ? AND finalized = 1 AND imported = 0',
      [_algo],
    );
    expect(
      plan.map((r) => '${r['detail']}').join(' '),
      contains('COVERING INDEX idx_day_result_finalized'),
    );
  });
}
