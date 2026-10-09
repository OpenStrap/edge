// The public surface of the workout and breathing area on AppState: every
// member is present with its original type (the annotations are compile-time
// checks), the field-style members stay assignable, and the helper types other
// code reaches through app_state.dart are still exported from it.
//
// Public AppState members in scope (name -> kind):
//   activeWorkout            LiveWorkoutState?  mutable field (screens + tests assign)
//   startWorkout             void ({targetKcal, workoutId, type})
//   stopWorkout              Future<void>
//   deleteWorkout            Future<void> (String)
//   workoutStepsMeasured     int? getter
//   liveZone                 int? getter
//   liveDistanceKm           double? getter
//   routeTracking            bool getter
//   routeTracker             RouteTracker? getter
//   routeLocationIssue       GpsPermissionStatus? mutable field
//   retryRouteTracking       Future<void>
//   maybeFinishFromLiveActivity            Future<void>
//   maybeStopBreathingFromLiveActivity     Future<void>
//   liveStepsAbsentReason    String? getter (reads activeWorkout and the pedometer)
//   exportWorkoutToHealth    Future<bool> (String?) (forwards to HealthExporter)
//   breathingActive / breathingWindowOpen  bool mutable fields
//   breathingPattern         BreathPattern mutable field
//   breathingStartedAt / breathingTarget   DateTime? / Duration? getters
//   breathingResult          Map<String, dynamic>? mutable field
//   breathingError           String? mutable field
//   openBreathingWindow / closeBreathingWindow / startBreathingSession /
//   stopBreathingSession     Future<void>
//   breathingHistory         Future<List<Map<String, dynamic>>> ({limit})
//   buzzBreathPhase / buzzSessionComplete  void
// @visibleForTesting: debugTickWorkout, debugReconcileOrphanedLiveWorkout,
//   debugArmOwnedTimers (also arms the backfill and alarm timers),
//   debugFinalizeLivePedometer / debugFeedLiveAccel (pedometer, which stays).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/gps_source.dart';
import 'package:openstrap_edge/gps/route_tracker.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every member in the workout and breathing area is present with its '
      'original type', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final LiveWorkoutState? active = app.activeWorkout;
    final void Function({double targetKcal, String? workoutId, String type})
        start = app.startWorkout;
    final Future<void> Function() stop = app.stopWorkout;
    final Future<void> Function(String) delete = app.deleteWorkout;
    final int? steps = app.workoutStepsMeasured;
    final int? zone = app.liveZone;
    final double? km = app.liveDistanceKm;
    final bool tracking = app.routeTracking;
    final RouteTracker? tracker = app.routeTracker;
    final GpsPermissionStatus? issue = app.routeLocationIssue;
    final Future<void> Function() retry = app.retryRouteTracking;
    final Future<void> Function() finishFromLa = app.maybeFinishFromLiveActivity;
    final Future<void> Function() stopBreathFromLa =
        app.maybeStopBreathingFromLiveActivity;
    final String? absent = app.liveStepsAbsentReason;
    final Future<bool> Function(String?) export = app.exportWorkoutToHealth;
    final bool breathing = app.breathingActive;
    final bool window = app.breathingWindowOpen;
    final BreathPattern pattern = app.breathingPattern;
    final DateTime? startedAt = app.breathingStartedAt;
    final Duration? target = app.breathingTarget;
    final Map<String, dynamic>? result = app.breathingResult;
    final String? error = app.breathingError;
    final Future<void> Function() open = app.openBreathingWindow;
    final Future<void> Function() close = app.closeBreathingWindow;
    final Future<void> Function({BreathPattern? pattern, Duration? target})
        startBreathing = app.startBreathingSession;
    final Future<void> Function() stopBreathing = app.stopBreathingSession;
    final Future<List<Map<String, dynamic>>> Function({int limit}) history =
        app.breathingHistory;
    final void Function(BreathPhaseKind) phase = app.buzzBreathPhase;
    final void Function() complete = app.buzzSessionComplete;
    final void Function() tick = app.debugTickWorkout;
    final Future<void> Function() reconcile =
        app.debugReconcileOrphanedLiveWorkout;
    final void Function() arm = app.debugArmOwnedTimers;
    expect([
      start, stop, delete, retry, finishFromLa, stopBreathFromLa, export,
      open, close, startBreathing, stopBreathing, history, phase, complete,
      tick, reconcile, arm,
    ], everyElement(isNotNull));
    expect([active, steps, zone, km, tracker, issue, absent, startedAt,
      target, result, error], everyElement(isNull));
    expect([tracking, breathing, window], everyElement(isFalse));
    expect(pattern, same(kBreathPatterns.first));
  });

  test('the field-style members are assignable (screens and tests set them)',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(), targetKcal: 100, type: 'strength');
    app.activeWorkout = null;
    app.routeLocationIssue = GpsPermissionStatus.denied;
    app.routeLocationIssue = null;
    app.breathingActive = true;
    app.breathingActive = false;
    app.breathingWindowOpen = true;
    app.breathingWindowOpen = false;
    app.breathingPattern = kBreathPatterns.last;
    app.breathingResult = {'ok': true};
    app.breathingError = 'x';
    expect(app.breathingPattern, same(kBreathPatterns.last));
  });

  test('LiveWorkoutState is still reachable through app_state.dart and keeps '
      'the surface the screens and the tally restore read', () {
    final w = LiveWorkoutState(
      startTime: DateTime.now(),
      targetKcal: 250,
      workoutId: 'w4-d',
      type: 'running',
    );
    expect(w.zoneSeconds, hasLength(6));
    expect(w.maxHrSeen, 0);
    expect(w.caloriesOrNull, isNull);
    expect(w.strain, isNull);
    expect(w.currentHr, isNull);
    expect(w.elapsed, Duration.zero);
    expect(w.idleWatch, isNotNull);
    expect(w.perMinuteHr(), isEmpty);
    expect(w.zoneMinutes(), hasLength(5));
    w.restoreTally(
      minuteHr: const [100.0, 110.0],
      zoneSecondsIn: const [0, 60, 60, 0, 0, 0],
      secondsByBpm: const {100: 60, 110: 60},
      maxHrSeenIn: 111,
    );
    expect(w.maxHrSeen, 111);
    expect(w.perMinuteHr(), [100.0, 110.0]);
  });

  test('the breathing session clock is the wall clock unless a test replaces '
      'it', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    expect(app.breathingNow().difference(DateTime.now()).inSeconds.abs(),
        lessThanOrEqualTo(1));
  });
}
