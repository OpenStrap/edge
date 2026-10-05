// The workout's steps through AppState. `workoutStepsMeasured` is the live
// pedometer's count FOR THIS WORKOUT (null = not measured, which is not the
// same as zero), and the stop banks `steps` / `cadence_spm` from it. The
// pedometer itself (the minute chunks, the rate gate) belongs to the
// connection, not the workout; what these pin is the workout-scoped
// bookkeeping around it: the base snapshot at start, the "saw samples" latch,
// the rebase across a pedometer reset, the 30 s accel-gap rules and where they
// are judged, and the per-minute cadence list. The gap rules compare frame
// ingest times with the phone clock, so every walk below is laid out on a
// timeline that ends at (or near) the real now.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_steps.db';
const _gapMs = 30000;

/// Frames ingested at 100 ms spacing on one continuous clock. It starts
/// [frames] frames before [endMs] (default: now), so the first [frames] frames
/// end at that instant and anything fed after them lies in the future, where
/// it can never look like a stale stream.
class _Timeline {
  _Timeline(this.app, {required int frames, int? endMs})
      : cursor = (endMs ?? nowMs()) - frames * 100;
  final AppState app;
  int cursor;
  int frame = 0;

  /// [minutes] of a textbook walk at a true 100 Hz (10 samples / 100 ms).
  void walk(double minutes) {
    final n = (minutes * 600).round();
    for (var i = 0; i < n; i++) {
      app.debugFeedLiveAccel(walkFrame(frame++, 10), recTs: 1, atMs: cursor);
      cursor += 100;
    }
  }

  /// [minutes] of a still wrist.
  void still(double minutes) {
    final n = (minutes * 600).round();
    for (var i = 0; i < n; i++) {
      app.debugFeedLiveAccel(List<double>.filled(10, 1.0),
          recTs: 1, atMs: cursor);
      cursor += 100;
    }
  }

