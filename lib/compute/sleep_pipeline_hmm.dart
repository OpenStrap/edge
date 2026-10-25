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

  // AASM-konforme Log-Transitionen
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

  void computeBaseline(List<Map<String, dynamic>> first120minData) {
    if (first120minData.isEmpty) return;
    final hrs = first120minData.map((d) => (d['hr'] as num).toDouble()).where((h) => h > 0).toList();
    final rmssds = first120minData.map((d) => (d['rmssd'] as num).toDouble()).where((r) => r > 0).toList();
    
    if (hrs.isNotEmpty) hrMinNight = hrs.reduce(min);
    if (rmssds.isNotEmpty) rmssdMeanNight = rmssds.reduce((a, b) => a + b) / rmssds.length;
  }

  double _getEmissionLogProb(SleepState state, double hr, double rmssd, {bool isContactLost = false}) {
    // Sensor-Kontaktverlust / Motion Artifacts (Drehen im Bett, loses Band):
    // Wenn kein Puls oder RMSSD vorhanden ist (z.B. 0 oder unphysiologisch),
    // liefert die Beobachtung NULL Information (Uniform Log-Prob für alle Zustände).
    // Der Viterbi-Algorithmus überbrückt diese Lücke rein über die Übergangswahrscheinlichkeiten
    // (Transition Matrix), behält also den aktuellen physiologischen Zustand bei!
    if (isContactLost || hr <= 0 || rmssd <= 0) {
      return log(0.25); // Neutrale Emission — keine Verzerrung der Klassifikation
    }

    if (hrMinNight == null || hrMinNight == 0 || rmssdMeanNight == null || rmssdMeanNight == 0) {
      return log(0.25);
    }

    final hrNorm = hr / hrMinNight!;
    final rmssdNorm = rmssd / rmssdMeanNight!;
    
    // Wissenschaftliche Heuristik für Apnoe-Indikation: 
    // Häufige Arousals (hr spike) aus tiefem Schlaf.
    // Wenn hrNorm sehr hoch bei eigentlich tiefem Zustand -> Strafe für Deep
    bool apneaLikely = (hrNorm > 1.3 && rmssdNorm < 0.5);

    double prob = 0.25;
    switch (state) {
      case SleepState.wake:
        prob = (hrNorm > 1.2 || apneaLikely) ? 0.85 : 0.15;
        break;
      case SleepState.nremDeep:
        prob = (hrNorm < 0.95 && rmssdNorm > 1.1 && !apneaLikely) ? 0.8 : 0.05;
        break;
      case SleepState.rem:
        prob = (hrNorm > 1.05 && rmssdNorm > 0.9 && rmssdNorm < 1.1) ? 0.7 : 0.2;
        break;
      case SleepState.nremLight:
        prob = 0.4;
        break;
    }
    return log(prob);
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
      viterbi[0][i] = initProb + _getEmissionLogProb(state, hr, rmssd);
    }

    for (var t = 1; t < T; t++) {
      final hr = (nightData[t]['hr'] as num?)?.toDouble() ?? 0.0;
      final rmssd = (nightData[t]['rmssd'] as num?)?.toDouble() ?? 0.0;
      for (var j = 0; j < N; j++) {
        final nextState = states[j];
        final emission = _getEmissionLogProb(nextState, hr, rmssd);
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
