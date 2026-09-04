// Pure transport-layer logic for the BLE engine — NO flutter_blue_plus, NO I/O.
// Everything here is deterministic and unit-testable without hardware:
//   - the connection-phase state machine + its legacy string projection
//   - the reconnection backoff schedule (bounded exponential + jitter)
//   - the sequence-counter allocators (live high range / sync ACK low range)
//   - the drain stop-condition predicates
//
// Keeping this layer pure makes the race-prone transitions unit-testable
// without a real WHOOP band.

import 'dart:async';
import 'dart:math';

// Pure byte-layer package (zero deps, no I/O) — purity of this file holds.
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show alarmRev1Payload;

import '../sync/sync_policy.dart' show isPlausibleUnix, kMinPlausibleUnix;

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

// ── what the user is told ────────────────────────────────────────────────────
// The engine already knows, precisely, why a link is not working — six flags on
// DeviceState plus the phone-level blockers below. It used to keep that to
// itself and hand the UI a four-value connection string, so every distinct
// failure rendered as "Not connected" (or, worse, as "No band in range", which
// sends a user who revoked a permission on a walk around the house). This is
// the single projection a screen renders instead: one condition, a name, a
// reason, and a way forward.

/// The phone's own Bluetooth stack refusing us, as opposed to a band that is
/// simply not answering. Deliberately separate from every band-side flag: the
/// fixes point in opposite directions (Settings vs. walk closer), so conflating
/// them guarantees the user follows the wrong one.
enum BleBlocker {
  /// The OS is withholding Bluetooth from THIS app (iOS `unauthorized`, Android
  /// BLUETOOTH_SCAN/CONNECT denied). Only Settings clears it.
  permissionDenied,

  /// The radio itself is off. Every app is equally stuck.
  adapterOff,

  /// No BLE radio on this device at all. Nothing to fix.
  unsupported,
}

/// Thrown by transport calls that never reached the radio. Distinct from
/// "returned nothing", which means the scan genuinely ran and heard nothing.
class BleUnavailableException implements Exception {
  final BleBlocker blocker;
  const BleUnavailableException(this.blocker);

  @override
  String toString() => 'BleUnavailableException(${blocker.name})';
}

/// Map an adapter-state name and/or a thrown transport error onto a blocker.
/// Returns null when neither says the stack is unusable — i.e. the failure is
/// about the band, not the phone.
///
/// String matching is unavoidable: flutter_blue_plus surfaces the Android
/// permission refusal as a platform exception whose text is the only signal.
/// The adapter state is checked first because it is the reliable one.
BleBlocker? classifyBleBlocker({String? adapterState, Object? error}) {
  switch (adapterState) {
    case 'unauthorized':
      return BleBlocker.permissionDenied;
    case 'unavailable':
      return BleBlocker.unsupported;
    case 'off':
    case 'turningOff':
      return BleBlocker.adapterOff;
  }
  if (error == null) return null;
  final s = error.toString().toLowerCase();
  if (s.contains('unauthorized') ||
      s.contains('permission') ||
      s.contains('not authorized') ||
      s.contains('denied')) {
    return BleBlocker.permissionDenied;
  }
  if (s.contains('adapter is off') ||
      s.contains('bluetooth must be turned on') ||
      s.contains('poweredoff') ||
      s.contains('powered off')) {
    return BleBlocker.adapterOff;
  }
  if (s.contains('unsupported') || s.contains('not supported')) {
    return BleBlocker.unsupported;
  }
  return null;
}

/// Whether an unintentional disconnect looks like the link TIMING OUT — the
/// band stopped answering / went out of range — rather than an ordinary
/// termination (peer closed the link, local close, adapter off).
///
/// [MarginalRadioDetector] and [PostBondTimeoutLoopDetector] both key on
/// "armed/bonded, then a QUICK TIMEOUT", and both used to be handed a
/// hardcoded `true`, which made every ordinary drop a timeout: two unremarkable
/// disconnects inside 8 s of setup were enough to latch the re-pair guide, on
/// iOS as well as Android.
///
/// The platform's own reason string is the only timeout evidence we have, and
/// it says so in words on both: Android reports HCI/GATT names
/// (`LINK_SUPERVISION_TIMEOUT`, `GATT_CONNECTION_TIMEOUT`, …), iOS the CBError
/// `localizedDescription` ("The connection has timed out unexpectedly."). Same
/// string-matching trade as [classifyBleBlocker], for the same reason. No
/// reason reported ⇒ NOT a timeout: we never assume one we cannot see.
bool isTimeoutDisconnect(String? reasonDescription) {
  final s = reasonDescription?.toLowerCase();
  if (s == null) return false;
  return s.contains('timeout') || s.contains('timed out');
}

/// The one connection state a screen renders. Ordered by priority in
/// [bandStatusFor], most-blocking first.
enum BandCondition {
  bluetoothDenied,
  bluetoothOff,
  bluetoothUnsupported,

  /// Bond refused repeatedly ⇒ auto-reconnect is PAUSED. Nothing is retrying.
  reconnectPaused,

  /// The link comes up but the band rejects the encryption key.
  repairNeeded,

  /// A batch is stuck un-confirmed and the band keeps re-sending it.
  syncStuck,

  /// The band holds newer data than it will hand over.
  strapUnresponsive,

  /// Syncs complete carrying no sensor data — the band's clock has lost sync.
  clockLost,

  connected,
  connecting,
  scanning,
  disconnected,
}

/// A named connection state with the copy that goes with it. The copy lives
/// here, not in the UI, so the mapping is unit-testable and every surface that
/// shows the link (home, devices, pairing, a background notification) says the
/// same thing about the same state.
class BandStatus {
  final BandCondition condition;

  /// Names the state. Never "Something went wrong".
  final String title;

  /// Why it is in that state, and what it means for the user's data.
  final String reason;

  /// The way forward, or null when there is genuinely nothing to do.
  final String? fix;

  /// Set only for [BandCondition.reconnectPaused] — the count already baked
  /// into [reason]'s English text, carried separately so a UI layer can
  /// re-render the reason in another language without re-parsing it.
  final int? bondRefusals;

  const BandStatus(this.condition, this.title, this.reason,
      {this.fix, this.bondRefusals});

  /// True for the states that need to be shown. The four ordinary link states
  /// (connected/connecting/scanning/disconnected) are the app's normal
  /// vocabulary and do not need a failure card.
  bool get isFault =>
      condition != BandCondition.connected &&
      condition != BandCondition.connecting &&
      condition != BandCondition.scanning &&
      condition != BandCondition.disconnected;
}

