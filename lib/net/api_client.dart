// ApiClient — all backend HTTP. Auth endpoints are unauthenticated; everything
// else goes through `_authed`, which injects the access JWT and, on a 401,
// transparently refreshes once and retries. If refresh fails, it clears the
// session and fires `onLoggedOut` so the UI can route to login gracefully
// (the local upload queue persists and retries after re-login).

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../sync/config.dart';

class ApiException implements Exception {
  final int status;
  final String body;
  ApiException(this.status, this.body);
  @override
  String toString() => 'HTTP $status: $body';
}

class ApiClient {
  final BackendConfig config;
  final Session session;
  final void Function()? onLoggedOut;
  final Duration timeout;

  // One reused client so the upload loop keeps the TLS connection alive instead of
  // re-handshaking per batch (a real win when many batches go out back-to-back).
  final http.Client _client = http.Client();

  ApiClient(this.config, this.session, {this.onLoggedOut})
      : timeout = const Duration(seconds: 60);

  /// Release the connection pool. Call when the client is done (e.g. headless run).
  void close() => _client.close();

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('${config.url}$path').replace(queryParameters: q);

  // ── unauthenticated auth flow ──────────────────────────────────────────────
  Future<Map<String, dynamic>> register({
    required String email,
    String? name,
    int? age,
    double? heightCm,
    double? weightKg,
  }) =>
      _postJson('/auth/register', {
        'email': email,
        if (name != null) 'name': name,
        if (age != null) 'age': age,
        if (heightCm != null) 'height_cm': heightCm,
        if (weightKg != null) 'weight_kg': weightKg,
      });

  Future<Map<String, dynamic>> requestOtp(String email) =>
      _postJson('/auth/request-otp', {'email': email});

