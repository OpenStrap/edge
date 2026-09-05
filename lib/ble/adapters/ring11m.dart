// A generic white-label smart ring ("R11M"/"R10M", also "TK5") as a
// [BandAdapter]: negotiate over the plain request/response command channel,
// correctly speak the block-ack/nack sub-protocol its history transfer uses,
// bank every frame verbatim, decode nothing physiological.
//
// NOT the Colmi R11/R12 — a different, unrelated product on a different
// protocol. NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6): it ships
// EXPERIMENTAL, `signals` stays `const {}`, and this id is absent from
// `kDerivableSources` — nothing this file writes can become a number until
// someone has held one.
//
// WHY THIS DOES NOT REQUEST HISTORY BY TYPE. `protocol`'s `ring11m.dart`
// pins the outer frame, the negotiation replies, and the block terminator —
// each checked against a real captured example or an exact byte sequence.
// What it deliberately has no builder for is the per-history-type REQUEST
// command ("query key") that starts a steps/sleep/HR/etc. transfer: no
// concrete byte value for one was available to check against a real frame,
// and inventing one is exactly the guess this project's whole discipline
// exists to refuse. So this session never asks the ring for a specific
// history type. What it DOES do, and does correctly: recognise ANY
// group-0x05 block the ring sends — pushed on its own, or later once a real
// request command is confirmed and this file is widened — validate its CRC,
// ack or nack it so the ring's own state machine keeps moving instead of
// stalling, and archive every byte regardless.
//
// WHY A BOUNDED WINDOW, LIKE THE DAFIT/MOYOUNG FAMILY AND NOT OURA'S
// `bytesLeft == 0`. There is no per-type request to exhaust and therefore no
// natural end-of-drain signal this file can read — the ring's own auto-sync
// behaviour, if it has one, is exactly what it decides on its own. A fixed
// window is the honest floor: long enough to run the negotiation and catch
// anything the ring sends during it, bounded so a background sync slot ends.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run], never on the instance (an adapter is const and a
/// session is not).
class Ring11mAdapter extends BandAdapter {
  /// Wall-clock now, injected so a fixture replay is deterministic.
  final DateTime Function() now;

  /// How long one session stays open once the negotiation completes, waiting
  /// for whatever the ring sends. See the header note on why this is bounded
  /// rather than driven by a request/completion pair.
  final Duration listenWindow;

  /// How long to wait for a reply to a negotiation write.
  final Duration replyTimeout;

  const Ring11mAdapter({
    this.now = DateTime.now,
    this.listenWindow = const Duration(seconds: 20),
    this.replyTimeout = const Duration(seconds: 5),
  });

  @override
  BandEntry get entry => kRing11m;

  /// NOTHING. The ring's realtime pushes and history records carry heart
  /// rate, SpO2 and activity data, but their body layouts are either
  /// undescribed or only hedged with plausibility bounds — see `ring11m.dart`
  /// in `protocol`. A declared-but-absent signal is worse than a missing one
  /// (see [BandAdapter.signals]), so nothing is claimed until a decoder exists
  /// and a real capture has met it.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = _Inbox();
    final archived = <Uint8List>[];
    // Bytes accumulated for the history block currently in flight, cleared on
    // every terminator — see the header note on why this file cannot tell
    // which history TYPE they belong to and does not try.
    final blockData = <int>[];

    void onNotification(int atSec, List<int> value) {
      final raw = Uint8List.fromList(value);
      archived.add(raw);
      final f = parseRing11mFrame(value);
      if (f == null) return;
      inbox.add(f);
    }

    final subs = [
      link.notify(kRing11mCommandChar).listen(
            (rec) => onNotification(rec.$1, rec.$2),
            onDone: inbox.close,
            onError: (Object _) => inbox.close(),
          ),
      link.notify(kRing11mHistoryChar).listen(
            (rec) => onNotification(rec.$1, rec.$2),
            onError: (Object _) {},
          ),
    ];

