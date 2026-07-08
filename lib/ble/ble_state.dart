// Pure transport-layer logic for the BLE engine — NO flutter_blue_plus, NO I/O.
// Everything here is deterministic and unit-testable without hardware:
//   - the connection-phase state machine + its legacy string projection
//   - the reconnection backoff schedule (bounded exponential + jitter)
//   - the sequence-counter allocators (live high range / sync ACK low range)
//   - the drain stop-condition predicates
//
// Keeping this layer pure makes the race-prone transitions unit-testable
// without a real WHOOP band.

import 'dart:math';

import '../sync/sync_policy.dart' show isPlausibleUnix;

/// The explicit connection state machine. The flutter_blue_plus connection-state
/// stream is the SOURCE OF TRUTH for connected/disconnected; this enum layers the
/// app's intent + sub-phases (scan/discover/subscribe) on top of it.
///
/// SINGLE LISTENING MODE: once the link is up we subscribe → SET_CLOCK → INIT
/// (which triggers the historical flood) → then JUST KEEP LISTENING. Historical
/// records and live records arrive on the same data stream; HISTORY_END markers
/// are ACKed as they come and every record is stored. There is no longer a
/// "syncing" phase that flips to a separate "live" mode after a live-edge/idle
/// cutoff — that artificial duality caused the connected↔syncing flap and the
/// early ABORT that stopped the offload before HISTORY_COMPLETE (the cursor never
/// advanced → "Groundhog Day" re-flood on every reconnect). The collapsed phases
/// are: idle → scanning → connecting (+ discovering/subscribing/settingUp/
/// reconnecting) → listening (+ error).
enum BleConnState {
  idle,
  scanning,
  connecting,
  discovering,
  subscribing,
  settingUp,
  listening, // connected + subscribed; continuously listening (history + live)
  reconnecting,
  error,
}

/// Legacy `DeviceState.connection` string the UI still reads. Derived from the
/// phase so the public surface is unchanged. The UI distinguishes only
/// scanning / connecting / connected / disconnected — there is no separate
/// "syncing" string anymore (history streams under the single 'connected' state).
String connStringFor(BleConnState s) {
  switch (s) {
    case BleConnState.idle:
    case BleConnState.error:
      return 'disconnected';
    case BleConnState.scanning:
      return 'scanning';
    case BleConnState.connecting:
    case BleConnState.discovering:
    case BleConnState.subscribing:
    case BleConnState.settingUp:
    case BleConnState.reconnecting:
      return 'connecting';
    case BleConnState.listening:
      return 'connected';
  }
}

/// Pure reconnection schedule: bounded exponential backoff with jitter.
///
/// delay(attempt) = clamp(base * 2^(attempt-1), base, cap), then ± up to
/// `jitterFraction` of that value. `attempt` is 1-based (the first retry is 1).
/// Capped exponential backoff with jitter so a fleet of devices doesn't
/// thunder-herd a flaky radio.
class ReconnectPolicy {
  final Duration base;
  final Duration cap;
  final double jitterFraction; // 0.0..1.0
  final Random _rng;

  ReconnectPolicy({
    this.base = const Duration(seconds: 2),
    this.cap = const Duration(seconds: 30),
    this.jitterFraction = 0.2,
    Random? rng,
  }) : _rng = rng ?? Random();

  /// The deterministic (no-jitter) backoff for an attempt — used by tests to
  /// assert the schedule shape.
  Duration baseDelayFor(int attempt) {
    if (attempt < 1) attempt = 1;
    // Guard the shift against overflow on absurd attempt counts.
    final factor = attempt > 30 ? (1 << 30) : (1 << (attempt - 1));
    final ms = base.inMilliseconds * factor;
    final capped = ms > cap.inMilliseconds ? cap.inMilliseconds : ms;
    return Duration(milliseconds: capped);
  }

  /// The actual delay to wait before retry `attempt`, with jitter applied.
  Duration delayFor(int attempt) {
    final d = baseDelayFor(attempt).inMilliseconds;
    if (jitterFraction <= 0) return Duration(milliseconds: d);
    final span = (d * jitterFraction).round();
    final delta = span == 0 ? 0 : _rng.nextInt(span * 2 + 1) - span;
    final jittered = (d + delta).clamp(base.inMilliseconds, cap.inMilliseconds);
    return Duration(milliseconds: jittered);
  }
}

