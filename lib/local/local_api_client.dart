// LocalApiClient — a drop-in ApiClient for LOCAL mode. Instead of HTTP, it reads the
// on-device derived store (the bundles LocalPipeline writes) and SYNTHESIZES the exact
// response envelopes the cloud endpoints return, so the existing Today / Sleep / Heart /
// Body / Workouts screens render unchanged. "Mode is plumbing, not data."
//
// Only the GET reads the UI uses are overridden; writes become local no-ops (profile
// edits persist via LocalProfile). Unmapped/secondary endpoints return valid EMPTY
// shapes so screens degrade to "—" gracefully (never crash, never fabricate).
import 'dart:convert';
import '../data/db.dart';
import '../net/api_client.dart';
import '../sync/config.dart';
import 'local_profile.dart';

class LocalApiClient extends ApiClient {
  LocalApiClient()
      : super(
          BackendConfig(url: 'local://', chosen: true, deviceId: 'local'),
          Session(),
        );

  // ── derived-store readers ───────────────────────────────────────────────────
  Future<Map<String, dynamic>?> _bundle(String date, String kind) async {
    final raw = await LocalDb.getDerived(date, kind);
    if (raw == null) return null;
    final m = jsonDecode(raw);
    return m is Map<String, dynamic> ? m : null;
  }

