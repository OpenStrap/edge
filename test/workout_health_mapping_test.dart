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
// The supported sets below are transcribed from `health: 11.1.1`
// (`lib/src/health_plugin.dart`, `_isOnIOS` / `_isOnAndroid`), restricted to the
// values `healthActivityForType` can actually emit. They are a PIN, not a
// mirror: on a `health` upgrade, re-check those two functions and update these
// sets deliberately. If a value silently leaves a platform's set upstream, this
// test is what catches it before another workout family goes missing for a
// release.

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
    for (final unknown in ['surfing', 'padel', 'autodetected', null]) {
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
