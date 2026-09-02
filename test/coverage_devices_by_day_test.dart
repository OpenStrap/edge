// M6 -- LocalDb.coverageDevicesByDay (spec-m6.md §5.2, §13.2 test 8).
//
// Opens a real LocalDb through the full migration ladder (so `device_coverage`
// exists with its real schema), inserts coverage rows directly, and checks the
// day-splitting arithmetic — the `day_label_test.dart` idiom.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

Future<void> _insertCoverage(
  String deviceId,
  String signal,
  int startTs,
  int endTs,
) async {
  final db = await LocalDb.instance;
  await db.insert('device_coverage', {
    'device_id': deviceId,
    'signal': signal,
    'start_ts': startTs,
    'end_ts': endTs,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'coverage_devices_by_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance; // run the ladder once.
  });

  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('empty signals returns empty map with no query', () async {
    expect(
      await LocalDb.coverageDevicesByDay(
        signals: const [],
        fromSec: 0,
        toSec: 1000,
      ),
      isEmpty,
    );
  });

  test('an interval crossing local midnight lands on both day labels',
      () async {
    // 2026-09-01 22:00 local -> 2026-09-02 02:00 local.
    final start = DateTime(2026, 9, 1, 22).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime(2026, 9, 2, 2).millisecondsSinceEpoch ~/ 1000;
    await _insertCoverage('ring-A', 'hr1Hz', start, end);

    final out = await LocalDb.coverageDevicesByDay(
      signals: const ['hr1Hz'],
      fromSec: start - 3600,
      toSec: end + 3600,
    );
    expect(out['2026-09-01'], ['ring-A']);
    expect(out['2026-09-02'], ['ring-A']);
  });

  test('device ids on one day come back sorted, stable regardless of insert '
      'order', () async {
    final start = DateTime(2026, 9, 3, 10).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime(2026, 9, 3, 11).millisecondsSinceEpoch ~/ 1000;
    await _insertCoverage('ring-B', 'hr1Hz', start, end);
    await _insertCoverage('', 'hr1Hz', start, end); // primary device, id ''
    final out = await LocalDb.coverageDevicesByDay(
      signals: const ['hr1Hz'],
      fromSec: start,
      toSec: end,
    );
    expect(out['2026-09-03'], ['', 'ring-B']);
  });

  test('a row for a signal not asked for is excluded', () async {
    final start = DateTime(2026, 9, 4, 10).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime(2026, 9, 4, 11).millisecondsSinceEpoch ~/ 1000;
    await _insertCoverage('ring-A', 'accel1Hz', start, end);
    final out = await LocalDb.coverageDevicesByDay(
      signals: const ['hr1Hz'],
      fromSec: start,
      toSec: end,
    );
    expect(out, isEmpty);
  });
}
