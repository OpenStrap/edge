// The MyKronoz ZeTime HOST: a scripted battery reply in, `raw_archive` out —
// and never a `decoded_onehz` row, because this band declares no signal.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one and
// `flutter_blue_plus` has no simulator path, so the watch below is a script
// built to the envelope `zetime.dart` (protocol package) documents. This
// file pins the HOST — banking the frame, reading the one device fact this
// build decodes, and refusing a malformed reply — and proves nothing about a
// real watch.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show kZeTimeWriteChar;
import 'package:openstrap_edge/ble/zetime_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'zetime-0a1b2c3d';

List<int> _batteryReply(int level) => <int>[
      kZeTimePreamble,
      kZeTimeCmdBattery,
      0x01,
      0x01,
      0x00,
      level,
      kZeTimeEnd,
    ];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'zetime_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  // FIRST, deliberately: `batteryPct` is the same "most recent reading"
  // persistence `OuraLink.batteryPct` carries and it is never reset between
  // sessions — correct app behaviour (a battery level stays known until it is
  // updated), but it means a later test cannot assert this one is still
  // null. Ordered so the null case is observed before anything sets it.
  test('a malformed reply is dropped, not banked under a guessed shape',
      () async {
    await ZeTimeLink.instance.ingestForTest(
      _deviceId,
      (i, v) => [<int>[0x00, 0x00]],
    );
    expect(ZeTimeLink.instance.batteryPct, isNull);
    final db = await LocalDb.instance;
    expect(await db.query('raw_archive'), isEmpty);
  });

  test('a battery reply is decoded and banked verbatim, no signal stored',
      () async {
    final link = await ZeTimeLink.instance.ingestForTest(
      // Only the FIRST write (the battery request itself) gets a reply — the
      // second write is the fixed ack token, which a real watch answers with
      // nothing on the notify characteristic. Replying to both would still
      // pass (`raw_archive` dedups on the frame's own hex — see this class's
      // own `_buildArchiveRow` doc), but this is the shape a real session
      // actually has.
      _deviceId,
      (i, v) => i == 0 ? [_batteryReply(63)] : const <List<int>>[],
    );
    expect(ZeTimeLink.instance.batteryPct, 63);
    expect(link.writes.first.$1, kZeTimeWriteChar);

    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive');
    expect(archive, hasLength(1));
    expect(archive.single['reason'], 'zetime_cmd_0x08');
    // NULL, not 0: this band has no flash-record counter — see
    // `zetime_link.dart`'s own `_buildArchiveRow` doc.
    expect(archive.single['counter'], isNull);

    // This band declares no signal, so nothing lands in the real substrate —
    // the whole point of `ZeTimeAdapter.signals` being `const {}`.
    expect(await db.query('decoded_onehz'), isEmpty);
  });
}
