// A commit that banks no records (a bare HISTORY_END token, or only
// gate-dropped archives) must not seed the record frontier with '0' on an
// install that has never stored a record. A stored 0 is not null, so every
// `getCursorInt('rec_ts_hw') ?? fallback` reader took it as a real frontier
// and Home read "Synced through Thu 1 Jan 1970" instead of "No band data yet".

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'cursor_zero_seed_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a token-only commit on a fresh install leaves the frontier unset',
      () async {
    await LocalDb.commitSyncBatch(const [], const <Sample?>[],
        trimToken: '0102030405060708');
    expect(await LocalDb.getCursor('rec_ts_hw'), isNull);
    expect(await LocalDb.getCursor('counter_hw'), isNull);
    // The token itself is still banked.
    expect(await LocalDb.getCursor('strap_trim'), '0102030405060708');
  });

  test('a gate-dropped-only commit leaves the frontier unset but is seen',
      () async {
    // A never-set strap clock: every record is below the floor, so the gate
    // archives them all and no raw moves rec_ts_hw.
    expect(await LocalDb.hasGateDroppedArchive(), isFalse);
    await LocalDb.commitSyncBatch(const [], const <Sample?>[],
        trimToken: '0a0b',
        archives: [
          ArchiveRecord(
            counter: 3,
            hex: '2f18001122',
            packetType: 0x2F,
            capturedAt: 1750000000 * 1000,
            reason: kGateDroppedReason,
          ),
        ]);
    expect(await LocalDb.getRecordFrontier(), isNull);
    expect(await LocalDb.hasGateDroppedArchive(), isTrue);
  });

  test('the first real record still advances both cursors', () async {
    await LocalDb.commitSyncBatch(
      [
        RawRecord(
          counter: 7,
          packetType: 0x2F,
          hex: '2f18aabbccdd',
          capturedAt: 1750000001 * 1000,
          recTs: 1750000001,
        ),
      ],
      <Sample?>[Sample(tsEpoch: 1750000001, counter: 7, hr: 60)],
      trimToken: 'aa',
    );
    expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000001);
    expect(await LocalDb.getCursorInt('counter_hw'), 7);
  });

  test('a later empty commit does not regress a real frontier', () async {
    await LocalDb.commitSyncBatch(const [], const <Sample?>[],
        trimToken: 'bb');
    expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000001);
    expect(await LocalDb.getCursorInt('counter_hw'), 7);
  });

  test('frontier readers treat a stored 0 as unset', () async {
    await LocalDb.setCursor('rec_ts_hw', '0');
    expect(await LocalDb.getRecordFrontier(), isNull);
    await LocalDb.setCursor('rec_ts_hw', '1750000001');
    expect(await LocalDb.getRecordFrontier(), 1750000001);
  });
}
