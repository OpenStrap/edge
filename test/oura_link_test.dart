// The Oura HOST: scripted frames in, `raw_archive` / `decoded_onehz` out.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the ring below
// is a script and the frames are hand-built to the layouts the protocol package's
// Oura wire format documents. It pins the HOST — the anchor, the commit ordering, the
// attribution and what is refused — and it proves nothing about a real ring.
//
// `oura_adapter_test.dart` already proves the session state machine. This file
// exists for the three things only a host can get wrong: banking every byte,
// refusing to stamp a second it cannot honestly name, and never putting a
// command on the wire that no builder produced.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/oura_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'oura-0a1b2c3d';

/// Any 16 bytes. The replay ring answers a scripted result rather than actually
/// verifying the AES block, so the VALUE of the key is not what is under test
/// here — `oura_adapter_test.dart` pins the cipher against a known vector.
const List<int> _key = <int>[
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
];

/// The session's "now". Fixed so a stamp assertion is a real assertion.
const int _nowSec = 1786000000;

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

List<int> _frame(int tag, List<int> payload) =>
    <int>[tag, payload.length, ...payload];

List<int> _event(int tag, int tsDs, List<int> body) => _frame(tag, <int>[
      tsDs & 0xff,
      (tsDs >> 8) & 0xff,
      (tsDs >> 16) & 0xff,
      (tsDs >> 24) & 0xff,
      ...body,
    ]);

List<int> _summary(int received, int bytesLeft) => _frame(0x11, <int>[
      received,
      0,
      bytesLeft & 0xff,
      (bytesLeft >> 8) & 0xff,
      (bytesLeft >> 16) & 0xff,
      (bytesLeft >> 24) & 0xff,
    ]);

final List<int> _nonceReply =
    _frame(0x2f, _hex('2c') + _hex('0e2d6a0a08c99b4365f458e6e97382'));
final List<int> _authOk = _frame(0x2f, _hex('2e00'));

/// 0x0d6c centi-degrees = 34.36 C, a plausible worn reading.
const String _temp3436 = '6c0d';

/// A time_sync body: Unix seconds, little-endian.
List<int> _syncBody(int unix) => <int>[
      unix & 0xff,
      (unix >> 8) & 0xff,
      (unix >> 16) & 0xff,
      (unix >> 24) & 0xff,
    ];

/// A ring that serves [batches] in order, one per history request, then stops.
List<List<int>> Function(int, List<int>) _ring(List<List<List<int>>> batches) {
  var served = 0;
  return (int i, List<int> v) {
    if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
    if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
    if (v.first != 0x10) return const <List<int>>[];
    if (served >= batches.length) return [_summary(0, 0)];
    return batches[served++];
  };
}

