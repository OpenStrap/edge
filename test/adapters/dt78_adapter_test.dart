// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), adapted for a band that
// declares NO signals at all: instead of "every declared signal arrives",
// this pins the two things that matter for a raw-bank-only adapter — every
// frame reaches `raw_archive` and nothing here is ever mistaken for a decoded
// health value.
//
// No hardware, no mocks: a [ReplayBandLink] fed the format's own worked
// examples byte-for-byte.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/dt78.dart';

/// `AB 00 05 FF 91 80 00 50` — the format's own battery worked example:
/// level 0x50 = 80.
const List<int> kBatteryReply = <int>[0xAB, 0x00, 0x05, 0xFF, 0x91, 0x80, 0x00, 0x50];

/// Drive [Dt78Adapter] over recorded bytes and collect what it yields.
Future<List<BandEvent>> replay(
  void Function(ReplayBandLink link) feed,
) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = kDt78Adapter.run(link).listen(events.add, onDone: done.complete);
  // Let the four startup polls actually go out before feeding replies —
  // otherwise a poll's own write is not yet in `link.writes` when a test
  // wants to assert against it.
  await Future<void>.delayed(Duration.zero);
  feed(link);
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — every frame is a bank, never a measurement',
      () {
    expect(kDt78Adapter.signals, isEmpty);
    expect(kDt78Adapter.entry.isFramed, isFalse);
  });

  test('polls device info, battery, the health bundle and steps on start',
      () async {
    final link = ReplayBandLink();
    final done = Completer<void>();
    final sub = kDt78Adapter.run(link).listen((_) {}, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    await link.close();
    await done.future;
    await sub.cancel();

    // Compared as two parallel lists rather than a `List` of records: a
    // record's own `==` falls back to `List`'s IDENTITY equality for a
    // field that is itself a `List`, which `equals()`'s deep comparison does
    // not reach through — plain nested lists get the deep comparison this
    // needs.
    expect(link.writes.map((w) => w.$1).toList(),
        List.filled(4, kDt78WriteChar));
    expect(link.writes.map((w) => w.$2.toList()).toList(), <List<int>>[
      <int>[0xAB, 0x00, 3, 0xFF, 0x92, 0x80],
      <int>[0xAB, 0x00, 3, 0xFF, 0x91, 0x80],
      <int>[0xAB, 0x00, 3, 0xFF, 0x32, 0x01],
      <int>[0xAB, 0x00, 3, 0xFF, 0x51, 0x80],
    ]);
  });

  test('a battery reply becomes a note; the frame is still archived',
      () async {
    final events = await replay(
      (link) => link.feed(kDt78NotifyChar, kBatteryReply, atSec: 1_800_000_000),
    );
    final notes = events.whereType<BandNote>().toList();
    expect(notes.where((n) => n.key == 'battery').single.value, 80);

    final batches = events.whereType<SampleBatch>().toList();
    expect(batches.any((b) => b.raw != null && b.raw!.single.length == 8),
        isTrue,
        reason: 'the raw frame is banked whether or not it was decoded');
    // No signal was declared, so nothing here is ever a decoded sample.
    expect(batches.every((b) => b.samples.isEmpty), isTrue);
  });

  test('a frame split across two notifications is still reassembled',
      () async {
    final events = await replay((link) {
      link.feed(kDt78NotifyChar, kBatteryReply.sublist(0, 4), atSec: 1);
      link.feed(kDt78NotifyChar, kBatteryReply.sublist(4), atSec: 1);
    });
    expect(events.whereType<BandNote>().where((n) => n.key == 'battery'),
        hasLength(1));
  });

  test('an unrecognised command is archived, never dropped', () async {
    final unknown = <int>[0xAB, 0x00, 0x03, 0xFF, 0x77, 0x80];
    final events = await replay(
      (link) => link.feed(kDt78NotifyChar, unknown, atSec: 1),
    );
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches.any((b) => b.raw?.single.length == unknown.length), isTrue);
  });

  test('a too-short length byte is dropped as noise, not a crash', () async {
    // `len=2` claims a frame with no mode byte — shorter than any real
    // frame (`FF, cmd, mode` is the floor) — followed by a real battery
    // reply. Must resync onto the real frame rather than throw.
    final stray = <int>[0xAB, 0x00, 0x02, 0xFF, 0x99];
    final events = await replay(
      (link) => link.feed(
          kDt78NotifyChar, <int>[...stray, ...kBatteryReply], atSec: 1),
    );
    expect(events.whereType<BandNote>().where((n) => n.key == 'battery'),
        hasLength(1));
  });

  test('never emits an OffloadCheckpoint — this protocol has no trim-on-ack',
      () async {
    final events = await replay(
      (link) => link.feed(kDt78NotifyChar, kBatteryReply, atSec: 1),
    );
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('buildDt78Poll matches the format\'s own frame layout', () {
    expect(buildDt78Poll(0x91, 0x80), <int>[0xAB, 0x00, 3, 0xFF, 0x91, 0x80]);
  });
}
