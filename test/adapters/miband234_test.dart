// The Mi Band 2/3 auth handshake, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE, and it is not the crypto (that is
// `oura_auth_crypto_test.dart`'s sibling below, pinned against a published
// AES vector independent of this file's own encoder). It is the SHAPE of the
// handshake and the optional-channel forwarding:
//
//   * a first pairing writes the key before it ever asks for a challenge, and
//     a reconnect with an installed key skips straight to the challenge;
//   * any refusal — a bad install ack, a bad challenge, a bad final result,
//     or silence — ends the session before anything is subscribed;
//   * battery, steps and heart-rate notifications reach the host as raw,
//     undecoded bytes with no [NeutralSample];
//   * a history round reads the announced number of minute SAMPLES, not
//     bytes, and ends on the band's done notification.
//
// Nothing here has met hardware. It proves the state machine, not the band.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show kHuamiActivityControlChar, kHuamiActivityDataChar;

/// Any 16 bytes. The replay band answers a scripted result rather than
/// actually verifying the AES block, so the VALUE of the key is not what is
/// under test here.
const List<int> _kKey = <int>[
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, //
  0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, //
];

const List<int> _kChallenge = <int>[
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
];

List<int> _sendKeyAck(int status) => <int>[0x10, 0x01, status];
List<int> _challengeFrame(List<int> challenge) =>
    <int>[0x10, 0x02, 0x01, ...challenge];
List<int> _authResult(int status) => <int>[0x10, 0x03, status];

MiBand234Adapter _adapter({bool needsKeyWrite = false}) => MiBand234Adapter(
      key: _kKey,
      needsKeyWrite: needsKeyWrite,
      replyTimeout: const Duration(milliseconds: 50),
      confirmTimeout: const Duration(milliseconds: 50),
      fetchTimeout: const Duration(milliseconds: 50),
    );

/// Drive [adapter] over a replay link, answering each write on the auth
/// characteristic as the band would.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  MiBand234Adapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply,
) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    // Real time passes, so a reply timeout can expire mid-drive.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kHuami234AuthChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

/// The band's ordinary reply script once a key is already installed.
List<List<int>> _reconnectReply(int i, List<int> v) {
  if (v.length == 3 && v[0] == 0x02 && v[1] == 0x00 && v[2] == 0x02) {
    return [_challengeFrame(_kChallenge)];
  }
  if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x01)];
  return const [];
}

