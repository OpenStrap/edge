// Issue #200: ~22% of an S22's battery in a day with 15 minutes of screen-on.
//
// The reporter blamed the 10 s heartbeat and the 15-minute backfill. The actual
// dominant cost was that Android's connection priority was requested once, at
// connect setup, and never stepped back down — an ~11.25 ms interval with zero
// slave latency, held 24/7 on a connection that is permanent by design, with a
// battery-optimization exemption ensuring Doze never damps it.
//
// These pin the stepping rule. The load-bearing property is the LAST test: an
// offload always runs at the fast interval, whatever else is going on, because
// throughput during a drain is what the fast interval was for.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  test('an idle backgrounded link runs at the cheap interval', () {
    expect(
      desiredLinkPriority(
        offloadActive: false,
        background: true,
        hasLiveConsumer: false,
      ),
      LinkPriority.lowPower,
      reason: 'the overnight state, and where the drain was being spent',
    );
  });

  test('idle in the foreground is balanced, not high', () {
    expect(
      desiredLinkPriority(
        offloadActive: false,
        background: false,
        hasLiveConsumer: false,
      ),
      LinkPriority.balanced,
    );
  });

  test('a foreground live consumer keeps the fast interval', () {
    // A workout / spot check / breathing session streams 100 Hz; that genuinely
    // needs the bandwidth.
    expect(
      desiredLinkPriority(
        offloadActive: false,
        background: false,
        hasLiveConsumer: true,
      ),
      LinkPriority.high,
    );
  });

  test('a live consumer in the BACKGROUND does not hold the link high', () {
    // Backgrounded, the engine downgrades to the compact 1 Hz stream, so the
    // bandwidth argument no longer applies.
    expect(
      desiredLinkPriority(
        offloadActive: false,
        background: true,
        hasLiveConsumer: true,
      ),
      LinkPriority.lowPower,
    );
  });

  test('an offload ALWAYS gets the fast interval', () {
    // The invariant that keeps this change throughput-only: whatever else is
    // true, a drain in flight raises the link first. Sync correctness never
    // depends on the interval (commit-before-ACK, durable cursor), but making a
    // drain crawl would be a real regression, so this is exhaustive.
    for (final background in [false, true]) {
      for (final live in [false, true]) {
        expect(
          desiredLinkPriority(
            offloadActive: true,
            background: background,
            hasLiveConsumer: live,
          ),
          LinkPriority.high,
          reason: 'background=$background live=$live',
        );
      }
    }
  });

  test('the battery poll is minutes apart, not seconds', () {
    // It rode the 30 s keep-alive tick: 2,880 radio round-trips a day for a
    // display value that changes a handful of times.
    expect(kBatteryPollIntervalSeconds, greaterThanOrEqualTo(300));
    // Still far inside the liveness fuse, so it can never be the thing that
    // starves `sinceLastRx` and bounces a healthy link.
    expect(kBatteryPollIntervalSeconds, greaterThan(kLivenessFuseSeconds));
  });
}
