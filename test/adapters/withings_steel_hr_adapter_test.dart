// The Withings Steel HR / Activité session, replayed through
// [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE, and it is not the decode — there is none, on
// purpose (see `withings_steel_hr.dart`'s own header):
//
//   * a fresh pairing takes the no-auth INITIAL_CONNECT path and nothing else;
//   * a resumed connection runs the real challenge-response — the device's
//     nonce answered with the real SHA1, and the device's own answer to the
//     HOST's nonce actually verified before the session is trusted;
//   * a wrong answer from the device ends the session unauthenticated;
//   * every reassembled post-handshake message reaches `raw` verbatim,
//     including one that arrives split across more than one notification —
//     proving the inbound reassembler, not just the single-packet case.
//
// Nothing here has met hardware. It proves the state machine, not the watch.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show kWithingsWriteChar;
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/withings_steel_hr.dart';

const String _mac = 'AA:BB:CC:DD:EE:FF';
final List<int> _deviceNonce = List<int>.generate(16, (i) => i);

/// Short enough that a deliberately-unanswered wait does not stall CI.
const Duration _kFast = Duration(milliseconds: 50);

WithingsSteelHrAdapter _adapter({required bool firstConnect}) =>
    WithingsSteelHrAdapter(firstConnect: firstConnect, replyTimeout: _kFast);

List<List<int>> _asChunks(Uint8List message) =>
    chunkWithingsMessage(message).map((c) => c.toList()).toList();

/// A scripted device: reassembles the host's outbound writes exactly the way
/// a real one would, and answers once a logical message completes.
class _ScriptedDevice {
  final WithingsReassembler _reassembler = WithingsReassembler();
  final List<WithingsMessage> received = [];

  /// Set true to answer the challenge with the WRONG secret, so a test can
  /// prove the mismatch is caught rather than waved through.
  bool wrongAnswer = false;

  /// Bytes to feed back as notifications, or nothing for "no reply yet".
  List<List<int>> onWrite(List<int> chunk) {
    final complete = _reassembler.feed(chunk);
    if (complete == null) return const [];
    final msg = parseWithingsMessage(complete)!;
    received.add(msg);
    if (msg.type == kWithingsMsgProbe && msg.struct(kWithingsStructProbe) != null) {
      // The host's opening probe. Reply with our own CHALLENGE.
      final challenge = buildWithingsMessage(kWithingsMsgChallenge, [
        buildChallengeStruct(_mac, _deviceNonce),
      ]);
      return _asChunks(challenge);
    }
    if (msg.type == kWithingsMsgChallenge) {
      // The host answered our challenge and proposed its own nonce. Read the
      // nonce back out so the reply proves the SAME secret without this test
      // hardcoding a value the adapter generated at random.
      final theirChallenge = msg.struct(kWithingsStructChallenge)!;
      final (_, hostNonce) = parseChallengeStruct(theirChallenge.payload)!;
      final answer = wrongAnswer
          ? Uint8List(20) // 20 zero bytes — the right length, the wrong value
          : withingsChallengeResponse(hostNonce, _mac);
      final probeReply = buildWithingsMessage(kWithingsMsgProbe, [
        buildChallengeResponseStruct(answer),
      ]);
      return _asChunks(probeReply);
    }
    return const [];
  }
}

Future<(List<BandEvent>, ReplayBandLink, _ScriptedDevice)> _drive(
  WithingsSteelHrAdapter adapter, {
  List<List<int>> Function()? afterAuth,
}) async {
  final link = ReplayBandLink();
  final device = _ScriptedDevice();
  final events = <BandEvent>[];
  final done = Completer<void>();
  var authNoted = false;
  final sub = adapter.run(link).listen(
        (e) {
          events.add(e);
          if (!authNoted && e is BandNote && e.key == 'withings_session_ready') {
            authNoted = true;
            if (afterAuth != null) {
              for (final f in afterAuth()) {
                link.feed(kWithingsWriteChar, f, atSec: 1786000000);
              }
            }
          }
        },
        onDone: () => done.complete(),
      );
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    await Future<void>.delayed(Duration.zero);
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in device.onWrite(w.$2)) {
        link.feed(kWithingsWriteChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link, device);
}

