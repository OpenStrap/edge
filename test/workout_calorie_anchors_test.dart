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
import 'package:openstrap_edge/compute/derivation_engine.dart';
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

    test('does not require height — Keytel does not read one', () {
      // This predicate gates the BOUT paths: the live tick and a manually
      // logged session, both of which price heart rate through Keytel, whose
      // terms are HR, body mass, age and sex. Height enters those only through
      // the resting floor, and only for the seconds below the activity gate.
      expect(_anchored.isComplete, isFalse);
      expect(_anchored.hasCalorieAnchors, isTrue);
    });

    test('is not enough for the DAY figures, which also need a height', () {
      // The day's calories are not the bout's. `Calories.dailyEnergy` defines
      // ACTIVE as the surplus over the Mifflin basal minute, so the Mifflin
      // height term is inside the active scalar as well as the total, and a
      // stand-in 170 cm moves both — figures that are persisted to `day_result`
      // and exported to Apple Health / Health Connect. `wakeDayEnergy`
      // therefore abstains outright rather than imputing; see
      // daily_energy_consistency_test for the size of it.
      expect(
        DerivationEngine.wakeDayEnergy(
          <double>[for (var i = 0; i < 60; i++) 140.0],
          profile: _anchored,
        ),
        isNull,
        reason: 'the Keytel anchors alone do not buy a day figure',
      );
      expect(
        DerivationEngine.wakeDayEnergy(
          <double>[for (var i = 0; i < 60; i++) 140.0],
          profile: const Profile(
            ageYears: 34,
            weightKg: 72,
            heightCm: 178,
            sex: 'm',
          ),
        ),
        isNotNull,
      );
    });
  });

  group('LiveWorkoutState.caloriesOrNull', () {
    test('rounds the live figure once something was actually costed', () {
      final s = _session(_anchored);
      s.restingHr = 55; // the bout gate needs a real resting HR
      for (var i = 0; i < 120; i++) {
        s.elapsed = Duration(seconds: i);
        s.accrueHr(140);
      }
      expect(s.calories, greaterThan(0));
      expect(s.caloriesOrNull, s.calories.round());
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

    test('a costed session is never zero now that there is a resting floor', () {
      // This case used to be reachable: the live tick billed a bare Keytel
      // term, which goes negative at a low enough heart rate and was clamped
      // to zero, so a session could be genuinely costed and still total 0.
      //
      // It no longer is. The tick shares the substrate re-score's rates, and
      // below the activity gate that means the Harris-Benedict RESTING rate,
      // which is strictly positive. A session with any heart rate at all now
      // has a positive cost; a session with none is absent. The zero-shaped
      // ambiguity `caloriesOrNull` exists to resolve is therefore now only
      // ever "we could not score this", which is exactly what null says.
      final s = _session(_anchored);
      s.restingHr = 55;
      for (var i = 0; i < 120; i++) {
        s.elapsed = Duration(seconds: i);
        s.accrueHr(45); // far below the gate — bills the resting floor
      }
      expect(s.caloriesOrNull, isNotNull);
      expect(s.calories, greaterThan(0));
    });

    test('is absent without a resting HR to place the activity gate', () {
      // The re-score refuses to fabricate a 220/60 anchor pair and drops any
      // bout that fell back to one, so the live tick must abstain on the same
      // input rather than show a number the finished session will not.
      final s = _session(_anchored); // restingHr not set
      for (var i = 0; i < 120; i++) {
        s.elapsed = Duration(seconds: i);
        s.accrueHr(140);
      }
      expect(s.caloriesOrNull, isNull);
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
