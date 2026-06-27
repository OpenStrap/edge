// background_derivation.dart — scheduled HEAVY derivation, app-closed.
//
// The light pass (most-recent affected day) is kicked synchronously from every
// drain/flush completion in AppState (foreground + background BLE wakes) — see
// AppState._afterDrain. THIS file is the SCHEDULED heavy pass (full sleep
// staging + 24-h spectra over every stale day).
//
//   Android: a real OS-scheduled WorkManager periodic job (constrained to when
//            charging + idle is preferred). WorkManager genuinely runs us in a
//            background isolate even when the app is killed.
//
//   iOS:     HONEST CAVEAT — heavy compute on iOS is NOT guaranteed.
//            BackgroundTasks.swift registers "wtf.openstrap.edge.bgsync" as a
//            BGProcessingTask and ios_bg_task.dart handles the run→Dart callout
//            (sync + heavy derive). iOS decides if/when to run it (idle + power
//            preferred; force-quit apps never run background tasks at all).
//            Reliable iOS coverage: (a) the light pass during CoreBluetooth-
//            restoration BLE wakes (IosBleRestore), (b) BGProcessingTask when iOS
//            grants budget (IosBgTask), and (c) finalize-on-foreground when the
//            app next opens. We do NOT pretend the BGTask is guaranteed.
//
// The WorkManager callback runs in its OWN isolate with no Provider/UI — it reads
// the profile straight from shared_preferences and drives DerivationEngine, which
// keeps all DB I/O on that (its own main) isolate and offloads the pure pipeline
// via Isolate.run.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'derivation_engine.dart';
import 'profile.dart';

const String _kHeavyTask = 'openstrap.derive.heavy';
const String _kProfileKey = 'local_profile_json'; // mirrors AppState._kProfile

/// The WorkManager entry point. MUST be a top-level / static fn with the
/// @pragma so it survives tree-shaking in the background isolate.
@pragma('vm:entry-point')
void derivationDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final profile = await _loadProfile();
      final engine = DerivationEngine(log: (m) => debugPrint('[bg-derive] $m'));
      await engine.run(profile, heavy: true);
      // Baseline-dirty rescan on the scheduled tick: refresh baseline-dependent
      // scalars on recent finalized days when the rolling baseline has moved.
      // Cheap no-op when the baseline signature is unchanged.
      await engine.rescanRecent(profile);
      return true;
    } catch (e, st) {
      debugPrint('[bg-derive] failed: $e\n$st');
      return true; // don't thrash retries; the next run catches up.
    }
  });
}

Future<Profile> _loadProfile() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfileKey);
    if (raw == null) return const Profile();
    final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return Profile.fromMap(m);
  } catch (_) {
    return const Profile();
  }
}

/// Initialize + schedule the heavy derivation. Call once at app startup.
/// No-op-safe: failures are swallowed (compute still happens on drain hooks +
/// on foreground).
class BackgroundDerivation {
  static Future<void> init() async {
    // Android only: WorkManager has no iOS background-fetch guarantee for heavy
    // compute. On iOS we rely on the drain-hook light pass + foreground finalize.
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().initialize(derivationDispatcher);
      await Workmanager().registerPeriodicTask(
        _kHeavyTask,
        _kHeavyTask,
        frequency: const Duration(hours: 6),
        constraints: Constraints(
          networkType: NetworkType.notRequired,
          requiresBatteryNotLow: true,
          // Prefer running while charging/idle so heavy 24-h spectra + staging
          // don't tax the battery during active use.
          requiresCharging: false,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('[bg-derive] schedule failed: $e');
    }
  }
}
