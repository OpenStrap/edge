// sync_policy.dart — pure, I/O-free reconnect/offload policy.
// Value-typed state machines covering the six detectors + BackfillPolicy +
// clock/plausibility gates. NOTHING here touches BLE, the DB, or Flutter —
// every type is exhaustively unit-testable and the engine just feeds it
// observations and reads back decisions.
//
// WHOOP 4.0 only (the only family OpenStrap supports). The WHOOP-5-specific
// Whoop5EmptyOffloadTracker is included for completeness but is not wired by
// the engine.

import 'dart:math' as math;

// ── timing constants (seconds) ───────────────────────────────────────────────
const int kBackfillIntervalSeconds = 900; // re-offload every 15 min (periodic)
const int kKeepAliveIntervalSeconds =
    30; // re-arm realtime, poll battery, watchdog
const int kBackfillIdleTimeoutSeconds = 60; // strap went silent mid-offload
const int kLivenessFuseSeconds = 120; // no data for >fuse ⇒ bounce the link
const int kHistoricalSendFloorSeconds = 5; // official app floors 0x16 to 5s
const int kHistoricalAbortRetryDelaySeconds =
    3; // official app retries 3s after abort

/// iOS can hand back a peripheral that still reports `connected` while its
/// GATT notifications actually died during suspension (the "zombie link" —
/// see `BleEngine._keepAliveFire` and `AppState.openSession`). This is the
/// ONE shared freshness bar for "trust the connected flag or not": under it,
/// treat `sinceLastRx` as proof of a genuinely live link; at/over it, the flag
/// is not to be trusted and the caller must force a real teardown+reconnect
/// instead of doing lightweight work (a catch-up pull, a fast reclaim) over
/// what may be a dead radio session. Deliberately tighter than
/// [kLivenessFuseSeconds] (which decides when an ACTIVE session bounces
/// itself) because every site that reads this is instead deciding whether to
/// trust a connection it did not just watch tick over — a resume, a BG-task
/// wake, a headless entry point.
const int kLinkFreshnessSeconds = 30;

/// True when a connection reporting "connected" should NOT be trusted because
/// no data has actually arrived within [kLinkFreshnessSeconds]. Pure — callers
/// own the actual teardown/reconnect. See [kLinkFreshnessSeconds].
bool isLinkStale(Duration sinceLastRx) =>
    sinceLastRx.inSeconds >= kLinkFreshnessSeconds;

// ── plausibility gates (unix seconds) ────────────────────────────────────────
const int kMinPlausibleUnix = 1700000000; // 2023-11 floor
const int kFutureMargin = 86400; // +1 day
const int kSessionRangeMargin =
    7 * 86400; // ±7 days around the strap's own range

/// True iff [ts] (epoch sec) is a believable record time given wall-clock [wallNow]
/// and — when known — the strap's own GET_DATA_RANGE window. An absolute
/// floor/ceiling always applies; if the session range is known we additionally
/// reject records more than 7 days outside it (wandering-clock pollution).
bool isPlausibleUnix(
  int ts,
  int wallNow, {
  int? sessionOldestUnix,
  int? sessionNewestUnix,
}) {
  if (ts < kMinPlausibleUnix || ts > wallNow + kFutureMargin) return false;
  if (sessionOldestUnix != null && sessionNewestUnix != null) {
    if (sessionOldestUnix >= kMinPlausibleUnix &&
        sessionNewestUnix >= sessionOldestUnix) {
      return ts >= sessionOldestUnix - kSessionRangeMargin &&
          ts <= sessionNewestUnix + kSessionRangeMargin;
    }
  }
  return true;
}

// ── clock correlation ────────────────────────────────────────────────────────
/// Correlates the strap's RTC epoch with wall-clock at the instant of GET_CLOCK.
class ClockRef {
  final int device; // strap RTC epoch at correlation time
  final int wall; // wall unix seconds at that same instant
  const ClockRef({required this.device, required this.wall});
}

/// The dedup grid the record-time correction snaps to. Repeated re-syncs of the
/// SAME physical record (a band that re-floods after a missed ACK) must land on
/// the IDENTICAL corrected rec_ts, or the decoded_onehz UNIQUE(rec_ts) dedup
/// admits duplicates. Snapping the correction to a coarse grid makes the result
/// stable even if the strap↔wall offset wobbles by a few seconds between syncs.
const int kRecTsGridSeconds = 300; // 5-minute grid