  /// The stream goes quiet for [ms].
  void silence(int ms) => cursor += ms;
}

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

  /// A started workout with its fire-and-forget starts finished: the session
  /// row is written and, for a type that records a route, the tracker is
  /// listening (stopping mid-way through the permission round trip is not what
  /// these tests are about).
  Future<AppState> running(String id, String type) async {
    final app = AppState.forTesting();
    app.startWorkout(workoutId: id, type: type);
    await sessionLanded(id);
    await settleRoute(app, type);
    return app;
  }

  group('workoutStepsMeasured', () {
    test('null with no workout, whatever the pedometer has counted', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      _Timeline(app, frames: 600).walk(1);
      expect(app.workoutStepsMeasured, isNull);
    });

    test('null on a gait workout until a gait-capable sample has arrived, '
        'then a count from zero', () async {
      final app = await running('w4-s1', 'running');
      expect(app.workoutStepsMeasured, isNull);
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: nowMs());
      expect(app.workoutStepsMeasured, 0,
          reason: 'samples arrived, no step completed: measured zero');
      await finish(app);
    });

    test('counts only the steps taken since THIS workout began (the base is '
        'snapshotted at start)', () async {
      final app = AppState.forTesting();
      final tl = _Timeline(app, frames: 1200);
      tl.walk(2); // before the workout: committed, not the workout's
      app.startWorkout(workoutId: 'w4-s2', type: 'walking');
      await sessionLanded('w4-s2');
      expect(app.workoutStepsMeasured, isNull,
          reason: 'no sample since the start');
      tl.still(1 / 600);
      expect(app.workoutStepsMeasured, 0);
      tl.walk(2);
      final steps = app.workoutStepsMeasured!;
      expect(steps, greaterThan(100));
      // Control: the same two minutes on an app whose workout began first.
      final control = AppState.forTesting();
      control.startWorkout(workoutId: 'w4-s2-control', type: 'walking');
      await sessionLanded('w4-s2-control');
      _Timeline(control, frames: 1200).walk(2);
      expect(steps, closeTo(control.workoutStepsMeasured!, 15),
          reason: 'the earlier two minutes are not in the workout count');
      await finish(control);
      await finish(app);
    });

    test('a non-gait workout is never billed pedometer samples: stays null, '
        'and says why', () async {
      final app = await running('w4-s3', 'strength');
      _Timeline(app, frames: 600).walk(1);
      expect(app.workoutStepsMeasured, isNull);
      expect(app.liveStepsAbsentReason,
          startsWith('Steps are only counted from the strap while you are on '
              'foot'));
      await finish(app);
    });

    test('a gait workout has no absence reason while the stream is healthy',
        () async {
      final app = await running('w4-s4', 'trail_running');
      _Timeline(app, frames: 600).walk(1);
      expect(app.liveStepsAbsentReason, isNull);
      expect(app.workoutStepsMeasured, greaterThan(0));
      await finish(app);
    });

    test('the type match is case-insensitive', () async {
      final app = await running('w4-s5', 'Running');
      _Timeline(app, frames: 600).walk(1);
      expect(app.workoutStepsMeasured, greaterThan(0));
      await finish(app);
    });

    test('a pedometer reset mid-workout (reconnect) carries the accrued '
        'steps through: the count neither drops nor restarts', () async {
      final app = await running('w4-s6', 'running');
      final tl = _Timeline(app, frames: 1200);
      tl.walk(2);
      final before = app.workoutStepsMeasured!;
      expect(before, greaterThan(100));
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, before,
          reason: 'rebased negative against the zeroed counter');
      tl.walk(1);
      expect(app.workoutStepsMeasured!, greaterThan(before));
      await finish(app);
    });

    test('a reset before any sample keeps the workout unmeasured (the latch '
        'is about samples, not about the counter)', () async {
      final app = await running('w4-s7', 'running');
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, isNull);
      await finish(app);
    });

    test('the latch survives a reset: samples seen before it keep the count '
        'a number, never a dash', () async {
      final app = await running('w4-s8', 'running');
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: nowMs());
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, 0);
      await finish(app);
    });
  });

  group('the 30 s accel-gap rules', () {
    /// The first frame lands [afterStartMs] after the workout began, then a
    /// walking minute follows on a continuous clock.
    Future<AppState> firstFrameAt(String id, int afterStartMs) async {
      final app = await running(id, 'walking');
      final start = app.activeWorkout!.startTime.millisecondsSinceEpoch;
      final tl = _Timeline(app, frames: 600, endMs: start + afterStartMs + 60000);
      tl.walk(1);
      return app;
    }

    test('a first frame exactly 30 s after the start is covered; 1 ms later '
        'the stream "only came up minutes in" and the count is absent',
        () async {
      final ok = await firstFrameAt('w4-g1', _gapMs);
      expect(ok.workoutStepsMeasured, greaterThan(0));
      final late = await firstFrameAt('w4-g2', _gapMs + 1);
      expect(late.workoutStepsMeasured, isNull);
      await finish(ok);
      await finish(late);
    });

    test('a hole between two frames: 30 s is tolerated, 30 s + 1 ms is a gap '
        'that stays latched after the frames come back', () async {
      final ok = await running('w4-g3', 'walking');
      final tlOk = _Timeline(ok, frames: 600);
      tlOk.walk(1);
      tlOk.silence(_gapMs - 100);
      tlOk.walk(1);
      expect(ok.workoutStepsMeasured, greaterThan(0));

      final gap = await running('w4-g4', 'walking');
      final tlGap = _Timeline(gap, frames: 600);
      tlGap.walk(1);
      expect(gap.workoutStepsMeasured, greaterThan(0));
      tlGap.silence(_gapMs - 100 + 1);
      tlGap.walk(1);
      expect(gap.workoutStepsMeasured, isNull,
          reason: 'partial coverage is not a total, even once frames resume');
      await finish(ok);
      await finish(gap);
    });

    test('the gap is judged against the clock at read time too: a stream '
        'that has been quiet for over 30 s reads absent, then recovers when '
        'frames resume inside the window', () async {
      final app = await running('w4-g5', 'walking');
      final tl = _Timeline(app, frames: 600, endMs: nowMs() - _gapMs - 2000);
      tl.walk(1);
      expect(app.workoutStepsMeasured, isNull,
          reason: 'the last frame is older than 30 s');
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: nowMs());
      expect(app.workoutStepsMeasured, isNull,
          reason: 'that silence was a gap in the session, latched');
      await finish(app);
    });

    test('the accel-gap state survives a pedometer reset: a hole across a '
        'reconnect is still a hole, and a covered reconnect is not',
        () async {
      final covered = await running('w4-g6', 'walking');
      final t1 = _Timeline(covered, frames: 600);
      t1.walk(1);
      await covered.debugFinalizeLivePedometer();
      t1.silence(_gapMs - 100);
      t1.walk(1);
      expect(covered.workoutStepsMeasured, greaterThan(0));

      final holed = await running('w4-g7', 'walking');
      final t2 = _Timeline(holed, frames: 600);
      t2.walk(1);
      await holed.debugFinalizeLivePedometer();
      t2.silence(_gapMs + 1);
      t2.walk(1);
      expect(holed.workoutStepsMeasured, isNull);

      // A gap seen before the reset is not forgiven by it either.
      final before = await running('w4-g8', 'walking');
      final t3 = _Timeline(before, frames: 600);
      t3.walk(0.5);
      t3.silence(_gapMs + 1);
      t3.walk(0.5);
      await before.debugFinalizeLivePedometer();
      t3.walk(0.5);
      expect(before.workoutStepsMeasured, isNull);
      await finish(covered);
      await finish(holed);
      await finish(before);
    });

    test('coverage is judged at the moment stop is called, not after the '
        'route flush it then waits on: a walk that was covered when the user '
        'pressed stop banks its steps, though the live getter has gone stale '
        'by the time the teardown finishes', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-stopentry', type: 'walking');
      await sessionLanded('w4-stopentry');
      await until(() => app.routeTracker != null && spies.geoListening,
          what: 'the route tracker to listen');
      spies.emitFix(51.0, 0.0);
      await until(() => app.routeTracker!.pointCount >= 1);
      // The last gait frame is 29.5 s old: covered now, stale half a second on.
      final tl = _Timeline(app, frames: 700, endMs: nowMs() - 29500);
      tl.walk(70 / 60);
      expect(app.workoutStepsMeasured, greaterThan(0));

      final hold = await DbHold.acquire();
      final stopping = app.stopWorkout();
      await settleMs(900);
      expect(app.activeWorkout, isNotNull, reason: 'stop is still tearing down');
      expect(app.workoutStepsMeasured, isNull,
          reason: 'read now, the same stream is more than 30 s old');
      await hold.release();
      await stopping;
      final row = (await sessionRow('w4-stopentry'))!;
      expect(row['steps'], greaterThan(0));
      await finish(app);
    });
  });

  group('what stop banks', () {
    test('a walked workout banks steps and a measured cadence', () async {
      final app = await running('w4-b1', 'walking');
      _Timeline(app, frames: 3000).walk(5);
      final live = app.workoutStepsMeasured!;
      await app.stopWorkout();
      await settleMs(200);
      final row = (await sessionRow('w4-b1'))!;
      expect(row['steps'], live);
      expect((row['cadence_spm'] as num) > 60, isTrue,
          reason: 'a 2 Hz gait is ~120 steps a minute');
      await finish(app);
    });

    test('stopping clears the count and the next workout starts from a '
        'fresh base', () async {
      final app = await running('w4-b2', 'walking');
      final tl = _Timeline(app, frames: 1200);
      tl.walk(2);
      await app.stopWorkout();
      expect(app.workoutStepsMeasured, isNull);
      app.startWorkout(workoutId: 'w4-b3', type: 'walking');
      await sessionLanded('w4-b3');
      expect(app.workoutStepsMeasured, isNull);
      tl.still(1 / 600);
      expect(app.workoutStepsMeasured, 0,
          reason: 'the first workout\'s steps are not the second\'s');
      await finish(app);
    });

    test('samples with no steps in them bank no steps column and no cadence '
        '(a zero is not banked)', () async {
      final app = await running('w4-b4', 'walking');
      _Timeline(app, frames: 1800).still(3);
      expect(app.workoutStepsMeasured, 0);
      await app.stopWorkout();
      final row = (await sessionRow('w4-b4'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a workout that never saw a sample banks nothing for steps',
        () async {
      final app = await running('w4-b5', 'walking');
      await app.stopWorkout();
      final row = (await sessionRow('w4-b5'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a non-gait workout banks none even beside a walking signal',
        () async {
      final app = await running('w4-b6', 'rowing');
      _Timeline(app, frames: 1800).walk(3);
      await app.stopWorkout();
      final row = (await sessionRow('w4-b6'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a delete teardown (no save) clears the steps state too', () async {
      final app = await running('w4-b7', 'walking');
      _Timeline(app, frames: 600).walk(1);
      expect(app.workoutStepsMeasured, isNotNull);
      await app.deleteWorkout('w4-b7');
      expect(app.workoutStepsMeasured, isNull);
      app.startWorkout(workoutId: 'w4-b8', type: 'walking');
      await sessionLanded('w4-b8');
      expect(app.workoutStepsMeasured, isNull);
      await finish(app);
    });
  });
}
