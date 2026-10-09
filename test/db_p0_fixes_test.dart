// P0 regressions in the LocalDb data layer, run against the REAL LocalDb over
// sqflite_ffi. Each test fails against the pre-fix behaviour.
//
//  1. exportDaysDb had NEVER worked — openDatabase(onCreate:) with no version:
//     throws ArgumentError before opening anything; and the decoded_rr copy
//     built one `IN (?, …)` per counter (86 400 a day, past
//     SQLITE_MAX_VARIABLE_NUMBER).
//  3. the decoded_rr orphan guard covered only the UNIQUE(rec_ts) eviction, not
//     the `counter` PRIMARY KEY eviction the strap's reboot counter-reset causes.
//  4. decodedRrByCounterRange assumed counters rise with rec_ts, so a page
//     spanning a reboot queried `counter >= high AND counter <= low` → zero rows
//     and the whole page's RR beats vanished silently (no RMSSD/HRV).
//  5. deleteDays never cascaded workout_route (deleteSession does), so a deleted
//     GPS run left every lat/lng point on disk forever.
//  8. importFromDbFile replayed decoded_onehz through a plain batch.insert,
//     bypassing the orphan guard entirely.
// 10. day/night counts are answered in SQL, never by decoding payloads. (Their
//     one caller, getRecords, has since stopped asking for them at all — the
//     helpers stay because a payload-free count is the shape any future one
//     should use.)
// 11. the timeline's event query was the OLDEST 2000 rows globally, so recent
//     days' markers vanished once `events` grew past that.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

/// path_provider has no plugin in a unit test; exportDaysDb needs a temp dir.
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

Sample _sample(int ts, int counter, List<int> rr) => Sample(
  tsEpoch: ts,
  counter: counter,
  hr: 70,
  rrIntervalsMs: rr,
  ax: 0,
  ay: 0,
  az: 0,
  spo2RedRaw: 0,
  spo2IrRaw: 0,
  skinTempRaw: 0,
);