/// Sequence-counter allocator with the WHOOP seq discipline baked in:
///   - live commands use a HIGH range (0xA0+), wrapping back to 0xA0
///   - sync ACKs use a LOW range (5+, continuing from INIT 0..4)
/// The two ranges never collide, so a live command can never be mistaken for a
/// batch ACK (which would break the historical cursor).
class SeqAllocator {
  static const int liveFloor = 0xA0;
  static const int syncFloor = 5;

  int _live = liveFloor;
  int _sync = syncFloor;

  /// Next live-command sequence byte (0xA0..0xFF, wrapping).
  int nextLive() {
    final v = _live;
    _live = (_live + 1) & 0xFF;
    if (_live < liveFloor) _live = liveFloor;
    return v;
  }

  /// Next sync-ACK sequence byte (5..0xFF, wrapping back to 5).
  int nextSync() {
    final v = _sync;
    _sync = (_sync + 1) & 0xFF;
    if (_sync < syncFloor) _sync = syncFloor;
    return v;
  }

  /// Reset both counters (fresh connection).
  void reset() {
    _live = liveFloor;
    _sync = syncFloor;
  }
}

/// Pure historical-offload stop-condition logic.
///
/// The offload ends ONLY when:
///   - HISTORY_COMPLETE marker arrived (`complete`) — the band drained its backlog
///   - the link dropped (`linkDown`)
///   - a generous safety `timeout` elapsed (so a pathological stream can't pin the
///     radio forever)
///
/// We DELIBERATELY do NOT stop on a "live edge" (newest record near now). The band
/// offloads OLDEST-first and only emits HISTORY_COMPLETE once its flash backlog is
/// fully handed over; cutting the offload short (the old liveEdge/idle ABORT) meant
/// we ACKed only part of the backlog, the band's read cursor never reached the end,
/// and on the next connect it re-flooded the same history ("Groundhog Day").
///
/// The transport now allows one narrow abort path: if an offload goes silent for the
/// full idle watchdog window, the driver abandons the open chunk, sends
/// ABORT_HISTORICAL, waits a short settle delay, and retries. That is a recovery
/// path for a stalled drain, not a normal stop condition. Once complete, the SAME
/// subscription keeps delivering live records — there is no mode switch.
enum DrainStop { keepGoing, complete, linkDown, timeout }

class DrainStopEvaluator {
  final Duration timeout;

  const DrainStopEvaluator({this.timeout = const Duration(seconds: 600)});

  /// Evaluate against the current offload telemetry. All times in seconds.
  DrainStop evaluate({
    required bool complete,
    required bool linkDown,
    required Duration sinceStart,
  }) {
    if (complete) return DrainStop.complete;
    if (linkDown) return DrainStop.linkDown;
    if (sinceStart >= timeout) return DrainStop.timeout;
    return DrainStop.keepGoing;
  }
}

/// Pure per-record admission gate + time-frontier tracker for the historical
/// offload. ONE instance per connection; BOTH frame-processing paths (the
/// immediate path and the queued offload path) must funnel every historical
/// record through [admit] — this class existing at all is the fix for the bug
/// where the two paths drifted apart (the queued path, which real traffic
/// takes, silently lost the plausibility gate + frontier advance, so the
/// stuck-strap detector and auto-continue ran on a frozen frontier).
///
/// Responsibilities (kept together so they can never diverge again):
///   - plausibility gate: reject records whose embedded unix time is
///     implausible vs wall-clock / the strap's own GET_DATA_RANGE window
///     (a previous owner's wandering-clock pollution). Rejected records are
///     neither stored nor counted; the batch ACK still walks the cursor.
///   - frontier: track the highest plausible rec_ts admitted so far — the
///     durable high-water the StuckStrapDetector / BackfillContinuation read.
///   - drop counter: how many records the gate rejected (diagnostics).
class RecordGate {
  /// Highest plausible historical rec_ts admitted (or the seed from the
  /// durable cursor at connect, so detectors are correct on first offload).
  int frontierTs;

  /// Records rejected by the plausibility gate this connection.
  int dropped = 0;

  RecordGate({this.frontierTs = 0});