Future<ReplayBandLinkResult> _run(List<List<List<int>>> batches) async {
  final link = await OuraLink.instance.ingestForTest(
    _deviceId,
    _key,
    _ring(batches),
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
    LocalDb.dbName = 'oura_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every frame is banked verbatim, decoded or not', () async {
    const unknown = '0102030405060708090a0b0c0d0e';
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        // Nothing decodes this one. It must still reach the archive — the beat
        // intervals and the hypnogram live in frames exactly like it.
        _event(0x60, 1300, _hex(unknown)),
        _summary(3, 0),
      ],
    ]);
    expect(r.archive, hasLength(3));
    final hexes = r.archive.map((a) => a['hex']).toSet();
    expect(hexes.contains(_hexOf(_event(0x60, 1300, _hex(unknown)))), isTrue);
    // One reason PER TAG, so a decoder written later finds its records by name.
    expect(
      r.archive.map((a) => a['reason']).toSet(),
      {'oura_evt_0x42', 'oura_evt_0x69', 'oura_evt_0x60'},
    );
    // NOT re-drivable, and that is deliberate: `redriveArchivedRecords` replays
    // a row's hex through the WHOOP R24 chain, which would be the wrong decoder
    // over the right bytes.
    for (final a in r.archive) {
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
  });

  test('a measured time_sync is what stamps the batch carrying it', () async {
    const syncUnix = 1782043215;
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
        // 200 deciseconds — 20 seconds — after the sync.
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], syncUnix + 20);
    expect(r.onehz.first['ts_ms'], (syncUnix + 20) * 1000);
    expect(r.onehz.first['skin_temp_c'], closeTo(34.36, 0.001));
    // Absolute Celsius NEVER lands in the relative-ADC column, and a ring
    // second that carried a temperature carried no heart rate.
    expect(r.onehz.first['skin_temp_raw'], isNull);
    expect(r.onehz.first['hr'], isNull);
    for (final c in ['ax', 'ay', 'az', 'spo2_red_raw']) {
      expect(r.onehz.first[c], isNull, reason: c);
    }
    // Attributed, and not the primary band.
    expect(r.onehz.first['device_id'], _deviceId);
    expect(r.onehz.first['device_id'], isNot(LocalDb.kPrimaryDeviceId));
    expect(r.onehz.first['source'], 'oura');
    expect(r.onehz.first['device_family'], 'oura');
  });

  test('the anchor and the cursor both survive the session', () async {
    const syncUnix = 1782043215;
    await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
        _summary(1, 0),
      ],
    ]);
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), '1000,$syncUnix');
    // The highest envelope stamp in the batch plus one — the short-batch
    // advance. Persisted only because the commit landed first.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 1001);
  });

  test('no anchor anywhere writes no timestamped row, and banks the bytes',
      () async {
    // THE HONEST ABSTENTION. A plausible wrong `ts_ms` is worse than a missing
    // one: it writes the same physiological second under a second key that
    // REPLACE can never collapse.
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, isEmpty);
    expect(r.archive, hasLength(1));
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), isNull);
  });

  test('a reading held before the anchor arrives is written once it does',
      () async {
    // Every connect writes SET_TIME, so the ring's fresh `time_sync` lands at
    // its CURRENT decisecond — the END of the drain. On a fresh pairing that is
    // after the whole of its history, and abstaining would throw all of it away.
    const syncUnix = 1782043215;
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 512),
      ],
      [
        // 100 deciseconds — 10 seconds — after the reading above.
        _event(kOuraEvtTimeSync, 1300, _syncBody(syncUnix)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], syncUnix - 10);
  });

  test('a stored anchor stamps a session that measures none', () async {
    const storedUnix = 1782043215;
    await LocalDb.setCursor('oura_anchor:$_deviceId', '1000,$storedUnix');
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, hasLength(1));
    expect(r.onehz.first['rec_ts'], storedUnix + 20);
  });

  test('a stamp in the future is refused, not written', () async {
    // The reboot direction that CAN be bounded for free: the ring's decisecond
    // counter is an uptime, so a stale origin extrapolates a record forward
    // past now — and no record is from the future.
    await LocalDb.setCursor('oura_anchor:$_deviceId', '0,$_nowSec');
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 10000000, _hex(_temp3436)),
        _summary(1, 0),
      ],
    ]);
    expect(r.onehz, isEmpty, reason: 'a million seconds from now');
    expect(r.archive, hasLength(1), reason: 'still banked, just not stamped');
  });

  test('the host writes nothing that no builder produced', () async {
    // ASSUMPTIONS I1: `GattBandLink`'s dangerous-opcode block reads an opcode
    // out of a WHOOP envelope and answers null for an unframed band, so NOTHING
    // at the link refuses these. The ring has a factory reset, a DFU state
    // machine, a flight mode, a manufacturing-mode setter and a bulk-sampler
    // erase, and the only thing stopping them is that no builder exists and
    // this host writes nothing else.
    final r = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtDebugData, 1100, _hex('2456c80f00')),
        _summary(2, 0),
      ],
    ]);
    expect(r.writes, isNotEmpty);
    // The four builders in the protocol package's Oura wire format, and nothing
    // else — a new tag here means someone added a builder, go and read which one.
    const built = {0x2f, 0x1c, 0x12, 0x10};
    for (final w in r.writes) {
      expect(built, contains(w.first),
          reason: 'unbuilt command tag 0x${w.first.toRadixString(16)}');
    }
    // And each write is byte-identical to what its builder produces.
    for (final w in r.writes) {
      final rebuilt = switch (w.first) {
        0x2f when w[2] == 0x2b => ouraCmdAuthNonce(),
        0x2f => ouraCmdAuthenticate(w.sublist(3)),
        0x1c => ouraCmdSetNotifyFlags(w[2]),
        0x12 => ouraCmdSyncTime(
            w[2] | (w[3] << 8) | (w[4] << 16) | (w[5] << 24),
            tzHalfHours: w[10],
          ),
        _ => ouraCmdGetEvents(
            w[2] | (w[3] << 8) | (w[4] << 16) | (w[5] << 24),
            maxEvents: w[6],
          ),
      };
      expect(w, rebuilt);
    }
  });

  test('a stranded reset invalidates the stored time anchor too', () async {
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await LocalDb.setCursor('oura_anchor:$_deviceId', '4000,1782043215');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 4096)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
    expect(await LocalDb.getCursor('oura_anchor:$_deviceId'), isNull,
        reason: 'the anchor was measured on the boot the reset ended');
  });

  test('the band-only readers cannot see a ring row', () async {
    await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(1782043215)),
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    final db = await LocalDb.instance;
    final banded = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_onehz WHERE source IS NULL',
    );
    expect(banded.first['c'], 0,
        reason: 'every derive/export read filters `source IS NULL`');
  });

  test('a bookmark past the end of the ring is dropped, not kept', () async {
    // The ring rebooted: its decisecond counter restarted below our bookmark,
    // so every request from there matches nothing while it quietly fills up.
    // Bytes remaining with nothing delivered is the signal, and the remedy is
    // to re-read from the beginning — free, because a re-read is idempotent.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    await OuraLink.instance.ingestForTest(_deviceId, _key, (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 4096)];
      return const <List<int>>[];
    }, nowSeconds: () => _nowSec);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('an empty ring keeps its bookmark', () async {
    // The other half of the same signal, and getting it wrong costs a full
    // re-read on every idle sync: no bytes left and nothing delivered is a ring
    // with nothing to give, not a stranded bookmark.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    await OuraLink.instance.ingestForTest(_deviceId, _key, (i, v) {
      if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
      if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
      if (v.first == 0x10) return [_summary(0, 0)];
      return const <List<int>>[];
    }, nowSeconds: () => _nowSec);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 9391523);
  });

  test('the key install is one frame, the key in the clear, 16 bytes', () {
    // It cannot be authenticated — it is what creates the credential the
    // handshake uses — so the whole of its safety is that a ring only accepts
    // one while it is factory reset.
    final frame = ouraCmdSetAuthKey(_key);
    expect(frame.first, 0x24);
    expect(frame[1], 16, reason: 'length counts payload bytes only');
    expect(frame.sublist(2), _key);
    expect(frame, hasLength(18));
    // A short or long key is a caller bug, not something to pad around: the
    // ring would latch whatever it was sent and only a factory reset undoes it.
    expect(() => ouraCmdSetAuthKey(const <int>[1, 2, 3]), throwsArgumentError);
    // Success is status 0; anything else, and silence, is a refusal.
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x25, 0x01, 0x00])!), 0);
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x25, 0x01, 0x02])!), 2);
    expect(ouraSetAuthKeyResult(parseOuraFrame(<int>[0x11, 0x01, 0x00])!), isNull);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await OuraLink.pairedRingRow(), isNull);
    expect(await OuraLink.instance.sync(), isFalse);
  });

  group('forgetRing', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kOura.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Ring',
      );
      expect(await OuraLink.pairedRingRow(), isNotNull);
      final ok = await OuraLink.forgetRing(_deviceId);
      expect(ok, isTrue);
      expect(await OuraLink.pairedRingRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await OuraLink.forgetRing(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await OuraLink.forgetRing('oura-never-paired');
      expect(ok, isTrue);
      expect(await OuraLink.pairedRingRow(), isNull);
    });
  });
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
