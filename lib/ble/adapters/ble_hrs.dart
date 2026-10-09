// Any standard Bluetooth heart-rate sensor — the SIG's Heart Rate Service
// (0x180D) — as a [BandAdapter].
//
// This is the HOSTILE case for a WHOOP-shaped seam, and that is exactly why it
// is the first one expressed in it: no envelope, no CRC, one notify
// characteristic, no commands, no clock, no flash and therefore no offload. If
// it needed a special case anywhere in `adapter.dart`, the seam would be wrong.
// It did not.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a strap and
// `flutter_blue_plus` has no simulator path, so everything below is verified by
// the Bluetooth SIG's Heart Rate Service 1.0 layout, by the fixtures in
// `test/hrs_link_test.dart`, and by the compiler. It ships EXPERIMENTAL
// (ASSUMPTIONS R6) until he owns one and cross-confirms it.

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The adapter. Const, and it holds no session state — everything a session
/// needs lives inside [run].
class BleHrsAdapter extends BandAdapter {
  const BleHrsAdapter();

  @override
  BandEntry get entry => kBleHrs;

  /// I3 + I1, and nothing else. Every sleep, temperature, step and SpO2 card
  /// therefore DELETES ITSELF through the absence contract that already
  /// exists. No new UI conditionals were written for this band, and none
  /// should be.
  ///
  /// One second is the SIG's typical notification rate, not a guarantee: a
  /// strap notifies per beat or per second depending on the model, so
  /// `sampleCadenceSeconds()` measures the real rate downstream and metrics
  /// abstain rather than stretch a window.
  @override
  Map<InputSignal, Duration> get signals => const {
        InputSignal.hrSparse: Duration(seconds: 1),
        InputSignal.rrIntervals: Duration(seconds: 1),
      };

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // No handshake. Nothing to authenticate, no clock to set, no INIT — the
    // whole session is one subscription, which is what makes this the honest
    // floor for "how little can an adapter be".
    // Time covered by refused notifications' beats since the last banked
    // interval: the next banked beat carries it as its gap, so the host's
    // beat chain does not close over the hole (same as `polar_pmd.dart`).
    var gapMs = 0;
    await for (final (atSec, value) in link.notify(kHeartRateMeasurementUuid)) {
      final s = parseHeartRateMeasurement(value);
      if (s == null) continue;
      // The sensor's own "no skin contact" is a REFUSAL, not a low reading: a
      // chest strap off the chest reports confident nonsense. Drop the sample.
      if (s.contact == false) {
        for (final rr in s.rrMs) {
          gapMs += rr;
        }
        continue;
      }
      final gap = s.rrMs.isEmpty ? 0 : gapMs;
      if (s.rrMs.isNotEmpty) gapMs = 0;
      yield SampleBatch(
        [
          NeutralSample(
            // ARRIVAL TIME, NOT BEAT TIME. The RR durations are exact; this
            // anchor is not — BLE notification delivery jitters by tens of
            // milliseconds and the stack batches. `anchor` says so, and the
            // time-axis metrics refuse on `TimeAnchor.arrival`. Do not copy
            // this line into a band that stamps its own records as if the
            // timestamp were measured.
            anchor: TimeAnchor.arrival,
            tsEpoch: atSec,
            hr: s.hr,
            rrMs: s.rrMs,
            gapMs: gap,
            vendor: s.contact == null ? const {} : {'contact': s.contact},
          ),
        ],
        // No `raw`: a 0x2A37 notification IS the sample, so archiving the
        // bytes would store the same two numbers a second time.
        // Not ephemeral: these rows are the point.
        ephemeral: false,
      );
    }
    // No OffloadCheckpoint, ever. The sensor stores nothing, so there is
    // nothing to tell it to forget — the host flushes on its own cadence.
  }
}

/// The single instance. Const, so it costs nothing to reference.
const BleHrsAdapter kBleHrsAdapter = BleHrsAdapter();
