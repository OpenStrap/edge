// The strength-set store: migration and the one invariant that made it
// necessary.
//
// Nothing measures a bench press. Until v38 there was nowhere to put what the
// user typed — `sessions` has no exercise, set, rep, load or RPE column — so
// every number on the strength screens was unbacked. This checks the ladder
// lands the tables on an existing install, and that a bodyweight set survives
// the round trip as NULL rather than as zero kilos, which is the whole reason
// `load_kg` is nullable.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Build a database file at [version] with nothing but a marker table, then
/// close it — the strength step is a pure create, so it needs no predecessor.
Future<void> _seedOldDb(String name, int version) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE marker (id INTEGER PRIMARY KEY)');
        await db.insert('marker', {'id': 1});
      },
    ),
  );
  await db.close();
}

Future<Database> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  return LocalDb.instance;
}

Future<bool> _hasTable(Database db, String table) async =>
    (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    ))
        .isNotEmpty;

void main() {
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  Future<Database> upgradeFrom(int version, String name) async {
    created.add(name);
    await _seedOldDb(name, version);
    return _openThroughLocalDb(name);
  }

  test('v34 upgrades to the current version and gains the strength tables',
      () async {
    final db = await upgradeFrom(34, 'strength_from_34.db');

    final rows = await db.rawQuery('PRAGMA user_version');
    expect((rows.first.values.first as num).toInt(), LocalDb.schemaVersion);
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(38));

    expect(await _hasTable(db, 'strength_set'), isTrue);
    expect(await _hasTable(db, 'exercise_def'), isTrue);
    // The pre-existing data is untouched — this step creates, never rewrites.
    expect(await db.query('marker'), hasLength(1));
  });

  test('a fresh database has the tables too', () async {
    created.add('strength_fresh.db');
    await databaseFactory.deleteDatabase(await _dbPath('strength_fresh.db'));
    final db = await _openThroughLocalDb('strength_fresh.db');
    expect(await _hasTable(db, 'strength_set'), isTrue);
    expect(await _hasTable(db, 'exercise_def'), isTrue);
  });

  test('a bodyweight set round-trips as NULL, not as zero kilos', () async {
    created.add('strength_rows.db');
    await databaseFactory.deleteDatabase(await _dbPath('strength_rows.db'));
    await _openThroughLocalDb('strength_rows.db');

    await LocalDb.saveStrengthSets('sess-1', [
      {
        'exercise_key': 'bench_press',
        'set_index': 1,
        'reps': 8,
        'load_kg': 80.0,
        'rpe': 7,
        'at_ts': 1770000000,
      },
      {
        'exercise_key': 'pull_up',
        'set_index': 1,
        'reps': 9,
        'rpe': 8,
        'at_ts': 1770000600,
      },
    ]);

    final sets = await LocalDb.strengthSets('sess-1');
    expect(sets, hasLength(2));
    expect(sets[0]['seq'], 0);
    expect(sets[0]['load_kg'], 80.0);
    expect(sets[1]['load_kg'], isNull,
        reason: 'a bodyweight pull-up at 0 kg would zero the session volume');
    expect(sets[1]['note'], '');

    // Re-saving the same session replaces rather than duplicates.
    await LocalDb.saveStrengthSets('sess-1', [
      {
        'exercise_key': 'bench_press',
        'set_index': 1,
        'reps': 8,
        'load_kg': 82.5,
        'at_ts': 1770000000,
      },
    ]);
    final again = await LocalDb.strengthSets('sess-1');
    expect(again.first['load_kg'], 82.5);

    final recent = await LocalDb.recentSetsFor('pull_up');
    expect(recent, hasLength(1));
    expect(recent.first['reps'], 9);
    expect(await LocalDb.recentSetsFor('nothing_here'), isEmpty);
  });

  test('deleting a session takes its sets with it', () async {
    created.add('strength_cascade.db');
    await databaseFactory.deleteDatabase(await _dbPath('strength_cascade.db'));
    await _openThroughLocalDb('strength_cascade.db');

    await LocalDb.putSession({
      'id': 'sess-del',
      'start_ts': 1770100000,
      'end_ts': 1770103600,
      'type': 'strength',
      'status': 'done',
      'created_at': 1770100000,
    });
    await LocalDb.saveStrengthSets('sess-del', [
      {
        'exercise_key': 'bench_press',
        'set_index': 1,
        'reps': 1,
        'load_kg': 200.0,
        'at_ts': 1770100100,
      },
    ]);

    await LocalDb.deleteSession('sess-del');

    expect(await LocalDb.strengthSets('sess-del'), isEmpty);
    // The real symptom: a mistyped set on a deleted workout kept coming back
    // as "previous"/"best" on the live strength screen and kept exporting
    // under a session_id that no longer exists.
    expect(await LocalDb.recentSetsFor('bench_press'), isEmpty);
  });

  test('strength history candidates are newest and heaviest without N queries',
      () async {
    created.add('strength_history.db');
    await databaseFactory.deleteDatabase(await _dbPath('strength_history.db'));
    await _openThroughLocalDb('strength_history.db');

    await LocalDb.saveStrengthSets('older', [
      {
        'exercise_key': 'bench_press',
        'set_index': 1,
        'reps': 8,
        'load_kg': 80.0,
        'at_ts': 100,
      },
      {
        'exercise_key': 'bench_press',
        'set_index': 2,
        'reps': 10,
        'load_kg': 80.0,
        'at_ts': 200,
      },
      {
        'exercise_key': 'pull_up',
        'set_index': 1,
        'reps': 9,
        'at_ts': 250,
      },
    ]);
    await LocalDb.saveStrengthSets('newer', [
      {
        'exercise_key': 'bench_press',
        'set_index': 1,
        'reps': 12,
        'load_kg': 70.0,
        'at_ts': 300,
      },
    ]);

    final candidates = await LocalDb.strengthHistoryCandidates();
    final previousBench = candidates.previous
        .firstWhere((row) => row['exercise_key'] == 'bench_press');
    expect(previousBench['at_ts'], 300);
    expect(previousBench['load_kg'], 70.0);

    final bestBench = candidates.best
        .firstWhere((row) => row['exercise_key'] == 'bench_press');
    expect(bestBench['load_kg'], 80.0);
    expect(bestBench['reps'], 10,
        reason: 'more reps wins a tied best-load candidate');
    expect(candidates.previous.any((row) => row['exercise_key'] == 'pull_up'),
        isTrue);
    expect(candidates.best.any((row) => row['exercise_key'] == 'pull_up'),
        isFalse,
        reason: 'bodyweight history has no fabricated zero-kilo best');
  });

  test('sessions carries the private flag, defaulting to not-private',
      () async {
    final db = await upgradeFrom(39, 'sessions_private_from_39.db');
    final cols = await db.rawQuery('PRAGMA table_info(sessions)');
    final private = cols.firstWhere((c) => c['name'] == 'private');
    expect(private['notnull'], 1);
    expect(private['dflt_value'], '0');

    await LocalDb.putSession({
      'id': 'sess-priv',
      'start_ts': 1770200000,
      'end_ts': 1770203600,
      'type': 'run',
      'status': 'done',
      'created_at': 1770200000,
    });
    expect((await LocalDb.session('sess-priv'))!['private'], 0);
    await LocalDb.setSessionPrivate('sess-priv', true);
    expect((await LocalDb.session('sess-priv'))!['private'], 1);
    await LocalDb.setSessionPrivate('sess-priv', false);
    expect((await LocalDb.session('sess-priv'))!['private'], 0);
  });
}
