// Changing a dose's time must carry its history with it. slotsForDay resolves
// past days against the CURRENT schedule and looks doses up by minute, so rows
// left at the old minute made every earlier dose read as missed.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/med_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('moving 08:00 to 08:30 keeps a week of taken doses taken', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await createMedTables(db);

    final now = DateTime(2026, 10, 17, 12);
    final created = DateTime(2026, 10, 1, 7).millisecondsSinceEpoch;
    MedDef def(int min) => MedDef(
      key: 'custom_vitamin_d',
      label: 'Vitamin D',
      schedule: [MedSchedule(min, const [])],
      createdAt: created,
    );
    await MedDb.putDef(db, def(480));
    for (var i = 6; i >= 0; i--) {
      await MedDb.mark(
        db,
        medKey: 'custom_vitamin_d',
        date: dayLabelOf(DateTime(now.year, now.month, now.day - i)),
        slotMin: 480,
        taken: true,
      );
    }
    // A row already recorded against the new time on one day wins over the
    // moved one rather than tripping the primary key.
    final clash = dayLabelOf(DateTime(now.year, now.month, now.day - 3));
    await MedDb.mark(
      db,
      medKey: 'custom_vitamin_d',
      date: clash,
      slotMin: 510,
      taken: false,
      skipped: true,
    );
    expect(await MedDb.adherenceWindow(db, now: now), (taken: 7, of: 7));

    await MedDb.putDef(db, def(510));
    await MedDb.retimeSlot(
      db,
      medKey: 'custom_vitamin_d',
      fromMin: 480,
      toMin: 510,
    );

    expect(await MedDb.adherenceWindow(db, now: now), (taken: 6, of: 7));
    final past = slotsForDay(
      [def(510)],
      dayLabelOf(DateTime(2026, 10, 15)),
      await MedDb.dosesForDay(db, dayLabelOf(DateTime(2026, 10, 15))),
      now: now,
    );
    expect(past.single.slotMin, 510);
    expect(past.single.state, DoseState.taken);
    final clashDay = slotsForDay(
      [def(510)],
      clash,
      await MedDb.dosesForDay(db, clash),
      now: now,
    );
    expect(clashDay.single.state, DoseState.skipped);
  });
}
