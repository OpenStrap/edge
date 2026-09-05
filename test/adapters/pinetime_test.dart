// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), PineTime's shape: no
// signal is declared, nothing is ever written, both notify channels are
// merged, and every notification comes back as raw bytes and nothing else.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/pinetime.dart';

/// A plausible step-count notification: a little-endian u32.
final Uint8List kStepsFrame = Uint8List.fromList([0x2a, 0x00, 0x00, 0x00]);

/// A plausible heart-rate-measurement notification: flags byte 0x00 (u8 bpm
/// format, no contact bit), bpm 0x3c.
final Uint8List kHrFrame = Uint8List.fromList([0x00, 0x3c]);

/// Let the adapter's `async*` body actually run before this test touches the
/// link again — same idiom `id115_test.dart`'s own two-characteristic replay
/// spins on: a stream's generator body is scheduled, not entered
/// synchronously, so a `link.close()` right after `.listen()` can beat both
/// of this adapter's `notify()` calls into existence.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<List<BandEvent>> replay(
    List<(String uuid, int sec, Uint8List value)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kPineTimeAdapter.run(link).listen(events.add, onDone: done.complete);
  await _settle();
  for (final (uuid, sec, value) in arrivals) {
    link.feed(uuid, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kPineTimeAdapter.signals, isEmpty);
    expect(kPineTimeAdapter.entry.isFramed, isFalse);
    expect(kPineTimeAdapter.entry.requiredCharacteristics,
        [kPineTimeStepCountChar, kHeartRateMeasurementUuid]);
  });

  test('writes nothing at all: both channels stream unprompted', () async {
    final link = ReplayBandLink();
    final sub = kPineTimeAdapter.run(link).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('both notify channels are merged into raw frames, neither one lost',
      () async {
    final events = await replay([
      (kPineTimeStepCountChar, 1_800_000_000, kStepsFrame),
      (kHeartRateMeasurementUuid, 1_800_000_001, kHrFrame),
    ]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(2));
    expect(batches.every((b) => b.samples.isEmpty), isTrue);
    expect(batches.every((b) => !b.ephemeral), isTrue);
    final raws = batches.map((b) => b.raw!.single).toList();
    expect(raws, containsAll([kStepsFrame, kHrFrame]));
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events =
        await replay([(kPineTimeStepCountChar, 1_800_000_000, kStepsFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('the session ends once BOTH notify channels close', () async {
    final link = ReplayBandLink();
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub =
        kPineTimeAdapter.run(link).listen(events.add, onDone: done.complete);
    await _settle();
    link.feed(kPineTimeStepCountChar, kStepsFrame, atSec: 1_800_000_000);
    // Closing the whole link is the only way `ReplayBandLink` ends a
    // channel — this proves the merge does not hang waiting on a stream
    // that was never fed, not that one channel alone can end the session.
    await link.close();
    await done.future;
    await sub.cancel();
    expect(events.whereType<SampleBatch>(), hasLength(1));
  });
}
