// `healthActivityForType` and `healthWorkoutTitleForType` — the app's
// `sessions.type` to HealthKit / Health Connect activity map and record title,
// which the mapper's own doc comment has named as tested here since #184
// without the file existing.
//
// WHAT THIS CAN AND CANNOT CATCH. It pins the app's own switch, on both
// platform branches, which a host VM is the only place to do: `Platform.isIOS`
// and `Platform.isAndroid` are both false in a unit test, which is why the
// function takes `ios` rather than reading `Platform`. It does NOT call
// `writeWorkoutData`, and it cannot see the plugin's per-platform allow-lists
// or its native maps — so the platform facts asserted below were read out of
// the installed `health` 12.2.1 by hand, and a package upgrade that moved them
// would leave this suite green. Re-read them on a version bump.
//
// The failure being defended against is silent: `writeWorkoutData` throws
// `HealthException` for any type absent from THAT platform's set, before the
// platform channel, so a spelling that exists on one store and not the other
// does not degrade — it drops every workout of that type on the other one.

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  group('healthActivityForType', () {
    test('the families the two stores spell differently split by platform', () {
      // #184 itself: iOS has no bare STRENGTH_TRAINING, and every strength
      // workout was rejected for two releases.
      expect(healthActivityForType('strength', ios: true),
          HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING);
      expect(healthActivityForType('strength', ios: false),
          HealthWorkoutActivityType.STRENGTH_TRAINING);
      // The same latent bug for swims, caught before it shipped.
      expect(healthActivityForType('swimming', ios: true),
          HealthWorkoutActivityType.SWIMMING);
      expect(healthActivityForType('swimming', ios: false),
          HealthWorkoutActivityType.SWIMMING_POOL);
      // Bowling exists on iOS and nowhere in Health Connect.
      expect(healthActivityForType('bowling', ios: true),
          HealthWorkoutActivityType.BOWLING);
      expect(healthActivityForType('bowling', ios: false),
          HealthWorkoutActivityType.OTHER);
    });

    test('an OTHER workout still reaches Android under its own name', () {
      // Health Connect titles the record with the enum name when the write
      // carries no title, so bowling landed there as "OTHER".
      expect(healthWorkoutTitleForType('bowling'), 'Bowling');
      expect(healthWorkoutTitleForType('general_workout'), 'General Workout');
      expect(healthWorkoutTitleForType('table_tennis'), 'Table Tennis');
      // The ponytail ceiling, pinned so it is a known shape and not a
      // surprise: acronyms come back title-cased.
      expect(healthWorkoutTitleForType('hiit'), 'Hiit');
      // Nothing to title is not a title of nothing — null lets the platform
      // keep its own default rather than writing an empty string.
      expect(healthWorkoutTitleForType(null), isNull);
      expect(healthWorkoutTitleForType('   '), isNull);
      // Null, not a blank string: Android falls back to its own default only
      // when the title is absent, so ' ' would write an EMPTY name — worse
      // than the "OTHER" it replaced. `sessions.type` is free-form, and the
      // coach can write one, so a punctuation-only type is reachable.
      expect(healthWorkoutTitleForType('_'), isNull);
      expect(healthWorkoutTitleForType('___'), isNull);
      expect(healthWorkoutTitleForType('cold__plunge'), 'Cold Plunge');
    });

    test('soccer is OTHER on Android — a write that reports false', () {
      // Not a supported-set problem: SOCCER passes the Dart guard and is
      // commented out of Health Connect's own write map, so the call returns
      // false, which this file counts toward the day's give-up budget. One
      // football would pause the whole day's export, sleep included.
      expect(healthActivityForType('football', ios: true),
          HealthWorkoutActivityType.SOCCER);
      expect(healthActivityForType('football', ios: false),
          HealthWorkoutActivityType.OTHER);
    });

    test('one spelling is used where only one is accepted by both', () {
      for (final ios in [true, false]) {
        // Bare CLIMBING and STAIRS are iOS-only; SKIING is Android-only.
        expect(healthActivityForType('climbing', ios: ios),
            HealthWorkoutActivityType.ROCK_CLIMBING);
        expect(healthActivityForType('stairs', ios: ios),
            HealthWorkoutActivityType.STAIR_CLIMBING);
        expect(healthActivityForType('skiing', ios: ios),
            HealthWorkoutActivityType.DOWNHILL_SKIING);
      }
    });

    test('an unknown, unnamed or unmapped type lands as OTHER, not nowhere',
        () {
      for (final ios in [true, false]) {
        // The catch-all row is deliberately here: "a general workout" is the
        // user declining to say what it was, and MIXED_CARDIO or
        // CROSS_TRAINING would be the app saying it for them.
        expect(healthActivityForType('general_workout', ios: ios),
            HealthWorkoutActivityType.OTHER);
        // 'other' is what an accepted auto-detected bout is stored as.
        expect(healthActivityForType('other', ios: ios),
            HealthWorkoutActivityType.OTHER);
        expect(healthActivityForType(null, ios: ios),
            HealthWorkoutActivityType.OTHER);
        expect(healthActivityForType('underwater basket weaving', ios: ios),
            HealthWorkoutActivityType.OTHER);
      }
    });

    test('skateboarding keeps its title and uses the safe shared fallback', () {
      for (final ios in [true, false]) {
        expect(healthActivityForType('skateboarding', ios: ios),
            HealthWorkoutActivityType.OTHER);
      }
      expect(healthWorkoutTitleForType('skateboarding'), 'Skateboarding');
    });

  });
}
