// The per-second fields a gen5 band computes ITSELF — its pedometer's
// cumulative step count and cadence, its activity class, a calibrated skin
// temperature in °C and the corroborating second HR byte — are decoded off
// every record and PERSISTED (schema v34) instead of being dropped on the
// floor.
//
// The invariant these tests exist to protect is ABSENCE, not presence: a gen4
// band sends none of this, so a gen4 second must store NULL. Zeroing them would
// mint a 0-step second and a 0 °C skin temperature for every gen4 record in the
// ledger — indistinguishable from a real reading downstream, and exactly the
// class of fabrication this codebase keeps having to undo.
//
// `on_wrist` and `hr_valid` are the same story taken one step further: the v18
// bits v34 filled them from are DISPROVEN (body 60 bits 0-1 are the
// primary-flags bit-8 snapshot, not wear; body 15 bit7 is not HR validity), so
// from v35 they have no writer at all and every new row stores NULL. The tests
// here still exercise the columns' storage contract — a nullable INTEGER that
// tells 0 from NULL — because the columns are kept for a source that could one
// day supply them honestly; `gen5_sample_mapping_test.dart` is what pins that
// the real decode path never does.
//
// Runs the REAL LocalDb over sqflite_ffi, so the DDL, the migration ladder and
// the read paths are the shipping ones.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

/// The v33 `decoded_onehz` / `decoded_rr` shape — rec_ts-keyed, WITHOUT any of
/// the band-computed columns. This is what an existing install's (million-row)
/// table looks like before the upgrade.
const _v33DecodedDdl = [
  '''
  CREATE TABLE decoded_onehz (
    rec_ts INTEGER PRIMARY KEY,
    counter INTEGER NOT NULL,
    hr INTEGER NOT NULL,
    ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
    spo2_red_raw INTEGER NOT NULL,
    spo2_ir_raw INTEGER NOT NULL,
    skin_temp_raw INTEGER NOT NULL)
''',
  'CREATE INDEX idx_decoded_onehz_counter ON decoded_onehz(counter)',
  '''
  CREATE TABLE decoded_rr (
    rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL,
    rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
    PRIMARY KEY (rec_ts, beat_index))
''',
];

/// The v34 `decoded_onehz` shape — identical DDL to today's, because v35 is a
/// DATA migration, not a schema one. What a v34 install differs in is its
/// CONTENT: it banked `on_wrist` from gen5 v18 body 60 bits 0-1, `hr_valid`
/// from body 15 bit7, and the raw -50.00 °C skin-temp sentinel.
const _v34DecodedDdl = [
  '''
  CREATE TABLE decoded_onehz (
    rec_ts INTEGER PRIMARY KEY,
    counter INTEGER NOT NULL,
    hr INTEGER NOT NULL,
    ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
    spo2_red_raw INTEGER NOT NULL,
    spo2_ir_raw INTEGER NOT NULL,
    skin_temp_raw INTEGER NOT NULL,
    step_count INTEGER,
    step_cadence INTEGER,
    activity_class INTEGER,
    skin_temp_c REAL,
    on_wrist INTEGER,
    hr_valid INTEGER,
    hr_alt INTEGER)
''',
  'CREATE INDEX idx_decoded_onehz_counter ON decoded_onehz(counter)',
  '''
  CREATE TABLE decoded_rr (
    rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL,
    rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
    PRIMARY KEY (rec_ts, beat_index))
''',
];

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Point LocalDb at a fresh, empty database file.
Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(await _dbPath(name));
}

RawRecord _raw(int recTs, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  // Not hex: forces the decode helper onto the supplied (already decoded)
  // Sample, which is how the BLE engine hands records over anyway.
  hex: 'decoded-by-the-supplied-sample',
  capturedAt: recTs * 1000,
  recTs: recTs,
);

