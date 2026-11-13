// "Add a medication" with a name that already exists adds a time to it; it
// does not replace the medication. putDef is INSERT OR REPLACE, so a fresh
// def built from the name alone used to drop every other time of day and
// blank the dose, unit, kind and note.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/med_store.dart';

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createMedTables(db);
  });

  tearDown(() => db.close());

  test('an existing name keeps its schedule, dose, kind and note', () async {
    await MedDb.putDef(
      db,
      const MedDef(
        key: 'custom_ibuprofen',
        label: 'Ibuprofen',
        doseValue: 400,
        doseUnit: 'mg',
        kind: 'supplement',
        note: 'with food',
        schedule: [MedSchedule(480, []), MedSchedule(840, [])],
      ),
    );
    final before = (await MedDb.defs(db)).single;

    await MedDb.addScheduledTime(
      db,
      ' ibuprofen ',
      const MedSchedule(1320, []),
    );

    final after = (await MedDb.defs(db, activeOnly: false)).single;
    expect(after.key, 'custom_ibuprofen');
    expect(after.label, 'Ibuprofen');
    expect([for (final s in after.schedule) s.minuteOfDay], [480, 840, 1320]);
    expect(after.doseValue, 400);
    expect(after.doseUnit, 'mg');
    expect(after.kind, 'supplement');
    expect(after.note, 'with food');
    expect(after.createdAt, before.createdAt);
  });

  test(
    'the same time of day again takes the new days, not a duplicate',
    () async {
      await MedDb.addScheduledTime(db, 'Vitamin D', const MedSchedule(480, []));
      await MedDb.addScheduledTime(
        db,
        'Vitamin D',
        const MedSchedule(480, [1, 4]),
      );
      final d = (await MedDb.defs(db)).single;
      expect(d.schedule.length, 1);
      expect(d.schedule.single.days, [1, 4]);
    },
  );

  test('a legacy key is matched by label instead of duplicated', () async {
    await MedDb.putDef(
      db,
      const MedDef(
        key: 'custom_gr_ner_tee',
        label: 'Grüner Tee',
        doseValue: 1,
        doseUnit: 'cup',
        schedule: [MedSchedule(600, [])],
      ),
    );
    await MedDb.addScheduledTime(db, 'grüner tee', const MedSchedule(900, []));
    final all = await MedDb.defs(db, activeOnly: false);
    expect(all.length, 1);
    expect(all.single.key, 'custom_gr_ner_tee');
    expect([for (final s in all.single.schedule) s.minuteOfDay], [600, 900]);
    expect(all.single.doseLabel, '1 cup');
  });

  test('a new name is created as directed', () async {
    await MedDb.addScheduledTime(db, 'Magnesium', const MedSchedule(1260, []));
    final d = (await MedDb.defs(db)).single;
    expect(d.key, MedDb.keyFor('Magnesium'));
    expect(d.doseLabel, 'As directed');
    expect(d.kind, 'medication');
  });
}
