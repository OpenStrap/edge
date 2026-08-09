// Every workout type the app can start MUST map to an activity type the target
// platform's health store actually accepts.
//
// Issue #184: `strength` mapped to `HealthWorkoutActivityType.STRENGTH_TRAINING`
// on BOTH platforms. That value exists only in the plugin's Android set, so on
// iOS `writeWorkoutData` threw `HealthException` *before* the platform channel,
// the throw was swallowed by a `debugPrint`, and no strength workout ever
// reached Apple Health. The same latent bug existed for `swim`, which mapped to
// bare `SWIMMING` — an iOS-only value — and so was dropped on Android.
//
// The supported sets below are a PIN, not a mirror: on a `health` upgrade,
// re-check the sources named below and update them deliberately. If a value
// silently leaves a platform's set upstream, this test is what catches it
// before another workout family goes missing for a release.
//
// SOURCE OF TRUTH, and it differs per platform:
//   iOS     — `ios/Classes/SwiftHealthPlugin.swift`, `workoutActivityTypeMap`.
//   Android — `android/.../HealthPlugin.kt`, `workoutTypeMap`. NOT the Dart
//             `_isOnAndroid` list, which is only an advisory pre-check and
//             does NOT agree with the Kotlin map. `SOCCER` is the live example:
//             the Dart list contains it, the Kotlin map has it commented out,
//             and a write of it returns `success(false)` instead of throwing.
//             This file's exporter reads a false as a real write failure and
//             counts it toward the day's give-up budget, so trusting the Dart
//             list here would have shipped a workout type that silently paused
//             a whole day of health export.

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/ui/workouts/workout_types.dart';

/// Values `healthActivityForType` may emit that iOS (HealthKit) accepts.
const _iosSupported = <HealthWorkoutActivityType>{
  HealthWorkoutActivityType.RUNNING,
  HealthWorkoutActivityType.BIKING,
  HealthWorkoutActivityType.WALKING,
  HealthWorkoutActivityType.SWIMMING,
  HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING,
  HealthWorkoutActivityType.YOGA,
  HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING,
  HealthWorkoutActivityType.BOXING,
  HealthWorkoutActivityType.ROWING,
  HealthWorkoutActivityType.HIKING,
  HealthWorkoutActivityType.ROCK_CLIMBING,
  HealthWorkoutActivityType.DOWNHILL_SKIING,
  HealthWorkoutActivityType.SNOWBOARDING,
  HealthWorkoutActivityType.STAIR_CLIMBING,
  HealthWorkoutActivityType.PILATES,
  HealthWorkoutActivityType.TENNIS,
  HealthWorkoutActivityType.BASKETBALL,
  HealthWorkoutActivityType.SOCCER,
  HealthWorkoutActivityType.GOLF,
  HealthWorkoutActivityType.OTHER,
};

/// Values `healthActivityForType` may emit that Android (Health Connect) accepts.
const _androidSupported = <HealthWorkoutActivityType>{
  HealthWorkoutActivityType.RUNNING,
  HealthWorkoutActivityType.BIKING,
  HealthWorkoutActivityType.WALKING,
  HealthWorkoutActivityType.SWIMMING_POOL,
  HealthWorkoutActivityType.STRENGTH_TRAINING,
  HealthWorkoutActivityType.YOGA,
  HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING,
  HealthWorkoutActivityType.BOXING,
  HealthWorkoutActivityType.ROWING,
  HealthWorkoutActivityType.HIKING,
  HealthWorkoutActivityType.ROCK_CLIMBING,
  HealthWorkoutActivityType.DOWNHILL_SKIING,
  HealthWorkoutActivityType.SNOWBOARDING,
  HealthWorkoutActivityType.STAIR_CLIMBING,
  HealthWorkoutActivityType.PILATES,
  HealthWorkoutActivityType.TENNIS,
  HealthWorkoutActivityType.BASKETBALL,
  HealthWorkoutActivityType.GOLF,
  HealthWorkoutActivityType.OTHER,
};

/// Type strings that can reach the exporter but are not in [kWorkoutTypes]:
/// manual-start aliases and the auto-detector's own vocabulary.
const _extraTypeStrings = <String>[
  'running',
  'cycling',
  'bike',
  'biking',
  'walking',
  'swimming',
  'weights',
  'lifting',
  'row',
  'hiking',
  'climbing',
  'skiing',
  'snowboarding',
  'stair',
  'racquet',
  'squash',
  'padel',
  'badminton',
  'football',
  'autodetected',
  'autodetected_workout',
  'workout',
  '',
];

