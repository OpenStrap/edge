import 'dart:async';
import 'dart:io';

import '../data/db.dart';

enum DeriveJobKind { light, heavy }

/// Serializes derive work behind the capture pipeline using durable queued jobs.
///
/// While an offload is active we persist intent in `compute_jobs` and defer the
/// actual derive until capture has settled for a small window. On restart, any
/// interrupted running job is re-queued and resumed.
class DeriveScheduler {
  DeriveScheduler({
    required this.run,
    required this.log,
    required this.onChanged,
    this.lightSettle = const Duration(seconds: 8),
    this.heavySettle = const Duration(seconds: 2),
    this.workoutHoldCap = const Duration(hours: 6),
  });

  final Future<void> Function({required DeriveJobKind kind}) run;
  final void Function(String) log;
  final void Function() onChanged;
  final Duration lightSettle;
  final Duration heavySettle;

  /// Ceiling on the live-workout hold. The hold's whole justification is "a
  /// workout is minutes long and its own results are derived at the end
  /// anyway, so deferring costs nothing" — which inverts the moment the user
  /// forgets to finish the session: capture keeps landing records, every
  /// queued job stays parked, today's `day_result` is never built, and Home
  /// spends the day on "Nothing recorded for today — Sync the band" while the
  /// strap is connected and syncing fine. Past the cap the session is treated
  /// as forgotten and held work drains even though it is still live. Six
  /// hours matches `AppState._kMaxLiveWorkoutAgeMs`, the ceiling past which a
  /// live session row from a previous run is already judged "almost certainly
  /// not something the user is still in".
  final Duration workoutHoldCap;

  bool _offloadActive = false;

  /// True while a live workout is running. Held exactly like [_offloadActive].
  ///
  /// Heavy derivation spawns an isolate (roughly doubling peak heap) and hits
  /// the DB hard. Nothing used to stop that landing in the middle of a run or
  /// ride — and the existing foreground/background gate is INVERTED for this
  /// case: with the phone mounted on the bars and the screen awake the app IS
  /// foregrounded, so derives ran at their most expensive possible moment,
  /// competing with the GPS stream, the live map and the BLE drain. A workout
  /// is minutes long and its own results are derived at the end anyway, so
  /// deferring costs nothing — as long as the session actually ends; a
  /// forgotten one is bounded by [workoutHoldCap].
  bool _workoutActive = false;

  /// True once [workoutHoldCap] has elapsed on the CURRENT session's hold.
  /// Cleared on release, so the next session holds again from scratch.
  bool _workoutHoldExpired = false;
  Timer? _workoutCapTimer;

  /// The gate the drain actually checks: live workout, cap not yet blown.
  bool get _workoutHeld => _workoutActive && !_workoutHoldExpired;

  // While the app is backgrounded we must NOT run derivation: a derive pass
  // decodes the retained substrate + runs the metric compute, and doing
  // that on a short background BLE wake trips iOS's CPU watchdog
  // (cpu_resource_fatal) or memory jetsam → the app gets terminated. Capture
  // (persist + ACK) is lightweight and keeps running; the derive intent is
  // durable in compute_jobs, so it simply waits and drains on foreground
  // return. (No OS periodic scheduler backs this up — the old WorkManager
  // registration was deliberately removed, see main.dart — so on Android,
  // where the foreground service gives derivation a real budget, backgrounded
  // derives DO run; their cadence is capped by DeriveDebouncer's background
  // tier, not blocked here.) Held exactly like _offloadActive.
  bool _background = false;
  bool _running = false;
  bool _pendingLight = false;
  bool _pendingHeavy = false;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> init() async {
    await LocalDb.recoverComputeJobs();
    await _refreshSnapshot();
    _arm();
  }

  bool get offloadActive => _offloadActive;
  bool get running => _running;
  bool get pendingLight => _pendingLight;
  bool get pendingHeavy => _pendingHeavy;

  Map<String, dynamic> snapshot() => {
        'offload_active': _offloadActive,
        'workout_active': _workoutActive,
        'workout_hold_expired': _workoutHoldExpired,
        'background': _background,
        'running': _running,
        'pending_light': _pendingLight,
        'pending_heavy': _pendingHeavy,
      };

  void markStoredData() {
    unawaited(_enqueue(type: 'derive_light', reason: 'stored_data'));
  }

  void requestHeavy() {
    unawaited(_enqueue(type: 'derive_heavy', reason: 'capture_settled'));
  }

