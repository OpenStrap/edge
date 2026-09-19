// sync()'s returned WorkoutImportResult.workouts must count what actually
// got stored, not what got read. A workout the user tombstoned via
// rememberDeletedUuid is correctly kept out of LocalDb — but the count used
// to be taken from the pre-filter read, so a tombstoned-only sync reported
// "1 workout brought in" while storing zero rows. That false count skipped
// the empty-state branch, ran markImported, and told the user a deleted
// workout was just re-added. See health_workout_import.dart sync().

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_workout_import.dart';

HealthDataPoint _w(String uuid) => HealthDataPoint(
      uuid: uuid,
      value: WorkoutHealthValue(
        workoutActivityType: HealthWorkoutActivityType.RUNNING,
      ),
      type: HealthDataType.WORKOUT,
      unit: HealthDataUnit.NO_UNIT,
      dateFrom: DateTime(2026, 8, 1, 9),
      dateTo: DateTime(2026, 8, 1, 10),
      sourceId: 'src',
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'dev',
      sourceName: 'Strava',
    );

/// Stubs the platform channel calls sync() makes so it never leaves Dart:
/// no route fetch (routesSupported is false for a non-Apple fake here).
class _FakeHealth extends Health {
  _FakeHealth(this.points);
  final List<HealthDataPoint> points;

  @override
  Future<void> configure() async {}

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async =>
      points;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_import_sync_test.db';
    dir = Directory(await databaseFactory.getDatabasesPath());
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir.path, LocalDb.dbName));
    await LocalDb.instance;
    SharedPreferences.setMockInitialValues(const {});
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir.path, LocalDb.dbName));
  });

  test('a fully-tombstoned read reports zero, not the pre-filter count',
      () async {
    await rememberDeletedUuid('w1');
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([_w('w1')]),
      isApple: false,
    );

    final res = await importer.sync();

    expect(res.workouts, 0,
        reason: 'the only row read was tombstoned and never stored');
    expect(await LocalDb.importedWorkouts(), isEmpty);
  });

  test('a mixed read counts only what survives the tombstone filter',
      () async {
    await rememberDeletedUuid('gone');
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([_w('gone'), _w('kept')]),
      isApple: false,
    );

    final res = await importer.sync();

    expect(res.workouts, 1);
    final stored = await LocalDb.importedWorkouts();
    expect(stored.map((r) => r['uuid']), ['kept']);
  });

  test('no tombstones: reported count matches what was stored', () async {
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([_w('a'), _w('b')]),
      isApple: false,
    );

    final res = await importer.sync();

    expect(res.workouts, 2);
    expect(await LocalDb.importedWorkouts(), hasLength(2));
  });
}