    try {
      // Negotiation: model, battery, capabilities, then the clock. Each is a
      // documented reply to check against, and a refused write just ends the
      // negotiation early — whatever already arrived is still archived below.
      if (!await link.write(kRing11mCommandChar, ring11mCmdModelQuery())) {
        link.log('ring11m: model query refused; ending the session.');
        yield* _flush(archived);
        return;
      }
      final modelReply = await inbox.firstWhere(
        (f) => parseRing11mModel(f) != null,
        replyTimeout,
      );
      if (modelReply != null) {
        link.log('ring11m: model ${parseRing11mModel(modelReply)}');
      }

      if (await link.write(kRing11mCommandChar, ring11mCmdBatteryQuery())) {
        final batteryReply = await inbox.firstWhere(
          (f) => parseRing11mBattery(f) != null,
          replyTimeout,
        );
        final pct = batteryReply == null ? null : parseRing11mBattery(batteryReply);
        if (pct != null) yield BandNote('battery', pct);
      }

      if (await link.write(kRing11mCommandChar, ring11mCmdCapabilityQuery())) {
        final capReply = await inbox.firstWhere(
          (f) => parseRing11mCapabilitiesRaw(f) != null,
          replyTimeout,
        );
        // Raw only — see `parseRing11mCapabilitiesRaw`'s own doc on why no
        // individual bit is decoded.
        if (capReply != null) {
          link.log('ring11m: capabilities ${_hex(capReply.payload)}');
        }
      }

      if (!await link.write(kRing11mCommandChar, ring11mCmdSetTime(now()))) {
        link.log('ring11m: clock write refused.');
      }

      // Whatever the ring sends from here — an unsolicited history block, a
      // realtime push, nothing at all — for the bounded window below.
      final deadline = DateTime.now().add(listenWindow);
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        final f = await inbox.next(remaining);
        if (f == null) break; // timed out, or the link closed
        if (f.group == kRing11mGroupHealthHistory) {
          if (f.command == kRing11mCmdHistoryTerminator) {
            final term = parseRing11mHistoryTerminator(f);
            if (term != null) {
              final ok = ring11mHistoryCrc(blockData) == term.crc16;
              yield BandNote(ok ? 'ring11m_block_ack' : 'ring11m_block_nack',
                  term.packetCount);
              await link.write(kRing11mCommandChar, buildRing11mHistoryAck(ok));
            }
            blockData.clear();
          } else {
            blockData.addAll(f.payload);
          }
        }
        // group 0x06 realtime pushes and anything else: archived above via
        // `onNotification`, not otherwise acted on.
      }
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
    yield* _flush(archived);
  }

  Stream<BandEvent> _flush(List<Uint8List> archived) async* {
    if (archived.isNotEmpty) {
      yield SampleBatch(const [], raw: List.of(archived));
    }
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The single instance. Const, so it costs nothing to reference.
const Ring11mAdapter kRing11mAdapter = Ring11mAdapter();

/// Frames off the notify characteristics, buffered so a reply landing before
/// anyone is waiting is not dropped. Hand-rolled for the same reason
/// `oura.dart`'s `_Inbox` is: the whole of what this session needs is "the
/// next frame, or nothing", once, for two characteristics feeding one queue.
class _Inbox {
  final List<Ring11mFrame> _buf = [];
  Completer<Ring11mFrame?>? _waiter;
  bool _closed = false;

  void add(Ring11mFrame f) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(f);
      return;
    }
    _buf.add(f);
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  Future<Ring11mFrame?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed || timeout <= Duration.zero) return Future.value(null);
    final w = Completer<Ring11mFrame?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  /// The next frame satisfying [test]. Every frame that does NOT match is
  /// pushed back onto the front of the buffer, in its original order, rather
  /// than dropped — a group-0x05 history block can genuinely arrive while a
  /// negotiation reply is still pending (this file never asked the ring not
  /// to), and a `firstWhere` that discarded it would silently break the
  /// block-ack accounting for something the ring sent unprompted.
  Future<Ring11mFrame?> firstWhere(
    bool Function(Ring11mFrame) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    final skipped = <Ring11mFrame>[];
    Ring11mFrame? match;
    while (deadline.elapsed < timeout) {
      final f = await next(timeout - deadline.elapsed);
      if (f == null) break;
      if (test(f)) {
        match = f;
        break;
      }
      skipped.add(f);
    }
    if (skipped.isNotEmpty) _buf.insertAll(0, skipped);
    return match;
  }
}
