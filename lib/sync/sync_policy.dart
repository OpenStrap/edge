// sync_policy.dart — pure, I/O-free reconnect/offload policy.
// Value-typed state machines covering the reconnect/offload detectors +
// BackfillPolicy + clock/plausibility gates. NOTHING here touches BLE, the
// DB, or Flutter — every type is exhaustively unit-testable and the engine
// just feeds it observations and reads back decisions.
//
// WHOOP 4.0 only (the only family OpenStrap supports). A prior speculative
// Whoop5EmptyOffloadTracker was removed — unwired, untested dead code with no
// real WHOOP5 offload path to integrate with. Write its real equivalent
// alongside actual WHOOP5 support when that's built; it won't be identical
// to the speculative shape anyway once real integration requirements exist.

import 'dart:math' as math;

// ── timing constants (seconds) ───────────────────────────────────────────────
const int kBackfillIntervalSeconds = 900; // re-offload every 15 min (periodic)
const int kKeepAliveIntervalSeconds =
    30; // re-arm realtime, poll battery, watchdog
const int kBackfillIdleTimeoutSeconds = 60; // strap went silent mid-offload
const int kLivenessFuseSeconds = 120; // no data for >fuse ⇒ bounce the link
// Every existing RTC recheck is symptom-triggered (drift detected on the ONE
// GET_CLOCK read at connect, or a defensive SET_CLOCK on StuckStrapDetector
// tripping). A connection that stays open for many hours (iOS's
// bluetooth-central background mode keeps links open indefinitely) had NO
// independent proactive recheck. This re-arms a plain GET_CLOCK on a healthy
// long-lived link; the existing clock_epoch response handler already does
// the drift comparison + bounded SET_CLOCK re-issue, so this only supplies
// the missing periodic trigger, not new drift-correction logic.
const int kRtcReverifyIntervalSeconds = 6 * 3600; // 6h
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

/// A stricter, single-purpose sanity check for a band-reported "newest
/// record" timestamp (GET_DATA_RANGE's `range_newest`) that sits implausibly
/// far in the future — the signature of a corrupt/never-set strap RTC.
/// Deliberately narrower than [isPlausibleUnix] (which also enforces the
/// historical floor and the strap's own ±7-day session band): this is an
/// EARLY gate on the raw band-reported value itself, before it's trusted
/// enough to tighten the per-record plausibility window for the rest of the
/// session — GET_DATA_RANGE responses are documented to occasionally carry
/// junk at unstable offsets, and today nothing sanity-checks them before they
/// feed [RecordGate]'s session window.
bool isCorruptFutureRtc(int reportedUnix, int wallNow) =>
    reportedUnix > wallNow + kFutureMargin;

// ── clock correlation ────────────────────────────────────────────────────────
/// Correlates the strap's RTC epoch with wall-clock at the instant of GET_CLOCK.
class ClockRef {
  final int device; // strap RTC epoch at correlation time
  final int wall; // wall unix seconds at that same instant
  const ClockRef({required this.device, required this.wall});

