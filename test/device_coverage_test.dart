// device_coverage backfill (v51, M3): seed a populated v50-era decoded_onehz
// / decoded_rr (already device_id-keyed since v47), open through the real
// LocalDb ladder, and assert the coverage rows the oldV<51 rung's step 6
// (`_backfillDeviceCoverage`) writes for the substrate that survives.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';

const _decodedOneHzDdl = '''
  CREATE TABLE decoded_onehz (
    device_id TEXT NOT NULL DEFAULT '',
    ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER,
    counter INTEGER NOT NULL,
    hr INTEGER,
    ax REAL, ay REAL, az REAL,
    spo2_red_raw INTEGER,
    spo2_ir_raw INTEGER,
    skin_temp_raw INTEGER,
    PRIMARY KEY (device_id, ts_ms)
  )
''';

const _decodedOneHzDdlNoDeviceId = '''
  CREATE TABLE decoded_onehz (
    rec_ts INTEGER PRIMARY KEY,
    counter INTEGER NOT NULL,
    hr INTEGER,
    ax REAL, ay REAL, az REAL,
    spo2_red_raw INTEGER,
    spo2_ir_raw INTEGER,
    skin_temp_raw INTEGER
  )
''';

const _decodedRrDdl = '''
  CREATE TABLE decoded_rr (
    device_id TEXT NOT NULL DEFAULT '',
    ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER NOT NULL,
    beat_index INTEGER NOT NULL,
    rr_ts_ms INTEGER NOT NULL,
    rr_ms INTEGER NOT NULL,
    PRIMARY KEY (device_id, ts_ms, beat_index)
  )
''';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _seedOldDb(
  String name,
  int version,
  List<String> ddl, {
  Future<void> Function(Database db)? seedRows,
}) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final s in ddl) {
          await db.execute(s);
        }
      },
    ),
  );
  if (seedRows != null) await seedRows(db);
  await db.close();
}

Future<int> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.first.values.first as num?)?.toInt() ?? -1;
}

Future<void> _insertOneHz(
  Database db, {
  required String deviceId,
  required int recTs,
  int? hr,
  double? ax,
  int? spo2Red,
  int? skinTemp,
}) async {
  await db.insert('decoded_onehz', {
    'device_id': deviceId,
    'ts_ms': recTs * 1000,
    'rec_ts': recTs,
    'counter': recTs,
    'hr': hr,
    'ax': ax,
    'ay': ax == null ? null : 0.2,
    'az': ax == null ? null : 0.9,
    'spo2_red_raw': spo2Red,
    'spo2_ir_raw': spo2Red,
    'skin_temp_raw': skinTemp,
  });
}

