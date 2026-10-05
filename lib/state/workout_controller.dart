// The live-workout controller, moved out of AppState with no behaviour
// change. It owns the active workout and its lifecycle: start / stop / delete,
// the 1 Hz tick that bills heart rate into the session's tallies, the 30 s
// tally snapshot and the cold-start reconcile that resumes or finalizes an
// orphaned live row, the GPS route recorder, the Live Activity pushes, the
// display-wake hold and the compute hold the derive scheduler takes for the
// session, the zone-crossing alert state, the Health export of a finished
// session, and the live-workout step state the pedometer feeds.
// [LiveWorkoutState] lives here too; app_state.dart re-exports it.
//
// The live pedometer stays in AppState (it also feeds coverage, the stillness
// nudge and the posture check). The boundary is this: the per-workout step
// state (`_workoutRawBase`, `_workoutSawSamples`, `_workoutMinuteSteps`) is
// owned here, because start / stop / reconcile are what set and clear it, and
// the pedometer reaches it through three narrow calls ([noteWorkoutSample],
// [addWorkoutMinuteSteps], [rebaseWorkoutSteps]). The connection-lifetime raw
// total the base is read against arrives as the [liveRaw] callback.
//
// It does not own the pedometer, the resting-HR anchors, the BLE engine, the
// derive scheduler, the repository or the Health exporter; they arrive as
// callbacks (the zone-crossing buzz is the `buzz` callback). It holds no
// reference to AppState. Platform services (Live Activity, ScreenWake, the HRS
// / PMD links, GPS, the database) are static and called directly, as before.
//
// AppState.dispose cancels the tick timer through [dispose] and nothing else:
// it does not finalize a live workout, release the display hold, end the Live
// Activity or stop the route recorder. That is today's behaviour, pinned by the
// controller tests.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../ble/hrs_link.dart';
import '../ble/live_cadence.dart';
import '../ble/polar_pmd_link.dart';
import '../compute/hr_max.dart';
import '../compute/manual_session.dart' show strainFromPerMinuteHr;
import '../compute/profile.dart';
import '../data/day_label.dart';
import '../data/db.dart';
import '../data/local_repository.dart';
import '../gps/gps_source.dart';
import '../gps/route_tracker.dart';
import '../gps/route_types.dart';
import '../gps/screen_wake.dart';
import '../health/health_export.dart';
import '../live/live_activity.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/tap_router.dart';
import '../sync/edge_tracking.dart';
import '../widget/widget_service.dart';
import '../ui2/activity/live.dart' show LiveDraft;
import 'workout_idle.dart';
import 'zone_alert.dart';

class WorkoutController {
  WorkoutController({
    required Map<String, dynamic>? Function() user,
    required String? Function() linkDeviceFamily,
    required Future<void> Function() clearRadioFallbackAndReconcile,
    required void Function() nudgeLive,
    required void Function(bool active) setWorkoutActive,
    required void Function() notify,
    required void Function(String line) log,
    required int? Function() liveHr,
    required int Function() liveRaw,
    required bool Function() zoneAlertEnabled,
    required int Function() zoneAlertTargetZone,
    required Future<void> Function() refreshNightlyRhr,
    required int Function() restingHr,
    required double? Function() liveRestingHr,
    required double? Function() observedCeilingBpm,
    required List<double> Function() rhr28,
    required void Function() bumpInsights,
    required Future<void> Function() forceResync,
    required Future<void> Function({
      required int startSec,
      required int endSec,
    }) dismissSupersededSuggestions,
    required bool Function() healthSyncEnabled,
    required Future<bool> Function(Map<String, Object?> session) exportToHealth,
    required Future<void> Function() buzz,
    required LocalRepository? Function() repo,
    required bool Function() hostDisposed,
  })  : _user = user,
        _linkDeviceFamily = linkDeviceFamily,
        _clearRadioFallbackAndReconcile = clearRadioFallbackAndReconcile,
        _nudgeLive = nudgeLive,
        _setWorkoutActive = setWorkoutActive,
        _notify = notify,
        _log = log,
        _liveHr = liveHr,
        _liveRaw = liveRaw,
        _zoneAlertEnabled = zoneAlertEnabled,
        _zoneAlertTargetZone = zoneAlertTargetZone,
        _refreshNightlyRhr = refreshNightlyRhr,
        _restingHr = restingHr,
        _liveRestingHr = liveRestingHr,
        _observedCeilingBpm = observedCeilingBpm,
        _rhr28 = rhr28,
        _bumpInsights = bumpInsights,
        _forceResync = forceResync,
        _dismissSupersededSuggestions = dismissSupersededSuggestions,
        _healthSyncEnabled = healthSyncEnabled,
        _exportToHealth = exportToHealth,
        _buzz = buzz,
        _repo = repo,
        _hostDisposed = hostDisposed;

  final Map<String, dynamic>? Function() _user;
  final String? Function() _linkDeviceFamily;
  final Future<void> Function() _clearRadioFallbackAndReconcile;
  final void Function() _nudgeLive;

  // The derive scheduler's compute hold for the session (see
  // DeriveScheduler.setWorkoutActive).
  final void Function(bool active) _setWorkoutActive;
  final void Function() _notify;
  final void Function(String line) _log;

  // The live heart rate, freshness-gated by the host ([AppState.liveHr]).
  final int? Function() _liveHr;

  // The pedometer's connection-lifetime raw step total.
  final int Function() _liveRaw;
  final bool Function() _zoneAlertEnabled;
  final int Function() _zoneAlertTargetZone;

  // The resting-HR anchors stay with the host (init reads them too): the
  // refresh, the display fallback, the scoring anchor, and the two TS-03
  // zone anchors.
  final Future<void> Function() _refreshNightlyRhr;
  final int Function() _restingHr;
  final double? Function() _liveRestingHr;
  final double? Function() _observedCeilingBpm;
  final List<double> Function() _rhr28;
  final void Function() _bumpInsights;
  final Future<void> Function() _forceResync;
  final Future<void> Function({required int startSec, required int endSec})
      _dismissSupersededSuggestions;
  final bool Function() _healthSyncEnabled;
  final Future<bool> Function(Map<String, Object?> session) _exportToHealth;
  final Future<void> Function() _buzz;
  final LocalRepository? Function() _repo;
  final bool Function() _hostDisposed;

  // Per-minute RAW step counts for the ACTIVE workout only, for
  // [sessionCadenceSpm]. Bounded at 12 h of minutes; a session longer than that
  // has enough gait-like minutes for the median already.
  final List<int> _workoutMinuteSteps = [];

  // Snapshot of the RAW session total at the moment a manual workout started, so
  // the live-session screen shows steps FOR THIS WORKOUT (not since connection).
  int? _workoutRawBase;

  /// The debounced HR-zone-crossing watch for the active session, or null
  /// when [zoneAlertEnabled] was off at start (or the session has none —
  /// same "session-scoped, reset on both teardown paths" shape as
  /// [_workoutRawBase] above, rather than living on [LiveWorkoutState] itself,
  /// so arming it needs no change to that class's constructor.
  ZoneCrossingAlert? _zoneAlert;

  /// Whether ANY gait-capable accel sample has reached us since the active
  /// workout began, so [workoutStepsMeasured] can tell "did not move" apart
  /// from "the band never sent anything to count".
  ///
  /// Deliberately a latch and NOT a comparison against `_liveSamples`:
  /// `_resetLivePedometer()` zeroes that counter on every (re)connect, and it
  /// runs mid-workout. A counter comparison therefore went permanently
  /// "unmeasured" after the first reconnect — steps stuck on a dash for the
  /// rest of the workout and `stopWorkout` banking none — which is the same
  /// trap `_resetLivePedometer` already sidesteps for `_workoutRawBase` by
  /// rebasing it negative rather than dropping it.
  bool _workoutSawSamples = false;

  /// Phone-clock time of the last gait accel frame for the active workout.
  /// Unlike `_liveLastIngestMs` it survives `_resetLivePedometer()`, so a
  /// reconnect gap is still seen as a gap.
  int? _workoutLastGaitMs;

  /// The workout's accel stream went quiet for longer than
  /// [_kWorkoutImuGapMs] at some point (screen locked, link dropped, process
  /// relaunched). The count then covers only part of the session and is not
  /// its total — see [workoutStepsMeasured].
  bool _workoutStepsGap = false;

  /// Far above the frame cadence (1-10 frames/s) and above a brief glance at
  /// the lock screen; anything longer is time the pedometer did not see.
  static const int _kWorkoutImuGapMs = 30000;

  // ── live session coach ───────────────────────────────────────────────────────
  LiveWorkoutState? activeWorkout;
  Timer? _workoutTimer;

  // GPS route tracking for the active run/ride/walk (on-device only). Null when
  // no session is live or the type isn't route-eligible / permission denied.
  RouteTracker? _routeTracker;
  RouteTracker? get routeTracker => _routeTracker;
  // A hike is a walk that goes somewhere, so it records a route like one.
  // Ski and snowboard are deliberately NOT here despite being outdoors: the
  // route screen's hero numbers are distance and pace, and pace down a
  // lift-served descent is not the same claim as pace on a walk — it would
  // read as a performance figure while measuring gravity.