/// Snap [ts] DOWN to the nearest [grid]-second boundary.
int snapToGrid(int ts, [int grid = kRecTsGridSeconds]) => (ts ~/ grid) * grid;

class ClockPolicy {
  /// Re-issue SET_CLOCK if the strap clock has drifted > 1 day or is frozen in
  /// the pre-2023 past (an unset RTC).
  static bool shouldSetClock(int deviceClock, int wallNow) {
    final drift = (wallNow - deviceClock).abs();
    return drift > 86400 || deviceClock < kMinPlausibleUnix;
  }

  /// Salvage an implausible record time using the strap↔wall clock offset
  /// (device→wall = [clockWall] - [deviceClock]). A wandering/unset RTC offsets
  /// EVERY record in a session by the same amount, so shifting by that offset
  /// recovers the true wall time. Conservative by design:
  ///   - only corrects when the offset exceeds 1 day (small drift is left alone —
  ///     the embedded time is trusted for sub-day skew);
  ///   - SNAPS the result to a 5-minute grid so repeated re-syncs dedupe to the
  ///     identical rec_ts (protects the decoded_onehz UNIQUE(rec_ts) key);
  ///   - never returns a time past wall-clock-now;
  ///   - the result must still pass [isPlausibleUnix] against the session's own
  ///     GET_DATA_RANGE ±7-day band.
  /// Returns the corrected+snapped ts, or null when it can't be made plausible
  /// (the caller then drops the record, exactly as before).
  static int? correctRecordTs(
    int recTs, {
    required int wallNow,
    int? deviceClock,
    int? clockWall,
    int? sessionOldestUnix,
    int? sessionNewestUnix,
  }) {
    if (deviceClock == null || clockWall == null) return null;
    final offset = clockWall - deviceClock;
    if (offset.abs() <= 86400) return null; // sub-day drift — don't manufacture a fix
    var corrected = recTs + offset;
    // Snap FIRST, then clamp: snapping down can only lower the value, so a value
    // that was <= now stays <= now, and we still guard the post-snap result.
    corrected = snapToGrid(corrected);
    if (corrected > wallNow) return null; // never push a record into the future
    if (!isPlausibleUnix(
      corrected,
      wallNow,
      sessionOldestUnix: sessionOldestUnix,
      sessionNewestUnix: sessionNewestUnix,
    )) {
      return null;
    }
    return corrected;
  }
}

// ── periodic-backfill rate policy ────────────────────────────────────────────
enum BackfillTrigger {
  periodic,
  connect,
  foreground,
  manual,
  strap,
  autoContinue,
}

class BackfillPolicy {
  static const double periodicFloorSeconds = 900.0;
  static const double eventFloorSeconds = 90.0;
  static const int emptyBackoffThreshold = 3;
  static const double maxEmptyBackoff = 4.0;

  /// Whether an offload [trigger] should actually run now, given the last run
  /// time and a streak of consecutive empty offloads (exponential backoff once
  /// the streak crosses the threshold). manual/autoContinue are never floored.
  static bool shouldRun(
    BackfillTrigger trigger,
    double now,
    double? lastBackfillAt,
    int emptyStreak,
  ) {
    if (lastBackfillAt == null) return true;
    final elapsed = now - lastBackfillAt;
    final backoff = emptyStreak >= emptyBackoffThreshold
        ? math
              .pow(2.0, (emptyStreak - emptyBackoffThreshold + 1).toDouble())
              .toDouble()
              .clamp(1.0, maxEmptyBackoff)
        : 1.0;
    switch (trigger) {
      case BackfillTrigger.manual:
      case BackfillTrigger.autoContinue:
        return true;
      case BackfillTrigger.connect:
      case BackfillTrigger.foreground:
        return elapsed >= eventFloorSeconds;
      case BackfillTrigger.strap:
        return elapsed >= eventFloorSeconds * backoff;
      case BackfillTrigger.periodic:
        return elapsed >= periodicFloorSeconds * backoff;
    }
  }
}

