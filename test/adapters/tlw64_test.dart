// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), this family's shape:
// no signal declared and no command ever written, so the only thing to
// prove is that every arriving frame is archived verbatim and nothing else
// happens.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/tlw64.dart';

/// A step-count push, real command byte (`CMD_FETCH_STEPS = 0xb2`) but a
/// made-up payload — decodable by spec, but this adapter must never turn it
/// into a [NeutralSample].
final Uint8List kStepsFrame =
    Uint8List.fromList([0xb2, 0x00, 0x00, 0x00, 0x0a]);

Future<List<BandEvent>> replay(List<(int, Uint8List)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kNo1BandAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kNo1NotifyChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kNo1BandAdapter.signals, isEmpty);
    expect(kNo1BandAdapter.entry.isFramed, isFalse);
  });

  test('a step-count frame never becomes a NeutralSample, only raw bytes',
      () async {
    final events = await replay([(1_800_000_000, kStepsFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.ephemeral, isFalse);
    expect(batches.single.raw!.single, kStepsFrame);
  });

  test('every frame is archived, including an empty-looking one dropped',
      () async {
    final events = await replay([
      (1_800_000_000, kStepsFrame),
      (1_800_000_001, Uint8List(0)),
    ]);
    // The empty notification yields nothing at all — there is no byte to
    // archive — while the real one still comes through.
    expect(events.whereType<SampleBatch>(), hasLength(1));
  });

  test('never writes to the peripheral', () async {
    final link = ReplayBandLink();
    final sub = kNo1BandAdapter.run(link).listen((_) {});
    link.feed(kNo1NotifyChar, kStepsFrame, atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events = await replay([(1_800_000_000, kStepsFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