  DateTime _lastLaPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// Last time this session's tallies were snapshotted to
  /// `live_workout_tally` — see [_persistLiveWorkoutTally]. Throttled the same
  /// way [_lastLaPush] is; a snapshot every tick would be a write per second
  /// for the whole workout for no benefit over one every 30s.
  DateTime _lastTallyPersist = DateTime.fromMillisecondsSinceEpoch(0);

  /// The most recently DISPATCHED (possibly still in-flight) tally save.
  /// stopWorkout/_cancelActiveWorkoutTeardown await this before deleting the
  /// row: a save dispatched by one tick and a delete issued moments later by
  /// a stop/cancel race independently, and without this a save that was
  /// still in flight when the delete ran could land AFTER it and resurrect a
  /// row for a workout that has already finished — leaking a stale tally
  /// onto a future session that reuses the id (CodeRabbit/Sourcery-flagged).
  Future<void>? _pendingTallyPersist;

  // `_maxHr` (220 − age, silently substituting age 30 → a flat 190 for every
  // user who skipped the field) and the public `maxHr` that wrapped it are
  // GONE (TS-03a). The live session now carries its own ceiling, resolved once
  // at start from the athlete's age AND the strap that is measuring it
  // ([LiveWorkoutState.hrMax]) — the same `estimatedMaxHr` the day pipeline and
  // the session re-score band on, so the live gauge, the persisted `zone_min`
  // and the detail screen's recomputed `zone_bands` can no longer disagree.
  // `maxHr` had no readers left at all; its doc still claimed the route map
  // used it, and the route map takes its ceiling from the session.

  /// Why route tracking is NOT running for the current route-eligible workout
  /// (null = no issue / tracking active). Drives the live screen's "Location
  /// off" affordance instead of silently skipping the map.
  GpsPermissionStatus? routeLocationIssue;

  /// HR → zone 0..5, through THE app's zone set ([trainingZones]).
  ///
  /// The set is the LIVE SESSION's, not the profile's: it is fixed at start
  /// from the age, the strap actually measuring, the observed ceiling and the
  /// measured resting HR. 0 is the honest answer when there is no set at all
  /// (no age, or an uncalibrated/unstamped band) — which lands every second in
  /// Z0 and persists an empty `zone_min`, rather than banding the whole workout
  /// against a stranger's 190 bpm.
  int _zoneFor(int hr) {
    final set = activeWorkout?.zoneSet;
    if (hr <= 0 || set == null) return 0;
    return set.zoneNumber(hr.toDouble());
  }

  /// The zone the live session is in right now, 1..5, or null at rest / with
  /// no session. Exposed so the live screens read the ONE zone table instead
  /// of keeping a second copy of the thresholds — which is how two screens
  /// end up disagreeing about the same heartbeat.
  int? get liveZone {
    final z = _zoneFor(activeWorkout?.currentHr ?? 0);
    return z == 0 ? null : z;
  }

  /// Distance the live route recorder has measured, km. Null when no route is
  /// being recorded — which is not the same as zero.
  double? get liveDistanceKm {
    final rt = _routeTracker;
    return rt == null ? null : rt.distanceMeters.value / 1000;
  }

  /// Whether a route recorder is actually running and taking fixes — as
  /// opposed to the activity merely being one that deserves a route.
  bool get routeTracking => _routeTracker?.isRunning ?? false;

  /// Steps for the active workout, or NULL when nothing gait-capable was ever
  /// measured for it (issue #183).
  ///
  /// The live count needs the band's 100 Hz accel stream. That stream is
  /// routinely absent even during a perfectly good workout: the sticky
  /// standard-HR fallback suppresses it, the background downgrade turns it off,
  /// and a pocketed phone can drop it entirely — while GPS distance and the
  /// 1 Hz HR keep flowing. Reporting `0` in that state is a fabricated
  /// measurement, and it is what the issue screenshotted: a mile walked, HR and
  /// distance both right, "0 STEPS" beside them.
  int? get workoutStepsMeasured =>
      _workoutStepsMeasuredAt(DateTime.now().millisecondsSinceEpoch);

  /// [workoutStepsMeasured] with coverage judged as of [nowMs], so
  /// [stopWorkout] can judge it at the moment of stop rather than after the
  /// route/sensor teardown it awaits.
  int? _workoutStepsMeasuredAt(int nowMs) {
    if (activeWorkout == null || _workoutRawBase == null) return null;
    // Nothing gait-capable has arrived for this workout — unmeasured, as
    // opposed to zero steps having been measured.
    if (!_workoutSawSamples) return null;
    // Partial coverage is not a total: backgrounding a gait workout turns the
    // IMU off (see [_liveOwners]) while HR and GPS keep going, so 2 counted
    // minutes of a 40-minute walk would otherwise bank as the walk's steps.
    final last = _workoutLastGaitMs;
    if (_workoutStepsGap ||
        (last != null &&
            nowMs - last > _kWorkoutImuGapMs)) {
      return null;
    }
    final raw = _liveRaw() - _workoutRawBase!;
    return raw > 0 ? (raw * ana.StepParams.gain).round() : 0;
  }

  /// A gait-capable accel sample reached the pedometer while a workout is
  /// active (see [_workoutSawSamples]).
  void noteWorkoutSample(int ingestMs) {
    final w = activeWorkout;
    if (w == null) return;
    // Survives `_resetLivePedometer()` — see [_workoutSawSamples].
    _workoutSawSamples = true;
    // The first frame is measured against the start, so a stream that
    // only came up minutes in is a gap too, not full coverage.
    final last = _workoutLastGaitMs ?? w.startTime.millisecondsSinceEpoch;
    if (ingestMs - last > _kWorkoutImuGapMs) {
      _workoutStepsGap = true;
    }
    _workoutLastGaitMs = ingestMs;
  }

  /// A completed 60 s pedometer chunk's step count, banked for the session's
  /// cadence. Workout-scoped: dropped when no workout is active.
  void addWorkoutMinuteSteps(int minuteSteps) {
    if (activeWorkout != null && _workoutMinuteSteps.length < 720) {
      _workoutMinuteSteps.add(minuteSteps);
    }
  }

  /// The pedometer's raw counter is about to be zeroed (a fresh connected
  /// session). If a workout is active, `_workoutRawBase` was snapshotted from a
  /// *previous* (now-stale) raw total — left untouched, [workoutStepsMeasured]
  /// would compute a negative delta on the next BLE disconnect/reconnect blip,
  /// clamp to 0, and visibly reset the walk's step count instead of counting
  /// monotonically. Rebase it here so the already-accrued workout steps carry
  /// through the reset. Call BEFORE the counter is zeroed.
  void rebaseWorkoutSteps() {
    if (activeWorkout != null && _workoutRawBase != null) {
      final accruedRaw = _liveRaw() - _workoutRawBase!;
      _workoutRawBase = accruedRaw > 0 ? -accruedRaw : 0;
    }
  }

