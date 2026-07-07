// android_background.dart — Android OS keep-alive integrations, Dart side.
//
// Two independent levers that make the background BLE session survive the OS:
//
//   1. CompanionDeviceManager (CDM) association. After pairing we associate the
//      band's MAC with the app via CDM (a one-time system dialog pre-filtered to
//      the exact device). An associated companion app is exempt from several
//      background-execution limits (it may start its foreground service from the
//      background), and on API 31+ `startObservingDevicePresence` makes the OS
//      relaunch/bind the app's CompanionDeviceService when the band appears —
//      the native EdgeCompanionService then restarts EdgeTrackingService.
//
//   2. Battery-optimization (Doze) exemption. `isIgnoringBatteryOptimizations`
//      reports the current state; `requestIgnoreBatteryOptimizations` fires the
//      system ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS dialog. Without the
//      exemption, Doze can freeze the process between BLE events overnight.
//
// All methods are safe no-ops on iOS and degrade gracefully on old Android
// (the native side gates by API level). Failures are logged, never thrown —
// nothing here may break pairing or the session flow.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidBackground {
  static const _ch = MethodChannel('openstrap/android_background');

  /// Fire-and-forget CDM association for the paired band ([mac] is the
  /// flutter_blue_plus remoteId, which on Android IS the MAC address). Shows
  /// the one-time system companion dialog (pre-filtered to this device) when
  /// no association exists yet; re-arms device-presence observation otherwise.
  /// No-op below API 26; presence observation needs API 31+.
  static Future<void> associateCompanion(String mac) async {
    if (!Platform.isAndroid) return;
    try {
      final res = await _ch.invokeMethod<String>('associateCompanion', mac);
      debugPrint('[android-bg] companion association: $res');
    } catch (e) {
      debugPrint('[android-bg] companion association failed (non-fatal): $e');
    }
  }

  /// Whether the app is already exempt from battery optimizations (Doze).
  /// Returns true on iOS / errors-as-unknown default to false on Android.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ==
          true;
    } catch (e) {
      debugPrint('[android-bg] battery-opt check failed: $e');
      return false;
    }
  }

  /// Fire the system "ignore battery optimizations?" dialog for this app.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('[android-bg] battery-opt request failed: $e');
    }
  }
}
