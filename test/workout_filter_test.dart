// The workout list's filter/sort rules. Pure policy, so these are plain unit
// tests — no widget pumping, no database.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/workouts/workout_filter.dart';

Map<String, dynamic> w({
  required int startTs,
  String type = 'run',
  int durationMin = 30,
  double strain = 8,
  int calories = 200,
  String status = 'done',
  List<num> zoneMin = const [1, 2, 3, 4, 5],
}) => {
  'start_ts': startTs,
  'type': type,
  'duration_min': durationMin,
  'strain': strain,
  'calories': calories,
  'status': status,
  'zone_min': zoneMin,
};

void main() {
  group('canonicalWorkoutType', () {
    test('keeps a known key', () {
      expect(canonicalWorkoutType('boxing'), 'boxing');
    });

    test('collapses anything outside the vocabulary to other', () {
      // The detector's own strings, rows from an older release, and imports
      // all land here — if they mapped to nothing, no filter chip could ever
      // reach them and they would vanish the moment a type filter went on.
      for (final t in ['autodetected_workout', 'kitesurfing', '', null]) {
        expect(canonicalWorkoutType(t), 'other');
      }
    });
  });

  group('filtering', () {
    final list = [
      w(startTs: 300, type: 'run', durationMin: 60, strain: 12),
      w(startTs: 200, type: 'strength', durationMin: 20, strain: 5),
      w(startTs: 100, type: 'autodetected_workout', durationMin: 45, strain: 9),
    ];

    test('no filter keeps everything', () {
      expect(const WorkoutFilter().apply(list).length, 3);
      expect(const WorkoutFilter().isNarrowing, isFalse);
    });

    test('type filter keeps only that type', () {
      final out = const WorkoutFilter(types: {'run'}).apply(list);
      expect(out.map((e) => e['type']), ['run']);
    });

    test('the other chip catches unrecognised types', () {
      final out = const WorkoutFilter(types: {'other'}).apply(list);
      expect(out.single['start_ts'], 100);
    });

    test('duration floor is inclusive', () {
      expect(const WorkoutFilter(minMinutes: 45).apply(list).length, 2);
      expect(const WorkoutFilter(minMinutes: 60).apply(list).length, 1);
    });

    test('strain floor is inclusive', () {
      expect(const WorkoutFilter(minStrain: 9).apply(list).length, 2);
    });

    test('floors compose', () {
      final out = const WorkoutFilter(minMinutes: 45, minStrain: 10)
          .apply(list);
      expect(out.single['start_ts'], 300);
    });

    test('a live session is still subject to the type filter', () {
      // Type is known the moment a session starts, so filtering to runs must
      // not surface the ride that happens to be in progress.
      final live = w(startTs: 400, type: 'cycle', status: 'live');
      final out = const WorkoutFilter(types: {'run'}).apply([...list, live]);
      expect(out.map((e) => e['type']), ['run']);
    });

    test('a live session survives every floor', () {
      // It has no final duration or strain yet, so any numeric floor would
      // hide the one session the user is most likely looking at.
      final live = w(
        startTs: 400,
        type: 'cycle',
        durationMin: 0,
        strain: 0,
        status: 'live',
      );
      final out = const WorkoutFilter(minMinutes: 60, minStrain: 15)
          .apply([...list, live]);
      expect(out.map((e) => e['status']), contains('live'));
    });

    test('sort alone is not narrowing', () {
      // Reordering hides nothing, so the summary above the list stays the
      // repo's own whole-range aggregate rather than being recomputed.
      const f = WorkoutFilter(sort: WorkoutSort.longest);
      expect(f.isNarrowing, isFalse);
      expect(f.isDefault, isFalse);
    });
  });

  group('sorting', () {
    final list = [
      w(startTs: 100, durationMin: 60, strain: 4),
      w(startTs: 300, durationMin: 20, strain: 15),
      w(startTs: 200, durationMin: 60, strain: 9),
    ];

    test('newest first is the default', () {
      expect(
        const WorkoutFilter().apply(list).map((e) => e['start_ts']),
        [300, 200, 100],
      );
    });

    test('oldest first reverses it', () {
      expect(
        const WorkoutFilter(sort: WorkoutSort.oldest)
            .apply(list)
            .map((e) => e['start_ts']),
        [100, 200, 300],
      );
    });

    test('longest breaks ties by newest, not by query order', () {
      expect(
        const WorkoutFilter(sort: WorkoutSort.longest)
            .apply(list)
            .map((e) => e['start_ts']),
        [200, 100, 300],
      );
    });

    test('hardest orders by strain', () {
      expect(
        const WorkoutFilter(sort: WorkoutSort.hardest)
            .apply(list)
            .map((e) => e['start_ts']),
        [300, 200, 100],
      );
    });

    test('only the chronological sorts keep week grouping', () {
      expect(WorkoutSort.newest.isChronological, isTrue);
      expect(WorkoutSort.oldest.isChronological, isTrue);
      expect(WorkoutSort.longest.isChronological, isFalse);
      expect(WorkoutSort.hardest.isChronological, isFalse);
    });

    test('does not mutate the source list', () {
      final source = [...list];
      const WorkoutFilter(sort: WorkoutSort.hardest).apply(source);
      expect(source.map((e) => e['start_ts']), [100, 300, 200]);
    });
  });

  group('summarizeWorkouts', () {
    test('totals match the visible list', () {
      final out = summarizeWorkouts([
        w(startTs: 100, durationMin: 30, calories: 200, zoneMin: [1, 2]),
        w(startTs: 200, durationMin: 45, calories: 300, zoneMin: [3, 4, 5]),
      ]);
      expect(out['count'], 2);
      expect(out['total_min'], 75);
      expect(out['total_calories'], 500);
      expect(out['zone_min'], [4, 6, 5]);
    });

    test('excludes live sessions exactly as the repo does', () {
      final out = summarizeWorkouts([
        w(startTs: 100, durationMin: 30),
        w(startTs: 200, durationMin: 99, status: 'live'),
      ]);
      expect(out['count'], 1);
      expect(out['total_min'], 30);
    });

    test('a missing calorie figure is skipped, never defaulted', () {
      // Sessions logged against an incomplete profile carry a null kcal. The
      // total is the sum of what was actually measured — the uncosted session
      // still counts as a session and still contributes its minutes.
      final out = summarizeWorkouts([
        {
          'duration_min': 30,
          'calories': null,
          'status': 'done',
          'zone_min': const <num>[],
        },
        w(startTs: 100, durationMin: 30, calories: 250),
      ]);
      expect(out['total_calories'], 250);
      expect(out['count'], 2, reason: 'uncosted is still a workout');
      expect(out['total_min'], 60, reason: 'its minutes are real');
    });
  });

  group('description', () {
    test('is empty when nothing narrows', () {
      expect(const WorkoutFilter().description, '');
    });

    test('names one or two types, counts more', () {
      expect(const WorkoutFilter(types: {'run'}).description, 'Run');
      expect(
        const WorkoutFilter(types: {'run', 'boxing', 'golf'}).description,
        '3 types',
      );
    });

    test('joins the active floors', () {
      expect(
        const WorkoutFilter(minMinutes: 30, minStrain: 10).description,
        '30m+ · strain 10+',
      );
    });
  });
}
