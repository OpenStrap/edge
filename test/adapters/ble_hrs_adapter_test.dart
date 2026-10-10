// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): replay a fixture through
// a [ReplayBandLink] and assert that every signal the adapter DECLARES really
// appears in what it EMITS.
//
// Why this one and not a decode test: a declared-but-absent signal is worse
// than a missing one. A missing signal deletes its card through the absence
// contract; a declared one that never arrives leaves a card permanently empty
// with nothing to point at. The decode itself is pinned in `hrs_link_test.dart`
// against the SIG layout.
//
// This is also the worked example a contributor copies —
// `test/adapters/<id>_test.dart`, ~40 lines, no hardware, no mocks.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';

/// uint8 HR + contact supported/detected + RR present; 500 and 512 ticks.
const List<int> kHrWithTwoRr = <int>[0x16, 120, 0xF4, 0x01, 0x00, 0x02];

/// flags 0x00 — the RR bit CLEAR, which plenty of optical armbands never set.
const List<int> kBpmOnly = <int>[0x00, 61];

/// Drive [BleHrsAdapter] over recorded bytes and collect what it yields.
Future<List<BandEvent>> replay(List<(int, List<int>)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  // onDone is wired BEFORE anything is fed: `run()` finishing is what we wait
  // on, and guessing at a delay instead is how a test drops the tail.
  final sub = kBleHrsAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kHeartRateMeasurementUuid, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('every declared InputSignal actually appears in an emitted sample',
      () async {
    final events = await replay(const [
      (1_800_000_000, kHrWithTwoRr),
      (1_800_000_001, kBpmOnly),
    ]);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isNotEmpty);

    final seen = <InputSignal>{
      if (samples.any((s) => s.hr != null)) InputSignal.hrSparse,
      if (samples.any((s) => s.rrMs.isNotEmpty)) InputSignal.rrIntervals,
    };
    expect(seen, containsAll(kBleHrsAdapter.signals.keys),
        reason: 'a declared signal that never arrives leaves a permanently '
            'empty card instead of no card');
    // And the converse: nothing UNDECLARED is emitted either. Declaring I3+I1
    // is what makes every sleep, temperature, step and SpO2 card delete itself.
    expect(kBleHrsAdapter.signals.keys.toSet(), seen);
  });

  test('cadence is roughly what the adapter declared', () async {
    final events = await replay([
      for (var i = 0; i < 10; i++) (1_800_000_000 + i, kHrWithTwoRr),
    ]);
    final ts = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples.map((s) => s.tsEpoch),
    ];
    expect(ts, hasLength(10));
    final span = ts.last - ts.first;
    expect(span / (ts.length - 1),
        closeTo(kBleHrsAdapter.signals[InputSignal.hrSparse]!.inSeconds, 0.5));
  });

  test('arrival time comes from the LINK, never from a clock in the adapter',
      () async {
    // The whole point of stamping arrival on the packet: a fixture replays
    // deterministically. If the adapter read `DateTime.now()` this would be
    // today's epoch, and `TimeAnchor.arrival` would be untestable.
    final events = await replay(const [(1_800_000_000, kHrWithTwoRr)]);
    final s = (events.single as SampleBatch).samples.single;
    expect(s.tsEpoch, 1_800_000_000);
    expect(s.anchor, TimeAnchor.arrival);
  });

  test('a strap stores nothing, so it never emits an OffloadCheckpoint',
      () async {
    final events = await replay(const [
      (1_800_000_000, kHrWithTwoRr),
      (1_800_000_001, <int>[0x04, 45]), // contact bits 0b10 = off the chest
    ]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    // An off-chest reading is refused outright, not stored as a low HR.
    expect(events, hasLength(1));
    // Nothing is written back to a sensor that has no command characteristic.
    expect(kBleHrsAdapter.entry.isFramed, isFalse);
  });

  test('the beats of an off-chest notification still pass time on the chain',
      () async {
    // 1024 ticks = 1000 ms each. The middle notification is refused, but its
    // beat happened: the next banked beat carries it as a gap, so the chain
    // ends that beat two intervals after the first instead of one.
    final events = await replay(const [
      (1_800_000_000, <int>[0x16, 60, 0x00, 0x04]),
      (1_800_000_001, <int>[0x14, 60, 0x00, 0x04]), // off the chest
      (1_800_000_002, <int>[0x16, 60, 0x00, 0x04]),
    ]);
    final s = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(s.map((x) => x.gapMs), [0, 1000]);
    final a = beatEndTimesMs(s[0].rrMs, s[0].tsEpoch, null);
    final b = beatEndTimesMs(s[1].rrMs, s[1].tsEpoch, a.last,
        gapsMs: [s[1].gapMs]);
    expect(b.single - a.single, 2000);
  });
}
