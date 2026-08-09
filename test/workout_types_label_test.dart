// The workout-type vocabulary is looked up by a free-form `type` string that
// comes straight out of the database, so every lookup has to survive whatever
// case an older release, an import, or a hand-edited row happened to write.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/kit/os_icons.dart';
import 'package:openstrap_edge/ui/workouts/workout_types.dart';

void main() {
  group('workoutTypeLabel', () {
    test('uses the table label rather than capitalising the key', () {
      // Capitalising blind is how 'hiit' read as "Hiit" everywhere except the
      // picker, and it cannot produce a label that differs from its key at all.
      expect(workoutTypeLabel('hiit'), 'HIIT');
      expect(workoutTypeLabel('tennis'), 'Racquet');
    });

    test('is case-insensitive', () {
      for (final variant in ['TENNIS', 'Tennis', 'tEnNiS']) {
        expect(workoutTypeLabel(variant), 'Racquet');
      }
      expect(workoutTypeLabel('STRENGTH'), 'Strength');
    });

    test('falls back to capitalising an unknown type', () {
      expect(workoutTypeLabel('kitesurfing'), 'Kitesurfing');
    });

    test('collapses the detector vocabulary and the empty case', () {
      expect(workoutTypeLabel('autodetected_workout'), 'Workout');
      expect(workoutTypeLabel('AUTODETECTED'), 'Workout');
      expect(workoutTypeLabel(''), 'Workout');
      expect(workoutTypeLabel(null), 'Workout');
    });
  });

  group('icon lookups', () {
    test('are case-insensitive too', () {
      expect(workoutTypeIcon('BOXING'), OsIcon.boxing);
      expect(workoutTypeOsIcon('Boxing'), OsIcon.boxing);
    });

    test('an unknown type still renders something', () {
      expect(workoutTypeIcon('kitesurfing'), OsIcon.strength);
      expect(workoutTypeOsIcon('kitesurfing'), isNull);
    });
  });

  test('every type key is already lowercase, so lookups can normalize once',
      () {
    for (final e in kWorkoutTypes) {
      expect(e.$1, e.$1.toLowerCase(), reason: '${e.$1} breaks the lookups');
    }
  });
}
