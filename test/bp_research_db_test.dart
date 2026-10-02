// BP research store over the real LocalDb (sqflite_common_ffi).
import 'dart:convert' show jsonEncode;

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
}) => BpResearchCapture(
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
  featureVersion: kResearchFeatureVersion,
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

  test(
    'a retake with no device replaces the reference, not duplicates it',
    () async {
      await LocalDb.putBpResearchCapture(_capture(_at));
      await LocalDb.putBpResearchCapture(_capture(_at, window: _win));
      final rows = await LocalDb.bpResearchCaptures();
      expect(rows, hasLength(1));
      expect(rows.first['device'], '');
      expect(rows.first['hr_mean'], 62.5);
    },
  );

  test('a named device stays distinct from the no-device row', () async {
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'omron'));
    final rows = await LocalDb.bpResearchCaptures();
    expect(rows, hasLength(2)); // the '' row from the previous test + omron
    expect(rows.where((r) => r['device'] == 'omron'), hasLength(1));
  });

  test(
    'delete removes the window row too (the SQL cascade is inert)',
    () async {
      final db = await LocalDb.instance;
      final before = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window',
      );
      expect(before.first['c'], greaterThan(0));
      final refs = await db.rawQuery(
        'SELECT id FROM bp_research_reference WHERE device = ?',
        ['omron'],
      );
      await LocalDb.deleteBpResearchCapture(refs.first['id'] as int);
      final orphaned = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
      );
      expect(orphaned.first['c'], 0);
    },
  );

  test(
    'a retake that now finds band data replaces the absent window',
    () async {
      final later = _at + 60000;
      await LocalDb.putBpResearchCapture(_capture(later));
      await LocalDb.putBpResearchCapture(_capture(later, window: _win));
      final db = await LocalDb.instance;
      final windows = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id IN '
        '(SELECT id FROM bp_research_reference WHERE measured_at_ms = ?)',
        [later],
      );
      expect(windows.first['c'], 1);
      final orphaned = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
      );
      expect(orphaned.first['c'], 0);
    },
  );

  test(
    'a retro capture pairs with HISTORICAL rows and keeps entry time',
    () async {
      final db = await LocalDb.instance;
      await db.delete('bp_research_window');
      await db.delete('bp_research_reference');
      final measured = _at; // the cuff reading, this morning
      final entered = _at + 6 * 3600 * 1000; // typed in this evening
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: measured,
          measurementStartedAtMs: measured,
          systolicMmHg: 120,
          diastolicMmHg: 80,
          capturedAtMs: entered, // ENTRY time, not measurement
          device: 'omron',
          bandDeviceId: LocalDb.kPrimaryDeviceId,
          measurementSessionId: 'morning',
          window: _win,
        ),
      );
      final r = (await LocalDb.bpResearchCaptures()).first;
      expect(r['measured_at_ms'], measured);
      expect(r['measurement_started_at_ms'], measured);
      expect(r['measurement_finished_at_ms'], isNull); // no invented duration
      expect(r['captured_at_ms'], entered); // entry vs measurement
      expect(r['band_device_id'], LocalDb.kPrimaryDeviceId);
      expect(r['measurement_session_id'], 'morning');
    },
  );

  test(
    'a snapshot freezes the raw rows; re-processing writes a new revision',
    () async {
      final db = await LocalDb.instance;
      await db.delete('bp_research_snapshot');
      await db.delete('bp_research_window');
      await db.delete('bp_research_reference');
      final onehz = [
        {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
        {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 62},
      ];
      final rr = [
        {'rr_ts_ms': _at - 60000, 'rr_ms': 1000},
        {'rr_ts_ms': _at - 59000, 'rr_ms': 1050},
      ];
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: _at,
          systolicMmHg: 120,
          diastolicMmHg: 80,
          capturedAtMs: _at,
          device: 'omron',
          window: researchWindowFrom(
            measuredAtMs: _at,
            onehzRows: onehz,
            rrRows: rr,
          ),
        ),
        snapshotOnehzRows: onehz,
        snapshotRrRows: rr,
      );
      final id =
          (await db.rawQuery(
                'SELECT id FROM bp_research_reference',
              )).first['id']
              as int;
      final snap1 = await db.rawQuery(
        'SELECT revision, onehz_json FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      expect(snap1, hasLength(1));
      expect(snap1.first['revision'], 1);
      // The frozen rows are the exact input: reproducible.
      expect(snap1.first['onehz_json'], contains('60'));
      final win = await db.rawQuery(
        'SELECT snapshot_revision, feature_version, quality_status, '
        'valid_interval_pair_count FROM bp_research_window '
        'WHERE reference_id = ?',
        [id],
      );
      expect(win.first['snapshot_revision'], 1);
      expect(win.first['feature_version'], kResearchFeatureVersion);
      expect(win.first['quality_status'], isNotNull);
      expect(win.first['valid_interval_pair_count'], 1);
    },
  );

  test('a retake keeps the reference id and writes revision 2, revision 1'
      ' stays byte-identical', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    final rows1 = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
      {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 62},
    ];
    final rr1 = [
      {'rr_ts_ms': _at - 60000, 'rr_ms': 1000},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'omron',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rows1,
          rrRows: rr1,
        ),
      ),
      snapshotOnehzRows: rows1,
      snapshotRrRows: rr1,
    );
    final idBefore =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final json1 =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [idBefore],
            )).first['onehz_json']
            as String;
    // The retake: DIFFERENT sensor rows for the same natural reference.
    final rows2 = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 64},
      {'rec_ts': (_at - 59000) ~/ 1000, 'hr': 66},
    ];
    final rr2 = [
      {'rr_ts_ms': _at - 60000, 'rr_ms': 900},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 118,
        diastolicMmHg: 79,
        capturedAtMs: _at + 1000,
        device: 'omron',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rows2,
          rrRows: rr2,
        ),
      ),
      snapshotOnehzRows: rows2,
      snapshotRrRows: rr2,
    );
    final idAfter =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    // The reference id is STABLE — a retake is an update, not a new row.
    expect(idAfter, idBefore);
    final snaps = await db.rawQuery(
      'SELECT revision, onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? ORDER BY revision',
      [idBefore],
    );
    expect(snaps, hasLength(2));
    expect(snaps[0]['revision'], 1);
    expect(snaps[1]['revision'], 2);
    // Revision 1 is untouched — byte-identical history.
    expect(snaps[0]['onehz_json'], json1);
    expect(snaps[0]['onehz_json'], contains('60'));
    expect(snaps[1]['onehz_json'], contains('64'));
    // The window summary points at the CURRENT revision.
    final win = await db.rawQuery(
      'SELECT snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [idBefore],
    );
    expect(win.first['snapshot_revision'], 2);
    // The reference fields were updated in place.
    final ref = await db.rawQuery(
      'SELECT systolic_mmhg FROM bp_research_reference WHERE id = ?',
      [idBefore],
    );
    expect(ref.first['systolic_mmhg'], 118.0);
  });

  test(
    'a reference correction (no new snapshot rows) keeps the snapshots',
    () async {
      final db = await LocalDb.instance;
      // Re-capture the SAME natural reference with corrected values but no
      // snapshot rows: a field fix must not touch the snapshot history.
      final id =
          (await db.rawQuery(
                'SELECT id FROM bp_research_reference',
              )).first['id']
              as int;
      final before = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: _at,
          systolicMmHg: 117,
          diastolicMmHg: 78,
          capturedAtMs: _at + 2000,
          device: 'omron',
        ),
      );
      final after = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [id],
      );
      expect(after.first['c'], before.first['c']);
      final ref = await db.rawQuery(
        'SELECT systolic_mmhg FROM bp_research_reference WHERE id = ?',
        [id],
      );
      expect(ref.first['systolic_mmhg'], 117.0);
    },
  );

  test('overwriting an existing snapshot revision is an integrity error, '
      'not a silent rewrite', () async {
    final db = await LocalDb.instance;
    final id =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final foreignJson = jsonEncode([
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 999},
    ]);
    // A second writer claiming the SAME (reference, revision) key with
    // DIFFERENT content must fail loudly: plain INSERT + UNIQUE.
    await expectLater(
      db.insert('bp_research_snapshot', {
        'reference_id': id,
        'revision': 1,
        'onehz_json': foreignJson,
        'rr_json': '[]',
        'created_at_ms': _at,
      }),
      throwsA(isA<Exception>()),
    );
    // The destination revision is untouched.
    final kept = await db.rawQuery(
      'SELECT onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [id],
    );
    expect(kept, hasLength(1));
    expect(kept.first['onehz_json'], isNot(foreignJson));
  });

  test('delete removes the snapshot rows too', () async {
    final db = await LocalDb.instance;
    final id =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    await LocalDb.deleteBpResearchCapture(id);
    final left = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [id],
    );
    expect(left.first['c'], 0);
  });

  test(
    'the research tables ride the backup restore and salvage lists',
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
    },
  );

  // A foreign export's AUTOINCREMENT ids are meaningless on this install:
  // its id=1 must never REPLACE an unrelated local capture that happens to
  // hold id=1. The merge keys references on (measured_at_ms, device) and
  // remaps each window onto the DESTINATION reference id.
  test('restore merges captures by natural key, never by source id', () async {
    // Start from a clean store: earlier tests in this file leave rows
    // behind, and this one asserts exact row sets.
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local state: one capture (id=1 by AUTOINCREMENT) plus its window.
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'local'));
    // A foreign export whose DIFFERENT capture also carries id=1.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.execute(
      'CREATE TABLE bp_research_window ('
      'reference_id INTEGER NOT NULL PRIMARY KEY, '
      'window_start_ms INTEGER NOT NULL, window_end_ms INTEGER NOT NULL, '
      'onehz_rows INTEGER, rr_beats INTEGER, hr_mean REAL, rr_ms_mean REAL, '
      'rr_ms_min REAL, rr_ms_max REAL, rmssd_ms REAL, meta_json TEXT)',
    );
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
      'ORDER BY measured_at_ms',
    );
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
      'WHERE r.measured_at_ms = ?',
      [_at + 60000],
    );
    expect(importedWin.first['hr_mean'], 71.0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a colliding restore keeps the destination id and its window', () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // Local capture WITH a window.
    await LocalDb.putBpResearchCapture(
      _capture(_at, device: 'local', window: _win),
    );
    final localId =
        (await db0.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;

    // A foreign export of the SAME instant (same natural key) with no
    // window row: the capture's fields update, the window survives.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign3.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
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
      'SELECT id, posture, systolic_mmhg FROM bp_research_reference',
    );
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
      [localId],
    );
    expect(win.first['hr_mean'], 62.5);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a re-import of the same export converges (idempotent merge)', () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign2.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, '
      'device TEXT, posture TEXT, conditions TEXT, '
      'systolic_mmhg REAL NOT NULL, diastolic_mmhg REAL NOT NULL, '
      'captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
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
      'WHERE measured_at_ms = ?',
      [_at + 120000],
    )).first['c'];
    expect(n, 1);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('a restore whose snapshot conflicts skips the window too '
      '(window/snapshot consistency)', () async {
    final db0 = await LocalDb.instance;
    await db0.delete('bp_research_snapshot');
    await db0.delete('bp_research_window');
    await db0.delete('bp_research_reference');
    // LOCAL: a capture with snapshot revision 1 (rows A) and a window
    // pointing at it.
    final rowsA = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'cuff',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rowsA,
          rrRows: const [],
        ),
      ),
      snapshotOnehzRows: rowsA,
      snapshotRrRows: const [],
    );
    final localId =
        (await db0.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final localJson =
        (await db0.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [localId],
            )).first['onehz_json']
            as String;
    final localHr = (await db0.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [localId],
    )).first['hr_mean'];

    // FOREIGN: the SAME natural reference, a snapshot revision 1 with
    // DIFFERENT rows (B), and a window whose features came from B —
    // importing that window would point features at local revision 1,
    // which holds A. Both must be skipped; the local pair stays.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'bp_foreign_conflict.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, device TEXT, posture TEXT, '
      'conditions TEXT, systolic_mmhg REAL NOT NULL, '
      'diastolic_mmhg REAL NOT NULL, captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.insert('bp_research_reference', {
      'id': 42,
      'measured_at_ms': _at,
      'device': 'cuff',
      'systolic_mmhg': 121,
      'diastolic_mmhg': 81,
      'captured_at_ms': _at,
    });
    await src.execute(
      'CREATE TABLE bp_research_window ('
      'reference_id INTEGER PRIMARY KEY, window_start_ms INTEGER NOT NULL, '
      'window_end_ms INTEGER NOT NULL, onehz_rows INTEGER, rr_beats INTEGER, '
      'hr_mean REAL, rr_ms_mean REAL, rr_ms_min REAL, rr_ms_max REAL, '
      'rmssd_ms REAL, meta_json TEXT, observed_start_ms INTEGER, '
      'observed_end_ms INTEGER, valid_hr_seconds INTEGER, '
      'valid_interval_count INTEGER, valid_interval_pair_count INTEGER, '
      'coverage_fraction REAL, rejected_interval_fraction REAL, '
      'quality_status TEXT, feature_version INTEGER, '
      'snapshot_revision INTEGER)',
    );
    await src.insert('bp_research_window', {
      'reference_id': 42,
      'window_start_ms': _at - 300000,
      'window_end_ms': _at,
      'onehz_rows': 300,
      'hr_mean': 77.7,
      'feature_version': 3,
      'snapshot_revision': 1,
    });
    await src.execute(
      'CREATE TABLE bp_research_snapshot ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, reference_id INTEGER NOT NULL, '
      'revision INTEGER NOT NULL, onehz_json TEXT NOT NULL, '
      'rr_json TEXT NOT NULL, created_at_ms INTEGER NOT NULL, '
      'UNIQUE (reference_id, revision))',
    );
    await src.insert('bp_research_snapshot', {
      'reference_id': 42,
      'revision': 1,
      'onehz_json': '[{"rec_ts":${(_at - 60000) ~/ 1000},"hr":99}]',
      'rr_json': '[]',
      'created_at_ms': _at,
    });
    await src.close();
    await LocalDb.importFromDbFile(srcPath);

    final db = await LocalDb.instance;
    // The local snapshot revision 1 is untouched — foreign content lost.
    final snap = await db.rawQuery(
      'SELECT onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [localId],
    );
    expect(snap, hasLength(1));
    expect(snap.first['onehz_json'], localJson);
    // The foreign window was SKIPPED: the local window survives.
    final win = await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [localId],
    );
    expect(win, hasLength(1));
    expect(win.first['hr_mean'], localHr);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test(
    'a restore with an IDENTICAL snapshot is idempotent (window too)',
    () async {
      final db = await LocalDb.instance;
      final localId =
          (await db.rawQuery(
                'SELECT id FROM bp_research_reference',
              )).first['id']
              as int;
      final localJson =
          (await db.rawQuery(
                'SELECT onehz_json FROM bp_research_snapshot '
                'WHERE reference_id = ? AND revision = 1',
                [localId],
              )).first['onehz_json']
              as String;
      // The SAME snapshot content under the same key: idempotent
      // re-import, no duplicate revision rows, the window converges.
      final srcPath = p.join(
        await databaseFactory.getDatabasesPath(),
        'bp_foreign_ident.db',
      );
      await databaseFactory.deleteDatabase(srcPath);
      final src = await databaseFactory.openDatabase(srcPath);
      await src.execute(
        'CREATE TABLE bp_research_reference ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'measured_at_ms INTEGER NOT NULL, device TEXT, posture TEXT, '
        'conditions TEXT, systolic_mmhg REAL NOT NULL, '
        'diastolic_mmhg REAL NOT NULL, captured_at_ms INTEGER NOT NULL, '
        'UNIQUE (measured_at_ms, device))',
      );
      await src.insert('bp_research_reference', {
        'id': 43,
        'measured_at_ms': _at,
        'device': 'cuff',
        'systolic_mmhg': 120,
        'diastolic_mmhg': 80,
        'captured_at_ms': _at,
      });
      await src.execute(
        'CREATE TABLE bp_research_window ('
        'reference_id INTEGER PRIMARY KEY, window_start_ms INTEGER NOT NULL, '
        'window_end_ms INTEGER NOT NULL, onehz_rows INTEGER, rr_beats INTEGER, '
        'hr_mean REAL, rr_ms_mean REAL, rr_ms_min REAL, rr_ms_max REAL, '
        'rmssd_ms REAL, meta_json TEXT, observed_start_ms INTEGER, '
        'observed_end_ms INTEGER, valid_hr_seconds INTEGER, '
        'valid_interval_count INTEGER, valid_interval_pair_count INTEGER, '
        'coverage_fraction REAL, rejected_interval_fraction REAL, '
        'quality_status TEXT, feature_version INTEGER, '
        'snapshot_revision INTEGER)',
      );
      await src.insert('bp_research_window', {
        'reference_id': 43,
        'window_start_ms': _at - 300000,
        'window_end_ms': _at,
        'onehz_rows': 1,
        'hr_mean': 60,
        'feature_version': 3,
        'snapshot_revision': 1,
      });
      await src.execute(
        'CREATE TABLE bp_research_snapshot ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, reference_id INTEGER NOT NULL, '
        'revision INTEGER NOT NULL, onehz_json TEXT NOT NULL, '
        'rr_json TEXT NOT NULL, created_at_ms INTEGER NOT NULL, '
        'UNIQUE (reference_id, revision))',
      );
      await src.insert('bp_research_snapshot', {
        'reference_id': 43,
        'revision': 1,
        'onehz_json': localJson,
        'rr_json': '[]',
        'created_at_ms': _at,
      });
      await src.close();
      await LocalDb.importFromDbFile(srcPath);
      await LocalDb.importFromDbFile(srcPath);
      final snaps = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_snapshot '
        'WHERE reference_id = ?',
        [localId],
      );
      expect(snaps.first['c'], 1);
      final win = await db.rawQuery(
        'SELECT COUNT(*) c FROM bp_research_window '
        'WHERE reference_id = ?',
        [localId],
      );
      expect(win.first['c'], 1);
      await databaseFactory.deleteDatabase(srcPath);
    },
  );

  test('the store rejects invalid references before writing anything', () async {
    final db = await LocalDb.instance;
    final before =
        (await db.rawQuery(
              'SELECT COUNT(*) c FROM bp_research_reference',
            )).first['c']
            as int;
    BpResearchCapture ref(int m, double sys, double dia) => BpResearchCapture(
      measuredAtMs: m,
      systolicMmHg: sys,
      diastolicMmHg: dia,
      capturedAtMs: m,
      device: 'validate',
      window: _win,
    );
    // NaN / infinity: rejected, never laundered through the bounds check.
    for (final bad in [
      ref(_at + 1000000, double.nan, 80),
      ref(_at + 1000000, double.infinity, 80),
      ref(_at + 1000000, 120, double.nan),
      ref(_at + 1000000, 120, double.negativeInfinity),
      // Out of research bounds.
      ref(_at + 1000000, 301, 80),
      ref(_at + 1000000, 49, 80),
      ref(_at + 1000000, 120, 201),
      ref(_at + 1000000, 120, 19),
      // dia >= sys.
      ref(_at + 1000000, 120, 120),
      ref(_at + 1000000, 110, 120),
    ]) {
      await expectLater(LocalDb.putBpResearchCapture(bad), throwsArgumentError);
    }
    // Boundary values are VALID: 300/200 passes the bounds, dia < sys.
    await LocalDb.putBpResearchCapture(ref(_at + 1000000, 300, 200));
    // Nothing partial was left behind by the rejected writes.
    final after =
        (await db.rawQuery(
              'SELECT COUNT(*) c FROM bp_research_reference',
            )).first['c']
            as int;
    expect(after, before + 1);
    // None of the REJECTED writes left a window or snapshot row behind:
    // the only window/snapshot rows are the ones that BELONG to the one
    // valid reference (rows with no owning reference must not exist).
    final orphanW =
        (await db.rawQuery(
              'SELECT COUNT(*) c FROM bp_research_window '
              'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
            )).first['c']
            as int;
    final orphanS =
        (await db.rawQuery(
              'SELECT COUNT(*) c FROM bp_research_snapshot '
              'WHERE reference_id NOT IN (SELECT id FROM bp_research_reference)',
            )).first['c']
            as int;
    expect(orphanW, 0);
    expect(orphanS, 0);
    await LocalDb.deleteBpResearchCapture(_at + 1000000);
  });

  test('the production beat query and window computation keep every beat '
      'of one record (integration)', () async {
    // The FULL production path, not synthetic maps: real decoded_rr rows
    // (several beats of ONE record share rr_ts_ms = rec_ts*1000), the
    // same COALESCE query the capture screen runs, the snapshot freeze,
    // and researchWindowFrom on the queried rows.
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_rr');
    final recTs = (_at - 60000) ~/ 1000; // inside the rest window
    // FOUR beats of that one record: identical rr_ts_ms, distinct
    // beat_index; one carries a measured beat_ts_ms.
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 0,
      'rec_ts': recTs,
      'beat_index': 0,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': 1000,
    });
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 0,
      'rec_ts': recTs,
      'beat_index': 1,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': 1100,
    });
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 0,
      'rec_ts': recTs,
      'beat_index': 2,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': 900,
    });
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 0,
      'rec_ts': recTs,
      'beat_index': 3,
      'rr_ts_ms': recTs * 1000,
      'beat_ts_ms': recTs * 1000 + 3000,
      'rr_ms': 1050,
    });
    // THE PRODUCTION QUERY (same shape as the capture screen).
    final start = _at - kResearchRestPreMs;
    final end = _at + kResearchWindowPostMs;
    final rr = await db.rawQuery(
      'SELECT rr_ts_ms, rr_ms, beat_index, beat_ts_ms FROM decoded_rr '
      'WHERE device_id = ? '
      'AND COALESCE(beat_ts_ms, rr_ts_ms) >= ? '
      'AND COALESCE(beat_ts_ms, rr_ts_ms) < ? '
      'ORDER BY rr_ts_ms ASC, beat_index ASC',
      [LocalDb.kPrimaryDeviceId, start, end],
    );
    expect(rr, hasLength(4)); // no beat was dropped as a "duplicate"
    final w = researchWindowFrom(
      measuredAtMs: _at,
      onehzRows: const [],
      rrRows: rr,
    );
    expect(w, isNotNull);
    expect(w!.rrBeats, 4); // all four beats survive the window computation
    expect(w.validIntervalCount, 4);
    // Beat 3 was MEASURED 3000 ms after beat 2 — beyond the 2500 ms beat-gap
    // engineering default — so the pair across that gap is correctly NOT
    // used for RMSSD: 3 successive beats = 2 RMSSD pairs, not 3.
    expect(w.validIntervalPairCount, 2);
    expect(w.rmssdMs, isNotNull);
    // The snapshot freezes exactly these queried rows (beat fields ride
    // along), so re-processing reproduces the same features.
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'integration',
        window: w,
      ),
      snapshotOnehzRows: const [],
      snapshotRrRows: rr,
    );
    final snap = await db.rawQuery('SELECT rr_json FROM bp_research_snapshot');
    expect(snap, hasLength(1));
    expect(snap.first['rr_json'] as String, contains('beat_index'));
    await LocalDb.deleteBpResearchCapture(
      (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
          as int,
    );
  });

  test(
    'beat_ts_ms window membership follows the measured beat instant',
    () async {
      // A beat whose record second lies in the window but whose MEASURED
      // instant does not must stay outside; the mirrored case (record
      // outside, measured inside) must be kept.
      final recIn = (_at - 10000) ~/ 1000; // record inside the window
      final w = researchWindowFrom(
        measuredAtMs: _at,
        onehzRows: const [],
        rrRows: [
          // Record second inside, measured instant BEFORE the window.
          {
            'rr_ts_ms': recIn * 1000,
            'beat_index': 0,
            'beat_ts_ms': _at - kResearchRestPreMs - 5000,
            'rr_ms': 1000,
          },
          // Record second before the window, measured instant inside.
          {
            'rr_ts_ms': (_at - kResearchRestPreMs - 60000) ~/ 1000 * 1000,
            'beat_index': 0,
            'beat_ts_ms': _at - 60000,
            'rr_ms': 1100,
          },
        ],
      );
      expect(w, isNotNull);
      expect(w!.rrBeats, 1); // only the measured-inside beat survives
      expect(w.rrMsMean, 1100.0);
    },
  );
  // ========================================================================
  // ATOMIC BP RESEARCH RESTORE (reference + snapshot + window, ONE unit).
  // The regression behind these tests: the restore loop used to visit the
  // three BP tables in SEPARATE passes and loaded the source snapshots only
  // in the snapshot pass — so in the window pass the snapshot status map
  // was EMPTY and every conflict-free window with a snapshot revision was
  // silently skipped. Fresh-target restores lost their windows entirely.
  // ========================================================================

  Future<String> makeForeignBpDb(
    String name, {
    required int refId,
    required int measuredAtMs,
    String device = 'restore',
    double sys = 130,
    double dia = 85,
    List<Map<String, Object?>>? snapshots,
    List<Map<String, Object?>>? windows,
  }) async {
    final srcPath = p.join(await databaseFactory.getDatabasesPath(), name);
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE bp_research_reference ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'measured_at_ms INTEGER NOT NULL, device TEXT, posture TEXT, '
      'conditions TEXT, systolic_mmhg REAL NOT NULL, '
      'diastolic_mmhg REAL NOT NULL, captured_at_ms INTEGER NOT NULL, '
      'UNIQUE (measured_at_ms, device))',
    );
    await src.insert('bp_research_reference', {
      'id': refId,
      'measured_at_ms': measuredAtMs,
      'device': device,
      'systolic_mmhg': sys,
      'diastolic_mmhg': dia,
      'captured_at_ms': measuredAtMs,
    });
    await src.execute(
      'CREATE TABLE bp_research_window ('
      'reference_id INTEGER PRIMARY KEY, window_start_ms INTEGER NOT NULL, '
      'window_end_ms INTEGER NOT NULL, onehz_rows INTEGER, rr_beats INTEGER, '
      'hr_mean REAL, rr_ms_mean REAL, rr_ms_min REAL, rr_ms_max REAL, '
      'rmssd_ms REAL, meta_json TEXT, observed_start_ms INTEGER, '
      'observed_end_ms INTEGER, valid_hr_seconds INTEGER, '
      'valid_interval_count INTEGER, valid_interval_pair_count INTEGER, '
      'coverage_fraction REAL, rejected_interval_fraction REAL, '
      'quality_status TEXT, feature_version INTEGER, '
      'snapshot_revision INTEGER)',
    );
    for (final w in windows ?? const <Map<String, Object?>>[]) {
      await src.insert('bp_research_window', w);
    }
    await src.execute(
      'CREATE TABLE bp_research_snapshot ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, reference_id INTEGER NOT NULL, '
      'revision INTEGER NOT NULL, onehz_json TEXT NOT NULL, '
      'rr_json TEXT NOT NULL, created_at_ms INTEGER NOT NULL, '
      'UNIQUE (reference_id, revision))',
    );
    for (final s in snapshots ?? const <Map<String, Object?>>[]) {
      await src.insert('bp_research_snapshot', s);
    }
    await src.close();
    return srcPath;
  }

  Map<String, Object?> foreignWindow(
    int refId, {
    int? snapshotRevision,
    double hrMean = 77.7,
    int onehzRows = 300,
  }) => {
    'reference_id': refId,
    'window_start_ms': _at - 300000,
    'window_end_ms': _at,
    'onehz_rows': onehzRows,
    'rr_beats': 210,
    'hr_mean': hrMean,
    'rmssd_ms': 38.5,
    'feature_version': kResearchFeatureVersion,
    'snapshot_revision': snapshotRevision,
  };

  Map<String, Object?> foreignSnapshot(
    int refId,
    int revision, {
    required int hr,
  }) => {
    'reference_id': refId,
    'revision': revision,
    'onehz_json': '[{"rec_ts":${(_at - 60000) ~/ 1000},"hr":$hr}]',
    'rr_json': '[]',
    'created_at_ms': _at,
  };

  Future<void> clearBpTables() async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
  }

  test('restore: a FRESH target restores reference + snapshot + window '
      'as one unit (the regression)', () async {
    await clearBpTables();
    // FRESH target: no local BP rows at all. The source carries a
    // reference, snapshot revision 1, and a window naming revision 1.
    final srcPath = await makeForeignBpDb(
      'bp_fresh_success.db',
      refId: 7,
      measuredAtMs: _at,
      snapshots: [foreignSnapshot(7, 1, hr: 60)],
      windows: [foreignWindow(7, snapshotRevision: 1, hrMean: 71.5)],
    );
    final counts = await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final refs = await db.rawQuery('SELECT * FROM bp_research_reference');
    expect(refs, hasLength(1));
    final destId = refs.first['id'] as int;
    final snaps = await db.rawQuery(
      'SELECT * FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [destId],
    );
    expect(snaps, hasLength(1));
    expect(
      snaps.first['onehz_json'],
      '[{"rec_ts":${(_at - 60000) ~/ 1000},"hr":60}]',
    );
    final wins = await db.rawQuery(
      'SELECT * FROM bp_research_window WHERE reference_id = ?',
      [destId],
    );
    expect(wins, hasLength(1));
    expect(wins.first['snapshot_revision'], 1);
    expect(wins.first['hr_mean'], 71.5);
    expect(wins.first['rmssd_ms'], 38.5);
    // Counters: exactly 1 / 1 / 1, no skips.
    expect(counts['bp_research_reference'], 1);
    expect(counts['bp_research_snapshot'], 1);
    expect(counts['bp_research_window'], 1);
    expect(counts['bp_research_window_snapshot_conflicts'], 0);
    expect(counts['bp_research_window_missing_snapshot'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: an IDENTICAL snapshot re-import is idempotent and the '
      'window converges', () async {
    await clearBpTables();
    // LOCAL: reference + snapshot rev 1 (rows A) + a LOCAL window with
    // DISTINCT features, so the test proves the import UPDATED the
    // window rather than merely preserving a pre-existing one.
    final rowsA = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 130,
        diastolicMmHg: 85,
        capturedAtMs: _at,
        device: 'restore',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rowsA,
          rrRows: const [],
        ),
      ),
      snapshotOnehzRows: rowsA,
      snapshotRrRows: const [],
    );
    final db = await LocalDb.instance;
    final destId =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    // SOURCE: the SAME natural reference, the SAME snapshot rev 1 (rows
    // A), but a window with DIFFERENT features (88.8) — the identical
    // snapshot status must admit that window and converge it.
    final srcPath = await makeForeignBpDb(
      'bp_ident_converge.db',
      refId: 9,
      measuredAtMs: _at,
      device: 'restore',
      snapshots: [foreignSnapshot(9, 1, hr: 60)],
      windows: [foreignWindow(9, snapshotRevision: 1, hrMean: 88.8)],
    );
    final counts = await LocalDb.importFromDbFile(srcPath);
    final snaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(snaps.first['c'], 1); // no duplicate revision rows
    final wins = await db.rawQuery(
      'SELECT hr_mean, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(wins, hasLength(1));
    expect(wins.first['hr_mean'], 88.8); // the IMPORTED window won
    expect(wins.first['snapshot_revision'], 1);
    // Re-import AGAIN: full idempotency, still one of each, same values.
    final counts2 = await LocalDb.importFromDbFile(srcPath);
    final snaps2 = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(snaps2.first['c'], 1);
    final wins2 = await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [destId],
    );
    expect(wins2, hasLength(1));
    expect(wins2.first['hr_mean'], 88.8);
    // An identical snapshot is NOT a new import; nothing was skipped
    // as a conflict or missing.
    expect(counts['bp_research_snapshot'], 0);
    expect(counts['bp_research_snapshot_conflicts'], 0);
    expect(counts2['bp_research_snapshot'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: a CONFLICTING snapshot skips the snapshot AND the '
      'window, counters rise', () async {
    await clearBpTables();
    // LOCAL: reference + snapshot rev 1 (rows A) + window A.
    final rowsA = [
      {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 130,
        diastolicMmHg: 85,
        capturedAtMs: _at,
        device: 'restore',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rowsA,
          rrRows: const [],
        ),
      ),
      snapshotOnehzRows: rowsA,
      snapshotRrRows: const [],
    );
    final db = await LocalDb.instance;
    final destId =
        (await db.rawQuery('SELECT id FROM bp_research_reference')).first['id']
            as int;
    final localJson =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [destId],
            )).first['onehz_json']
            as String;
    final localHr = (await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [destId],
    )).first['hr_mean'];
    // SOURCE: same natural reference, snapshot rev 1 with DIFFERENT
    // rows (hr 99), and a window computed from those rows.
    final srcPath = await makeForeignBpDb(
      'bp_conflict_counters.db',
      refId: 11,
      measuredAtMs: _at,
      device: 'restore',
      snapshots: [foreignSnapshot(11, 1, hr: 99)],
      windows: [foreignWindow(11, snapshotRevision: 1, hrMean: 95.5)],
    );
    final counts = await LocalDb.importFromDbFile(srcPath);
    // Local snapshot rev 1 stays byte-identical (A), foreign B lost.
    final snap = await db.rawQuery(
      'SELECT onehz_json FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [destId],
    );
    expect(snap, hasLength(1));
    expect(snap.first['onehz_json'], localJson);
    // The foreign window was SKIPPED; local window A survives untouched.
    final win = await db.rawQuery(
      'SELECT hr_mean FROM bp_research_window WHERE reference_id = ?',
      [destId],
    );
    expect(win, hasLength(1));
    expect(win.first['hr_mean'], localHr);
    // Counters tell the truth: nothing imported, conflicts recorded.
    expect(counts['bp_research_snapshot'], 0);
    expect(counts['bp_research_window'], 0);
    expect(counts['bp_research_snapshot_conflicts'], 1);
    expect(counts['bp_research_window_snapshot_conflicts'], 1);
    expect(counts['bp_research_window_missing_snapshot'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: a window whose snapshot is MISSING in the source is '
      'never imported', () async {
    await clearBpTables();
    // SOURCE: a reference and a window naming snapshot revision 1 —
    // but NO snapshot row at all. Its features have no raw-data basis
    // here; importing the window would point at nothing.
    final srcPath = await makeForeignBpDb(
      'bp_missing_snapshot.db',
      refId: 13,
      measuredAtMs: _at,
      snapshots: const [],
      windows: [foreignWindow(13, snapshotRevision: 1)],
    );
    final counts = await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final refs = await db.rawQuery('SELECT * FROM bp_research_reference');
    expect(refs, hasLength(1)); // the reference itself is imported
    final destId = refs.first['id'] as int;
    final wins = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_window '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(wins.first['c'], 0); // the window was NOT imported
    expect(counts['bp_research_window'], 0);
    expect(counts['bp_research_window_missing_snapshot'], 1);
    expect(counts['bp_research_window_snapshot_conflicts'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: a LEGACY snapshotless window (snapshot_revision NULL) '
      'imports snapshotless, no fabricated revision', () async {
    await clearBpTables();
    // SOURCE: v1-style capture — a window with snapshot_revision NULL
    // and no snapshot rows. The documented legacy rule: import the
    // window as-is, keep it snapshotless, never fabricate a revision.
    final srcPath = await makeForeignBpDb(
      'bp_legacy_window.db',
      refId: 15,
      measuredAtMs: _at,
      snapshots: const [],
      windows: [foreignWindow(15, snapshotRevision: null, hrMean: 66.6)],
    );
    final counts = await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final refs = await db.rawQuery('SELECT * FROM bp_research_reference');
    expect(refs, hasLength(1));
    final destId = refs.first['id'] as int;
    final wins = await db.rawQuery(
      'SELECT hr_mean, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(wins, hasLength(1));
    expect(wins.first['hr_mean'], 66.6);
    expect(wins.first['snapshot_revision'], null); // stays snapshotless
    final snaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [destId],
    );
    expect(snaps.first['c'], 0); // no revision was fabricated
    expect(counts['bp_research_window'], 1);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: a reference ID collision maps snapshot and window to '
      'the CORRECT destination reference', () async {
    await clearBpTables();
    // LOCAL: one capture whose AUTOINCREMENT id is 1 (deliberately the
    // same NUMBER the source uses for a DIFFERENT natural reference).
    await LocalDb.putBpResearchCapture(_capture(_at, device: 'local'));
    final db = await LocalDb.instance;
    final localId =
        (await db.rawQuery(
              'SELECT id FROM bp_research_reference WHERE device = ?',
              ['local'],
            )).first['id']
            as int;
    // SOURCE: id 1 — a DIFFERENT natural reference (different time) —
    // with its own snapshot and window. They must land on the SOURCE
    // row's DESTINATION id, never on the local id that shares the
    // number.
    final srcPath = await makeForeignBpDb(
      'bp_id_collision.db',
      refId: 1,
      measuredAtMs: _at + 60000,
      device: 'foreign',
      snapshots: [foreignSnapshot(1, 1, hr: 70)],
      windows: [foreignWindow(1, snapshotRevision: 1, hrMean: 72.0)],
    );
    await LocalDb.importFromDbFile(srcPath);
    final refs = await db.rawQuery(
      'SELECT id, device, measured_at_ms FROM bp_research_reference '
      'ORDER BY measured_at_ms',
    );
    expect(refs, hasLength(2)); // both captures survive
    final foreignDestId =
        refs.firstWhere((r) => r['device'] == 'foreign')['id'] as int;
    // Snapshot and window point at the FOREIGN reference's destination
    // id — never at the local row that merely shares the number 1.
    final snaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ? AND revision = 1',
      [foreignDestId],
    );
    expect(snaps.first['c'], 1);
    final wins = await db.rawQuery(
      'SELECT hr_mean, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [foreignDestId],
    );
    expect(wins, hasLength(1));
    expect(wins.first['hr_mean'], 72.0);
    expect(wins.first['snapshot_revision'], 1);
    // The LOCAL reference keeps its window untouched (from _capture:
    // the first put had none, so the count is 0 here) and no foreign
    // row landed on it.
    final localSnaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot '
      'WHERE reference_id = ?',
      [localId],
    );
    expect(localSnaps.first['c'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });

  test('restore: a repeated re-import of the SAME source creates no '
      'duplicates and stable counts', () async {
    await clearBpTables();
    final srcPath = await makeForeignBpDb(
      'bp_reimport.db',
      refId: 17,
      measuredAtMs: _at,
      snapshots: [foreignSnapshot(17, 1, hr: 65)],
      windows: [foreignWindow(17, snapshotRevision: 1, hrMean: 73.0)],
    );
    final c1 = await LocalDb.importFromDbFile(srcPath);
    final c2 = await LocalDb.importFromDbFile(srcPath);
    final c3 = await LocalDb.importFromDbFile(srcPath);
    final db = await LocalDb.instance;
    final refs = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_reference',
    );
    expect(refs.first['c'], 1); // no duplicate references
    final snaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot',
    );
    expect(snaps.first['c'], 1); // no duplicate snapshots
    final wins = await db.rawQuery('SELECT COUNT(*) c FROM bp_research_window');
    expect(wins.first['c'], 1); // no duplicate windows
    final json = await db.rawQuery(
      'SELECT onehz_json, rr_json FROM bp_research_snapshot',
    );
    expect(
      json.first['onehz_json'],
      '[{"rec_ts":${(_at - 60000) ~/ 1000},"hr":65}]',
    );
    expect(json.first['rr_json'], '[]'); // content unchanged
    // First import reports 1/1/1; re-imports converge — the identical
    // snapshot and the natural-key reference are not NEW imports.
    expect(c1['bp_research_reference'], 1);
    expect(c1['bp_research_snapshot'], 1);
    expect(c1['bp_research_window'], 1);
    expect(c2['bp_research_reference'], 1); // matched, updated in place
    expect(c2['bp_research_snapshot'], 0); // identical, not new
    expect(c2['bp_research_window'], 1); // re-written, still one row
    expect(c3['bp_research_window_missing_snapshot'], 0);
    await databaseFactory.deleteDatabase(srcPath);
  });
  test('restore-invariant: a window without snapshot lists is stored '
      'SNAPSHOTLESS, never a fabricated revision (B2/B4)', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    // A window object carrying a BOGUS snapshotRevision=99 — without
    // snapshot lists the store must NOT persist that claim.
    final bogus = BpResearchWindow(
      windowStartMs: _at - 300000,
      windowEndMs: _at,
      onehzRows: 10,
      hrMean: 60.0,
      featureVersion: kResearchFeatureVersion,
      snapshotRevision: 99,
      qualityStatus: 'ok',
    );
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'invariant',
        window: bogus,
      ),
      // NO snapshot lists.
    );
    final win = await db.rawQuery(
      'SELECT snapshot_revision FROM bp_research_window w '
      'JOIN bp_research_reference r ON r.id = w.reference_id '
      'WHERE r.device = ?',
      ['invariant'],
    );
    expect(win, hasLength(1));
    // No revision is claimed that does not exist.
    expect(win.first['snapshot_revision'], isNull);
    final snaps = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot s '
      'JOIN bp_research_reference r ON r.id = s.reference_id '
      'WHERE r.device = ?',
      ['invariant'],
    );
    expect(snaps.first['c'], 0);
  });

  test('reprocess: a pending capture with a later watermark becomes final, '
      'writes revision 2, keeps revision 1 byte-identical', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_onehz');
    // Band synced only up to T-60s at capture time: pending.
    await db.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 1,
      'rec_ts': (_at - 60000) ~/ 1000,
      'counter': 0,
      'hr': 60,
    });
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'reprocess',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: [
            {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
          ],
          rrRows: const [],
          dataThroughMs: _at - 60000,
        ),
      ),
      snapshotOnehzRows: [
        {'rec_ts': (_at - 60000) ~/ 1000, 'hr': 60},
      ],
      snapshotRrRows: const [],
    );
    final refId =
        (await db.rawQuery(
              'SELECT id FROM bp_research_reference WHERE device = ?',
              ['reprocess'],
            )).first['id']
            as int;
    var win = await db.rawQuery(
      'SELECT quality_status, snapshot_revision '
      'FROM bp_research_window WHERE reference_id = ?',
      [refId],
    );
    expect(win.first['quality_status'], 'pending');
    expect(win.first['snapshot_revision'], 1);
    final rev1Json =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [refId],
            )).first['onehz_json']
            as String;
    // The band syncs the rest of the window — up to the LAST whole
    // second that can still lie inside the half-open window.
    for (int s = 0; s < 300; s++) {
      await db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': 100 + s,
        'rec_ts': (_at - 300000) ~/ 1000 + s,
        'counter': s,
        'hr': 60,
      });
    }
    // The RR series syncs its tail too — the watermark is the EARLIER
    // of both series, so HR alone would keep the window pending.
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 900,
      'rec_ts': (_at - 1000) ~/ 1000,
      'beat_index': 0,
      'rr_ts_ms': _at - 1000,
      'rr_ms': 900,
    });
    // ...and the developer explicitly re-processes the capture.
    await LocalDb.reprocessBpResearchCapture(refId);
    win = await db.rawQuery(
      'SELECT quality_status, snapshot_revision, hr_mean '
      'FROM bp_research_window WHERE reference_id = ?',
      [refId],
    );
    expect(win.first['quality_status'], 'ok');
    expect(win.first['snapshot_revision'], 2); // NEW revision
    // Revision 1 stays byte-identical.
    final rev1After =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [refId],
            )).first['onehz_json']
            as String;
    expect(rev1After, rev1Json);
    // The reference itself was never touched.
    final ref = await db.rawQuery(
      'SELECT measured_at_ms, systolic_mmhg, diastolic_mmhg, captured_at_ms '
      'FROM bp_research_reference WHERE id = ?',
      [refId],
    );
    expect(ref.first['measured_at_ms'], _at);
    expect(ref.first['systolic_mmhg'], 120.0);
    expect(ref.first['diastolic_mmhg'], 80.0);
  });

  test('reprocess stays pending when the sync still does not reach the '
      'window end', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_onehz');
    await db.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 500,
      'rec_ts': (_at - 240000) ~/ 1000,
      'counter': 0,
      'hr': 62,
    });
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 118,
        diastolicMmHg: 78,
        capturedAtMs: _at,
        device: 'stillpending',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: [
            {'rec_ts': (_at - 240000) ~/ 1000, 'hr': 62},
          ],
          rrRows: const [],
          dataThroughMs: _at - 240000,
        ),
      ),
      snapshotOnehzRows: [
        {'rec_ts': (_at - 240000) ~/ 1000, 'hr': 62},
      ],
      snapshotRrRows: const [],
    );
    final refId =
        (await db.rawQuery(
              'SELECT id FROM bp_research_reference WHERE device = ?',
              ['stillpending'],
            )).first['id']
            as int;
    // Re-process WITHOUT new data: must stay pending — no fabricated
    // final verdict.
    await LocalDb.reprocessBpResearchCapture(refId);
    final win = await db.rawQuery(
      'SELECT quality_status FROM bp_research_window '
      'WHERE reference_id = ?',
      [refId],
    );
    expect(win.first['quality_status'], 'pending');
  });
  test('an empty, not-final window is PENDING, keeps its row, and '
      're-processing attaches a new revision once data arrives', () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_onehz');
    await db.delete('decoded_rr');
    // Szenario: cuff reading "just now", band has synced NOTHING yet —
    // watermark 0 < window end. The capture must KEEP a pending window
    // row (not lose it to null), so re-processing can find it.
    final w = researchWindowFrom(
      measuredAtMs: _at,
      onehzRows: const [],
      rrRows: const [],
      nowMs: _at,
      dataThroughMs: 0,
    );
    expect(w, isNotNull); // the regression: no more silent null
    expect(w!.qualityStatus, 'pending');
    expect(w.onehzRows, isNull); // missing ≠ 0
    expect(w.rrBeats, isNull);
    expect(w.hrMean, isNull);
    expect(w.rmssdMs, isNull);
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'syncfix',
        window: w,
      ),
      snapshotOnehzRows: const [],
      snapshotRrRows: const [],
    );
    final refId =
        (await db.rawQuery(
              'SELECT id FROM bp_research_reference WHERE device = ?',
              ['syncfix'],
            )).first['id']
            as int;
    var win = await db.rawQuery(
      'SELECT quality_status, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [refId],
    );
    expect(win, hasLength(1)); // the window row SURVIVED the store
    expect(win.first['quality_status'], 'pending');
    // Re-process BEFORE any sync: must stay pending, must NOT lose the
    // row, must NOT invent a revision over empty rows.
    await LocalDb.reprocessBpResearchCapture(refId);
    win = await db.rawQuery(
      'SELECT quality_status, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [refId],
    );
    expect(win, hasLength(1));
    expect(win.first['quality_status'], 'pending');
    // The band syncs the full window tail now...
    for (int s = 0; s < 300; s++) {
      await db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': 1000 + s,
        'rec_ts': (_at - 300000) ~/ 1000 + s,
        'counter': s,
        'hr': 60,
      });
    }
    await db.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 2000,
      'rec_ts': (_at - 1000) ~/ 1000,
      'beat_index': 0,
      'rr_ts_ms': _at - 1000,
      'rr_ms': 900,
    });
    // ...and re-processing attaches REAL data plus a new revision.
    await LocalDb.reprocessBpResearchCapture(refId);
    win = await db.rawQuery(
      'SELECT quality_status, snapshot_revision, onehz_rows, hr_mean '
      'FROM bp_research_window WHERE reference_id = ?',
      [refId],
    );
    expect(win.first['quality_status'], 'ok'); // final now
    expect(win.first['snapshot_revision'], 1); // FIRST real revision
    expect(win.first['onehz_rows'], 300);
    expect(win.first['hr_mean'], 60.0);
    final snap = await db.rawQuery(
      'SELECT COUNT(*) c FROM bp_research_snapshot WHERE reference_id = ?',
      [refId],
    );
    expect(snap.first['c'], 1);
    // A SECOND re-process with unchanged data writes revision 2 and
    // keeps revision 1 byte-identical.
    final rev1 =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [refId],
            )).first['onehz_json']
            as String;
    await LocalDb.reprocessBpResearchCapture(refId);
    final win2 = await db.rawQuery(
      'SELECT snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [refId],
    );
    expect(win2.first['snapshot_revision'], 2);
    final rev1After =
        (await db.rawQuery(
              'SELECT onehz_json FROM bp_research_snapshot '
              'WHERE reference_id = ? AND revision = 1',
              [refId],
            )).first['onehz_json']
            as String;
    expect(rev1After, rev1);
  });

  test('a final, provably empty window is still an honest NULL window '
      '(no pending-forever regression)', () async {
    // Watermark provably covers the window end, the window is in the
    // past, and there is STILL nothing: null is CORRECT (no_data
    // honesty), not a fabricated pending row.
    final w = researchWindowFrom(
      measuredAtMs: _at,
      onehzRows: const [],
      rrRows: const [],
      nowMs: _at + 600000,
      dataThroughMs: _at + 600000,
    );
    expect(w, isNull);
  });

  test('reprocess after the decoded rows were pruned keeps the frozen window',
      () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_onehz');
    await db.delete('decoded_rr');
    final rows = [
      for (var s = 0; s < 300; s++) {'rec_ts': (_at - 300000) ~/ 1000 + s, 'hr': 60},
    ];
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'pruned',
        window: researchWindowFrom(
          measuredAtMs: _at,
          onehzRows: rows,
          rrRows: const [],
        ),
      ),
      snapshotOnehzRows: rows,
      snapshotRrRows: const [],
    );
    // Newer data exists, so the window is final, but its own rows are gone.
    await db.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': 1,
      'rec_ts': _at ~/ 1000 + 3600,
      'counter': 0,
      'hr': 60,
    });
    final refId = (await db.rawQuery('SELECT id FROM bp_research_reference'))
        .first['id'] as int;
    await LocalDb.reprocessBpResearchCapture(refId);
    final win = await db.rawQuery(
      'SELECT hr_mean, snapshot_revision FROM bp_research_window '
      'WHERE reference_id = ?',
      [refId],
    );
    expect(win, hasLength(1));
    expect(win.first['hr_mean'], 60.0);
    expect(win.first['snapshot_revision'], 1);
  });

  test('reprocess of a capture stored without a window creates the window',
      () async {
    final db = await LocalDb.instance;
    await db.delete('bp_research_snapshot');
    await db.delete('bp_research_window');
    await db.delete('bp_research_reference');
    await db.delete('decoded_onehz');
    await db.delete('decoded_rr');
    await LocalDb.putBpResearchCapture(
      BpResearchCapture(
        measuredAtMs: _at,
        systolicMmHg: 120,
        diastolicMmHg: 80,
        capturedAtMs: _at,
        device: 'late',
      ),
    );
    for (var s = 0; s < 300; s++) {
      await db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': s,
        'rec_ts': (_at - 300000) ~/ 1000 + s,
        'counter': s,
        'hr': 60,
      });
    }
    final refId = (await db.rawQuery('SELECT id FROM bp_research_reference'))
        .first['id'] as int;
    await LocalDb.reprocessBpResearchCapture(refId);
    final win = await db.rawQuery(
      'SELECT snapshot_revision FROM bp_research_window WHERE reference_id = ?',
      [refId],
    );
    expect(win, hasLength(1));
    expect(win.first['snapshot_revision'], 1);
  });
}
