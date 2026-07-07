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

  /// True while any headless entry point holds the gate.
  static bool get busy => _running != null;

  /// Run [body] exclusively. If another entry point already holds the gate the
  /// call is SKIPPED (returns null) — same "skip, don't queue" semantics the
  /// old per-flag guards had, but shared across all entry points.
  static Future<T?> tryRun<T>(String owner, Future<T> Function() body) async {
    if (_running != null) {
      debugPrint('[headless-gate] busy — "$owner" skipped this cycle');
      return null;
    }
    final done = Completer<void>();
    _running = done.future;
    try {
      return await body();
    } finally {
      _running = null;
      done.complete();
    }
  }
}
