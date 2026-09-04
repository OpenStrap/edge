// M6 -- LocalDb.setSignalPriority / clearSignalPriority (spec-m6.md §9.1,
// §13.2 test 9).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'signal_priority_writers_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('setSignalPriority writes dense ranks with user_set = 1', () async {
    await LocalDb.setSignalPriority(
      InputSignal.rrIntervals,
      ['ring-A', ''],
    );
    final order = await LocalDb.signalPriority(InputSignal.rrIntervals);
    expect(order, ['ring-A', '']);

    final db = await LocalDb.instance;
    final rows = await db.query('signal_priority',
        where: 'signal = ?', whereArgs: [InputSignal.rrIntervals.name]);
    expect(rows.every((r) => r['user_set'] == 1), isTrue);
    expect(
      rows.firstWhere((r) => r['device_id'] == 'ring-A')['rank'],
      0,
    );
    expect(rows.firstWhere((r) => r['device_id'] == '')['rank'], 1);
  });

  test('setSignalPriority replaces (not appends to) a prior order', () async {
    await LocalDb.setSignalPriority(InputSignal.hr1Hz, ['a', 'b']);
    await LocalDb.setSignalPriority(InputSignal.hr1Hz, ['b']);
    expect(await LocalDb.signalPriority(InputSignal.hr1Hz), ['b']);
  });

  test('clearSignalPriority removes only user_set = 1 rows — seeded '
      'defaults survive a reset', () async {
    final db = await LocalDb.instance;
    // A seeded (physics-ladder) default row, user_set = 0, inserted directly
    // rather than via setSignalPriority — which always fully replaces a
    // signal's rows and would wipe this seed too, by design.
    await db.insert('signal_priority',
        {'signal': 'hr1Hz', 'device_id': '', 'rank': 0, 'user_set': 0});
    await db.insert('signal_priority',
        {'signal': 'hr1Hz', 'device_id': 'ring-A', 'rank': 1, 'user_set': 1});

    await LocalDb.clearSignalPriority(InputSignal.hr1Hz);

    final rows = await db.query('signal_priority',
        where: 'signal = ?', whereArgs: ['hr1Hz']);
    // Only the seeded user_set=0 row survives.
    expect(rows.length, 1);
    expect(rows.single['user_set'], 0);
    expect(rows.single['device_id'], '');
  });

  test('signalPriorities returns every signal with rows, sparse otherwise',
      () async {
    await LocalDb.setSignalPriority(InputSignal.rrIntervals, ['ring-A']);
    final all = await LocalDb.signalPriorities();
    expect(all[InputSignal.rrIntervals.name], ['ring-A']);
    expect(all[InputSignal.hr1Hz.name], isNull);
  });
}
