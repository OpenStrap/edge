// DISCLAIMER: EXPERIMENTAL RESEARCH FEATURE ONLY.
//
// This classifier is NOT a medical device, NOT a validated sleep staging tool,
// and NOT a substitute for clinical polysomnography (PSG).
//
// The sleep staging methodology used here is for informational and research
// purposes only. It is based on autonomic signatures derived from wrist-worn
// PPG sensors and accelerometry. These signatures are estimates and not
// clinically diagnostic.
//
// IF YOU ARE EXPERIENCING SLEEP PROBLEMS (e.g. apnea, chronic insomnia, 
// excessive daytime fatigue), please consult a physician or a qualified 
// sleep specialist. Do NOT rely on these analytics for medical decisions.

import 'dart:math';

enum SleepState { wake, nremLight, nremDeep, rem }

// The transition table and the emission sigmoid centres/scales below are
// hand-set ESTIMATES (per 30 s epoch), not fitted to or validated against PSG.
class HMMConfig {
  static const states = [
    SleepState.wake,
    SleepState.nremLight,
    SleepState.nremDeep,
    SleepState.rem
  ];

  static final Map<SleepState, Map<SleepState, double>> transitionLogProb = {
    SleepState.wake: {
      SleepState.wake: log(0.90),
      SleepState.nremLight: log(0.09),
      SleepState.nremDeep: log(0.005),
      SleepState.rem: log(0.005)
    },
    SleepState.nremLight: {
      SleepState.wake: log(0.12),
      SleepState.nremLight: log(0.73),
      SleepState.nremDeep: log(0.10),
      SleepState.rem: log(0.05)
    },
    SleepState.nremDeep: {
      SleepState.wake: log(0.06),
      SleepState.nremLight: log(0.14),
      SleepState.nremDeep: log(0.80),
      SleepState.rem: log(0.03)
    },
    SleepState.rem: {
      SleepState.wake: log(0.10),
      SleepState.nremLight: log(0.10),
      // INTENTIONAL HARD FORBID: REM never goes straight to deep (it passes
      // through light). log(0) is -infinity; the decoder only ever ADDS it to
      // finite emissions and compares, so it rules the move out without ever
      // producing NaN.
      SleepState.nremDeep: double.negativeInfinity,
      SleepState.rem: log(0.85)
    },
  };
}

class SleepStageAnalyzer {
  double? hrMinNight;
  double? rmssdMeanNight;
  // HYBRID baselines: motion (ENMO, g) and skin temp (centi-°C) medians from
  // the opening window. 0 = absent sentinel and is EXCLUDED — a missing sensor
  // must never set the baseline to "perfectly still" / "cold".
  double? enmoMedianNight;
  double? skinTempMedianNight;

  // THREE-LEVEL self-calibration (per user, across nights):
  //  - nightly baseline (computeBaseline, first 120 min) — primary, always there
  //  - 7-day rolling baseline — smooths single restless nights out
  //  - long-term baseline — the user's personal reference; a nightly baseline
  //    that deviates strongly from it marks the night as ATYPICAL (illness,
  //    alcohol, travel) instead of silently bending the thresholds.
  double? hrMin7d;
  double? rmssdMean7d;
  double? hrMinLong;
  double? rmssdMeanLong;
  /// True when tonight's baseline deviates from the long-term baseline by more
  /// than [atypicalZThreshold] robust z — an outlier night, lower confidence.
  bool atypicalNight = false;
  static const double atypicalZThreshold = 2.0;

  /// Feed the multi-night histories (trailing nightly series, oldest first).
  /// [rhrHistory]/[rmssdHistory] are the persisted per-night resting-HR /
  /// nocturnal-RMSSD series; the last 7 form the rolling baseline, all of them
  /// the long-term one. Missing/empty history simply leaves the level unset.
  void computeMultiNightBaselines({
    List<double> rhrHistory = const [],
    List<double> rmssdHistory = const [],
    List<double> skinTempHistory = const [],
  }) {
    double? medianOf(List<double> xs) {
      final v = xs.where((x) => x.isFinite && x > 0).toList()..sort();
      if (v.isEmpty) return null;
      return v[v.length ~/ 2];
    }
    double? madOf(List<double> xs, double? med) {
      if (med == null) return null;
      final dev = xs.where((x) => x.isFinite).map((x) => (x - med).abs()).toList()..sort();
      if (dev.isEmpty) return null;
      return dev[dev.length ~/ 2];
    }
    List<double> last7(List<double> xs) => xs.length > 7 ? xs.sublist(xs.length - 7) : xs;
    hrMin7d = medianOf(last7(rhrHistory));
    rmssdMean7d = medianOf(last7(rmssdHistory));
    hrMinLong = medianOf(rhrHistory);
    rmssdMeanLong = medianOf(rmssdHistory);
    // Motion + thermal channels self-calibrate too when a nightly history
    // exists (skinTempAdcHistory); without one they stay nightly-only.
    skinTempMedian7d = medianOf(last7(skinTempHistory));
    skinTempMedianLong = medianOf(skinTempHistory);
    // Outlier check: nightly vs long-term, robust z via MAD (1.4826*MAD ~ sd).
    if (hrMinNight != null && hrMinLong != null) {
      final mad = madOf(rhrHistory, hrMinLong);
      final sd = mad != null && mad > 0 ? 1.4826 * mad : 3.0; // floor: 3 bpm
      final z = (hrMinNight! - hrMinLong!) / sd;
      if (z.abs() > atypicalZThreshold) atypicalNight = true;
    }
  }

