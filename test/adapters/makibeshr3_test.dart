// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), this board's shape: no
// signal declared and no command ever written, so the only thing to prove is
// that every arriving frame is archived verbatim and nothing else happens.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/makibeshr3.dart';

/// A made-up notification — decodable-looking, but this adapter must never
/// turn it into a [NeutralSample].
final Uint8List kSomeFrame = Uint8List.fromList([0x02, 0x01, 0x4b]);

Future<List<BandEvent>> replay(List<(int, Uint8List)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kMakibesHr3Adapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kMakibesHr3ReportChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kMakibesHr3Adapter.signals, isEmpty);
    expect(kMakibesHr3Adapter.entry.isFramed, isFalse);
  });

  test('a frame never becomes a NeutralSample, only raw bytes', () async {
    final events = await replay([(1_800_000_000, kSomeFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.ephemeral, isFalse);
    expect(batches.single.raw!.single, kSomeFrame);
  });

  test('an empty notification archives nothing', () async {
    final events = await replay([(1_800_000_000, Uint8List(0))]);
    expect(events.whereType<SampleBatch>(), isEmpty);
  });

  test('never writes to the peripheral', () async {
    final link = ReplayBandLink();
    final sub = kMakibesHr3Adapter.run(link).listen((_) {});
    link.feed(kMakibesHr3ReportChar, kSomeFrame, atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events = await replay([(1_800_000_000, kSomeFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
