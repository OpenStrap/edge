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
      SleepState.wake: log(0.05),
      SleepState.nremLight: log(0.80),
      SleepState.nremDeep: log(0.10),
      SleepState.rem: log(0.05)
    },
    SleepState.nremDeep: {
      SleepState.wake: log(0.02),
      SleepState.nremLight: log(0.15),
      SleepState.nremDeep: log(0.80),
      SleepState.rem: log(0.03)
    },
    SleepState.rem: {
      SleepState.wake: log(0.05),
      SleepState.nremLight: log(0.10),
      SleepState.nremDeep: log(0.00),
      SleepState.rem: log(0.85)
    },
  };
}

class SleepStageAnalyzer {
  double? hrMinNight;
  double? rmssdMeanNight;

  // The same plausibility window decides which samples form the baseline and
  // which observations get scored. A value outside it (a 250 bpm spike, a NaN
  // from a dropped beat) is a measurement fault, not physiology, and scoring it
  // would push the decoder towards wake.
  static bool _plausibleHr(double? h) => h != null && h.isFinite && h > 30.0 && h < 200.0;
  static bool _plausibleRmssd(double? r) => r != null && r.isFinite && r > 0.0 && r < 500.0;

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
    
    if (hrs.isNotEmpty) {
      hrs.sort();
      hrMinNight = hrs[(hrs.length * 0.1).floor()];
    }
    if (rmssds.isNotEmpty) rmssdMeanNight = rmssds.reduce((a, b) => a + b) / rmssds.length;
  }

  double _getEmissionLogProb(SleepState state, double hr, double rmssd, {bool isContactLost = false}) {
    if (isContactLost ||
        !_plausibleHr(hr) ||
        !_plausibleRmssd(rmssd) ||
        hrMinNight == null ||
        rmssdMeanNight == null) {
      return log(0.25);
    }

    final hrNorm = hr / hrMinNight!;
    final rmssdNorm = rmssd / rmssdMeanNight!;
    
    double sigmoid(double x, double center, double scale) => 1.0 / (1.0 + exp(-(x - center) / scale));

    double prob;
    switch (state) {
      case SleepState.wake:
        prob = sigmoid(hrNorm, 1.2, 0.05) * (1.0 - sigmoid(rmssdNorm, 0.8, 0.05));
        break;
      case SleepState.nremDeep:
        prob = (1.0 - sigmoid(hrNorm, 1.0, 0.05)) * sigmoid(rmssdNorm, 1.1, 0.05);
        break;
      case SleepState.rem:
        prob = sigmoid(hrNorm, 1.05, 0.05) * sigmoid(rmssdNorm, 1.0, 0.05);
        break;
      case SleepState.nremLight:
        prob = 0.4;
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
              isContactLost: nightData[0]['isContactLost'] == true);
    }

    for (var t = 1; t < T; t++) {
      final hr = (nightData[t]['hr'] as num?)?.toDouble() ?? 0.0;
      final rmssd = (nightData[t]['rmssd'] as num?)?.toDouble() ?? 0.0;
      final contactLost = nightData[t]['isContactLost'] == true;
      for (var j = 0; j < N; j++) {
        final nextState = states[j];
        final emission =
            _getEmissionLogProb(nextState, hr, rmssd, isContactLost: contactLost);
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
