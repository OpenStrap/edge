// Regression: LocalDb.onehzHrAccelBetween must exclude rows with a null
// hr/ax/ay/az (v25 records legitimately have no gravity vector — see the
// comment on the query). SmartWakeSample.fromRow does `as num` with no null
// check, so a null-accel row reaching it throws and silently kills the
// smart-wake check for the whole tick.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/smart_wake.dart';

void main() {
  late Database db;
  late String dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_smart_wake_null_accel_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a null-accel row in the window is excluded, not crashed on',
      () async {
    // A normal decoded row alongside a v25-style row with no accel.
    await db.insert('decoded_onehz', {
      'rec_ts': 100,
      'ts_ms': 100000,
      'counter': 1,
      'hr': 55,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
    });
    await db.insert('decoded_onehz', {
      'rec_ts': 101,
      'ts_ms': 101000,
      'counter': 2,
      'hr': null,
      'ax': null,
      'ay': null,
      'az': null,
    });

    final rows = await LocalDb.onehzHrAccelBetween(100, 101);

    expect(rows, hasLength(1));
    expect(rows.single['rec_ts'], 100);
    // Would throw a TypeError before the fix if the null row leaked through.
    expect(() => [for (final r in rows) SmartWakeSample.fromRow(r)],
        returnsNormally);
  });
}