  double? skinTempMedian7d;
  double? skinTempMedianLong;
  /// Effective thermal baseline: blend nightly with 7d rolling when both exist.
  double? get effectiveSkinTempMedian =>
      skinTempMedian7d != null && skinTempMedianNight != null
          ? (skinTempMedianNight! + skinTempMedian7d!) / 2
          : (skinTempMedianNight ?? skinTempMedian7d);

  /// Effective HR baseline for the emission: blend nightly with the 7-day
  /// rolling level when both exist (half/half) — the night's own physiology
  /// anchors it, the rolling window keeps single odd nights from dominating.
  double? get effectiveHrMin =>
      hrMin7d != null && hrMinNight != null ? (hrMinNight! + hrMin7d!) / 2 : (hrMinNight ?? hrMin7d);
  double? get effectiveRmssdMean =>
      rmssdMean7d != null && rmssdMeanNight != null ? (rmssdMeanNight! + rmssdMean7d!) / 2 : (rmssdMeanNight ?? rmssdMean7d);

  // The same plausibility window decides which samples form the baseline and
  // which observations get scored. A value outside it (a 250 bpm spike, a NaN
  // from a dropped beat) is a measurement fault, not physiology, and scoring it
  // would push the decoder towards wake.
  static bool _plausibleHr(double? h) => h != null && h.isFinite && h > 30.0 && h < 200.0;
  static bool _plausibleRmssd(double? r) => r != null && r.isFinite && r > 0.0 && r < 500.0;
  static double _sigmoid(double x, double center, double scale) =>
      1.0 / (1.0 + exp(-(x - center) / scale));

  void computeBaseline(List<Map<String, dynamic>> first120minData) {
    if (first120minData.isEmpty) return;
    final hrs = first120minData
        .map((d) => (d['hr'] as num?)?.toDouble())
        .where(_plausibleHr)
        .cast<double>()
        .toList();
    final rmssds = first120minData
        .map((d) => (d['rmssd'] as num?)?.toDouble())
        .where(_plausibleRmssd)
        .cast<double>()
        .toList();
    final enmos = first120minData
        .map((d) => (d['enmo'] as num?)?.toDouble() ?? 0.0)
        .where((e) => e.isFinite && e > 0.0)
        .toList();
    final temps = first120minData
        .map((d) => (d['skin_temp'] as num?)?.toDouble() ?? 0.0)
        .where((t) => t.isFinite && t > 0.0)
        .toList();

    if (hrs.isNotEmpty) {
      hrs.sort();
      hrMinNight = hrs[(hrs.length * 0.1).floor()];
    }
    if (rmssds.isNotEmpty) rmssdMeanNight = rmssds.reduce((a, b) => a + b) / rmssds.length;
    if (enmos.isNotEmpty) {
      enmos.sort();
      enmoMedianNight = enmos[enmos.length ~/ 2];
    }
    if (temps.isNotEmpty) {
      temps.sort();
      skinTempMedianNight = temps[temps.length ~/ 2];
    }
  }