  /// Should this record be stored? Records with no decodable time ([tsEpoch]
  /// null or <= 0) are always admitted (we can't gate them) and never advance
  /// the frontier. Plausible records advance [frontierTs]; implausible ones
  /// increment [dropped] and are refused.
  bool admit(
    int? tsEpoch, {
    required int wallNow,
    int? sessionOldestUnix,
    int? sessionNewestUnix,
  }) {
    if (tsEpoch == null || tsEpoch <= 0) return true;
    if (!isPlausibleUnix(
      tsEpoch,
      wallNow,
      sessionOldestUnix: sessionOldestUnix,
      sessionNewestUnix: sessionNewestUnix,
    )) {
      dropped++;
      return false;
    }
    if (tsEpoch > frontierTs) frontierTs = tsEpoch;
    return true;
  }
}

/// Explicit, observable signal for "the band's hardware record counter went
/// backwards" — the signature of a band reboot mid-offload (its onboard
/// counter resets). Recovery already happens correctly and silently at the
/// DB layer (`decoded_onehz` REPLACE-by-rec_ts + orphan-cascade delete on the
/// evicted counter's RR beats) — this adds NO new recovery behavior, only an
/// observable event, so a regression (and any future regression in how it's
/// handled) doesn't go unnoticed the way CRC failures used to before they
/// were counted. Seed [seedCounter] from the durable `counter_hw` cursor so a
/// regression is caught even across the reconnect that a reboot itself
/// usually causes — the two events are correlated, not sequential.
class CounterRegressionDetector {
  int? _lastCounter;

  /// Regressions observed since construction (never reset by [reset] — reset
  /// only clears the last-seen counter for reseeding at a fresh connect).
  int regressions = 0;

  CounterRegressionDetector({int? seedCounter}) : _lastCounter = seedCounter;

  /// Feed the next record's raw hardware counter (u32, may wrap on a
  /// sufficiently long-running band). Returns true exactly when this counter
  /// is a genuine regression against the previous one (not benign u32
  /// wraparound near the top of the range).
  bool feed(int counter) {
    final prev = _lastCounter;
    _lastCounter = counter;
    if (prev == null || counter >= prev) return false;
    // Wraparound guard: prev near the top of u32, counter near 0 is normal
    // roll-over on an extremely long-running band, not a reboot.
    const wrapGuard = 0xFFFFFFFF - 1000000;
    if (prev >= wrapGuard && counter < 1000000) return false;
    regressions++;
    return true;
  }

  /// Re-seed for a fresh connection (does not clear the lifetime [regressions]
  /// count — that's diagnostics across the engine's lifetime).
  void reseed(int? seedCounter) {
    _lastCounter = seedCounter;
  }
}

/// Pure retry schedule for the HISTORY_END batch-ACK write.
///
/// The safe-trim invariant commits raw+samples+cursor DURABLY BEFORE the ACK,
/// so by the time the ACK write runs the data can never be lost — but if the
/// write silently FAILS the band never trims its flash and re-floods the same
/// chunk forever (a silent re-flood loop). So the ACK write is verified and
/// retried a few times with short backoff; on persistent failure the link is
/// bounced (reconnect re-delivers the chunk; decoded rows are dedup-safe via
/// the REPLACE-keyed store).
class AckRetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;

  const AckRetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
  });

  /// Whether another attempt is allowed after [failedAttempts] failures.
  bool shouldRetry(int failedAttempts) => failedAttempts < maxAttempts;

  /// Delay before retry number [attempt] (1-based; attempt 1 is the first
  /// RETRY, i.e. after the first failure). Linear backoff: base, 2×base, …
  Duration delayFor(int attempt) {
    final n = attempt < 1 ? 1 : attempt;
    return baseDelay * n;
  }
}

/// Tracks ACK-write failures per historical-batch token ACROSS RECONNECTS —
/// a chunk whose ACK keeps failing for the SAME token (the "Groundhog Day"
/// re-flood signature: the band never trims, so it re-sends the identical
/// batch next session) is a persistent, diagnosable problem distinct from a
/// one-off bounce. Pure counter + threshold; the caller owns actually
/// writing to sync_ledger/sync_quarantine and bouncing the link — which
/// already happens regardless of this class, since the data is safe either
/// way (durably committed before the ACK was ever attempted). This only adds
/// visibility into a chunk that's stuck, where previously nothing recorded
/// that the SAME token had failed before.
class ChunkFailureLedger {
  final int quarantineThreshold;
  ChunkFailureLedger({this.quarantineThreshold = 3});

  final Map<String, int> _failures = {};

  /// Record another ACK failure for [tokenHex]. Returns the new failure count.
  int recordFailure(String tokenHex) {
    final n = (_failures[tokenHex] ?? 0) + 1;
    _failures[tokenHex] = n;
    return n;
  }

