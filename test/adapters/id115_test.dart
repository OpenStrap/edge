// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), this board's shape: no
// signal declared and no command ever written, so the only thing to prove is
// that every arriving frame — from EITHER channel — is archived verbatim and
// nothing else happens.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/id115.dart';

/// A made-up frame on the general channel.
final Uint8List kNormalFrame = Uint8List.fromList([0x08, 0x02, 0x01]);

/// A made-up frame on the health-data channel.
final Uint8List kHealthFrame = Uint8List.fromList([0x08, 0x08, 0x03, 0x2a]);

Future<List<BandEvent>> replay({
  List<(int, Uint8List)> normal = const [],
  List<(int, Uint8List)> health = const [],
}) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kId115Adapter.run(link).listen(events.add, onDone: done.complete);
  // `run()` is `async*`: `.listen()` schedules its body rather than running
  // it synchronously. This adapter subscribes to BOTH channels — if a test
  // only feeds one of them, the other's `notify()` call would otherwise
  // still be pending when `link.close()` starts iterating `_channels`,
  // inserting a new entry mid-iteration. One microtask turn is enough for
  // both subscriptions to be registered first.
  await Future<void>.delayed(Duration.zero);
  for (final (sec, value) in normal) {
    link.feed(kId115NotifyNormalChar, value, atSec: sec);
  }
  for (final (sec, value) in health) {
    link.feed(kId115NotifyHealthChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kId115Adapter.signals, isEmpty);
    expect(kId115Adapter.entry.isFramed, isFalse);
  });

  test('a frame on the general channel is archived, never a NeutralSample',
      () async {
    final events = await replay(normal: [(1_800_000_000, kNormalFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.raw!.single, kNormalFrame);
  });

  test('a frame on the health-data channel is archived too', () async {
    final events = await replay(health: [(1_800_000_000, kHealthFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.raw!.single, kHealthFrame);
  });

  test('frames from both channels are archived independently', () async {
    final events = await replay(
      normal: [(1_800_000_000, kNormalFrame)],
      health: [(1_800_000_001, kHealthFrame)],
    );
    expect(events.whereType<SampleBatch>(), hasLength(2));
  });

  test('never writes to the peripheral', () async {
    final link = ReplayBandLink();
    final sub = kId115Adapter.run(link).listen((_) {});
    link.feed(kId115NotifyNormalChar, kNormalFrame, atSec: 1_800_000_000);
    link.feed(kId115NotifyHealthChar, kHealthFrame, atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events = await replay(normal: [(1_800_000_000, kNormalFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