void main() {
  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test('the literal signal names in the backfill match InputSignal.name',
      () {
    // A 3-line assertion so a rename in signals.dart cannot silently orphan
    // every backfilled row.
    expect(InputSignal.hr1Hz.name, 'hr1Hz');
    expect(InputSignal.accel1Hz.name, 'accel1Hz');
    expect(InputSignal.ppgRedIr.name, 'ppgRedIr');
    expect(InputSignal.skinTempRaw.name, 'skinTempRaw');
    expect(InputSignal.rrIntervals.name, 'rrIntervals');
  });

  test(
    'backfill: contiguity, per-signal absence, and pruned days',
    () async {
      const name = 'device_coverage_backfill_test.db';
      created.add(name);
      const base = 1786099980; // bucket-aligned (multiple of 60)
      const gapStart = base + 300 + 600; // 10 minutes after the run ends
      await _seedOldDb(
        name,
        50,
        [_decodedOneHzDdl, _decodedRrDdl],
        seedRows: (db) async {
          // 300 seconds of hr+accel, one 1-second hole at +150 (must NOT
          // split — gap <= 2 buckets), then a fresh run after a 10-minute
          // hole (must split into a second interval).
          for (var t = 0; t < 300; t++) {
            if (t == 150) continue;
            await _insertOneHz(
              db,
              deviceId: '',
              recTs: base + t,
              hr: 60,
              ax: 0.1,
              // skin_temp_raw present only in the FIRST 150 seconds, to
              // prove per-signal absence produces no skinTempRaw row there.
              skinTemp: t < 150 ? 30000 : null,
            );
          }
          for (var t = 0; t < 60; t++) {
            await _insertOneHz(
              db,
              deviceId: '',
              recTs: gapStart + t,
              hr: 60,
              ax: 0.1,
            );
          }
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      final hrRows = await db.query(
        'device_coverage',
        where: 'signal = ?',
        whereArgs: ['hr1Hz'],
        orderBy: 'start_ts ASC',
      );
      // One interval for the 300-second run (the 1s hole at t=150 does not
      // split it) and a second, separate interval after the 10-minute gap.
      expect(hrRows.length, 2, reason: '$hrRows');
      expect(hrRows[0]['start_ts'], base);
      expect(hrRows[0]['end_ts'], base + 300);
      expect(hrRows[1]['start_ts'], gapStart);

      // skin_temp_raw only covers the first 150 seconds — absent input
      // produces no claim for the rest.
      final tempRows = await db.query(
        'device_coverage',
        where: 'signal = ?',
        whereArgs: ['skinTempRaw'],
      );
      expect(tempRows.length, 1, reason: '$tempRows');
      expect(tempRows.single['start_ts'], base);
      // Bucket-granular: the last second carrying a temp reading (t=149) sits
      // in the [120,180) bucket, so the interval's end is bucket-rounded up.
      expect(tempRows.single['end_ts'], base + 180);

      // ppgRedIr never had a non-null value seeded — no row at all.
      expect(
        await db.query(
          'device_coverage',
          where: 'signal = ?',
          whereArgs: ['ppgRedIr'],
        ),
        isEmpty,
      );
    },
  );

  test('backfill: a pruned (empty) decoded_onehz produces zero rows and the '
      'open still succeeds', () async {
    const name = 'device_coverage_pruned_test.db';
    created.add(name);
    await _seedOldDb(name, 50, [_decodedOneHzDdl, _decodedRrDdl]);

    expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
    final db = await LocalDb.instance;
    expect(await db.query('device_coverage'), isEmpty);
  });

  test(
    'backfill: a pre-v47 decoded_onehz (no device_id) backfills under the '
    'primary device without throwing',
    () async {
      const name = 'device_coverage_pre_v47_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        44,
        [_decodedOneHzDdlNoDeviceId],
        seedRows: (db) async {
          for (var t = 0; t < 5; t++) {
            await db.insert('decoded_onehz', {
              'rec_ts': 1786200000 + t,
              'counter': t,
              'hr': 60,
            });
          }
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;
      final rows = await db.query(
        'device_coverage',
        where: 'signal = ?',
        whereArgs: ['hr1Hz'],
      );
      expect(rows.length, 1);
      expect(rows.single['device_id'], LocalDb.kPrimaryDeviceId);
    },
  );

  test(
    'backfill: rrIntervals is read from decoded_rr, one row per beat',
    () async {
      const name = 'device_coverage_rr_test.db';
      created.add(name);
      const base = 1786299960; // bucket-aligned (multiple of 60)
      await _seedOldDb(
        name,
        50,
        [_decodedOneHzDdl, _decodedRrDdl],
        seedRows: (db) async {
          for (var t = 0; t < 10; t++) {
            await db.insert('decoded_rr', {
              'device_id': '',
              'ts_ms': (base + t) * 1000,
              'rec_ts': base + t,
              'beat_index': 0,
              'rr_ts_ms': (base + t) * 1000,
              'rr_ms': 800,
            });
          }
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;
      final rows = await db.query(
        'device_coverage',
        where: 'signal = ?',
        whereArgs: ['rrIntervals'],
      );
      expect(rows.length, 1);
      expect(rows.single['start_ts'], base);
      // Bucket-granular: the last beat (t=9) sits in the [0,60) bucket.
      expect(rows.single['end_ts'], base + 60);
    },
  );
}
