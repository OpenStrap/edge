// Migration 49→50: the `alarm_schedule` table. CREATE TABLE IF NOT EXISTS,
// no backfill, no rewrite — see db.dart's v50 rung doc for why that additive
// shape is what keeps a throw here from bricking the whole upgrade ladder
// (invariant 11). Run against REAL sqflite_ffi, same idiom as
// db_migration_ladder_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A v49 database with no tables at all — `_repairOpenSchema`'s self-heal
/// (every `_create*` is CREATE TABLE IF NOT EXISTS) backfills everything else
/// this ladder needs, so an empty seed is enough to isolate the v50 rung.
Future<void> _seedEmptyV49Db(String name) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: 49, onCreate: (db, _) async {}),
  );
  await db.close();
}

/// Open [name] through LocalDb (running the real ladder) and hand back the
/// resulting `PRAGMA user_version`.
Future<int> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  // THE LADDER, not the quarantine-and-rebuild safety net — see
  // db_migration_ladder_test.dart's identical guard for why this matters.
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.first.values.first as num?)?.toInt() ?? -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final name in created) {
      await databaseFactory.deleteDatabase(await _dbPath(name));
    }
  });

  test(
      'upgrade from v49 reaches schemaVersion 50 and creates alarm_schedule '
      'keyed on weekday', () async {
    const name = 'openstrap_alarm_schedule_migration_test.db';
    created.add(name);
    await _seedEmptyV49Db(name);
    final version = await _openThroughLocalDb(name);
    expect(LocalDb.schemaVersion, 50);
    expect(version, LocalDb.schemaVersion);

    final db = await LocalDb.instance;
    final cols = await db.rawQuery('PRAGMA table_info(alarm_schedule)');
    final names = cols.map((c) => c['name'] as String).toSet();
    expect(names, {'weekday', 'hour', 'minute', 'enabled'});
    final weekdayCol = cols.firstWhere((c) => c['name'] == 'weekday');
    expect((weekdayCol['pk'] as num).toInt(), 1,
        reason: 'weekday must be the PRIMARY KEY');

    final health = await LocalDb.schemaHealth();
    expect(health['ok'], isTrue, reason: '$health');
  });

  test('a fresh install (onCreate) also has alarm_schedule', () async {
    const name = 'openstrap_alarm_schedule_fresh_test.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _dbPath(name));
    await LocalDb.close();
    LocalDb.lastRebuild = null;
    LocalDb.dbName = name;
    final db = await LocalDb.instance;
    final cols = await db.rawQuery('PRAGMA table_info(alarm_schedule)');
    expect(cols, isNotEmpty);
  });

  test(
      'setAlarmScheduleDay / alarmScheduleRows / clearAlarmSchedule round-trip '
      'through the real table, upserting rather than duplicating a weekday',
      () async {
    const name = 'openstrap_alarm_schedule_crud_test.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _dbPath(name));
    await LocalDb.close();
    LocalDb.lastRebuild = null;
    LocalDb.dbName = name;
    await LocalDb.instance;

    await LocalDb.setAlarmScheduleDay(
        weekday: 0, hour: 7, minute: 30, enabled: true);
    await LocalDb.setAlarmScheduleDay(
        weekday: 3, hour: 6, minute: 0, enabled: false);
    var rows = await LocalDb.alarmScheduleRows();
    expect(rows.length, 2);

    // Re-setting weekday 0 upserts (PRIMARY KEY (weekday)) — it must not
    // leave a stale second row behind.
    await LocalDb.setAlarmScheduleDay(
        weekday: 0, hour: 8, minute: 0, enabled: true);
    rows = await LocalDb.alarmScheduleRows();
    expect(rows.length, 2);
    final mon = rows.firstWhere((r) => r['weekday'] == 0);
    expect(mon['hour'], 8);
    expect(mon['minute'], 0);
    expect(mon['enabled'], 1);

    await LocalDb.clearAlarmSchedule();
    expect(await LocalDb.alarmScheduleRows(), isEmpty);
  });
}