  void startWorkout({
    double targetKcal = 300,
    String? workoutId,
    String type = 'other',
  }) {
    if (activeWorkout != null) return;
    // A new session owns no draft yet. One left in Prefs belongs to a session
    // that ended without clearing it (finalized as stale on relaunch), and its
    // pause would hold this session's clock. Setup opens the fresh one after.
    LiveDraft.clear();
    final start = DateTime.now();
    final id = workoutId ?? 'w${start.millisecondsSinceEpoch}';
    _workoutRawBase = _liveRaw();
    _workoutSawSamples = false;
    _workoutLastGaitMs = null;
    _workoutStepsGap = false;
    _workoutMinuteSteps.clear();
    _zoneAlert = _zoneAlertEnabled()
        ? ZoneCrossingAlert(targetZone: _zoneAlertTargetZone())
        : null;
    // A first night may have been derived since init. This read finishes
    // after the session below is constructed, so it back-fills the anchor on
    // `activeWorkout` when it lands rather than blocking the start.
    unawaited(_refreshNightlyRhr());
    // Hold heavy derivation for the session — an isolate spawn mid-ride
    // competes with GPS, the live map and the BLE drain (see
    // DeriveScheduler.setWorkoutActive).
    _setWorkoutActive(true);
    // Hold the display for EVERY live session, not just route-eligible ones.
    // Arming this from _maybeStartRouteTracking meant an indoor workout, a
    // location-denied run, and a resumed non-route session all watched the
    // screen sleep mid-set. Released unconditionally on both teardown paths.
    ScreenWake.hold('workout');
    activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: targetKcal,
      workoutId: id,
      type: type,
      age: (_user()?['age'] as num?)?.round(),
      // Score against the profile the session is performed under.
      profile: Profile.fromMap(_user()),
      // ...and against the strap performing it. Pinned at start for the same
      // reason the profile is: the link can drop mid-session, and a workout
      // that silently changed zone ceilings halfway through is worse than one
      // scored end-to-end on the band it began on. Null when nothing is
      // linked — unknown provenance, which refuses rather than assuming gen4.
      hrMax: estimatedMaxHr(
        (_user()?['age'] as num?),
        _linkDeviceFamily(),
      ),
      // TS-04 — zones are banded on the MEASURED pair when both exist. The
      // anchors are read on the same refresh that loads the nightly resting HR
      // (see [_refreshNightlyRhr]); an anchor that has not landed yet simply
      // yields the age-estimate set, which is what this session would have got
      // before TS-03 anyway.
      zoneSet: trainingZones(
        age: (_user()?['age'] as num?),
        deviceFamily: _linkDeviceFamily(),
        observedCeilingBpm: _observedCeilingBpm(),
        restingHrHistory: _rhr28(),
        manualZoneLowerBpm: manualZoneBoundsFromProfile(_user()),
      ),
      restingHr: _liveRestingHr(),
    );
    // The workout is now an owner (HR; plus IMU for a foreground gait type —
    // the live step count rides the 100 Hz stream). AFTER the assignment: the
    // engine reads the owner set synchronously on entry. A deliberate workout
    // start is an explicit user action, so it also clears the sticky
    // marginal-radio fallback that silently suppressed the IMU flood for the
    // rest of the process lifetime; the detectors re-trip if it can't hold.
    // Unconditionally: a workout may be started offline, and a fallback left
    // set would mask its IMU owner for the whole session once the band
    // reconnects. The reconcile is a no-op with no link.
    unawaited(_clearRadioFallbackAndReconcile());
    // Persist the live session (INSERT OR REPLACE — idempotent if repo already
    // inserted this id). Final stats are written on stop.
    unawaited(
      LocalDb.putSession({
        'id': id,
        'start_ts': start.millisecondsSinceEpoch ~/ 1000,
        'end_ts': null,
        'type': type,
        'status': 'live',
        'source': 'manual',
        // Which strap is measuring this workout, if one is linked right now.
        // Null when nothing is connected — unknown provenance, not gen4.
        'device_family': _linkDeviceFamily(),
        'created_at': start.millisecondsSinceEpoch,
      }),
    );
    // Never leak a previous periodic tick by overwriting the reference.
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickWorkout(),
    );
    _notify();
    _log('Live session started. Goal: ${targetKcal.round()} kcal');
    // Light up the lock screen / Dynamic Island (iOS).
    LiveActivity.start(
      startedAt: start,
      targetKcal: targetKcal.round(),
      // 0 = no ceiling, same convention `_zoneFor` uses. The widget declares
      // the field and draws nothing with it (`zone` is computed here), so this
      // is a passthrough, not a number anyone reads.
      maxHr: activeWorkout?.hrMax?.round() ?? 0,
      rhr: _restingHr(),
    );
    _lastLaPush = DateTime.fromMillisecondsSinceEpoch(0);
    // GPS route: only for run/ride/walk, and only if the user grants location.
    unawaited(_maybeStartRouteTracking(id, type));
    // A paired heart-rate sensor is armed by a workout and only by a workout —
    // the same rule GPS follows. No-op when nothing is paired.
    unawaited(HrsLink.instance.arm());
    unawaited(PolarPmdLink.instance.arm());
  }

  /// Start recording the route if the type is eligible and location permission
  /// is granted. Denial is surfaced (routeLocationIssue) — the workout still
  /// runs without a map, but the user is told why and how to fix it.
  Future<void> _maybeStartRouteTracking(String id, String type) async {
    // Lowercased for the same reason every other type lookup is: the stored
    // `type` column is free-form text and older rows carry mixed case.
    if (!typeRecordsRoute(type)) return;
    if (_routeTracker != null) return;
    routeLocationIssue = null;
    var perm = GpsPermissionStatus.error;
    try {
      perm = await GpsSource.ensurePermission();
    } catch (_) {
      perm = GpsPermissionStatus.error;
    }
    // The permission round-trip can outlive the whole AppState (a resumed
    // workout kicks this off unawaited during startup), so re-check both.
    if (_hostDisposed()) return;
    // The session may have ended while we awaited the permission dialog.
    if (activeWorkout?.workoutId != id) return;
    if (perm != GpsPermissionStatus.granted) {
      routeLocationIssue = perm;
      _log('Route tracking unavailable: ${perm.name}.');
      _notify();
      return;
    }
    final tracker = RouteTracker(
      sink: (batch) => LocalDb.appendRoutePoints(
        id,
        [for (final p in batch) p.toRow(id)],
      ),
      zoneNow: () => _zoneFor(activeWorkout?.currentHr ?? 0),
    );
    _routeTracker = tracker;
    try {
      tracker.start(GpsSource.stream());
    } catch (_) {
      _routeTracker = null;
      routeLocationIssue = GpsPermissionStatus.error;
      _notify();
      return;
    }
    // Android: retype the already-running FGS to connectedDevice|location so
    // the OS keeps delivering fixes while a route session is live.
    EdgeTracking.start(location: true);
    _notify();
    _log('Route tracking started for $type.');
  }

  /// Re-attempt route tracking after the user fixed permissions (returns from
  /// Settings). No-op unless a route-eligible session is live without a tracker.
  Future<void> retryRouteTracking() async {
    final w = activeWorkout;
    if (w == null || w.workoutId == null || _routeTracker != null) return;
    await _maybeStartRouteTracking(w.workoutId!, w.type);
  }

  /// If the Live Activity's Finish button was tapped (App Intent set the flag),
  /// stop the workout here too. Call on app resume.
  Future<void> maybeFinishFromLiveActivity() async {
    // Consume FIRST. `&&` short-circuited the consume away whenever no session
    // was live, so a Finish tapped on a Live Activity that outlived the app
    // stayed latched on disk — and then ended the NEXT workout, days later, on
    // the first resume that happened to have one running.
    final asked = await WidgetService.consumeEndSessionFlag();
    if (asked && activeWorkout != null) await stopWorkout();
  }

  /// Reconcile any session row still `status='live'` left over from a
  /// previous run — `stopWorkout()`'s finalize write never happened, almost
  /// certainly because the app was killed/crashed mid-workout. `activeWorkout`
  /// was PURELY in-memory and nothing ever restored it from this row, so after
  /// a restart the mini-player banner / live session screen (and their only
  /// "finish" control) became unreachable — the workout's sole remaining
  /// action was the detail screen's unconditional delete button ("can't stop
  /// workout, only delete"). Called once from [_init].
  ///
  /// - Recent (<= [_kMaxLiveWorkoutAgeMs] old): genuinely resumable —
  ///   rehydrate `activeWorkout` so the normal "hold to finish" flow works
  ///   again. Live per-second tallies (calories, strain, zone minutes) can't
  ///   be reconstructed from a single DB row, so they restart from zero going
  ///   forward rather than being fabricated — honest, not perfect, but no
  ///   worse than the row being permanently un-finishable otherwise.
  /// - Stale (older than the ceiling), or a malformed/second stray row:
  ///   almost certainly not something the user is still "in" — silently
  ///   finalize it (status: 'done') instead of resurfacing a days-old "still
  ///   live" banner. duration_min/calories are left unset rather than guessed
  ///   (we don't know the real end time or effort).
  static const int _kMaxLiveWorkoutAgeMs = 6 * 60 * 60 * 1000; // 6h
  Future<void> reconcileOrphanedLiveWorkout() async {
    try {
      // Called unawaited from _init(); a concurrent startWorkout() could in
      // principle already be running by the time this DB round-trip resolves
      // (CodeRabbit flagged the race). Bail rather than clobber a real,
      // just-started activeWorkout and leak its timer.
      if (activeWorkout != null) return;
      final rows = await LocalDb.liveSessions();
      // RE-CHECK AFTER THE AWAIT. This is kicked unawaited from _init(), one
      // line before `initialized = true` makes the shell interactive — so the
      // user can tap "Start workout" INSIDE this DB round-trip. The pre-await
      // guard alone let us then overwrite a genuinely live `activeWorkout` with
      // the stale row AND assign a second `_workoutTimer` over the live one:
      // the first timer became unreachable, was never cancelled, and kept
      // running _tickWorkout at 2 Hz for the rest of the session — double
      // counting calories/strain/zone-seconds against a workout the user never
      // started.
      if (activeWorkout != null) return;
      if (rows.isEmpty) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      var resumed = false;
      for (final row in rows) {
        final startSec = (row['start_ts'] as num?)?.toInt();
        final ageMs = startSec == null ? null : nowMs - startSec * 1000;
        if (!resumed && ageMs != null && ageMs >= 0 && ageMs <= _kMaxLiveWorkoutAgeMs) {
          resumed = true;
          final startMs = startSec! * 1000;
          final id = row['id'] as String? ?? 'w$startMs';
          activeWorkout = LiveWorkoutState(
            startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
            targetKcal: 300,
            workoutId: id,
            type: (row['type'] as String?) ?? 'other',
            age: (_user()?['age'] as num?)?.round(),
            profile: Profile.fromMap(_user()),
            // The same ceiling startWorkout pins. Without it the resumed
            // session's idle gate is null, and WorkoutIdleWatch then counts
            // ANY positive reading as active — a forgotten session idling at
            // resting heart rate would never be asked about after a restart,
            // the exact case the watch exists for.
            hrMax: estimatedMaxHr(
              (_user()?['age'] as num?),
              _linkDeviceFamily(),
            ),
            // Same TS-04 zone set `startWorkout` pins, missing here — without
            // it `w.zoneSet` was null for every resumed session, `_zoneFor`
            // then returns 0 for every reading regardless of HR, and the
            // Time-in-Zones bar (and now the zone-crossing alert) silently
            // tracked nothing for the rest of a resumed workout.
            zoneSet: trainingZones(
              age: (_user()?['age'] as num?),
              deviceFamily: _linkDeviceFamily(),
              observedCeilingBpm: _observedCeilingBpm(),
              restingHrHistory: _rhr28(),
              manualZoneLowerBpm: manualZoneBoundsFromProfile(_user()),
            ),
            restingHr: _liveRestingHr(),
          );
          // Restore the per-second tallies a PREVIOUS process snapshotted
          // before it was killed — without this, strain/calories/zone
          // minutes silently restarted from zero on every resumed session
          // (the reported bug). Best-effort: a missing/corrupt row just
          // means the tallies genuinely start from zero, same as before.
          try {
            final tally = await LocalDb.liveWorkoutTally(id);
            if (tally != null) {
              final minuteHr = (jsonDecode(tally['per_minute_hr'] as String)
                      as List)
                  .map((v) => (v as num?)?.toDouble())
                  .toList();
              final zoneSecondsIn = (jsonDecode(
                tally['zone_seconds'] as String,
              ) as List)
                  .map((v) => (v as num).toDouble())
                  .toList();
              final secondsByBpm = (jsonDecode(
                tally['seconds_by_bpm'] as String,
              ) as Map)
                  .map(
                    (k, v) =>
                        MapEntry(int.parse(k as String), (v as num).toDouble()),
                  );
              activeWorkout!.restoreTally(
                minuteHr: minuteHr,
                zoneSecondsIn: zoneSecondsIn,
                secondsByBpm: secondsByBpm,
                maxHrSeenIn: (tally['max_hr_seen'] as num?)?.toInt() ?? 0,
              );
              _log('[workout] restored live tallies from before the relaunch (id=$id).');
            }
          } catch (e) {
            _log('[workout] could not restore live tally for $id: $e — tallies resume from zero.');
          }
          // Without this, `workoutStepsMeasured` (gated on _workoutRawBase
          // != null) stays null for the rest of this resumed session, and
          // stopWorkout()
          // would persist 0 steps even once real pedometer data resumes
          // flowing — CodeRabbit caught this. Mirrors startWorkout()'s own
          // snapshot: steps count from zero going forward, same as
          // calories/strain/zone-minutes already (honestly) do here.
          _workoutRawBase = _liveRaw();
          _workoutSawSamples = false;
          _workoutLastGaitMs = null;
          // The steps before the relaunch are gone, so a count from here
          // would be only part of the session: it stays unmeasured rather
          // than banking as the total (see [_workoutStepsGap]).
          _workoutStepsGap = true;
          _workoutMinuteSteps.clear();
          _zoneAlert = _zoneAlertEnabled()
              ? ZoneCrossingAlert(targetZone: _zoneAlertTargetZone())
              : null;
    // A first night may have been derived since init. This read finishes
    // after the session below is constructed, so it back-fills the anchor on
    // `activeWorkout` when it lands rather than blocking the start.
    unawaited(_refreshNightlyRhr());
          // Never overwrite a live timer reference without cancelling it.
          _workoutTimer?.cancel();
          _workoutTimer = Timer.periodic(
            const Duration(seconds: 1),
            (_) => _tickWorkout(),
          );
          _log('[workout] resumed a live session still running after restart (id=$id).');
          // Re-arm GPS for the REST of the session. Without this a resumed
          // workout recorded no further route at all: the timer/calories/strain
          // all came back, the map silently never did, and the athlete only
          // found out at the finish screen. `_maybeStartRouteTracking` is a
          // no-op for non-route types and re-appends to the SAME workout_route
          // rows (`id` is unchanged), so the pre-restart part of the route is
          // kept and the gap shows honestly as a segment break.
          unawaited(_maybeStartRouteTracking(id, activeWorkout!.type));
          unawaited(HrsLink.instance.arm());
          unawaited(PolarPmdLink.instance.arm());
          _setWorkoutActive(true);
          ScreenWake.enable();
          _nudgeLive(); // a resumed workout owns its streams too
        } else {
          // A stale live row has no end_ts (it was never stopped). We don't
          // know when the workout actually ended (edge#277), so this is NEVER
          // exported to Health: [end_ts] here is fabricated, so a
          // [start,end_ts] Health workout sample would report a bogus
          // duration as real data.
          // `end_ts_fabricated` records that so `_writeOneWorkout` can skip it
          // on every later periodic export pass too, not just this call site —
          // without the flag the row looks like any other finished workout and
          // gets exported on the next drain/derive cycle regardless.
          //
          // The stamp is the LAST TALLY SNAPSHOT (written every 30 s while the
          // session ticked), not reconcile-time: a run killed at 18:40 and
          // reopened at 07:30 would otherwise span the whole night, and the
          // substrate re-score bills that night's HR as workout calories,
          // strain and zone minutes, and the suggestion sweep retires every
          // auto-detected workout inside it. No snapshot means it never
          // ticked, so there is no evidence it ran past its start.
          final nowSec = nowMs ~/ 1000;
          final startTs = (row['start_ts'] as num?)?.toInt() ?? nowSec;
          final hadRealEnd = row['end_ts'] != null;
          // Best-effort: a failed or malformed snapshot read falls back to
          // startTs rather than leaving this (and later) stale rows unfinalized.
          var lastTickSec = startTs;
          if (!hadRealEnd) {
            try {
              final updatedTs = (await LocalDb.liveWorkoutTally(
                row['id'] as String? ?? '',
              ))?['updated_ts'];
              if (updatedTs is num) lastTickSec = updatedTs.toInt() ~/ 1000;
            } catch (_) {}
          }
          final finalEndTs = (row['end_ts'] as int?) ??
              math.max(startTs, math.min(lastTickSec, nowSec));
          await LocalDb.putSession({
            ...row,
            'status': 'done',
            'end_ts': finalEndTs,
            'end_ts_fabricated': hadRealEnd ? (row['end_ts_fabricated'] ?? 0) : 1,
          });
          // Never resumed, so its tally snapshot (if any) is now orphaned.
          unawaited(LocalDb.deleteLiveWorkoutTally(row['id'] as String? ?? ''));
          await _dismissSupersededSuggestions(
            startSec: startTs,
            endSec: finalEndTs,
          );
          _log('[workout] finalized a stale live-session row from a previous run (id=${row['id']}).');
        }
      }
      if (resumed) _notify();
    } catch (e) {
      _log('[workout] reconcile orphaned live session failed: $e');
    }
  }

  Future<void> stopWorkout() async {
    if (activeWorkout == null) return;
    // Step coverage is judged at the moment of stop: the teardown awaited
    // below can take long enough to look like an accel gap that never happened.
    final stopMs = DateTime.now().millisecondsSinceEpoch;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    // Stop GPS route recording and AWAIT the buffered-tail flush before the
    // finish screen loads the route — an unawaited stop raced the navigation
    // and the finish/detail map missed the last batch of fixes.
    final rt = _routeTracker;
    _routeTracker = null;
    routeLocationIssue = null;
    if (rt != null) {
      try {
        await rt.stop();
      } catch (_) {}
      // Android: drop the FGS back to connectedDevice-only now the route ended.
      EdgeTracking.start(location: false);
    }
    // Release the display unconditionally — not inside the `rt != null` branch.
    // A session that never got a tracker (permission denied) still armed
    // nothing, but a session whose tracker was already cleared by another path
    // would otherwise leave the screen pinned awake until the app is killed.
    // AWAITED, like the route tail: an unawaited disarm races the finish screen
    // and the last buffered batch of sensor beats never reaches the database.
    await HrsLink.instance.disarm();
    await PolarPmdLink.instance.disarm();
    ScreenWake.releaseOwner('workout');
    _setWorkoutActive(false);
    final w = activeWorkout!;
    // Off the clock, not the last tick: a session finished while still paused
    // after a relaunch has never ticked, and its elapsed is still zero.
    w.elapsed = _sessionClock(w, DateTime.now());
    // Nullable for the same reason `steps` below is: an unanchored profile
    // means this session was never costed, and a 0 in the column reads as
    // "burned nothing" rather than "not measured".
    final finalKcal = w.caloriesOrNull;
    // Nullable: an unmeasured workout must leave the column unset rather than
    // bank a zero that reads as "you took no steps".
    final wSteps = _workoutStepsMeasuredAt(stopMs);
    // Measured walking cadence, or null when this session had too few gait-like
    // minutes to have one — most indoor sessions. Never 0.
    final wCadence =
        _workoutSawSamples ? sessionCadenceSpm(_workoutMinuteSteps) : null;
    // Persist the finalized session before clearing the live state. zone_min =
    // the per-zone seconds the 1 Hz tick accumulated (Z1..Z5, minutes).
    final id = w.workoutId ?? 'w${w.startTime.millisecondsSinceEpoch}';
    final zoneMin = w.zoneMinutes();
    final endTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Which strap measured this workout. `putSession` is INSERT OR REPLACE, so
    // an omitted key would blank the stamp startWorkout banked — keep that one
    // when the link has since dropped rather than downgrading a real answer to
    // "unknown".
    final bandFamily = _linkDeviceFamily() ??
        ((await LocalDb.session(id))?['device_family'] as String?);
    final sessionRow = {
      'id': id,
      'start_ts': w.startTime.millisecondsSinceEpoch ~/ 1000,
      'end_ts': endTs,
      'type': w.type,
      'status': 'done',
      'calories': finalKcal,
      'strain': w.strain,
      'max_hr': w.maxHrSeen > 0 ? w.maxHrSeen : null,
      'duration_min': w.elapsed.inMinutes,
      'zone_min_json': jsonEncode(
        zoneMin.any((v) => v > 0) ? zoneMin : const <num>[],
      ),
      if (wSteps != null && wSteps > 0) 'steps': wSteps,
      'cadence_spm': ?wCadence,
      'source': 'manual',
      'device_family': bandFamily,
      'created_at': w.startTime.millisecondsSinceEpoch,
    };
    // AWAITED, and the live state is not cleared until it lands. This was
    // fire-and-forget with `activeWorkout = null` on the next line: the
    // in-memory session is the ONLY other copy, so a failed write silently
    // destroyed the whole workout while the summary screen rendered it in full.
    // On a throw the session stays live — every teardown above is idempotent,
    // so calling stopWorkout() again is a clean retry — and the exception
    // propagates instead of being reported as a finished, saved session.
    try {
      await LocalDb.putSession(sessionRow);
      // The session is durable — tell the screens that read sessions. Without
      // this the Workout tab, which loads once and caches, showed no trace of
      // the workout you had just finished in History, "This week", "Tracked"
      // or the weekly load until the app was restarted.
      _bumpInsights();
      // The session is durable now; its scratch tally snapshot (if any) is
      // no longer needed and would otherwise be restored onto a FUTURE
      // workout that happens to reuse this id. AWAIT any save the last tick
      // already dispatched before deleting — otherwise that save can land
      // AFTER this delete and resurrect the row (Sourcery-flagged race).
      await _awaitPendingTallyPersist();
      unawaited(LocalDb.deleteLiveWorkoutTally(id));
      // Retire any auto-detected suggestion this live session covers, so it
      // doesn't keep asking "did you work out?" about a workout already saved.
      await _dismissSupersededSuggestions(
        startSec: sessionRow['start_ts'] as int,
        endSec: endTs,
      );
    } catch (e) {
      _log('[workout] could not save session $id: $e — keeping it live');
      _notify();
      rethrow;
    }
    // Session-triggered Health export (issue #130) — don't wait for the next
    // day_result/derive pass (which may not run at all if the band isn't
    // connected right now); write this workout to Apple Health/Health Connect
    // immediately. Best-effort, never throws, no-ops if sync is off.
    if (_healthSyncEnabled()) {
      unawaited(_exportToHealth(sessionRow));
    }
    activeWorkout = null;
    // The draft (and its pause) belongs to this session. Ended from the Live
    // Activity or a double-tap, a paused draft used to outlive it and freeze
    // the next session's tick.
    LiveDraft.clear();
    _workoutRawBase = null;
    _workoutSawSamples = false;
    _workoutLastGaitMs = null;
    _workoutStepsGap = false;
    _workoutMinuteSteps.clear();
    _zoneAlert = null;
    _notify();
    _log(
      finalKcal == null
          ? 'Live session ended. No calorie anchors in the profile.'
          : 'Live session ended. Burned $finalKcal kcal.',
    );
    LiveActivity.end();
    // The workout's ownership ends: a workout stopped while backgrounded used
    // to leave FULL live armed with no consumer, and the keep-alive then
    // re-armed the 100 Hz flood every 30 s until the next lifecycle transition.
    _nudgeLive();
    // A workout often rides the live feed; if the connection blipped during it, the
    // band may hold that window in flash. Pull it now over the live connection so the
    // just-finished session isn't left with a gap.
    unawaited(_forceResync());
  }

  /// Tears down the in-memory live-workout state (timer, GPS route tracker,
  /// Live Activity) WITHOUT persisting anything — unlike [stopWorkout], which
  /// finalizes and writes a completed session. Used by [deleteWorkout] below
  /// when the row being deleted happens to be the one currently live: just
  /// nulling `activeWorkout` left the timer still ticking, the route tracker
  /// still appending GPS points, and the Live Activity still showing, all
  /// against a workout id that no longer has a backing DB row.
  Future<void> _cancelActiveWorkoutTeardown() async {
    final tallyId = activeWorkout?.workoutId;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    // AWAIT any save the last tick already dispatched before deleting — see
    // the matching comment in stopWorkout.
    await _awaitPendingTallyPersist();
    if (tallyId != null) unawaited(LocalDb.deleteLiveWorkoutTally(tallyId));
    final rt = _routeTracker;
    _routeTracker = null;
    routeLocationIssue = null;
    if (rt != null) {
      try {
        await rt.stop();
      } catch (_) {}
      EdgeTracking.start(location: false);
    }
    // AWAITED, like the route tail: an unawaited disarm races the finish screen
    // and the last buffered batch of sensor beats never reaches the database.
    await HrsLink.instance.disarm();
    await PolarPmdLink.instance.disarm();
    ScreenWake.releaseOwner('workout');
    _setWorkoutActive(false);
    activeWorkout = null;
    LiveDraft.clear();
    _nudgeLive(); // the workout's stream ownership ends with it
    _workoutRawBase = null;
    _workoutSawSamples = false;
    _workoutLastGaitMs = null;
    _workoutStepsGap = false;
    _workoutMinuteSteps.clear();
    _zoneAlert = null;
    LiveActivity.end();
  }

  /// Delete a stored workout session and, if it happens to be the one
  /// currently tracked as "live", fully tear down that live state too (see
  /// [_cancelActiveWorkoutTeardown]). Previously the UI called
  /// `repo.deleteWorkout(id)` directly — that only removed the DB row, so
  /// deleting a session right after finishing it (before this in-memory
  /// state was independently cleared) could leave the app still showing
  /// "Run live" until a manual refresh/restart; and deleting a workout that
  /// was GENUINELY still live would have left its timer/route tracker/Live
  /// Activity running against a deleted id.
  ///
  /// Teardown runs BEFORE the delete: stopping the route tracker flushes its
  /// tail under this id, which would otherwise land after the delete.
  Future<void> deleteWorkout(String id) async {
    final live = activeWorkout?.workoutId == id;
    if (live) await _cancelActiveWorkoutTeardown();
    // The live session is already gone either way: a failed delete leaves its
    // row `status='live'`, which the relaunch reconcile finalizes. The UI still
    // has to hear that nothing is live any more.
    try {
      await _repo()?.deleteWorkout(id);
    } finally {
      if (live) _notify();
    }
  }

  /// Session-triggered Health export for one just-finished workout (issue
  /// #130) — for callers outside this class that write a `sessions` row
  /// directly rather than going through [stopWorkout]. See
  /// [HealthExporter.exportWorkout] for why this can't just wait for the next
  /// day export. Best-effort, never throws.
  ///
  /// This used to take the row, and its only two call sites went out with the
  /// old `lib/ui/workouts` — leaving it callerless while `logManualWorkout`
  /// paths (the coach, the log-workout sheet) exported nothing at all. Those
  /// callers hold the `workout_id` the repo hands back, not the row, and most
  /// of them have no AppState to reach for either, so the seam that matters is
  /// [HealthExporter.exportWorkoutId] and this just forwards to it.
  Future<bool> exportWorkoutToHealth(String? sessionId) =>
      HealthExporter.exportWorkoutId(sessionId);

  /// Ask about a session that has gone quiet — the [WorkoutIdleWatch] ask.
  ///
  /// Once per session EVER, belt and braces: the watch stops on
  /// [WorkoutIdleWatch.confirmFired], and the dedupeKey is claimed
  /// persistently by FiredKeyStore, so even a session resumed after a crash
  /// (same id) cannot re-fire. `confirmFired` only on a real present — a drop
  /// (quiet hours, muted reminders) releases the key and leaves the watch's
  /// retry loop running, which is what turns an overnight ask into the
  /// morning nudge instead of a loss.
  Future<void> _nudgeIdleWorkout(LiveWorkoutState w) async {
    try {
      final id = w.workoutId ?? 'w${w.startTime.millisecondsSinceEpoch}';
      final fired = await NotificationCenter.instance.emit(
        NotificationEvent(
          dedupeKey: '$id:workout_idle',
          category: NotifCategory.reminders,
          // NORMAL: the prompt sanction in classOf requires it, same as the
          // movement and detected-workout prompts.
          priority: NotifPriority.normal,
          title: 'Still working out?',
          body: 'Nothing above resting effort has been recorded for '
              '${w.idleWatch.nudgeAfter.inMinutes} minutes. If the session '
              'is over, finish it from the Workout tab.',
          date: todayLabel(),
          route: kRouteWorkoutIdle,
        ),
      );
      if (fired) {
        w.idleWatch.confirmFired();
        _log('[workout] idle nudge fired for $id');
      }
    } catch (e) {
      _log('[workout] idle nudge skipped: $e');
    }
  }

  /// Wall time since start minus every pause, the in-progress one included —
  /// the same clock the live screen's draft shows.
  Duration _sessionClock(LiveWorkoutState w, DateTime now) {
    final d = LiveDraft.current;
    final inPause = d?.pausedAt == null ? 0 : now.difference(d!.pausedAt!).inSeconds;
    final v = now.difference(w.startTime) -
        Duration(seconds: (d?.pausedSec ?? 0) + inPause);
    return v.isNegative ? Duration.zero : v;
  }

  void _tickWorkout() {
    final w = activeWorkout;
    if (w == null) return;

    // Pause is held by the live screen's draft. While paused the clock and
    // every tally (zones, strain, calories, the idle watch) hold too, so the
    // saved duration_min and the history row match the summary's clock.
    // The clock is set BEFORE the pause return: a session that comes back
    // paused after a relaunch starts at elapsed 0 and would otherwise keep it.
    final now = DateTime.now();
    w.elapsed = _sessionClock(w, now);
    final pausedAt = LiveDraft.current?.pausedAt;
    if (pausedAt != null) {
      // The quiet stretch restarts at the pause and again at resume, but a
      // pause left running is still a forgotten session: it gets asked about.
      if (w.idleWatch.onPausedTick(now, pausedAt)) {
        unawaited(_nudgeIdleWorkout(w));
      }
      return;
    }
    // [liveHr], not `device.liveHr`: a reading that is stale or arriving from a
    // band that has dropped is NOT a measurement of this second, and billing it
    // into the peak, the per-zone seconds and (through accrueHr) strain and
    // calories is how a session that ended at the trailhead came back reading
    // like an hour of zone 3. Absent stays absent — the tick simply skips.
    final hr = _liveHr();
    w.currentHr = hr;
    if (hr != null) {
      // Smooth at accrual (issue #127): a raw `> maxHrSeen` would let a 1–2 s
      // PPG spike define the session max. accrueHr feeds the rolling-median peak.
      w.accrueHr(hr);
      // Per-zone time: one tick ≈ one second in the current zone (persisted as
      // zone_min at stop — this is what feeds the Time-in-Zones bar).
      if (hr > 0) w.zoneSeconds[_zoneFor(hr)] += 1;
    }

    // HR-zone-crossing haptic (opt-in, see [zoneAlertEnabled]). Skipped
    // entirely on a null [hr] — same "absent stays absent" rule the peak and
    // zone-seconds tally above follow — rather than feeding it as zone 0: a
    // few-second link blip would otherwise read as "left the target zone"
    // and buzz twice for a connection hiccup that was never a real crossing.
    final alert = _zoneAlert;
    if (alert != null && hr != null && alert.onTick(DateTime.now(), _zoneFor(hr))) {
      unawaited(_buzz());
    }

    // Forgotten-session watch: judged against the calorie gate (null when
    // the anchors cannot define one — then only absence counts, see
    // WorkoutIdleWatch), capped at the zone-1 floor (issue #466): the calorie
    // gate is 40 % HRR, moderate intensity, so a steady 92 bpm session the
    // live bar shows as ZONE 1 was being told "nothing above resting effort".
    // Quiet means below BOTH lines — billed as rest AND shown as rest. The
    // ask is a notification, once per session; the session itself is never
    // touched — there is deliberately no auto-stop.
    //
    // The cap never goes below a quarter of the way from resting HR to the
    // calorie gate (~10 % HRR). Resting HR here is the night's LOWEST 30-min
    // mean, so sleeping HR sits a few bpm above it: a zone-1 edge at or just
    // above it (manual bounds only need >= 30 bpm) would make a session left
    // open overnight read active forever, and the nudge would never go out.
    // A wider floor (halfway) overshot a real 50 %-HRmax zone-1 edge once RHR
    // passes ~0.375 HRmax, nudging sessions the bar shows as ZONE 1.
    final wRhr = w.restingHr;
    final wMax = w.hrMax;
    final calGate = (wRhr != null && wMax != null)
        ? ana.Calories.activeGateHr(wMax, wRhr)
        : null;
    final z1Floor = w.zoneSet?.zones.first.lower;
    final idleGate = (calGate == null || z1Floor == null)
        ? calGate
        : math.max(math.min(calGate, z1Floor), wRhr! + (calGate - wRhr) / 4);
    if (w.idleWatch.onTick(DateTime.now(), hr: hr, gate: idleGate)) {
      unawaited(_nudgeIdleWorkout(w));
    }

    // Neither strain NOR calories is accrued here. `accrueHr` (called above)
    // recomputes both from the session's per-minute HR through the one shared
    // path each has — Banister -> log-squash for strain, and the published
    // Keytel/Harris-Benedict rates behind `Calories.estimateBoutCalories` for
    // kcal. So the live gauge, a manually logged session and the day's own
    // figures all mean the same thing.
    //
    // Calories used to be billed HERE, per second, from an inline copy of
    // Keytel with no activity gate and no resting floor. That copy charged the
    // full active rate at any heart rate the band reported, so the number on
    // the gauge did not survive the re-score of its own stream.
    // Push to the Live Activity at most ~every 4s (ActivityKit throttles; saves battery).
    // Skipped entirely while HR is absent: the widget's channel takes a
    // non-null int, so the only way to push "no reading" today would be to send
    // 0 bpm, which is a fabricated measurement on the lock screen. Holding the
    // last frame is the lesser wrong until `LiveActivity.update` takes `int?`.
    if (hr != null && DateTime.now().difference(_lastLaPush).inSeconds >= 4) {
      _lastLaPush = DateTime.now();
      LiveActivity.update(
        hr: hr,
        zone: _zoneFor(hr),
        // Absent stays absent. These used to be coerced to 0, so a new user
        // with no profile anchors — the case where both correctly abstain and
        // the in-app gauge shows "—" — got a confident "0 kcal" pushed to the
        // lock screen for the whole session. Unmeasured is not zero.
        strain: w.strain,
        calories: w.caloriesOrNull,
        maxHr: w.hrMax?.round() ?? 0, // 0 = no ceiling; the widget ignores it
        rhr: _restingHr(),
      );
    }
    // Snapshot the tallies so a hard-kill relaunch mid-workout can resume
    // near where it left off instead of zeroing strain/calories/zone minutes
    // — see reconcileOrphanedLiveWorkout and _persistLiveWorkoutTally.
    if (DateTime.now().difference(_lastTallyPersist).inSeconds >= 30) {
      _lastTallyPersist = DateTime.now();
      _pendingTallyPersist = _persistLiveWorkoutTally(w);
    }
    _notify();
  }

  /// Waits out a save [_tickWorkout] already dispatched, if one is still in
  /// flight, so a caller about to DELETE the tally row (stop/cancel) never
  /// races a pending write — see [_pendingTallyPersist]'s doc. A no-op when
  /// nothing is pending; swallows a save failure, which the delete that
  /// follows renders moot either way.
  Future<void> _awaitPendingTallyPersist() async {
    final pending = _pendingTallyPersist;
    _pendingTallyPersist = null;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      /* the row is about to be deleted regardless */
    }
  }

  /// Best-effort snapshot of [w]'s per-second tallies to `live_workout_tally`.
  /// Never throws into the tick loop — a failed write just means the next
  /// periodic tick tries again.
  Future<void> _persistLiveWorkoutTally(LiveWorkoutState w) async {
    final id = w.workoutId;
    if (id == null) return;
    try {
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': id,
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        // COMPLETED minutes only (`_perMinute`, not `perMinuteHrDense()`):
        // the dense getter folds in the minute still in progress, and
        // restoring that as if it were a finished 60s minute would let a
        // partial pre-kill minute outweigh a real one once strain
        // recomputes off it (Sourcery-flagged).
        'per_minute_hr': jsonEncode(w._perMinute),
        'zone_seconds': jsonEncode(w.zoneSeconds),
        'seconds_by_bpm': jsonEncode(
          w._secondsByBpm.map((k, v) => MapEntry(k.toString(), v)),
        ),
        'max_hr_seen': w.maxHrSeen,
      });
    } catch (_) {
      /* best effort — next tick retries */
    }
  }


  // Test seams. They carry no @visibleForTesting here because AppState's own
  // delegates (which keep the annotation) forward to them; only tests and those
  // delegates may use them.

  /// Run one 1 Hz tick without the timer.
  void debugTickWorkout() => _tickWorkout();

  /// Arm the 1 Hz tick timer so a test can prove [dispose] cancels it.
  void debugArmTimer() {
    _workoutTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {});
  }

  /// Cancel the tick timer. Nothing else is torn down — see the file header.
  void dispose() {
    _workoutTimer?.cancel();
    _workoutTimer = null;
  }
}

