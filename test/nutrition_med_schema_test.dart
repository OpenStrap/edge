// Schema 35 (nutrition) and 36 (medication), through the REAL ladder.
//
// The point is not that the CREATE ran. It is that a database seeded at v34 —
// what every existing install is — upgrades without throwing and accepts a
// write IMMEDIATELY, not on the next launch. onUpgrade runs inside one
// exclusive transaction, so a single throwing step rolls the whole ladder back
// and leaves the app permanently stuck on the loading screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';

/// Enough of the v34 shape for the ladder to have something real to walk.
const _v34Ddl = [
  '''
  CREATE TABLE derived_day (
    date TEXT PRIMARY KEY, payload_json TEXT NOT NULL, version INTEGER NOT NULL,
    last_raw_ts INTEGER NOT NULL, computed_at INTEGER NOT NULL,
    rhr REAL, rmssd REAL, readiness REAL)
''',
  '''
  CREATE TABLE baselines (
    key TEXT PRIMARY KEY, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)
''',
  '''
  CREATE TABLE metric_series (
    date TEXT NOT NULL, key TEXT NOT NULL, value REAL, PRIMARY KEY (date, key))
''',
  "CREATE TABLE journal (date TEXT PRIMARY KEY, "
      "tags_json TEXT NOT NULL DEFAULT '[]', "
      "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)",
];

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

void main() {
  const name = 'migrate_from_v34_nutrition_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _dbPath(name));
  });

  test('two non-Latin medication names do not share a key', () {
    // putDef REPLACEs by key: a shared `custom__` meant the second med
    // overwrote the first and took over its dose history.
    expect(MedDb.keyFor('鱼油'), isNot(MedDb.keyFor('铁')));
    expect(MedDb.keyFor('Vitamin D'), 'custom_vitamin_d');
  });

  test('v34 → 36 adds nutrition and medication, usable immediately', () async {
    final path = await _dbPath(name);
    await databaseFactory.deleteDatabase(path);
    final seeded = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 34,
        onCreate: (db, _) async {
          for (final s in _v34Ddl) {
            await db.execute(s);
          }
        },
      ),
    );
    await seeded.insert('journal', {
      'date': '2026-08-14',
      'tags_json': '["late meal"]',
      'note': 'kept',
      'updated_at': 1,
    });
    await seeded.close();

    await LocalDb.close();
    LocalDb.dbName = name;
    final db = await LocalDb.instance;

    expect(
      (await db.rawQuery('PRAGMA user_version')).first.values.first,
      LocalDb.schemaVersion,
    );
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(36));

    // Purely additive: what was already stored is untouched.
    final journal = await LocalDb.journalRows();
    expect(journal.single['note'], 'kept');

    // The tables work on this launch, not the next one.
    await NutritionDb.put(
      db,
      const FoodEntry(
        id: 'f1',
        date: '2026-08-14',
        meal: 'dinner',
        label: 'Chicken and rice',
        kcal: 620,
        proteinG: 48,
        confirmed: true,
      ),
    );
    final day = await NutritionDb.entriesForDay(db, '2026-08-14');
    expect(day.single.kcal, 620);
    // Every nutrient column is nullable, and an unwritten one stays NULL
    // rather than defaulting to a zero the user never claimed.
    expect(day.single.fibreG, isNull);

    await MedDb.putDef(
      db,
      const MedDef(
        key: 'custom_d',
        label: 'Vitamin D',
        doseValue: 2000,
        doseUnit: 'IU',
        schedule: [
          MedSchedule(480, [1, 2, 3, 4, 5, 6, 7]),
        ],
      ),
    );
    final defs = await MedDb.defs(db);
    expect(defs.single.doseLabel, '2000 IU');
    expect(defs.single.schedule.single.minuteOfDay, 480);
    // `created_at` is read back, not just written: it bounds every adherence
    // denominator, so a def that cannot say when it started makes every day
    // before it a run of misses.
    final createdAt = defs.single.createdAt;
    expect(createdAt, isNotNull);

    // An EDIT arrives as a fresh MedDef with no stamp, and the row is written
    // with REPLACE — restamping it to now would silently drop every dose the
    // schedule had already come due for out of adherence.
    await MedDb.putDef(
      db,
      const MedDef(
        key: 'custom_d',
        label: 'Vitamin D3',
        doseValue: 4000,
        doseUnit: 'IU',
        schedule: [
          MedSchedule(480, [1, 2, 3, 4, 5, 6, 7]),
        ],
      ),
    );
    final edited = await MedDb.defs(db);
    expect(edited.single.label, 'Vitamin D3');
    expect(edited.single.createdAt, createdAt);

    await MedDb.mark(
      db,
      medKey: 'custom_d',
      date: '2026-08-14',
      slotMin: 480,
      taken: true,
    );
    final doses = await MedDb.dosesForDay(db, '2026-08-14');
    expect(doses['custom_d']![480]!['taken_ts'], isNotNull);

    // An untaken slot stores NULL rather than 0 — that distinction is what
    // keeps a future dose out of the adherence denominator.
    await MedDb.mark(
      db,
      medKey: 'custom_d',
      date: '2026-08-13',
      slotMin: 480,
      taken: false,
    );
    final earlier = await MedDb.dosesForDay(db, '2026-08-13');
    expect(earlier['custom_d']![480]!['taken_ts'], isNull);

    final health = await LocalDb.schemaHealth();
    expect(health['ok'], isTrue, reason: '$health');
  });
}
