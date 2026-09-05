// Bangle.js as a [BandAdapter] — pair, connect, bank raw bytes. Nothing else.
//
// Bangle.js has no byte-level record protocol of its own. It exposes Nordic's
// UART Service, a generic serial-over-BLE pipe, behind which runs a full
// Espruino JavaScript REPL: the phone writes JS source text, the watch
// executes it and prints text back. Activity/HR/notification data only
// exists as JSON lines an OPTIONAL, user-installed, third-party JS app can be
// made to emit — that app's message schema is not a firmware-level fact, it
// is a moving target owned by a different, independently-versioned project a
// given watch may or may not be running. So this adapter never parses a line,
// never assumes one was even printed, and never writes to the RX
// characteristic: there is nothing to hand it that would not itself be
// evaluated as executable code.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). It ships EXPERIMENTAL: no
// signal, no decode, every chunk lands in `raw_archive` verbatim and stays
// there until someone owning real hardware writes and verifies a decoder
// against a real capture.

import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state.
class BangleJsAdapter extends BandAdapter {
  const BangleJsAdapter();

  @override
  BandEntry get entry => kBangleJs;

  /// Empty on purpose. No card may ever key off this adapter's id.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // No handshake, no write, no line reassembly. Every notification chunk is
    // re-emitted verbatim as raw bytes — decoding a text REPL's output as if
    // it were a stable record format would be exactly the guess this project
    // never takes.
    await for (final (_, value) in link.notify(kNordicUartTxChar)) {
      yield SampleBatch(
        const [],
        raw: [Uint8List.fromList(value)],
        ephemeral: false,
      );
    }
    // No OffloadCheckpoint: nothing here is ever told to forget anything.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const BangleJsAdapter kBangleJsAdapter = BangleJsAdapter();
