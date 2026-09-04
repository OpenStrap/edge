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
// ACKING IS SELECTIVE, NOT BLANKET. Two group/command replies — hardware
// info and band info — are the ones the documented init sequence asks for
// and the ones the reference behaviour acks before moving on; every other
// notification (a button press, an ambient reading, a bare ack echoed back)
// is archived and left alone. Acking a frame this file has no reason to
// expect would be guessing at a control-flow effect nobody has observed.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class DafitAdapter extends BandAdapter {
  /// Wall-clock now, in Unix seconds. Injected so a fixture replay is
  /// deterministic — `DateTime.now()` does not appear in this file.
  final DateTime Function() now;

  /// How long to wait for a hardware-info / band-info reply before giving up
  /// on acking it and moving on. The handshake still completes either way —
  /// see the header note on why acking is best-effort, not load-bearing.
  final Duration replyTimeout;

  const DafitAdapter({
    this.now = DateTime.now,
    this.replyTimeout = const Duration(seconds: 5),
  });

  @override
  BandEntry get entry => kDafit;

  /// NOTHING. See the header note — no decoder exists for this family's
  /// activity data and none is requested, so no signal is ever emitted.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final inbox = StreamController<DafitFrame>();
    final sub = link.notify(kDafitNotifyChar).listen(
      (rec) {
        final raw = rec.$2;
        // Frame or not, archive the bytes verbatim: this file's decode
        // coverage is deliberately zero, so nothing distinguishes "worth
        // keeping" from "not yet understood" — see the header note.
        _archived.add(Uint8List.fromList(raw));
        final f = parseDafitFrame(raw);
        if (f != null) inbox.add(f);
      },
      onDone: inbox.close,
      onError: (Object _) => inbox.close(),
    );
    try {
      for (final frame in dafitInitSequence(now())) {
        if (!await link.write(kDafitWriteChar, frame)) {
          link.log('dafit: handshake write refused; ending the session.');
          return;
        }
        // The band is documented to need time to act on each step; a
        // fixed pacing gap is the session-layer half of that, matching the
        // spacing the reference handshake itself uses.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final reply = await _nextMatching(
          inbox.stream,
          (f) =>
              (f.group == kDafitGroupRequestData &&
                  f.command == kDafitCmdGetHwInfo) ||
              (f.group == kDafitGroupBandInfo &&
                  f.command == kDafitCmdGetBandInfo),
          replyTimeout,
        );
        if (reply != null && await link.write(kDafitWriteChar, buildDafitAck(reply))) {
          // Acked. Nothing else to do with the reply's payload — see the
          // header note on why this file does not decode it.
        }
      }
      // Bank whatever accumulated during the handshake, then keep archiving
      // anything the band sends afterwards for as long as the link holds.
      if (_archived.isNotEmpty) {
        yield SampleBatch(const [], raw: List.of(_archived), ephemeral: false);
        _archived.clear();
      }
      await for (final _ in inbox.stream) {
        if (_archived.isNotEmpty) {
          yield SampleBatch(const [], raw: List.of(_archived), ephemeral: false);
          _archived.clear();
        }
      }
    } finally {
      await sub.cancel();
      await inbox.close();
    }
    // No OffloadCheckpoint, ever — see the header note. This family's
    // activity history is never requested, so there is nothing to tell it
    // to forget.
  }

  final List<Uint8List> _archived = [];

  /// The next frame satisfying [test], or null on timeout. Frames not
  /// matching are left in the archive (already banked in [_archived] by the
  /// listener above) rather than discarded.
  Future<DafitFrame?> _nextMatching(
    Stream<DafitFrame> stream,
    bool Function(DafitFrame) test,
    Duration timeout,
  ) async {
    final completer = Completer<DafitFrame?>();
    late final StreamSubscription<DafitFrame> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    sub = stream.listen((f) {
      if (test(f) && !completer.isCompleted) {
        completer.complete(f);
      }
    }, onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }
}

/// The single instance. Const, so it costs nothing to reference.
const DafitAdapter kDafitAdapter = DafitAdapter();
