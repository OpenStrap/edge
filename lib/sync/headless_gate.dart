// headless_gate.dart — ONE process-wide gate for every headless sync entry point.
//
// Three separate wake paths can call runHeadlessSync():
//   - the iOS CoreBluetooth-restoration wake (IosBleRestore)
//   - the iOS BGProcessingTask (IosBgTask, heavy profile)
//   - the iOS BGAppRefreshTask (IosBgTask, sync-only profile)
//
// They used to carry their OWN private `_busy` flags with asymmetric guards, so
// two of them could race into runHeadlessSync() concurrently and only the
// engine's static band-owner arbitration saved the offload from duplicate ACKs.
// This gate makes the mutual exclusion EXPLICIT and shared: whichever entry
// point is running holds the gate; the others skip their cycle (a skipped wake
// is harmless — the non-destructive cursor catches everything up next time).

import 'dart:async';

import 'package:flutter/foundation.dart';

class HeadlessSyncGate {
  HeadlessSyncGate._();

  static Future<void>? _running;
  static String? _runningOwner;

  /// True while any headless entry point holds the gate.
  static bool get busy => _running != null;

  // Skip-streak telemetry. Previously a collision between wake sources was
  // only ever a single debugPrint line with no counter — a wake source that
  // keeps losing the race EVERY cycle (a sign two sources are colliding
  // rather than actually diversifying background coverage, e.g. the
  // BLE-restore wake and a BGAppRefreshTask firing back-to-back every time)
  // looked identical to one that skipped once by chance. Per-owner
  // consecutive-skip + lifetime-total counters make that pattern observable.
  static final Map<String, int> _consecutiveSkipsByOwner = {};
  static int _totalSkips = 0;

  /// Consecutive skips for [owner] since it last actually ran (0 if it ran
  /// most recently, or has never skipped).
  static int consecutiveSkipsFor(String owner) =>
      _consecutiveSkipsByOwner[owner] ?? 0;

  /// Lifetime skip count across every owner (process-wide, resets on relaunch).
  static int get totalSkips => _totalSkips;

  /// Run [body] exclusively. If another entry point already holds the gate the
  /// call is SKIPPED (returns null) — same "skip, don't queue" semantics the
  /// old per-flag guards had, but shared across all entry points.
  static Future<T?> tryRun<T>(String owner, Future<T> Function() body) async {
    if (_running != null) {
      final n = (_consecutiveSkipsByOwner[owner] ?? 0) + 1;
      _consecutiveSkipsByOwner[owner] = n;
      _totalSkips++;
      debugPrint(
        '[headless-gate] busy (held by "$_runningOwner") — "$owner" skipped '
        'this cycle (consecutive_skips=$n, total_skips=$_totalSkips)',
      );
      return null;
    }
    _consecutiveSkipsByOwner[owner] = 0; // this run breaks its own streak
    final done = Completer<void>();
    _running = done.future;
    _runningOwner = owner;
    try {
      return await body();
    } finally {
      _running = null;
      _runningOwner = null;
      done.complete();
    }
  }

  /// Test-only reset — static state otherwise leaks across test cases.
  @visibleForTesting
  static void resetForTest() {
    _running = null;
    _runningOwner = null;
    _consecutiveSkipsByOwner.clear();
    _totalSkips = 0;
  }
}
