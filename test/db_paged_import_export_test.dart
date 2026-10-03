// Paged source reads on the import/export paths, run against the REAL LocalDb
// over sqflite_ffi.
//
// THE BUG (production, Crashlytics 0.9.19, Android):
//   java.lang.OutOfMemoryError — "Failed to allocate a 32 byte allocation with
//   27360 free bytes and 26KB until OOM, target footprint 268435456, growth
//   limit 268435456", with `current_screen: ImportScreen`.
//
// `importFromDbFile` read each source table with ONE unbounded `src.query(t)`,
// and `exportDaysDb`'s `copyRawRange` read a whole day of `decoded_onehz` in
// one statement. sqflite serialises an entire result set into Java objects
// BEFORE any of it crosses the platform channel, so a full-history
// `decoded_onehz` (86,400 rows per day) had to fit on the 256 MB Dalvik heap
// all at once — and was then held live for the duration of the insert loop.
//
// Both are now keyset-paged on rowid at 2000 rows. These tests drive row counts
// ACROSS several page boundaries (and off-by-one around them) to prove paging
// neither drops nor duplicates rows, since a broken cursor is silent: you get
// a partial import, not an error.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

/// The page size used by both paged readers in db.dart. The tests deliberately
/// straddle it rather than assuming any particular value is "big enough".
const int kPageSize = 2000;

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

