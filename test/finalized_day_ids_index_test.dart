// `finalizedDayIds` reads an indexed `day_result.imported` flag instead of
// scanning every finalized bundle. Only a top-level JSON boolean true is
// imported, for rows written before the column existed (backfill) and after
// (triggers), on every write path.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

const _algo = 7;

/// The expected set, computed in Dart exactly as `LocalDb.isMeasuredDayRow`
/// reads a payload (`p['imported'] == true`). It deliberately shares no code
/// with the SQL expression under test, so the test is a SQL/Dart parity check
/// and not the expression compared with itself.
Future<Set<String>> _dartOracle(Database db) async => {
  for (final r in await db.query(
    'day_result',
    columns: ['day_id', 'payload_json'],
    where: 'algo_version = ? AND finalized = 1',
    whereArgs: [_algo],
  ))
    if (SeriesCodec.decodePayloadJson(r['payload_json'])?['imported'] != true)
      r['day_id'] as String,
};

Future<bool> _indexed(Database db) async => (await db.rawQuery(
  "SELECT 1 FROM sqlite_master WHERE type = 'index' "
  "AND name = 'idx_day_result_finalized_v2'",
)).isNotEmpty;

Future<void> _put(String day, String payload, {bool finalized = true}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: _algo,
      payloadJson: payload,
      windowJson: '{}',
      finalized: finalized,
    );

