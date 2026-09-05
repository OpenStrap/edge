// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): replay a fixture
// through a [ReplayBandLink] and assert what [ZeTimeAdapter] actually does.
//
// [ZeTimeAdapter.signals] is `const {}` — see `_registry.dart`'s `kZeTime` for
// why — so the usual "every declared signal appears" assertion is vacuous
// here; what this file pins instead is the one thing this adapter is allowed
// to do: ask for the battery, bank whatever parses, and emit nothing beyond
// that. `zetime_link_test.dart` exercises the same adapter end to end through
// the real `BandHost` and the real database; this one is the ~40-line
// no-hardware, no-mocks version a contributor copies.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/zetime.dart';

List<int> _batteryReply(int level) => <int>[
      kZeTimePreamble,
      kZeTimeCmdBattery,
      0x01,
      0x01,
      0x00,
      level,
      kZeTimeEnd,
    ];

/// Drive [kZeTimeAdapter] over a scripted link and collect what it yields.
Future<(List<BandEvent>, ReplayBandLink)> _replay(List<int>? notifyFrame) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kZeTimeAdapter.run(link).listen(events.add, onDone: done.complete);
  // The adapter waits out a fixed reply window before it ends on its own —
  // feed the reply as soon as the request lands so the test does not sit
  // through the whole thing waiting for nothing.
  if (notifyFrame != null) {
    link.feed(kZeTimeNotifyChar, notifyFrame, atSec: 1_800_000_000);
  }
  await done.future;
  await sub.cancel();
  return (events, link);
}

void main() {
  test('declares no signal — this band may bank bytes, never claim a metric',
      () {
    expect(kZeTimeAdapter.signals, isEmpty);
  });

  test('asks for the battery, then acks — nothing else on the wire', () async {
    final (_, link) = await _replay(_batteryReply(63));
    expect(link.writes, hasLength(2));
    // Field-by-field, not the tuple as a whole: a record's own `==` compares
    // its `List<int>` field by identity, not content, so two equal-looking
    // frames from separate builds would never compare equal wrapped together.
    expect(link.writes[0].$1, kZeTimeWriteChar);
    expect(link.writes[0].$2, zetimeRequestFrame(kZeTimeCmdBattery));
    expect(link.writes[1].$1, kZeTimeAckChar);
    expect(link.writes[1].$2, const <int>[kZeTimeAckToken]);
  });

  test('a battery reply becomes a note and a raw frame, never a NeutralSample',
      () async {
    final (events, _) = await _replay(_batteryReply(63));
    expect(events.whereType<BandNote>().single.value, 63);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches.single.samples, isEmpty);
    expect(batches.single.raw, hasLength(1));
    expect(batches.single.ephemeral, isFalse);
  });

  test('a malformed notification is dropped, not banked as a guess', () async {
    final (events, _) = await _replay(<int>[0x00, 0x00, 0x00]);
    expect(events.whereType<BandNote>(), isEmpty);
    expect(events.whereType<SampleBatch>(), isEmpty);
  });

  test('nothing at all still ends the session, empty-handed', () async {
    final (events, _) = await _replay(null);
    expect(events, isEmpty);
  });
}
