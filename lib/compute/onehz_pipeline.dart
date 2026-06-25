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
  final List<double> skinTempZHistory;

  // ── day confidence + flags (e.g. LOW_CONFIDENCE_RECOVERY for fallback days) ─
  final double dayConfidence;
  final List<String> dayFlags;

  const DayBundleInput({
    required this.date,
    required this.dayTsSec,
    required this.dayHr,
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
    this.skinTempZHistory = const [],
    this.dayConfidence = 0,
    this.dayFlags = const [],
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'day_ts': dayTsSec,
        'day_hr': dayHr,
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
        'skin_temp_z_history': skinTempZHistory,
        'day_confidence': dayConfidence,
        'day_flags': dayFlags,
      };

  static DayBundleInput fromJson(Map<String, dynamic> m) {
    List<int> ints(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    List<double> dbls(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    List<String> strs(String k) =>
        ((m[k] as List?) ?? const []).map((e) => e.toString()).toList();
    return DayBundleInput(
      date: m['date'] as String,
      dayTsSec: ints('day_ts'),
      dayHr: ints('day_hr'),
      sleepTsSec: ints('sleep_ts'),
      sleepHr: ints('sleep_hr'),
      sleepRrTsMs: dbls('sleep_rr_ts_ms'),
      sleepRrMs: dbls('sleep_rr_ms'),
      sleepSpo2Red: ints('sleep_spo2_red'),
      sleepSpo2Ir: ints('sleep_spo2_ir'),
      sleepSkinTemp: ints('sleep_skin_temp'),
      sleepJson: ((m['sleep_json'] as Map?) ?? const {}).cast<String, dynamic>(),
      hypnoStages: strs('hypno_stages'),
      sleepOnsetSec: (m['sleep_onset_sec'] as num?)?.toInt() ?? 0,
      sleepOffsetSec: (m['sleep_offset_sec'] as num?)?.toInt() ?? 0,
      profile: ((m['profile'] as Map?) ?? const {}).cast<String, dynamic>(),
      lnRmssdHistory: dbls('ln_rmssd_history'),
      rhrHistory: dbls('rhr_history'),
      respHistory: dbls('resp_history'),
      skinTempZHistory: dbls('skin_temp_z_history'),
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
  final remSec = (d.sleepJson['rem_sec'] as num?)?.toInt();
  final wakeSec = (d.sleepJson['wake_sec'] as num?)?.toInt();
  final sleepConf = (d.sleepJson['confidence'] as num?)?.toDouble() ?? 0;

  // ── CLINICAL (sleep-windowed) ──────────────────────────────────────────────
  final hrvT = hrvTime(nn, nnTimesMs: nnTimes);
  final hrvF = nn.length >= 20
      ? hrvFreq(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<HrvFreq>.absent(tier: Tier.high, inputs_used: ['rr_cleaned']);
  // Nocturnal RHR over the SLEEP HR (fallback to day-valid only if no sleep HR).
  final rhr = nocturnalRhr(sleepHr.isNotEmpty ? sleepHr : dayHrValid);
  // HR dip: day-side = waking HR outside the sleep window; night-side = sleep HR.
  final dayOnly = _dayHrOutsideSleep(d);
  final dip = hrDip(dayOnly, sleepHr);
  final dc = decelerationCapacity(nn);
  final ac = accelerationCapacity(nn);

  // ── RESPIRATION (sleep-windowed) ───────────────────────────────────────────
  final resp = nn.length >= 30
      ? rsaRespRate(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<RespEstimate>.absent(
          tier: Tier.estimate, inputs_used: ['rr_cleaned']);
  final cvhr = nn.length >= 60
      ? cvhrApneaScreen(nn, nnTimes, artifactFraction: artifactFraction)
      : const Metric<CvhrResult>.absent(
          tier: Tier.estimate, inputs_used: ['rr_cleaned']);
  final cpc = nn.length >= 60
      ? cardiopulmonaryCoupling(nn, nnTimes)
      : const Metric<CpcResult>.absent(
          tier: Tier.high, inputs_used: ['rr_cleaned']);

  // Relative ODI over the SLEEP window's spo2 channels (desaturation screen).
  final odiRed = [for (final v in d.sleepSpo2Red) v.toDouble()];
  final odiIr = [for (final v in d.sleepSpo2Ir) v.toDouble()];
  final odiTs = [for (final t in d.sleepTsSec) t.toDouble()];
  final odi = (odiRed.length == odiIr.length &&
          odiRed.length == odiTs.length &&
          odiRed.length >= 60)
      ? relativeOdi(odiRed, odiIr, odiTs)
      : const Metric<RelativeOdiResult>.absent(
          tier: Tier.relative, inputs_used: ['spo2_red_raw', 'spo2_ir_raw']);

  // ── WELLNESS: relative skin-temp deviation (z) vs personal baseline ────────
  double? skinTempZ;
  final tempValid =
      d.sleepSkinTemp.where((v) => v > 0).map((v) => v.toDouble()).toList();
  if (tempValid.length >= 60 && d.skinTempZHistory.length >= 3) {
    final m = _mean(tempValid)!;
    final base = _mean(d.skinTempZHistory)!;
    final sd = _stddev(d.skinTempZHistory);
    if (sd != null && sd > 0) skinTempZ = (m - base) / sd;
  }

  // ── READINESS (the canonical composite, baseline-dependent) ───────────────
  final lnToday =
      (hrvT.present && hrvT.value!.rmssd != null && hrvT.value!.rmssd! > 0)
          ? math.log(hrvT.value!.rmssd!)
          : null;
  final rhrToday = rhr.present ? rhr.value!.low30Mean : null;
  final respToday = resp.present ? resp.value!.brpm : null;
  final composite = readinessComposite([
    hrvInput(lnToday, d.lnRmssdHistory),
    rhrInput(rhrToday, d.rhrHistory),
    respInput(respToday, d.respHistory),
    tempInput(skinTempZ, d.skinTempZHistory),
  ]);
  // Plews lnRMSSD readiness over the trailing history INCLUDING today.
  final lnHist = [...d.lnRmssdHistory, ?lnToday];
  final lnReadiness = lnHist.length >= 4
      ? readinessLnRmssd(lnHist)
      : const Metric<ReadinessLnRmssd>.absent(
          tier: Tier.high, inputs_used: ['ln_rmssd_history']);

  // ── STRAIN: Banister TRIMP over the WAKE span (per-minute day HR) ──────────
  final prof = d.profile;
  final age = (prof['age'] as num?)?.toDouble();
  final sex = (prof['sex'] as String?)?.toLowerCase();
  final hrMax = age == null ? null : 208 - 0.7 * age; // Tanaka
  final rhrForTrimp = rhrToday ?? (prof['resting_hr'] as num?)?.toDouble();
  Metric<double> trimp = const Metric<double>.absent(
      tier: Tier.estimate, inputs_used: ['hr_1hz', 'profile']);
  if (hrMax != null && rhrForTrimp != null && sex != null && dayHrValid.isNotEmpty) {
    // Wake-span per-minute mean HR = the day minus the sleep window.
    final perMin = _perMinuteMeanWake(d);
    if (perMin.isNotEmpty) {
      trimp = banisterTrimp(perMin,
          restingHr: rhrForTrimp,
          maxHr: hrMax,
          sex: sex == 'f' ? Sex.female : Sex.male);
    }
  }

  // ── curve series for the UI ────────────────────────────────────────────────
  final hrCurve = _downsampleHr(d.dayTsSec, d.dayHr);
  final hypnogram = _hypnogramSegments(d);
  final hrvTimeline = _hrvTimeline(nn, nnTimes);

  // ── ASSEMBLE the bundle (envelopes are plain JSON) ─────────────────────────
  final clinical = <String, dynamic>{
    'hrv_time': hrvT.toJson((v) => v.toJson()),
    'hrv_freq': hrvF.toJson((v) => v.toJson()),
    'resting_hr': rhr.toJson((v) => v.toJson()),
    'hr_dip': dip.toJson((v) => v.toJson()),
    'prsa_dc': dc.toJson((v) => v.toJson()),
    'prsa_ac': ac.toJson((v) => v.toJson()),
    'readiness_lnrmssd': lnReadiness.toJson((v) => v.toJson()),
    'readiness_composite': composite.toJson((v) => v.toJson()),
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
              'rem_sec': remSec,
              'wake_sec': wakeSec,
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
      'note': 'relative deviation (z) vs your baseline; raw ADC, no absolute °C',
    },
  };

  // Indexed scalars (also surfaced to metric_series by the engine).
  final rhrScalar = rhr.present ? rhr.value!.low30Mean : null;
  final rmssdScalar =
      (hrvT.present && hrvT.value!.rmssd != null) ? hrvT.value!.rmssd : null;
  final readinessScalar = composite.present ? composite.value!.score : null;

  return <String, dynamic>{
    'date': d.date,
    'day_confidence': _round(d.dayConfidence, 4),
    'flags': d.dayFlags,
    'clinical': clinical,
    'sleep': sleep,
    'respiration': respiration,
    'wellness': wellness,
    'series': {
      'hr_curve': hrCurve,
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
      'rmssd': rmssdScalar,
      'readiness': readinessScalar,
      'ln_rmssd': lnToday,
      'resp_rate': respToday,
      'skin_temp_z': skinTempZ,
      'sdnn': hrvT.present ? hrvT.value!.sdnn : null,
      'dip_pct': dip.present ? dip.value!.dipPct : null,
      'trimp': trimp.present ? trimp.value : null,
      'odi_per_hour': odi.present ? odi.value!.odiPerHour : null,
      'cpc_ratio': cpc.present ? cpc.value!.cpcRatio : null,
    },
  };
}

// ── helpers (pure) ───────────────────────────────────────────────────────────

/// Wrap a value sub-map in the {value,confidence,tier,inputs_used} envelope the
/// serve seam reads via `.value`. Null inner → honest "—".
Map<String, dynamic> _envelope(
  Map<String, dynamic>? value, {
  required double confidence,
  required String tier,
  required List<String> inputs,
}) =>
    {
      'value': value ?? '—',
      'confidence': value == null ? 0 : _round(confidence, 6),
      'tier': tier,
      'inputs_used': inputs,
    };

/// Day-side HR: the day-span HR samples that fall OUTSIDE the sleep window.
List<double> _dayHrOutsideSleep(DayBundleInput d) {
  if (d.sleepOnsetSec == 0 && d.sleepOffsetSec == 0) {
    return [for (final h in d.dayHr) h.toDouble()];
  }
  final out = <double>[];
  for (var i = 0; i < d.dayHr.length; i++) {
    final t = d.dayTsSec[i];
    if (t < d.sleepOnsetSec || t >= d.sleepOffsetSec) out.add(d.dayHr[i].toDouble());
  }
  return out;
}

/// Per-minute mean HR over the WAKE span (day minus sleep window), valid only.
List<double> _perMinuteMeanWake(DayBundleInput d) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < d.dayHr.length; i++) {
    if (d.dayHr[i] <= 0) continue;
    final t = d.dayTsSec[i];
    if (t >= d.sleepOnsetSec && t < d.sleepOffsetSec) continue; // skip sleep
    (buckets[t ~/ 60] ??= []).add(d.dayHr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [for (final k in keys) _mean(buckets[k]!)!];
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
    for (final k in keys) {'t': k * 60, 'v': _mean(buckets[k]!)!.round()}
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