Future<void> _rawPut(Database db, String day, String payload) async {
  await db.insert('day_result', {
    'day_id': day, 'algo_version': _algo, 'payload_json': payload,
    'window_json': '{}', 'computed_at': 0, 'finalized': 1,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await LocalDb.close();
  });


  // WHY: substring matching confuses nested keys and misses spaced booleans.
  // CLAIM(imported-exact); catches: LIKE, json_extract without a type check.
  test('only a top-level boolean true marks an imported day on every write', () async {
    await _useFreshDb('finalized_shapes.db');
    final db = await LocalDb.instance;
    final shapes = <String, bool>{
      '{}': false,
      '{"imported":true}': true,
      '{"imported":false}': false,
      '{"nested":{"imported":true}}': false,
      jsonEncode({'note': '"imported":true'}): false,
      '{"not_imported":true}': false,
      '{"imported":1}': false,
      '{"imported":"true"}': false,
      '{"imported":null}': false,
      '{ "imported" : true }': true,
      'invalid JSON': false,
    };
    final expected = <String>{};
    var n = 0;
    for (final entry in shapes.entries) {
      final day = '2026-01-${(++n).toString().padLeft(2, '0')}';
      // The table agrees with the Dart reader, so SQL and Dart cannot drift.
      expect(SeriesCodec.decodePayloadJson(entry.key)?['imported'] == true,
          entry.value, reason: 'oracle ${entry.key}');
      await _rawPut(db, day, entry.key);
      if (!entry.value) expected.add(day);
      expect((await db.query('day_result', columns: ['imported'],
        where: 'day_id = ?', whereArgs: [day])).single['imported'],
        entry.value ? 1 : 0, reason: entry.key);
    }
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    // Raw SQL payload rewrites also go through the mirror's update trigger.
    await db.update('day_result', {'payload_json': '{ "imported" : true }'},
      where: 'day_id = ?', whereArgs: ['2026-01-01']);
    expected.remove('2026-01-01');
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    await db.update('day_result', {'payload_json': '{"nested":{"imported":true}}'},
      where: 'day_id = ?', whereArgs: ['2026-01-01']);
    expected.add('2026-01-01');
    expect(await LocalDb.finalizedDayIds(_algo), expected);
  });

  // WHY: schema-62 already has a completed LIKE backfill and triggers. Both
  // upgrade and same-version repair must invalidate that completion marker.
  // CLAIM(imported-exact); catches: replacing only the trigger definitions.
  for (final version in [62, 63]) {
    test('repairs a stale legacy mirror opened at schema $version twice', () async {
      await _useFreshDb('finalized_legacy_$version.db');
      var db = await LocalDb.instance;
      await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_v2_ins');
      await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_v2_upd');
      await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_ins');
      await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_upd');
      await db.execute('DROP INDEX IF EXISTS idx_day_result_finalized_v2');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_day_result_finalized '
        'ON day_result(algo_version, finalized, imported, day_id)');
      for (final suffix in ['ins', 'upd']) {
        await db.execute('CREATE TRIGGER trg_day_result_imported_$suffix '
          'AFTER ${suffix == 'ins' ? 'INSERT' : 'UPDATE OF payload_json'} '
          'ON day_result BEGIN UPDATE day_result '
          "SET imported = (NEW.payload_json LIKE '%\"imported\":true%') "
          'WHERE rowid = NEW.rowid; END');
      }
      await _rawPut(db, '2026-01-01', '{"nested":{"imported":true}}');
      await _rawPut(db, '2026-01-02', '{ "imported" : true }');
      expect((await db.query('day_result', columns: ['imported'],
        orderBy: 'day_id')).map((r) => r['imported']).toList(), [1, 0]);
      await db.setVersion(version);
      for (var open = 0; open < 2; open++) {
        await LocalDb.close();
        expect(await LocalDb.finalizedDayIds(_algo), {'2026-01-01'});
        db = await LocalDb.instance;
        expect((await db.query('day_result', columns: ['imported'],
          orderBy: 'day_id')).map((r) => r['imported']).toList(), [0, 1]);
        expect(await _indexed(db), isTrue);
      }
    });
  }

  // WHY: a refused index build must keep the fallback's classification exact.
  // CLAIM(imported-exact); catches: retaining LIKE only in the fallback path.
  test('failed index creation falls back to the exact top-level key', () async {
    await _useFreshDb('finalized_fallback.db');
    final db = await LocalDb.instance;
    await db.execute('CREATE TABLE idx_day_result_finalized_v2 (id INTEGER)');
    await _rawPut(db, '2026-01-01', '{"nested":{"imported":true}}');
    await _rawPut(db, '2026-01-02', '{ "imported" : true }');
    await _rawPut(db, '2026-01-03', 'invalid JSON');
    expect(await LocalDb.finalizedDayIds(_algo), {'2026-01-01', '2026-01-03'});
    expect(await _indexed(db), isFalse);
    await db.execute('DROP TABLE idx_day_result_finalized_v2');
    expect(await LocalDb.finalizedDayIds(_algo), {'2026-01-01', '2026-01-03'});
    expect(await _indexed(db), isTrue);
  });

  test('same set as the exact scan, through the triggers', () async {
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
    expect(ids, await _dartOracle(db));
  });

  test('backfills rows written before the column existed', () async {
    await _useFreshDb('finalized_ids_backfill.db');
    final db = await LocalDb.instance;
    // Emulate a pre-column database: no triggers, no index, stale flags.
    await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_v2_ins');
    await db.execute('DROP TRIGGER IF EXISTS trg_day_result_imported_v2_upd');
    await db.execute('DROP INDEX IF EXISTS idx_day_result_finalized_v2');
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
    final expected = await _dartOracle(db);
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
      contains('COVERING INDEX idx_day_result_finalized_v2'),
    );
  });

  Future<List<String>> triggers(Database db) async => [
    for (final r in await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND tbl_name = 'day_result' ORDER BY name",
    ))
      r['name'] as String,
  ];

  Future<bool> hasIndex(Database db, String name) async => (await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    [name],
  )).isNotEmpty;

  // WHY: day_result is written by every derive. A trigger body that calls
  // json_valid/json_type cannot compile on a SQLite without JSON1 (the Android
  // framework builds some devices ship), and then EVERY insert fails, so no day
  // could be saved. Without JSON1 the legacy LIKE mirror must stay in place.
  // CLAIM(imported-exact); catches: a JSON1 requirement on the write path.
  test('without JSON1 a fresh database keeps the legacy LIKE mirror', () async {
    LocalDb.debugJsonProbeFails = true;
    addTearDown(() => LocalDb.debugJsonProbeFails = false);
    await _useFreshDb('finalized_no_json1.db');
    final db = await LocalDb.instance;
    expect(await triggers(db),
        ['trg_day_result_imported_ins', 'trg_day_result_imported_upd']);
    for (final r in await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'trigger' "
      "AND tbl_name = 'day_result'",
    )) {
      expect(r['sql'], isNot(contains('json_')), reason: 'no JSON1 in a trigger');
    }
    await _rawPut(db, '2026-01-01', '{"nested":{"imported":true}}');
    await _rawPut(db, '2026-01-02', '{ "imported" : true }');
    // The legacy substring test, kept as it was: nested matches, spaced does not.
    expect((await db.query('day_result', columns: ['imported'],
      orderBy: 'day_id')).map((r) => r['imported']).toList(), [1, 0]);
    expect(await LocalDb.finalizedDayIds(_algo), {'2026-01-02'});
    expect(await hasIndex(db, 'idx_day_result_finalized'), isTrue);
    expect(await hasIndex(db, 'idx_day_result_finalized_v2'), isFalse);
  });

  // WHY: a database file restored from a JSON1 device onto one without JSON1
  // arrives carrying the JSON triggers; they would fail every write there.
  // CLAIM(imported-exact); catches: leaving JSON triggers when JSON1 is absent.
  test('reopening without JSON1 swaps a restored JSON mirror for the LIKE one',
      () async {
    addTearDown(() => LocalDb.debugJsonProbeFails = false);
    await _useFreshDb('finalized_restored_json.db');
    var db = await LocalDb.instance;
    expect(await triggers(db), [
      'trg_day_result_imported_v2_ins',
      'trg_day_result_imported_v2_upd',
    ]);
    await LocalDb.finalizedDayIds(_algo);
    expect(await hasIndex(db, 'idx_day_result_finalized_v2'), isTrue);
    await LocalDb.close();
    LocalDb.debugJsonProbeFails = true;
    db = await LocalDb.instance;
    expect(await triggers(db),
        ['trg_day_result_imported_ins', 'trg_day_result_imported_upd']);
    expect(await hasIndex(db, 'idx_day_result_finalized_v2'), isFalse);
  });
}
