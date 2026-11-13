// Copy a SQLite database into a new file with the SAME schema (tables,
// indexes, views, triggers, sqlite_sequence, user_version), entirely inside
// SQLite: ATTACH the source read side, then INSERT ... SELECT per table, so no
// row passes through Dart. sqflite runs those statements off the UI thread.
//
// Used for the issue report's recent slice, and as the whole-database export
// on SQLite older than 3.27, which has no `VACUUM INTO` (Android 8-10 ship
// the framework SQLite 3.18/3.22, and sqflite uses the framework's).

import 'package:sqflite/sqflite.dart';

/// Rows of [table] to copy: '' = every row, a ' WHERE ...' clause = those
/// rows, null = none (the table itself is still created). The source is
/// attached as `src`.
typedef AttachCopyWhere = Future<String?> Function(
    DatabaseExecutor db, String table);

/// Build [dest] (replaced if it exists) from the database at [srcPath]. The
/// source is only ever READ. On failure [dest] is deleted and the error
/// rethrown.
Future<void> attachCopy(
    String srcPath, String dest, AttachCopyWhere whereFor) async {
  await deleteDatabase(dest);
  final out = await openDatabase(dest, singleInstance: false);
  try {
    await out.execute('ATTACH DATABASE ? AS src', [srcPath]);
    final schema = await out.rawQuery(
        "SELECT type, name, sql FROM src.sqlite_master WHERE sql IS NOT NULL "
        "AND name NOT LIKE 'sqlite_%' ORDER BY rowid");
    final have = {
      for (final r in await out.rawQuery(
          "SELECT name FROM main.sqlite_master WHERE type = 'table'"))
        r['name'] as String
    };
    // One DEFERRED transaction = one consistent read of the source, and
    // only a read lock on it. sqflite's transaction() is BEGIN IMMEDIATE,
    // which would take the source's write lock too and stall syncing.
    await out.execute('BEGIN');
    for (final r in schema) {
      if (r['type'] != 'table' || have.contains(r['name'])) continue;
      final name = r['name'] as String;
      await out.execute(r['sql'] as String);
      final where = await whereFor(out, name);
      if (where == null) continue;
      await out.execute(
          'INSERT INTO main."$name" SELECT * FROM src."$name"$where');
    }
    final seq = await out.rawQuery(
        "SELECT 1 FROM src.sqlite_master WHERE name = 'sqlite_sequence'");
    if (seq.isNotEmpty) {
      await out.execute('DELETE FROM main.sqlite_sequence');
      await out.execute(
          'INSERT INTO main.sqlite_sequence SELECT * FROM src.sqlite_sequence');
    }
    // Indexes, views and triggers after the rows (a trigger must not fire
    // on the copy).
    for (final type in const ['index', 'view', 'trigger']) {
      for (final r in schema) {
        if (r['type'] == type) await out.execute(r['sql'] as String);
      }
    }
    final v = await out.rawQuery('PRAGMA src.user_version');
    await out.execute('PRAGMA user_version = ${v.first.values.first}');
    await out.execute('COMMIT');
    await out.execute('DETACH DATABASE src');
    await out.close();
  } catch (_) {
    try {
      await out.close();
    } catch (_) {}
    try {
      await deleteDatabase(dest);
    } catch (_) {}
    rethrow;
  }
}
