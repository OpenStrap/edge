// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), this board's shape: no
// signal declared and no command ever written, so the only thing to prove is
// that every arriving frame is archived verbatim and nothing else happens.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/watch9.dart';

/// A battery-info reply, this board's own header shape (`RESP_BATTERY_INFO =
/// [0x08, 0x01, 0x14]`) plus a made-up value byte — decodable by spec, but
/// this adapter must never turn it into a [NeutralSample].
final Uint8List kBatteryFrame =
    Uint8List.fromList([0x08, 0x01, 0x14, 0x5a]);

Future<List<BandEvent>> replay(List<(int, Uint8List)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kWatch9Adapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kWatch9Char, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kWatch9Adapter.signals, isEmpty);
    expect(kWatch9Adapter.entry.isFramed, isFalse);
  });

  test('a battery-shaped frame never becomes a NeutralSample, only raw bytes',
      () async {
    final events = await replay([(1_800_000_000, kBatteryFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.ephemeral, isFalse);
    expect(batches.single.raw!.single, kBatteryFrame);
  });

  test('an empty notification archives nothing', () async {
    final events =
        await replay([(1_800_000_000, Uint8List(0))]);
    expect(events.whereType<SampleBatch>(), isEmpty);
  });

  test('never writes to the peripheral', () async {
    final link = ReplayBandLink();
    final sub = kWatch9Adapter.run(link).listen((_) {});
    link.feed(kWatch9Char, kBatteryFrame, atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events = await replay([(1_800_000_000, kBatteryFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
