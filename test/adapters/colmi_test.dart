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
Future<({List<BandEvent> events, List<(String, List<int>)> writes})> _replay({
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
  return (events: events, writes: link.writes);
}

/// [value] as 5 little-endian bytes, matching `colmi.dart`'s own private
/// `_leBytes5` (not reachable from here — library-private per file, not per
/// package) byte for byte.
List<int> _leBytes5(int value) =>
    List<int>.generate(5, (i) => (value >> (8 * i)) & 0xff);

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
    const nowSeconds = 1_800_000_000;
    final result = await _replay(nowSeconds: () => nowSeconds);
    final events = result.events;
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

    // The exact write sequence: one battery request, then 7 days of
    // [hr, stress, hrv, activity], each on the write characteristic. This is
    // the assertion the event-only checks above cannot make — it fails the
    // moment the history loop is shortened, skipped, or reordered while the
    // battery request alone still produces an event.
    final writes = result.writes;
    expect(writes, hasLength(1 + 7 * 4));
    for (final (uuid, _) in writes) {
      expect(uuid, kColmiWriteChar);
    }
    expect(writes[0].$2, colmiFrame(kColmiCmdBattery));

    for (var day = 0; day < 7; day++) {
      final base = 1 + day * 4;
      final dayTs = nowSeconds - day * 86400;
      expect(writes[base].$2, colmiFrame(kColmiCmdHrHistory, <int>[day, ..._leBytes5(dayTs)]));
      expect(writes[base + 1].$2, colmiFrame(kColmiCmdStressHistory, <int>[day]));
      expect(writes[base + 2].$2, colmiFrame(kColmiCmdHrvHistory, <int>[day]));

      final date = DateTime.fromMillisecondsSinceEpoch(dayTs * 1000, isUtc: false);
      expect(
        writes[base + 3].$2,
        colmiFrame(kColmiCmdActivityHistory, <int>[
          colmiBcd(date.year % 100),
          colmiBcd(date.month),
          colmiBcd(date.day),
        ]),
      );
    }
  });

  test('cursor is deterministic off the injected clock, never a real one',
      () async {
    // Two independent replays off the SAME injected clock produce the
    // BYTE-IDENTICAL write sequence — proof the day-cursor bytes come only
    // from [nowSeconds], never `DateTime.now()`.
    const nowSeconds = 1_800_000_000;
    final a = await _replay(nowSeconds: () => nowSeconds);
    final b = await _replay(nowSeconds: () => nowSeconds);
    expect(
      a.writes.map((w) => w.$2).toList(),
      b.writes.map((w) => w.$2).toList(),
    );

    // A different injected clock moves the HR walk's timestamp bytes and the
    // activity walk's BCD date — the cursor tracks the clock, not a fixed day.
    final c = await _replay(nowSeconds: () => nowSeconds + 86400);
    expect(a.writes[1].$2, isNot(c.writes[1].$2));
  });
}
