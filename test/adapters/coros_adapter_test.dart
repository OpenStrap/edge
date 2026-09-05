// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): replay a fixture
// through a [ReplayBandLink] and assert that every signal the adapter
// DECLARES really appears in what it EMITS — plus the one-shot status pull
// this adapter adds on top of the generic HR parse [BleHrsAdapter] already
// has (pinned in `ble_hrs_adapter_test.dart`).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/coros.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';

/// uint8 HR + contact supported/detected + RR present; 500 and 512 ticks.
const List<int> kHrWithTwoRr = <int>[0x16, 120, 0xF4, 0x01, 0x00, 0x02];

/// flags 0x00 — the RR bit CLEAR, which plenty of optical armbands never set.
const List<int> kBpmOnly = <int>[0x00, 61];

/// Drive [CorosAdapter] over recorded bytes and reads and collect what it
/// yields. [reads] primes the one-shot GATT reads the status pull makes.
Future<List<BandEvent>> replay(
  List<(int, List<int>)> arrivals, {
  Map<String, List<int>> reads = const {},
}) async {
  final link = ReplayBandLink()..reads.addAll(reads);
  final events = <BandEvent>[];
  final done = Completer<void>();
  // onDone is wired BEFORE anything is fed: `run()` finishing is what we wait
  // on, and guessing at a delay instead is how a test drops the tail.
  final sub = kCorosAdapter.run(link).listen(events.add, onDone: done.complete);
  for (final (sec, value) in arrivals) {
    link.feed(kHeartRateMeasurementUuid, value, atSec: sec);
  }
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  test('every declared InputSignal actually appears in an emitted sample',
      () async {
    final events = await replay(const [
      (1_800_000_000, kHrWithTwoRr),
      (1_800_000_001, kBpmOnly),
    ]);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isNotEmpty);

    final seen = <InputSignal>{
      if (samples.any((s) => s.hr != null)) InputSignal.hrSparse,
      if (samples.any((s) => s.rrMs.isNotEmpty)) InputSignal.rrIntervals,
    };
    expect(seen, containsAll(kCorosAdapter.signals.keys),
        reason: 'a declared signal that never arrives leaves a permanently '
            'empty card instead of no card');
    expect(kCorosAdapter.signals.keys.toSet(), seen);
  });

  test('arrival time comes from the LINK, never from a clock in the adapter',
      () async {
    final events = await replay(const [(1_800_000_000, kHrWithTwoRr)]);
    final batches = events.whereType<SampleBatch>();
    expect(batches, hasLength(1));
    final s = batches.single.samples.single;
    expect(s.tsEpoch, 1_800_000_000);
    expect(s.anchor, TimeAnchor.arrival);
  });

  test('an off-chest reading is refused outright, not banked as a low HR',
      () async {
    final events = await replay(const [
      (1_800_000_000, kHrWithTwoRr),
      (1_800_000_001, <int>[0x04, 45]), // contact bits 0b10 = off the chest
    ]);
    expect(events.whereType<SampleBatch>(), hasLength(1));
  });

  test('this watch stores nothing this project decodes, so it never emits '
      'an OffloadCheckpoint', () async {
    final events = await replay(const [(1_800_000_000, kHrWithTwoRr)]);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    expect(kCorosAdapter.entry.isFramed, isFalse);
  });

  test('battery and device identity surface as BandNotes when the reads '
      'answer', () async {
    // Fed alongside one HR arrival rather than an empty fixture: `close()`
    // only ends channels the generator has already subscribed to, and this
    // is what guarantees it has reached that point before the link closes.
    final events = await replay(
      const [(1_800_000_000, kHrWithTwoRr)],
      reads: {
        kBatteryLevelUuid: [72],
        kModelNumberUuid: utf8Bytes('PACE 3'),
        kSerialNumberUuid: utf8Bytes('SN12345'),
        kFirmwareRevisionUuid: utf8Bytes('3.0512.0'),
      },
    );
    final notes = {
      for (final e in events.whereType<BandNote>()) e.key: e.value,
    };
    expect(notes['battery'], 72);
    expect(notes['model'], 'PACE 3');
    expect(notes['serial'], 'SN12345');
    expect(notes['firmware'], '3.0512.0');
  });

  test('a watch that answers nothing for the status pull still connects and '
      'still yields HR', () async {
    final events = await replay(const [(1_800_000_000, kHrWithTwoRr)]);
    expect(events.whereType<BandNote>(), isEmpty);
    expect(events.whereType<SampleBatch>(), hasLength(1));
  });
}

/// Test-only helper: a Device Information string as the bytes the wire
/// actually carries.
List<int> utf8Bytes(String s) => utf8.encode(s);
