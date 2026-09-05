// The Makibes HR3 HOST: paired-row lookup, the primary-device-id refusal,
// the busy-flag serialisation guard, connect-failure teardown, and the
// archive-row builder.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `flutter_blue_plus` has no
// simulator path, so `connect()` throws under `flutter test` (no plugin is
// registered) — the same technique `hrs_link_test.dart` uses to reach the
// failing-connect path in pure Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ble_state.dart'
    show acquireSecondaryLinkSlot, releaseSecondaryLinkSlot;
import 'package:openstrap_edge/ble/makibeshr3_link.dart';
import 'package:openstrap_edge/data/db.dart';

const String _deviceId = 'makibeshr3-0a1b2c3d';

/// Both slots taken, then given back — proves whatever ran in between did
/// not leak one.
Future<void> _expectNoSlotLeak() async {
  const wait = Duration(seconds: 2);
  expect(await acquireSecondaryLinkSlot(timeout: wait), isTrue,
      reason: 'a slot was never released');
  expect(await acquireSecondaryLinkSlot(timeout: wait), isTrue,
      reason: 'a slot was never released');
  releaseSecondaryLinkSlot();
  releaseSecondaryLinkSlot();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'makibeshr3_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('nothing paired means nothing to sync', () async {
    expect(await MakibesHr3Link.pairedRow(), isNull);
    expect(await MakibesHr3Link.instance.sync(), isFalse);
  });

  test('pairedRow finds the stored row', () async {
    await LocalDb.upsertDevice(
      id: _deviceId,
      adapterId: kMakibesHr3.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
      label: 'Test HR3',
    );
    final row = await MakibesHr3Link.pairedRow();
    expect(row, isNotNull);
    expect(row!['id'], _deviceId);
  });

  test('the primary device id is refused outright', () async {
    // `''` is the primary band, permanently (ASSUMPTIONS A1). A board
    // writing under it would interleave its frames with the band's own rows.
    await LocalDb.upsertDevice(
      adapterId: kMakibesHr3.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
    );
    expect(await MakibesHr3Link.instance.sync(), isFalse);
    // Reached before any BLE connect — no slot taken, nothing to leak.
    await _expectNoSlotLeak();
  });

  test('a second sync while one is in flight is a no-op', () async {
    await LocalDb.upsertDevice(
      id: _deviceId,
      adapterId: kMakibesHr3.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
    );
    // `_busy` is set synchronously before the first call's first `await`, so
    // a call issued immediately after sees it set — no race to win.
    final a = MakibesHr3Link.instance.sync();
    final b = MakibesHr3Link.instance.sync();
    expect(await b, isFalse, reason: 'a sync already in flight is a no-op');
    // The first attempt really tries: `connect()` has no plugin registered
    // under a test and throws, which is the failing-sync path this proves.
    expect(await a, isFalse);
    await _expectNoSlotLeak();
    // And the busy flag cleared, so a later call is a real attempt again.
    expect(await MakibesHr3Link.instance.sync(), isFalse);
  });

  test('a connect failure disconnects and releases the slot, not leaks it',
      () async {
    await LocalDb.upsertDevice(
      id: _deviceId,
      adapterId: kMakibesHr3.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
    );
    // `connect()` throws under a test (no plugin registered) — the same
    // failing-connect path a real timeout or a partially-negotiated
    // connection would take. The teardown `finally` must still run: no
    // secondary-link slot left held for the life of the process.
    expect(await MakibesHr3Link.instance.sync(), isFalse);
    await _expectNoSlotLeak();
  });

  test('the archive-row builder banks a frame, attributed and undecoded',
      () async {
    await MakibesHr3Link.instance.ingestForTest(_deviceId, const [
      (1_800_000_000, [0x2f, 0x01, 0x02, 0x03]),
    ]);
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive');
    expect(archive, hasLength(1));
    final row = archive.first;
    expect(row['device_id'], _deviceId);
    expect(row['device_id'], isNot(LocalDb.kPrimaryDeviceId));
    expect(row['hex'], '2f010203');
    expect(row['packet_type'], 0x2f);
    expect(row['counter'], isNull,
        reason: 'this board has no flash-record counter — NULL, not 0');
    expect(row['rec_ts'], isNull, reason: 'nothing here is ever decoded');
    expect(row['reason'], 'makibeshr3_frame');
    // Never decoded into a number: the band-only readers must not see it.
    final onehz = await db.query('decoded_onehz');
    expect(onehz, isEmpty);
  });

  test('an empty frame banks nothing', () async {
    await MakibesHr3Link.instance.ingestForTest(_deviceId, const [
      (1_800_000_000, <int>[]),
    ]);
    final db = await LocalDb.instance;
    expect(await db.query('raw_archive'), isEmpty);
  });
}