  /// HYBRID emission over ALL available channels: HR, RMSSD, ENMO (motion),
  /// skin temp. Absent channels (0 sentinel) contribute a NEUTRAL factor —
  /// never evidence. Wake is boosted by ANY of: elevated HR + low RMSSD
  /// (autonomic arousal), high movement, warm skin (peripheral vasodilation
  /// on arousal); sleep states are penalised by movement.
  double _getEmissionLogProb(SleepState state, double hr, double rmssd, {
    double enmo = 0.0,
    double skinTemp = 0.0,
    bool isContactLost = false,
  }) {
    if (isContactLost ||
        effectiveHrMin == null ||
        effectiveRmssdMean == null) {
      return log(0.25);
    }
    if (!_plausibleHr(hr) || !_plausibleRmssd(rmssd)) {
      // HR/RR unusable: motion-only evidence. A clearly moving wrist cannot
      // be deep sleep; absent motion (0 sentinel) is neutral.
      final motionWake = enmo > 0 ? _sigmoid(enmo, 0.08, 0.03) : 0.5;
      switch (state) {
        case SleepState.wake:
          return log(max(0.01, 0.2 + 0.8 * motionWake));
        case SleepState.nremDeep:
          return log(max(0.01, 0.1 * (1.0 - motionWake)));
        case SleepState.rem:
          return log(max(0.01, 0.15 * (1.0 - motionWake)));
        case SleepState.nremLight:
          return log(max(0.01, 0.3));
      }
    }

    final hrNorm = hr / effectiveHrMin!;
    final rmssdNorm = rmssd / effectiveRmssdMean!;
    // Motion relative to the night's own median (robust for restless
    // sleepers); absent ENMO -> neutral 1.0.
    final motion = enmo > 0 && enmoMedianNight != null && enmoMedianNight! > 0
        ? enmo / enmoMedianNight!
        : 1.0;
    final motionWake = _sigmoid(motion, 3.0, 1.5);
    final motionSleep = 1.0 - _sigmoid(motion, 2.0, 1.0);
    // Skin temp vs the night median, normalised so ~100 centi-°C = 1 °C.
    final tempWake = skinTemp > 0 && effectiveSkinTempMedian != null
        ? _sigmoid((skinTemp - effectiveSkinTempMedian!) / 100.0, 1.5, 1.0)
        : 0.5;

    double prob;
    switch (state) {
      case SleepState.wake:
        // Noisy-OR over autonomic, motion and thermal arousal cues — any one
        // strong cue can carry wake, so brief awakenings with movement but
        // barely-elevated HR are still caught.
        final autonomic =
            _sigmoid(hrNorm, 1.15, 0.05) * (1.0 - _sigmoid(rmssdNorm, 0.8, 0.05));
        prob = 1.0 - (1.0 - autonomic) * (1.0 - motionWake) * (1.0 - tempWake);
        break;
      case SleepState.nremDeep:
        prob = (1.0 - _sigmoid(hrNorm, 1.0, 0.05)) *
            _sigmoid(rmssdNorm, 1.1, 0.05) *
            motionSleep;
        break;
      case SleepState.rem:
        prob = _sigmoid(hrNorm, 1.05, 0.05) *
            _sigmoid(rmssdNorm, 1.0, 0.05) *
            (0.5 + 0.5 * motionSleep);
        break;
      case SleepState.nremLight:
        prob = 0.4 * (0.5 + 0.5 * motionSleep);
        break;
    }
    return log(max(0.01, prob));
  }

  List<SleepState> viterbiDecode(List<Map<String, dynamic>> nightData) {
    if (nightData.isEmpty) return [];

    final T = nightData.length;
    final states = HMMConfig.states;
    final N = states.length;

    final viterbi = List.generate(T, (_) => List<double>.filled(N, double.negativeInfinity));
    final backpointer = List.generate(T, (_) => List<int>.filled(N, 0));

    for (var i = 0; i < N; i++) {
      final state = states[i];
      final hr = (nightData[0]['hr'] as num?)?.toDouble() ?? 0.0;
      final rmssd = (nightData[0]['rmssd'] as num?)?.toDouble() ?? 0.0;
      final initProb = (state == SleepState.wake || state == SleepState.nremLight) ? log(0.5) : double.negativeInfinity;
      viterbi[0][i] = initProb +
          _getEmissionLogProb(state, hr, rmssd,
              enmo: (nightData[0]['enmo'] as num?)?.toDouble() ?? 0.0,
              skinTemp: (nightData[0]['skin_temp'] as num?)?.toDouble() ?? 0.0,
              isContactLost: nightData[0]['isContactLost'] == true);
    }

    for (var t = 1; t < T; t++) {
      final hr = (nightData[t]['hr'] as num?)?.toDouble() ?? 0.0;
      final rmssd = (nightData[t]['rmssd'] as num?)?.toDouble() ?? 0.0;
      final contactLost = nightData[t]['isContactLost'] == true;
      final enmo = (nightData[t]['enmo'] as num?)?.toDouble() ?? 0.0;
      final skinTemp = (nightData[t]['skin_temp'] as num?)?.toDouble() ?? 0.0;
      for (var j = 0; j < N; j++) {
        final nextState = states[j];
        final emission =
            _getEmissionLogProb(nextState, hr, rmssd,
                enmo: enmo, skinTemp: skinTemp, isContactLost: contactLost);
        var maxLogProb = double.negativeInfinity;
        var bestPrevState = 0;
        for (var i = 0; i < N; i++) {
          final prevState = states[i];
          final trans = HMMConfig.transitionLogProb[prevState]![nextState]!;
          final logProb = viterbi[t - 1][i] + trans + emission;
          if (logProb > maxLogProb) {
            maxLogProb = logProb;
            bestPrevState = i;
          }
        }
        viterbi[t][j] = maxLogProb;
        backpointer[t][j] = bestPrevState;
      }
    }

    var bestLastState = 0;
    var maxFinalProb = double.negativeInfinity;
    for (var i = 0; i < N; i++) {
      if (viterbi[T - 1][i] > maxFinalProb) {
        maxFinalProb = viterbi[T - 1][i];
        bestLastState = i;
      }
    }
    // Wake and light are always reachable with finite emissions, so a path
    // always exists; if one ever does not (or a score is NaN), decode
    // nothing and let the caller keep the shipped labels.
    if (!maxFinalProb.isFinite) return [];

    final result = List<SleepState>.filled(T, SleepState.nremLight);
    var currentStateIndex = bestLastState;
    result[T - 1] = states[currentStateIndex];
    for (var t = T - 1; t > 0; t--) {
      currentStateIndex = backpointer[t][currentStateIndex];
      result[t - 1] = states[currentStateIndex];
    }
    return result;
  }
}
