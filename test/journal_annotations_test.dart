// The metric-detail "Journal marks" join: workouts, timed meals and timed
// journal fields on their local day, named as the day page names them.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/journal_annotations.dart';

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
}