class HistoricalSyncCommandPolicy {
  static double waitSeconds(double? lastSendAt, double now) {
    if (lastSendAt == null) return 0.0;
    final remain = kHistoricalSendFloorSeconds - (now - lastSendAt);
    return remain > 0 ? remain : 0.0;
  }
}

// ── continuation: re-kick immediately instead of waiting 15 min ──────────────
class BackfillContinuation {
  static const int defaultMaxAutoContinues = 6;
  static const int defaultBehindGapSeconds = 300;

  /// Whether to immediately re-trigger an offload after a chunk drain / idle cap.
  /// ALL gates must hold: still connected, under the per-connection cap, the trim
  /// cursor actually advanced (not spinning on a frozen cursor), and either the
  /// strap is genuinely >5 min ahead of our frontier OR this session persisted
  /// real rows (the strap's reported "newest" can be stale — #451).
  static bool shouldAutoContinue({
    required bool stillConnected,
    required int? strapNewestTs,
    required int? ourFrontierTs,
    required int rowsPersistedThisSession,
    required bool lastTrimAdvanced,
    required int consecutiveCount,
    int maxAutoContinues = defaultMaxAutoContinues,
    int behindGapSeconds = defaultBehindGapSeconds,
  }) {
    if (!stillConnected) return false;
    if (consecutiveCount >= maxAutoContinues) return false;
    if (!lastTrimAdvanced) return false;
    if (strapNewestTs != null && ourFrontierTs != null) {
      if ((strapNewestTs - ourFrontierTs) > behindGapSeconds) return true;
    }
    return rowsPersistedThisSession > 0;
  }
}

// ── detector 1: marginal radio ───────────────────────────────────────────────
/// A weak BT radio that can't sustain the R10/R11 raw stream: consecutive
/// arm→quick-timeout cycles. Trips once; action = fall back to standard HR only.
class MarginalRadioDetector {
  final int tripThreshold;
  final double quickTimeoutWindow;
  MarginalRadioDetector({
    this.tripThreshold = 2,
    this.quickTimeoutWindow = 20.0,
  });

  int _consecutive = 0;
  bool tripped = false;

  /// Feed a disconnect. Returns true exactly once, on the call that trips.
  bool connectionEnded({
    required bool wasArmed,
    required double? secondsSinceArm,
    required bool timedOut,
  }) {
    final armCausedTimeout =
        wasArmed &&
        timedOut &&
        secondsSinceArm != null &&
        secondsSinceArm <= quickTimeoutWindow;
    if (!armCausedTimeout) {
      _consecutive = 0;
      return false;
    }
    _consecutive++;
    if (!tripped && _consecutive >= tripThreshold) {
      tripped = true;
      return true;
    }
    return false;
  }

  void reset() {
    _consecutive = 0;
    tripped = false;
  }
}

// ── detector 2: post-bond timeout loop (#617) ────────────────────────────────
/// Bond succeeds then dies ~1s later, re-scans, repeats. Consecutive
/// bond→quick-timeout cycles. Trips once; action = surface the re-pair guide.
class PostBondTimeoutLoopDetector {
  final int tripThreshold;
  final double quickTimeoutWindow;
  PostBondTimeoutLoopDetector({
    this.tripThreshold = 2,
    this.quickTimeoutWindow = 8.0,
  });

  int _consecutive = 0;
  bool tripped = false;

  bool connectionEnded({
    required bool wasBonded,
    required double? secondsSinceBond,
    required bool timedOut,
  }) {
    final bondThenQuickTimeout =
        wasBonded &&
        timedOut &&
        secondsSinceBond != null &&
        secondsSinceBond <= quickTimeoutWindow;
    if (!bondThenQuickTimeout) {
      _consecutive = 0;
      return false;
    }
    _consecutive++;
    if (!tripped && _consecutive >= tripThreshold) {
      tripped = true;
      return true;
    }
    return false;
  }

  void reset() {
    _consecutive = 0;
    tripped = false;
  }
}

