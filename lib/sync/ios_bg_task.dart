// ios_bg_task.dart — iOS BGProcessingTask Dart handler.
//
// Native (BackgroundTasks.swift) calls the `openstrap/bg_task` channel method
// `run` when iOS opportunistically wakes the app for a BGProcessingTask. We run
// runHeadlessSync() (connect → flash offload → local store → disconnect → light
// derive) followed by a heavy DerivationEngine pass (full sleep staging + 24h
// spectra), then return true to signal completion.
//
// iOS gives BGProcessingTask a longer wall-clock budget than BGAppRefreshTask
// (up to ~2–3 min typically; device-dependent), but we must still be bounded.
// runHeadlessSync already has a timeout inside BleEngine; heavy derive is also
// bounded per-day. If the OS fires the expiration handler, the partial run is
// safe — the non-destructive cursor and the per-day finalisation flag let the
// next wake (or foreground open) catch up.
//
// Guard: if IosBleRestore reports the app already owns the band (foreground
// session active), we skip the headless sync to avoid fighting flutter_blue_plus
// for the peripheral, and go straight to derive. This shouldn't happen in
// practice (BGTasks only fire in the background), but it is defensive.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../ble/ios_ble_restore.dart';
import 'background_sync.dart';

class IosBgTask {
  static const _ch = MethodChannel('openstrap/bg_task');
  static const _kProfileKey = 'local_profile_json'; // matches AppState._kProfile
  static bool _busy = false;

  /// Register the method call handler. Call once at startup from main().
  /// No-op on Android.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'run') return null;
      return _run();
    });
  }

  static Future<bool> _run() async {
    if (_busy) {
      debugPrint('[ios-bgtask] already busy — skipping');
      return true;
    }
    _busy = true;
    try {
      // Skip headless BLE if the foreground session already owns the band.
      if (!IosBleRestore.foregroundActive) {
        debugPrint('[ios-bgtask] running headless sync');
        await runHeadlessSync();
      } else {
        debugPrint('[ios-bgtask] foreground active — skip BLE, proceeding to derive');
      }
      // Heavy derive pass (full sleep staging + 24h spectra over all stale days).
      try {
        final profile = await _loadProfile();
        final engine =
            DerivationEngine(log: (l) => debugPrint('[ios-bgtask-derive] $l'));
        await engine.run(profile, heavy: true);
        // Baseline-dirty rescan on the iOS BGTask tick: refresh baseline-dependent
        // scalars on recent finalized days if the rolling baseline moved.
        // Cheap no-op when the baseline signature is unchanged.
        await engine.rescanRecent(profile);
      } catch (e) {
        debugPrint('[ios-bgtask] heavy derive skipped: $e');
      }
      debugPrint('[ios-bgtask] done');
      return true;
    } catch (e) {
      debugPrint('[ios-bgtask] error (ignored): $e');
      // Return true even on error — the non-destructive cursor means a retry is
      // not harmful, but we don't want to spam the OS with failure signals that
      // could cause iOS to throttle our background budget.
      return true;
    } finally {
      _busy = false;
    }
  }

  static Future<Profile> _loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProfileKey);
      if (raw == null) return const Profile();
      return Profile.fromMap((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (_) {
      return const Profile();
    }
  }
}
