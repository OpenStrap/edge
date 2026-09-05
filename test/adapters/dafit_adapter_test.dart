// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), adapted for a band that
// declares no signals at all: assert that this adapter really does bank
// every frame verbatim, acks only the two replies the handshake expects, and
// never yields a sample or an offload checkpoint.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/dafit.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Drive [DafitAdapter] over a replayed link with no handshake pacing (a
/// fixture should not sit through eight real 200 ms waits), collecting
/// whatever it yields until the link closes.
Future<List<BandEvent>> replay(
  DafitAdapter adapter,
  ReplayBandLink link, {
  FutureOr<void> Function(ReplayBandLink link)? whileRunning,
}) async {
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  // `run()` is `async*`: `.listen()` schedules its body rather than running it
  // synchronously, so without this the notify channel this adapter subscribes
  // to may not exist yet when `link.close()` below iterates `_channels` —
  // closing nothing, and leaving the adapter awaiting a channel that never
  // closes. One microtask turn is enough for the body to reach its first
  // `await`, which is well past the `notify()` call that creates the channel.
  await Future<void>.delayed(Duration.zero);
  if (whileRunning != null) await whileRunning(link);
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  final adapter = DafitAdapter(
    now: () => DateTime.utc(2024, 3, 5, 14, 22, 37),
    handshakePause: Duration.zero,
  );

  test('writes the eight-frame init handshake, in order', () async {
    final link = ReplayBandLink();
    await replay(adapter, link);
    expect(link.writes, hasLength(8));
    for (final (uuid, _) in link.writes) {
      expect(uuid, kDafitWriteChar);
    }
    // The clock write really carries the injected `now`.
    final clockFrame = parseDafitFrame(link.writes[1].$2)!;
    expect(clockFrame.group, kDafitGroupGeneral);
    expect(clockFrame.command, kDafitCmdSetDateTime);
  });

  test('acks a hardware-info reply but archives it, not decodes it',
      () async {
    final link = ReplayBandLink();
    final hwInfoReply =
        buildDafitFrame(kDafitGroupRequestData, kDafitCmdGetHwInfo, [0x01, 0x02]);
    final events = await replay(adapter, link, whileRunning: (l) async {
      l.feed(kDafitNotifyChar, hwInfoReply, atSec: 1_800_000_000);
      // Give the async notification handler a turn to run its ack write.
      await Future<void>.delayed(Duration.zero);
    });

    // Exactly one ack, matching the group of the frame it acked. Filtered by
    // the ack header rather than assumed to be the 9th write: the handshake
    // writes and the notify listener's ack write are two independent async
    // flows over the same link, so their relative ORDER in `link.writes` is
    // not guaranteed — only that the ack appears somewhere.
    final acks =
        link.writes.where((w) => w.$2[0] == kDafitAckHeader).toList();
    expect(acks, hasLength(1));
    expect(acks.single.$1, kDafitWriteChar);
    expect(acks.single.$2[3], kDafitGroupRequestData);

    // Banked verbatim, not turned into any structured value.
    final raw = [for (final e in events) if (e is SampleBatch) ...?e.raw];
    expect(raw, anyElement(orderedEquals(hwInfoReply)));
  });

  test('leaves an unrelated notification archived and un-acked', () async {
    final link = ReplayBandLink();
    // A button-press frame — not one of the two acked group/commands.
    final buttonFrame = buildDafitFrame(0x1c, 0x01);
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kDafitNotifyChar, buttonFrame, atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
    });
    expect(link.writes, hasLength(8)); // handshake only, no ack appended
  });

  test('declares and emits no signal at all', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      l.feed(
        kDafitNotifyChar,
        buildDafitFrame(kDafitGroupBandInfo, kDafitCmdGetBandInfo, [0x01]),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
    });
    expect(adapter.signals, isEmpty);
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isEmpty);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('a refused handshake write ends the session without hanging',
      () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    final events = await replay(adapter, link);
    expect(events, isEmpty);
    expect(link.writes, hasLength(1)); // stops at the first refusal
  });

  test('a frame archived before a LATER refused write is not dropped',
      () async {
    // handshakePause > 0 here, deliberately: the default adapter's zero pause
    // resolves all 8 writes in one microtask cascade, leaving no room to flip
    // writeSucceeds mid-handshake the way a real refusal partway through can.
    final localAdapter = DafitAdapter(
      now: () => DateTime.utc(2024, 3, 5, 14, 22, 37),
      handshakePause: const Duration(milliseconds: 5),
    );
    final link = ReplayBandLink();
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub =
        localAdapter.run(link).listen(events.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero); // let notify() subscribe
    // A button-press frame lands and is archived while the first handshake
    // write is still succeeding.
    final buttonFrame = buildDafitFrame(0x1c, 0x01);
    link.feed(kDafitNotifyChar, buttonFrame, atSec: 1_800_000_000);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    link.writeSucceeds = false; // the SECOND handshake write is refused
    await done.future;
    await sub.cancel();

    expect(link.writes, hasLength(2)); // stops at the second write's refusal
    final raw = [for (final e in events) if (e is SampleBatch) ...?e.raw];
    expect(raw, anyElement(orderedEquals(buttonFrame)));
  });
}