  /// How far the strap RTC lags wall-clock (positive = strap behind). This is the
  /// offset used to arm the on-device alarm in the strap's own clock frame; a
  /// caller with no correlation yet should treat it as 0 (`ref?.driftSec ?? 0`).
  int get driftSec => wall - device;
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
  /// Whether a GET_CLOCK `clock_epoch` read may be trusted enough to become
  /// this session's strap-RTC ↔ wall correlation ([ClockRef]).
  ///
  /// `range_newest` (GET_DATA_RANGE) is already guarded by [isCorruptFutureRtc]
  /// before it is allowed to tighten the per-record plausibility window;
  /// `clock_epoch` had NO such gate, even though it feeds something strictly
  /// more dangerous. A corrupt far-future RTC read yields a large NEGATIVE
  /// [ClockRef.driftSec], and [AlarmPayloads.toStrapFrame] arms the wake alarm
  /// at `when - driftSec` — i.e. years in the future, where it silently never
  /// fires. Reject the read instead: with no correlation the alarm falls back
  /// to the raw wall epoch, and the bounded SET_CLOCK retry budget is not
  /// spent chasing a value that was never real.
  static bool acceptsClockRead(int deviceClock, int wallNow) =>
      !isCorruptFutureRtc(deviceClock, wallNow);

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

/// Whether a decoded battery reading describes the band's CURRENT charge.
///
/// Two sources populate the same battery field. A GET_BATTERY_LEVEL response is
/// live by construction — it is answered on the spot and carries no timestamp.
/// A BATTERY_LEVEL event does carry one, and cannot be trusted without it: the
/// band re-serves its whole buffered event log on connect, so a first pair with
/// a long backlog delivers weeks of historical readings at speed. Applied
/// blind, they walk the live indicator through the band's entire battery
/// history before it settles. Same hazard the `charging` flag already guards
/// via [DeviceState.chargingTs].
class BatteryPolicy {
  /// How recent a BATTERY_LEVEL event must be to count as the current charge.
  /// The band emits one roughly every 8 minutes, so a half-hour window keeps
  /// every genuinely live event while rejecting a replayed backlog.
  static const int maxEventAgeSec = 1800;

  /// [tsEpoch] is the event's own strap-clock stamp, or null for a poll
  /// response. The window is symmetric on purpose: a strap RTC running ahead
  /// stamps an event in the FUTURE, and a one-sided age check never looks at
  /// that side — a future-dated replay would sail through and overwrite the
  /// live value. Beyond the window in either direction is a drifting or unset
  /// RTC, refused for the same reason [ClockPolicy] refuses one: with no
  /// accepted event the 30-second poll still owns the value.
  static bool acceptsEventReading(int? tsEpoch, int wallNow) {
    if (tsEpoch == null) return true;
    return (wallNow - tsEpoch).abs() <= maxEventAgeSec;
  }
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

/// Run-state for a chain of auto-continued offload rounds.
///
/// Kept separate from [BackfillContinuation] (which is a pure decision) because
/// the ORDER these transitions happen in is itself the thing that goes wrong:
/// a productive round has to clear the unproductive streak BEFORE the gate is
/// consulted, or a streak already at the cap blocks the very round that is
/// making progress.
class AutoContinueRun {
  int _unproductive = 0;
  double? _startedAt;

  int get unproductiveStreak => _unproductive;
  bool get active => _startedAt != null;

  /// Seconds since this run's first auto-continue, or 0 if no run is active.
  double elapsed(double now) => _startedAt == null ? 0 : now - _startedAt!;

  /// Call once per finished round, BEFORE consulting [BackfillContinuation].
  /// A round that banked records and advanced the trim token has proven there
  /// is more to fetch, so it does not spend the budget.
  void observe({required bool productive}) {
    if (productive) _unproductive = 0;
  }

  /// Call when the gate said continue.
  void continued({required bool productive, required double now}) {
    _startedAt ??= now;
    if (!productive) _unproductive++;
  }

  /// Call when the gate said stop — the chain is over, so the next one starts
  /// with a full budget. New runs are still rate-limited by the backfill floor.
  void end() {
    _startedAt = null;
    _unproductive = 0;
  }
}

// ── continuation: re-kick immediately instead of waiting 15 min ──────────────
class BackfillContinuation {
  static const int defaultMaxAutoContinues = 6;
  static const int defaultBehindGapSeconds = 300;

  /// Ceiling on one continuous auto-continue run, seconds. Rounds that are
  /// making progress no longer spend [defaultMaxAutoContinues], so this is what
  /// bounds the run — which is the right unit anyway, because what actually
  /// runs out on a background wake is time, not rounds.
  static const int defaultMaxAutoContinueSeconds = 600;

