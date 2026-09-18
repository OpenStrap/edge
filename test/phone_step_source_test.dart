import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Steps now come ONLY from a source that can actually resolve gait, and the
/// two such sources must never be summed: the phone (pocket, sees trunk motion)
/// and the band (wrist, documented emitting 22-27 false steps/min during
/// dishes/driving) both count the same walk. Adding them roughly doubles a day.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const day = '2026-08-03';
  const otherDay = '2026-08-02';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_phone_step_source_test.db';
  });

  setUp(() async {
    // Fresh DB per test — `live_coverage` is append-only, so leakage between
    // tests would look exactly like the double-counting these tests exist to
    // rule out.
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('band-only day sums the band rows', () async {
    await LocalDb.addLiveCoverage(1000, 1600, 120, day);
    await LocalDb.addLiveCoverage(2000, 2600, 80, day);
    expect(await LocalDb.liveStepsForDay(day), 200);
  });

  test('phone WINS outright when present — the two are never added', () async {
    await LocalDb.addLiveCoverage(1000, 1600, 120, day); // wrist
    await LocalDb.replacePhoneCoverageForDay(
      day,
      [(startTs: 1000, endTs: 4600, steps: 350)],
    );
    // NOT 470. The phone measured the same walking from a better place.
    expect(await LocalDb.liveStepsForDay(day), 350);
  });

  test('phone sync is idempotent — re-syncing a day never accumulates',
      () async {
    for (var i = 0; i < 3; i++) {
      await LocalDb.replacePhoneCoverageForDay(
        day,
        [
          (startTs: 1000, endTs: 4600, steps: 350),
          (startTs: 4600, endTs: 8200, steps: 120),
        ],
      );
    }
    expect(await LocalDb.liveStepsForDay(day), 470);
  });

  test('a later sync REPLACES an earlier partial one rather than adding',
      () async {
    await LocalDb.replacePhoneCoverageForDay(
      day,
      [(startTs: 1000, endTs: 4600, steps: 100)],
    );
    // The day filled in; the same hour now reads higher.
    await LocalDb.replacePhoneCoverageForDay(
      day,
      [(startTs: 1000, endTs: 4600, steps: 900)],
    );
    expect(await LocalDb.liveStepsForDay(day), 900);
  });

  test('phone replace is scoped to its day and never touches band rows',
      () async {
    await LocalDb.addLiveCoverage(1000, 1600, 55, otherDay);
    await LocalDb.replacePhoneCoverageForDay(
      otherDay,
      [(startTs: 1000, endTs: 4600, steps: 700)],
    );
    await LocalDb.replacePhoneCoverageForDay(day, const []);

    // Clearing today's phone rows must not disturb yesterday.
    expect(await LocalDb.liveStepsForDay(otherDay), 700);
    // And with today's phone rows gone, the band fallback returns.
    await LocalDb.addLiveCoverage(9000, 9600, 42, day);
    expect(await LocalDb.liveStepsForDay(day), 42);
  });

  test('an empty phone sync leaves the day with no steps, not a zero row',
      () async {
    await LocalDb.replacePhoneCoverageForDay(day, const []);
    expect(await LocalDb.liveStepsForDay(day), 0);
  });

  test('a zero phone window IS stored (confirmed-still evidence); inverted '
      'ones are dropped', () async {
    await LocalDb.replacePhoneCoverageForDay(
      day,
      [
        (startTs: 1000, endTs: 4600, steps: 0), // confirmed motionless hour
        (startTs: 5000, endTs: 4000, steps: 50), // inverted
        (startTs: 6000, endTs: 9600, steps: 75), // the only real one
      ],
    );
    expect(await LocalDb.liveStepsForDay(day), 75);
    // `resolvedStepsForDay` omits zero-credit spans on purpose, so checking
    // it alone would pass just the same if the zero row had been dropped —
    // query the table directly for what a regression here would actually
    // break (the confirmed-still veto in live_coverage_policy_test.dart).
    final db = await LocalDb.instance;
    final rows = await db.query(
      'live_coverage',
      where: 'day = ? AND source = ? AND steps = 0',
      whereArgs: [day, LocalDb.kStepSourcePhone],
    );
    expect(rows, hasLength(1));
    expect(rows.single['start_ts'], 1000);
    expect(rows.single['end_ts'], 4600);
    // The inverted window never made it in at all.
    final allPhoneRows = await db.query(
      'live_coverage',
      where: 'day = ? AND source = ?',
      whereArgs: [day, LocalDb.kStepSourcePhone],
    );
    expect(allPhoneRows, hasLength(2));
  });

  test('clearing phone coverage falls back to the band, not to zero', () async {
    await LocalDb.addLiveCoverage(1000, 1600, 64, day); // band
    await LocalDb.replacePhoneCoverageForDay(
      day,
      [(startTs: 1000, endTs: 4600, steps: 900)],
    );
    expect(await LocalDb.liveStepsForDay(day), 900, reason: 'phone preferred');

    // User turns phone steps off: the phone rows must go, or they would keep
    // overriding the band forever from a source no longer being read.
    await LocalDb.clearPhoneCoverage();
    expect(await LocalDb.liveStepsForDay(day), 64);
  });

  group('v27 migration — the path EVERY existing install takes', () {
    // Every other test here opens a fresh DB, so `onCreate` emits the `source`
    // column directly and the `if (oldV < 27)` step never runs. That upgrade
    // path carries a load-bearing assumption: pre-v27 rows must default to
    // 'band'. If they defaulted to 'phone', every existing band count would be
    // read as a phone count and would suppress the real band fallback. An
    // unguarded ALTER TABLE has also bricked this file's upgrades twice.

    Future<void> seedV26() async {
      final dir = await databaseFactory.getDatabasesPath();
      final db = await databaseFactory.openDatabase(
        p.join(dir, LocalDb.dbName),
        options: OpenDatabaseOptions(
          version: 26,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE live_coverage ('
                'id INTEGER PRIMARY KEY AUTOINCREMENT,'
                'start_ts INTEGER NOT NULL,'
                'end_ts INTEGER NOT NULL,'
                'steps INTEGER NOT NULL,'
                'day TEXT NOT NULL)');
          },
        ),
      );
      await db.insert('live_coverage', {
        'start_ts': 1000,
        'end_ts': 1600,
        'steps': 137,
        'day': day,
      });
      await db.close();
    }

    test('a pre-v27 row survives the upgrade and counts as BAND', () async {
      await seedV26();

      // Reopening through LocalDb runs the real migration ladder.
      expect(await LocalDb.liveStepsForDay(day), 137,
          reason: 'the legacy row must still count after upgrading');

      // ...and it must be BAND, so a phone sync can still take precedence.
      await LocalDb.replacePhoneCoverageForDay(
        day,
        [(startTs: 1000, endTs: 4600, steps: 900)],
      );
      expect(await LocalDb.liveStepsForDay(day), 900,
          reason: 'legacy rows defaulting to phone would block this override');

      // Dropping the phone rows reveals the legacy band row again — proof it
      // was never silently relabelled.
      await LocalDb.clearPhoneCoverage();
      expect(await LocalDb.liveStepsForDay(day), 137);
    });

    test('the migration is idempotent across repeated opens', () async {
      await seedV26();
      expect(await LocalDb.liveStepsForDay(day), 137);
      await LocalDb.close();
      // The second open re-runs `_repairOpenSchema`, which also calls
      // `_ensureLiveCoverageSource`. An unguarded ALTER would throw here.
      expect(await LocalDb.liveStepsForDay(day), 137);
    });
  });
}
