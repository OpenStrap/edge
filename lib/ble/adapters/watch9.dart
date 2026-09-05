// The Watch9, an unbranded OEM board, as a [BandAdapter]: subscribe, archive
// every frame, decode nothing.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). Nobody on this project owns
// one, so `signals` is `const {}` and `watch9` is absent from
// `kDerivableSources` — this session holds a link and archives bytes, it
// never turns them into a step count, a sleep stage or a heart rate.
//
// NO WRITE, EVER. Every function on this board — firmware version, battery,
// alarms, notifications, a fitness goal — is requested by writing a framed
// command (a five-byte header, a sequence number, a one-byte checksum) and
// reading the matching reply off the SAME characteristic it was written to.
// This file has no captured reply to check the checksum algorithm against,
// so it never builds one — [run] only ever listens.
//
// ONE CHARACTERISTIC, BOTH DIRECTIONS. This board's own GATT table declares
// four characteristics under its service, but only one of them is ever
// written to or read from by any known client — the other three are dead
// weight this file does not touch either.

import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class Watch9Adapter extends BandAdapter {
  const Watch9Adapter();

  @override
  BandEntry get entry => kWatch9;

  /// NOTHING. See the header note — no command is ever sent, and nothing
  /// this board might push unprompted has a decoder to turn it into a
  /// signal.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    await for (final (_, value) in link.notify(kWatch9Char)) {
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
const Watch9Adapter kWatch9Adapter = Watch9Adapter();
