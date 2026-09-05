// The NO1-family control board — TLW64 smartwatch and F1 wristband — as a
// [BandAdapter]: subscribe, archive every frame, decode nothing.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Nobody on this project owns
// either device, so `signals` is `const {}` and `tlw64` is absent from
// `kDerivableSources` — this session holds a link and archives bytes, it
// never turns them into a step count, a sleep stage or a heart rate.
//
// NO WRITE, EVER. Every function this family has — battery, firmware, steps,
// sleep, and on the F1 heart rate — is fetched by writing a one-byte command
// and waiting for the matching reply, which means the reply's own layout is
// this file's only source of truth for what to send next. There is no
// captured reply to check that against, so this file does not send the
// command either: [run] only ever listens. If the band pushes anything on
// its own (a button press, a step milestone), that arrives and is archived
// the same as everything else would be.
//
// TWO PRODUCT NAMES, ONE PROTOCOL. The TLW64 and the F1 answer the identical
// service with the identical command bytes for every function they share —
// see [kNo1Service]'s own doc — so one entry and one adapter cover both
// rather than duplicating this file for a difference that is not there.

import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class Tlw64Adapter extends BandAdapter {
  const Tlw64Adapter();

  @override
  BandEntry get entry => kNo1Band;

  /// NOTHING. See the header note — no command is ever sent, and nothing
  /// this family might push unprompted has a decoder to turn it into a
  /// signal.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    await for (final (_, value) in link.notify(kNo1NotifyChar)) {
      if (value.isEmpty) continue;
      // Every frame, verbatim — see the header note on why nothing here is
      // ever recognised or acted on.
      yield SampleBatch(const [], raw: [Uint8List.fromList(value)]);
    }
    // No OffloadCheckpoint: this file never asks the band for its stored
    // history, so there is nothing to tell it to forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const Tlw64Adapter kNo1BandAdapter = Tlw64Adapter();