RawRecord _raw(int ts, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  hex: 'p0fix$counter',
  capturedAt: ts * 1000,
  recTs: ts,
);

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_p0_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    LocalDb.dbName = 'openstrap_p0_fixes_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await databaseFactory.deleteDatabase(p.join(dir, 'p0_foreign_export.db'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ── fix 3: THE re-key regression ─────────────────────────────────────────
  test(
    'a REUSED counter (reboot reset) KEEPS both seconds — the counter-PK '
    'eviction that silently, unrecoverably deleted a 1 Hz row is gone',
    () async {
      const older = 1785000000; // pre-reboot, counter 777
      const newer = 1785000600; // post-reboot, SAME counter 777
      const counter = 777;

      await LocalDb.insertRecord(
        _raw(older, counter),
        _sample(older, counter, [800, 810, 820]), // THREE beats
      );
      // Pre-fix: `counter` was decoded_onehz's PRIMARY KEY, so this REPLACE
      // evicted the `older` row entirely — and raw_records is dropped, so that
      // 1 Hz second was gone for good. Under the rec_ts key both seconds live.
      await LocalDb.insertRecord(
        _raw(newer, counter),
        _sample(newer, counter, [900, 910]), // TWO beats
      );

      final db = await LocalDb.instance;
      final rows = await db.query(
        'decoded_onehz',
        where: 'rec_ts IN (?, ?)',
        whereArgs: [older, newer],
        orderBy: 'rec_ts ASC',
      );
      expect(rows, hasLength(2),
          reason: 'the pre-reboot second must NOT be evicted');
      expect([for (final r in rows) r['counter']], [counter, counter]);

      // Each second keeps its own beats, keyed by its rec_ts.
      final oldBeats = await db.query('decoded_rr',
          where: 'rec_ts = ?', whereArgs: [older], orderBy: 'beat_index ASC');
      expect([for (final b in oldBeats) b['rr_ms']], [800, 810, 820]);
      final newBeats = await db.query('decoded_rr',
          where: 'rec_ts = ?', whereArgs: [newer], orderBy: 'beat_index ASC');
      expect([for (final b in newBeats) b['rr_ms']], [900, 910]);

      // Re-offloading `older` with FEWER beats must not strand the third —
      // the write path DELETEs the second's beats before reinserting.
      await LocalDb.insertRecord(
        _raw(older, counter),
        _sample(older, counter, [850]), // ONE beat now
      );
      final reBeats = await db.query('decoded_rr',
          where: 'rec_ts = ?', whereArgs: [older], orderBy: 'beat_index ASC');
      expect([for (final b in reBeats) b['rr_ms']], [850],
          reason: 'stale high-index beats must not survive a shrink');

      // No beat carries the wrong second's timestamp, anywhere.
      final stale = await db.rawQuery(
        'SELECT COUNT(*) c FROM decoded_rr WHERE rr_ts_ms != rec_ts * 1000',
      );
      expect(stale.first['c'], 0);
    },
  );

  // ── fix 4 ────────────────────────────────────────────────────────────────
  test(
    'decodedRrByRecTsRange returns a page spanning a counter RESET — the '
    'window is by rec_ts, immune to the reboot counter reset',
    () async {
      const t0 = 1785100000;
      // Pre-reboot: high counter. Post-reboot: the counter restarts near zero,
      // for the NEXT second — exactly what a page ordered by (rec_ts, counter)
      // straddles.
      await LocalDb.insertRecord(
        _raw(t0, 1200000),
        _sample(t0, 1200000, [800, 805]),
      );
      await LocalDb.insertRecord(
        _raw(t0 + 1, 5),
        _sample(t0 + 1, 5, [900, 905]),
      );

      // Read the page exactly as derivation_engine does.
      final page = await LocalDb.decodedOneHzBatchByRecTsRange(
        limit: 100,
        fromRecTs: t0,
        toRecTs: t0 + 1,
      );
      expect(page, hasLength(2));
      final first = (page.first['rec_ts'] as num).toInt();
      final last = (page.last['rec_ts'] as num).toInt();
      expect(first, t0);
      expect(last, t0 + 1);
      // Sanity: the page really does end on a LOWER counter (reboot straddle).
      expect((page.first['counter'] as num).toInt(), 1200000);
      expect((page.last['counter'] as num).toInt(), 5);

      final rr = await LocalDb.decodedRrByRecTsRange(
        fromRecTs: first,
        toRecTs: last,
      );
      // A counter span (`>= 1200000 AND <= 5`) used to match nothing at all —
      // the window silently produced no RR beats, so no RMSSD/HRV, no error.
      expect(rr, hasLength(4));
      expect([for (final r in rr) r['rr_ms']], [800, 805, 900, 905]);
    },
  );

  // ── fix 5 ────────────────────────────────────────────────────────────────
  test('deleteDays cascades workout_route with its session', () async {
    const dayId = '2026-04-10';
    final startSec =
        DateTime(2026, 4, 10, 9).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSession({
      'id': 'run-with-route',
      'start_ts': startSec,
      'end_ts': startSec + 1800,
      'type': 'run',
      'status': 'done',
      'source': 'manual',
      'created_at': startSec * 1000,
    });
    await LocalDb.appendRoutePoints('run-with-route', [
      for (var i = 0; i < 5; i++)
        {
          'session_id': 'run-with-route',
          'seq': i,
          'ts_ms': (startSec + i) * 1000,
          'lat': 12.97 + i * 0.001,
          'lng': 77.59 + i * 0.001,
        },
    ]);
    expect(await LocalDb.sessionHasRoute('run-with-route'), isTrue);

    await LocalDb.deleteDays({dayId});

    final db = await LocalDb.instance;
    expect(
      await db.query('sessions', where: 'id = ?', whereArgs: ['run-with-route']),
      isEmpty,
    );
    expect(
      await db.query(
        'workout_route',
        where: 'session_id = ?',
        whereArgs: ['run-with-route'],
      ),
      isEmpty,
      reason: 'every lat/lng point of a deleted day must go with it',
    );
  });

  // ── fix 11 ───────────────────────────────────────────────────────────────
  test(
    'eventsInRange is bounded BY THE DAY — a day past the oldest-2000 page is '
    'still reachable',
    () async {
      final db = await LocalDb.instance;
      await db.delete('events');
      final base = DateTime(2026, 5, 1).millisecondsSinceEpoch ~/ 1000;
      // 2400 old events, then 3 on a much later day.
      final batch = db.batch();
      for (var i = 0; i < 2400; i++) {
        batch.insert('events', {
          'hex': 'old$i',
          'event_id': 1,
          'ts': base + i,
          'captured_at': (base + i) * 1000,
        });
      }
      final lateDayStart =
          DateTime(2026, 5, 20).millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < 3; i++) {
        batch.insert('events', {
          'hex': 'new$i',
          'event_id': 2,
          'ts': lateDayStart + 3600 * (i + 1),
          'captured_at': (lateDayStart + 3600 * (i + 1)) * 1000,
        });
      }
      await batch.commit(noResult: true);

      // The OLD path: oldest-2000 globally, then filtered to the day → nothing.
      final oldest = await LocalDb.unuploadedEvents(limit: 2000);
      final viaOldPath = oldest.where(
        (e) =>
            (e['ts'] as num) >= lateDayStart &&
            (e['ts'] as num) < lateDayStart + 86400,
      );
      expect(
        viaOldPath,
        isEmpty,
        reason: 'documents the bug the day-bounded query replaces',
      );

      final viaNewPath = await LocalDb.eventsInRange(
        lateDayStart,
        lateDayStart + 86400,
      );
      expect(viaNewPath, hasLength(3));
      expect(viaNewPath.every((e) => e['event_id'] == 2), isTrue);
    },
  );

  // ── fix 10 ───────────────────────────────────────────────────────────────
  test(
    'dayResultDayIdsDesc / daysWithSleepTst answer in SQL, latest version only',
    () async {
      final db = await LocalDb.instance;
      await db.delete('day_result');
      await LocalDb.putDayResult(
        dayId: '2026-02-01',
        algoVersion: 40,
        payloadJson: '{"sleep":{"accounting":{"value":{"tst_sec":21600}}}}',
        windowJson: '{}',
      );
      // A LATER version of the same day that lost its sleep block — the latest
      // version is the one that counts.
      await LocalDb.putDayResult(
        dayId: '2026-02-01',
        algoVersion: 41,
        payloadJson: '{"sleep":{"accounting":{"value":{"tst_sec":25200}}}}',
        windowJson: '{}',
      );
      await LocalDb.putDayResult(
        dayId: '2026-02-02',
        algoVersion: 41,
        payloadJson: '{"sleep":{"accounting":{"value":{}}}}',
        windowJson: '{}',
      );
      // A corrupt payload must degrade to "no sleep", never take the query out.
      await LocalDb.putDayResult(
        dayId: '2026-02-03',
        algoVersion: 41,
        payloadJson: 'not json at all',
        windowJson: '{}',
      );

      expect(await LocalDb.dayResultDayIdsDesc(), [
        '2026-02-03',
        '2026-02-02',
        '2026-02-01',
      ]);
      expect(await LocalDb.daysWithSleepTst(), {'2026-02-01'});
    },
  );

  // ── fix 8 ────────────────────────────────────────────────────────────────
  test(
    'importFromDbFile merges a LEGACY (counter-keyed, no rec_ts) decoded export '
    'cleanly under the rec_ts key — foreign-wins, no stranded beats',
    () async {
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz');
      await db.delete('decoded_rr');

      const collideTs = 1786000000; // rec_ts present locally AND in the foreign
      const t2 = 1786000500; // local-only second
      const t3 = 1786009999; // foreign-only second

      await LocalDb.insertRecord(
        _raw(collideTs, 8002),
        _sample(collideTs, 8002, [700, 710, 720]),
      );
      await LocalDb.insertRecord(
        _raw(t2, 8003),
        _sample(t2, 8003, [600, 610]),
      );

      // A foreign export in the OLD schema: decoded_rr has a `counter` column
      // and NO rec_ts (the import must derive rec_ts from rr_ts_ms).
      final dir = await databaseFactory.getDatabasesPath();
      final srcPath = p.join(dir, 'p0_foreign_export.db');
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
      Future<void> foreign(int counter, int recTs, List<int> rr) async {
        await src.insert('decoded_onehz', {
          'counter': counter,
          'rec_ts': recTs,
          'hr': 61,
          'ax': 0.0,
          'ay': 0.0,
          'az': 0.0,
          'spo2_red_raw': 0,
          'spo2_ir_raw': 0,
          'skin_temp_raw': 0,
        });
        for (var i = 0; i < rr.length; i++) {
          await src.insert('decoded_rr', {
            'counter': counter,
            'beat_index': i,
            'rr_ts_ms': recTs * 1000,
            'rr_ms': rr[i],
          });
        }
      }

      // Same second as local, but with FEWER beats than the 3 already stored.
      // An equal-or-larger foreign set hides the bug: every local beat_index
      // gets overwritten and a row-by-row replace-insert looks correct. Only a
      // shrinking set exposes the stale local tail (beats 1 and 2) that a
      // merge-without-clear leaves spliced onto the foreign series.
      await foreign(8001, collideTs, [500]);
      await foreign(9999, t3, [400]);
      // SQLite storage classes are per VALUE, not per column, so an export can
      // hand back a String where INTEGER is declared. This beat has no usable
      // key: it must be dropped on its own rather than reaching the insert and
      // failing NOT NULL inside the transaction, which would abort every other
      // row above with it.
      await src.insert('decoded_rr', {
        'counter': 7777,
        'beat_index': 0,
        'rr_ts_ms': 'not-a-number',
        'rr_ms': 600,
      });
      // raw_archive: the kept store of frames we could not decode.
      // exportCopy() is a whole-db VACUUM INTO so these rows leave the device;
      // the import has to bring them back. Two rows sharing a counter with
      // DIFFERENT hex — the reboot-counter-reuse case the table is keyed on
      // `hex` to survive — must both land.
      await src.execute('''
        CREATE TABLE IF NOT EXISTS raw_archive (
          hex TEXT PRIMARY KEY,
          counter INTEGER,
          packet_type INTEGER NOT NULL,
          rec_ts INTEGER,
          captured_at INTEGER NOT NULL,
          reason TEXT NOT NULL
        )
      ''');
      for (final hex in ['deadbeef01', 'deadbeef02']) {
        await src.insert('raw_archive', {
          'hex': hex,
          'counter': 4242, // same counter, different boots
          'packet_type': 0x2F,
          'rec_ts': collideTs,
          'captured_at': collideTs * 1000,
          'reason': 'unknown_version',
        });
      }
      await src.close();

      await LocalDb.importFromDbFile(srcPath);

      // Foreign wins the rec_ts collision; the other two seconds are untouched.
      final onehz = await db.query('decoded_onehz', orderBy: 'rec_ts ASC');
      expect([for (final r in onehz) r['rec_ts']], [collideTs, t2, t3]);
      final collided =
          onehz.firstWhere((r) => r['rec_ts'] == collideTs);
      expect(collided['counter'], 8001, reason: 'foreign row won');
      expect(collided['hr'], 61);

      // The collided second's beats are EXACTLY the foreign set. Not a merge:
      // the local [700, 710, 720] must be gone, tail included.
      final b1 = await db.query('decoded_rr',
          where: 'rec_ts = ?', whereArgs: [collideTs], orderBy: 'beat_index ASC');
      expect([for (final b in b1) b['rr_ms']], [500],
          reason: 'stale local beats 1-2 would splice a foreign/local RR '
              'series into one second and silently corrupt its RMSSD');
      // The foreign-only second imported with rec_ts derived from rr_ts_ms.
      final b3 = await db.query('decoded_rr',
          where: 'rec_ts = ?', whereArgs: [t3]);
      expect([for (final b in b3) b['rr_ms']], [400]);
      expect(b3.first['rr_ts_ms'], t3 * 1000);

      // Both archived frames survived the restore.
      final archived = await db.query('raw_archive', orderBy: 'hex ASC');
      expect([for (final a in archived) a['hex']],
          ['deadbeef01', 'deadbeef02'],
          reason: 'raw_archive was missing from the import merge list, so a '
              'backup/restore silently dropped the one table whose entire '
              'purpose is that a frame is never lost');

      // Nothing orphaned, nothing cross-stamped, anywhere.
      final orphans = await db.rawQuery(
        'SELECT COUNT(*) c FROM decoded_rr '
        'WHERE rec_ts NOT IN (SELECT rec_ts FROM decoded_onehz)',
      );
      expect(orphans.first['c'], 0);
      final stale = await db.rawQuery(
        'SELECT COUNT(*) c FROM decoded_rr WHERE rr_ts_ms != rec_ts * 1000',
      );
      expect(stale.first['c'], 0);
    },
  );

  // ── fix 1 ────────────────────────────────────────────────────────────────
  test(
    'exportDaysDb actually produces a database, and copies well past '
    'SQLITE_MAX_VARIABLE_NUMBER counters of RR',
    () async {
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz');
      await db.delete('decoded_rr');

      const dayId = '2026-03-20';
      final dayStart = DateTime(2026, 3, 20).millisecondsSinceEpoch ~/ 1000;
      const n = 1200; // > SQLITE_MAX_VARIABLE_NUMBER's 999 floor
      await LocalDb.commitSyncBatch(
        [for (var i = 0; i < n; i++) _raw(dayStart + i, 90000 + i)],
        [for (var i = 0; i < n; i++) _sample(dayStart + i, 90000 + i, [800])],
      );
      await LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: 41,
        payloadJson: '{"exported":true}',
        windowJson: '{}',
      );

      // Before the fix this threw ArgumentError('onCreate must be null if no
      // version is specified') — the export had never once produced a file.
      final path = await LocalDb.exportDaysDb({dayId});
      expect(await File(path).exists(), isTrue);

      final out = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        int count(List<Map<String, Object?>> r) =>
            (r.first.values.first as num).toInt();
        expect(
          count(await out.rawQuery('SELECT COUNT(*) FROM decoded_onehz')),
          n,
        );
        expect(
          count(await out.rawQuery('SELECT COUNT(*) FROM decoded_rr')),
          n,
          reason: 'the chunked IN() must not drop any counter',
        );
        expect(
          count(await out.rawQuery('SELECT COUNT(*) FROM day_result')),
          1,
        );
      } finally {
        await out.close();
      }
    },
  );
}
