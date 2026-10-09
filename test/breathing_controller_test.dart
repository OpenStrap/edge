import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/breathing_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'breathing_controller.db';

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

  test('the controller owns start, stop, quiet windows, and the banked minute',
      () async {
    var clock = DateTime.utc(2026, 10, 5, 8);
    var connected = true;
    var notifications = 0;
    var reconciles = 0;
    var nudges = 0;
    var clockReads = 0;
    final buzzes = <int>[];
    final controller = BreathingController(
      isConnected: () => connected,
      repo: () => null,
      reconcileLiveStreams: () async {
        reconciles++;
      },
      nudgeLive: () {
        nudges++;
      },
      buzzPattern: (pattern) async {
        buzzes.add(pattern);
      },
      notify: () => notifications++,
      now: () {
        clockReads++;
        return clock;
      },
    );

    await controller.openBreathingWindow();
    expect(controller.breathingWindowOpen, isTrue);
    expect(reconciles, 1);

    await controller.startBreathingSession(target: const Duration(minutes: 2));
    expect(controller.breathingActive, isTrue);
    expect(controller.breathingTarget, const Duration(minutes: 2));
    expect(reconciles, 2);
    expect(spies.breathingMethods, ['start']);

    await controller.stopBreathingSession();
    expect(controller.breathingActive, isFalse);
    expect(controller.breathingWindowOpen, isTrue);
    expect(nudges, 1);
    expect(spies.breathingMethods, ['start', 'end']);

    await controller.closeBreathingWindow();
    expect(controller.breathingWindowOpen, isFalse);
    expect(nudges, 2);
    expect(notifications, 4);
    expect(clockReads, 3,
        reason: 'start reads twice and stop reads the same injected clock once');

    await controller.startBreathingSession();
    clock = clock.add(const Duration(milliseconds: 59999));
    await controller.stopBreathingSession();

    clock = clock.add(const Duration(milliseconds: 1));
    await controller.startBreathingSession();
    clock = clock.add(const Duration(seconds: 60));
    await controller.stopBreathingSession();
    await settleMs(100);
    final rows = await LocalDb.breathingSessions();
    expect(rows, hasLength(1));
    expect(rows.single['seconds'], 60);

    for (final kind in [
      BreathPhaseKind.inhale,
      BreathPhaseKind.exhale,
      BreathPhaseKind.holdIn,
      BreathPhaseKind.work,
      BreathPhaseKind.rest,
      BreathPhaseKind.holdOut,
    ]) {
      controller.buzzBreathPhase(kind);
    }
    controller.buzzSessionComplete();
    await settleMs(20);
    expect(buzzes, [1, 0, 2, 1, 0, 2, 4]);

    connected = false;
    controller.buzzBreathPhase(BreathPhaseKind.inhale);
    controller.buzzSessionComplete();
    await settleMs(20);
    expect(buzzes, [1, 0, 2, 1, 0, 2, 4]);
  });

  test('the recompute timer, Live Activity stop flag, and injected seams work',
      () async {
    final repo = BreathRepo();
    var notifications = 0;
    final controller = BreathingController(
      isConnected: () => true,
      repo: () => repo,
      reconcileLiveStreams: () async {},
      nudgeLive: () {},
      buzzPattern: (_) async {},
      notify: () => notifications++,
    );
    final probe = TimerProbe();
    await probe.run(() async {
      await controller.openBreathingWindow();
      await controller.startBreathingSession();
      controller.tapFrame(hr28Frame());
      probe.active(kBreathRecompute).single.fire();
      await until(() => repo.coherenceCalls.isNotEmpty);
      expect(controller.breathingResult, repo.result);
      expect(notifications, 3);
      spies.widgetFlags['end_breathing_session'] = true;
      await controller.maybeStopBreathingFromLiveActivity();
      expect(controller.breathingActive, isFalse);
      expect(controller.breathingWindowOpen, isFalse);
      expect(spies.widgetFlags['end_breathing_session'], false);
      expect(probe.active(kBreathRecompute), isEmpty);
    });
  });

  test('frames are gated and capped, a late result after stop is dropped, and '
      'dispose cancels the timer', () async {
    final repo = BreathRepo();
    var connected = false;
    var notifications = 0;
    final controller = BreathingController(
      isConnected: () => connected,
      repo: () => repo,
      reconcileLiveStreams: () async {},
      nudgeLive: () {},
      buzzPattern: (_) async {},
      notify: () => notifications++,
    );
    final probe = TimerProbe();
    await probe.run(() async {
      await controller.startBreathingSession();
      await controller.openBreathingWindow();
      expect(controller.breathingError, 'Connect your band first.');
      expect(controller.breathingActive, isFalse);
      expect(controller.breathingWindowOpen, isFalse);
      expect(notifications, 2);
      expect(probe.livePeriodics, isEmpty);

      connected = true;
      controller.tapFrame(hr28Frame());
      await controller.startBreathingSession();
      expect(controller.breathingError, isNull);
      for (var i = 0; i < 8100; i++) {
        controller.tapFrame(hr28Frame(i));
      }
      repo.gate = Completer<void>();
      probe.active(kBreathRecompute).single.fire();
      await until(() => repo.coherenceCalls.isNotEmpty);
      expect(repo.coherenceCalls.single.frames, hasLength(8000));
      expect(repo.coherenceCalls.single.pacedHz, controller.breathingPattern.pacedHz);

      final before = notifications;
      await controller.stopBreathingSession();
      expect(notifications, before + 1);
      repo.gate!.complete();
      await settleMs(20);
      expect(controller.breathingResult, isNull);
      expect(notifications, before + 1);

      await controller.startBreathingSession();
      expect(probe.active(kBreathRecompute), hasLength(1));
      controller.dispose();
      expect(probe.active(kBreathRecompute), isEmpty);
      expect(controller.breathingActive, isTrue);
    });
  });

  test('a result that lands after dispose is still accepted, the Live '
      'Activity hears it, and the guarded host notify swallows the tick',
      () async {
    final repo = BreathRepo();
    var hostDisposed = false;
    var notifyCalls = 0;
    var delivered = 0;
    final controller = BreathingController(
      isConnected: () => true,
      repo: () => repo,
      reconcileLiveStreams: () async {},
      nudgeLive: () {},
      buzzPattern: (_) async {},
      // The host's notify is a no-op once it is disposed, as AppState's is.
      notify: () {
        notifyCalls++;
        if (!hostDisposed) delivered++;
      },
    );
    final probe = TimerProbe();
    await probe.run(() async {
      await controller.startBreathingSession();
      controller.tapFrame(hr28Frame());
      repo.gate = Completer<void>();
      probe.active(kBreathRecompute).single.fire();
      await until(() => repo.coherenceCalls.isNotEmpty);
      expect(controller.breathingResult, isNull);

      final callsBefore = notifyCalls;
      final deliveredBefore = delivered;
      hostDisposed = true;
      controller.dispose();
      expect(probe.active(kBreathRecompute), isEmpty);
      expect(controller.breathingActive, isTrue,
          reason: 'dispose cancels the timer and nothing else');

      repo.gate!.complete();
      await until(() => controller.breathingResult != null,
          what: 'the late result being accepted');
      expect(controller.breathingResult, repo.result);
      expect(notifyCalls, callsBefore + 1,
          reason: 'the controller still asks its host to notify');
      expect(delivered, deliveredBefore,
          reason: 'the host callback is what suppresses it');
      await until(() => spies.breathingMethods.contains('update'),
          what: 'the Live Activity update');
      expect(spies.breathingMethods, ['start', 'update']);
      expect(spies.breathingActivity.last.args, {'coherenceScore': 72.0});

      await controller.stopBreathingSession();
    });
  });

  group('effect order follows the statement order the host used', () {
    late List<String> trace;
    late int reads;
    late Completer<void>? reconcileGate;
    late bool connected;
    late BreathingController controller;
    final base = DateTime.utc(2026, 10, 5, 8);

    // Each read is a minute and a second after the last, so every value is
    // distinct and a start-to-stop span is long enough to be banked.
    DateTime read(int n) => base.add(Duration(seconds: 61 * n));

    setUp(() {
      trace = [];
      reads = 0;
      reconcileGate = null;
      connected = true;
      controller = BreathingController(
        isConnected: () => connected,
        repo: () => null,
        reconcileLiveStreams: () async {
          trace.add('reconcile:begin');
          if (reconcileGate != null) await reconcileGate!.future;
          trace.add('reconcile:end');
        },
        nudgeLive: () => trace.add('nudge'),
        buzzPattern: (pattern) async => trace.add('buzz:$pattern'),
        notify: () => trace.add('notify'),
        now: () {
          reads++;
          trace.add('now:$reads');
          return read(reads);
        },
      );
    });

    test('openBreathingWindow notifies before it reconciles', () async {
      reconcileGate = Completer<void>();
      final done = controller.openBreathingWindow();
      expect(trace, ['notify', 'reconcile:begin']);
      reconcileGate!.complete();
      await done;
      expect(trace, ['notify', 'reconcile:begin', 'reconcile:end']);
    });

    test('startBreathingSession reads the clock, notifies, starts the Live '
        'Activity, then waits on reconcile before arming the timer', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        reconcileGate = Completer<void>();
        final done = controller.startBreathingSession();
        expect(trace, ['now:1', 'notify', 'now:2', 'reconcile:begin']);
        expect(controller.breathingStartedAt, read(1));
        await until(() => spies.breathingMethods.isNotEmpty,
            what: 'the Live Activity start');
        expect(spies.breathingMethods, ['start']);
        expect(spies.breathingActivity.single.args,
            containsPair('startedAtMs', read(2).millisecondsSinceEpoch),
            reason: 'the Live Activity takes its own, later clock read');
        expect(probe.active(kBreathRecompute), isEmpty,
            reason: 'the timer is armed only after reconcile completes');

        reconcileGate!.complete();
        await done;
        expect(trace.last, 'reconcile:end');
        expect(trace, hasLength(5));
        expect(probe.active(kBreathRecompute), hasLength(1));
        await controller.stopBreathingSession();
      });
    });

    test('stopBreathingSession nudges, reads the clock once, then notifies',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        await controller.startBreathingSession();
        trace.clear();
        await controller.stopBreathingSession();
        expect(trace, ['nudge', 'now:3', 'notify']);
        expect(spies.breathingMethods.last, 'end');
      });
    });

    test('stopBreathingSession with a window open holds its notify until the '
        'banked row is written', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        await controller.openBreathingWindow();
        await controller.startBreathingSession();
        trace.clear();
        final done = controller.stopBreathingSession();
        expect(trace, ['nudge', 'now:3'],
            reason: 'the insert is awaited, so notify cannot have run yet');
        await done;
        expect(trace, ['nudge', 'now:3', 'notify']);
        final rows = await LocalDb.breathingSessions();
        expect(rows, hasLength(1));
        expect(rows.single['started_at'], read(1).millisecondsSinceEpoch);
      });
    });

    test('closeBreathingWindow nudges before it notifies', () async {
      await controller.openBreathingWindow();
      trace.clear();
      await controller.closeBreathingWindow();
      expect(trace, ['nudge', 'notify']);
    });

    test('a refused start or open notifies and touches nothing else',
        () async {
      connected = false;
      await controller.startBreathingSession();
      await controller.openBreathingWindow();
      expect(trace, ['notify', 'notify']);
      expect(spies.breathingMethods, isEmpty);
    });

    test('buzzes go out in call order and never touch the clock', () async {
      controller.buzzBreathPhase(BreathPhaseKind.inhale);
      controller.buzzBreathPhase(BreathPhaseKind.holdIn);
      controller.buzzSessionComplete();
      await settleMs(20);
      expect(trace, ['buzz:1', 'buzz:2', 'buzz:4']);
    });
  });
}
