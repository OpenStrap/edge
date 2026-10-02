// Step calibration policy tests — pure, no DB, no BLE, no clock. Every rule
// under test is a pure function in step_calibration.dart (and the substrate
// counter walk in substrate.dart), which is exactly why they can be pinned
// here without fixtures.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/step_calibration.dart';

Substrate _sub(List<int> stepCount, {List<int>? ts, String? family}) {
  final n = ts?.length ?? stepCount.length;
  return Substrate(
    tsSec: ts ?? [for (var i = 0; i < n; i++) 1_700_000_000 + i],
    hr: List<int>.filled(n, 0),
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0.0),
    ay: List<double>.filled(n, 0.0),
    az: List<double>.filled(n, 1.0),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    stepCount: stepCount,
    deviceFamily: family,
  );
}

StepCalibrationDay _day(int ref, int ticks) =>
    StepCalibrationDay(referenceSteps: ref, counterTicks: ticks);

void main() {
  group('Wearing', () {
    test('codes are the closed set the column already defaults to', () {
      // The column has shipped DEFAULT 1 since schema v51; these integers
      // are frozen contract, not an enum's accident.
      expect(Wearing.wrist, 1);
      expect(Wearing.bicep, 2);
      expect(Wearing.other, 3);
    });
    test('an unknown code is null, never a silent fall to wrist', () {
      expect(Wearing.parse(99), isNull);
      expect(Wearing.parse(null), isNull);
      expect(Wearing.parse('2'), isNull);
      expect(Wearing.parse(3), Wearing.other);
    });
    test('wearingName covers every known code', () {
      expect(wearingName(Wearing.wrist), 'wrist');
      expect(wearingName(Wearing.bicep), 'bicep');
      expect(wearingName(Wearing.other), 'other');
    });
  });

  group('estimateStepCalibration', () {
    test('fewer than minDays admitted days stays uncalibrated', () {
      final p = estimateStepCalibration('gen5', Wearing.wrist,
          [_day(5000, 5000), _day(4000, 4000)]);
      expect(p.factor, 1.0);
      expect(p.nDays, 0);
      expect(p.isCalibrated, isFalse);
    });
    test('a learned factor of exactly 1.0 is still calibrated', () {
      // Phone and counter agree across three admitted days: the fitted
      // factor lands exactly on the prior. That is a LEARNED 1.0 with days
      // of evidence, not the cold-start prior — it must disclose its
      // calibration and earn its confidence.
      final p = estimateStepCalibration('gen5', Wearing.wrist, [
        _day(5000, 5000),
        _day(4000, 4000),
        _day(6000, 6000),
      ]);
      expect(p.factor, 1.0);
      expect(p.nDays, 3);
      expect(p.isCalibrated, isTrue);
    });
    test('the estimate is a ratio of sums, weighted by evidence', () {
      // A heavy day (10k ref, 20k ticks) plus two light days (1k ref, 1k
      // ticks each) — a mean of ratios would say 0.75; the ratio of sums
      // says 12k/22k, weighting the heavy day by its evidence.
      final p = estimateStepCalibration('gen5', Wearing.bicep, [
        _day(10000, 20000),
        _day(1000, 1000),
        _day(1000, 1000),
      ]);
      final raw = 12000 / 22000;
      final shrunk = (3 * raw + kStepFactorPriorWeight) / (3 + kStepFactorPriorWeight);
      expect(p.factor, shrunk.clamp(kStepFactorMin, kStepFactorMax));
      expect(p.nDays, 3);
      expect(p.isCalibrated, isTrue);
    });
    test('days the phone did not cover admit nothing', () {
      // reference 0 = the phone was in a drawer; a 10k-tick day with no
      // reference must not drag the factor toward zero.
      final p = estimateStepCalibration('gen5', Wearing.wrist,
          [_day(0, 10000), _day(0, 8000), _day(0, 9000)]);
      expect(p.isCalibrated, isFalse);
    });
    test('thin reference days are excluded by the floor', () {
      final p = estimateStepCalibration('gen5', Wearing.wrist, [
        _day(900, 5000), // under kStepCalMinReferenceSteps
        _day(950, 4000),
        _day(9000, 9000),
      ]);
      // One admitted day is under minDays 3 → uncalibrated.
      expect(p.nDays, 0);
      expect(p.isCalibrated, isFalse);
    });
    test('the factor is clamped to the documented error band', () {
      // Phone says 4x the ticks — a reference gone wrong, not a body.
      final p = estimateStepCalibration('gen5', Wearing.other, [
        _day(20000, 5000),
        _day(20000, 5000),
        _day(20000, 5000),
        _day(20000, 5000),
      ]);
      expect(p.factor, kStepFactorMax);
    });
    test('the prior is factor 1.0 at the current version', () {
      final p = StepCalibrationProfile.uncalibrated('gen5', Wearing.wrist);
      expect(p.version, kStepCalibrationVersion);
      expect(p.factor, 1.0);
    });
  });

  group('applyStepCalibration', () {
    final learned = const StepCalibrationProfile(
      deviceFamily: 'gen5',
      wearing: Wearing.bicep,
      factor: 1.5,
      nDays: 5,
      version: kStepCalibrationVersion,
    );
    test('an uncalibrated profile passes the raw ticks through', () {
      final p = StepCalibrationProfile.uncalibrated('gen5', Wearing.wrist);
      expect(applyStepCalibration(4000, p), 4000);
      expect(applyStepCalibration(4000, null), 4000);
    });
    test('a learned factor scales the total and rounds', () {
      expect(applyStepCalibration(4000, learned), 6000);
      expect(applyStepCalibration(4001, learned), 6002); // 6001.5 rounds
    });
    test('zero ticks stay zero — no steps out of nothing', () {
      expect(applyStepCalibration(0, learned), 0);
    });
    test('the output never exceeds factorMax times the raw', () {
      // Defensive: any upstream integer weirdness is bounded.
      final big = const StepCalibrationProfile(
        deviceFamily: 'gen5',
        wearing: Wearing.wrist,
        factor: 3.0, // past the clamp, so only the output bound holds it
        nDays: 9,
        version: kStepCalibrationVersion,
      );
      expect(applyStepCalibration(5000, big), 10000);
    });
  });

  group('stepCounterConfidence', () {
    test('uncalibrated keeps the historical 0.9', () {
      expect(stepCounterConfidence(null), 0.9);
      expect(
        stepCounterConfidence(
            StepCalibrationProfile.uncalibrated('gen5', Wearing.wrist)),
        0.9,
      );
    });
    test('evidence earns confidence up to a proxy ceiling of 0.98', () {
      final few = const StepCalibrationProfile(
        deviceFamily: 'gen5',
        wearing: Wearing.wrist,
        factor: 1.2,
        nDays: 4,
        version: kStepCalibrationVersion,
      );
      final many = const StepCalibrationProfile(
        deviceFamily: 'gen5',
        wearing: Wearing.wrist,
        factor: 1.2,
        nDays: 400,
        version: kStepCalibrationVersion,
      );
      final cFew = stepCounterConfidence(few);
      expect(cFew, greaterThan(0.9));
      expect(cFew, lessThan(stepCounterConfidence(many)));
      expect(stepCounterConfidence(many), lessThanOrEqualTo(0.98));
    });
  });

  group('counterDeltasFromSubstrate — the honesty walk', () {
    test('a dense gap-free run reports zero gap seconds', () {
      final d = counterDeltasFromSubstrate(
        _sub([100, 102, 105, 105, 109]),
        cumulativeCounterModulus: 65536,
      )!;
      expect(d.total, 9);
      expect(d.gapSeconds, 0);
      expect(d.droppedBoundaries, 0);
      expect(d.sampleCount, 5);
    });
    test('a sync gap is reported in seconds, not silently absorbed', () {
      final d = counterDeltasFromSubstrate(
        _sub(
          [100, 104, 200, 204],
          ts: [0, 1, 3600, 3601].map((t) => 1_700_000_000 + t).toList(),
        ),
        cumulativeCounterModulus: 65536,
      )!;
      // 3598 unsampled seconds between the two spans.
      expect(d.gapSeconds, 3598);
      expect(d.total, 104); // 4 + 96 across the gap + 4
    });
    test('a reset boundary is counted as dropped, not as a wrap', () {
      // 40000 -> 0: modulo 65536 reads 25536, over budget → dropped.
      final d = counterDeltasFromSubstrate(
        _sub(
          [40000, 40004, 0, 4],
          ts: [0, 60, 3600, 3660].map((t) => 1_700_000_000 + t).toList(),
        ),
        cumulativeCounterModulus: 65536,
      )!;
      expect(d.droppedBoundaries, 1);
      // 4 before the reset, 4 after it — both real deltas; only the
      // boundary itself (40004 -> 0) is dropped.
      expect(d.total, 8);
    });
    test('absent counter (gen4) is null, not zero', () {
      expect(
        counterDeltasFromSubstrate(
          _sub([-1, -1, -1]),
          cumulativeCounterModulus: 65536,
        ),
        isNull,
      );
      // And no modulus declared → no walk at all.
      expect(
        counterDeltasFromSubstrate(_sub([100, 104]),
            cumulativeCounterModulus: null),
        isNull,
      );
    });
    test('the bare-total wrapper agrees with the walk', () {
      final s = _sub([100, 104, 200, 65530, 65534, 2, 6],
          ts: [0, 60, 3600, 7200, 7260, 10800, 10860]
              .map((t) => 1_700_000_000 + t)
              .toList());
      expect(
        hardwareStepsFromCounter(s, cumulativeCounterModulus: 65536),
        counterDeltasFromSubstrate(s, cumulativeCounterModulus: 65536)!
            .total,
      );
    });
  });

  group('counterTicksPerWindow', () {
    const t0 = 1_700_000_000;
    // 1 Hz counter rising 1 per second over [0, 600) and [1200, 1800); the
    // band is off (no records) over [600, 1200).
    final ts = [
      for (var t = 0; t < 600; t++) t0 + t,
      for (var t = 1200; t < 1800; t++) t0 + t,
    ];
    final s = _sub([for (var i = 0; i < ts.length; i++) i], ts: ts);

    test('counts only inside a window the counter saw end to end', () {
      final w = counterTicksPerWindow(
        s,
        [(t0 + 100, t0 + 400), (t0 + 500, t0 + 1300), (t0 + 1300, t0 + 1700)],
        cumulativeCounterModulus: 65536,
      )!;
      expect(w[0], 300);
      expect(w[1], isNull); // the band was off for part of it
      expect(w[2], 400);
    });

    test('no counter on the family is null, not zero', () {
      expect(
        counterTicksPerWindow(_sub([-1, -1]), [(t0, t0 + 1)],
            cumulativeCounterModulus: 65536),
        isNull,
      );
    });
  });
}