/// Active workout tracking (in-memory only).
class LiveWorkoutState {
  final DateTime startTime;
  final double targetKcal;
  final String? workoutId; // local session id (for the breakdown on finish)
  final String type; // exercise type label
  Duration elapsed = Duration.zero;

  /// Live kcal for the bout so far. Zero here is ambiguous on its own — read
  /// [caloriesOrNull] anywhere a user can see it.
  ///
  /// RECOMPUTED from the retained per-minute series on every sample, not
  /// accrued. Same reason [strain] is: [restingHr] is loaded asynchronously and
  /// can land after the session starts, and it sets the gate that decides
  /// whether a minute is billed at the active or the resting rate. An
  /// incremental tally could only ever have corrected the seconds after the
  /// anchor arrived, leaving the earlier ones scored against a guess.
  double calories = 0.0;

  /// Whether the calorie estimate has run even once this session.
  ///
  /// Separate from [Profile.hasCalorieAnchors] because "can we score this" and
  /// "did we score this" are different questions and both have a zero-shaped
  /// answer. A complete profile whose band never delivered a heart rate — the
  /// link dropped, the strap was off — accrues nothing, and reporting that as
  /// 0 kcal claims a measurement that was never taken. Strain already reports
  /// that case as absent; this makes calories agree.
  bool _caloriesScored = false;

