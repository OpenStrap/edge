// A private session is "hidden from summaries and exports". v_sessions is what
// both the CSV workouts export and the coach read, so it must not carry one.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late String dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_private_sessions_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('private sessions stay out of v_sessions and the workouts csv',
      () async {
    final db = await LocalDb.instance;
    for (final (id, private) in [('run', 0), ('intimacy', 1)]) {
      await db.insert('sessions', {
        'id': id,
        'start_ts': 1782000000,
        'end_ts': 1782003600,
        'type': id,
        'status': 'done',
        'source': 'local',
        'created_at': 0,
        'private': private,
      });
    }

    final view = await db.rawQuery('SELECT id FROM v_sessions');
    expect([for (final r in view) r['id']], ['run']);

    final workouts = kCsvExportSets.firstWhere((s) => s.name == 'workouts');
    final csv = await db.rawQuery(workouts.sql);
    expect([for (final r in csv) r['type']], ['run']);
  });
}
