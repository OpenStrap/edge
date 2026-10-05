// What stopping a workout exports. A saved
// session goes to Apple Health / Health Connect right away when the health
// sync switch is on (issue #130), fire-and-forget; nothing is exported when it
// is off, when the save failed, when the session was torn down by a delete, or
// (today) when it lasted under a second. Seen through the Health plugin's
// channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_export.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await workoutDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    await workoutDbTearDown(_db);
  });

  List<String> health() => [for (final c in spies.health) c.method];

  /// A workout that lasts long enough (> 1 s) to be a Health sample.
  Future<AppState> ran(String id, {bool sync = true, String type = 'strength'}) async {
    final app = AppState.forTesting();
    app.healthSyncEnabled = sync;
    app.startWorkout(workoutId: id, type: type);
    backdate(app, const Duration(minutes: 5));
    return app;
  }

  test('sync off: a saved workout reaches nothing', () async {
    final app = await ran('w4-x1', sync: false);
    await app.stopWorkout();
    await settleMs(400);
    expect(health(), isEmpty);
    expect((await sessionRow('w4-x1'))!['status'], 'done');
    await finish(app);
  });

  test('sync on: the saved row is written to the health store (clear the '
      'window, then write), matching the row\'s own start and end', () async {
    final app = await ran('w4-x2');
    await app.stopWorkout();
    await settleMs(400);
    expect(health(), ['delete', 'writeWorkoutData']);
    final row = (await sessionRow('w4-x2'))!;
    final write = spies.health.last.args as Map;
    expect(write['activityType'], 'STRENGTH_TRAINING');
    expect(write['startTime'], (row['start_ts'] as int) * 1000);
    expect(write['endTime'], (row['end_ts'] as int) * 1000);
    expect(write['totalEnergyBurned'], isNull,
        reason: 'an unscored session exports no energy, not 0');
    await finish(app);
  });

  test('stop does not wait for the export: it is fire-and-forget',
      () async {
    final app = await ran('w4-x3');
    await app.stopWorkout();
    expect(app.activeWorkout, isNull);
    await settleMs(400);
    expect(health(), isNotEmpty);
    await finish(app);
  });

  test('a session under a second is saved but not exported (end must be '
      'after start at second resolution)', () async {
    final app = AppState.forTesting();
    app.healthSyncEnabled = true;
    app.startWorkout(workoutId: 'w4-x4', type: 'strength');
    await sessionLanded('w4-x4');
    await app.stopWorkout();
    await settleMs(400);
    expect((await sessionRow('w4-x4'))!['status'], 'done');
    expect(health(), isEmpty);
    await finish(app);
  });

  test('a failed save exports nothing', () async {
    final app = await ran('w4-x5');
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    await expectLater(app.stopWorkout(), throwsA(anything));
    await settleMs(400);
    expect(health(), isEmpty);
    expect(app.activeWorkout, isNotNull, reason: 'kept live for the retry');
    await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
    await app.stopWorkout();
    await settleMs(400);
    expect(health(), ['delete', 'writeWorkoutData'],
        reason: 'the retry that did save is the one that exports');
    await finish(app);
  });

  test('a delete-teardown exports nothing', () async {
    final app = await ran('w4-x6');
    await app.deleteWorkout('w4-x6');
    await settleMs(400);
    expect(health(), isEmpty);
    await finish(app);
  });

  test('exportWorkoutToHealth forwards an id to the shared exporter, which '
      'is gated on the stored sync preference (so with none, nothing '
      'is written)', () async {
    final app = await ran('w4-x7', sync: false);
    await app.stopWorkout();
    await settleMs(300);
    expect(await app.exportWorkoutToHealth('w4-x7'), isFalse);
    expect(await app.exportWorkoutToHealth(null), isFalse);
    expect(health(), isEmpty);
    await finish(app);
  });
}
