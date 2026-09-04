// A Lefun-protocol OEM ring/band as a [BandAdapter]: no auth, one bounded
// battery poll, bank every frame the radio hands back.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The envelope and the
// battery report are the only things `protocol`'s `lefun.dart` decodes with
// any confidence — steps, sleep and PPG all ride the same envelope under
// their own report codes and have no decoder there, so `signals` is
// `const {}` and every frame is archived verbatim rather than turned into a
// value.
//
// A BOUNDED POLL, NOT A LIVE SESSION. Unlike a chest strap this device has no
// per-second stream to hold a link open for — the one thing worth asking for
// is battery, and everything else worth banking is whatever the ring pushes
// on its own in the few seconds after that ask. So `run()` writes one
// request, waits out [replyTimeout], and ends — the host tears the link down
// once the stream closes, the same way `oura.dart`'s one-shot drain does.
//
// ponytail: no GET_ACTIVITY_DATA / GET_SLEEP_DATA / GET_PPG_DATA request
// builders here, even though their request bodies (a single day-index or
// PPG-type byte) are simple. Their RESPONSE layouts are not decoded by this
// file, so requesting them would only bank more undecoded bytes for a
// question nobody has asked yet — add them when someone verifies a response
// shape against real hardware.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Not const: [replyTimeout] is overridable so a test does not
/// have to sit through the real wait.
class LefunAdapter extends BandAdapter {
  /// How long to hold the link open after the battery request, banking
  /// whatever arrives on the notify characteristic in that window.
  final Duration replyTimeout;

  LefunAdapter({this.replyTimeout = const Duration(seconds: 5)});

  @override
  BandEntry get entry => kLefun;

  /// NOTHING. See the module doc for why battery — the one report this file
  /// decodes — is not a signal either: it is device state, not a
  /// physiological reading, and it reaches the host as a [BandNote].
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final raw = <Uint8List>[];
    int? batteryPct;
    final sub = link.notify(kLefunNotifyChar).listen((rec) {
      final f = parseLefunFrame(rec.$2);
      if (f == null) return;
      // Every frame archived verbatim, decoded or not (owner rulings R1-R3):
      // steps, sleep and PPG all ride this same envelope with no decoder
      // here, and the bytes are banked now so one written later can be run
      // over them.
      raw.add(Uint8List.fromList(rec.$2));
      if (f.report == kLefunReportBattery) {
        batteryPct = decodeLefunBattery(f.params) ?? batteryPct;
      }
    });
    try {
      if (!await link.write(kLefunWriteChar, buildLefunFrame(kLefunReportBattery))) {
        link.log('lefun: battery request refused.');
      } else {
        await Future<void>.delayed(replyTimeout);
      }
      if (batteryPct case final pct?) yield BandNote('battery', pct);
      if (raw.isNotEmpty) yield SampleBatch(const [], raw: raw);
    } finally {
      await sub.cancel();
    }
  }
}
