import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

Map<String, dynamic> epoch(double hr, double rmssd, {double enmo = 0.0, double skinTemp = 0.0}) =>
    {'hr': hr, 'rmssd': rmssd, 'enmo': enmo, 'skin_temp': skinTemp};

SleepStageAnalyzer baselined() {
  final a = SleepStageAnalyzer();
  a.computeBaseline(List.generate(7200, (_) => epoch(55, 45, enmo: 0.01, skinTemp: 3350)));
  return a;
}

void main() {
  test('multi-night: 7d and long-term baselines are computed from histories', () {
    final a = baselined();
    final rhr = List<double>.generate(30, (_) => 55.0);
    final rmssd = List<double>.generate(30, (_) => 45.0);
    a.computeMultiNightBaselines(rhrHistory: rhr, rmssdHistory: rmssd);
    expect(a.hrMin7d, 55.0);
    expect(a.hrMinLong, 55.0);
    expect(a.rmssdMean7d, 45.0);
    expect(a.atypicalNight, isFalse);
    // effective baseline blends nightly + 7d
    expect(a.effectiveHrMin, 55.0);
  });

  test('multi-night: a deviating night is flagged atypical (outlier detection)', () {
    final a = SleepStageAnalyzer();
    // tonight's baseline is 12 bpm higher than the personal norm (illness/alcohol)
    a.computeBaseline(List.generate(7200, (_) => epoch(67, 45, enmo: 0.01, skinTemp: 3350)));
    final rhr = List<double>.generate(30, (_) => 55.0);
    a.computeMultiNightBaselines(rhrHistory: rhr, rmssdHistory: List.filled(30, 45.0));
    expect(a.atypicalNight, isTrue,
        reason: 'HR baseline +12 bpm vs long-term with tiny MAD must be an outlier night');
  });

  test('multi-night: no history -> no 7d/long-term, nightly baseline still works', () {
    final a = baselined();
    a.computeMultiNightBaselines();
    expect(a.hrMin7d, isNull);
    expect(a.hrMinLong, isNull);
    expect(a.effectiveHrMin, 55.0); // falls back to nightly
    expect(a.atypicalNight, isFalse);
  });

  test('multi-night: normal variation within long-term spread is NOT atypical', () {
    final a = baselined();
    // long-term history with realistic spread (±3 bpm), tonight at +2
    final rhr = [52.0, 53.0, 54.0, 55.0, 56.0, 57.0, 58.0, ...List.filled(23, 55.0)];
    a.computeMultiNightBaselines(rhrHistory: rhr, rmssdHistory: List.filled(30, 45.0));
    expect(a.atypicalNight, isFalse);
  });
}
