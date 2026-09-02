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

  /// Whether storage is actually available, i.e. whether a `getX` default is
  /// "the key is unset" or "we cannot see what you chose".
  ///
  /// For a tab index those are the same answer. For a CONSENT they are not:
  /// an on-by-default switch read through unavailable storage would send on
  /// behalf of somebody who turned it off. Anything gating an outbound call
  /// checks this first — see `offLookupAllowed`.
  static bool get loaded => _sp != null;

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

  /// The same write, with SharedPreferences' own acknowledgement handed back —
  /// false when there is no storage, or when the platform refused it.
  ///
  /// For a tab index nobody can be hurt by a write that quietly failed. For a
  /// CONSENT they can: SharedPreferences updates its cache OPTIMISTICALLY and
  /// never rolls it back, so a failed revocation reads as off for the rest of
  /// the session and is back ON at the next launch, with nobody told. The one
  /// caller that must know is `setOffLookupAllowed`.
  /// A THROW is the same answer as a false: the write did not land. Letting it
  /// propagate is worse than useless here — it skips the caller's "we could not
  /// save that" warning and takes out the flow that was asking (the scanner
  /// exits before the camera opens), so the one path that exists to TELL the
  /// person never runs. Failure is reported, never raised.
  static Future<bool> setBoolAcked(String key, bool value) async {
    try {
      return await _sp?.setBool(key, value) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── selection keys (one namespace; keep them disjoint) ──────────────────────
  static const String shellTab = 'ui.shell_tab';
  static const String recapRange = 'ui.recap_range';
  static const String workoutsRange = 'ui.workouts_range';

  /// Automatic local backup: the chosen cadence, and when one last ran.
  static const String backupCadence = 'backup.cadence';
  static const String backupLastRunMs = 'backup.last_run_ms';

  /// Developer mode. Off unless somebody deliberately turned it on — it is a
  /// tool for us, not a feature, so it has no switch in the normal settings
  /// list and nothing reads it except the surfaces it reveals.
  static const String devMode = 'dev.mode';

  /// Per-metric range toggle on the shared MetricScreen (Today/Week/Month/3M).
  /// Keyed by the metric id so Sleep / Heart / Body each remember independently.
  static String metricTab(String metric) => 'ui.metric_tab.$metric';

  /// One-shot: a second framed band's ASK provisioning is requested and should
  /// run at the next start-up, before anything touches flutter_blue_plus (the
  /// only moment the ASK picker can show — see AppState._provisionAdditionalAccessory).
  /// Cleared in a `finally` regardless of outcome.
  static const String kAskAddPendingKey = 'ble.ask_add_pending';
}
