// backend_client.dart — thin client for the v2 cloud backend, used ONLY by the
// existing-user onboarding import. The running app is fully local (cloud excised);
// this is the one place that talks to the network, to pull a returning v2 user's
// DERIVED history once at onboarding.
//
// Auth: POST /auth/request-otp {email} (404 ⇒ no account) → POST /auth/verify-otp
// {email, code} → {access_jwt, refresh_token, user}. Subsequent reads send
// `Authorization: Bearer <access_jwt>`.
//
// Base URL resolution (the open-source repo must NOT bake in a specific instance):
//   1. a RUNTIME override the user set in-app ([BackendClient.overrideUrl]), else
//   2. the BUILD-time `BACKEND_URL` (CI writes it from a repo secret into .env →
//      `flutter build --dart-define-from-file=.env`; see .github/workflows/build.yml),
//   3. else empty → the existing-user cloud import shows "not configured" and the
//      user can point it at their own instance in Settings.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Build-time backend URL (CI `BACKEND_URL` secret via --dart-define-from-file).
/// Empty when not provided — never a hard-coded personal instance.
const String _buildBackendUrl =
    String.fromEnvironment('BACKEND_URL', defaultValue: '');

/// A non-2xx response (or an explicit `{error}` body) from the backend.
class BackendException implements Exception {
  final int status;
  final String message;
  BackendException(this.status, this.message);
  @override
  String toString() => 'BackendException($status): $message';
}

/// The result of a successful OTP verification.
class CloudSession {
  final String accessJwt;
  final String refreshToken;
  final Map<String, dynamic> user; // {id,email,name,age,height_cm,weight_kg,sex,...}
  CloudSession(this.accessJwt, this.refreshToken, this.user);
}

class BackendClient {
  /// User-set runtime override (Settings → Backend URL), loaded from prefs at
  /// startup by AppState. Takes precedence over the build-time URL.
  static String? overrideUrl;

  /// The effective backend base: runtime override → build-time `BACKEND_URL` →
  /// '' (unconfigured).
  static String get effectiveBase {
    final o = overrideUrl?.trim();
    if (o != null && o.isNotEmpty) return _normalize(o);
    return _normalize(_buildBackendUrl);
  }

  /// Strip a trailing slash so `'$base$path'` never doubles up.
  static String _normalize(String u) =>
      u.endsWith('/') ? u.substring(0, u.length - 1) : u;

  BackendClient({String? base, http.Client? client})
      : base = base ?? effectiveBase,
        _http = client ?? http.Client();

  final String base;
  final http.Client _http;
  String? _jwt;

  bool get configured => base.trim().isNotEmpty;

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('$base$path').replace(queryParameters: q);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (_jwt != null) 'authorization': 'Bearer $_jwt',
      };

  /// Request an OTP for [email]. Returns true if an account exists (code sent),
  /// false if there is no v2 account for that email (404). Throws otherwise.
  Future<bool> requestOtp(String email) async {
    final r = await _http.post(_u('/auth/request-otp'),
        headers: _headers,
        body: jsonEncode({'email': email.trim().toLowerCase()}));
    if (r.statusCode == 404) return false;
    if (r.statusCode >= 400) throw BackendException(r.statusCode, _msg(r));
    return true;
  }

  /// Verify [code] for [email]; stores the JWT for subsequent authed reads.
  Future<CloudSession> verifyOtp(String email, String code) async {
    final r = await _http.post(_u('/auth/verify-otp'),
        headers: _headers,
        body: jsonEncode(
            {'email': email.trim().toLowerCase(), 'code': code.trim()}));
    if (r.statusCode >= 400) throw BackendException(r.statusCode, _msg(r));
    final m = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    _jwt = m['access_jwt'] as String?;
    if (_jwt == null) throw BackendException(r.statusCode, 'No token returned');
    return CloudSession(
      _jwt!,
      (m['refresh_token'] ?? '').toString(),
      ((m['user'] as Map?) ?? const {}).cast<String, dynamic>(),
    );
  }

  // ── authenticated reads (require a prior verifyOtp) ─────────────────────────

  Future<Map<String, dynamic>> getProfile() => _getMap('/profile');

  /// Daily derived rows (the `daily` table) for [from]..[to] (YYYY-MM-DD).
  Future<List<dynamic>> getDailies(String from, String to) =>
      _getList('/strain', {'from': from, 'to': to});

  /// Per-day sleep rows for [from]..[to] (YYYY-MM-DD).
  Future<List<dynamic>> getSleeps(String from, String to) =>
      _getList('/sleep', {'from': from, 'to': to});

  /// Workout sessions in [fromSec]..[toSec] (unix seconds).
  Future<List<dynamic>> getSessions(int fromSec, int toSec) =>
      _getList('/sessions', {'from': '$fromSec', 'to': '$toSec'});

  Future<Map<String, dynamic>> _getMap(String path,
      [Map<String, String>? q]) async {
    final r = await _http.get(_u(path, q), headers: _headers);
    if (r.statusCode >= 400) throw BackendException(r.statusCode, _msg(r));
    final d = jsonDecode(r.body);
    return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<List<dynamic>> _getList(String path, [Map<String, String>? q]) async {
    final r = await _http.get(_u(path, q), headers: _headers);
    if (r.statusCode >= 400) throw BackendException(r.statusCode, _msg(r));
    final d = jsonDecode(r.body);
    return d is List ? d : const [];
  }

  String _msg(http.Response r) {
    try {
      final m = jsonDecode(r.body);
      if (m is Map && m['error'] != null) return m['error'].toString();
    } catch (_) {/* non-JSON body */}
    return 'HTTP ${r.statusCode}';
  }

  void close() => _http.close();
}
