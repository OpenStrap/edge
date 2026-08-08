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
///     neither stored nor counted. A burst that banks at least one durable
///     row may still ACK (cursor walks past mixed pollution); a drop-only
///     empty burst must NOT ACK — see [TrimAckVerdict.blockedNoDurableProgress].
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

/// Why an in-flight HISTORY_END token may (or may not) be echoed back to the
/// band. See [TrimAckPolicy].
enum TrimAckVerdict {
  /// Every precondition holds — echo the verbatim 8-byte token.
  send,

  /// The session that received this HISTORY_END is no longer the engine's
  /// current session (the link dropped / was replaced while the handler was
  /// parked mid-await). Writing now would put an OLD connection's token, with
  /// a re-used sync seq, onto a BRAND NEW link — and a failed write would tear
  /// down the healthy new session.
  blockedStaleSession,

  /// The burst this token terminates had its buffered records DISCARDED
  /// without ever being committed (idle watchdog / abort-and-retry). Its
  /// straggler terminal is still in flight; echoing it would trim flash we
  /// deliberately threw away.
  blockedDiscardedBurst,

  /// The durable commit did NOT complete. The records are not in the database,
  /// so the band must keep them.
  blockedCommitFailed,

  /// This burst's HISTORY_END would trim flash we neither decoded nor archived:
  /// the plausibility gate rejected every historical record (`droppedThisBurst >
  /// 0`) and the buffer is empty. Echoing the token used to "walk the cursor"
  /// past wandering-clock pollution, but after a reconnect / bad session window
  /// the same path permanently deleted good samples (HR frozen until a manual
  /// reconnect). Refuse the trim so the band re-delivers; the engine should
  /// re-correlate the clock and retry.
  blockedNoDurableProgress,
}

/// THE gate on the one irreversible act in the whole offload protocol: echoing
/// a HISTORY_END continuation token, which is what tells the band it may trim
/// that chunk out of its flash.
///
/// The safe-trim invariant is "every row is durable BEFORE the caller echoes
/// the HISTORY_END trim token, or none is". Historically only the HAPPY path
/// honoured it: the commit's exception was swallowed and the caller ACKed
/// regardless, so a failed transaction (a real production OOM inside
/// `commitSyncBatch` — see `lib/data/db.dart`) meant the buffer had already
/// been cleared, the transaction had rolled back, the cursor had not advanced,
/// and the band was then told to trim — those records existed nowhere,
/// permanently and silently.
///
/// Pure and total: the engine supplies observations, this decides. The
/// engine must call it AGAIN after the commit await (the commit can take
/// seconds on a large batch — long enough for the session to die under it).
class TrimAckPolicy {
  const TrimAckPolicy._();

  /// [sessionCurrent]  — the receiving session is still the engine's session
  ///                     AND still connected.
  /// [burstDiscarded]  — this burst's open chunk was discarded un-committed.
  /// [commitDurable]   — the atomic commit completed (pass `true` when asking
  ///                     the pre-commit question "should I even commit this
  ///                     token?").
  /// [hadDurableRows]  — this burst buffered at least one raw/sample or archive
  ///                     row to bank before ACK. Pass `true` when unknown
  ///                     (pre-commit stale/discard checks only).
  /// [droppedThisBurst] — RecordGate rejects during this burst. Combined with
  ///                     `!hadDurableRows`, refuses trim so gate-only bursts
  ///                     cannot delete flash we never stored.
  static TrimAckVerdict evaluate({
    required bool sessionCurrent,
    required bool burstDiscarded,
    required bool commitDurable,
    bool hadDurableRows = true,
    int droppedThisBurst = 0,
  }) {
    // Order is deliberate: a stale session must be refused before anything
    // else touches the (new) link, and a poisoned burst must be refused before
    // the commit result is even considered — its records are already gone.
    if (!sessionCurrent) return TrimAckVerdict.blockedStaleSession;
    if (burstDiscarded) return TrimAckVerdict.blockedDiscardedBurst;
    if (!commitDurable) return TrimAckVerdict.blockedCommitFailed;
    if (!hadDurableRows && droppedThisBurst > 0) {
      return TrimAckVerdict.blockedNoDurableProgress;
    }
    return TrimAckVerdict.send;
  }
}

