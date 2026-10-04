import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';

import '../tool/update_wger_exercises.dart';
import '../tool/wger_weightlifting_selection.dart';

List<Map<String, Object?>> _reviewedRows() => [
  for (final id in wgerWeightliftingSelection.keys)
    {
      'uuid': id,
      'category': {'name': 'Arms'},
    },
];

void main() {
  test('refresh ignores unreviewed entries even in a lifting category', () {
    final reviewed = _reviewedRows();
    final selected = selectWeightliftingExercises([
      ...reviewed,
      {
        'uuid': 'unreviewed-cardio',
        'category': {'name': 'Cardio'},
      },
      {
        'uuid': 'unreviewed-breathing',
        'category': {'name': 'Abs'},
      },
      {
        'uuid': 'unreviewed-stretch',
        'category': {'name': 'Legs'},
      },
      {
        'uuid': 'unreviewed-lift',
        'category': {'name': 'Arms'},
      },
    ]);
    expect(selected, reviewed);
  });

  test('refresh refuses to silently drop a reviewed exercise', () {
    final rows = _reviewedRows()..removeLast();
    expect(() => selectWeightliftingExercises(rows), throwsStateError);
  });

  test('refresh refuses duplicate reviewed UUIDs', () {
    final rows = _reviewedRows();
    rows.add(rows.first);
    expect(() => selectWeightliftingExercises(rows), throwsStateError);
  });

  test('reviewed UUIDs cannot turn into cardio or an unknown category', () {
    for (final category in ['Cardio', 'Yoga', '']) {
      final rows = _reviewedRows();
      rows.first['category'] = {'name': category};
      expect(
        () => selectWeightliftingExercises(rows),
        throwsStateError,
        reason: category,
      );
    }
  });

  test('a muscle with an empty English name keeps its Latin name', () {
    expect(wgerMuscleName({'name': 'Trapezius', 'name_en': ''}), 'Trapezius');
    expect(wgerMuscleName({'name': 'Biceps brachii', 'name_en': 'Biceps'}),
        'Biceps');
    expect(
        exerciseByKey('wger:d7a418d4-d0cb-4f85-8a7c-1e9d97152cbd')!
            .matches('trapezius', 'en'),
        isTrue);
  });

  test('dumbbell lifts step in 2 kg, bar lifts in 2.5', () {
    expect(wgerLoadStep(['Dumbbell']), 2);
    expect(wgerLoadStep(['Bench', 'Dumbbell']), 2);
    expect(wgerLoadStep(['Barbell', 'Dumbbell']), 2.5);
    expect(wgerLoadStep(['Cable machine']), 2.5);
    // kettlebells come in 4 kg sizes, so 2.5 could never reach 8/12/16/24
    expect(wgerLoadStep(['Kettlebell']), 2);
    // the shipped snapshot was generated with the same rule
    expect(
        exerciseByKey('wger:eb9476ac-2c00-4f49-a40f-f81682161a75')!.step, 2);
    for (final e in exerciseLibrary.where((e) => e.key.startsWith('wger:'))) {
      expect(e.step, wgerLoadStep(e.equipment), reason: e.label);
    }
  });
}

