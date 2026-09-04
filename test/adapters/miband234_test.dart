// The Mi Band 2/3/4 auth handshake, replayed through [ReplayBandLink].
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
//     undecoded bytes with no [NeutralSample] and no [OffloadCheckpoint] —
//     this band's flash is never touched.
//
// Nothing here has met hardware. It proves the state machine, not the band.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';

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
    await Future<void>.delayed(Duration.zero);
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
  if (v.length == 2 && v[0] == 0x02 && v[1] == 0x08) {
    return [_challengeFrame(_kChallenge)];
  }
  if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x01)];
  return const [];
}

void main() {
  test('declares no signals — every optional channel is archived, not decoded',
      () {
    expect(_adapter().signals, isEmpty);
  });

  test('a first pairing writes the key before requesting a challenge',
      () async {
    final (_, link) = await _drive(_adapter(needsKeyWrite: true), (i, v) {
      if (v.length == 18 && v[0] == 0x01 && v[1] == 0x08) {
        return [_sendKeyAck(0x01)];
      }
      return _reconnectReply(i, v);
    });
    expect(link.writes[0].$2, <int>[0x01, 0x08, ..._kKey]);
    expect(link.writes[1].$2, <int>[0x02, 0x08]);
    final answer = miBand234AuthResponse(_kKey, _kChallenge);
    expect(link.writes[2].$2, <int>[0x03, 0x08, ...answer]);
  });

  test('a reconnect with an installed key skips the key write entirely',
      () async {
    final (_, link) = await _drive(_adapter(), _reconnectReply);
    expect(link.writes, hasLength(2));
    expect(link.writes.first.$2, <int>[0x02, 0x08]);
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
      if (v.length == 2 && v[0] == 0x02) {
        return [<int>[0x10, 0x02, 0x00, ..._kChallenge]];
      }
      return const [];
    });
    expect(events, isEmpty);
  });

  test('0x04 on the final result means the wrong key or still bound '
      'elsewhere — either way the session ends', () async {
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.length == 2 && v[0] == 0x02) return [_challengeFrame(_kChallenge)];
      if (v.isNotEmpty && v[0] == 0x03) return [_authResult(0x04)];
      return const [];
    });
    expect(events, isEmpty);
    // Nothing was ever subscribed past the auth characteristic — a failed
    // handshake never reaches the optional channels.
    expect(link.writes, hasLength(2));
  });

  test('battery, steps and heart rate are archived raw, undecoded, and never '
      'checkpoint', () async {
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
    // This band's flash is never touched — no history command exists on this
    // path at all, so there is nothing to checkpoint.
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
