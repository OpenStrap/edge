// The Mi Band 2/3/4 HOST: scripted frames in, `raw_archive` out — and never
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
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
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
  if (v.length == 2 && v[0] == 0x02) return [_challengeFrame(_challenge)];
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
    expect(link.writes, hasLength(2));
    expect(link.writes.first.$2, <int>[0x02, 0x08]);
    expect(link.writes.last.$2.sublist(0, 2), <int>[0x03, 0x08]);
    // Nothing that could touch history or settings was ever written — there
    // is no builder for either on this path.
    expect(link.writes.every((w) => w.$2.first <= 0x03), isTrue);
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
}
