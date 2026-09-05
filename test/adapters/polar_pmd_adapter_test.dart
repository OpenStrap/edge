// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): replay a fixture through
// a [ReplayBandLink] and assert that every signal the adapter DECLARES really
// appears in what it EMITS.
//
// This adapter also has a START handshake `ble_hrs` does not: a control-point
// write must be confirmed before the data stream means anything, so the
// fixture below feeds that reply before it feeds any PPI frame, and spins a
// few event-loop turns after each feed so the generator has actually reacted
// before the next step — the same shape `oura_link.dart`'s own test seam uses
// for the same reason (a lazy, sequential subscriber needs a turn to reach
// its next `notify()` call).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/polar_pmd.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// The control-point's confirmation that PPI streaming started.
const List<int> kStartOk = <int>[0xF0, 0x02, 0x03, 0x00];
const List<int> kStartRefused = <int>[0xF0, 0x02, 0x03, 0x01];

/// One PPI frame: 10-byte header (measurement type + timestamp + frame type)
/// followed by one or more 6-byte records.
List<int> ppiFrame(List<List<int>> records) => <int>[
      0x03,
      ...List.filled(8, 0),
      0x00,
      for (final r in records) ...r,
    ];

/// hr 60, ppi 1000 ms, error 10 ms, flags 0x00.
const List<int> kOneBeat = <int>[60, 0xE8, 0x03, 0x0A, 0x00, 0x00];
const List<int> kZeroHrBeat = <int>[0, 0xE8, 0x03, 0x0A, 0x00, 0x00];

/// Let the event loop run a few turns — enough for a lazy, sequential
/// subscriber to react to whatever was just fed and reach its next `notify`
/// call, without guessing at a fixed delay.
Future<void> _settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Drive [PolarPmdAdapter] over recorded bytes and collect what it yields.
/// [controlReply] is fed to the control characteristic first (null skips it,
/// to exercise the no-reply timeout path); the frame in [dataFrame], if any,
/// is fed only after the adapter has had a chance to react to that reply.
Future<List<BandEvent>> replay(
  List<int>? dataFrame, {
  List<int>? controlReply = kStartOk,
}) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kPolarPmdAdapter.run(link).listen(events.add, onDone: done.complete);
  // Give the adapter a chance to issue its START write before anything is fed.
  await _settle();
  if (controlReply != null) {
    link.feed(kPolarPmdControlChar, controlReply, atSec: 1_800_000_000);
  }
  // Let the generator react to the reply (proceed to read the data stream,
  // or — on a refusal — run its `finally` and end) before deciding what to
  // feed next.
  await _settle();
  if (dataFrame != null) {
    link.feed(kPolarPmdDataChar, dataFrame, atSec: 1_800_000_000);
    await _settle();
  }
  await link.close();
  await done.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  return events;
}

void main() {
  test('every declared InputSignal actually appears in an emitted sample',
      () async {
    final events = await replay(ppiFrame([kOneBeat]));
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isNotEmpty);
    final seen = <InputSignal>{
      if (samples.any((s) => s.hr != null)) InputSignal.hrSparse,
      if (samples.any((s) => s.rrMs.isNotEmpty)) InputSignal.rrIntervals,
    };
    expect(seen, containsAll(kPolarPmdAdapter.signals.keys));
    expect(kPolarPmdAdapter.signals.keys.toSet(), seen);
  });

  test('the START command is written before anything is read', () async {
    final link = ReplayBandLink();
    final done = Completer<void>();
    final sub = kPolarPmdAdapter.run(link).listen((_) {}, onDone: done.complete);
    await _settle();
    expect(link.writes.single, (kPolarPmdControlChar, polarPmdStartPpi()));
    // Resolved with a reply rather than left to the 5 s timeout: an
    // uncompleted `started` future leaves its Timer running past this test's
    // own end, which does not fail anything but bleeds 5 real seconds into
    // whatever runs next.
    link.feed(kPolarPmdControlChar, kStartOk, atSec: 1_800_000_000);
    await link.close();
    await done.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
  });

  test('a refused START ends the session with no samples', () async {
    final events = await replay(null, controlReply: kStartRefused);
    expect(events, isEmpty);
  });

  test('hr == 0 is a refusal, never a fabricated measurement', () async {
    final events = await replay(ppiFrame([kZeroHrBeat, kOneBeat]));
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, hasLength(1));
    expect(samples.single.hr, 60);
  });

  test('a sensor with no flash never emits an OffloadCheckpoint', () async {
    final events = await replay(ppiFrame([kOneBeat]));
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('vendor fields carry the blocker bit and the raw skin-contact bits',
      () async {
    // flags 0x07 = blocker + both skin-contact bits.
    final beat = <int>[60, 0xE8, 0x03, 0x0A, 0x00, 0x07];
    final events = await replay(ppiFrame([beat]));
    final s = (events.single as SampleBatch).samples.single;
    expect(s.vendor['blocker'], isTrue);
    expect(s.vendor['skin_contact'], 0x03);
    expect(s.vendor['error_ms'], 10);
  });
}
