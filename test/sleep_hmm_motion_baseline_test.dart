import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

Map<String, dynamic> epoch(double hr, double rmssd, double ts, {double enmo = 0.0, double skinTemp = 0.0}) =>
    {'hr': hr, 'rmssd': rmssd, 'ts': ts, 'enmo': enmo, 'skin_temp': skinTemp};

void main() {
  test('motion baseline uses the stable core, not the restless opening', () {
    final a = SleepStageAnalyzer();
    // 8 h night: first 2 h restless (enmo 0.2 — settling in), core calm (0.01).
    final night = <Map<String, dynamic>>[
      for (var t = 0; t < 7200; t++) epoch(55, 45, t.toDouble(), enmo: 0.2, skinTemp: 3350),
      for (var t = 7200; t < 21600; t++) epoch(55, 45, t.toDouble(), enmo: 0.01, skinTemp: 3350),
      for (var t = 21600; t < 28800; t++) epoch(55, 45, t.toDouble(), enmo: 0.2, skinTemp: 3350),
    ];
    // opening-window baseline (old behavior) would see enmo 0.2:
    a.computeBaseline(night.take(7200).toList());
    expect(a.enmoMedianNight, 0.2);
    // core-based motion baseline sees the calm middle 50 %:
    a.computeMotionBaseline(night);
    expect(a.enmoMedianNight, 0.01);
  });

  test('motion baseline: absent ENMO (0 sentinel) never becomes the baseline', () {
    final a = SleepStageAnalyzer();
    final night = [for (var t = 0; t < 1000; t++) epoch(55, 45, t.toDouble(), enmo: -1.0)];
    a.computeMotionBaseline(night);
    expect(a.enmoMedianNight, isNull);
  });
}
