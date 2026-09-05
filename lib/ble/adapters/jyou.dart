// A Jyou/Y5-class band as a [BandAdapter]: subscribe, archive every frame,
// surface only battery and firmware as [BandNote]s. Nothing else.
//
// NO AUTH, NO HANDSHAKE. Every write is a fixed 10-byte command (one opcode
// byte, two big-endian int32 argument slots, one additive checksum byte) and
// every notification is a variable-length frame tagged by its first byte —
// there is no session state on the wire at all, which is why [run] never
// writes anything and just listens.
//
// EVERY DECODED FIELD IS AN ON-DEVICE ESTIMATE WITH NO PPG/ACCEL GROUND TRUTH
// BEHIND IT, and nobody on this project owns one (ASSUMPTIONS R6). Heart
// rate, steps, blood pressure and SpO2 are all readable at fixed offsets —
// and all deliberately left undecoded into a [NeutralSample]: a
// declared-but-absent signal is worse than a missing one (see
// [BandAdapter.signals]), so nothing is claimed here until a decoder exists
// and a real capture has met it. Battery and firmware are device housekeeping,
// not physiology, which is why they cross as notes the same way Oura's
// `battery`/`battery_mv` do.

import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// Notify-frame tags this adapter recognises. Everything else still lands in
/// `raw` — an unrecognised tag is not an error, just nothing to name here.
const int _kTagDeviceInfo = 0xF6;
const int _kTagBattery = 0xF7;

/// The adapter. Const, and it holds no session state.
class JyouAdapter extends BandAdapter {
  const JyouAdapter();

  @override
  BandEntry get entry => kJyou;

  /// Empty on purpose (the hard invariant). HR, steps, blood pressure and
  /// SpO2 are all readable off the wire and none of them is claimed — see
  /// this file's own header.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // No clock-sync write, no command channel touched at all: the device
    // streams device info, battery, steps and HR on its own the moment
    // something is subscribed, and the housekeeping write is not worth the
    // extra diff for a band nobody has met.
    await for (final (_, value) in link.notify(kJyouMeasureChar)) {
      final bytes = Uint8List.fromList(value);
      if (bytes.isEmpty) continue;
      switch (bytes[0]) {
        case _kTagBattery:
          if (bytes.length > 8) yield BandNote('battery', bytes[8]);
        case _kTagDeviceInfo:
          if (bytes.length > 7) {
            final ver = bytes[4];
            yield BandNote(
              'firmware',
              '${ver ~/ 100}.${(ver % 100) ~/ 10}.${ver % 100 % 10}',
            );
          }
      }
      // EVERY frame is archived, known tag or not — including the two just
      // read above, and every HR/steps/BP/SpO2 frame this band ever sends.
      // The bytes are banked now so a decoder written when someone owns one
      // can run over them, instead of a guess running over them today.
      yield SampleBatch(const [], raw: [bytes], ephemeral: false);
    }
    // No OffloadCheckpoint: nothing here trims a flash on our ACK, the device
    // just streams live.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const JyouAdapter kJyouAdapter = JyouAdapter();
