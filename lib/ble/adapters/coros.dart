// A Coros sports watch (Pace/Apex/Vertix series) as a [BandAdapter]: a
// one-shot status pull (battery, model, serial, firmware) at connect, then
// the same generic 0x2A37 heart-rate parse [BleHrsAdapter] already has.
//
// SCOPE IS DELIBERATELY NARROW. Every standard SIG service on this watch
// answers a plain connect with no pairing or bonding enforced — battery,
// device information and heart rate are all documented, unencrypted GATT.
// Recorded activity, sleep and step history ride a completely undocumented
// proprietary channel with no public frame spec anywhere; decoding it would
// mean inventing a physiological data format from nothing, which is exactly
// what this project refuses to do. That channel is never touched here.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one, so ships
// EXPERIMENTAL (ASSUMPTIONS R6): `signals` covers only the generic HR parse,
// and `coros` stays absent from `kDerivableSources` like every other band —
// see `_registry.dart`'s `kCoros` doc on the one real unknown (the exact
// advertised service UUID) that still needs a real device to close.

import 'dart:convert';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class CorosAdapter extends BandAdapter {
  const CorosAdapter();

  @override
  BandEntry get entry => kCoros;

  /// The generic HR parse only. Nothing else on this watch is decoded —
  /// battery and device identity are [BandNote]s, not a physiological signal.
  @override
  Map<InputSignal, Duration> get signals => const {
        InputSignal.hrSparse: Duration(seconds: 1),
        InputSignal.rrIntervals: Duration(seconds: 1),
      };

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // One-shot, best-effort: a watch that answers battery and identity but
    // not heart rate (or the reverse) still gets whatever it does answer —
    // see `kCoros`'s own doc on why none of this is required to connect.
    final battery = await link.read(kBatteryLevelUuid);
    if (battery != null && battery.isNotEmpty) {
      yield BandNote('battery', battery[0]);
    }
    final model = await _readString(link, kModelNumberUuid);
    if (model != null) yield BandNote('model', model);
    final serial = await _readString(link, kSerialNumberUuid);
    if (serial != null) yield BandNote('serial', serial);
    final firmware = await _readString(link, kFirmwareRevisionUuid);
    if (firmware != null) yield BandNote('firmware', firmware);

    // No handshake for HR itself — same floor as `BleHrsAdapter`: one
    // subscription, no clock, no INIT.
    await for (final (atSec, value) in link.notify(kHeartRateMeasurementUuid)) {
      final s = parseHeartRateMeasurement(value);
      if (s == null) continue;
      // The sensor's own "no skin contact" is a REFUSAL, not a low reading —
      // see `ble_hrs.dart`'s identical guard.
      if (s.contact == false) continue;
      yield SampleBatch(
        [
          NeutralSample(
            // ARRIVAL TIME, NOT BEAT TIME — see `ble_hrs.dart`'s doc on why.
            anchor: TimeAnchor.arrival,
            tsEpoch: atSec,
            hr: s.hr,
            rrMs: s.rrMs,
            vendor: s.contact == null ? const {} : {'contact': s.contact},
          ),
        ],
        ephemeral: false,
      );
    }
    // No OffloadCheckpoint, ever. This watch's recorded history is never
    // requested — see the header note — so there is nothing to tell it to
    // forget.
  }

  /// A read-only Device Information string, or null for a missing
  /// characteristic, an empty reply or one that decodes to nothing.
  Future<String?> _readString(BandLink link, String uuid) async {
    final bytes = await link.read(uuid);
    if (bytes == null || bytes.isEmpty) return null;
    final s = utf8.decode(bytes, allowMalformed: true).trim();
    return s.isEmpty ? null : s;
  }
}

/// The single instance. Const, so it costs nothing to reference.
const CorosAdapter kCorosAdapter = CorosAdapter();
