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
import 'package:openstrap_edge/compute/profile.dart';

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

    test('abstains on an empty HR series rather than reporting a bare BMR', () {
      // No heart rate at all is "we did not measure this day", which is not
      // the same claim as "this day burned exactly your BMR".
      expect(
        DerivationEngine.wakeDayEnergy(const <double>[], profile: _profile),
        isNull,
      );
    });
  });
}
