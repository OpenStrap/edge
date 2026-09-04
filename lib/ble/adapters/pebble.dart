// The Pebble 2 / Pebble 2 SE smartwatch as a [BandAdapter]: connect, and bank
// raw bytes off PPoGATT ("Pebble Protocol over GATT"), the reliable
// byte-transport underneath everything the watch says.
//
// SCOPE IS PPoGATT ONLY, DELIBERATELY. There is no inner Pebble-Protocol frame
// (2-byte length + 2-byte endpoint ID) reassembled here — every de-serialed
// chunk is banked verbatim to `raw_archive`, exactly how `oura.dart` banks
// undecoded event bytes today. Without answering the watch's own handshake at
// that inner layer (endpoint 17, PHONE_VERSION), the watch never settles into
// an app-visible "connected" state and keeps sending the reset/renegotiation
// command below — which this file answers correctly, so the transport stays
// alive, but nothing past it is decoded. That is a known ceiling, not a bug:
// `signals` is empty, so nothing downstream is waiting on a live session.
//
// NOT WIRED TO ANY HOST YET, and that is a gap, not a ceiling. Registering
// [kPebble] in `kBandRegistry` makes PAIRING generic —
// `HrsLink.pairNotifySensor` validates the characteristics and writes the
// `device` row, same as a chest strap — but nothing calls [PebbleAdapter.run]
// afterward: there is no `pebble_link.dart` running a periodic connect the
// way `oura_link.dart`'s `sync()` does for the ring, and `HrsLink.arm()` is
// hardcoded to `kBleHrsAdapter` and workout-scoped, so it never looks at this
// entry either. A paired Pebble today writes its `device` row and then does
// nothing, forever — this file is exercised by `pebble_adapter_test.dart` and
// the compiler, never by a live session. Wiring one (a periodic drain, not
// workout-armed — a watch on the wrist is not a chest strap) is follow-up
// work, not done here.
//
// ONLY PEBBLE 2 / PEBBLE 2 SE. Every older model runs Bluetooth Classic SPP as
// its primary channel, and even its BLE path requires the phone to also stand
// up a local GATT SERVER — a second, peripheral-role identity this host does
// not have. Pebble 2 / Pebble 2 SE are BLE-only and pure client: connect,
// discover, subscribe, write. Nothing else is reachable from this stack.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Pebble.
// Everything below is the documented GATT layout and the fixed control bytes
// the transport requires, verified by the fixtures in
// `test/adapters/pebble_adapter_test.dart` and the compiler. It ships
// EXPERIMENTAL (ASSUMPTIONS R6): `signals` is empty and `kAdapterSignals`
// carries nothing for `'pebble'`, so no card can go looking for a number this
// adapter never claims.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The lower 3 bits of a PPoGATT header byte.
const int _kPpogattCmdData = 0;
const int _kPpogattCmdAck = 1;
const int _kPpogattCmdReset = 2;

class PebbleAdapter extends BandAdapter {
  const PebbleAdapter();

  @override
  BandEntry get entry => kPebble;

  /// NOTHING. See the header — PPoGATT is banked, not decoded, so no card may
  /// go looking for a number this adapter never produces.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    await for (final (_, value) in link.notify(kPebblePpogattReadUuid)) {
      if (value.isEmpty) continue;
      final header = value[0];
      final serial = header >> 3;
      final command = header & 0x7;
      switch (command) {
        case _kPpogattCmdData:
          // ACK the serial we just received, THEN bank the payload — the
          // watch re-sends an un-ACKed packet, so a decode failure below must
          // never swallow the ACK.
          await link.write(kPebblePpogattWriteUuid, <int>[(serial << 3) | 1]);
          yield SampleBatch(
            const [],
            raw: [Uint8List.fromList(value.sublist(1))],
          );
        case _kPpogattCmdAck:
          // An ACK for a serial WE sent. This adapter never sends a data
          // packet of its own, so this is only ever the watch echoing
          // something unexpected — worth a log line, nothing to bank.
          link.log('pebble: ack for serial $serial');
        case _kPpogattCmdReset:
          // A reset/renegotiation request. The three-byte reply is a fixed
          // control response the transport requires to stay alive — not a
          // decoded fact about the watch — sent only when the request itself
          // carried a body past the header.
          await link.write(
            kPebblePpogattWriteUuid,
            value.length > 1 ? const <int>[0x03, 0x19, 0x19] : const <int>[0x03],
          );
          link.log('pebble: reset/renegotiation request (serial $serial)');
        default:
          link.log('pebble: unrecognised PPoGATT command $command, dropped');
      }
    }
    // The watch stores nothing on our say-so at this layer, so there is
    // nothing to tell it to forget — no OffloadCheckpoint, ever.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const PebbleAdapter kPebbleAdapter = PebbleAdapter();