/// Per-burst poison latch for [TrimAckVerdict.blockedDiscardedBurst].
///
/// The idle watchdog abandons the open chunk (N buffered, never-committed
/// records) on the contract "the band re-delivers them next offload", and the
/// abort path then sends ABORT_HISTORICAL. But that burst's HISTORY_END is
/// ALREADY in flight and arrives anyway — and nothing stopped the handler from
/// committing an empty buffer and echoing the token verbatim, which trims
/// exactly the records that were just thrown away. The token is unknown at
/// discard time (it only arrives with the terminal), so the poison is keyed to
/// the BURST, not the token: a discard poisons the open burst, and only a
/// fresh HISTORY_START / re-arm clears it.
class BurstTrimGuard {
  bool _discarded = false;

  /// Bursts poisoned since construction (diagnostics — a rising count means
  /// the drain keeps stalling mid-burst).
  int poisonedBursts = 0;

  /// True while the open burst may NOT be trimmed.
  bool get discarded => _discarded;

  /// A fresh burst begins (HISTORY_START / re-arm) — nothing lost yet.
  void beginBurst() => _discarded = false;

  /// The open chunk was abandoned without a durable commit.
  void discardOpenChunk() {
    if (_discarded) return;
    _discarded = true;
    poisonedBursts++;
  }
}

/// What a link-down must do to the session that just died.
enum LinkDownAction {
  /// Cancel every timer + subscription the session owns, then surface `idle`.
  tearDownSession,

  /// The event belongs to a session we already replaced — ignore it entirely.
  ignoreStaleSession,
}

/// A dropped link used to only flip a flag and surface the phase; the actual
/// teardown happened solely on the NEXT connect()/disconnect(). When
/// [BondRefusalGiveUp] trips, the app pauses auto-reconnect and never calls
/// disconnect() — so the dead session's five timers (heartbeat, keep-alive,
/// periodic backfill, idle watchdog, historical retry) kept firing forever and
/// its four `onValueReceived` subscriptions stayed registered, one more full
/// set leaked per drop.
class LinkDownPolicy {
  const LinkDownPolicy._();

  static LinkDownAction evaluate({required bool sessionIsCurrent}) =>
      sessionIsCurrent
          ? LinkDownAction.tearDownSession
          : LinkDownAction.ignoreStaleSession;
}

/// Outcome of a process-wide single-owner band claim.
enum BandClaimDecision {
  /// Take the claim (nobody holds it, or the incumbent's claim is stale).
  claim,

  /// A live foreground owner exists and we are the background drainer —
  /// don't touch the band this cycle.
  yieldToOwner,

  /// A live background owner exists and we are foreground — drop its link
  /// (awaited) and then take the claim.
  preemptThenClaim,
}

/// Pure arbitration for the process-wide single-owner guard.
///
/// The claim used to be tested for NON-NULLNESS only, and was taken BEFORE the
/// link was up and released only by an explicit `disconnect()`. So a connect
/// that threw left the claim pointing at an engine with no link, forever: a
/// later iOS restore wake spun up a background drainer, saw a non-null owner,
/// yielded, and reported "strap not reachable this cycle" for the rest of the
/// process lifetime. [incumbentLive] is the fix — a claim held by an engine
/// with no session is not a claim.
class BandClaimPolicy {
  const BandClaimPolicy._();

  static BandClaimDecision decide({
    required bool incumbentPresent,
    required bool incumbentLive,
    required bool isBackgroundDrainer,
  }) {
    if (!incumbentPresent) return BandClaimDecision.claim;
    if (!incumbentLive) return BandClaimDecision.claim;
    if (isBackgroundDrainer) return BandClaimDecision.yieldToOwner;
    return BandClaimDecision.preemptThenClaim;
  }
}

