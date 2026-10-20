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
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_workout_import.dart';

HealthDataPoint _w(
  String uuid, {
  String sourceId = 'src',
  String sourceName = 'Strava',
}) => HealthDataPoint(
      uuid: uuid,
      value: WorkoutHealthValue(
        workoutActivityType: HealthWorkoutActivityType.RUNNING,
      ),
      type: HealthDataType.WORKOUT,
      unit: HealthDataUnit.NO_UNIT,
      dateFrom: DateTime(2026, 8, 1, 9),
      dateTo: DateTime(2026, 8, 1, 10),
      sourceId: sourceId,
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'dev',
      sourceName: sourceName,
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

/// Records what the permission request asked for.
class _PermHealth extends Health {
  List<HealthDataType>? asked;

  @override
  Future<void> configure() async {}

  @override
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async =>
      false;

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    asked = types;
    return true;
  }
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

  test('our own exported workouts are not imported back', () async {
    const app = 'wtf.openstrap.openstrap_edge';
    PackageInfo.setMockInitialValues(
      appName: 'Locus',
      packageName: app,
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    // An earlier import already stored one of them.
    await LocalDb.putImportedWorkouts([
      {
        'uuid': 'ours-ios',
        'start_ts': 1,
        'end_ts': 2,
        'kind': 'RUNNING',
        'source': 'Locus',
      },
    ]);
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([
        _w('ours-ios', sourceId: app, sourceName: 'Locus'),
        _w('ours-android', sourceId: '', sourceName: app),
        _w('strava'),
      ]),
      isApple: false,
    );

    final res = await importer.sync();

    expect(res.workouts, 1);
    final stored = await LocalDb.importedWorkouts();
    expect(stored.map((r) => r['uuid']), ['strava']);
  });

  test('apple: only a prompt:true sync lets the route fetch ask', () async {
    final sent = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kHealthRoutesChannel, (call) async {
      sent.add((call.arguments as Map)['prompt']);
      return const <Object?>[];
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kHealthRoutesChannel, null));
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([_w('a')]),
      isApple: true,
    );

    await importer.sync();
    await importer.sync(prompt: true);

    expect(sent, [false, true],
        reason: 'the auto path calls sync() bare and must never prompt');
  });

  test('copies of our own exports stored before the filter get cleaned up',
      () async {
    PackageInfo.setMockInitialValues(
      appName: 'Edge',
      packageName: 'site.openstrap.edge',
      version: '1',
      buildNumber: '1',
      buildSignature: '',
    );
    await LocalDb.putImportedWorkouts([
      for (final u in ['old1', 'old2'])
        ImportedWorkoutRow(
          uuid: u,
          startTs: 1,
          endTs: 2,
          kind: 'running',
          source: 'Edge',
        ).toRow(),
    ]);
    final importer = HealthWorkoutImporter(
      health: _FakeHealth([
        _w('ours', sourceId: 'site.openstrap.edge', sourceName: 'Edge'),
        _w('theirs'),
      ]),
      isApple: false,
    );

    await importer.sync();

    final stored = await LocalDb.importedWorkouts();
    expect(stored.map((r) => r['uuid']), ['theirs']);
  });

  test('health connect asks for the reads the workout read needs', () async {
    // The plugin reads distance, total calories and steps per session; a
    // missing grant on any of them empties the whole workout read.
    final health = _PermHealth();
    await HealthWorkoutImporter(health: health, isApple: false)
        .requestPermission();
    expect(
        health.asked,
        containsAll([
          HealthDataType.WORKOUT,
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.TOTAL_CALORIES_BURNED,
          HealthDataType.STEPS,
        ]));
  });
}
