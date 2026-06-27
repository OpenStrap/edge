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
/// We DELIBERATELY do NOT stop on a "live edge" (newest record near now) or on an
/// idle gap, and we NEVER send ABORT_HISTORICAL. The band offloads OLDEST-first and
/// only emits HISTORY_COMPLETE once its flash backlog is fully handed over; cutting
/// the offload short (the old liveEdge/idle ABORT) meant we ACKed only part of the
/// backlog, the band's read cursor never reached the end, and on the next connect it
/// re-flooded the same history ("Groundhog Day"). Letting it run to HISTORY_COMPLETE
/// is what advances the cursor durably. Once complete, the SAME subscription keeps
/// delivering live records — there is no mode switch.
enum DrainStop { keepGoing, complete, linkDown, timeout }

class DrainStopEvaluator {
  final Duration timeout;

  const DrainStopEvaluator({
    this.timeout = const Duration(seconds: 600),
  });

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
  final Duration quietPeriod;
  final Duration maxWait;

  const DeriveDebouncer({
    this.quietPeriod = const Duration(seconds: 12),
    this.maxWait = const Duration(seconds: 90),
  });

  /// Should we derive now, given the pending-record bookkeeping?
  ///   [hasPending]       — records persisted since the last derive
  ///   [sinceLastRecord]  — how long since the most recent persisted record
  ///   [sinceFirstPending]— how long since the first record of the current dirty run
  bool shouldDerive({
    required bool hasPending,
    required Duration sinceLastRecord,
    required Duration sinceFirstPending,
  }) {
    if (!hasPending) return false;
    if (sinceLastRecord >= quietPeriod) return true; // stream went quiet
    if (sinceFirstPending >= maxWait) return true; // never-quiet floor
    return false;
  }
}
