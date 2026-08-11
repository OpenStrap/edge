// The day's ACTIVE calories and its TOTAL calories must come from one HR-flex
// pass, so that `calories_total - calories == basal` holds by construction.
//
// They used to come from two different implementations. `calories` was summed
// by a derivation-local copy of Keytel (`_keytelCaloriesWake`) that billed the
// FULL Keytel rate on every active minute, while `calories_total` came from
// `ana.Calories.dailyEnergy`, whose active component nets out the basal minute
// you are also counting inside the total. The same minute was therefore paid
// for twice in `calories`: once as basal (inside total) and again as part of
// the active rate. Active read high by exactly basalPerMin x active-minutes,
// and the basal figure the Health export derives as `total - active` read low
// by the same amount.
//
// The expected values below are computed by hand from the published formulas
// (Mifflin-St Jeor 1990 for BMR, Keytel 2005 for the active rate) so this test
// pins real arithmetic rather than whatever the implementation happens to emit.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

// age 34 -> Tanaka HRmax = 208 - 0.7*34 = 184.2, HR-flex point = 0.50 * = 92.1
const _profile = Profile(
  ageYears: 34,
  weightKg: 72,
  heightCm: 178,
  sex: 'm',
);

// Mifflin-St Jeor (male): 10*72 + 6.25*178 - 5*34 + 5 = 1667.5 kcal/day
const _bmrDay = 1667.5;
const _basalPerMin = _bmrDay / 1440.0; // 1.15798611... kcal/min

// Keytel (male) at HR 140, 72 kg, age 34:
//   -55.0969 + 0.6309*140 + 0.1988*72 + 0.2017*34 = 54.4005 kJ/min
//   54.4005 / 4.184                               = 13.002032 kcal/min
const _keytelKcalMinAt140 = 54.4005 / 4.184;

/// A day with one hard hour and the rest spent at rest. The 55 bpm minutes sit
/// below the 92.1 flex point, so they contribute nothing to active — that is
/// the whole point of HR-flex, and it is what keeps a quiet day reading as
/// basal instead of inheriting Keytel's low-HR overestimate.
const _activeMinutes = 60;
final _dayHr = <double>[
  for (var i = 0; i < _activeMinutes; i++) 140.0,
  for (var i = 0; i < 1440 - _activeMinutes; i++) 55.0,
];

