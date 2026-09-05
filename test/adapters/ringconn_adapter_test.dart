// The RingConn session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE, and it is not the wire format itself — that is
// proven in the protocol package. It is the SHAPE of the session:
//
//   * the System ID is read before anything is written, and an unreadable one
//     ends the session with no writes at all;
//   * the challenge is answered with SM3 over the ring's own recovered MAC,
//     and a refused or unconfirmed handshake ends the session before any
//     channel is opened;
//   * both channels are opened at "now" and drained independently;
//   * a bulk page's remaining-count byte is what pulls the next page of the
//     SAME burst, never a fresh fetch;
//   * every frame — auth, sync-open ack, every page — reaches `raw`, and
//     `samples` is always empty: nothing here decodes a value.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/ringconn.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI.
const Duration _kFast = Duration(milliseconds: 50);

/// Forward EUI-64 form of MAC `a1:b2:c3:44:55:66` (OUI + FF FE + NIC).
final List<int> _systemId = _hex('a1b2c3fffe445566');
final List<int> _mac = _hex('a1b2c3445566');

List<int> _hex(String s) => [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

RingConnAdapter _adapter({int Function()? nowSeconds}) => RingConnAdapter(
      nowSeconds: nowSeconds ?? (() => 1786000000),
      replyTimeout: _kFast,
    );

List<int> _xorFrame(int respid, List<int> body) {
  final full = [respid, ...body];
  var x = 0;
  for (final b in full) {
    x ^= b;
  }
  return [...full, x & 0xff];
}

List<int> _challengeReply(int challenge) =>
    _xorFrame(kRingConnRespAuth, [0x00, challenge]);
List<int> _authConfirm() =>
    _xorFrame(kRingConnRespAuth, [0x01, ...List<int>.filled(35, 0)]);
List<int> _syncOpenReply() => _xorFrame(kRingConnRespSyncOpen, [0x00, 0x00]);
List<int> _fetchEmpty() => _xorFrame(kRingConnRespFetchEmpty, const []);

List<int> _bulkPage(int respid, int recordLen, int remaining, List<int> tags) {
  final records = <int>[
    for (final t in tags) ...[t, ...List<int>.filled(recordLen - 1, 0xaa)],
  ];
  return _xorFrame(respid, [0x00, remaining, ...records]);
}

/// Drive [adapter] over a replay link, answering each write as the ring
/// would. A replay link records writes but cannot react to them, so this
/// waits for the write count to grow and feeds the reply that write earned —
/// the smallest thing that exercises the real `run()`.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  RingConnAdapter adapter,
  List<List<int>> Function(int writeIndex, List<int> value) reply, {
  /// Null (the default) seeds the real fixture MAC. An explicit empty list is
  /// how a test asks for an UNREADABLE System ID — `ReplayBandLink.read`
  /// answers whatever is seeded here verbatim, and `RingConnAdapter` refuses
  /// anything that is not exactly 8 bytes.
  List<int>? systemId,
}) async {
  final link = ReplayBandLink();
  final sid = systemId ?? _systemId;
  link.readValues[kSystemIdUuid] = sid;
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(
        (e) {
          events.add(e);
          // Stand in for `BandHost`'s commit-then-confirm: nothing here
          // decodes or persists, so every checkpoint confirms the instant it
          // arrives — this drives the ack write same as a real commit would.
          if (e is OffloadCheckpoint) unawaited(e.confirm());
        },
        onDone: () => done.complete(),
      );
  var served = 0;
  for (var spin = 0; spin < 400 && !done.isCompleted; spin++) {
    await Future<void>.delayed(Duration.zero);
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kRingConnNotifyChar, f, atSec: 1786000000);
      }
      served++;
    }
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  await sub.cancel();
  return (events, link);
}

