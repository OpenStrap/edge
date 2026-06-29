// UpdateService — the Android OTA mechanics. There's no app store in the loop
// (the app is sideloaded), so we ARE the update channel: download the signed APK
// from the backend's update pointer and hand it to the system installer. The new
// APK must be signed with the same release key or Android refuses the update —
// which is already true for our CI-built GitHub releases.
//
// iOS can't sideload-install, so [supported] is false there and the UI hides OTA.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cloud/companion_client.dart';
import '../models/app_status.dart';

/// A coarse progress event the UI renders.
class OtaProgress {
  final String phase; // 'downloading' | 'installing' | 'error'
  final int percent;  // 0..100 while downloading
  final String? message;
  const OtaProgress(this.phase, {this.percent = 0, this.message});
}

class UpdateService {
  /// Only Android can install an APK in-app.
  static bool get supported => Platform.isAndroid;

  /// Fetch the OTA update pointer + admin alert banner from the companion
  /// backend's public, UNAUTHENTICATED `GET /app/status` — the single URL the app
  /// uses for everything. Best-effort: returns null on any failure (no companion
  /// URL configured, offline, bad JSON) so the caller simply skips the update
  /// prompt / banner.
  static Future<AppStatus?> fetchStatus() async {
    final base = CompanionClient.effectiveBase;
    if (base.isEmpty) return null;
    try {
      final resp = await http
          .get(Uri.parse('$base/app/status'))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      return AppStatus.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Download + launch the system installer for [apkUrl]. Emits progress; the
  /// terminal 'installing' event means Android's install dialog is up. Errors
  /// arrive either as an 'error' [OtaProgress] (known OTA failures) or on the
  /// stream's error channel (unexpected) — the UI should fall back to
  /// [openInBrowser] in both cases.
  static Stream<OtaProgress> install(String apkUrl) {
    if (!supported) {
      return Stream.value(const OtaProgress('error', message: 'OTA is Android-only'));
    }
    return OtaUpdate()
        .execute(apkUrl, destinationFilename: 'openstrap-update.apk')
        .map((e) {
      switch (e.status) {
        case OtaStatus.DOWNLOADING:
          return OtaProgress('downloading', percent: int.tryParse(e.value ?? '0') ?? 0);
        case OtaStatus.INSTALLING:
          return const OtaProgress('installing', percent: 100);
        default:
          // PERMISSION_NOT_GRANTED_ERROR, DOWNLOAD_ERROR, CHECKSUM_ERROR, etc.
          return OtaProgress('error', message: '${e.status} ${e.value ?? ''}'.trim());
      }
    });
  }

  /// Fallback: open the APK / release URL in the browser so the user can
  /// download + install manually (also the only path on a denied install perm).
  static Future<bool> openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
