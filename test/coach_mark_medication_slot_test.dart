// mark_medication must land on a slot the schedule actually has. Doses are
// read back by the scheduled minute, so a row at 08:15 for an 08:00 slot was
// saved, confirmed, and never counted.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/data/med_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> open() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await createMedTables(db);
    // 08:00 on weekdays only.
    await MedDb.putDef(
      db,
      MedDef(
        key: 'custom_vitamin_d',
        label: 'Vitamin D',
        schedule: [MedSchedule(480, const [1, 2, 3, 4, 5])],
        createdAt: DateTime(2026, 10, 1).millisecondsSinceEpoch,
      ),
    );
    return db;
  }

  test('a time off the schedule is refused, nothing written', () async {
    final db = await open();
    await expectLater(
      CoachActions.markMedication(db, {
        'name': 'Vitamin D',
        'date': '2026-10-19',
        'time': '08:15',
        'state': 'taken',
      }),
      throwsA(isA<CoachActionError>()),
    );
    expect(await MedDb.dosesForDay(db, '2026-10-19'), isEmpty);
  });

  test('a day the schedule does not cover is refused', () async {
    final db = await open();
    await expectLater(
      CoachActions.markMedication(db, {
        'name': 'Vitamin D',
        'date': '2026-10-17', // Saturday
        'state': 'taken',
      }),
      throwsA(isA<CoachActionError>()),
    );
    expect(await MedDb.dosesForDay(db, '2026-10-17'), isEmpty);
  });

  test('the scheduled slot is marked and reads back taken', () async {
    final db = await open();
    await CoachActions.markMedication(db, {
      'name': 'Vitamin D',
      'date': '2026-10-19',
      'state': 'taken',
    });
    final defs = await MedDb.defs(db);
    final slots = slotsForDay(
      defs,
      '2026-10-19',
      await MedDb.dosesForDay(db, '2026-10-19'),
      now: DateTime(2026, 10, 19, 12),
    );
    expect(slots.single.state, DoseState.taken);
  });
}
