// The Makibes HR3, an unbranded OEM board, as a [BandAdapter]: subscribe,
// archive every frame, decode nothing.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Nobody on this project owns
// one, so `signals` is `const {}` and `makibeshr3` is absent from
// `kDerivableSources` — this session holds a link and archives bytes, it
// never turns them into a step count, a sleep stage or a heart rate.
//
// NO WRITE, EVER. This board's functions are each requested by writing a
// command to its control characteristic and reading the reply back on the
// separate report characteristic. There is no captured reply here to check
// any of those command bytes against, so this file never writes one —
// [run] only ever listens.
//
// THE SERVICE IS THE STANDARD NORDIC UART SERVICE, and that is not a
// fingerprint — it is reused by large numbers of unrelated gadgets across
// many unaffiliated device families. Matching on it alone finds candidates,
// not certainty; the pairing UI surfaces a hit by its advertised name and
// lets the user confirm.

import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class MakibesHr3Adapter extends BandAdapter {
  const MakibesHr3Adapter();

  @override
  BandEntry get entry => kMakibesHr3;

  /// NOTHING. See the header note — no command is ever sent, and nothing
  /// this board might push unprompted has a decoder to turn it into a
  /// signal.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    await for (final (_, value) in link.notify(kMakibesHr3ReportChar)) {
      if (value.isEmpty) continue;
      // Every frame, verbatim — see the header note on why nothing here is
      // ever recognised or acted on.
      yield SampleBatch(const [], raw: [Uint8List.fromList(value)]);
    }
    // No OffloadCheckpoint: this file never asks the board for its stored
    // history, so there is nothing to tell it to forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const MakibesHr3Adapter kMakibesHr3Adapter = MakibesHr3Adapter();
