// The Pebble HOST: scripted PPoGATT bytes in, `raw_archive` out.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Pebble (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the watch below
// is a script. `pebble_adapter_test.dart` already proves the transport state
// machine (ACKs, resets); this file exists for the one thing only a host can
// get wrong: whether a byte the adapter yields actually reaches the database.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/pebble_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'pebble-0a1b2c3d';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'pebble_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('an inner frame reaches raw_archive; health lands in observation',
      () async {
    List<int> u16(int v) => [v & 0xff, v >> 8];
    List<int> u32(int v) =>
        [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];
    final at = DateTime(2026, 10, 4, 8);
    final ts = at.millisecondsSinceEpoch ~/ 1000;
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13)];
    final data = [2, 5, ...u32(0), ...u32(0), ...u16(7), ...u32(ts), 0, 13, 1,
        25, 0, ...u16(100), 5, 0, 0, 0, 0, 0, 0, 0, 61];
    await PebbleLink.instance.ingestForTest(
      _deviceId,
      [
        ...pebblePpogattPackets(pebbleFrame(kPebbleEndpointDatalog, open), 0),
        ...pebblePpogattPackets(pebbleFrame(kPebbleEndpointDatalog, data), 3),
      ],
      nowSeconds: () => ts + 3600,
    );
    final db = await LocalDb.instance;
    expect((await db.query('raw_archive')).length, greaterThanOrEqualTo(1));
    final hr = await db.query('decoded_onehz');
    expect(hr.single['hr'], 61);
    expect(hr.single['source'], 'pebble');
    final steps = await db.query('observation');
    expect(steps.single['value'], 25.0);
    expect(await LocalDb.getCursorInt('pebble_steps_hw:$_deviceId'), ts);
  });

  test('a failed step write withholds the ACK and the high-water mark',
      () async {
    List<int> u16(int v) => [v & 0xff, v >> 8];
    List<int> u32(int v) =>
        [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];
    final ts = DateTime(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000;
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13)];
    final data = [2, 5, ...u32(0), ...u32(0), ...u16(7), ...u32(ts), 0, 13, 1,
        25, 0, ...u16(100), 5, 0, 0, 0, 0, 0, 0, 0, 61];
    // The step row cannot land.
    await (await LocalDb.instance).execute('DROP TABLE observation');
    final link = await PebbleLink.instance.ingestForTest(
      _deviceId,
      [
        ...pebblePpogattPackets(pebbleFrame(kPebbleEndpointDatalog, open), 0),
        ...pebblePpogattPackets(pebbleFrame(kPebbleEndpointDatalog, data), 3),
      ],
      nowSeconds: () => ts + 3600,
    );
    final frames = PebbleFrameReassembler();
    final sent = [
      for (final (u, w) in link.writes)
        if (u == kPebblePpogattWriteUuid && w.isNotEmpty && (w[0] & 7) == 0)
          ...frames.add(w.sublist(1)),
    ];
    // The open is ACKed; the data message, whose steps did not bank, is not,
    // so the watch keeps it.
    expect(sent.where((f) => f.$2[0] == 0x85).length, 1);
    expect(await LocalDb.getCursorInt('pebble_steps_hw:$_deviceId'), isNull);
  });

  test('a step write that fails part-way through a session is not counted '
      'twice when the watch re-sends', () async {
    List<int> u16(int v) => [v & 0xff, v >> 8];
    List<int> u32(int v) =>
        [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24];
    final t0 = DateTime(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000;
    final open = [1, 5, ...List.filled(16, 0), ...u32(1), ...u32(81), 0,
        ...u16(9 + 13)];
    List<int> minute(int ts, int steps) => [2, 5, ...u32(0), ...u32(0),
        ...u16(7), ...u32(ts), 0, 13, 1, steps, 0, ...u16(100), 5, 0, 0, 0, 0,
        0, 0, 0, 61];
    List<List<int>> session(List<List<int>> messages) {
      final out = <List<int>>[];
      for (final m in [open, ...messages]) {
        out.addAll(pebblePpogattPackets(
            pebbleFrame(kPebbleEndpointDatalog, m), out.length));
      }
      return out;
    }
    int now() => t0 + 3600;
    await PebbleLink.instance.ingestForTest(_deviceId, session([minute(t0, 25)]),
        nowSeconds: now);
    final db = await LocalDb.instance;
    // A (day total 125) cannot land; B (130) could.
    await db.execute("CREATE TRIGGER fail_a BEFORE INSERT ON observation "
        "WHEN NEW.value = 125 BEGIN SELECT RAISE(ABORT, 'disk'); END");
    final resend = [minute(t0 + 60, 100), minute(t0 + 120, 5)];
    await PebbleLink.instance.ingestForTest(_deviceId, session(resend),
        nowSeconds: now);
    await db.execute('DROP TRIGGER fail_a');
    await PebbleLink.instance.ingestForTest(_deviceId, session(resend),
        nowSeconds: now);
    final steps = await (await LocalDb.instance).query('observation');
    expect(steps.single['value'], 130.0);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await PebbleLink.pairedWatchRow(), isNull);
    expect(await PebbleLink.instance.sync(), isFalse);
  });

  group('forgetPebble', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kPebble.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Pebble',
      );
      expect(await PebbleLink.pairedWatchRow(), isNotNull);
      final ok = await PebbleLink.forgetPebble(_deviceId);
      expect(ok, isTrue);
      expect(await PebbleLink.pairedWatchRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await PebbleLink.forgetPebble(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await PebbleLink.forgetPebble('pebble-never-paired');
      expect(ok, isTrue);
      expect(await PebbleLink.pairedWatchRow(), isNull);
    });
  });
}
