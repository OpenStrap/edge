// Replay a fixture through a [ReplayBandLink] and assert what [HPlusAdapter]
// decodes, archives, and — just as importantly — never claims. Same shape as
// `ble_hrs_adapter_test.dart` and `oura_adapter_test.dart`: no hardware, no
// mocks.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/hplus.dart';

/// A realtime-stats frame long enough to carry a battery byte at offset 9.
/// Fields before and after it (steps/distance/calories/reserved/HR/active
/// time) are filler; only the tag and the battery byte are asserted against.
List<int> realtimeFrame({required int battery}) => <int>[
      0x33, // tag
      0, 0, // steps
      0, 0, // distance
      0, 0, 0, 0, // calories
      battery, // battery — offset 9
      0, // reserved
      0, // heart rate
      0, 0, // active time
    ];

/// Drive [HPlusAdapter] over recorded bytes and collect what it yields.
Future<List<BandEvent>> replay(List<(int, List<int>)> arrivals) async {
  final link = ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  const adapter = HPlusAdapter(idleTimeout: Duration(milliseconds: 200));
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  // Let the init-sequence writes go out before frames start arriving — the
  // ReplayBandLink buffers regardless, but this mirrors real timing.
  await Future<void>.delayed(Duration.zero);
  for (final (sec, value) in arrivals) {
    link.feed(kHPlusMeasureChar, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('the init sequence is written to the control characteristic, in order',
      () async {
    final link = ReplayBandLink();
    const adapter = HPlusAdapter(idleTimeout: Duration(milliseconds: 200));
    final done = Completer<void>();
    final sub = adapter.run(link).listen((_) {}, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    await link.close();
    await done.future;
    await sub.cancel();
    expect(link.writes.map((w) => w.$2).toList(), <List<int>>[
      <int>[0x4f, 0x5a],
      <int>[0x4d],
      <int>[0x35, 0x0a],
      <int>[0x4f],
    ]);
    expect(link.writes.every((w) => w.$1 == kHPlusControlChar), isTrue);
  });

  test('a realtime-stats frame surfaces its battery byte as a BandNote',
      () async {
    final events =
        await replay([(1_800_000_000, realtimeFrame(battery: 61))]);
    final notes = events.whereType<BandNote>().toList();
    expect(notes.where((n) => n.key == 'battery').map((n) => n.value),
        <int>[61]);
  });

  test('0xff on the battery byte is the not-measured sentinel — no note',
      () async {
    final events =
        await replay([(1_800_000_000, realtimeFrame(battery: 0xff))]);
    expect(events.whereType<BandNote>().where((n) => n.key == 'battery'),
        isEmpty);
  });

  test('a tag-0x18 firmware-version frame decodes its two raw bytes',
      () async {
    final events =
        await replay([(1_800_000_000, <int>[0x18, 7, 2])]); // minor, major
    final notes =
        events.whereType<BandNote>().where((n) => n.key == 'firmware');
    expect(notes.map((n) => n.value), <String>['2.7']);
  });

  test('a tag-0x2e firmware-version frame reads minor/major at its own offset',
      () async {
    final versionFrame = <int>[0x2e, 0, 0, 0, 0, 0, 0, 0, 0, 7, 2];
    final events = await replay([(1_800_000_000, versionFrame)]);
    final notes =
        events.whereType<BandNote>().where((n) => n.key == 'firmware');
    expect(notes.map((n) => n.value), <String>['2.7']);
  });

  test('every frame is archived verbatim, decoded or not', () async {
    final events = await replay([
      (1_800_000_000, realtimeFrame(battery: 50)),
      (1_800_000_001, <int>[0x1a, 1, 2, 3]), // sleep record — never decoded
    ]);
    final raw = [
      for (final e in events)
        if (e is SampleBatch) ...?e.raw,
    ];
    expect(raw, hasLength(2));
    expect(raw[0], Uint8List.fromList(realtimeFrame(battery: 50)));
    expect(raw[1], Uint8List.fromList(<int>[0x1a, 1, 2, 3]));
  });

  test('nothing here declares a signal, and nothing offloads', () async {
    expect(const HPlusAdapter().signals, isEmpty);
    final events = await replay([(1_800_000_000, realtimeFrame(battery: 50))]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isEmpty);
  });
}
