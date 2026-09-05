// The Withings Steel HR / Activité HOST: scripted device in, `raw_archive`
// out, the `firstConnect` bookmark flipped only once a session actually
// authenticated.
//
// NOTHING HERE HAS MET HARDWARE. `withings_steel_hr_adapter_test.dart`
// already proves the session state machine; this file exists for the two
// things only a host can get wrong: banking every byte with a name a future
// decoder can find, and not clearing the one bit of session state this band
// persists on the strength of a mere connection attempt.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart'
    show kWithingsSteelHr;
import 'package:openstrap_edge/ble/adapters/withings_steel_hr.dart';
import 'package:openstrap_edge/ble/withings_steel_hr_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'withings_steel_hr-0a1b2c3d';
const String _mac = 'AA:BB:CC:DD:EE:FF';
final List<int> _deviceNonce = List<int>.generate(16, (i) => i);

List<List<int>> _asChunks(Uint8List message) =>
    chunkWithingsMessage(message).map((c) => c.toList()).toList();

/// A scripted device answering the real challenge-response, verbatim. Also
/// answers a bare INITIAL_CONNECT with one arbitrary follow-up message, so
/// the no-auth path has something to prove archiving with too.
List<List<int>> Function(int, List<int>) _device({bool authenticates = true}) {
  final reassembler = WithingsReassembler();
  return (int i, List<int> chunk) {
    final complete = reassembler.feed(chunk);
    if (complete == null) return const <List<int>>[];
    final msg = parseWithingsMessage(complete)!;
    if (msg.type == kWithingsMsgInitialConnect) {
      return _asChunks(buildWithingsMessage(3000, const []));
    }
    if (msg.type == kWithingsMsgProbe && msg.struct(kWithingsStructProbe) != null) {
      return _asChunks(buildWithingsMessage(kWithingsMsgChallenge, [
        buildChallengeStruct(_mac, _deviceNonce),
      ]));
    }
    if (msg.type == kWithingsMsgChallenge) {
      if (!authenticates) return const <List<int>>[]; // stays silent
      final theirs = msg.struct(kWithingsStructChallenge)!;
      final (_, hostNonce) = parseChallengeStruct(theirs.payload)!;
      final answer = withingsChallengeResponse(hostNonce, _mac);
      return _asChunks(buildWithingsMessage(kWithingsMsgProbe, [
        buildChallengeResponseStruct(answer),
      ]));
    }
    return const <List<int>>[];
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'withings_steel_hr_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('a fresh device sends only INITIAL_CONNECT, and banks whatever '
      'answers it', () async {
    final link = await WithingsSteelHrLink.instance.ingestForTest(
      _deviceId,
      true,
      _device(),
    );
    expect(link.writes, hasLength(1));
    final sent = parseWithingsMessage(Uint8List.fromList(link.writes.single.$2))!;
    expect(sent.type, kWithingsMsgInitialConnect);
    expect(sent.structs, isEmpty);
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'captured_at, hex');
    expect(archive, hasLength(1));
    expect(archive.first['reason'], 'withings_msg_0xbb8'); // 3000 == 0xbb8
    expect(archive.first['device_id'], _deviceId);
  });

  test('the firstConnect flag clears only once the session actually '
      'authenticated', () async {
    expect(await LocalDb.getCursor('withings_steel_hr_first_connect:$_deviceId'),
        isNull);
    await WithingsSteelHrLink.instance.ingestForTest(_deviceId, true, _device());
    expect(await LocalDb.getCursor('withings_steel_hr_first_connect:$_deviceId'),
        '0');
  });

  test('a resumed session authenticates and banks a message that follows, '
      'with a reason naming its own message type — but nothing from the '
      'handshake itself', () async {
    final reassembler = WithingsReassembler();
    List<List<int>> device(int i, List<int> chunk) {
      final complete = reassembler.feed(chunk);
      if (complete == null) return const <List<int>>[];
      final msg = parseWithingsMessage(complete)!;
      if (msg.type == kWithingsMsgProbe &&
          msg.struct(kWithingsStructProbe) != null) {
        return _asChunks(buildWithingsMessage(kWithingsMsgChallenge, [
          buildChallengeStruct(_mac, _deviceNonce),
        ]));
      }
      if (msg.type == kWithingsMsgChallenge) {
        final theirs = msg.struct(kWithingsStructChallenge)!;
        final (_, hostNonce) = parseChallengeStruct(theirs.payload)!;
        final answer = withingsChallengeResponse(hostNonce, _mac);
        // The probe reply that closes the handshake, PLUS one arbitrary
        // follow-up message — a real device pushing something unprompted
        // once the session is live, which the harness can only script as a
        // second logical message riding the same reply.
        return [
          ..._asChunks(buildWithingsMessage(kWithingsMsgProbe, [
            buildChallengeResponseStruct(answer),
          ])),
          ..._asChunks(buildWithingsMessage(2000, const [])),
        ];
      }
      return const <List<int>>[];
    }

    await WithingsSteelHrLink.instance.ingestForTest(_deviceId, false, device);
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'captured_at, hex');
    // Nothing from the handshake itself is archived — only what comes after
    // it, same as `oura.dart` never banking its own auth frames.
    expect(archive, hasLength(1));
    expect(archive.first['reason'], 'withings_msg_0x7d0'); // 2000 == 0x7d0
    expect(archive.first['device_id'], _deviceId);
  });

  test('a device that never answers the challenge is never treated as '
      'authenticated', () async {
    // firstConnect: false is what a resumed connection actually passes —
    // whether that flag gets written at all is the thing under test.
    await WithingsSteelHrLink.instance
        .ingestForTest(_deviceId, false, _device(authenticates: false));
    // The cursor is untouched, not merely "still false": this branch never
    // calls setCursor, because the session never earned the note that gates
    // it.
    expect(await LocalDb.getCursor('withings_steel_hr_first_connect:$_deviceId'),
        isNull);
    final db = await LocalDb.instance;
    expect(await db.query('raw_archive'), isEmpty,
        reason: 'the session never got past the handshake');
  });

  test('a paired row is found by adapter id', () async {
    await LocalDb.upsertDevice(
      id: _deviceId,
      adapterId: kWithingsSteelHr.id,
      remoteId: 'AA:BB:CC:DD:EE:FF',
      label: 'Withings Steel HR',
    );
    final row = await WithingsSteelHrLink.pairedRow();
    expect(row?['id'], _deviceId);
  });

  test('forgetting a device clears its firstConnect cursor, not just the '
      'device row — a re-pair mints the same id and must not inherit a '
      'stale "already past first connect" bookmark', () async {
    await LocalDb.upsertDevice(
      id: _deviceId,
      adapterId: kWithingsSteelHr.id,
      remoteId: _mac,
      label: 'Withings Steel HR',
    );
    await LocalDb.setCursor('withings_steel_hr_first_connect:$_deviceId', '0');
    await WithingsSteelHrLink.forgetDevice(_deviceId);
    expect(await LocalDb.deviceRow(_deviceId), isNull);
    expect(await LocalDb.getCursor('withings_steel_hr_first_connect:$_deviceId'),
        isNull);
  });
}
