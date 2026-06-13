// iOS CoreBluetooth state-restoration bridge.
//
// The native BleRestoreManager (ios/Runner/BleRestoreManager.swift) holds a no-timeout
// pending connect to the paired band so iOS relaunches the app when the band reappears —
// even from terminated. When that fires, native invokes `wake` here and we run the same
// headless drain the periodic task uses, then tell native we're done so it re-arms.
//
// No-op on Android (WorkManager handles background there).

import 'dart:io';

import 'package:flutter/services.dart';

import '../sync/background_sync.dart';
import '../sync/file_log.dart';

class IosBleRestore {
  static const _ch = MethodChannel('openstrap/ble_restore');
  static bool _busy = false;

  /// Set true while the app holds a live foreground session (BleEngine connected).
  /// A wake-triggered headless sync would otherwise fight flutter_blue_plus for the
  /// band, so we skip it — the foreground session is already draining.
  static bool foregroundActive = false;

  static Future<void> _log(String m) =>
      FileLog.write('${DateTime.now().toIso8601String()} [ios-restore] $m');

  /// Register the wake handler and tell native Flutter is ready. Call once at startup.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'wake') return null;
      await _log('wake from CoreBluetooth');
      if (foregroundActive) {
        await _log('foreground session active — skipping headless sync');
        await _done();
        return null;
      }
      if (_busy) {
        await _log('already syncing — ignoring wake');
        return null;
      }
      _busy = true;
      try {
        await runHeadlessSync();
      } catch (e) {
        await _log('headless sync threw: $e');
      } finally {
        _busy = false;
        await _done();
      }
      return null;
    });
    try {
      await _ch.invokeMethod('ready');
    } catch (_) {}
  }

  /// Arm restoration for this band (its iOS peripheral UUID == PairedDevice.remoteId).
  static Future<void> arm(String remoteId) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('arm', remoteId);
      await _log('armed for $remoteId');
    } catch (_) {}
  }

  /// Stop restoration (sign-out / unpair).
  static Future<void> disarm() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('disarm');
    } catch (_) {}
  }

  static Future<void> _done() async {
    try {
      await _ch.invokeMethod('syncDone');
    } catch (_) {}
  }
}
