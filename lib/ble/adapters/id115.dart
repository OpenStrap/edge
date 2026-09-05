// The ID115, an unbranded OEM board, as a [BandAdapter]: subscribe to both
// of its channels, archive every frame, decode nothing.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Nobody on this project owns
// one, so `signals` is `const {}` and `id115` is absent from
// `kDerivableSources` — this session holds a link and archives bytes, it
// never turns them into a step count, a sleep stage or a heart rate.
//
// TWO INDEPENDENT CHANNELS. The general channel (settings, notifications,
// device info) and the health-data channel (today's activity fetch) are a
// separate write/notify characteristic pair each — there is no shared
// envelope between them, so this file listens to both and merges whatever
// arrives into one archive stream.
//
// NO WRITE, EVER. Every function on this board — device info, settings,
// today's steps — is requested by writing a command and reading the reply
// back on the matching channel. There is no captured reply here to check
// any of those command bytes against, so this file never writes one —
// [run] only ever listens.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class Id115Adapter extends BandAdapter {
  const Id115Adapter();

  @override
  BandEntry get entry => kId115;

  /// NOTHING. See the header note — no command is ever sent, and nothing
  /// this board might push unprompted has a decoder to turn it into a
  /// signal.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // Merged into one controller rather than two parallel `await for`s: a
    // single `yield` loop below is simpler than interleaving two, and
    // ordering between the channels is not meaningful here — nothing this
    // file does depends on which channel a given frame arrived on.
    final frames = StreamController<Uint8List>();
    // Either subscription closing (its channel ending, or an error) closes
    // the shared controller — so the OTHER channel can still have a frame
    // in flight afterwards. Guarded, not just `.add()`: an unguarded add on
    // an already-closed controller throws `StateError` synchronously inside
    // this data callback, with no `onError` above it to catch it.
    void addFrame(Uint8List b) {
      if (!frames.isClosed) frames.add(b);
    }

    final normalSub = link.notify(kId115NotifyNormalChar).listen(
          (rec) => addFrame(Uint8List.fromList(rec.$2)),
          onDone: frames.close,
          onError: (Object _) => frames.close(),
        );
    final healthSub = link.notify(kId115NotifyHealthChar).listen(
          (rec) => addFrame(Uint8List.fromList(rec.$2)),
          onDone: frames.close,
          onError: (Object _) => frames.close(),
        );
    try {
      await for (final bytes in frames.stream) {
        if (bytes.isEmpty) continue;
        // Every frame, verbatim, from either channel — see the header note
        // on why nothing here is ever recognised or acted on.
        yield SampleBatch(const [], raw: [bytes]);
      }
    } finally {
      await normalSub.cancel();
      await healthSub.cancel();
      await frames.close();
    }
    // No OffloadCheckpoint: this file never asks the board for its stored
    // history, so there is nothing to tell it to forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const Id115Adapter kId115Adapter = Id115Adapter();
