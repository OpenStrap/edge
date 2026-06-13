// Android "Edge Tracking" foreground service.
//
// Keeps the app process alive while backgrounded so the live BLE connection keeps
// draining the strap (Android kills background processes otherwise). Shows a single
// silent, low-priority notification ("Edge Tracking"), the same trade modern Android
// requires for long-running BLE — there is no reliable background-BLE path without it.
//
// No-op on iOS: there, CoreBluetooth state restoration (BleRestoreManager) handles
// background relaunch silently, so no service/notification is needed.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class EdgeTracking {
  static const _ch = MethodChannel('openstrap/edge_tracking');

  /// Start the foreground service. Idempotent — safe to call on every session start.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('start');
    } catch (e) {
      debugPrint('[edge-tracking] start failed: $e');
    }
  }

  /// Stop the service (sign-out / unpair).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