  /// Live kcal, or null when this session cannot be costed at all — the
  /// profile lacks the anchors Keytel needs, no resting HR has arrived to set
  /// the bout gate, or no heart rate ever landed. Absent beats fabricated, and
  /// absent also beats a confident zero.
  int? get caloriesOrNull => _caloriesScored ? calories.round() : null;

  /// Re-cost the bout so far. The only writer of [calories].
  ///
  /// Uses the SAME published rates, coefficients and activity gate as
  /// `Calories.estimateBoutCalories`, which is what the substrate re-score and
  /// every manually logged session run on — so the figure on the live gauge
  /// survives its own re-score. It used to bill the raw Keytel active rate for
  /// every second the band reported a heart rate, with no gate and no resting
  /// floor, which roughly doubled the cost of warm-up, rest between sets and
  /// cool-down against what the re-score would later say about the same stream.
  ///
  /// PER SAMPLE, not per minute. [_secondsByBpm] holds how many seconds the
  /// bout spent at each whole-bpm value, so this reproduces
  /// `estimateBoutCalories`'s sample-by-sample billing exactly while staying
  /// O(distinct bpm) in memory instead of retaining every raw sample.
  ///
  /// It scored per MINUTE, off the mean of each minute, and that lost the two
  /// things the re-score gets right:
  ///
  ///   * The gate is per sample there and was per minute-mean here. A minute
  ///     that straddles the gate — 30 s at 93 and 30 s at 94 against a 93.76
  ///     gate — billed as a whole resting minute (1.19 kcal) where the
  ///     re-score bills half of it active (3.63). About 146 kcal adrift over a
  ///     zone-2 hour, in a stream that never looks unusual.
  ///   * The seconds were wrong. A completed minute billed a flat 60 s no
  ///     matter how few samples backed it, and the minute in progress billed
  ///     `_minuteCount`, a SAMPLE count used as a second count — 12 s instead
  ///     of 60 at a 5 s notify rate.
  void _scoreCalories() {
    final rhr = restingHr;
    // Local copy: a public final field does not type-promote across the guard.
    final maxHr = hrMax;
    // The re-score refuses to invent a 220/60 anchor pair, so neither does
    // this. A resting HR landing later re-scores the whole bout.
    if (!profile.hasCalorieAnchors || rhr == null || maxHr == null) {
      _caloriesScored = false;
      calories = 0.0;
      return;
    }
    // THE gate, from the one place that defines it. This used to be the
    // arithmetic inlined below, which is the third copy of it — and
    // `Calories`' own docstring says a second copy is how the day and the bout
    // came to disagree in the first place. It also got none of the anchor
    // validation: a non-finite resting HR makes the gate NaN, every
    // `bpm < gate` is then false, and EVERY sample bills at the active rate.
    // Null means the anchors cannot define a gate, and the live gauge abstains
    // exactly as the re-score does.
    final gate = ana.Calories.activeGateHr(maxHr, rhr);
    if (gate == null) {
      _caloriesScored = false;
      calories = 0.0;
      return;
    }
    if (_secondsByBpm.isEmpty && _lastSampleHr == null) {
      _caloriesScored = false;
      calories = 0.0;
      return;
    }

    final age = profile.ageYears!.toDouble();
    final weightKg = profile.weightKg!;
    final coeffs = ana.Calories.resolveCoeffs(workoutSex(profile.sex));
    // Height is not a Keytel term; it only moves the Harris-Benedict resting
    // floor. Defaulted to match `computeManualSessionStats`, so the two paths
    // cannot disagree for a profile that carries no height.
    final heightCm = profile.heightCm ?? 170.0;
    final restingRate =
        ana.Calories.restingKcalPerS(coeffs, weightKg, heightCm, age);

    var kcal = 0.0;
    void bill(int bpm, double seconds) {
      final rate = bpm < gate
          ? restingRate
          : ana.Calories.activeKcalPerS(
              coeffs,
              bpm.toDouble(),
              maxHr,
              weightKg,
              age,
            );
      kcal += rate * seconds;
    }

    _secondsByBpm.forEach(bill);
    // The newest sample has no successor yet, so its own duration is unknown.
    // `estimateBoutCalories` gives the final sample one representative second;
    // matching that is what keeps the gauge and the re-score equal at every
    // instant rather than only at the end.
    final trailing = _lastSampleHr;
    if (trailing != null) bill(trailing, 1.0);

    calories = kcal;
    _caloriesScored = true;
  }