  /// Verify OTP → persists the session (access + refresh + user) and returns it.
  Future<Map<String, dynamic>> verifyOtp(String email, String code) async {
    final r = await _postJson('/auth/verify-otp', {'email': email, 'code': code});
    session
      ..accessJwt = r['access_jwt'] as String?
      ..refreshToken = r['refresh_token'] as String?
      ..user = (r['user'] as Map?)?.cast<String, dynamic>();
    await session.save();
    return r;
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body) async {
    final resp = await http
        .post(_u(path),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(timeout);
    final json = _decode(resp.body);
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, json['error']?.toString() ?? resp.body);
    }
    return json;
  }

  // ── token refresh ────────────────────────────────────────────────────────────
  Future<bool> _refresh() async {
    if (!(session.refreshToken?.isNotEmpty ?? false)) return false;
    try {
      final resp = await http
          .post(_u('/auth/refresh'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': session.refreshToken}))
          .timeout(timeout);
      if (resp.statusCode != 200) return false;
      final j = _decode(resp.body);
      session
        ..accessJwt = j['access_jwt'] as String?
        ..refreshToken = (j['refresh_token'] as String?) ?? session.refreshToken;
      await session.save();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── authed request with one transparent refresh+retry ────────────────────────
  Future<http.Response> _authed(
      Future<http.Response> Function(Map<String, String> headers) send) async {
    Map<String, String> hdr() => {
          'Authorization': 'Bearer ${session.accessJwt}',
          'Content-Type': 'application/json',
        };
    var resp = await send(hdr()).timeout(timeout);
    if (resp.statusCode == 401) {
      if (await _refresh()) {
        resp = await send(hdr()).timeout(timeout);
      }
      if (resp.statusCode == 401) {
        await session.clear();
        onLoggedOut?.call();
        throw ApiException(401, 'session expired');
      }
    }
    return resp;
  }

  // ── ingest (per-user; device_id is a local sub-key) ──────────────────────────
  Future<Map<String, dynamic>> ingestBatch(List<String> records) async {
    final resp = await _authed((h) => _client.post(_u('/ingest/batch'),
        headers: h,
        body: jsonEncode({'device_id': config.deviceId, 'records': records})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return _decode(resp.body);
  }

  Future<void> ingestEvents(List<String> events) async {
    final resp = await _authed((h) => _client.post(_u('/ingest/events'),
        headers: h,
        body: jsonEncode({'device_id': config.deviceId, 'events': events})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
  }

  // ── profile ────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getProfile() async {
    final resp = await _authed((h) => _client.get(_u('/profile'), headers: h));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    final u = _decode(resp.body);
    session.user = u;
    await session.save();
    return u;
  }

  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> fields) async {
    final resp = await _authed((h) =>
        http.patch(_u('/profile'), headers: h, body: jsonEncode(fields)));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    final u = _decode(resp.body);
    session.user = u;
    await session.save();
    return u;
  }

  // ── query (insights/history) ─────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchMetrics(int fromTs, int toTs) =>
      _getList('/metrics', {'from': '$fromTs', 'to': '$toTs'});
  Future<List<Map<String, dynamic>>> fetchSleep() => _getList('/sleep');
  Future<List<Map<String, dynamic>>> fetchDaily() => _getList('/strain'); // daily table
  Future<Map<String, dynamic>> fetchTrends() async {
    final resp = await _authed((h) => _client.get(_u('/trends'), headers: h));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return _decode(resp.body);
  }

  // ── production insights endpoints (UI screens) ───────────────────────────────
  // All JWT-authed via _authed. Responses parsed defensively by the model layer.

  /// GET /today → single object of metric fields + a `flags` blob.
  Future<Map<String, dynamic>> getToday() => _getObj('/today');

  /// GET /sleep?from&to → list of nightly rows (newest first).
  Future<List<Map<String, dynamic>>> getSleep({int? from, int? to}) =>
      _getList('/sleep', _range(from, to));

  /// GET /strain?from&to → list of daily rows (newest first).
  Future<List<Map<String, dynamic>>> getStrain({int? from, int? to}) =>
      _getList('/strain', _range(from, to));

  /// GET /sessions?from&to → list of auto-detected workouts.
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) =>
      _getList('/sessions', _range(from, to));

  /// GET /trends?days=90 → object of named series + baseline + anomaly.
  Future<Map<String, dynamic>> getTrends({int days = 90}) =>
      _getObj('/trends', {'days': '$days'});

  /// GET /history?range=7d|30d|90d|365d → per-metric series + summaries
  /// (avg/min/max/total/delta-vs-prior-period/trend) + calendar + zone totals.
  Future<Map<String, dynamic>> getHistory({String range = '30d'}) =>
      _getObj('/history', {'range': range});

  // ── journal + correlation engine ──────────────────────────────────────────
  /// GET /journal?range=30d → [{date, tags[], note}].
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) =>
      _getList('/journal', {'range': range});

  /// POST /journal — upsert a day's tags + note (empty both = delete).
  Future<void> postJournal(String date, List<String> tags, String note) async {
    final resp = await _authed((h) => _client.post(_u('/journal'),
        headers: h, body: jsonEncode({'date': date, 'tags': tags, 'note': note})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
  }

  /// GET /journal/insights?range=90d → {range, insights:[{tag, days, effects[]}]}.
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      _getObj('/journal/insights', {'range': range});

  // ── day drill-down detail (all computed server-side) ───────────────────────
  /// GET /day/strain?date= → cumulative strain curve + zones + HR stats + sessions.
  Future<Map<String, dynamic>> getDayStrain(String date) =>
      _getObj('/day/strain', {'date': date});

  /// GET /day/sleep?date= → hypnogram + stage breakdown + debt + consistency.
  Future<Map<String, dynamic>> getDaySleep(String date) =>
      _getObj('/day/sleep', {'date': date});

  /// GET /day/timeline?date= → 24h HR + activity + sleep + sessions + events + highs.
  Future<Map<String, dynamic>> getDayTimeline(String date) =>
      _getObj('/day/timeline', {'date': date});

  /// GET /day/stress?date= → HRV stress + sleep-arousal + factual HR timeline.
  Future<Map<String, dynamic>> getDayStress(String date) =>
      _getObj('/day/stress', {'date': date});

  /// GET /day/heart?date= → 24h HR + RHR + HRV + zones + nocturnal + recovery +
  /// stress + illness + drivers (everything heart/autonomic for a day).
  Future<Map<String, dynamic>> getDayHeart(String date) =>
      _getObj('/day/heart', {'date': date});

  /// GET /day/lungs?date= → respiratory rate (RSA, gated) + relative SpO₂.
  Future<Map<String, dynamic>> getDayLungs(String date) =>
      _getObj('/day/lungs', {'date': date});

  // ── workouts (manual/live/auto) ──────────────────────────────────────────
  /// GET /workouts?range=week|month|quarter → list + training-volume summary.
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) =>
      _getObj('/workouts', {'range': range});

  /// GET /workout/:id → one workout's breakdown + HR timeline.
  Future<Map<String, dynamic>> getWorkout(String id) => _getObj('/workout/$id');

  /// POST /workout/start {type} → {workout_id, start_ts, type, status}.
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async {
    final resp = await _authed((h) => _client.post(_u('/workout/start'),
        headers: h, body: jsonEncode({'type': type, if (title != null) 'title': title})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return _decode(resp.body);
  }

  /// POST /workout/end {workout_id} → computed breakdown.
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    final resp = await _authed((h) => _client.post(_u('/workout/end'),
        headers: h, body: jsonEncode({'workout_id': workoutId})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return _decode(resp.body);
  }

  /// GET /trend/:metric?scale=week|month|quarter&anchor=YYYY-MM-DD
  /// → server-aggregated buckets (7 daily / weekly-mean / monthly-mean bars) with
  /// coverage + target + achieved, for the Metric Explorer. Drill = re-call with a
  /// narrower scale+anchor; the leaf is /day/*.
  Future<Map<String, dynamic>> getTrend(String metric,
          {String scale = 'week', String? anchor}) =>
      _getObj('/trend/$metric', {
        'scale': scale,
        if (anchor != null) 'anchor': anchor,
      });

  /// GET /records → personal records + streaks + baseline drift (your body over time).
  Future<Map<String, dynamic>> getRecords() => _getObj('/records');

  /// GET /notifications → {unread, notifications:[…]} (server-generated feed).
  Future<Map<String, dynamic>> getNotifications() => _getObj('/notifications');

  /// POST /notifications/read — mark some (or all, when ids null) as read.
  Future<void> markNotificationsRead({List<String>? ids}) async {
    final resp = await _authed((h) => _client.post(_u('/notifications/read'),
        headers: h, body: jsonEncode({if (ids != null) 'ids': ids})));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
  }

  /// GET /chart?metric=hr&from&to → downsampled time series.
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to}) {
    final q = {'metric': metric, ...?_range(from, to)};
    return _getObj('/chart', q);
  }

  Map<String, String>? _range(int? from, int? to) {
    if (from == null && to == null) return null;
    return {if (from != null) 'from': '$from', if (to != null) 'to': '$to'};
  }

  Future<Map<String, dynamic>> _getObj(String path, [Map<String, String>? q]) async {
    final resp = await _authed((h) => _client.get(_u(path, q), headers: h));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return _decode(resp.body);
  }

  Future<List<Map<String, dynamic>>> _getList(String path, [Map<String, String>? q]) async {
    final resp = await _authed((h) => _client.get(_u(path, q), headers: h));
    if (resp.statusCode != 200) throw ApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> _decode(String body) {
    if (body.isEmpty) return {};
    final d = jsonDecode(body);
    return d is Map ? d.cast<String, dynamic>() : {'data': d};
  }
}
