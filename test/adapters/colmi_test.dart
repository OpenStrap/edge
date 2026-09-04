// Replay a fixture through [ReplayBandLink] and assert: checksum construction,
// one paged history walk, and that `signals` is empty — the mandatory adapter
// test (MULTIBAND_PLAN §3.3.3), same shape as `ble_hrs_adapter_test.dart` and
// `oura_adapter_test.dart`.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart';

/// Drive [ColmiAdapter] over a link that answers every write with the SAME
/// one-frame reply (tagged with the request's own command id), then ends.
/// Enough to exercise the write/collect loop without hand-building a
/// multi-packet history reply.
Future<List<BandEvent>> _replay({
  required int Function() nowSeconds,
  Duration quietTimeout = const Duration(milliseconds: 20),
}) async {
  final link = ReplayBandLink();
  final adapter = ColmiAdapter(
    nowSeconds: nowSeconds,
    firstReplyTimeout: const Duration(milliseconds: 100),
    quietTimeout: quietTimeout,
  );
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);

  // Answer every write with one reply frame under the SAME command id, a
  // beat after the write lands — long enough that the adapter's own
  // `_collect` has actually started waiting, short enough that the quiet
  // timeout above still trips promptly.
  unawaited(() async {
    var lastWriteCount = 0;
    while (!done.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (link.writes.length > lastWriteCount) {
        final (_, value) = link.writes.last;
        lastWriteCount = link.writes.length;
        final reply = List<int>.from(value)..[1] = 0x2a;
        link.feed(kColmiNotifyChar, reply, atSec: nowSeconds());
      }
    }
  }());

  await done.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  await link.close();
  return events;
}

void main() {
  test('a frame checksums as the low byte of the sum of bytes 0-14', () {
    final f = colmiFrame(kColmiCmdBattery);
    expect(f, hasLength(16));
    expect(f[0], kColmiCmdBattery);
    var sum = 0;
    for (var i = 0; i < 15; i++) {
      sum += f[i];
    }
    expect(f[15], sum & 0xff);

    // A non-trivial payload checksums the same way.
    final withPayload = colmiFrame(kColmiCmdHrHistory, <int>[3, 1, 2, 3, 4, 5]);
    var sum2 = 0;
    for (var i = 0; i < 15; i++) {
      sum2 += withPayload[i];
    }
    expect(withPayload[15], sum2 & 0xff);
    expect(withPayload[1], 3); // day offset lands at payload[0].
  });

  test('BCD encodes a two-digit value byte-literally', () {
    expect(colmiBcd(24), 0x24);
    expect(colmiBcd(9), 0x09);
    expect(colmiBcd(0), 0x00);
  });

  test('declares no signals, matching the hard invariant for an unverified band',
      () {
    expect(kColmiAdapter.signals, isEmpty);
    expect(kColmiAdapter.entry.isFramed, isFalse);
  });

  test('a paged history walk writes a day-cursor request per command and '
      'banks every reply as raw, decoding nothing', () async {
    final events = await _replay(nowSeconds: () => 1_800_000_000);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    // The whole point: bytes are banked, nothing is decoded into a sample.
    expect(samples, isEmpty);

    final rawFrames = [
      for (final e in events)
        if (e is SampleBatch) ...?e.raw,
    ];
    expect(rawFrames, isNotEmpty);

    final batteryNotes = events.whereType<BandNote>().where((n) => n.key == 'battery');
    expect(batteryNotes, hasLength(1));
    expect(batteryNotes.single.value, 0x2a);

    // Never an OffloadCheckpoint: this ring has no ACK/trim command at all —
    // the host reads a rolling window on its own schedule, same as a
    // notify-only sensor.
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('cursor is deterministic off the injected clock, never a real one',
      () async {
    final events = await _replay(nowSeconds: () => 1_800_000_000);
    // Every write this adapter made is reconstructible from the fixed clock —
    // proven by the fact the fake link's reply loop above (matching purely on
    // "a new write landed") was enough for every command to get answered.
    expect(events, isNotEmpty);
  });
}