  /// Current failure count for [tokenHex] (0 if never failed / already cleared).
  int failureCount(String tokenHex) => _failures[tokenHex] ?? 0;

  /// Whether [tokenHex] has just crossed the quarantine threshold.
  bool shouldQuarantine(String tokenHex) =>
      (_failures[tokenHex] ?? 0) >= quarantineThreshold;

  /// Clear tracking for [tokenHex] once it finally ACKs successfully.
  void recordSuccess(String tokenHex) {
    _failures.remove(tokenHex);
  }
}

/// Pure debounce/coalesce logic for the "new data stored → derive" trigger.
///
/// With continuous listening there is no discrete "sync done" signal, so we can't
/// fire the DerivationEngine off a SyncReport anymore. Instead, every time records
/// are persisted we mark them as dirty; once the inbound record stream goes quiet
/// for [quietPeriod] (or [maxWait] elapses since the first un-derived record so a
/// never-quiet stream still derives periodically) a derive is scheduled, coalescing
/// the burst into a single pass. Pure + deterministic so it's unit-testable without
/// timers — the engine drives it with wall-clock reads.
class DeriveDebouncer {
  final Duration staleQuietPeriod;
  final Duration staleMaxWait;
  final Duration freshQuietPeriod;
  final Duration freshMaxWait;
  final Duration staleThreshold;

  const DeriveDebouncer({
    this.staleQuietPeriod = const Duration(seconds: 12),
    this.staleMaxWait = const Duration(seconds: 90),
    this.freshQuietPeriod = const Duration(minutes: 1),
    this.freshMaxWait = const Duration(minutes: 5),
    this.staleThreshold = const Duration(minutes: 30),
  });

  /// Should we derive now, given the pending-record bookkeeping?
  ///   [hasPending]       — records persisted since the last derive
  ///   [sinceLastRecord]  — how long since the most recent persisted record
  ///   [sinceFirstPending]— how long since the first record of the current dirty run
  bool shouldDerive({
    required bool hasPending,
    required Duration sinceLastRecord,
    required Duration sinceFirstPending,
    required Duration dataStaleness,
  }) {
    if (!hasPending) return false;
    final staleMode = dataStaleness >= staleThreshold;
    final quietPeriod = staleMode ? staleQuietPeriod : freshQuietPeriod;
    final maxWait = staleMode ? staleMaxWait : freshMaxWait;
    if (sinceLastRecord >= quietPeriod) return true; // stream went quiet
    if (sinceFirstPending >= maxWait) return true; // never-quiet floor
    return false;
  }
}

/// Pure builders for the on-device wake-alarm command PAYLOADS (the inner body
/// AFTER the opcode byte). The engine wraps these in a frame via its `_send`;
/// keeping the exact byte layout here makes it unit-testable without a real band.
///
/// Alarm opcodes: SET_ALARM_TIME 0x42, GET_ALARM_TIME 0x43, RUN_ALARM 0x44,
/// DISABLE_ALARM 0x45. The RICH SET form (a haptic waveform + time) is the one
/// that actually FIRES on WHOOP 4.0; the SHORT time-only form is ACKed but never
/// buzzes (no waveform to play).
class AlarmPayloads {
  /// The strap's stock 12-byte wake-buzz haptic pattern:
  ///   [0..7]  eight waveform-effect slots (two active: 47, 152; six idle)
  ///   [8..9]  u16 per-effect loop control (LE) = 0
  ///   [10]    overall-waveform loop count = 7
  ///   [11]    max alarm duration in seconds = 30
  static const List<int> defaultHaptics = <int>[
    47, 152, 0, 0, 0, 0, 0, 0, // waveform-effect slots
    0, 0, //                       loop control (u16 LE)
    7, //                          overall loop
    30, //                         duration seconds
  ];

  /// Sub-seconds in 1/32768 s units (the 32768 Hz RTC crystal), 0..32767.
  static int subsecOf(DateTime when) =>
      ((when.millisecondsSinceEpoch % 1000) * 32768) ~/ 1000;

