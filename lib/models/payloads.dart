// Per-screen response models. Each wraps a raw decoded payload and exposes
// typed Metric getters. EVERYTHING is defensive: the backend is being finalized
// in parallel, so any field can be missing → Metric.empty (renders "—").

import 'dart:convert';
import 'metric.dart';

/// Decode a `flags` field that may be a JSON string, a map, or null.
Map<String, dynamic> decodeFlags(Object? flags) {
  if (flags is Map) return flags.cast<String, dynamic>();
  if (flags is String && flags.isNotEmpty) {
    try {
      final d = jsonDecode(flags);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
  }
  return const {};
}

num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

/// A metric resolved either from an object field or a scalar+flags pair.
Metric metricOf(
  Map<String, dynamic> row,
  String key, {
  Map<String, dynamic>? flags,
}) {
  final raw = row[key];
  if (raw is Map) return Metric.parse(raw);
  return Metric.parse(raw, flag: flagFor(flags, key));
}

/// ── /today ──────────────────────────────────────────────────────────────────
/// Backend nests metrics under `daily` and `sleep` sub-objects (each already a
/// metric envelope). We read straight from those — no top-level flags needed.
class TodayData {
  final Map<String, dynamic> _daily;
  final Map<String, dynamic> _sleep;
  final Map<String, dynamic>? _coach;
  final Map<String, dynamic>? _stress;
  final Map<String, dynamic>? _nocturnal;
  final Map<String, dynamic>? _resp;
  final Map<String, dynamic>? _hrv;
  final Map<String, dynamic>? _skinTemp;
  final Map<String, dynamic>? _spo2;
  final Map<String, dynamic>? _status;

  /// User's daily step goal (null → use the client default). Top-level on /today.
  final int? stepGoal;

  TodayData._(
    this._daily,
    this._sleep,
    this._coach,
    this._stress,
    this._nocturnal,
    this._resp,
    this._hrv,
    this._skinTemp,
    this._spo2,
    this._status,
    this.stepGoal,
  );

  factory TodayData.fromJson(Object? json) {
    final row = json is Map ? json.cast<String, dynamic>() : const {};
    Map<String, dynamic>? sub(String k) =>
        (row[k] is Map) ? (row[k] as Map).cast<String, dynamic>() : null;
    final daily = sub('daily') ?? const <String, dynamic>{};
    final sleep = sub('sleep') ?? const <String, dynamic>{};
    final goal = (row['step_goal'] as num?)?.toInt();
    return TodayData._(
      daily,
      sleep,
      sub('coach'),
      sub('stress'),
      sub('nocturnal'),
      sub('resp'),
      sub('hrv'),
      sub('skin_temp'),
      sub('spo2'),
      sub('status'),
      goal,
    );
  }

  TodayStatus? get status => _status == null ? null : TodayStatus(_status);

  /// Nocturnal HRV (RMSSD, ms) — measured from beat-to-beat intervals. Null until
  /// a night's worth of RR has been captured.
  ({double rmssd, double confidence, double? baseline})? get hrv {
    final h = _hrv;
    if (h == null || h['rmssd'] == null) return null;
    return (
      rmssd: (h['rmssd'] as num).toDouble(),
      confidence: (h['confidence'] as num?)?.toDouble() ?? 0,
      baseline: (h['baseline'] as num?)?.toDouble(),
    );
  }

  /// Skin-temp deviation vs your baseline (relative, raw units), or null.
  double? get skinTempIdx => (_skinTemp?['value'] as num?)?.toDouble();

  /// Overnight relative oxygen-dip screen derived from red/IR channels.
  Spo2Data? get spo2 =>
      (_spo2 == null || _spo2['odi_per_hour'] == null) ? null : Spo2Data(_spo2);

  /// The deterministic coach output (plan + strain target + contributors), or null.
  CoachData? get coach => _coach == null ? null : CoachData(_coach);

  /// Stress / arousal monitor summary (NOT HRV), or null.
  StressData? get stress => (_stress == null || _stress['score'] == null)
      ? null
      : StressData(_stress);

  /// Nocturnal-heart summary, or null when no sleeping-HR was measured.
  NocturnalData? get nocturnal =>
      (_nocturnal == null || _nocturnal['sleeping_hr_avg'] == null)
      ? null
      : NocturnalData(_nocturnal);

  /// Respiratory rate (PPG) — only present once validated server-side; else null.
  RespData? get resp => _resp == null ? null : RespData(_resp);

  // Recovery is HRV-based now (replaces the old heuristic readiness). Kept the
  // getter name `readiness` is dropped in favour of `recovery`.
  Metric get recovery => metricOf(_daily, 'recovery');
  // Composite Readiness (HRV ∩ sleep ∩ dip ∩ arousal) — the Today/widget headline.
  Metric get readiness => metricOf(_daily, 'readiness');
  Metric get vo2max => metricOf(_daily, 'vo2max');
  Metric get fitness => metricOf(_daily, 'fitness');
  Metric get form => metricOf(_daily, 'form');
  Metric get strain => metricOf(_daily, 'strain');
  Metric get restingHr => metricOf(_daily, 'resting_hr');
  Metric get rhrDelta => metricOf(_daily, 'resting_hr_delta');
  Metric get wearTime => metricOf(_daily, 'wear_min');
  Metric get calories => metricOf(_daily, 'calories'); // active calories (est.)
  Metric get caloriesTotal =>
      metricOf(_daily, 'calories_total'); // total daily energy (TDEE, est.)
  Metric get steps => metricOf(_daily, 'steps'); // 24/7 step estimate
  Metric get activeMin => metricOf(_daily, 'active_min'); // movement minutes

  /// Body alert (illness/overtraining) — {signal, kind, triggers, note} or null.
  Map<String, dynamic>? get bodyAlert {
    final a = _daily['anomaly'];
    if (a is Map && a['signal'] == true) return a.cast<String, dynamic>();
    return null;
  }

  // Sleep summary for the ring: asleep-vs-need (there is NO 0–100 sleep score).
  Metric get sleepDuration => metricOf(_sleep, 'duration_min');
  Metric get sleepNeed => metricOf(_sleep, 'need_min');
  Metric get sleepEfficiency => metricOf(_sleep, 'efficiency');

  bool get isEmpty => _daily.isEmpty && _sleep.isEmpty;
}

class TodayStatus {
  final Map<String, dynamic> _s;
  TodayStatus(this._s);

  String? get todayDay => _s['today_day']?.toString();
  String get activityState => (_s['activity_state'] ?? 'missing').toString();
  String? get activityDay => _s['activity_day']?.toString();
  int? get activityComputedAt => (_s['activity_computed_at'] as num?)?.toInt();
  String get overnightState => (_s['overnight_state'] ?? 'missing').toString();
  String? get overnightDay => _s['overnight_day']?.toString();
  int? get overnightComputedAt =>
      (_s['overnight_computed_at'] as num?)?.toInt();
  bool get showingPriorOvernight => _s['showing_prior_overnight'] == true;

  bool get overnightBuilding => overnightState == 'building';
  bool get activityBuilding => activityState == 'building';
  bool get overnightReady => overnightState == 'ready';
  bool get activityReady => activityState == 'ready';
}

/// ── coach (from /today.coach) — deterministic plan, strain target, contributors ─
class CoachData {
  final Map<String, dynamic> _c;
  CoachData(this._c);

  String get summary => (_c['summary'] ?? '').toString();

  /// Recommended strain target {value, low, high, rationale}, or null.
  ({double value, double low, double high, String rationale})?
  get strainTarget {
    final t = _c['strain_target'];
    if (t is! Map) return null;
    return (
      value: _d(t['value']),
      low: _d(t['low']),
      high: _d(t['high']),
      rationale: (t['rationale'] ?? '').toString(),
    );
  }

  List<CoachSuggestion> get plan => ((_c['plan'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => CoachSuggestion(e.cast<String, dynamic>()))
      .toList();

  List<CoachContributor> get contributors =>
      ((_c['readiness_contributors'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => CoachContributor(e.cast<String, dynamic>()))
          .toList();

  static double _d(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

class CoachSuggestion {
  final Map<String, dynamic> _s;
  CoachSuggestion(this._s);
  String get id => (_s['id'] ?? '').toString();
  String get category => (_s['category'] ?? '').toString();
  String get title => (_s['title'] ?? '').toString();
  String get body => (_s['body'] ?? '').toString();
  int get severity => (_s['severity'] as num?)?.toInt() ?? 0;
  String? get target => _s['target']?.toString();
  List<({String label, String value, String? detail})> get why =>
      ((_s['why'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (w) => (
              label: (w['label'] ?? '').toString(),
              value: (w['value'] ?? '').toString(),
              detail: w['detail']?.toString(),
            ),
          )
          .toList();
}

class CoachContributor {
  final Map<String, dynamic> _c;
  CoachContributor(this._c);
  String get key => (_c['key'] ?? '').toString();
  String get label => (_c['label'] ?? '').toString();
  num? get value => _c['value'] as num?;
  num? get baseline => _c['baseline'] as num?;
  double get impact => (_c['impact'] as num?)?.toDouble() ?? 0;
  String get note => (_c['note'] ?? '').toString();
}

/// ── stress / arousal monitor (from /today.stress or /day/stress summary) ──────
class StressData {
  final Map<String, dynamic> _s;
  StressData(this._s);
  int? get score => (_s['score'] as num?)?.toInt();
  int get calmMin => (_s['calm_min'] as num?)?.toInt() ?? 0;
  int get balancedMin => (_s['balanced_min'] as num?)?.toInt() ?? 0;
  int get stressedMin => (_s['stressed_min'] as num?)?.toInt() ?? 0;
  int get activeMin => (_s['active_min'] as num?)?.toInt() ?? 0;
  int get wornMin => (_s['worn_min'] as num?)?.toInt() ?? 0;
  ({int ts, int score})? get peak {
    final p = _s['peak'];
    if (p is! Map) return null;
    final ts = _num(p['t'] ?? p['ts'])?.toInt();
    final sc = _num(p['score'])?.toInt();
    if (ts == null || sc == null) return null;
    return (ts: ts, score: sc);
  }

  /// A short human label for the day's stress level.
  String get band {
    final v = score ?? 0;
    if (v < 25) return 'Calm day';
    if (v < 50) return 'Balanced';
    if (v < 75) return 'Elevated';
    return 'High arousal';
  }
}

/// ── nocturnal heart (from /today.nocturnal or /day/sleep.nocturnal) ───────────
class NocturnalData {
  final Map<String, dynamic> _n;
  NocturnalData(this._n);
  int? get sleepingHrAvg => (_n['sleeping_hr_avg'] as num?)?.toInt();
  int? get sleepingHrMin => (_n['sleeping_hr_min'] as num?)?.toInt();
  int? get nadirTs => (_n['nadir_ts'] as num?)?.toInt();
  int? get dayHrAvg => (_n['day_hr_avg'] as num?)?.toInt();
  double? get dipPct => (_n['dip_pct'] as num?)?.toDouble();
  double? get vsBaselineBpm => (_n['vs_baseline_bpm'] as num?)?.toDouble();
  bool get elevated => _n['elevated'] == true;
}

class Spo2Data {
  final Map<String, dynamic> _s;
  Spo2Data(this._s);

  double? get odiPerHour => (_s['odi_per_hour'] as num?)?.toDouble();
  int get dipCount => (_s['dip_count'] as num?)?.toInt() ?? 0;
  double? get meanDipPct => (_s['mean_dip_pct'] as num?)?.toDouble();
  double? get burdenPct => (_s['burden_pct'] as num?)?.toDouble();
  double? get signalCoverage => (_s['signal_coverage'] as num?)?.toDouble();
  double? get trustedCoverage => (_s['trusted_coverage'] as num?)?.toDouble();
  double? get confidence => (_s['confidence'] as num?)?.toDouble();
}

/// ── respiratory rate (PPG; gated — only present once validated) ───────────────
class RespData {
  final Map<String, dynamic> _r;
  RespData(this._r);
  double? get value => (_r['value'] as num?)?.toDouble();
  double get confidence => (_r['confidence'] as num?)?.toDouble() ?? 0;
}

/// ── /records — your body over time (PRs + streaks + baseline drift) ───────────
class RecordsData {
  final Map<String, dynamic> _r;
  RecordsData(this._r);

  factory RecordsData.fromJson(Object? json) =>
      RecordsData(json is Map ? json.cast<String, dynamic>() : const {});

  int get daysTracked => (_r['days_tracked'] as num?)?.toInt() ?? 0;
  int get nightsTracked => (_r['nights_tracked'] as num?)?.toInt() ?? 0;
  int get workoutsTracked => (_r['workouts_tracked'] as num?)?.toInt() ?? 0;

  Map<String, dynamic> get _records =>
      (_r['records'] is Map) ? (_r['records'] as Map).cast() : const {};

  /// A record = {value, date} (+ optional type). null when never set.
  ({num value, String date, String? type})? record(String key) {
    final m = _records[key];
    if (m is! Map) return null;
    final v = _num(m['value']);
    final d = m['date']?.toString();
    if (v == null || d == null) return null;
    return (value: v, date: d, type: m['type']?.toString());
  }

  /// streak {current, label} for wear/sleep/strain_target.
  ({int current, String label})? streak(String key) {
    final s = (_r['streaks'] is Map) ? (_r['streaks'] as Map)[key] : null;
    if (s is! Map) return null;
    return (
      current: (_num(s['current'])?.toInt()) ?? 0,
      label: (s['label'] ?? '').toString(),
    );
  }

  ({double now, double then, double delta, String direction, int days})?
  get rhrDrift {
    final d = _r['rhr_drift'];
    if (d is! Map) return null;
    return (
      now: _num(d['now'])?.toDouble() ?? 0,
      then: _num(d['then'])?.toDouble() ?? 0,
      delta: _num(d['delta'])?.toDouble() ?? 0,
      direction: (d['direction'] ?? '').toString(),
      days: _num(d['days'])?.toInt() ?? 0,
    );
  }

  bool get isEmpty => daysTracked == 0 && nightsTracked == 0;
}

/// ── /notifications — server-generated personalized feed ──────────────────────
class NotificationItem {
  final Map<String, dynamic> _n;
  NotificationItem(this._n);
  String get id => (_n['id'] ?? '').toString();
  String get kind => (_n['kind'] ?? '').toString();
  String get category => (_n['category'] ?? '').toString();
  int get priority => (_n['priority'] as num?)?.toInt() ?? 0;
  String get title => (_n['title'] ?? '').toString();
  String get body => (_n['body'] ?? '').toString();
  bool get read => _n['read'] == true;
  int? get createdAt => (_n['created_at'] as num?)?.toInt();
}

class NotificationsData {
  final int unread;
  final List<NotificationItem> items;
  const NotificationsData(this.unread, this.items);

  factory NotificationsData.fromJson(Object? json) {
    final row = json is Map ? json.cast<String, dynamic>() : const {};
    final list = (row['notifications'] as List?) ?? const [];
    return NotificationsData(
      (row['unread'] as num?)?.toInt() ?? 0,
      list
          .whereType<Map>()
          .map((e) => NotificationItem(e.cast<String, dynamic>()))
          .toList(),
    );
  }
  bool get isEmpty => items.isEmpty;
}

/// ── /sleep (a row, newest first) ──────────────────────────────────────────────
class SleepData {
  final Map<String, dynamic> _row;
  final Map<String, dynamic> _flags;
  SleepData(this._row) : _flags = decodeFlags(_row['flags']);

  factory SleepData.fromRows(List<Map<String, dynamic>> rows) =>
      SleepData(rows.isNotEmpty ? rows.first : {});

  // Scalar columns + a `flags` blob keyed {duration, stages}. duration_min and
  // efficiency both carry the `duration` confidence entry.
  Metric get durationMin => Metric.parse(
    _num(_row['duration_min']),
    flag: flagFor(_flags, 'duration'),
  );
  // need_min comes from the user's baseline (backend attaches it per row).
  Metric get needMin => metricOf(_row, 'need_min', flags: _flags);
  Metric get efficiency =>
      Metric.parse(_num(_row['efficiency']), flag: flagFor(_flags, 'duration'));
  // Sleep-timing consistency 0–100 (circular variance of bed/wake times — not the
  // Phillips epoch-agreement SRI); backend column is `regularity` (bare number).
  Metric get regularity => metricOf(_row, 'regularity', flags: _flags);
  // 4-class wrist stages (estimate): Awake / Light / Deep / REM. Light + Deep
  // split NREM via HR + motion (no EEG); Deep is a low-confidence overlay.
  // nremMin (= light + deep) is kept for back-compat.
  Metric get lightMin => metricOf(_row, 'light_min', flags: _flags);
  Metric get deepMin => metricOf(_row, 'deep_min', flags: _flags);
  Metric get nremMin => metricOf(_row, 'nrem_min', flags: _flags);
  Metric get remMin => metricOf(_row, 'rem_min', flags: _flags);

  int? get onsetEpoch => _num(_row['onset'] ?? _row['onset_ts'])?.toInt();
  int? get wakeEpoch => _num(_row['wake'] ?? _row['wake_ts'])?.toInt();

  /// Stages are ESTIMATE/beta per CONFIDENCE.
  bool get stagesBeta => true;

  bool get isEmpty => _row.isEmpty;
}

/// ── /strain (daily, newest first) ────────────────────────────────────────────
class StrainData {
  final Map<String, dynamic> _row;
  final Map<String, dynamic> _flags;
  StrainData(this._row) : _flags = decodeFlags(_row['flags']);

  factory StrainData.fromRows(List<Map<String, dynamic>> rows) =>
      StrainData(rows.isNotEmpty ? rows.first : {});

  // Daily row scalars + a `flags` blob. Note the flag keys differ from the
  // column names: acwr→`load`.
  Metric get dailyStrain => metricOf(_row, 'strain', flags: _flags);
  Metric get acwr =>
      Metric.parse(_num(_row['acwr']), flag: flagFor(_flags, 'load'));
  // steps + active/sedentary REMOVED in v0. calories = ACTIVE calories (est.).
  Metric get calories => metricOf(_row, 'calories', flags: _flags);
  Metric get steps => metricOf(_row, 'steps', flags: _flags); // detected (est.)

  /// HR zone minutes z1..z5 (may live as a nested object or a JSON string).
  List<int> get zoneMinutes {
    final z = _row['hr_zones'];
    final map = decodeFlags(z);
    return [
      _num(map['zone1_min'])?.toInt() ?? 0,
      _num(map['zone2_min'])?.toInt() ?? 0,
      _num(map['zone3_min'])?.toInt() ?? 0,
      _num(map['zone4_min'])?.toInt() ?? 0,
      _num(map['zone5_min'])?.toInt() ?? 0,
    ];
  }

  bool get isEmpty => _row.isEmpty;
}

/// ── a single auto-detected workout ───────────────────────────────────────────
class Session {
  final Map<String, dynamic> _row;
  final Map<String, dynamic> _flags;
  Session(this._row) : _flags = decodeFlags(_row['flags']);

  int? get startEpoch =>
      _num(_row['start'] ?? _row['start_ts'] ?? _row['onset'])?.toInt();
  int? get durationMin => _num(_row['duration_min'])?.toInt();
  String get type => (_row['type'] ?? _row['sport'] ?? 'Workout').toString();
  Metric get avgHr => metricOf(_row, 'avg_hr', flags: _flags);
  Metric get maxHr => metricOf(_row, 'max_hr', flags: _flags);
  Metric get strain => metricOf(_row, 'strain', flags: _flags);
  Metric get hrr60 => metricOf(_row, 'hrr60', flags: _flags);
  Metric get calories => metricOf(_row, 'calories', flags: _flags);

  List<int> get zoneMinutes {
    final map = decodeFlags(_row['hr_zones']);
    return [
      _num(map['zone1_min'])?.toInt() ?? 0,
      _num(map['zone2_min'])?.toInt() ?? 0,
      _num(map['zone3_min'])?.toInt() ?? 0,
      _num(map['zone4_min'])?.toInt() ?? 0,
      _num(map['zone5_min'])?.toInt() ?? 0,
    ];
  }
}

/// ── /trends ──────────────────────────────────────────────────────────────────
class TrendsData {
  final Map<String, dynamic> _row;
  TrendsData(this._row);

  factory TrendsData.fromJson(Object? json) =>
      TrendsData(json is Map ? json.cast<String, dynamic>() : {});

  /// A named time series → list of (epochSec, value).
  List<TrendPoint> series(String key) {
    final raw =
        _row[key] ?? (_row['series'] is Map ? _row['series'][key] : null);
    if (raw is! List) return const [];
    final out = <TrendPoint>[];
    for (final e in raw) {
      if (e is Map) {
        final t = _num(e['t'] ?? e['ts'] ?? e['date'])?.toInt();
        final v = _num(e['v'] ?? e['value']);
        if (t != null && v != null) out.add(TrendPoint(t, v.toDouble()));
      } else if (e is List && e.length >= 2) {
        final t = _num(e[0])?.toInt();
        final v = _num(e[1]);
        if (t != null && v != null) out.add(TrendPoint(t, v.toDouble()));
      }
    }
    return out;
  }

  Map<String, dynamic> get baseline =>
      (_row['baseline'] is Map) ? (_row['baseline'] as Map).cast() : const {};

  double? get rhrBaseline => _num(baseline['resting_hr'])?.toDouble();

  /// Fitness direction: 'improving' | 'flat' | 'declining'.
  String? get fitnessDirection => _row['fitness_direction']?.toString();
  double? get rhrSlope => _num(_row['rhr_slope'])?.toDouble();
  double? get hrrSlope => _num(_row['hrr_slope'])?.toDouble();

  /// Anomaly / illness signal (ESTIMATE). null when not fired. Backend shape is
  /// `{signal:bool, message:string}` — only surface when signal is true AND the
  /// message is non-empty.
  String? get anomalyMessage {
    final a = _row['anomaly'] ?? _row['illness_signal'];
    if (a is Map) {
      if (a['signal'] == false) return null;
      final m = a['message']?.toString();
      return (m != null && m.isNotEmpty) ? m : null;
    }
    if (a is String && a.isNotEmpty) return a;
    return null;
  }

  bool get isEmpty => _row.isEmpty;
}

class TrendPoint {
  final int t; // epoch seconds
  final double v;
  const TrendPoint(this.t, this.v);
}

/// ── /chart?metric=hr → list of (epochSec, value) ─────────────────────────────
class ChartSeries {
  final List<TrendPoint> points;
  const ChartSeries(this.points);

  factory ChartSeries.fromJson(Object? json) {
    final list = json is Map ? (json['points'] ?? json['data']) : json;
    if (list is! List) return const ChartSeries([]);
    final out = <TrendPoint>[];
    for (final e in list) {
      if (e is Map) {
        final t = _num(e['t'] ?? e['ts'])?.toInt();
        final v = _num(e['v'] ?? e['value'] ?? e['hr']);
        if (t != null && v != null && v > 0) {
          out.add(TrendPoint(t, v.toDouble()));
        }
      } else if (e is List && e.length >= 2) {
        final t = _num(e[0])?.toInt();
        final v = _num(e[1]);
        if (t != null && v != null && v > 0) {
          out.add(TrendPoint(t, v.toDouble()));
        }
      }
    }
    return ChartSeries(out);
  }

  bool get isEmpty => points.isEmpty;
}
