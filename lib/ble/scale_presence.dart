// Hears a paired Mi scale wake up and syncs it, so a weighing needs no tap on
// the Devices page.
//
// A scale advertises only while it is awake (a foot on it, a tap), and the
// only thing that ever synced it on Android was the Devices-page button: the
// headless pass runs at boot, not on a schedule. So, while the app process
// lives (its foreground service keeps it), a short low-power scan filtered to
// the paired scale's address runs every [gap]; a hit runs the normal
// `SessionLink.sync()` session, which reads the stored history too, so a
// missed window costs a delay and never a reading.
//
// The scan goes through `withScanLock`, so it queues behind a pairing scan or
// the primary band's instead of racing it. Nothing here connects: the session
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
    this.bandWaiting,
    this.window = const Duration(seconds: 8),
    this.gap = const Duration(seconds: 20),
    this.cooldown = const Duration(minutes: 3),
  })  : _paired = pairedScales ?? _pairedScales,
        _hear = hear ?? _scan,
        _sync = sync ?? _syncSession;

  final Future<Map<String, String>> Function() _paired;
  final Future<String?> Function(List<String>, Duration) _hear;
  final Future<void> Function(String) _sync;
  final Duration window, gap, cooldown;

  /// True while a paired band is not connected, i.e. its reconnect scan may be
  /// queued on the scan lock. The cycle is skipped then, so a scale scan can
  /// never delay the band.
  final bool Function()? bandWaiting;

  bool _stop = true;
  Future<void>? _loop;
  Completer<void>? _nap;

  /// Start watching; a second call while running does nothing.
  void start() {
    if (_loop != null) return;
    _stop = false;
    _loop = _run().whenComplete(() => _loop = null);
  }

  /// Stop after the current cycle; completes once the loop has ended.
  Future<void> stop() async {
    _stop = true;
    if (_nap case final n? when !n.isCompleted) n.complete();
    await _loop;
  }

  Future<void> _run() async {
    while (!_stop) {
      var wait = gap;
      try {
        final scales = await _paired(); // remote id (lower case) -> adapter id
        if (scales.isNotEmpty && bandWaiting?.call() != true) {
          final hit = await _hear(scales.keys.toList(), window);
          if (hit != null && !_stop) {
            await _sync(scales[hit.toLowerCase()]!);
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

  static Future<String?> _scan(List<String> ids, Duration window) =>
      withScanLock(() async {
        String? hit;
        final want = {for (final i in ids) i.toLowerCase()};
        final sub = FlutterBluePlus.onScanResults.listen((results) {
          for (final r in results) {
            final id = r.device.remoteId.str.toLowerCase();
            if (hit == null && want.contains(id)) {
              hit = id;
              unawaited(FlutterBluePlus.stopScan().catchError(
                  (Object e) => debugPrint('[scale-watch] stopScan failed: $e')));
            }
          }
        });
        try {
          await FlutterBluePlus.startScan(
            withRemoteIds: [for (final i in ids) i.toUpperCase()],
            timeout: window,
            androidScanMode: AndroidScanMode.lowPower,
          );
          // Bounded: a lost scan-stop event must not hold the process-wide
          // scan lock (and with it every other scan) forever.
          await FlutterBluePlus.isScanning
              .where((on) => !on)
              .first
              .timeout(window + const Duration(seconds: 5));
        } finally {
          await sub.cancel();
        }
        return hit;
      });
}