  /// Headline 0–21 strain, or null when the profile lacks an anchor the
  /// Banister formula needs. Recomputed on every HR sample by [accrueHr] — it
  /// is NOT accrued incrementally any more. The old `strain += %HRR * 0.01`
  /// per second was uncited and uncapped: it read 25.33 where the canonical
  /// method reads 11.62 for the same hour, and passed the top of its own 0–21
  /// scale after ~50 minutes of hard work, which the gauge silently clamped.
  double? strain;

  /// The live heart rate this session is currently being scored against, or
  /// null when the band is not delivering one (dropped, or stalled — see
  /// [AppState.liveHr]). Null, not 0: a session with no reading is unmeasured,
  /// not resting, and `_zoneFor(0)` is a real answer to a question nobody asked.
  int? currentHr;
  int maxHrSeen = 0; // spike-suppressed peak live HR this session (issue #127)

  /// Rolling-median accumulator behind [maxHrSeen] — smooths the live 1 Hz HR
  /// at accrual so a transient PPG motion spike can't set the session max (or
  /// fire a spurious "new max!"). Same window + reject as the on-read recompute.
  final RollingMaxHr _hrPeak;

  /// Seconds spent in each HR zone (index 0..5 = Z0 rest .. Z5 max), tallied at
  /// 1 Hz by _tickWorkout. Z1..Z5 are persisted as `zone_min` on stop.
  final List<double> zoneSeconds = List<double>.filled(6, 0);

