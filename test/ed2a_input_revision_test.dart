import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
// ED-2a E4 RED contract. Run with flutter test --concurrency=1.
// Only the input portion of fork 561f2838 and generation portions of
// 74c0b37b/30cd944e apply. No store_rev, row_rev, scheduler or checkpoints.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/models.dart';

const _inputs = ['decoded_onehz', 'decoded_rr'];
final _midnight = DateTime(2026, 10, 20);
final _lo = _midnight.millisecondsSinceEpoch ~/ 1000;
final _day = dayLabelOf(_midnight);

Map<String, Object?> _row(String table, int ts, {String device = ''}) => {
  'device_id': device, 'ts_ms': ts * 1000, 'rec_ts': ts,
  if (table == 'decoded_onehz') ...{'counter': 1, 'hr': 61},
  if (table == 'decoded_rr') ...{
    'beat_index': 0, 'rr_ts_ms': ts * 1000, 'rr_ms': 850,
  },
};

Future<bool> _hasRevisions(Database db) async => (await db.rawQuery(
  "SELECT 1 FROM sqlite_master WHERE type='table' AND name='input_rev'",
)).isNotEmpty;

// Missing infrastructure is revision zero, so mutation tests fail an assertion
// about an unchanged revision, never a spurious 'no such table' exception.
Future<int> _rev(Database db, int ts) async {
  if (!await _hasRevisions(db)) return 0;
  final rows = await db.query('input_rev', columns: ['rev'],
      where: 'bucket = ?', whereArgs: [ts ~/ 900]);
  return rows.isEmpty ? 0 : (rows.single['rev'] as num).toInt();
}

Future<List<Map<String, Object?>>> _revisionRows(Database db) async =>
    await _hasRevisions(db) ? db.query('input_rev', orderBy: 'bucket') : [];

Future<List<Map<String, Object?>>> _legacyFingerprint(Database db) =>
    db.rawQuery('SELECT MAX(rec_ts) AS mx, COUNT(*) AS n FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts < ?', [_lo, _lo + 7200]);

