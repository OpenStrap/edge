// A rejected main sleep stored under tomorrow's label has to reach today's nap
// filter even when today's data stops hours before midnight.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_rejected_sleep_next_label_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a reject stored under the next calendar day is read', () async {
    final on = DateTime(2026, 3, 4, 22).millisecondsSinceEpoch ~/ 1000;
    final off = DateTime(2026, 3, 5, 6).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSleepOverride(
      dayId: '2026-03-05',
      onsetTs: on,
      offsetTs: off,
      source: 'rejected',
    );
    expect(await DerivationEngine.debugRejectedSleepSpans('2026-03-04'), [
      [on, off],
    ]);
  });
}
