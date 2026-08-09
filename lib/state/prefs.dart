// Prefs — a tiny synchronous façade over SharedPreferences for UI selection
// state (selected tab, per-metric range toggles, etc.). Local-first, no auth.
//
// Screens need to RESTORE a saved selection in initState() without an async gap
// (which would flash the default first). So we keep a cached SharedPreferences
// instance, loaded once at startup via [ensureLoaded] (awaited in main before
// runApp). Reads are then synchronous; writes persist in the background.
//
// If a screen is somehow built before [ensureLoaded] completes, reads fall back
// to the provided default — never throws, never blocks.

import 'package:shared_preferences/shared_preferences.dart';

class Prefs {
  Prefs._();

  static SharedPreferences? _sp;

  /// Load + cache the SharedPreferences instance. Call once before runApp.
  /// Idempotent and best-effort — failures leave reads on their defaults.
  static Future<void> ensureLoaded() async {
    try {
      _sp ??= await SharedPreferences.getInstance();
    } catch (_) {/* reads fall back to defaults */}
  }

  // ── synchronous read (fall back to default until loaded) ────────────────────
  static int getInt(String key, int fallback) => _sp?.getInt(key) ?? fallback;
  static String getString(String key, String fallback) =>
      _sp?.getString(key) ?? fallback;
  static bool getBool(String key, bool fallback) =>
      _sp?.getBool(key) ?? fallback;

  // ── fire-and-forget write (kept in sync with the cache for immediate reads) ──
  static void setInt(String key, int value) {
    _sp?.setInt(key, value);
  }

  static void setString(String key, String value) {
    _sp?.setString(key, value);
  }

  static void setBool(String key, bool value) {
    _sp?.setBool(key, value);
  }

  // ── selection keys (one namespace; keep them disjoint) ──────────────────────
  static const String shellTab = 'ui.shell_tab';
  static const String recapRange = 'ui.recap_range';
  static const String workoutsRange = 'ui.workouts_range';

  /// Automatic local backup: the chosen cadence, and when one last ran.
  static const String backupCadence = 'backup.cadence';
  static const String backupLastRunMs = 'backup.last_run_ms';

  /// Per-metric range toggle on the shared MetricScreen (Today/Week/Month/3M).
  /// Keyed by the metric id so Sleep / Heart / Body each remember independently.
  static String metricTab(String metric) => 'ui.metric_tab.$metric';
}
