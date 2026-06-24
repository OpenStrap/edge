// LocalPipeline — the on-device compute path for LOCAL mode.
//
//   raw frames (LocalDb) → decode (Rust core via NativeCore) → per physiological
//   day: minutes + pooled RR + per-minute RR → the FULL analytics chain (Rust core,
//   incl. the 1 Hz-native family) → store derived bundles (LocalDb), PERMANENT.
//
// Mirrors the backend `processUser` 3-pass orchestration so local == cloud:
//   Pass 1  seed baselines from the permanent derived history (calc_baselines)
//   Pass 2  per-day metrics (sleep, strain, zones, calories, rhr, HRV, recovery,
//           stress, nocturnal, sessions, illness, anomaly, + 1 Hz: cvhr / dc_ac /
//           asymmetry / long-term HRV / circadian HRV / daytime HRV)
//   Pass 3  cross-day windows (load/ACWR, fitness model, monotony, fitness trend,
//           vo2max, sleep regularity, readiness index)
//
// Every NUMBER comes from the Rust core (byte-identical to the cloud wasm build);
// only the orchestration (which days, what inputs) lives here, mirroring the server.
//
// Call OPPORTUNISTICALLY (sync-complete / app-resume / on-charge), never as heavy
// background work (iOS will kill it). Idempotent: re-running recomputes + replaces.
import 'dart:convert';
import '../data/db.dart';
import '../native/native_core.dart';

class LocalPipeline {
  final NativeCore core;
  final Map<String, dynamic>? profile; // user-shaped map (age/sex/height_cm/weight_kg)
  LocalPipeline(this.core, {this.profile});

  /// Decode diagnostics from the last computeAll: how many raw rows were valid
  /// historical R24 (kept) vs skipped (live/wrong-type/garbage-ts), and the day count.
  ({int kept, int skipped, int days})? lastDecode;

  static const _retentionDays = 14;

  // Physiological-day windows (mirror backend sleepMinutes()): a day's "night" is the
  // prior evening 18:00 → this noon 12:00, so a sleep that crosses midnight attributes
  // to the wake-up day.
  static const _sleepWindowStartHour = 18; // prev day
  static const _sleepWindowEndHour = 12; // this day

