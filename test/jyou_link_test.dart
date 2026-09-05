// Proves `JyouLink` actually wires its `BandHost` with a `buildArchive`
// callback — the adapter yielding `raw` bytes is not enough on its own (see
// `BandHost._bufferArchive`, which silently drops every frame when the host
// was built with no `buildArchive`).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/jyou_link.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  const deviceId = 'jyou-a1b2c3d4';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'jyou_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('a frame the adapter yields actually lands in raw_archive', () async {
    final (host, link) = JyouLink.instance.hostForTest(deviceId);
    final done = host.run(link);
    link.feed(kJyouMeasureChar, [0xFC, 0, 0, 0, 0, 0, 0, 0, 68],
        atSec: 1_800_000_000);
    await link.close();
    await done;
    await host.stop();

    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive');
    expect(archive, hasLength(1));
    expect(archive.single['device_id'], deviceId);
    expect(archive.single['hex'], 'fc0000000000000044');
    expect(archive.single['reason'], 'jyou_evt_0xfc');
  });
}
