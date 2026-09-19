// F-3: `stopWorkout()` ended with `unawaited(LocalDb.putSession(sessionRow))`
// and cleared `activeWorkout` on the very next line. The in-memory session is
// the ONLY other copy — the `status='live'` row written at start carries no
// duration, no zones, no calories and no strain — so a failed write destroyed
// the whole workout while the summary screen rendered it in full, and it was
// gone on the next launch.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const name = 'workout_stop_durability_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  test('a session that could not be written stays live instead of vanishing',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = LiveWorkoutState(
      startTime: DateTime.now().subtract(const Duration(minutes: 42)),
      targetKcal: 400,
      workoutId: 'w-durability',
      type: 'run',
    );

    // Make the durable write fail the way a real one would.
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    await expectLater(app.stopWorkout(), throwsA(anything));

    // Before the fix this was null and the 42 minutes were gone.
    expect(app.activeWorkout, isNotNull);
    expect(app.activeWorkout!.workoutId, 'w-durability');

    // Every teardown step is idempotent, so calling stop again is a clean
    // retry — which is the only reason keeping it live is useful.
    await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
    await app.stopWorkout();
    expect(app.activeWorkout, isNull);

    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: ['w-durability'],
    );
    expect(rows, hasLength(1));
    expect(rows.first['status'], 'done');
    expect(
      (rows.first['end_ts'] as num).toInt() -
          (rows.first['start_ts'] as num).toInt(),
      greaterThan(2400),
      reason: 'the retry banked the real 42-minute window',
    );
  });

  test(
      'stopWorkout retires an auto-detected suggestion its window covers',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final start = DateTime.now().subtract(const Duration(minutes: 20));
    app.activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: 200,
      workoutId: 'w-supersede',
      type: 'run',
    );

    // A detector-flagged fragment overlapping the live session's window.
    await LocalDb.putWorkoutSuggestion({
      'id': 'sug-1',
      'date': '2026-01-01',
      'start_ts': start.millisecondsSinceEpoch ~/ 1000 + 60,
      'end_ts': start.millisecondsSinceEpoch ~/ 1000 + 300,
      'dismissed': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    await app.stopWorkout();

    final active = await LocalDb.activeWorkoutSuggestions();
    expect(active.where((s) => s['id'] == 'sug-1'), isEmpty,
        reason: 'the just-logged workout should retire the overlapping '
            'suggestion instead of leaving a stale "did you work out?" prompt');
  });
}
