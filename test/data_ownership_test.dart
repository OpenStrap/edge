// "Delete everything" must delete everything, imports must not destroy
// measured days, and the app must not phone home without being asked.
//
// The reset test is the load-bearing one. The old reset walked the derived
// days and deleted those, which left about twenty tables standing behind a
// dialog that said otherwise — so the assertion here is deliberately
// "EVERY user-data table in sqlite_master is empty", not a list of table names.
// The store_identity row is rotated on wipe to invalidate old checkpoints. A list
// would have to be updated when a table is added, which is exactly the failure
// mode being tested for.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _count(List<Map<String, Object?>> rows) => (rows.first['n'] as num).toInt();

Future<void> _seedEverything() async {
  final db = await LocalDb.instance;
  // One row in every table, so "empty afterwards" cannot pass by accident on a
  // table that was never populated. Columns are discovered rather than
  // hard-coded: this test must not need editing when a schema does.
  for (final t in await LocalDb.tableNames()) {
    final cols = await db.rawQuery('PRAGMA table_info($t)');
    final row = <String, Object?>{};
    for (final c in cols) {
      final name = c['name'] as String;
      final type = (c['type'] as String? ?? '').toUpperCase();
      row[name] = type.contains('INT') || type.contains('REAL')
          ? 1
          : 'x'; // TEXT / BLOB / no affinity
    }
    try {
      await db.insert(t, row, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      // A CHECK constraint or a generated column can refuse the dummy row.
      // Not a problem: the tables that DO take one are enough to prove the
      // wipe is table-agnostic, and the emptiness assertion covers all of them.
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_data_ownership_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('wipeAll', () {
    test('leaves EVERY user-data table empty and rotates local store identity',
        () async {
      await _seedEverything();
      final db = await LocalDb.instance;
      final tables = await LocalDb.tableNames();
      expect(tables, isNotEmpty);

      // Sanity: the seed actually put something in the tables the old reset
      // was documented to miss. If these are empty before the wipe the test
      // proves nothing.
      for (final t in const [
        'lab_result',
        'baselines',
        'sync_cursor',
        'breathing_session',
        'strength_set',
        'raw_archive',
      ]) {
        if (!tables.contains(t)) continue;
        final n = _count(await db.rawQuery('SELECT COUNT(*) AS n FROM $t'));
        expect(n, greaterThan(0), reason: '$t was never seeded');
      }

      final storeId = await LocalDb.storeIdentity();
      await LocalDb.wipeAll();
      expect(await LocalDb.storeIdentity(), isNot(storeId));

      for (final t in tables) {
        final n = _count(await db.rawQuery('SELECT COUNT(*) AS n FROM $t'));
        expect(n, t == 'store_identity' ? 1 : 0,
            reason: '$t survived "Delete everything"');
      }
    });

    test('keeps the schema — no table is dropped and no migration re-runs',
        () async {
      final before = await LocalDb.tableNames();
      await LocalDb.wipeAll();
      expect(await LocalDb.tableNames(), before);
    });
  });

  group('isMeasuredDay — the guard every importer must pass', () {
    setUp(() async {
      final db = await LocalDb.instance;
      await db.delete('day_result');
    });

    test('absent day is not measured', () async {
      expect(await LocalDb.isMeasuredDay('2026-01-01'), isFalse);
    });

    test('a derived day IS measured, so an import must keep it', () async {
      await LocalDb.putDayResult(
        dayId: '2026-01-02',
        algoVersion: 1,
        payloadJson: '{"date":"2026-01-02"}',
        windowJson: '{}',
        finalized: true,
        readiness: 61,
      );
      expect(await LocalDb.isMeasuredDay('2026-01-02'), isTrue);
    });

    test('a skip marker is not measured', () async {
      await LocalDb.putDayResult(
        dayId: '2026-01-03',
        algoVersion: 1,
        payloadJson: '{"skipped":true}',
        windowJson: '{}',
        skipped: true,
      );
      expect(await LocalDb.isMeasuredDay('2026-01-03'), isFalse);
    });

    test('a previous import is replaceable', () async {
      await LocalDb.putDayResult(
        dayId: '2026-01-04',
        algoVersion: 1,
        payloadJson: '{"imported":true,"source":"cloud_v2"}',
        windowJson: '{}',
        finalized: true,
      );
      expect(await LocalDb.isMeasuredDay('2026-01-04'), isFalse);
    });

    test('present but unreadable is treated as real — never clobber', () {
      expect(
        LocalDb.isMeasuredDayRow({'payload_json': '{not json', 'skipped': 0}),
        isTrue,
      );
    });
  });

  test('every CSV export set runs, including the hand-entered ones', () async {
    final db = await LocalDb.instance;
    for (final set in kCsvExportSets) {
      // The query, not its result: six of these join tables that did not have
      // an export at all, and a typo in one SELECT would otherwise only
      // surface as a silently missing file in a user's export.
      final rows = await db.rawQuery(set.sql);
      expect(rows, isNotNull, reason: '${set.name} failed to run');
    }
  });

  test('the export names what it leaves out', () {
    expect(kCsvExportExclusions, isNotEmpty);
  });

  test('update checks do not fire on a build without the OTA feature',
      () async {
    // kSideloadOtaEnabled is a --dart-define, absent under `flutter test`, so
    // this is the store/self-built case: fetchStatus must make no request at
    // all. It used to be gated only on a non-empty URL, which meant a GET on
    // every launch and every foreground in shipped builds.
    expect(kSideloadOtaEnabled, isFalse);
    expect(await UpdateService.fetchStatus(), isNull);
  });
}
