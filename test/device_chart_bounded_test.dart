// getDeviceChart's `bounded` flag blanks the chart and says the device's data
// only starts later. The prune removes whole days, so the oldest kept day is
// complete even though its first row is after midnight — it must still draw.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late String dir;
  final repo = LocalRepositoryImpl(getProfileMap: () => const {});

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_device_chart_bounded_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('the oldest kept day draws; the day before it is bounded', () async {
    final first =
        DateTime(2026, 5, 17, 0, 3).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 3; i++) {
      final ts = first + i * 60;
      await db.insert('decoded_onehz', {
        'device_id': 'band-a',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': i,
        'hr': 60,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
    }

    final kept =
        await repo.getDeviceChart('hr', deviceId: 'band-a', date: '2026-05-17');
    expect(kept['bounded'], isFalse);
    expect(kept['points'], hasLength(3));

    final before =
        await repo.getDeviceChart('hr', deviceId: 'band-a', date: '2026-05-16');
    expect(before['bounded'], isTrue);
    expect(before['oldest'], '2026-05-17');
  });
}
