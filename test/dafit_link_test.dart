// The DaFit/MOYOUNG HOST: `DafitLink` itself, not the adapter's session state
// machine (that is `test/adapters/dafit_adapter_test.dart`). This file exists
// for the three things only the host can get wrong: the primary-device guard
// in `sync()`/`forget()`, and `_buildArchiveRow`'s counter/reason mapping as
// it actually lands through `LocalDb.commitSyncBatch` — the same kind of gap
// `oura_link_test.dart` closes for the Oura path, via the same
// `ingestForTest` seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/dafit_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'dafit-0a1b2c3d';
DateTime _now() => DateTime.utc(2024, 3, 5, 14, 22, 37);

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'dafit_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('nothing paired means nothing to sync', () async {
    expect(await DafitLink.pairedRow(), isNull);
    expect(await DafitLink.instance.sync(), isFalse);
  });

  group('forget', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kDafit.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Watch',
      );
      expect(await DafitLink.pairedRow(), isNotNull);
      final ok = await DafitLink.forget(_deviceId);
      expect(ok, isTrue);
      expect(await DafitLink.pairedRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await DafitLink.forget(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await DafitLink.forget('dafit-never-paired');
      expect(ok, isTrue);
      expect(await DafitLink.pairedRow(), isNull);
    });
  });

  test('every frame is banked with a null counter and a reason keyed off '
      'the ack byte', () async {
    final hwInfoReply = buildDafitFrame(
      kDafitGroupRequestData,
      kDafitCmdGetHwInfo,
      [0x01, 0x02],
    );
    final buttonFrame = buildDafitFrame(0x1c, 0x01);
    // A frame the BAND sends shaped like an ack (as opposed to the ack this
    // session writes out for hwInfoReply, which is a write, never a
    // notification, and so is never a row here at all).
    final ackEcho = buildDafitAck(parseDafitFrame(hwInfoReply)!);
    await DafitLink.instance.ingestForTest(_deviceId, _now, [
      (1_800_000_000, hwInfoReply),
      (1_800_000_001, buttonFrame),
      (1_800_000_002, ackEcho),
    ]);
    final db = await LocalDb.instance;
    final rows = await db.query('raw_archive', orderBy: 'captured_at, hex');
    expect(rows, hasLength(3));
    for (final r in rows) {
      // NULL, not 0 — see `_buildArchiveRow`'s own comment on why a regression
      // back to a constant 0 would silently exempt this family from thinning.
      expect(r['counter'], isNull, reason: r['hex'] as String);
      expect(r['device_id'], _deviceId);
    }
    final byHex = {for (final r in rows) r['hex']: r['reason']};
    expect(byHex[_hex(hwInfoReply)], 'dafit_frame');
    expect(byHex[_hex(buttonFrame)], 'dafit_frame');
    expect(byHex[_hex(ackEcho)], 'dafit_ack');
  });
}
