// The Wellue O2Ring as a [BandAdapter]: connect, ask for device info, bank
// every byte, decode nothing physiological.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one (ASSUMPTIONS
// R6), so it ships EXPERIMENTAL, `signals` stays `const {}`, and
// `kDerivableSources` does not contain it — exactly the same posture as
// `oura.dart`, for the same reason.
//
// WHY THIS IS SO MUCH SHORTER THAN `oura.dart`. There is no key, no nonce, no
// challenge-response — `protocol`'s own header explains why the file
// commands that would drain a stored recording are not implemented at all, so
// what is left is one request/reply round trip with no session state to carry
// between calls. INFO's reply is JSON, so parsing it is not a guess about a
// bit-packed layout the way Oura's undecoded events are — but the numbers it
// carries are device metadata (battery, model, serial, file names), never a
// physiological reading, so none of it is a [NeutralSample] and none of it is
// declared in [signals].
//
// EVERY NOTIFICATION IS ARCHIVED VERBATIM regardless of whether this file
// could parse it, same as Oura's undecoded events (owner rulings R1-R3): a
// byte this session could not make sense of today is not a byte to discard.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// One O2Ring session: write INFO, collect whatever answers within
/// [replyTimeout], archive it all, surface metadata as [BandNote]s, done.
class O2RingAdapter extends BandAdapter {
  /// How long to wait for a reply before ending the session. The ring is not
  /// a store to drain — one request, one window, then disconnect.
  final Duration replyTimeout;

  const O2RingAdapter({this.replyTimeout = const Duration(seconds: 5)});

  @override
  BandEntry get entry => kO2Ring;

  /// NOTHING. This ring reports SpO2, pulse and perfusion index, and this
  /// adapter decodes none of them into a sample — see this file's own header.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // ACCUMULATE, DON'T ASSUME ONE NOTIFICATION IS ONE FRAME. A reply can
    // arrive split across several BLE notifications — documented behaviour
    // for this ring family — so every fragment is appended to one growing
    // buffer, and [parseO2RingFrame] doubles as the completeness check: it
    // returns null until the buffer holds a full, CRC-valid frame, which is
    // exactly "keep waiting for more" without a second length calculation
    // duplicating the one the parser already does.
    final buf = <int>[];
    O2RingFrame? frame;
    final done = Completer<void>();
    final sub = link.notify(kO2RingNotifyChar).listen(
          (rec) {
            buf.addAll(rec.$2);
            frame ??= parseO2RingFrame(buf);
            if (frame != null && !done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
        );
    try {
      if (!await link.write(kO2RingWriteChar, o2ringCmdInfo())) {
        link.log('o2ring: the ring would not accept the INFO command.');
        return;
      }
      await done.future.timeout(replyTimeout, onTimeout: () {});
      if (buf.isEmpty) {
        link.log('o2ring: no reply to INFO within ${replyTimeout.inSeconds}s.');
        return;
      }
      // Metadata only, and only from a frame that actually parsed — never a
      // sample. The bytes are archived below regardless of whether they did.
      final f = frame ?? parseO2RingFrame(buf);
      if (f != null && f.cmd == kO2RingCmdInfo) {
        final info = parseO2RingInfo(f.data);
        if (info != null) {
          if (info.batteryPct != null) yield BandNote('battery', info.batteryPct);
          if (info.model != null) yield BandNote('model', info.model);
          if (info.serial != null) yield BandNote('serial', info.serial);
          if (info.files.isNotEmpty) yield BandNote('o2ring_files', info.files.join(','));
        }
      }
      yield SampleBatch(const [], raw: [Uint8List.fromList(buf)]);
    } finally {
      await sub.cancel();
    }
    // No OffloadCheckpoint: this build asks for nothing the ring would need
    // to be told it may forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const O2RingAdapter kO2RingAdapter = O2RingAdapter();
