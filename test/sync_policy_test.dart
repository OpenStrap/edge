// Pure-logic tests for the reconnect/offload policy (sync_policy.dart):
// plausibility gates, clock policy, BackfillPolicy rate floors,
// BackfillContinuation, and the five value-typed detectors.
// None of this touches BLE/DB.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  const wall = 1750000000; // a plausible "now" (2025-06)

  group('plausibility gate', () {
    test('absolute floor + future ceiling', () {
      expect(isPlausibleUnix(kMinPlausibleUnix - 1, wall), isFalse);
      expect(isPlausibleUnix(kMinPlausibleUnix, wall), isTrue);
      expect(isPlausibleUnix(wall, wall), isTrue);
      expect(isPlausibleUnix(wall + kFutureMargin + 1, wall), isFalse);
      expect(isPlausibleUnix(wall + kFutureMargin, wall), isTrue);
    });

    test('session-relative window rejects >7d outside the strap range', () {
      final oldest = wall - 3 * 86400;
      final newest = wall;
      // Inside the ±7d margin around the strap's own window → kept.
      expect(
          isPlausibleUnix(oldest - 6 * 86400, wall,
              sessionOldestUnix: oldest, sessionNewestUnix: newest),
          isTrue);
      // >7d before the oldest banked record → rejected (wandering-clock pollution).
      expect(
          isPlausibleUnix(oldest - 8 * 86400, wall,
              sessionOldestUnix: oldest, sessionNewestUnix: newest),
          isFalse);
      // >7d after the newest → rejected.
      expect(
          isPlausibleUnix(newest + 8 * 86400, wall,
              sessionOldestUnix: oldest, sessionNewestUnix: newest),
          isFalse);
    });

    test('a garbage session range is ignored (falls back to absolute gate)', () {
      // newest < oldest → invalid range → only the absolute gate applies.
      expect(
          isPlausibleUnix(wall, wall,
              sessionOldestUnix: wall, sessionNewestUnix: wall - 100),
          isTrue);
    });
  });

  group('ClockPolicy', () {
    test('re-sets on >1d drift or an unset (pre-2023) RTC', () {
      expect(ClockPolicy.shouldSetClock(wall, wall), isFalse);
      expect(ClockPolicy.shouldSetClock(wall - 86400 - 1, wall), isTrue);
      expect(ClockPolicy.shouldSetClock(wall + 86400 + 1, wall), isTrue);
      expect(ClockPolicy.shouldSetClock(1000, wall), isTrue); // frozen/unset
    });
  });

  group('BackfillPolicy', () {
    test('first run is always allowed', () {
      expect(BackfillPolicy.shouldRun(BackfillTrigger.periodic, 100, null, 0),
          isTrue);
    });

    test('manual + autoContinue are never floored', () {
      expect(BackfillPolicy.shouldRun(BackfillTrigger.manual, 0.1, 0, 0), isTrue);
      expect(BackfillPolicy.shouldRun(BackfillTrigger.autoContinue, 0.1, 0, 0),
          isTrue);
    });

    test('periodic honors the 900s floor', () {
      expect(BackfillPolicy.shouldRun(BackfillTrigger.periodic, 899, 0, 0),
          isFalse);
      expect(
          BackfillPolicy.shouldRun(BackfillTrigger.periodic, 900, 0, 0), isTrue);
    });

    test('connect/foreground honor the 90s event floor', () {
      expect(BackfillPolicy.shouldRun(BackfillTrigger.connect, 89, 0, 0), isFalse);
      expect(BackfillPolicy.shouldRun(BackfillTrigger.connect, 90, 0, 0), isTrue);
    });

    test('empty-streak backoff multiplies the strap floor (capped 4x)', () {
      // streak 3 → 2^1 = 2x event floor (90 → 180s)
      expect(BackfillPolicy.shouldRun(BackfillTrigger.strap, 179, 0, 3), isFalse);
      expect(BackfillPolicy.shouldRun(BackfillTrigger.strap, 180, 0, 3), isTrue);
      // streak huge → capped at 4x (90 → 360s), not unbounded.
      expect(
          BackfillPolicy.shouldRun(BackfillTrigger.strap, 359, 0, 99), isFalse);
      expect(BackfillPolicy.shouldRun(BackfillTrigger.strap, 360, 0, 99), isTrue);
    });
  });

  group('BackfillContinuation', () {
    bool cont({
      bool connected = true,
      int? strapNewest = 2000,
      int? frontier = 1000,
      int rows = 50,
      bool trimAdvanced = true,
      int count = 0,
    }) =>
        BackfillContinuation.shouldAutoContinue(
          stillConnected: connected,
          strapNewestTs: strapNewest,
          ourFrontierTs: frontier,
          rowsPersistedThisSession: rows,
          lastTrimAdvanced: trimAdvanced,
          consecutiveCount: count,
        );

    test('continues when strap is >5min ahead and trim advanced', () {
      expect(cont(strapNewest: 2000, frontier: 1000), isTrue);
    });
    test('stops when disconnected', () => expect(cont(connected: false), isFalse));
    test('stops at the per-connection cap', () => expect(cont(count: 6), isFalse));
    test('stops when the cursor did not advance (spin guard)',
        () => expect(cont(trimAdvanced: false), isFalse));
    test('within the behind-gap but rows persisted → continues (#451 stale newest)',
        () => expect(cont(strapNewest: 1100, frontier: 1000, rows: 30), isTrue));
    test('within the behind-gap and no rows → stops',
        () => expect(cont(strapNewest: 1100, frontier: 1000, rows: 0), isFalse));
  });

  group('MarginalRadioDetector', () {
    test('trips after 2 consecutive arm→quick-timeouts, one-shot', () {
      final d = MarginalRadioDetector();
      expect(
          d.connectionEnded(
              wasArmed: true, secondsSinceArm: 5, timedOut: true),
          isFalse);
      expect(
          d.connectionEnded(
              wasArmed: true, secondsSinceArm: 5, timedOut: true),
          isTrue); // trips
      expect(
          d.connectionEnded(
              wasArmed: true, secondsSinceArm: 5, timedOut: true),
          isFalse); // already tripped → one-shot
    });

    test('a slow timeout (>20s after arm) does not count + resets the streak', () {
      final d = MarginalRadioDetector();
      d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true);
      // 25s later → outside the quick window → resets.
      expect(
          d.connectionEnded(
              wasArmed: true, secondsSinceArm: 25, timedOut: true),
          isFalse);
      // Next single quick timeout shouldn't trip (streak was reset).
      expect(
          d.connectionEnded(
              wasArmed: true, secondsSinceArm: 5, timedOut: true),
          isFalse);
    });

    test('not armed → never counts', () {
      final d = MarginalRadioDetector();
      expect(
          d.connectionEnded(
              wasArmed: false, secondsSinceArm: null, timedOut: true),
          isFalse);
      expect(
          d.connectionEnded(
              wasArmed: false, secondsSinceArm: null, timedOut: true),
          isFalse);
    });
  });

  group('PostBondTimeoutLoopDetector', () {
    test('trips after 2 bond→quick(<=8s)-timeouts', () {
      final d = PostBondTimeoutLoopDetector();
      expect(
          d.connectionEnded(
              wasBonded: true, secondsSinceBond: 2, timedOut: true),
          isFalse);
      expect(
          d.connectionEnded(
              wasBonded: true, secondsSinceBond: 2, timedOut: true),
          isTrue);
    });
    test('a timeout 9s after bond is outside the window', () {
      final d = PostBondTimeoutLoopDetector();
      d.connectionEnded(wasBonded: true, secondsSinceBond: 2, timedOut: true);
      expect(
          d.connectionEnded(
              wasBonded: true, secondsSinceBond: 9, timedOut: true),
          isFalse);
    });
  });

  group('EmptySyncTracker', () {
    test('trips on the 3rd consecutive console-only completed sync', () {
      final d = EmptySyncTracker();
      expect(
          d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
          isFalse);
      expect(
          d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
          isFalse);
      expect(
          d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
          isTrue);
    });
    test('a sync that banked sensor records resets the streak', () {
      final d = EmptySyncTracker();
      d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true);
      d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true);
      expect(
          d.recordCompletedSync(bankedSensorRecords: true, consoleOnly: false),
          isFalse); // reset
      expect(
          d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
          isFalse); // streak back to 1
    });
  });

  group('StuckStrapDetector', () {
    test('trips when frontier frozen >=10min and strap >5min ahead', () {
      final d = StuckStrapDetector();
      // seed
      expect(d.observe(5000, 1000, 0), isFalse);
      // frozen frontier (1000), strap ahead (5000), 9min later → not yet.
      expect(d.observe(5000, 1000, 540), isFalse);
      // 10min after the last advance → stuck.
      expect(d.observe(5000, 1000, 600), isTrue);
    });
    test('progressing frontier is healthy (never stuck)', () {
      final d = StuckStrapDetector();
      d.observe(5000, 1000, 0);
      expect(d.observe(5000, 2000, 600), isFalse); // advanced → re-seed
      expect(d.observe(5000, 3000, 1200), isFalse);
    });
    test('caught up (within the behind-gap) is not stuck', () {
      final d = StuckStrapDetector();
      d.observe(1200, 1000, 0);
      // strap only 200s ahead (< 300s behind-gap) → off-wrist, not stuck.
      expect(d.observe(1200, 1000, 1000), isFalse);
    });
  });
}
