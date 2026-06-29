// companion_client.dart — the ONLY network client for the slim companion backend
// (openstrap-companion). Distinct from backend_client.dart, which is the one-shot
// existing-user IMPORT client. This carries the OPT-IN, consent-gated channels:
//   • POST /consent        — record a grant/revoke (called when a toggle flips)
//   • POST /telemetry      — a batch of crash/error/device records
//   • POST /health/upload  — the full local .db (gzipped), once/day on Wi-Fi+charge
//   • GET  /app/status     — OTA pointer + banner + the live Terms version
//
// Everything is anchored to an anonymous install id (device_id); no account
// required. The base URL is a build-time `COMPANION_URL` define (the public repo
// bakes in nothing) with an optional runtime override, mirroring BackendClient.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Build-time companion URL (`--dart-define=COMPANION_URL=...`). Empty when unset.
const String _buildCompanionUrl =
    String.fromEnvironment('COMPANION_URL', defaultValue: '');

class CompanionClient {
  /// Optional runtime override (Settings), loaded from prefs by AppState.
  static String? overrideUrl;

  /// Effective base: runtime override → build-time `COMPANION_URL` → '' (off).
  static String get effectiveBase {
    final o = overrideUrl?.trim();
    if (o != null && o.isNotEmpty) return _normalize(o);
    return _normalize(_buildCompanionUrl);
  }

  static String _normalize(String u) =>
      u.endsWith('/') ? u.substring(0, u.length - 1) : u;

  /// True when a companion URL is configured (else every call is a silent no-op).
  static bool get configured => effectiveBase.isNotEmpty;

  static final http.Client _http = http.Client();

  static Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('$effectiveBase$path').replace(queryParameters: q);

  /// POST /consent — record a grant/revoke for a scope. Best-effort (returns false
  /// on any failure; the local toggle is the source of truth either way).
  static Future<bool> postConsent({
    required String deviceId,
    required String scope, // 'telemetry' | 'health_data'
    required bool granted,
    int? termsVersion,
    String? userId,
  }) async {
    if (!configured) return false;
    try {
      final r = await _http
          .post(_u('/consent'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'device_id': deviceId,
                'scope': scope,
                'granted': granted,
                if (termsVersion != null) 'terms_version': termsVersion,
                if (userId != null) 'user_id': userId,
              }))
          .timeout(const Duration(seconds: 10));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// POST /telemetry — a batch of records with a shared device snapshot. Returns
  /// the count the server accepted (0 on failure). The caller clears its outbox
  /// only on a successful (>=0 with 2xx) send.
  static Future<bool> postTelemetry({
    required String deviceId,
    String? userId,
    int? consentVersion,
    required Map<String, dynamic> device,
    required List<Map<String, dynamic>> events,
  }) async {
    if (!configured || events.isEmpty) return false;
    try {
      final r = await _http
          .post(_u('/telemetry'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'device_id': deviceId,
                if (userId != null) 'user_id': userId,
                if (consentVersion != null) 'consent_version': consentVersion,
                'device': device,
                'events': events,
              }))
          .timeout(const Duration(seconds: 15));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// POST /health/upload — the gzipped full local .db. Metadata rides query params
  /// (the body is the raw gzip blob). Returns true on a 2xx.
  static Future<bool> uploadHealthDb({
    required String deviceId,
    required List<int> gzBytes,
    String? userId,
    int? consentVersion,
    String? appVersion,
  }) async {
    if (!configured) return false;
    try {
      final r = await _http
          .post(
            _u('/health/upload', {
              'device_id': deviceId,
              'gz': '1',
              if (userId != null) 'user_id': userId,
              if (consentVersion != null) 'consent_version': '$consentVersion',
              if (appVersion != null) 'app_version': appVersion,
            }),
            headers: const {'content-type': 'application/gzip'},
            body: gzBytes,
          )
          .timeout(const Duration(seconds: 60));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// GET /app/status — { update, banner, terms }. null on failure.
  static Future<Map<String, dynamic>?> getStatus() async {
    if (!configured) return null;
    try {
      final r = await _http
          .get(_u('/app/status'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(r.body);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}
