// Schema 55: step-calibration tables and the wearing writer, on the real
// LocalDb over sqflite_ffi. The upgrade path is covered by
// db_migration_ladder_test.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/live_coverage_policy.dart';
import 'package:openstrap_edge/data/step_calibration.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  test('a fresh install creates the learning tables at the current schema',
      () async {
    LocalDb.dbName = 'step_cal_fresh.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance; // force open + onCreate ladder
    final cols = await LocalDb.instance;
    final tables = await cols.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
      "('step_calibration','step_calibration_day')",
    );
    expect(tables.length, 2);
    await LocalDb.close();
  });

  test('the wearing setter and reader round-trip through device.wearing',
      () async {
    LocalDb.dbName = 'step_cal_wearing.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    Future<int?> stamp() async =>
        ((await LocalDb.deviceRow())?['wearing_set_ts'] as num?)?.toInt();
    // No device row yet: nothing to read, and the setter reports no save.
    expect(await LocalDb.deviceWearingRaw(), isNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 0);
    expect(await LocalDb.deviceWearingRaw(), isNull);
    await LocalDb.upsertDevice(adapterId: 'gen5');
    expect(await LocalDb.deviceWearingRaw(), Wearing.wrist); // column DEFAULT
    expect(await stamp(), isNull);
    // Re-picking the default is not a change and must not stamp.
    expect(await LocalDb.setDeviceWearing(Wearing.wrist), 1);
    expect(await stamp(), isNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await LocalDb.deviceWearingRaw(), Wearing.bicep);
    final firstStamp = await stamp();
    expect(firstStamp, isNotNull);
    expect(await LocalDb.setDeviceWearing(Wearing.bicep), 1);
    expect(await stamp(), firstStamp);
    await LocalDb.close();
  });

  test('profile put/read round-trips and refuses foreign versions',
      () async {
    LocalDb.dbName = 'step_cal_profile.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final db = await LocalDb.instance;
    expect(
      await LocalDb.stepCalibrationProfile('gen5', Wearing.bicep),
      isNull,
    );
    const profile = StepCalibrationProfile(
      deviceFamily: 'gen5',
      wearing: Wearing.bicep,
      factor: 1.4,
      nDays: 6,
      version: kStepCalibrationVersion,
    );
    await LocalDb.putStepCalibrationProfile(profile);
    final back = await LocalDb.stepCalibrationProfile('gen5', Wearing.bicep);
    expect(back!.factor, 1.4);
    expect(back.nDays, 6);
    expect(back.version, kStepCalibrationVersion);
    // A foreign version is invisible to this code, never re-applied.
    await db.insert('step_calibration', {
      'device_family': 'gen5',
      'wearing': Wearing.other,
      'factor': 9.9,
      'n_days': 999,
      'version': kStepCalibrationVersion + 1,
      'updated_ts': 0,
    });
    expect(await LocalDb.stepCalibrationProfile('gen5', Wearing.other), isNull);
    await LocalDb.close();
  });

  test('day observations bank idempotently and read back most-recent-first',
      () async {
    LocalDb.dbName = 'step_cal_days.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-01',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      referenceSteps: 8000,
      counterTicks: 10000,
    );
    // Same key: replace, not append.
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-01',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      referenceSteps: 9000,
      counterTicks: 10000,
    );
    await LocalDb.putStepCalibrationDay(
      day: '2026-01-02',
      deviceFamily: 'gen5',
      wearing: Wearing.wrist,
      // Null reference: the phone did not cover this day — absent, not 0.
      referenceSteps: null,
      counterTicks: 500,
    );
    final rows = await LocalDb.stepCalibrationDays('gen5', Wearing.wrist);
    expect(rows.length, 2);
    expect(rows.first['day'], '2026-01-02'); // DESC
    expect(rows.first['reference_steps'], isNull);
    expect(rows.last['reference_steps'], 9000); // replaced, not doubled
    await LocalDb.close();
  });

  test('days without a phone reference never evict the learned factor',
      () async {
    LocalDb.dbName = 'step_cal_evict.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
    const t0 = 1_700_000_000;
    // gen5 counter rising 1 tick/s for 2000 s.
    final sub = Substrate(
      deviceFamily: 'gen5',
      tsSec: [for (var i = 0; i < 2000; i++) t0 + i],
      hr: List<int>.filled(2000, 60),
      rrTsMs: const [],
      rrMs: const [],
      ax: List<double>.filled(2000, 0),
      ay: List<double>.filled(2000, 0),
      az: List<double>.filled(2000, 1),
      spo2Red: List<int>.filled(2000, 0),
      spo2Ir: List<int>.filled(2000, 0),
      skinTemp: List<int>.filled(2000, 0),
      skinContact: List<int>.filled(2000, 0),
      stepCount: [for (var i = 0; i < 2000; i++) i],
    );
    final engine = DerivationEngine();
    const phone = [
      CoverageSpan(startTs: t0, endTs: t0 + 1999, steps: 2800, fromBand: false),
    ];
    for (var d = 1; d <= 3; d++) {
      await engine.updateStepCalibration('2026-01-0$d', sub, Wearing.wrist,
          phoneSpans: phone);
    }
    final learned = await LocalDb.stepCalibrationProfile('gen5', Wearing.wrist);
    expect(learned!.isCalibrated, isTrue);
    // A month without the phone: nothing to pair, so nothing banked.
    for (var d = 1; d <= 30; d++) {
      await engine.updateStepCalibration(
          '2026-02-${d.toString().padLeft(2, '0')}', sub, Wearing.wrist,
          phoneSpans: const []);
    }
    final after = await LocalDb.stepCalibrationProfile('gen5', Wearing.wrist);
    expect(after!.factor, learned.factor);
    expect(after.nDays, 3);
    expect(
        (await LocalDb.stepCalibrationDays('gen5', Wearing.wrist)).length, 3);
    await LocalDb.close();
  });

  test('a restore carries the wearing choice onto an unset local row',
      () async {
    LocalDb.dbName = 'step_cal_restore.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final srcPath = p.join(dir, 'step_cal_restore_src.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute('CREATE TABLE device (id TEXT PRIMARY KEY, '
        'remote_id TEXT, first_seen INTEGER, last_seen INTEGER, '
        'wearing INTEGER, wearing_set_ts INTEGER)');
    await src.insert('device', {
      'id': LocalDb.kPrimaryDeviceId,
      'remote_id': 'OLD-PHONE-UUID',
      'first_seen': 1,
      'last_seen': 1,
      'wearing': Wearing.bicep,
      'wearing_set_ts': 1786000000,
    });
    await src.close();

    await LocalDb.upsertDevice(adapterId: 'gen5', remoteId: 'NEW-PHONE-UUID');
    await LocalDb.importFromDbFile(srcPath);
    final row = (await LocalDb.deviceRow())!;
    expect(row['remote_id'], 'NEW-PHONE-UUID'); // pairing stays local
    expect(row['wearing'], Wearing.bicep);
    expect(row['wearing_set_ts'], 1786000000);

    // A choice made on THIS install wins over the backup's.
    await LocalDb.setDeviceWearing(Wearing.other);
    await LocalDb.importFromDbFile(srcPath);
    expect(await LocalDb.deviceWearingRaw(), Wearing.other);
    await databaseFactory.deleteDatabase(srcPath);
    await LocalDb.close();
  });
}
