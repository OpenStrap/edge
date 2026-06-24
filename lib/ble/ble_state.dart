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
/// app's intent + sub-phases (scan/discover/subscribe/drain/live) on top of it.
enum BleConnState {
  idle,
  scanning,
  connecting,
  discovering,
  subscribing,
  settingUp,
  ready, // connected + subscribed + handshake done, no live stream yet
  syncing, // historical drain in progress
  live, // live streams enabled
  reconnecting,
  error,
}

/// Legacy `DeviceState.connection` string the UI still reads. Derived from the
/// phase so the public surface is unchanged. The UI only distinguishes
/// scanning / connecting / connected / syncing / disconnected.
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
    case BleConnState.ready:
    case BleConnState.live:
      return 'connected';
    case BleConnState.syncing:
      return 'syncing';
  }
}

/// Pure reconnection schedule: bounded exponential backoff with jitter.
///
/// delay(attempt) = clamp(base * 2^(attempt-1), base, cap), then ± up to
/// `jitterFraction` of that value. `attempt` is 1-based (the first retry is 1).
/// Mirrors reference's `didFailToConnect` capped backoff but adds jitter so a fleet of
/// devices doesn't thunder-herd a flaky radio.
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

/// Pure drain stop-condition logic. The drain ends when ANY of:
///   - HISTORY_COMPLETE marker arrived (`complete`)
///   - the link dropped (`linkDown`)
///   - we caught up to the live edge: newest record within `liveEdgeWindow` of now
///     AND we've actually received records
///   - idle: no new records for `idleTimeout`
///   - the overall `timeout` elapsed
/// Returning the REASON (not just a bool) lets the caller decide whether to send
/// ABORT_HISTORICAL (live-edge / idle) vs. just stop (complete / link-down).
enum DrainStop { keepGoing, complete, linkDown, liveEdge, idle, timeout }

class DrainStopEvaluator {
  final Duration liveEdgeWindow;
  final Duration idleTimeout;
  final Duration timeout;

  const DrainStopEvaluator({
    this.liveEdgeWindow = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 8),
    this.timeout = const Duration(seconds: 600),
  });

  /// Evaluate against the current drain telemetry.
  /// All times in epoch-ms / seconds as noted.
  DrainStop evaluate({
    required bool complete,
    required bool linkDown,
    required int records,
    required int lastRecordTsSec, // newest historical record ts (unix sec), 0 if none
    required int nowSec,
    required Duration sinceStart,
    required Duration sinceLastNewRecord,
  }) {
    if (complete) return DrainStop.complete;
    if (linkDown) return DrainStop.linkDown;
    if (sinceStart >= timeout) return DrainStop.timeout;
    if (lastRecordTsSec > 0 &&
        records > 0 &&
        (nowSec - lastRecordTsSec) < liveEdgeWindow.inSeconds) {
      return DrainStop.liveEdge;
    }
    if (records > 0 && sinceLastNewRecord >= idleTimeout) return DrainStop.idle;
    // Also idle-out a drain that never produced a single record (nothing banked).
    if (records == 0 && sinceStart >= idleTimeout) return DrainStop.idle;
    return DrainStop.keepGoing;
  }
}
