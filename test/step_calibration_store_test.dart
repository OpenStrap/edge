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
}
