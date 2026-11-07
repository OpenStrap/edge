// The metric-detail "Journal marks" join: workouts, timed meals and timed
// journal fields on their local day, named as the day page names them.
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/journal_annotations.dart';

import 'support/process_tz.dart';

int _ts(int d, int h) => DateTime(2026, 3, d, h).millisecondsSinceEpoch ~/ 1000;

void main() {
  test('workouts, timed meals and timed journal fields land as marks', () {
    final out = journalAnnotations(
      from: '2026-03-10',
      to: '2026-03-12',
      sessions: [
        {'start_ts': _ts(11, 7), 'end_ts': _ts(11, 8), 'type': 'running'},
        // Outside the window: dropped.
        {'start_ts': _ts(20, 7), 'end_ts': _ts(20, 8), 'type': 'running'},
      ],
      mealsByDay: {
        '2026-03-11': [
          FoodEntry(
              id: 'a',
              date: '2026-03-11',
              meal: 'lunch',
              label: 'Soup',
              atTs: _ts(11, 13)),
          // No clock time: not a mark.
          const FoodEntry(
              id: 'b', date: '2026-03-11', meal: 'dinner', label: 'Rice'),
        ],
      },
      journalByDay: {
        '2026-03-12': {
          'caffeine_mg': const JournalMetricValue(80, atMinuteOfDay: 9 * 60),
          // No time of day: not a mark.
          'alcohol_units': const JournalMetricValue(1),
        },
      },
    );
    expect([for (final a in out) a.kind], [
      AnnotationKind.workout,
      AnnotationKind.journal,
      AnnotationKind.journal,
    ]);
    expect(out[0].at, _ts(11, 7).toDouble());
    expect(out[0].until, _ts(11, 8).toDouble());
    expect(out[1].at, _ts(11, 13).toDouble());
    expect(out[1].label, 'Soup');
    expect(out[2].at, _ts(12, 9).toDouble());
    expect({for (final a in out) a.id}, hasLength(3));
    expect(dayLabelOf(DateTime.fromMillisecondsSinceEpoch(out[2].at.toInt() * 1000)),
        '2026-03-12');
  });

  test('nothing read means no marks', () {
    expect(journalAnnotations(from: '2026-03-10', to: '2026-03-12'), isEmpty);
  });

  // A day is its local calendar day, 23 h or 25 h on the two DST days. Literal
  // UTC seconds in America/New_York; a UTC-placed day or start + 86400 moves at
  // least one of these in or out of the window.
  group('the local day across DST (New York)', () {
    final originalTz = Platform.environment['TZ'];
    setUpAll(() => setProcessTz('America/New_York'));
    tearDownAll(() => setProcessTz(originalTz));

    test('the fixture timezone actually applied (guards the group)', () {
      expect(DateTime(2026, 3, 8).timeZoneOffset, const Duration(hours: -5));
      expect(DateTime(2026, 3, 9).timeZoneOffset, const Duration(hours: -4));
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

    List<double> ats(String day, List<int> starts) => [
          for (final a in journalAnnotations(
            from: day,
            to: day,
            sessions: [
              for (final t in starts) {'start_ts': t, 'end_ts': t + 600},
            ],
          ))
            a.at,
        ]..sort();

    test('spring forward: the 23 h day holds exactly its own sessions', () {
      expect(
        ats('2026-03-08', [
          1772945999, // 23:59:59 EST on 03-07: the day before
          1772946000, // 00:00:00 EST on 03-08
          1773028799, // 23:59:59 EDT on 03-08
          1773028800, // 00:00:00 EDT on 03-09: the day after
        ]),
        [1772946000.0, 1773028799.0],
      );
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

    test('fall back: the 25 h day holds its extra hour and nothing else', () {
      expect(
        ats('2026-11-01', [
          1793505599, // 23:59:59 EDT on 10-31: the day before
          1793505600, // 00:00:00 EDT on 11-01
          1793514600, // the repeated 01:30, now EST
          1793595599, // 23:59:59 EST on 11-01, 25 h after its start
          1793595600, // 00:00:00 EST on 11-02: the day after
        ]),
        [1793505600.0, 1793514600.0, 1793595599.0],
      );
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);
  });
}
