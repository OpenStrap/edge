// The Mi Band 2/3 HOST: scripted frames in, `raw_archive` out — and never
// `decoded_onehz`, because nothing on this path is decoded.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one (owner
// ruling R6) and `flutter_blue_plus` has no simulator path, so the band below
// is a script. `miband234_test.dart` already proves the session state
// machine; this file exists for the three things only a host can get wrong:
// banking every byte with the archive tag stripped back off, attributing
// every row away from the primary band, and dropping a pairing key exactly
// once — never before a row points to it, never after.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show kHuamiActivityControlChar, kHuamiActivityDataChar;
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart'
    show activeWearableId;
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'miband234-0a1b2c3d';

/// Any 16 bytes — the replay band answers a scripted result rather than
/// actually verifying the AES block, so the VALUE of the key is not what is
/// under test here (`miband234_auth_crypto_test.dart` pins the cipher).
const List<int> _key = <int>[
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
];

const List<int> _challenge = <int>[
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, //
];

const int _nowSec = 1786000000;

List<int> _challengeFrame(List<int> c) => <int>[0x10, 0x02, 0x01, ...c];
List<int> _authResult(int status) => <int>[0x10, 0x03, status];

/// The band's reply script for a reconnect (key already installed).
List<List<int>> _reconnectReply(int i, List<int> v) {
  if (v[0] == 0x02) return [_challengeFrame(_challenge)];
  if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x01)];
  return const [];
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'miband_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test(
      'battery, steps and heart-rate notifications are banked with the '
      'archive tag stripped back off — hex is exactly the wire bytes',
      () async {
    final link = await MiBand234Link.instance.ingestForTest(
      _deviceId,
      _key,
      _reconnectReply,
      extra: const [
        (kHuami234BatteryChar, <int>[0x03, 84]),
        (kHuami234StepsChar, <int>[0x2a, 0x00, 0x00, 0x00]),
        (kHeartRateMeasurementUuid, <int>[0x00, 65]),
      ],
      nowSeconds: () => _nowSec,
    );
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'hex');
    expect(archive, hasLength(3));
    expect(
      archive.map((a) => a['reason']).toSet(),
      {'miband234_battery', 'miband234_steps', 'miband234_hr'},
    );
    // The tag is host-side bookkeeping, never part of the wire — the stored
    // hex is exactly what the (simulated) radio delivered.
    expect(archive.map((a) => a['hex']).toSet(), {'0354', '2a000000', '0041'});
    // Attributed away from the primary band, every row.
    for (final a in archive) {
      expect(a['device_id'], _deviceId);
      expect(a['device_id'], isNot(LocalDb.kPrimaryDeviceId));
    }
    // The auth handshake actually ran — this is not an empty session that
    // happened to have nothing to authenticate.
    expect(link.writes, isNotEmpty);
  });

  test('nothing here is ever a decoded sample', () async {
    await MiBand234Link.instance.ingestForTest(
      _deviceId,
      _key,
      _reconnectReply,
      extra: const [
        (kHuami234BatteryChar, <int>[0x03, 84]),
      ],
      nowSeconds: () => _nowSec,
    );
    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz');
    expect(onehz, isEmpty);
  });

  test('the host writes nothing off the auth characteristic that a key-write, '
      'a challenge request or a proved answer did not put there', () async {
    final link = await MiBand234Link.instance.ingestForTest(
      _deviceId,
      _key,
      _reconnectReply,
      nowSeconds: () => _nowSec,
    );
    // A reconnect: no key write, just request-then-prove.
    final auth = link.writes.where((w) => w.$1 == kHuami234AuthChar).toList();
    expect(auth, hasLength(2));
    expect(auth.first.$2, <int>[0x02, 0x00, 0x02]);
    expect(auth.last.$2.sublist(0, 2), <int>[0x03, 0x00]);
    // The band's drop-acknowledgement (0x03 on the activity-control
    // characteristic) is never sent.
    expect(
        link.writes.any((w) =>
            w.$1 == kHuamiActivityControlChar && w.$2.first == 0x03),
        isFalse);
  });

  // One history round of 4 minutes, the next round empty.
  List<(String, List<int>)> history(String char, List<int> v) {
    if (char != kHuamiActivityControlChar) return const [];
    if (v[0] == 0x01) {
      // Asked from Oct 1: the band answers with 4 minutes from Oct 3.
      final first = v[4] == 10 && v[5] == 1;
      return [
        (kHuamiActivityControlChar, [
          0x10, 0x01, 0x01, first ? 4 : 0, 0, 0, 0, //
          0xea, 0x07, 10, 3, 0, 0, 0, 0,
        ]),
      ];
    }
    return [
      (kHuamiActivityDataChar, [
        0, 1, 0, 0, 60, 1, 0, 0, 61, 1, 0, 0, 62, 1, 0, 0, 63, //
      ]),
      (kHuamiActivityControlChar, [0x10, 0x02, 0x01]),
    ];
  }

  test('the resume cursor is committed with the round\'s rows, or not at all',
      () async {
    final since = DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
    for (final id in [_deviceId, LocalDb.kPrimaryDeviceId]) {
      await LocalDb.setCursor('miband_since:$id', '$since');
    }
    await MiBand234Link.instance.ingestForTest(_deviceId, _key, _reconnectReply,
        history: history, nowSeconds: () => since + 4 * 86400);
    expect(await LocalDb.getCursorInt('miband_since:$_deviceId'),
        isNot(since), reason: 'committed with its rows');
    // The primary id is refused for these rows, so the commit fails, and the
    // cursor must stay where it was.
    await MiBand234Link.instance.ingestForTest(
        LocalDb.kPrimaryDeviceId, _key, _reconnectReply,
        history: history, nowSeconds: () => since + 4 * 86400);
    expect(await LocalDb.getCursorInt('miband_since:'), since);
  });

  test('a band that rejects the key is a failed sync that says re-pair, not '
      'a quiet success', () async {
    await MiBand234Link.instance.ingestForTest(_deviceId, _key, (i, v) {
      if (v[0] == 0x02) return [_challengeFrame(_challenge)];
      if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x04)];
      return const [];
    }, nowSeconds: () => _nowSec);
    expect(MiBand234Link.instance.lastSyncFailure,
        MiBand234SyncFailure.keyRejected);
  });

  test('a band that stops answering mid-handshake is told apart from a '
      'rejected key', () async {
    await MiBand234Link.instance.ingestForTest(
        _deviceId, _key, (i, v) => const [],
        nowSeconds: () => _nowSec);
    expect(MiBand234Link.instance.lastSyncFailure,
        MiBand234SyncFailure.authUnanswered);
  });

  test('an authenticated session leaves no failure behind', () async {
    await MiBand234Link.instance.ingestForTest(
        _deviceId, _key, (i, v) => const [],
        nowSeconds: () => _nowSec);
    await MiBand234Link.instance.ingestForTest(
        _deviceId, _key, _reconnectReply,
        nowSeconds: () => _nowSec);
    expect(MiBand234Link.instance.lastSyncFailure, isNull);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await MiBand234Link.pairedRow(), isNull);
    expect(await MiBand234Link.instance.sync(), isFalse);
  });

  group('forgetBand', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      expect(await MiBand234Link.pairedRow(), isNotNull);
      final ok = await MiBand234Link.forgetBand(_deviceId);
      expect(ok, isTrue);
      expect(await MiBand234Link.pairedRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await MiBand234Link.forgetBand(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await MiBand234Link.forgetBand('miband234-never-paired');
      expect(ok, isTrue);
      expect(await MiBand234Link.pairedRow(), isNull);
    });
  });
  // A re-pair (say after a factory reset to recover a lost key) used to mint
  // a fresh id beside the old row: syncs went to the new id while the active
  // wearable kept naming the old one, and the stale row held a sensor slot.
  group('re-pair keeps one row', () {
    test('a re-pair of the same band reuses its row id', () async {
      expect(miBandReusableDeviceId(const [], 'AA:BB:CC:DD:EE:FF'), isNull);
      expect(
        miBandReusableDeviceId([
          {
            'id': LocalDb.kPrimaryDeviceId,
            'adapter_id': kMiBand234.id,
            'remote_id': 'AA:BB:CC:DD:EE:FF',
          },
        ], 'AA:BB:CC:DD:EE:FF'),
        isNull,
      );
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      expect(await activeWearableId(), _deviceId);
      final reused = miBandReusableDeviceId(
          await LocalDb.deviceRows(), 'AA:BB:CC:DD:EE:FF');
      expect(reused, _deviceId);
      await LocalDb.upsertDevice(
        id: reused!,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      final bands = [
        for (final r in await LocalDb.deviceRows())
          if (r['adapter_id'] == kMiBand234.id) r['id'],
      ];
      expect(bands, [_deviceId]);
      expect((await MiBand234Link.pairedRow())!['id'],
          await activeWearableId());
    });

    // Pairing stores the new key under the id before the band proves it. A
    // second band borrowing a working band's id would, on a failure after it
    // took the key, leave the working band's row pointing at a key it never
    // had: every later sync would be refused until a factory reset.
    test('a different band never borrows a paired band\'s id', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      expect(
        miBandReusableDeviceId(
            await LocalDb.deviceRows(), '11:22:33:44:55:66'),
        isNull,
      );
    });

    test('a failed pairing keeps the paired band working', () {
      // A different band (fresh id): its key is an orphan however far the
      // attempt got, and the paired band's key was never touched.
      for (final installed in [false, true]) {
        for (final prior in [false, true]) {
          expect(
            miBandFailedPairKey(
                reused: false, keyInstalled: installed, hadPriorKey: prior),
            MiBandFailedPairKey.drop,
          );
        }
      }
      // The same band, failed before it took the new key: its old key is
      // still the one it answers to.
      expect(
        miBandFailedPairKey(
            reused: true, keyInstalled: false, hadPriorKey: true),
        MiBandFailedPairKey.restore,
      );
      expect(
        miBandFailedPairKey(
            reused: true, keyInstalled: false, hadPriorKey: false),
        MiBandFailedPairKey.drop,
      );
      // The same band, failed after it took the new key: the old one is dead.
      expect(
        miBandFailedPairKey(
            reused: true, keyInstalled: true, hadPriorKey: true),
        MiBandFailedPairKey.keep,
      );
    });

    test('forgetting a band drops its resume cursor', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      await LocalDb.setCursor('miband_since:$_deviceId', '$_nowSec');
      await MiBand234Link.forgetBand(_deviceId);
      expect(await LocalDb.getCursor('miband_since:$_deviceId'), isNull);
    });

    test('duplicates an older pairing left are found and forgotten', () async {
      const stale = 'miband234-aaaaaaaa';
      await LocalDb.upsertDevice(
        id: stale,
        adapterId: kMiBand234.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Band',
      );
      expect(await activeWearableId(), stale);
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kMiBand234.id,
        remoteId: '11:22:33:44:55:66',
        label: 'Band',
      );
      final ids = staleMiBandRowIds(await LocalDb.deviceRows(), _deviceId);
      expect(ids, [stale]);
      for (final id in ids) {
        await MiBand234Link.forgetBand(id);
      }
      expect(staleMiBandRowIds(await LocalDb.deviceRows(), _deviceId), isEmpty);
      expect(await activeWearableId(), _deviceId);
    });

    test('never names the primary band or another adapter', () {
      expect(
        staleMiBandRowIds([
          {'id': LocalDb.kPrimaryDeviceId, 'adapter_id': kMiBand234.id},
          {'id': 'oura-1', 'adapter_id': 'oura'},
          {'id': _deviceId, 'adapter_id': kMiBand234.id},
        ], _deviceId),
        isEmpty,
      );
    });
  });
}
