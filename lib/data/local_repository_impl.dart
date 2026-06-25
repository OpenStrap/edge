// LocalRepositoryImpl — serves the UI from the PRECOMPUTED derived store.
//
// ZERO heavy compute on read: every method reads derived_day / metric_series
// rows (written by the DerivationEngine) and shapes them into the exact Map/List
// blobs the existing screens expect (the shapes the old cloud ApiClient returned,
// parsed by lib/models/payloads.dart + metric.dart).
//
// Metric envelopes: the onehz `Metric.toJson()` already emits
//   {value, confidence, tier, inputs_used, [note, drivers]}
// which Metric.parse (Case A) reads directly. Where a screen wants a bare scalar
// + a `flags` blob (Case B), we project the same fields into a flags entry.
//
// Honesty: a metric whose value is absent stays absent ("—"); we never fabricate.
// Profile-gated metrics are null when the profile field is missing.

import 'dart:convert';

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'db.dart';
import 'local_repository.dart';

class LocalRepositoryImpl extends LocalRepository {
  LocalRepositoryImpl({required this.getProfileMap});

  /// Reads the live AppState profile map (age/weight/height/sex/step_goal…).
  final Map<String, dynamic>? Function() getProfileMap;

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Decode a derived_day row's payload bundle, or null.
  Future<Map<String, dynamic>?> _bundle(String date) async {
    final row = await LocalDb.derivedDay(date);
    if (row == null) return null;
    return _decode(row['payload_json']);
  }

  Future<Map<String, dynamic>?> _latestBundle() async {
    final row = await LocalDb.latestDerivedDay();
    if (row == null) return null;
    return _decode(row['payload_json']);
  }

  /// The cross-day analytics rollup bundle (from the `crossday` baseline), or
  /// null when none has been computed yet.
  Future<Map<String, dynamic>?> _crossDay() async {
    final r = await LocalDb.baseline('crossday');
    return _decode(r?['payload_json']);
  }

