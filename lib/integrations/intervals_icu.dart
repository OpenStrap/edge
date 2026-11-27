// intervals.icu: sign-in (OAuth PKCE once the app is registered, API key
// until then), daily wellness push and workout upload (TCX).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../data/day_label.dart';
import 'oauth_loopback.dart';
import '../gps/route_models.dart';
import 'tcx.dart';

// Public OAuth client (PKCE, no secret), so the id is not sensitive.
// Cloudflare in front of intervals.icu refuses some default client strings
// (error 1010), so say who we are.
const String kIntervalsUserAgent = 'OpenStrap-Edge';

const String kIntervalsClientId = String.fromEnvironment('INTERVALS_CLIENT_ID', defaultValue: '2017');

/// `metric_series` key -> intervals.icu wellness field, with the unit scale.
/// Keys confirmed in lib/data/db.dart (v_daily view 6303-6322; spo2 14161).
const Map<String, (String, double)> kIntervalsWellnessMap = {
  'rhr': ('restingHR', 1),
  'rmssd': ('hrv', 1),
  'tst_min': ('sleepSecs', 60),
  'readiness': ('readiness', 1),
  'spo2': ('spO2', 1),
  'resp_rate': ('respiration', 1),
  'steps': ('steps', 1),
};

/// PUT body for one day. Absent values are omitted, never zero.
Map<String, Object> intervalsWellnessBody(String day, Map<String, double> series) {
  final out = <String, Object>{'id': day};
  kIntervalsWellnessMap.forEach((key, f) {
    final v = series[key];
    if (v == null || v.isNaN) return;
    final x = v * f.$2;
    out[f.$1] = (f.$1 == 'sleepSecs' || f.$1 == 'steps' || f.$1 == 'restingHR') ? x.round() : x;
  });
  return out;
}

class IntervalsException implements Exception {
  final String message;
  IntervalsException(this.message);
  @override
  String toString() => message;
}

/// Stored sign-in: either an OAuth bearer token or an API key.
class IntervalsAuth {
  final String athleteId;
  final String secret;
  final bool apiKey;
  const IntervalsAuth(this.athleteId, this.secret, {required this.apiKey});

  String get header => apiKey
      ? 'Basic ${base64.encode(utf8.encode('API_KEY:$secret'))}'
      : 'Bearer $secret';
}

/// Parses the token endpoint response into the athlete id and token.
IntervalsAuth parseIntervalsToken(String body) {
  final j = jsonDecode(body);
  final token = j is Map ? j['access_token'] : null;
  final id = j is Map && j['athlete'] is Map ? (j['athlete'] as Map)['id'] : null;
  if (token is! String || token.isEmpty || id == null) {
    throw IntervalsException('intervals.icu sign-in returned no token.');
  }
  return IntervalsAuth('$id', token, apiKey: false);
}

class IntervalsIcu extends ChangeNotifier {
  static const _apple = IOSOptions(accessibility: KeychainAccessibility.first_unlock);
  static const _macos = MacOsOptions(accessibility: KeychainAccessibility.first_unlock);
  static const _kAuth = 'intervals_icu_auth';
  static const _kAuto = 'intervals_icu_auto_push';
  static const _base = 'https://intervals.icu';
  static const _scope = 'ACTIVITY:WRITE,WELLNESS:WRITE';

  final http.Client _http;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  IntervalsAuth? _auth;
  // Bumped by every sign-in and sign-out, so a storage read that started
  // before one cannot put old credentials back.
  int _authGen = 0;
  static const _timeout = Duration(seconds: 20);
  static const _uploadTimeout = Duration(seconds: 90);

  /// Set when intervals.icu answered 401/403: the key or token is dead and
  /// the user has to reconnect. Cleared by the next successful sign-in.
  bool authFailed = false;

  /// Hourly wellness push after a derive pass. On once connected; the user can
  /// turn it off and still send by hand.
  bool autoPush = true;

