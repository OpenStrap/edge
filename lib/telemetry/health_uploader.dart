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
  Future<bool> maybeUpload({required bool consented}) async {
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
