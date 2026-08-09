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

    test('resolves the spellings an import can carry', () {
      // The WHOOP importer stores the raw slug of the export's activity name,
      // so a real library is full of these.
      expect(workoutTypeLabel('running'), 'Run');
      expect(workoutTypeLabel('weightlifting'), 'Strength');
      expect(workoutTypeLabel('functional fitness'), 'Strength');
      expect(workoutTypeLabel('hiking'), 'Hike');
      expect(workoutTypeLabel('squash'), 'Racquet');
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

  group('aliases', () {
    test('resolve to a real key, and real keys resolve to themselves', () {
      for (final e in kWorkoutTypes) {
        expect(resolveWorkoutTypeKey(e.$1), e.$1);
      }
      for (final entry in kWorkoutTypeAliases.entries) {
        expect(
          kWorkoutTypesByKey.containsKey(entry.value),
          isTrue,
          reason: '"${entry.key}" points at "${entry.value}", which is not a '
              'real type — the alias is unreachable',
        );
      }
    });

    test('never shadow a real key', () {
      // An alias that collides with a key would be dead code at best and a
      // silent re-routing of a real type at worst.
      for (final key in kWorkoutTypeAliases.keys) {
        expect(
          kWorkoutTypesByKey.containsKey(key),
          isFalse,
          reason: '"$key" is both a type and an alias',
        );
        expect(key, key.toLowerCase());
      }
    });

    test('an unknown string resolves to nothing', () {
      expect(resolveWorkoutTypeKey('kitesurfing'), isNull);
      expect(resolveWorkoutTypeKey(''), isNull);
      expect(resolveWorkoutTypeKey(null), isNull);
    });
  });
}