/// Reassemble every write the host sent, in order, back into messages — the
/// same job [_ScriptedDevice] does live, used here just to assert on the
/// shape of what went out.
List<WithingsMessage> _reassembleWrites(List<(String, List<int>)> writes) {
  final r = WithingsReassembler();
  final out = <WithingsMessage>[];
  for (final w in writes) {
    final complete = r.feed(w.$2);
    if (complete != null) {
      final m = parseWithingsMessage(complete);
      if (m != null) out.add(m);
    }
  }
  return out;
}

void main() {
  test('a fresh pairing sends only INITIAL_CONNECT — no probe, no challenge',
      () async {
    final (events, link, device) = await _drive(_adapter(firstConnect: true));
    final sent = _reassembleWrites(link.writes);
    expect(sent, hasLength(1));
    expect(sent.single.type, kWithingsMsgInitialConnect);
    expect(sent.single.structs, isEmpty);
    // The device sees it (nothing here has met hardware, but the harness
    // did reassemble it) — it just never provokes a reply, so nothing past
    // it happens.
    expect(device.received.map((m) => m.type).toList(),
        [kWithingsMsgInitialConnect]);
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'withings_session_ready'),
      isTrue,
      reason: 'the no-auth path is itself the gate passing',
    );
  });

  test('a resumed connection runs probe -> challenge -> verified response',
      () async {
    final (events, link, device) = await _drive(_adapter(firstConnect: false));
    expect(device.received.map((m) => m.type).toList(),
        [kWithingsMsgProbe, kWithingsMsgChallenge]);
    // The host's own challenge reuses the device's macAddress verbatim.
    final ourChallengeMsg =
        _reassembleWrites(link.writes).firstWhere((m) => m.type == kWithingsMsgChallenge);
    final ourChallenge = parseChallengeStruct(
        ourChallengeMsg.struct(kWithingsStructChallenge)!.payload)!;
    expect(ourChallenge.$1, _mac);
    expect(
      events.whereType<BandNote>().any((n) => n.key == 'withings_session_ready'),
      isTrue,
    );
  });

  test('a wrong answer from the device ends the session unauthenticated',
      () async {
    final link = ReplayBandLink();
    final device = _ScriptedDevice()..wrongAnswer = true;
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = _adapter(firstConnect: false).run(link).listen(
          events.add,
          onDone: () => done.complete(),
        );
    var served = 0;
    for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        final w = link.writes[served];
        for (final f in device.onWrite(w.$2)) {
          link.feed(kWithingsWriteChar, f, atSec: 1786000000);
        }
        served++;
      }
    }
    await link.close();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    await sub.cancel();
    expect(events.whereType<BandNote>(), isEmpty);
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(link.logs.any((l) => l.contains('mismatch')), isTrue);
  });

  test('every post-handshake message reaches raw verbatim, including one '
      'split across more than one notification', () async {
    // 40 bytes of payload chunks into three 20-byte writes — proving the
    // adapter's own reassembler, not just the single-packet case every
    // handshake message above already is.
    final big = buildWithingsMessage(kWithingsMsgChallenge, [
      buildChallengeResponseStruct(List<int>.generate(40, (i) => i)),
    ]);
    expect(_asChunks(big).length, greaterThan(1));

    final (events, _, _) = await _drive(
      _adapter(firstConnect: false),
      afterAuth: () => _asChunks(big),
    );
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty,
        reason: 'this band decodes nothing — see its own signals getter');
    expect(batches.single.ephemeral, isFalse);
    expect(batches.single.raw, hasLength(1));
    expect(batches.single.raw!.single, big,
        reason: 'reassembled verbatim, header included');
  });
}
