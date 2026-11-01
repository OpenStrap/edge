import 'package:flutter_test/flutter_test.dart';
import '../lib/compute/sleep_pipeline_hmm.dart';

void main() {
  test('Arousals do not trigger a full cycle reset and maintain stage continuity', () {
    final analyzer = SleepStageAnalyzer();

    // Baseline erzeugen (HR ~ 60, RMSSD ~ 40)
    final baseline = List.generate(240, (i) => {'hr': 60.0, 'rmssd': 40.0});
    analyzer.computeBaseline(baseline);

    // Testsequenz: Deep Sleep -> Kurzes Arousal (Wake) -> Deep Sleep
    final nightData = <Map<String, dynamic>>[];
    
    // Block 1: Stable Deep Sleep
    nightData.addAll(List.generate(20, (i) => {'hr': 55.0, 'rmssd': 50.0}));
    
    // Block 2: Short Arousal (1 Epoche)
    nightData.add({'hr': 80.0, 'rmssd': 20.0});
    
    // Block 3: Return to Deep Sleep
    nightData.addAll(List.generate(20, (i) => {'hr': 55.0, 'rmssd': 50.0}));

    final states = analyzer.viterbiDecode(nightData);

    // Erwartung: Nach dem Arousal kehrt das System direkt wieder zu NREM Deep zurück,
    // ohne stundenlang in NREM Light "festzustecken".
    expect(states[19], SleepState.nremDeep);
    expect(states[21], SleepState.nremDeep);
  });
}
