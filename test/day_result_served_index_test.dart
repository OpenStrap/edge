// availableDayIds and dayResultIds filter on skipped/partial, which sit after
// the large payload in each row. They must be answered from an index.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late String dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_result_served_index_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('skip/partial filters read a covering index, results unchanged',
      () async {
    Future<void> put(String day, {int skipped = 0, int partial = 0}) =>
        db.insert('day_result', {
          'day_id': day,
          'algo_version': 5,
          'payload_json': '{}',
          'computed_at': 1,
          'finalized': 1,
          'skipped': skipped,
          'partial': partial,
        });
    await put('2026-01-01');
    await put('2026-01-02', skipped: 1);
    await put('2026-01-03', partial: 1);

    expect(await LocalDb.availableDayIds(), ['2026-01-03', '2026-01-01']);
    expect(await LocalDb.dayResultIds(5), {'2026-01-01'});

    final plan = (await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT day_id FROM day_result '
      'WHERE algo_version = 5 AND skipped = 0 AND partial = 0',
    ))
        .map((r) => r['detail'])
        .join(' ');
    expect(plan, contains('COVERING INDEX'));
  });
}
