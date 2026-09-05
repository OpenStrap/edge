// A Howear-branded band (HK8 Ultra, HK8 Pro Max and the like) as a
// [BandAdapter]: connect, ask for its own battery report, bank every frame it
// sends, and decode nothing else.
//
// THE HOSTILE CASE, LIKE `ble_hrs`. No CRC, no encryption, no clock this
// build reads back — the whole session is one write and whatever notifies
// back. Unlike a heart-rate strap the band does not stream on its own, so
// the one write is what gives a session something to bank at all.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one (ASSUMPTIONS
// R6), so this ships EXPERIMENTAL: `signals` is `const {}` and this id is
// absent from `kDerivableSources`. The battery reply is decoded because it is
// device housekeeping, not a physiological reading — the same distinction
// `oura_link.dart` draws for its own battery notes. Everything else this
// family can say (steps, heart rate, sleep, notifications) is left
// undecoded and archived verbatim: no captured bytes back any of those
// layouts yet, and a guessed one is worse than none.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

class WearFitAdapter extends BandAdapter {
  const WearFitAdapter();

  @override
  BandEntry get entry => kWearFit;

  /// Nothing. See the header — battery is reported through [BandNote], never
  /// through a declared signal.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // No handshake to gate this on: unlike Oura's key install, a battery
    // request needs nothing from the band first. A refusal is logged, not
    // fatal — the session still listens for whatever the band sends on its
    // own.
    if (!await link.write(kWearFitWriteChar, wearFitCmdGetBattery())) {
      link.log('wearfit: battery request refused.');
    }
    await for (final (_, value) in link.notify(kWearFitNotifyChar)) {
      final f = parseWearFitFrame(value);
      if (f == null) continue;
      final battery = parseWearFitBattery(f);
      if (battery != null) {
        yield BandNote('battery', battery.percent);
        yield BandNote('battery_charging', battery.chargeState != 0);
      }
      // Every frame is archived verbatim (owner rulings R1-R3: capture
      // everything, decode when someone has the hardware) — including the
      // battery reply just decoded above, so a future decoder for this
      // family's other opcodes can be run over what today's session could
      // not read.
      yield SampleBatch(
        const [],
        raw: [Uint8List.fromList(value)],
        ephemeral: false,
      );
    }
  }
}

const WearFitAdapter kWearFitAdapter = WearFitAdapter();
