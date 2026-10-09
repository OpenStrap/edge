// Lifetime of the workout / breathing state. What AppState.dispose cancels in
// this area (the 1 Hz tick, the 20 s breathing recompute), what it leaves alone
// (the live state itself, the display hold, the Live Activity, a running
// route recorder: today's behaviour, pinned so a move cannot change it by
// accident), identities, and what a dispose does to calls that arrive after it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_dispose.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await workoutDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    BleEngine.resetBandClaimForTest();
    await workoutDbTearDown(_db);
  });

  group('timers', () {
    test('dispose cancels the workout tick and the breathing recompute',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.device.connection = 'connected';
        app.startWorkout(workoutId: 'w4-z1', type: 'strength');
        await app.startBreathingSession();
        expect(probe.active(kTick), hasLength(1));
        expect(probe.active(kBreathRecompute), hasLength(1));
        await sessionLanded('w4-z1');
        app.dispose();
        expect(probe.active(kTick), isEmpty);
        expect(probe.active(kBreathRecompute), isEmpty);
        await settleMs(300);
      });
    });

    test('with nothing running dispose arms and leaves no timer of this '
        'area', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.dispose();
        expect(probe.active(kTick), isEmpty);
        expect(probe.active(kBreathRecompute), isEmpty);
      });
    });

    test('debugArmOwnedTimers arms a 1 s and a 20 s periodic, and dispose '
        'cancels both (the hook the older dispose test leans on)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.debugArmOwnedTimers();
        expect(probe.active(kTick), hasLength(1));
        expect(probe.active(kBreathRecompute), hasLength(1));
        app.dispose();
        expect(probe.active(kTick), isEmpty);
        expect(probe.active(kBreathRecompute), isEmpty);
      });
    });
  });

  group('what dispose leaves as it was (today)', () {
    test('a live workout is not finalized or cleared: the row stays live for '
        'the next launch\'s reconcile', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-z2', type: 'strength');
      await sessionLanded('w4-z2');
      app.dispose();
      expect(app.activeWorkout, isNotNull);
      await settleMs(400);
      expect((await sessionRow('w4-z2'))!['status'], 'live');
    });

    test('the display hold and the Live Activity are not released by dispose',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-z3', type: 'strength');
      await sessionLanded('w4-z3');
      app.dispose();
      await settleMs(400);
      expect(ScreenWake.owners, contains('workout'));
      expect(spies.liveActivityMethods, ['start']);
      // Test hygiene: put the statics back.
      await ScreenWake.releaseOwner('workout');
    });

    test('an active breathing session is not ended by dispose either (no '
        'Live Activity end, flags stay)', () async {
      final app = AppState.forTesting();
      app.device.connection = 'connected';
      await app.startBreathingSession();
      app.dispose();
      await settleMs(400);
      expect(app.breathingActive, isTrue);
      expect(spies.breathingMethods, ['start']);
    });
  });

  group('after dispose', () {
    test('a tick on a disposed app does not throw (notify is guarded)',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-z4', type: 'strength');
      await sessionLanded('w4-z4');
      app.dispose();
      expect(app.debugTickWorkout, returnsNormally);
      await settleMs(300);
    });

    test('a second dispose throws the framework\'s disposed-notifier error',
        () async {
      final app = AppState.forTesting();
      app.dispose();
      expect(app.dispose, throwsA(isA<FlutterError>()));
    });

    test('a breathing recompute that lands after dispose is still accepted, '
        'without notifying',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo()..gate = Completer<void>();
        final app = AppState.forTesting();
        app.device.connection = 'connected';
        app.repo = repo;
        await app.startBreathingSession();
        app.debugOnLiveFrame(0x28, hr28Frame(), 1);
        final timer = probe.active(kBreathRecompute).single;
        timer.fire();
        await settleMs(30);
        app.dispose();
        repo.gate!.complete();
        await settleMs(100);
        // The session was never ended, so the answer is accepted into the
        // field; what matters is that nothing threw on the disposed notifier.
        expect(repo.coherenceCalls, hasLength(1));
      });
    });
  });

  group('identity', () {
    test('the notifiers a workout bumps keep their identity across a whole '
        'start / stop', () async {
      final app = AppState.forTesting();
      final revision = app.insightsRevision;
      app.startWorkout(workoutId: 'w4-z5', type: 'strength');
      await app.stopWorkout();
      expect(identical(app.insightsRevision, revision), isTrue);
      expect(app.insightsRevision.value, 1);
      await settleMs(200);
      app.dispose();
    });

    test('AppState adds no listener of its own to the revision notifier '
        'during a workout, and a screen\'s add / remove balances', () async {
      final app = AppState.forTesting();
      // ignore: invalid_use_of_protected_member
      expect(app.insightsRevision.hasListeners, isFalse);
      var heard = 0;
      void on() => heard++;
      app.insightsRevision.addListener(on);
      app.startWorkout(workoutId: 'w4-z6', type: 'strength');
      await app.stopWorkout();
      expect(heard, 1);
      app.insightsRevision.removeListener(on);
      // ignore: invalid_use_of_protected_member
      expect(app.insightsRevision.hasListeners, isFalse);
      await settleMs(200);
      app.dispose();
    });
  });
}
