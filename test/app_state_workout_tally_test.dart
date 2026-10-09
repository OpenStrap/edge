// The live tally snapshot a workout keeps for a hard-kill relaunch, through
// AppState: what a tick snapshots (completed minutes only, gaps kept as gaps),
// that a relaunch restores it without billing the time the app was dead, and
// that no save is left to land after the row it belongs to has been deleted.
// The restore's headline numbers (strain, calories, zone minutes, peak) are
// pinned in app_state_regressions_test; this adds the shape of the history.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_tally.db';

const _user = {
  'age': 30,
  'weight_kg': 70.0,
  'height_cm': 175.0,
  'sex': 'male',
  'resting_hr': 55,
};

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

  test('a tick snapshots COMPLETED minutes only, with gap minutes kept as '
      'nulls, and the zone, per-bpm and peak tallies beside them', () async {
    final probe = TimerProbe();
    await probe.run(() async {
      final app = AppState.forTesting();
      app.user = {..._user};
      app.engine.state.generation = 'gen4';
      app.startWorkout(workoutId: 'w4-snap', type: 'strength');
      await sessionLanded('w4-snap');
      backdate(app, const Duration(minutes: 30));
      final w = app.activeWorkout!;
      // Minutes 0 and 2 have a sample; minute 1 had none.
      w.elapsed = const Duration(seconds: 10);
      w.accrueHr(140);
      w.elapsed = const Duration(minutes: 2, seconds: 10);
      w.accrueHr(140);
      setLiveHr(app, 150);
      probe.active(kTick).single.fire(); // the clock is now 30:00
      await tallyLanded('w4-snap');
      final row = (await LocalDb.liveWorkoutTally('w4-snap'))!;
      final minutes = jsonDecode(row['per_minute_hr'] as String) as List;
      expect(minutes, [140, null, 140],
          reason: 'a gap minute is not 0 bpm, and the minute in progress (the '
              '150 bpm tick) is not in the snapshot');
      expect(w.perMinuteHrDense().length, greaterThan(minutes.length),
          reason: 'the dense view does fold the in-progress minute in');
      expect(jsonDecode(row['zone_seconds'] as String), hasLength(6));
      final bpm = jsonDecode(row['seconds_by_bpm'] as String) as Map;
      expect(bpm.keys, ['140'],
          reason: 'a sample is billed when the next one closes it');
      expect(row['max_hr_seen'], w.maxHrSeen);
      await finish(app);
    });
  });

  test('a relaunch restores the history with its gaps and does not bill the '
      'time the app was dead: the first tick adds one second, not the '
      'offline stretch, and the peak holds', () async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSession({
      'id': 'w4-restore',
      'start_ts': nowSec - 20 * 60,
      'end_ts': null,
      'type': 'strength',
      'status': 'live',
      'source': 'manual',
      'created_at': (nowSec - 20 * 60) * 1000,
    });
    await LocalDb.saveLiveWorkoutTally({
      'workout_id': 'w4-restore',
      'updated_ts': DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000,
      'per_minute_hr': jsonEncode(<double?>[140, null, 150, 145]),
      'zone_seconds': jsonEncode([0.0, 0.0, 0.0, 600.0, 0.0, 0.0]),
      'seconds_by_bpm': jsonEncode({'140': 300.0, '150': 300.0}),
      'max_hr_seen': 160,
    });
    final probe = TimerProbe();
    await probe.run(() async {
      final app = AppState.forTesting();
      app.user = {..._user};
      app.engine.state.generation = 'gen4';
      await app.debugReconcileOrphanedLiveWorkout();
      final w = app.activeWorkout!;
      expect(w.workoutId, 'w4-restore');
      expect(w.perMinuteHrDense().take(4), [140, null, 150, 145]);
      expect(w.zoneSeconds[3], 600);
      expect(w.maxHrSeen, 160);
      expect(w.elapsed, Duration.zero, reason: 'the clock waits for the tick');
      final kcal = w.calories;

      setLiveHr(app, 150);
      probe.active(kTick).single.fire();
      expect(w.zoneSeconds[3], anyOf(601, 600),
          reason: 'one second is billed to whichever zone 150 bpm is in');
      expect(w.zoneSeconds.reduce((a, b) => a + b), 601);
      expect(w.maxHrSeen, 160, reason: 'a lower reading does not lower the peak');
      expect(w.elapsed.inMinutes, 20);
      expect(w.calories - kcal, lessThan(2.0),
          reason: 'billing the 20 offline minutes at the active rate would '
              'add tens of kcal');
      await finish(app);
    });
  });
}