/// Where an inbound reassembled frame is processed.
enum FrameRoute {
  /// The single serialized offload queue (`_offloadFrames`), so history
  /// records and their terminals are handled strictly in arrival order by ONE
  /// loop.
  serializedQueue,

  /// Handled inline (command responses, events, live high-rate frames).
  immediate,
}

/// Pure routing decision for [FrameRoute].
///
/// Metadata (HISTORY_START / HISTORY_END / HISTORY_COMPLETE) used to reach the
/// serialized queue only when it arrived on the `data` characteristic;
/// metadata reassembled on `cmd_from`/`events` was fired unawaited on the
/// immediate path instead — the one route that could run a HISTORY_END handler
/// CONCURRENTLY with the queued drain, i.e. two handlers racing on the same
/// drain controller (one snapshots an empty buffer and can ACK before the
/// other's commit is durable). Metadata now always takes the queue.
class FrameRoutePolicy {
  const FrameRoutePolicy._();

  static FrameRoute route({
    required bool isMetadata,
    required bool isHistorical,
    required bool isDataRole,
  }) {
    if (isMetadata) return FrameRoute.serializedQueue;
    if (isHistorical && isDataRole) return FrameRoute.serializedQueue;
    return FrameRoute.immediate;
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
/// Whether band records are landing RIGHT NOW.
///
/// Answers the TestFlight report "don't get to know if syncing is happening or
/// not" without adding a spinner: records arrive in bursts with gaps, so the
/// answer has to hold for a moment after each batch or an indicator would
/// strobe — and it has to expire, or a finished drain would look like a running
/// one forever.
///
/// Pure, so the window is testable without a band or a clock.
class SyncActivityWindow {
  SyncActivityWindow({this.windowMs = 6000});

  /// How long one batch keeps the answer true.
  final int windowMs;

  int _lastMs = 0;

  /// Records just landed.
  void mark(int nowMs) => _lastMs = nowMs;

  /// True while the last batch is still within [windowMs].
  bool isActive(int nowMs) => _lastMs > 0 && nowMs - _lastMs < windowMs;

  /// When the current window closes, or null if nothing has arrived.
  int? expiresAtMs() => _lastMs > 0 ? _lastMs + windowMs : null;
}

/// Steps accrued since LOCAL MIDNIGHT, from a counter that counts since the BLE
/// connection began.
///
/// The Today tile shows `derived day total + live session steps`, and the live
/// half is "since this connection started". This app deliberately holds ONE
/// continuous connection — the whole engine is built around never dropping it —
/// so that counter routinely spans midnight, and at 00:01 the tile showed
/// yesterday's steps plus today's and kept climbing from there. Reported from
/// TestFlight as "steps and calories are not resetting every day, it's
/// accumulating".
///
/// Rebasing at the day boundary is the fix: steps taken before midnight belong
/// to yesterday, and yesterday's derived total already contains them.
///
/// Pure so the boundary behaviour is testable without a clock or a band.
class LiveStepDayWindow {
  String? _day;
  int _base = 0;

  /// [sessionTotal] is the connection-lifetime count; [today] is the local day
  /// label. Returns what belongs to [today].
  int stepsToday(int rawSessionTotal, String today) {
    // A counter cannot be negative. Letting one through would seat `_base`
    // below zero, and the next ordinary reading would then report the
    // difference as steps that were never taken.
    final sessionTotal = rawSessionTotal > 0 ? rawSessionTotal : 0;
    if (_day == null) {
      // First observation. The session counter is per-connection and per-
      // process, so whatever it holds now was walked during this session — on
      // this day. Rebasing here instead would DISCARD a real walk, which is
      // what the live-coverage tests caught.
      _day = today;
      _base = 0;
    } else if (_day != today) {
      // A day boundary crossed while this window was watching: everything the
      // counter holds belongs to the day that just ended.
      _day = today;
      _base = sessionTotal;
    }
    // A reconnect zeroes the session counter. Without this the stale, larger
    // base would make every subsequent reading negative — clamped to 0 below,
    // so a walk after a reconnect on the same day would silently stop counting.
    if (sessionTotal < _base) _base = sessionTotal;
    final n = sessionTotal - _base;
    return n > 0 ? n : 0;
  }

  /// The day this window is currently based on — null until first use.
  ///
  /// Kept current from the SAMPLE path, not just from the widget that displays
  /// it: a phone parked on another tab across midnight would otherwise make its
  /// first post-midnight read the first observation of any day, and count
  /// yesterday's whole session as today's.
  String? get day => _day;
}

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
  final Duration foregroundQuietPeriod;
  final Duration foregroundMaxWait;

  const DeriveDebouncer({
    this.staleQuietPeriod = const Duration(seconds: 12),
    this.staleMaxWait = const Duration(seconds: 90),
    this.freshQuietPeriod = const Duration(minutes: 1),
    this.freshMaxWait = const Duration(minutes: 5),
    this.staleThreshold = const Duration(minutes: 30),
    // A THIRD tier, independent of data staleness: while the app is in the
    // foreground, a human is plausibly staring at the screen waiting for
    // their just-synced number. The fresh-mode tier's whole rationale (avoid
    // paying compute/battery cost for every trickle of ambient live data) is
    // moot when the screen is already on — the cost of deriving sooner is
    // the same either way, only the WAIT changes. Without this, the exact
    // moment a catch-up sync's data staleness drops below staleThreshold
    // (i.e. records finally reach "now" — precisely what the user is
    // waiting on) is also the moment the debounce flips to its SLOWEST
    // tier. This tier takes priority over fresh/stale whenever foreground.
    this.foregroundQuietPeriod = const Duration(seconds: 5),
    this.foregroundMaxWait = const Duration(seconds: 15),
  });

  /// Should we derive now, given the pending-record bookkeeping?
  ///   [hasPending]       — records persisted since the last derive
  ///   [sinceLastRecord]  — how long since the most recent persisted record
  ///   [sinceFirstPending]— how long since the first record of the current dirty run
  ///   [isForeground]     — the app is actively in the foreground right now;
  ///                        takes priority over the fresh/stale staleness
  ///                        tiers when true (see foregroundQuietPeriod doc)
  bool shouldDerive({
    required bool hasPending,
    required Duration sinceLastRecord,
    required Duration sinceFirstPending,
    required Duration dataStaleness,
    bool isForeground = false,
  }) {
    if (!hasPending) return false;
    Duration quietPeriod;
    Duration maxWait;
    if (isForeground) {
      quietPeriod = foregroundQuietPeriod;
      maxWait = foregroundMaxWait;
    } else {
      final staleMode = dataStaleness >= staleThreshold;
      quietPeriod = staleMode ? staleQuietPeriod : freshQuietPeriod;
      maxWait = staleMode ? staleMaxWait : freshMaxWait;
    }
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

  /// Convert a WALL-CLOCK alarm target into the strap's own RTC frame.
  ///
  /// The strap runs the wake alarm autonomously and fires when ITS RTC reaches
  /// the armed epoch — so the epoch we send must be in the strap's clock frame,
  /// not ours. If SET_CLOCK never latched (some firmware rejects the payload) the
  /// strap RTC is offset from wall time; arming the raw wall epoch then fires at
  /// the wrong strap-time, or effectively NEVER (a raw 2026 epoch is decades in
  /// the future of a strap clock still near its factory epoch). This is why an
  /// immediate RUN_ALARM buzz works but a scheduled alarm never fires.
  ///
  /// [driftSec] is `wall - device` from the GET_CLOCK correlation (positive when
  /// the strap RTC is BEHIND wall). At wall-time `W` the strap RTC reads
  /// `W - driftSec`, so we shift the target back by the drift; the sub-second part
  /// is preserved (whole-second shift). Pass `0` when uncorrelated to arm the raw
  /// wall epoch unchanged.
  static DateTime toStrapFrame(DateTime when, int driftSec) =>
      when.subtract(Duration(seconds: driftSec));
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
