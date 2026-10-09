import 'dart:async';

import '../ble/ble_state.dart' show LiveStreamOwners;
import '../ble/live_step_runs.dart' show isGaitStepType;

class LiveStreamController {
  LiveStreamController({
    required bool Function() background,
    required String? Function() activeWorkoutType,
    required bool Function() breathing,
    required Future<void> Function() reconcileLiveStreams,
  })  : _background = background,
        _activeWorkoutType = activeWorkoutType,
        _breathing = breathing,
        _reconcileLiveStreams = reconcileLiveStreams;

  final bool Function() _background;
  final String? Function() _activeWorkoutType;
  final bool Function() _breathing;
  final Future<void> Function() _reconcileLiveStreams;

  // ── live HR / IMU ownership (#287) ──────────────────────────────────────────
  //
  // A foreground connection used to be an implicit request for both the
  // realtime-HR stream and the 100 Hz IMU stream, and every feature that
  // needed one re-armed the whole bundle and tried to remember whether it was
  // the one that had turned it on. The engine now owns the streams through a
  // serialized desired-vs-applied reconciler; this side only says WHO wants
  // WHAT ([owners]) and nudges it whenever an owner changes.
  //
  // Policy (gen5; `desiredLiveStreams` in ble_state.dart):
  //   HR  ← a mounted live-HR view, any workout, a breathing session or
  //         window. iOS background is NOT an owner any more: the 1 Hz stream
  //         was held there purely to keep the suspended process schedulable
  //         (~86,400 wakes/day, most of a day's battery). The band's own
  //         HIGH_FREQ_SYNC prompt is the wake source now — see
  //         BandPromptPolicy and _refreshHighFreqWakeWindow.
  //   IMU ← a gait workout in the FOREGROUND, a bounded movement-sampling
  //         window, or the passive strap-step opt-in (off).
  //   An ordinary foreground connection owns nothing on gen5: the on-chip daily
  //   counter is the step fallback and the phone can supply windowed steps.
  //   Backgrounded with no owner is fully OFF on both platforms — on Android
  //   the EdgeTracking foreground service keeps the process alive without any
  //   inbound stream, on iOS the band's prompt wakes it; the 1 Hz stream with
  //   no consumer was ~86,400 wakes a day either way. Liveness
  //   is covered by the keep-alive's forced battery poll
  //   (kNoStreamPollSilenceSeconds) and the resume paths judge freshness by
  //   the no-stream bar. `state.wristOn`/`liveHr` simply stop updating while
  //   nothing owns HR.
  // gen4 keeps its previous behaviour: a foreground connection owns HR plus
  // the R10/R11 + IMU + optical bundle (see `LiveStreamOwners.foreground`).

  /// Screens showing the live BPM that are mounted right now.
  int _liveHrViewers = 0;

  /// A screen that displays the live heart rate is on screen: own the HR
  /// stream while it is. Pair with [releaseLiveHrView] in `dispose`.
  void retainLiveHrView() {
    _liveHrViewers++;
    nudge();
  }

  void releaseLiveHrView() {
    if (_liveHrViewers > 0) _liveHrViewers--;
    nudge();
  }

  /// A bounded movement-reminder sampling window is open (IMU-only owner).
  ///
  /// There is NO scheduler yet, and enabling the movement-reminder preference
  /// must not hold the IMU stream: sampling only inside bounded windows cannot
  /// prove that movement did not happen between them, so a standing owner
  /// would let the reminder claim an uninterrupted stillness it never
  /// observed. A separately validated scheduler that can account for the gaps
  /// is the only thing that should call this.
  void setMovementSamplingWindow(bool active) {
    if (_movementSampling == active) return;
    _movementSampling = active;
    nudge();
  }

  bool _movementSampling = false;

  /// Passive strap-step collection: OFF by default on gen5 (#287 decision 1).
  /// A future explicit opt-in requests IMU through this same owner.
  static const bool _passiveStrapSteps = false;

  LiveStreamOwners get owners {
    final workoutType = _activeWorkoutType();
    return LiveStreamOwners(
      // A route is not disposed when the app backgrounds, so a mounted
      // live-HR page must not keep the stream on behind a locked screen.
      visibleLiveHrView: !_background() && _liveHrViewers > 0,
      activeWorkout: workoutType != null,
      foregroundGaitWorkout: workoutType != null &&
          !_background() &&
          isGaitStepType(workoutType),
      breathing: _breathing(),
      movementSampling: _movementSampling,
      passiveStrapSteps: _passiveStrapSteps,
      foreground: !_background(),
    );
  }

  /// An owner input changed: let the engine converge. Fire-and-forget; the
  /// engine reads [owners] inside its own loop, and its keep-alive tick heals
  /// a nudge that was missed.
  void nudge() => unawaited(_reconcileLiveStreams());
}