  /// RICH 20-byte SET_ALARM_TIME payload — the form that actually fires:
  /// `[0x04][u8 index][u32 epoch-sec LE][u16 subsec LE][12-byte haptic pattern]`.
  static List<int> rich(DateTime when, {int index = 0, List<int>? haptics}) {
    final ms = when.millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final subsec = subsecOf(when);
    final pattern = haptics ?? defaultHaptics;
    assert(pattern.length == 12, 'alarm haptic pattern must be 12 bytes');
    return <int>[
      0x04,
      index & 0xff,
      sec & 0xff,
      (sec >> 8) & 0xff,
      (sec >> 16) & 0xff,
      (sec >> 24) & 0xff,
      subsec & 0xff,
      (subsec >> 8) & 0xff,
      ...pattern.map((b) => b & 0xff),
    ];
  }

  /// SHORT 7-byte time-only SET_ALARM_TIME payload (ACKs but does NOT fire):
  /// `[0x01][u32 epoch-sec LE][u16 subsec LE]`.
  static List<int> simple(DateTime when) {
    final ms = when.millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final subsec = subsecOf(when);
    return <int>[
      0x01,
      sec & 0xff,
      (sec >> 8) & 0xff,
      (sec >> 16) & 0xff,
      (sec >> 24) & 0xff,
      subsec & 0xff,
      (subsec >> 8) & 0xff,
    ];
  }

  /// RUN_ALARM (0x44) body — fire the haptics immediately ("test buzz").
  static const List<int> runNow = <int>[0x01];

  /// DISABLE_ALARM (0x45) body — cancel the on-device alarm.
  static const List<int> disable = <int>[0x01];
}

/// Effect of a strap alarm-lifecycle event, for the caller to act on.
enum AlarmEffect { confirmed, fired, cleared }

/// Pure state machine for alarm CONFIRMATION, driven by the strap's own event
/// stream. This replaces the parked (and wrong) GET_ALARM readback as the display
/// truth: instead of guessing whether an alarm latched, the strap tells us.
///   - [set] after a SET write → not confirmed, timer starts (PENDING)
///   - event 56 (ALARM_SET) → [confirmed] = true
///   - no 56 within the grace window → UNCONFIRMED (soft warning)
///   - event 57/58 (EXECUTED) → fired ([firedAt] set)
///   - event 59 (DISABLED) → cleared
/// I/O-free + deterministic (caller supplies `nowMs`) so it is fully unit-testable.
class AlarmConfirmation {
  // Strap alarm-lifecycle event ids (match the protocol EventId values).
  static const int kEvtSet = 56;
  static const int kEvtStrapExecuted = 57;
  static const int kEvtAppExecuted = 58;
  static const int kEvtDisabled = 59;
  static const int kEvtHapticsFired = 60;

  final int graceMs;
  AlarmConfirmation({this.graceMs = 6000});

  int? targetEpoch; // the scheduled wake time (unix sec), or null when off
  bool confirmed = false; // strap emitted ALARM_SET (56)
  int? setAtMs; // wall-ms of the SET write (for the grace window)
  int? lastEventId; // most recent alarm event seen
  int? firedAt; // wall-ms of the last EXECUTED event

  /// Record a SET write (awaiting the strap's confirmation event).
  void set(int epoch, int nowMs) {
    targetEpoch = epoch;
    confirmed = false;
    setAtMs = nowMs;
  }

  /// Record an explicit disable/clear.
  void disable() {
    targetEpoch = null;
    confirmed = false;
    setAtMs = null;
  }

  /// SET written but not yet confirmed AND still inside the grace window.
  bool isPending(int nowMs) =>
      targetEpoch != null &&
      !confirmed &&
      setAtMs != null &&
      nowMs - setAtMs! < graceMs;

  /// Set but neither confirmed nor still pending — the soft-warning state.
  bool isUnconfirmed(int nowMs) =>
      targetEpoch != null && !confirmed && !isPending(nowMs);

  /// Feed a strap event. Returns the resulting [AlarmEffect] the caller acts on,
  /// or null when the event is unrelated to the alarm.
  AlarmEffect? onEvent(int id, int nowMs) {
    switch (id) {
      case kEvtSet:
        confirmed = true;
        lastEventId = id;
        return AlarmEffect.confirmed;
      case kEvtStrapExecuted:
      case kEvtAppExecuted:
        lastEventId = id;
        firedAt = nowMs;
        return AlarmEffect.fired;
      case kEvtDisabled:
        confirmed = false;
        targetEpoch = null;
        setAtMs = null;
        lastEventId = id;
        return AlarmEffect.cleared;
      default:
        return null;
    }
  }
}
