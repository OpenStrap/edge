// The BP research tables are additive with no ladder rung: an existing
// install gets them from the open-time repair pass, a fresh one from onCreate.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Build a database file at [version] with [ddl] applied, then close it.
Future<void> _seedOldDb(
  String name,
  int version,
  List<String> ddl,
) async {
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
  await db.close();
}

/// Open [name] through LocalDb and assert it did not quarantine-and-rebuild.
Future<Database> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(
    LocalDb.lastRebuild,
    isNull,
    reason:
        'the upgrade bricked and fell back to quarantine-and-rebuild: '
        '${LocalDb.lastRebuild?.cause}',
  );
  final rows = await db.rawQuery('PRAGMA user_version');
  expect((rows.first.values.first as num?)?.toInt(), LocalDb.schemaVersion);
  return db;
}

const _expectedRefV2Cols = [
  'measurement_started_at_ms',
  'measurement_finished_at_ms',
  'band_device_id',
  'measurement_session_id',
  'time_precision',
];

const _expectedWinV2Cols = [
  'observed_start_ms',
  'observed_end_ms',
  'valid_hr_seconds',
  'valid_interval_count',
  'valid_interval_pair_count',
  'coverage_fraction',
  'rejected_interval_fraction',
  'quality_status',
  'feature_version',
  'snapshot_revision',
];

Future<Set<String>> _columns(Database db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final c in info) c['name'] as String};
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
    'fresh install creates the bp research tables',
    () async {
      const name = 'bp_migrate_fresh_test.db';
      created.add(name);
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      LocalDb.dbName = name;
      await databaseFactory.deleteDatabase(await _dbPath(name));
      final db = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      final refCols = await _columns(db, 'bp_research_reference');
      final winCols = await _columns(db, 'bp_research_window');
      for (final c in _expectedRefV2Cols) {
        expect(refCols, contains(c));
      }
      for (final c in _expectedWinV2Cols) {
        expect(winCols, contains(c));
      }
      final snapCols = await _columns(db, 'bp_research_snapshot');
      expect(snapCols, containsAll(['reference_id', 'revision', 'onehz_json']));
    },
  );

  test(
    'an existing v54 database gets the bp research tables on open',
    () async {
      const name = 'bp_migrate_v54_test.db';
      created.add(name);
      await _seedOldDb(name, 54, const []);
      final db = await _openThroughLocalDb(name);
      expect(
        await db.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
          'bp_research_reference',
        ]),
        isNotEmpty,
      );
      expect(
        await db.rawQuery('SELECT name FROM sqlite_master WHERE name = ?', [
          'bp_research_snapshot',
        ]),
        isNotEmpty,
      );
      final refCols = await _columns(db, 'bp_research_reference');
      for (final c in _expectedRefV2Cols) {
        expect(refCols, contains(c));
      }
    },
  );
}