void main() {
  final allTypes = <String?>[
    ...kWorkoutTypes.map((e) => e.$1),
    ..._extraTypeStrings,
    null,
  ];

  group('healthActivityForType stays inside each platform supported set', () {
    for (final type in allTypes) {
      test('"${type ?? '<null>'}" is writable on both platforms', () {
        expect(
          _iosSupported,
          contains(healthActivityForType(type, ios: true)),
          reason:
              'iOS would throw HealthException for "$type" and the workout '
              'would never reach Apple Health (issue #184)',
        );
        expect(
          _androidSupported,
          contains(healthActivityForType(type, ios: false)),
          reason:
              'Health Connect would throw HealthException for "$type" and the '
              'workout would never reach Android health',
        );
      });
    }
  });

  // The picker table and the health switch are two hand-maintained lists.
  // Adding a tile to `kWorkoutTypes` without adding a case to
  // `healthActivityForType` is silent — the workout still exports, just as an
  // unlabelled "Other", so it is invisible until someone opens Apple Health
  // and finds a wall of generic entries.
  test('every picker type has its own health activity, not a silent OTHER', () {
    // `cardio` and `other` are genuinely unspecific: neither store has a
    // better home for them than OTHER, and that is a decision, not an
    // oversight.
    const deliberatelyOther = {'cardio', 'other'};
    // Android-only exemption: Health Connect has no writable soccer type at
    // this plugin version (see the header), so OTHER there is the correct
    // answer rather than a missing case.
    const androidOtherOk = {'soccer'};
    for (final e in kWorkoutTypes) {
      if (deliberatelyOther.contains(e.$1)) continue;
      for (final ios in [true, false]) {
        if (!ios && androidOtherOk.contains(e.$1)) continue;
        expect(
          healthActivityForType(e.$1, ios: ios),
          isNot(HealthWorkoutActivityType.OTHER),
          reason:
              '"${e.$1}" is offered in the workout picker but falls through to '
              'OTHER on ${ios ? 'iOS' : 'Android'} — add a case to '
              'healthActivityForType',
        );
      }
    }
  });

  test('strength maps to the platform-correct strength spelling', () {
    expect(
      healthActivityForType('strength', ios: true),
      HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING,
    );
    expect(
      healthActivityForType('strength', ios: false),
      HealthWorkoutActivityType.STRENGTH_TRAINING,
    );
    // The aliases the manual-start UI and older rows can carry.
    for (final alias in ['weights', 'lifting', 'Strength', 'STRENGTH']) {
      expect(
        healthActivityForType(alias, ios: true),
        HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING,
        reason: '"$alias" must land on the same iOS type as "strength"',
      );
    }
  });

  test('soccer does not reach a Health Connect type it would reject', () {
    // The Kotlin write map has SOCCER commented out. Sending it anyway comes
    // back false rather than throwing, and this exporter reads a false as a
    // real write failure — one soccer workout would take the whole day's
    // export down with it.
    expect(
      healthActivityForType('soccer', ios: true),
      HealthWorkoutActivityType.SOCCER,
    );
    expect(
      healthActivityForType('soccer', ios: false),
      HealthWorkoutActivityType.OTHER,
    );
    expect(
      healthActivityForType('football', ios: false),
      HealthWorkoutActivityType.OTHER,
    );
  });

  test('swim maps to the platform-correct swim spelling', () {
    expect(
      healthActivityForType('swim', ios: true),
      HealthWorkoutActivityType.SWIMMING,
    );
    expect(
      healthActivityForType('swim', ios: false),
      HealthWorkoutActivityType.SWIMMING_POOL,
    );
  });

  test('an unknown type degrades to OTHER rather than an unwritable value', () {
    // 'padel' used to stand in for "unknown" here and is now a racquet alias —
    // pick strings the switch genuinely has no case for.
    for (final unknown in ['surfing', 'kitesurfing', 'autodetected', null]) {
      expect(
        healthActivityForType(unknown, ios: true),
        HealthWorkoutActivityType.OTHER,
      );
      expect(
        healthActivityForType(unknown, ios: false),
        HealthWorkoutActivityType.OTHER,
      );
    }
  });
}