/// Fold the phone-level blocker and the band's own diagnostic flags into one
/// state. Pure; [connection] is `DeviceState.connection`.
///
/// Priority is linear and deliberate: a blocker defeats everything (nothing can
/// run), a paused reconnect outranks the flags it caused, and the data-flow
/// flags outrank the plain link state because "not connected" is the less
/// useful of the two true statements.
BandStatus bandStatusFor({
  required String connection,
  BleBlocker? blocker,
  bool autoReconnectPaused = false,
  bool needsRepairGuide = false,
  bool syncChunkQuarantined = false,
  bool strapNeedsReboot = false,
  bool syncClockLost = false,
  int bondRefusals = 0,
}) {
  const repairFix = 'Forget the band in the phone’s Bluetooth settings, '
      'then pair it again here';
  switch (blocker) {
    case BleBlocker.permissionDenied:
      return const BandStatus(
        BandCondition.bluetoothDenied,
        'Bluetooth is switched off for this app',
        'The phone is withholding the Bluetooth radio from OpenStrap, so '
            'nothing can be scanned or connected. This is not the band — '
            'walking closer to it will not help.',
        fix: 'Open Settings → OpenStrap and allow Bluetooth',
      );
    case BleBlocker.adapterOff:
      return const BandStatus(
        BandCondition.bluetoothOff,
        'Bluetooth is turned off',
        'The phone’s radio is off, so the band cannot be reached by any app. '
            'The band keeps recording meanwhile; nothing is lost.',
        fix: 'Turn Bluetooth on',
      );
    case BleBlocker.unsupported:
      return const BandStatus(
        BandCondition.bluetoothUnsupported,
        'This phone has no Bluetooth Low Energy radio',
        'The band can only be reached over Bluetooth Low Energy. Imported '
            'data still works; a live link does not.',
      );
    case null:
      break;
  }
  if (autoReconnectPaused) {
    return BandStatus(
      BandCondition.reconnectPaused,
      'Reconnecting has been paused',
      'The band refused the pairing key $bondRefusals times in a row, so the '
          'app stopped retrying rather than pin the radio and drain both '
          'batteries on a link that will not open. Nothing is reconnecting '
          'until you act.',
      fix: repairFix,
      bondRefusals: bondRefusals,
    );
  }
  if (needsRepairGuide) {
    return const BandStatus(
      BandCondition.repairNeeded,
      'The band needs to be paired again',
      'The link comes up, but the band rejects the encryption key the phone '
          'holds, so every command is dropped and no data moves. Your '
          'recordings are safe on the band.',
      fix: repairFix,
    );
  }
  if (syncChunkQuarantined) {
    return const BandStatus(
      BandCondition.syncStuck,
      'One batch of recordings will not finish transferring',
      'The band keeps re-sending the same batch because the app cannot get '
          'its confirmation through. Everything in it is already saved here — '
          'nothing is lost — but the band cannot move on until the '
          'confirmation lands.',
      fix: 'Reconnect the band; if it repeats tomorrow, pair it again',
    );
  }
  if (strapNeedsReboot) {
    return const BandStatus(
      BandCondition.strapUnresponsive,
      'The band has stopped handing over its recordings',
      'The band reports newer recordings than it will send. Those recordings '
          'are still on the band and still safe; it just is not passing them '
          'across.',
      fix: 'Put the band on its charger for a minute, then reconnect',
    );
  }
  if (syncClockLost) {
    return const BandStatus(
      BandCondition.clockLost,
      'Syncs are finishing with no data in them',
      'The band completes each sync without handing over a single sensor '
          'reading, which almost always means its onboard clock has lost '
          'sync. The app keeps resetting it on every connect.',
      fix: 'Leave the band connected for a few minutes; if nothing arrives '
          'by tomorrow, pair it again',
    );
  }
  switch (connection) {
    case 'connected':
      return const BandStatus(
        BandCondition.connected,
        'Connected',
        'The band is linked and handing over its recordings.',
      );
    case 'connecting':
      return const BandStatus(
        BandCondition.connecting,
        'Connecting',
        'Opening the link to the band.',
      );
    case 'scanning':
      return const BandStatus(
        BandCondition.scanning,
        'Looking for the band',
        'Listening for the band to advertise itself.',
      );
    default:
      return const BandStatus(
        BandCondition.disconnected,
        'Not connected',
        'The band is out of range, on its charger, or held by another app. '
            'It keeps recording either way.',
        fix: 'Bring the band near the phone, and close any other app '
            'connected to it',
      );
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

  /// Of [dropped], the ones that failed the ABSOLUTE floor
  /// (`ts < kMinPlausibleUnix`) rather than the future or session-window tests.
  /// The two have opposite prognoses: an unset or wandering RTC drifts back
  /// into range (or SET_CLOCK pulls it back), while a source whose time base is
  /// not a wall-clock epoch at all never will. Counted, never acted on — the
  /// gate's verdict is identical either way, and must stay so.
  int droppedBelowFloor = 0;

  RecordGate({this.frontierTs = 0});

  /// True when this connection rejected records and EVERY rejection was below
  /// the absolute floor — the signature of a source that does not stamp
  /// wall-clock time (uptime-since-boot, a sequence number, milliseconds).
  ///
  /// Worth reporting apart from a transient clock problem because the stall is
  /// PERMANENT: no retry, reconnect or SET_CLOCK resolves it, and the visible
  /// symptom (records seen, nothing banked, the chunk re-delivered forever) is
  /// identical to the transient case. See the `kMinPlausibleUnix` assumption
  /// block in `sync_policy.dart` for the upgrade path.
  bool get timeBaseNotWallClock => dropped > 0 && dropped == droppedBelowFloor;

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
      if (tsEpoch < kMinPlausibleUnix) droppedBelowFloor++;
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

  /// The band counted more frames in this burst than we counted as valid
  /// received traffic — some arrived corrupted or never arrived at all. The
  /// rows we DID get are already committed; refusing the token asks the band
  /// to re-send the chunk so the missing seconds get another chance instead of
  /// being trimmed out of flash forever. Strictly bounded by the caller —
  /// an unbounded refusal wedged sync forever once.
  blockedBurstShortfall,
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
  /// [hadDurableRows]  — this burst buffered at least one RECORD to bank, or
  ///                     one archive that is NOT a plausibility drop, before
  ///                     ACK. Plausibility drops are excluded on purpose: they
  ///                     are archived too, so counting them would make this
  ///                     gate unfireable exactly in the drop-only case it
  ///                     exists for. Records we simply cannot decode DO count —
  ///                     they are durably set aside, and excluding them wedges
  ///                     an undecodable-only burst into endless re-delivery.
  ///                     Pass `true` when unknown (pre-commit stale/discard
  ///                     checks only).
  /// [droppedThisBurst] — RecordGate rejects during this burst. Combined with
  ///                     `!hadDurableRows`, refuses trim so gate-only bursts
  ///                     cannot delete flash we never stored.
  /// [shortfallRetry]  — the caller has budget to spend one refusal
  ///                     on this token's positive shortfall. Pass `false` on
  ///                     the PRE-commit call: this refusal must happen only
  ///                     AFTER the rows we did receive are durable, or the
  ///                     re-delivery costs us the good records too.
  static TrimAckVerdict evaluate({
    required bool sessionCurrent,
    required bool burstDiscarded,
    required bool commitDurable,
    bool hadDurableRows = true,
    int droppedThisBurst = 0,
    bool shortfallRetry = false,
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
    // Last: everything above is a reason the chunk must not be trimmed at all.
    // This one is a reason to ask for it AGAIN, and only once.
    if (shortfallRetry) return TrimAckVerdict.blockedBurstShortfall;
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
/// the BURST, not the token: a discard poisons the open burst, and only a fresh
/// HISTORY_START clears it. NOT a local re-arm — the abort→retry path re-arms
/// on a 3 s timer while the abandoned burst's terminal is still on the wire.
class BurstTrimGuard {
  bool _discarded = false;

  /// Bursts poisoned since construction (diagnostics — a rising count means
  /// the drain keeps stalling mid-burst).
  int poisonedBursts = 0;

  /// True while the open burst may NOT be trimmed.
  bool get discarded => _discarded;

  /// A fresh burst begins (HISTORY_START) — nothing lost yet.
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

  /// Handled inline AND enqueued on the serialized queue at its true arrival
  /// position, where the burst COUNT for it is applied.
  ///
  /// Burst count members that are not type-47 data (events 48, console 50,
  /// puffin wrappers 53/54/55 — ) arrive on a
  /// different characteristic than the data frames but over the SAME ACL link,
  /// so the band's transmit order is the arrival order. Counting them inline
  /// while the data frames and their HISTORY_END queue up REORDERS the count:
  /// a member could be tallied into the burst before its HISTORY_START opened
  /// the window (where the next rearm wipes it) or after its HISTORY_END had
  /// already validated — which is exactly how a burst goes permanently short
  /// by its event/console members. Enqueueing the count at the arrival
  /// position restores the band's ordering; the frame is still PROCESSED
  /// inline, so wrist/battery/alarm handling is never delayed behind an
  /// offload commit.
  immediateAndCount,
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

  /// [isBurstCountMember] is for the non-data
  /// families (48/50/53/54/55); [offloadActive] is whether a history session is
  /// running at all, since outside one there is no burst to count into.
  static FrameRoute route({
    required bool isMetadata,
    required bool isHistorical,
    required bool isDataRole,
    bool isBurstCountMember = false,
    bool offloadActive = false,
  }) {
    if (isMetadata) return FrameRoute.serializedQueue;
    if (isHistorical && isDataRole) return FrameRoute.serializedQueue;
    if (isBurstCountMember && offloadActive) {
      return FrameRoute.immediateAndCount;
    }
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
    // A FOURTH tier: explicitly backgrounded (Android — the foreground service
    // keeps capture running with no OS deferral, see DeriveScheduler). Nobody
    // can see a fresh number while backgrounded, the queued jobs are durable,
    // and the foreground flip re-evaluates immediately (the engine pokes the
    // timer in setBackground) — so the only thing a fast background cadence
    // buys is widget/Health-Connect freshness, which tolerates ~45 min. This
    // is what caps the all-night light-derive churn (one pass per maxWait
    // instead of one per 5-min fresh window).
    this.backgroundQuietPeriod = const Duration(minutes: 20),
    this.backgroundMaxWait = const Duration(minutes: 45),
  });

  final Duration backgroundQuietPeriod;
  final Duration backgroundMaxWait;

  /// The (quietPeriod, maxWait) pair for the current tier. One copy of the
  /// tier priority: foreground > backgrounded > stale/fresh.
  ({Duration quietPeriod, Duration maxWait}) _tierFor({
    required Duration dataStaleness,
    required bool isForeground,
    required bool isBackgrounded,
  }) {
    if (isForeground) {
      return (quietPeriod: foregroundQuietPeriod, maxWait: foregroundMaxWait);
    }
    if (isBackgrounded) {
      return (quietPeriod: backgroundQuietPeriod, maxWait: backgroundMaxWait);
    }
    final staleMode = dataStaleness >= staleThreshold;
    return staleMode
        ? (quietPeriod: staleQuietPeriod, maxWait: staleMaxWait)
        : (quietPeriod: freshQuietPeriod, maxWait: freshMaxWait);
  }

  /// Should we derive now, given the pending-record bookkeeping?
  ///   [hasPending]       — records persisted since the last derive
  ///   [sinceLastRecord]  — how long since the most recent persisted record
  ///   [sinceFirstPending]— how long since the first record of the current dirty run
  ///   [isForeground]     — the app is actively in the foreground right now;
  ///                        takes priority over the fresh/stale staleness
  ///                        tiers when true (see foregroundQuietPeriod doc)
  ///   [isBackgrounded]   — the app is explicitly backgrounded (engine
  ///                        setBackground); slowest tier, second in priority
  bool shouldDerive({
    required bool hasPending,
    required Duration sinceLastRecord,
    required Duration sinceFirstPending,
    required Duration dataStaleness,
    bool isForeground = false,
    bool isBackgrounded = false,
  }) {
    if (!hasPending) return false;
    final tier = _tierFor(
      dataStaleness: dataStaleness,
      isForeground: isForeground,
      isBackgrounded: isBackgrounded,
    );
    if (sinceLastRecord >= tier.quietPeriod) return true; // stream went quiet
    if (sinceFirstPending >= tier.maxWait) return true; // never-quiet floor
    return false;
  }

  /// How long until [shouldDerive] could next flip true, given the same
  /// inputs — lets the engine arm ONE one-shot timer at the exact boundary
  /// instead of polling every 2 s for the whole pending window (which, with a
  /// continuous background stream, was a permanent 0.5 Hz CPU wake). Clamped
  /// to ≥1 s. Tier flips (foreground/background transitions) are handled by
  /// the engine re-arming, not by this estimate.
  Duration nextCheckDelay({
    required Duration sinceLastRecord,
    required Duration sinceFirstPending,
    required Duration dataStaleness,
    bool isForeground = false,
    bool isBackgrounded = false,
  }) {
    final tier = _tierFor(
      dataStaleness: dataStaleness,
      isForeground: isForeground,
      isBackgrounded: isBackgrounded,
    );
    final untilQuiet = tier.quietPeriod - sinceLastRecord;
    final untilMax = tier.maxWait - sinceFirstPending;
    final next = untilQuiet < untilMax ? untilQuiet : untilMax;
    return next < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : next;
  }
}

/// Pure builders for the on-device wake-alarm command PAYLOADS (the inner body
/// AFTER the opcode byte). The engine wraps these in a frame via its `_send`;
/// keeping the exact byte layout here makes it unit-testable without a real band.
///
/// Alarm opcodes: SET_ALARM_TIME 0x42, GET_ALARM_TIME 0x43, RUN_ALARM 0x44,
/// DISABLE_ALARM 0x45. Prefer [setPayloadForBand] for arming.
///
/// WHICH SET FORM FIRES ON WHOOP 4 — firmware-dependent (evidence: PR #265).
/// On fw 41.17.4 (boot 17.2.2) the REV-1 9-byte form ([rev1]) fired
/// autonomously at the armed second (events 60 HAPTICS_FIRED + 57
/// STRAP_DRIVEN_ALARM_EXECUTED, then 59 auto-disable), while the RICH
/// 20-byte 0x04 form latched (event 56 + GET_ALARM readback) but never
/// executed — three controlled trials, 2026-08-19/20, plus zero event-57s
/// across 1.07M lines of this band's history while rich was the shipped
/// form. On another WHOOP 4 (fw not yet reported; 2026-08-11 export in the
/// PR review) the RICH form DID execute — the observed discriminator is
/// firmware version, not the form alone. The SHORT 7-byte form is rev1 minus
/// the trailing haptic-mode u16; at haptic-mode 0 the two pad4 to
/// byte-identical BLE frames, so there is no wire distinction between them
/// and no separate short-form behaviour to claim. [rev1] is the arm form: it
/// is what the official WHOOP app sends (btsnoop wire capture, noop PR #535)
/// and no observed firmware fails to execute it. WHOOP 5 keeps the rich
/// 21-byte slot-1 form (#194, verified by its own users).
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

  /// REV-1 9-byte SET_ALARM_TIME payload — the gen4 arm form: the official
  /// app's wire form, fired on fw 41.17.4 (class doc for the evidence):
  /// `[0x01][u32 epoch-sec LE][u16 subsec LE][u16 haptic-mode LE]`.
  /// The byte layout has exactly one home, `openstrap_protocol`'s
  /// [alarmRev1Payload]; this is the app-side name for it. Haptic-mode stays
  /// at its default 0 (the strap's stock wake buzz) — the only value
  /// wire-captured from the official app, so we never send anything else.
  static List<int> rev1(DateTime when) => alarmRev1Payload(when);

  /// RICH 20-byte SET_ALARM_TIME payload. On gen4 this is REFERENCE ONLY —
  /// execution is firmware-dependent: on fw 41.17.4 it latches (event 56)
  /// without ever executing, while at least one other firmware executes it
  /// (class doc). Gen5 arms a 21-byte variant of this shape via
  /// [setPayloadForBand].
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

  /// SHORT 7-byte time-only SET_ALARM_TIME payload — [rev1] without the
  /// trailing haptic-mode u16. At haptic-mode 0 the two serialize to the SAME
  /// padded frame, so this is not a distinct wire form. REFERENCE ONLY:
  /// `[0x01][u32 epoch-sec LE][u16 subsec LE]`. Prefer [setPayloadForBand].
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

  /// Generation-correct SET_ALARM_TIME body — 9 bytes on gen4, 21 on gen5.
  ///
  /// WHOOP 4: the REV-1 form ([rev1]) — the official app's wire form, which
  /// fired on fw 41.17.4 where the rich slot-0 body this used to build
  /// latched without executing (class doc for the firmware split).
  /// [index]/[haptics]/[crescendo] do not exist in the rev-1 layout and are
  /// ignored on gen4.
  ///
  /// WHOOP 5: rich 21-byte body at slot **index 1** (index 0 is rejected with
  /// console `arm info is invalid, error 0xb`; the [index] argument is ignored
  /// so callers cannot accidentally arm slot 0). Kept exactly as #194 shipped
  /// it — verified by gen5 users; the gen4 findings do not transfer.
  static List<int> setPayloadForBand(
    DateTime when, {
    required bool isGen5,
    int index = 0,
    List<int>? haptics,
    int crescendo = 0,
  }) =>
      isGen5
          ? <int>[
              ...rich(when, index: gen5Slot, haptics: haptics),
              // gen5's body carries one byte more than gen4's rich form: a
              // crescendo flag the strap validates as 0 or 1 and rejects
              // otherwise, so a 20-byte body is refused there. Keep this in
              // step with protocol's cmdSetAlarm, the reference layout.
              crescendo & 0x01,
            ]
          : rev1(when);

  /// The alarm slot WHOOP 5 accepts (index 0 is rejected).
  static const int gen5Slot = 1;

  /// The gen5 "every slot" alarm id, used by [disableForBand].
  static const int gen5AllSlots = 0xFF;

  /// Gen5 Maverick test-buzz body (RUN_HAPTIC_PATTERN_MAVERICK = 0x13).
  /// Same `[47, 152]` waveform pair as Find-band. Keep [overallLoop] at 1 for
  /// a short pulse — the wake-alarm's loop=7 feels like a stuck vibrate.
  static List<int> gen5MaverickBuzz({int overallLoop = 1}) {
    // `& 0xff` keeps an int (unlike `clamp`, which widens to num).
    final loop = overallLoop.clamp(0, 0xff).toInt();
    return <int>[0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, loop];
  }

  /// RUN_ALARM (0x44) body — fire the haptics immediately ("test buzz").
  static const List<int> runNow = <int>[0x01];

  /// DISABLE_ALARM (0x45) body — cancel the on-device alarm. GEN4 form; do not
  /// change (hardware-verified). Use [disableForBand].
  static const List<int> disable = <int>[0x01];

  /// Generation-correct DISABLE_ALARM (0x45) body.
  ///
  /// WHOOP 4 takes revision 1 with no operand. WHOOP 5 takes revision 2 plus
  /// the alarm id to clear, where [gen5AllSlots] clears every slot; sent the
  /// gen4 body it reads the id from past the end of the body and the alarm
  /// stays armed.
  static List<int> disableForBand({
    required bool isGen5,
    int id = gen5AllSlots,
  }) =>
      isGen5 ? <int>[0x02, id & 0xff] : disable;

  /// Generation-correct GET_ALARM_TIME (0x43) body.
  ///
  /// WHOOP 4 takes revision 1 with no operand; WHOOP 5 takes revision 4 plus
  /// the alarm id to read, defaulting to the slot [setPayloadForBand] arms.
  static List<int> getPayloadForBand({
    required bool isGen5,
    int id = gen5Slot,
  }) =>
      isGen5 ? <int>[0x04, id & 0xff] : const <int>[0x01];

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

// ── command/response correlation ────────────────────────────────────

/// A command response that was matched to a request we actually made.
///
/// Wire layout:
/// `[36][response seq][echoed opcode][originating seq][result][body…]`.
class CorrelatedResponse {
  /// The echoed opcode — equal to the opcode of the request by construction.
  final int opcode;

  /// The sequence WE allocated for the request (not necessarily the byte on
  /// the wire: see [viaSeqZeroFallback]).
  final int seq;

  /// `result`: 0 FAILURE, 1 SUCCESS, 2 PENDING, 3 UNSUPPORTED. `-1` when the
  /// response was too short to carry one.
  final int status;

  /// The decoded response field map (whatever the protocol decoder produced).
  final Map<String, dynamic> fields;

  /// True when this reply carried originating sequence 0 and was matched by
  /// opcode alone — the doc-02 compatibility path.
  final bool viaSeqZeroFallback;

  const CorrelatedResponse({
    required this.opcode,
    required this.seq,
    required this.status,
    this.fields = const {},
    this.viaSeqZeroFallback = false,
  });

  bool get success => status == CommandAwaiter.statusSuccess;
  bool get failed => status == CommandAwaiter.statusFailure;
  bool get unsupported => status == CommandAwaiter.statusUnsupported;
}

/// What [CommandAwaiter.deliver] did with a response.
enum CommandDelivery {
  /// It satisfied a pending request, which is now complete.
  completed,

  /// It matched a pending request whose PENDING is non-terminal — the await stays open for the terminal result.
  pendingHeld,

  /// Nothing was waiting for it, or it failed the match rules (wrong opcode
  /// for that sequence, or an ambiguous sequence-zero fallback).
  unmatched,
}

/// One outstanding command transaction. Created by [CommandAwaiter.register]
/// BEFORE the write goes out.
class PendingCommand {
  final int seq;
  final int opcode;
  final Duration timeout;
  final CommandAwaiter _owner;
  final Completer<CorrelatedResponse?> _completer =
      Completer<CorrelatedResponse?>();

  PendingCommand._(this._owner, this.seq, this.opcode, this.timeout);

  Timer? _expiry;

  /// Start the one-shot expiry. Idempotent: the timeout is applied EXACTLY
  /// ONCE and there is no automatic resend — retry, disconnect and abort
  /// belong to the calling state machine.
  ///
  /// Called from [CommandAwaiter.register] rather than lazily from [response],
  /// so a command that is registered and then never awaited still leaves the
  /// registry after [timeout]. Arming here starts the clock fractionally
  /// before the write returns, which costs a few ms of a multi-second window
  /// and buys the invariant that nothing can outlive its timeout.
  void _armExpiry() {
    _expiry ??= Timer(timeout, () {
      _owner._forget(this);
      if (!_completer.isCompleted) _completer.complete(null);
    });
  }

  /// The correlated reply, or null once [timeout] expires.
  Future<CorrelatedResponse?> get response {
    _armExpiry();
    return _completer.future;
  }

  bool get isCompleted => _completer.isCompleted;

  /// Give up without waiting out the timeout — the write never went out, or
  /// the link died under it.
  void cancel() {
    _expiry?.cancel();
    _owner._forget(this);
    if (!_completer.isCompleted) _completer.complete(null);
  }

  void _complete(CorrelatedResponse r) {
    _expiry?.cancel();
    _owner._forget(this);
    if (!_completer.isCompleted) _completer.complete(r);
  }
}

/// The registry that turns fire-and-forget writes into real request/response
/// transactions.
///
/// Match rule — a response is accepted only when **both** fields agree:
/// ```text
/// response.originating_sequence == request.sequence
/// response.echoed_opcode        == request.opcode
/// ```
/// A sequence match with the wrong opcode is NOT a success: it is rejected and
/// the surrounding await is left to time out. That is the whole point — the
/// old ad-hoc completers in the engine keyed off "a reply of roughly the right
/// shape arrived", so an unrelated command's answer could satisfy a read the
/// app then acted on.
///
/// This class is deliberately transport-free: the engine allocates the
/// sequence, frames and writes; this only says which reply belongs to which
/// request.
class CommandAwaiter {
  /// The generic five-second command await.
  static const Duration defaultTimeout = Duration(milliseconds: 5000);

  static const int statusFailure = 0;
  static const int statusSuccess = 1;
  static const int statusPending = 2;
  static const int statusUnsupported = 3;

  /// The only commands whose `PENDING` is NON-terminal: GET_HELLO(145) and GET_DATA_RANGE(34) keep waiting for a
  /// terminal failure/success/unsupported. Every other command completes on
  /// the first matching response, PENDING included.
  static const Set<int> pendingIsNonTerminal = <int>{0x91, 0x22};

  /// Whether to honour the optional sequence-zero compatibility path:
  /// a response whose originating sequence is 0 may match a nonzero request by
  /// opcode. The doc's own caveat is that two outstanding requests with the
  /// same opcode then become ambiguous — so a fallback match is only taken
  /// when EXACTLY ONE pending request carries that opcode, and refused
  /// otherwise rather than guessing.
  final bool seqZeroFallback;

  CommandAwaiter({this.seqZeroFallback = true});

  final List<PendingCommand> _pending = <PendingCommand>[];

  int get pendingCount => _pending.length;

  /// The (seq, opcode) pairs currently outstanding — diagnostics/tests.
  List<String> get pendingKeys =>
      _pending.map((p) => '${p.seq}/${p.opcode}').toList(growable: false);

  bool hasPendingOpcode(int opcode) => _pending.any((p) => p.opcode == opcode);

  bool hasPendingSeq(int seq) => _pending.any((p) => p.seq == seq);

  /// Install an observer for a command about to be written. Call this BEFORE
  /// the write so a fast response cannot arrive before its
  /// observer exists.
  PendingCommand register(
    int seq,
    int opcode, {
    Duration timeout = defaultTimeout,
  }) {
    final p = PendingCommand._(this, seq, opcode, timeout);
    _pending.add(p);
    // Arm now, not on first await. An entry that is registered and never
    // awaited would otherwise sit in `_pending` for the life of the
    // connection, and `deliver` would refuse every later sequence-zero
    // fallback for that opcode because the stale entry makes the match
    // ambiguous.
    p._armExpiry();
    return p;
  }

  /// Offer a decoded command response to the registry.
  CommandDelivery deliver({
    required int? opcode,
    required int? reqSeq,
    int? status,
    Map<String, dynamic> fields = const {},
  }) {
    // Without an echoed opcode or an originating sequence there is nothing to
    // correlate on, so nothing may be satisfied.
    if (opcode == null || reqSeq == null) return CommandDelivery.unmatched;
    PendingCommand? match;
    var viaFallback = false;
    for (final p in _pending) {
      if (p.seq == reqSeq && p.opcode == opcode) {
        match = p;
        break;
      }
    }
    if (match == null && seqZeroFallback && reqSeq == 0) {
      final sameOpcode = _pending.where((p) => p.opcode == opcode).toList();
      if (sameOpcode.length != 1) return CommandDelivery.unmatched;
      match = sameOpcode.single;
      viaFallback = true;
    }
    if (match == null) return CommandDelivery.unmatched;
    final result = status ?? -1;
    if (result == statusPending && pendingIsNonTerminal.contains(opcode)) {
      return CommandDelivery.pendingHeld;
    }
    match._complete(CorrelatedResponse(
      opcode: opcode,
      seq: match.seq,
      status: result,
      fields: fields,
      viaSeqZeroFallback: viaFallback,
    ));
    return CommandDelivery.completed;
  }

  /// Abandon every outstanding command (the link went down). Each await
  /// resolves null immediately instead of holding its caller for the full
  /// timeout on a connection that no longer exists.
  void failAll() {
    for (final p in List<PendingCommand>.of(_pending)) {
      p.cancel();
    }
    _pending.clear();
  }

  void _forget(PendingCommand p) => _pending.remove(p);
}

/// The identity half of the gen5 bootstrap readiness check — ENFORCED.
///
/// After a terminal successful HELLO, readiness requires the serial and CPU
/// strings to each FULLY match `[a-zA-Z0-9]+`. An empty or partially-matching
/// value fails, and the bootstrap treats a failed verdict as a connection
/// failure: no READY, disconnect. The CPU string is lowercase hex by
/// construction, so in practice it can only fail when it is empty — which is
/// precisely a body the parser never filled.
///
/// An all-zero serial is an EEPROM-failure signal, NOT a rejection — it passes
/// the alphanumeric gate and is surfaced as a separate diagnostic.
class HelloIdentity {
  static final RegExp alphanumeric = RegExp(r'^[a-zA-Z0-9]+$');

  final bool serialOk;
  final bool cpuOk;
  final bool eepromFailureSignal;

  const HelloIdentity({
    required this.serialOk,
    required this.cpuOk,
    required this.eepromFailureSignal,
  });

  bool get ok => serialOk && cpuOk;

  static HelloIdentity evaluate({
    required String serial,
    required String cpuHex,
    bool eepromFailureSignal = false,
  }) =>
      HelloIdentity(
        serialOk: alphanumeric.hasMatch(serial),
        cpuOk: alphanumeric.hasMatch(cpuHex),
        eepromFailureSignal: eepromFailureSignal,
      );

  @override
  String toString() => 'serial=${serialOk ? 'ok' : 'BAD'} '
      'cpu=${cpuOk ? 'ok' : 'BAD'}'
      '${eepromFailureSignal ? ' serial=all-zero(EEPROM)' : ''}';
}

/// The bootstrap clock gate.
///
/// The pinned flow compares the timestamp hello already returned (or, as a
/// fallback, a `GET_CLOCK` reply) against host time and writes NOTHING below
/// two whole seconds of absolute drift: "Below 2 whole seconds, succeed with no
/// BLE write. At 2 or more, send one `SET_CLOCK(10)`". This app used to send
/// SET_CLOCK unconditionally on every connect, i.e. one guaranteed write per
/// connection that the band never needed.
///
/// Deliberately NOT part of [ClockPolicy] (sync_policy.dart): that class owns
/// the *repair* rules — a drift over a day, an unset RTC, a phone we do not
/// trust — which are a different question with a different threshold. This is
/// only the bootstrap sequence's "is a correction needed at all" step, and it
/// sits with the rest of the doc-01 bootstrap logic ([HelloIdentity]).
class BootstrapClockGate {
  /// Absolute whole-second drift at or above which exactly one SET_CLOCK goes
  /// out. Below it the bootstrap makes no BLE write at all.
  static const int toleranceSeconds = 2;

  /// [driftSec] is `wall - strapRtc` ([ClockRef.driftSec]); the sign does not
  /// matter, only the magnitude.
  ///
  /// A null drift means no correlation exists at this point — hello carried no
  /// timestamp AND the GET_CLOCK fallback went unanswered, or the reading was
  /// rejected as implausible (an unset band RTC reads decades low and is never
  /// correlated). That must WRITE: an unset RTC left uncorrected stamps every
  /// record and every alarm against a clock that was never set, which is the
  /// one outcome worse than a redundant write.
  static bool needsCorrection(int? driftSec) =>
      driftSec == null || driftSec.abs() >= toleranceSeconds;

  /// The same gate at millisecond resolution, for the gen5 path where hello
  /// carries subseconds (32768 units/s) and the comparison is against a newly
  /// sampled phone time. "Below two WHOLE seconds of absolute drift, no
  /// write" — a delta of 1.999 s has whole-second component 1 and passes;
  /// exactly 2.000 s writes. Null keeps the write-on-no-reading rule above.
  static bool needsCorrectionMs(int? absDeltaMs) =>
      absDeltaMs == null || absDeltaMs.abs() >= toleranceSeconds * 1000;
}

/// Which GENERATION a scan result advertises, by its advertised service UUIDs.
///
/// A HINT, NOT THE ACCEPT DECISION — do not turn it back into one. Acceptance
/// is deliberately broader (`advertisementLooksLikeWhoop` and the scanner's own
/// match): a band whose 128-bit service UUID spills into the scan-response
/// overflow area advertises only the 16-bit member UUID or its name, and
/// refusing those would leave WHOOP MG unpairable (#255).
///
/// This is the narrower question the connect ROUTE asks: which generation did
/// the advertisement actually name? A name-only or 16-bit-only match names
/// none and returns null, and the connect path then probes the official gen5
/// order first and lets GATT discovery pin the truth. Returning null here
/// therefore means "no hint", never "not a WHOOP".
class ScanAcceptPolicy {
  /// The advertised-service prefixes that identify a WHOOP band: gen4
  /// "Harvard" `61080001-…`, gen5 `fd4b0001-…`.
  static const String gen4AdvertisedPrefix = '61080001';
  static const String gen5AdvertisedPrefix = 'fd4b0001';

  /// The generation the advertisement claims — 'gen4' / 'gen5' — or null when
  /// no supported WHOOP service UUID is advertised (no hint; the scanner may
  /// still have accepted the result). [serviceUuids] are the advertisement's
  /// service UUID strings, any case.
  static String? accepts(Iterable<String> serviceUuids) {
    for (final raw in serviceUuids) {
      final s = raw.toLowerCase();
      if (s.startsWith(gen5AdvertisedPrefix)) return 'gen5';
      if (s.startsWith(gen4AdvertisedPrefix)) return 'gen4';
    }
    return null;
  }
}

/// Which connect order a link gets, decided BEFORE discovery has run.
enum ConnectRoute {
  /// The official gen5 sequence (PHY preference → discovery → MTU → bond …).
  gen5Official,

  /// The proven legacy gen4 flow (bond → MTU → discovery …), unchanged.
  gen4Legacy,
}

/// The routing rule: only an EXPLICIT gen4 hint takes the legacy order.
/// Unknown/null — a pairing upgraded from an older build, a garbled stored
/// value — probes gen5-first: the official sequence's pre-discovery steps are
/// safe on any device (the PHY request is non-fatal by contract), its
/// discovery identifies the band, and a discovered gen4 falls back to the
/// unchanged legacy flow. Routing unknown links through the legacy order
/// instead would run a gen5 band's bond in the wrong position on every
/// connect until something persisted the generation.
ConnectRoute connectRouteFor(String? generationHint) =>
    generationHint == 'gen4' ? ConnectRoute.gen4Legacy : ConnectRoute.gen5Official;

/// Whether a `GET_BATTERY_PACK_INFO(151)` reply actually identifies a pack.
///
/// "A response is usable only if its pack address/name field is non-empty and
/// is not `00:00:00:00:00:00`" — the band answers the command while it is still
/// working out what it is sitting on, so an early reply carries the all-zero
/// address, which is why the follow-up retries at all.
///
/// `attached` is deliberately not part of the gate: the doc names only the
/// address/name field, and the flag is recorded alongside the reading rather
/// than deciding whether the reading counts.
class BatteryPackInfoGate {
  /// The "no pack yet" address the band answers with before it knows.
  static const String unsetAddress = '00:00:00:00:00:00';

  static bool usable({required String identifier, required String name}) {
    final id = identifier.trim().toLowerCase();
    final nm = name.trim().toLowerCase();
    if (id == unsetAddress) return false;
    if (id.isNotEmpty) return true;
    // No identifier: a name alone carries the reply only when it is a real
    // name — the sentinel address leaking through the name field is still
    // "no pack yet".
    return nm.isNotEmpty && nm != unsetAddress;
  }
}

/// Process-wide BLE scan mutex.
///
/// The radio has ONE scanner. Today `BleEngine.scan` is its only caller —
/// `hr_sensor.dart`'s sensor scan had zero callers and went with the file, and
/// a pairing screen for a second device is the next thing to take this lock.
/// Every caller stops whatever is already scanning and then waits for
/// `FlutterBluePlus.isScanning` to go false — an await that any scan stopping
/// satisfies, including the OTHER caller's. The loser's scan therefore
/// "completed" the instant the winner called `stopScan`, having seen nothing,
/// and the caller reported "no device found" with no error anywhere to say
/// why. Serialising the two bodies is the whole fix.
///
/// Same idiom as `BleEngine._locked` — chain onto the previous op, hand the
/// caller a completer, swallow nothing — hoisted out of the engine because the
/// contention is BETWEEN objects, not between two ops on one engine. It has to
/// stay static once a primary band and a secondary device can both scan.
///
/// ponytail: one global lock, so a queued scan waits out the running one's
/// whole timeout (~12 s) rather than joining it. Give waiters the running
/// scan's results only if a screen ever needs both scans at once.
Future<T> withScanLock<T>(Future<T> Function() body) {
  final completer = Completer<T>();
  // A body that throws must not break the chain — the error goes to its own
  // caller and the next scan still runs.
  _scanLock = _scanLock.then((_) async {
    try {
      completer.complete(await body());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  });
  return completer.future;
}

Future<void> _scanLock = Future.value();

/// One GATT write in flight at a time, per LINK.
///
/// Same idiom as [withScanLock] — chain onto the previous op, hand the caller a
/// completer, swallow nothing — but INSTANCE-scoped, because the thing being
/// serialised is one peripheral's command characteristic and two peripherals
/// must not queue behind each other (the per-remoteId ownership model exists so
/// a background drainer and a foreground link can run at once).
///
/// Why it has to exist at all: a with-response write issued before the previous
/// one has been acknowledged is dropped or reordered by the stack, and the
/// failure is SILENT — the frame simply never reaches the band. `BleEngine`
/// has had this since the batch-ACK path was written; `GattBandLink` shipped
/// without it (ASSUMPTIONS G5) and could not bite only because no adapter
/// wrote anything yet.
class WriteChain {
  Future<void> _tail = Future.value();

  /// Run [op] after everything already queued on this chain. The returned
  /// future carries [op]'s result or its error; the chain itself never carries
  /// the error, so one failed write cannot wedge every write after it.
  Future<T> add<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

// ── live HR / IMU stream ownership (discussion #287) ─────────────────────────
//
// A foreground connection used to be an implicit request for BOTH the
// realtime-HR stream (opcode 3) and the 100 Hz IMU stream (gen5 opcode 106),
// and the enable / HR-only / disable methods each flipped the engine's live
// flags BEFORE their writes went out, with no serialisation between them. Two
// races followed from that: a breathing close started an OFF sequence
// unawaited, a workout starting inside that window saw "already enabled" and
// skipped its ON, and the older OFF then finished and left the workout without
// a stream; and a feature that started while another already had streams on
// recorded no ownership, so when both left nothing recomputed the remaining
// owner set and the keep-alive kept re-arming a flood nobody read.
//
// The fix is a desired-vs-applied reconciler: every consumer is an explicit
// owner ([LiveStreamOwners]), the policy below turns the owner set into two
// independent desired bits ([desiredLiveStreams]), and the engine walks the
// applied state towards the desired one a single transition at a time
// ([nextLiveStreamStep]). The engine is the only writer of these opcodes; the
// app never calls enable/disable, it only changes owners and nudges.

/// Which live streams are wanted or applied. OFF, HR-only, IMU-only and
/// HR+IMU are all representable — a three-state off / HR-only / full model
/// cannot express movement sampling without HR, and would arm the IMU flood
/// for breathing and non-gait workouts that only read beats.
class LiveStreamIntent {
  final bool hr;
  final bool imu;
  const LiveStreamIntent({required this.hr, required this.imu});

  static const off = LiveStreamIntent(hr: false, imu: false);

  bool get any => hr || imu;

  @override
  bool operator ==(Object other) =>
      other is LiveStreamIntent && other.hr == hr && other.imu == imu;

  @override
  int get hashCode => Object.hash(hr, imu);

  @override
  String toString() => 'LiveStreamIntent(hr: $hr, imu: $imu)';
}

/// Who wants what, as explicit consumers. None of these is "the app is
/// connected" — except [foreground], which only the gen4 legacy row of
/// [desiredLiveStreams] reads.
class LiveStreamOwners {
  /// A screen showing the live BPM is mounted (HR).
  final bool visibleLiveHrView;

  /// A workout is running, any type, foreground or background (HR: zones,
  /// peak HR, strain and calories all ride the beat stream).
  final bool activeWorkout;

  /// A gait workout (see `kGaitStepTypeKeys`) is running in the FOREGROUND
  /// (IMU: live steps and cadence). Background IMU is not promised until the
  /// background link is measured to sustain the pedometer's sample-rate floor.
  final bool foregroundGaitWorkout;

  /// A guided-breathing session or its pre/post quiet window is open (HR:
  /// R-R for coherence and RMSSD).
  final bool breathing;

  /// iOS, backgrounded: the inbound 1 Hz notification is what keeps the
  /// suspended process schedulable, so HR stays on there with no other owner.
  /// An Edge platform policy, not a measured guarantee.
  final bool iosBackgroundKeepalive;

  /// A bounded movement-reminder sampling window is open (IMU-only). There is
  /// no scheduler yet: enabling the reminder preference must NOT hold IMU, and
  /// sampling only inside windows cannot prove stillness between them.
  final bool movementSampling;

  /// Passive strap-step collection opt-in (IMU). Off by default on gen5: the
  /// on-chip daily counter is the fallback, and the phone can supply windowed
  /// steps. A future opt-in requests IMU through this same owner.
  final bool passiveStrapSteps;

  /// The app is in the foreground. Read ONLY for gen4, where a foreground
  /// connection keeps today's behaviour: HR plus the R10/R11 + IMU + optical
  /// bundle, so gen4 users keep passive strap steps and live HR exactly as
  /// before. gen4 has no on-chip daily step fallback, and the "default off"
  /// decision in #287 was taken in gen5 terms.
  final bool foreground;

  const LiveStreamOwners({
    this.visibleLiveHrView = false,
    this.activeWorkout = false,
    this.foregroundGaitWorkout = false,
    this.breathing = false,
    this.iosBackgroundKeepalive = false,
    this.movementSampling = false,
    this.passiveStrapSteps = false,
    this.foreground = false,
  });

  static const none = LiveStreamOwners();

  @override
  String toString() => 'LiveStreamOwners('
      'hrView: $visibleLiveHrView, workout: $activeWorkout, '
      'fgGait: $foregroundGaitWorkout, breathing: $breathing, '
      'iosBg: $iosBackgroundKeepalive, movement: $movementSampling, '
      'passiveSteps: $passiveStrapSteps, foreground: $foreground)';
}

/// The streams the current owners call for.
///
///   wantHr  = visibleLiveHrView || activeWorkout || breathing
///           || iosBackgroundKeepalive
///   wantImu = foregroundGaitWorkout || movementSampling || passiveStrapSteps
///
/// plus, on gen4 only, `foreground` as an owner of both (see
/// [LiveStreamOwners.foreground]). History sync is never an owner — it reads
/// flash, not live frames — which is why it has no field here.
///
/// [standardHrFallback] is the sticky marginal-radio latch: a radio that
/// cannot sustain the high-rate flood keeps HR and drops IMU, exactly as the
/// old enable path returned right after HR ON.
LiveStreamIntent desiredLiveStreams(
  LiveStreamOwners o, {
  required bool gen5,
  required bool standardHrFallback,
}) {
  final legacy = !gen5 && o.foreground;
  final hr = o.visibleLiveHrView ||
      o.activeWorkout ||
      o.breathing ||
      o.iosBackgroundKeepalive ||
      legacy;
  final imu = (o.foregroundGaitWorkout ||
          o.movementSampling ||
          o.passiveStrapSteps ||
          legacy) &&
      !standardHrFallback;
  return LiveStreamIntent(hr: hr, imu: imu);
}

/// One transition of one stream. `imuOn`/`imuOff` are the high-rate bundle:
/// opcode 106 alone on gen5, R10/R11 + IMU + optical on gen4.
enum LiveStreamStep {
  hrOn,
  imuOn,
  imuOff,
  hrOff;

  bool get isImu => this == imuOn || this == imuOff;
}

/// The next single transition that moves [applied] towards [desired], or null
/// when they already agree. Order is today's wire order: ONs first (HR before
/// the bundle), then OFFs (bundle before HR), so a full arm and a full disarm
/// emit exactly the sequences the old enable/disable methods did.
///
/// Per-bit uncertainty the engine tracks per link:
///
/// [imuFresh] — the strap's bundle state is not known on a fresh link. gen4's
/// R10/R11 OFF state PERSISTS across reconnects on the strap (protocol
/// `cmdSendR10R11`: "the off state persists across reconnects"), so a fresh
/// gen4 link cannot be modelled as known-off. While fresh, the first time the
/// link is used at all (anything desired) the bundle is replayed in the
/// desired direction; a link nothing wants stays silent, which is what an
/// Android-background gen4 reconnect did before. gen5 passes false: its IMU
/// bit is a single write and #287 forbids speculative writes there.
///
/// [imuDirty] / [hrDirty] — a write for that bit FAILED or went stale, so the
/// strap may be in either state (a timed-out write can still have landed; a
/// gen4 bundle can be half-applied). Dirty ALWAYS replays the newest desired
/// direction before convergence, even when nothing is desired: a dirty OFF
/// must be cleaned up, unlike a fresh one.
LiveStreamStep? nextLiveStreamStep({
  required LiveStreamIntent applied,
  required LiveStreamIntent desired,
  bool imuFresh = false,
  bool imuDirty = false,
  bool hrDirty = false,
}) {
  final replayImu = imuDirty || (imuFresh && desired.any);
  if (desired.hr && (!applied.hr || hrDirty)) return LiveStreamStep.hrOn;
  if (desired.imu && (!applied.imu || replayImu)) return LiveStreamStep.imuOn;
  if (!desired.imu && (applied.imu || replayImu)) return LiveStreamStep.imuOff;
  if (!desired.hr && (applied.hr || hrDirty)) return LiveStreamStep.hrOff;
  return null;
}

/// [applied] after [step] succeeded.
LiveStreamIntent applyLiveStreamStep(
  LiveStreamIntent applied,
  LiveStreamStep step,
) =>
    switch (step) {
      LiveStreamStep.hrOn => LiveStreamIntent(hr: true, imu: applied.imu),
      LiveStreamStep.hrOff => LiveStreamIntent(hr: false, imu: applied.imu),
      LiveStreamStep.imuOn => LiveStreamIntent(hr: applied.hr, imu: true),
      LiveStreamStep.imuOff => LiveStreamIntent(hr: applied.hr, imu: false),
    };
