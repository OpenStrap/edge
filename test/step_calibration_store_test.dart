// The calibration store: a saved run and the profile it implies are one write,
// and a restore leaves every family's profile describing the runs it holds.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/step_calibration_fit.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;

StepCalibrationRun _brisk(int expected, int raw) => StepCalibrationRun(
      category: StepCategory.brisk,
      reference: StepReference.wearerCount,
      expectedSteps: expected,
      rawSteps: raw,
      cadenceSpm: 110,
      peakToPeakG: null,
      confidence: null,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'step_calibration_store_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('a save whose profile write fails leaves no run behind', () async {
    final db = await LocalDb.instance;
    // Make the profile write the step that fails, after the run insert.
    await db.execute('DROP TABLE live_step_calibration');

    await expectLater(
      LocalDb.bankLiveStepCalibrationRun(_brisk(100, 120), runTs: 1000),
      throwsA(anything),
    );
    final runs = await db.query('live_step_calibration_run');
    expect(runs, isEmpty);
  });

  test('a save banks the run and its profile together', () async {
    final profile =
        await LocalDb.bankLiveStepCalibrationRun(_brisk(100, 120), runTs: 1000);
    expect(profile.nRuns, 1);
    expect(await LocalDb.liveStepCalibrationRuns(), hasLength(1));
    final stored = await LocalDb.liveStepGainProfile(StepCategory.brisk);
    expect(stored?.gain, closeTo(100 / 120, 1e-9));
  });

  test('refitting after a merge replaces a profile that no longer matches',
      () async {
    // What a restore leaves: two runs on record, and a profile row carried in
    // from the backup that was fitted from only one of them.
    await LocalDb.putLiveStepCalibrationRun(_brisk(100, 120), runTs: 1000);
    await LocalDb.putLiveStepCalibrationRun(_brisk(100, 80), runTs: 2000);
    await LocalDb.putLiveStepGainProfile(LiveStepGainProfile(
      version: kLiveStepGainVersion,
      category: StepCategory.brisk,
      gain: 100 / 120,
      nRuns: 1,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ));

    await LocalDb.refitAllLiveStepGains();

    final stored = await LocalDb.liveStepGainProfile(StepCategory.brisk);
    expect(stored?.nRuns, 2);
    expect(stored?.gain, closeTo(200 / 200, 1e-9));
    // A family with no runs is left alone rather than written as uncalibrated.
    expect(await LocalDb.liveStepGainProfile(StepCategory.jog), isNull);
  });

  group('runs the current step counter did not score', () {
    // Banks a row the way an older build did: no counter tag. The column is
    // left NULL, which is what an upgraded install holds for every run it
    // saved before tagging existed.
    Future<void> putLegacyRun(int runTs, {int? counterVersion}) async {
      final db = await LocalDb.instance;
      await db.insert('live_step_calibration_run', {
        'category': 'brisk',
        'run_ts': runTs,
        'reference': 'wearerCount',
        'expected_steps': 100,
        'raw_steps': 60,
        'cadence_spm': 110.0,
        'counter_version': counterVersion,
      });
    }

    test('an untagged run is not read back as evidence', () async {
      await putLegacyRun(1000);
      await LocalDb.putLiveStepCalibrationRun(_brisk(100, 120), runTs: 2000);

      final runs = await LocalDb.liveStepCalibrationRuns();
      expect(runs, hasLength(1));
      expect(runs.single.rawSteps, 120);
    });

    test('a run from another counter version is not read back either',
        () async {
      await putLegacyRun(1000, counterVersion: kLiveStepCounterVersion - 1);
      expect(await LocalDb.liveStepCalibrationRuns(), isEmpty);
    });

    test('a refit ignores stale runs instead of fitting the old counter',
        () async {
      // Without the filter this would fit (100 + 100) / (60 + 120).
      await putLegacyRun(1000);
      await LocalDb.putLiveStepCalibrationRun(_brisk(100, 120), runTs: 2000);

      await LocalDb.refitAllLiveStepGains();

      final stored = await LocalDb.liveStepGainProfile(StepCategory.brisk);
      expect(stored?.nRuns, 1);
      expect(stored?.gain, closeTo(100 / 120, 1e-9));
    });

    test('opening the database clears stale runs and profiles, keeps current',
        () async {
      await putLegacyRun(1000);
      await putLegacyRun(1500, counterVersion: kLiveStepCounterVersion - 1);
      await LocalDb.putLiveStepCalibrationRun(_brisk(100, 120), runTs: 2000);
      final db = await LocalDb.instance;
      // A profile fitted under the previous gain version.
      await db.insert('live_step_calibration', {
        'category': 'jog',
        'gain': 0.9,
        'n_runs': 3,
        'version': kLiveStepGainVersion - 1,
        'updated_ts': 0,
      });
      await LocalDb.putLiveStepGainProfile(LiveStepGainProfile(
        version: kLiveStepGainVersion,
        category: StepCategory.brisk,
        gain: 100 / 120,
        nRuns: 1,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ));

      await LocalDb.close();
      final reopened = await LocalDb.instance;

      final runs = await reopened.query('live_step_calibration_run');
      expect(runs.map((r) => r['run_ts']), [2000]);
      final profiles = await reopened.query('live_step_calibration');
      expect(profiles.map((r) => r['category']), ['brisk']);
    });

    test('an install from before the tag gains the column on open', () async {
      final db = await LocalDb.instance;
      // Rebuild the table in its untagged shape, as an upgraded install has it.
      await db.execute('DROP TABLE live_step_calibration_run');
      await db.execute('''
        CREATE TABLE live_step_calibration_run (
          category TEXT NOT NULL, run_ts INTEGER NOT NULL,
          reference TEXT NOT NULL, expected_steps INTEGER NOT NULL,
          raw_steps INTEGER NOT NULL, cadence_spm REAL NOT NULL,
          p2p_g REAL, confidence REAL, PRIMARY KEY (category, run_ts))
      ''');
      await db.insert('live_step_calibration_run', {
        'category': 'brisk',
        'run_ts': 1000,
        'reference': 'wearerCount',
        'expected_steps': 100,
        'raw_steps': 60,
        'cadence_spm': 110.0,
      });

      await LocalDb.close();
      final reopened = await LocalDb.instance;

      final cols = await reopened.rawQuery(
        'PRAGMA table_info(live_step_calibration_run)',
      );
      expect(cols.map((c) => c['name']), contains('counter_version'));
      expect(await reopened.query('live_step_calibration_run'), isEmpty);
      // And a new run banks and reads back normally on the repaired table.
      await LocalDb.bankLiveStepCalibrationRun(_brisk(100, 120), runTs: 2000);
      expect(await LocalDb.liveStepCalibrationRuns(), hasLength(1));
    });
  });
}