  /// Hold derivation for the duration of a live workout (see [_workoutActive]).
  /// Queued jobs stay durable and drain the moment the session ends.
  void setWorkoutActive(bool active) {
    if (_workoutActive == active) return;
    _workoutActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      _workoutCapTimer?.cancel();
      _workoutCapTimer = Timer(workoutHoldCap, () {
        _workoutHoldExpired = true;
        log('[derive-scheduler] workout still live past the hold cap — '
            'treating it as forgotten; derive may run');
        onChanged();
        _arm();
      });
      log('[derive-scheduler] workout live — holding derive work');
      onChanged();
      return;
    }
    _workoutCapTimer?.cancel();
    _workoutCapTimer = null;
    _workoutHoldExpired = false;
    log('[derive-scheduler] workout ended — derive may run');
    onChanged();
    _arm();
  }

  void setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] capture active — holding derive work');
      onChanged();
      return;
    }
    log('[derive-scheduler] capture settled — derive may run');
    onChanged();
    _arm();
  }

  /// Foreground/background gate. While backgrounded, derivation is held (heavy
  /// compute on a background BLE wake gets the app killed by the OS). Queued jobs
  /// stay durable and drain when we come back to the foreground.
  void setBackground(bool background) {
    // Only defer derivation on iOS. Android has a foreground service, so we have OS budget.
    final effectiveBackground = Platform.isIOS ? background : false;
    if (_background == effectiveBackground) return;
    _background = effectiveBackground;
    if (_background) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] backgrounded — deferring derive to foreground');
      onChanged();
      return;
    }
    log('[derive-scheduler] foregrounded — draining deferred derive work');
    onChanged();
    _arm();
  }

  // An enqueue still in its DB await when the owner is disposed would
  // otherwise arm a fresh timer and notify a dead listener.
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _workoutCapTimer?.cancel();
    _workoutCapTimer = null;
  }

  Future<void> _enqueue({
    required String type,
    required String reason,
  }) async {
    await LocalDb.enqueueDeriveJob(type: type, reason: reason);
    await _refreshSnapshot();
    _arm();
  }

  void _arm() {
    if (_disposed || _running || _offloadActive || _background || _workoutHeld) {
      return;
    }
    if (!_pendingLight && !_pendingHeavy) {
      unawaited(_refreshSnapshot());
      return;
    }
    _timer?.cancel();
    _timer = Timer(_pendingHeavy ? heavySettle : lightSettle, () {
      unawaited(_drain());
    });
    onChanged();
  }

  Future<void> _drain() async {
    if (_running || _offloadActive || _background || _workoutHeld) return;
    _timer?.cancel();
    _timer = null;
    final job = await LocalDb.takeNextComputeJob();
    if (job == null) {
      await _refreshSnapshot();
      return;
    }
    final id = job['id']?.toString();
    // RE-CHECK THE GATES AFTER ACQUISITION. The checks above happened before a
    // DB round-trip, and a workout can start (or an offload/background flip can
    // land) inside it — at which point running the pass is exactly what the
    // gate exists to prevent. The job is already marked `running` by
    // takeNextComputeJob, so hand it back rather than leaving it claimed.
    if (_offloadActive || _background || _workoutHeld) {
      if (id != null && id.isNotEmpty) {
        await LocalDb.requeueComputeJob(id);
      }
      await _refreshSnapshot();
      return;
    }
    final kind = _parseKind(job['type']?.toString());
    _running = true;
    await _refreshSnapshot();
    log('[derive-scheduler] running ${kind == DeriveJobKind.heavy ? "heavy" : "light"} pass');
    try {
      await run(kind: kind);
      if (id != null && id.isNotEmpty) {
        await LocalDb.completeComputeJob(id);
      }
    } catch (e) {
      if (id != null && id.isNotEmpty) {
        await LocalDb.failComputeJob(id, '$e');
      }
      rethrow;
    } finally {
      _running = false;
      await _refreshSnapshot();
      if (_pendingHeavy || _pendingLight) _arm();
      onChanged();
    }
  }

  DeriveJobKind _parseKind(String? type) {
    switch (type) {
      case 'derive_heavy':
        return DeriveJobKind.heavy;
      case 'derive_light':
      default:
        return DeriveJobKind.light;
    }
  }

  Future<void> _refreshSnapshot() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final jobs = await LocalDb.computeJobs(state: 'queued', limit: 50);
      _pendingLight = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_light',
      );
      _pendingHeavy = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_heavy',
      );
    } finally {
      _refreshing = false;
      onChanged();
    }
  }
}
