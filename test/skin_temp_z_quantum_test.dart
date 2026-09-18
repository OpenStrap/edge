// Bug: `skin_temp_z` (onehz_pipeline.dart) standardized today's raw skin-temp
// ADC mean against the baseline history's SD with only an `sd > 0` gate — no
// floor for the ADC channel's own quantization step. analytics already
// guards this exact channel (`tempInput(..., quantum: 1)` in
// readiness_composite.dart), refusing when the baseline SD sits below 1 ADC
// count even though it is nonzero. A baseline oscillating between two
// adjacent ADC counts has SD ~0.5-0.6 — nonzero, but sub-quantum — and the
// old gate let that noise standardize into an inflated z that feeds
// `tempIllnessFlag`/`multivariateAnomaly` and the raw health_screen display.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  Map<String, dynamic> bundle(List<double> adcHistory) {
    const t0 = 1780000000;
    const n = 6 * 3600;
    return deriveDayBundle(
      DayBundleInput(
        date: '2026-06-01',
        dayTsSec: [for (var i = 0; i < n; i++) t0 + i],
        dayHr: List<int>.filled(n, 60),
        sleepTsSec: const [],
        sleepHr: const [],
        sleepRrTsMs: const [],
        sleepRrMs: const [],
        // 60+ valid samples ⇒ today's raw skin-temp ADC mean is computable.
        sleepSkinTemp: List<int>.filled(60, 30005),
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        profile: const {},
        skinTempAdcHistory: adcHistory,
        deviceFamily: 'gen4',
      ).toJson(),
    );
  }

  test(
    'a baseline oscillating between two adjacent ADC counts (SD < 1) '
    'abstains rather than reporting an inflated z',
    () {
      final b = bundle([30000, 30001, 30000]); // SD ≈ 0.577
      expect((b['scalars'] as Map)['skin_temp_z'], isNull);
    },
  );

  test(
    'a baseline with a real ADC spread (SD ≥ 1) still computes z',
    () {
      final b = bundle([29990, 30000, 30010]); // SD = 10
      expect((b['scalars'] as Map)['skin_temp_z'], isNotNull);
    },
  );

  test(
    'boundary: SD exactly at the 1-ADC-count quantum still computes',
    () {
      final b = bundle([29999, 30000, 30001]); // SD = 1.0 exactly
      expect((b['scalars'] as Map)['skin_temp_z'], isNotNull);
    },
  );
}