  /// Decode all stored raw, derive the full metric set per day, persist to the local
  /// derived store, then prune raw past the 14-day retention. Returns days written.
  Future<int> computeAll() async {
    final raws = await LocalDb.rawHexForCompute();

    // Decode → per-day accumulators. _DayBin holds the minute HR buckets + the
    // full beat-to-beat RR for one UTC date.
    //
    // GATE STRICTLY: only historical type-24 frames carry the 1 Hz HR + beat-to-beat
    // RR we derive from. That means packet_type 0x2F (historicalData) AND record_type
    // 24 (= 0x18, at inner byte [1] → hex chars 2..4). This matters because
    // parse_r24() does NOT check the record type — handing it a live packet
    // (0x28/0x2B/0x33) or a historical R10 reads random bytes as a timestamp and
    // scatters them across thousands of bogus "days" (the "1322 days" bug). After the
    // type gate we still sanity-check the epoch (drops RTC-unset / corrupt frames).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const tsFloor = 1609459200; // 2021-01-01 — anything older is a dead/garbage RTC
    final bins = <String, _DayBin>{};
    var kept = 0, skipped = 0;
    for (final row in raws) {
      final pt = (row['packet_type'] as int?) ?? 0;
      final hex = row['hex'] as String;
      if (pt != 0x2F || hex.length < 4 || hex.substring(2, 4).toLowerCase() != '18') {
        skipped++;
        continue;
      }
      final out = core.decode('decode_r24', hex);
      if (out == null) {
        skipped++;
        continue;
      }
      final ts = ((out['ts_epoch'] ?? 0) as num).toInt();
      if (ts < tsFloor || ts > nowSec + 86400) {
        skipped++; // RTC-unset / corrupt timestamp
        continue;
      }
      final hr = ((out['hr'] ?? 0) as num).toDouble();
      final rr = ((out['rr_intervals_ms'] ?? const []) as List).cast<num>();
      (bins[_utcDate(ts)] ??= _DayBin()).add(ts, hr, rr);
      kept++;
    }
    lastDecode = (kept: kept, skipped: skipped, days: bins.length);
    if (bins.isEmpty) {
      await _pruneIfDerived();
      return 0;
    }

    final days = bins.keys.toList()..sort();

    // ── Pass 1: seed baselines from the PERMANENT derived history (never the window) ──
    final baseline = await _seedBaseline(days.first);

    // ── Pass 2: per-day metrics ──
    final dailyStrainSeries = <Map<String, dynamic>>[]; // {ts, strain} for cross-day
    final nightSummaries = <Map<String, dynamic>>[]; // {onset_ts, wake_ts}
    final rmssdHistory = <double>[]; // for recovery z-score
    final siHistory = <double>[]; // for stress z-score
    final perDay = <String, Map<String, dynamic>>{}; // date -> daily bundle (mutable)

    var written = 0;
    for (final day in days) {
      final bin = bins[day]!;
      final minutes = bin.minutes();
      if (minutes.isEmpty) continue;

      // Night window = prev-evening 18:00 → this-noon 12:00 (UTC proxy).
      final sleepMinutes = _nightMinutes(bins, day);
      final sleepRr = _nightRrByMin(bins, day);
      final pooledNightRr = sleepRr.expand((m) => (m['rr'] as List).cast<num>()).toList();

      // Sleep + hypnogram.
      final sleep = core.analytics('calc_sleep', {'minutes': sleepMinutes, 'baseline': baseline});
      final onset = (sleep is Map ? sleep['onset_ts'] : null);
      final wake = (sleep is Map ? sleep['wake_ts'] : null);
      Map<String, dynamic>? hypno;
      if (onset != null && wake != null) {
        final h = core.analytics('stage_hypnogram', {
          'minutes': sleepMinutes,
          'onset': onset,
          'wake': wake,
          'baseline': baseline,
          'rr_by_min': sleepRr,
        });
        if (h is Map<String, dynamic>) hypno = h;
      }
      final periods = core.analytics('calc_sleep_periods', {'minutes': sleepMinutes, 'baseline': baseline});
      nightSummaries.add({'onset_ts': onset, 'wake_ts': wake});

      // Heart / strain / energy.
      final restingHr = core.analytics('calc_resting_hr', {
        'minutes': minutes,
        'sleep_window': {'onset_ts': onset, 'wake_ts': wake},
      });
      final strain = core.analytics('calc_strain', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
      final zones = core.analytics('calc_hr_zones', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
      final calories = core.analytics('calc_calories', {
        'minutes': minutes,
        'profile': profile ?? const {},
        'resting_hr': _num(restingHr, 'resting_hr') ?? baseline['resting_hr'],
        'max_hr': _num(zones, 'max_hr_used'),
      });
      final hrRecovery = core.analytics('calc_hr_recovery', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
      final sessions = core.analytics('detect_sessions', {'minutes': minutes, 'baseline': baseline, 'profile': profile});

      // Nocturnal heart + sleep arousal/restlessness.
      final nocturnal = core.analytics('calc_nocturnal_heart', {
        'sleep_minutes': sleepMinutes,
        'day_minutes': minutes,
        'baseline': baseline,
      });
      final sleepStress = core.analytics('calc_sleep_stress', {'sleep_minutes': sleepMinutes, 'baseline': baseline});
      final restlessness = core.analytics('calc_restlessness', {'sleep_minutes': sleepMinutes, 'baseline': baseline});

      // HRV (nocturnal pooled RR) — the recovery/stress anchor.
      final hrvTime = core.analytics('time_domain_hrv', {'rr': pooledNightRr});
      final hrvFreq = core.analytics('freq_domain_hrv', {'rr': pooledNightRr});
      final baevsky = core.analytics('baevsky_stress_index', {'rr': pooledNightRr});
      final rmssd = _num(hrvTime, 'rmssd');
      final si = _num(baevsky, 'si');
      final recovery = core.analytics('calc_recovery', {
        'rmssd_today': rmssd,
        'baseline_rmssd': List<double>.from(rmssdHistory),
        'date': day,
      });
      final stress = core.analytics('calc_stress', {
        'rr': pooledNightRr,
        'baseline_si': List<double>.from(siHistory),
        'date': day,
      });
      if (rmssd != null) rmssdHistory.add(rmssd.toDouble());
      if (si != null) siHistory.add(si.toDouble());

      // ── 1 Hz-native family (the whole reason to be local: 24/7 beat-to-beat RR) ──
      final cvhr = core.analytics('calc_cvhr', {'rr': pooledNightRr});
      final dcAc = core.analytics('calc_dc_ac', {'rr': pooledNightRr});
      final asymmetry = core.analytics('calc_hr_asymmetry', {'rr': pooledNightRr});
      final longHrv = core.analytics('calc_long_term_hrv', {'rr': pooledNightRr});
      final circadianHrv = core.analytics('calc_circadian_hrv', {
        'by_minute': bin.rrByMin(),
        'night_from': onset,
        'night_to': wake,
      });
      final daytimeHrv = core.analytics('calc_daytime_hrv', {'by_minute': bin.daytimeRrByMin(onset, wake)});

      // Illness / anomaly screens (need ≥7 days of history → null early, honestly).
      final illness = core.analytics('calc_illness', {
        'today': {'resting_hr': _num(restingHr, 'resting_hr'), 'rmssd': rmssd},
        'history': {
          'resting_hr': _history(perDay, 'resting_hr'),
          'rmssd': List<double>.from(rmssdHistory),
        },
      });
      final anomaly = core.analytics('calc_anomaly', {
        'recent_rhr': _history(perDay, 'resting_hr'),
        'sleep_efficiency': (sleep is Map ? sleep['efficiency'] : null),
        'baseline': baseline,
      });

      // Accumulate cross-day series.
      final strainScore = _num(strain, 'score') ?? 0.0;
      final dayTs = _dayStartTs(day);
      dailyStrainSeries.add({'ts': dayTs, 'strain': strainScore});

      // Assemble the per-day bundles (raw FFI outputs, stored verbatim).
      perDay[day] = {
        'strain': strain,
        'resting_hr': restingHr,
        'zones': zones,
        'calories': calories,
        'hr_recovery': hrRecovery,
        'hrv': hrvTime,
        'hrv_freq': hrvFreq,
        'baevsky': baevsky,
        'recovery': recovery,
        'stress': stress,
        'nocturnal': nocturnal,
        'illness': illness,
        'anomaly': anomaly,
        'cvhr': cvhr,
        'dc_ac': dcAc,
        'asymmetry': asymmetry,
        'long_hrv': longHrv,
        'circadian_hrv': circadianHrv,
        'daytime_hrv': daytimeHrv,
      };

      await LocalDb.upsertDerived(day, 'sleep', jsonEncode({
        'sleep': sleep,
        'hypnogram': hypno,
        'periods': periods,
        'sleep_stress': sleepStress,
        'restlessness': restlessness,
      }));
      await LocalDb.upsertDerived(day, 'sessions', jsonEncode(sessions));
      written++;
    }

    // ── Pass 3: cross-day metrics, then finalize each daily bundle ──
    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final bundle = perDay[day];
      if (bundle == null) continue;

      final loadSeries = dailyStrainSeries.sublist(0, i + 1);
      final sriNights = nightSummaries.sublist((i - 13).clamp(0, i), i + 1);

      final load = core.analytics('calc_load', {'daily_strain': loadSeries});
      final fitnessModel = core.analytics('calc_fitness_model', {'daily_strain': loadSeries});
      final monotony = core.analytics('calc_monotony', {'daily_strain': loadSeries});
      final regularity = core.analytics('calc_sleep_regularity', {'nights': sriNights});
      final vo2max = core.analytics('calc_vo2max', {
        'max_hr': _num(bundle['zones'], 'max_hr_used'),
        'resting_hr': _num(bundle['resting_hr'], 'resting_hr') ?? baseline['resting_hr'],
      });
      // fitness trend wants DayHistory[] (resting_hr / hrr60 / daily_strain).
      final fitnessTrend = core.analytics('calc_fitness_trend', {'daily': _dayHistory(days, perDay, i)});

      final sleepBundle = jsonDecode(await LocalDb.getDerived(day, 'sleep') ?? '{}');
      final sleepDuration = (sleepBundle['sleep'] is Map) ? sleepBundle['sleep']['duration_min'] : null;
      final readiness = core.analytics('calc_readiness_index', {
        'recovery': _num(bundle['recovery'], 'score'),
        'sleep_duration_min': sleepDuration,
        'sleep_need_min': baseline['sleep_need_min'],
        'dip_pct': _num(bundle['nocturnal'], 'dip_pct'),
        'sleep_stress': (sleepBundle['sleep_stress'] is Map) ? sleepBundle['sleep_stress']['score'] : null,
      });

      bundle.addAll({
        'load': load,
        'fitness_model': fitnessModel,
        'monotony': monotony,
        'regularity': regularity,
        'vo2max': vo2max,
        'fitness_trend': fitnessTrend,
        'readiness': readiness,
        'f_fitness': _num(fitnessModel, 'fitness'),
      });
      await LocalDb.upsertDerived(day, 'daily', jsonEncode(bundle));
    }

    // Persist the freshly-seeded baseline so the next run (and the UI) can read it.
    await LocalDb.upsertDerived('_baseline', 'baselines', jsonEncode(baseline));

    await _pruneIfDerived();
    return written;
  }

  // ── baseline seeding (Pass 1): from the permanent derived history, NOT the window ──
  Future<Map<String, dynamic>> _seedBaseline(String firstDay) async {
    final dailyRows = await LocalDb.getDerivedRange('daily', '0000-00-00', '9999-99-99');
    final sleepRows = await LocalDb.getDerivedRange('sleep', '0000-00-00', '9999-99-99');
    final sleepByDate = {for (final r in sleepRows) r['date'] as String: jsonDecode(r['payload'] as String)};

    final history = <Map<String, dynamic>>[];
    for (final r in dailyRows) {
      final d = jsonDecode(r['payload'] as String);
      final s = sleepByDate[r['date']];
      history.add({
        'resting_hr': _num(d['resting_hr'], 'resting_hr'),
        'hrr60': _num(d['hr_recovery'], 'hrr60'),
        'daily_strain': _num(d['strain'], 'score'),
        'session_hr_max': _num(d['zones'], 'max_hr_used'),
        'sleep_duration_min': (s is Map && s['sleep'] is Map) ? s['sleep']['duration_min'] : null,
      });
    }
    // Last 30 derived days feed the baseline; defaults until enough history accrues.
    final tail = history.length > 30 ? history.sublist(history.length - 30) : history;
    final out = core.analytics('calc_baselines', {'history': tail, 'profile': profile});
    return {
      'resting_hr': _num(out, 'resting_hr') ?? 50,
      'max_hr': _num(out, 'max_hr') ?? _ageMaxHr(),
      'sleep_need_min': _num(out, 'sleep_need_min') ?? 480,
      if (_num(out, 'skin_temp') != null) 'skin_temp': _num(out, 'skin_temp'),
      if (_num(out, 'chronic_strain') != null) 'chronic_strain': _num(out, 'chronic_strain'),
    };
  }

  double _ageMaxHr() {
    final age = (profile?['age'] as num?)?.toDouble() ?? 30.0;
    return 208 - 0.7 * age; // Tanaka floor
  }

  // ── prune raw past retention (local regime: no upload, cutoff alone governs) ──
  Future<void> _pruneIfDerived() async {
    final derived = await LocalDb.derivedDates();
    if (derived.isEmpty) return;
    final cutoff = DateTime.now().subtract(const Duration(days: _retentionDays)).millisecondsSinceEpoch;
    await LocalDb.pruneRawBefore(cutoff, requireUploaded: false);
  }

  // ── helpers ──
  static num? _num(dynamic m, String k) {
    if (m is Map && m[k] is num) return m[k] as num;
    return null;
  }

  /// A trailing series of a daily scalar (from already-computed bundles) for the
  /// illness/anomaly history inputs.
  List<double> _history(Map<String, dynamic> perDay, String metric) {
    final out = <double>[];
    for (final b in perDay.values) {
      final v = _num(b['resting_hr'], 'resting_hr');
      if (v != null) out.add(v.toDouble());
    }
    return out;
  }

  /// DayHistory[] up to and including index [i] for fitness-trend slope.
  List<Map<String, dynamic>> _dayHistory(List<String> days, Map<String, dynamic> perDay, int i) {
    final out = <Map<String, dynamic>>[];
    for (var j = (i - 27).clamp(0, i); j <= i; j++) {
      final b = perDay[days[j]];
      if (b == null) continue;
      out.add({
        'resting_hr': _num(b['resting_hr'], 'resting_hr'),
        'hrr60': _num(b['hr_recovery'], 'hrr60'),
        'daily_strain': _num(b['strain'], 'score'),
      });
    }
    return out;
  }

  // Minutes that fall in the night window for [day] (prev 18:00 → this 12:00).
  List<Map<String, dynamic>> _nightMinutes(Map<String, _DayBin> bins, String day) {
    final start = _dayStartTs(day) - (24 - _sleepWindowStartHour) * 3600;
    final end = _dayStartTs(day) + _sleepWindowEndHour * 3600;
    final merged = <int, List<num>>{};
    for (final bin in bins.values) {
      bin.forEachMinuteInRange(start, end, (tsMin, hrs) => (merged[tsMin] ??= []).addAll(hrs));
    }
    return _DayBin.minutesFrom(merged);
  }

  List<Map<String, dynamic>> _nightRrByMin(Map<String, _DayBin> bins, String day) {
    final start = _dayStartTs(day) - (24 - _sleepWindowStartHour) * 3600;
    final end = _dayStartTs(day) + _sleepWindowEndHour * 3600;
    final merged = <int, List<num>>{};
    for (final bin in bins.values) {
      bin.forEachRrInRange(start, end, (tsMin, rr) => (merged[tsMin] ??= []).addAll(rr));
    }
    final out = merged.entries.map((e) => {'ts': e.key * 60, 'rr': e.value}).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return out;
  }

  int _dayStartTs(String day) {
    final p = day.split('-');
    return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2])).millisecondsSinceEpoch ~/ 1000;
  }

  String _utcDate(int tsEpochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(tsEpochSec * 1000, isUtc: true);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

/// One physiological day's decoded HR + RR, bucketed to the minute.
class _DayBin {
  final Map<int, List<num>> _hrByMin = {}; // ts//60 -> hr samples
  final Map<int, List<num>> _rrByMin = {}; // ts//60 -> rr intervals (ms)

  void add(int tsSec, double hr, List<num> rr) {
    final tsMin = tsSec ~/ 60;
    if (hr > 0) (_hrByMin[tsMin] ??= []).add(hr);
    if (rr.isNotEmpty) (_rrByMin[tsMin] ??= []).addAll(rr);
  }

  /// Minute rollups (Minute struct shape) for this day, ascending.
  List<Map<String, dynamic>> minutes() => minutesFrom(_hrByMin);

  /// Per-minute RR (MinuteRr struct shape), ascending.
  List<Map<String, dynamic>> rrByMin() {
    final out = _rrByMin.entries.map((e) => {'ts': e.key * 60, 'rr': e.value}).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return out;
  }

  /// Daytime-only RR (exclude the sleep window) for daytime-HRV.
  List<Map<String, dynamic>> daytimeRrByMin(dynamic onset, dynamic wake) {
    final o = (onset is num) ? onset.toInt() : null;
    final w = (wake is num) ? wake.toInt() : null;
    final out = <Map<String, dynamic>>[];
    for (final e in _rrByMin.entries) {
      final ts = e.key * 60;
      if (o != null && w != null && ts >= o && ts <= w) continue; // skip sleep
      out.add({'ts': ts, 'rr': e.value});
    }
    out.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return out;
  }

  void forEachMinuteInRange(int startSec, int endSec, void Function(int tsMin, List<num> hrs) f) {
    for (final e in _hrByMin.entries) {
      final ts = e.key * 60;
      if (ts >= startSec && ts < endSec) f(e.key, e.value);
    }
  }

  void forEachRrInRange(int startSec, int endSec, void Function(int tsMin, List<num> rr) f) {
    for (final e in _rrByMin.entries) {
      final ts = e.key * 60;
      if (ts >= startSec && ts < endSec) f(e.key, e.value);
    }
  }

  /// Build Minute-struct rows from a (ts//60 -> hr[]) map.
  static List<Map<String, dynamic>> minutesFrom(Map<int, List<num>> buckets) {
    final out = buckets.entries.map((e) {
      final hrs = e.value;
      final avg = hrs.isEmpty ? 0.0 : hrs.reduce((a, b) => a + b) / hrs.length;
      return {
        'ts': e.key * 60,
        'hr_avg': avg,
        'hr_min': hrs.isEmpty ? 0 : hrs.reduce((a, b) => a < b ? a : b),
        'hr_max': hrs.isEmpty ? 0 : hrs.reduce((a, b) => a > b ? a : b),
        'hr_n': hrs.length,
        'activity': 0,
        'steps': 0,
        'wrist_on': hrs.isNotEmpty,
      };
    }).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return out;
  }
}
