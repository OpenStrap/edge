// android_background.dart — Android OS keep-alive integrations, Dart side.
//
// Three independent levers that make the background BLE session survive the OS:
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
//   3. OEM autostart/protected-apps allowlist. The stock Doze exemption above
//      is well-known (though NOT officially documented anywhere by Google —
//      verified against developer.android.com's Doze/App-Standby guide) to
//      be insufficient on Xiaomi/Huawei/Honor/Oppo/Vivo/OnePlus, which layer
//      their own aggressive killers behind a separate allowlist stock APIs
//      cannot toggle. `needsOemAutostartSettings` only reports true when
//      BOTH the manufacturer is one of those AND the OS confirms via the
//      one official signal for this — `ActivityManager.isBackgroundRestricted`
//      (API 28+) — that it's actually restricting this app right now; we
//      deliberately don't nag every user on those OEMs unconditionally, only
//      the ones the OS itself says are affected. `openOemAutostartSettings`
//      opens the OEM screen (falling back to the app's standard settings
//      page if no OEM-specific screen exists on this device/OS version).
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

  /// Manufacturers whose OS layers an aggressive process-killer on top of
  /// stock Android Doze, gating background survival behind a separate
  /// "autostart"/"protected apps" allowlist the stock
  /// [requestIgnoreBatteryOptimizations] dialog does NOT cover. Lowercased
  /// [Build.MANUFACTURER] substrings.
  static const Set<String> aggressiveOemManufacturers = {
    'xiaomi',
    'huawei',
    'honor',
    'oppo',
    'realme',
    'vivo',
    'oneplus',
  };

  /// The device manufacturer (lowercased, e.g. "xiaomi"), or null on iOS/error.
  static Future<String?> manufacturerHint() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('manufacturerHint');
    } catch (e) {
      debugPrint('[android-bg] manufacturer hint failed: $e');
      return null;
    }
  }

  /// Whether the OS is CURRENTLY restricting this app's background work —
  /// `ActivityManager.isBackgroundRestricted()` (API 28+), the one official,
  /// documented signal for this ("if true, any work that the app tries to do
  /// will be aggressively restricted while it is in the background"). False
  /// on iOS, on API <28, or on error (fails closed — never over-claims
  /// restriction).
  static Future<bool> isBackgroundRestricted() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('isBackgroundRestricted') == true;
    } catch (e) {
      debugPrint('[android-bg] background-restricted check failed: $e');
      return false;
    }
  }

  /// True when the extra OEM autostart step is actually worth offering:
  /// this device's OEM is known to gate background survival behind a
  /// separate allowlist AND the OS is presently confirmed to be restricting
  /// this app (`isBackgroundRestricted`, API 28+) — i.e. we don't just guess
  /// off the manufacturer string, we confirm against the one documented
  /// signal for this situation before nagging the user. (API <28 predates
  /// that signal entirely — `isBackgroundRestricted` reports false there,
  /// so this option simply won't surface on those now-ancient devices;
  /// acceptable given how old API <28 is at this point.)
  static Future<bool> needsOemAutostartSettings() async {
    final m = await manufacturerHint();
    if (m == null || !aggressiveOemManufacturers.any(m.contains)) return false;
    return isBackgroundRestricted();
  }

  /// Open this OEM's autostart/protected-apps allowlist screen (a second,
  /// stronger line of defense than the stock battery-optimization exemption
  /// — see the native-side doc). Falls back to the app's standard "App info"
  /// settings page if no OEM-specific screen exists on this device, so the
  /// call always lands the user somewhere useful. No-op on iOS.
  static Future<void> openOemAutostartSettings() async {
    if (!Platform.isAndroid) return;
    try {
      final outcome = await _ch.invokeMethod<String>('openOemAutostartSettings');
      debugPrint('[android-bg] OEM autostart settings: $outcome');
    } catch (e) {
      debugPrint('[android-bg] OEM autostart settings failed: $e');
    }
  }
}
