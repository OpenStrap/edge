// The PineTime HOST: scripted notifications in, `raw_archive` out.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `pinetime_test.dart` already
// proves the adapter merges both notify channels into raw frames; this file
// exists for the one thing only a host can get wrong — whether those frames
// actually reach the database, which `oura_link_test.dart` and
// `hrs_link_test.dart` each already guard for their own band.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/pinetime_link.dart';
import 'package:openstrap_edge/data/db.dart';

const String _deviceId = 'pinetime-0a1b2c3d';

final List<int> _stepsFrame = [0x2a, 0x00, 0x00, 0x00];
final List<int> _hrFrame = [0x00, 0x3c];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'pinetime_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every frame from either channel is banked, not silently dropped',
      () async {
    await PineTimeLink.instance.ingestForTest(_deviceId, [
      (kPineTimeStepCountChar, 1_800_000_000, _stepsFrame),
      (kHeartRateMeasurementUuid, 1_800_000_001, _hrFrame),
    ]);

    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'hex');
    expect(archive, hasLength(2));
    final hexes = archive.map((a) => a['hex']).toSet();
    expect(hexes, {'2a000000', '003c'});
    expect(archive.every((a) => a['reason'] == 'pinetime_frame'), isTrue);
    // No signal is ever declared, so nothing here writes a decoded row.
    expect(await db.query('decoded_onehz'), isEmpty);
    // Not re-drivable: `redriveArchivedRecords` replays a row's hex through
    // the WHOOP R24 chain, the wrong decoder over the right bytes.
    for (final a in archive) {
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
  });

  test('nothing paired means nothing to sync', () async {
    expect(await PineTimeLink.pairedRow(), isNull);
    expect(await PineTimeLink.instance.sync(), isFalse);
  });
}
