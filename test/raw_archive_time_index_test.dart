// The Ultrahuman reader ranges one device's archived records by rec_ts. Once
// housekeeping has built the time index, that read must be an index range,
// not a walk of the device's whole archive plus a sort.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late String dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_raw_archive_time_index_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('ultrahuman range read uses the rec_ts index, no sort', () async {
    final db = await LocalDb.instance;
    await LocalDb.ensureRawArchiveTimeIndex();
    await LocalDb.ensureRawArchiveTimeIndex(); // idempotent

    final plan = (await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT hex FROM ${LocalDb.rawArchiveView} '
      "WHERE device_id = ? AND reason = 'ultrahuman_record' "
      'AND rec_ts >= ? AND rec_ts <= ? ORDER BY rec_ts',
      ['ring', 0, 1],
    ))
        .map((r) => r['detail'])
        .join(' | ');
    expect(plan, contains('idx_raw_archive_reason_ts'));
    expect(plan, contains('rec_ts>?'));
    expect(plan, isNot(contains('TEMP B-TREE')));
  });
}
