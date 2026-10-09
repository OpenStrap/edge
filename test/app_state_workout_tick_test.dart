// The 1 Hz workout tick through AppState: what one tick bills from the live
// heart rate, what it pushes to the lock-screen activity and the tally table,
// how many times it notifies, and what a paused session's tick does instead.
//
// The tick is fired two ways, both through AppState: by hand through the
// periodic timer the app armed (TimerProbe), or through debugTickWorkout.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_tick.db';

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

  /// A started session on a stamped gen4 band for a profiled user, ticking
  /// through [probe]'s timer.
  Future<(AppState, FakePeriodic)> started(
    TimerProbe probe,
    String id, {
    String type = 'strength',
    bool profile = true,
  }) async {
    final app = AppState.forTesting();
    if (profile) app.user = {..._user};
    app.engine.state.generation = 'gen4';
    app.startWorkout(workoutId: id, type: type);
    await sessionLanded(id);
    return (app, probe.active(kTick).single);
  }

  group('what one tick does to the session', () {
    test('with nothing live a tick is a no-op: no notify, nothing written',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      app.debugTickWorkout();
      expect(ticks.ticks, 0);
      expect(spies.liveActivity, isEmpty);
      ticks.stop();
    });

    test('a tick notifies exactly once, with or without a heart rate',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-n');
        final ticks = TickCounter(app);
        setLiveHr(app, 140);
        tick.fire();
        expect(ticks.ticks, 1);
        setLiveHr(app, null);
        tick.fire();
        expect(ticks.ticks, 2);
        tick.fire();
        expect(ticks.ticks, 3);
        ticks.stop();
        await finish(app);
      });
    });

    test('a fresh reading sets currentHr, the elapsed time and one second in '
        'the zone that heart rate is in', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-zone');
        setLiveHr(app, 150);
        await settleMs(50);
        tick.fire();
        final w = app.activeWorkout!;
        expect(w.currentHr, 150);
        expect(w.elapsed.inMilliseconds, greaterThan(0));
        final zone = app.liveZone;
        expect(zone, isNotNull);
        expect(zone, inInclusiveRange(1, 5));
        expect(w.zoneSeconds[zone!], 1);
        expect(w.zoneSeconds.reduce((a, b) => a + b), 1);
        // Same zone table the screens read, so the live gauge and the tally
        // cannot disagree about one heartbeat.
        expect(w.zoneSet!.zoneNumber(150), zone);
        tick.fire();
        tick.fire();
        expect(w.zoneSeconds[zone], 3);
        await finish(app);
      });
    });

    test('a different heart rate is billed to its own zone', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-zones');
        setLiveHr(app, 100);
        tick.fire();
        final low = app.liveZone;
        setLiveHr(app, 185);
        tick.fire();
        final high = app.liveZone;
        expect(high, isNotNull);
        expect(low == null || low < high!, isTrue);
        final w = app.activeWorkout!;
        expect(w.zoneSeconds.reduce((a, b) => a + b), 2);
        expect(w.zoneSeconds[high!], 1);
        await finish(app);
      });
    });

    test('with no zone set (no age on file) every second lands in Z0 and '
        'liveZone is null', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-z0', profile: false);
        setLiveHr(app, 150);
        tick.fire();
        final w = app.activeWorkout!;
        expect(w.zoneSet, isNull);
        expect(app.liveZone, isNull);
        expect(w.zoneSeconds[0], 1);
        expect(w.zoneSeconds.sublist(1).every((s) => s == 0), isTrue);
        await finish(app);
      });
    });

    test('a reading older than the freshness window is absent: currentHr '
        'null, no second billed, the peak untouched', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-stale');
        setLiveHr(app, 150);
        tick.fire();
        final w = app.activeWorkout!;
        final billed = w.zoneSeconds.reduce((a, b) => a + b);
        final peak = w.maxHrSeen;
        setLiveHr(app, 150, ageMs: AppState.liveHrMaxAge.inMilliseconds + 1000);
        tick.fire();
        expect(w.currentHr, isNull);
        expect(w.zoneSeconds.reduce((a, b) => a + b), billed);
        expect(w.maxHrSeen, peak);
        await finish(app);
      });
    });

    test('a disconnected band bills nothing however fresh the value looks',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-disc');
        setLiveHr(app, 150);
        app.device.connection = 'disconnected';
        tick.fire();
        expect(app.activeWorkout!.currentHr, isNull);
        expect(app.activeWorkout!.zoneSeconds.every((s) => s == 0), isTrue);
        await finish(app);
      });
    });

    test('with the anchors on file billed ticks cost kcal and '
        'strain; with no heart rate ever, both stay absent (not 0)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-kcal');
        // Strain is priced on the user's own quiet-waking level: three days
        // on file, and the anchor refresh awaited so the live session has it.
        for (var d = 1; d <= 3; d++) {
          await LocalDb.putMetricSeriesValue('2020-01-0$d', 'quiet_hrr', 0.20);
        }
        await app.debugRefreshNightlyRhr();
        final w = app.activeWorkout!;
        tick.fire();
        expect(w.caloriesOrNull, isNull);
        expect(w.strain, isNull);
        setLiveHr(app, 150);
        for (var i = 0; i < 120; i++) {
          tick.fire();
        }
        expect(w.caloriesOrNull, isNotNull);
        // Two seconds' worth of wall clock billed: a real (tiny) kcal figure
        // that rounds to 0 on the gauge - scored, which is not the same as
        // absent.
        expect(w.calories, greaterThan(0));
        expect(w.caloriesOrNull, 0);
        expect(w.strain, isNotNull);
        await finish(app);
      });
    });
  });

  group('the Live Activity push', () {
    test('the first tick with a reading pushes once, with the session\'s '
        'numbers; the next within 4 s does not', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-la');
        expect(spies.liveActivityMethods, ['start']);
        setLiveHr(app, 150);
        tick.fire();
        await until(() => spies.liveActivity.length >= 2);
        expect(spies.liveActivityMethods, ['start', 'update']);
        final args = spies.liveActivity.last.args as Map;
        expect(args['hr'], 150);
        expect(args['zone'], app.liveZone);
        expect(args['maxHr'], app.activeWorkout!.hrMax!.round());
        expect(args['rhr'], 55);
        tick.fire();
        tick.fire();
        await settleMs(50);
        expect(spies.liveActivityMethods, ['start', 'update'],
            reason: 'throttled to one push per 4 s');
        await finish(app);
      });
    });

    test('a tick with no reading never pushes (no fabricated 0 bpm)',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-la-none');
        setLiveHr(app, null);
        tick.fire();
        tick.fire();
        await settleMs(50);
        expect(spies.liveActivityMethods, ['start']);
        await finish(app);
      });
    });

    test('an unscored session pushes null strain and kcal, and rhr falls '
        'back to the display default 60', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) =
            await started(probe, 'w4-la-bare', profile: false);
        setLiveHr(app, 120);
        tick.fire();
        await until(() => spies.liveActivity.length >= 2);
        final args = spies.liveActivity.last.args as Map;
        expect(args['strain'], isNull);
        expect(args['calories'], isNull);
        expect(args['maxHr'], 0, reason: '0 = no ceiling');
        expect(args['rhr'], 60);
        await finish(app);
      });
    });
  });

  group('the tally snapshot', () {
    test('the first tick writes live_workout_tally; later ticks inside 30 s '
        'do not rewrite it', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-tally');
        expect(await LocalDb.liveWorkoutTally('w4-tally'), isNull);
        setLiveHr(app, 150);
        tick.fire();
        await tallyLanded('w4-tally');
        final row = (await LocalDb.liveWorkoutTally('w4-tally'))!;
        expect(row['workout_id'], 'w4-tally');
        expect(jsonDecode(row['zone_seconds'] as String) as List, hasLength(6));
        expect(row['per_minute_hr'], '[]',
            reason: 'completed minutes only; none is complete yet');
        expect(row['max_hr_seen'], app.activeWorkout!.maxHrSeen);
        await LocalDb.deleteLiveWorkoutTally('w4-tally');
        tick.fire();
        tick.fire();
        await settleMs(100);
        expect(await LocalDb.liveWorkoutTally('w4-tally'), isNull,
            reason: 'the throttle is 30 s');
        await finish(app);
      });
    });

    test('the 30 s throttle clock is the app\'s, not the session\'s: a '
        'session started right after another one\'s first snapshot gets none '
        'on its own first tick (today\'s behaviour)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-first');
        setLiveHr(app, 150);
        tick.fire();
        await tallyLanded('w4-first');
        expect(await LocalDb.liveWorkoutTally('w4-first'), isNotNull);
        await app.stopWorkout();
        expect(await LocalDb.liveWorkoutTally('w4-first'), isNull,
            reason: 'stop deletes the scratch row');
        app.startWorkout(workoutId: 'w4-second', type: 'strength');
        await sessionLanded('w4-second');
        final second = probe.active(kTick).single;
        second.fire();
        await settleMs(100);
        expect(await LocalDb.liveWorkoutTally('w4-second'), isNull);
        await finish(app);
      });
    });
  });

  group('the timer', () {
    test('only one tick timer ever runs: a start after a stop arms a fresh '
        '1 s timer and the old one stays cancelled', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, first) = await started(probe, 'w4-t1');
        await app.stopWorkout();
        expect(first.cancelled, isTrue);
        app.startWorkout(workoutId: 'w4-t2', type: 'strength');
        final live = probe.active(kTick);
        expect(live, hasLength(1));
        expect(identical(live.single, first), isFalse);
        await finish(app);
      });
    });

    test('debugTickWorkout is the same tick the timer runs', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-dbg');
        setLiveHr(app, 150);
        app.debugTickWorkout();
        tick.fire();
        expect(app.activeWorkout!.zoneSeconds.reduce((a, b) => a + b), 2);
        await finish(app);
      });
    });
  });

  group('a paused session (the live screen holds a draft)', () {
    test('the tick keeps the clock honest and returns before billing, '
        'pushing, snapshotting or notifying', () async {
      await Prefs.ensureLoaded();
      addTearDown(LiveDraft.clear);
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-paused');
        backdate(app, const Duration(minutes: 50));
        final w = app.activeWorkout!;
        final draft = LiveDraft.begin(activityByName('running')!)
          ..pausedSec = 20 * 60;
        setLiveHr(app, 150);
        tick.fire();
        expect(w.elapsed.inMinutes, 30, reason: 'wall time minus banked pause');
        expect(w.zoneSeconds.reduce((a, b) => a + b), 1);
        await tallyLanded('w4-paused');
        await LocalDb.deleteLiveWorkoutTally('w4-paused');
        final pushes = spies.liveActivity.length;

        draft.pausedAt = DateTime.now().subtract(const Duration(minutes: 5));
        final ticks = TickCounter(app);
        tick.fire();
        tick.fire();
        await settleMs(60);
        expect(ticks.ticks, 0, reason: 'a paused tick does not notify');
        expect(w.elapsed.inMinutes, 25,
            reason: 'the in-progress pause comes off the clock too');
        expect(w.zoneSeconds.reduce((a, b) => a + b), 1,
            reason: 'nothing is billed while paused');
        expect(w.currentHr, 150, reason: 'the held reading is left as it was');
        expect(spies.liveActivity.length, pushes);
        expect(await LocalDb.liveWorkoutTally('w4-paused'), isNull);

        draft.setPaused(false);
        tick.fire();
        expect(ticks.ticks, 1, reason: 'resuming is an ordinary tick again');
        expect(w.zoneSeconds.reduce((a, b) => a + b), 2);
        ticks.stop();
        await finish(app);
      });
    });

    test('a paused draft that is not this session\'s is cleared by a new '
        'start, so the first tick is billed', () async {
      await Prefs.ensureLoaded();
      addTearDown(LiveDraft.clear);
      LiveDraft.begin(activityByName('running')!).setPaused(true);
      final probe = TimerProbe();
      await probe.run(() async {
        final (app, tick) = await started(probe, 'w4-fresh');
        expect(LiveDraft.current, isNull);
        setLiveHr(app, 140);
        tick.fire();
        expect(app.activeWorkout!.zoneSeconds.reduce((a, b) => a + b), 1);
        await finish(app);
      });
    });
  });
}
