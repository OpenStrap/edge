// A Polar optical sensor's PMD (measurement data) service, PPI stream only —
// as a [BandAdapter].
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one and
// `flutter_blue_plus` has no simulator path, so everything below is verified
// by the wire layout in `polar_pmd.dart` (protocol), the fixtures in
// `test/adapters/polar_pmd_adapter_test.dart` and the compiler. It ships
// EXPERIMENTAL (ASSUMPTIONS R6) until the owner has held one and cross-
// confirms it.
//
// PPI ONLY, deliberately. The PMD service also carries PPG, ECG, accelerometer
// and gyroscope streams — none of them are decoded here, and each would need
// its own settings negotiation and its own undecoded-raw-archive format for a
// stream nothing consumes today. PPI needs no settings block, streams online
// with one control-point write, and is fully decoded per-sample, so there is
// nothing to archive raw — same reasoning `ble_hrs` already gives for skipping
// `raw`.

import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class PolarPmdAdapter extends BandAdapter {
  const PolarPmdAdapter();

  @override
  BandEntry get entry => kPolarPmd;

  /// HR + beat interval — functionally the same pair `ble_hrs` declares, from
  /// a different physical sensor. See that adapter's own doc on why a
  /// declared-but-absent signal is worse than a missing one; this is the
  /// honest statement of what a PPI stream physically carries.
  @override
  Map<InputSignal, Duration> get signals => const {
        InputSignal.hrSparse: Duration(seconds: 1),
        InputSignal.rrIntervals: Duration(seconds: 1),
      };

  /// How long to wait for the START command's control-point reply before
  /// giving up on this session — short, because a sensor that never answers
  /// it will never stream either.
  static const Duration _startTimeout = Duration(seconds: 5);

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // The control-point reply this session is waiting for, resolved the
    // moment a START reply for the PPI type arrives. A misbehaving sensor
    // that never answers times out rather than hanging the session.
    final started = Completer<bool>();
    final controlSub = link.notify(kPolarPmdControlChar).listen((rec) {
      final r = parsePolarPmdControlResponse(rec.$2);
      if (r != null &&
          r.reqOpcode == kPolarPmdOpRequestMeasurementStart &&
          r.measType == kPolarPmdMeasTypePpi &&
          !started.isCompleted) {
        started.complete(r.ok);
      }
    });
    // SUBSCRIBED NOW, READ LATER. The sensor is free to start streaming the
    // moment the START write lands — before this session has even seen its
    // control-point ack — so the data characteristic has to be listened to
    // (and its notifications therefore buffered) from the same instant as
    // the control characteristic, not only once the ack arrives. A single-
    // subscription controller queues everything `.add`ed before `.stream`
    // gets its listener, which is what makes the two-step
    // subscribe-then-consume below lose nothing. Same shape `oura.dart`'s
    // `_Inbox` exists for; smaller because this stream needs no "next with
    // timeout", just a buffered pass-through.
    final dataEvents = StreamController<(int, List<int>)>();
    final dataSub = link.notify(kPolarPmdDataChar).listen(
          dataEvents.add,
          onDone: dataEvents.close,
          onError: dataEvents.addError,
        );
    try {
      if (!await link.write(kPolarPmdControlChar, polarPmdStartPpi())) {
        link.log('polar_pmd: START write refused; ending the session.');
        return;
      }
      final ok = await started.future
          .timeout(_startTimeout, onTimeout: () => false);
      if (!ok) {
        link.log('polar_pmd: PPI start was not confirmed; ending the '
            'session.');
        return;
      }
      await for (final (atSec, value) in dataEvents.stream) {
        final samples = parsePolarPmdPpiFrame(value);
        if (samples == null) continue;
        final neutrals = [
          for (final s in samples)
            // hr == 0 is the sensor's own "no valid beat this record" — a
            // refusal, not a low reading. Storing it would put a fabricated
            // zero into a heart-rate series, the same rule `ble_hrs` applies
            // to a strap reporting no skin contact.
            if (s.hr != 0)
              NeutralSample(
                anchor: TimeAnchor.arrival,
                tsEpoch: atSec,
                hr: s.hr,
                rrMs: [s.ppiMs],
                vendor: {
                  'blocker': s.blocker,
                  // Raw bits, under their own name — their real-world
                  // polarity is not independently confirmed against
                  // hardware, so nothing here gates on them (see
                  // `PolarPpiSample.skinContactBits`'s own doc).
                  'skin_contact': s.skinContactBits,
                  'error_ms': s.errorEstimateMs,
                },
              ),
        ];
        if (neutrals.isNotEmpty) yield SampleBatch(neutrals);
      }
    } finally {
      // Best-effort: a link that has already dropped simply refuses this
      // write, which is fine — the sensor stops streaming on disconnect
      // regardless.
      unawaited(link.write(kPolarPmdControlChar, polarPmdStopPpi()));
      await controlSub.cancel();
      await dataSub.cancel();
      unawaited(dataEvents.close());
    }
    // No OffloadCheckpoint, ever. Online streaming only — nothing is stored
    // on the sensor for this stream, so there is nothing to tell it to forget.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const PolarPmdAdapter kPolarPmdAdapter = PolarPmdAdapter();