/// A row straight out of `decoded_onehz`, so NULL can be told from 0.
Future<Map<String, Object?>> _rowAt(int recTs) async {
  final db = await LocalDb.instance;
  final rows = await db.query(
    'decoded_onehz',
    where: 'rec_ts = ?',
    whereArgs: [recTs],
  );
  return rows.single;
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

  test('a gen5 second round-trips every band-computed field', () async {
    const name = 'openstrap_gen5_fields_test.db';
    created.add(name);
    await _useFreshDb(name);

    const recTs = 1785000000;
    await LocalDb.insertRecord(
      _raw(recTs, 9001),
      Sample(
        tsEpoch: recTs,
        counter: 9001,
        hr: 58,
        rrIntervalsMs: const [1010],
        ax: 0.02,
        ay: -0.05,
        az: 0.99,
        spo2RedRaw: 1111,
        spo2IrRaw: 2222,
        skinTempRaw: 3333,
        stepCount: 12345,
        stepCadence: 94,
        activityClass: 2,
        skinTempC: 30.62,
        onWrist: 1,
        hrValid: true,
        hrAlt: 59,
      ),
    );

    // The derive read path must actually SELECT the new columns — a column that
    // is written but never read back is the same as not storing it.
    final frames = await LocalDb.decodedOneHzBatchByRecTsRange(
      limit: 10,
      fromRecTs: recTs - 1,
      toRecTs: recTs + 1,
    );
    expect(frames, hasLength(1));
    final f = frames.single;
    expect(f['step_count'], 12345);
    expect(f['step_cadence'], 94);
    expect(f['activity_class'], 2);
    expect((f['skin_temp_c'] as num).toDouble(), closeTo(30.62, 1e-9));
    expect(f['on_wrist'], 1);
    expect(f['hr_valid'], 1);
    expect(f['hr_alt'], 59);
    // The pre-existing columns are untouched by the widening.
    expect(f['hr'], 58);
    expect(f['skin_temp_raw'], 3333);

    // …and the Sample-returning paths carry them back as typed fields.
    final ranged = await LocalDb.samplesInRange(recTs - 1, recTs + 1);
    expect(ranged, hasLength(1));
    expect(ranged.single.stepCount, 12345);
    expect(ranged.single.stepCadence, 94);
    expect(ranged.single.activityClass, 2);
    expect(ranged.single.skinTempC, closeTo(30.62, 1e-9));
    expect(ranged.single.onWrist, 1);
    expect(ranged.single.hrValid, isTrue);
    expect(ranged.single.hrAlt, 59);

    final latest = await LocalDb.latestSample();
    expect(latest!.stepCount, 12345);
    expect(latest.hrValid, isTrue);

    // hrValid FALSE must survive as false, not collapse to null/absent.
    await LocalDb.insertRecord(
      _raw(recTs + 1, 9002),
      Sample(
        tsEpoch: recTs + 1,
        counter: 9002,
        hr: 0,
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 0,
        spo2IrRaw: 0,
        skinTempRaw: 0,
        stepCount: 12345,
        hrValid: false,
      ),
    );
    expect((await _rowAt(recTs + 1))['hr_valid'], 0);
    expect((await LocalDb.latestSample())!.hrValid, isFalse);
  });

  test('derive read path selects band_sleep_state in both call shapes',
      () async {
    const name = 'openstrap_band_sleep_state_test.db';
    created.add(name);
    await _useFreshDb(name);

    const recTs = 1785000000;
    for (final c in [9101, 9102]) {
      await LocalDb.insertRecord(
        _raw(recTs + c - 9101, c),
        Sample(
          tsEpoch: recTs + c - 9101,
          counter: c,
          hr: 58,
          ax: 0.02,
          ay: -0.05,
          az: 0.99,
          spo2RedRaw: 1,
          spo2IrRaw: 2,
          skinTempRaw: 3,
        ),
      );
    }
    final db = await LocalDb.instance;
    await db.rawUpdate('UPDATE decoded_onehz SET band_sleep_state = 3');

    final first = await LocalDb.decodedOneHzBatchByRecTsRange(
      limit: 10,
      fromRecTs: recTs - 1,
      toRecTs: recTs + 5,
    );
    expect(first, hasLength(2));
    expect(first.first.containsKey('band_sleep_state'), isTrue);
    expect(first.first['band_sleep_state'], 3);

    final cont = await LocalDb.decodedOneHzBatchByRecTsRange(
      limit: 10,
      fromRecTs: recTs - 1,
      toRecTs: recTs + 5,
      afterRecTs: recTs,
      afterCounter: 9101,
    );
    expect(cont, hasLength(1));
    expect(cont.single.containsKey('band_sleep_state'), isTrue);
    expect(cont.single['band_sleep_state'], 3);
  });

  test('a gen4 second stores NULL — never a fabricated 0 — for all of them',
      () async {
    const name = 'openstrap_gen4_null_fields_test.db';
    created.add(name);
    await _useFreshDb(name);

    const recTs = 1785100000;
    await LocalDb.insertRecord(
      _raw(recTs, 4001),
      // Exactly what a gen4 record decodes to: no step count, no cadence, no
      // class, no calibrated temperature, no wear bits, no HR-quality flag.
      Sample(
        tsEpoch: recTs,
        counter: 4001,
        hr: 62,
        rrIntervalsMs: const [960],
        ax: 0.1,
        ay: -0.2,
        az: 0.97,
        spo2RedRaw: 1234,
        spo2IrRaw: 2345,
        skinTempRaw: 3456,
      ),
    );

    final row = await _rowAt(recTs);
    for (final c in const [
      'step_count',
      'step_cadence',
      'activity_class',
      'skin_temp_c',
      'on_wrist',
      'hr_valid',
      'hr_alt',
    ]) {
      expect(row[c], isNull, reason: '$c must be NULL on a gen4 record, not 0');
    }
    // The gen4 fields it DOES carry are stored as before.
    expect(row['hr'], 62);
    expect(row['skin_temp_raw'], 3456);

    final s = await LocalDb.latestSample();
    expect(s!.stepCount, isNull);
    expect(s.skinTempC, isNull);
    expect(s.hrValid, isNull);
    expect(s.activityClass, isNull);
  });

  test('upgrading a populated v33 database keeps its rows readable', () async {
    const name = 'openstrap_v33_upgrade_fields_test.db';
    created.add(name);
    final path = await _dbPath(name);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);

    const recTs = 1780000000;
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 33,
        onCreate: (db, _) async {
          for (final s in _v33DecodedDdl) {
            await db.execute(s);
          }
        },
      ),
    );
    await old.insert('decoded_onehz', {
      'rec_ts': recTs,
      'counter': 777,
      'hr': 55,
      'ax': 0.01,
      'ay': 0.02,
      'az': 0.99,
      'spo2_red_raw': 10,
      'spo2_ir_raw': 20,
      'skin_temp_raw': 30,
    });
    await old.insert('decoded_rr', {
      'rec_ts': recTs,
      'beat_index': 0,
      'rr_ts_ms': recTs * 1000,
      'rr_ms': 1090,
    });
    await old.close();

    LocalDb.dbName = name;
    final db = await LocalDb.instance;
    expect(
      ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
          .toInt(),
      LocalDb.schemaVersion,
    );

    // The pre-migration row survived intact, and reads back through the same
    // widened query the derive path uses.
    final frames = await LocalDb.decodedOneHzBatchByRecTsRange(
      limit: 10,
      fromRecTs: recTs - 1,
      toRecTs: recTs + 1,
    );
    expect(frames, hasLength(1));
    expect(frames.single['hr'], 55);
    expect(frames.single['skin_temp_raw'], 30);
    // It predates the columns, so it reports nothing for them — not zero.
    expect(frames.single['step_count'], isNull);
    expect(frames.single['skin_temp_c'], isNull);
    expect((await LocalDb.latestSample())!.stepCount, isNull);

    final rr = await LocalDb.decodedRrByRecTsRange(
      fromRecTs: recTs,
      toRecTs: recTs,
    );
    expect(rr.single['rr_ms'], 1090);

    // A NEW gen5 second lands beside the migrated one in the upgraded table.
    await LocalDb.insertRecord(
      _raw(recTs + 60, 778),
      Sample(
        tsEpoch: recTs + 60,
        counter: 778,
        hr: 57,
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 0,
        spo2IrRaw: 0,
        skinTempRaw: 0,
        stepCount: 4242,
        skinTempC: 22.5,
        onWrist: 0,
      ),
    );
    final fresh = await _rowAt(recTs + 60);
    expect(fresh['step_count'], 4242);
    expect((fresh['skin_temp_c'] as num).toDouble(), closeTo(22.5, 1e-9));
    expect(fresh['on_wrist'], 0);
    expect(fresh['hr_alt'], isNull);

    expect((await LocalDb.schemaHealth())['ok'], isTrue);
  });

  // v35. The columns were always the right SHAPE (nullable, no DEFAULT); what
  // was wrong was what v34 put in two of them. `on_wrist` came from gen5 v18
  // body 60 bits 0-1 — the primary-flags bit-8 snapshot, not wear — and
  // `hr_valid` from body 15 bit7, which toggles ~50/50 independently of HR
  // presence across 1,587,671 retained records. `skin_temp_c` could also hold
  // the AS6221 -50.00 °C unavailable code. The writer stopped emitting all
  // three; this migration retires what it already banked, so a later reader
  // cannot pick up a confident answer the data never supported.
  test('upgrading a v34 database retires the disproven values it banked',
      () async {
    const name = 'openstrap_v34_retire_fields_test.db';
    created.add(name);
    final path = await _dbPath(name);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);

    const disproven = 1781000000; // a second v34 filled from the bad bits
    const sentinel = 1781000060; // …and one whose skin temp was the error code
    const honest = 1781000120; // …and one carrying only real values
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 34,
        onCreate: (db, _) async {
          for (final s in _v34DecodedDdl) {
            await db.execute(s);
          }
        },
      ),
    );
    Future<void> insert(int recTs, Map<String, Object?> extra) => old.insert(
      'decoded_onehz',
      {
        'rec_ts': recTs,
        'counter': recTs % 1000,
        'hr': 61,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 3000,
        ...extra,
      },
    );
    await insert(disproven, {
      'skin_temp_c': 30.57,
      'on_wrist': 1,
      'hr_valid': 1,
      'step_count': 8080,
      'hr_alt': 62,
    });
    await insert(sentinel, {'skin_temp_c': -50.0, 'on_wrist': 0, 'hr_valid': 0});
    await insert(honest, {'skin_temp_c': 22.5, 'step_count': 8081});
    await old.close();

    LocalDb.dbName = name;
    final db = await LocalDb.instance;
    expect(
      ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
          .toInt(),
      LocalDb.schemaVersion,
    );

    // Both disproven columns are cleared on EVERY row — including the row that
    // recorded a confident 0 ("off wrist" / "HR invalid"), which is exactly as
    // fabricated as a confident 1.
    for (final ts in const [disproven, sentinel, honest]) {
      final row = await _rowAt(ts);
      expect(row['on_wrist'], isNull, reason: 'on_wrist at $ts');
      expect(row['hr_valid'], isNull, reason: 'hr_valid at $ts');
    }

    // The sentinel becomes absence; real temperatures are untouched.
    expect((await _rowAt(sentinel))['skin_temp_c'], isNull);
    expect(
      ((await _rowAt(disproven))['skin_temp_c'] as num).toDouble(),
      closeTo(30.57, 1e-9),
    );
    expect(
      ((await _rowAt(honest))['skin_temp_c'] as num).toDouble(),
      closeTo(22.5, 1e-9),
    );

    // Nothing else in the row was collateral damage — the migration only
    // touches the three columns it is about.
    final row = await _rowAt(disproven);
    expect(row['hr'], 61);
    expect(row['skin_temp_raw'], 3000);
    expect(row['step_count'], 8080, reason: 'the step counter is REAL (T3)');
    expect(row['hr_alt'], 62);

    // The typed read seam agrees: absent, not "off wrist" / "invalid" / -50.
    final s = (await LocalDb.samplesInRange(sentinel, sentinel)).single;
    expect(s.skinTempC, isNull);
    expect(s.onWrist, isNull);
    expect(s.hrValid, isNull);
    expect(s.hr, 61);

    expect((await LocalDb.schemaHealth())['ok'], isTrue);

    // Idempotent: reopening runs no migration and changes nothing.
    await LocalDb.close();
    await LocalDb.instance;
    expect((await _rowAt(honest))['step_count'], 8081);
    expect((await _rowAt(disproven))['on_wrist'], isNull);
  });
}
