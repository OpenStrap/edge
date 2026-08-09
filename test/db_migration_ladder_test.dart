// END-TO-END migration-ladder regressions, run against the REAL LocalDb over
// sqflite_ffi. Each test hand-builds a database at an OLD schema version, then
// opens it through LocalDb so sqflite runs the whole onUpgrade ladder.
//
// Why this file exists: `onUpgrade` runs inside ONE exclusive transaction, so a
// single throwing step rolls the whole ladder back and `openDatabase` rethrows.
// The app then has NO recoverable state — it is stuck on the loading screen on
// every launch, permanently. Two steps used a bare `ALTER TABLE … ADD COLUMN`
// against a table that a LATER-numbered `_create*` helper had already created
// with the CURRENT (column-bearing) DDL:
//
//   oldV <= 2 : step 3 re-creates raw_records WITH rec_ts, step 6 re-adds it.
//   oldV <= 6 : step 7 creates sessions WITH steps,        step 11 re-adds it.
//
// Plus the legacy-table migrations (sync_cursor / sync_ledger / sync_quarantine)
// which renamed → created → copied → dropped OUTSIDE any transaction, so a crash
// mid-copy orphaned `<table>_legacy` forever and silently lost the resumable-sync
// cursor (strap_trim / counter_hw / rec_ts_hw).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';

/// The pre-v3 raw_records shape: keyed by frame hex, NO rec_ts column.
const _legacyRawDdl = '''
  CREATE TABLE raw_records (
    hex TEXT PRIMARY KEY,
    counter INTEGER,
    packet_type INTEGER,
    captured_at INTEGER NOT NULL,
    uploaded INTEGER NOT NULL DEFAULT 0
  )
''';

/// The v6-era raw_records shape: hex PK, rec_ts already present.
const _v6RawDdl = '''
  CREATE TABLE raw_records (
    hex TEXT PRIMARY KEY,
    counter INTEGER,
    packet_type INTEGER,
    captured_at INTEGER NOT NULL,
    rec_ts INTEGER NOT NULL DEFAULT 0,
    uploaded INTEGER NOT NULL DEFAULT 0
  )
''';

/// The v5-era derived tables, so step 9's derived_day → day_result copy is real.
const _v5DerivedDdl = [
  '''
  CREATE TABLE derived_day (
    date TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    version INTEGER NOT NULL,
    last_raw_ts INTEGER NOT NULL,
    computed_at INTEGER NOT NULL,
    rhr REAL, rmssd REAL, readiness REAL
  )
''',
  '''
  CREATE TABLE baselines (
    key TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )
''',
  '''
  CREATE TABLE metric_series (
    date TEXT NOT NULL, key TEXT NOT NULL, value REAL,
    PRIMARY KEY (date, key)
  )
''',
];

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Build a database file at [version] with [ddl] applied, then close it.
Future<void> _seedOldDb(
  String name,
  int version,
  List<String> ddl, {
  Future<void> Function(Database db)? seedRows,
}) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final s in ddl) {
          await db.execute(s);
        }
      },
    ),
  );
  if (seedRows != null) await seedRows(db);
  await db.close();
}

/// Open [name] through LocalDb (running the real ladder) and hand back the
/// resulting user_version.
Future<int> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.first.values.first as num?)?.toInt() ?? -1;
}

