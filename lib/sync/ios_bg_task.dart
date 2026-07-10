// ios_bg_task.dart — iOS BGProcessingTask + BGAppRefreshTask Dart handler.
//
// Native (BgSyncScheduler.swift) calls the `openstrap/bg_task` channel method
// `run` when iOS opportunistically wakes the app for a background task.
//   - BGProcessingTask (no arguments): FULL profile — runHeadlessSync()
//     (connect → flash offload → local store → disconnect → light derive)
//     followed by a heavy DerivationEngine pass (full sleep staging + 24h
//     spectra).
//   - BGAppRefreshTask ({'mode': 'sync'}): LIGHT profile — headless sync only,
//     NO heavy derivation (a refresh task's ~30 s budget can't fit it; the
//     light per-drain derive inside runHeadlessSync still runs).
// Returns true to signal completion.
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
import 'headless_gate.dart';

class IosBgTask {
  static const _ch = MethodChannel('openstrap/bg_task');
  static const _kProfileKey = 'local_profile_json'; // matches AppState._kProfile

  /// When the FOREGROUND app owns the band, a BG-task wake must not open a
  /// competing headless connection — but it should still pull the flash backlog
  /// over the EXISTING live link. AppState installs its floored catch-up pull
  /// here (see AppState.foregroundCatchUp); null until an AppState exists.
  static Future<void> Function()? foregroundPull;

  /// Register the method call handler. Call once at startup from main().
  /// No-op on Android.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'run') return null;
      // BGAppRefreshTask passes {'mode': 'sync'} → LIGHT profile (sync only).
      final args = call.arguments;
      final mode = args is Map ? args['mode']?.toString() : null;
      return _run(syncOnly: mode == 'sync');
    });
  }

  static Future<bool> _run({required bool syncOnly}) async {
    // ONE shared gate across every headless entry point (BGProcessingTask,
    // BGAppRefreshTask, the BLE-restore wake) — see HeadlessSyncGate. A busy
    // gate means another wake is already syncing: skip, report success.
    final ran = await HeadlessSyncGate.tryRun<bool>(
        syncOnly ? 'bg_refresh' : 'bg_task', () async {
      try {
        // Skip headless BLE if the foreground session already owns the band.
        if (!IosBleRestore.foregroundActive) {
          debugPrint('[ios-bgtask] running headless sync (syncOnly=$syncOnly)');
          await runHeadlessSync();
        } else {
          // The foreground app owns the band: no headless BLE (it would fight
          // flutter_blue_plus for the peripheral) — but still use this OS-granted
          // budget to pull the flash backlog over the app's own live connection.
          debugPrint(
              '[ios-bgtask] foreground owns the band — catch-up over live link');
          try {
            await foregroundPull?.call();
          } catch (e) {
            debugPrint('[ios-bgtask] foreground pull failed (ignored): $e');
          }
        }
        if (!syncOnly) {
          // Heavy derive pass (full sleep staging + 24h spectra, stale days).
          try {
            final profile = await _loadProfile();
            final engine = DerivationEngine(
                log: (l) => debugPrint('[ios-bgtask-derive] $l'));
            await engine.run(profile, heavy: true);
            // Baseline-dirty rescan on the iOS BGTask tick: refresh
            // baseline-dependent scalars on recent finalized days if the
            // rolling baseline moved. Cheap no-op when unchanged.
            await engine.rescanRecent(profile);
          } catch (e) {
            debugPrint('[ios-bgtask] heavy derive skipped: $e');
          }
        } else {
          // Honest best attempt: run a light derive pass during BGAppRefreshTask.
          // This keeps today's metrics fresh without tripping the CPU watchdog.
          try {
            final profile = await _loadProfile();
            final engine = DerivationEngine(
                log: (l) => debugPrint('[ios-bgrefresh-derive] $l'));
            await engine.run(profile, heavy: false);
          } catch (e) {
            debugPrint('[ios-bgrefresh] light derive skipped: $e');
          }
        }
        debugPrint('[ios-bgtask] done (syncOnly=$syncOnly)');
        return true;
      } catch (e) {
        debugPrint('[ios-bgtask] error (ignored): $e');
        // Return true even on error — the non-destructive cursor means a retry
        // is not harmful, but we don't want to spam the OS with failure signals
        // that could cause iOS to throttle our background budget.
        return true;
      }
    });
    return ran ?? true; // gate busy → another wake is already doing the work
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
