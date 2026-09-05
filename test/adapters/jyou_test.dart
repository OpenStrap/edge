// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), Jyou's shape: no
// signal is declared, so the only thing to prove is that battery/firmware
// reach the host as notes and every other frame — including a decodable-
// looking HR one — comes back as raw bytes and nothing else.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/jyou.dart';

/// Battery frame: tag 0xF7, level 77 at byte 8.
final Uint8List kBatteryFrame =
    Uint8List.fromList([0xF7, 0, 0, 0, 0, 0, 0, 0, 77]);

/// Device-info frame: tag 0xF6, firmware byte 0x8F (143 -> "1.4.3") at byte 4.
final Uint8List kDeviceInfoFrame =
    Uint8List.fromList([0xF6, 0, 0, 0, 143, 0, 0, 0]);

/// Heart-rate frame: tag 0xFC, bpm 68 at byte 8 — decodable by spec, but this
/// adapter must never turn it into a [NeutralSample].
final Uint8List kHrFrame =
    Uint8List.fromList([0xFC, 0, 0, 0, 0, 0, 0, 0, 68]);

Future<List<BandEvent>> replay(List<(int, Uint8List)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub =
      kJyouAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kJyouMeasureChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('declares no signals — no card may ever key off this adapter', () {
    expect(kJyouAdapter.signals, isEmpty);
    expect(kJyouAdapter.entry.isFramed, isFalse);
  });

  test('battery and firmware reach the host as notes', () async {
    final events = await replay([
      (1_800_000_000, kBatteryFrame),
      (1_800_000_001, kDeviceInfoFrame),
    ]);
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 77), isTrue);
    expect(
      notes.any((n) => n.key == 'firmware' && n.value == '1.4.3'),
      isTrue,
    );
  });

  test('a heart-rate frame never becomes a NeutralSample, only raw bytes',
      () async {
    final events = await replay([(1_800_000_000, kHrFrame)]);
    final batches = events.whereType<SampleBatch>().toList();
    expect(batches, hasLength(1));
    expect(batches.single.samples, isEmpty);
    expect(batches.single.ephemeral, isFalse);
    expect(batches.single.raw!.single, kHrFrame);
  });

  test('every frame is archived, known tag or not', () async {
    final events = await replay([
      (1_800_000_000, kBatteryFrame),
      (1_800_000_001, kDeviceInfoFrame),
      (1_800_000_002, kHrFrame),
    ]);
    expect(events.whereType<SampleBatch>(), hasLength(3));
  });

  test('never writes to the peripheral', () async {
    final link = ReplayBandLink();
    final sub = kJyouAdapter.run(link).listen((_) {});
    link.feed(kJyouMeasureChar, kBatteryFrame, atSec: 1_800_000_000);
    await link.close();
    await sub.cancel();
    expect(link.writes, isEmpty);
  });

  test('no flash storage, never emits an OffloadCheckpoint', () async {
    final events = await replay([(1_800_000_000, kBatteryFrame)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });
}
