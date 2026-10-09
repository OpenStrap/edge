// WorkoutController built straight from its constructor, with every host
// callback recording into one trace. The AppState-level suites
// (app_state_workout_*_test) pin the same behaviour through the facade; this
// file pins the controller's own contract: the order it calls its host in, what
// it leaves alone when a stop fails, what delete tears down before it touches
// the row, and what dispose does not do.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/workout_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart' show activityByName;
import 'package:openstrap_edge/ui2/activity/live.dart' show LiveDraft;

import 'support/app_state_workout_harness.dart';

const _db = 'workout_controller.db';

/// Records the workout calls the controller forwards to the repository, and
/// what the controller looked like when each one arrived.
class _Repo extends LocalRepository {
  _Repo(this.onDelete);
  final void Function(String id) onDelete;
  Object? deleteThrows;

  @override
  Future<void> deleteWorkout(String id) async {
    onDelete(id);
    if (deleteThrows != null) throw deleteThrows!;
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

/// A controller plus the host it is wired to. Every callback that reaches the
/// host appends to [trace] in call order.
class _Rig {
  _Rig() {
    repo = _Repo((id) => trace.add('repo.delete:$id'));
    c = WorkoutController(
      user: () => {'age': 30, 'weight_kg': 70.0, 'height_cm': 175.0,
        'sex': 'male', 'resting_hr': 55},
      linkDeviceFamily: () => family,
      clearRadioFallbackAndReconcile: () async => trace.add('radio'),
      nudgeLive: () => trace.add('nudge'),
      setWorkoutActive: (on) => trace.add('hold:$on'),
      notify: () => trace.add('notify'),
      log: logs.add,
      liveHr: () => hr,
      liveRaw: () => raw,
      zoneAlertEnabled: () => false,
      zoneAlertTargetZone: () => 3,
      refreshNightlyRhr: () async => trace.add('rhr'),
      restingHr: () => 55,
      liveRestingHr: () => 55,
      observedCeilingBpm: () => null,
      rhr28: () => const [],
      bumpInsights: () => trace.add('bump'),
      forceResync: () async => trace.add('resync'),
      dismissSupersededSuggestions: ({required startSec, required endSec}) async =>
          trace.add('dismiss:$startSec-$endSec'),
      healthSyncEnabled: () => false,
      exportToHealth: (_) async => false,
      buzz: () async => trace.add('buzz'),
      repo: () => repoOverride ?? repo,
      hostDisposed: () => hostDisposed,
    );
  }

  final trace = <String>[];
  final logs = <String>[];
  int? hr;
  int raw = 0;
  String? family;
  bool hostDisposed = false;
  late final _Repo repo;
  _Repo? repoOverride;
  late final WorkoutController c;
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

  Future<Future<void> Function()> breakSessionWrites() async {
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    return () => db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
  }

  Future<void> started(_Rig r, String id, {String type = 'strength'}) async {
    r.c.startWorkout(workoutId: id, type: type);
    await sessionLanded(id);
  }

  test('a fresh controller is inert', () {
    final r = _Rig();
    expect(r.c.activeWorkout, isNull);
    expect(r.c.workoutStepsMeasured, isNull);
    expect(r.c.liveZone, isNull);
    expect(r.c.liveDistanceKm, isNull);
    expect(r.c.routeTracking, isFalse);
    r.c.debugTickWorkout();
    r.c.dispose();
    expect(r.trace, isEmpty);
  });

  group('start', () {
    test('calls its host in order, arms one tick timer, and snapshots the '
        'raw step base', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final r = _Rig()..raw = 100;
        r.c.startWorkout(workoutId: 'wc-start', type: 'strength');
        expect(r.trace, ['rhr', 'hold:true', 'radio', 'notify']);
        expect(r.logs, ['Live session started. Goal: 300 kcal']);
        expect(probe.active(kTick), hasLength(1));
        expect(r.c.activeWorkout!.workoutId, 'wc-start');
        await until(() => spies.liveActivityMethods.contains('start'));
        expect(spies.keepAwake, [true]);

        // No accel sample yet: unmeasured, not zero.
        r.raw = 160;
        expect(r.c.workoutStepsMeasured, isNull);
        r.c.noteWorkoutSample(nowMs());
        expect(r.c.workoutStepsMeasured, (60 * ana.StepParams.gain).round());

        // A second start while one is live changes nothing.
        r.trace.clear();
        r.c.startWorkout(workoutId: 'wc-other');
        expect(r.trace, isEmpty);
        expect(r.c.activeWorkout!.workoutId, 'wc-start');

        await sessionLanded('wc-start');
        await r.c.stopWorkout();
      });
    });
  });

  group('stop', () {
    test('succeeds in order: release the hold, write, bump, then clear the '
        'live state, notify, end the Live Activity and nudge', () async {
      final r = _Rig();
      await started(r, 'wc-stop');
      r.trace.clear();
      await r.c.stopWorkout();
      expect([
        for (final e in r.trace) e.startsWith('dismiss:') ? 'dismiss' : e
      ], [
        'hold:false',
        'bump',
        'dismiss',
        'notify',
        'nudge',
        'resync',
      ]);
      expect(r.c.activeWorkout, isNull);
      expect((await sessionRow('wc-stop'))!['status'], 'done');
      expect(r.logs.last, startsWith('Live session ended.'));
      await until(() => spies.liveActivityMethods.contains('end'));
      expect(spies.keepAwake, [true, false]);
    });

    test('a failed write keeps the session live and leaves the Live '
        'Activity, step base and zone alert alone; a retry then finishes it',
        () async {
      // A linked band, so the stop reaches the write itself (an unlinked one
      // first reads the stamped family back from the row).
      final r = _Rig()
        ..raw = 10
        ..family = 'gen4';
      await started(r, 'wc-fail');
      await until(() => spies.liveActivityMethods.contains('start'));
      r.c.noteWorkoutSample(nowMs());
      r.raw = 50;
      final steps = r.c.workoutStepsMeasured;
      expect(steps, greaterThan(0));
      final restore = await breakSessionWrites();
      r.trace.clear();
      await expectLater(r.c.stopWorkout(), throwsA(anything));
      // Teardown ran (idempotent), the write failed, nothing was cleared.
      expect(r.trace, ['hold:false', 'notify']);
      expect(r.c.activeWorkout, isNotNull);
      expect(r.c.workoutStepsMeasured, steps,
          reason: 'the raw base is only reset after the write lands');
      expect(spies.liveActivityMethods, ['start'],
          reason: 'the Live Activity ends only after a successful write');
      expect(r.logs.last, contains('keeping it live'));

      await restore();
      r.trace.clear();
      await r.c.stopWorkout();
      expect(r.c.activeWorkout, isNull);
      expect(r.c.workoutStepsMeasured, isNull);
      expect(r.trace, contains('bump'));
      await until(() => spies.liveActivityMethods.contains('end'));
      expect((await sessionRow('wc-fail'))!['steps'], steps);
    });

    test('step coverage is judged at stop entry, before the teardown it '
        'awaits', () async {
      final r = _Rig();
      r.c.startWorkout(workoutId: 'wc-entry', type: 'walking');
      await sessionLanded('wc-entry');
      await until(() => r.c.routeTracker != null && spies.geoListening,
          what: 'the route tracker to listen');
      spies.emitFix(51.0, 0.0);
      await until(() => r.c.routeTracker!.pointCount >= 1);
      // Covered at stop entry (last gait sample 29.5 s ago, window 30 s);
      // stale once the blocked route flush has waited a little over 0.5 s.
      r.c.noteWorkoutSample(nowMs() - 29500);
      r.raw = 80;
      expect(r.c.workoutStepsMeasured, greaterThan(0));
      final hold = await DbHold.acquire();
      addTearDown(hold.release);
      final stopping = r.c.stopWorkout();
      await settleMs(1200);
      expect(r.c.activeWorkout, isNotNull, reason: 'still tearing down');
      expect(r.c.workoutStepsMeasured, isNull,
          reason: 'read now, the same stream is over 30 s old');
      await hold.release();
      await stopping;
      expect((await sessionRow('wc-entry'))!['steps'], greaterThan(0));
    });

    test('a gap over 30 s, or a late first frame, makes session steps '
        'absent', () async {
      final late = _Rig();
      await started(late, 'wc-late');
      // First frame 31 s after the start: a stream that only came up late.
      late.c.noteWorkoutSample(
          late.c.activeWorkout!.startTime.millisecondsSinceEpoch + 31000);
      late.raw = 50;
      expect(late.c.workoutStepsMeasured, isNull);
      await late.c.stopWorkout();
      expect((await sessionRow('wc-late'))!['steps'], isNull);
    });

    test('the pedometer rebases the base before it zeroes the counter, so '
        'steps carry through a reconnect; minute steps are workout-scoped',
        () async {
      final r = _Rig();
      r.c.addWorkoutMinuteSteps(120); // no workout yet: dropped
      await started(r, 'wc-rebase');
      r.c.noteWorkoutSample(nowMs());
      r.raw = 100;
      final before = r.c.workoutStepsMeasured!;
      expect(before, greaterThan(0));
      r.c.rebaseWorkoutSteps();
      r.raw = 0; // the connection-level counter is zeroed
      expect(r.c.workoutStepsMeasured, before);
      r.raw = 20;
      expect(r.c.workoutStepsMeasured, greaterThan(before));
      await r.c.stopWorkout();
      expect((await sessionRow('wc-rebase'))!['cadence_spm'], isNull,
          reason: 'the pre-start minute was never banked');
    });
  });

  group('delete', () {
    test('a live workout is torn down before its row is deleted, and the '
        'host hears about it even when the delete throws', () async {
      final r = _Rig();
      await started(r, 'wc-del', type: 'walking');
      await until(() => r.c.routeTracker != null && spies.geoListening);
      // The repo sees the controller as the delete arrives: teardown is done.
      var sawLive = true;
      var sawTracker = true;
      final repo = _Repo((id) {
        r.trace.add('repo.delete:$id');
        sawLive = r.c.activeWorkout != null;
        sawTracker = r.c.routeTracker != null;
      })..deleteThrows = StateError('disk gone');
      r.repoOverride = repo;
      r.trace.clear();
      await expectLater(r.c.deleteWorkout('wc-del'), throwsStateError);
      expect(r.trace, [
        'hold:false',
        'nudge',
        'repo.delete:wc-del',
        'notify',
      ], reason: 'teardown, then the row, then the notify from the finally');
      expect(sawLive, isFalse);
      expect(sawTracker, isFalse);
      expect(r.c.activeWorkout, isNull);
      expect(r.c.routeTracker, isNull);
      expect(spies.keepAwake, [true, false]);
      await until(() => spies.liveActivityMethods.contains('end'));
    });

    test('deleting some other row touches no live state and does not notify',
        () async {
      final r = _Rig();
      await started(r, 'wc-keep');
      r.trace.clear();
      await r.c.deleteWorkout('someone-else');
      expect(r.trace, ['repo.delete:someone-else']);
      expect(r.c.activeWorkout, isNotNull);
      await r.c.stopWorkout();
    });

    test('the delete waits for a tally save the last tick left in flight, '
        'then the tally row is gone', () async {
      final r = _Rig()..hr = 120;
      await started(r, 'wc-pending');
      final hold = await DbHold.acquire();
      addTearDown(hold.release);
      r.c.debugTickWorkout(); // dispatches the first snapshot, blocked on the db
      r.trace.clear();
      final deleting = r.c.deleteWorkout('wc-pending');
      await settleMs(300);
      expect(r.trace, isNot(contains('repo.delete:wc-pending')),
          reason: 'the delete must not race the pending save');
      await hold.release();
      await deleting;
      expect(r.trace, contains('repo.delete:wc-pending'));
      await settleMs(200);
      expect(await LocalDb.liveWorkoutTally('wc-pending'), isNull);
    });
  });

  group('the 1 Hz tick', () {
    test('a paused session holds its clock: no tally, no notify, no Live '
        'Activity push', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final r = _Rig()..hr = 130;
        await started(r, 'wc-pause');
        addTearDown(LiveDraft.clear);
        final w = r.c.activeWorkout!;
        final draft = LiveDraft.begin(activityByName('running')!)
          ..pausedSec = 20 * 60;
        draft.setPaused(true);
        draft.pausedAt = DateTime.now().subtract(const Duration(minutes: 5));
        r.trace.clear();
        r.c.debugTickWorkout();
        expect(r.trace, isEmpty, reason: 'a paused tick does not notify');
        expect(w.zoneSeconds.every((s) => s == 0), isTrue);
        expect(w.currentHr, isNull, reason: 'the HR is not read while paused');
        expect(await LocalDb.liveWorkoutTally('wc-pause'), isNull);
        draft.setPaused(false);
        await r.c.stopWorkout();
      });
    });

    test('bills a fresh reading once, notifies once, and throttles the '
        'tally snapshot and the Live Activity push', () async {
      final r = _Rig()..hr = 130;
      await started(r, 'wc-tick');
      await until(() => spies.liveActivityMethods.contains('start'));
      r.trace.clear();
      r.c.debugTickWorkout();
      expect(r.trace, ['notify']);
      expect(r.c.activeWorkout!.currentHr, 130);
      await tallyLanded('wc-tick');
      final first = (await LocalDb.liveWorkoutTally('wc-tick'))!['updated_ts'];
      await settleMs(50);
      r.c.debugTickWorkout();
      await settleMs(100);
      expect((await LocalDb.liveWorkoutTally('wc-tick'))!['updated_ts'], first,
          reason: 'within 30 s the second tick writes no snapshot');
      await until(() => spies.liveActivityMethods.contains('update'));
      expect(spies.liveActivityMethods.where((m) => m == 'update'), hasLength(1),
          reason: 'within 4 s the second tick pushes nothing');
      expect(r.trace, ['notify', 'notify']);

      r.hr = null;
      r.c.debugTickWorkout();
      expect(r.c.activeWorkout!.currentHr, isNull,
          reason: 'an absent reading stays absent');
      await r.c.stopWorkout();
    });
  });

  group('cold-start reconcile', () {
    Future<void> live(String id, {required int ageSec}) => LocalDb.putSession({
          'id': id,
          'start_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 - ageSec,
          'end_ts': null,
          'type': 'strength',
          'status': 'live',
          'source': 'manual',
          'created_at': DateTime.now().millisecondsSinceEpoch - ageSec * 1000,
        });

    Future<void> snapshot(String id, int updatedMs) => LocalDb.saveLiveWorkoutTally({
          'workout_id': id,
          'updated_ts': updatedMs,
          'per_minute_hr': jsonEncode([100.0, 110.0]),
          'zone_seconds': jsonEncode([0.0, 60.0, 0.0, 0.0, 0.0, 0.0]),
          'seconds_by_bpm': jsonEncode({'100': 60.0}),
          'max_hr_seen': 110,
        });

    test('a stale row ends at its last tally snapshot, flagged fabricated, '
        'and the supersede sweep sees the same bounds', () async {
      final r = _Rig();
      await live('wc-stale', ageSec: 10 * 3600);
      final startSec = (await sessionRow('wc-stale'))!['start_ts'] as int;
      await snapshot('wc-stale', (startSec + 3600) * 1000);
      await r.c.reconcileOrphanedLiveWorkout();
      final row = (await sessionRow('wc-stale'))!;
      expect(row['status'], 'done');
      expect(row['end_ts'], startSec + 3600);
      expect(row['end_ts_fabricated'], 1);
      expect(r.trace, ['dismiss:$startSec-${startSec + 3600}']);
      expect(r.c.activeWorkout, isNull);
      await settleMs(100);
      expect(await LocalDb.liveWorkoutTally('wc-stale'), isNull,
          reason: 'an orphaned snapshot is deleted');
    });

    test('no snapshot, a malformed one, or one before the start fall back '
        'to the start; one from the future is capped at now', () async {
      final r = _Rig();
      await live('wc-none', ageSec: 9 * 3600);
      await live('wc-bad', ageSec: 9 * 3600);
      await live('wc-early', ageSec: 9 * 3600);
      await live('wc-future', ageSec: 9 * 3600);
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': 'wc-bad',
        'updated_ts': 'garbage',
        'per_minute_hr': '[]',
        'zone_seconds': '[]',
        'seconds_by_bpm': '{}',
        'max_hr_seen': 0,
      });
      final startSec = (await sessionRow('wc-early'))!['start_ts'] as int;
      await snapshot('wc-early', (startSec - 600) * 1000);
      final before = nowMs() ~/ 1000;
      await snapshot('wc-future', nowMs() + 5 * 3600 * 1000);
      await r.c.reconcileOrphanedLiveWorkout();
      for (final id in ['wc-none', 'wc-bad', 'wc-early']) {
        final row = (await sessionRow(id))!;
        expect(row['end_ts'], row['start_ts'], reason: id);
        expect(row['end_ts_fabricated'], 1, reason: id);
      }
      final f = (await sessionRow('wc-future'))!;
      expect(f['end_ts'] as int, inInclusiveRange(before, nowMs() ~/ 1000));
    });

    test('a recent row is resumed with its tallies restored, steps held '
        'absent, one tick timer and the host holds', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final r = _Rig();
        await live('wc-resume', ageSec: 600);
        await snapshot('wc-resume', nowMs() - 5000);
        await r.c.reconcileOrphanedLiveWorkout();
        final w = r.c.activeWorkout!;
        expect(w.workoutId, 'wc-resume');
        expect(w.zoneSeconds[1], 60);
        expect(probe.active(kTick), hasLength(1));
        expect(r.trace, ['rhr', 'hold:true', 'nudge', 'notify']);
        await until(() => spies.keepAwake.isNotEmpty);
        expect(spies.keepAwake, [true]);
        expect(spies.liveActivityMethods, isEmpty,
            reason: 'a resume does not restart the Live Activity');
        r.c.noteWorkoutSample(nowMs());
        r.raw = 50;
        expect(r.c.workoutStepsMeasured, isNull,
            reason: 'the relaunch left a hole in the count');
        await r.c.stopWorkout();
      });
    });
  });

  group('dispose', () {
    test('cancels the tick timer and nothing else: the session stays live, '
        'the display hold, route recorder and Live Activity are untouched',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final r = _Rig();
        r.c.startWorkout(workoutId: 'wc-dispose', type: 'walking');
        await sessionLanded('wc-dispose');
        await until(() => r.c.routeTracker != null && spies.geoListening);
        await until(() => spies.liveActivityMethods.contains('start'));
        expect(probe.active(kTick), hasLength(1));
        final tracker = r.c.routeTracker;
        r.trace.clear();
        r.c.dispose();
        expect(probe.active(kTick), isEmpty);
        expect(r.trace, isEmpty, reason: 'no host call at dispose');
        expect(r.c.activeWorkout, isNotNull);
        expect(r.c.routeTracker, same(tracker));
        expect(r.c.routeTracking, isTrue);
        expect(spies.keepAwake, [true]);
        expect(spies.liveActivityMethods, ['start']);
        expect((await sessionRow('wc-dispose'))!['status'], 'live');
        // Clean up the way a test must: the controller no longer ticks.
        await r.c.stopWorkout();
      });
    });

    test('a permission answer that lands after the host is disposed starts '
        'no route recorder and notifies nobody', () async {
      final r = _Rig();
      spies.geoGate = Completer<void>();
      r.c.startWorkout(workoutId: 'wc-late-perm', type: 'walking');
      await sessionLanded('wc-late-perm');
      await until(() => spies.geolocator.isNotEmpty);
      r.hostDisposed = true;
      r.trace.clear();
      spies.geoGate!.complete();
      await settleMs(200);
      expect(r.c.routeTracker, isNull);
      expect(r.trace, isEmpty);
      r.hostDisposed = false;
      await r.c.stopWorkout();
    });
  });
}
