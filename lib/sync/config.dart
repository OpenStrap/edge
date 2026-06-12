// Local persisted config: the chosen backend, the paired band (LOCAL only — no
// server device table), and the auth session (JWT access + refresh).

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// The band the user paired. Persisted so we auto-reconnect on every launch.
/// LOCAL ONLY — the server never remembers a device; we re-pair after sign-in.
class PairedDevice {
  static const String _kRemoteId = 'paired_remote_id';
  static const String _kSerial = 'paired_serial';

  final String remoteId; // BLE remote id (iOS: per-install UUID; Android: MAC)
  final String? serial;
  PairedDevice(this.remoteId, this.serial);

  static Future<PairedDevice?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kRemoteId);
    if (id == null || id.isEmpty) return null;
    return PairedDevice(id, prefs.getString(_kSerial));
  }

  static Future<void> save(String remoteId, String? serial) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemoteId, remoteId);
    if (serial != null) await prefs.setString(_kSerial, serial);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRemoteId);
    await prefs.remove(_kSerial);
  }
}

/// Which backend the user picked (default Worker or self-hosted) + the local
/// band serial used as `device_id` in uploads. Data is scoped server-side by
/// the JWT's user — `deviceId` is just a sub-key under the user.
class BackendConfig {
  static const String _kUrl = 'backend_url';
  static const String _kChosen = 'backend_chosen';
  static const String _kDeviceId = 'device_id';

  // Injected at build time from BACKEND_URL (see .env + --dart-define-from-file,
  // and the CI workflow). Empty when not provided — onboarding then asks the user
  // for their own self-hosted backend.
  static const String defaultUrl =
      String.fromEnvironment('BACKEND_URL');

  String url;
  bool chosen; // user has confirmed a backend (passed the first-launch screen)
  String deviceId;

  BackendConfig({required this.url, required this.chosen, required this.deviceId});

  static Future<BackendConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return BackendConfig(
      url: prefs.getString(_kUrl) ?? defaultUrl,
      chosen: prefs.getBool(_kChosen) ?? false,
      deviceId: prefs.getString(_kDeviceId) ?? 'whoop-unknown',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, url);
    await prefs.setBool(_kChosen, chosen);
    await prefs.setString(_kDeviceId, deviceId);
  }
}

/// Auth session: JWT access (24h) + refresh (30d) + cached user profile.
class Session {
  static const String _kAccess = 'access_jwt';
  static const String _kRefresh = 'refresh_token';
  static const String _kUser = 'user_json';

  String? accessJwt;
  String? refreshToken;
  Map<String, dynamic>? user;

  Session({this.accessJwt, this.refreshToken, this.user});

  bool get isValid =>
      (accessJwt?.isNotEmpty ?? false) && (refreshToken?.isNotEmpty ?? false);

  static Future<Session> load() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(_kUser);
    return Session(
      accessJwt: prefs.getString(_kAccess),
      refreshToken: prefs.getString(_kRefresh),
      user: u != null ? jsonDecode(u) as Map<String, dynamic> : null,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (accessJwt != null) await prefs.setString(_kAccess, accessJwt!);
    if (refreshToken != null) await prefs.setString(_kRefresh, refreshToken!);
    if (user != null) await prefs.setString(_kUser, jsonEncode(user));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    await prefs.remove(_kUser);
    accessJwt = null;
    refreshToken = null;
    user = null;
  }
}
