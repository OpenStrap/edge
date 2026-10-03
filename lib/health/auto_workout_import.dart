// auto_workout_import.dart — opt-in background bring-in of Health workouts.
//
// The manual Import button asks permission ON THE TAP and then reads the
// source's whole shareable window, replacing by uuid (a second pass updates
// rows instead of stacking copies — see HealthWorkoutImporter.sync). That is
// the right shape for a button and the wrong shape for a background job:
// nothing may prompt from a cadence pass, and an unconditional read on every
// drain is exactly the churn the battery audit removed elsewhere.
//
// So auto-import is:
//   • OPT-IN, off by default — same rule as every outbound path in this app.
//     The switch lives next to the manual Import button; turning it ON is a
//     user tap, so THAT is the moment permission may be asked.
//   • NON-PROMPTING thereafter — a cadence pass only reads when the store
//     already granted WORKOUT read (checked without prompting). Until one
//     manual import has been approved, auto-import silently does nothing.
//   • THROTTLED — at most one full-window read per hour (see
//     [kAutoWorkoutImportInterval]); a zero-row read still stamps the
//     attempt, or a store that holds nothing would be re-read on every
//     foreground pass.
//   • BEST-EFFORT — never throws into the caller; failures just leave the
//     manual button as the fallback it always was.

import 'package:shared_preferences/shared_preferences.dart';

import 'health_import_state.dart';
import 'health_workout_import.dart';

const String kAutoWorkoutImportPref = 'health_auto_import_workouts';
const String kAutoWorkoutImportLastMs = 'health_auto_import_last_ms';

/// How often auto-import may do a full-window read. Workouts are not a
/// live metric; an hour keeps the store load trivial while a finished run
/// lands the next time the app comes to the foreground.
const Duration kAutoWorkoutImportInterval = Duration(hours: 1);

/// The decision, PURE — everything the runner needs to have already checked.
bool shouldAutoImport({
  required bool enabled,
  required bool permissionGranted,
  required DateTime? lastAttempt,
  required DateTime now,
  Duration interval = kAutoWorkoutImportInterval,
}) {
  if (!enabled || !permissionGranted) return false;
  if (lastAttempt == null) return true;
  return now.difference(lastAttempt) >= interval;
}

enum AutoImportOutcome {
  /// The switch is off (or the store was never granted) — nothing ran.
  skipped,

  /// Inside [kAutoWorkoutImportInterval] of the last attempt.
  throttled,

  /// A read ran; [workouts] says what came in.
  ran,
}

class AutoWorkoutImport {
  AutoWorkoutImport._();

  /// DEFAULT ON. The sweep is pull-based, silent and throttled to one read
  /// per hour; until the user grants WORKOUT access (one tap on the refresh
  /// button) it reads nothing (HealthKit hands an ungranted read an empty
  /// list), so there is no consent reason to ship it off.
  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance())
          .getBool(kAutoWorkoutImportPref) ??
      true;

  static Future<void> setEnabled(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(kAutoWorkoutImportPref, on);

  /// Runs the auto path. Safe to call unawaited from anywhere; returns what
  /// happened for callers that surface it.
  static Future<AutoImportOutcome> maybeRun({
    HealthWorkoutImporter? importer,
    DateTime Function()? nowFn,
  }) async {
    try {
      final now = (nowFn ?? DateTime.now)();
      final prefs = await SharedPreferences.getInstance();
      final enabled = await isEnabled();
      final lastMs = prefs.getInt(kAutoWorkoutImportLastMs);
      // NON-PROMPTING probe: hasPermissions only. A denied/undecided store
      // means the user has not approved auto reads yet — the manual button's
      // tap is where that question gets asked, never here.
      if (!enabled) return AutoImportOutcome.skipped;
      final granted = await (importer ?? HealthWorkoutImporter())
          .hasReadPermission();
      // An ungranted store is SKIPPED, not throttled: it is waiting on one
      // manual tap to grant access, not on the clock.
      if (!granted) return AutoImportOutcome.skipped;
      final throttled = !shouldAutoImport(
        enabled: true,
        permissionGranted: true,
        lastAttempt: lastMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastMs),
        now: now,
      );
      if (throttled) return AutoImportOutcome.throttled;
      await prefs.setInt(
          kAutoWorkoutImportLastMs, now.millisecondsSinceEpoch);
      final res = await (importer ?? HealthWorkoutImporter()).sync();
      // Only a read that actually brought rows advances the IMPORTED cursor —
      // same rule as the button: marking a zero/denied read as done would put
      // the UI to sleep on someone who said no.
      if (res.workouts > 0) {
        await markImported(HealthImport.workouts);
      }
      return AutoImportOutcome.ran;
    } catch (_) {
      return AutoImportOutcome.skipped;
    }
  }
}
