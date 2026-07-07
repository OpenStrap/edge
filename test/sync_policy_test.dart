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
        isPlausibleUnix(
          oldest - 6 * 86400,
          wall,
          sessionOldestUnix: oldest,
          sessionNewestUnix: newest,
        ),
        isTrue,
      );
      // >7d before the oldest banked record → rejected (wandering-clock pollution).
      expect(
        isPlausibleUnix(
          oldest - 8 * 86400,
          wall,
          sessionOldestUnix: oldest,
          sessionNewestUnix: newest,
        ),
        isFalse,
      );
      // >7d after the newest → rejected.
      expect(
        isPlausibleUnix(
          newest + 8 * 86400,
          wall,
          sessionOldestUnix: oldest,
          sessionNewestUnix: newest,
        ),
        isFalse,
      );
    });

    test(
      'a garbage session range is ignored (falls back to absolute gate)',
      () {
        // newest < oldest → invalid range → only the absolute gate applies.
        expect(
          isPlausibleUnix(
            wall,
            wall,
            sessionOldestUnix: wall,
            sessionNewestUnix: wall - 100,
          ),
          isTrue,
        );
      },
    );
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
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.periodic, 100, null, 0),
        isTrue,
      );
    });

    test('manual + autoContinue are never floored', () {
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.manual, 0.1, 0, 0),
        isTrue,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.autoContinue, 0.1, 0, 0),
        isTrue,
      );
    });

    test('periodic honors the 900s floor', () {
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.periodic, 899, 0, 0),
        isFalse,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.periodic, 900, 0, 0),
        isTrue,
      );
    });

    test('connect/foreground honor the 90s event floor', () {
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.connect, 89, 0, 0),
        isFalse,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.connect, 90, 0, 0),
        isTrue,
      );
      // FOREGROUND catch-up pull (app reopened on a healthy link): allowed
      // after the floor, refused inside it — rapid app switching can't hammer
      // the strap.
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.foreground, 89, 0, 0),
        isFalse,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.foreground, 90, 0, 0),
        isTrue,
      );
      // First-ever pull is never floored.
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.foreground, 1, null, 0),
        isTrue,
      );
    });

    test('empty-streak backoff multiplies the strap floor (capped 4x)', () {
      // streak 3 → 2^1 = 2x event floor (90 → 180s)
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.strap, 179, 0, 3),
        isFalse,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.strap, 180, 0, 3),
        isTrue,
      );
      // streak huge → capped at 4x (90 → 360s), not unbounded.
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.strap, 359, 0, 99),
        isFalse,
      );
      expect(
        BackfillPolicy.shouldRun(BackfillTrigger.strap, 360, 0, 99),
        isTrue,
      );
    });
  });

  group('HistoricalSyncCommandPolicy', () {
    test('first historical send is immediate', () {
      expect(HistoricalSyncCommandPolicy.waitSeconds(null, 100), 0);
    });

    test('historical send is floored to 5 seconds', () {
      expect(HistoricalSyncCommandPolicy.waitSeconds(100, 101), 4);
      expect(HistoricalSyncCommandPolicy.waitSeconds(100, 104.5), 0.5);
      expect(HistoricalSyncCommandPolicy.waitSeconds(100, 105), 0);
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
    }) => BackfillContinuation.shouldAutoContinue(
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
    test(
      'stops when disconnected',
      () => expect(cont(connected: false), isFalse),
    );
    test(
      'stops at the per-connection cap',
      () => expect(cont(count: 6), isFalse),
    );
    test(
      'stops when the cursor did not advance (spin guard)',
      () => expect(cont(trimAdvanced: false), isFalse),
    );
    test(
      'within the behind-gap but rows persisted → continues (#451 stale newest)',
      () => expect(cont(strapNewest: 1100, frontier: 1000, rows: 30), isTrue),
    );
    test(
      'within the behind-gap and no rows → stops',
      () => expect(cont(strapNewest: 1100, frontier: 1000, rows: 0), isFalse),
    );
    test(
      'missing strap newest information + no rows → stops',
      () => expect(
        cont(strapNewest: null, frontier: 1000, rows: 0),
        isFalse,
      ),
    );
  });

  group('MarginalRadioDetector', () {
    test('trips after 2 consecutive arm→quick-timeouts, one-shot', () {
      final d = MarginalRadioDetector();
      expect(
        d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true),
        isFalse,
      );
      expect(
        d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true),
        isTrue,
      ); // trips
      expect(
        d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true),
        isFalse,
      ); // already tripped → one-shot
    });

    test(
      'a slow timeout (>20s after arm) does not count + resets the streak',
      () {
        final d = MarginalRadioDetector();
        d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true);
        // 25s later → outside the quick window → resets.
        expect(
          d.connectionEnded(
            wasArmed: true,
            secondsSinceArm: 25,
            timedOut: true,
          ),
          isFalse,
        );
        // Next single quick timeout shouldn't trip (streak was reset).
        expect(
          d.connectionEnded(wasArmed: true, secondsSinceArm: 5, timedOut: true),
          isFalse,
        );
      },
    );

    test('not armed → never counts', () {
      final d = MarginalRadioDetector();
      expect(
        d.connectionEnded(
          wasArmed: false,
          secondsSinceArm: null,
          timedOut: true,
        ),
        isFalse,
      );
      expect(
        d.connectionEnded(
          wasArmed: false,
          secondsSinceArm: null,
          timedOut: true,
        ),
        isFalse,
      );
    });
  });

  group('PostBondTimeoutLoopDetector', () {
    test('trips after 2 bond→quick(<=8s)-timeouts', () {
      final d = PostBondTimeoutLoopDetector();
      expect(
        d.connectionEnded(wasBonded: true, secondsSinceBond: 2, timedOut: true),
        isFalse,
      );
      expect(
        d.connectionEnded(wasBonded: true, secondsSinceBond: 2, timedOut: true),
        isTrue,
      );
    });
    test('a timeout 9s after bond is outside the window', () {
      final d = PostBondTimeoutLoopDetector();
      d.connectionEnded(wasBonded: true, secondsSinceBond: 2, timedOut: true);
      expect(
        d.connectionEnded(wasBonded: true, secondsSinceBond: 9, timedOut: true),
        isFalse,
      );
    });
  });

  group('EmptySyncTracker', () {
    test('trips on the 3rd consecutive console-only completed sync', () {
      final d = EmptySyncTracker();
      expect(
        d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
        isFalse,
      );
      expect(
        d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
        isFalse,
      );
      expect(
        d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
        isTrue,
      );
    });
    test('a sync that banked sensor records resets the streak', () {
      final d = EmptySyncTracker();
      d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true);
      d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true);
      expect(
        d.recordCompletedSync(bankedSensorRecords: true, consoleOnly: false),
        isFalse,
      ); // reset
      expect(
        d.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
        isFalse,
      ); // streak back to 1
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

  group('BondRefusalGiveUp', () {
    test('trips exactly once on the Nth consecutive refusal', () {
      final d = BondRefusalGiveUp(giveUpThreshold: 3);
      expect(d.bondRefused(), isFalse); // 1
      expect(d.bondRefused(), isFalse); // 2
      expect(d.bondRefused(), isTrue); // 3 → give up (one-shot)
      expect(d.gaveUp, isTrue);
      expect(d.consecutive, 3);
      // Already gave up → never re-fires on further refusals.
      expect(d.bondRefused(), isFalse);
    });

    test('a successful bond clears the streak AND the give-up latch', () {
      final d = BondRefusalGiveUp(giveUpThreshold: 2);
      d.bondRefused();
      expect(d.bondRefused(), isTrue); // gave up
      d.bondSucceeded();
      expect(d.gaveUp, isFalse);
      expect(d.consecutive, 0);
      // A fresh run of refusals can trip again.
      d.bondRefused();
      expect(d.bondRefused(), isTrue);
    });
  });

  group('snapToGrid + correctRecordTs (RTC salvage)', () {
    test('snapToGrid rounds DOWN to the 5-minute boundary', () {
      expect(snapToGrid(0), 0);
      expect(snapToGrid(299), 0);
      expect(snapToGrid(300), 300);
      expect(snapToGrid(301), 300);
      expect(snapToGrid(1234567), (1234567 ~/ 300) * 300);
    });

    test('sub-day drift is left alone (returns null — trust embedded time)', () {
      // offset = clockWall - deviceClock = 3600 (1h) ≤ 1 day → no correction.
      expect(
        ClockPolicy.correctRecordTs(
          wall - 100000,
          wallNow: wall,
          deviceClock: wall - 3600,
          clockWall: wall,
        ),
        isNull,
      );
    });

    test('a >1-day offset is applied AND snapped to the 5-min grid', () {
      const daysOff = 40 * 86400; // unset RTC parked ~40 days in the past
      final deviceClock = wall - daysOff;
      // A record stamped at the device clock's own "now" salvages to ~wall,
      // snapped down to the 5-min grid.
      final corrected = ClockPolicy.correctRecordTs(
        deviceClock, // recTs sits on the device clock
        wallNow: wall,
        deviceClock: deviceClock,
        clockWall: wall,
      );
      expect(corrected, isNotNull);
      expect(corrected, snapToGrid(wall));
      expect(corrected! % kRecTsGridSeconds, 0);
    });

    test('never pushes a corrected record into the future', () {
      const daysOff = 40 * 86400;
      final deviceClock = wall - daysOff;
      // A record stamped AHEAD of the device clock would land past wall-now
      // after the offset is applied → rejected.
      final corrected = ClockPolicy.correctRecordTs(
        deviceClock + daysOff + 10 * 86400,
        wallNow: wall,
        deviceClock: deviceClock,
        clockWall: wall,
      );
      expect(corrected, isNull);
    });

    test('the corrected result must still pass the session-relative band', () {
      const daysOff = 40 * 86400;
      final deviceClock = wall - daysOff;
      // Session window sits far from where the correction lands → rejected even
      // though the arithmetic is plausible against the absolute gate.
      final corrected = ClockPolicy.correctRecordTs(
        deviceClock,
        wallNow: wall,
        deviceClock: deviceClock,
        clockWall: wall,
        sessionOldestUnix: wall - 100 * 86400,
        sessionNewestUnix: wall - 90 * 86400,
      );
      expect(corrected, isNull);
    });
  });

  group('isLinkStale (background zombie-link guard)', () {
    test('fresh data (well under the bar) is NOT stale', () {
      expect(isLinkStale(const Duration(seconds: 5)), isFalse);
      expect(isLinkStale(const Duration(seconds: 29)), isFalse);
    });

    test('at or over kLinkFreshnessSeconds is stale', () {
      expect(isLinkStale(const Duration(seconds: kLinkFreshnessSeconds)), isTrue);
      expect(isLinkStale(const Duration(seconds: 31)), isTrue);
      expect(isLinkStale(const Duration(minutes: 10)), isTrue);
    });

    test('is strictly tighter than the in-session liveness fuse', () {
      // Deliberately different bars for different jobs (see doc comment on
      // kLinkFreshnessSeconds): this guards "should I trust a connection I
      // didn't just watch tick over" (resume / BG-task wake / headless entry),
      // kLivenessFuseSeconds guards "should an ACTIVE session bounce itself".
      expect(kLinkFreshnessSeconds, lessThan(kLivenessFuseSeconds));
    });
  });
}
