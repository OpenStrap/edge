// onehz_pipeline.dart — the PURE, isolate-safe per-day analytics pipeline (V2).
//
// `deriveDayBundle` is a top-level function with NO DB / IO / Flutter binding
// dependency, so it runs cleanly under `Isolate.run(...)` off the UI isolate.
//
// V2 INVARIANTS enforced here:
//   * SINGLE-SOURCE SLEEP. The day already carries ONE `SleepSegmentation`
//     (from analytics' segmentSleep, computed by the coordinator). Every sleep
//     figure — TST/WASO/efficiency/nrem/rem/wake/hypnogram — comes from THAT one
//     result. We never re-detect sleep or run a second estimator.
//   * WINDOWS ARE FIRST-CLASS. HRV/RHR/recovery run over the SLEEP window only
//     (the fix for the ~166 ms whole-day RMSSD bug). Strain (TRIMP) runs over the
//     WAKE span. Resp/ODI/CPC run over sleep. No metric runs over "the whole
//     capture".
//   * HONEST BY TYPE. Every output keeps the {value,confidence,tier,inputs_used}
//     Metric envelope; absent input → null/"—", never fabricated.
//
// CROSSING THE ISOLATE BOUNDARY (copied, not shared):
//   IN  : a serialized `DayBundleInput` (the day's sliced 1 Hz substrate arrays +
//         the precomputed sleep segmentation + the profile + baseline history).
//   OUT : Map<String,dynamic> (plain JSON) — the full derived bundle, envelopes +
//         the curve series the UI needs + indexed scalars. Survives jsonEncode.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

const MetricCfg _skinTempAdcCfg = MetricCfg(
  minVal: 1.0,
  maxVal: 65535.0,
  floorSpread: 25.0,
  halfLifeB: 14.0,
  halfLifeS: 21.0,
);

/// Serializable input to the isolate: one physiological day's decoded 1 Hz
/// substrate (the day slice), the PRECOMPUTED single-source sleep segmentation,
/// the profile, and trailing baseline history for the readiness pass.
///
/// `*Win` arrays are the day-slice arrays restricted to the SLEEP window — the
/// coordinator slices once so the isolate input is small and the windowing is
/// done in exactly one place. `sleepJson` is the SleepSegmentation.toJson() (the
/// single source of TST/WASO/stages/hypnogram).
class DayBundleInput {
  final String date; // wake-to-wake label (coordinator-supplied)

  // ── DAY span (wake → next wake) 1 Hz substrate ────────────────────────────
  final List<int> dayTsSec;
  final List<int> dayHr; // 0 = off-skin
  // Day-span RR (beat-end epoch ms + interval ms) for the 24/7 irregular-rhythm
  // screen. Sparse (0–4 beats/s); empty when no RR was captured.
  final List<double> dayRrTsMs;
  final List<double> dayRrMs;

  // ── SLEEP window 1 Hz substrate (the window from segmentSleep) ────────────
  final List<int> sleepTsSec;
  final List<int> sleepHr;
  final List<double> sleepRrTsMs;
  final List<double> sleepRrMs;
  final List<int> sleepSpo2Red;
  final List<int> sleepSpo2Ir;
  final List<int> sleepSkinTemp;

  // ── the SINGLE-SOURCE sleep segmentation (JSON of SleepSegmentation) ──────
  final Map<String, dynamic> sleepJson; // {window,tst_sec,…,confidence}
  final List<String> hypnoStages; // per-second 'wake'|'nrem'|'rem' over window
  final int sleepOnsetSec; // window onset (epoch sec), 0 if no sleep
  final int sleepOffsetSec; // window offset (epoch sec), 0 if no sleep

  // ── profile + trailing baseline history ───────────────────────────────────
  final Map<String, dynamic> profile;
  final List<double> lnRmssdHistory;
  final List<double> rhrHistory;
  final List<double> respHistory;

  /// Trailing robust nocturnal RMSSD means (ms) — the SAME `rmssd` series the
  /// engine writes to metric_series (NREM-restricted, median-of-5-min). Used as
  /// the history for the EWMA hrv baseline so its center and today's value are the
  /// SAME metric (was previously reconstructed from ln(whole-window RMSSD), a
  /// definition mismatch that made the z spuriously large).
  final List<double> rmssdHistory;

  /// Trailing RAW nightly skin-temp ADC means (NOT z-scores). The personal
  /// baseline for the relative skin-temp deviation: today's mean sleep-window
  /// ADC is z-scored against THIS series. Must be raw ADC means so the unit
  /// matches today's raw mean (the old z-vs-z series was a unit mismatch bug).
  final List<double> skinTempAdcHistory;

  // ── day confidence + flags (e.g. LOW_CONFIDENCE_RECOVERY for fallback days) ─
  final double dayConfidence;
  final List<String> dayFlags;

  const DayBundleInput({
    required this.date,
    required this.dayTsSec,
    required this.dayHr,
    this.dayRrTsMs = const [],
    this.dayRrMs = const [],
    required this.sleepTsSec,
    required this.sleepHr,
    required this.sleepRrTsMs,
    required this.sleepRrMs,
    required this.sleepSpo2Red,
    required this.sleepSpo2Ir,
    required this.sleepSkinTemp,
    required this.sleepJson,
    required this.hypnoStages,
    required this.sleepOnsetSec,
    required this.sleepOffsetSec,
    required this.profile,
    this.lnRmssdHistory = const [],
    this.rhrHistory = const [],
    this.respHistory = const [],
    this.rmssdHistory = const [],
    this.skinTempAdcHistory = const [],
    this.dayConfidence = 0,
    this.dayFlags = const [],
  });

  Map<String, dynamic> toJson() => {
    'date': date,
    'day_ts': dayTsSec,
    'day_hr': dayHr,
    'day_rr_ts_ms': dayRrTsMs,
    'day_rr_ms': dayRrMs,
    'sleep_ts': sleepTsSec,
    'sleep_hr': sleepHr,
    'sleep_rr_ts_ms': sleepRrTsMs,
    'sleep_rr_ms': sleepRrMs,
    'sleep_spo2_red': sleepSpo2Red,
    'sleep_spo2_ir': sleepSpo2Ir,
    'sleep_skin_temp': sleepSkinTemp,
    'sleep_json': sleepJson,
    'hypno_stages': hypnoStages,
    'sleep_onset_sec': sleepOnsetSec,
    'sleep_offset_sec': sleepOffsetSec,
    'profile': profile,
    'ln_rmssd_history': lnRmssdHistory,
    'rhr_history': rhrHistory,
    'resp_history': respHistory,
    'rmssd_history': rmssdHistory,
    'skin_temp_adc_history': skinTempAdcHistory,
    'day_confidence': dayConfidence,
    'day_flags': dayFlags,
  };

