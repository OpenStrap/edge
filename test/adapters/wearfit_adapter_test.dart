// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), for a write+notify band
// with no declared signals at all: replay a fixture through a
// [ReplayBandLink] and assert the session asks for battery, archives every
// frame verbatim, and — the empty-signals half — emits no [NeutralSample].

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/wearfit.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Real captured battery reply: not charging, 80%.
const List<int> kBatteryReply = <int>[0xab, 0x00, 0x05, 0xff, 0x91, 0x80, 0x00, 0x50];

/// Real captured device-info reply — recognised as a frame, not decoded.
const List<int> kDeviceInfoReply = <int>[
  0xab, 0x00, 0x11, 0xff, 0x92, //
  0xc0, 0x08, 0x04, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x60, 0x00, 0x6b,
];

/// Drive [WearFitAdapter] over recorded bytes and collect what it yields.
Future<List<BandEvent>> replay(List<List<int>> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = kWearFitAdapter.run(link).listen(events.add, onDone: done.complete);
  // The adapter's first write (the battery request) happens before it starts
  // listening in any observable way here — feeding replies after `run` is
  // called is enough, same as `ble_hrs_adapter_test.dart`.
  for (final value in arrivals) {
    link.feed(kWearFitNotifyChar, value, atSec: 1_800_000_000);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('asks for battery before listening for anything else', () async {
    final link = ReplayBandLink();
    final sub = kWearFitAdapter.run(link).listen((_) {});
    // Give the adapter's first `await link.write(...)` a turn to land.
    await Future<void>.delayed(Duration.zero);
    expect(link.writes, hasLength(1));
    expect(link.writes.single.$1, kWearFitWriteChar);
    expect(link.writes.single.$2, wearFitCmdGetBattery());
    await link.close();
    await sub.cancel();
  });

  test('decodes the battery reply into a BandNote, never a signal', () async {
    final events = await replay([kBatteryReply]);
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 80), isTrue);
    expect(
      notes.any((n) => n.key == 'battery_charging' && n.value == false),
      isTrue,
    );
  });

  test('archives every frame verbatim, decoded or not', () async {
    final events = await replay([kBatteryReply, kDeviceInfoReply]);
    final raw = [
      for (final e in events)
        if (e is SampleBatch) ...?e.raw,
    ];
    expect(raw.map((b) => b.toList()), [kBatteryReply, kDeviceInfoReply]);
  });

  test('declares no signal, and emits no NeutralSample either', () async {
    expect(kWearFitAdapter.signals, isEmpty);
    final events = await replay([kBatteryReply, kDeviceInfoReply]);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isEmpty);
  });

  test('never emits an OffloadCheckpoint — nothing here trims a flash',
      () async {
    final events = await replay([kBatteryReply]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    expect(kWearFitAdapter.entry.isFramed, isFalse);
  });
}
