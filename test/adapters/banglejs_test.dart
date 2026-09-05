// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), Bangle.js's shape: no
// signal is declared, so the only thing to prove is that nothing invents one
// — every chunk comes back as raw bytes and nothing else.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/banglejs.dart';

Future<List<BandEvent>> replay(List<(int, List<int>)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kBangleJsAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kNordicUartTxChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kBangleJsAdapter.signals, isEmpty);
    expect(kBangleJsAdapter.entry.isFramed, isFalse);
  });

  test('every notification is re-emitted verbatim as raw bytes, never decoded',
      () async {
    final events = await replay(const [
      (1_800_000_000, [0x10, 0x47, 0x42]), // arbitrary REPL text bytes
      (1_800_000_001, [0x0A]),
    ]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(2));
    for (final b in batches) {
      expect(b.samples, isEmpty);
      expect(b.ephemeral, isFalse);
      expect(b.raw, isNotNull);
    }
    expect(batches[0].raw!.single, Uint8List.fromList([0x10, 0x47, 0x42]));
    expect(batches[1].raw!.single, Uint8List.fromList([0x0A]));
  });

  test('never writes to the peripheral — there is nothing safe to hand a '
      'JS REPL', () async {
    final link = ReplayBandLink();
    final sub = kBangleJsAdapter.run(link).listen((_) {});
    link.feed(kNordicUartTxChar, const [0x01], atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('a pipe with no flash storage never emits an OffloadCheckpoint',
      () async {
    final events = await replay(const [(1_800_000_000, [0x01])]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