  static DayBundleInput fromJson(Map<String, dynamic> m) {
    List<int> ints(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    List<double> dbls(String k) => ((m[k] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList();
    List<String> strs(String k) =>
        ((m[k] as List?) ?? const []).map((e) => e.toString()).toList();
    return DayBundleInput(
      date: m['date'] as String,
      dayTsSec: ints('day_ts'),
      dayHr: ints('day_hr'),
      dayRrTsMs: dbls('day_rr_ts_ms'),
      dayRrMs: dbls('day_rr_ms'),
      sleepTsSec: ints('sleep_ts'),
      sleepHr: ints('sleep_hr'),
      sleepRrTsMs: dbls('sleep_rr_ts_ms'),
      sleepRrMs: dbls('sleep_rr_ms'),
      sleepSpo2Red: ints('sleep_spo2_red'),
      sleepSpo2Ir: ints('sleep_spo2_ir'),
      sleepSkinTemp: ints('sleep_skin_temp'),
      sleepJson: ((m['sleep_json'] as Map?) ?? const {})
          .cast<String, dynamic>(),
      hypnoStages: strs('hypno_stages'),
      sleepOnsetSec: (m['sleep_onset_sec'] as num?)?.toInt() ?? 0,
      sleepOffsetSec: (m['sleep_offset_sec'] as num?)?.toInt() ?? 0,
      profile: ((m['profile'] as Map?) ?? const {}).cast<String, dynamic>(),
      lnRmssdHistory: dbls('ln_rmssd_history'),
      rhrHistory: dbls('rhr_history'),
      respHistory: dbls('resp_history'),
      rmssdHistory: dbls('rmssd_history'),
      skinTempAdcHistory: dbls('skin_temp_adc_history'),
      dayConfidence: (m['day_confidence'] as num?)?.toDouble() ?? 0,
      dayFlags: strs('day_flags'),
    );
  }
}

/// THE ISOLATE ENTRY POINT.
///
/// Pure: takes the serialized [DayBundleInput] map, returns a plain JSON map (the
/// full derived bundle). Call directly + synchronously in tests, or via
/// `Isolate.run(() => deriveDayBundle(input))` in production.
Map<String, dynamic> deriveDayBundle(Map<String, dynamic> inputJson) {
  final d = DayBundleInput.fromJson(inputJson);

  // ── HR over the DAY (for the curve, strain zones, dip day-side) ───────────
  final dayHr = [for (final h in d.dayHr) h.toDouble()];
  final dayHrValid = dayHr.where((h) => h > 0).toList();

  // ── WORN minutes — distinct wall-clock minutes that have ANY record ────────
  // Wear is RECORD presence, NOT valid HR. The band logs 1 Hz to flash only
  // while on-wrist (off-wrist it stops and emits WRIST_OFF), so a record in a
  // minute means the band was worn that minute. We deliberately do NOT gate on
  // HR>0: a valid HR needs a still wrist + good optical contact, which happens
  // mostly during SLEEP, so an HR-valid count collapses "worn" to ~the sleep
  // duration (the 24 h-worn-shows-7 h bug). Bucketing by real epoch-second
  // timestamp (not array index) is also gap-safe.
  final wornMinuteBuckets = <int>{};
  for (final ts in d.dayTsSec) {
    wornMinuteBuckets.add(ts ~/ 60);
  }
  final wornMin = wornMinuteBuckets.length;

  // ── HR over the SLEEP WINDOW (RHR / dip night-side) ────────────────────────
  final sleepHr = [for (final h in d.sleepHr) h.toDouble()];

  // ── RR over the SLEEP WINDOW → cleaned NN → HRV (the V2 fix) ───────────────
  // HRV/RHR are rest/sleep-only per the catalog. Running correctRr+hrvTime over
  // the SLEEP RR (not the whole day) is what brings RMSSD back to physiological
  // tens-of-ms instead of the whole-day ~166 ms inflated value.
  final corrected = correctRr(d.sleepRrMs);
  final nn = corrected.nn;
  final nnTimes = corrected.nnTimesMs;
  final artifactFraction = (1.0 - corrected.cleanFraction).clamp(0.0, 1.0);

  final hasSleep = (d.sleepJson['tst_sec']) != null;

  // ── SLEEP: everything from the SINGLE-SOURCE segmentation ──────────────────
  final sleepWinJson = (d.sleepJson['window'] as Map?)?.cast<String, dynamic>();
  final tstSec = (d.sleepJson['tst_sec'] as num?)?.toInt();
  final wasoSec = (d.sleepJson['waso_sec'] as num?)?.toInt();
  final inBedSec = (d.sleepJson['in_bed_sec'] as num?)?.toInt();
  final effPct = (d.sleepJson['efficiency_pct'] as num?)?.toDouble();
  final nremSec = (d.sleepJson['nrem_sec'] as num?)?.toInt();
  // 4-class split of NREM into Light/Deep (Deep = LOW CONFIDENCE overlay).
  final lightSec = (d.sleepJson['light_sec'] as num?)?.toInt();
  final deepSec = (d.sleepJson['deep_sec'] as num?)?.toInt();
  final remSec = (d.sleepJson['rem_sec'] as num?)?.toInt();
  final wakeSec = (d.sleepJson['wake_sec'] as num?)?.toInt();
  final sleepConf = (d.sleepJson['confidence'] as num?)?.toDouble() ?? 0;

  // ── CLINICAL (sleep-windowed) ──────────────────────────────────────────────
  // Whole-window time-domain HRV is kept for SDNN / detail rows only. The
  // nightly headline HRV is the mean of 5-min cleaned-window RMSSDs across the
  // detected sleep session, not one RMSSD over the whole night's NN stream.
  final hrvT = hrvTime(nn, nnTimesMs: nnTimes);
  // Keep the robust estimator as a secondary detail only; the canonical nightly
  // RMSSD follows the sleep-session windowed formulation.
  final nremMask = _nremMaskAlignedToNn(d, nnTimes, d.sleepRrTsMs);
  final robustRmssd = nocturnalRmssd(nn, nnTimes, stageMaskPerSec: nremMask);
  final sleepSessionRmssdMetric = sleepSessionWindowedRmssd(
    d.sleepRrMs,
    d.sleepRrTsMs,
    startSec: d.sleepOnsetSec,
    endSec: d.sleepOffsetSec,
  );
  final sleepSessionRmssd = sleepSessionRmssdMetric.present
      ? sleepSessionRmssdMetric.value
      : null;
  final hrvF = nn.length >= 20
      ? hrvFreq(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<HrvFreq>.absent(
          tier: Tier.high,
          inputs_used: ['rr_cleaned'],
        );
  // Nocturnal RHR over the SLEEP HR (fallback to day-valid only if no sleep HR).
  final rhr = nocturnalRhr(sleepHr.isNotEmpty ? sleepHr : dayHrValid);
  // HR dip: day-side = waking HR outside the sleep window; night-side = sleep HR.
  final dayOnly = _dayHrOutsideSleep(d);
  final dip = hrDip(dayOnly, sleepHr);
  final dc = decelerationCapacity(nn);
  final ac = accelerationCapacity(nn);
  // Baevsky Stress Index over the sleep NN — resting autonomic tension (a
  // transparent RR-histogram metric; no ML). Daily resting-stress indicator.
  final stress = baevskyStressIndex(nn);

  // ── RESPIRATION (sleep-windowed) ───────────────────────────────────────────
  final resp = nn.length >= 30
      ? rsaRespRate(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<RespEstimate>.absent(
          tier: Tier.estimate,
          inputs_used: ['rr_cleaned'],
        );
  final cvhr = nn.length >= 60
      ? cvhrApneaScreen(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<CvhrResult>.absent(
          tier: Tier.estimate,
          inputs_used: ['rr_cleaned'],
        );
  final cpc = nn.length >= 60
      ? cardiopulmonaryCoupling(nn, nnTimes)
      : const Metric<CpcResult>.absent(
          tier: Tier.high,
          inputs_used: ['rr_cleaned'],
        );

  // ── 24/7 IRREGULAR-RHYTHM SCREEN (day-span RR; not a diagnosis) ────────────
  // Runs over the WHOLE-DAY cleaned RR (not just sleep) so an arrhythmia screen
  // isn't limited to the sleep window. Hard-gated on beat count + artifact inside
  // irregularBeatScreen; returns absent on a thin/noisy day.
  final dayCorrected = correctRr(d.dayRrMs);
  final irregular24h = irregularBeatScreen(
    dayCorrected.nn,
    artifactFraction: (1.0 - dayCorrected.cleanFraction).clamp(0.0, 1.0),
  );

  // ── BREATHING-RATE VARIABILITY (per-window RSA over the sleep NN) ──────────
  // Window the cleaned sleep NN into ~30-min bins, take each bin's RSA resp rate,
  // then BRV = dispersion + Theil-Sen trend of those per-window rates.
  final respWindows = _respPerWindow(nn, nnTimes);
  final brv = respWindows.length >= 3
      ? breathingRateVariability(respWindows)
      : const Metric<BrvResult>.absent(
          tier: Tier.estimate,
          inputs_used: ['resp_rate_series'],
        );

  // Relative ODI over the SLEEP window's spo2 channels (desaturation screen).
  final odiRed = [for (final v in d.sleepSpo2Red) v.toDouble()];
  final odiIr = [for (final v in d.sleepSpo2Ir) v.toDouble()];
  final odiTs = [for (final t in d.sleepTsSec) t.toDouble()];
  final odi =
      (odiRed.length == odiIr.length &&
          odiRed.length == odiTs.length &&
          odiRed.length >= 60)
      ? relativeOdi(odiRed, odiIr, odiTs)
      : const Metric<RelativeOdiResult>.absent(
          tier: Tier.relative,
          inputs_used: ['spo2_red_raw', 'spo2_ir_raw'],
        );

  // ── WELLNESS: relative skin-temp deviation (z) vs personal baseline ────────
  // STEP 1 — today's RAW mean sleep-window skin-temp ADC. ALWAYS computable when
  // there's sleep + temp data; stored EVERY day to build the baseline series so
  // z starts computing once ≥3 prior days exist (honest bootstrap: first ~3 days
  // legitimately read "—", then it works).
  final tempValid = d.sleepSkinTemp
      .where((v) => v > 0)
      .map((v) => v.toDouble())
      .toList();
  final double? skinTempAdc = tempValid.length >= 60 ? _mean(tempValid) : null;
  // STEP 2 — z-score today's RAW mean against the RAW-ADC baseline history (NOT
  // the previously-computed z-scores; that unit mismatch was the bug). Gated on
  // ≥3 prior raw means.
  double? skinTempZ;
  if (skinTempAdc != null && d.skinTempAdcHistory.length >= 3) {
    final base = _mean(d.skinTempAdcHistory)!;
    final sd = _stddev(d.skinTempAdcHistory);
    if (sd != null && sd > 0) skinTempZ = (skinTempAdc - base) / sd;
  }

  // ── READINESS (the canonical composite, baseline-dependent) ───────────────
  final lnToday = (sleepSessionRmssd != null && sleepSessionRmssd > 0)
      ? math.log(sleepSessionRmssd)
      : null;
  final rhrToday = rhr.present ? rhr.value!.low30Mean : null;
  final respToday = resp.present ? resp.value!.brpm : null;
  final composite = readinessComposite([
    hrvInput(lnToday, d.lnRmssdHistory),
    rhrInput(rhrToday, d.rhrHistory),
    respInput(respToday, d.respHistory),
    // Feed the RAW ADC mean + the RAW-ADC baseline so the composite computes its
    // own oriented robust-z internally (consistent with the other inputs, which
    // pass raw values + their raw baselines).
    tempInput(skinTempAdc, d.skinTempAdcHistory),
  ]);
  // Plews lnRMSSD readiness over the trailing history INCLUDING today.
  final lnHist = [...d.lnRmssdHistory, ?lnToday];
  final lnReadiness = lnHist.length >= 4
      ? readinessLnRmssd(lnHist)
      : const Metric<ReadinessLnRmssd>.absent(
          tier: Tier.high,
          inputs_used: ['ln_rmssd_history'],
        );

  // ── STRAIN: Banister TRIMP over the WAKE span (per-minute day HR) ──────────
  final prof = d.profile;
  final age = (prof['age'] as num?)?.toDouble();
  final sex = (prof['sex'] as String?)?.toLowerCase();
  final hrMax = age == null ? null : 208 - 0.7 * age; // Tanaka
  final rhrForTrimp = rhrToday ?? (prof['resting_hr'] as num?)?.toDouble();
  final weightKg = (prof['weight_kg'] as num?)?.toDouble();
  final heightCm = (prof['height_cm'] as num?)?.toDouble();
  // Wake-span per-minute mean HR = the day minus the sleep window (shared by
  // TRIMP, HR zones, and calories so all three see the same wake series).
  final wakeHr = _perMinuteWakeSeries(d);
  final perMin = [for (final p in wakeHr) p.hr];
  Metric<double> trimp = const Metric<double>.absent(
    tier: Tier.estimate,
    inputs_used: ['hr_1hz', 'profile'],
  );
  Map<String, int> hrZones = const {};
  double? caloriesKcal;
  if (hrMax != null && perMin.isNotEmpty) {
    if (rhrForTrimp != null && sex != null && dayHrValid.isNotEmpty) {
      trimp = banisterTrimp(
        perMin,
        restingHr: rhrForTrimp,
        maxHr: hrMax,
        sex: sex == 'f' ? Sex.female : Sex.male,
      );
    }
    hrZones = _wakeZoneMinutesFromSeries(wakeHr, hrMax);
    if (age != null && sex != null && weightKg != null) {
      caloriesKcal = Calories.dailyEnergy(
        perMin,
        profile: WorkoutUserProfile(
          weightKg: weightKg,
          heightCm: heightCm ?? 170.0,
          age: age,
          sex: sex == 'f' ? 'female' : (sex == 'm' ? 'male' : 'nonbinary'),
        ),
        hrmax: hrMax,
      ).active; // active-energy component (Keytel surplus over basal)
    }
  }

  // HEADLINE STRAIN = 0–21 log-squash of raw TRIMP; raw TRIMP kept as a detail.
  final rawTrimp = trimp.present ? trimp.value : null;
  final strainMetric = strainScoreMetric(rawTrimp);

  // ── curve series for the UI ────────────────────────────────────────────────
  final hrCurve = _downsampleHr(d.dayTsSec, d.dayHr);
  final hypnogram = _hypnogramSegments(d);
  final hrvTimeline = _hrvTimeline(nn, nnTimes);
  final strainCurve = _strainCurve(
    wakeHr,
    restingHr: rhrForTrimp,
    maxHr: hrMax,
    sex: sex,
  );
  final zoneTimeline = hrMax == null
      ? const <Map<String, num>>[]
      : _zoneTimeline(wakeHr, hrMax);

  // ── ASSEMBLE the bundle (envelopes are plain JSON) ─────────────────────────
  // ── HRV stability (CV = SDNN/meanNN) + Poincaré irregular-beat screen ──────
  // Both over the sleep NN. CV is a normalized variability stability index;
  // SD1/SD2 are the Poincaré descriptors; a high SD1/SD2 ratio flags erratic
  // beat-to-beat timing (a SCREEN, not a diagnosis).
  double? hrvCv, sd1, sd2;
  var irregularFlag = false;
  var irregularConf = 0.0;
  if (nn.length >= 20) {
    final meanNn = nn.reduce((a, b) => a + b) / nn.length;
    final sdnn = hrvT.present ? hrvT.value!.sdnn : null;
    if (sdnn != null && meanNn > 0) hrvCv = sdnn / meanNn * 100;
    final diffs = [for (var i = 1; i < nn.length; i++) nn[i] - nn[i - 1]];
    final sdsd = _stddev(diffs);
    if (sdsd != null && sdnn != null) {
      sd1 = sdsd / math.sqrt2;
      final v = 2 * sdnn * sdnn - sd1 * sd1;
      sd2 = v > 0 ? math.sqrt(v) : 0.0;
      irregularConf = 0.5;
      // CONSERVATIVE: a healthy Poincaré SD1/SD2 sits ~0.2–0.5 (RSA pushes it
      // toward 0.5); erratic/AF-like rhythms scatter the plot toward a blob
      // (ratio → ~1). Flag only clearly-abnormal ≥0.7 to avoid false alarms —
      // this is a SCREEN, not a diagnosis.
      irregularFlag = sd2 > 0 && (sd1 / sd2) >= 0.70;
    }
  }

  final clinical = <String, dynamic>{
    'hrv_time': hrvT.toJson((v) => v.toJson()),
    // HRV stability (CV %) + Poincaré irregular-beat screen.
    'cv': hrvCv == null ? null : _round(hrvCv, 1),
    'irregular': <String, dynamic>{
      'sd1': sd1 == null ? null : _round(sd1, 1),
      'sd2': sd2 == null ? null : _round(sd2, 1),
      'flag': irregularFlag,
      'confidence': irregularConf,
    },
    // 24/7 irregular-rhythm SCREEN over the whole-day RR (the headline screen
    // that drives the opt-in notification). Sleep-only `irregular` kept above.
    'irregular_24h': irregular24h.toJson((v) => v.toJson()),
    // Breathing-rate variability trend (within-user only).
    'brv': brv.toJson((v) => v.toJson()),
    // Canonical nightly HRV, matching the sleep-session windowed RMSSD
    // aggregation over the chosen sleep session. The robust estimator is
    // retained alongside it as a secondary detail for comparison/debugging.
    'rmssd_sleep_session': {
      'value': sleepSessionRmssd == null ? '—' : _round(sleepSessionRmssd, 1),
      'confidence': sleepSessionRmssdMetric.present
          ? _round(sleepSessionRmssdMetric.confidence, 4)
          : 0,
      'tier': Tier.high,
      'inputs_used': const ['rr_sleep_window'],
      'note': sleepSessionRmssdMetric.note,
    },
    'rmssd_nocturnal': robustRmssd.toJson(),
    'hrv_freq': hrvF.toJson((v) => v.toJson()),
    'resting_hr': rhr.toJson((v) => v.toJson()),
    'hr_dip': dip.toJson((v) => v.toJson()),
    'prsa_dc': dc.toJson((v) => v.toJson()),
    'prsa_ac': ac.toJson((v) => v.toJson()),
    'readiness_lnrmssd': lnReadiness.toJson((v) => v.toJson()),
    'readiness_composite': composite.toJson((v) => v.toJson()),
    // Headline 0–21 strain envelope; raw Banister TRIMP kept as `trimp`.
    'strain': strainMetric.toJson(),
    'trimp': trimp.toJson(),
  };

  // Sleep section — ALL fields from the single SleepSegmentation. We re-emit the
  // serve-seam-expected envelopes (window/accounting/stager .value sub-maps) but
  // every figure traces to the one segmentation result (no second estimator).
  final sleep = <String, dynamic>{
    'window': _envelope(
      hasSleep ? sleepWinJson : null,
      confidence: sleepConf,
      tier: Tier.high,
      inputs: const ['accel_1hz', 'hr_1hz'],
    ),
    'accounting': _envelope(
      hasSleep
          ? {
              'tst_sec': tstSec,
              'waso_sec': wasoSec,
              'in_bed_sec': inBedSec,
              'efficiency_pct': effPct,
              'nrem_sec': nremSec,
              // 4-class split: Light + Deep == NREM. Deep is LOW CONFIDENCE.
              'light_sec': lightSec,
              'deep_sec': deepSec,
              'rem_sec': remSec,
              'wake_sec': wakeSec,
              'deep_low_confidence': true,
            }
          : null,
      confidence: sleepConf,
      tier: Tier.estimate,
      inputs: const ['sleep_stages'],
    ),
    'stager': _envelope(
      hasSleep
          ? {
              'wake_pct': tstSec == null || inBedSec == null || inBedSec == 0
                  ? null
                  : 100.0 * (wakeSec ?? 0) / inBedSec,
              'nrem_pct': tstSec == null || tstSec == 0
                  ? null
                  : 100.0 * (nremSec ?? 0) / tstSec,
              'rem_pct': tstSec == null || tstSec == 0
                  ? null
                  : 100.0 * (remSec ?? 0) / tstSec,
              'epoch_sec': 1,
              'epochs': d.hypnoStages.length,
            }
          : null,
      confidence: sleepConf,
      tier: Tier.estimate,
      inputs: const ['hr_1hz', 'immobility'],
    ),
    'cpc': cpc.toJson((v) => v.toJson()),
  };

  final respiration = <String, dynamic>{
    'rsa': resp.toJson((v) => v.toJson()),
    'cvhr_apnea': cvhr.toJson((v) => v.toJson()),
    'odi': odi.toJson((v) => v.toJson()),
  };

  final wellness = <String, dynamic>{
    'skin_temp': {
      'value': skinTempZ == null ? '—' : _round(skinTempZ, 4),
      'confidence': skinTempZ == null ? 0 : 0.5,
      'tier': Tier.relative,
      'inputs_used': const ['skin_temp_raw'],
      'note':
          'relative deviation (z) vs your baseline; raw ADC, no absolute °C',
    },
  };

  // Indexed scalars (also surfaced to metric_series by the engine).
  final rhrScalar = rhr.present ? rhr.value!.low30Mean : null;
  // HEADLINE RMSSD = mean of 5-min cleaned-window RMSSDs across the detected
  // sleep session. Fall back to the robust estimator, then the whole-window
  // RMSSD only when the canonical sleep-session value is absent.
  final rmssdScalar =
      sleepSessionRmssd ??
      (robustRmssd.present
          ? robustRmssd.value
          : ((hrvT.present && hrvT.value!.rmssd != null)
                ? hrvT.value!.rmssd
                : null));
  // Whole-window RMSSD kept available as a secondary detail (NOT the headline).
  final rmssdWholeScalar = (hrvT.present && hrvT.value!.rmssd != null)
      ? hrvT.value!.rmssd
      : null;
  final readinessScalar = composite.present ? composite.value!.score : null;
  final strainScalar = strainMetric.present ? strainMetric.value : null;

  // ── STRESS: Baevsky SI → a transparent 0–100 score (log-mapped over the
  //    plausible resting SI range [20, 600]). Resting autonomic tension; the
  //    stress screen reads this {score, si, lf_hf, rmssd, level} block directly.
  final si = stress.present ? stress.value!.si : null;
  final lfhf = hrvF.present ? hrvF.value!.lfhf : null;
  double? stressScore;
  if (si != null && si > 0) {
    final lo = math.log(20), hi = math.log(600);
    stressScore = (100 * (math.log(si) - lo) / (hi - lo)).clamp(0.0, 100.0);
  }
  final stressBlock = <String, dynamic>{
    'value': stressScore == null ? '—' : _round(stressScore, 1),
    'score': stressScore == null ? null : _round(stressScore, 1),
    'si': si == null ? null : _round(si, 2),
    'level': stress.present ? stress.value!.level : null,
    'lf_hf': lfhf == null ? null : _round(lfhf, 3),
    'rmssd': rmssdScalar == null ? null : _round(rmssdScalar, 1),
    'confidence': stress.present ? _round(stress.confidence, 4) : 0,
    'tier': Tier.estimate,
    'inputs_used': const ['rr_cleaned'],
    'note': 'Baevsky Stress Index → 0–100; resting autonomic tension (PRV).',
  };

  // ── SpO₂ (RELATIVE only): overnight oxygen-dip screening from the red/IR ADC
  //    channels. Never absolute %SpO₂; this is a relative overnight signal.
  final odiPerHour = odi.present ? odi.value!.odiPerHour : null;
  final dipCount = odi.present ? odi.value!.dipCount : null;
  final meanDipPct = odi.present ? odi.value!.meanDipPct : null;
  final maxDipPct = odi.present ? odi.value!.maxDipPct : null;
  final longestDipSec = odi.present ? odi.value!.longestDipSec : null;
  final burdenPct = odi.present ? odi.value!.burdenPct : null;
  final signalCoverage = odi.present ? odi.value!.signalCoverage : null;
  final trustedCoverage = odi.present ? odi.value!.trustedCoverage : null;
  final rejectCounts = odi.present ? odi.value!.rejectCounts : null;
  final severityCounts = odi.present ? odi.value!.severityCounts : null;
  final spo2Block = <String, dynamic>{
    'value': odiPerHour == null ? '—' : _round(odiPerHour, 2),
    'odi_per_hour': odiPerHour == null ? null : _round(odiPerHour, 2),
    'dip_count': dipCount,
    'mean_dip_pct': meanDipPct == null ? null : _round(meanDipPct, 2),
    'max_dip_pct': maxDipPct == null ? null : _round(maxDipPct, 2),
    'longest_dip_sec': longestDipSec,
    'burden_pct': burdenPct == null ? null : _round(burdenPct, 2),
    'signal_coverage': signalCoverage == null
        ? null
        : _round(signalCoverage, 4),
    'trusted_coverage': trustedCoverage == null
        ? null
        : _round(trustedCoverage, 4),
    'reject_counts': rejectCounts,
    'severity_counts': severityCounts,
    'confidence': odi.present ? _round(odi.confidence, 4) : 0,
    'tier': Tier.relative,
    'inputs_used': const ['spo2_red_raw', 'spo2_ir_raw'],
    'note':
        'relative overnight oxygen-dip screen (dips/h); no absolute %SpO₂ from this band',
  };

  // ── NOCTURNAL detail: sleeping-HR nadir + waking HR. Both computable today
  //    with NO baseline; the "vs baseline" comparison is added at the seam from
  //    the rhr history series.
  final nadir = rhr.present ? rhr.value!.p1 : null;
  final wakingHr = dip.present ? dip.value!.dayMean : null;
  // Nadir INSTANT: epoch-second of the lowest valid sleeping-HR second, so the
  // nocturnal card can render "@ HH:MM" instead of "@ -". From the sleep-window
  // HR series (parallel to sleepTsSec); null when no valid sleep HR.
  int? nadirTs;
  {
    var lo = 1 << 30;
    for (var i = 0; i < d.sleepHr.length && i < d.sleepTsSec.length; i++) {
      final h = d.sleepHr[i];
      if (h > 0 && h < lo) {
        lo = h;
        nadirTs = d.sleepTsSec[i];
      }
    }
  }

  // ── HR stats over the day's valid HR (for the strain detail hr {max,avg,min}).
  final hrStats = dayHrValid.isEmpty
      ? null
      : {
          'max': dayHrValid.reduce(math.max).round(),
          'min': dayHrValid.reduce(math.min).round(),
          'avg': _mean(dayHrValid)!.round(),
        };

  // ── SLEEP CYCLES from the per-second hypnogram (NREM→REM completions).
  // Sleep cycles — Rosenblum 2024 "fractal cycles", HRV-adapted: peak-to-peak of
  // the smoothed per-minute RMSSD series (REM peaks / NREM troughs), NOT
  // categorical REM-episode counting. Over the sleep window's RR.
  final cyc = detectSleepCycles(
    d.sleepRrMs,
    d.sleepRrTsMs,
    d.sleepOnsetSec,
    d.sleepOffsetSec,
  );
  sleep['cycles'] = [for (final c in cyc.cycles) c.toJson()];
  sleep['cycle_count'] = cyc.n;
  sleep['cycles_mean_min'] = cyc.meanDurationMin;
  // The continuous z-RMSSD wave the cycle GRAPH plots ({t: epochSec, z}).
  sleep['cycle_series'] = cyc.series;

  // ── PERSONAL BASELINES (Winsorized-EWMA) ───────────────────────────────────
  // Robust, recency-weighted personal centers + spread for the metrics whose
  // units match the engine configs (rhr bpm, hrv RMSSD ms, resp brpm). Fold the
  // trailing history + today's value, then z/delta/ratio + cold-start status.
  // ADDITIVE: a richer, calibration-honest baseline block the recovery/illness
  // layer can consume; the existing readiness/skin_temp_z headlines are untouched.
  // skin_temp is intentionally EXCLUDED — its series is raw ADC, not the °C the
  // skin_temp cfg bounds expect, so feed it through a raw-ADC cfg instead.
  Map<String, dynamic> baselineBlock(
    List<double> history,
    double? today,
    MetricCfg cfg,
  ) {
    final state = Baselines.foldHistory(<double?>[
      for (final v in history) v,
    ], cfg);
    final dev = today == null ? null : Baselines.deviation(today, state);
    return <String, dynamic>{
      ...state.toJson(),
      'value': today,
      'z': dev == null ? null : _round(dev.z, 3),
      'delta': dev == null ? null : _round(dev.delta, 3),
      'ratio': dev == null ? null : _round(dev.ratio, 4),
      'in_normal_range': dev?.inNormalRange,
    };
  }

  final baselines = <String, dynamic>{
    'resting_hr': baselineBlock(
      d.rhrHistory,
      rhrScalar,
      Baselines.restingHRCfg,
    ),
    'hrv': baselineBlock(d.rmssdHistory, rmssdScalar, Baselines.hrvCfg),
    'resp': baselineBlock(d.respHistory, respToday, Baselines.respCfg),
    'skin_temp': baselineBlock(
      d.skinTempAdcHistory,
      skinTempAdc,
      _skinTempAdcCfg,
    ),
  };

  return <String, dynamic>{
    'date': d.date,
    'day_confidence': _round(d.dayConfidence, 4),
    'flags': d.dayFlags,
    'clinical': clinical,
    'baselines': baselines,
    'sleep': sleep,
    'zones': hrZones,
    'max_hr_used': hrMax,
    'hr_stats': ?hrStats,
    'calories': caloriesKcal == null ? null : _round(caloriesKcal, 0),
    'respiration': respiration,
    'wellness': wellness,
    'stress': stressBlock,
    'spo2': spo2Block,
    'series': {
      'hr_curve': hrCurve,
      'strain_curve': strainCurve,
      'zone_timeline': zoneTimeline,
      'hrv_timeline': hrvTimeline,
      'hypnogram': hypnogram,
    },
    'coverage': {
      'hr_samples': d.dayHr.length,
      'hr_valid': dayHrValid.length,
      'rr_beats': d.sleepRrMs.length,
      'nn_clean': nn.length,
      'clean_fraction': _round(corrected.cleanFraction, 4),
      'sleep_seconds': inBedSec ?? 0,
    },
    'scalars': {
      'rhr': rhrScalar,
      // Headline RMSSD (robust nocturnal, NREM). Whole-window kept separately.
      'rmssd': rmssdScalar,
      'rmssd_whole': rmssdWholeScalar,
      'readiness': readinessScalar,
      // Headline 0–21 strain (the screens already expect a 0–21 scale); raw
      // Banister TRIMP stays under `trimp` as the secondary "training load".
      'strain': strainScalar,
      'max_hr_used': hrMax,
      'ln_rmssd': lnToday,
      'resp_rate': respToday,
      'skin_temp_z': skinTempZ,
      // RAW nightly skin-temp ADC mean — the personal BASELINE series for
      // skin_temp_z. ALWAYS present when there's sleep+temp data (even while z is
      // still null in the ≤3-day bootstrap), so the series fills and z starts
      // computing from ~day 4. This is the series _attachHistory must feed back.
      'skin_temp_adc': skinTempAdc,
      'sdnn': hrvT.present ? hrvT.value!.sdnn : null,
      'dip_pct': dip.present ? dip.value!.dipPct : null,
      'trimp': trimp.present ? trimp.value : null,
      'odi_per_hour': odi.present ? odi.value!.odiPerHour : null,
      'cpc_ratio': cpc.present ? cpc.value!.cpcRatio : null,
      // Stress score (0–100) + SI for trends; spo2 relative desaturation index.
      'stress': stressScore,
      'stress_si': si,
      'spo2': odiPerHour,
      // Active calories (Keytel) + nocturnal HR detail (nadir / waking HR).
      'calories': caloriesKcal == null ? null : _round(caloriesKcal, 0),
      'sleeping_hr_nadir': nadir,
      'sleeping_hr_nadir_ts': nadirTs?.toDouble(),
      'waking_hr': wakingHr,
      // Sleep-stage minutes + HRV freq/stability — surfaced as scalars so they
      // flow to metric_series and get day/week/month/3M trends.
      'rem_min': remSec == null ? null : (remSec / 60).roundToDouble(),
      'deep_min': deepSec == null ? null : (deepSec / 60).roundToDouble(),
      'light_min': lightSec == null ? null : (lightSec / 60).roundToDouble(),
      'tst_min': tstSec == null ? null : (tstSec / 60).roundToDouble(),
      'lf_hf': lfhf == null ? null : _round(lfhf, 3),
      'hrv_cv': hrvCv == null ? null : _round(hrvCv, 1),
      // 24/7 irregular-rhythm screen flag (1/0) → drives trend + notification.
      'irregular_rhythm_flag':
          irregular24h.present ? (irregular24h.value!.flag ? 1.0 : 0.0) : null,
      // Breathing-rate variability (CV) + Theil-Sen trend slope.
      'brv_cv': brv.present ? _round(brv.value!.cv, 4) : null,
      'brv_slope': brv.present && brv.value!.trendSlope != null
          ? _round(brv.value!.trendSlope!, 4)
          : null,
      // Sleep efficiency % + worn minutes → their own day/week/month/3M trends.
      'efficiency': effPct == null ? null : _round(effPct, 1),
      'worn_min': wornMin == 0 ? null : wornMin.toDouble(),
    },
  };
}

// ── helpers (pure) ───────────────────────────────────────────────────────────

/// Per-window RSA respiratory rates (br/min) for the BRV estimator. Buckets the
/// cleaned NN into [windowMs] (~30-min) bins by beat time and runs [rsaRespRate]
/// on each bin with ≥[minBeats] beats; keeps only resolved windows.
List<double> _respPerWindow(
  List<double> nn,
  List<double> nnTimes, {
  double windowMs = 1800000.0,
  int minBeats = 60,
}) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = ((nnTimes[i] - t0) / windowMs).floor();
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < minBeats) continue;
    // NN is already artifact-corrected upstream → artifactFraction 0.
    final r = rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
  return out;
}

/// Wrap a value sub-map in the {value,confidence,tier,inputs_used} envelope the
/// serve seam reads via `.value`. Null inner → honest "—".
Map<String, dynamic> _envelope(
  Map<String, dynamic>? value, {
  required double confidence,
  required String tier,
  required List<String> inputs,
}) => {
  'value': value ?? '—',
  'confidence': value == null ? 0 : _round(confidence, 6),
  'tier': tier,
  'inputs_used': inputs,
};

/// Build a per-second NREM bool mask ALIGNED to the NN window the robust
/// nocturnal-RMSSD estimator uses.
///
/// `nocturnalRmssd` is t0-relative to `nnTimes.first`, masking a window by its
/// midpoint SECOND counted from that t0. CRUCIAL: `correctRr` RE-BASES nnTimesMs
/// to start near zero (NOT epoch ms), so the mask is indexed in seconds elapsed
/// since the first NN beat — NOT epoch seconds. The first NN beat's absolute
/// instant is the first ORIGINAL RR timestamp (`d.sleepRrTsMs.first`, epoch ms),
/// so mask index `s` maps to absolute second `firstRrSec + s`, then to the hypno
/// index `firstRrSec + s − sleepOnsetSec` (hypnoStages run per-second from
/// sleepOnsetSec). Returns null if we lack NN times / RR times / stages (the
/// estimator then runs unmasked over all sleep windows — still robust, just not
/// NREM-restricted).
List<bool>? _nremMaskAlignedToNn(
  DayBundleInput d,
  List<double> nnTimes,
  List<double> nnTimesSrcMs,
) {
  if (nnTimes.isEmpty ||
      nnTimesSrcMs.isEmpty ||
      d.hypnoStages.isEmpty ||
      d.sleepOnsetSec == 0) {
    return null;
  }
  // Absolute epoch second of the first NN beat (from the ORIGINAL RR times).
  final firstRrSec = (nnTimesSrcMs.first / 1000.0).floor();
  // Span in seconds is measured on the RE-BASED nn time base (starts ~0).
  final span = (nnTimes.last / 1000.0).floor() + 1;
  if (span <= 0) return null;
  final mask = List<bool>.filled(span, false);
  for (var s = 0; s < span; s++) {
    final hypnoIdx = (firstRrSec + s) - d.sleepOnsetSec;
    if (hypnoIdx >= 0 && hypnoIdx < d.hypnoStages.length) {
      // NREM = Light + Deep in the 4-class stream (was the single 'nrem' label).
      final lbl = d.hypnoStages[hypnoIdx];
      mask[s] = lbl == 'light' || lbl == 'deep' || lbl == 'nrem';
    }
  }
  return mask;
}

/// Day-side HR: the day-span HR samples that fall OUTSIDE the sleep window.
List<double> _dayHrOutsideSleep(DayBundleInput d) {
  if (d.sleepOnsetSec == 0 && d.sleepOffsetSec == 0) {
    return [for (final h in d.dayHr) h.toDouble()];
  }
  final out = <double>[];
  for (var i = 0; i < d.dayHr.length; i++) {
    final t = d.dayTsSec[i];
    if (t < d.sleepOnsetSec || t >= d.sleepOffsetSec) {
      out.add(d.dayHr[i].toDouble());
    }
  }
  return out;
}

/// Per-minute mean HR over the WAKE span (day minus sleep window), valid only.
class _WakeMinuteHr {
  final int tsSec;
  final double hr;
  const _WakeMinuteHr(this.tsSec, this.hr);
}

List<_WakeMinuteHr> _perMinuteWakeSeries(DayBundleInput d) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < d.dayHr.length; i++) {
    if (d.dayHr[i] <= 0) continue;
    final t = d.dayTsSec[i];
    if (t >= d.sleepOnsetSec && t < d.sleepOffsetSec) continue; // skip sleep
    (buckets[t ~/ 60] ??= []).add(d.dayHr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [for (final k in keys) _WakeMinuteHr(k * 60, _mean(buckets[k]!)!)];
}

Map<String, int> _wakeZoneMinutesFromSeries(
  List<_WakeMinuteHr> wakeHr,
  double hrMax,
) {
  final samples = <HrSample>[
    for (final p in wakeHr) HrSample(p.tsSec * 1000.0, p.hr),
  ];
  final zoneSet = HeartRateZones.zonesFromMaxHr(hrMax);
  return HeartRateZones.timeInZone(samples, zoneSet).toRoundedMinuteMap();
}

List<Map<String, num>> _zoneTimeline(List<_WakeMinuteHr> wakeHr, double hrMax) {
  final zoneSet = HeartRateZones.zonesFromMaxHr(hrMax);
  return [
    for (final p in wakeHr) {'t': p.tsSec, 'z': zoneSet.zoneNumber(p.hr)},
  ];
}

List<Map<String, num>> _strainCurve(
  List<_WakeMinuteHr> wakeHr, {
  required double? restingHr,
  required double? maxHr,
  required String? sex,
}) {
  if (wakeHr.isEmpty ||
      restingHr == null ||
      maxHr == null ||
      maxHr <= restingHr ||
      sex == null) {
    return const [];
  }
  final b = sex == 'f' ? 1.67 : 1.92;
  final reserve = maxHr - restingHr;
  var trimp = 0.0;
  final out = <Map<String, num>>[];
  for (final p in wakeHr) {
    var hrr = (p.hr - restingHr) / reserve;
    if (hrr < 0) hrr = 0;
    if (hrr > 1) hrr = 1;
    trimp += hrr * math.exp(b * hrr);
    out.add({'t': p.tsSec, 'v': _round(strainScore(trimp), 2)});
  }
  return out;
}

double? _mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

double? _stddev(List<double> xs) {
  if (xs.length < 2) return null;
  final m = _mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

double _round(double v, int dp) {
  final p = math.pow(10, dp);
  return (v * p).round() / p;
}

/// HR curve downsampled to ~per-minute {t: epochSec, v: bpm} (valid only).
List<Map<String, num>> _downsampleHr(List<int> tsSec, List<int> hr) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < hr.length; i++) {
    if (hr[i] <= 0) continue;
    final min = tsSec[i] ~/ 60;
    (buckets[min] ??= []).add(hr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [
    for (final k in keys) {'t': k * 60, 'v': _mean(buckets[k]!)!.round()},
  ];
}

/// HRV timeline: RMSSD over rolling ~5-min windows of cleaned NN, {t, v}.
List<Map<String, num>> _hrvTimeline(List<double> nn, List<double> nnTimes) {
  if (nn.length < 10 || nnTimes.length != nn.length) return const [];
  const winMs = 300000.0; // 5 min
  final out = <Map<String, num>>[];
  var lo = 0;
  for (var i = 0; i < nn.length; i++) {
    while (nnTimes[i] - nnTimes[lo] > winMs) {
      lo++;
    }
    if (i - lo >= 10) {
      var ssd = 0.0;
      for (var k = lo + 1; k <= i; k++) {
        final diff = nn[k] - nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / (i - lo));
      if (out.isEmpty || nnTimes[i] - out.last['t']! * 1000 > 60000) {
        out.add({'t': (nnTimes[i] / 1000).round(), 'v': _round(rmssd, 1)});
      }
    }
  }
  return out;
}

/// Hypnogram segments {start,end,stage} (epoch seconds) from the single-source
/// per-second stage labels (d.hypnoStages over the sleep window). Display-ready.
List<Map<String, dynamic>> _hypnogramSegments(DayBundleInput d) {
  final stages = d.hypnoStages;
  if (stages.isEmpty || d.sleepOnsetSec == 0) return const [];
  final t0 = d.sleepOnsetSec;
  final segs = <Map<String, dynamic>>[];
  int segStart = 0;
  String cur = stages.first;
  for (var i = 1; i < stages.length; i++) {
    if (stages[i] != cur) {
      segs.add({'start': t0 + segStart, 'end': t0 + i, 'stage': cur});
      cur = stages[i];
      segStart = i;
    }
  }
  segs.add({'start': t0 + segStart, 'end': t0 + stages.length, 'stage': cur});
  return segs;
}
