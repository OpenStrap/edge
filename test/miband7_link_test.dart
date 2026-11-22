// The Mi Band 7 HOST (`HelioStrapLink.miBand7`): scripted band in, database
// rows out, through the real `BandHost` and real sqlite. Pins where its data
// LANDS and that it never touches a paired Helio Strap's rows.
// `test/adapters/miband7_test.dart` pins what is decoded.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/helio_strap_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _bandId = 'zeppos_l66-0a1b2c3d';
const String _helioId = 'helio-11223344';
final DateTime _now = DateTime(2026, 10, 4, 12, 0);
int _nowSec() => _now.millisecondsSinceEpoch ~/ 1000;
final Uint8List _authKey = Uint8List.fromList(List.generate(16, (i) => i + 1));
final DateTime _roundStart = DateTime(_now.year, _now.month, _now.day, 6, 0);
const int _steps1 = 20, _hr1 = 65, _steps2 = 10;

List<int> _record(int steps, int hr) => [0, 0, steps & 0xff, hr & 0xff, 0, 0, 0, 0];

/// Real handshake, one activity round with data, every other type "no data".
List<(String, List<int>)> Function(int, String, List<int>) _bandScript() {
  final kp = keypairFrom(
      Uint8List.fromList(List.generate(24, (i) => (i * 7 + 3) % 256)));
  final remoteRandom =
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + 5) % 256));
  final decoder = Huami2021Decoder();
  final encoder = Huami2021Encoder();

  List<(String, List<int>)> auth(List<int> body) => [
        for (final c in encoder.encode(kHuami2021AuthEndpoint, body))
          (kHuami2021ChunkNotifyChar, c),
      ];

  return (index, char, value) {
    if (char == kHuami2021ChunkWriteChar) {
      final frame = decoder.feed(value, sessionKey: null);
      if (frame == null || frame.endpoint != kHuami2021AuthEndpoint) return [];
      final payload = frame.payload;
      if (payload.isNotEmpty && payload[0] == 0x04) {
        return auth([0x10, 0x04, 0x01, ...remoteRandom, ...kp.publicKey]);
      }
      if (payload.isNotEmpty && payload[0] == 0x05) return auth([0x10, 0x05, 0x01]);
      return [];
    }
    if (char != kHuami2021FetchControlChar || value.isEmpty) return [];
    if (value[0] == 0x01) {
      final hasData = value[1] == kHuami2021TypeActivity;
      final n = hasData ? 2 : 0;
      final rs = hasData ? _roundStart : DateTime(1970);
      return [
        (
          kHuami2021FetchControlChar,
          [
            0x10, 0x01, 0x01, n, 0, 0, 0,
            rs.year & 0xff, (rs.year >> 8) & 0xff, rs.month, rs.day,
            rs.hour, rs.minute, rs.second,
          ]
        ),
      ];
    }
    if (value.length == 1 && value[0] == 0x02) {
      return [
        (kHuami2021FetchDataChar, [0, ..._record(_steps1, _hr1)]),
        (kHuami2021FetchDataChar, [1, ..._record(_steps2, 0xff)]),
        (kHuami2021FetchControlChar, const [0x10, 0x02, 0x01]),
      ];
    }
    return [];
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'miband7_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  Future<void> sync() => HelioStrapLink.miBand7.ingestForTest(
        _bandId,
        _bandScript(),
        nowSeconds: _nowSec,
        authKeyReader: () async => _authKey,
      );

  test('the Mi Band 7 link drives the Mi Band 7 entry', () {
    expect(HelioStrapLink.miBand7.entry, kMiBand7);
    expect(HelioStrapLink.instance.entry, kHelioStrap);
  });

  test('HR lands in decoded_onehz under the band\'s own device id', () async {
    await sync();
    final db = await LocalDb.instance;
    final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
    expect(rows.map((r) => (r['rec_ts'], r['hr'], r['device_id'])), [
      (_roundStart.millisecondsSinceEpoch ~/ 1000, _hr1, _bandId),
    ]);
  });

  test('steps lands as a vendor observation attributed to Xiaomi', () async {
    await sync();
    final db = await LocalDb.instance;
    final rows =
        await db.query('observation', where: 'key = ?', whereArgs: ['steps']);
    expect(rows, hasLength(1));
    expect(rows.single['value'], _steps1 + _steps2);
    expect(rows.single['attribution'], 'Xiaomi');
  });

  test('every raw reply is banked under the band\'s own archive reason',
      () async {
    await sync();
    final db = await LocalDb.instance;
    final reasons = (await db.query(LocalDb.rawArchiveView, columns: ['reason']))
        .map((r) => r['reason'] as String)
        .toSet();
    expect(reasons, isNotEmpty);
    expect(reasons.every((r) => r.startsWith('zeppos_l66_0x')), isTrue,
        reason: '$reasons');
  });

  test('forgetting the band leaves a paired Helio Strap alone', () async {
    await LocalDb.upsertDevice(
        id: _bandId, adapterId: kMiBand7.id, remoteId: 'AA', label: kMiBand7.label);
    await LocalDb.upsertDevice(
        id: _helioId, adapterId: kHelioStrap.id, remoteId: 'BB', label: kHelioStrap.label);
    expect((await HelioStrapLink.miBand7.pairedRow())?['id'], _bandId);
    expect((await HelioStrapLink.pairedHelioStrapRow())?['id'], _helioId);

    expect(await HelioStrapLink.miBand7.forget(_bandId), isTrue);

    expect(await HelioStrapLink.miBand7.pairedRow(), isNull);
    expect((await HelioStrapLink.pairedHelioStrapRow())?['id'], _helioId);
  });
}
