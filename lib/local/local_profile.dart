// LocalProfile — the on-device profile for LOCAL mode (no account, no email).
// Mirrors the cloud `session.user` map shape (name/sex/age/height_cm/weight_kg +
// derived resting_hr/max_hr) so every screen, the strain/calorie math, and the
// LocalPipeline can read profile fields the SAME way they do in cloud mode
// (`app.user['age']`, etc.). Persisted in SharedPreferences as one JSON blob.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalProfile {
  static const _key = 'local_profile';

  /// Load the stored local profile (the `user`-shaped map), or null if unset.
  static Future<Map<String, dynamic>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  /// Merge [fields] into the stored profile (read-modify-write) and persist.
  /// Returns the merged map. Mirrors cloud PATCH /profile semantics locally.
  static Future<Map<String, dynamic>> patch(Map<String, dynamic> fields) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await load() ?? <String, dynamic>{};
    current.addAll(fields);
    await prefs.setString(_key, jsonEncode(current));
    return current;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
