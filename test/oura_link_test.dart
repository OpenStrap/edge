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

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart'
    show ReplayBandLink;
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

  test(
      'trailing bytes after a valid frame are not a second frame, and the '
      'raw_archive row keeps them byte-exact',
      () async {
    // One notification carries exactly one frame; the ring may append bytes
    // past the declared length. Here the trailing bytes look like a whole
    // second temperature frame. Checked on the actual `raw_archive` and
    // `decoded_onehz` rows: one temperature second, not two, and one archive
    // row holding the whole notification as delivered.
    const syncUnix = 1782043215;
    final anchor = _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix));
    final temp = _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436));
    final trailing = _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436));
    final withTrailing = <int>[...temp, ...trailing];
    final r = await _run([
      [anchor, withTrailing, _summary(2, 0)]
    ]);
    expect(r.onehz, hasLength(1),
        reason: 'the trailing bytes are not read as a second record');
    expect(r.archive, hasLength(2));
    final hexes = r.archive.map((a) => a['hex']).toSet();
    expect(hexes, {_hexOf(anchor), _hexOf(withTrailing)},
        reason: 'one row per notification, trailing bytes kept');
    expect(r.archive.map((a) => a['reason']).toSet(),
        {'oura_evt_0x42', 'oura_evt_0x69'});
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

  test('a notification with an over-long event is still banked, under its '
      'first byte', () async {
    // 19 declared bytes: past the 18 a standard event can carry, so nothing in
    // it is trusted for decoding. The bytes are banked all the same.
    final overLong = _frame(0x60, List<int>.filled(19, 0x11));
    final r = await _run([
      [
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        overLong,
        _summary(1, 0),
      ],
    ]);
    expect(r.archive, hasLength(2));
    final row = r.archive.singleWhere((a) => a['reason'] == 'oura_evt_0x60');
    expect(row['packet_type'], 0x60);
    expect(row['hex'],
        overLong.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
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
            force: w[1] == 0x0a,
          ),
        _ => ouraCmdGetEvents(
            w[2] | (w[3] << 8) | (w[4] << 16) | (w[5] << 24),
            maxEvents: w[6],
          ),
      };
      expect(w, rebuilt);
    }
  });

  test('the stranded reset still lands when an advance is queued ahead of it',
      () async {
    // Batch 1 advances the cursor, batch 2 is stranded; the reset is queued
    // behind the advance and must still be the write that lands.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first != 0x10) return const <List<int>>[];
        final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
        if (cursor == 5000) {
          return [
            _event(kOuraEvtTimeSync, 5000, _syncBody(1782043215)),
            _event(kOuraEvtTempPeriod, 5100, _hex(_temp3436)),
            _summary(2, 512),
          ];
        }
        return [_summary(0, 4096)];
      },
      nowSeconds: () => _nowSec,
    );
    // The reset landed despite the advance queued ahead of it.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('a stranded reset invalidates the stored time anchor too', () async {
    // The anchor was measured on the boot the reset ended.
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

  test('a ring that answers below the bookmark never moves it', () async {
    // Replays below the bookmark must not move it backwards.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtTimeSync, 4900, _syncBody(1782043215)),
            _event(kOuraEvtTempPeriod, 4999, _hex(_temp3436)),
            _summary(2, 0),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 5000);
  });

  test('a ring start that restarted the counter clears the stored origin',
      () async {
    await LocalDb.setCursor('oura_anchor:$_deviceId', '5000000,1782043215');
    await _run([
      [
        _event(kOuraEvtRingStart, 10, const [4, 0, 0, 0, 0x02]),
        _summary(1, 0),
      ],
    ]);
    final stored = await LocalDb.getCursor('oura_anchor:$_deviceId');
    expect(stored == null || stored.isEmpty, isTrue,
        reason: 'the dead boot\'s origin must not stamp the new boot');
  });

  test(
      'the PRODUCTION teardown closes the replay link, not the harness '
      '(Fix B)',
      () async {
    // FIX B: `_replaySession` registers the replay link as `_link`, exactly
    // as `startSessionForTest` and the production `_sync` do — so the
    // session's own teardown (`stop()` → `_link?.close()`) really closes
    // it. Without the registration, `_link` is null at teardown and ONLY
    // the harness's unconditional fallback close below closes the link —
    // masking, in every replay test, the exact code path a real sync runs.
    //
    // THE ORDERING PROOF, deterministic — no clock: the session result
    // future (`done`) completes only after `_runSessionAndTeardown`'s
    // `finally { await stop(); }`, and `stop()` only completes after its
    // `await closing` — so the teardown's close is ENTERED before the
    // serving loop can exit and before the harness fallback close runs.
    // Parking the close at the `closeGate` seam therefore freezes the world
    // at exactly that point: `closeCount == 1` (the TEARDOWN'S close) while
    // the session result is still unsettled proves the teardown — not the
    // harness — owns the close. Releasing the gate lets the whole chain
    // finish; the harness's fallback close then runs as the SECOND close
    // (harmless: channels already cleared), which is the honest total.
    final gate = Completer<void>();
    ReplayBandLink? held;
    final ok = OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      onLink: (l) {
        held = l;
        l.closeGate = gate;
      },
    );
    final link = held!;
    // The teardown's close ENTRY, awaited on the link's own completer — the
    // close completes it the moment the production teardown reaches it.
    await link.closeEntered;
    // THE TEARDOWN'S close is parked — and it is the ONLY one so far.
    expect(link.closeCount, 1,
        reason: 'the production teardown entered the link close first');
    expect(link.closed, isTrue,
        reason: 'the close entered: the refusal is in force');
    var settled = false;
    ok.then((_) => settled = true, onError: (_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse,
        reason: 'the result is chained behind stop()\'s awaited close — '
            'it cannot settle while the close is parked');
    // Release the close: the teardown finishes, the session result settles,
    // the serving loop exits, and the harness fallback close runs SECOND.
    gate.complete();
    expect(await ok, isTrue);
    expect(link.closeCount, 2,
        reason: 'teardown close + harness fallback close — and the fallback '
            'is harmless on an already-closed link');
    expect(OuraLink.instance.hostForTest, isNull);
  });

  test('a drain that reaches the end reports the session as synced', () async {
    // An empty, up-to-date ring is a SUCCESSFUL sync — the honest end of a
    // drain, with no measurement invented. The expectation is on the SAME
    // bool `sync()` returns: `_replaySession` runs `_runSession`, the
    // production result path, so this pins the `return true` a user's
    // "Synced." snackbar is built on.
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(ok, isTrue);
  });

  test('a refused authentication reports the session as NOT synced', () async {
    // Auth-Abbruch: the ring answers the challenge with a refusal. Nothing
    // was fetched, so `sync()` must say so — not "Synced.".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) {
          return [_frame(0x2f, _hex('2e01'))];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse);
  });

  test('a drain that never gets its batch reports the session as NOT synced',
      () async {
    // The ring authenticates and then goes quiet: the history request is
    // never answered. Connected, but nothing was synced — `sync()` must say
    // so rather than report "Synced.", which is the exact symptom a user
    // sees as "the ring connects but no data arrives".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        // 0x1c (notify flags), 0x12 (time sync) and 0x10 (history) all go
        // unanswered; the session ends on the reply window, not on data.
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse);
  });

  test('success then failure across two consecutive attempts', () async {
    // The result flag must be PER SESSION, not a sticky latch: a successful
    // first sync must not make a second, failed one report success — the
    // §4.3 sticky-boolean pattern this repo keeps shipping.
    final first = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(first, isTrue);
    final second = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(second, isFalse);
  });

  test('a refused write reports the session as NOT synced', () async {
    // Verweigerter Write: the ring refuses the nonce request (flat battery,
    // wedged stack). The session ends on the adapter's own `return false`
    // path — `_authenticate` refuses to carry on unauthenticated — so the
    // result must be false, not "Synced.".
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) => const <List<int>>[],
      nowSeconds: () => _nowSec,
      writeSucceeds: false,
    );
    expect(ok, isFalse);
  });

  test('a failed durable commit reports the session as NOT synced', () async {
    // A real commit failure, not just a missing confirm: the host runs into the
    // production-side guard assertion in `commitSyncBatch` (neutral rows under
    // the primary device id), which throws INSIDE the real transaction.
    // `BandHost._commitLocked` treats every exception as a commit failure and
    // buffers back, so this assertion stands in for any transaction failure.
    //
    // LIMIT OF THIS INJECTION: the public `sync()` method already refuses the
    // primary device id BEFORE any session (`_sync`'s guard). The test reaches
    // the deeper in-transaction failure through the test seam. There is no
    // production-side fault injection on `LocalDb` for a storage failure under
    // a permitted Oura device id; such a seam would be a refactor beyond the
    // scope of this test.
    //
    // THE CONFIRM IS ONLY INDIRECTLY OBSERVABLE: the protocol has no ACK write;
    // `OffloadCheckpoint.confirm()` is a purely internal callback. The only
    // wire-visible proof of a CONFIRMED batch is the second history request,
    // and that happens ONLY when `bytesLeft > 0` (adapter loop). That is why
    // this batch reports bytes as remaining: after a confirmed commit the
    // adapter WOULD have to ask again; after a failed commit every further
    // write stays out. The control case in the next test shows the assertion
    // really tells the two paths apart.
    await LocalDb.setCursor(
        'oura_anchor:${LocalDb.kPrimaryDeviceId}', '1000,1782043215');
    final ok = await OuraLink.instance.syncResultForTest(
      LocalDb.kPrimaryDeviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          // A batch with data remaining: only a CONFIRMED confirm leads to the
          // second history request.
          return [
            _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
            _summary(1, 4096),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(ok, isFalse, reason: 'the commit failed — no durable data, no '
        'confirm, so no success');
    final link = OuraLink.instance.lastReplayLink!;
    // NO SECOND HISTORY REQUEST: the confirm never ran, so every further write
    // stayed out. (A confirmed batch WITH bytesLeft > 0 would necessarily have
    // produced a second 0x10 write; see the control case.)
    final writes = [for (final w in link.writes) w.$2];
    expect(writes.where((w) => w.first == 0x10), hasLength(1),
        reason: 'the failed commit must end the session before the loop '
            'asks again');
    // Cursor never moved: the cursor note fires only after a confirmed batch.
    expect(
      await LocalDb.getCursorInt('oura_cursor_ds:${LocalDb.kPrimaryDeviceId}'),
      isNull,
    );
    // Nothing from the failed transaction reached the table.
    final db = await LocalDb.instance;
    expect(
      await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [LocalDb.kPrimaryDeviceId]),
      isEmpty,
    );
  });

  // ── Time anchor / re-drain scenarios (the #2455 shape, made honest) ──
  test(
      'RE-DRAIN A: same events, same anchor — REPLACE collapses, nothing '
      'duplicates',
      () async {
    // Scenario A: the ring re-delivers IDENTICAL events under the SAME
    // anchor. The primary key (device_id, ts_ms) makes the second delivery
    // REPLACE the first — one row, not two, and the value is the same one.
    const syncUnix = 1782043215;
    final batch = [
      _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
      _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
      _summary(2, 0),
    ];
    final first = await _run([batch]);
    expect(first.onehz, hasLength(1));
    final second = await _run([batch]);
    expect(second.onehz, hasLength(1),
        reason: 'the same second under the same anchor is ONE row, not two');
    expect(second.onehz.first['rec_ts'], first.onehz.first['rec_ts'],
        reason: 'the same anchor maps the same decisecond to the same '
            'wall-clock second — no drift between deliveries');
  });

  test(
      'RE-DRAIN B: same events, CHANGED anchor — the rows re-stamp, the '
      'record count stays honest',
      () async {
    // Scenario B: the anchor the session measures DIFFERS between two
    // deliveries of the same events (e.g. the ring rebooted and its uptime
    // restarted; the second sync's time_sync pairs a new decisecond with a
    // new Unix second). The rows under (device_id, ts_ms) are keyed by the
    // NEW stamp: if the two anchors disagree on the same decisecond, the
    // two deliveries write DIFFERENT keys — two rows for one physiological
    // second, the exact #2455 shape. This test PINS today's behaviour
    // honestly: it exists so the day a real capture shows a re-anchored
    // re-drain, the duplicate is caught here first, by counts and values,
    // not by a user's chart.
    const syncUnix1 = 1782043215;
    const syncUnix2 = 1782043215 + 3600; // one hour apart
    final first = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix1)),
        _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    // Second session: the ring re-delivers the SAME deciseconds, but this
    // sync's own time_sync measures a DIFFERENT Unix second for them. A
    // re-delivery only reaches the host once the bookmark is gone (a reset
    // re-read): with the cursor in place the adapter drops every replayed
    // decisecond and nothing re-stamps at all.
    await LocalDb.deleteCursor('oura_cursor_ds:$_deviceId');
    final second = await _run([
      [
        _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix2)),
        _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    // HONEST PIN of today's behaviour: both deliveries stamp their own
    // anchor, so the same physiological decisecond exists under BOTH
    // wall-clock seconds — two rows. A schema-level record identity is the
    // only fix for that, and it needs a migration plan and an explicit
    // approval — NOT a speculative change here.
    expect(first.onehz, hasLength(1));
    expect(second.onehz, hasLength(2));
    expect(second.onehz.last['rec_ts'], isNot(first.onehz.first['rec_ts']),
        reason: 'a changed anchor re-stamps the same decisecond — the '
            '#2455 duplicate shape, pinned here as a KNOWN gap');
  });

  test(
      'RE-DRAIN C/D: a session aborted after a confirmed batch resumes '
      'from the persisted boundary',
      () async {
    // Scenario C + D in one honest flow: the first sync delivers a batch,
    // it is confirmed and committed — and then the ring stops answering
    // (bytesLeft > 0 but no second batch). The cursor HAS advanced past the
    // confirmed batch; the session reports not-synced. The second sync must
    // resume from the persisted boundary: it asks from the advanced cursor,
    // and the re-delivered tail does not duplicate what the first session
    // already committed.
    const syncUnix = 1782043215;
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (cursor == 0) {
            return [
              _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
              _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
              _summary(2, 512),
            ];
          }
          // The second ask: the ring goes silent (protocol timeout).
          return const <List<int>>[];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    // The first batch's boundary IS persisted: the confirmed cursor.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 1101);
    final db = await LocalDb.instance;
    expect(
        (await db.query('decoded_onehz',
                columns: ['count(*) as n'],
                where: "device_id = '$_deviceId'"))
            .first['n'],
        1,
        reason: 'the aborted session kept its confirmed batch');
    // RESUME: the second session asks from 1101 — the re-delivered tail
    // below that boundary never re-banks, and the new data stamps on.
    final second = await _run([
      [
        // Replayed tail (below 1101) plus the new event.
        _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
        _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    expect(second.onehz, hasLength(2),
        reason: 'the resumed session keeps the committed row and adds the '
            'new one — the replayed tail neither duplicates nor shifts');
    expect(
        second.onehz.map((r) => r['rec_ts']).toSet(),
        hasLength(2),
        reason: 'two distinct seconds — no key collision from the replay');
  });

  test(
      'RE-DRAIN G: a ring counter reset strands the bookmark — the '
      're-read starts from zero',
      () async {
    // Scenario G: the ring reboots, its decisecond counter restarts near
    // zero, and the stored bookmark points past everything it holds. The
    // stranded-cursor reset drops the bookmark so the NEXT sync re-reads
    // from the beginning — the re-read is idempotent by the (device_id,
    // ts_ms) key, so nothing duplicates.
    const syncUnix = 1782043215;
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await LocalDb.setCursor('oura_anchor:$_deviceId', '4000,${syncUnix - 100}');
    final first = await _run([
      [
        // The new boot's records, all far below the 5000 bookmark.
        _event(kOuraEvtTimeSync, 100, _syncBody(syncUnix)),
        _event(kOuraEvtTempPeriod, 200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    // The bookmark was stranded and reset — nothing was decoded under it.
    expect(first.onehz, isEmpty,
        reason: 'the stranded bookmark keeps everything below it out');
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0,
        reason: 'the stranded reset dropped the bookmark for the re-read');
    // THE RE-READ: same records, now from cursor 0, stamped by the stored
    // anchor the reset invalidated and the session re-measured.
    final second = await _run([
      [
        _event(kOuraEvtTimeSync, 100, _syncBody(syncUnix)),
        _event(kOuraEvtTempPeriod, 200, _hex(_temp3436)),
        _summary(2, 0),
      ],
    ]);
    expect(second.onehz, hasLength(1),
        reason: 'the re-read banks the new boot\'s records exactly once');
  });

  test(
      'RE-DRAIN H: a DIFFERENT physical ring never sees the old ring\'s '
      'cursor or anchor',
      () async {
    // Scenario H: another ring pairs under a DIFFERENT device id. Its
    // cursor and anchor items are its own — the old ring's bookmark and
    // origin are invisible to it, and its rows are keyed under its own id.
    const other = 'oura-ffeeddcc';
    const syncUnix = 1782043215;
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '5000');
    await LocalDb.setCursor('oura_anchor:$_deviceId', '4000,$syncUnix');
    await OuraLink.instance.ingestForTest(
      other,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          final cursor = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          // The other ring starts from ITS OWN cursor: zero.
          expect(cursor, 0,
              reason: 'the new ring\'s first ask is from ITS zero — the '
                  'old ring\'s 5000 bookmark never leaked across ids');
          return [
            _event(kOuraEvtTimeSync, 100, _syncBody(syncUnix)),
            _event(kOuraEvtTempPeriod, 200, _hex(_temp3436)),
            _summary(2, 0),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    // Its rows are its own: the old ring's id has none.
    final db = await LocalDb.instance;
    expect(
        (await db.query('decoded_onehz',
                columns: ['count(*) as n'],
                where: "device_id = '$other'"))
            .first['n'],
        greaterThan(0),
        reason: 'the other ring banked its own row under its own id');
    expect(
        (await db.query('decoded_onehz',
                columns: ['count(*) as n'],
                where: "device_id = '$_deviceId'"))
            .first['n'],
        0,
        reason: 'the old ring\'s table rows are untouched by the new ring');
    expect(await LocalDb.getCursor('oura_anchor:$other'), isNotNull,
        reason: 'the other ring measured its own anchor');
  });

  test('FAULT E: an injected durable-commit failure under a LEGAL ring id',
      () async {
    // This test sets the fault FIRST (the correct order) and proves the
    // whole chain: commit throws, batch re-buffers, cursor NEVER advances,
    // no drain-ok, NOT synced, honest category.
    const syncUnix = 1782043215;
    OuraLink.instance.commitFaultForTest = (commit) async {
      // NOT calling commit() is the point: the injected fault replaces the
      // durable commit entirely, exactly like a database that refused the
      // transaction. The restore-on-failure path in `BandHost`'s catch runs
      // for it the same as for a genuine failure.
      throw StateError('injected durable-commit failure (test seam)');
    };
    try {
      final ok = await OuraLink.instance.syncResultForTest(
        _deviceId,
        _key,
        (i, v) {
          if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
          if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
          if (v.first == 0x10) {
            return [
              _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
              _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
              _summary(2, 0),
            ];
          }
          return const <List<int>>[];
        },
        nowSeconds: () => _nowSec,
        // 5s protocol budget < 30s harness budget: the failed commit parks
        // the adapter on the confirm timeout, and that wait must end in a
        // NORMAL false — never in the harness watchdog's StateError.
        timeouts: const Duration(seconds: 5),
        harnessTimeout: const Duration(seconds: 30),
      );
      expect(ok, isFalse, reason: 'a failed durable commit is NOT a success');
      final db = await LocalDb.instance;
      expect(
          (await db.query('decoded_onehz',
                  columns: ['count(*) as n'],
                  where: "device_id = '$_deviceId'"))
              .first['n'],
          0,
          reason: 'the failed commit left no rows behind');
      expect(
        await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'),
        isNull,
        reason: 'the cursor must remain exactly at the previous boundary — '
            'the cursor note only fires after a confirmed batch',
      );
      expect(
        OuraLink.instance.lastSyncCategory,
        OuraSyncCategory.storageFailed,
        reason: 'the host observed the commit failure; the later generic '
            'unconfirmed-checkpoint note must not replace it',
      );
      final link = OuraLink.instance.lastReplayLink!;
      final historyWrites = link.writes
          .where((w) => w.$2.isNotEmpty && w.$2.first == 0x10);
      expect(
        historyWrites,
        hasLength(1),
        reason: 'an unconfirmed failed batch must not advance the drain',
      );
      expect(
        OuraLink.instance.hostForTest,
        isNull,
        reason: 'the failed session must complete host cleanup',
      );
    } finally {
      OuraLink.instance.commitFaultForTest = null;
    }

    // The follow-up attempt WITHOUT the fault must succeed cleanly: the
    // failure category is session-scoped and must not stick.
    final ok2 = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          return [
            _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
            _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
            _summary(2, 0),
          ];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(seconds: 5),
      harnessTimeout: const Duration(seconds: 30),
    );
    expect(ok2, isTrue,
        reason: 'a follow-up sync without the fault must succeed');
    expect(OuraLink.instance.lastSyncCategory, OuraSyncCategory.drained,
        reason: 'the successful follow-up reports drained — the storage '
            'failure never leaks into the next session');
    final db = await LocalDb.instance;
    expect(
        (await db.query('decoded_onehz',
                columns: ['count(*) as n'],
                where: "device_id = '$_deviceId'"))
            .first['n'],
        greaterThan(0),
        reason: 'the successful follow-up durably stored its rows');
    expect(
      await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'),
      isNotNull,
      reason: 'the successful follow-up advanced the cursor',
    );
  });

  test('an unconfirmed checkpoint does not hide an observed commit failure',
      () async {
    // NOTE-PRIORITY, driven through the production handler: the generic
    // `oura_batch_unconfirmed` must not overwrite a commit failure the
    // host actually observed, but alone (no known failure) it stays the
    // honest `checkpointUnconfirmed`.
    final link = OuraLink.instance;

    Future<bool> runEmptySuccessfulSession() => link.syncResultForTest(
          _deviceId,
          _key,
          (i, v) {
            if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
            if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
            if (v.first == 0x10) return [_summary(0, 0)];
            return const <List<int>>[];
          },
          nowSeconds: () => _nowSec,
          timeouts: const Duration(seconds: 5),
          harnessTimeout: const Duration(seconds: 30),
        );

    // A clean session first, so the category is a known baseline.
    expect(await runEmptySuccessfulSession(), isTrue);
    expect(link.lastSyncCategory, OuraSyncCategory.drained);

    // No known persistence failure: the generic category is appropriate.
    link.handleSyncNoteForTest('oura_batch_unconfirmed');
    expect(
      link.lastSyncCategory,
      OuraSyncCategory.checkpointUnconfirmed,
      reason: 'without an observed commit failure the unconfirmed '
          'checkpoint is the honest category',
    );

    // The host now reports an observed durable commit failure.
    link.handleSyncNoteForTest('host_commit_failed');
    expect(
      link.lastSyncCategory,
      OuraSyncCategory.storageFailed,
      reason: 'the observed commit failure is the specific truth',
    );

    // A later generic note must preserve the more specific cause.
    link.handleSyncNoteForTest('oura_batch_unconfirmed');
    expect(
      link.lastSyncCategory,
      OuraSyncCategory.storageFailed,
      reason: 'the generic unconfirmed-note must not overwrite the '
          'observed commit failure',
    );

    // A new real session resets the old category.
    expect(await runEmptySuccessfulSession(), isTrue);
    expect(
      link.lastSyncCategory,
      OuraSyncCategory.drained,
      reason: 'a new session starts clean — no failure category sticks '
          'across sessions',
    );
  });

  test(
      'FAULT F: a cursor-persistence failure leaves the durable data, '
      'reports NOT synced, and never claims a moved bookmark',
      () async {
    // Scenario F: the commit LANDS (the rows are durable) but the cursor
    // write throws. The honest outcome: NOT synced (the drain never
    // completed its checkpoint chain), rows present, cursor unchanged.
    const syncUnix = 1782043215;
    OuraLink.instance.cursorFaultForTest = (item, value) async {
      throw StateError('injected cursor-persistence failure (test seam)');
    };
    try {
      final ok = await OuraLink.instance.syncResultForTest(
        _deviceId,
        _key,
        (i, v) {
          if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
          if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
          if (v.first == 0x10) {
            return [
              _event(kOuraEvtTimeSync, 1000, _syncBody(syncUnix)),
              _event(kOuraEvtTempPeriod, 1100, _hex(_temp3436)),
              _summary(2, 0),
            ];
          }
          return const <List<int>>[];
        },
        nowSeconds: () => _nowSec,
        harnessTimeout: const Duration(seconds: 10),
      );
      expect(ok, isFalse,
          reason: 'a session whose checkpoint chain broke is NOT a success');
      final db = await LocalDb.instance;
      expect(
          (await db.query('decoded_onehz',
                  columns: ['count(*) as n'],
                  where: "device_id = '$_deviceId'"))
              .first['n'],
          greaterThan(0),
          reason: 'the durable commit DID land — the data is safe');
      expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), isNull,
          reason: 'the cursor never persisted — the next sync re-reads, '
              'which is idempotent and honest');
    } finally {
      OuraLink.instance.cursorFaultForTest = null;
    }
  });

  test('a CATEGORY never leaks into the next attempt', () async {
    // The reset proof: a failing session sets a category; the NEXT
    // attempt, failing EARLY (auth refusal), reports the NEW category;
    // a session that never reaches a note (empty reply script, refused
    // write) reports `none`, not the stale previous one.
    final refused = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) {
          return [_frame(0x2f, _hex('2e01'))];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      timeouts: const Duration(milliseconds: 50),
    );
    expect(refused, isFalse);
    expect(OuraLink.instance.lastSyncCategory, OuraSyncCategory.authRefused);
    // A WRITE-refused session (writeSucceeds: false) must NOT still report
    // the auth refusal: the new session starts clean.
    final writeRefused = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) => const <List<int>>[],
      nowSeconds: () => _nowSec,
      writeSucceeds: false,
      harnessTimeout: const Duration(seconds: 10),
    );
    expect(writeRefused, isFalse);
    expect(OuraLink.instance.lastSyncCategory, isNot(OuraSyncCategory.authRefused),
        reason: 'the category describes THIS session, not the previous one');
    // And a successful clean session reports `drained`.
    final drained = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(drained, isTrue);
    expect(OuraLink.instance.lastSyncCategory, OuraSyncCategory.drained);
  });

  test('a confirmed batch with bytes left DOES ask again (control case)',
      () async {
    // CONTROL CASE: the same ring reply (1 event, bytesLeft > 0) under a
    // PERMITTED Oura device id with a successful commit. The adapter MUST make
    // the second history request here; only that makes the failure test's
    // single-request assertion real proof that the confirm did not happen, and
    // not just the normal end sequence of a final batch.
    await LocalDb.setCursor('oura_anchor:$_deviceId', '1000,1782043215');
    var batches = 0;
    final ok = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) {
          batches++;
          if (batches == 1) {
            return [
              _event(kOuraEvtTempPeriod, 1200, _hex(_temp3436)),
              _summary(1, 4096),
            ];
          }
          return [_summary(0, 0)];
        }
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    // The session only ends here on the second pass (second batch: summary(0,0)
    // → drain ok). Result true, and there was more than one history request:
    // the proof of the confirm.
    expect(ok, isTrue);
    final link = OuraLink.instance.lastReplayLink!;
    final writes = [for (final w in link.writes) w.$2];
    expect(writes.where((w) => w.first == 0x10).length, greaterThan(1),
        reason: 'the confirmed batch advanced the loop — this is the '
            'behaviour the failed-commit test proves was MISSING');
    // And the cursor actually grew.
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 1201);
  });

  group('session lifecycle (the production outer order)', () {
    test('cleanup waits for a successful session, then runs', () async {
      // FULL HANDSHAKE CONTROL, no scheduler randomness: the observer runs from
      // the start, and every ring reply is fed only AFTER the matching write
      // was observed; the completers are completed synchronously in `onWrite`.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
      );
      // Nonce request observed → answer with the challenge.
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      // Proof write observed → the ring accepts the key.
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      // History request observed → HOLD BACK the reply.
      await historyAsked.future;
      // OPEN SESSION: cleanup must not have started yet. THIS IS EXACTLY WHERE
      // THIS TEST CATCHES A PREMATURE TEARDOWN in `_runSessionAndTeardown`
      // itself (a `finally` that runs before the session ends): `stop()` would
      // already have closed the link and cancelled the subscription while the
      // drain is still waiting for its reply. LIMIT: the outer `_sync` body
      // (connect, discovery) cannot be tested without a radio and is NOT
      // covered here.
      expect(link.closed, isFalse, reason: 'teardown must not have begun');
      expect(link.isListening(kOuraNotifyChar), isTrue,
          reason: 'the session still owns the notify subscription');
      var settled = false;
      result.then((_) => settled = true);
      // One microtask turn so the `.then` can attach; no sleep, the ordering is
      // already fixed by the assertions above.
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse,
          reason: 'the session is still open — the result is not settled');

      // The final reply: empty and up to date.
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      final ok = await result;
      expect(ok, isTrue);
      // CLEANUP RAN, after the session ended.
      expect(link.closed, isTrue, reason: 'stop() closed the link');
      expect(link.isListening(kOuraNotifyChar), isFalse,
          reason: 'the host cancelled its run subscription on the way out');
    });

    test('cleanup also runs after a failing session', () async {
      // The same outer flow for the failure path. The proof observer is the
      // same instance and ran BEFORE the challenge was fed, the ordering the
      // reviewer asked for.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          }
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      expect(link.closed, isFalse,
          reason: 'the session is still mid-handshake');
      // Refuse the authentication: result 1 = wrong key.
      link.feed(kOuraNotifyChar, _frame(0x2f, _hex('2e01')),
          atSec: _nowSec);
      final ok = await result;
      expect(ok, isFalse);
      expect(link.closed, isTrue,
          reason: 'stop() ran after the failed session ended');
      expect(link.isListening(kOuraNotifyChar), isFalse);
    });

    test('the second stop() of the session path is a harmless no-op',
        () async {
      // `_sync` keeps its outer `finally { await stop(); }` for the early
      // returns (Bluetooth off, missing characteristics) and the exception
      // paths, so stop() runs twice on the session path: once in
      // `_runSessionAndTeardown`, once in the outer finally. This test pins
      // that the second call is safe: no throw, no cursor corruption, no
      // leftover state.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      expect(await result, isTrue);
      // The first stop() ran in the session teardown; this is the second.
      await OuraLink.instance.stop();
      expect(link.closed, isTrue, reason: 'still closed — no re-open');
      expect(link.isListening(kOuraNotifyChar), isFalse);
    });

    test(
        'a failing link close still stops the host, and surfaces after cleanup',
        () async {
      // Thread-1 review: stop() must not blindly await close() (closing the
      // replay channel can wait on a consumer that only ends with host.stop()),
      // BUT the close error must not stay an unobserved Future either. This
      // test pins both: the session runs to completion normally, its teardown
      // calls stop(), close() FAILS, and the host still stops, the error throws
      // WITH a stack trace, and the field state is clean afterwards. The seam
      // throws only AFTER the work is done (flags, gates, channels), so the
      // refusal is really in force; the error is purely about observing the
      // failure.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      ReplayBandLink? sessionLink;
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
        onLink: (l) {
          sessionLink = l;
          l.closeThrows = true;
        },
      );
      final hostBefore = OuraLink.instance.hostForTest;
      expect(hostBefore, isNotNull, reason: 'the session owns a live host');
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      // The session completed HONESTLY, but its teardown's stop() hit the
      // failing close: sessionThrew is false, so the teardown failure
      // PROPAGATES through the result future with its own stacktrace —
      // the documented error priority. Awaiting the result therefore
      // throws; cleanup observables are checked AFTER, proving the host
      // teardown ran DESPITE the close failure.
      await expectLater(
          result,
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message',
              contains('replay link close failure'))));
      expect(OuraLink.instance.hostForTest, isNull,
          reason: 'host cleanup ran DESPITE the link close failure');
      expect(sessionLink!.closed, isTrue,
          reason: 'the link really closed — the seam threw after the work');
    });

    test(
        'stop() stays pending until the link close fully completes '
        '(Fix A)', () async {
      // FIX A: stop() STARTS the link close (refusal in force at once), does
      // the host shutdown and the remaining cleanup, and only then AWAITS the
      // close future before reporting the teardown complete. This test parks
      // the close at the `closeGate` seam — after the flags and gates are
      // already in force — and proves stop() (and the session result chained
      // behind it) stays pending for exactly that awaited close, never
      // reporting success while the close is still running.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final gate = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
        onLink: (l) {
          // Park the link close: the close ENTERS (flags set, refusal in
          // force) but does not finish until this test releases it.
          l.closeGate = gate;
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      // The session ended and the teardown STARTED — the close entered (its
      // synchronous refusal is in force) — but it is PARKED. The confirm
      // chain before it runs on REAL sqflite I/O, so the close's ENTRY is
      // awaited on the link's own `closeEntered` completer — the close
      // itself completes it, deterministically, the moment it runs.
      await link.closeEntered;
      expect(link.closed, isTrue,
          reason: 'the teardown started — the close entered');
      expect(link.closeCount, 1,
          reason: 'the close ran exactly once — it is parked INSIDE it');
      var settled = false;
      result.then((_) => settled = true, onError: (_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse,
          reason: 'stop() must stay pending until the close completes');
      // Release the close: NOW the teardown can finish.
      gate.complete();
      final ok = await result;
      expect(ok, isTrue);
      expect(OuraLink.instance.hostForTest, isNull,
          reason: 'the host teardown ran before stop() reported completion');
    });

    test(
        'a DELAYED close failure surfaces only after the full cleanup '
        '(Fix A)', () async {
      // FIX A, error path: a close that fails LATE — after stop()'s captured
      // error checks would have passed in the old code — must still surface
      // with its own error, and only after every cleanup step ran.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final gate = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
        onLink: (l) {
          l.closeGate = gate;
          l.closeThrows = true;
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      gate.complete();
      // The session ended honestly; the teardown's close FAILED. The result
      // future (sessionThrew = false) propagates the teardown failure.
      await expectLater(
          result,
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message',
              contains('replay link close failure'))));
      // The full cleanup ran despite the failure.
      expect(OuraLink.instance.hostForTest, isNull,
          reason: 'host cleanup ran despite the close failure');
      expect(link.closeCount, 1);
    });

    test('a re-entrant stop() shares the ONE running cleanup (Fix A)',
        () async {
      // FIX A, re-entrancy: a second stop() while the first teardown is
      // parked inside the link close must WAIT on the same running cleanup —
      // neither double-running it nor returning early against a half-torn
      // state. `closeCount` staying 1 is the no-double-teardown proof;
      // BOTH futures completing only after the gate release is the
      // no-premature-completion proof.
      final nonceAsked = Completer<void>();
      final proofAsked = Completer<void>();
      final historyAsked = Completer<void>();
      final gate = Completer<void>();
      final (result, link) = await OuraLink.instance.startSessionForTest(
        _deviceId,
        _key,
        nowSeconds: () => _nowSec,
        onWrite: (uuid, value) {
          if (value.first == 0x2f && value[2] == 0x2b) {
            if (!nonceAsked.isCompleted) nonceAsked.complete();
          } else if (value.first == 0x2f && value[2] == 0x2d) {
            if (!proofAsked.isCompleted) proofAsked.complete();
          } else if (value.first == 0x10) {
            if (!historyAsked.isCompleted) historyAsked.complete();
          }
        },
        onLink: (l) {
          l.closeGate = gate;
        },
      );
      await nonceAsked.future;
      link.feed(kOuraNotifyChar, _nonceReply, atSec: _nowSec);
      await proofAsked.future;
      link.feed(kOuraNotifyChar, _authOk, atSec: _nowSec);
      await historyAsked.future;
      link.feed(kOuraNotifyChar, _summary(0, 0), atSec: _nowSec);
      // The teardown's close ENTRY, awaited on the link's own completer —
      // the confirm chain before it is real sqflite I/O, so the entry
      // itself is the deterministic signal (see the Fix A test above).
      await link.closeEntered;
      expect(link.closeCount, 1,
          reason: 'the session teardown entered its close');
      // The second stop() — the re-entrant caller — while the first is
      // parked inside the close.
      final secondStop = OuraLink.instance.stop();
      var secondDone = false;
      secondStop.then((_) => secondDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse,
          reason: 'the second stop() must not report completion early');
      gate.complete();
      final ok = await result;
      expect(ok, isTrue);
      await secondStop;
      expect(secondDone, isTrue);
      // ONE teardown ran: the close was entered exactly once across both
      // callers, and no cleanup step ran a second time.
      expect(link.closeCount, 1,
          reason: 'the shared cleanup ran once — no double teardown');
      expect(OuraLink.instance.hostForTest, isNull);
    });

    // MATRIX GAP, documented honestly instead of tested speculatively:
    // "host stop throws" has NO injectable production path today —
    // `BandHost._commitLocked` catches commit failures itself (returns
    // false, re-buffers, logs), so the primary-device guard used by the
    // commit-failure test does NOT make `host.stop()` throw. The remaining
    // `stop()` code (cursor flush, disconnect, field clears) running after
    // a host failure is therefore guarded in `OuraLink.stop`'s own
    // try/catch around `host.stop()`, verified statically — a fault seam
    // for it would be a new test-only production hook, which this round
    // excludes ("no further architecture extension").
  });

  test(
      'a session held open at a CONCRETE step fails the HARNESS, '
      'it does not return false',
      () async {
    // TEST-WATCHDOG: `onTimeout: () => false` alone would let a negative
    // test's `isFalse` expectation pass on a HANG — the exact greenwash the
    // review called out. The wedge here is NOT a 1 ms patience racing
    // execution speed: the session's FIRST write (the auth nonce) parks at
    // a completer the test never completes. The session is genuinely,
    // deterministically stuck mid-handshake — the exact "ring that never
    // answers" the watchdog exists for. `gateEntered` proves the session
    // actually reached the held step BEFORE the watchdog judges it, so the
    // verdict cannot depend on machine speed either way.
    ReplayBandLink? heldLink;
    final ok = OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      harnessTimeout: const Duration(seconds: 2),
      onLink: (link) {
        heldLink = link;
        link.writeGate = Completer<void>();
      },
    );
    final link = heldLink!;
    // The session reached the held step (its first write parked) ...
    await link.gateEntered;
    // ... and it is stuck there for real: not closed, still subscribed,
    // and no write made it past the gate.
    expect(link.closed, isFalse);
    expect(link.isListening(kOuraNotifyChar), isTrue);
    expect(link.writes, isEmpty,
        reason: 'the held step is the FIRST write — the session is parked '
            'mid-handshake, not past it');
    await expectLater(ok, throwsA(isA<StateError>()));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a wedged session cleans up before the harness failure surfaces',
      () async {
    // CLEANUP ON THE TIMEOUT PATH TOO: the watchdog must run the same
    // teardown a normal path would (link closed, host stopped, cursor
    // writes flushed, fields cleared) BEFORE the StateError surfaces, so
    // a wedged session never leaves a half-torn OuraLink behind. Same
    // deterministic wedge as the test above: the first write parks at a
    // completer that is never completed.
    try {
      await OuraLink.instance.syncResultForTest(
        _deviceId,
        _key,
        (i, v) {
          if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
          if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
          if (v.first == 0x10) return [_summary(0, 0)];
          return const <List<int>>[];
        },
        nowSeconds: () => _nowSec,
        harnessTimeout: const Duration(seconds: 2),
        onLink: (link) => link.writeGate = Completer<void>(),
      );
      fail('the wedged session must have thrown, not returned');
    } on StateError {
      // expected: the harness failure, AFTER cleanup ran
    }
    // Cleanup observables: the wedged session's link was closed by the
    // harness teardown — and close() RELEASED the parked write (the gate
    // completer), so the session could actually unwind instead of hanging
    // `BandHost.stop`'s cancel() forever. The session's host is stopped
    // and cleared BEFORE the harness failure surfaces: no half-torn
    // state left behind.
    expect(OuraLink.instance.lastReplayLink!.closed, isTrue,
        reason: "the harness closed the wedged session's link on the "
            'timeout path');
    expect(OuraLink.instance.hostForTest, isNull,
        reason: 'cleanup ran BEFORE the harness failure surfaced: the '
            "session's host is stopped and cleared");
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'a wedged session ENDS (not hangs) and a follow-up sync is unaffected',
      () async {
    // THE CLEANUP HANG PATH, made observable: attempt 1's first write parks
    // at a gate; the harness watchdog expires, and its link.close() must
    // RELEASE that gate — the ONLY way the parked write (and behind it
    // `BandHost.stop`'s `cancel()`, which waits for the adapter generator
    // to unwind) can ever end. Proof that the old session ACTUALLY
    // finished, not a sleep loop: the harness's `done` future only
    // completes after the session's own teardown ran
    // (`_runSessionAndTeardown`'s finally), so awaiting the (throwing)
    // verdict IS the completion proof. A follow-up session then runs to
    // its honest success on the same ring — the serialized production
    // reality, no artificial overlap.
    final gate = Completer<void>();
    ReplayBandLink? wedgedLink;
    final firstAttempt = OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
      harnessTimeout: const Duration(seconds: 2),
      onLink: (link) {
        wedgedLink = link;
        link.writeGate = gate;
      },
    );
    // The session parked at its first write — proof, not a timer.
    await wedgedLink!.gateEntered;
    // The watchdog fires: harness deadline expired with the session
    // unfinished. AWAITING the throw is the proof the session ENDED —
    // done completes only after the session's own finally ran, and the
    // finally could only run because close() released the gate.
    await expectLater(firstAttempt, throwsA(isA<StateError>()));
    expect(wedgedLink!.closed, isTrue,
        reason: "the harness closed the wedged session's link — and its "
            'gate with it, so the session could unwind');
    expect(OuraLink.instance.hostForTest, isNull,
        reason: "the wedged session's host is stopped and cleared — its "
            'cleanup completed, not hang');
    // FOLLOW-UP: a plain, successful session on the SAME ring, AFTER the
    // wedged one fully ended — the serialized reality. It must succeed
    // on its own terms, with no residue of the wedged attempt.
    final second = await OuraLink.instance.syncResultForTest(
      _deviceId,
      _key,
      (i, v) {
        if (v.first == 0x2f && v[2] == 0x2b) return [_nonceReply];
        if (v.first == 0x2f && v[2] == 0x2d) return [_authOk];
        if (v.first == 0x10) return [_summary(0, 0)];
        return const <List<int>>[];
      },
      nowSeconds: () => _nowSec,
    );
    expect(second, isTrue,
        reason: 'the follow-up session must succeed on its own terms — '
            'the wedged attempt left no residue');
    expect(OuraLink.instance.lastReplayLink!.closed, isTrue,
        reason: "the follow-up session's own teardown ran");
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a closed replay link refuses new writes', () async {
    // THE CLOSE CONTRACT, EXACTLY AS SPECIFIED: a new write after close
    // returns false and is NOT recorded. The check runs BEFORE onWrite
    // and BEFORE the writes list — a write an adapter attempted past its
    // teardown must leave no trace that could read as a real session write
    // or fire an observer that assumes a live session.
    final link = ReplayBandLink();
    await link.close();

    final accepted = await link.write(
      kOuraCommandChar,
      <int>[0x10],
    );

    expect(accepted, isFalse);
    expect(link.writes, isEmpty);
  });

  test('a replay write parked at a GATE is refused when close beats it',
      () async {
    // The gate sits BEFORE the writes record: a write that is parked at the
    // gate has NOT been accepted or recorded yet. So when close() runs while
    // the write is parked, write() must return BEFORE recording — the link
    // never records a write that met a closed link, at any await boundary.
    // NOT a claim that a GATT platform write behaves identically — the
    // real link's refusal is checked inside its write chain, before the
    // operation is handed to the plugin; what this pins is the CONTRACT
    // (a closed link never reports success nor records a write that meets
    // it after close), which the replay link and the real link must both
    // honour, each in its own implementation.
    final gate = Completer<void>();
    final link = ReplayBandLink()..writeGate = gate;
    final inFlight = link.write(kOuraCommandChar, <int>[0x10]);
    // The write is parked at the gate — proof, not a timer.
    await link.gateEntered;
    // close() WHILE the write is parked: the immediate refusal goes into
    // force under the in-flight write, and close() itself completes the
    // gate — the parked write is released by the close, never by the
    // test completing an already-completed completer (complete is not
    // idempotent).
    await link.close();
    expect(gate.isCompleted, isTrue,
        reason: 'close() released the gate — the parked write woke up by '
            'itself, not because the test completed the completer');
    expect(await inFlight, isFalse,
        reason: 'a write that was parked when the link closed must not '
            'report success afterwards');
    expect(link.writes, isEmpty,
        reason: 'the gate sits before the record — a refused, never '
            'recorded write');
  });

  test('a closed replay link does not WAIT at an open gate', () async {
    // A link that is closed BEFORE a write even starts must refuse the
    // write IMMEDIATELY — not park it at a still-open gate, where the
    // write would hang until something completes the completer. The
    // gate is installed AFTER close, so close() cannot have completed
    // it: only the early writesRefused check can return this write
    // without ever touching the gate.
    final link = ReplayBandLink();
    await link.close();

    final gate = Completer<void>();
    link.writeGate = gate;

    var writeObserved = false;
    link.onWrite = (_, _) {
      writeObserved = true;
    };

    try {
      final accepted = await link
          .write(kOuraCommandChar, <int>[0x10])
          .timeout(const Duration(seconds: 5));

      expect(
        accepted,
        isFalse,
        reason: 'a closed link must refuse the write',
      );

      expect(
        gate.isCompleted,
        isFalse,
        reason: 'the refusal must not release the open gate',
      );

      expect(
        writeObserved,
        isFalse,
        reason: 'a refused write must not reach the write observer',
      );

      expect(
        link.writes,
        isEmpty,
        reason: 'a refused write must not be recorded',
      );
    } finally {
      // Cleanup only: release a gate the write parked at (the regression)
      // so its future ends instead of leaking past the test. All
      // assertions above have already run by then.
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  });

  test('a replay write parked at its DELAY ends on close, not on the clock',
      () async {
    // Thread-2 review, the ISOLATED path: only ReplayBandLink, no OuraLink, no
    // sqflite, no harness stopwatch. close() interrupts the delay wait via the
    // close signal: writeDelay runs longer than any test budget, and the write
    // ends false LONG before the delay elapses. The PR rationale (fake_async
    // cannot test the HARNESS path because of real sqflite FFI I/O and a real
    // stopwatch) applies to the session path; this test involves neither.
    final link = ReplayBandLink()..writeDelay = const Duration(days: 1);
    final inFlight = link.write(kOuraCommandChar, <int>[0x10]);
    // One pump starts the delay wait (the write already recorded).
    await Future<void>.delayed(Duration.zero);
    await link.close();
    final accepted = await inFlight;
    expect(accepted, isFalse,
        reason: 'close must interrupt the delay wait, not wait a day for it');
    expect(link.writes, hasLength(1),
        reason: 'the write was recorded BEFORE the delay — the record stays, '
            'the VERDICT is refusal (the same rule as a GATT write already '
            'handed to the plugin queue)');
  });

  test('the close contract separates immediate refusal from completed '
      'shutdown', () async {
    // (b) the refusal is in force IMMEDIATELY (synchronously at the top
    // of close), a separate thing from (c) the awaited, asynchronous
    // stream shutdown. `writesRefused` is the synchronous half, `closed`
    // plus a gone listener the completed half.
    final link = ReplayBandLink();
    final sub = link.notify(kOuraNotifyChar).listen((_) {});
    expect(link.writes, isEmpty);
    // BEFORE close: writes go through.
    expect(await link.write(kOuraNotifyChar, [0x01]), isTrue);
    expect(link.writes, hasLength(1));
    await link.close();
    // (b) immediate refusal, already in force at the top of close:
    expect(link.writesRefused, isTrue,
        reason: 'the write refusal must be synchronous, not "once the '
            'closes finish"');
    // (c) the asynchronous shutdown COMPLETED: channels closed, listener
    // gone.
    expect(link.closed, isTrue);
    expect(link.isListening(kOuraNotifyChar), isFalse);
    await sub.cancel();
    // (a) writes after close: refused, and NOT recorded.
    expect(await link.write(kOuraNotifyChar, [0x02]), isFalse,
        reason: 'the close contract: no writes after close');
    expect(link.writes, hasLength(1),
        reason: 'a refused write must not be recorded');
  });

  test('a stranded bookmark reports the session as NOT synced', () async {
    // A bookmark past the end of the ring is a recoverable fault (the next
    // sync re-reads from zero), but THIS session synced nothing: reporting it
    // as "Synced." would hide the fault behind a success message.
    await LocalDb.setCursor('oura_cursor_ds:$_deviceId', '9391523');
    final ok = await OuraLink.instance.syncResultForTest(
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
    expect(ok, isFalse);
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), 0);
  });

  test('a sleep-stage row stamped in the future is refused', () async {
    await LocalDb.setCursor('oura_anchor:$_deviceId', '0,$_nowSec');
    await _run([
      [
        _event(kOuraEvtSleepPhaseData, 10, _hex('000055aaff')),
        _event(kOuraEvtSleepPhaseData, 10000000, _hex('010055aaff')),
        _summary(2, 0),
      ],
    ]);
    // Vendor scalars are banked off the commit chain; wait for them.
    final db = await LocalDb.instance;
    var rows = <Map<String, Object?>>[];
    for (var i = 0; i < 200 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rows = await db.query('observation');
    }
    expect(rows, hasLength(4));
    expect(rows.every((r) => r['ts_ms'] == (_nowSec + 1) * 1000), isTrue,
        reason: 'the stage row a million seconds out is not written');
  });

  test("a night whose rows did not bank leaves the cursor put", () async {
    await LocalDb.setCursor('oura_anchor:$_deviceId', '0,$_nowSec');
    // The hypnogram write fails; the sample commit would still land.
    await (await LocalDb.instance).execute('DROP TABLE vendor_sleep_epoch');
    await OuraLink.instance.ingestForTest(
      _deviceId,
      _key,
      _ring([
        [
          _event(kOuraEvtTempPeriod, 5, _hex(_temp3436)),
          _event(kOuraEvtSleepPhaseData, 10, _hex('000055aaff')),
          _summary(2, 0),
        ],
      ]),
      nowSeconds: () => _nowSec,
      // The confirm never comes; do not wait the full window for it.
      timeouts: const Duration(seconds: 1),
    );
    expect(await LocalDb.getCursorInt('oura_cursor_ds:$_deviceId'), isNull,
        reason: 'confirming would move past a night that is not banked');
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
