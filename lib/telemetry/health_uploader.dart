// health_uploader.dart — OPT-IN contribution of the FULL local .db (raw + derived)
// to the companion backend. Heavy, so it runs at most once/day and only under good
// conditions (the cadence design): consent ON + Wi-Fi + charging + >24h since the
// last upload. The .db is gzipped before sending; the server keeps only the latest
// per device, so storage stays bounded. Entirely best-effort — never throws into
// the caller (the derive/BLE path).

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud/companion_client.dart';
import '../data/db.dart';

/// Compile-time gate for the whole health-data-contribution feature (this
/// upload path + the "Contribute my health data" toggle in Settings and
/// onboarding). Defaults OFF, same convention as [kSideloadOtaEnabled] in
/// update_service.dart.
///
/// Two-tier by release channel (see docs/privacy.html's "GitHub releases"
/// section, the user-facing policy): OFF for any official App Store/Play
/// Store submission (once that pipeline exists it must pass
/// `ENABLE_HEALTH_DATA_CONTRIBUTION=false` explicitly), ON for the GitHub
/// Releases build (.github/workflows/build.yml, both android + ios jobs) —
/// but "ON" here only means the feature EXISTS in that binary; actual
/// upload additionally requires the user to explicitly flip the in-app
/// toggle, which defaults off and is itself hidden whenever this flag is
/// false. Uploading someone's entire raw + derived health history to a
/// backend is by far the biggest privacy/compliance surface this app could
/// have, so keep the App Store/Play Store channel's "we do not collect
/// your health data" promise (docs/privacy.html) true by construction of
/// the CI config, not contingent on nobody flipping this default later.
///
/// This flag exists purely because the code is open source: an independent
/// developer compiling their OWN build from this repo can also opt in and
/// point it at a backend of their own choosing. That is their build and
/// their responsibility, not something our privacy policy governs.
///   flutter build apk --dart-define=ENABLE_HEALTH_DATA_CONTRIBUTION=true
const bool kHealthDataContributionEnabled = bool.fromEnvironment(
  'ENABLE_HEALTH_DATA_CONTRIBUTION',
  defaultValue: false,
);

class HealthUploader {
  HealthUploader._();
  static final HealthUploader instance = HealthUploader._();

  static const String _kLastUpload = 'health_upload_last_ts'; // unix sec
  static const int _minIntervalSec = 24 * 60 * 60; // once/day max

  /// Anchors stamped on the upload (AppState sets these).
  String? deviceId;
  String? userId;
  int consentVersion = 1;

  bool _running = false;

  /// Attempt an upload if [consented] AND on Wi-Fi AND charging AND >24h since the
  /// last one. Returns true if an upload actually happened.
  ///
  /// Defense in depth: even though the Settings/onboarding toggle that sets
  /// [consented] is itself hidden when [kHealthDataContributionEnabled] is
  /// false, gate the actual network call on the same flag directly — no
  /// build without the flag should ever attempt this upload regardless of
  /// how `consented` ended up true (e.g. a stale local pref).
  Future<bool> maybeUpload({required bool consented}) async {
    if (!kHealthDataContributionEnabled) return false;
    if (!consented || !CompanionClient.configured || _running) return false;
    if (deviceId == null) return false;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLastUpload) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (now - last < _minIntervalSec) return false;

      if (!await _onWifi()) return false;
      if (!await _charging()) return false;

      // Snapshot the DB, gzip it, upload, record the timestamp.
      final path = await LocalDb.exportCopy();
      final file = File(path);
      try {
        final bytes = await file.readAsBytes();
        final gz = gzip.encode(bytes);
        String? appVersion;
        try {
          appVersion = (await PackageInfo.fromPlatform()).version;
        } catch (_) {}
        final ok = await CompanionClient.uploadHealthDb(
          deviceId: deviceId!,
          gzBytes: gz,
          userId: userId,
          consentVersion: consentVersion,
          appVersion: appVersion,
        );
        if (ok) {
          await prefs.setInt(_kLastUpload, now);
          return true;
        }
        return false;
      } finally {
        if (await file.exists()) await file.delete(); // don't leave the copy around
      }
    } catch (_) {
      return false; // best-effort
    } finally {
      _running = false;
    }
  }

  Future<bool> _onWifi() async {
    try {
      final res = await Connectivity().checkConnectivity();
      return res.contains(ConnectivityResult.wifi) ||
          res.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false; // unknown → don't burn mobile data
    }
  }

  Future<bool> _charging() async {
    try {
      final s = await Battery().batteryState;
      return s == BatteryState.charging || s == BatteryState.full;
    } catch (_) {
      return false;
    }
  }
}