  /// The persisted `zone_min` payload: minutes in Z1..Z5 (index 0 = Z1 — the
  /// 5-element shape the Time-in-Zones bar parses). Z0 (rest) is excluded.
  List<double> zoneMinutes() => [
        for (var z = 1; z <= 5; z++)
          double.parse((zoneSeconds[z] / 60.0).toStringAsFixed(2)),
      ];

  /// Anchors for the live strain score. Held on the session because a workout
  /// must be scored against the profile it was performed under, not whatever
  /// the profile happens to say when the session ends.
  final Profile profile;

  /// THE HR ceiling for this session — `estimatedMaxHr(age, family)`, resolved
  /// once at start from the athlete's age and the strap measuring the window.
  /// Null when either is missing, and then strain, calories and the zone split
  /// all abstain: there is no ceiling to be a percentage of.
  ///
  /// This is the STRAIN/CALORIE anchor only. The zone split reads [zoneSet],
  /// which may be banded on a MEASURED ceiling while this stays the age
  /// estimate — see the comment there.
  final double? hrMax;

  /// THE zone set this session's per-second split is binned with (TS-04),
  /// resolved once at start from `trainingZones` — the same function the day
  /// pipeline and the detail screen's `zone_bands` use, so the live gauge, the
  /// persisted `zone_min` and the recomputed bands cannot disagree about one
  /// heartbeat.
  ///
  /// Deliberately NOT derived from [hrMax]. Once the band has observed a
  /// ceiling, zones move onto it and onto the measured resting HR; strain does
  /// not, because moving it would rewrite every strain score ever shown. Two
  /// anchors, named, beats one anchor quietly used for both.
  final ana.HeartRateZoneSet? zoneSet;