  Future<void> setAutoPush(bool on) async {
    autoPush = on;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(_kAuto, on);
    } catch (e) {
      debugPrint('intervals.icu auto-push pref not saved: $e');
    }
  }

  IntervalsIcu({http.Client? client, @visibleForTesting IntervalsAuth? auth})
      : _http = client ?? http.Client(),
        _auth = auth;
  static final instance = IntervalsIcu();

  /// True once an INTERVALS_CLIENT_ID is compiled in; otherwise the UI offers
  /// the API-key form (Settings > Developer on intervals.icu).
  bool get oauthAvailable => kIntervalsClientId.isNotEmpty;
  bool get signedIn => _auth != null;
  String? get athleteId => _auth?.athleteId;
  bool get usesApiKey => _auth?.apiKey ?? false;

  /// Reads the saved sign-in. True when the read worked (even if nothing was
  /// saved); false when storage failed, so the caller can try again later.
  Future<bool> load() async {
    try {
      autoPush = (await SharedPreferences.getInstance()).getBool(_kAuto) ?? true;
    } catch (_) {}
    final gen = _authGen;
    try {
      final raw = await _secure.read(key: _kAuth, iOptions: _apple, mOptions: _macos);
      if (gen != _authGen) return true; // signed in or out while reading
      if (raw == null) return true;
      final j = jsonDecode(raw) as Map;
      _auth = IntervalsAuth(j['id'] as String, j['secret'] as String, apiKey: j['key'] == true);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('intervals.icu load failed: $e');
      return false;
    }
  }

  Future<void> _store(IntervalsAuth a) async {
    await _secure.write(
        key: _kAuth,
        value: jsonEncode({'id': a.athleteId, 'secret': a.secret, 'key': a.apiKey}),
        iOptions: _apple,
        mOptions: _macos);
    _authGen++;
    _auth = a;
    authFailed = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    _authGen++;
    await _secure.delete(key: _kAuth, iOptions: _apple, mOptions: _macos);
    _authGen++;
    _auth = null;
    authFailed = false;
    notifyListeners();
  }

  /// API-key mode. Checks the key against the athlete endpoint before saving.
  Future<void> saveApiKey(String athleteId, String key) async {
    final a = IntervalsAuth(athleteId.trim(), key.trim(), apiKey: true);
    if (a.athleteId.isEmpty || a.secret.isEmpty) {
      throw IntervalsException('Enter your athlete id and API key.');
    }
    final r = await _send(() => _http.get(Uri.parse('$_base/api/v1/athlete/${a.athleteId}'),
        headers: {'Authorization': a.header, 'User-Agent': kIntervalsUserAgent}));
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw IntervalsException('intervals.icu rejected that athlete id or API key.');
    }
    if (r.statusCode >= 300) throw IntervalsException('intervals.icu error ${r.statusCode}.');
    await _store(a);
  }

  /// OAuth PKCE sign-in; [open] shows the page in an in-app browser.
  Future<void> signIn(Future<bool> Function(Uri) open) async {
    if (!oauthAvailable) throw IntervalsException('intervals.icu sign-in is not available yet. Use an API key.');
    final got = await LoopbackAuth(host: 'localhost').run(
      open: open,
      authorize: (redirect, state, challenge) => Uri.parse('$_base/oauth/authorize').replace(queryParameters: {
        'client_id': kIntervalsClientId,
        'redirect_uri': redirect,
        'scope': _scope,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      }),
    );
    final r = await _send(() => _http.post(Uri.parse('$_base/api/oauth/token'), headers: {'User-Agent': kIntervalsUserAgent}, body: {
      'client_id': kIntervalsClientId,
      'code': got.code,
      'code_verifier': got.verifier,
      'redirect_uri': got.redirectUri,
    }));
    if (r.statusCode >= 300) throw IntervalsException('intervals.icu sign-in failed (${r.statusCode}).');
    await _store(parseIntervalsToken(r.body));
  }

  /// Runs one request with a time limit, so a stalled connection ends in an
  /// error the caller can show and retry instead of waiting forever.
  Future<http.Response> _send(Future<http.Response> Function() go, {Duration? limit}) async {
    try {
      return await go().timeout(limit ?? _timeout);
    } on TimeoutException {
      throw IntervalsException('intervals.icu did not answer. Try again in a moment.');
    }
  }

  /// [a] is the sign-in the request was made with: an old request that fails
  /// after a new sign-in must not mark the new one dead.
  void _check(http.Response r, String what, IntervalsAuth a) {
    if (r.statusCode == 401 || r.statusCode == 403) {
      if (identical(_auth, a) && !authFailed) {
        authFailed = true;
        notifyListeners();
      }
      throw IntervalsException('intervals.icu no longer accepts the sign-in. Reconnect in Settings.');
    }
    if (r.statusCode >= 300) throw IntervalsException('intervals.icu $what failed (${r.statusCode}).');
  }

  IntervalsAuth get _need => _auth ?? (throw IntervalsException('Not signed in to intervals.icu.'));

  @visibleForTesting
  Future<void> putWellness(String day, Map<String, Object> body) async {
    final a = _need;
    final r = await _send(() => _http.put(Uri.parse('$_base/api/v1/athlete/${a.athleteId}/wellness/$day'),
        headers: {'Authorization': a.header, 'Content-Type': 'application/json', 'User-Agent': kIntervalsUserAgent}, body: jsonEncode(body)));
    _check(r, 'wellness push', a);
  }

  /// Wellness values per day (label yyyy-MM-dd) from `metric_series`, for
  /// days on or after [from]. Own-measured values only.
  Future<Map<String, Map<String, double>>> _series(String from) async {
    final out = <String, Map<String, double>>{};
    for (final k in kIntervalsWellnessMap.keys) {
      for (final r in await LocalDb.metricSeries(k, from: from, measuredOnly: true)) {
        (out[r['date'] as String] ??= {})[k] = (r['value'] as num).toDouble();
      }
    }
    return out;
  }

  Future<void> _tail = Future.value();

  /// One wellness push at a time, each reading its values when its turn
  /// comes, so an older snapshot cannot land after a newer one.
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _tail.then((_) => f());
    _tail = r.then((_) {}, onError: (_) {});
    return r;
  }

  /// Pushes the last [days] calendar days (today included) that have values;
  /// returns how many went.
  Future<int> pushRecent({int days = 7}) => _serial(() async {
        final now = DateTime.now();
        final from = dayLabelOf(DateTime(now.year, now.month, now.day - (days - 1)));
        var n = 0;
        for (final e in (await _series(from)).entries) {
          await putWellness(e.key, intervalsWellnessBody(e.key, e.value));
          n++;
        }
        return n;
      });

  DateTime? _lastAuto;
  bool _loaded = false;

  /// Called after each derive pass: the last two days, at most hourly, and
  /// never loud. Light passes run every few minutes during a drain.
  Future<void> pushAfterDerive() async {
    try {
      if (!_loaded) _loaded = await load();
      final now = DateTime.now();
      if (!signedIn || !autoPush || authFailed || (_lastAuto != null && now.difference(_lastAuto!).inMinutes < 60)) return;
      await pushRecent(days: 2);
      _lastAuto = now; // only a push that worked holds the next one back
    } catch (e) {
      debugPrint('intervals.icu auto push failed: $e');
    }
  }

  /// Uploads one saved workout as TCX. [routeOf] is `repo.getWorkoutRoute`.
  /// Returns false when the session has no HR or GPS to send. intervals.icu
  /// de-dupes by file hash, and `external_id` ties it to our session.
  Future<bool> uploadWorkout(String sessionId,
      {String? name, Future<WorkoutRoute?> Function(String id)? routeOf}) async {
    _need;
    final act = await tcxActivityForSession(sessionId, routeOf: routeOf);
    if (act == null) return false;
    await uploadTcx(sessionId, buildTcx(act), name: name);
    return true;
  }

  @visibleForTesting
  Future<void> uploadTcx(String sessionId, String tcx, {String? name}) async {
    final a = _need;
    final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/api/v1/athlete/${a.athleteId}/activities').replace(queryParameters: {
          'name': ?name,
          'external_id': 'openstrap-$sessionId',
        }))
      ..headers['Authorization'] = a.header
      ..headers['User-Agent'] = kIntervalsUserAgent
      ..files.add(http.MultipartFile.fromString('file', tcx,
          filename: 'openstrap-$sessionId.tcx'));
    final r = await _send(() async => http.Response.fromStream(await _http.send(req)), limit: _uploadTimeout);
    _check(r, 'upload', a);
  }
}
