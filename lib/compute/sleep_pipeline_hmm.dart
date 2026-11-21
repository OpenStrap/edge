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
      SleepState.nremLight: log(0.11), // rows must sum to 1.0 (CodeRabbit #756)
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
      SleepState.rem: log(0.80) // rows must sum to 1.0 (CodeRabbit #756)
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
    List<double> enmoHistory = const [],
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
    // Motion history: persisted per-night ENMO medians (stable-core), so the
    // motion channel self-calibrates across nights like the others. Absent
    // history (pre-feature nights) simply leaves the levels unset.
    enmoMedian7d = medianOfEnmo(last7(enmoHistory));
    enmoMedianLong = medianOfEnmo(enmoHistory);
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
  double? enmoMedian7d;
  double? enmoMedianLong;
  // ENMO medians use >= 0 as valid (a measured still night is a real 0);
  // the -1 absent sentinel is excluded.
  double? medianOfEnmo(List<double> xs) {
    final v = xs.where((x) => x.isFinite && x >= 0).toList()..sort();
    if (v.isEmpty) return null;
    return v[v.length ~/ 2];
  }
  /// Effective thermal baseline: blend nightly with 7d rolling when both exist.
  double? get effectiveSkinTempMedian =>
      skinTempMedian7d != null && skinTempMedianNight != null
          ? (skinTempMedianNight! + skinTempMedian7d!) / 2
          : (skinTempMedianNight ?? skinTempMedian7d);
  /// Effective motion baseline: blend nightly (stable core) with 7d rolling.
  double? get effectiveEnmoMedian =>
      enmoMedian7d != null && enmoMedianNight != null
          ? (enmoMedianNight! + enmoMedian7d!) / 2
          : (enmoMedianNight ?? enmoMedian7d);

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
        .map((d) => (d['enmo'] as num?)?.toDouble() ?? -1.0)
        .where((e) => e.isFinite && e >= 0.0)
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

  /// Motion (and thermal) baseline from the STABLE CORE of the night — the
  /// middle 50 % by elapsed time — NOT the first 120 min. The opening window
  /// contains settling-in / turning over and is systematically more active, so
  /// a median taken from it would overstate the person's normal sleep motion
  /// and the wake-vs-arousal threshold would sit too high. HR/RMSSD keep the
  /// opening-window baseline (autonomic settling is exactly what we want there).
  /// Missing ENMO (0 sentinel) is excluded — never "still".
  void computeMotionBaseline(List<Map<String, dynamic>> nightData) {
    if (nightData.length < 10) return;
    final t0 = (nightData.first['ts'] as num?)?.toDouble() ?? 0.0;
    final t1 = (nightData.last['ts'] as num?)?.toDouble() ?? t0;
    final span = t1 - t0;
    if (span <= 0) return;
    final core = nightData
        .where((e) => ((e['ts'] as num?)?.toDouble() ?? 0.0) - t0 > span * 0.25 &&
            ((e['ts'] as num?)?.toDouble() ?? 0.0) - t0 < span * 0.75)
        .toList();
    if (core.isEmpty) return;
    final enmos = core
        .map((d) => (d['enmo'] as num?)?.toDouble() ?? -1.0)
        .where((e) => e.isFinite && e >= 0.0)
        .toList();
    if (enmos.isNotEmpty) {
      enmos.sort();
      enmoMedianNight = enmos[enmos.length ~/ 2];
    }
  }

  /// HYBRID emission over ALL available channels: HR, RMSSD, ENMO (motion),
  /// skin temp. Absent channels (0 sentinel) contribute a NEUTRAL factor —
  /// never evidence. Wake is boosted by ANY of: elevated HR + low RMSSD
  /// (autonomic arousal), high movement, warm skin (peripheral vasodilation
  /// on arousal); sleep states are penalised by movement.
  double _getEmissionLogProb(SleepState state, double hr, double rmssd, {
    double enmo = -1.0, // -1 = absent (see viterbiDecode)
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
      // be deep sleep. If motion is ALSO absent (0 sentinel), the epoch is
      // fully unmeasured — return the uniform neutral for every state so the
      // gap cannot bias adjacent measured epochs towards wake (CodeRabbit #756).
      if (enmo < 0) return log(0.25); // absent sentinel: fully unmeasured epoch
      final motionWake = _sigmoid(enmo, 0.08, 0.03);
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
    // sleepers). Absent ENMO (0 sentinel) = NO evidence either way: wake
    // factor 0 (does not boost wake), sleep factor 1.0 (does not penalise).
    // A measured-zero baseline (very still night) is real: floor the divisor so
    // movement still scores instead of silently disabling the channel.
    final motionMeasured = enmo >= 0 && effectiveEnmoMedian != null;
    final motion =
        motionMeasured ? enmo / max(effectiveEnmoMedian!, 0.005) : 1.0;
    final motionWake = motionMeasured ? _sigmoid(motion, 5.0, 1.0) : 0.0;
    final motionSleep = motionMeasured ? 1.0 - _sigmoid(motion, 4.0, 1.5) : 1.0;
    // Skin temp vs the night median, normalised so ~100 centi-°C = 1 °C.
    // Absent temp = no thermal evidence (excluded from the noisy-OR, i.e.
    // factor 0, never the 0.5 that would silently boost wake) — CodeRabbit #756.
    final tempMeasured = skinTemp > 0 && effectiveSkinTempMedian != null;
    final tempWake = tempMeasured
        ? _sigmoid((skinTemp - effectiveSkinTempMedian!) / 100.0, 1.5, 0.3)
        : 0.0;

    double prob;
    switch (state) {
      case SleepState.wake:
        // Noisy-OR over autonomic, motion and thermal arousal cues — any one
        // strong cue can carry wake, so brief awakenings with movement but
        // barely-elevated HR are still caught.
        final autonomic =
            _sigmoid(hrNorm, 1.15, 0.05) * (1.0 - _sigmoid(rmssdNorm, 0.8, 0.05));
        // Weak HR-only bonus for "quiet wakefulness" (issue #593 pattern:
        // lying still, HR clearly above the personal sleep baseline, RMSSD
        // barely moved). Capped at 0.5 and centred high (1.25×) so REM —
        // whose HR/HRV is wake-like (Zemaityte et al.) — is not flipped to
        // wake; REM's own emission + self-transition guard it instead.
        final hrOnlyWake = _sigmoid(hrNorm, 1.25, 0.04) * 0.5;
        prob = 1.0 -
            (1.0 - autonomic) *
                (1.0 - motionWake) *
                (1.0 - tempWake) *
                (1.0 - hrOnlyWake);
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

  /// True when the emission carries no information at all (contact lost, no
  /// baseline, or no usable HR/RR AND no motion).
  bool _unmeasured(double hr, double rmssd, double enmo, bool contactLost) =>
      contactLost ||
      effectiveHrMin == null ||
      effectiveRmssdMean == null ||
      ((!_plausibleHr(hr) || !_plausibleRmssd(rmssd)) && enmo < 0);

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
              enmo: (nightData[0]['enmo'] as num?)?.toDouble() ?? -1.0,
              skinTemp: (nightData[0]['skin_temp'] as num?)?.toDouble() ?? 0.0,
              isContactLost: nightData[0]['isContactLost'] == true);
    }

    for (var t = 1; t < T; t++) {
      final hr = (nightData[t]['hr'] as num?)?.toDouble() ?? 0.0;
      final rmssd = (nightData[t]['rmssd'] as num?)?.toDouble() ?? 0.0;
      final contactLost = nightData[t]['isContactLost'] == true;
      final enmo = (nightData[t]['enmo'] as num?)?.toDouble() ?? -1.0;
      final skinTemp = (nightData[t]['skin_temp'] as num?)?.toDouble() ?? 0.0;
      if (_unmeasured(hr, rmssd, enmo, contactLost)) {
        // A gap says nothing: hold the state. Running the sticky transition
        // table over uniform emissions let wake absorb the whole gap.
        for (var j = 0; j < N; j++) {
          viterbi[t][j] = viterbi[t - 1][j];
          backpointer[t][j] = j;
        }
        continue;
      }
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
