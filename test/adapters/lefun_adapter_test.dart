// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): replay a fixture
// through a [ReplayBandLink]. `LefunAdapter.signals` is `const {}`, so there
// is no declared signal to assert appears — the shape this test proves
// instead is the one this adapter actually makes: one bounded battery
// request, then bank whatever the notify characteristic hands back.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/lefun.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Future<List<BandEvent>> replay(
  List<int> Function(List<int> writeArgs)? reply, {
  Duration replyTimeout = const Duration(milliseconds: 20),
}) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final adapter = LefunAdapter(replyTimeout: replyTimeout);
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  // Wait for the write to land before answering it — a fixed delay would
  // race the adapter's own write.
  while (link.writes.isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  if (reply != null) {
    link.feed(kLefunNotifyChar, reply(link.writes.single.$2), atSec: 0);
  }
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signal at all', () {
    expect(LefunAdapter().signals, isEmpty);
  });

  test('writes exactly one battery request, then ends the stream', () async {
    final link = ReplayBandLink();
    final done = Completer<void>();
    final sub = LefunAdapter(replyTimeout: const Duration(milliseconds: 5))
        .run(link)
        .listen((_) {}, onDone: done.complete);
    await done.future;
    await sub.cancel();
    expect(link.writes, hasLength(1));
    expect(link.writes.single.$1, kLefunWriteChar);
    expect(link.writes.single.$2, buildLefunFrame(kLefunReportBattery));
  });

  test('a battery reply becomes a BandNote and an archived frame', () async {
    final events = await replay((_) => const [0x5A, 0x05, 0x03, 0x57, 0xFB]);
    final notes = events.whereType<BandNote>().toList();
    expect(notes, hasLength(1));
    expect(notes.single.key, 'battery');
    expect(notes.single.value, 87);

    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.raw, hasLength(1));
    expect(batches.single.raw!.single,
        const [0x5A, 0x05, 0x03, 0x57, 0xFB]);
  });

  test('a corrupted frame is dropped, not archived', () async {
    // Same bytes as above with the checksum flipped.
    final events = await replay((_) => const [0x5A, 0x05, 0x03, 0x57, 0x00]);
    expect(events.whereType<BandNote>(), isEmpty);
    expect(events.whereType<SampleBatch>(), isEmpty);
  });

  test('nothing arriving yields nothing, not an empty archive', () async {
    final events = await replay(null);
    expect(events, isEmpty);
  });

  test('a refused write ends the session without waiting out the timeout',
      () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sw = Stopwatch()..start();
    final sub = LefunAdapter(replyTimeout: const Duration(seconds: 30))
        .run(link)
        .listen(events.add, onDone: done.complete);
    await done.future;
    await sub.cancel();
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    expect(events, isEmpty);
  });
}