  /// Whether to immediately re-trigger an offload after a chunk drain / idle cap.
  /// ALL gates must hold: still connected, inside the time ceiling, under the
  /// unproductive-round cap, the trim cursor actually advanced (not spinning on
  /// a frozen cursor), and either the strap is genuinely >5 min ahead of our
  /// frontier OR this session persisted real rows (the strap's reported
  /// "newest" can be stale — #451).
  ///
  /// [consecutiveUnproductiveCount] counts only rounds that banked nothing. A
  /// round that banked records AND advanced the trim token has proven there is
  /// more to fetch, so it must not consume the budget — otherwise a single
  /// background wake stops after [maxAutoContinues] rounds no matter how far
  /// behind the strap is, and the backlog outruns the sync.
  static bool shouldAutoContinue({
    required bool stillConnected,
    required int? strapNewestTs,
    required int? ourFrontierTs,
    required int rowsPersistedThisSession,
    required bool lastTrimAdvanced,
    required int consecutiveUnproductiveCount,
    double elapsedSeconds = 0,
    int maxAutoContinues = defaultMaxAutoContinues,
    int behindGapSeconds = defaultBehindGapSeconds,
    int maxAutoContinueSeconds = defaultMaxAutoContinueSeconds,
  }) {
    if (!stillConnected) return false;
    if (elapsedSeconds >= maxAutoContinueSeconds) return false;
    if (consecutiveUnproductiveCount >= maxAutoContinues) return false;
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

// ── detector 1b: frame corruption ────────────────────────────────────────────
/// [MarginalRadioDetector] only ever sees *timeouts* — a link that stops
/// responding. A degrading radio can instead keep responding promptly while
/// corrupting an increasing fraction of frames (CRC8 length-byte or CRC32
/// payload mismatch in `framing.dart`) — which looks identical to a healthy
/// link on every timeout-based diagnostic. This tracks a rolling window of
/// frame validity and trips once the corruption rate within the window
/// crosses [rateThreshold], driving the SAME standard-HR fallback action as
/// marginal-radio — same remedy (drop the raw live stream, keep 1 Hz decode),
/// independent failure signature. [minSamples] avoids tripping on a tiny,
/// noisy sample right after connect.
class FrameCorruptionDetector {
  final int windowSize;
  final double rateThreshold;
  final int minSamples;

  FrameCorruptionDetector({
    this.windowSize = 50,
    this.rateThreshold = 0.2,
    this.minSamples = 20,
  });

  final List<bool> _window = []; // true = valid frame
  int _invalidInWindow = 0;
  bool tripped = false;

  /// Feed one frame's validity. Returns true exactly once, on the call that
  /// crosses the threshold.
  bool feed(bool valid) {
    _window.add(valid);
    if (!valid) _invalidInWindow++;
    if (_window.length > windowSize) {
      final removed = _window.removeAt(0);
      if (!removed) _invalidInWindow--;
    }
    if (tripped || _window.length < minSamples) return false;
    final rate = _invalidInWindow / _window.length;
    if (rate >= rateThreshold) {
      tripped = true;
      return true;
    }
    return false;
  }

  void reset() {
    _window.clear();
    _invalidInWindow = 0;
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

  /// How long the auto-reconnect pause lasts before the loop is allowed to try
  /// again (issue #208).
  ///
  /// The pause used to be permanent in practice: it is cleared ONLY inside the
  /// `createBond()` success branch, which lives inside the connect path, which
  /// the pause itself prevents from ever running again. A user who hit five
  /// refusals — a transient stack/OEM condition, not necessarily a broken bond —
  /// had auto-reconnect off for the life of the process, with the Android
  /// foreground service making sure the process never restarted to clear it.
  /// A cooldown keeps the intended behaviour (stop hammering a band that will
  /// not bond) without the dead end.
  final Duration cooldown;

  BondRefusalGiveUp({
    this.giveUpThreshold = 5,
    this.cooldown = const Duration(minutes: 30),
  });

  int _consecutive = 0;
  bool gaveUp = false;
  DateTime? _gaveUpAt;

  int get consecutive => _consecutive;

  /// When the pause was entered, or null if not paused.
  DateTime? get gaveUpAt => _gaveUpAt;

  /// Whether the auto-reconnect pause is still in force at [now]. Once the
  /// cooldown expires the latch clears itself and the streak restarts, so a
  /// band that still refuses simply re-trips after another [giveUpThreshold]
  /// refusals rather than being retried forever.
  bool stillPaused(DateTime now) {
    if (!gaveUp) return false;
    final since = _gaveUpAt;
    if (since != null && now.difference(since) >= cooldown) {
      reset();
      return false;
    }
    return true;
  }

  /// Feed a bond refusal/timeout. Returns true EXACTLY ONCE, on the call that
  /// crosses the threshold (the caller then pauses reconnect + surfaces the guide).
  bool bondRefused({DateTime? now}) {
    if (gaveUp) return false;
    _consecutive++;
    if (_consecutive >= giveUpThreshold) {
      gaveUp = true;
      _gaveUpAt = now ?? DateTime.now();
      return true;
    }
    return false;
  }

  /// A bond that succeeded (or a session that got past bonding). Clears the
  /// streak AND the give-up latch so a later refusal run can trip again.
  void bondSucceeded() => reset();

  void reset() {
    _consecutive = 0;
    gaveUp = false;
    _gaveUpAt = null;
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

// ── meta-layer: staleness escalation ─────────────────────────────────────────
/// Every mechanism above (reconnect backoff, keep-alive, periodic backfill,
/// the OS-level wake sources on both platforms) can fail in SEQUENCE with
/// nothing noticing — an aggressive OEM battery killer, a lost race between
/// background wake sources, a band left out of BLE range for days. This is
/// the top-of-the-ladder backstop: watches how long it's been since we last
/// durably banked a record (the `rec_ts_hw` cursor — the same "honest
/// frontier" RecordGate/backfill policies already trust) and escalates in
/// tiers, ultimately driving the one universal backstop on both platforms —
/// a human reopening the app.
enum StalenessTier {
  /// Recently synced — nothing to show.
  fresh,

  /// Quiet in-app signal only (no OS notification) — long enough to be
  /// worth a subtle indicator, not long enough to interrupt the user.
  quiet,

  /// Long enough that a silent failure is more likely than "just hasn't
  /// had new data" — worth an OS notification asking the user to reopen
  /// the app (the only thing that can restart every wake mechanism at once).
  notify,
}

const int kStalenessQuietSeconds = 12 * 3600; // 12h
const int kStalenessNotifySeconds = 48 * 3600; // 48h

/// Tier for [secondsSinceLastRecord] (wall-now minus the `rec_ts_hw` cursor).
/// Pure threshold lookup — callers own actually presenting the signal/
/// notification and any de-duplication/cooldown around repeated firing.
StalenessTier stalenessTierFor(int secondsSinceLastRecord) {
  if (secondsSinceLastRecord >= kStalenessNotifySeconds) {
    return StalenessTier.notify;
  }
  if (secondsSinceLastRecord >= kStalenessQuietSeconds) {
    return StalenessTier.quiet;
  }
  return StalenessTier.fresh;
}

/// Whether enough time has passed since the last staleness OS notification to
/// fire another one. Distinct from [stalenessTierFor]'s threshold: a band
/// that stays lost for a week shouldn't get a notification every single
/// background cycle (which can run every ~15 min) — but SHOULD get reminded
/// periodically rather than only once, since a single missed/dismissed
/// notification shouldn't be the only chance to recover. [renotifyAfter]
/// defaults to the same width as the notify threshold itself.
bool shouldRenotifyStaleness(
  DateTime? lastNotifiedAt,
  DateTime now, {
  Duration renotifyAfter = const Duration(seconds: kStalenessNotifySeconds),
}) {
  if (lastNotifiedAt == null) return true;
  return now.difference(lastNotifiedAt) >= renotifyAfter;
}

/// Escalation for a `TrimAckVerdict.blockedNoDurableProgress` loop.
///
/// Refusing the trim is ALWAYS the right call: echoing the token would let the
/// band delete flash we never banked, the one irreversible act in this
/// protocol. But refusing forever means sync silently stops making progress,
/// and nothing surfaced it — `EmptySyncTracker` (→ `syncClockLost`) and
/// `StuckStrapDetector` are both only evaluated in `_onOffloadFinished`, which
/// needs a HISTORY_COMPLETE that this loop never reaches, because the band
/// keeps re-delivering the same un-trimmed chunk.
///
/// Two thresholds, because there are two different questions:
///   * [remedyAfter] refusals in a row ⇒ try the remedy (SET_CLOCK + bounce).
///     The usual cause is a poisoned post-reconnect plausibility window.
///   * [giveUpAfter] remedies that did NOT work ⇒ stop assuming the next
///     SET_CLOCK will fix it and tell the user. Still never ACKs.
///
/// Counting must span RECONNECTS. The remedy IS a reconnect, so a
/// per-connection reset makes the escalation unreachable — the session is torn
/// down at streak 1 and the next connect zeroes it. Only a successful trim ACK
/// proves the condition is over ([trimAcked]).
class NoDurableProgressEscalation {
  final int remedyAfter;
  final int giveUpAfter;

  NoDurableProgressEscalation({this.remedyAfter = 3, this.giveUpAfter = 3});

  int _refusals = 0;
  int _remedies = 0;
  bool _gaveUp = false;

  int get refusals => _refusals;
  int get remedies => _remedies;
  bool get gaveUp => _gaveUp;

  /// Feed one refused HISTORY_END. Returns true when the caller should run the
  /// remedy (and resets the refusal streak so the next run needs a fresh one).
  bool trimRefused() {
    _refusals++;
    if (_refusals < remedyAfter) return false;
    _refusals = 0;
    _remedies++;
    return true;
  }

  /// True EXACTLY ONCE, on the remedy that crosses [giveUpAfter] — the caller
  /// then surfaces `syncClockLost`. Latched so it can't re-notify every cycle.
  bool shouldSurfaceGiveUp() {
    if (_gaveUp || _remedies < giveUpAfter) return false;
    _gaveUp = true;
    return true;
  }

  /// A trim ACK: records were banked and the band may advance. The only real
  /// proof the condition is over — clears the streak, the remedy count AND the
  /// give-up latch, so a later run can escalate again.
  void trimAcked() {
    _refusals = 0;
    _remedies = 0;
    _gaveUp = false;
  }
}

// ── link power policy (issue #200) ───────────────────────────────────────────

/// How aggressively to run the Android GATT link right now.
///
/// Android exposes three connection-interval presets. `high` is ~11.25 ms with
/// zero slave latency — the phone's controller services ~89 connection events a
/// second, and the host is woken for every one that carries data.
enum LinkPriority { high, balanced, lowPower }

/// Battery poll cadence. The band's battery is a DISPLAY value that moves on the
/// order of hours; nothing in the sync path depends on it. It was being read on
/// every 30 s keep-alive tick — 2,880 radio round-trips a day for a number that
/// changes a few times.
const int kBatteryPollIntervalSeconds = 300;

/// The connection priority the link should be running at.
///
/// WHY THIS EXISTS (issue #200): the engine requested `high` once, at connect
/// setup, "for the drain" — and never stepped back down. Since the connection is
/// deliberately permanent (foreground service + START_STICKY + keep-alive
/// watchdog + CDM presence relaunch), that meant an ~11.25 ms interval held 24/7,
/// including all night with nothing to say. The app also steers users into a
/// battery-optimization exemption, so Doze never damps it either. That
/// configuration — not the timers the reporter suspected — is the dominant
/// drain.
///
/// The rule: pay for a fast interval only while something is actually consuming
/// the link.
///   • an offload in flight → `high` (throughput is the whole point),
///   • a live consumer in the foreground (workout, spot check, breathing) →
///     `high`; the 100 Hz streams need the bandwidth,
///   • foreground, idle → `balanced`,
///   • background with no live consumer → `lowPower`.
///
/// SAFETY: this changes throughput, never correctness. The drain is
/// commit-before-ACK and resumes from a durable cursor, so a slower interval can
/// only make an offload take longer — and an offload always raises the priority
/// back to `high` first. The one real constraint is the liveness fuse
/// ([kLivenessFuseSeconds]): whatever interval we sit at must still let the 1 Hz
/// notify or the keep-alive response arrive inside 120 s, which `lowPower`
/// (~500 ms interval) does with three orders of magnitude to spare.
LinkPriority desiredLinkPriority({
  required bool offloadActive,
  required bool background,
  required bool hasLiveConsumer,
}) {
  if (offloadActive) return LinkPriority.high;
  if (hasLiveConsumer && !background) return LinkPriority.high;
  return background ? LinkPriority.lowPower : LinkPriority.balanced;
}

// ── reconnect supervision (issue #208) ───────────────────────────────────────

/// Why the supervisor decided to act (for logging — a silent self-heal that
/// nobody can see in a log is how this class of bug hides).
enum ReconnectSupervisorAction {
  /// Nothing to do: connected, unpaired, paused, or a loop is already running.
  none,

  /// No loop is running and we are not connected — start one.
  start,

  /// A loop has been "running" far too long with nothing to show for it; the
  /// in-flight flag is stale (an await that never returned). Clear it and start
  /// a fresh loop.
  restartStale,
}

/// Level-triggered reconnect supervision.
///
/// WHY THIS EXISTS: `_reconnect()` was EDGE-triggered — the only thing that
/// called it was the `connected → disconnected` transition. The loop itself is
/// unbounded and correct, but it sits inside one try/catch, so ANY throw inside
/// it (a foreground-lease acquisition, a claim/teardown error, a stream setup
/// failure) abandoned the loop for good. After that the engine sits at
/// 'disconnected', so the edge can never fire again, and on Android the
/// foreground service guarantees the process never restarts to clear it. That
/// is the reported "shows reconnecting, then disconnected, forever, until you
/// forget the band and re-pair".
///
/// An await that never returns produces the same dead end with the in-flight
/// flag stuck true, which no amount of re-triggering fixes — hence
/// [ReconnectSupervisorAction.restartStale].
///
/// This is the pure decision. The caller runs a timer, feeds it observations,
/// and acts on the verdict.
ReconnectSupervisorAction superviseReconnect({
  required bool paired,
  required bool keepAlive,
  required bool connected,
  required bool loopRunning,
  required bool autoReconnectPaused,

  /// Time since the CURRENT attempt started — not since the loop did. A loop
  /// legitimately runs for hours against a band left at home; an individual
  /// attempt does not.
  required Duration? attemptRunningFor,

  /// Something else is already driving a connect (a user-initiated
  /// `openSession`). Starting a second loop underneath it makes two callers
  /// race the same peripheral and re-run the whole post-connect block.
  bool connectInFlight = false,
  Duration staleAfter = const Duration(minutes: 25),
}) {
  if (!paired ||
      !keepAlive ||
      connected ||
      autoReconnectPaused ||
      connectInFlight) {
    return ReconnectSupervisorAction.none;
  }
  if (!loopRunning) return ReconnectSupervisorAction.start;
  // MUST stay comfortably above the longest legitimate single attempt. The
  // Android OS-autoConnect branch waits up to 15 minutes per pass, so a
  // threshold measured from the LOOP's start (rather than the attempt's) and
  // set at 20 minutes fired mid-way through a perfectly healthy second pass —
  // tearing down a live loop and, worse, letting the abandoned attempt's
  // eventual `disconnect()` cancel the OS pending connect the replacement was
  // waiting on. That turned the supervisor into a cause of the very
  // never-reconnects symptom it exists to cure.
  if (attemptRunningFor != null && attemptRunningFor >= staleAfter) {
    return ReconnectSupervisorAction.restartStale;
  }
  return ReconnectSupervisorAction.none;
}
