// Per-screen payload cache. Stores the last successful raw JSON payload per
// screen key in shared_preferences so screens render instantly + offline with
// an "updated Xm ago" stamp. Keyed (best-effort) per user via the email so a
// re-login doesn't show another account's cached data.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CachedPayload {
  final Object? data; // decoded JSON (Map or List)
  final DateTime fetchedAt;
  const CachedPayload(this.data, this.fetchedAt);

  /// "updated 3m ago" style string.
  String get ageLabel {
    final d = DateTime.now().difference(fetchedAt);
    if (d.inSeconds < 45) return 'updated just now';
    if (d.inMinutes < 60) return 'updated ${d.inMinutes}m ago';
    if (d.inHours < 24) return 'updated ${d.inHours}h ago';
    return 'updated ${d.inDays}d ago';
  }
}

class InsightsCache {
  static String _key(String screen, String? userKey) =>
      'cache:${userKey ?? 'anon'}:$screen';

  /// Save a successful payload for [screen]. Swallows errors (cache is best-effort).
  static Future<void> save(String screen, Object? data, {String? userKey}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(screen, userKey),
        jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'd': data}),
      );
    } catch (_) {}
  }

  /// Load the last cached payload for [screen], or null.
  static Future<CachedPayload?> load(String screen, {String? userKey}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(screen, userKey));
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return CachedPayload(
        m['d'],
        DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
      );
    } catch (_) {
      return null;
    }
  }
}