  /// Read a derived payload stored as a JSON array (e.g. the 'sessions' bundle).
  Future<List<Map<String, dynamic>>> _listBundle(String date, String kind) async {
    final raw = await LocalDb.getDerived(date, kind);
    if (raw == null) return const [];
    final v = jsonDecode(raw);
    return v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];
  }

  Future<String?> _latestDate() async {
    final dates = (await LocalDb.derivedDates()).toList()..sort();
    return dates.isEmpty ? null : dates.last;
  }

  Future<List<String>> _dates() async => (await LocalDb.derivedDates()).toList()..sort();

  // ── helpers ───────────────────────────────────────────────────────────────
  static Map<String, dynamic>? _m(dynamic v) => v is Map<String, dynamic> ? v : null;
  static num? _f(dynamic m, String k) => (m is Map && m[k] is num) ? m[k] as num : null;

  /// Wrap a scalar in the `Metric<T>` envelope the UI expects.
  Map<String, dynamic> _met(num? value,
      {String unit = '', double? confidence, String tier = 'HIGH', String? label, List<String>? inputs}) {
    return {
      'value': value,
      'unit': unit,
      'confidence': confidence ?? (value == null ? 0.0 : 0.7),
      'tier': tier,
      'label': label,
      'inputs_used': inputs ?? const <String>[],
    };
  }

  /// The `daily` envelope block (shared by /today and used by drill-downs).
  Future<Map<String, dynamic>?> _dailyEnvelope(String date) async {
    final d = await _bundle(date, 'daily');
    if (d == null) return null;
    final strain = _m(d['strain']);
    final rhr = _m(d['resting_hr']);
    final recovery = _m(d['recovery']);
    final readiness = _m(d['readiness']);
    final calories = _m(d['calories']);
    final zones = _m(d['zones']);
    final load = _m(d['load']);
    final ft = _m(d['fitness_trend']);
    final fm = _m(d['fitness_model']);
    final vo2 = _m(d['vo2max']);
    return {
      'strain': _met(_f(strain, 'score'), confidence: _f(strain, 'confidence')?.toDouble(), tier: strain?['tier'] ?? 'HIGH'),
      'resting_hr': _met(_f(rhr, 'resting_hr'), unit: 'bpm', confidence: _f(rhr, 'confidence')?.toDouble()),
      'resting_hr_delta': _met(null, unit: 'bpm'),
      'recovery': _met(_f(recovery, 'score'), unit: '%', confidence: _f(recovery, 'confidence')?.toDouble()),
      'readiness': _met(_f(readiness, 'score'), unit: '%', confidence: _f(readiness, 'confidence')?.toDouble()),
      'vo2max': _met(_f(vo2, 'vo2max'), unit: 'ml/kg/min', tier: 'ESTIMATE'),
      'fitness': _met(_f(fm, 'fitness'), tier: 'ESTIMATE'),
      'form': _met(_f(fm, 'form'), tier: 'ESTIMATE'),
      'calories': _met(_f(calories, 'kcal'), unit: 'kcal', tier: 'ESTIMATE', confidence: _f(calories, 'confidence')?.toDouble()),
      'steps': _met(null, unit: 'steps', tier: 'ESTIMATE'), // live IMU only — absent from flash
      'wear_min': _met(null, unit: 'min'),
      'hr_zones': zones ?? {},
      'acwr': _met(_f(load, 'acwr'), confidence: _f(load, 'confidence')?.toDouble()),
      'fitness_trend': {'value': ft?['direction'], 'unit': '', 'confidence': _f(ft, 'confidence') ?? 0.0, 'tier': 'ESTIMATE', 'label': null, 'inputs_used': const []},
      'anomaly': d['anomaly'] ?? {},
      'confidence': _f(strain, 'confidence') ?? 0.0,
      'flags': {},
    };
  }

  /// The `sleep` envelope block (shared by /today).
  Future<Map<String, dynamic>?> _sleepEnvelope(String date) async {
    final sb = await _bundle(date, 'sleep');
    final s = _m(sb?['sleep']);
    if (s == null) return null;
    final stages = _m(s['stages']);
    return {
      'date': date,
      'duration_min': _met(_f(s, 'duration_min'), unit: 'min'),
      'need_min': _met(null, unit: 'min'),
      'efficiency': _met(_f(s, 'efficiency'), unit: '%'),
      'onset_ts': s['onset_ts'],
      'wake_ts': s['wake_ts'],
      'stages': stages == null
          ? null
          : {'light_min': stages['light_min'], 'deep_min': stages['deep_min'], 'rem_min': stages['rem_min']},
      'stages_meta': {'c': 0.5, 'tier': 'ESTIMATE', 'label': 'beta'},
      'regularity': null,
      'confidence': _f(s, 'confidence') ?? 0.0,
      'flags': {},
    };
  }

  // ── /today ──────────────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getToday() async {
    final date = await _latestDate();
    if (date == null) return {'date': null, 'daily': null, 'sleep': null, 'live': null};
    final d = await _bundle(date, 'daily');
    final hrv = _m(d?['hrv']);
    return {
      'date': date,
      'step_goal': (await LocalProfile.load())?['step_goal'],
      'coach': null,
      'stress': d?['stress'],
      'illness': d?['illness'],
      'sleep_stress': (await _bundle(date, 'sleep'))?['sleep_stress'],
      'drivers': null,
      'nocturnal': d?['nocturnal'],
      'resp': null,
      'hrv': hrv == null
          ? null
          : {
              'rmssd': _f(hrv, 'rmssd'),
              'sdnn': _f(hrv, 'sdnn'),
              'lf_hf': _f(_m(d?['hrv_freq']), 'lf_hf'),
              'cv': null,
              'confidence': 0.7,
              'baseline': null,
            },
      'skin_temp': null,
      'spo2': null,
      'daily': await _dailyEnvelope(date),
      'sleep': await _sleepEnvelope(date),
      'live': null,
    };
  }

  // ── /day/strain ───────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final d = await _bundle(date, 'daily');
    final strain = _m(d?['strain']);
    final zones = _m(d?['zones']);
    final load = _m(d?['load']);
    final fm = _m(d?['fitness_model']);
    final sessions = await _listBundle(date, 'sessions');
    return {
      'date': date,
      'strain': _f(strain, 'score'),
      'curve': const [],
      'zones': {
        'z1': zones?['zone1_min'] ?? 0,
        'z2': zones?['zone2_min'] ?? 0,
        'z3': zones?['zone3_min'] ?? 0,
        'z4': zones?['zone4_min'] ?? 0,
        'z5': zones?['zone5_min'] ?? 0,
      },
      'hr': {'max': null, 'min': null, 'avg': null},
      'max_hr_used': _f(zones, 'max_hr_used'),
      'worn_min': 0,
      'load': load == null ? null : {'acwr': _f(load, 'acwr'), 'band': load['band']},
      'fitness_trend': _m(d?['fitness_trend'])?['direction'],
      'vo2max': _f(_m(d?['vo2max']), 'vo2max'),
      'fitness_model': fm == null ? null : {'fitness': _f(fm, 'fitness'), 'fatigue': _f(fm, 'fatigue'), 'form': _f(fm, 'form')},
      'monotony': _f(_m(d?['monotony']), 'monotony'),
      'calories': _f(_m(d?['calories']), 'kcal'),
      'steps': null,
      'drivers': null,
      'sessions': sessions,
    };
  }

  // ── /day/sleep ──────────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async {
    final sb = await _bundle(date, 'sleep');
    final s = _m(sb?['sleep']);
    final hyp = _m(sb?['hypnogram']);
    return {
      'date': date,
      'has_sleep': s != null,
      'nocturnal': _m(await _bundle(date, 'daily'))?['nocturnal'],
      'resp': null,
      'onset_ts': s?['onset_ts'],
      'wake_ts': s?['wake_ts'],
      'in_bed_min': _f(s, 'in_bed_min') ?? _f(s, 'duration_min'),
      'duration_min': _f(s, 'duration_min'),
      'awake_min': _f(hyp, 'awake_min'),
      'efficiency': _f(s, 'efficiency'),
      'need_min': null,
      'debt_min': null,
      'regularity': null,
      'stages': _m(s?['stages']) == null
          ? null
          : {'light_min': s!['stages']['light_min'], 'deep_min': s['stages']['deep_min'], 'rem_min': s['stages']['rem_min']},
      'stages_beta': true,
      'hypnogram': (hyp?['hypnogram'] is List) ? hyp!['hypnogram'] : const [],
      'cycles': const [],
      'cycles_mean_min': null,
      'cycle_series': const [],
      'cycles_beta': true,
    };
  }

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    final sb = await _bundle(date, 'sleep');
    final periods = _m(sb?['periods']);
    return {
      'date': date,
      'has_sleep': periods != null,
      'need_min': null,
      'total_asleep_min': periods?['total_asleep_min'],
      'periods': (periods?['periods'] is List) ? periods!['periods'] : const [],
    };
  }

  // ── /day/heart ──────────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    final d = await _bundle(date, 'daily');
    final hrv = _m(d?['hrv']);
    final rhr = _m(d?['resting_hr']);
    return {
      'date': date,
      'hr': const [],
      'avg_hr': null,
      'max_hr': _f(_m(d?['zones']), 'max_hr_used'),
      'resting_hr': _f(rhr, 'resting_hr'),
      'resting_hr_baseline': null,
      'recovery': _f(_m(d?['recovery']), 'score'),
      'readiness': _f(_m(d?['readiness']), 'score'),
      'hrv': hrv == null
          ? null
          : {'rmssd': _f(hrv, 'rmssd'), 'sdnn': _f(hrv, 'sdnn'), 'lf_hf': _f(_m(d?['hrv_freq']), 'lf_hf'), 'cv': null, 'confidence': 0.7, 'baseline': null},
      'zones': _m(d?['zones']),
      'nocturnal': d?['nocturnal'],
      'stress': d?['stress'],
      'illness': d?['illness'],
      'irregular': null,
      'resp': null,
      'spo2': null,
      'skin_temp': null,
      'drivers': null,
    };
  }

  // ── /day/stress + /day/hrv + /day/wear + /day/timeline + /day/lungs ──────────
  @override
  Future<Map<String, dynamic>> getDayStress(String date) async {
    final d = await _bundle(date, 'daily');
    final sb = await _bundle(date, 'sleep');
    return {
      'date': date,
      'stress': d?['stress'],
      'sleep_stress': sb?['sleep_stress'],
      'drivers': null,
      'hr': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async {
    final d = await _bundle(date, 'daily');
    return {'date': date, 'daytime_hrv': d?['daytime_hrv']};
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => {
        'date': date,
        'worn_min': 0,
        'coverage_pct': null,
        'histogram': const [],
        'gaps': const [],
      };

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async =>
      {'date': date, 'hr': const [], 'activity': const [], 'sleep': null, 'sessions': const [], 'events': const []};

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async => {'date': date, 'resp': null, 'spo2': null};

  // ── /history ────────────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getHistory({String range = '30d'}) async {
    final days = await _dates();
    final n = {'7d': 7, '30d': 30, '90d': 90, '365d': 365}[range] ?? 30;
    final pick = days.length > n ? days.sublist(days.length - n) : days;
    final series = <String, List<Map<String, dynamic>>>{
      'strain': [], 'recovery': [], 'resting_hr': [], 'calories': [], 'sleep_duration': []
    };
    final calendar = <Map<String, dynamic>>[];
    for (final date in pick) {
      final d = await _bundle(date, 'daily');
      final sb = await _bundle(date, 'sleep');
      final t = _dayTs(date);
      void add(String k, num? v) { if (v != null) series[k]!.add({'t': t, 'v': v}); }
      add('strain', _f(_m(d?['strain']), 'score'));
      add('recovery', _f(_m(d?['recovery']), 'score'));
      add('resting_hr', _f(_m(d?['resting_hr']), 'resting_hr'));
      add('calories', _f(_m(d?['calories']), 'kcal'));
      final dur = _f(_m(sb?['sleep']), 'duration_min');
      add('sleep_duration', dur);
      calendar.add({'date': date, 't': t, 'strain': _f(_m(d?['strain']), 'score'), 'readiness': _f(_m(d?['recovery']), 'score'), 'wear_min': null, 'sleep_min': dur});
    }
    Map<String, dynamic> summarize(List<Map<String, dynamic>> s) {
      if (s.isEmpty) return {'avg': null, 'min': null, 'max': null, 'latest': null, 'total': null, 'delta_pct': null, 'trend': 'flat'};
      final vs = s.map((e) => (e['v'] as num).toDouble()).toList();
      final sum = vs.reduce((a, b) => a + b);
      return {'avg': sum / vs.length, 'min': vs.reduce((a, b) => a < b ? a : b), 'max': vs.reduce((a, b) => a > b ? a : b), 'latest': vs.last, 'total': sum, 'delta_pct': null, 'trend': 'flat'};
    }
    return {
      'range': range,
      'days': n,
      'metrics': {for (final k in series.keys) k: summarize(series[k]!)},
      'series': series,
      'calendar': calendar,
      'hr_zones': {'z1': 0, 'z2': 0, 'z3': 0, 'z4': 0, 'z5': 0, 'total': 0},
      'worn_days': pick.length,
      'total_days': n,
    };
  }

  // ── /trend/:metric ────────────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getTrend(String metric, {String scale = 'week', String? anchor}) async {
    final days = await _dates();
    final n = {'week': 7, 'month': 30, 'quarter': 90}[scale] ?? 7;
    final pick = days.length > n ? days.sublist(days.length - n) : days;
    final buckets = <Map<String, dynamic>>[];
    final values = <double>[];
    for (final date in pick) {
      final v = await _metricValue(metric, date);
      if (v != null) values.add(v.toDouble());
      buckets.add({
        'label': date.substring(5),
        't_start': _dayTs(date),
        't_end': _dayTs(date) + 86400,
        'value': v,
        'min': v,
        'max': v,
        'n_days': 1,
        'coverage': v == null ? 0.0 : 1.0,
        'achieved': null,
        'target': null,
        'met': null,
      });
    }
    final avg = values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
    return {
      'metric': metric,
      'label': metric,
      'unit': '',
      'scale': scale,
      'anchor': anchor ?? (pick.isEmpty ? null : pick.last),
      'summary': {
        'avg': avg,
        'min': values.isEmpty ? null : values.reduce((a, b) => a < b ? a : b),
        'max': values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b),
        'delta_vs_prev': null,
        'met_count': null,
        'total': values.isEmpty ? null : values.reduce((a, b) => a + b),
      },
      'buckets': buckets,
    };
  }

  Future<num?> _metricValue(String metric, String date) async {
    final d = await _bundle(date, 'daily');
    final sb = await _bundle(date, 'sleep');
    switch (metric) {
      case 'strain': return _f(_m(d?['strain']), 'score');
      case 'recovery': return _f(_m(d?['recovery']), 'score');
      case 'readiness': return _f(_m(d?['readiness']), 'score');
      case 'resting_hr': return _f(_m(d?['resting_hr']), 'resting_hr');
      case 'calories': return _f(_m(d?['calories']), 'kcal');
      case 'hrv': case 'hrv_rmssd': return _f(_m(d?['hrv']), 'rmssd');
      case 'vo2max': return _f(_m(d?['vo2max']), 'vo2max');
      case 'fitness': return _f(_m(d?['fitness_model']), 'fitness');
      case 'fatigue': return _f(_m(d?['fitness_model']), 'fatigue');
      case 'form': return _f(_m(d?['fitness_model']), 'form');
      case 'acwr': return _f(_m(d?['load']), 'acwr');
      case 'sleep_duration': case 'sleep': return _f(_m(sb?['sleep']), 'duration_min');
      case 'sleep_efficiency': return _f(_m(sb?['sleep']), 'efficiency');
      default: return null;
    }
  }

  // ── /workouts + /sessions + /strain + /sleep lists ──────────────────────────
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final days = await _dates();
    final n = {'week': 7, 'month': 30, 'quarter': 90}[range] ?? 30;
    final pick = days.length > n ? days.sublist(days.length - n) : days;
    final workouts = <Map<String, dynamic>>[];
    for (final date in pick) {
      for (final w in await _listBundle(date, 'sessions')) {
        workouts.add({...w, 'status': 'done', 'source': 'auto', 'detected': true});
      }
    }
    return {
      'range': range,
      'workouts': workouts,
      'summary': {
        'count': workouts.length,
        'total_min': 0,
        'total_calories': 0,
        'by_type': {},
        'zone_min': const [0, 0, 0, 0, 0],
        'hardest': null,
        'classifier': {'reviewed': 0, 'correct': 0, 'accuracy': null},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getWorkout(String id) async => {'id': id, 'hr': const []};

  @override
  Future<List<Map<String, dynamic>>> getStrain({int? from, int? to}) async {
    final out = <Map<String, dynamic>>[];
    for (final date in await _dates()) {
      final d = await _bundle(date, 'daily');
      out.add({'date': date, 'strain': _f(_m(d?['strain']), 'score'), 'recovery': _f(_m(d?['recovery']), 'score'), 'resting_hr': _f(_m(d?['resting_hr']), 'resting_hr')});
    }
    return out.reversed.toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) async {
    final out = <Map<String, dynamic>>[];
    for (final date in await _dates()) {
      out.addAll(await _listBundle(date, 'sessions'));
    }
    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> getSleep({int? from, int? to}) async {
    final out = <Map<String, dynamic>>[];
    for (final date in await _dates()) {
      final s = _m((await _bundle(date, 'sleep'))?['sleep']);
      if (s != null) out.add({'date': date, ...s});
    }
    return out.reversed.toList();
  }

  // ── secondary endpoints: valid empty shapes (graceful "—") ───────────────────
  @override
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to}) async => {'metric': metric, 'series': const []};

  @override
  Future<Map<String, dynamic>> getNotifications() async => {'unread': 0, 'notifications': const []};

  @override
  Future<Map<String, dynamic>> getRecords() async => {'records': const [], 'streaks': const [], 'baseline': null};

  @override
  Future<Map<String, dynamic>> getCycle() async => {'phase': null, 'prediction': null, 'logs': const [], 'overlay': const []};

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async => const [];

  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async => {'range': range, 'insights': const []};

  @override
  Future<Map<String, dynamic>> getAppStatus() async => const {}; // no OTA pointer in local mode

  // ── profile (local-backed) ──────────────────────────────────────────────────
  @override
  Future<Map<String, dynamic>> getProfile() async => (await LocalProfile.load()) ?? {};

  @override
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> fields) async => LocalProfile.patch(fields);

  // ── writes: local no-ops (return plausible shapes) ───────────────────────────
  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {}
  @override
  Future<void> postCycleLog(String date, {String kind = 'start', String? note}) async {}
  @override
  Future<void> deleteCycleLog(String date) async {}
  @override
  Future<void> markNotificationsRead({List<String>? ids}) async {}
  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async =>
      {'workout_id': null, 'type': type, 'status': 'live'};
  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async => {'workout_id': workoutId};
  @override
  Future<Map<String, dynamic>> setWorkoutType(String id, String type) async => {'type': type, 'type_source': 'confirmed'};
  @override
  Future<void> deleteWorkout(String id) async {}

  static int _dayTs(String date) {
    final p = date.split('-');
    return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2])).millisecondsSinceEpoch ~/ 1000;
  }
}
