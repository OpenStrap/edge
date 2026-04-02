import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiClient {
  // Set this to your own backend URL (see /backend for the FastAPI server)
  static const _base = 'http://localhost:5677';
  static const _timeout = Duration(seconds: 8);

  static final _client = http.Client();

  // ── Ingest ─────────────────────────────────────────────────────────────────

  static Future<void> ingest({
    int? hr,
    double? hrv,
    double? spo2,
    double? tempC,
    double? batteryPct,
    bool? charging,
    double? accelMag,
    bool? wristOn,
  }) async {
    final body = <String, dynamic>{};
    if (hr != null) body['hr'] = hr;
    if (hrv != null) body['hrv'] = hrv;
    if (spo2 != null) body['spo2'] = spo2;
    if (tempC != null) body['temp_c'] = tempC;
    if (batteryPct != null) body['battery_pct'] = batteryPct;
    if (charging != null) body['charging'] = charging;
    if (accelMag != null) body['accel_mag'] = accelMag;
    if (wristOn != null) body['wrist_on'] = wristOn;
    if (body.isEmpty) return;

    try {
      await _client
          .post(
            Uri.parse('$_base/api/ingest'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (_) {
      // Silently drop — offline resilient
    }
  }

  // ── Insights ───────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> fetchTodayInsights() async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/api/insights/today'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> fetchRecovery() async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/api/insights/recovery'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> fetchHrHistory(
      {int hours = 24}) async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/api/metrics/hr?hours=$hours'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map;
        return (data['data'] as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  static Future<List<Map<String, dynamic>>> fetchHistory(
      {int days = 7}) async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/api/insights/history?days=$days'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map;
        return (data['history'] as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  // ── Health ─────────────────────────────────────────────────────────────────

  static Future<bool> isReachable() async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
