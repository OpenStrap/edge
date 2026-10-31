// Pins the cadence band the calibration fits its gait categories against to the
// band the SESSION logic already uses.
//
// `lib/compute/step_calibration_fit.dart` redeclares this band rather than
// importing it — it is deliberately dependency-free (pure, no analytics, no
// I/O). That makes a silent drift possible, and a silent drift here is the bad
// kind: the calibration would build category bands the session logic disagrees
// with, so a minute could be "walking" to one and "not walking" to the other,
// and the correction would be applied to windows the rest of the app would not
// call gait.
//
// So the pair is pinned in both directions, the same DERIVED-OR-PINNED
// convention `live_step_runs.dart` uses for `kRouteTypeKeys`: a deliberate
// change to either constant fails this test instead of quietly splitting the
// definition of gait.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ble/live_cadence.dart'
    show kMinCadenceSpm, kMaxCadenceSpm;
import 'package:openstrap_edge/compute/step_calibration_fit.dart';

void main() {
  test('calibration gait band equals the session gait band', () {
    expect(kGaitCadenceMinSpm, kMinCadenceSpm.toDouble());
    expect(kGaitCadenceMaxSpm, kMaxCadenceSpm.toDouble());
  });

  test('the band identifies gait, not AN-2554 interval bounds', () {
    // AN-2554's 0.5-5 steps/s (30-300 spm) is the widest interval a human gait
    // interval may have — what the COUNTER accepts. The band that identifies a
    // minute as ambulation is narrower, and a 40 spm "minute" is a few steps to
    // the kettle. If this test fails because someone widened the band to the
    // AN-2554 range, the everyday family will start absorbing slow walks.
    expect(kGaitCadenceMinSpm, greaterThan(30));
    expect(kGaitCadenceMaxSpm, lessThan(300));
  });

  test('an everyday run has no gait band at all', () {
    final run = StepCalibrationRun(
      category: StepCategory.everyday,
      reference: StepReference.phonePedometer,
      expectedSteps: 55,
      rawSteps: 400,
      cadenceSpm: 95,
      peakToPeakG: 1.4,
      confidence: 0.35,
    );
    expect(categoryBand(StepCategory.everyday, [run]), isNull);
  });
}
