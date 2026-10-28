import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

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

  group('observations the decoder cannot trust', () {
    SleepStageAnalyzer baselined() {
      final a = SleepStageAnalyzer();
      a.computeBaseline(List.generate(240, (_) => {'hr': 60.0, 'rmssd': 40.0}));
      return a;
    }

    List<Map<String, dynamic>> deepAround(List<Map<String, dynamic>> middle) => [
          ...List.generate(20, (_) => <String, dynamic>{'hr': 55.0, 'rmssd': 50.0}),
          ...middle,
          ...List.generate(20, (_) => <String, dynamic>{'hr': 55.0, 'rmssd': 50.0}),
        ];

    test('a contact-lost stretch is bridged, not scored as wake', () {
      final night = deepAround(List.generate(
          10, (_) => <String, dynamic>{'hr': 95.0, 'rmssd': 12.0, 'isContactLost': true}));
      final states = baselined().viterbiDecode(night);
      for (var t = 20; t < 30; t++) {
        expect(states[t], SleepState.nremDeep, reason: 'epoch $t');
      }
    });

    test('implausible and non-finite HR get the neutral emission', () {
      for (final bad in [250.0, double.nan, double.infinity]) {
        final night = deepAround(
            List.generate(10, (_) => <String, dynamic>{'hr': bad, 'rmssd': 12.0}));
        final states = baselined().viterbiDecode(night);
        for (var t = 20; t < 30; t++) {
          expect(states[t], SleepState.nremDeep, reason: 'hr=$bad epoch $t');
        }
      }
    });

    test('the same values without the flag still read as wake', () {
      final night = deepAround(
          List.generate(10, (_) => <String, dynamic>{'hr': 95.0, 'rmssd': 12.0}));
      final states = baselined().viterbiDecode(night);
      expect(states[25], SleepState.wake);
    });

    test('baseline skips missing and non-finite values instead of throwing', () {
      final a = SleepStageAnalyzer();
      a.computeBaseline([
        {'hr': null, 'rmssd': 40.0},
        {'rmssd': 40.0},
        {'hr': double.nan, 'rmssd': double.nan},
        ...List.generate(20, (_) => <String, dynamic>{'hr': 60.0, 'rmssd': 40.0}),
      ]);
      expect(a.hrMinNight, 60.0);
      expect(a.rmssdMeanNight, 40.0);
    });
  });
}
