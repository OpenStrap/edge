// The Helio Strap HOST: scripted strap in, database rows out. Same shape as
// `colmi_link_test.dart` — this file pins where each decoded thing LANDS,
// `test/adapters/helio_strap_full_session_test.dart` pins what is decoded
// (and already proves the ECDH/AES handshake math agrees on both sides; this
// file reuses that same real-crypto script, through `HelioStrapLink`'s real
// `BandHost` and real sqlite instead of driving the adapter directly).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/helio_strap_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'helio-0a1b2c3d';
final DateTime _now = DateTime(2026, 10, 4, 12, 0);
int _nowSec() => _now.millisecondsSinceEpoch ~/ 1000;
final Uint8List _authKey =
    Uint8List.fromList(List.generate(16, (i) => i + 1));

Uint8List _aesEcb(Uint8List key, Uint8List data, bool encrypt) {
  final c = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

Uint8List _aesDecrypt(Uint8List k, Uint8List d) => _aesEcb(k, d, false);

final DateTime _activityRoundStart =
    DateTime(_now.year, _now.month, _now.day, 6, 0);
const int _steps1 = 20, _hr1 = 65, _steps2 = 10;

List<int> _activityRecord(int steps, int hr) =>
    [0, 0, steps & 0xff, hr & 0xff, 0, 0, 0, 0];

/// Real B-163/AES handshake, one real activity fetch round, every other
/// type "no data" — the exact script `helio_strap_full_session_test.dart`
/// proves agrees on both sides, restructured for `ingestForTest`'s
/// per-write callback shape (one call per write, return the replies it
/// provokes) instead of a standing event loop.
List<(String, List<int>)> Function(int, String, List<int>) _strapScript() {
  final deviceKeypair = keypairFrom(
      Uint8List.fromList(List.generate(24, (i) => (i * 7 + 3) % 256)));
  final remoteRandom =
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + 5) % 256));
  final strapDecoder = Huami2021Decoder();
  final strapEncoder = Huami2021Encoder();
  Uint8List? deviceSessionKey;

  List<int> fetchStartReply(int type) {
    final hasData = type == kHuami2021TypeActivity;
    final expected = hasData
        ? (_activityRecord(_steps1, _hr1).length +
                _activityRecord(_steps2, 0xff).length) ~/
            8
        : 0;
    final rs = hasData ? _activityRoundStart : DateTime(1970);
    return [
      0x10, 0x01, 0x01,
      expected & 0xff, (expected >> 8) & 0xff, (expected >> 16) & 0xff,
      (expected >> 24) & 0xff,
      rs.year & 0xff, (rs.year >> 8) & 0xff, rs.month, rs.day, rs.hour,
      rs.minute, rs.second,
    ];
  }

  return (index, char, value) {
    final out = <(String, List<int>)>[];
    if (char == kHuami2021ChunkWriteChar) {
      final frame = strapDecoder.feed(value, sessionKey: null);
      if (frame == null || frame.endpoint != kHuami2021AuthEndpoint) {
        return out;
      }
      final payload = frame.payload;
      if (payload.isNotEmpty && payload[0] == 0x04) {
        final phonePublicKey = payload.sublist(4, 4 + 48);
        final shared = sharedSecret(deviceKeypair.privateKey, phonePublicKey);
        deviceSessionKey = Uint8List(16);
        for (var i = 0; i < 16; i++) {
          deviceSessionKey![i] = shared[i + 8] ^ _authKey[i];
        }
        final step2 = Uint8List.fromList(
            [0x10, 0x04, 0x01, ...remoteRandom, ...deviceKeypair.publicKey]);
        for (final chunk in strapEncoder.encode(kHuami2021AuthEndpoint, step2)) {
          out.add((kHuami2021ChunkNotifyChar, chunk));
        }
      } else if (payload.isNotEmpty && payload[0] == 0x05) {
        final authProof = _aesDecrypt(_authKey, payload.sublist(1, 17));
        final sessionProof =
            _aesDecrypt(deviceSessionKey!, payload.sublist(17, 33));
        expect(authProof, remoteRandom,
            reason: 'proof block 1 must decrypt under the shared auth key');
        expect(sessionProof, remoteRandom,
            reason: 'proof block 2 must decrypt under the derived session '
                'key — proves the ECDH math matches on both sides');
        final step5 = Uint8List.fromList([0x10, 0x05, 0x01]);
        for (final chunk in strapEncoder.encode(kHuami2021AuthEndpoint, step5)) {
          out.add((kHuami2021ChunkNotifyChar, chunk));
        }
      }
      return out;
    }
    if (char == kHuami2021FetchControlChar) {
      if (value.isNotEmpty && value[0] == 0x01) {
        out.add((kHuami2021FetchControlChar, fetchStartReply(value[1])));
      } else if (value.length == 1 && value[0] == 0x02) {
        var counter = 0;
        for (final r in [
          _activityRecord(_steps1, _hr1),
          _activityRecord(_steps2, 0xff),
        ]) {
          out.add((kHuami2021FetchDataChar, [counter++, ...r]));
        }
        out.add((kHuami2021FetchControlChar, const [0x10, 0x02, 0x01]));
      }
    }
    return out;
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'helio_strap_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  Future<void> sync() => HelioStrapLink.instance.ingestForTest(
        _deviceId,
        _strapScript(),
        nowSeconds: _nowSec,
        authKeyReader: () async => _authKey,
      );

  test('HR lands in decoded_onehz under source helio_strap, outside derivation',
      () async {
    await sync();
    final db = await LocalDb.instance;
    final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
    final roundStartSec = _activityRoundStart.millisecondsSinceEpoch ~/ 1000;
    expect(rows.map((r) => (r['rec_ts'], r['hr'])), [
      (roundStartSec, _hr1),
    ], reason: 'the second minute\'s hr=0xff sentinel yields no row');
    for (final r in rows) {
      expect(r['device_id'], _deviceId);
    }
  });

  test('steps lands as a vendor observation attributed to Amazfit', () async {
    await sync();
    final db = await LocalDb.instance;
    final rows = await db.query('observation',
        where: 'key = ?', whereArgs: ['steps']);
    expect(rows, hasLength(1));
    expect(rows.single['value'], _steps1 + _steps2);
    expect(rows.single['attribution'], 'Amazfit');
    expect(rows.single['source_kind'], 'vendor');
  });

  test('no auth key: nothing is written and sync reports failure', () async {
    final ok = await HelioStrapLink.instance.ingestForTest(
      _deviceId,
      (i, c, v) => const [],
      nowSeconds: _nowSec,
      authKeyReader: () async => null,
    ).then((link) => link.writes.isEmpty);
    expect(ok, isTrue);
    final db = await LocalDb.instance;
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(HelioStrapLink.instance.lastSyncFailed, isTrue);
  });
}