void main() {
  group('DerivationEngine.wakeDayEnergy', () {
    test('active calories net out the basal minute, not double-count it', () {
      final e = DerivationEngine.wakeDayEnergy(_dayHr, profile: _profile);

      expect(e, isNotNull);

      // The regression this test exists for. The old derivation-local sum
      // billed the full Keytel rate per active minute:
      final doubleCounted = _keytelKcalMinAt140 * _activeMinutes; // ~780.12
      // HR-flex bills only the SURPLUS over the basal minute:
      final correct =
          (_keytelKcalMinAt140 - _basalPerMin) * _activeMinutes; // ~710.64

      expect(e!.active, closeTo(correct, 0.5));
      expect(
        e.active,
        lessThan(doubleCounted - 60.0),
        reason: 'active must be short of the naive Keytel sum by roughly '
            'basalPerMin x $_activeMinutes = ${(_basalPerMin * _activeMinutes).toStringAsFixed(1)} kcal',
      );
    });

    test('total is the full-day basal floor plus the active surplus', () {
      final e = DerivationEngine.wakeDayEnergy(_dayHr, profile: _profile)!;

      expect(e.basal, closeTo(_bmrDay, 0.5));
      expect(e.total, closeTo(e.basal + e.active, 0.001));
    });

    test('total - active == basal, the invariant the Health export relies on', () {
      // health_export writes BASAL_ENERGY_BURNED as calories_total - calories.
      // When the two came from different implementations that subtraction
      // silently produced a basal figure that was too low.
      final e = DerivationEngine.wakeDayEnergy(_dayHr, profile: _profile)!;

      expect(e.total - e.active, closeTo(e.basal, 0.001));
    });

    test('a day spent entirely below the flex point reads as pure basal', () {
      final quiet = <double>[for (var i = 0; i < 1440; i++) 55.0];

      final e = DerivationEngine.wakeDayEnergy(quiet, profile: _profile)!;

      expect(e.active, 0.0);
      expect(e.total, closeTo(_bmrDay, 0.5));
    });

    test('abstains when the profile lacks a Keytel anchor', () {
      // Matches Profile.hasCalorieAnchors: age, body mass and sex. Absent beats
      // fabricated — the engine must not fall back to a stand-in body.
      expect(
        DerivationEngine.wakeDayEnergy(
          _dayHr,
          profile: const Profile(weightKg: 72, sex: 'm'),
        ),
        isNull,
        reason: 'age is a Keytel term',
      );
      expect(
        DerivationEngine.wakeDayEnergy(
          _dayHr,
          profile: const Profile(ageYears: 34, sex: 'm'),
        ),
        isNull,
        reason: 'body mass is a Keytel term',
      );
      expect(
        DerivationEngine.wakeDayEnergy(
          _dayHr,
          profile: const Profile(ageYears: 34, weightKg: 72),
        ),
        isNull,
        reason: 'the formula has a different constant per sex',
      );
    });

    test('abstains without a height, and the whole triple goes with it', () {
      // Height is not a Keytel term, so the instinct is that only the basal
      // floor needs it and the ACTIVE figure could still be published. It
      // cannot: `dailyEnergy` defines active as the surplus over the Mifflin
      // basal minute, so the height term is inside active too. Standing 170 cm
      // in moves a scalar that is persisted to `day_result` and exported to
      // Apple Health.
      const noHeight = Profile(ageYears: 34, weightKg: 72, sex: 'm');
      expect(DerivationEngine.wakeDayEnergy(_dayHr, profile: noHeight), isNull);
    });

    test('a stand-in height would move ACTIVE, not just the basal floor', () {
      // The measurement behind the gate above, pinned so the reasoning cannot
      // quietly stop being true. Same profile, same series, height alone.
      const short = Profile(ageYears: 35, weightKg: 80, heightCm: 150, sex: 'm');
      const tall = Profile(ageYears: 35, weightKg: 80, heightCm: 195, sex: 'm');
      final hr = <double>[for (var i = 0; i < 600; i++) 130.0];

      final s = DerivationEngine.wakeDayEnergy(hr, profile: short)!;
      final t = DerivationEngine.wakeDayEnergy(hr, profile: tall)!;

      expect((s.active - t.active).abs(), greaterThan(100.0));
      expect((s.total - t.total).abs(), greaterThan(100.0));
    });

    test('abstains on an empty HR series rather than reporting a bare BMR', () {
      // No heart rate at all is "we did not measure this day", which is not
      // the same claim as "this day burned exactly your BMR".
      expect(
        DerivationEngine.wakeDayEnergy(const <double>[], profile: _profile),
        isNull,
      );
    });
  });

  // The helper above holds the invariant on its own. The invariant that matters
  // is the one on the PERSISTED PAIR, and that is a different claim: the
  // scalars survive a whole day-block composition after the helper returns, and
  // a second `dailyEnergy` further down that composition — differently gated
  // and over a different span — used to overwrite `calories_total` on the way
  // out. Every assertion in the group above passed
  // throughout, which is exactly why the group below exists.
  group('the scalar pair a persisted day carries', () {
    // A 70-year-old is the sharpest case for the wake-vs-whole-day question:
    // `dailyEnergy`'s flex gate is 0.50 x Tanaka HRmax = 104 - 0.35*age, so at
    // 70 it sits at 79.5 bpm — under a perfectly ordinary sleeping heart rate.
    const older = Profile(ageYears: 70, weightKg: 80, heightCm: 175, sex: 'm');
    // Mifflin (male): 10*80 + 6.25*175 - 5*70 + 5 = 1548.75 kcal/day
    const olderBasalPerMin = 1548.75 / 1440.0;

    // Six hours of substrate: two asleep at 82 bpm (above the 79.5 flex point),
    // one awake and working at 120, three awake and quiet at 60.
    const dayStart = 1767225600; // a whole minute, so the sleep window aligns
    const sleepOnset = dayStart;
    const sleepOffset = dayStart + 2 * 3600;
    const hardUntil = dayStart + 3 * 3600;
    const dayEnd = dayStart + 6 * 3600;

    Substrate build() {
      final ts = <int>[];
      final hr = <int>[];
      final ax = <double>[], ay = <double>[], az = <double>[];
      for (var t = dayStart; t < dayEnd; t++) {
        ts.add(t);
        hr.add(t < sleepOffset ? 82 : (t < hardUntil ? 120 : 60));
        // A little movement so ENMO produces real minutes; the figures under
        // test are HR-driven and do not depend on its magnitude.
        ax.add(0.01 * ((t % 7) - 3));
        ay.add(0.01 * ((t % 5) - 2));
        az.add(1.0);
      }
      final n = ts.length;
      return Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: List<int>.filled(n, 0),
        spo2Ir: List<int>.filled(n, 0),
        skinTemp: List<int>.filled(n, 0),
        skinContact: List<int>.filled(n, 0),
      );
    }

    ({Map<String, dynamic> bundle, Map<String, dynamic> scalars}) run() {
      final bundle = <String, dynamic>{};
      final scalars = <String, dynamic>{};
      DerivationEngine.applyDayActivity(
        bundle: bundle,
        scalars: scalars,
        daySub: build(),
        profile: older,
        sleepOnsetSec: sleepOnset,
        sleepOffsetSec: sleepOffset,
      );
      return (bundle: bundle, scalars: scalars);
    }

    test('calories_total - calories == basal on the pair, not just the helper',
        () {
      final out = run();
      final active = out.scalars['calories'] as double;
      final total = out.scalars['calories_total'] as double;
      final block = (out.bundle['calories_total'] as Map).cast<String, dynamic>();

      // The subtraction health_export performs to write BASAL_ENERGY_BURNED.
      expect(total - active, closeTo((block['basal'] as int).toDouble(), 0.51));
      // Six covered hours of Mifflin, pro-rated: 1.07552 * 360 = 387.19 kcal.
      expect(total - active, closeTo(olderBasalPerMin * 360, 2.0));
    });

    test('sleep is not billed as active energy', () {
      final out = run();
      final active = out.scalars['calories'] as double;

      // Only the hard wake hour is active. Keytel (male, 80 kg, 70 y) at 120
      // bpm is 50.6341 kJ/min = 12.1018 kcal/min; netting the basal minute
      // leaves 11.0263 kcal/min over 60 minutes.
      expect(active, closeTo(661.58, 2.0));

      // Scoring the whole-day series instead would add the two sleeping hours:
      // Keytel at 82 bpm is 6.3721 kcal/min, 5.2966 over basal, x 120 minutes =
      // 635.6 kcal of fabricated "active" energy per night.
      expect(
        active,
        lessThan(800.0),
        reason: 'an 82 bpm sleeping heart rate clears the 79.5 bpm flex gate, '
            'so a whole-day active term bills the night as exercise',
      );
    });

    test('the quiet wake hours contribute nothing, and are not dropped', () {
      // The three hours at 60 bpm sit below the flex point, so they add no
      // active energy — but they are still COVERED minutes and must still be
      // billed basal, or a sedentary afternoon shortens the day's BMR.
      final out = run();
      final block = (out.bundle['calories_total'] as Map).cast<String, dynamic>();

      expect(block['basal'] as int, closeTo(olderBasalPerMin * 360, 2.0));
      expect(block['active'] as int, closeTo(661.58, 2.0));
      // Within a kcal, not exactly equal. The three ints are rounded
      // independently off one double triple that DOES satisfy
      // total == basal + active, and round(a + b) is not round(a) + round(b)
      // once the fractional parts carry. This fixture happens not to carry, so
      // exact equality passed on the arithmetic of these particular numbers and
      // would have failed by one on a different bpm, duration or profile while
      // the production invariant stayed intact. The exact form is asserted on
      // the doubles above, which is where it actually holds.
      expect(
        ((block['value'] as int) -
                ((block['active'] as int) + (block['basal'] as int)))
            .abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('an unanchored profile leaves the pair absent, not zero', () {
      // No sex means no Keytel coefficient block. The day still has heart rate,
      // movement and a step count; it must simply carry no calorie figure.
      final bundle = <String, dynamic>{};
      final scalars = <String, dynamic>{};
      DerivationEngine.applyDayActivity(
        bundle: bundle,
        scalars: scalars,
        daySub: build(),
        profile: const Profile(ageYears: 70, weightKg: 80, heightCm: 175),
        sleepOnsetSec: sleepOnset,
        sleepOffsetSec: sleepOffset,
      );

      expect(scalars.containsKey('calories'), isFalse);
      expect(scalars.containsKey('calories_total'), isFalse);
      expect(bundle.containsKey('calories_total'), isFalse);
      // The unrelated blocks still ran — abstaining from energy must not
      // silently take movement down with it.
      expect(bundle['movement'], isNotNull);
    });
  });

  // The 1 Hz pipeline computes the SAME active quantity for the early-read path
  // that Today draws before a full day result exists. It has to gate on height
  // for the same reason `wakeDayEnergy` does, or Today shows an imputed figure
  // that the derived day then withdraws.
  group('the pure pipeline mirrors the gate', () {
    const dayStart = 1767225600;
    const n = 3600;

    Map<String, dynamic> bundleFor(Map<String, dynamic> profile) {
      final ts = [for (var i = 0; i < n; i++) dayStart + i];
      final hr = [for (var i = 0; i < n; i++) 130];
      return deriveDayBundle(
        DayBundleInput(
          date: '2026-01-01',
          dayTsSec: ts,
          dayHr: hr,
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
          profile: profile,
          dayConfidence: 0.5,
          dayFlags: const [],
        ).toJson(),
      );
    }

    num? caloriesOf(Map<String, dynamic> profile) {
      final scalars =
          (bundleFor(profile)['scalars'] as Map).cast<String, dynamic>();
      return scalars['calories'] as num?;
    }

    test('scores the day when the profile carries a real height', () {
      expect(
        caloriesOf(const {
          'age': 34,
          'sex': 'm',
          'weight_kg': 72,
          'height_cm': 178,
        }),
        isNotNull,
      );
    });

    test('abstains without one instead of standing 170 cm in', () {
      expect(
        caloriesOf(const {'age': 34, 'sex': 'm', 'weight_kg': 72}),
        isNull,
        reason: 'the active term is a surplus over the Mifflin basal minute, '
            'so an imputed height moves it',
      );
    });
  });
}
