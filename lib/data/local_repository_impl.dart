// LocalRepositoryImpl — serves the UI from the PRECOMPUTED derived store.
//
// ZERO heavy compute on read: every method reads day_result / metric_series
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
import 'dart:isolate';
import 'dart:math' as math;

import '../compute/derivation_engine.dart';
import '../compute/hr_max.dart';
import '../compute/manual_session.dart';
import '../compute/profile.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'day_label.dart';
import 'db.dart';
import 'local_repository.dart';
import '../gps/route_models.dart';
import '../gps/route_math.dart' as rmath;

class LocalRepositoryImpl extends LocalRepository {
  LocalRepositoryImpl({required this.getProfileMap});

  /// Reads the live AppState profile map (age/weight/height/sex/step_goal…).
  final Map<String, dynamic>? Function() getProfileMap;

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Decode a day_result row's payload bundle (latest algo_version), or null.
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

  /// True when [date] is today's LOCAL day label (the key the day model files
  /// everything under) — the only case where a missing derived row should fall
  /// back to the latest complete day. The screens pass `todayLabel()` for the
  /// Today tab; historical drill-downs pass an exact past date, which must
  /// NEVER fall back (else every empty day renders the latest day's data — the
  /// "stage minutes show the latest night" bug).
  bool _isTodayLabel(String date) => date == todayLabel();

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

