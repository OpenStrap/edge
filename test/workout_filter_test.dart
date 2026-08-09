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

    test('resolves an alias rather than collapsing it', () {
      expect(canonicalWorkoutType('running'), 'run');
      expect(canonicalWorkoutType('weightlifting'), 'strength');
      expect(canonicalWorkoutType('HIKING'), 'hike');
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

    test('an alias is found by its real family chip', () {
      // Imported sessions carry the export's own spelling. Filtering by Run
      // must find the row the feed titles "Run", not leave it under Other.
      final imported = w(startTs: 600, type: 'running');
      final out = const WorkoutFilter(types: {'run'}).apply([imported]);
      expect(out, hasLength(1));
      expect(
        const WorkoutFilter(types: {'other'}).apply([imported]),
        isEmpty,
        reason: 'it is a run, so Other must not claim it as well',
      );
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

    test('a strain floor excludes a session that was never scored', () {
      // Null strain means the profile lacked an anchor, or the window had no
      // HR. It cannot be shown to clear the bar, so listing it under
      // "strain 10+" would be a claim we cannot make.
      final unscored = {
        'start_ts': 500,
        'type': 'run',
        'duration_min': 60,
        'strain': null,
        'status': 'done',
      };
      // All three scored sessions clear 5; the unscored one is the only
      // thing the floor removes.
      expect(
        const WorkoutFilter(minStrain: 5).apply([...list, unscored]).length,
        3,
      );
      expect(
        const WorkoutFilter().apply([...list, unscored]).length,
        4,
        reason: 'with no floor it is an ordinary workout',
      );
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

    test('hardest sinks unscored sessions below real zeros', () {
      final unscored = {
        'start_ts': 400,
        'duration_min': 30,
        'strain': null,
        'status': 'done',
      };
      final zero = w(startTs: 350, strain: 0);
      final out = const WorkoutFilter(sort: WorkoutSort.hardest)
          .apply([unscored, zero, ...list]);
      expect(out.last['start_ts'], 400, reason: 'unscored ranks below a real 0');
      expect(out[out.length - 2]['start_ts'], 350);
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

    test('a range where nothing could be costed reports no total at all', () {
      // Not 0. A whole timeframe of uncosted sessions showing "0 kcal" is the
      // same fabrication as one session showing it.
      final out = summarizeWorkouts([
        {'duration_min': 30, 'calories': null, 'status': 'done'},
        {'duration_min': 45, 'calories': null, 'status': 'done'},
      ]);
      expect(out['total_calories'], isNull);
      expect(out['count'], 2);
      expect(out['total_min'], 75);
    });

    test('an empty list has no total either', () {
      expect(summarizeWorkouts(const [])['total_calories'], isNull);
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