// ── detector 2b: bond-refusal give-up ────────────────────────────────────────
/// A band that keeps REFUSING the bond (link reachable, encryption denied) will
/// never accept commands, so retrying forever just pins the radio and drains the
/// battery. After [giveUpThreshold] consecutive refusals this signals "give up":
/// the caller pauses the auto-reconnect loop and surfaces the re-pair guide
/// instead. Distinct from [PostBondTimeoutLoopDetector] (which watches a
/// bond→instant-timeout loop) — this counts outright refusals of createBond.
/// A single successful bond resets the streak.
class BondRefusalGiveUp {
  final int giveUpThreshold;
  BondRefusalGiveUp({this.giveUpThreshold = 5});

  int _consecutive = 0;
  bool gaveUp = false;

  int get consecutive => _consecutive;

  /// Feed a bond refusal/timeout. Returns true EXACTLY ONCE, on the call that
  /// crosses the threshold (the caller then pauses reconnect + surfaces the guide).
  bool bondRefused() {
    if (gaveUp) return false;
    _consecutive++;
    if (_consecutive >= giveUpThreshold) {
      gaveUp = true;
      return true;
    }
    return false;
  }

  /// A bond that succeeded (or a session that got past bonding). Clears the
  /// streak AND the give-up latch so a later refusal run can trip again.
  void bondSucceeded() {
    _consecutive = 0;
    gaveUp = false;
  }

  void reset() {
    _consecutive = 0;
    gaveUp = false;
  }
}

// ── detector 3: empty-sync tracker ───────────────────────────────────────────
/// ≥3 consecutive COMPLETED offloads that banked no sensor records (console
/// only) ⇒ the strap's clock has lost sync. Trips once per crossing.
class EmptySyncTracker {
  final int threshold;
  EmptySyncTracker({this.threshold = 3});

  int _consecutive = 0;

  /// Feed a HISTORY_COMPLETE. Returns true on the call that crosses the threshold.
  bool recordCompletedSync({
    required bool bankedSensorRecords,
    required bool consoleOnly,
  }) {
    if (!consoleOnly || bankedSensorRecords) {
      _consecutive = 0;
      return false;
    }
    _consecutive++;
    return _consecutive >= threshold;
  }

  void reset() => _consecutive = 0;
}

// ── detector 4: WHOOP-5 empty offload (#580) — NOT wired (no WHOOP5) ──────────
class Whoop5EmptyOffloadTracker {
  final int quietThreshold;
  Whoop5EmptyOffloadTracker({this.quietThreshold = 2});

  int _consecutive = 0;
  bool historyEmpty = false;

  bool recordOffload({required bool bankedRecords}) {
    if (bankedRecords) {
      _consecutive = 0;
      historyEmpty = false;
      return false;
    }
    _consecutive++;
    if (!historyEmpty && _consecutive >= quietThreshold) {
      historyEmpty = true;
      return true;
    }
    return false;
  }

  void reset() {
    _consecutive = 0;
    historyEmpty = false;
  }
}

// ── detector 5: stuck strap ──────────────────────────────────────────────────
/// The strap reports newer data than us but our persisted frontier hasn't moved
/// for ≥10 min while the strap is >5 min ahead ⇒ stuck; action = defensive
/// EXIT_HIGH_FREQ_SYNC + SET_CLOCK. Value-typed; caller passes a monotonic `now`.
class StuckStrapDetector {
  final double stuckAfterSeconds;
  final int behindGapSeconds;
  StuckStrapDetector({
    this.stuckAfterSeconds = 600.0,
    this.behindGapSeconds = 300,
  });

  int? _lastFrontierTs;
  double? _lastAdvanceWall;

  bool observe(int? strapNewestTs, int? ourFrontierTs, double now) {
    if (strapNewestTs == null || ourFrontierTs == null) return false;
    if (_lastFrontierTs == null) {
      _lastFrontierTs = ourFrontierTs;
      _lastAdvanceWall = now;
      return false;
    }
    if (ourFrontierTs > _lastFrontierTs!) {
      _lastFrontierTs = ourFrontierTs;
      _lastAdvanceWall = now;
      return false;
    }
    final behind = (strapNewestTs - ourFrontierTs) > behindGapSeconds;
    if (!behind) {
      _lastAdvanceWall = now;
      return false;
    }
    return (now - (_lastAdvanceWall ?? now)) >= stuckAfterSeconds;
  }

  void reset() {
    _lastFrontierTs = null;
    _lastAdvanceWall = null;
  }
}
