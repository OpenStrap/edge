// Hears a paired Mi scale wake up and syncs it, so a weighing needs no tap on
// the Devices page.
//
// A scale advertises only while it is awake (a foot on it, a tap), and the
// only thing that ever synced it on Android was the Devices-page button: the
// headless pass runs at boot, not on a schedule. So, while the app process
// lives (its foreground service keeps it), a short low-power scan filtered to
// the paired scale's address scans for [window] and rests [gap] between scans; a hit runs the normal
// `SessionLink.sync()` session, which reads the stored history too, so a
// missed window costs a delay and never a reading.
//
// The scan goes through `withScanLock`, so it queues behind a pairing scan
// instead of racing it. The band's own reconnect is an OS `autoConnect`, not a
// scan, so it is not held up by this. Nothing here connects: the session
// takes its own secondary-link slot.
//
// ponytail: fixed duty cycle and a flat [cooldown] after a hit (so a scale
// that stays awake is not synced in a loop). A second weighing inside the
// cooldown waits for the next window after it. Move to a long-lived filtered
// scan only if a real scale is seen missing its window.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart' show kMiScale2, kMiScaleComposition;
import 'ble_state.dart' show withScanLock;
import 'session_link.dart';

/// The adapters this watches: the Mi scales (the thermometer is unverified).
final Set<String> kAutoSyncAdapters = {kMiScaleComposition.id, kMiScale2.id};

class ScalePresenceWatcher {
  ScalePresenceWatcher({
    Future<Map<String, String>> Function()? pairedScales,
    Future<String?> Function(List<String> remoteIds, Duration window)? hear,
    Future<void> Function(String adapterId)? sync,
    Future<void> Function(String adapterId)? abort,
    this.window = const Duration(seconds: 8),
    this.gap = const Duration(seconds: 20),
    this.cooldown = const Duration(minutes: 3),
    this.syncTimeout = const Duration(minutes: 2),
  }) : _paired = pairedScales ?? _pairedScales,
       _hear = hear ?? _scan,
       _sync = sync ?? _syncSession,
       _abort = abort ?? _abortSession;

  final Future<Map<String, String>> Function() _paired;
  final Future<String?> Function(List<String>, Duration) _hear;
  final Future<void> Function(String) _sync;
  final Future<void> Function(String) _abort;
  final Duration window, gap, cooldown, syncTimeout;

  bool _stop = true;
  bool _restartPending = false;
  Future<void>? _loop;
  Completer<void>? _nap;

  /// Start watching; a second call while running does nothing.
  void start() {
    if (_loop != null) {
      // Still draining after a stop(): restart once it has ended, otherwise
      // the watcher would stay dead for the rest of the process.
      if (_stop) _restartPending = true;
      return;
    }
    _stop = false;
    _loop = _run().whenComplete(() {
      _loop = null;
      if (_restartPending) {
        _restartPending = false;
        start();
      }
    });
  }

  /// Stop after the current cycle; completes once that loop has ended. A
  /// start() made while it drains begins a new loop afterwards, which this
  /// future does not wait for.
  Future<void> stop() async {
    _stop = true;
    _restartPending = false;
    if (_nap case final n? when !n.isCompleted) n.complete();
    await _loop;
  }

  Future<void> _run() async {
    while (!_stop) {
      var wait = gap;
      try {
        final scales = await _paired(); // remote id (lower case) -> adapter id
        if (scales.isNotEmpty) {
          final hit = await _hear(scales.keys.toList(), window);
          if (hit != null && !_stop) {
            final adapterId = scales[hit.toLowerCase()]!;
            await _sync(adapterId).timeout(
              syncTimeout,
              onTimeout: () {
                // The timeout only stops the wait; end the session too, so a
                // queued sync cannot connect after the watcher gave up on it.
                unawaited(
                  _abort(adapterId).catchError(
                    (Object e) => debugPrint('[scale-watch] abort failed: $e'),
                  ),
                );
              },
            );
            wait = cooldown;
          }
        }
      } catch (e) {
        // A missing scan permission or radio off: back off, never spin.
        debugPrint('[scale-watch] cycle failed: $e');
        wait = cooldown;
      }
      if (_stop) break;
      final nap = _nap = Completer<void>();
      await Future.any([Future<void>.delayed(wait), nap.future]);
    }
  }

  static Future<Map<String, String>> _pairedScales() async => {
    for (final r in await LocalDb.deviceRows())
      if (kAutoSyncAdapters.contains(r['adapter_id']) &&
          r['id'] != LocalDb.kPrimaryDeviceId &&
          (r['remote_id'] as String?)?.isNotEmpty == true)
        (r['remote_id'] as String).toLowerCase(): r['adapter_id'] as String,
  };

  static Future<void> _syncSession(String adapterId) async {
    await SessionLink.forId(adapterId)?.sync();
  }

  static Future<void> _abortSession(String adapterId) async {
    await SessionLink.forId(adapterId)?.stop();
  }

  static Future<String?> _scan(List<String> ids, Duration window) =>
      withScanLock(() async {
        String? hit;
        final want = {for (final i in ids) i.toLowerCase()};
        final sub = FlutterBluePlus.onScanResults.listen((results) {
          for (final r in results) {
            final id = r.device.remoteId.str.toLowerCase();
            if (hit == null && want.contains(id)) {
              hit = id;
              unawaited(
                FlutterBluePlus.stopScan().catchError(
                  (Object e) => debugPrint('[scale-watch] stopScan failed: $e'),
                ),
              );
            }
          }
        });
        try {
          // startScan's own timeout only starts once the platform call has
          // returned; a hung permission/startup call must not hold the lock.
          final started = FlutterBluePlus.startScan(
            withRemoteIds: [for (final i in ids) i.toUpperCase()],
            timeout: window,
            androidScanMode: AndroidScanMode.lowPower,
          );
          try {
            await started.timeout(const Duration(seconds: 10));
          } on TimeoutException {
            // Quiet cycle. A scan that still starts late ends by itself after
            // [window]; stopping it here could kill a scan another caller
            // started once the lock was released.
            unawaited(started.then<void>((_) {}, onError: (Object _) {}));
            return null;
          }
          // Bounded: a lost scan-stop event must not hold the process-wide
          // scan lock (and with it every other scan) forever.
          try {
            await FlutterBluePlus.isScanning
                .where((on) => !on)
                .first
                .timeout(window + const Duration(seconds: 5));
          } on TimeoutException {
            // The stop event was lost: end the scan ourselves before the lock
            // is released, and treat it as a quiet cycle (retry at [gap]).
            await FlutterBluePlus.stopScan()
                .timeout(const Duration(seconds: 3))
                .catchError(
                  (Object e) => debugPrint('[scale-watch] stopScan failed: $e'),
                );
          }
        } finally {
          await sub.cancel();
        }
        return hit;
      });
}
