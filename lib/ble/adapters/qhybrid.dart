// The Fossil/Skagen Q Hybrid — the original "hybrid" smartwatch line
// (`HW.0.0`, `HL.0.0`, `DN.1.0`) — as a [BandAdapter].
//
// Plain unencrypted GATT: one control/command characteristic that answers
// flat `[type, cmdId, ...payload]` requests with `[3, cmdId, ...payload]`
// responses (no CRC, no length envelope, no sequence counter), plus five
// notify-only characteristics — two for file-download chunking, one more in
// that same group, one for button presses, one for a file-upload ack — whose
// sub-protocols are not decoded here. There is no encryption anywhere in this
// variant and no pairing key; standard platform BLE bonding is the whole of
// what "pairing" means, same as [kBleHrs].
//
// THE ONE REAL RISK: an encrypted sibling protocol (the Hybrid HR / Gen 6
// line) advertises this exact same service UUID, so a live scan match on it
// cannot tell the two apart before connecting. Rather than guess, this
// adapter treats a harmless battery-level query as a self-confirming probe —
// write `[1, 8]` to the control characteristic and wait for `[3, 8, level]`
// back. A reply means this is the plain protocol; no reply within the window
// means abstain cleanly, exactly the "no reply = abstain" idiom `oura.dart`
// already uses for its own handshake. Nothing is banked until the probe
// confirms.
//
// NOTHING HERE HAS MET HARDWARE, so every notification is banked as raw
// bytes and nothing is decoded into a sample. EXPERIMENTAL (ASSUMPTIONS R6)
// until someone owns one: `signals` is empty and `kDerivableSources` does
// not contain `qhybrid`, so nothing this adapter banks can become a metric.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class QHybridAdapter extends BandAdapter {
  /// How long to wait for the battery-probe reply before abstaining.
  /// Overridable only so a test does not have to sit through it — same
  /// reason `oura.dart`'s `replyTimeout` is a constructor parameter.
  final Duration probeTimeout;

  const QHybridAdapter({this.probeTimeout = const Duration(seconds: 5)});

  @override
  BandEntry get entry => kQHybrid;

  /// NOTHING. See the header: every frame is banked raw, undecoded.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // The probe reply is recognised and swallowed here, never banked as data
    // — it is a confirmation this adapter generated, not something the watch
    // would have sent unprompted.
    final probeReply = Completer<bool>();
    final raw = StreamController<BandEvent>();
    final subs = <StreamSubscription<Object?>>[];

    // Set the INSTANT a valid reply arrives, never inferred from
    // `probeReply.isCompleted` — that completer settles once `run` has moved
    // on to await it, which is a later moment than the reply landing. Every
    // notification received before this is true is DROPPED, not merely
    // withheld: a `raw` fed before anyone is confirmed to listen only drains
    // once something subscribes, and on the abstain path nothing ever does
    // (see the header on `raw.close()` below) — so banking pre-confirmation
    // frames either leaks bytes that predate knowing this is even the right
    // protocol, or, on a successful probe, contradicts "nothing is banked
    // until the probe confirms" by surfacing them anyway once it does.
    var confirmed = false;

    for (final uuid in entry.requiredCharacteristics) {
      subs.add(link.notify(uuid).listen((rec) {
        final (_, value) = rec;
        if (uuid == kQHybridControlChar &&
            !probeReply.isCompleted &&
            value.length >= 3 &&
            value[0] == 3 &&
            value[1] == 8) {
          confirmed = true;
          probeReply.complete(true);
          return;
        }
        if (!confirmed) return;
        raw.add(SampleBatch(const [], raw: [Uint8List.fromList(value)]));
      }));
    }

    try {
      if (!await link.write(kQHybridControlChar, const [1, 8])) {
        link.log('qhybrid: battery probe write refused; ending the stream.');
        return;
      }
      final confirmed = await probeReply.future
          .timeout(probeTimeout, onTimeout: () => false);
      if (!confirmed) {
        link.log('qhybrid: no probe reply within ${probeTimeout.inSeconds}s; '
            'abstaining (likely the encrypted sibling protocol).');
        return;
      }
      // The only way a caller of `BandHost.run` (a `Future<void>`, success or
      // abstain alike) learns the probe actually confirmed — same `BandNote`
      // channel `oura.dart` uses for its own handshake facts.
      yield const BandNote('qhybrid_confirmed');
      yield* raw.stream;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      // NOT awaited. `raw.close()`'s returned future only completes once
      // every buffered event has been delivered to a listener — and on the
      // abstain path (probe refused or never confirmed) nothing has EVER
      // listened to `raw`, so awaiting it here hangs this whole method
      // forever the moment any characteristic notifies before the probe
      // settles. Nothing downstream needs to know `raw` finished draining;
      // the subscriptions above are already cancelled, which is the real
      // teardown.
      raw.close();
    }
  }
}

/// The single instance. Const, so it costs nothing to reference.
const QHybridAdapter kQHybridAdapter = QHybridAdapter();
