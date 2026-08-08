// Issue #208: a band taken off for ten minutes, or carried out of range, never
// reconnects. The app shows "reconnecting", falls back to "disconnected", and
// stays there until the user forgets the band and re-pairs it.
//
// Two independent dead ends produced that, and both are terminal-by-design
// rather than flaky:
//
//   1. `_reconnect()` was EDGE-triggered — its only caller is the
//      `connected → disconnected` transition — and the whole retry loop sat
//      inside one try/catch. Any throw inside the loop abandoned it for good,
//      after which the engine rests at 'disconnected' so the edge can never
//      fire again. On Android the foreground service guarantees the process
//      never restarts to clear it.
//   2. The bond-refusal pause was cleared ONLY inside the `createBond()`
//      success branch, which lives inside the connect path that the pause
//      prevents from running. Self-sealing.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  group('superviseReconnect', () {
    ReconnectSupervisorAction call({
      bool paired = true,
      bool keepAlive = true,
      bool connected = false,
      bool loopRunning = false,
      bool paused = false,
      bool connectInFlight = false,
      Duration? runningFor,
    }) => superviseReconnect(
      paired: paired,
      keepAlive: keepAlive,
      connected: connected,
      loopRunning: loopRunning,
      autoReconnectPaused: paused,
      connectInFlight: connectInFlight,
      attemptRunningFor: runningFor,
    );

    test('disconnected with no loop running restarts the loop', () {
      // The state the app was stuck in — nothing else would ever fire.
      expect(call(), ReconnectSupervisorAction.start);
    });

    test('does nothing while connected', () {
      expect(call(connected: true), ReconnectSupervisorAction.none);
    });

    test('does nothing when unpaired or when we do not want a link', () {
      expect(call(paired: false), ReconnectSupervisorAction.none);
      expect(call(keepAlive: false), ReconnectSupervisorAction.none);
    });

    test('never fights a healthy attempt', () {
      // The Android OS-autoConnect branch waits up to 15 minutes for the band
      // to reappear. That is one NORMAL attempt, and restarting it is actively
      // harmful: the abandoned attempt's eventual disconnect() cancels the OS
      // pending connect its replacement is waiting on.
      expect(
        call(loopRunning: true, runningFor: const Duration(minutes: 15)),
        ReconnectSupervisorAction.none,
      );
      expect(
        call(loopRunning: true, runningFor: const Duration(minutes: 24)),
        ReconnectSupervisorAction.none,
      );
      expect(
        call(loopRunning: true, runningFor: null),
        ReconnectSupervisorAction.none,
      );
    });

    test('a loop running for hours is fine while its attempts turn over', () {
      // A band left at home keeps the loop alive indefinitely; only an
      // individual attempt that never returns is evidence of a wedge.
      expect(
        call(loopRunning: true, runningFor: const Duration(minutes: 3)),
        ReconnectSupervisorAction.none,
      );
    });

    test('restarts an attempt wedged well past the autoConnect window', () {
      // An await that never returns (a leaked band lease, a hung platform call)
      // leaves the in-flight flag true forever; re-triggering cannot fix that,
      // so the flag has to be treated as stale.
      expect(
        call(loopRunning: true, runningFor: const Duration(minutes: 25)),
        ReconnectSupervisorAction.restartStale,
      );
    });

    test('stays out of the way of a user-initiated connect', () {
      // `openSession` starts the supervisor before doing its own connect, and a
      // first Android connect (bond dialog, discovery, INIT) can outlast a
      // 60 s tick. Starting a loop underneath it makes two callers race the
      // same peripheral and re-run the whole post-connect block.
      expect(call(connectInFlight: true), ReconnectSupervisorAction.none);
    });

    test('respects an active bond-refusal pause', () {
      // Not a dead end any more (see below), but while it IS in force the
      // supervisor must not hammer a band that refuses to bond.
      expect(call(paused: true), ReconnectSupervisorAction.none);
      expect(
        call(paused: true, loopRunning: true, runningFor: const Duration(hours: 1)),
        ReconnectSupervisorAction.none,
      );
    });
  });

  group('BondRefusalGiveUp cooldown', () {
    test('trips exactly once at the threshold, then pauses', () {
      final g = BondRefusalGiveUp(giveUpThreshold: 3);
      final t0 = DateTime(2026, 8, 8, 12);
      expect(g.bondRefused(now: t0), isFalse);
      expect(g.bondRefused(now: t0), isFalse);
      expect(g.bondRefused(now: t0), isTrue, reason: 'crosses the threshold');
      expect(g.bondRefused(now: t0), isFalse, reason: 'only ever once');
      expect(g.stillPaused(t0), isTrue);
    });

    test('the pause expires after its cooldown', () {
      final g = BondRefusalGiveUp(
        giveUpThreshold: 1,
        cooldown: const Duration(minutes: 30),
      );
      final t0 = DateTime(2026, 8, 8, 12);
      expect(g.bondRefused(now: t0), isTrue);
      expect(g.stillPaused(t0.add(const Duration(minutes: 29))), isTrue);
      expect(
        g.stillPaused(t0.add(const Duration(minutes: 30))),
        isFalse,
        reason: 'previously nothing could ever clear this',
      );
      // Expiry resets the streak, so a band that still refuses re-trips
      // normally instead of being retried forever.
      expect(g.consecutive, 0);
      expect(g.gaveUp, isFalse);
      expect(g.bondRefused(now: t0.add(const Duration(minutes: 31))), isTrue);
    });

    test('a successful bond clears the streak and the latch', () {
      final g = BondRefusalGiveUp(giveUpThreshold: 2);
      final t0 = DateTime(2026, 8, 8, 12);
      g.bondRefused(now: t0);
      g.bondRefused(now: t0);
      expect(g.stillPaused(t0), isTrue);
      g.bondSucceeded();
      expect(g.stillPaused(t0), isFalse);
      expect(g.gaveUpAt, isNull);
    });

    test('an unpaused tracker is never reported as paused', () {
      final g = BondRefusalGiveUp();
      expect(g.stillPaused(DateTime(2026, 8, 8)), isFalse);
    });
  });
}
