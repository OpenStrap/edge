// log_food and add_medication take numbers from the model. A negative or
// NaN amount used to be stored as a confirmed entry and summed into the day
// total, and a quantity with no unit was stored as grams.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);
  // No tables: anything that got past the guard would fail with a
  // DatabaseException, not a CoachActionError.
  setUp(() async => db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      ));
  tearDown(() => db.close());

  test('num_ does not read NaN or Infinity strings as numbers', () {
    expect(CoachActions.num_('NaN'), isNull);
    expect(CoachActions.num_('Infinity'), isNull);
    expect(CoachActions.num_('-Infinity'), isNull);
    expect(CoachActions.num_(' 2.5 '), 2.5);
  });

  test('log_food refuses negative, NaN and non-numeric amounts', () async {
    for (final bad in <Map<String, dynamic>>[
      {'kcal': -500},
      {'protein_g': 'NaN'},
      {'sodium_mg': 'Infinity'},
      {'fat_g': 'lots'},
      {'quantity': -1, 'unit': 'g'},
    ]) {
      await expectLater(
        CoachActions.logFood(db, {'meal': 'lunch', 'label': 'soup', ...bad}),
        throwsA(isA<CoachActionError>()),
        reason: '$bad',
      );
    }
  });

  test('log_food refuses a quantity with no unit', () async {
    await expectLater(
      CoachActions.logFood(db, {'meal': 'lunch', 'label': 'rice', 'quantity': 2}),
      throwsA(isA<CoachActionError>()),
    );
  });

  test('a valid entry still saves, absent amounts stay absent', () async {
    await createNutritionTables(db);
    await CoachActions.logFood(db, {
      'meal': 'lunch',
      'label': 'rice',
      'quantity': 2,
      'unit': 'piece',
      'kcal': '0',
      'protein_g': '',
    });
    final e = (await NutritionDb.entriesForDay(
      db,
      CoachActions.day(null),
    )).single;
    expect(e.quantity, 2);
    expect(e.unit, 'piece');
    expect(e.kcal, 0);
    expect(e.proteinG, isNull);
  });

  test('add_medication refuses a negative or NaN dose', () async {
    for (final bad in [-5, 'NaN']) {
      await expectLater(
        CoachActions.addMedication(db, {
          'name': 'ibuprofen',
          'time': '08:00',
          'dose_value': bad,
        }),
        throwsA(isA<CoachActionError>()),
        reason: '$bad',
      );
    }
  });
}
