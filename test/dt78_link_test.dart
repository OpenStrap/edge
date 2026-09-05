// The DT78/DT92/DT66/wearfit-2.0-clone HOST wrapper: DB-only tests, the same
// surface `casio_link_test.dart` and `pinetime_link_test.dart` cover for
// their own hosts — no radio touched, because every path here that matters
// returns before `sync()` reaches BLE.
//
// This file exists for what only the host can get wrong: refusing to sync
// with nothing paired, refusing to write under the primary band's device id,
// and serialising concurrent sync() calls through `busy`.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/dt78_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'dt78_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('nothing paired means nothing to sync', () async {
    expect(await Dt78Link.pairedRow(), isNull);
    expect(await Dt78Link.instance.sync(), isFalse);
  });

  test('refuses to sync a row that claims the primary device id', () async {
    await LocalDb.upsertDevice(
      id: LocalDb.kPrimaryDeviceId,
      adapterId: kDt78.id,
      remoteId: 'AA:BB:CC:DD:EE:01',
      label: 'DT78',
    );
    // The guard fires before any connect attempt, so this is safe without a
    // real BLE stack behind it.
    expect(await Dt78Link.instance.sync(), isFalse);
  });

  test('busy serialises a second concurrent sync() to a no-op', () async {
    // Nothing paired, so the first call resolves fast — but `busy` is set
    // synchronously before that resolution, and a call made while it is
    // still in flight must collapse to `false` rather than starting a
    // second radio session.
    final first = Dt78Link.instance.sync();
    expect(Dt78Link.instance.busy, isTrue);
    expect(await Dt78Link.instance.sync(), isFalse);
    expect(await first, isFalse);
    expect(Dt78Link.instance.busy, isFalse);
  });
}