void main() {
  test('declares no signal at all', () {
    expect(_adapter().signals, isEmpty);
  });

  test('an unreadable System ID ends the session with no writes and no '
      'events', () async {
    final (events, link) = await _drive(
      _adapter(),
      (i, v) => const [],
      systemId: const [],
    );
    expect(link.writes, isEmpty);
    expect(events, isEmpty);
    expect(
      link.logs.any((l) => l.contains('could not read the System ID')),
      isTrue,
    );
  });

  test('answers the challenge with SM3 over the recovered MAC, and both '
      'frames reach raw', () async {
    const challenge = 0x2b;
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
        return [_challengeReply(challenge)];
      }
      if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
      return const [];
    });
    expect(link.writes.first.$2, ringConnCmdStatus());
    final authWrite = link.writes[1].$2;
    expect(authWrite.first, kRingConnCmdStatus);
    expect(authWrite[1], 0x01);
    expect(authWrite.sublist(2, 5), ringConnAuthResponse(_mac, challenge));
    // Every frame the ring sent — the challenge and the confirm — reaches
    // `raw`, even though neither is a bulk page.
    final auth = events.whereType<SampleBatch>().first;
    expect(auth.raw, hasLength(2));
    expect(auth.samples, isEmpty);
  });

  test('no challenge ends the session before any channel opens', () async {
    final (events, link) =
        await _drive(_adapter(), (i, v) => const []);
    expect(link.writes, hasLength(1), reason: 'only the status write');
    expect(events, isEmpty);
    expect(
      link.logs.any((l) => l.contains('no authentication challenge')),
      isTrue,
    );
  });

  test('an unconfirmed handshake ends the session before any channel opens',
      () async {
    final (_, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
        return [_challengeReply(0x01)];
      }
      return const [];
    });
    expect(
      link.writes.any((w) => w.$2.first == kRingConnCmdSyncOpen),
      isFalse,
    );
  });

  test('opens both channels at "now" once authenticated', () async {
    const now = 1786000000;
    final (_, link) = await _drive(
      _adapter(nowSeconds: () => now),
      (i, v) {
        if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
          return [_challengeReply(0x01)];
        }
        if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
        if (v.first == kRingConnCmdSyncOpen) return [_syncOpenReply()];
        if (v.first == kRingConnCmdFetch) return [_fetchEmpty()];
        return const [];
      },
    );
    final opens =
        link.writes.where((w) => w.$2.first == kRingConnCmdSyncOpen).toList();
    expect(opens, hasLength(2));
    final cursor = ringConnCursor(now);
    final cursorBytes = [
      (cursor >>> 24) & 0xff,
      (cursor >>> 16) & 0xff,
      (cursor >>> 8) & 0xff,
      cursor & 0xff,
    ];
    expect(opens[0].$2.sublist(2, 6), cursorBytes);
    expect(opens[1].$2.sublist(2, 6), cursorBytes);
    // Sleep, then awake — the one byte that differs.
    expect(opens[0].$2[6], kRingConnChannelSleep);
    expect(opens[1].$2[6], kRingConnChannelAwake);
  });

  test('a bulk page with remaining > 0 is ACKed to pull the next page of the '
      'SAME burst, never a fresh fetch', () async {
    var acks = 0;
    final (events, link) = await _drive(_adapter(), (i, v) {
      if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
        return [_challengeReply(0x01)];
      }
      if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
      if (v.first == kRingConnCmdSyncOpen) return [_syncOpenReply()];
      if (v.first == kRingConnCmdFetch) {
        return [_bulkPage(kRingConnRespBulkActivity, kRingConnActivityRecordLen, 1, [0x01])];
      }
      if (v.first == kRingConnCmdAckActivity) {
        acks++;
        return [_bulkPage(kRingConnRespBulkActivity, kRingConnActivityRecordLen, 0, [0x02])];
      }
      return const [];
    });
    // One channel drains two pages before ending; the other channel (whose
    // fetch is answered the same way by this script) drains two more.
    expect(acks, 2);
    final batches = events.whereType<SampleBatch>().toList();
    // auth (1) + each channel yields its own frame the moment it arrives
    // (sync-open ack, page 1, page 2 — one batch apiece, never accumulated
    // for a single yield at the end of the burst) — 1 + 2*3.
    expect(batches, hasLength(7));
    for (final b in batches.skip(1)) {
      expect(b.samples, isEmpty);
      expect(b.raw, hasLength(1));
    }
    final page2 = _bulkPage(
      kRingConnRespBulkActivity,
      kRingConnActivityRecordLen,
      0,
      [0x02],
    );
    expect(
      batches.last.raw!.single,
      Uint8List.fromList(page2),
      reason: 'the last page reaches raw verbatim, header included',
    );
    // Never any command this file did not build.
    const built = {
      kRingConnCmdStatus,
      kRingConnCmdSyncOpen,
      kRingConnCmdFetch,
      kRingConnCmdAckActivity,
    };
    for (final w in link.writes) {
      expect(built, contains(w.$2.first));
    }
  });

  test('a non-bulk reply ends the burst even when nothing was queued to '
      'follow it', () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
        return [_challengeReply(0x01)];
      }
      if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
      if (v.first == kRingConnCmdSyncOpen) return [_syncOpenReply()];
      if (v.first == kRingConnCmdFetch) return [_fetchEmpty()];
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    // auth (1) + each channel's own sync-open-ack and fetch-empty frames,
    // one batch apiece — 1 + 2*2.
    expect(batches, hasLength(5));
    for (final b in batches) {
      expect(b.samples, isEmpty);
    }
  });

  test('a ring that goes silent mid-burst ends the session instead of '
      'hanging, and still banks what it already sent', () async {
    final (events, _) = await _drive(_adapter(), (i, v) {
      if (v.first == kRingConnCmdStatus && v[1] == 0x00) {
        return [_challengeReply(0x01)];
      }
      if (v.first == kRingConnCmdStatus && v[1] == 0x01) return [_authConfirm()];
      if (v.first == kRingConnCmdSyncOpen) return [_syncOpenReply()];
      if (v.first == kRingConnCmdFetch) {
        // remaining > 0, but the ring never answers the ACK this earns.
        return [_bulkPage(kRingConnRespBulkActivity, kRingConnActivityRecordLen, 1, [0x01])];
      }
      return const [];
    });
    final batches = events.whereType<SampleBatch>().toList();
    // auth + sleep-channel (banked what arrived before the timeout).
    // The awake channel's own sync-open never gets a reply either, once the
    // fetch that starts it times out the same way — either way nothing hangs.
    expect(batches, isNotEmpty);
    expect(batches.every((b) => b.samples.isEmpty), isTrue);
  });
}
