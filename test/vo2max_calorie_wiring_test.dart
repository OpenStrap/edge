// The fitness anchor has to actually reach the calorie estimator.
//
// `vo2maxEstimate` (Uth: 15.3 x HRmax/RHR) was already computed in the crossday
// pipeline and shown on the Body screen, while every calorie path ran Keytel's
// age/mass/sex-only model — the weaker of the two the paper publishes. The
// input existed and the consumer that most benefits from it never saw it.
//
// VO2max here is DERIVED, not measured: it is a function of resting HR and
// Tanaka HRmax, so threading it in is really "let resting heart rate inform the
// calorie estimate", which is a genuine and independent fitness signal rather
// than a circular one. It stays optional everywhere — a profile with no
// resting HR gets exactly the numbers it got before.
//
// Every path must pick it up together. Wiring one and not another is how the
// live tick and the substrate re-score drifted apart in the first place.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/app_state.dart';

const _profile = Profile(
  ageYears: 34,
  weightKg: 72,
  heightCm: 178,
  sex: 'm',
);

// Tanaka HRmax = 184.2. A 45 bpm resting HR is a fit athlete:
//   Uth VO2max = 15.3 * (184.2 / 45) = 62.63 ml/kg/min
// and the bout gate sits at 45 + 0.30*(184.2-45) = 86.76 bpm.
const _fitRestingHr = 45.0;

final _startedAt = DateTime(2026, 1, 1, 7);
final _ts = [
  for (var i = 0; i < 600; i++)
    (_startedAt.millisecondsSinceEpoch ~/ 1000) + i,
];
final _bpm = [for (var i = 0; i < 600; i++) 140];