void main() {
  test('declares hrSparse (one stored HR per minute) and the registry '
      'mirrors it', () {
    expect(_adapter().signals.keys, [InputSignal.hrSparse]);
    expect(kAdapterSignals['miband234'], _adapter().signals);
  });

  test('a first pairing writes the key before requesting a challenge',
      () async {
    final (_, link) = await _drive(_adapter(needsKeyWrite: true), (i, v) {
      if (v.length == 18 && v[0] == 0x01 && v[1] == 0x00) {
        return [_sendKeyAck(0x01)];
      }
      return _reconnectReply(i, v);
    });
    expect(link.writes[0].$2, <int>[0x01, 0x00, ..._kKey]);
    expect(link.writes[1].$2, <int>[0x02, 0x00, 0x02]);
    final answer = miBand234AuthResponse(_kKey, _kChallenge);
    expect(link.writes[2].$2, <int>[0x03, 0x00, ...answer]);
  });

  test('a reconnect with an installed key skips the key write entirely',
      () async {
    final (_, link) = await _drive(_adapter(), _reconnectReply);
    final auth = link.writes.where((w) => w.$1 == kHuami234AuthChar).toList();
    expect(auth, hasLength(2));
    expect(auth.first.$2, <int>[0x02, 0x00, 0x02]);
  });

  test('an unanswered challenge request is retried in its short form',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.length == 2 && v[0] == 0x02) return [_challengeFrame(_kChallenge)];
      if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x01)];
      return const [];
    });
    final auth = link.writes.where((w) => w.$1 == kHuami234AuthChar).toList();
    expect(auth.map((w) => w.$2.sublist(0, 2)), [
      [0x02, 0x00],
      [0x02, 0x00],
      [0x03, 0x00],
    ]);
  });

  test('a refused key install ends the session before any challenge request',
      () async {
    final (events, link) = await _drive(_adapter(needsKeyWrite: true), (i, v) {
      if (v[0] == 0x01) return [_sendKeyAck(0x04)];
      return const [];
    });
    expect(link.writes, hasLength(1), reason: 'no challenge request either');
    expect(events, isEmpty);
  });

  test('silence on the key install is a refusal, not a stall past the timeout',
      () async {
    final (events, link) = await _drive(
      _adapter(needsKeyWrite: true),
      (i, v) => const [],
    );
    expect(link.writes, hasLength(1));
    expect(events, isEmpty);
  });

  test('a challenge with the wrong status is unusable', () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v[0] == 0x02) {
        return [<int>[0x10, 0x02, 0x00, ..._kChallenge]];
      }
      return const [];
    });
    expect(events, isEmpty);
  });

  test('0x04 on the final result means the wrong key or still bound '
      'elsewhere — either way the session ends', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v[0] == 0x02) return [_challengeFrame(_kChallenge)];
      if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x04)];
      return const [];
    });
    expect(events, isEmpty);
    // Nothing was ever subscribed past the auth characteristic — a failed
    // handshake never reaches the optional channels.
    expect(link.writes, hasLength(2));
  });

  test('battery, steps and heart rate are archived raw, undecoded, and never '
      'checkpoint without history', () async {
    final link = ReplayBandLink();
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = _adapter().run(link).listen(events.add, onDone: done.complete);
    var served = 0;
    for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        for (final f in _reconnectReply(served, link.writes[served].$2)) {
          link.feed(kHuami234AuthChar, f, atSec: 1786000000);
        }
        served++;
      }
    }
    // Auth has now completed (the loop above stops once `run()` reaches the
    // subscribe stage and stops writing). Feed the optional channels —
    // `ReplayBandLink` buffers per-characteristic, so a frame fed before the
    // adapter's own `listen()` lands is not dropped.
    link.feed(kHuami234BatteryChar, <int>[0x03, 84], atSec: 1786000001);
    link.feed(kHuami234StepsChar, <int>[0x2a, 0x00, 0x00, 0x00],
        atSec: 1786000002);
    link.feed(kHeartRateMeasurementUuid, <int>[0x00, 65], atSec: 1786000003);
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await link.close();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    await sub.cancel();

    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(3));
    // No decoded sample ever, from any of the three channels.
    expect(batches.every((b) => b.samples.isEmpty), isTrue);
    // Not ephemeral: these bytes are meant to be persisted, just undecoded.
    expect(batches.every((b) => b.ephemeral == false), isTrue);
    // `anyElement(equals(...))` rather than `contains`: `Uint8List`'s `==` is
    // identity, not value, so a bare `contains` would never match a freshly
    // built comparison list — `equals` is what does the deep comparison.
    final raws = batches.map((b) => b.raw!.single).toList();
    expect(raws, anyElement(equals(<int>[kMiBand234ArchiveBattery, 0x03, 84])));
    expect(
      raws,
      anyElement(
          equals(<int>[kMiBand234ArchiveSteps, 0x2a, 0x00, 0x00, 0x00])),
    );
    expect(raws, anyElement(equals(<int>[kMiBand234ArchiveHr, 0x00, 65])));
    // The band answered no history round, so there is nothing to checkpoint.
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('a history round reads the announced number of minute samples, then '
      'notes the cursor before its checkpoint', () async {
    final start = DateTime.utc(2026, 10, 3);
    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final adapter = MiBand234Adapter(
      key: _kKey,
      replyTimeout: const Duration(milliseconds: 50),
      fetchTimeout: const Duration(milliseconds: 50),
      sinceSec: startSec,
      nowSeconds: () => startSec + 86400,
    );
    // 8 minutes = 32 bytes, in two 16-byte packets.
    final samples = [for (var m = 0; m < 8; m++) ...[1, 10, 0, 60 + m]];
    var rounds = 0;
    final link = ReplayBandLink();
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = adapter.run(link).listen(events.add, onDone: done.complete);
    var served = 0;
    for (var spin = 0; spin < 300 && !done.isCompleted; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      while (served < link.writes.length) {
        final (char, v) = link.writes[served++];
        if (char == kHuami234AuthChar) {
          for (final f in _reconnectReply(served, v)) {
            link.feed(kHuami234AuthChar, f, atSec: 1786000000);
          }
        } else if (char == kHuamiActivityControlChar && v[0] == 0x01) {
          final n = rounds++ == 0 ? 8 : 0;
          link.feed(kHuamiActivityControlChar, [
            0x10, 0x01, 0x01, n, 0, 0, 0, //
            0xea, 0x07, 10, 3, 0, 0, 0, 0,
          ], atSec: 1786000000);
        } else if (char == kHuamiActivityControlChar && v[0] == 0x02) {
          link
            ..feed(kHuamiActivityDataChar, [0, ...samples.sublist(0, 16)],
                atSec: 1786000000)
            ..feed(kHuamiActivityDataChar, [1, ...samples.sublist(16)],
                atSec: 1786000000)
            ..feed(kHuamiActivityControlChar, [0x10, 0x02, 0x01],
                atSec: 1786000000);
        }
      }
    }
    await link.close();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    await sub.cancel();

    final hr = [
      for (final b in events.whereType<SampleBatch>()) ...b.samples,
    ];
    expect(hr.map((s) => s.hr), [60, 61, 62, 63, 64, 65, 66, 67]);
    expect(hr.first.tsEpoch, startSec);
    expect(rounds, 2, reason: 'the next round starts after the 8 minutes');
    final order = [
      for (final e in events)
        if (e is BandNote) 'note' else if (e is OffloadCheckpoint) 'checkpoint',
    ];
    expect(order, ['note', 'checkpoint']);
  });

  test(
      'cancelling the session cancels all three optional-channel '
      'subscriptions, not just the auth one', () async {
    final link = ReplayBandLink();
    final sub = _adapter().run(link).listen((_) {});
    // Spin until the handshake has written past the auth characteristic and
    // subscribed to battery/steps/HR — same drive loop as the test above,
    // minus collecting events, stopping the instant the subscribe happens.
    var served = 0;
    // The history fetch runs first and waits out its reply timeout on this
    // silent link, so this spin lets real time pass.
    for (var spin = 0;
        spin < 400 && !link.isListening(kHuami234BatteryChar);
        spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        for (final f in _reconnectReply(served, link.writes[served].$2)) {
          link.feed(kHuami234AuthChar, f, atSec: 1786000000);
        }
        served++;
      }
    }
    expect(link.isListening(kHuami234BatteryChar), isTrue);
    expect(link.isListening(kHuami234StepsChar), isTrue);
    expect(link.isListening(kHeartRateMeasurementUuid), isTrue);

    // This is what `BandHost.stop()` does: cancel the subscription on
    // `run()`, WITHOUT the link itself ever ending. A leak would leave all
    // three still listening after this.
    await sub.cancel();
    expect(link.isListening(kHuami234BatteryChar), isFalse);
    expect(link.isListening(kHuami234StepsChar), isFalse);
    expect(link.isListening(kHeartRateMeasurementUuid), isFalse);
  });
}
