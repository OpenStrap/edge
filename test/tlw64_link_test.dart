// The HOST for a paired NO1-family band (TLW64/F1) — the DB-writing half
// `test/adapters/tlw64_test.dart` does not touch. That file proves the
// adapter emits raw bytes and nothing else; this one proves a session's
// frames actually reach `raw_archive`, attributed to the right device, with
// the `counter: null` policy `_buildArchiveRow` documents.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/tlw64_link.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  group('substrate write', () {
    const deviceId = 'tlw64-0a1b2c3d';

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'tlw64_link_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    test('a frame lands in raw_archive, attributed, counter NULL', () async {
      await Tlw64Link.instance.ingestForTest(deviceId, const [
        (1_800_000_000, [0xb2, 0x00, 0x00, 0x00, 0x0a]),
      ]);

      final db = await LocalDb.instance;
      final rows = await db.query('raw_archive');
      expect(rows, hasLength(1));
      expect(rows.single['device_id'], deviceId);
      expect(rows.single['device_id'], isNot(LocalDb.kPrimaryDeviceId));
      expect(rows.single['packet_type'], 0xb2);
      expect(rows.single['reason'], 'no1_frame');
      // THE LOAD-BEARING ONE. A stray `counter: 0` makes every one of this
      // family's frames `0 % 60 == 0` — permanently exempt from the
      // raw-archive thinning pass, by accident rather than policy.
      expect(rows.single['counter'], isNull);
    });

    test('two frames both survive — not deduped by a shared counter',
        () async {
      await Tlw64Link.instance.ingestForTest(deviceId, const [
        (1_800_000_000, [0xb2, 0x00, 0x00, 0x00, 0x0a]),
        (1_800_000_001, [0xb3, 0x01, 0x02, 0x03, 0x04]),
      ]);
      final db = await LocalDb.instance;
      expect(await db.query('raw_archive'), hasLength(2));
    });
  });
}
