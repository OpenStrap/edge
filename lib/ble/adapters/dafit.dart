// A DaFit/MOYOUNG-V2 clone watch as a [BandAdapter]: run the documented
// handshake, ack what the band needs acked to keep answering, bank every
// frame verbatim, and decode nothing.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one of these
// boards, so it ships EXPERIMENTAL (ASSUMPTIONS R6): `signals` is `const {}`
// and `dafit` is absent from `kDerivableSources` — this session holds a link
// and archives bytes, it never turns them into a heart rate, a step count or
// a sleep stage.
//
// WHY THE HANDSHAKE RUNS AT ALL, given the above. It is control plane, not
// data: setting the clock and asking for the two init acks is what a
// connection on this family is documented to need before the band settles
// down, and skipping it is documented to leave the band's battery draining
// fast whether or not anything is ever fetched. None of it is a request for
// a physiological reading — this file requests none and decodes none.
//
// THIS IS FETCH-BY-NOTHING, not fetch-by-cursor and not trim-on-ack. The
// session never asks this family for its stored activity history — there is
// no decoder for any of it — so there is nothing here that could tell the
// band to forget anything. [OffloadCheckpoint] is never emitted; the host
// flushes archived frames on its own cadence, same as a live-only sensor.
//
// ACKING IS SELECTIVE, NOT BLANKET, AND CONCURRENT WITH SENDING, NOT GATING
// IT. Two group/command replies — hardware info and band info — are the
// ones the init sequence asks for and the two a connection on this family is
// documented to need acked before it settles down; every other notification
// (a button press, an ambient reading, a bare ack echoed back) is archived
// and left alone. The single notify listener below acks a matching reply
// whenever it arrives, independently of which handshake step is currently
// being written — so a reply that lands early or late is still acked, and a
// reply that never arrives never stalls the handshake, which only paces
// itself against the clock, not against the band's replies.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// True for the two replies the documented init sequence expects an ack on.
bool _isAckable(DafitFrame f) =>
    (f.group == kDafitGroupRequestData && f.command == kDafitCmdGetHwInfo) ||
    (f.group == kDafitGroupBandInfo && f.command == kDafitCmdGetBandInfo);

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run], never on the instance (an adapter is const and
/// a session is not).
class DafitAdapter extends BandAdapter {
  /// Wall-clock now, injected so a fixture replay is deterministic —
  /// `DateTime.now()` does not appear anywhere else in this file.
  final DateTime Function() now;

  /// Pacing gap between handshake writes — the documented spacing this
  /// family's connection sequence uses, and overridable so a fixture replay
  /// does not have to sit through eight real 200 ms waits.
  final Duration handshakePause;

  const DafitAdapter({
    this.now = DateTime.now,
    this.handshakePause = const Duration(milliseconds: 200),
  });

  @override
  BandEntry get entry => kDafit;

  /// NOTHING. See the header note — no decoder exists for this family's
  /// activity data and none is requested, so no signal is ever emitted.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final archived = <Uint8List>[];
    // Fires once per notification the band sends, so the generator below has
    // something to `await for` on — a plain `StreamController<void>` rather
    // than re-deriving one from `archived`'s own length, which would race
    // against the clear() below.
    final flush = StreamController<void>();
    final sub = link.notify(kDafitNotifyChar).listen(
      (rec) async {
        final raw = Uint8List.fromList(rec.$2);
        // Frame or not, archive the bytes verbatim: this file's decode
        // coverage is deliberately zero, so nothing distinguishes "worth
        // keeping" from "not yet understood" — see the header note.
        archived.add(raw);
        final f = parseDafitFrame(raw);
        if (f != null && _isAckable(f)) {
          await link.write(kDafitWriteChar, buildDafitAck(f));
        }
        if (!flush.isClosed) flush.add(null);
      },
      onDone: () {
        if (!flush.isClosed) flush.close();
      },
      onError: (Object _) {
        if (!flush.isClosed) flush.close();
      },
    );
    try {
      for (final frame in dafitInitSequence(now())) {
        if (!await link.write(kDafitWriteChar, frame)) {
          link.log('dafit: handshake write refused; ending the session.');
          return;
        }
        // The band is documented to need time to act on each step; this is
        // the session-layer half of that.
        if (handshakePause > Duration.zero) {
          await Future<void>.delayed(handshakePause);
        }
      }
      // Bank whatever accumulated (handshake replies included) as it flushes,
      // for as long as the link holds. Frames that arrived before this loop
      // attached are not lost — a single-subscription `StreamController`
      // buffers events added before its first listener, so every `flush`
      // fired during the handshake above is still queued and delivered here.
      await for (final _ in flush.stream) {
        if (archived.isNotEmpty) {
          yield SampleBatch(const [], raw: List.of(archived));
          archived.clear();
        }
      }
    } finally {
      await sub.cancel();
      // NOT awaited: a single-subscription `StreamController`'s `close()`
      // future only completes once a listener has drained it, and on the
      // early-return path above (a refused handshake write) nothing has
      // listened to `flush` yet — awaiting it here would hang the whole
      // teardown forever instead of just letting the controller finish
      // closing on its own.
      if (!flush.isClosed) flush.close();
    }
    // No OffloadCheckpoint, ever — see the header note. This family's
    // activity history is never requested, so there is nothing to tell it
    // to forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const DafitAdapter kDafitAdapter = DafitAdapter();