void main() {
  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test(
    'upgrade from v2 completes — step 3 recreates raw_records WITH rec_ts, '
    'so step 6 must not re-add it (duplicate column bricked every launch)',
    () async {
      const name = 'migrate_from_v2_test.db';
      created.add(name);
      await _seedOldDb(name, 2, [
        _legacyRawDdl,
        'CREATE TABLE samples (counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)',
        '''CREATE TABLE events (
             hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
             captured_at INTEGER NOT NULL)''',
      ]);

      // Before the guard this threw
      // DatabaseException(duplicate column name: rec_ts) out of openDatabase,
      // rolling the whole ladder back — forever, on every launch.
      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'upgrade from v6 completes — step 7 creates sessions WITH steps, '
    'so step 11 must not re-add it',
    () async {
      const name = 'migrate_from_v6_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        6,
        [
          _v6RawDdl,
          'CREATE TABLE samples (counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)',
          '''CREATE TABLE events (
               hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
               captured_at INTEGER NOT NULL)''',
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          await db.insert('raw_records', {
            'hex': 'deadbeef',
            'counter': 42,
            'packet_type': 47,
            'captured_at': 1780000000 * 1000,
            'rec_ts': 0,
          });
          await db.insert('derived_day', {
            'date': '2026-05-05',
            'payload_json': '{"legacy": true}',
            'version': 1,
            'last_raw_ts': 1780000000,
            'computed_at': 1,
            'rhr': 55.0,
          });
        },
      );

      // Before the guard: DatabaseException(duplicate column name: steps).
      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');

      // The ladder's real work still happened: derived_day carried across.
      final migrated = await LocalDb.dayResult('2026-05-05');
      expect(migrated, isNotNull);
      expect(migrated!['payload_json'], '{"legacy": true}');

      // …and `sessions` has exactly ONE `steps` column, not two.
      final db = await LocalDb.instance;
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      expect(cols.where((c) => c['name'] == 'steps').length, 1);
      expect(cols.where((c) => c['name'] == 'hrr_bpm').length, 1);
    },
  );

  test(
    'an orphaned sync_cursor_legacy is RESUMED, not abandoned — a crash '
    'mid-copy must not silently lose the resumable-sync cursor',
    () async {
      const name = 'migrate_legacy_resume_test.db';
      created.add(name);
      // Exactly the state an interrupted legacy migration leaves behind: the
      // NEW-shaped sync_cursor already exists (so the old code's "already
      // current" early-return fired and never looked at the orphan), while
      // sync_cursor_legacy still holds the rows that were never copied.
      await _seedOldDb(
        name,
        LocalDb.schemaVersion,
        [
          '''CREATE TABLE sync_cursor (
               name TEXT PRIMARY KEY, value TEXT, updated_at INTEGER NOT NULL)''',
          '''CREATE TABLE sync_cursor_legacy (
               name TEXT PRIMARY KEY, value TEXT, note TEXT)''',
        ],
        seedRows: (db) async {
          // Say the copy died after one of three rows.
          await db.insert('sync_cursor', {
            'name': 'strap_trim',
            'value': 'aabbccdd',
            'updated_at': 1,
          });
          for (final r in const [
            ['strap_trim', 'aabbccdd'],
            ['counter_hw', '1200000'],
            ['rec_ts_hw', '1780000000'],
          ]) {
            await db.insert('sync_cursor_legacy', {
              'name': r[0],
              'value': r[1],
            });
          }
        },
      );

      await _openThroughLocalDb(name);

      // Every legacy row is now in the live table…
      expect(await LocalDb.getCursor('strap_trim'), 'aabbccdd');
      expect(await LocalDb.getCursorInt('counter_hw'), 1200000);
      expect(await LocalDb.getCursorInt('rec_ts_hw'), 1780000000);
      // …and the orphan is gone, so this can never run again.
      final db = await LocalDb.instance;
      final left = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='sync_cursor_legacy'",
      );
      expect(left, isEmpty);
    },
  );

  test(
    'a legacy migration interrupted BEFORE the CREATE (table missing, legacy '
    'present) also resumes cleanly',
    () async {
      const name = 'migrate_legacy_resume2_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        LocalDb.schemaVersion,
        [
          '''CREATE TABLE sync_cursor_legacy (
               name TEXT PRIMARY KEY, value TEXT, note TEXT)''',
        ],
        seedRows: (db) async {
          await db.insert('sync_cursor_legacy', {
            'name': 'strap_trim',
            'value': 'feedface',
          });
        },
      );

      await _openThroughLocalDb(name);
      expect(await LocalDb.getCursor('strap_trim'), 'feedface');
      final db = await LocalDb.instance;
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='sync_cursor_legacy'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'upgrade from v27 adds the numeric journal tables without touching the '
    'tags and note already stored for a day',
    () async {
      const name = 'migrate_from_v27_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        27,
        [
          ..._v5DerivedDdl,
          "CREATE TABLE journal (date TEXT PRIMARY KEY, "
              "tags_json TEXT NOT NULL DEFAULT '[]', "
              "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)",
        ],
        seedRows: (db) async {
          await db.insert('journal', {
            'date': '2026-06-01',
            'tags_json': '["caffeine","late meal"]',
            'note': 'felt rough',
            'updated_at': 1,
          });
        },
      );

      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      // The upgrade is purely additive: a day that only ever had tags keeps
      // them, and simply has no numeric rows.
      final rows = await LocalDb.journalRows();
      expect(rows.single['tags_json'], '["caffeine","late meal"]');
      expect(rows.single['note'], 'felt rough');
      expect(await LocalDb.journalMetricsForDay('2026-06-01'), isEmpty);

      // And the new tables are usable immediately, not on the next launch.
      await LocalDb.putJournalMetrics('2026-06-01', {
        'mood': const JournalMetricValue(4),
      });
      expect(
        (await LocalDb.journalMetricsForDay('2026-06-01'))['mood']!.value,
        4,
      );
      expect(await LocalDb.journalFieldDefs(), isEmpty);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );
}
