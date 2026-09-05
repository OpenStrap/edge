// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), Pebble's shape: no
// signal to check for arrival, so what is pinned here instead is the
// transport staying alive — the ACK a data packet gets, the raw bytes it
// banks, and the fixed control reply a reset request gets.
//
// ~40 lines, no hardware, no mocks — same worked-example shape as
// `ble_hrs_adapter_test.dart`.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/pebble.dart';

/// Drive [PebbleAdapter] over recorded bytes and collect what it yields.
Future<List<BandEvent>> replay(ReplayBandLink link, List<List<int>> arrivals) async {
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = kPebbleAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final value in arrivals) {
    link.feed(kPebblePpogattReadUuid, value, atSec: 1_800_000_000);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('a data packet is ACKed on the write characteristic and its payload '
      'is banked as raw', () async {
    final link = ReplayBandLink();
    // header = (serial 3 << 3) | command 0 = 0x18, payload [0xAA, 0xBB].
    final events = await replay(link, [
      <int>[0x18, 0xAA, 0xBB],
    ]);

    expect(link.writes, hasLength(1));
    expect(link.writes.single.$1, kPebblePpogattWriteUuid);
    expect(link.writes.single.$2, <int>[0x19]); // (3<<3)|1
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.raw, [Uint8List.fromList(<int>[0xAA, 0xBB])]);
  });

  test('a reset request with a body gets the three-byte fixed reply', () async {
    final link = ReplayBandLink();
    // header = (serial 1 << 3) | command 2 = 0x0A, with a body byte.
    await replay(link, [
      <int>[0x0A, 0x01],
    ]);
    expect(link.writes, hasLength(1));
    expect(link.writes.single.$1, kPebblePpogattWriteUuid);
    expect(link.writes.single.$2, <int>[0x03, 0x19, 0x19]);
  });

  test('a bare reset request (no body) gets the one-byte fixed reply',
      () async {
    final link = ReplayBandLink();
    await replay(link, [
      <int>[0x02], // (0<<3)|2, header only
    ]);
    expect(link.writes, hasLength(1));
    expect(link.writes.single.$1, kPebblePpogattWriteUuid);
    expect(link.writes.single.$2, <int>[0x03]);
  });

  test('an ACK for a serial we sent is logged, nothing banked and nothing '
      'written back', () async {
    final link = ReplayBandLink();
    final events = await replay(link, [
      <int>[0x09], // (1<<3)|1
    ]);
    expect(link.writes, isEmpty);
    expect(events, isEmpty);
    expect(link.logs, contains('pebble: ack for serial 1'));
  });

  test('an unconfirmed ack write banks nothing, expecting a retransmit',
      () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    // header = (serial 3 << 3) | command 0 = 0x18, payload [0xAA, 0xBB].
    final events = await replay(link, [
      <int>[0x18, 0xAA, 0xBB],
    ]);
    expect(events.whereType<SampleBatch>(), isEmpty);
    expect(link.logs, contains('pebble: ack write unconfirmed for serial 3, '
        'expecting a retransmit'));
  });

  test('a Pebble stores nothing on our say-so, so it never emits an '
      'OffloadCheckpoint', () async {
    final link = ReplayBandLink();
    final events = await replay(link, [
      <int>[0x18, 0xAA],
    ]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    expect(kPebbleAdapter.entry.isFramed, isFalse);
    expect(kPebbleAdapter.signals, isEmpty);
  });
}
