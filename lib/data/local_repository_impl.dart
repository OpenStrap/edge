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

import '../compute/derivation_engine.dart';
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
    final row = await LocalDb.dayResult(date);
    if (row == null) return null;
    return _decode(row['payload_json']);
  }

  /// The most-recent COMPLETE derived day to show on Today. With the calendar-day
  /// model "today" starts empty at midnight and only gains sleep/recovery once
  /// tonight's sleep is recorded — so a partial today must NOT blank the screen.
  /// We walk newest→oldest and PREFER the latest day that actually has SLEEP (the
  /// recovery/sleep headline), i.e. "show me last night's sleep + latest
  /// recovery". Fallbacks, in order: latest day with sleep → latest day with any
  /// scalars → newest decodable → null. This is what makes Today show yesterday's
  /// data when today hasn't filled yet (and the day-detail seams inherit it).
  Future<Map<String, dynamic>?> _latestBundle() async {
    final rows = await LocalDb.recentDayResults(14);
    Map<String, dynamic>? newest, withScalars;
    for (final row in rows) {
      final b = _decode(row['payload_json']);
      if (b == null) continue;
      newest ??= b;
      if (b['skipped'] == true) continue;
      final scalars = b['scalars'];
      if (scalars is Map && scalars.isNotEmpty) withScalars ??= b;
      if (_bundleHasSleep(b)) return b; // latest COMPLETE day wins
    }
    return withScalars ?? newest;
  }

  /// True when a bundle carries a real sleep (single-source accounting present).
  bool _bundleHasSleep(Map<String, dynamic> b) {
    final acc = ((b['sleep'] as Map?)?['accounting'] as Map?)?['value'];
    return acc is Map && acc['tst_sec'] != null;
  }

  /// The cross-day analytics rollup bundle (from the `crossday` baseline), or
  /// null when none has been computed yet.
  Future<Map<String, dynamic>?> _crossDay() async {
    final r = await LocalDb.baseline('crossday');
    return _decode(r?['payload_json']);
  }

  Future<Map<String, dynamic>?> _freshness(String key) async {
    final row = await LocalDb.computeFreshness(key);
    return _decode(row?['payload_json']);
  }

  Future<Map<String, dynamic>?> _wakeFeatures(String dayId) async {
    final row = await LocalDb.wakeDayFeatures(dayId, kAlgoVersion);
    return _decode(row?['payload_json']);
  }

  String _todayLocalLabel() => LocalDb.localDayLabelNow();

  /// True when [date] is today's (UTC) label — the only case where a missing
  /// derived row should fall back to the latest complete day. The screens pass
  /// `todayUtc()` for the Today tab; historical drill-downs pass an exact past
  /// date, which must NEVER fall back (else every empty day renders the latest
  /// day's data — the "stage minutes show the latest night" bug).
  bool _isTodayLabel(String date) =>
      date == DateTime.now().toUtc().toIso8601String().substring(0, 10);

  /// The bundle for a requested date: the exact day's row, or — only for the
  /// Today request — the latest complete day. A historical date with no row
  /// returns null (→ the caller's honest empty shape), not the latest.
  Future<Map<String, dynamic>?> _bundleForDate(String date) async =>
      await _bundle(date) ??
      (_isTodayLabel(date) ? await _latestBundle() : null);

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
  /// An optional [note] (e.g. a `need_baseline:…` string) is carried through so
  /// the UI can render "Need N more nights" for baseline-gated abstentions.
  Map<String, dynamic> _scalarMetric(
    num? v,
    String tier, {
    String? unit,
    String? note,
  }) => {
    'value': v ?? '—',
    'confidence': v == null ? 0 : 0.8,
    'tier': tier,
    'inputs_used': const [],
    'unit': ?unit,
    'note': ?note,
  };

  /// The `note` string of a metric envelope at [path] (e.g.
  /// 'clinical.readiness_composite'), or null. Used to surface the
  /// `need_baseline:have=H,need=N` convention to the UI.
  String? _needNote(Map<String, dynamic>? b, String path) {
    final env = _sub(b, path);
    final note = env?['note'];
    return note is String ? note : null;
  }

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
  Future<Map<String, dynamic>> setStepGoal(int goal) async => {
    ...?getProfileMap(),
    'step_goal': goal,
  };

  // ── today ─────────────────────────────────────────────────────────────────
  // Shape per lib/models/payloads.dart TodayData: {daily:{…}, sleep:{…},
  // nocturnal:{…}, resp:{…}, hrv:{…}, skin_temp:{…}, step_goal}.

  @override
  Future<Map<String, dynamic>> getToday() async {
    var todayFresh = await _freshness('today');
    if (todayFresh == null) {
      await LocalDb.refreshComputeFreshness();
      todayFresh = await _freshness('today');
    }
    final todayDay = todayFresh?['today_day']?.toString() ?? _todayLocalLabel();
    final todayBundle = await _bundle(todayDay);
    final overnightBundle = await _latestBundle();
    final overnightState =
        todayFresh?['overnight_state']?.toString() ?? 'missing';
    final activityState =
        todayFresh?['activity_state']?.toString() ?? 'missing';
    final showingPriorOvernight =
        todayFresh?['showing_prior_overnight'] == true;
    final showOvernight = overnightState == 'ready' || showingPriorOvernight;
    final sleepBundle = showOvernight ? overnightBundle : null;
    final activityBundle = activityState == 'ready' ? todayBundle : null;
    final wakeFeatures = activityState == 'ready'
        ? null
        : await _wakeFeatures(todayDay);
    final b = sleepBundle ?? activityBundle;
    if (b == null && wakeFeatures == null) {
      return {
        'daily': const {},
        'sleep': const {},
        'status': {
          'today_day': todayDay,
          'overnight_state': overnightState,
          'activity_state': activityState,
        },
        'step_goal': await _stepGoal(),
      };
    }
    final clinical = sleepBundle == null
        ? const <String, dynamic>{}
        : (_sub(sleepBundle, 'clinical') ?? const <String, dynamic>{});
    final resp = sleepBundle == null
        ? const <String, dynamic>{}
        : (_sub(sleepBundle, 'respiration') ?? const <String, dynamic>{});
    final cd = await _crossDay();

    final hrvTime = clinical['hrv_time'] is Map
        ? (clinical['hrv_time'] as Map).cast<String, dynamic>()
        : null;
    final rhrEnv = clinical['resting_hr'] is Map
        ? (clinical['resting_hr'] as Map).cast<String, dynamic>()
        : null;

    final rmssd = showOvernight ? _scalar(sleepBundle, 'rmssd') : null;
    // Readiness/recovery: when the composite abstains for lack of baseline, the
    // envelope carries a `need_baseline:have=H,need=N` note. Pass that note
    // through so the hero can render "Need N more nights" instead of a number.
    final readinessScalar = showOvernight
        ? _scalar(sleepBundle, 'readiness')
        : null;
    final readinessNote = readinessScalar == null && showOvernight
        ? _needNote(sleepBundle, 'clinical.readiness_composite')
        : null;
    final readinessMetric = _scalarMetric(
      readinessScalar,
      'HIGH',
      note: readinessNote,
    );
    final daily = <String, dynamic>{
      'readiness': readinessMetric,
      'recovery': readinessMetric,
      'resting_hr': _scalarMetric(
        showOvernight ? _scalar(sleepBundle, 'rhr')?.round() : null,
        'HIGH',
        unit: 'bpm',
      ),
      // Headline 0–21 strain (the strain gauge already expects a 0–21 scale).
      'strain': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['strain'] as num?)?.toDouble()
            : _scalar(activityBundle, 'strain'),
        'ESTIMATE',
      ),
      'wear_min': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['wear_min'] as num?)?.toDouble()
            : _wearMin(activityBundle),
        'HIGH',
        unit: 'min',
      ),
      // Active calories (Keytel HR→kcal over the wake span) + total daily energy
      // (TDEE: Mifflin BMR floor + active surplus).
      'calories': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['calories'] as num?)?.round()
            : _scalar(activityBundle, 'calories')?.round(),
        'ESTIMATE',
        unit: 'kcal',
      ),
      'calories_total': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['calories_total'] as num?)?.round()
            : _scalar(activityBundle, 'calories_total')?.round(),
        'ESTIMATE',
        unit: 'kcal',
      ),
      // STEPS — real 100 Hz count (streamed time) + 1 Hz walking estimate for the
      // rest; the derivation combines them and avoids double-counting.
      'steps': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['steps'] as num?)?.round()
            : _scalar(activityBundle, 'steps')?.round(),
        'ESTIMATE',
        unit: 'steps',
      ),
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
      'sleep': sleepBundle == null ? const {} : _sleepSummary(sleepBundle),
      if (sleepBundle != null && rhrEnv != null)
        'nocturnal': _nocturnal(
          sleepBundle,
          baselineRhr: await _seriesMean('rhr'),
        ),
      if (sleepBundle != null && resp['rsa'] is Map)
        'resp': _respObj(sleepBundle),
      'hrv': hrv,
      'skin_temp': sleepBundle != null
          ? await _skinTempBlock(sleepBundle)
          : const {'value': null},
      // Stress (Baevsky SI → 0–100 score block) + relative SpO₂ (desat index),
      // both emitted by the pipeline. The Today tiles + stress screen read these.
      if (sleepBundle != null && sleepBundle['stress'] is Map)
        'stress': sleepBundle['stress'],
      if (sleepBundle != null && sleepBundle['spo2'] is Map)
        'spo2': sleepBundle['spo2'],
      if (activityBundle != null && activityBundle['activity'] is Map)
        'activity': activityBundle['activity'],
      if (activityBundle == null && wakeFeatures?['activity'] is Map)
        'activity': (wakeFeatures!['activity'] as Map).cast<String, dynamic>(),
      // Cross-day rollup surfaced on Today (present only when computed).
      'illness': cd?['illness'],
      'anomaly': cd?['anomaly'],
      'load': cd?['load'],
      'readiness_breakdown': cd?['readiness_glassbox'],
      'regularity': cd?['regularity'],
      'status': {
        'today_day': todayDay,
        'activity_state': activityState,
        'activity_day': todayFresh?['activity_day'],
        'activity_computed_at': todayFresh?['activity_computed_at'],
        'overnight_state': overnightState,
        'overnight_day': todayFresh?['overnight_day'],
        'overnight_computed_at': todayFresh?['overnight_computed_at'],
        'showing_prior_overnight':
            todayFresh?['showing_prior_overnight'] == true,
      },
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
    return hr == null
        ? null
        : (hr / 60).round(); // 1 Hz valid samples → minutes
  }

  Map<String, dynamic> _sleepSummary(Map<String, dynamic> b) {
    // sleep.accounting is a Metric envelope {value:{tst_sec,…}, confidence,…} —
    // read the inner `.value`, not the envelope (the fields live one level down).
    final acct = _sub(b, 'sleep.accounting.value');
    final tst = (acct?['tst_sec'] as num?);
    final eff = (acct?['efficiency_pct'] as num?);
    if (tst == null) return const {};
    return {
      'duration_min': _scalarMetric(
        (tst / 60).round(),
        'ESTIMATE',
        unit: 'min',
      ),
      'efficiency': _scalarMetric(eff, 'ESTIMATE', unit: '%'),
    };
  }

  Map<String, dynamic> _nocturnal(Map<String, dynamic> b, {num? baselineRhr}) {
    final rhr = _scalar(b, 'rhr'); // sleeping-HR avg (low30 mean)
    final dip = _scalar(b, 'dip_pct');
    final nadir = _scalar(b, 'sleeping_hr_nadir'); // lowest sleeping HR
    final waking = _scalar(b, 'waking_hr'); // waking-span mean HR
    // vs baseline: tonight's sleeping HR minus the personal rhr baseline. Null
    // (→ "Need N nights") until a baseline exists; never fabricated.
    final vsBase = (rhr != null && baselineRhr != null)
        ? (rhr - baselineRhr)
        : null;
    // Elevated sleeping HR = ≥ baseline + 4 bpm (calcNocturnalHeart rule); false
    // until a baseline exists.
    final elevated =
        (rhr != null && baselineRhr != null) && rhr >= baselineRhr + 4;
    // KEY NAMES must match what the screens read: sleep_detail + detail_cards
    // use sleeping_hr_min / day_hr_avg / vs_baseline_bpm / nadir_ts / elevated.
    return {
      'sleeping_hr_avg': rhr?.round(),
      'sleeping_hr_min': nadir?.round(),
      'day_hr_avg': waking?.round(),
      'vs_baseline_bpm': vsBase == null
          ? null
          : double.parse(vsBase.toStringAsFixed(1)),
      'dip_pct': dip == null ? null : dip / 100.0,
      'nadir_ts': _scalar(b, 'sleeping_hr_nadir_ts')?.toInt(),
      'elevated': elevated,
    };
  }

  Map<String, dynamic>? _respObj(Map<String, dynamic> b) {
    final rr = _scalar(b, 'resp_rate');
    if (rr == null) return null;
    final env = _sub(b, 'respiration.rsa');
    // Round to 1 dp — the raw double (16.0121312…) was overflowing the card.
    return {
      'value': double.parse(rr.toStringAsFixed(1)),
      'confidence': (env?['confidence'] as num?) ?? 0.5,
    };
  }

  /// Relative skin-temp deviation block. Present once a value exists; otherwise
  /// a `need_baseline:have=H,need=3` note so the card shows "Need N more nights"
  /// instead of a bare "—" (skin-temp z needs ≥3 nights of ADC baseline).
  Future<Map<String, dynamic>> _skinTempBlock(Map<String, dynamic> b) async {
    final z = _scalar(b, 'skin_temp_z');
    if (z != null) return {'value': z};
    final have = (await LocalDb.metricSeries('skin_temp_adc')).length;
    return {'value': null, 'note': 'need_baseline:have=$have,need=3'};
  }

  // ── day drill-downs ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];
    final rmssd = _scalar(b, 'rmssd');
    final cd = await _crossDay();
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
        // HRV stability (CV %) + LF/HF — both now computed.
        'cv': _sub(b, 'clinical')?['cv'],
        'lf_hf': _sub(b, 'clinical.hrv_freq.value')?['lf_hf'],
      },
      // Poincaré irregular-beat screen (sd1/sd2/flag/confidence).
      'irregular': _sub(b, 'clinical')?['irregular'],
      // 24/7 irregular-rhythm SCREEN over whole-day RR (the headline screen).
      'irregular_24h': _sub(b, 'clinical')?['irregular_24h'],
      // Breathing-rate variability (within-user trend).
      'brv': _sub(b, 'clinical')?['brv'],
      // Mean heart-rate recovery across the day's detected/saved bouts (bpm/60s).
      'hrr': _scalar(b, 'hrr_bpm'),
      // Winsorized-EWMA personal baselines (rhr/hrv/resp/skin_temp) — robust
      // center + spread + z + cold-start status for each.
      'baselines': b['baselines'],
      // Waking ultradian HRV timeline (RMSSD over the day, outside sleep).
      'daytime_hrv': b['daytime_hrv'],
      'nocturnal': _nocturnal(b, baselineRhr: await _seriesMean('rhr')),
      'resp': _respObj(b),
      'spo2': _sub(b, 'respiration.odi'),
      // Illness watch (CUSUM/NightSignal) — carries `note` (need_baseline) while
      // baseline is short, so the card can say "Need N more nights".
      'illness': cd?['illness'],
      'skin_temp': await _skinTempBlock(b),
    };
  }

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async {
    final b = await _bundleForDate(date);
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
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    // Each is a Metric envelope — read the inner `.value` where the fields live.
    final acct = _sub(b, 'sleep.accounting.value');
    final win = _sub(b, 'sleep.window.value');
    final tst = (acct?['tst_sec'] as num?);
    // Provenance of this day's sleep window: auto / auto_fallback / manual /
    // confirmed / none — drives the Sleep screen's confirm prompt + edit affordance.
    final sleepSource = (b['sleep_source'] as String?) ?? 'auto';
    if (tst == null) {
      return {'has_sleep': false, 'sleep_source': sleepSource};
    }
    final spt = (win?['spt_sec'] as num?);
    final waso = (acct?['waso_sec'] as num?);
    final effPct = (acct?['efficiency_pct'] as num?);
    num? sec(String k) =>
        (win?[k] as num?) == null ? null : ((win![k] as num) / 1000).round();
    // 4-class stage minutes straight from the single-source segmentation seconds
    // (Light + Deep == NREM). Deep is the LOW-CONFIDENCE HR-depth overlay.
    int? min(String k) {
      final v = acct?[k] as num?;
      return v == null ? null : (v / 60).round();
    }

    final sleepConf = _sub(b, 'sleep.accounting')?['confidence'] as num?;
    return {
      // Shape matches sleep_detail_screen's contract exactly.
      'has_sleep': true,
      'sleep_source': sleepSource,
      'duration_min': (tst / 60).round(),
      'in_bed_min': spt == null ? null : (spt / 60).round(),
      'awake_min': waso == null ? null : (waso / 60).round(),
      'efficiency': effPct == null ? null : effPct / 100.0, // screen wants 0..1
      'onset_ts': sec('onset_ms'),
      'wake_ts': sec('offset_ms'),
      // 4-class stage minutes: Awake / Light / Deep / REM. Light+Deep is the
      // legacy combined "Core" (nrem_min) kept for any reader that wants it.
      'light_min': min('light_sec'),
      'deep_min': min('deep_sec'),
      'rem_min': min('rem_sec'),
      'nrem_min': min('nrem_sec'),
      'stages_beta': true,
      // The 4-class stager is a low-confidence wrist ESTIMATE; Deep especially is
      // an unvalidated overlay. The screen badges the whole stage block honestly.
      'stages_confidence': sleepConf,
      'hypnogram': _hypnoPoints(b), // [{t, stage}] points the screen merges
      'nocturnal': _nocturnal(b, baselineRhr: await _seriesMean('rhr')),
      'resp': _respObj(b),
      // Sleep need: default 8 h (480 min) until a personal sleep-need baseline
      // exists. Debt = need − actual TST (≥0). Never null so the gauge always reads.
      'need_min': 480,
      'debt_min': ((480 - (tst / 60)).clamp(0, 480)).round(),
      'regularity':
          null, // needs ≥several nights (honest null → "Need N nights")
      // Sleep periods (main + naps) for the periods screen.
      'periods': (b['sleep_periods'] as Map?)?['periods'] ?? const [],
      'total_asleep_min': (b['sleep_periods'] as Map?)?['total_asleep_min'],
      // Sleep cycles — Rosenblum 2024 "fractal cycles" (HRV-adapted): peak-to-
      // peak of the smoothed per-minute RMSSD series (REM peaks / NREM troughs).
      'cycles': _sub(b, 'sleep')?['cycles'] ?? const [],
      'cycle_count': (_sub(b, 'sleep')?['cycle_count'] as num?)?.toInt() ?? 0,
      'cycles_mean_min': _cyclesMeanMin(b),
      // The graph plots the continuous z-RMSSD wave [{t,z}] — NOT the cycle spans.
      'cycle_series': _sub(b, 'sleep')?['cycle_series'] ?? const [],
      // Parallel 4-class AASM read (Cole–Kripke/DoG stager): SOL / REM-latency /
      // disturbances + stage minutes + hypnogram. ESTIMATE; the headline stages
      // above stay the single source. {present:false} when none qualifies.
      'advanced': b['advanced_sleep'],
      // Low-confidence WRIST orientation (gravity-tilt) during sleep — a body-
      // position PROXY, NOT supine/side/prone body position.
      'wrist_orientation': b['wrist_orientation'],
    };
  }

  /// Mean completed-cycle length (min), or null when no cycles.
  num? _cyclesMeanMin(Map<String, dynamic> b) {
    final cyc = _sub(b, 'sleep')?['cycles'];
    if (cyc is! List || cyc.isEmpty) return null;
    var sum = 0.0;
    for (final c in cyc) {
      sum += ((c as Map)['len_min'] as num?)?.toDouble() ?? 0;
    }
    return (sum / cyc.length).round();
  }

  /// The bundle stores the hypnogram as segments {start,end,stage} (epoch sec);
  /// the detail screen wants per-point {t,stage} and re-merges them. Emit one
  /// point per segment boundary plus a closing point so the last stage has width.
  List<Map<String, dynamic>> _hypnoPoints(Map<String, dynamic> b) {
    final segs = (_sub(b, 'series')?['hypnogram'] as List?) ?? const [];
    final out = <Map<String, dynamic>>[];
    for (final s in segs) {
      if (s is Map && s['start'] != null && s['stage'] != null) {
        out.add({'t': s['start'], 'stage': s['stage']});
      }
    }
    final last = segs.isNotEmpty ? segs.last : null;
    if (last is Map && last['end'] != null && last['stage'] != null) {
      out.add({'t': last['end'], 'stage': last['stage']});
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final sleepWin = _sub(b, 'sleep.window.value');
    return {
      'resp': _respObj(b),
      'cvhr': _sub(b, 'respiration.cvhr_apnea'),
      'spo2': _sub(
        b,
        'respiration.odi',
      ), // relative desaturation screen; never an absolute %
      'sleep_window': {
        'start': (sleepWin?['onset_ms'] as num?) == null
            ? null
            : ((sleepWin!['onset_ms'] as num) / 1000).round(),
        'end': (sleepWin?['offset_ms'] as num?) == null
            ? null
            : ((sleepWin!['offset_ms'] as num) / 1000).round(),
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final cov = _sub(b, 'coverage');
    final total = (cov?['hr_samples'] as num?)?.toInt() ?? 0;
    // Wear block (on/off segments, first/last on, longest off) computed in the
    // engine; fall back to the coverage counts when absent.
    final w = b['wear'] is Map
        ? (b['wear'] as Map).cast<String, dynamic>()
        : null;
    return {
      // Wear = RECORD presence, not valid HR (HR drops out during daytime
      // motion). Fall back to the total record count, never hr_valid.
      'worn_min': (w?['worn_min'] as num?)?.toInt() ?? (total / 60).round(),
      'coverage_pct':
          (w?['coverage_pct'] as num?)?.toInt() ?? (total > 0 ? 100 : 0),
      'segments': w?['segments'] ?? const [],
      'first_on': w?['first_on'],
      'last_on': w?['last_on'],
      'longest_off_min': w?['longest_off_min'],
      'hourly': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async {
    // Stress = the pipeline's Baevsky Stress Index block (resting autonomic
    // tension; transparent RR-histogram metric → 0–100 score). Falls back to the
    // readiness inverse only if SI is absent. Nocturnal arousal isn't computed,
    // so `sleep_stress` is intentionally absent (the screen handles it).
    final b = await _bundleForDate(date);
    if (b == null) return const {};

    final stressBlk = b['stress'] is Map
        ? (b['stress'] as Map).cast<String, dynamic>()
        : null;
    num? score = (stressBlk?['score'] as num?);
    String? level = stressBlk?['level'] as String?;
    final si = (stressBlk?['si'] as num?);
    if (score == null) {
      // Fallback: inverse of readiness (only when SI couldn't compute).
      final readiness = _scalar(b, 'readiness');
      if (readiness != null) {
        score = (100 - readiness).round().clamp(0, 100);
        level = score < 34 ? 'low' : (score < 67 ? 'moderate' : 'high');
      }
    }

    final lfHf =
        (stressBlk?['lf_hf'] as num?) ??
        (_sub(b, 'clinical.hrv_freq.value')?['lf_hf'] as num?);
    final rmssd = (stressBlk?['rmssd'] as num?) ?? _scalar(b, 'rmssd');
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];

    // Drivers from the cross-day glass-box readiness, when present.
    final drivers = <Map<String, dynamic>>[];
    final cd = await _crossDay();
    final gb = cd?['readiness_glassbox'];
    final gbDrivers = gb is Map ? (gb['drivers'] as List?) : null;
    if (gbDrivers != null) {
      for (final d in gbDrivers) {
        if (d is Map) {
          final label = (d['label'] ?? '').toString();
          if (label.isEmpty) continue;
          drivers.add({
            'label': label,
            'detail': (d['detail'] ?? '').toString(),
          });
        }
      }
    }

    return {
      'stress': {
        'score': score,
        'si': si,
        'lf_hf': lfHf,
        'rmssd': rmssd,
        'level': level,
      },
      'hr': hrCurve,
      'drivers': drivers,
      // Nocturnal restlessness (movement fragmentation) + waking ultradian HRV,
      // both computed in the engine from accel / day-RR.
      'restlessness': b['restlessness'],
      'daytime_hrv': b['daytime_hrv'],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final zones = _sub(b, 'zones');
    final hrStats = _sub(b, 'hr_stats');
    final series = _sub(b, 'series');
    final curve = (series?['strain_curve'] as List?) ?? const [];
    final zoneTimeline = (series?['zone_timeline'] as List?) ?? const [];
    // EWMA-ACWR training load lives in the cross-day rollup (acute/chronic over a
    // history window); the strain detail's "Training load (ACWR)" row reads it.
    final cd = await _crossDay();
    return {
      // Headline 0–21 strain (the detail screen clamps to 0..21). Raw Banister
      // TRIMP is kept as the secondary "training load" figure.
      'strain': _scalar(b, 'strain'),
      'training_load': _scalar(b, 'trimp'),
      // Secondary 0–100 Edwards "effort" strain (zone-weighted, per-second wake HR).
      'effort': _scalar(b, 'strain_effort'),
      'load': cd?['load'], // {acwr, acute, chronic, band} when ≥ history exists
      // HR-zone minutes (Z1–Z5 by %HRmax) — the strain detail's zone bars.
      'zones': {
        'z1': (zones?['z1'] as num?)?.toInt() ?? 0,
        'z2': (zones?['z2'] as num?)?.toInt() ?? 0,
        'z3': (zones?['z3'] as num?)?.toInt() ?? 0,
        'z4': (zones?['z4'] as num?)?.toInt() ?? 0,
        'z5': (zones?['z5'] as num?)?.toInt() ?? 0,
      },
      'curve': [
        for (final p in curve.whereType<Map>()) {'t': p['t'], 'v': p['v']},
      ],
      'zone_timeline': [
        for (final p in zoneTimeline.whereType<Map>())
          {'t': p['t'], 'z': p['z']},
      ],
      'calories': _scalar(b, 'calories')?.round(),
      // Total daily energy (TDEE) + 24/7 step ESTIMATE (live pedometer tunes it).
      'calories_total': _scalar(b, 'calories_total')?.round(),
      'steps': _scalar(b, 'steps')?.round(),
      'hr': {
        'max': (hrStats?['max'] as num?)?.toInt(),
        'avg': (hrStats?['avg'] as num?)?.toInt(),
        'min': (hrStats?['min'] as num?)?.toInt(),
      },
      'max_hr_used': b['max_hr_used'] is num
          ? b['max_hr_used'] as num
          : _scalar(b, 'max_hr_used'),
      'flags': const {},
    };
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];

    // Peak / lowest HR + their instants, from the day HR curve (seam-side; the
    // curve is what's stored, good enough for a daily overview + gives @time).
    num? peakV, lowV;
    int? peakT, lowT;
    for (final e in hrCurve) {
      if (e is! Map) continue;
      final v = e['v'] as num?;
      final t = (e['t'] as num?)?.toInt();
      if (v == null || t == null || v <= 0) continue;
      if (peakV == null || v > peakV) {
        peakV = v;
        peakT = t;
      }
      if (lowV == null || v < lowV) {
        lowV = v;
        lowT = t;
      }
    }

    // Day window from the BUNDLE's date (not the requested date) so hr/sleep/
    // segments stay consistent when a partial "today" falls back to the latest
    // complete day.
    final bundleDate = (b['date'] as String?) ?? date;
    final dayStart = _localMidnightSec(bundleDate);
    final dayEnd = dayStart + 86400;

    // Sleep span (onset/wake) for the context band + sleep symbol.
    final sw = _sub(b, 'sleep.window.value');
    final sleep = <Map<String, dynamic>>[];
    final onMs = sw?['onset_ms'] as num?;
    final offMs = sw?['offset_ms'] as num?;
    if (onMs != null && offMs != null) {
      sleep.add({
        'onset_ts': (onMs / 1000).round(),
        'wake_ts': (offMs / 1000).round(),
      });
    }

    // Workouts + device events for that calendar day.
    final sess = await LocalDb.sessionsInRange(dayStart, dayEnd);
    final allEvents = await LocalDb.unuploadedEvents(limit: 2000);
    final events = <Map<String, dynamic>>[
      for (final e in allEvents)
        if (((e['ts'] as num?)?.toInt() ?? -1) >= dayStart &&
            ((e['ts'] as num?)?.toInt() ?? -1) < dayEnd)
          {
            'event_id': (e['event_id'] as num?)?.toInt(),
            'ts': (e['ts'] as num?)?.toInt(),
          },
    ];

    // Daytime naps (principled detectNaps) as their own bands on the timeline.
    final napsVal = _sub(b, 'naps')?['value'];
    final naps = <Map<String, dynamic>>[
      if (napsVal is List)
        for (final nMap in napsVal)
          if (nMap is Map && nMap['start'] != null && nMap['end'] != null)
            {
              'start': (nMap['start'] as num).toInt(),
              'end': (nMap['end'] as num).toInt(),
              'duration_min': (nMap['duration_min'] as num?)?.toInt(),
            },
    ];

    // HRV line. Prefer the ALL-DAY series (`series.hrv_day`, already epoch-
    // stamped, 24/7). Fall back to the sleep-only `hrv_timeline` whose `t` is
    // SECONDS-FROM-WINDOW-START (re-based nnTimes) — rebase that to epoch via the
    // sleep onset, or it lands on a wildly different axis and won't render.
    final series = _sub(b, 'series');
    final dayHrv = (series?['hrv_day'] as List?) ?? const [];
    List<Map<String, dynamic>> hrvLine;
    if (dayHrv.isNotEmpty) {
      hrvLine = [
        for (final e in dayHrv)
          if (e is Map && e['t'] is num && e['v'] is num)
            {'t': (e['t'] as num).toInt(), 'v': e['v']},
      ];
    } else {
      final rawHrv = (series?['hrv_timeline'] as List?) ?? const [];
      final hrvOnsetSec = onMs == null ? null : (onMs / 1000).round();
      hrvLine = [
        if (hrvOnsetSec != null)
          for (final e in rawHrv)
            if (e is Map && e['t'] is num && e['v'] is num)
              {'t': hrvOnsetSec + (e['t'] as num).toInt(), 'v': e['v']},
      ];
    }
    // Plausibility clip: RMSSD physiologically sits ~5–220 ms; values above are
    // ectopic/missed-beat artifacts (the 400+ ms spikes). Drop them so one bad
    // window can't flatten the whole line. Covers old data + the sleep fallback.
    hrvLine = [
      for (final e in hrvLine)
        if ((e['v'] as num) >= 5 && (e['v'] as num) <= 220) e,
    ];

    // Day HR average (from the curve) for the overview stats.
    num avgHr = 0;
    var nHr = 0;
    for (final e in hrCurve) {
      if (e is Map && e['v'] is num && (e['v'] as num) > 0) {
        avgHr += e['v'] as num;
        nHr++;
      }
    }

    // Respiratory rate (br/min) + relative skin-temp trend — all-day lines.
    final respLine = (series?['resp_day'] as List?) ?? const [];
    final tempLine = (series?['skin_temp_day'] as List?) ?? const [];

    return {
      'hr': hrCurve,
      'hrv': hrvLine,
      'resp': respLine,
      'skin_temp': tempLine,
      'activity': b['activity_curve'] ?? const [],
      'day_start': dayStart,
      'highs': {
        if (peakV != null) 'peak_hr': {'v': peakV, 't': peakT},
        if (lowV != null) 'low_hr': {'v': lowV, 't': lowT},
        if (nHr > 0) 'avg_hr': {'v': (avgHr / nHr).round()},
      },
      'sleep': sleep,
      'naps': naps,
      'sessions': [for (final r in sess) _workoutOf(r)],
      'events': events,
    };
  }

  /// Local midnight (epoch sec) of a 'YYYY-MM-DD' date string.
  int _localMidnightSec(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return 0;
    final y = int.tryParse(p[0]),
        m = int.tryParse(p[1]),
        d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return 0;
    return DateTime(y, m, d).millisecondsSinceEpoch ~/ 1000;
  }

  // ── lists / summaries ─────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> getSleep({int? from, int? to}) async {
    final rows = await LocalDb.recentDayResults(60);
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final b = _decode(r['payload_json']);
      if (b == null) continue;
      final acct = _sub(b, 'sleep.accounting.value');
      final tst = (acct?['tst_sec'] as num?);
      if (tst == null) continue;
      out.add({
        'date': r['date'],
        'duration_min': (tst / 60).round(),
        'efficiency': acct?['efficiency_pct'],
        'flags': {
          'duration': {'c': 0.6, 'tier': 'ESTIMATE', 'beta': true},
        },
      });
    }
    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> getStrain({int? from, int? to}) async {
    final rows = await LocalDb.recentDayResults(60);
    return [
      for (final r in rows)
        {
          'date': r['date'],
          'strain': (() {
            final b = _decode(r['payload_json']);
            // Headline 0–21 strain (fall back to nothing if older bundle).
            return _scalar(b, 'strain');
          })(),
          'flags': const {},
        },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) async {
    // Manual/live sessions (the sessions table) MERGED with auto-detected
    // workouts from the per-day bundle. Manual/saved WINS on overlap: a detected
    // bout overlapping a manual session is dropped here (and is already dropped
    // upstream in the engine via savedSpans — this is a belt-and-suspenders pass
    // for sessions saved after the day was derived).
    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final fromSec =
        from ??
        now.subtract(const Duration(days: 31)).millisecondsSinceEpoch ~/ 1000;
    final toSec = to ?? nowSec;

    final manualRows = await LocalDb.sessionsInRange(fromSec, toSec);
    final manual = [for (final r in manualRows) _workoutOf(r)];

    // Saved spans (manual) for overlap-dedup of detected bouts.
    final savedSpans = <List<int>>[];
    for (final w in manual) {
      final st = (w['start_ts'] as num?)?.toInt();
      final en = (w['end_ts'] as num?)?.toInt() ?? st;
      if (st != null && en != null) savedSpans.add([st, en]);
    }
    bool overlapsSaved(int s, int e) =>
        savedSpans.any((sp) => s <= sp[1] && sp[0] <= e);

    // Detected workouts from each recent derived day's bundle.
    final detected = <Map<String, dynamic>>[];
    final dayRows = await LocalDb.recentDayResults(60);
    for (final r in dayRows) {
      final b = _decode(r['payload_json']);
      final list = b?['detected_workouts'];
      if (list is! List) continue;
      for (final dw in list) {
        if (dw is! Map) continue;
        final st = (dw['start'] as num?)?.toInt();
        final en = (dw['end'] as num?)?.toInt();
        if (st == null || en == null) continue;
        if (st < fromSec || st > toSec) continue;
        if (overlapsSaved(st, en)) continue; // manual wins
        detected.add(_detectedWorkoutOf(dw, r['date'] as String?));
      }
    }

    final all = [...manual, ...detected];
    all.sort(
      (a, b) => ((b['start_ts'] as num?) ?? 0).compareTo(
        (a['start_ts'] as num?) ?? 0,
      ),
    );
    return all;
  }

  /// Shape a bundle `detected_workouts` entry (ExerciseSession.toJson) into the
  /// workout map the screens parse. start/end are epoch SECONDS.
  Map<String, dynamic> _detectedWorkoutOf(Map dw, String? date) {
    final start = (dw['start'] as num?)?.toInt();
    final end = (dw['end'] as num?)?.toInt();
    final durS =
        (dw['duration_s'] as num?)?.toDouble() ??
        ((start != null && end != null) ? (end - start).toDouble() : null);
    final sport = (dw['sport'] as String?) ?? 'detected';
    return {
      'id': 'auto_${date ?? ''}_$start',
      'start_ts': start,
      'end_ts': end,
      'status': 'detected',
      'source': 'auto',
      'type': sport,
      'title': sport,
      'strain': (dw['strain'] as num?)?.toDouble(),
      'calories': (dw['calories_kcal'] as num?)?.round(),
      'duration_min': durS == null ? null : (durS / 60).round(),
      'avg_hr': (dw['avg_hr'] as num?)?.round(),
      'peak_hr': (dw['peak_hr'] as num?)?.toInt(),
      'zone_min': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> getHistory({String range = '30d'}) async {
    final rows = await LocalDb.recentDayResults(90);
    return {
      'days': [
        for (final r in rows)
          {
            'date': r['date'],
            'readiness': r['readiness'],
            'resting_hr': r['rhr'],
            'rmssd': r['rmssd'],
          },
      ],
    };
  }

  // ── trends + records + charts ──────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getTrend(
    String metric, {
    String scale = 'week',
    String? anchor,
  }) async {
    final key = _trendKey(metric);
    final rows = await LocalDb.metricSeries(key); // ascending by date
    final byDate = <String, double>{};
    for (final r in rows) {
      final v = (r['value'] as num?)?.toDouble();
      if (v != null) byDate[r['date'] as String] = v;
    }
    final (unit, label) = _unitLabel(metric);
    final base = {
      'baseline': {'resting_hr': await _seriesMean('rhr')},
    };
    if (byDate.isEmpty) {
      return {'buckets': const [], 'unit': unit, 'label': label, ...base};
    }

    DateTime parseD(String s) {
      final p = s.split('-');
      return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    }

    int secOf(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    double? meanOf(Iterable<double> xs) {
      final l = xs.toList();
      return l.isEmpty ? null : l.reduce((a, b) => a + b) / l.length;
    }

    final anchorDay = anchor != null
        ? parseD(anchor)
        : parseD(rows.last['date'] as String);

    // Mean of the metric over [start, endInclusive] calendar days.
    double? windowMean(DateTime start, DateTime endIncl) {
      final vals = <double>[];
      var d = start;
      while (!d.isAfter(endIncl)) {
        final v = byDate[ymd(d)];
        if (v != null) vals.add(v);
        d = d.add(const Duration(days: 1));
      }
      return meanOf(vals);
    }

    final buckets = <Map<String, dynamic>>[];
    if (scale == 'week') {
      // 7 daily buckets ending at the anchor day.
      for (var i = 6; i >= 0; i--) {
        final day = anchorDay.subtract(Duration(days: i));
        final v = byDate[ymd(day)];
        buckets.add({
          'value': v ?? 0.0,
          'has': v != null,
          't_start': secOf(day),
          't_end': secOf(day.add(const Duration(days: 1))),
        });
      }
    } else if (scale == 'month') {
      // 4 weekly buckets (mean of each week) ending at the anchor week.
      for (var w = 3; w >= 0; w--) {
        final end = anchorDay.subtract(Duration(days: w * 7));
        final start = end.subtract(const Duration(days: 6));
        final m = windowMean(start, end);
        buckets.add({
          'value': m ?? 0.0,
          'has': m != null,
          't_start': secOf(start),
          't_end': secOf(end.add(const Duration(days: 1))),
        });
      }
    } else {
      // quarter → 3 monthly buckets (mean of each calendar month).
      for (var mo = 2; mo >= 0; mo--) {
        final monthStart = DateTime.utc(
          anchorDay.year,
          anchorDay.month - mo,
          1,
        );
        final nextMonth = DateTime.utc(
          monthStart.year,
          monthStart.month + 1,
          1,
        );
        final m = windowMean(
          monthStart,
          nextMonth.subtract(const Duration(days: 1)),
        );
        buckets.add({
          'value': m ?? 0.0,
          'has': m != null,
          't_start': secOf(monthStart),
          't_end': secOf(nextMonth),
        });
      }
    }

    // Summary: avg over present buckets + delta vs the immediately-prior window.
    final present = [
      for (final b in buckets)
        if (b['has'] == true) b['value'] as double,
    ];
    final avg = meanOf(present);
    final spanDays = scale == 'week' ? 7 : (scale == 'month' ? 28 : 90);
    final prevEnd = anchorDay.subtract(Duration(days: spanDays));
    final prevAvg = windowMean(
      prevEnd.subtract(Duration(days: spanDays - 1)),
      prevEnd,
    );
    final delta = (avg != null && prevAvg != null) ? avg - prevAvg : null;

    return {
      'buckets': buckets,
      'unit': unit,
      'label': label,
      'summary': {
        'avg': avg == null ? null : double.parse(avg.toStringAsFixed(1)),
        'delta_vs_prev': delta == null
            ? null
            : double.parse(delta.toStringAsFixed(1)),
        'total': present.length,
      },
      ...base,
    };
  }

  /// Display (unit, label) per trend metric.
  (String, String) _unitLabel(String metric) {
    switch (metric) {
      case 'resting_hr':
        return ('bpm', 'resting HR');
      case 'hrv':
        return ('ms', 'HRV');
      case 'recovery':
        return ('%', 'recovery');
      case 'strain':
        return ('', 'strain');
      case 'stress':
        return ('', 'stress');
      case 'spo2':
        return ('dips/h', 'oxygen dips');
      case 'sleep':
        return ('h', 'sleep');
      case 'active_min':
        return ('min', 'active');
      case 'calories':
        return ('kcal', 'calories');
      case 'calories_total':
        return ('kcal', 'total calories');
      case 'steps':
        return ('steps', 'steps');
      case 'resp_rate':
        return ('rpm', 'respiratory rate');
      case 'light':
        return ('min', 'light sleep');
      case 'deep':
        return ('min', 'deep sleep');
      case 'rem':
        return ('min', 'REM sleep');
      case 'tst':
        return ('min', 'time asleep');
      case 'lf_hf':
        return ('', 'LF / HF');
      case 'hrv_cv':
        return ('%', 'HRV stability');
      case 'dip':
        return ('%', 'nocturnal HR dip');
      case 'efficiency':
        return ('%', 'sleep efficiency');
      case 'wear':
        return ('', 'wear'); // minutes; the screen formats as Hh Mm
      case 'skin_temp':
        return ('', 'skin temp'); // relative z vs baseline
      case 'hrr':
        return ('bpm', 'HR recovery'); // 60-s post-exercise drop; higher = fitter
      case 'brv':
        return ('', 'breathing variability'); // CV of per-window respiratory rate
      default:
        return ('', metric);
    }
  }

  String _trendKey(String metric) {
    switch (metric) {
      case 'hrv':
        return 'rmssd';
      case 'recovery':
        return 'readiness';
      case 'resting_hr': // series key is `rhr`
        return 'rhr';
      case 'skin_temp': // series key is the relative z-score
        return 'skin_temp_z';
      case 'wear': // worn-minutes trend
        return 'worn_min';
      case 'efficiency': // sleep-efficiency % trend
        return 'efficiency';
      case 'steps': // 24/7 step ESTIMATE series (ambulatory-min × cadence)
        return 'steps';
      case 'light':
        return 'light_min';
      case 'deep':
        return 'deep_min';
      case 'rem':
        return 'rem_min';
      case 'tst':
      case 'sleep': // the Sleep screen's trend metric → time-asleep series
        return 'tst_min';
      case 'dip':
        return 'dip_pct';
      case 'hrr':
        return 'hrr_bpm';
      case 'brv':
        return 'brv_cv';
      // lf_hf, hrv_cv map to themselves (series keys match).
      default:
        return metric;
    }
  }

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
  }) async {
    if (metric == 'hr') {
      final b = await _latestBundle();
      return {'points': (_sub(b, 'series')?['hr_curve'] as List?) ?? const []};
    }
    final rows = await LocalDb.metricSeries(_trendKey(metric));
    return {
      'points': [
        for (final r in rows)
          {'t': _dateToEpoch(r['date'] as String), 'v': r['value']},
      ],
    };
  }

  int _dateToEpoch(String date) =>
      (DateTime.tryParse('$date 12:00:00')?.millisecondsSinceEpoch ?? 0) ~/
      1000;

  @override
  Future<Map<String, dynamic>> getRecords() async {
    final rows = await LocalDb.recentDayResults(3650);
    final days = rows.length;
    int nights = 0;
    for (final r in rows) {
      final b = _decode(r['payload_json']);
      if (_sub(b, 'sleep.accounting.value')?['tst_sec'] != null) nights++;
    }
    return {
      'days_tracked': days,
      'nights_tracked': nights,
      'workouts_tracked': 0,
      'records': const {},
      'streaks': const {},
    };
  }

  // ── workouts (manual / live / auto) — local sessions store ──────────────────

  /// Shape one sessions-table row into the workout map the screens parse.
  /// start_ts/end_ts are epoch SECONDS; zone_min decodes the JSON list.
  Map<String, dynamic> _workoutOf(Map<String, dynamic> r) {
    final zoneMin = _decodeList(r['zone_min_json']);
    final type = (r['type'] as String?) ?? 'other';
    return {
      'id': r['id'],
      'start_ts': (r['start_ts'] as num?)?.toInt(),
      'end_ts': (r['end_ts'] as num?)?.toInt(),
      'status': r['status'],
      'type': type,
      'title': type,
      'strain': (r['strain'] as num?)?.toDouble(),
      'calories': (r['calories'] as num?)?.round(),
      'duration_min': (r['duration_min'] as num?)?.toInt(),
      'steps': (r['steps'] as num?)?.toInt(),
      'max_hr': (r['max_hr'] as num?)?.toInt(),
      // Heart-rate recovery (bpm drop in 60 s) backfilled during derivation.
      'hrr60': (r['hrr_bpm'] as num?)?.round(),
      'zone_min': zoneMin,
    };
  }

  List<dynamic> _decodeList(Object? json) {
    if (json is! String || json.isEmpty) return const [];
    try {
      final d = jsonDecode(json);
      return d is List ? d : const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final fromTs = _rangeFromSec(range, now);
    final rows = await LocalDb.sessionsInRange(fromTs, nowSec);
    final workouts = [for (final r in rows) _workoutOf(r)];

    // Summary excludes live sessions (no final stats yet).
    final done = workouts.where((w) => w['status'] != 'live');
    var count = 0, totalMin = 0, totalCal = 0;
    final zoneSum = <num>[];
    for (final w in done) {
      count++;
      totalMin += (w['duration_min'] as int?) ?? 0;
      totalCal += (w['calories'] as int?) ?? 0;
      final zm = (w['zone_min'] as List?) ?? const [];
      for (var i = 0; i < zm.length; i++) {
        final v = (zm[i] as num?) ?? 0;
        if (i < zoneSum.length) {
          zoneSum[i] += v;
        } else {
          zoneSum.add(v);
        }
      }
    }
    return {
      'workouts': workouts,
      'summary': {
        'count': count,
        'total_min': totalMin,
        'total_calories': totalCal,
        'zone_min': zoneSum,
      },
    };
  }

  /// Epoch SECONDS lower bound for a range label. 'all' → 0.
  int _rangeFromSec(String range, DateTime now) {
    switch (range) {
      case 'all':
        return 0;
      case 'week':
        return now.subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/
            1000;
      case 'quarter':
      case '3m':
        return now.subtract(const Duration(days: 90)).millisecondsSinceEpoch ~/
            1000;
      case 'month':
      default:
        return now.subtract(const Duration(days: 31)).millisecondsSinceEpoch ~/
            1000;
    }
  }

  @override
  Future<Map<String, dynamic>> getWorkout(String id) async {
    final r = await LocalDb.session(id);
    return r == null ? const {} : _workoutOf(r);
  }

  @override
  Future<void> deleteWorkout(String id) async => LocalDb.deleteSession(id);

  @override
  Future<Map<String, dynamic>> startWorkout(
    String type, {
    String? title,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final id = 'w$nowMs';
    await LocalDb.putSession({
      'id': id,
      'start_ts': nowMs ~/ 1000,
      'end_ts': null,
      'type': type,
      'status': 'live',
      'source': 'manual',
      'created_at': nowMs,
    });
    return {'workout_id': id, 'type': type};
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    // Mark done + stamp end_ts; final stats (calories/strain/etc) are written by
    // app_state.stopWorkout from the LiveWorkoutState (it has the live tallies).
    final r = await LocalDb.session(workoutId);
    if (r != null) {
      await LocalDb.putSession({
        ...r,
        'status': 'done',
        'end_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    }
    return {'workout_id': workoutId};
  }

  @override
  Future<Map<String, dynamic>> setWorkoutType(String id, String type) async {
    await LocalDb.setSessionType(id, type);
    return {'workout_id': id, 'type': type};
  }

  // ── journal — local store + tag-vs-metric correlation insights ──────────────

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async {
    final since = _rangeSinceLabel(range);
    final rows = await LocalDb.journalRows(sinceDaysEpoch: since);
    return [
      for (final r in rows)
        {
          'date': r['date'],
          'tags': _decodeStrList(r['tags_json']),
          'note': (r['note'] as String?) ?? '',
        },
    ];
  }

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {
    await LocalDb.putJournal(date, jsonEncode(tags), note);
  }

  /// For each distinct tag in the window, compare mean readiness on tagged days
  /// vs the window mean and emit a metric-delta card (only when n_with >= 2).
  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async {
    final since = _rangeSinceLabel(range);
    final journal = await LocalDb.journalRows(sinceDaysEpoch: since);
    if (journal.isEmpty) return const {'insights': []};

    // Outcome series we correlate behaviours against. Each is read from
    // metric_series and indexed by date. Direction (does HIGHER help?) is encoded
    // per outcome so the UI can phrase "+/− your recovery".
    const outcomeDefs = <Map<String, dynamic>>[
      {
        'key': 'readiness',
        'label': 'Recovery',
        'higherBetter': true,
        'unit': '',
      },
      {'key': 'rmssd', 'label': 'HRV', 'higherBetter': true, 'unit': 'ms'},
      {
        'key': 'rhr',
        'label': 'Resting HR',
        'higherBetter': false,
        'unit': 'bpm',
      },
      {
        'key': 'efficiency',
        'label': 'Sleep efficiency',
        'higherBetter': true,
        'unit': '%',
      },
    ];

    // date → value maps for each outcome.
    final maps = <String, Map<String, double>>{};
    for (final od in outcomeDefs) {
      final key = od['key'] as String;
      final m = <String, double>{};
      for (final r in await LocalDb.metricSeries(key)) {
        final v = (r['value'] as num?)?.toDouble();
        if (v != null) m[r['date'] as String] = v;
      }
      maps[key] = m;
    }

    // The union of journal dates (the days we can attribute behaviours on),
    // sorted oldest-first — the shared index for journal + outcome arrays.
    final dates = <String>{
      for (final j in journal)
        if (j['date'] is String) j['date'] as String,
    }.toList()..sort();
    if (dates.length < 4) return const {'insights': []};

    final tagsByDate = <String, Set<String>>{};
    for (final j in journal) {
      final d = j['date'] as String?;
      if (d == null) continue;
      (tagsByDate[d] ??= <String>{}).addAll(_decodeStrList(j['tags_json']));
    }
    final jdays = <ana.JournalDay>[
      for (final d in dates) ana.JournalDay(d, tagsByDate[d] ?? const {}),
    ];
    final outcomes = <String, List<double?>>{
      for (final od in outcomeDefs)
        (od['key'] as String): [for (final d in dates) maps[od['key']]![d]],
    };

    final corr = ana.journalCorrelations(
      journal: jdays,
      dates: dates,
      outcomes: outcomes,
    );

    // Flatten to UI rows: one row per (tag, outcome) that is meaningful, phrased
    // by the outcome's direction. Sorted by absolute effect, strongest first.
    final unitOf = {
      for (final od in outcomeDefs) od['key'] as String: od['unit'],
    };
    final betterOf = {
      for (final od in outcomeDefs)
        od['key'] as String: od['higherBetter'] as bool,
    };
    final labelOf = {
      for (final od in outcomeDefs) od['key'] as String: od['label'] as String,
    };
    final insights = <Map<String, dynamic>>[];
    for (final tc in corr) {
      for (final e in tc.effects) {
        if (e.insufficient || !e.meaningful || e.pctChange == null) continue;
        final higherOnTag = e.higherSide == 'tagged';
        final betterWhenHigher = betterOf[e.outcome] ?? true;
        // "helped" = the change moved the outcome in the good direction.
        final helped = higherOnTag == betterWhenHigher;
        insights.add({
          'tag': tc.tag,
          'outcome': e.outcome,
          'outcome_label': labelOf[e.outcome],
          'delta': e.delta,
          'delta_pct': e.pctChange,
          'unit': unitOf[e.outcome],
          'helped': helped,
          'n_with': e.nTagged,
          'n_without': e.nUntagged,
        });
      }
    }
    insights.sort(
      (a, b) => (b['delta_pct'] as double).abs().compareTo(
        (a['delta_pct'] as double).abs(),
      ),
    );
    return {'insights': insights};
  }

  List<String> _decodeStrList(Object? json) => [
    for (final e in _decodeList(json)) e.toString(),
  ];

  /// A YYYY-MM-DD lower-bound label for a '30d'/'90d'/'7d'-style range, or null
  /// (no bound) for 'all'.
  String? _rangeSinceLabel(String range) {
    if (range == 'all') return null;
    final m = RegExp(r'(\d+)').firstMatch(range);
    final days = m == null ? 30 : int.parse(m.group(1)!);
    final d = DateTime.now().subtract(Duration(days: days));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  // ── menstrual cycle — local log + honest phase/prediction ───────────────────

  @override
  Future<Map<String, dynamic>> getCycle() async {
    final enabled = getProfileMap()?['track_cycle'] == true;
    if (!enabled) {
      return {
        'enabled': false,
        'note': 'Enable cycle tracking in your profile.',
      };
    }
    final rows = await LocalDb.cycleLogs(); // oldest first
    final logs = [
      for (final r in rows) {'date': r['date'], 'kind': r['kind']},
    ];
    final startDates = [
      for (final r in rows)
        if (r['kind'] == 'start') r['date'] as String,
    ];

    // Mean cycle length = mean of gaps (days) between consecutive starts.
    double? meanLength;
    if (startDates.length >= 2) {
      final gaps = <int>[];
      for (var i = 1; i < startDates.length; i++) {
        final a = DateTime.tryParse(startDates[i - 1]);
        final b = DateTime.tryParse(startDates[i]);
        if (a != null && b != null) gaps.add(b.difference(a).inDays);
      }
      if (gaps.isNotEmpty) {
        meanLength = gaps.reduce((a, b) => a + b) / gaps.length;
      }
    }

    final lastStartStr = startDates.isEmpty ? null : startDates.last;
    final lastStart = lastStartStr == null
        ? null
        : DateTime.tryParse(lastStartStr);
    final today = DateTime.now();
    int? cycleDay;
    if (lastStart != null) {
      final d0 = DateTime(lastStart.year, lastStart.month, lastStart.day);
      final t0 = DateTime(today.year, today.month, today.day);
      cycleDay = t0.difference(d0).inDays + 1; // day 1 = start day
    }

    String? predictedNext;
    num? daysUntilNext;
    if (lastStart != null && meanLength != null) {
      final next = lastStart.add(Duration(days: meanLength.round()));
      predictedNext = _ymd(next);
      final t0 = DateTime(today.year, today.month, today.day);
      daysUntilNext = DateTime(
        next.year,
        next.month,
        next.day,
      ).difference(t0).inDays;
    }

    // Phase + fertile window — only when meanLength is known (else honest unknown).
    String phase = 'unknown';
    String? fertileStart, fertileEnd;
    if (meanLength != null && cycleDay != null && lastStart != null) {
      final ovDay = (meanLength - 14).round().clamp(10, meanLength.round());
      if (cycleDay <= 5) {
        phase = 'menstrual';
      } else if (cycleDay < ovDay) {
        phase = 'follicular';
      } else if (cycleDay <= ovDay + 1) {
        phase = 'ovulation';
      } else {
        phase = 'luteal';
      }
      final ovDate = lastStart.add(Duration(days: ovDay - 1));
      fertileStart = _ymd(ovDate.subtract(const Duration(days: 2)));
      fertileEnd = _ymd(ovDate.add(const Duration(days: 2)));
    }

    // Retrospective ovulation confirmation via 3-over-6 coverline on recent
    // nightly RELATIVE skin-temp z (derived). Honest: confirmation only.
    String? ovulationEst;
    // Biometric overlay across the cycle — how resting HR / HRV / skin-temp shift
    // (descriptive context; the prediction is from logged periods, not these).
    final overlay = <Map<String, dynamic>>[];
    final derived = await LocalDb.recentDayResults(120);
    if (derived.isNotEmpty) {
      // recentDerivedDays is newest-first; coverline wants oldest-first.
      final ordered = derived.reversed.toList();
      final dates = <String>[];
      final temps = <double?>[];
      for (final r in ordered) {
        final b = _decode(r['payload_json']);
        final dt = r['date'] as String;
        dates.add(dt);
        final z = _scalar(b, 'skin_temp_z')?.toDouble();
        temps.add(z);
        // cycle day for this overlay row (relative to the last logged start).
        int? cd;
        if (lastStart != null) {
          final d = DateTime.tryParse(dt);
          if (d != null) {
            cd =
                DateTime(d.year, d.month, d.day)
                    .difference(
                      DateTime(lastStart.year, lastStart.month, lastStart.day),
                    )
                    .inDays +
                1;
          }
        }
        overlay.add({
          'date': dt,
          'cycle_day': ?cd,
          'resting_hr': _scalar(b, 'rhr')?.toDouble(),
          'hrv_rmssd': _scalar(b, 'rmssd')?.toDouble(),
          'skin_temp_idx': z,
        });
      }
      final ov = ana.menstrualCoverline(dates, temps);
      final events = ov.value;
      if (events != null && events.isNotEmpty) {
        ovulationEst = events.last.date;
      }
    }

    final confidence = (startDates.length / 3.0).clamp(0.0, 1.0);

    return {
      'enabled': true,
      'phase': phase,
      'cycle_day': cycleDay,
      'days_until_next': daysUntilNext,
      'predicted_next': predictedNext,
      'fertile_start': fertileStart,
      'fertile_end': fertileEnd,
      'ovulation_est': ovulationEst,
      'mean_length': meanLength,
      'note': null,
      'confidence': confidence,
      'logs': logs,
      'overlay': overlay,
    };
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Future<void> postCycleLog(
    String date, {
    String kind = 'start',
    String? note,
  }) async {
    await LocalDb.putCycleLog(date, kind, note: note);
  }

  @override
  Future<void> deleteCycleLog(String date) async =>
      LocalDb.deleteCycleLog(date);

  @override
  Future<void> postCycleSymptoms(
    String date,
    List<String> symptoms, {
    String? note,
  }) async => LocalDb.putCycleSymptoms(date, symptoms, note: note);

  @override
  Future<Map<String, List<String>>> getCycleSymptoms() async {
    final rows = await LocalDb.cycleSymptoms();
    final out = <String, List<String>>{};
    for (final r in rows) {
      final d = r['date'] as String?;
      if (d == null) continue;
      out[d] = _decodeStrList(r['symptoms_json']);
    }
    return out;
  }

  // ── notifications — locally-generated feed (written by DerivationEngine) ─────

  @override
  Future<Map<String, dynamic>> getNotifications() async {
    final rows = await LocalDb.notifications();
    return {
      'unread': await LocalDb.unreadCount(),
      'notifications': [
        for (final r in rows)
          {
            'id': r['id'],
            'kind': r['kind'],
            // Map the stored kind → the category/priority the feed UI styles by
            // (icon + colour). Without this every tile renders as a grey default.
            'category': _notifCategory(r['kind']?.toString() ?? ''),
            'priority': _notifPriority(r['kind']?.toString() ?? ''),
            'title': r['title'],
            'body': r['body'],
            'date': r['date'],
            'created_at': r['created_at'],
            'read': (r['read'] as num?) == 1,
          },
      ],
    };
  }

  // kind → feed category (drives the tile icon in notifications_screen.dart).
  static String _notifCategory(String kind) {
    switch (kind) {
      case 'recovery':
      case 'readiness':
        return 'recovery';
      case 'sleep':
        return 'sleep';
      case 'illness':
      case 'temp':
      case 'anomaly':
        return 'health';
      case 'load':
        return 'load';
      default:
        return kind;
    }
  }

  // kind → priority (drives the tile accent colour; 3=bad, 2=warn, 1=coral).
  static int _notifPriority(String kind) {
    switch (kind) {
      case 'illness':
        return 3;
      case 'temp':
      case 'anomaly':
      case 'readiness':
        return 2;
      case 'recovery':
        return 1;
      default:
        return 1;
    }
  }

  @override
  Future<void> markNotificationsRead({List<String>? ids}) async =>
      LocalDb.markNotificationsRead(ids: ids);

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
        if (e is Map && e['v'] is num && (e['v'] as num) > 0) (e['v'] as num),
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
