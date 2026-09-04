// MyKronoz ZeTime as a [BandAdapter]: connect, ask one benign device-fact
// question, bank every reply verbatim.
//
// NOTHING HERE HAS MET HARDWARE, and there is no cursor, no clock and no
// derived signal to get wrong yet — see `_registry.dart`'s `kZeTime` for why
// [signals] is empty and stays that way until the owner holds one.
//
// THE PROTOCOL HAS NO AUTHENTICATION. A write to the command characteristic
// gets a reply on the notify characteristic and a fixed one-byte token on the
// ack characteristic; there is no key, no nonce, no bonding requirement this
// file has to reason about — which is also why there is no `_authenticate`
// step the way `oura.dart` has one.
//
// ONE SHOT, NOT A DRAIN. This band's history commands (step count, sleep,
// heart rate) are deliberately never requested — see `zetime.dart`'s own
// header in `protocol` — so there is nothing here to fetch by cursor. The
// whole session is: ask for the battery level, listen for a fixed window,
// bank whatever frames arrive, end.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

class ZeTimeAdapter extends BandAdapter {
  /// How long to keep the notify subscription open after the battery request
  /// goes out. Nobody has measured this watch's real reply latency, so this
  /// is a round window rather than a per-reply wait — see the class doc.
  ///
  /// ponytail: a fixed delay rather than resolving the moment a battery reply
  /// actually lands. Upgrade path: once a real watch has been timed, wait on
  /// the specific reply instead (an `_Inbox`-shaped helper, `oura.dart`'s
  /// pattern) and return as soon as it arrives.
  static const Duration _replyWindow = Duration(seconds: 5);

  const ZeTimeAdapter();

  @override
  BandEntry get entry => kZeTime;

  /// NOTHING. See `kZeTime`'s own doc for why.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final frames = <Uint8List>[];
    int? batteryLevel;
    final sub = link.notify(kZeTimeNotifyChar).listen((rec) {
      final raw = rec.$2;
      final f = parseZeTimeFrame(raw);
      // Only bytes that actually parse as this envelope are banked — the same
      // choice `oura.dart` makes for the same reason: a malformed or
      // still-fragmented notification is not a frame this file understands
      // yet, and archiving it under a made-up shape would be a guess.
      if (f == null) return;
      frames.add(Uint8List.fromList(raw));
      final level = zetimeBatteryLevel(f);
      if (level != null) batteryLevel = level;
    });
    try {
      if (!await link.write(kZeTimeWriteChar, zetimeRequestFrame(kZeTimeCmdBattery))) {
        link.log('zetime: battery request refused.');
      } else if (!await link.write(kZeTimeAckChar, const [kZeTimeAckToken])) {
        link.log('zetime: ack write refused.');
      }
      await Future<void>.delayed(_replyWindow);
    } finally {
      await sub.cancel();
    }
    if (batteryLevel != null) yield BandNote('battery', batteryLevel);
    if (frames.isNotEmpty) {
      yield SampleBatch(const [], raw: frames);
    }
  }
}

/// The single instance. Const, so it costs nothing to reference.
const ZeTimeAdapter kZeTimeAdapter = ZeTimeAdapter();
