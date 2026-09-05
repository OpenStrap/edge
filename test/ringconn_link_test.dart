// The RingConn HOST: scripted frames in, `raw_archive` out, nothing else.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the ring below
// is a script and the frames are hand-built to the shapes the protocol
// package's RingConn wire format documents. It pins the HOST — banking every
// byte, never putting a command on the wire that no builder produced, and
// never writing a `decoded_onehz` row — and it proves nothing about a real
// ring.
//
// `ringconn_adapter_test.dart` already proves the session state machine.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ringconn_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'ringconn-0a1b2c3d';

/// Forward EUI-64 form of MAC `a1:b2:c3:44:55:66` (OUI + FF FE + NIC).
final List<int> _systemId = _hex('a1b2c3fffe445566');
final List<int> _mac = _hex('a1b2c3445566');

const int _nowSec = 1786000000;

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

List<int> _xorFrame(int respid, List<int> body) {
  final full = [respid, ...body];
  var x = 0;
  for (final b in full) {
    x ^= b;
  }
  return [...full, x & 0xff];
}

List<int> _challengeReply(int challenge) =>
    _xorFrame(kRingConnRespAuth, [0x00, challenge]);
List<int> _authConfirm() =>
    _xorFrame(kRingConnRespAuth, [0x01, ...List<int>.filled(35, 0)]);
/// Echoes [channel] back in the reply so this fixture — and the two
/// channels' archive rows below — can tell the sleep and awake drains apart.
List<int> _syncOpenReply(int channel) =>
    _xorFrame(kRingConnRespSyncOpen, [0x00, channel]);

/// [tag] (the channel byte) leads every record, so the sleep and awake
/// drains' pages hash to different `raw_archive` rows instead of colliding on
/// `(device_id, hex)` the way two byte-identical frames would.
List<int> _bulkPage(int respid, int recordLen, int remaining, int count,
    {required int tag}) {
  final records = <int>[
    for (var i = 0; i < count; i++) ...[
      tag,
      ...List<int>.filled(recordLen - 1, 0x11 * (i + 1)),
    ],
  ];
  return _xorFrame(respid, [0x00, remaining, ...records]);
}

/// A ring that authenticates, opens both channels, and hands each one
/// [recordsPerChannel] activity records in a single page before ending.
List<List<int>> Function(int, List<int>) _ring({int recordsPerChannel = 1}) {
  var lastChannel = -1;
  return (int i, List<int> v) {
    if (v.first == kRingConnCmdStatus && v[1] == 0x00) return [_challengeReply(0x2b)];
    if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
    if (v.first == kRingConnCmdSyncOpen) {
      lastChannel = v[6];
      return [_syncOpenReply(lastChannel)];
    }
    if (v.first == kRingConnCmdFetch) {
      return [
        _bulkPage(
          kRingConnRespBulkActivity,
          kRingConnActivityRecordLen,
          0,
          recordsPerChannel,
          tag: lastChannel,
        ),
      ];
    }
    return const <List<int>>[];
  };
}

Future<ReplayBandLinkResult> _run({
  int recordsPerChannel = 1,
  List<int>? systemId,
}) async {
  final link = await RingConnLink.instance.ingestForTest(
    _deviceId,
    systemId ?? _systemId,
    _ring(recordsPerChannel: recordsPerChannel),
    nowSeconds: () => _nowSec,
  );
  final db = await LocalDb.instance;
  return ReplayBandLinkResult(
    writes: [for (final w in link.writes) w.$2],
    onehz: await db.query('decoded_onehz', orderBy: 'ts_ms'),
    archive: await db.query('raw_archive', orderBy: 'captured_at, hex'),
  );
}

class ReplayBandLinkResult {
  final List<List<int>> writes;
  final List<Map<String, Object?>> onehz;
  final List<Map<String, Object?>> archive;
  const ReplayBandLinkResult({
    required this.writes,
    required this.onehz,
    required this.archive,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'ringconn_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every frame is banked verbatim, decoded or not, and nothing is ever '
      'decoded into a sample', () async {
    final r = await _run();
    // Both channels drain: auth (2 frames) + 2 channels x (open + page) = 6.
    expect(r.archive, hasLength(6));
    expect(r.onehz, isEmpty,
        reason: 'RingConnAdapter.signals is const {} — nothing is decoded');
    // One reason per reply tag, so a decoder written later finds its records
    // by name.
    expect(
      r.archive.map((a) => a['reason']).toSet(),
      {
        'ringconn_resp_0x${kRingConnRespAuth.toRadixString(16)}',
        'ringconn_resp_0x${kRingConnRespSyncOpen.toRadixString(16)}',
        'ringconn_resp_0x${kRingConnRespBulkActivity.toRadixString(16)}',
      },
    );
    // NOT re-drivable, and that is deliberate — see `oura_link_test.dart`'s
    // identical assertion: replaying this hex through the WHOOP R24 chain
    // would run the wrong decoder over the right bytes.
    for (final a in r.archive) {
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
  });

  test('nothing this host writes is a frame no builder in the protocol '
      'package produced', () async {
    final r = await _run();
    expect(r.writes, isNotEmpty);
    for (final w in r.writes) {
      final rebuilt = switch (w.first) {
        kRingConnCmdStatus when w[1] == 0x00 => ringConnCmdStatus(),
        kRingConnCmdStatus => ringConnCmdAuthResponse(w.sublist(2, 5)),
        kRingConnCmdSyncOpen => ringConnCmdSyncOpen(
            w[2] << 24 | w[3] << 16 | w[4] << 8 | w[5],
            w[6],
          ),
        kRingConnCmdFetch => ringConnCmdFetch(),
        kRingConnCmdAckActivity => ringConnCmdAckActivity(),
        _ => throw StateError(
            'unbuilt command tag 0x${w.first.toRadixString(16)}'),
      };
      expect(w, rebuilt);
    }
    // And the auth response really is SM3 over the ring's own MAC — not a
    // separate crypto surface to re-verify here, since `ringConnAuthResponse`
    // is protocol's own function called directly, with nothing edge-specific
    // in between.
    final authWrite =
        r.writes.firstWhere((w) => w.first == kRingConnCmdStatus && w[1] == 0x01);
    expect(authWrite.sublist(2, 5), ringConnAuthResponse(_mac, 0x2b));
  });

  test('the band-only readers cannot see a ring row', () async {
    await _run();
    final db = await LocalDb.instance;
    final banded = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_onehz WHERE source IS NULL',
    );
    expect(banded.first['c'], 0,
        reason: 'every derive/export read filters `source IS NULL`');
  });

  test('an unreadable System ID writes nothing at all', () async {
    // `ReplayBandLink.read` answers null for an unseeded uuid — the same
    // shape a real missing/unreadable characteristic takes.
    final r = await _run(systemId: const []);
    expect(r.writes, isEmpty);
    expect(r.archive, isEmpty);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await RingConnLink.pairedRingRow(), isNull);
    expect(await RingConnLink.instance.sync(), isFalse);
  });

  group('forgetRing', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kRingConn.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Ring',
      );
      expect(await RingConnLink.pairedRingRow(), isNotNull);
      final ok = await RingConnLink.forgetRing(_deviceId);
      expect(ok, isTrue);
      expect(await RingConnLink.pairedRingRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await RingConnLink.forgetRing(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await RingConnLink.forgetRing('ringconn-never-paired');
      expect(ok, isTrue);
      expect(await RingConnLink.pairedRingRow(), isNull);
    });
  });
}
