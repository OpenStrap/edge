// A night the strap spent partly warming up reads low. Readiness refuses it as
// tonight's temp input; it must not be banked as `skin_temp_adc` either, or it
// sits in every later night's baseline and drags the median and SD with it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  Map<String, dynamic> scalars(List<int> temps, List<double> history) {
    const t0 = 1780000000;
    const n = 6 * 3600;
    final b = deriveDayBundle(
      DayBundleInput(
        date: '2026-06-01',
        dayTsSec: [for (var i = 0; i < n; i++) t0 + i],
        dayHr: List<int>.filled(n, 60),
        sleepTsSec: const [],
        sleepHr: const [],
        sleepRrTsMs: const [],
        sleepRrMs: const [],
        sleepSkinTemp: temps,
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        profile: const {},
        skinTempAdcHistory: history,
        deviceFamily: 'gen4',
      ).toJson(),
    );
    return (b['scalars'] as Map).cast<String, dynamic>();
  }

  const history = [995.0, 1000.0, 1005.0, 998.0, 1002.0];

  test('a night with half of it cold is not banked and gets no z', () {
    final temps = [
      ...List<int>.filled(200, 500),
      ...List<int>.filled(200, 1000),
    ];
    final s = scalars(temps, history);
    expect(s['skin_temp_settled_frac'] as num, lessThan(0.8));
    expect(s['skin_temp_adc'], isNull);
    expect(s['skin_temp_z'], isNull);
  });

  test('a settled night is still banked and z-scored', () {
    final temps = [
      ...List<int>.filled(10, 500),
      ...List<int>.filled(390, 1000),
    ];
    final s = scalars(temps, history);
    expect(s['skin_temp_settled_frac'] as num, greaterThanOrEqualTo(0.8));
    expect(s['skin_temp_adc'], isNotNull);
    expect(s['skin_temp_z'], isNotNull);
  });

  test('a night that passes the gate banks its settled mean, not the raw one',
      () {
    // 15% of the night reads 250 counts low (warm-up after charging). That is
    // over the 0.80 gate, so the night counts — but the cold samples must not
    // be averaged into it: the raw mean is 962.5, ~10 SD below this baseline.
    final temps = [
      ...List<int>.filled(60, 750),
      ...List<int>.filled(340, 1000),
    ];
    final s = scalars(temps, history);
    expect(s['skin_temp_settled_frac'] as num, closeTo(0.85, 1e-6));
    expect(s['skin_temp_adc'] as num, closeTo(1000, 1e-6));
    expect(s['skin_temp_z'] as num, closeTo(0, 1e-6));
  });
}
