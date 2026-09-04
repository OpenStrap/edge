// A PineTime as a [BandAdapter]: subscribe to both notify channels, archive
// every frame. Nothing else.
//
// NO AUTH, NO HANDSHAKE, NO WRITE OF ANY KIND. Both characteristics start
// notifying the moment something subscribes to them — there is no bonding
// flag, no bind command, nothing this adapter has to say first.
//
// TWO INDEPENDENT NOTIFY CHANNELS ON TWO DIFFERENT SERVICES, merged into one
// stream by hand rather than reaching for `package:async`'s `StreamGroup`
// (same call `id115.dart` makes, for the same reason): the step-count
// characteristic on this watch's own motion service, and the standard SIG
// heart-rate measurement characteristic [kBleHrs] also answers on.
//
// STEP COUNT AND HEART RATE ARE BOTH READABLE HERE, and neither is decoded
// (ASSUMPTIONS R6): nobody on this project owns one, so nothing is claimed
// until a decoder exists and a real capture has met it. Declaring a signal
// off the heart-rate characteristic the way `ble_hrs.dart` does would need
// its own cross-confirmed capture on THIS firmware, not a borrowed decoder —
// a frame that parses does not mean this watch's clock, contact-sensing or
// units agree with the strap that decoder was proven against.

import 'dart:async';
import 'dart:typed_data';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state.
class PineTimeAdapter extends BandAdapter {
  const PineTimeAdapter();

  @override
  BandEntry get entry => kPineTime;

  /// Empty on purpose (the hard invariant). Step count and heart rate are
  /// both readable off the wire and neither is claimed here.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final merged = StreamController<(int, List<int>)>();
    var openSubs = 2;
    void onOneDone() {
      openSubs--;
      if (openSubs == 0) merged.close();
    }

    // `cancelOnError: true` on BOTH: without it, a channel that errors but
    // does not itself close keeps delivering — `onOneDone` would already have
    // closed `merged` on the error, and the next `merged.add` from either
    // channel throws a StateError into a stream nothing here catches.
    final subSteps = link.notify(kPineTimeStepCountChar).listen(
          merged.add,
          onDone: onOneDone,
          onError: (Object _) => onOneDone(),
          cancelOnError: true,
        );
    final subHr = link.notify(kHeartRateMeasurementUuid).listen(
          merged.add,
          onDone: onOneDone,
          onError: (Object _) => onOneDone(),
          cancelOnError: true,
        );
    // No write of any kind: both channels stream on their own the moment
    // they are subscribed.
    try {
      await for (final (_, value) in merged.stream) {
        final bytes = Uint8List.fromList(value);
        if (bytes.isEmpty) continue;
        // EVERY frame is archived, decoded or not, from either channel — the
        // bytes are banked now so a decoder written when someone owns one of
        // these can run over them, instead of a guess running over them
        // today.
        yield SampleBatch(const [], raw: [bytes], ephemeral: false);
      }
    } finally {
      await subSteps.cancel();
      await subHr.cancel();
    }
    // No OffloadCheckpoint: nothing here trims a flash on our ACK, and there
    // is no flash to trim from our side of the wire — the watch just streams
    // live.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const PineTimeAdapter kPineTimeAdapter = PineTimeAdapter();