  /// Resting-HR anchor for the strain score. NOT final: the measured nightly
  /// value is loaded asynchronously, so a session can begin before it lands.
  /// [AppState._refreshNightlyRhr] back-fills it here when it arrives, and the
  /// next HR sample re-scores through it — otherwise the session would be
  /// stuck unscored for its whole duration over a read that finished a
  /// fraction of a second after it started.
  double? restingHr;

  /// Per-minute mean HR, the unit Banister TRIMP weights. Live HR arrives at
  /// 1 Hz, so it is folded into the current minute here rather than kept as
  /// thousands of raw samples.
  /// DENSE — index IS the session minute, `null` where no sample arrived.
  ///
  /// This used to be a plain `List<double>` that only grew when a minute had
  /// samples, so a band dropout from minute 10 to 20 produced a 30-entry list
  /// for a 40-minute session. The summary drawn the moment you press stop maps
  /// index to x, so it joined minute 9 straight to minute 21 and drew every
  /// later reading ten minutes early — while the SAME session reopened from
  /// History was dense (`_denseMinutes`) and showed the gap correctly.
  final List<double?> _perMinute = [];
  int _minuteBucket = -1;
  double _minuteSum = 0;
  int _minuteCount = 0;

  /// Per-minute means INCLUDING the minute still in progress, so the live
  /// gauge moves within the first minute instead of sitting at zero for 60 s.
  /// Dense: one slot per session minute, `null` for a minute nothing reached.
  List<double?> perMinuteHrDense() {
    final out = <double?>[..._perMinute];
    if (_minuteCount > 0 && _minuteBucket >= 0) {
      while (out.length <= _minuteBucket) {
        out.add(null);
      }
      out[_minuteBucket] = _minuteSum / _minuteCount;
    }
    return out;
  }

  /// The same series with the holes removed — for statistics (strain, mean),
  /// which want the readings and not the time axis.
  List<double> perMinuteHr() => [for (final v in perMinuteHrDense()) ?v];

  /// Seconds the bout has spent at each whole-bpm value — the calorie series.
  ///
  /// Deliberately NOT the per-minute means above. `estimateBoutCalories`, which
  /// the substrate re-score and every manually logged session run on, decides
  /// active-vs-resting per SAMPLE and weights each sample by the elapsed time to
  /// the next one. A per-minute mean cannot express either: it collapses a
  /// minute that straddles the activity gate onto one side of it, and it has no
  /// idea how many seconds actually backed the samples in it.
  ///
  /// A histogram rather than a sample list because heart rate is a small
  /// integer — this is bounded at a couple of hundred entries for a bout of any
  /// length, while retaining raw 1 Hz samples is not.
  final Map<int, double> _secondsByBpm = {};

  /// The most recent accepted sample, still unbilled: its duration is the time
  /// until the NEXT sample, which has not arrived. Also what makes a gap in the
  /// stream bill correctly — the sample before a contact-loss gap is charged
  /// for the gap, capped, exactly as the re-score charges it.
  int? _lastSampleHr;
  double? _lastSampleSec;

  /// A stream that stops for longer than this stopped being one bout; billing
  /// the pre-gap heart rate across an hour of no data would invent the hour.
  ///
  /// Taken from the analytics constant rather than restated, because the whole
  /// point of this scoring path is that it gives up at the same instant the
  /// re-score of the same stream does. A second literal 150.0 here would agree
  /// today and diverge silently the day the published cap moved.
  static const double _gapCapS = ana.Calories.defaultMergeGapCapS;

  LiveWorkoutState({
    required this.startTime,
    required this.targetKcal,
    this.workoutId,
    this.type = 'other',
    int? age,
    this.profile = const Profile(),
    this.hrMax,
    this.zoneSet,
    this.restingHr,
  })  : _hrPeak = RollingMaxHr(age: age),
        idleWatch = WorkoutIdleWatch(startedAt: startTime);

  /// The forgotten-session watch — see [WorkoutIdleWatch]. Anchored on
  /// [startTime], which for a session the reconcile path rehydrated is the
  /// ORIGINAL start hours ago: the most forgotten a workout can be is exactly
  /// when the first tick should already be allowed to ask.
  final WorkoutIdleWatch idleWatch;

  /// Feed a live HR sample; updates the spike-suppressed [maxHrSeen], the
  /// per-minute accumulator behind strain, the per-bpm second counts behind
  /// calories, and both derived figures.
  ///
  /// A non-positive reading is off-skin, not a heart rate, so it is dropped —
  /// but the time it covers is NOT thrown away. It is billed to the last real
  /// sample when the next one arrives, capped at [_gapCapS], which is what
  /// `estimateBoutCalories` does with the same gap once the zeros have been
  /// filtered out of the stream it re-scores.
  void accrueHr(int hr) {
    if (hr <= 0) return;
    _hrPeak.add(hr);
    if (_hrPeak.max > maxHrSeen) maxHrSeen = _hrPeak.max;

    // Close out the previous sample: its duration is the time until this one.
    // Sub-second and out-of-order arrivals fall back to one second, matching
    // `estimateBoutCalories`'s handling of a non-positive gap.
    final nowSec = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final prevHr = _lastSampleHr;
    final prevSec = _lastSampleSec;
    if (prevHr != null && prevSec != null) {
      final gap = nowSec - prevSec;
      final dur = gap > 0 ? math.min(gap, _gapCapS) : 1.0;
      _secondsByBpm[prevHr] = (_secondsByBpm[prevHr] ?? 0) + dur;
    }
    _lastSampleHr = hr;
    _lastSampleSec = nowSec;

    // Fold into the current minute, measured from the session start so the
    // buckets are the session's own minutes rather than wall-clock ones.
    final minute = elapsed.inMinutes;
    if (minute != _minuteBucket) {
      // Close the finished bucket AT ITS OWN INDEX, padding the minutes that
      // produced nothing with null rather than skipping them.
      if (_minuteCount > 0 && _minuteBucket >= 0) {
        while (_perMinute.length <= _minuteBucket) {
          _perMinute.add(null);
        }
        _perMinute[_minuteBucket] = _minuteSum / _minuteCount;
      }
      _minuteBucket = minute;
      _minuteSum = 0;
      _minuteCount = 0;
    }
    _minuteSum += hr;
    _minuteCount++;

    // ONE strain method across the app (see strainFromPerMinuteHr). Null when
    // an anchor is missing — the gauge shows "—" rather than a number built on
    // an invented HRmax or resting HR.
    strain = strainFromPerMinuteHr(
      perMinuteHr(),
      profile: profile,
      restingHr: restingHr,
      hrMax: hrMax,
    );

    // Calories re-score off the same series, through the same estimator the
    // substrate re-score uses, so both live figures on the gauge mean the same
    // thing the finished session will.
    _scoreCalories();
  }

  /// Restore per-second tallies persisted mid-session by a PREVIOUS process,
  /// called once from `reconcileOrphanedLiveWorkout` right after a hard-kill
  /// relaunch rehydrates this session, before any new HR sample arrives.
  ///
  /// [minuteHr] must be ONLY completed minutes (`_perMinute`, never
  /// `perMinuteHrDense()` — the dense getter folds in the minute still in
  /// progress, which this would otherwise restore as if it were a full 60s
  /// minute; see `_persistLiveWorkoutTally`, the only writer of the snapshot
  /// this reads).
  ///
  /// Restores the finished-minute HR series, the zone-second tally, the
  /// calorie bpm histogram and the peak exactly — [_scoreCalories] and the
  /// strain recompute below then reproduce whatever the gauge showed at the
  /// last snapshot (up to ~30s of gap, the persist throttle). Deliberately
  /// does NOT restore [_lastSampleHr]/[_lastSampleSec] or the in-progress
  /// minute bucket: those describe a sample that is not still arriving, and
  /// resuming them would bill the entire offline gap (background, or the
  /// time the app was dead) as active minutes at the last known heart rate.
  /// The first new sample after this simply starts a fresh minute/gap, same
  /// as a real pause in the stream.
  void restoreTally({
    required List<double?> minuteHr,
    required List<double> zoneSecondsIn,
    required Map<int, double> secondsByBpm,
    required int maxHrSeenIn,
  }) {
    _perMinute
      ..clear()
      ..addAll(minuteHr);
    _minuteBucket = -1;
    _minuteSum = 0;
    _minuteCount = 0;
    for (var z = 0; z < zoneSeconds.length && z < zoneSecondsIn.length; z++) {
      zoneSeconds[z] = zoneSecondsIn[z];
    }
    _secondsByBpm
      ..clear()
      ..addAll(secondsByBpm);
    maxHrSeen = maxHrSeenIn;
    strain = strainFromPerMinuteHr(
      perMinuteHr(),
      profile: profile,
      restingHr: restingHr,
      hrMax: hrMax,
    );
    _scoreCalories();
  }
}
