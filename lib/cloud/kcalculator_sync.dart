// kcalculator_sync.dart — HealthE ↔ Kcalculator, through the user's OWN Supabase.
//
// Opt-in and off by default: nothing leaves the phone until the user enters
// their server address and signs in (Données > Kcalculator). Two directions,
// both one row per DAY, never per food and never raw readings:
//
//   • IN  — `nutrition_daily` (a Supabase view written by Kcalculator): the
//           day's total intake. Stored here as ONE food_entry per day,
//           id `kcalc-YYYY-MM-DD`, so the existing nutrition screen and its
//           eaten-vs-burned balance pick it up unchanged.
//   • OUT — `health_daily`: the day's measured burn (`calories`,
//           `calories_total`), steps, sleep, RMSSD, resting HR and the newest
//           weighing. Kcalculator shows it beside what was eaten.
//
// Auth is plain Supabase REST (GoTrue password grant + refresh token), so no
// new package. The refresh token lives in the platform keychain/keystore; the
// server address, the public anon key and the email are not secrets and live
// in shared_preferences. Every call is best-effort: a failure returns a
// message and never throws into a sync cycle.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/inputs/measurement_inputs.dart' show newestWeighing;
import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart';
import '../data/nutrition_store.dart';

/// Prefix of the one food_entry per day that mirrors Kcalculator's total.
const String kKcalEntryPrefix = 'kcalc-';

/// How many past days are (re)sent to `health_daily` on each sync. A day keeps
/// changing for ~48 h after wake (late derives, naps), so a short window is
/// re-sent every time; the server keeps the newest.
const int kHealthPushDays = 14;

const _kUrl = 'kcalc_sync_url';
const _kAnon = 'kcalc_sync_anon_key';
const _kEmail = 'kcalc_sync_email';
const _kUserId = 'kcalc_sync_user_id';
const _kWatermark = 'kcalc_sync_nutrition_since';
const _kLastSync = 'kcalc_sync_last_at';
const _kLastStatus = 'kcalc_sync_last_status';
const _kRefresh = 'kcalc_sync_refresh_token';

/// The metric_series keys sent out, and the health_daily column each fills.
const Map<String, String> kHealthColumns = {
  'calories': 'active_kcal',
  'calories_total': 'total_kcal',
  'steps': 'steps',
  'tst_min': 'sleep_min',
  'rmssd': 'hrv_ms',
  'rhr': 'resting_hr',
};

class KcalSyncConfig {
  const KcalSyncConfig({required this.url, required this.anonKey, required this.email, this.userId});
  final String url;
  final String anonKey;
  final String email;
  final String? userId;
}

class KcalculatorSync {
  KcalculatorSync._();
  static final KcalculatorSync instance = KcalculatorSync._();

  static const _secure = FlutterSecureStorage(
    // Readable from the first unlock after boot: background syncs run while
    // the phone is locked.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  http.Client _http = http.Client();
  @visibleForTesting
  set httpClient(http.Client c) => _http = c;

  String? _accessToken;
  DateTime? _accessExpires;
  Future<String>? _running;

  // ── configuration ─────────────────────────────────────────────────────────

  Future<KcalSyncConfig?> config() async {
    final sp = await SharedPreferences.getInstance();
    final url = sp.getString(_kUrl);
    final anon = sp.getString(_kAnon);
    final email = sp.getString(_kEmail);
    if (url == null || url.isEmpty || anon == null || anon.isEmpty || email == null) return null;
    return KcalSyncConfig(url: url, anonKey: anon, email: email, userId: sp.getString(_kUserId));
  }

  Future<bool> get isConnected async {
    final c = await config();
    if (c == null) return false;
    return (await _readRefresh()) != null;
  }

  Future<({DateTime? at, String? status})> lastRun() async {
    final sp = await SharedPreferences.getInstance();
    final ms = sp.getInt(_kLastSync);
    return (at: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms), status: sp.getString(_kLastStatus));
  }