void main() {
  test('the substrate re-score costs a fit athlete on the fitness model', () {
    final s = computeManualSessionStats(
      hrTs: _ts,
      hrBpm: _bpm,
      profile: _profile,
      zoneMaxHr: 184.2,
      restingHr: _fitRestingHr,
    );

    // Fitness-adjusted (VO2max 62.63):
    //   -95.7735 + 0.271*34 + 0.394*72 + 0.404*62.63 + 0.634*140
    //     = 55.870 kJ/min -> /251.04 * 600 s = 133.53 kcal
    expect(s.calories, isNotNull);
    expect(s.calories, closeTo(133.53, 0.2));

    // The age/mass/sex-only model would have said 54.4005 kJ/min -> 130.02.
    expect(
      s.calories,
      isNot(closeTo(130.02, 0.5)),
      reason: 'a 45 bpm resting HR is a real fitness signal and must move the '
          'estimate off the cohort-average model',
    );
  });

  test('the live tick costs the same athlete identically', () {
    // Parity is the property that must survive this change, not just each
    // path's own correctness.
    final live = LiveWorkoutState(
      startTime: _startedAt,
      targetKcal: 300,
      profile: _profile,
      restingHr: _fitRestingHr,
    );
    for (var i = 0; i < 600; i++) {
      live.elapsed = Duration(seconds: i);
      live.accrueHr(_bpm[i]);
    }

    final rescore = computeManualSessionStats(
      hrTs: _ts,
      hrBpm: _bpm,
      profile: _profile,
      zoneMaxHr: 184.2,
      restingHr: _fitRestingHr,
    );

    expect(live.calories, closeTo(rescore.calories!, 0.25));
    expect(live.calories, closeTo(133.53, 0.2));
  });

  test('the day derivation costs a fit athlete on the fitness model too', () {
    final day = <double>[
      for (var i = 0; i < 60; i++) 140.0,
      for (var i = 0; i < 1380; i++) 50.0,
    ];

    final fit = DerivationEngine.wakeDayEnergy(
      day,
      profile: _profile,
      restingHr: _fitRestingHr,
    );
    final anchorless = DerivationEngine.wakeDayEnergy(day, profile: _profile);

    expect(fit, isNotNull);
    expect(anchorless, isNotNull);
    expect(
      fit!.active,
      greaterThan(anchorless!.active),
      reason: 'VO2max 62.63 is above the cohort mean the age/mass/sex model '
          'assumes, so this athlete burns more at the same heart rate',
    );
    expect(
      fit.basal,
      closeTo(anchorless.basal, 1e-9),
      reason: 'Mifflin has no fitness term',
    );
  });

  test('no resting HR means no fitness term, not a fabricated one', () {
    // Uth needs a resting HR. Without one the estimate must fall back to the
    // published age/mass/sex model rather than inventing a fitness level.
    final day = <double>[
      for (var i = 0; i < 60; i++) 140.0,
      for (var i = 0; i < 1380; i++) 50.0,
    ];

    final withoutRhr = DerivationEngine.wakeDayEnergy(day, profile: _profile)!;
    final reference = ana.Calories.dailyEnergy(
      day,
      profile: const ana.WorkoutUserProfile(
        weightKg: 72,
        heightCm: 178,
        age: 34,
        sex: 'male',
      ),
      hrmax: 184.2,
    );

    expect(withoutRhr.active, closeTo(reference.active, 1e-9));
    expect(withoutRhr.total, closeTo(reference.total, 1e-9));
  });

  test('the pure day pipeline picks the anchor up too', () {
    // `deriveDayBundle` was the one calorie path with no test at all, and the
    // one that kept its OWN copy of the anchor closure rather than calling the
    // shared helper. Both are covered here.
    Map<String, dynamic> bundleFor({int? restingHr}) {
      const dayStart = 1767225600;
      const hours = 3;
      final ts = <int>[];
      final hr = <int>[];
      for (var t = dayStart; t < dayStart + hours * 3600; t++) {
        ts.add(t);
        hr.add(140);
      }
      return deriveDayBundle(
        DayBundleInput(
          date: '2026-01-01',
          dayTsSec: ts,
          dayHr: hr,
          // No sleep window: onset == offset, so nothing is excluded from the
          // wake series and `rhrToday` stays absent, which is what lets the
          // profile's own resting HR be the variable under test.
          sleepTsSec: const [],
          sleepHr: const [],
          sleepRrTsMs: const [],
          sleepRrMs: const [],
          sleepSpo2Red: const [],
          sleepSpo2Ir: const [],
          sleepSkinTemp: const [],
          sleepJson: const {},
          hypnoStages: const [],
          sleepOnsetSec: 0,
          sleepOffsetSec: 0,
          profile: {
            'age': 34,
            'sex': 'm',
            'weight_kg': 72,
            'height_cm': 178,
            'resting_hr': ?restingHr,
          },
          dayConfidence: 1.0,
          dayFlags: const [],
        ).toJson(),
      );
    }

    final anchorless = bundleFor()['calories'] as num?;
    final fit = bundleFor(restingHr: 45)['calories'] as num?;

    expect(anchorless, isNotNull, reason: 'the day has heart rate and a profile');
    expect(fit, isNotNull);

    // 180 wake minutes at 140 bpm, netting the basal minute out of each.
    // Mifflin (male, 72 kg, 178 cm, 34 y) = 1667.5/day = 1.15799 kcal/min.
    //   age/mass/sex model: 54.4005 kJ/min = 13.00203 kcal/min
    //     -> (13.00203 - 1.15799) * 180 = 2131.9 kcal
    //   VO2max 62.63 model:  55.8703 kJ/min = 13.35333 kcal/min
    //     -> (13.35333 - 1.15799) * 180 = 2195.2 kcal
    expect(anchorless!.toDouble(), closeTo(2131.9, 2.0));
    expect(fit!.toDouble(), closeTo(2195.2, 2.0));
    expect(
      fit,
      greaterThan(anchorless),
      reason: 'a 45 bpm resting HR is above the cohort mean fitness the '
          'age/mass/sex model bakes in',
    );
  });

  test('every path resolves the fitness anchor from one definition', () {
    // The pipeline used to inline its own copy of this, whose sex mapping
    // accepted 'f' but not 'female' — inert only because `vo2maxEstimate`
    // ignores its sex and age arguments today. Pin the agreement rather than
    // depending on that staying true.
    const short = Profile(ageYears: 34, weightKg: 72, sex: 'f');
    const long = Profile(ageYears: 34, weightKg: 72, sex: 'female');
    const capitalised = Profile(ageYears: 34, weightKg: 72, sex: 'Female');

    expect(vo2maxFor(short, 55), isNotNull);
    expect(vo2maxFor(long, 55), vo2maxFor(short, 55));
    expect(vo2maxFor(capitalised, 55), vo2maxFor(short, 55));

    expect(
      vo2maxAnchor(
        restingHr: 55,
        maxHr: short.hrMaxTanaka,
        sex: 'female',
        age: 34,
      ),
      vo2maxFor(short, 55),
      reason: 'the raw-value entry point the pure pipeline uses and the '
          'Profile-shaped one must be the same function',
    );

    // And the sex normalisation itself, which both the calorie coefficients and
    // Banister's constant now key on.
    expect(workoutSex('f'), 'female');
    expect(workoutSex('female'), 'female');
    expect(workoutSex('m'), 'male');
    expect(workoutSex('male'), 'male');
    // Reachable from the profile screen, whose options are male/female/other.
    expect(workoutSex('other'), 'nonbinary');
    expect(workoutSex(null), 'nonbinary');
  });

  test('an implausible resting HR does not poison the estimate', () {
    // A 0/negative RHR is the package's off-skin sentinel, and vo2maxEstimate
    // already abstains on it. The calorie path must inherit that abstention
    // rather than divide by it.
    final day = <double>[for (var i = 0; i < 60; i++) 140.0];

    final poisoned =
        DerivationEngine.wakeDayEnergy(day, profile: _profile, restingHr: 0);
    final clean = DerivationEngine.wakeDayEnergy(day, profile: _profile);

    expect(poisoned, isNotNull);
    expect(poisoned!.active, closeTo(clean!.active, 1e-9));
    expect(poisoned.active.isFinite, isTrue);
  });
}