  static Map<String, dynamic>? _decode(Object? json) {
    if (json is! String) return null;
    try {
      final d = jsonDecode(json);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Pull a sub-map by dotted path (e.g. 'clinical.hrv_time').
  Map<String, dynamic>? _sub(Map<String, dynamic>? b, String path) {
    var cur = b;
    for (final part in path.split('.')) {
      final next = cur?[part];
      cur = next is Map ? next.cast<String, dynamic>() : null;
      if (cur == null) return null;
    }
    return cur;
  }

  num? _scalar(Map<String, dynamic>? b, String key) {
    final s = _sub(b, 'scalars');
    final v = s?[key];
    return v is num ? v : null;
  }

  /// A bare metric from a scalar (used where a screen reads a number directly).
  Map<String, dynamic> _scalarMetric(num? v, String tier, {String? unit}) => {
        'value': v ?? '—',
        'confidence': v == null ? 0 : 0.8,
        'tier': tier,
        'inputs_used': const [],
        'unit': ?unit,
      };

  // ── profile ─────────────────────────────────────────────────────────────────
  // The profile lives in AppState (shared_preferences); AppState.updateProfile
  // is the writer. Here we just surface it / accept patches via the same map.

  @override
  Future<Map<String, dynamic>> getProfile() async {
    final p = getProfileMap() ?? const {};
    return {...p, 'step_goal': (p['step_goal'] as num?)?.toInt() ?? 10000};
  }

  @override
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> fields) async {
    // AppState.updateProfile persists; the screen calls that path. We echo back.
    return {...?getProfileMap(), ...fields};
  }

  @override
  Future<Map<String, dynamic>> setStepGoal(int goal) async =>
      {...?getProfileMap(), 'step_goal': goal};

  // ── today ─────────────────────────────────────────────────────────────────
  // Shape per lib/models/payloads.dart TodayData: {daily:{…}, sleep:{…},
  // nocturnal:{…}, resp:{…}, hrv:{…}, skin_temp:{…}, step_goal}.

  @override
  Future<Map<String, dynamic>> getToday() async {
    final b = await _latestBundle();
    if (b == null) {
      return {'daily': const {}, 'sleep': const {}, 'step_goal': await _stepGoal()};
    }
    final clinical = _sub(b, 'clinical') ?? const {};
    final resp = _sub(b, 'respiration') ?? const {};
    final cd = await _crossDay();

    final hrvTime = clinical['hrv_time'] is Map
        ? (clinical['hrv_time'] as Map).cast<String, dynamic>()
        : null;
    final rhrEnv = clinical['resting_hr'] is Map
        ? (clinical['resting_hr'] as Map).cast<String, dynamic>()
        : null;

    final rmssd = _scalar(b, 'rmssd');
    final daily = <String, dynamic>{
      'readiness': _scalarMetric(_scalar(b, 'readiness'), 'HIGH'),
      'recovery': _scalarMetric(_scalar(b, 'readiness'), 'HIGH'),
      'resting_hr': _scalarMetric(_scalar(b, 'rhr')?.round(), 'HIGH', unit: 'bpm'),
      'strain': _scalarMetric(_scalar(b, 'trimp'), 'ESTIMATE'),
      'wear_min': _scalarMetric(_wearMin(b), 'HIGH', unit: 'min'),
    };

    final hrv = rmssd == null
        ? null
        : {
            'rmssd': rmssd,
            'sdnn': _scalar(b, 'sdnn'),
            'confidence': (hrvTime?['confidence'] as num?) ?? 0.5,
          };

    return {
      'daily': daily,
      'sleep': _sleepSummary(b),
      if (rhrEnv != null) 'nocturnal': _nocturnal(b),
      if (resp['rsa'] is Map) 'resp': _respObj(b),
      'hrv': ?hrv,
      'skin_temp': {'value': _scalar(b, 'skin_temp_z')},
      // Cross-day rollup surfaced on Today (present only when computed).
      'illness': ?cd?['illness'],
      'anomaly': ?cd?['anomaly'],
      'load': ?cd?['load'],
      'readiness_breakdown': ?cd?['readiness_glassbox'],
      'regularity': ?cd?['regularity'],
      'step_goal': await _stepGoal(),
    };
  }

  @override
  Future<Map<String, dynamic>> getInsights() async =>
      (await _crossDay()) ?? const {};

  Future<int> _stepGoal() async =>
      (getProfileMap()?['step_goal'] as num?)?.toInt() ?? 10000;

  num? _wearMin(Map<String, dynamic> b) {
    final cov = _sub(b, 'coverage');
    final hr = (cov?['hr_valid'] as num?)?.toInt();
    return hr == null ? null : (hr / 60).round(); // 1 Hz valid samples → minutes
  }

  Map<String, dynamic> _sleepSummary(Map<String, dynamic> b) {
    final acct = _sub(b, 'sleep.accounting');
    final tst = (acct?['tst_sec'] as num?);
    final eff = (acct?['efficiency_pct'] as num?);
    if (tst == null) return const {};
    return {
      'duration_min': _scalarMetric((tst / 60).round(), 'ESTIMATE', unit: 'min'),
      'efficiency': _scalarMetric(eff, 'ESTIMATE', unit: '%'),
    };
  }

  Map<String, dynamic> _nocturnal(Map<String, dynamic> b) {
    final rhr = _scalar(b, 'rhr');
    final dip = _scalar(b, 'dip_pct');
    return {
      'sleeping_hr_avg': rhr?.round(),
      'dip_pct': dip == null ? null : dip / 100.0,
    };
  }

  Map<String, dynamic>? _respObj(Map<String, dynamic> b) {
    final rr = _scalar(b, 'resp_rate');
    if (rr == null) return null;
    final env = _sub(b, 'respiration.rsa');
    return {'value': rr, 'confidence': (env?['confidence'] as num?) ?? 0.5};
  }

  // ── day drill-downs ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];
    final rmssd = _scalar(b, 'rmssd');
    return {
      'hr': hrCurve, // [{t, v}] — detail_cards reads e['v']
      'resting_hr': _scalar(b, 'rhr')?.round(),
      'recovery': _scalar(b, 'readiness'),
      'avg_hr': _avgHr(hrCurve),
      'max_hr': _maxHr(hrCurve),
      'hrv': {
        if (rmssd != null) 'rmssd': rmssd.round(),
        'sdnn': _scalar(b, 'sdnn')?.round(),
        'baseline': (await _seriesMean('rmssd'))?.round(),
      },
      'nocturnal': _nocturnal(b),
      'resp': _respObj(b),
    };
  }

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    return {
      'timeline': (_sub(b, 'series')?['hrv_timeline'] as List?) ?? const [],
      'rmssd': _scalar(b, 'rmssd'),
      'sdnn': _scalar(b, 'sdnn'),
      'ln_rmssd': _scalar(b, 'ln_rmssd'),
      'baseline': await _seriesMean('rmssd'),
      'hrv_time': _sub(b, 'clinical.hrv_time'),
      'hrv_freq': _sub(b, 'clinical.hrv_freq'),
      'prsa_dc': _sub(b, 'clinical.prsa_dc'),
      'prsa_ac': _sub(b, 'clinical.prsa_ac'),
    };
  }

  @override
  Future<Map<String, dynamic>> getDaySleep(String date) => _daySleep(date);

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) => _daySleep(date);

  Future<Map<String, dynamic>> _daySleep(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    final acct = _sub(b, 'sleep.accounting');
    final stager = _sub(b, 'sleep.stager');
    final win = _sub(b, 'sleep.window');
    final tst = (acct?['tst_sec'] as num?);
    final hypnogram = (_sub(b, 'series')?['hypnogram'] as List?) ?? const [];
    return {
      'duration_min': tst == null ? null : (tst / 60).round(),
      'efficiency': acct?['efficiency_pct'],
      'waso_min': acct?['waso_sec'] == null ? null : ((acct!['waso_sec'] as num) / 60).round(),
      'cycles': acct?['cycles'],
      'onset': (win?['onset_ms'] as num?) == null ? null : ((win!['onset_ms'] as num) / 1000).round(),
      'wake': (win?['offset_ms'] as num?) == null ? null : ((win!['offset_ms'] as num) / 1000).round(),
      'light_min': null, // no light/deep split — stager only does wake/nrem/rem
      'deep_min': null,
      'nrem_min': _stagePct(stager, 'nrem_pct', tst), // combined NREM (real)
      'rem_min': _stagePct(stager, 'rem_pct', tst),
      'stages': hypnogram, // [{start, end, stage}]
      'flags': {
        'duration': {'c': 0.6, 'tier': 'ESTIMATE', 'beta': true},
      },
    };
  }

  int? _stagePct(Map<String, dynamic>? stager, String key, num? tstSec) {
    final pct = (stager?[key] as num?);
    if (pct == null || tstSec == null) return null;
    return ((tstSec / 60) * pct).round();
  }

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    return {
      'resp': _respObj(b),
      'cvhr': _sub(b, 'respiration.cvhr_apnea'),
      'spo2': _sub(b, 'respiration.odi'), // relative desaturation screen; never an absolute %
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    final cov = _sub(b, 'coverage');
    final valid = (cov?['hr_valid'] as num?)?.toInt() ?? 0;
    final total = (cov?['hr_samples'] as num?)?.toInt() ?? 0;
    return {
      'worn_min': (valid / 60).round(),
      'coverage_pct': total == 0 ? 0 : (100 * valid / total).round(),
      'hourly': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async {
    // No dedicated stress family in the 1 Hz bundle yet — surface an honest
    // empty so the screen shows "—" rather than fabricated arousal minutes.
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    return {
      'strain': _scalar(b, 'trimp'),
      'flags': const {},
    };
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async {
    final b = await _bundle(date) ?? await _latestBundle();
    if (b == null) return const {};
    return {'hr': (_sub(b, 'series')?['hr_curve'] as List?) ?? const []};
  }

  // ── lists / summaries ─────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getSleep({int? from, int? to}) async {
    final rows = await LocalDb.recentDerivedDays(60);
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final b = _decode(r['payload_json']);
      if (b == null) continue;
      final acct = _sub(b, 'sleep.accounting');
      final tst = (acct?['tst_sec'] as num?);
      if (tst == null) continue;
      out.add({
        'date': r['date'],
        'duration_min': (tst / 60).round(),
        'efficiency': acct?['efficiency_pct'],
        'flags': {
          'duration': {'c': 0.6, 'tier': 'ESTIMATE', 'beta': true}
        },
      });
    }
    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> getStrain({int? from, int? to}) async {
    final rows = await LocalDb.recentDerivedDays(60);
    return [
      for (final r in rows)
        {
          'date': r['date'],
          'strain': (() {
            final b = _decode(r['payload_json']);
            return _scalar(b, 'trimp');
          })(),
          'flags': const {},
        }
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) async =>
      const []; // auto-workout detection not in the 1 Hz bundle yet.

  @override
  Future<Map<String, dynamic>> getHistory({String range = '30d'}) async {
    final rows = await LocalDb.recentDerivedDays(90);
    return {
      'days': [
        for (final r in rows)
          {
            'date': r['date'],
            'readiness': r['readiness'],
            'resting_hr': r['rhr'],
            'rmssd': r['rmssd'],
          }
      ]
    };
  }

  // ── trends + records + charts ──────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getTrend(String metric,
      {String scale = 'week', String? anchor}) async {
    final key = _trendKey(metric);
    final rows = await LocalDb.metricSeries(key);
    final series = [
      for (final r in rows)
        {'date': r['date'], 'v': (r['value'] as num?)?.toDouble()}
    ];
    return {
      metric: series,
      'series': {metric: series},
      'baseline': {'resting_hr': await _seriesMean('rhr')},
    };
  }

  String _trendKey(String metric) {
    switch (metric) {
      case 'hrv':
        return 'rmssd';
      case 'recovery':
        return 'readiness';
      default:
        return metric;
    }
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to}) async {
    if (metric == 'hr') {
      final b = await _latestBundle();
      return {'points': (_sub(b, 'series')?['hr_curve'] as List?) ?? const []};
    }
    final rows = await LocalDb.metricSeries(_trendKey(metric));
    return {
      'points': [
        for (final r in rows)
          {'t': _dateToEpoch(r['date'] as String), 'v': r['value']}
      ]
    };
  }

  int _dateToEpoch(String date) =>
      (DateTime.tryParse('$date 12:00:00')?.millisecondsSinceEpoch ?? 0) ~/ 1000;

  @override
  Future<Map<String, dynamic>> getRecords() async {
    final rows = await LocalDb.recentDerivedDays(3650);
    final days = rows.length;
    int nights = 0;
    for (final r in rows) {
      final b = _decode(r['payload_json']);
      if (_sub(b, 'sleep.accounting')?['tst_sec'] != null) nights++;
    }
    return {
      'days_tracked': days,
      'nights_tracked': nights,
      'workouts_tracked': 0,
      'records': const {},
      'streaks': const {},
    };
  }

  // ── workouts (manual / live / auto) — local-only stubs, valid shapes ────────

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async =>
      {'workouts': const []};

  @override
  Future<Map<String, dynamic>> getWorkout(String id) async => const {};

  @override
  Future<void> deleteWorkout(String id) async {}

  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async {
    final id = 'w${DateTime.now().millisecondsSinceEpoch}';
    return {'workout_id': id, 'type': type};
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async =>
      {'workout_id': workoutId};

  @override
  Future<Map<String, dynamic>> setWorkoutType(String id, String type) async =>
      {'workout_id': id, 'type': type};

  // ── journal — local-only stubs ───────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {}

  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async =>
      const {'insights': []};

  // ── cycle — local-only stubs ─────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getCycle() async => const {'enabled': false};

  @override
  Future<void> postCycleLog(String date, {String kind = 'start', String? note}) async {}

  @override
  Future<void> deleteCycleLog(String date) async {}

  // ── notifications — derived from illness/anomaly flags (none yet) ────────────

  @override
  Future<Map<String, dynamic>> getNotifications() async =>
      const {'unread': 0, 'notifications': []};

  @override
  Future<void> markNotificationsRead({List<String>? ids}) async {}

  // ── live HRV spot-check (on-device decode + HRV) ────────────────────────────

  @override
  Future<Map<String, dynamic>> spotCheck(List<String> records) async {
    // Decode RR from the live RR-bearing frames (0x28 / R10), clean, compute HRV.
    final rrMs = <double>[];
    final hrs = <double>[];
    for (final hex in records) {
      final rr = proto.realtimeRr(hex);
      if (rr != null) {
        for (final v in rr.rrMs) {
          if (v > 0) rrMs.add(v.toDouble());
        }
      }
      try {
        final s = proto.decodeRecord(hex);
        if (s != null && s.hr > 0) hrs.add(s.hr.toDouble());
      } catch (_) {}
    }
    if (rrMs.length < 20) {
      return {'ok': false, 'n_beats': rrMs.length};
    }
    final cleaned = ana.correctRr(rrMs);
    final hrv = ana.hrvTime(cleaned.nn, nnTimesMs: cleaned.nnTimesMs);
    if (!hrv.present) return {'ok': false, 'n_beats': cleaned.nn.length};
    final meanHr = hrs.isEmpty
        ? null
        : hrs.reduce((a, b) => a + b) / hrs.length;
    return {
      'ok': true,
      'rmssd': hrv.value!.rmssd?.round(),
      'sdnn': hrv.value!.sdnn?.round(),
      'mean_hr': meanHr?.round(),
      'n_beats': cleaned.nn.length,
      'confidence': hrv.confidence,
    };
  }

  // ── small series helpers ─────────────────────────────────────────────────────

  Future<double?> _seriesMean(String key) async {
    final rows = await LocalDb.metricSeries(key, limit: 28);
    final vs = [for (final r in rows) (r['value'] as num).toDouble()];
    if (vs.isEmpty) return null;
    return vs.reduce((a, b) => a + b) / vs.length;
  }

  num? _avgHr(List hrCurve) {
    final vs = [
      for (final e in hrCurve)
        if (e is Map && e['v'] is num && (e['v'] as num) > 0) (e['v'] as num)
    ];
    if (vs.isEmpty) return null;
    return (vs.reduce((a, b) => a + b) / vs.length).round();
  }

  num? _maxHr(List hrCurve) {
    num mx = 0;
    for (final e in hrCurve) {
      if (e is Map && e['v'] is num && (e['v'] as num) > mx) mx = e['v'] as num;
    }
    return mx == 0 ? null : mx;
  }
}