  /// Signs in with the Kcalculator account (same email and password as the
  /// Kcalculator app). Returns null on success, else a message for the user.
  Future<String?> signIn({required String url, required String anonKey, required String email, required String password}) async {
    final base = normalizeUrl(url);
    if (base == null) return 'Adresse du serveur invalide (ex. https://xxxx.supabase.co)';
    try {
      final res = await _http.post(
        Uri.parse('$base/auth/v1/token?grant_type=password'),
        headers: {'apikey': anonKey.trim(), 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.trim(), 'password': password}),
      );
      if (res.statusCode != 200) return _authError(res);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kUrl, base);
      await sp.setString(_kAnon, anonKey.trim());
      await sp.setString(_kEmail, email.trim());
      await sp.setString(_kUserId, (body['user'] as Map?)?['id'] as String? ?? '');
      await sp.remove(_kWatermark); // a new account: pull its whole history
      _takeSession(body);
      await _secure.write(key: _kRefresh, value: body['refresh_token'] as String?);
      return null;
    } catch (e) {
      return 'Serveur injoignable : $e';
    }
  }

  /// Forgets the account. Days already imported stay in the food log.
  Future<void> signOut() async {
    final sp = await SharedPreferences.getInstance();
    for (final k in [_kUrl, _kAnon, _kEmail, _kUserId, _kWatermark, _kLastSync, _kLastStatus]) {
      await sp.remove(k);
    }
    try {
      await _secure.delete(key: _kRefresh);
    } catch (_) {}
    _accessToken = null;
    _accessExpires = null;
  }

  // ── sync ──────────────────────────────────────────────────────────────────

  /// For the app's own triggers (foreground, headless wake): silent no-op
  /// when not connected, never throws.
  Future<void> syncIfConfigured() async {
    try {
      if (!await isConnected) return;
      await syncNow();
    } catch (e) {
      debugPrint('[kcalc] sync skipped: $e');
    }
  }

  /// Runs one sync (or joins the one already running). Returns a status line.
  Future<String> syncNow() => _running ??= _sync().whenComplete(() => _running = null);

  Future<String> _sync() async {
    String status;
    try {
      final c = await config();
      if (c == null) return 'Non connecté';
      final token = await _token(c);
      if (token == null) {
        status = 'Session expirée : reconnecte-toi';
      } else {
        final pulled = await _pullNutrition(c, token);
        final pushed = await _pushHealth(c, token);
        status = 'Synchronisé : $pulled jour(s) de repas reçus, $pushed jour(s) santé envoyés';
      }
    } catch (e) {
      status = 'Échec de la synchro : $e';
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLastSync, DateTime.now().millisecondsSinceEpoch);
    await sp.setString(_kLastStatus, status);
    return status;
  }

  Future<int> _pullNutrition(KcalSyncConfig c, String token) async {
    final sp = await SharedPreferences.getInstance();
    final since = sp.getString(_kWatermark) ?? '1970-01-01T00:00:00Z';
    final rows = <Map<String, dynamic>>[];
    for (var from = 0;; from += 1000) {
      final uri = Uri.parse('${c.url}/rest/v1/nutrition_daily').replace(queryParameters: {
        'select': '*',
        'synced_at': 'gte.$since',
        'order': 'synced_at.asc',
      });
      final res = await _http.get(uri, headers: {..._headers(c, token), 'Range': '$from-${from + 999}'});
      if (res.statusCode == 404) throw 'vue nutrition_daily absente : lance la migration 006 de Kcalculator';
      if (res.statusCode >= 300) throw 'lecture nutrition_daily (${res.statusCode}) ${res.body}';
      final page = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
      rows.addAll(page);
      if (page.length < 1000) break;
    }
    if (rows.isEmpty) return 0;
    final db = await LocalDb.instance;
    var mark = since;
    for (final r in rows) {
      final date = r['date'] as String;
      final entry = entryFromNutritionRow(r);
      if (entry == null) {
        await NutritionDb.delete(db, '$kKcalEntryPrefix$date');
      } else {
        await NutritionDb.put(db, entry);
      }
      final s = r['synced_at'] as String?;
      if (s != null && s.compareTo(mark) > 0) mark = s;
    }
    await sp.setString(_kWatermark, mark);
    return rows.length;
  }

  Future<int> _pushHealth(KcalSyncConfig c, String token) async {
    final today = DateTime.now();
    final days = [for (var i = kHealthPushDays - 1; i >= 0; i--) dayLabelOf(DateTime(today.year, today.month, today.day - i))];
    final series = <String, Map<String, double>>{};
    for (final key in kHealthColumns.keys) {
      final rows = await LocalDb.metricSeries(key, measuredOnly: true);
      series[key] = {
        for (final r in rows)
          if (days.contains(r['date'])) r['date'] as String: (r['value'] as num).toDouble(),
      };
    }
    final w = await newestWeighing();
    final weighing = w == null ? null : (date: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(w.atMs)), kg: w.kg);
    final rows = buildHealthRows(days: days, series: series, weighing: weighing, userId: c.userId);
    if (rows.isEmpty) return 0;
    final res = await _http.post(
      Uri.parse('${c.url}/rest/v1/health_daily?on_conflict=user_id,date'),
      headers: {..._headers(c, token), 'Prefer': 'resolution=merge-duplicates,return=minimal'},
      body: jsonEncode(rows),
    );
    if (res.statusCode == 404) throw 'table health_daily absente : lance la migration 006 de Kcalculator';
    if (res.statusCode >= 300) throw 'envoi health_daily (${res.statusCode}) ${res.body}';
    return rows.length;
  }

  // ── session ───────────────────────────────────────────────────────────────

  Map<String, String> _headers(KcalSyncConfig c, String token) => {
        'apikey': c.anonKey,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  void _takeSession(Map<String, dynamic> body) {
    _accessToken = body['access_token'] as String?;
    final ttl = (body['expires_in'] as num?)?.toInt() ?? 3600;
    _accessExpires = DateTime.now().add(Duration(seconds: ttl - 60));
  }

  Future<String?> _readRefresh() async {
    try {
      return await _secure.read(key: _kRefresh);
    } catch (_) {
      return null;
    }
  }

  /// A valid access token, refreshing it when needed. Null = signed out.
  Future<String?> _token(KcalSyncConfig c) async {
    final exp = _accessExpires;
    if (_accessToken != null && exp != null && DateTime.now().isBefore(exp)) return _accessToken;
    final refresh = await _readRefresh();
    if (refresh == null) return null;
    final res = await _http.post(
      Uri.parse('${c.url}/auth/v1/token?grant_type=refresh_token'),
      headers: {'apikey': c.anonKey, 'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refresh}),
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    _takeSession(body);
    // Supabase rotates refresh tokens: the old one stops working now.
    await _secure.write(key: _kRefresh, value: body['refresh_token'] as String?);
    return _accessToken;
  }

  String _authError(http.Response res) {
    try {
      final b = jsonDecode(res.body) as Map<String, dynamic>;
      final msg = (b['error_description'] ?? b['msg'] ?? b['message'] ?? '').toString();
      if (msg.toLowerCase().contains('invalid login')) return 'Email ou mot de passe incorrect';
      if (res.statusCode == 401) return 'Clé publique (anon key) refusée par le serveur';
      return msg.isEmpty ? 'Connexion refusée (${res.statusCode})' : msg;
    } catch (_) {
      return 'Connexion refusée (${res.statusCode})';
    }
  }
}

// ── pure helpers (tested) ───────────────────────────────────────────────────

/// `https://x.supabase.co/` → `https://x.supabase.co`; null when not an http(s) URL.
String? normalizeUrl(String raw) {
  var u = raw.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  final uri = Uri.tryParse(u);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) return null;
  return u;
}

double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// One `nutrition_daily` row → the day's single food_entry, or null when the
/// day has nothing left (everything deleted in Kcalculator): the caller then
/// removes the entry. Unknown micros stay null, never zero.
FoodEntry? entryFromNutritionRow(Map<String, dynamic> r) {
  final date = r['date'] as String;
  final items = (r['items'] as num?)?.toInt() ?? 0;
  if (items <= 0) return null;
  return FoodEntry(
    id: '$kKcalEntryPrefix$date',
    date: date,
    meal: 'snack',
    label: 'Kcalculator : total du jour',
    unit: 'portion',
    kcal: _d(r['kcal']),
    proteinG: _d(r['protein_g']),
    carbsG: _d(r['carbs_g']),
    fatG: _d(r['fat_g']),
    fibreG: _d(r['fibre_g']),
    sugarG: _d(r['sugar_g']),
    satFatG: _d(r['sat_fat_g']),
    sodiumMg: _d(r['sodium_mg']),
    ironMg: _d(r['iron_mg']),
    calciumMg: _d(r['calcium_mg']),
    confirmed: true,
    note: r['micros_complete'] == false
        ? '$items aliment(s) dans Kcalculator. Micros partiels : certains aliments ne les renseignent pas.'
        : '$items aliment(s) dans Kcalculator.',
  );
}

/// The `health_daily` rows to upsert: one per day that has at least one
/// measured value. A missing measurement is sent as null, never zero.
List<Map<String, dynamic>> buildHealthRows({
  required List<String> days,
  required Map<String, Map<String, double>> series,
  required ({String date, double kg})? weighing,
  String? userId,
  String source = 'healthe',
  DateTime? now,
}) {
  final stamp = (now ?? DateTime.now()).toUtc().toIso8601String();
  final out = <Map<String, dynamic>>[];
  for (final day in days) {
    final row = <String, dynamic>{};
    for (final MapEntry(key: key, value: col) in kHealthColumns.entries) {
      final v = series[key]?[day];
      row[col] = v == null ? null : (col == 'steps' ? v.round() : double.parse(v.toStringAsFixed(1)));
    }
    row['weight_kg'] = weighing != null && weighing.date == day ? weighing.kg : null;
    if (row.values.every((v) => v == null)) continue;
    out.add({
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      'date': day,
      'source': source,
      ...row,
      'updated_at': stamp,
    });
  }
  return out;
}