  /// Round a display value to 2dp without upgrading an int to a double —
  /// used where a raw analytics metric (e.g. round6()'d lf_hf) would
  /// otherwise render with far more precision than its sibling scalars.
  num? _round2(num? v) => v == null ? null : num.parse(v.toStringAsFixed(2));

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
    return {...p, 'step_goal': (p['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal};
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
    var readinessScalar = showOvernight
        ? _scalar(sleepBundle, 'readiness')
        : null;
    // FROZEN MORNING HEADLINE (#128): once today's overnight first settled on a
    // genuinely complete night, the derive pinned that readiness. Surface the
    // pin so the hero + once-a-morning recovery story stop drifting as the day's
    // re-derives (more daytime data, a shifting baseline) move the live scalar.
    // ONLY the headline is pinned — every other metric below still reflects the
    // latest re-derive. Gated to today's OWN overnight (`ready`, matching day)
    // so a prior-night fallback or a stale yesterday pin can never leak in.
    if (overnightState == 'ready') {
      final pin = await LocalDb.frozenHeadline();
      if (pin != null && pin.day == todayDay) {
        readinessScalar = pin.value.toDouble();
      }
    }
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
      // No imputation: stressSummaryForToday returns the SI block verbatim (null
      // when absent), so the Today tile shows "—" whenever the real SI abstained.
      // The old `100 - readiness` fallback that fabricated a number was removed.
      if (sleepBundle != null)
        'stress': ?stressSummaryForToday(sleepBundle, _scalar(sleepBundle, 'readiness')),
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
      (getProfileMap()?['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal;

  num? _wearMin(Map<String, dynamic> b) {
    // Wear = RECORD presence (the band logs 1 Hz to flash ONLY while worn), NOT
    // hr_valid/60. HR only locks when still (mostly sleep), so hr_valid collapsed
    // wear to ~half a day — the "wore it all day, shows half" bug, on BOTH
    // platforms. Prefer the engine wear block's record-presence worn_min; fall
    // back to the TOTAL record count (hr_samples, not hr_valid); never hr_valid.
    // Mirrors getDayWear so the summary tile and the wear detail agree.
    final w = b['wear'] is Map ? (b['wear'] as Map).cast<String, dynamic>() : null;
    final fromBlock = (w?['worn_min'] as num?);
    if (fromBlock != null) return fromBlock;
    final cov = _sub(b, 'coverage');
    final total = (cov?['hr_samples'] as num?)?.toInt();
    return total == null ? null : (total / 60).round();
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
      // Sleep need: same default-8 h convention as getDaySleep, so the Today
      // sleep tile gets its "of Xh need" caption + progress just like the
      // Sleep screen (it was silently absent from the /today seam before).
      'need_min': _scalarMetric(480, 'ESTIMATE', unit: 'min'),
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
        // Rounded to 2dp for display — the raw clinical metric is round6()'d
        // in analytics, which read as a raw-looking "0.354402" next to the
        // whole-number RMSSD/SDNN beside it. Only consumer is this HRV group
        // (detail_cards.dart HeartDayContent), so rounding at the source here
        // is safe.
        'lf_hf': _round2(_sub(b, 'clinical.hrv_freq.value')?['lf_hf'] as num?),
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
      // 'spo2' (oxygen dips) moved to _daySleep()/getDaySleep — it's an
      // overnight signal, grouped with the Sleep tab's nocturnal numbers now,
      // not shown on the Heart tab anymore.
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
  Future<List<String>> availableDays() => LocalDb.availableDayIds();

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
      // NO NIGHT SLEEP — but that is not the same as no sleep at all.
      //
      // A nap-only or night-shift day still has detected daytime periods, and
      // this early return used to drop them on the floor: the screen showed
      // "No sleep recorded for this night" while the very same nap was stored,
      // credited against sleep need, and drawn as a band on the Timeline.
      // Three surfaces, two answers.
      //
      // `has_sleep` stays FALSE — it means what it says, that there is no
      // NIGHT to render a hypnogram, stages or efficiency for, and inventing
      // one from a nap would be exactly the conflation this file avoids
      // elsewhere. The periods ride along so the screen can show what it does
      // know instead of claiming nothing happened.
      final napPeriods = _periodsWithMainStages(b, const {});
      if (napPeriods.isEmpty) {
        return {'has_sleep': false, 'sleep_source': sleepSource};
      }
      return {
        'has_sleep': false,
        'sleep_source': sleepSource,
        'periods': napPeriods,
        'total_asleep_min': _totalAsleepMin(b, napPeriods),
      };
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
    // Sleep periods (main + naps) for the periods screen. The main period is
    // enriched HERE with the hypnogram + stage minutes: derivation builds the
    // periods in a second isolate that never receives `series.hypnogram`, so
    // this is the first point where the whole bundle is in hand. Naps carry
    // neither by design — no stage claim is made for them.
    //
    // Naps carry their own confidence and the screen draws a ConfDot for any
    // period that has one, so omitting the main period's left the main card as
    // the ONLY one with no dot — reading as "unknown" for the best-evidenced
    // period on the screen. Stays null when accounting had no confidence,
    // which correctly draws nothing.
    final periods = _periodsWithMainStages(
      b,
      {
        'light_min': min('light_sec'),
        'deep_min': min('deep_sec'),
        'rem_min': min('rem_sec'),
        'nrem_min': min('nrem_sec'),
      },
      mainConfidence: sleepConf,
    );
    final night = <String, dynamic>{
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
      // Oxygen dips (SpO2/ODI) — moved here from getDayHeart's payload: an
      // overnight signal belongs with the rest of this night's numbers, not
      // a general daytime heart metric. Pure re-exposure of the same bundle
      // field getDayHeart already read; no new computation.
      'spo2': b['spo2'],
      // Sleep need: default 8 h (480 min) until a personal sleep-need baseline
      // exists. Debt = need − actual TST (≥0). Never null so the gauge always reads.
      'need_min': 480,
      'debt_min': ((480 - (tst / 60)).clamp(0, 480)).round(),
      'regularity':
          null, // needs ≥several nights (honest null → "Need N nights")
      // Sleep periods (main + naps) for the periods screen. The main period is
      // enriched HERE with the hypnogram + stage minutes: derivation builds the
      // periods in a second isolate that never receives `series.hypnogram`, so
      // this is the first point where the whole bundle is in hand. Naps carry
      // neither by design — no stage claim is made for them.
      'periods': periods,
      // The hero total must equal the sum of the cards under it — a user can
      // add them up. `_boundedPeriod` can CORRECT a period on read (clamping a
      // duration to its own window, dropping a degenerate one), which makes the
      // stored total stale, so it is recomputed from what is actually
      // rendered. See [_totalAsleepMin] for why an absent stored total stays
      // absent rather than being recomputed into a confident number.
      'total_asleep_min': _totalAsleepMin(b, periods),
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
    // NOTE: this used to re-map the periods here through
    // `sleepPeriodsForScreen` and overwrite `night['periods']`. That translator
    // read `start`/`end`/`asleep_min` -- the vocabulary the producer emitted
    // when this branch was written. Since #204 the producer emits
    // `onset_ts`/`wake_ts`/`duration_min` directly, and `_periodsWithMainStages`
    // (above) already attaches the hypnogram, stage minutes and the main
    // period's confidence, translating any legacy payload on read.
    //
    // Keeping the overwrite after that rebase would have read every period
    // under keys that no longer exist, produced an EMPTY list, and blanked the
    // whole screen -- main sleep included -- while the hero still showed a
    // total. One source per concern: the writer-side seam owns this now.
    return night;
  }

  /// The persisted sleep periods with the MAIN period's hypnogram and stage
  /// minutes attached.
  ///
  /// Naps are returned untouched: they have no stages, and inventing an empty
  /// stage map would make the card draw a stage bar for sleep we never
  /// classified. Absent stage minutes are dropped rather than zeroed for the
  /// same reason — `StageBars` renders 0 as an invisible gap, which reads as
  /// "no deep sleep" instead of "not measured".
  List<Map<String, dynamic>> _periodsWithMainStages(
    Map<String, dynamic> b,
    Map<String, int?> stageMin, {
    num? mainConfidence,
  }) {
    final raw = (b['sleep_periods'] as Map?)?['periods'];
    if (raw is! List) return const [];
    final hypno = _hypnoPoints(b);
    final stages = <String, dynamic>{
      for (final e in stageMin.entries)
        if (e.value != null) e.key: e.value,
    };
    return [
      for (final p in raw.whereType<Map>())
        if (_boundedPeriod(_canonicalPeriod(p)) case final bp?)
          if (bp['is_main'] != true)
            bp
          else
            {
              ...bp,
              if (hypno.isNotEmpty) 'hypnogram': hypno,
              if (stages.isNotEmpty) 'stages': stages,
              'confidence': ?mainConfidence,
            },
    ];
  }

  /// Reads a persisted period under EITHER key vocabulary.
  ///
  /// The producer emits `onset_ts`/`wake_ts`/`duration_min`, but day results
  /// written before that change hold `start`/`end`/`asleep_min` and are never
  /// rewritten: a day finalizes ~48 h behind the data edge and raw is pruned
  /// after `rawRetentionDays`, so once its substrate is gone a kAlgoVersion
  /// bump cannot re-derive it — the old payload is what that day will serve
  /// forever. Without this the Sleep-periods cards for every such day render
  /// "—" for onset, wake AND duration, underneath a hero total that is still
  /// confident, which reads as data loss rather than an old schema.
  ///
  /// Translating on READ (rather than migrating on write) also means this and
  /// the parallel fix at the other end of the seam are order-independent.
  Map<String, dynamic> _canonicalPeriod(Map p) {
    final m = p.cast<String, dynamic>();
    // Fill only keys that are genuinely ABSENT — `containsKey`, never a null
    // check. A current-schema key present with an explicit null is an honest
    // "we did not measure this", and a null test cannot tell that apart from a
    // missing key. On a mixed payload (`duration_min: null` sitting alongside a
    // stale `asleep_min: 40`) a null test promotes an unknown into a
    // measurement — the precise dishonesty this seam exists to remove.
    //
    // A period already speaking the current vocabulary passes through
    // byte-for-byte either way.
    return {
      ...m,
      if (!m.containsKey('onset_ts') && m['start'] != null)
        'onset_ts': m['start'],
      if (!m.containsKey('wake_ts') && m['end'] != null) 'wake_ts': m['end'],
      if (!m.containsKey('duration_min') && m['asleep_min'] != null)
        'duration_min': m['asleep_min'],
    };
  }

  /// A period's reported asleep minutes can never exceed its own window.
  ///
  /// Ported from #205, which added it at the (now-removed) screen-side
  /// translator. It is a real invariant and belongs here, at the one seam the
  /// screen reads: `duration_min` and the window come from different producers
  /// (staging TST vs the detected bounds), so nothing else stops a card
  /// claiming more sleep than the period it sits in. Clamped, not dropped —
  /// the window is the trustworthy half.
  ///
  /// Returns null for a period with no usable window at all, so the caller can
  /// drop it rather than render a zero-length card.
  Map<String, dynamic>? _boundedPeriod(Map<String, dynamic> m) {
    final onset = (m['onset_ts'] as num?)?.toInt();
    final wake = (m['wake_ts'] as num?)?.toInt();
    if (onset == null || wake == null || wake <= onset) {
      // Keep it only if it carries no window claim at all; a period whose
      // window is present but degenerate is junk.
      return (onset == null && wake == null) ? m : null;
    }
    final windowMin = ((wake - onset) / 60).round();
    final dur = (m['duration_min'] as num?)?.toInt();
    if (dur == null || (dur >= 0 && dur <= windowMin)) return m;
    // NEGATIVE is not "too small", it is CORRUPT — there is no such thing as
    // minus fifty minutes of sleep. It is dropped to unknown rather than
    // clamped to either end: clamping UP to the window would invent a full
    // night out of garbage, and clamping DOWN to 0 would state "you did not
    // sleep", which is a measurement we do not have. Unknown then propagates
    // through `_totalAsleepMin`, so the hero reads "—" instead of a total
    // built on a value we know is nonsense.
    if (dur < 0) return {...m, 'duration_min': null};
    return {...m, 'duration_min': windowMin};
  }

  /// The day's total asleep minutes, consistent with the cards on screen.
  ///
  /// ABSENT STAYS ABSENT. A null stored total means the producer could not
  /// state one — most often because nap detection abstained, so the day holds
  /// an unknown NUMBER of unmeasured naps (see `_sleepPeriods`). Recomputing a
  /// sum from the periods we happen to have would turn that honest "—" into a
  /// confident figure that silently omits them, which is the exact claim the
  /// producer refused to make.
  ///
  /// Otherwise the total is recomputed from the RENDERED periods rather than
  /// trusted verbatim, because `_boundedPeriod` may have corrected one on read
  /// and the stored sum would then be stale — leaving the hero disagreeing with
  /// the cards a user can add up. A period whose own duration is unknown makes
  /// the sum unknown again, for the same reason it does at the writer.
  num? _totalAsleepMin(
    Map<String, dynamic> b,
    List<Map<String, dynamic>> periods,
  ) {
    final stored = (b['sleep_periods'] as Map?)?['total_asleep_min'];
    if (stored == null) return null;
    var sum = 0;
    for (final p in periods) {
      final d = (p['duration_min'] as num?)?.toInt();
      if (d == null) return null;
      sum += d;
    }
    return sum;
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
      'spo2': b['spo2'], // relative desaturation screen; never an absolute %
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
    final hrSamples = (cov?['hr_samples'] as num?)?.toInt();
    // Wear block (on/off segments, first/last on, longest off) computed in the
    // engine; fall back to the coverage counts when absent.
    final w = b['wear'] is Map
        ? (b['wear'] as Map).cast<String, dynamic>()
        : null;
    // MISSING IS NOT ZERO. This used to collapse "we never measured wear" into
    // `worn_min: 0` via `hr_samples ?? 0`, which an imported day (no `wear`
    // block, no `coverage` block) hits every time — making it byte-identical to
    // a day the strap genuinely sat in a drawer, so the screen asserted "Not
    // worn on this day — no wrist contact was recorded" about data it simply
    // never had. Resolution order is now: engine wear block, then the day's
    // own `worn_min` scalar, then the coverage record count, then absent.
    final scalarWornMin = (_sub(b, 'scalars')?['worn_min'] as num?)?.toInt();
    final wornMin = (w?['worn_min'] as num?)?.toInt() ??
        scalarWornMin ??
        (hrSamples == null ? null : (hrSamples / 60).round());
    return {
      // Wear = RECORD presence, not valid HR (HR drops out during daytime
      // motion). Fall back to the total record count, never hr_valid.
      'worn_min': wornMin,
      'coverage_pct': (w?['coverage_pct'] as num?)?.toInt() ??
          (hrSamples == null ? null : (hrSamples > 0 ? 100 : 0)),
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
    // tension; transparent RR-histogram metric → 0–100 score). No fallback: the
    // score stays null when the SI is absent, so the screen renders "—" (the old
    // `100 - readiness` imputation was removed). Nocturnal arousal isn't computed,
    // so `sleep_stress` is intentionally absent (the screen handles it).
    final b = await _bundleForDate(date);
    if (b == null) return const {};

    final stressBlk = b['stress'] is Map
        ? (b['stress'] as Map).cast<String, dynamic>()
        : null;
    num? score = (stressBlk?['score'] as num?);
    String? level = stressBlk?['level'] as String?;
    final si = (stressBlk?['si'] as num?);
    // NO fallback here. `100 - readiness` used to backfill a "stress" number
    // whenever the real Baevsky SI was absent — fabricating a score from an
    // unrelated metric, which violates the "absent input -> null, never
    // imputed" rule and is exactly why a user with no overnight SI could see
    // a confident-looking stress score anyway. `hasStress` downstream (see
    // stress_screen.dart) already gates the hero UI on `score is num`, so
    // leaving score/level null here correctly renders as "-".

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
    // STEPS is a live-accumulating count, not a "show last settled day" metric —
    // unlike strain/zones/HR/curve above (where falling back to yesterday's
    // finished bundle via _bundleForDate is the correct "still settling" UX),
    // showing yesterday's step count as "today's steps" is actively wrong, not
    // just stale. When today's own row hasn't been derived yet, use today's
    // interim wake_day_features estimate instead of whatever _bundleForDate
    // fell back to (same source getToday() uses for the Today screen) — the
    // caller (strain_detail_screen.dart) folds AppState.liveSteps on top of
    // this, matching Today's base+live composition exactly.
    num? stepsBase;
    if (_isTodayLabel(date) && await _bundle(date) == null) {
      final wf = await _wakeFeatures(date);
      stepsBase = wf?['steps'] as num?;
    } else {
      stepsBase = _scalar(b, 'steps');
    }
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
      'steps': stepsBase?.round(),
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
    final dayEnd = _localDayEndSec(bundleDate);

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
    // Bounded BY THE DAY, in SQL. This used to pull `unuploadedEvents(limit:
    // 2000)` — `ORDER BY ts ASC LIMIT 2000`, i.e. the OLDEST 2000 rows — and
    // then filter that page down to this day. Once `events` held more than 2000
    // rows the page could no longer reach recent days at all, so their markers
    // silently vanished from the timeline (the same oldest-N-vs-trailing-N
    // shape as the metricSeries(limit:) outage).
    final dayEvents = await LocalDb.eventsInRange(dayStart, dayEnd);
    final events = <Map<String, dynamic>>[
      for (final e in dayEvents)
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
      // The DISPLAYED day (bundle date) — when a partial "today" fell back to
      // the latest complete day this differs from the requested date, and the
      // screen must window/axis by THIS date, not "now".
      'date': bundleDate,
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
  int _localMidnightSec(String ymd) => localDayStartSec(ymd) ?? 0;

  /// End of that local day (epoch sec) — the NEXT local midnight.
  ///
  /// NOT `_localMidnightSec(ymd) + 86400`: a spring-forward day is 23 h local
  /// and a fall-back day is 25 h, so the flat +86400 window pulled in an hour
  /// of the next day (or dropped the last hour) on exactly those two days a
  /// year. See day_label.dart.
  int _localDayEndSec(String ymd) => localDayEndSec(ymd) ?? 0;

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
    // The Recap card (ui/recap/recap_screen.dart) reads a `metrics` map
    // (avg/total/delta_pct per key), daily `series` for the mini-viz, a
    // `worn_days` count (its emptiness gate), and `from_epoch`/`to_epoch` for
    // the period label. Build all of that from the persisted metric_series
    // rows. NOTE: the old stub returned `{days:[…]}` — the wrong shape — so
    // `_isEmpty` always saw metrics={} / worn_days=0 and the recap was stuck on
    // "Not enough data yet" for BOTH week and month regardless of data.
    final days = range == '7d' ? 7 : 30;

    Future<Map<String, double>> seriesMap(String key) async {
      final rows = await LocalDb.metricSeries(key); // ascending by date
      final m = <String, double>{};
      for (final r in rows) {
        final v = (r['value'] as num?)?.toDouble();
        if (v != null) m[r['date'] as String] = v;
      }
      return m;
    }

    final strain = await seriesMap('strain');
    final rhr = await seriesMap('rhr');
    final tst = await seriesMap('tst_min'); // minutes (recap _hm() formats h/m)
    final cals = await seriesMap('calories');
    final steps = await seriesMap('steps');

    // Anchor on the most recent day that has ANY data.
    final allDates = <String>{
      ...strain.keys,
      ...rhr.keys,
      ...tst.keys,
      ...cals.keys,
      ...steps.keys,
    };
    if (allDates.isEmpty) {
      return {'metrics': const {}, 'series': const {}, 'worn_days': 0};
    }

    DateTime parseD(String s) {
      final p = s.split('-');
      return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    }

    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    int secOf(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

    final anchor = allDates.map(parseD).reduce((a, b) => a.isAfter(b) ? a : b);
    final start = anchor.subtract(Duration(days: days - 1));
    final prevEnd = start.subtract(const Duration(days: 1));
    final prevStart = prevEnd.subtract(Duration(days: days - 1));

    List<double> windowVals(Map<String, double> m, DateTime s, DateTime e) {
      final out = <double>[];
      var d = s;
      while (!d.isAfter(e)) {
        final v = m[ymd(d)];
        if (v != null) out.add(v);
        d = d.add(const Duration(days: 1));
      }
      return out;
    }

    double? mean(List<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
    double? total(List<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a + b);
    double? pctDelta(double? now, double? prev) =>
        (now == null || prev == null || prev == 0)
            ? null
            : (now - prev) / prev * 100.0;
    double? round1(double? v) =>
        v == null ? null : double.parse(v.toStringAsFixed(1));

    // Daily series (oldest→newest), present days only, as [{t, v}].
    List<Map<String, dynamic>> daily(Map<String, double> m) {
      final out = <Map<String, dynamic>>[];
      var d = start;
      while (!d.isAfter(anchor)) {
        final v = m[ymd(d)];
        if (v != null) out.add({'t': secOf(d), 'v': v});
        d = d.add(const Duration(days: 1));
      }
      return out;
    }

    final strainAvg = mean(windowVals(strain, start, anchor));
    final strainPrev = mean(windowVals(strain, prevStart, prevEnd));
    final rhrAvg = mean(windowVals(rhr, start, anchor));
    final rhrPrev = mean(windowVals(rhr, prevStart, prevEnd));
    final tstAvg = mean(windowVals(tst, start, anchor));
    final calTotal = total(windowVals(cals, start, anchor));

    // Worn days = distinct days in the window with any metric present.
    var worn = 0;
    var wd = start;
    while (!wd.isAfter(anchor)) {
      final k = ymd(wd);
      if (strain.containsKey(k) ||
          rhr.containsKey(k) ||
          tst.containsKey(k) ||
          cals.containsKey(k) ||
          steps.containsKey(k)) {
        worn++;
      }
      wd = wd.add(const Duration(days: 1));
    }

    return {
      'from_epoch': secOf(start),
      'to_epoch': secOf(anchor),
      'worn_days': worn,
      'metrics': {
        'strain': {
          'avg': round1(strainAvg),
          'delta_pct': round1(pctDelta(strainAvg, strainPrev)),
        },
        'resting_hr': {
          'avg': round1(rhrAvg),
          'delta_pct': round1(pctDelta(rhrAvg, rhrPrev)),
        },
        'sleep_duration': {'avg': round1(tstAvg)},
        'calories': {'total': round1(calTotal)},
      },
      'series': {
        'strain': daily(strain),
        'steps': daily(steps),
      },
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
      // "Today's heart rate" card: the curve must be TODAY's. _latestBundle
      // falls back to the latest COMPLETE day, so its curve could be
      // yesterday's — drawn on a midnight→now axis it rendered a previous
      // day's line on today's timeline. Prefer today's own (partial) bundle,
      // then clip whatever we got to today's local-day window; an empty result
      // is the card's honest "No heart-rate data yet today" state.
      final today = _todayLocalLabel();
      final b = await _bundleForDate(today);
      final curve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];
      final dayStart = _localMidnightSec(today);
      final dayEnd = _localDayEndSec(today);
      return {
        'points': [
          for (final e in curve)
            if (e is Map &&
                e['t'] is num &&
                (e['t'] as num) >= dayStart &&
                (e['t'] as num) < dayEnd)
              e,
        ],
      };
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
    // PAYLOAD-FREE. This used to be `recentDayResults(3650)` — `SELECT r.*`
    // over TEN YEARS of day_result, dragging every bundle's hr_curve /
    // hypnogram / HRV series across and `jsonDecode`ing each on the main
    // isolate, for a screen that only ever needs scalar extremes. At ~2 years
    // of history that is hundreds of MB decoded to compute two counts. Both
    // are now answered in SQLite: day labels from an index-only GROUP BY, the
    // sleep count via json_extract (only the scalar crosses the boundary).
    final dayLabelList = await LocalDb.dayResultDayIdsDesc();
    final days = dayLabelList.length;
    final sleepDays = await LocalDb.daysWithSleepTst();
    final nights = sleepDays.length;

    // Personal records from the day scalars (metric_series) + the sessions
    // table — computed locally with the record's own date attached.
    final records = <String, Map<String, dynamic>>{};
    Future<void> extreme(String recordKey, String seriesKey,
        {bool max = true, double Function(double)? mapValue}) async {
      final series = await LocalDb.metricSeries(seriesKey);
      String? bestDate;
      double? best;
      for (final r in series) {
        final v = (r['value'] as num?)?.toDouble();
        if (v == null) continue;
        if (best == null || (max ? v > best : v < best)) {
          best = v;
          bestDate = r['date'] as String?;
        }
      }
      if (best == null || bestDate == null) return;
      records[recordKey] = {
        'value': mapValue == null ? best : mapValue(best),
        'date': bestDate,
      };
    }

    await extreme('lowest_rhr', 'rhr', max: false);
    await extreme('top_strain', 'strain');
    await extreme('longest_sleep', 'tst_min');
    // The Records screen formats efficiency as a 0..1 fraction ((v*100)%).
    await extreme('best_efficiency', 'efficiency',
        mapValue: (v) => v > 1.5 ? v / 100.0 : v);
    await extreme('most_steps', 'steps');
    await extreme('top_readiness', 'readiness');

    // Honest gamification: don't celebrate a "personal best" built on a
    // baseline the app itself still calls "calibrating"/"provisional"
    // elsewhere (the Heart tab's Personal-baselines card) — resting_hr is
    // the one record key with a real Winsorized-EWMA trust status to check.
    // (The other record keys — strain/sleep/efficiency/steps/readiness/
    // workout — have no equivalent trust concept in this codebase to gate
    // on; celebrating an all-time extreme from a short history is a smaller,
    // pre-existing honesty gap for those, left as-is here rather than
    // inventing a new trust proxy for six unrelated metrics.)
    if (records.containsKey('lowest_rhr')) {
      final latest = await _latestBundle();
      // Dotted-path _sub instead of chained dynamic indexing — a bundle
      // where baselines.resting_hr isn't a Map (or is missing/a List) would
      // otherwise throw NoSuchMethodError out of getRecords() instead of
      // falling into the honest "not trusted" branch. _sub already walks
      // the whole path defensively, returning null on any mismatch.
      final rhrStatus = _sub(latest, 'baselines.resting_hr')?['status'] as String?;
      if (rhrStatus != 'trusted') records.remove('lowest_rhr');
    }

    // Sessions: top workout strain (with its type) + total tracked count.
    var workoutsTracked = 0;
    final sessions = await LocalDb.sessionsInRange(
        0, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    Map<String, dynamic>? topWorkout;
    for (final s in sessions) {
      if (s['status'] == 'live') continue;
      workoutsTracked++;
      final strain = (s['strain'] as num?)?.toDouble();
      if (strain == null || strain <= 0) continue;
      if (topWorkout == null ||
          strain > (topWorkout['value'] as double)) {
        final startTs = (s['start_ts'] as num?)?.toInt();
        topWorkout = {
          'value': strain,
          'date': startTs == null
              ? ''
              : _dayLabelOf(
                  DateTime.fromMillisecondsSinceEpoch(startTs * 1000)),
          'type': s['type'],
        };
      }
    }
    if (topWorkout != null && (topWorkout['date'] as String).isNotEmpty) {
      records['top_workout'] = topWorkout;
    }

    // Streaks: consecutive most-recent days with derived data / with sleep.
    final dayLabels = dayLabelList.toSet();
    int streakOf(Set<String> have) {
      var streak = 0;
      var d = DateTime.now();
      // Today may legitimately not be derived yet — start from today if
      // present, else from yesterday.
      if (!have.contains(_dayLabelOf(d))) {
        d = d.subtract(const Duration(days: 1));
      }
      while (have.contains(_dayLabelOf(d))) {
        streak++;
        d = d.subtract(const Duration(days: 1));
      }
      return streak;
    }

    final wearStreak = streakOf(dayLabels);
    final sleepStreak = streakOf(sleepDays);

    return {
      'days_tracked': days,
      'nights_tracked': nights,
      'workouts_tracked': workoutsTracked,
      'records': records,
      'streaks': {
        if (wearStreak > 0)
          'wear': {'current': wearStreak, 'label': 'Days tracked in a row'},
        if (sleepStreak > 0)
          'sleep': {'current': sleepStreak, 'label': 'Nights of sleep in a row'},
      },
      ..._rhrDriftOf(await LocalDb.metricSeries('rhr')),
    };
  }

  /// 'YYYY-MM-DD' local label for a DateTime (records/streaks bookkeeping).
  String _dayLabelOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Resting-HR drift: mean of the newest 7 rhr points vs the mean of the 7
  /// points ~30 days back. Needs ≥ 21 points spanning ≥ 21 days; otherwise the
  /// screen shows its honest "not enough history" state.
  Map<String, dynamic> _rhrDriftOf(List<Map<String, dynamic>> series) {
    final pts = [
      for (final r in series)
        if (r['value'] is num && r['date'] is String)
          (date: r['date'] as String, v: (r['value'] as num).toDouble()),
    ];
    if (pts.length < 21) return const {};
    double mean(Iterable<double> xs) =>
        xs.reduce((a, b) => a + b) / xs.length;
    final now = mean(pts.sublist(pts.length - 7).map((p) => p.v));
    final thenStart = math.max(0, pts.length - 37);
    final then = mean(pts.sublist(thenStart, thenStart + 7).map((p) => p.v));
    final delta = now - then;
    final direction = delta <= -1
        ? 'improving'
        : delta >= 1
            ? 'worsening'
            : 'flat';
    return {
      'rhr_drift': {
        'now': now,
        'then': then,
        'delta': delta,
        'direction': direction,
        'days': math.min(37, pts.length),
      },
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
      // manual / auto — the detail screen shows the AUTO tag + correct-type CTA.
      'source': r['source'],
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

    // Per-session HR aggregates from the 1 Hz substrate (one indexed join).
    // Sessions have no avg_hr column — without this every workout looked like
    // "no data" (avg_hr == 0) even when the window is full of worn HR.
    try {
      final age = _profileAge();
      final stats = await LocalDb.sessionHrStats(fromTs, nowSec,
          maxHrCeiling: hrCeilingForAge(age), minHrFloor: kHrFloorBpm);
      // Spike-suppressed max/min per session (issue #127): smooth the raw 1 Hz
      // over one batched join so the list agrees with getWorkout's on-read
      // recompute.
      final rawBySession = await LocalDb.sessionHrSamplesBySession(fromTs, nowSec);
      for (final w in workouts) {
        final s = stats[w['id']];
        final raw = rawBySession[w['id']];
        if (s != null && (s['n'] ?? 0) != 0) {
          w['avg_hr'] = (s['avg_hr'] as num).round();
        }
        // Peak: smoothed-from-raw (authoritative, matches the detail screen);
        // else stored column, else the ceiling-bounded SQL max.
        final smax = raw == null ? null : smoothedMaxHr(raw, age: age);
        if (smax != null) {
          w['max_hr'] = smax;
        } else if (s != null && (s['n'] ?? 0) != 0) {
          w['max_hr'] ??= (s['max_hr'] as num).toInt();
        }
        // Trough: same treatment. Raw pruned → the floor-bounded SQL min.
        final smin = raw == null ? null : smoothedMinHr(raw, age: age);
        if (smin != null) {
          w['min_hr'] = smin;
        } else if (s != null && (s['n'] ?? 0) != 0) {
          w['min_hr'] = (s['min_hr'] as num).toInt();
        }
      }
    } catch (_) {
      /* stats are an enrichment — the list still renders without them */
    }

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
    final stored = await LocalDb.session(id);
    if (stored == null) return const {};
    // Reconcile the live tallies against the substrate BEFORE projecting the
    // row (issue #206) — a session the app slept through stores a strain built
    // from the few minutes it was awake for. Persists on improvement, so the
    // list and the share card see the corrected value too.
    final rescored = await _rescoreSessionFromSubstrate(stored);
    final w = _workoutOf(rescored.row);
    final startTs = w['start_ts'] as int?;
    if (startTs == null) return w;
    final endTs =
        (w['end_ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (endTs <= startTs) return w;

    // Enrich from the 1 Hz substrate over the session window — the exact
    // approach getWorkoutRoute already uses. The detail/finish screens read
    // hr / avg_hr / min_hr / zone_bands / recovery_curve / hr_drift_pct /
    // time_to_peak_min; without a producer they were blank everywhere.
    try {
      // Reuse the rows the rescore above already read for this exact window
      // rather than scanning it a second time on every detail open.
      final hrRows = rescored.hrRows ??
          await LocalDb.hrSamplesInRange(startTs, endTs);
      if (hrRows.isNotEmpty) {
        final ts = [for (final e in hrRows) (e['rec_ts'] as num).toInt()];
        final hr = [for (final e in hrRows) (e['hr'] as num).toInt()];
        w['hr'] = _minuteHrCurve(ts, hr);
        final avg = hr.reduce((a, b) => a + b) / hr.length;
        w['avg_hr'] = avg.round();
        // Spike-suppressed trough (issue #127): a lone low PPG dropout must not
        // define the min, symmetric to the max recompute below.
        w['min_hr'] = smoothedMinHr(hr, age: _profileAge()) ?? hr.reduce(math.min);
        // Spike-suppressed peak (issue #127). RECOMPUTE from the smoothed raw —
        // do NOT floor against the stored column: the live path may already have
        // written a spiked max there, and math.max() would preserve it.
        final peakAt = smoothedMaxHrAt(hr, age: _profileAge());
        if (peakAt != null) {
          w['max_hr'] = peakAt.$1;
          w['time_to_peak_min'] = ((ts[peakAt.$2] - startTs) / 60).round();
        }
        w['zone_bands'] = _zoneBands(hr);
        final drift = _hrDriftPct(ts, hr, startTs, endTs);
        if (drift != null) w['hr_drift_pct'] = drift;
      }
      if (w['status'] == 'done') {
        final curve = await _recoveryCurve(endTs);
        if (curve.isNotEmpty) w['recovery_curve'] = curve;
      }
    } catch (_) {
      /* enrichment is best-effort — the summary scalars still render */
    }
    return w;
  }

  /// Minute-mean HR curve [{t, v}] (epoch sec at each minute start) from raw
  /// 1 Hz samples — the shape the detail chart parses.
  List<Map<String, num>> _minuteHrCurve(List<int> ts, List<int> hr) {
    final out = <Map<String, num>>[];
    var bucket = -1;
    var sum = 0;
    var n = 0;
    void emit() {
      if (n > 0) out.add({'t': bucket * 60, 'v': (sum / n).round()});
    }

    for (var i = 0; i < ts.length; i++) {
      final b = ts[i] ~/ 60;
      if (b != bucket) {
        emit();
        bucket = b;
        sum = 0;
        n = 0;
      }
      sum += hr[i];
      n++;
    }
    emit();
    return out;
  }

  /// Time-in-zone bands Z1..Z5 (50/60/70/80/90 % of max HR) over the session's
  /// 1 Hz HR — the shape the zones card + summary bar parse.
  List<Map<String, dynamic>> _zoneBands(List<int> hr) {
    final maxHr = _profileMaxHr();
    const names = ['Warm-up', 'Fat burn', 'Aerobic', 'Threshold', 'Max effort'];
    const loPct = [0.5, 0.6, 0.7, 0.8, 0.9];
    final secs = List<int>.filled(5, 0);
    for (final v in hr) {
      final pct = v / maxHr;
      for (var z = 4; z >= 0; z--) {
        if (pct >= loPct[z]) {
          secs[z]++;
          break;
        }
      }
    }
    final total = hr.length;
    return [
      for (var z = 0; z < 5; z++)
        {
          'zone': z + 1,
          'name': names[z],
          'lo': (loPct[z] * maxHr).round(),
          'hi': z == 4 ? maxHr : (loPct[z + 1] * maxHr).round(),
          'min': double.parse((secs[z] / 60).toStringAsFixed(1)),
          'pct': total == 0 ? 0 : (secs[z] / total * 100).round(),
        },
    ];
  }

  /// Cardiac drift: mean HR of the 2nd half vs the 1st half, %; sessions under
  /// 10 min (or with a sparse half) yield null rather than a noisy number.
  double? _hrDriftPct(List<int> ts, List<int> hr, int startTs, int endTs) {
    if (endTs - startTs < 600) return null;
    final mid = startTs + (endTs - startTs) ~/ 2;
    var s1 = 0, n1 = 0, s2 = 0, n2 = 0;
    for (var i = 0; i < ts.length; i++) {
      if (ts[i] < mid) {
        s1 += hr[i];
        n1++;
      } else {
        s2 += hr[i];
        n2++;
      }
    }
    if (n1 < 60 || n2 < 60) return null;
    final a = s1 / n1, b = s2 / n2;
    if (a <= 0) return null;
    return double.parse(((b / a - 1) * 100).toStringAsFixed(1));
  }

  /// Post-end HR recovery curve [{sec, drop}] at 60/120/180 s: the drop from
  /// the end-of-effort HR (median of the last 15 s) to the HR around each mark.
  Future<List<Map<String, num>>> _recoveryCurve(int endTs) async {
    final rows = await LocalDb.hrSamplesInRange(endTs - 15, endTs + 190);
    if (rows.isEmpty) return const [];
    final endWindow = <int>[];
    final post = <int, int>{}; // ts → hr
    for (final e in rows) {
      final t = (e['rec_ts'] as num).toInt();
      final v = (e['hr'] as num).toInt();
      if (t <= endTs) {
        endWindow.add(v);
      } else {
        post[t] = v;
      }
    }
    if (endWindow.length < 5) return const [];
    endWindow.sort();
    final endHr = endWindow[endWindow.length ~/ 2];
    final out = <Map<String, num>>[];
    for (final sec in const [60, 120, 180]) {
      // Median of a ±7 s window around the mark; skip marks with no data.
      final win = <int>[
        for (final e in post.entries)
          if ((e.key - (endTs + sec)).abs() <= 7) e.value,
      ]..sort();
      if (win.isEmpty) continue;
      final drop = endHr - win[win.length ~/ 2];
      if (drop <= 0) continue; // HR not recovering (or still working) — omit
      out.add({'sec': sec, 'drop': drop});
    }
    return out;
  }

  int _profileMaxHr() {
    final age = (getProfileMap()?['age'] as num?)?.toDouble() ?? 30.0;
    return (220 - age).round();
  }

  /// Profile age in years, or null when unset — the input to the physiological
  /// HR ceiling in the spike-suppressed max ([hrCeilingForAge]).
  int? _profileAge() => (getProfileMap()?['age'] as num?)?.round();

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

  @override
  Future<List<SessionSpan>> savedSessionSpans() async {
    // Everything ever logged — the overlap check has to see a session from any
    // date the athlete might be back-filling into, not just a recent window.
    final rows = await LocalDb.sessionsInRange(0, 1 << 40);
    return [
      for (final r in rows)
        if (r['id'] is String && r['start_ts'] is num && r['end_ts'] is num)
          SessionSpan(
            r['id'] as String,
            (r['start_ts'] as num).toInt(),
            (r['end_ts'] as num).toInt(),
          ),
    ];
  }

  @override
  Future<Map<String, dynamic>> logManualWorkout({
    required int startTs,
    required int endTs,
    required String type,
  }) =>
      _writeManualSession(
        startTs: startTs,
        endTs: endTs,
        type: type,
        // A manual row's id is derived from its start second, so re-logging the
        // same window is an UPDATE of that row, not a collision with it. Pass
        // the id we are about to write as the one to skip in the overlap check.
        validateAgainstId: manualSessionId(startTs),
      );

  @override
  Future<Map<String, dynamic>> logDetectedWorkout({
    required int startTs,
    required int endTs,
    required String type,
  }) =>
      _writeManualSession(
        startTs: startTs,
        endTs: endTs,
        type: type,
        sessionId: 'auto:$startTs',
        source: 'auto',
        validateAgainstId: 'auto:$startTs',
      );

  @override
  Future<Map<String, dynamic>> setWorkoutWindow(
    String id, {
    required int startTs,
    required int endTs,
  }) async {
    final existing = await LocalDb.session(id);
    if (existing == null) {
      throw StateError('setWorkoutWindow: no session $id');
    }
    // A running session has no end to correct yet, and buildManualSessionRow
    // always writes status 'done' — retiming one here would silently end it.
    // The detail screen already passes onEditTimes:null for a live row, but
    // the window is re-validated at this seam precisely because the form is
    // not the only caller; the status deserves the same treatment.
    if (existing['status'] == 'live') {
      throw StateError('setWorkoutWindow: session $id is still live');
    }
    // A retimed session keeps its id, so the OLD row is replaced rather than
    // orphaned — including its GPS route, which still belongs to it.
    return _writeManualSession(
      startTs: startTs,
      endTs: endTs,
      type: (existing['type'] as String?) ?? 'other',
      existing: existing,
      validateAgainstId: id,
    );
  }

  /// Shared writer for both user-timed paths: score the window from the 1 Hz
  /// substrate, persist, and retire any auto-detect suggestion it covers.
  ///
  /// Deliberately does NOT force a day re-derive. Sessions do not feed
  /// `day_result` — the derivation engine reads them only as `savedSpans`
  /// (auto-detect exclusion) and to back-fill `hrr_bpm`, while day strain and
  /// calories come from the whole-day substrate independently. So there is no
  /// analytics output to invalidate here and no `kAlgoVersion` bump to make;
  /// the next ordinary derive picks up the exclusion on its own.
  Future<Map<String, dynamic>> _writeManualSession({
    required int startTs,
    required int endTs,
    required String type,
    required String validateAgainstId,
    Map<String, dynamic>? existing,
    String? sessionId,
    String source = 'manual',
  }) async {
    // Re-check at the write seam. The form validates live, but its snapshot of
    // saved spans can be stale by the time save is tapped (a background derive
    // can log an auto-detected session mid-edit), and the form is not the only
    // possible caller. Throwing beats silently writing an overlapping row.
    final invalid = validateManualWindow(
      startSec: startTs,
      endSec: endTs,
      nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      existing: await savedSessionSpans(),
      editingId: validateAgainstId,
    );
    if (invalid != null) throw ManualWindowException(invalid);

    final hrRows = await LocalDb.hrSamplesInRange(startTs, endTs);
    final hrTs = [for (final e in hrRows) (e['rec_ts'] as num).toInt()];
    final hrBpm = [for (final e in hrRows) (e['hr'] as num).toInt()];

    final profile = Profile.fromMap(getProfileMap());
    // Prefer the measured nightly RHR; fall back to the user-supplied one.
    // Both are real inputs — absent both, strain stays null rather than
    // leaning on a 60 bpm stand-in.
    final restingHr = await _recentRestingHr() ??
        profile.restingHrManual?.toDouble();

    final stats = computeManualSessionStats(
      hrTs: hrTs,
      hrBpm: hrBpm,
      profile: profile,
      zoneMaxHr: _profileMaxHr().toDouble(),
      restingHr: restingHr,
    );

    final row = buildManualSessionRow(
      startSec: startTs,
      endSec: endTs,
      type: type,
      stats: stats,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      existing: existing,
      sessionId: sessionId,
      source: source,
    );
    await LocalDb.putSession(row);

    // Retire the fragment(s) this window supersedes, so the athlete isn't
    // asked "did you work out?" about the session they just logged.
    try {
      final sug = await LocalDb.activeWorkoutSuggestions();
      for (final id in supersededSuggestionIds(sug,
          startSec: startTs, endSec: endTs)) {
        await LocalDb.dismissWorkoutSuggestion(id);
      }
    } catch (_) {
      /* suggestion cleanup is best-effort — the session is already saved */
    }

    return {
      'workout_id': row['id'],
      'unscored': stats.isUnscored,
      'hr_samples': stats.hrSampleCount,
    };
  }

  /// Re-score a finished session's strain/calories/max-HR/zone-minutes from the
  /// 1 Hz substrate and persist the result when the substrate improves on what
  /// the live accumulator managed to see (issue #206).
  ///
  /// The live tallies only cover the minutes the foreground app was awake for;
  /// an app suspended or killed mid-workout stores a strain covering a fraction
  /// of the window — often a few sub-resting minutes, which score a confident
  /// `0.0`. Once the band offloads that window, the substrate holds the whole
  /// thing. [reconcileSessionScore] documents why merging the two by `max` is
  /// the correct rule; the short version is that both are lower bounds over
  /// subsets of the same window's minutes.
  ///
  /// Self-healing by construction: it re-runs whenever the row is read or a
  /// drain lands, and the merge is monotone, so a partially-drained window
  /// improves on each pass and converges. Returns the row with the reconciled
  /// values applied (never null-out a stored value), writing back only on a
  /// real change. Best-effort — never throws into a read path.
  Future<({Map<String, dynamic> row, List<Map<String, dynamic>>? hrRows})>
      _rescoreSessionFromSubstrate(Map<String, dynamic> row) async {
    final id = row['id'];
    final startTs = (row['start_ts'] as num?)?.toInt();
    final endTs = (row['end_ts'] as num?)?.toInt();
    // A live row is still accumulating; scoring it here would race the tally.
    if (id is! String ||
        startTs == null ||
        endTs == null ||
        endTs <= startTs ||
        (row['status']?.toString() ?? '') != 'done') {
      return (row: row, hrRows: null);
    }
    try {
      // Returned to the caller: `getWorkout` enriches from the SAME 1 Hz window
      // straight after this, and a two-hour session is ~7200 rows to scan twice.
      final hrRows = await LocalDb.hrSamplesInRange(startTs, endTs);
      if (hrRows.isEmpty) return (row: row, hrRows: hrRows);

      final profile = Profile.fromMap(getProfileMap());
      final hrBpm = [for (final e in hrRows) (e['hr'] as num).toInt()];
      final raw = computeManualSessionStats(
        hrTs: [for (final e in hrRows) (e['rec_ts'] as num).toInt()],
        hrBpm: hrBpm,
        profile: profile,
        zoneMaxHr: _profileMaxHr().toDouble(),
        restingHr:
            await _recentRestingHr() ?? profile.restingHrManual?.toDouble(),
      );
      // `computeManualSessionStats` reports the raw 1 Hz peak. Persisting that
      // writes a PPG spike into the column `getWorkout` deliberately refuses to
      // floor against (issue #127) — and once raw ages out past retention the
      // list has no smoothed value left to prefer, so the artefact would become
      // permanent. Store the spike-suppressed peak instead.
      final stats = ManualSessionStats(
        avgHr: raw.avgHr,
        maxHr: smoothedMaxHr(hrBpm, age: _profileAge()) ?? raw.maxHr,
        strain: raw.strain,
        calories: raw.calories,
        zoneMinutes: raw.zoneMinutes,
        hrSampleCount: raw.hrSampleCount,
      );

      // "Complete" = the band has handed over essentially the whole window.
      // 1 Hz means one sample per second, so sample count vs window seconds is
      // the coverage ratio; 90% absorbs the usual handful of dropped seconds.
      final windowSec = endTs - startTs;
      final complete =
          windowSec > 0 && stats.hrSampleCount >= (windowSec * 0.9).floor();

      final merged = reconcileSessionScore(
        substrateIsComplete: complete,
        liveStrain: (row['strain'] as num?)?.toDouble(),
        liveCalories: (row['calories'] as num?)?.toDouble(),
        liveMaxHr: (row['max_hr'] as num?)?.toInt(),
        liveZoneMinutes: [
          for (final v in _decodeList(row['zone_min_json']))
            if (v is num) v.toDouble(),
        ],
        substrate: stats,
      );
      if (!merged.changed) return (row: row, hrRows: hrRows);

      // `putSession` is INSERT-OR-REPLACE on the whole row, and everything
      // above this point awaited (two substrate reads). A retime or a
      // `stopWorkout` finalize landing in that window would be silently
      // reverted — old start/end/status written back over the new ones. Re-read
      // and bail if the row moved under us; the next sweep (or the next open)
      // scores the new window.
      final current = await LocalDb.session(id);
      if (current == null ||
          (current['start_ts'] as num?)?.toInt() != startTs ||
          (current['end_ts'] as num?)?.toInt() != endTs ||
          current['status']?.toString() != row['status']?.toString()) {
        // The row moved under us. Return the fresh row but NOT the rows we
        // read — they describe the old window, and `getWorkout` would enrich
        // the new one with them (a negative time-to-peak, zones over the wrong
        // span). The next pass scores the new window.
        return (row: current ?? row, hrRows: null);
      }

      final zoneJson = jsonEncode(
        merged.zoneMinutes.any((v) => v > 0) ? merged.zoneMinutes : const <num>[],
      );
      // Score columns ONLY, via a targeted UPDATE. `putSession` is
      // INSERT-OR-REPLACE over the whole row, so it also rewrites columns this
      // code never looked at — `hrr_bpm` (backfilled by the derive) and `type`
      // (the user's own correction) are both written by narrow UPDATEs that
      // the re-read above cannot detect.
      await LocalDb.setSessionScores(
        id,
        strain: merged.strain,
        calories: merged.calories,
        maxHr: merged.maxHr,
        zoneMinJson: zoneJson,
      );
      final updated = {
        ...current,
        'strain': merged.strain,
        'calories': merged.calories,
        'max_hr': merged.maxHr,
        'zone_min_json': zoneJson,
      };
      return (row: updated, hrRows: hrRows);
    } catch (_) {
      return (row: row, hrRows: null); // best-effort: the stored row renders
    }
  }

  /// Sessions this process has already scored as FINISHED, keyed by id and the
  /// window they had at the time (`id@endTs`).
  ///
  /// The skip cannot key on the window alone: a session that was still `live`
  /// during an earlier sweep is skipped by [_rescoreSessionFromSubstrate] (its
  /// tally is still accumulating), and once the frontier moved past its end a
  /// window-only rule would skip it forever after it finished — leaving the
  /// list showing the stale live-tally strain until someone opened it. Keying
  /// on the window too means a retimed session is rescored rather than assumed
  /// settled.
  final Set<String> _rescoredSessions = <String>{};

  /// Re-score recent finished sessions against the substrate now in the DB.
  /// Called after a drain lands, so a workout whose window arrived late is
  /// corrected on the LIST too, not only when its detail screen is opened.
  /// Returns how many rows changed.
  ///
  /// Runs on the DB-owning (main) isolate by necessity — the sqflite handle is
  /// not portable to another isolate — so it is bounded rather than offloaded:
  /// the window is the raw-retention horizon (older windows are pruned and can
  /// never improve) and anything already covered by a previous pass is skipped
  /// outright, which leaves an ordinary drain doing no substrate reads at all.

  @override
  Future<int> rescoreRecentSessions({int sinceDays = 3}) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var changed = 0;
    try {
      // Local-midnight bound, not `now - n * 86400`: a DST day is 23 or 25
      // hours, so a flat day-length silently moves the window by an hour.
      final fromTs =
          localDayStartSec(dayLabelOf(DateTime.now().subtract(
                Duration(days: sinceDays),
              ))) ??
              (nowSec - sinceDays * 86400);
      final rows = await LocalDb.sessionsInRange(fromTs, nowSec);
      // Where the durable record frontier stands NOW. A finished session whose
      // window sits behind it has all the substrate it is ever going to get.
      // Falls back to the newest decoded row so an import-only install (no
      // band, so no `rec_ts_hw` cursor) still gets the skip rather than
      // re-scanning every session's window on every pass.
      final frontier = await LocalDb.getCursorInt('rec_ts_hw') ??
          await LocalDb.lastDecodedRecTs() ??
          0;
      final seen = <String>{};
      for (final r in rows) {
        final id = r['id']?.toString();
        final endTs = (r['end_ts'] as num?)?.toInt();
        final key = (id == null || endTs == null) ? null : '$id@$endTs';
        if (key != null) seen.add(key);
        // Settled: finished, fully covered, and already scored in that state.
        if (key != null &&
            endTs! <= frontier &&
            _rescoredSessions.contains(key)) {
          continue;
        }
        final after = await _rescoreSessionFromSubstrate(r);
        // Count only what THIS pass wrote (the bail path returns a re-read row
        // whose values may differ for reasons we had nothing to do with), and
        // count ALL the scored columns — a pass that fixes calories or the zone
        // split without moving strain still changed what the list shows.
        const scored = ['strain', 'calories', 'max_hr', 'zone_min_json'];
        if (after.hrRows != null &&
            scored.any((k) => '${after.row[k]}' != '${r[k]}')) {
          changed++;
        }
        // Record it only once it is genuinely finished AND actually scored: a
        // live row is skipped by the helper and must be revisited after it
        // ends, and a row whose read threw (null rows) would otherwise be
        // written off for the rest of the process on a transient DB error.
        // The insertion condition MUST match the skip condition, `endTs <=
        // frontier` included. Without it, a workout scored while the band had
        // only handed over part of its window got stamped as settled, and the
        // next drain — the one carrying the REST of that window — skipped it.
        // The partial score then stood on the list until someone opened the
        // detail screen, which is exactly the case the sweep exists for.
        if (key != null &&
            endTs! <= frontier &&
            after.hrRows != null &&
            (r['status']?.toString() ?? '') == 'done') {
          _rescoredSessions.add(key);
        }
      }
      // Drop anything that aged out of the window so the set can't grow
      // without bound across a long-lived process.
      _rescoredSessions.retainWhere(seen.contains);
    } catch (_) {
      /* best-effort */
    }
    return changed;
  }

  /// Most recent nightly resting HR from `metric_series`, or null. Bounded to
  /// the last week so a stale figure from a long gap can't anchor TRIMP.
  Future<double?> _recentRestingHr() async {
    try {
      // 'rhr' is the `metric_series` key the derivation engine writes nightly
      // resting HR under (see _BaselineHistoryCache.keys).
      final vals = await LocalDb.trailingSeriesValues('rhr', 7);
      if (vals.isEmpty) return null;
      return vals.last;
    } catch (_) {
      return null;
    }
  }

  /// Tolerance when clipping route points to their session's window. GPS
  /// timestamps are millisecond-stamped while the session window is whole
  /// seconds, so the very first and last fix can land a hair outside it.
  static const int _routeClipPadSec = 5;

  @override
  Future<WorkoutRoute?> getWorkoutRoute(String id) async {
    final rows = await LocalDb.routePoints(id);
    if (rows.length < 2) return null;
    var points = [for (final r in rows) RoutePoint.fromRow(r)];

    // Clip to the session's CURRENT window. A route point outside its
    // session's window is not part of that session — which only became
    // reachable once workouts could be retimed: narrowing a live run that was
    // stopped late (say 90 min down to the 60 you actually ran) otherwise left
    // the map, distance, moving time and splits describing the full original
    // 90 minutes while the hero above them read "1h 00m". Two contradictory
    // accounts of the same session on one card.
    //
    // Widening cannot conjure GPS that was never recorded, so the route simply
    // stays as long as it is — correct, and honest about it.
    final session = await LocalDb.session(id);
    final startTs = (session?['start_ts'] as num?)?.toInt();
    final endTs = (session?['end_ts'] as num?)?.toInt();
    if (startTs != null && endTs != null && endTs > startTs) {
      final lo = (startTs - _routeClipPadSec) * 1000;
      final hi = (endTs + _routeClipPadSec) * 1000;
      final clipped = [
        for (final p in points)
          if (p.tsMs >= lo && p.tsMs <= hi) p,
      ];
      // Fewer than two points is not a route — better no map than a single
      // orphaned pin and a zero-length "distance".
      if (clipped.length < 2) return null;
      points = clipped;
    }

    // 1 Hz HR over the route's own time window (± a small pad), for zone
    // colouring and per-split average HR.
    final fromTs = (points.first.tsMs ~/ 1000) - 5;
    final toTs = (points.last.tsMs ~/ 1000) + 5;
    final hrRows = await LocalDb.hrSamplesInRange(fromTs, toTs);
    final hr = [
      for (final r in hrRows)
        HrSample(
          tsMs: (r['rec_ts'] as num).toInt() * 1000,
          hr: (r['hr'] as num).toInt(),
        ),
    ];

    return WorkoutRoute(
      sessionId: id,
      points: points,
      hr: hr,
      distanceMeters: rmath.totalDistanceMeters(points),
      movingSec: rmath.movingSeconds(points),
      splitsKm:
          rmath.computeSplits(points, hr, unitMeters: rmath.kMetersPerKm),
      splitsMi:
          rmath.computeSplits(points, hr, unitMeters: rmath.kMetersPerMile),
    );
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
    // A mean cycle shorter than the 10-day ovulation floor makes the clamp
    // bounds cross — `clamp(10, 8)` THROWS ArgumentError (lowerLimit >
    // upperLimit), and it threw straight out of getCycle() so the entire cycle
    // screen errored instead of degrading. Two logged `start` markers 8 days
    // apart is enough: a mis-tap the user then corrected, or a genuinely short
    // cycle. Below the floor there is no defensible ovulation day to place, so
    // be honest — leave `phase: 'unknown'` and publish no fertile window
    // (predictedNext / cycleDay / the biometric overlay still render).
    final ovDay = (meanLength == null || meanLength.round() < 10)
        ? null
        : (meanLength - 14).round().clamp(10, meanLength.round());
    if (ovDay != null && cycleDay != null && lastStart != null) {
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

  // ── live HRV spot-check (on-device decode + HRV) ────────────────────────────

  @override
  Future<Map<String, dynamic>> spotCheck(List<String> records) async {
    // Decode + HRV run OFF the UI isolate. The spot-check buffer grows over the
    // multi-minute measurement, so decoding every frame + RR correction + HRV on
    // the main isolate was real per-tick work that hung the UI on slower phones.
    return Isolate.run(() => _spotCheckCompute(records));
  }

  @override
  Future<Map<String, dynamic>> breathingCoherence(
    List<String> records, {
    double? pacedHz,
  }) async {
    // Offloaded: cardiac coherence is a 400-point Lomb-Scargle PSD recomputed
    // over the FULL (growing) session buffer every 20 s — pure sin/cos work that
    // was running on the UI isolate and is a confirmed foreground-hang source.
    return Isolate.run(() => _breathingCoherenceCompute(records, pacedHz));
  }

  // ── small series helpers ─────────────────────────────────────────────────────

  Future<double?> _seriesMean(String key) async {
    final vs = await LocalDb.trailingSeriesValues(key, 28);
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

/// The /today `stress` block from a day bundle — the pipeline's Baevsky block,
/// verbatim, with NO fallback substitute when SI couldn't compute a score.
/// (Previously mirrored getDayStress's `100 - readiness` fallback; removed for
/// the same reason — it fabricated a stress-looking number out of an unrelated
/// metric, violating the never-impute rule.) Pure + public so the Today seam
/// is unit-testable. Returns null when there is neither a stress block nor any
/// score (the tile then renders the honest "—"); [readiness] is now unused but
/// kept as a parameter for call-site compatibility.
Map<String, dynamic>? stressSummaryForToday(
  Map<String, dynamic> bundle,
  num? readiness,
) {
  final blk = bundle['stress'] is Map
      ? (bundle['stress'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return blk.isEmpty ? null : blk;
}

// ── Live spot-check / breathing compute (run under Isolate.run, off the UI) ────
// Top-level (no `this` capture) + only file-scoped `proto`/`ana` top-level
// functions + a List<String> of hex frames in, a plain Map out — all sendable.

Map<String, dynamic> _spotCheckCompute(List<String> records) {
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
  final meanHr = hrs.isEmpty ? null : hrs.reduce((a, b) => a + b) / hrs.length;
  return {
    'ok': true,
    'rmssd': hrv.value!.rmssd?.round(),
    'sdnn': hrv.value!.sdnn?.round(),
    'mean_hr': meanHr?.round(),
    'n_beats': cleaned.nn.length,
    'confidence': hrv.confidence,
  };
}

Map<String, dynamic> _breathingCoherenceCompute(
  List<String> records,
  double? pacedHz,
) {
  // Decode RR from the live RR-bearing frames (0x28 / R10) — same seam
  // spotCheck uses — then run McCraty & Zayas 2014 cardiac coherence.
  final rrMs = <double>[];
  for (final hex in records) {
    final rr = proto.realtimeRr(hex);
    if (rr != null) {
      for (final v in rr.rrMs) {
        if (v > 0) rrMs.add(v.toDouble());
      }
    }
  }
  if (rrMs.length < 20) {
    return {'ok': false, 'n_beats': rrMs.length};
  }
  final cleaned = ana.correctRr(rrMs);
  final m = ana.cardiacCoherence(cleaned.nn, cleaned.nnTimesMs, pacedHz: pacedHz);
  if (!m.present) {
    return {'ok': false, 'n_beats': cleaned.nn.length, 'note': m.note};
  }
  return {
    'ok': true,
    'ratio': m.value!.ratio,
    'score': m.value!.score.round(),
    'peak_hz': m.value!.peakHz,
    'n_beats': cleaned.nn.length,
    'confidence': m.confidence,
    'tier': m.tier,
    'note': m.note,
  };
}
