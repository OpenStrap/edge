// The live workout's start / stop / delete transitions through AppState: what
// each persists, releases and announces, how many times it notifies, what a
// failed stop leaves behind, and the order teardown and persistence run in.
//
// There is no pause or resume here: a workout is live or it is not. (A
// "resume" is only the cold-start reconcile, app_state_workout_reconcile_test;
// a pause is the live screen's draft, app_state_workout_tick_test.)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_lifecycle.db';

/// A repo that records the workout calls AppState forwards to it, and what
/// the app looked like at the moment each one arrived.
class _WorkoutRepo extends LocalRepository {
  _WorkoutRepo(this.onDelete);
  final void Function(String id) onDelete;
  final calls = <String>[];
  Object? deleteThrows;
  Completer<void>? deleteGate;

  @override
  Future<void> deleteWorkout(String id) async {
    calls.add('delete:$id');
    onDelete(id);
    if (deleteGate != null) await deleteGate!.future;
    if (deleteThrows != null) throw deleteThrows!;
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

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

  /// Rename the sessions table away so the next write to it fails, like a
  /// failing disk; [restore] puts it back.
  Future<Future<void> Function()> breakSessionWrites() async {
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    return () => db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
  }

  group('a fresh app', () {
    test('has no workout, no breathing session and no route state', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.activeWorkout, isNull);
      expect(app.workoutStepsMeasured, isNull);
      expect(app.liveZone, isNull);
      expect(app.liveDistanceKm, isNull);
      expect(app.routeTracker, isNull);
      expect(app.routeTracking, isFalse);
      expect(app.routeLocationIssue, isNull);
      expect(app.breathingActive, isFalse);
      expect(app.breathingWindowOpen, isFalse);
      expect(app.breathingResult, isNull);
      expect(app.breathingError, isNull);
      expect(app.breathingStartedAt, isNull);
      expect(app.breathingTarget, isNull);
      expect(app.debugLiveOwners.activeWorkout, isFalse);
    });
  });

  group('startWorkout', () {
    test('builds the live state from its arguments and the profile, and '
        'notifies twice (hold + start)', () async {
      final app = AppState.forTesting();
      app.user = {..._user};
      app.engine.state.generation = 'gen4';
      final ticks = TickCounter(app);
      final before = DateTime.now();
      app.startWorkout(workoutId: 'w4-start', type: 'strength', targetKcal: 450);
      final w = app.activeWorkout!;
      expect(w.workoutId, 'w4-start');
      expect(w.type, 'strength');
      expect(w.targetKcal, 450);
      expect(w.startTime.isBefore(before), isFalse);
      expect(w.elapsed, Duration.zero);
      expect(w.currentHr, isNull);
      expect(w.profile.weightKg, 70.0);
      expect(w.hrMax, isNotNull, reason: 'age 30 on a stamped gen4 band');
      expect(w.zoneSet, isNotNull);
      expect(w.restingHr, 55, reason: 'the profile RHR until a night lands');
      // Two, synchronously: the scheduler's hold announces itself through its
      // onChanged (= notifyListeners), then startWorkout's own notify.
      expect(ticks.ticks, 2);
      await sessionLanded('w4-start');
      ticks.stop();
      await finish(app);
    });

    test('an unlinked, profile-less start pins no ceiling and no zone set '
        '(absent, never a default)', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-bare');
      await sessionLanded('w4-bare');
      final w = app.activeWorkout!;
      expect(w.type, 'other');
      expect(w.targetKcal, 300);
      expect(w.hrMax, isNull);
      expect(w.zoneSet, isNull);
      expect(w.restingHr, isNull);
      expect(app.liveZone, isNull);
      await finish(app);
    });

    test('an omitted id becomes w<start epoch ms>', () async {
      final app = AppState.forTesting();
      app.startWorkout();
      final w = app.activeWorkout!;
      expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
      await sessionLanded(w.workoutId!);
      await finish(app);
    });

    test('a second start while one is live is a no-op: same state, no notify, '
        'no second timer, no second Live Activity', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.startWorkout(workoutId: 'w4-first', type: 'strength');
        await sessionLanded('w4-first');
        final first = app.activeWorkout;
        final ticks = TickCounter(app);
        final timers = probe.periodics.length;
        final activity = spies.liveActivity.length;
        app.startWorkout(workoutId: 'w4-second', type: 'running');
        expect(identical(app.activeWorkout, first), isTrue);
        expect(app.activeWorkout!.workoutId, 'w4-first');
        expect(ticks.ticks, 0);
        expect(probe.periodics.length, timers);
        expect(spies.liveActivity.length, activity);
        ticks.stop();
        await finish(app);
      });
    });

    test('arms a 1 s tick, holds the display, starts the Live Activity and '
        'logs the goal', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.startWorkout(workoutId: 'w4-arms', type: 'strength', targetKcal: 410);
        await sessionLanded('w4-arms');
        expect(probe.active(kTick), hasLength(1));
        expect(app.logLines, contains('Live session started. Goal: 410 kcal'));
        await until(() =>
            spies.keepAwake.isNotEmpty && spies.liveActivity.isNotEmpty);
        expect(spies.keepAwake, [true]);
        expect(spies.liveActivityMethods, ['start']);
        final args = spies.liveActivity.single.args as Map;
        expect(args['targetKcal'], 410);
        expect(args['hr'], 0);
        expect(args['strain'], isNull, reason: 'nothing measured yet');
        expect(args['calories'], isNull);
        await finish(app);
      });
    });

    test('holds derivation for the session: the scheduler says so, and says '
        'so again when it ends', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-hold', type: 'strength');
      await sessionLanded('w4-hold');
      expect(app.logLines,
          contains('[derive-scheduler] workout live — holding derive work'));
      expect(
          app.logLines,
          isNot(contains('[derive-scheduler] workout ended — derive may run')));
      await app.stopWorkout();
      const release = '[derive-scheduler] workout ended — derive may run';
      expect(app.logLines, contains(release));
      // logLines is newest first: the summary line comes after the release.
      expect(
          app.logLines.indexWhere((l) => l.startsWith('Live session ended')),
          lessThan(app.logLines.indexOf(release)));
      await finish(app);
    });

    test('writes the live session row: status live, no end, the strap stamp',
        () async {
      final app = AppState.forTesting();
      app.engine.state.generation = 'gen5';
      final started = DateTime.now();
      app.startWorkout(workoutId: 'w4-row', type: 'running');
      await sessionLanded('w4-row');
      final row = (await sessionRow('w4-row'))!;
      expect(row['status'], 'live');
      expect(row['end_ts'], isNull);
      expect(row['type'], 'running');
      expect(row['source'], 'manual');
      expect(row['device_family'], 'gen5');
      expect(row['start_ts'],
          inInclusiveRange(started.millisecondsSinceEpoch ~/ 1000 - 1,
              started.millisecondsSinceEpoch ~/ 1000 + 1));
      expect(row['created_at'],
          (app.activeWorkout!.startTime.millisecondsSinceEpoch));
      expect(row['calories'], isNull);
      await finish(app);
    });

    test('an unlinked start stamps no strap family (unknown, not gen4)',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-nofam', type: 'strength');
      await sessionLanded('w4-nofam');
      expect((await sessionRow('w4-nofam'))!['device_family'], isNull);
      await finish(app);
    });

    test('the workout is a live-stream owner from the first line, even '
        'offline, and a start clears the sticky radio fallback', () async {
      final engine = RecordingEngine();
      final app = AppState.forTesting(engine: engine);
      app.startWorkout(workoutId: 'w4-own', type: 'strength');
      expect(app.debugLiveOwners.activeWorkout, isTrue);
      expect(app.debugLiveOwners.foregroundGaitWorkout, isFalse);
      expect(engine.radioFallbackClears, 1);
      await sessionLanded('w4-own');
      await app.stopWorkout();
      expect(app.debugLiveOwners.activeWorkout, isFalse);
      expect(engine.reconciles, greaterThan(0),
          reason: 'stop nudges the engine so it can drop the streams');
      await finish(app);
    });
  });

  group('stopWorkout', () {
    test('with nothing live it is a no-op: no notify, no write, no release',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      await app.stopWorkout();
      expect(ticks.ticks, 0);
      expect(app.logLines, isEmpty);
      expect(spies.liveActivity, isEmpty);
      expect(spies.keepAwake, isEmpty);
      ticks.stop();
    });

    test('an unmeasured session banks status done, nullable measures left '
        'null, and clears every live field', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.engine.state.generation = 'gen5';
        app.startWorkout(workoutId: 'w4-stop', type: 'strength');
        final startMs = app.activeWorkout!.startTime.millisecondsSinceEpoch;
        await sessionLanded('w4-stop');
        final rev = app.insightsRevision.value;
        await app.stopWorkout();
        await settleMs(300);
        expect(app.activeWorkout, isNull);
        expect(app.workoutStepsMeasured, isNull);
        expect(app.liveZone, isNull);
        expect(probe.active(kTick), isEmpty, reason: 'the tick is cancelled');
        expect(app.insightsRevision.value, rev + 1,
            reason: 'the Workout tab hears the session landed');
        final row = (await sessionRow('w4-stop'))!;
        expect(row['status'], 'done');
        expect(row['type'], 'strength');
        expect(row['source'], 'manual');
        expect(row['device_family'], 'gen5');
        expect(row['created_at'], startMs);
        expect(row['start_ts'], startMs ~/ 1000);
        expect(row['end_ts'] as int, greaterThanOrEqualTo(startMs ~/ 1000));
        expect(row['calories'], isNull);
        expect(row['strain'], isNull);
        expect(row['max_hr'], isNull);
        expect(row['steps'], isNull);
        expect(row['cadence_spm'], isNull);
        expect(row['duration_min'], 0);
        expect(row['zone_min_json'], '[]');
        expect(app.logLines,
            contains('Live session ended. No calorie anchors in the profile.'));
        await finish(app);
      });
    });

    test('notifies once for the held-derive release, once more for the '
        'scheduler\'s own re-read, and once for the stop itself', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-notify', type: 'strength');
      await sessionLanded('w4-notify');
      final ticks = TickCounter(app);
      await app.stopWorkout();
      await settleMs(300);
      expect(ticks.ticks, 3);
      ticks.stop();
      await finish(app);
    });

    test('releases the display, ends the Live Activity and ends the '
        'workout\'s hold on the display wake', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-rel', type: 'strength');
      await sessionLanded('w4-rel');
      await app.stopWorkout();
      await until(() =>
          spies.keepAwake.length >= 2 && spies.liveActivity.length >= 2);
      expect(spies.keepAwake, [true, false]);
      expect(spies.liveActivityMethods, ['start', 'end']);
      expect(ScreenWake.owners, isNot(contains('workout')));
      await finish(app);
    });

    test('stop keeps the strap stamp when the link has dropped (the row is '
        'INSERT OR REPLACE)', () async {
      final app = AppState.forTesting();
      app.engine.state.generation = 'gen5';
      app.startWorkout(workoutId: 'w4-stamp', type: 'strength');
      await sessionLanded('w4-stamp');
      app.engine.state.generation = null;
      await app.stopWorkout();
      expect((await sessionRow('w4-stamp'))!['device_family'], 'gen5');
      await finish(app);
    });

    test('a measured session banks its peak, zone minutes and kcal; the '
        'duration is wall clock (0 min here)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-meas', type: 'strength');
        await sessionLanded('w4-meas');
        setLiveHr(app, 150);
        final tick = probe.active(kTick).single;
        for (var i = 0; i < 90; i++) {
          tick.fire();
        }
        final w = app.activeWorkout!;
        expect(w.currentHr, 150);
        expect(w.zoneSeconds.reduce((a, b) => a + b), 90);
        await app.stopWorkout();
        final row = (await sessionRow('w4-meas'))!;
        expect((row['max_hr'] as num) > 0, isTrue);
        expect(row['zone_min_json'], isNot('[]'));
        expect(row['calories'], isNotNull);
        expect(row['strain'], isNotNull);
        expect(row['duration_min'], 0);
        await finish(app);
      });
    });

    test('a second stop right after the first is a no-op', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-twice', type: 'strength');
      await sessionLanded('w4-twice');
      await app.stopWorkout();
      final rev = app.insightsRevision.value;
      final ticks = TickCounter(app);
      await app.stopWorkout();
      expect(ticks.ticks, 0);
      expect(app.insightsRevision.value, rev);
      ticks.stop();
      await finish(app);
    });

    test('a workout can be started again after a stop, with a fresh state',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.startWorkout(workoutId: 'w4-one', type: 'strength');
        await sessionLanded('w4-one');
        final first = probe.active(kTick).single;
        final one = app.activeWorkout;
        await app.stopWorkout();
        app.startWorkout(workoutId: 'w4-two', type: 'running');
        await sessionLanded('w4-two');
        expect(identical(app.activeWorkout, one), isFalse);
        expect(app.activeWorkout!.workoutId, 'w4-two');
        expect(app.activeWorkout!.zoneSeconds.every((s) => s == 0), isTrue);
        expect(first.cancelled, isTrue);
        expect(probe.active(kTick), hasLength(1));
        await finish(app);
      });
    });

    test('a stop retires the auto-detected suggestion it covers, and with '
        'health sync off exports nothing', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-sug', type: 'strength');
      await sessionLanded('w4-sug');
      backdate(app, const Duration(minutes: 20));
      final start = app.activeWorkout!.startTime.millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putWorkoutSuggestion({
        'id': 'sug-w4',
        'date': '2026-01-01',
        'start_ts': start + 60,
        'end_ts': start + 300,
        'dismissed': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      await app.stopWorkout();
      expect(
          (await LocalDb.activeWorkoutSuggestions())
              .where((s) => s['id'] == 'sug-w4'),
          isEmpty);
      expect(spies.health, isEmpty);
      await finish(app);
    });
  });

  group('a stop whose write fails', () {
    test('stays live and rethrows, with the teardown already done: tick '
        'cancelled, display released, derive hold released, route recorder '
        'dropped, the Live Activity left running, nothing exported or bumped',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.healthSyncEnabled = true;
        app.engine.state.generation = 'gen5';
        app.startWorkout(workoutId: 'w4-fail', type: 'running');
        await sessionLanded('w4-fail');
        await until(() => app.routeTracker != null && spies.geoListening);
        backdate(app, const Duration(minutes: 5));
        final restore = await breakSessionWrites();
        final rev = app.insightsRevision.value;
        final ticks = TickCounter(app);
        await expectLater(app.stopWorkout(), throwsA(anything));
        await settleMs(300);

        expect(app.activeWorkout, isNotNull, reason: 'kept as the only copy');
        expect(probe.active(kTick), isEmpty);
        expect(app.routeTracker, isNull);
        expect(app.routeLocationIssue, isNull);
        expect(spies.geoCancels, 1);
        expect(spies.keepAwake, [true, false]);
        expect(app.logLines,
            contains('[derive-scheduler] workout ended — derive may run'));
        expect(spies.liveActivityMethods, ['start'],
            reason: 'the Live Activity ends only after the row is durable');
        expect(
            app.logLines.any((l) => l.startsWith(
                '[workout] could not save session w4-fail:') &&
                l.endsWith('— keeping it live')),
            isTrue);
        expect(app.insightsRevision.value, rev);
        expect(spies.health, isEmpty);
        expect(ticks.ticks, greaterThanOrEqualTo(2),
            reason: 'the hold release and the write failure both notify');

        await restore();
        await app.stopWorkout();
        expect(app.activeWorkout, isNull);
        expect((await sessionRow('w4-fail'))!['status'], 'done');
        expect(app.insightsRevision.value, rev + 1);
        await until(() => spies.liveActivityMethods.contains('end'));
        expect(spies.liveActivityMethods, ['start', 'end']);
        await until(() => spies.health.isNotEmpty);
        expect(spies.keepAwake, [true, false],
            reason: 'the retry does not touch the display again');
        ticks.stop();
        await finish(app);
      });
    });
  });

  group('the order stop and delete run in', () {
    test('a tally save still in flight when stop is called cannot outlive '
        'the stop\'s delete of that row', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-ord', type: 'strength');
        await sessionLanded('w4-ord');
        setLiveHr(app, 150);
        final hold = await DbHold.acquire();
        probe.active(kTick).single.fire(); // dispatches the save, now blocked
        final stopping = app.stopWorkout();
        await settleMs(100);
        expect(app.activeWorkout, isNotNull, reason: 'stop waits on the write');
        await hold.release();
        await stopping;
        await settleMs(200);
        expect((await sessionRow('w4-ord'))!['status'], 'done');
        expect(await LocalDb.liveWorkoutTally('w4-ord'), isNull,
            reason: 'the save landed first and the delete after it');
        await finish(app);
      });
    });

    test('the same for a delete of the live workout', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.repo = _WorkoutRepo((_) {});
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-ord2', type: 'strength');
        await sessionLanded('w4-ord2');
        setLiveHr(app, 150);
        final hold = await DbHold.acquire();
        probe.active(kTick).single.fire();
        final deleting = app.deleteWorkout('w4-ord2');
        await settleMs(100);
        await hold.release();
        await deleting;
        await settleMs(200);
        expect(await LocalDb.liveWorkoutTally('w4-ord2'), isNull);
        await finish(app);
      });
    });
  });

  group('deleteWorkout', () {
    test('deleting a stored workout that is not live only asks the repo',
        () async {
      final app = AppState.forTesting();
      final repo = _WorkoutRepo((_) {});
      app.repo = repo;
      app.startWorkout(workoutId: 'w4-live', type: 'strength');
      await sessionLanded('w4-live');
      final ticks = TickCounter(app);
      await app.deleteWorkout('some-other');
      expect(repo.calls, ['delete:some-other']);
      expect(app.activeWorkout!.workoutId, 'w4-live');
      expect(ticks.ticks, 0);
      ticks.stop();
      await finish(app);
    });

    test('deleting the live one tears the session down WITHOUT saving it: '
        'tick cancelled, display released, Live Activity ended, three '
        'notifies, no sessions bump', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        final repo = _WorkoutRepo((_) {});
        app.repo = repo;
        app.startWorkout(workoutId: 'w4-del', type: 'strength');
        await sessionLanded('w4-del');
        final rev = app.insightsRevision.value;
        final ticks = TickCounter(app);
        await app.deleteWorkout('w4-del');
        await settleMs(300);
        expect(repo.calls, ['delete:w4-del']);
        expect(app.activeWorkout, isNull);
        expect(probe.active(kTick), isEmpty);
        expect(ticks.ticks, 3);
        expect(app.insightsRevision.value, rev,
            reason: 'nothing was saved, so no sessions bump');
        await until(() =>
            spies.keepAwake.length >= 2 && spies.liveActivity.length >= 2);
        expect(spies.keepAwake, [true, false]);
        expect(spies.liveActivityMethods, ['start', 'end']);
        expect(app.debugLiveOwners.activeWorkout, isFalse);
        expect(app.logLines,
            contains('[derive-scheduler] workout ended — derive may run'));
        expect((await sessionRow('w4-del'))!['status'], 'live',
            reason: 'the fake repo deleted nothing, and the teardown writes '
                'no row of its own');
        ticks.stop();
        await finish(app);
      });
    });

    test('teardown runs BEFORE the row is deleted: by the time the repo is '
        'asked, the workout is gone, the tick cancelled, the display and '
        'derive hold released and the route tail flushed under its id',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        late final Map<String, Object?> atDelete;
        final repo = _WorkoutRepo((id) {
          atDelete = {
            'workout': app.activeWorkout,
            'tick': probe.active(kTick).length,
            'owners': ScreenWake.owners.contains('workout'),
            'tracker': app.routeTracker,
            'geoCancels': spies.geoCancels,
            'release': app.logLines.contains(
                '[derive-scheduler] workout ended — derive may run'),
          };
        });
        app.repo = repo;
        app.startWorkout(workoutId: 'w4-order', type: 'running');
        await sessionLanded('w4-order');
        await until(() => app.routeTracker != null && spies.geoListening);
        spies.emitFix(51.0, 0.0);
        spies.emitFix(51.001, 0.0);
        await until(() => app.routeTracker!.pointCount >= 2);
        expect(await LocalDb.routePoints('w4-order'), isEmpty,
            reason: 'still sitting in the tracker\'s batch buffer');
        await app.deleteWorkout('w4-order');
        expect(atDelete['workout'], isNull);
        expect(atDelete['tick'], 0);
        expect(atDelete['owners'], isFalse);
        expect(atDelete['tracker'], isNull);
        expect(atDelete['geoCancels'], 1);
        expect(atDelete['release'], isTrue);
        expect(await LocalDb.routePoints('w4-order'), hasLength(2),
            reason: 'flushed by the teardown, before the repo delete ran');
        await finish(app);
      });
    });

    test('a repo that throws still leaves the session torn down, notifies '
        'from the finally, and rethrows', () async {
      final app = AppState.forTesting();
      final repo = _WorkoutRepo((_) {})..deleteThrows = StateError('nope');
      app.repo = repo;
      app.startWorkout(workoutId: 'w4-delthrow', type: 'strength');
      await sessionLanded('w4-delthrow');
      final ticks = TickCounter(app);
      await expectLater(app.deleteWorkout('w4-delthrow'), throwsStateError);
      expect(app.activeWorkout, isNull);
      expect(app.debugLiveOwners.activeWorkout, isFalse);
      await settleMs(200);
      expect(ticks.ticks, 3);
      expect((await sessionRow('w4-delthrow'))!['status'], 'live',
          reason: 'the row stays live for the next launch\'s reconcile');
      await until(() => spies.liveActivityMethods.contains('end'));
      ticks.stop();
      await finish(app);
    });

    test('the notify waits for the repo: with the delete still pending the '
        'session is already gone but the only notify so far is the '
        'scheduler\'s', () async {
      final app = AppState.forTesting();
      final repo = _WorkoutRepo((_) {})..deleteGate = Completer<void>();
      app.repo = repo;
      app.startWorkout(workoutId: 'w4-pend', type: 'strength');
      await sessionLanded('w4-pend');
      final ticks = TickCounter(app);
      final deleting = app.deleteWorkout('w4-pend');
      await until(() => repo.calls.isNotEmpty);
      expect(app.activeWorkout, isNull);
      final before = ticks.ticks;
      repo.deleteGate!.complete();
      await deleting;
      expect(ticks.ticks, before + 1, reason: 'the finally block\'s notify');
      ticks.stop();
      await finish(app);
    });

    test('with no repo the live session is still torn down', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-norepo', type: 'strength');
      await sessionLanded('w4-norepo');
      await app.deleteWorkout('w4-norepo');
      expect(app.activeWorkout, isNull);
      await finish(app);
    });
  });
}