void main() {
  late Directory tmp;
  late String srcPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_paged_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    LocalDb.dbName = 'openstrap_paged_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    srcPath = p.join(await databaseFactory.getDatabasesPath(), 'paged_src.db');
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await databaseFactory.deleteDatabase(srcPath);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Builds a foreign export holding [rows] seconds of 1 Hz data, each with one
  /// RR beat, starting at [startTs] / counter 1.
  Future<void> buildSource(int rows, {required int startTs}) async {
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute('''
      CREATE TABLE decoded_onehz (
        counter INTEGER PRIMARY KEY, rec_ts INTEGER NOT NULL,
        hr INTEGER NOT NULL, ax REAL NOT NULL, ay REAL NOT NULL,
        az REAL NOT NULL, spo2_red_raw INTEGER NOT NULL,
        spo2_ir_raw INTEGER NOT NULL, skin_temp_raw INTEGER NOT NULL)
    ''');
    await src.execute('''
      CREATE TABLE decoded_rr (
        counter INTEGER NOT NULL, beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index))
    ''');
    final batch = src.batch();
    for (var i = 0; i < rows; i++) {
      final counter = i + 1;
      final ts = startTs + i;
      batch.insert('decoded_onehz', {
        'counter': counter,
        'rec_ts': ts,
        // hr encodes the index so a shuffled/duplicated row is detectable.
        'hr': 40 + (i % 100),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 0,
      });
      batch.insert('decoded_rr', {
        'counter': counter,
        'beat_index': 0,
        'rr_ts_ms': ts * 1000,
        'rr_ms': 800 + (i % 50),
      });
    }
    await batch.commit(noResult: true);
    await src.close();
  }

  Future<void> clearLocal() async {
    final db = await LocalDb.instance;
    await db.delete('decoded_rr');
    await db.delete('decoded_onehz');
  }

  group('importFromDbFile pages the source without losing rows', () {
    // Straddle the boundary from both sides plus a clean multiple, which is
    // where an off-by-one cursor (`rowid >=` instead of `>`, or stopping on a
    // full final page) shows up.
    for (final rows in [
      kPageSize - 1,
      kPageSize,
      kPageSize + 1,
      kPageSize * 2,
      kPageSize * 2 + 37,
    ]) {
      test('$rows rows import exactly once', () async {
        await clearLocal();
        const startTs = 1786100000;
        await buildSource(rows, startTs: startTs);

        final counts = await LocalDb.importFromDbFile(srcPath);
        expect(counts['decoded_onehz'], rows,
            reason: 'every source row must be reported as copied');

        final db = await LocalDb.instance;
        final n = (await db.rawQuery(
          'SELECT COUNT(*) c FROM decoded_onehz',
        )).first['c'];
        expect(n, rows, reason: 'no rows dropped at a page boundary');

        final beats = (await db.rawQuery(
          'SELECT COUNT(*) c FROM decoded_rr',
        )).first['c'];
        expect(beats, rows, reason: 'RR beats page alongside their frames');

        // Endpoints prove the cursor covered the whole range, not just a prefix.
        final lo = (await db.rawQuery(
          'SELECT MIN(rec_ts) v FROM decoded_onehz',
        )).first['v'];
        final hi = (await db.rawQuery(
          'SELECT MAX(rec_ts) v FROM decoded_onehz',
        )).first['v'];
        expect(lo, startTs);
        expect(hi, startTs + rows - 1);

        // A duplicated page would show up as a gap in distinct timestamps.
        final distinct = (await db.rawQuery(
          'SELECT COUNT(DISTINCT rec_ts) c FROM decoded_onehz',
        )).first['c'];
        expect(distinct, rows);

        // Nothing stranded: every beat's rec_ts owns a decoded_onehz row.
        final orphans = (await db.rawQuery(
          'SELECT COUNT(*) c FROM decoded_rr '
          'WHERE rec_ts NOT IN (SELECT rec_ts FROM decoded_onehz)',
        )).first['c'];
        expect(orphans, 0);
      });
    }

    test('re-importing the same file is idempotent, not doubled', () async {
      await clearLocal();
      final rows = kPageSize + 500;
      await buildSource(rows, startTs: 1786200000);

      await LocalDb.importFromDbFile(srcPath);
      await LocalDb.importFromDbFile(srcPath);

      final db = await LocalDb.instance;
      final n = (await db.rawQuery(
        'SELECT COUNT(*) c FROM decoded_onehz',
      )).first['c'];
      expect(n, rows,
          reason: 'per-page transactions must stay INSERT OR REPLACE-safe, so '
              'an interrupted import is always safe to re-run');
    });

    test('a source missing most tables skips them without throwing', () async {
      // The fixture only ever creates decoded_onehz + decoded_rr, so every
      // other table in the import list raises "no such table" on its first
      // page. That path is narrowed to `DatabaseException.isNoSuchTableError()`
      // precisely so a genuine read failure can no longer masquerade as an
      // absent table — which means if that predicate ever stops matching
      // sqflite's real exception, importing a partial export would start
      // THROWING instead of skipping. Asserted explicitly rather than left to
      // ride implicitly on the paging tests above.
      await clearLocal();
      await buildSource(10, startTs: 1786400000);

      final counts = await LocalDb.importFromDbFile(srcPath);

      expect(counts['decoded_onehz'], 10, reason: 'present tables still copy');
      expect(counts.containsKey('journal'), isFalse,
          reason: 'a table absent from the source is skipped, not reported as '
              'an empty success');
    });

    test('an empty source table reports zero and writes nothing', () async {
      await clearLocal();
      await buildSource(0, startTs: 1786300000);
      final counts = await LocalDb.importFromDbFile(srcPath);
      expect(counts['decoded_onehz'], 0);
      final db = await LocalDb.instance;
      expect(
        (await db.rawQuery('SELECT COUNT(*) c FROM decoded_onehz')).first['c'],
        0,
      );
    });
  });

  group('exportDaysDb pages a whole day out', () {
    test('a multi-page day round-trips every row and beat', () async {
      await clearLocal();
      // ~2.4 pages inside a single local day, so copyRawRange must page.
      const rows = kPageSize * 2 + 800;
      // Anchor mid-day UTC so the local-day window contains the whole run
      // regardless of the machine's timezone offset.
      final startTs =
          DateTime.utc(2026, 5, 14, 2).millisecondsSinceEpoch ~/ 1000;
      await buildSource(rows, startTs: startTs);
      await LocalDb.importFromDbFile(srcPath);

      final db = await LocalDb.instance;
      final localDay = (await db.rawQuery(
        "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') d, "
        'COUNT(*) c FROM decoded_onehz GROUP BY d ORDER BY c DESC LIMIT 1',
      )).first;
      final dayId = localDay['d'] as String;
      final expectedRows = (localDay['c'] as num).toInt();
      expect(expectedRows, greaterThan(kPageSize),
          reason: 'the test is meaningless unless the day spans pages');

      final outPath = await LocalDb.exportDaysDb({dayId});
      expect(await File(outPath).exists(), isTrue);

      final out = await databaseFactory.openDatabase(outPath);
      try {
        final got = (await out.rawQuery(
          'SELECT COUNT(*) c FROM decoded_onehz',
        )).first['c'];
        expect(got, expectedRows,
            reason: 'every row of the day must survive the paged export');

        final beats = (await out.rawQuery(
          'SELECT COUNT(*) c FROM decoded_rr',
        )).first['c'];
        expect(beats, expectedRows,
            reason: 'each page\'s beats are pulled before the next page');

        final distinct = (await out.rawQuery(
          'SELECT COUNT(DISTINCT rec_ts) c FROM decoded_onehz',
        )).first['c'];
        expect(distinct, expectedRows, reason: 'no page copied twice');
      } finally {
        await out.close();
        await databaseFactory.deleteDatabase(outPath);
      }
    });
  });

  test('exportDaysDb copies a day that has a workout on it', () async {
    await clearLocal();
    // Local noon, so the session sits inside the day in any timezone.
    final start = DateTime(2026, 5, 20, 12).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSession({
      'id': 'manual:$start',
      'start_ts': start,
      'end_ts': start + 1800,
      'type': 'run',
      'status': 'done',
      'avg_hr': 140,
      'created_at': start * 1000,
    });
    final outPath = await LocalDb.exportDaysDb({'2026-05-20'});
    final out = await databaseFactory.openDatabase(outPath);
    try {
      final rows = await out.query('sessions');
      expect([for (final r in rows) r['avg_hr']], [140]);
    } finally {
      await out.close();
      await databaseFactory.deleteDatabase(outPath);
    }
  });

  group('importFromDbFile applies the v46 data rule at the seam', () {
    test('a pre-v46 backup cannot reinstate the retired columns', () async {
      await clearLocal();
      // A pre-v46 export: rows still carry the disproven on_wrist/hr_valid
      // values and the -50.00 °C skin-temp error sentinel. The v46 migration
      // only runs on version bumps, so the import seam is the ONLY line of
      // defence for these rows.
      await databaseFactory.deleteDatabase(srcPath);
      final src = await databaseFactory.openDatabase(srcPath);
      await src.execute('''
        CREATE TABLE decoded_onehz (
          rec_ts INTEGER PRIMARY KEY, counter INTEGER NOT NULL,
          hr INTEGER, skin_temp_c REAL, on_wrist INTEGER, hr_valid INTEGER)
      ''');
      await src.insert('decoded_onehz', {
        'rec_ts': 1786200000,
        'counter': 1,
        'hr': 62,
        'skin_temp_c': -50.0, // the unavailable/error sentinel
        'on_wrist': 1,
        'hr_valid': 1,
      });
      await src.insert('decoded_onehz', {
        'rec_ts': 1786200001,
        'counter': 2,
        'hr': 63,
        'skin_temp_c': 30.57, // a real reading must survive untouched
        'on_wrist': 1,
        'hr_valid': 0,
      });
      await src.close();

      await LocalDb.importFromDbFile(srcPath);

      final db = await LocalDb.instance;
      final rows = await db.rawQuery(
        'SELECT rec_ts, hr, skin_temp_c, on_wrist, hr_valid '
        'FROM decoded_onehz WHERE rec_ts IN (1786200000, 1786200001) '
        'ORDER BY rec_ts',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['hr'], 62, reason: 'the honest fields import normally');
      expect(rows[0]['skin_temp_c'], isNull,
          reason: 'the -50.00 °C sentinel is an absence, not a temperature');
      expect(rows[1]['skin_temp_c'], closeTo(30.57, 1e-9),
          reason: 'a real reading is not collateral damage');
      for (final r in rows) {
        expect(r['on_wrist'], isNull,
            reason: 'no honest writer exists for on_wrist');
        expect(r['hr_valid'], isNull,
            reason: 'no honest writer exists for hr_valid');
      }
    });
  });
}
