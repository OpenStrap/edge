import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

void main() {
  hmmPipelineMain();
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

/// The opt-in path through [deriveDayBundle]: a quiet first half and an
/// aroused second half must re-stage (the decoder actually ran on epoch-aligned
/// beats), and a second the band did not watch stays unobserved.
void hmmPipelineMain() {
  test('opt-in HMM re-stages a measured night and keeps unobserved seconds', () {
    const t0 = 1780000000;
    const n = 4 * 3600;
    final tsSec = [for (var s = 0; s < n; s++) t0 + s];
    final hr = [for (var s = 0; s < n; s++) s < n ~/ 2 ? 55 : 80];
    final rrTs = <double>[], rrMs = <double>[];
    var t = t0 * 1000.0;
    var i = 0;
    while (t < (t0 + n) * 1000.0) {
      final aroused = t >= (t0 + n ~/ 2) * 1000.0;
      final rr = aroused
          ? 750.0 + 2.0 * ((i % 3) - 1)
          : 1090.0 + 40.0 * ((i % 5) - 2);
      t += rr;
      rrTs.add(t);
      rrMs.add(rr);
      i++;
    }
    final stages = List<String>.filled(n, 'light');
    for (var s = 100; s < 160; s++) {
      stages[s] = 'unobserved';
    }
    Map<String, dynamic> run(bool hmm) => deriveDayBundle(DayBundleInput(
          date: '2026-06-01',
          dayTsSec: tsSec,
          dayHr: hr,
          sleepTsSec: tsSec,
          sleepHr: hr,
          sleepRrTsMs: rrTs,
          sleepRrMs: rrMs,
          sleepSkinTemp: List<int>.filled(n, 0),
          sleepJson: const {},
          hypnoStages: stages,
          sleepOnsetSec: t0,
          sleepOffsetSec: t0 + n,
          profile: const {'age': 30, 'sex': 'm', 'weight': 75, 'height': 178},
          useHmmStages: hmm,
        ).toJson());
    List<String> seq(Map<String, dynamic> b) => [
          for (final s in ((b['series'] as Map)['hypnogram'] as List).cast<Map>())
            s['stage'] as String,
        ];
    expect(seq(run(false)).toSet(), {'light', 'unobserved'});
    final on = seq(run(true));
    expect(on, contains('unobserved'));
    expect(on.toSet().difference({'light', 'unobserved'}), isNotEmpty);
  });
}
