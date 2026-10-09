// The GPS route recorder a workout owns, through AppState. Which types start
// one, what a permission refusal looks like, the retry, the live distance, the
// zone colouring (a callback into the workout's current HR), the points
// persisted, and what stop / delete / dispose do to it. The location plugin is
// a channel pair answered by PlatformSpies.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart' hide test;
import 'package:flutter_test/flutter_test.dart' as ft show test;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gps/gps_source.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'app_state_workout_route.db';
const _denied = 0;
const _deniedForever = 1;

const _user = {'age': 30, 'weight_kg': 70.0, 'sex': 'male', 'resting_hr': 55};

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

  // Every test body runs with its periodic timers under a TimerProbe: the
  // workout's real 1 Hz tick would otherwise fire (and notify) whenever the
  // machine is slow enough for a test to take a second, which is a wall-clock
  // race with the exact notify counts below. Nothing here wants a tick except
  // the one test that fires it by hand.
  void test(String name, Future<void> Function() body) =>
      ft.test(name, () => TimerProbe().run(body));

  List<String> geo() => [for (final c in spies.geolocator) c.method];

  /// Wait for the route start a workout kicks off (unawaited) to finish one
  /// way or the other: a tracker listening to the position stream, or a named
  /// refusal. Never a fixed sleep: the permission round trip is a channel
  /// call and takes as long as the machine makes it take.
  Future<void> routeSettled(AppState app) async {
    await until(
        () => app.routeLocationIssue != null || app.routeTracker != null);
    if (app.routeTracker != null) await until(() => spies.geoListening);
  }

  Future<AppState> run(String id, String type) async {
    final app = AppState.forTesting();
    app.startWorkout(workoutId: id, type: type);
    await sessionLanded(id);
    await routeSettled(app);
    return app;
  }

  // The held permission question has been answered all the way through (both
  // plugin calls made), so whatever the app was going to do with the answer
  // has had its chance; a short flush then covers the microtasks after it.
  Future<void> answerLanded() async {
    await until(() => spies.geolocator.length >= 2);
    await settleMs(100);
  }

  group('which workouts record a route', () {
    test('a route type with permission starts a tracker: asks the plugin, '
        'listens to the position stream, distance reads 0 (not null)',
        () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      app.startWorkout(workoutId: 'w4-g1', type: 'running');
      await sessionLanded('w4-g1');
      await routeSettled(app);
      expect(geo(), ['isLocationServiceEnabled', 'checkPermission']);
      expect(spies.geoListens, 1);
      expect(app.routeTracking, isTrue);
      expect(app.routeTracker, isNotNull);
      expect(app.routeLocationIssue, isNull);
      expect(app.liveDistanceKm, 0.0);
      expect(app.logLines, contains('Route tracking started for running.'));
      // Two synchronous notifies of the start, one more when the tracker is up.
      expect(ticks.ticks, 3);
      ticks.stop();
      await finish(app);
    });

    test('the type match is case-insensitive', () async {
      final app = await run('w4-g2', 'Running');
      expect(app.routeTracking, isTrue);
      await finish(app);
    });

    test('a non-route type never touches the location plugin', () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      app.startWorkout(workoutId: 'w4-g3', type: 'strength');
      await sessionLanded('w4-g3');
      expect(spies.geolocator, isEmpty);
      expect(app.routeTracker, isNull);
      expect(app.liveDistanceKm, isNull, reason: 'no recorder is not zero km');
      expect(app.routeTracking, isFalse);
      expect(ticks.ticks, 2);
      ticks.stop();
      await finish(app);
    });
  });

  group('when the plugin refuses', () {
    test('services off: named, no permission asked, one extra notify',
        () async {
      spies.locationServices = false;
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      app.startWorkout(workoutId: 'w4-p1', type: 'cycling');
      await sessionLanded('w4-p1');
      await routeSettled(app);
      expect(app.routeLocationIssue, GpsPermissionStatus.serviceOff);
      expect(geo(), ['isLocationServiceEnabled']);
      expect(app.routeTracker, isNull);
      expect(ticks.ticks, 3);
      ticks.stop();
      await finish(app);
    });

    test('denied: the permission is requested, the refusal named', () async {
      spies.permission = _denied;
      final app = await run('w4-p2', 'walking');
      expect(geo(),
          ['isLocationServiceEnabled', 'checkPermission', 'requestPermission']);
      expect(app.routeLocationIssue, GpsPermissionStatus.denied);
      expect(app.routeTracking, isFalse);
      expect(app.logLines, contains('Route tracking unavailable: denied.'));
      await finish(app);
    });

    test('denied forever: named, not re-requested', () async {
      spies.permission = _deniedForever;
      final app = await run('w4-p3', 'hiking');
      expect(geo(), ['isLocationServiceEnabled', 'checkPermission']);
      expect(app.routeLocationIssue, GpsPermissionStatus.deniedForever);
      await finish(app);
    });

    test('the workout itself still runs without a map', () async {
      spies.permission = _deniedForever;
      final app = await run('w4-p4', 'running');
      expect(app.activeWorkout, isNotNull);
      await app.stopWorkout();
      expect((await sessionRow('w4-p4'))!['status'], 'done');
      expect(app.routeLocationIssue, isNull, reason: 'cleared by the stop');
      await finish(app);
    });
  });

  group('retryRouteTracking', () {
    test('after the user fixes the permission it starts the tracker, and a '
        'second retry changes nothing', () async {
      spies.permission = _deniedForever;
      final app = await run('w4-t1', 'running');
      expect(app.routeTracker, isNull);
      spies.permission = 2;
      await app.retryRouteTracking();
      expect(app.routeTracker, isNotNull);
      expect(app.routeLocationIssue, isNull, reason: 'cleared at the retry');
      final calls = spies.geolocator.length;
      final tracker = app.routeTracker;
      await app.retryRouteTracking();
      expect(identical(app.routeTracker, tracker), isTrue);
      expect(spies.geolocator.length, calls);
      await finish(app);
    });

    test('with no workout, or a non-route one, it does nothing', () async {
      final app = AppState.forTesting();
      await app.retryRouteTracking();
      expect(spies.geolocator, isEmpty);
      app.startWorkout(workoutId: 'w4-t2', type: 'strength');
      await app.retryRouteTracking();
      expect(spies.geolocator, isEmpty);
      await finish(app);
    });
  });

  group('fixes', () {
    test('distance accumulates from accepted fixes; a poor-accuracy fix is '
        'dropped', () async {
      final app = await run('w4-f1', 'running');
      spies.emitFix(51.0, 0.0);
      spies.emitFix(51.0, 0.0, accuracy: 80);
      spies.emitFix(51.001, 0.0); // ~111 m north
      // Fixes are delivered in order, so once the last one has moved the
      // distance the poor one before it has been through the filter too.
      await until(() => (app.liveDistanceKm ?? 0) > 0);
      expect(app.liveDistanceKm, closeTo(0.111, 0.005));
      expect(app.routeTracker!.pointCount, 2);
      await finish(app);
    });

    test('the route is coloured by the workout\'s current zone (a callback '
        'into the live HR), and the points are persisted when stop flushes '
        'the tail', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-f2', type: 'running');
        await sessionLanded('w4-f2');
        await routeSettled(app);
        setLiveHr(app, 160);
        probe.active(kTick).single.fire();
        final zone = app.liveZone;
        expect(zone, isNotNull);
        spies.emitFix(51.0, 0.0);
        spies.emitFix(51.001, 0.0);
        // The path is emitted at most once a second, so the second fix is not
        // in it yet; the first fix's vertex is what carries the zone.
        await until(() => app.routeTracker!.path.value.isNotEmpty);
        final vertices = app.routeTracker!.path.value;
        expect(vertices, isNotEmpty);
        expect(vertices.first.zone, zone);
        expect(await LocalDb.routePoints('w4-f2'), isEmpty,
            reason: 'two points sit in the batch buffer (batch size 8)');
        await app.stopWorkout();
        final rows = await LocalDb.routePoints('w4-f2');
        expect(rows, hasLength(2));
        expect([for (final r in rows) r['seq']], [0, 1]);
        await finish(app);
      });
    });

    test('with no zone set every vertex is zone 0 (a callback that answers '
        '0, not null)', () async {
      final app = await run('w4-f3', 'running');
      spies.emitFix(51.0, 0.0);
      await until(() => app.routeTracker!.path.value.isNotEmpty);
      expect(app.routeTracker!.path.value.single.zone, 0);
      await finish(app);
    });
  });

  group('teardown', () {
    test('stop ends the recorder: cancelled stream, dropped tracker, cleared '
        'refusal', () async {
      final app = await run('w4-d1', 'running');
      expect(spies.geoListening, isTrue);
      await app.stopWorkout();
      await until(() => spies.geoCancels > 0);
      expect(app.routeTracker, isNull);
      expect(app.routeTracking, isFalse);
      expect(app.liveDistanceKm, isNull);
      expect(spies.geoCancels, 1);
      expect(spies.geoListening, isFalse);
      await finish(app);
    });

    test('a delete-teardown ends the recorder too', () async {
      final app = await run('w4-d2', 'running');
      await app.deleteWorkout('w4-d2');
      await until(() => spies.geoCancels > 0);
      expect(app.routeTracker, isNull);
      expect(spies.geoCancels, 1);
      await finish(app);
    });

    test('a workout stopped before the permission answer lands never gets '
        'a tracker, and records no refusal', () async {
      spies.geoGate = Completer<void>();
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-d3', type: 'running');
      await sessionLanded('w4-d3');
      // The permission question is open (held at the gate) before the stop.
      await until(() => spies.geolocator.isNotEmpty);
      await app.stopWorkout();
      spies.geoGate!.complete();
      await answerLanded();
      expect(app.routeTracker, isNull);
      expect(spies.geoListens, 0);
      expect(app.routeLocationIssue, isNull);
      await finish(app);
    });

    test('a permission answer that lands after dispose is ignored: no '
        'tracker, no notify, no throw', () async {
      spies.geoGate = Completer<void>();
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-d4', type: 'running');
      await sessionLanded('w4-d4');
      await until(() => spies.geolocator.isNotEmpty);
      app.dispose();
      spies.geoGate!.complete();
      await answerLanded();
      expect(app.routeTracker, isNull);
      expect(spies.geoListens, 0);
      await settleMs(200);
    });

    test('dispose does NOT stop a running recorder (today\'s behaviour: the '
        'tracker and its position stream outlive the app object)', () async {
      final app = await run('w4-d5', 'running');
      final tracker = app.routeTracker!;
      await sessionLanded('w4-d5');
      app.dispose();
      expect(tracker.isRunning, isTrue);
      expect(spies.geoCancels, 0);
      await tracker.stop(); // the test cleans up what dispose did not
      await until(() => spies.geoCancels > 0);
      expect(spies.geoCancels, 1);
      await settleMs(200);
    });
  });
}