Future<Map<String, Object?>> _schema(Database db) async {
  final out = <String, Object?>{};
  final entries = await db.rawQuery(
    "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
    "AND name != 'android_metadata' ORDER BY type, name",
  );
  for (final entry in entries) {
    final name = entry['name'] as String;
    // Compare column definitions rather than CREATE text: ALTER and CREATE
    // paths have different whitespace and IF NOT EXISTS spelling.
    out[name] = entry['type'] == 'table'
        ? await db.rawQuery('PRAGMA table_info("$name")')
        : (entry['sql'] as String?)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String livePath;
  late String sourcePath;
  late DatabaseFactory? previousFactory;
  late String previousName;
  final sql = <String>[];
  final legacyRows = <String, Object?>{};
  final legacyColumns = <String, Object?>{};

  setUp(() async {
    sqfliteFfiInit();
    previousFactory = databaseFactoryOrNull;
    previousName = LocalDb.dbName;
    await LocalDb.close();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('ed2a_rev_');
    livePath = p.join(tmp.path, 'live.db');
    sourcePath = p.join(tmp.path, 'source.db');
    // Public sqflite logger observes actual SQL, including nested batches.
    // ignore: experimental_member_use
    databaseFactoryOrNull = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
        options: SqfliteLoggerOptions(
          type: SqfliteDatabaseFactoryLoggerType.invoke,
          log: (event) {
            if (event is! SqfliteLoggerInvokeEvent) return;
            void collect(Object? value) {
              if (value is Map) {
                if (value['sql'] case final String statement) sql.add(statement);
                for (final v in value.values) { collect(v); }
              } else if (value is List) {
                for (final v in value) { collect(v); }
              }
            }
            collect(event.arguments);
          },
        ));
    LocalDb.dbName = livePath;
    LocalDb.lastRebuild = null;
    sql.clear();
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(livePath);
    await databaseFactory.deleteDatabase(sourcePath);
    databaseFactoryOrNull = previousFactory;
    LocalDb.dbName = previousName;
    await tmp.delete(recursive: true);
  });

  Future<Database> open() async {
    final db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull,
        reason: 'a broken rung must not pass by quarantining the original DB');
    return db;
  }

  Future<void> seed58() async {
    final db = await databaseFactory.openDatabase(livePath,
        options: OpenDatabaseOptions(version: 58));
    // Frozen v58 decoded DDL is below. Other tables use the existing repair
    // seam; remove E4 infrastructure before setting the old version and seeding.
    for (final ddl in _v58DecodedDdl) { await db.execute(ddl); }
    await LocalDb.repairOpenSchemaForTest(db);
    final triggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='trigger' "
      "AND tbl_name IN ('decoded_onehz','decoded_rr')",
    );
    for (final t in triggers) { await db.execute('DROP TRIGGER "${t['name']}"'); }
    await db.execute('DROP TABLE IF EXISTS input_rev');
    await db.setVersion(58);
    await db.insert('decoded_onehz', _row('decoded_onehz', _lo + 3));
    await db.insert('decoded_rr', _row('decoded_rr', _lo + 3));
    for (final table in _inputs) {
      legacyRows[table] = await db.query(table);
      legacyColumns[table] = await db.rawQuery('PRAGMA table_info($table)');
    }
    await db.close();
  }

  test('every table is classified for restore and diagnostic slices', () async {
    await open();
    final tables = await LocalDb.tableNames();
    expect(tables.toSet().difference(kRestoreClassification.keys.toSet()), isEmpty);
    expect(tables.toSet().difference(kSliceTables.keys.toSet()), isEmpty);
    expect(kRestoreClassification['input_rev'], RestoreClass.rebuildable);
    expect(LocalDb.restoreTablesForTest, isNot(contains('input_rev')));
  });

  test('rung 59 is reserved for additive input revisions', () async {
    expect(LocalDb.schemaVersion, 60, reason: 'rung 60 follows the additive revisions at 59');
    final db = await open();
    expect(await db.getVersion(), LocalDb.schemaVersion);
    expect(await _hasRevisions(db), isTrue);
    final tables = await LocalDb.tableNames();
    expect(tables, isNot(contains('store_rev')));
    expect(tables, isNot(contains('row_rev')));
  });

  test('58 to 59 preserves raw rows and creates all mutation triggers', () async {
    await seed58();
    final db = await open();
    expect((await db.query('decoded_onehz')).single['hr'], 61);
    expect((await db.query('decoded_rr')).single['rr_ms'], 850);
    for (final table in _inputs) {
      expect(await db.query(table), legacyRows[table], reason: '$table data unchanged');
      expect(await db.rawQuery('PRAGMA table_info($table)'), legacyColumns[table],
          reason: 'rung 59 must not change raw columns/defaults');
    }
    expect(await db.getVersion(), LocalDb.schemaVersion);
    expect(await _hasRevisions(db), isTrue);
    final triggers = await db.rawQuery(
      "SELECT tbl_name, sql FROM sqlite_master WHERE type='trigger'",
    );
    for (final table in _inputs) {
      final body = triggers.where((t) => t['tbl_name'] == table)
          .map((t) => (t['sql'] as String).toUpperCase()).join('\n');
      for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
        expect(body, contains('AFTER $op'), reason: '$table $op revision trigger');
      }
    }
    expect(await _revisionRows(db), isEmpty,
        reason: 'legacy rows must not be backfilled into input_rev');
    expect(await LocalDb.inputDayFingerprint(_day),
        (revisionSum: 0, revisionMax: 0, generation: LocalDb.storeGeneration));
  });

  test('upgrade and every-open repair do not scan or rewrite raw input', () async {
    await seed58();
    sql.clear();
    final db = await open();
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.close();
    await open();
    final openingSql = List<String>.of(sql);
    expect(openingSql, isNotEmpty, reason: 'SQL observation must be active');
    final dataAccess = RegExp(
      r'\b(?:FROM|JOIN|UPDATE|INTO|DELETE\s+FROM)\s+["`\[]?'
      r'(?:decoded_onehz|decoded_rr|samples|raw_archive)\b',
      caseSensitive: false,
    );
    expect(openingSql.where((s) {
      final ddl = s.trimLeft().toUpperCase();
      // Declaring a trigger/view does not execute its SELECT/UPDATE body.
      if (ddl.startsWith('CREATE TRIGGER') || ddl.startsWith('CREATE VIEW')) return false;
      // Main probes whether legacy decoded input exists before metadata repair.
      // This bounded probe is unrelated to revision creation or backfill.
      if (s == 'SELECT 1 FROM decoded_onehz LIMIT 1') return false;
      return dataAccess.hasMatch(s);
    }),
        isEmpty, reason: 'opening may inspect schema, never scan/backfill raw rows');
    expect(await _revisionRows(await LocalDb.instance), isEmpty);
  });

  test('fresh and upgraded schema agree; repair and reopen are idempotent', () async {
    await seed58();
    var db = await open();
    expect(await _hasRevisions(db), isTrue, reason: 'input_rev must exist first');
    await db.insert('decoded_onehz', _row('decoded_onehz', _lo + 100));
    final schema = await _schema(db);
    final revs = await _revisionRows(db);
    final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.close();
    db = await open();
    expect(await _schema(db), schema);
    expect(await _revisionRows(db), revs);
    expect(await db.query('decoded_onehz', orderBy: 'rec_ts'), rows);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(livePath);
    db = await open();
    expect(await _schema(db), schema, reason: 'onCreate and onUpgrade must agree');
  });

  test('absent day and legacy bucket revisions read zero', () async {
    await seed58();
    await open();
    for (final day in [_day, '1999-01-01']) {
      expect(await LocalDb.inputDayFingerprint(day),
          (revisionSum: 0, revisionMax: 0, generation: LocalDb.storeGeneration));
    }
  });

  for (final table in _inputs) {
    for (final op in ['INSERT', 'REPLACE', 'UPDATE', 'DELETE']) {
      test('$table $op advances only its 15-minute bucket', () async {
        final db = await open();
        final ts = _lo + 930;
        if (op != 'INSERT') { await db.insert(table, _row(table, ts)); }
        final before = await _rev(db, ts);
        final adjacent = await _rev(db, ts - 900);
        switch (op) {
          case 'INSERT': await db.insert(table, _row(table, ts));
          case 'REPLACE':
            // Identical values still invalidate; repeat to catch revision reset
            // under the outer statement's OR REPLACE conflict policy.
            for (var i = 0; i < 3; i++) {
              final last = await _rev(db, ts);
              await db.insert(table, _row(table, ts),
                  conflictAlgorithm: ConflictAlgorithm.replace);
              expect(await _rev(db, ts), greaterThan(last),
                  reason: '$table identical REPLACE must never reset the bucket');
            }
          case 'UPDATE':
            await db.update(table, table == 'decoded_onehz' ? {'hr': 62} : {'rr_ms': 900});
          case 'DELETE': await db.delete(table);
        }
        expect(await _rev(db, ts), greaterThan(before), reason: '$table $op was invisible');
        expect(await _rev(db, ts - 900), adjacent, reason: 'unrelated bucket changed');
      });
    }

    test('$table timestamp UPDATE invalidates both old and new buckets', () async {
      final db = await open();
      final ts = _lo + 899;
      await db.insert(table, _row(table, ts));
      final old = await _rev(db, ts), next = await _rev(db, ts + 1);
      await db.update(table, {'rec_ts': ts + 1, 'ts_ms': (ts + 1) * 1000});
      expect(await _rev(db, ts), greaterThan(old), reason: 'old window lost a row');
      expect(await _rev(db, ts + 1), greaterThan(next), reason: 'new window gained a row');
    });

    test('$table invalid timestamps do not create revision buckets', () async {
      final db = await open();
      for (final ts in [0, -1]) { await db.insert(table, _row(table, ts)); }
      expect(await _revisionRows(db), isEmpty);
    });
  }

  test('identical newest-wins replacement defeats MAX/count but moves revision', () async {
    final db = await open();
    final row = _row('decoded_onehz', _lo + 10);
    await db.insert('decoded_onehz', row);
    final old = await _legacyFingerprint(db);
    final before = await LocalDb.inputDayFingerprint(_day);
    await db.insert('decoded_onehz', row, conflictAlgorithm: ConflictAlgorithm.replace);
    expect(await _legacyFingerprint(db), old, reason: 'MAX/count blind spot reproduced');
    expect((await db.query('decoded_onehz')).length, 1);
    expect((await LocalDb.inputDayFingerprint(_day)).revisionSum,
        greaterThan(before.revisionSum), reason: 'identical REPLACE must invalidate cached input');
  });

  test('late RR without any 1 Hz row changes the day fingerprint', () async {
    final db = await open();
    final before = await LocalDb.inputDayFingerprint(_day);
    await db.insert('decoded_rr', _row('decoded_rr', _lo + 20));
    expect(await db.query('decoded_onehz'), isEmpty);
    expect((await LocalDb.inputDayFingerprint(_day)).revisionSum,
        greaterThan(before.revisionSum), reason: 'RR-only inputs must not require MAX(rec_ts)');
  });

  for (final date in [DateTime(2026, 10, 20), DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    test('fingerprint sums/maxes local day buckets for ${dayLabelOf(date)}', () async {
      final db = await open();
      final lo = date.millisecondsSinceEpoch ~/ 1000;
      final hi = DateTime(date.year, date.month, date.day + 1).millisecondsSinceEpoch ~/ 1000;
      // Unequal bucket revisions pin SUM and MAX independently. Outside rows
      // must not contribute, including precisely the following midnight.
      for (final ts in [lo - 1, lo, lo + 900, hi - 1, hi]) {
        await db.insert('decoded_onehz', _row('decoded_onehz', ts));
      }
      await db.update('decoded_onehz', {'hr': 63}, where: 'rec_ts = ?', whereArgs: [lo]);
      final fp = await LocalDb.inputDayFingerprint(dayLabelOf(date));
      expect(fp.revisionSum, 4, reason: 'two writes in first bucket, one in each of two others');
      expect(fp.revisionMax, 2);
      expect(fp.generation, LocalDb.storeGeneration);
      expect(await LocalDb.inputDayFingerprint(dayLabelOf(date)), fp,
          reason: 'reading the fingerprint must be idempotent');
    });
  }

  test('rolled-back raw writes roll back revisions as well', () async {
    final db = await open();
    final before = await LocalDb.inputDayFingerprint(_day);
    await expectLater(db.transaction((txn) async {
      await txn.insert('decoded_onehz', _row('decoded_onehz', _lo + 10));
      await txn.insert('decoded_rr', _row('decoded_rr', _lo + 10));
      throw StateError('abort before commit');
    }), throwsStateError);
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(await _revisionRows(db), isEmpty);
    expect(await LocalDb.inputDayFingerprint(_day), before);
  });

  test('reopen advances generation without changing input revisions', () async {
    var db = await open();
    await db.insert('decoded_onehz', _row('decoded_onehz', _lo + 10));
    final before = await LocalDb.inputDayFingerprint(_day);
    await LocalDb.close();
    db = await open();
    final after = await LocalDb.inputDayFingerprint(_day);
    expect(after.revisionSum, before.revisionSum);
    expect(after.revisionMax, before.revisionMax);
    expect(after.generation, greaterThan(before.generation));
    expect(await db.query('decoded_onehz'), hasLength(1));
  });

  test('wipe increments generation even when the revision key returns to zero', () async {
    final db = await open();
    final before = LocalDb.storeGeneration;
    final emptyKey = await LocalDb.inputDayFingerprint(_day);
    await db.insert('decoded_onehz', _row('decoded_onehz', _lo + 10));
    await LocalDb.wipeAll();
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(await db.query('input_rev'), isEmpty);
    expect(LocalDb.storeGeneration, greaterThan(before));
    expect(await LocalDb.inputDayFingerprint(_day), isNot(emptyKey),
        reason: '(day, revision, generation) must reject a pre-wipe cache entry');
  });

  Future<void> source({bool failAfterCommit = false}) async {
    final src = await databaseFactory.openDatabase(sourcePath);
    // A valid replacement in an EARLY table, followed by a destination failure
    // in a later table. This drives the public importer, not a test-only merge.
    await src.execute('CREATE TABLE journal (date TEXT PRIMARY KEY, '
        "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)");
    await src.insert('journal', {'date': _day, 'note': 'replacement', 'updated_at': 2});
    if (failAfterCommit) {
      await src.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
      await src.insert('baselines', {'key': 'missing-required-payload'});
    }
    await src.close();
  }

  for (final partial in [false, true]) {
    test('${partial ? 'partial failing' : 'successful replacement'} import advances generation', () async {
      final db = await open();
      await db.insert('journal', {'date': _day, 'note': 'old', 'updated_at': 1});
      await source(failAfterCommit: partial);
      final before = LocalDb.storeGeneration;
      final key = await LocalDb.inputDayFingerprint(_day);
      if (partial) {
        await expectLater(LocalDb.importFromDbFile(sourcePath), throwsA(isA<DatabaseException>()));
      } else {
        await LocalDb.importFromDbFile(sourcePath);
      }
      expect((await db.query('journal')).single['note'], 'replacement',
          reason: 'prove a page committed before checking invalidation');
      expect(LocalDb.storeGeneration, greaterThan(before),
          reason: 'every exit after durable replacement must invalidate caches');
      expect(await LocalDb.inputDayFingerprint(_day), isNot(key));
    });
  }

  for (final mode in ['success', 'later failure', 'first failure']) {
    test('bulk restore $mode invalidates only after a durable page', () async {
      final db = await open();
      final src = await databaseFactory.openDatabase(sourcePath);
      await src.execute(_v58DecodedDdl.first);
      await src.insert('decoded_onehz', _row('decoded_onehz', _lo + 10));
      if (mode == 'later failure') {
        await src.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
        await src.insert('baselines', {'key': 'missing-required-payload'});
      }
      await src.close();
      if (mode == 'first failure') {
        await db.execute("CREATE TRIGGER refuse_decoded BEFORE INSERT ON decoded_onehz "
            "BEGIN SELECT RAISE(ABORT, 'test bulk first-page failure'); END");
      }
      final generation = LocalDb.storeGeneration;
      if (mode == 'success') {
        await LocalDb.importFromDbFile(sourcePath);
      } else {
        await expectLater(LocalDb.importFromDbFile(sourcePath),
            throwsA(isA<DatabaseException>()));
      }
      expect(await db.query('decoded_onehz'),
          hasLength(mode == 'first failure' ? 0 : 1));
      expect(LocalDb.storeGeneration,
          mode == 'first failure' ? generation : greaterThan(generation));
    });
  }

  for (final mode in ['success', 'later table failure',
      'later archive-page failure', 'first failure']) {
    test('archive-only restore $mode tracks durable pages', () async {
      final db = await open();
      final src = await databaseFactory.openDatabase(sourcePath);
      await src.execute('CREATE TABLE raw_archive (hex TEXT PRIMARY KEY, '
          'counter INTEGER, packet_type INTEGER, rec_ts INTEGER, '
          'captured_at INTEGER, reason TEXT)');
      final sourceRows = mode == 'later archive-page failure' ? 501 : 1;
      final batch = src.batch();
      for (var i = 1; i <= sourceRows; i++) {
        batch.insert('raw_archive', {'hex': i.toRadixString(16).padLeft(4, '0'),
          'counter': i, 'packet_type': 0, 'rec_ts': _lo,
          'captured_at': _lo * 1000, 'reason': 'test_archive'});
      }
      await batch.commit(noResult: true);
      if (mode == 'later table failure') {
        await src.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
        await src.insert('baselines', {'key': 'missing-required-payload'});
      }
      await src.close();
      if (mode == 'first failure' || mode == 'later archive-page failure') {
        final rejected = mode == 'first failure' ? 1 : 501;
        await db.execute('CREATE TRIGGER refuse_archive BEFORE INSERT ON '
            '${LocalDb.rawArchiveTable} WHEN NEW.counter = $rejected '
            "BEGIN SELECT RAISE(ABORT, 'test archive page failure'); END");
      }
      final generation = LocalDb.storeGeneration;
      if (mode == 'success') {
        await LocalDb.importFromDbFile(sourcePath);
      } else {
        await expectLater(LocalDb.importFromDbFile(sourcePath),
            throwsA(isA<DatabaseException>()));
      }
      final copied = mode == 'first failure' ? 0 :
          mode == 'later archive-page failure' ? 500 : 1;
      expect(await db.query(LocalDb.rawArchiveTable), hasLength(copied));
      expect(LocalDb.storeGeneration,
          mode == 'first failure' ? generation : greaterThan(generation));
    });
  }

  test('failed first import page leaves generation unchanged', () async {
    final db = await open();
    await source();
    await db.execute("CREATE TRIGGER refuse_journal BEFORE INSERT ON journal "
        "BEGIN SELECT RAISE(ABORT, 'test first-page failure'); END");
    final before = LocalDb.storeGeneration;
    await expectLater(LocalDb.importFromDbFile(sourcePath), throwsA(isA<DatabaseException>()));
    expect(await db.query('journal'), isEmpty);
    expect(LocalDb.storeGeneration, before, reason: 'nothing committed');
  });

  test('failed first import page can retry and invalidate the next generation', () async {
    final db = await open();
    await source();
    await db.execute("CREATE TRIGGER refuse_journal BEFORE INSERT ON journal "
        "BEGIN SELECT RAISE(ABORT, 'test first-page failure'); END");
    final before = LocalDb.storeGeneration;
    await expectLater(LocalDb.importFromDbFile(sourcePath), throwsA(isA<DatabaseException>()));
    expect(await db.query('journal'), isEmpty);
    expect(LocalDb.storeGeneration, before, reason: 'nothing committed');
    await db.execute('DROP TRIGGER refuse_journal');
    await LocalDb.importFromDbFile(sourcePath);
    expect((await db.query('journal')).single['note'], 'replacement');
    expect(LocalDb.storeGeneration, greaterThan(before), reason: 'retry must not leave a sticky latch');
  });

  test('GUARD sync REPLACE shrinks/clears beats only for its device and second', () async {
    final db = await open();
    Future<void> commit(String device, int counter, List<int> rr, {int? ts}) {
      final at = ts ?? _lo;
      return LocalDb.commitSyncBatch(
        [RawRecord(counter: counter, packetType: 47, hex: 'feed$counter',
            capturedAt: at * 1000, recTs: at)],
        [Sample(tsEpoch: at, counter: counter, hr: 60 + counter,
            rrIntervalsMs: rr, ax: 0, ay: 0, az: 1,
            spo2RedRaw: 0, spo2IrRaw: 0, skinTempRaw: 30000)],
        deviceId: device, deviceFamily: 'gen4',
      );
    }
    await commit('', 10, [800, 810, 820]);
    await commit('secondary', 11, [700, 710]);
    await commit('', 12, [780], ts: _lo + 1);
    await commit('', 1, [900]);
    expect((await db.query('decoded_onehz', where: "device_id = '' AND rec_ts = $_lo")).single['counter'], 1);
    expect((await db.query('decoded_onehz', where: "device_id = '' AND rec_ts = $_lo")).single['hr'], 61);
    expect((await db.query('decoded_rr', where: "device_id = '' AND rec_ts = $_lo")).map((r) => r['rr_ms']), [900]);
    await commit('', 2, []);
    expect(await db.query('decoded_rr', where: "device_id = '' AND rec_ts = $_lo"), isEmpty);
    expect((await db.query('decoded_rr', where: 'rec_ts = ?', whereArgs: [_lo + 1]))
        .single['rr_ms'], 780, reason: 'the neighboring second must keep its beats');
    expect((await db.query('decoded_rr', where: "device_id = 'secondary'", orderBy: 'beat_index'))
        .map((r) => r['rr_ms']), [700, 710]);
  });
}

// Frozen c8e63556 v58 base table definitions; optional columns added by the
// existing repair path are captured before upgrade. Never seed input_rev here.
const _v58DecodedDdl = [
  '''CREATE TABLE decoded_onehz (
    device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER, counter INTEGER NOT NULL, hr INTEGER, ax REAL, ay REAL, az REAL,
    spo2_red_raw INTEGER, spo2_ir_raw INTEGER, skin_temp_raw INTEGER,
    step_count INTEGER, step_cadence INTEGER, activity_class INTEGER, skin_temp_c REAL,
    on_wrist INTEGER, hr_valid INTEGER, hr_alt INTEGER, ambient_raw INTEGER,
    device_family TEXT, source TEXT, temp_ch2_c REAL, temp_ch3_c REAL,
    signal_quality_logvar REAL, dyn_accel_g REAL, PRIMARY KEY(device_id, ts_ms))''',
  '''CREATE TABLE decoded_rr (
    device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL, rr_ts_ms INTEGER NOT NULL,
    rr_ms INTEGER NOT NULL, device_family TEXT, source TEXT,
    PRIMARY KEY(device_id, ts_ms, beat_index))''',
];
