// The R11M/R10M ring session, replayed through [ReplayBandLink].
//
// WHAT THIS EXISTS TO PROVE, and it is not the decode — that is proven with
// the wire format itself, in the protocol package. It is the SHAPE of the
// session: negotiation runs in order, a completed history block is ack'd or
// nack'd correctly on its own CRC, and every frame reaches `raw` regardless of
// whether anything decoded it.
//
// Nothing here has met hardware. It proves the state machine, not the ring.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/ring11m.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Short enough that a deliberately-unanswered wait does not stall CI. The
/// shipped default is 20s/5s; only their length is being shortened here,
/// never which one guards what.
const Duration _kFast = Duration(milliseconds: 60);

const Ring11mAdapter _adapter =
    Ring11mAdapter(listenWindow: _kFast, replyTimeout: _kFast);

/// Drive [adapter] over a replay link, answering each write as the ring would.
///
/// A replay link records writes but cannot react to them, and this session is
/// a conversation — so this spins on the write count and feeds the reply that
/// write earned, the same shape `oura_adapter_test.dart`'s own `_drive` uses.
Future<(List<BandEvent>, ReplayBandLink)> _drive(
  List<List<int>> Function(int writeIndex, List<int> value) reply, {
  List<(String uuid, List<int> value, int atSec)> unsolicited = const [],
}) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = _adapter.run(link).listen(events.add, onDone: done.complete);
  for (final (uuid, value, atSec) in unsolicited) {
    link.feed(uuid, value, atSec: atSec);
  }
  var served = 0;
  void serveWrites() {
    while (served < link.writes.length) {
      final w = link.writes[served];
      for (final f in reply(served, w.$2)) {
        link.feed(kRing11mCommandChar, f, atSec: 1);
      }
      served++;
    }
  }
  // A periodic real timer, not a fixed spin count: the negotiation has four
  // sequential legs, each up to `_kFast` long, and a bounded loop of
  // zero-delay spins can exhaust itself before the later legs' writes even
  // exist yet.
  final timer = Timer.periodic(const Duration(milliseconds: 5), (_) => serveWrites());
  await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  timer.cancel();
  await sub.cancel();
  return (events, link);
}

void main() {
  test('signals is empty — nothing is claimed for a ring nobody owns', () {
    expect(_adapter.signals, isEmpty);
  });

  test('negotiation writes model, battery, capability, then the clock, in order',
      () async {
    final (_, link) = await _drive((_, _) => const []);

    expect(link.writes.length, 4);
    for (final w in link.writes) {
      expect(w.$1, kRing11mCommandChar);
    }
    final frames = [for (final w in link.writes) parseRing11mFrame(w.$2)!];
    expect(frames[0].command, kRing11mCmdModelQuery);
    expect(frames[1].command, kRing11mCmdBatteryQuery);
    expect(frames[2].command, kRing11mCmdCapabilityQuery);
    expect(frames[3].command, kRing11mCmdSetTime);
  });

  test('a battery reply becomes a BandNote, nothing else does', () async {
    final (events, _) = await _drive((i, _) => i == 1
        ? [buildRing11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdBatteryQuery, [77])]
        : const []);

    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 77), isTrue);
  });

  test('an out-of-range battery byte is refused, not stored', () async {
    final (events, _) = await _drive((i, _) => i == 1
        ? [buildRing11mFrame(kRing11mGroupDeviceInfo, kRing11mCmdBatteryQuery, [200])]
        : const []);

    expect(events.whereType<BandNote>().where((n) => n.key == 'battery'), isEmpty);
  });

  test('a completed block with a matching CRC is ack\'d, not nack\'d', () async {
    const data = [1, 2, 3, 4, 5, 6, 7, 8];
    final crc = ring11mHistoryCrc(data);
    final (events, link) = await _drive(
      (_, _) => const [],
      unsolicited: [
        (kRing11mHistoryChar,
            buildRing11mFrame(kRing11mGroupHealthHistory, 0x01, data), 1),
        (
          kRing11mHistoryChar,
          buildRing11mFrame(kRing11mGroupHealthHistory, kRing11mCmdHistoryTerminator,
              [0x01, 0x00, crc & 0xff, (crc >> 8) & 0xff]),
          1
        ),
      ],
    );

    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'ring11m_block_ack'), isTrue);
    expect(notes.any((n) => n.key == 'ring11m_block_nack'), isFalse);
    expect(link.writes.any((w) => w.$2.length == 3 && w.$2[2] == 0x00), isTrue);
  });

  test('a completed block with a mismatched CRC is nack\'d', () async {
    final (events, link) = await _drive(
      (_, _) => const [],
      unsolicited: [
        (kRing11mHistoryChar,
            buildRing11mFrame(kRing11mGroupHealthHistory, 0x01, [9, 9, 9]), 1),
        (
          kRing11mHistoryChar,
          buildRing11mFrame(kRing11mGroupHealthHistory, kRing11mCmdHistoryTerminator,
              [0x01, 0x00, 0xde, 0xad]), // deliberately wrong
          1
        ),
      ],
    );

    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'ring11m_block_nack'), isTrue);
    expect(link.writes.any((w) => w.$2.length == 3 && w.$2[2] == 0x04), isTrue);
  });

  test('every frame the ring sends reaches raw, decoded or not', () async {
    final (events, _) = await _drive(
      (_, _) => const [],
      unsolicited: [
        (
          kRing11mCommandChar,
          buildRing11mFrame(kRing11mGroupRealtime, kRing11mCmdRealtimeHr, [88]),
          1
        ),
      ],
    );

    final raw = <Uint8List>[
      for (final e in events)
        if (e is SampleBatch && e.raw != null) ...e.raw!,
    ];
    expect(
      raw.any((b) {
        final f = parseRing11mFrame(b);
        return f != null &&
            f.group == kRing11mGroupRealtime &&
            f.command == kRing11mCmdRealtimeHr;
      }),
      isTrue,
    );
    // Undecoded and unclaimed: no signal is ever declared for a realtime push.
    expect(_adapter.signals, isEmpty);
  });
}
