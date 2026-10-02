// The BP research store guarantees the review fixes made explicit:
//   · a retake with NO device text replaces the reference instead of
//     duplicating it (NULL never equals NULL in a UNIQUE constraint, so
//     the store normalizes to '' — the rows must stay one, not two);
//   · deleting a capture removes its window row in the same transaction
//     (no PRAGMA foreign_keys here, so the ON DELETE CASCADE is inert);
//   · a retake that now finds band data replaces the old window instead
//     of orphaning it under the replaced reference's old id.
// Runs the REAL LocalDb over sqflite_common_ffi.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/bp_research_capture.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _at = 1700000000000; // ms

BpResearchCapture _capture(
  int measuredAtMs, {
  String? device,
  BpResearchWindow? window,
}) =>
    BpResearchCapture(
      measuredAtMs: measuredAtMs,
      device: device,
      posture: 'sitting',
      conditions: 'rest',
      systolicMmHg: 120,
      diastolicMmHg: 80,
      capturedAtMs: measuredAtMs,
      window: window,
    );

const _win = BpResearchWindow(
  windowStartMs: _at - 120000,
  windowEndMs: _at + 120000,
  onehzRows: 240,
  rrBeats: 200,
  hrMean: 62.5,
  rrMsMean: 960,
  rrMsMin: 800,
  rrMsMax: 1100,
  rmssdMs: 42,
  metaJson: null,
);

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'bp_research_db_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    final db = await LocalDb.instance;
    await db.close();
  });

  test('a retake with no device replaces the reference, not duplicates it',
      () async {
    await LocalDb.putBpResearchCapture(_capture(_at));
    await LocalDb.putBpResearchCapture(_capture(_at, window: _win));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(1));
    expect(rows.first['device'], '');
    expect(rows.first['hr_mean'], 62.5);
  });

  test('a named device stays distinct from the no-device row', () async {
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'omron'));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(2)); // the '' row from the previous test + omron
    expect(rows.where((r) => r['device'] == 'omron'), hasLength(1));
  });

  test('delete removes the window row too (the SQL cascade is inert)',
      () async {
    final db = await LocalDb.instance;
    final before =
        await db.rawQuery('SELECT COUNT(*) c FROM bp_research_window');
    expect(before.first['c'], greaterThan(0));
    final refs = await db
        .rawQuery('SELECT id FROM bp_research_reference WHERE device = ?',
            ['omron']);
    await LocalDb.deleteBpResearchCapture(refs.first['id'] as int);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
  });

  test('a retake that now finds band data replaces the absent window',
      () async {
    final later = _at + 60000;
    await LocalDb.putBpResearchCapture(_capture(later));
    await LocalDb.putBpResearchCapture(_capture(later, window: _win));
    final db = await LocalDb.instance;
    final windows = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id IN '
        '(SELECT id FROM bp_research_reference WHERE measured_at_ms = ?)',
        [later]);
    expect(windows.first['c'], 1);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
  });

  test('the research tables ride the backup restore and salvage lists',
      () async {
    expect(LocalDb.restoreTablesForTest, contains('bp_research_reference'));
    expect(LocalDb.restoreTablesForTest, contains('bp_research_window'));
    expect(LocalDb.salvageTablesForTest, contains('bp_research_reference'));
    expect(LocalDb.salvageTablesForTest, contains('bp_research_window'));
    // Parent before child, in both lists.
    int posOf(List<String> l, String t) => l.indexOf(t);
    expect(
      posOf(LocalDb.restoreTablesForTest, 'bp_research_reference'),
      lessThan(posOf(LocalDb.restoreTablesForTest, 'bp_research_window')),
    );
    expect(
      posOf(LocalDb.salvageTablesForTest, 'bp_research_reference'),
      lessThan(posOf(LocalDb.salvageTablesForTest, 'bp_research_window')),
    );
  });

  // A foreign export's AUTOINCREMENT ids are meaningless on this install:
  // its id=1 must never REPLACE an unrelated local capture that happens to
  // hold id=1. The merge keys references on (measured_at_ms, device) and
  // remaps each window onto the DESTINATION reference id.
  test('restore merges captures by natural key, never by source id',
      () async {
    // Start from a clean store: earlier tests in this file leave rows
    // behind, and this one asserts exact row sets.
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local state: one capture (id=1 by AUTOINCREMENT) plus its window.
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'local'));
    // A foreign export whose DIFFERENT capture also carries id=1.
    final srcPath =
        p.join(await databaseFactory.getDatabasesPath(), 'bp_foreign.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
        'CREATE TABLE bp_research_reference ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'measured_at_ms INTEGER NOT NULL, '
        'device TEXT, posture TEXT, conditions TEXT, '
        'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
        'captured_at_ms INTEGER NOT NULL, '
        'UNIQUE (measured_at_ms, device))');
    await src.execute(
        'CREATE TABLE bp_research_window ('
        'reference_id INTEGER NOT NULL PRIMARY KEY, '
        'window_start_ms INTEGER NOT NULL, window_end_ms INTEGER NOT NULL, '
        'onehz_rows INTEGER, rr_beats INTEGER, hr_mean REAL, rr_ms_mean REAL, '
        'rr_ms_min REAL, rr_ms_max REAL, rmssd_ms REAL, meta_json TEXT)');
    await src.insert('bp_research_reference', {
      'id': 1, // deliberately collides with the local capture's id
      'measured_at_ms': _at + 60000,
      'device': 'local',
      'posture': 'sitting',
      'conditions': 'rest',
      'systolic_mmhg': 130,
      'diastolic_mmhg': 85,
      'captured_at_ms': _at + 60000,
    });
    await src.insert('bp_research_window', {
      'reference_id': 1,
      'window_start_ms': _at + 60000 - 120000,
      'window_end_ms': _at + 60000 + 120000,
      'onehz_rows': 240,
      'rr_beats': 200,
      'hr_mean': 71.0,
    });
    await src.close();

    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['bp_research_reference'], 1);
    expect(counts['bp_research_window'], 1);

    final db = await LocalDb.instance;
    // Both captures survive: the foreign id=1 did not eat the local one.
    final refs = await db.rawQuery(
        'SELECT measured_at_ms, systolic_mmhg FROM bp_research_reference '
        'ORDER BY measured_at_ms');
    expect(refs, hasLength(2));
    expect(refs[0]['measured_at_ms'], _at);
    expect(refs[0]['systolic_mmhg'], 120.0);
    expect(refs[1]['measured_at_ms'], _at + 60000);
    expect(refs[1]['systolic_mmhg'], 130.0);
    // The imported window rides the imported reference's DESTINATION id,
    // and no window is orphaned.
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
    final importedWin = await db.rawQuery(
        'SELECT hr_mean FROM bp_research_window w '
        'JOIN bp_research_reference r ON r.id = w.reference_id '
        'WHERE r.measured_at_ms = ?', [_at + 60000]);
    expect(importedWin.first['hr_mean'], 71.0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a colliding restore keeps the destination id and its window',
      () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local capture WITH a window.
    await LocalDb.putBpResearchCapture(
        _capture(_at, device: 'local', window: _win));
    final localId = (await db0.rawQuery(
        'SELECT id FROM bp_research_reference')).first['id'] as int;

    // A foreign export of the SAME instant (same natural key) with no
    // window row: the capture's fields update, the window survives.
    final srcPath =
        p.join(await databaseFactory.getDatabasesPath(), 'bp_foreign3.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
        'CREATE TABLE bp_research_reference ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'measured_at_ms INTEGER NOT NULL, '
        'device TEXT, posture TEXT, conditions TEXT, '
        'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
        'captured_at_ms INTEGER NOT NULL, '
        'UNIQUE (measured_at_ms, device))');
    await src.insert('bp_research_reference', {
      'id': 7,
      'measured_at_ms': _at,
      'device': 'local',
      'posture': 'standing',
      'conditions': 'after exercise',
      'systolic_mmhg': 140,
      'diastolic_mmhg': 90,
      'captured_at_ms': _at + 1000,
    });
    await src.close();

    await LocalDb.importFromDbFile(srcPath);

    final db = await LocalDb.instance;
    final refs = await db.rawQuery(
        'SELECT id, posture, systolic_mmhg FROM bp_research_reference');
    expect(refs, hasLength(1));
    // The destination id is KEPT, so the window stays attached.
    expect(refs.first['id'], localId);
    expect(refs.first['posture'], 'standing');
    expect(refs.first['systolic_mmhg'], 140.0);
    final orphaned = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
    );
    expect(orphaned.first['c'], 0);
    final win = await db.rawQuery(
        'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
        [localId]);
    expect(win.first['hr_mean'], 62.5);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a re-import of the same export converges (idempotent merge)',
      () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    final srcPath =
        p.join(await databaseFactory.getDatabasesPath(), 'bp_foreign2.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
        'CREATE TABLE bp_research_reference ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'measured_at_ms INTEGER NOT NULL, '
        'device TEXT, posture TEXT, conditions TEXT, '
        'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
        'captured_at_ms INTEGER NOT NULL, '
        'UNIQUE (measured_at_ms, device))');
    await src.insert('bp_research_reference', {
      'id': 1,
      'measured_at_ms': _at + 120000,
      'device': '',
      'systolic_mmhg': 118,
      'diastolic_mmhg': 76,
      'captured_at_ms': _at + 120000,
    });
    await src.close();

    await LocalDb.importFromDbFile(srcPath);
    await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final n = (await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_reference '
        'WHERE measured_at_ms = ?', [_at + 120000])).first['c'];
    expect(n, 1);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('the window is filled once the band has synced past its end',
      () async {
    final at = _at + 10 * 86400000;
    final sec = at ~/ 1000;
    final db = await LocalDb.instance;
    Future<void> onehz(int t, int hr) => db.insert('decoded_onehz', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': t * 1000,
          'rec_ts': t,
          'counter': t,
          'hr': hr,
        });
    Future<void> beat(int t, int i, int rr) => db.insert('decoded_rr', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': t * 1000,
          'rec_ts': t,
          'beat_index': i,
          'rr_ts_ms': t * 1000,
          'rr_ms': rr,
        });
    // Beats of one record share rr_ts_ms; insert out of beat order.
    await beat(sec, 1, 1000);
    await beat(sec, 0, 800);
    await beat(sec + 1, 0, 1100);
    await onehz(sec, 60);
    await onehz(sec + 1, 0);
    await LocalDb.putBpResearchCapture(_capture(at));

    Future<Map<String, Object?>> row() async => (await LocalDb
            .bpResearchCaptures())
        .firstWhere((r) => r['measured_at_ms'] == at);

    // Synced data stops short of the window end: still pending.
    final edge = await LocalDb.fillBpResearchWindows();
    expect(edge, (sec + 1) * 1000);
    expect((await row())['onehz_rows'], isNull);

    await onehz(sec + 121, 61);
    await LocalDb.fillBpResearchWindows();
    final r = await row();
    expect(r['onehz_rows'], 2);
    expect(r['rr_beats'], 3);
    expect(r['hr_mean'], 60);
    // 800, 1000, 1100 in beat order.
    expect(r['rmssd_ms'] as double, closeTo(158.11, 0.01));
  });

  test('the prune fills a pending window before deleting its rows',
      () async {
    final at = _at + 20 * 86400000;
    final sec = at ~/ 1000;
    final db = await LocalDb.instance;
    for (final t in [sec, sec + 121]) {
      await db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': t * 1000,
        'rec_ts': t,
        'counter': t,
        'hr': 70,
      });
    }
    await LocalDb.putBpResearchCapture(_capture(at));
    // Nobody opened the dev screen; retention moves past the window.
    await LocalDb.pruneDecodedBeforeRecTs(sec + 120);
    final r = (await LocalDb.bpResearchCaptures())
        .firstWhere((r) => r['measured_at_ms'] == at);
    expect(r['onehz_rows'], 1);
    expect(r['hr_mean'], 70);
  });

  test('the window RR read seeks the store instead of scanning it',
      () async {
    // A capture with no band data stays pending and is re-read on every
    // prune, so this read must not walk and sort the whole decoded_rr.
    final db = await LocalDb.instance;
    final plan = (await db.rawQuery(
      'EXPLAIN QUERY PLAN ${LocalDb.bpResearchRrWindowSql}',
      [LocalDb.kPrimaryDeviceId, 1, 9],
    )).map((r) => r['detail'].toString()).join(' | ');
    expect(plan.toUpperCase(), contains('TS_MS'), reason: plan);
    expect(plan.toUpperCase(), isNot(contains('USE TEMP B-TREE')),
        reason: plan);
  });

  test('a salvage with an unreadable window table keeps the references',
      () async {
    const name = 'bp_research_salvage_test.db';
    final path = p.join(await databaseFactory.getDatabasesPath(), name);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
    LocalDb.dbName = name;
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'salvage'));
    await LocalDb.close();
    // Brick the ladder (see startup_and_rebuild_recovery_test.dart) and make
    // every read of the window table fail with something other than
    // "no such table".
    final raw = await databaseFactory.openDatabase(path);
    await raw.execute('CREATE TABLE _raw_old (hex TEXT)');
    await raw.execute('DROP TABLE bp_research_window');
    await raw.execute('CREATE VIEW bp_research_window AS '
        'SELECT abs(-9223372036854775807 - 1) AS reference_id');
    await raw.execute('PRAGMA user_version = 2');
    await raw.close();
    LocalDb.lastRebuild = null;

    final db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNotNull);
    final refs = await db.query('bp_research_reference');
    expect(refs, hasLength(1));
    expect(refs.first['device'], 'salvage');
    expect(LocalDb.lastRebuild!.salvaged['bp_research_reference'], 1);
    final q = File(LocalDb.lastRebuild!.quarantinePath);
    if (q.existsSync()) q.deleteSync();
  });
}
