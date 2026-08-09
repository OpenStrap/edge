// Calories are only ever reported for a profile that carries the anchors
// Keytel (2005) actually reads.
//
// The live 1 Hz tick used to substitute 30 years / 70 kg / male for whatever
// the profile was missing, while the substrate re-score refused to guess. So
// an untouched profile produced a confident kcal total for a stand-in body —
// and since 70 kg is heavier than a lot of people, it read high, which is
// exactly the "calories are always overstated" complaint. Both paths now share
// one predicate.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/app_state.dart';

const _anchored = Profile(ageYears: 34, weightKg: 72, sex: 'm');

LiveWorkoutState _session(Profile p) => LiveWorkoutState(
  startTime: DateTime(2026, 1, 1, 7),
  targetKcal: 300,
  profile: p,
);

void main() {
  group('Profile.hasCalorieAnchors', () {
    test('needs age, mass and sex', () {
      expect(_anchored.hasCalorieAnchors, isTrue);
      expect(const Profile().hasCalorieAnchors, isFalse);
      expect(
        const Profile(weightKg: 72, sex: 'm').hasCalorieAnchors,
        isFalse,
        reason: 'age is a Keytel term',
      );
      expect(
        const Profile(ageYears: 34, sex: 'm').hasCalorieAnchors,
        isFalse,
        reason: 'body mass is a Keytel term',
      );
      expect(
        const Profile(ageYears: 34, weightKg: 72).hasCalorieAnchors,
        isFalse,
        reason: 'the formula has a different constant per sex',
      );
    });

    test('does not require height, unlike isComplete', () {
      // Gating calories on `isComplete` would refuse to score a profile that
      // has everything the formula reads.
      expect(_anchored.isComplete, isFalse);
      expect(_anchored.hasCalorieAnchors, isTrue);
    });
  });

  group('LiveWorkoutState.caloriesOrNull', () {
    test('rounds the accrued figure once something was actually costed', () {
      final s = _session(_anchored);
      s.accrueCalories(431.7);
      expect(s.caloriesOrNull, 432);
    });

    test('is null until the estimate has run even once', () {
      // "Can we score this" and "did we score this" are different questions
      // and both have a zero-shaped answer. A complete profile whose band
      // never delivered a heart rate — link dropped, strap off — accrues
      // nothing, and reporting that as 0 kcal claims a measurement nobody
      // took. Strain already reports that case as absent.
      expect(_session(_anchored).caloriesOrNull, isNull);
      expect(_session(const Profile()).caloriesOrNull, isNull);
    });

    test('a costed session that came to nothing reports zero, not absent', () {
      // Reachable: the Keytel term goes negative at a low enough heart rate
      // and is clamped at zero. That IS a measurement, and it is not the same
      // claim as never having measured.
      final s = _session(_anchored);
      s.accrueCalories(0);
      expect(s.caloriesOrNull, 0);
    });
  });

  test('the substrate re-score abstains on the same predicate', () {
    final start = DateTime(2026, 1, 1, 7).millisecondsSinceEpoch ~/ 1000;
    final ts = [for (var i = 0; i < 600; i++) start + i];
    final hr = [for (var i = 0; i < 600; i++) 140];

    final unanchored = computeManualSessionStats(
      hrTs: ts,
      hrBpm: hr,
      zoneMaxHr: 185,
      profile: const Profile(weightKg: 72, sex: 'm'),
      restingHr: 55,
    );
    expect(unanchored.calories, isNull);
    expect(
      unanchored.avgHr,
      140,
      reason: 'only the calorie figure abstains — the rest of the session is '
          'still perfectly scoreable without a body mass',
    );

    final anchored = computeManualSessionStats(
      hrTs: ts,
      hrBpm: hr,
      zoneMaxHr: 185,
      profile: _anchored,
      restingHr: 55,
    );
    expect(anchored.calories, isNotNull);
    expect(anchored.calories, greaterThan(0));
  });
}
