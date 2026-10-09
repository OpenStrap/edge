import 'dart:async';

import '../data/db.dart';
import '../data/local_repository.dart';
import '../live/breathing_live_activity.dart';
import '../stress/breath_phases.dart';
import '../widget/widget_service.dart';

/// Owns guided breathing sessions and their quiet windows.
class BreathingController {
  BreathingController({
    required bool Function() isConnected,
    required LocalRepository? Function() repo,
    required Future<void> Function() reconcileLiveStreams,
    required void Function() nudgeLive,
    required Future<void> Function(int pattern) buzzPattern,
    required void Function() notify,
    DateTime Function()? now,
  })  : _isConnected = isConnected,
        _repo = repo,
        _reconcileLiveStreams = reconcileLiveStreams,
        _nudgeLive = nudgeLive,
        _buzzPattern = buzzPattern,
        _notify = notify,
        breathingNow = now ?? DateTime.now;

  final bool Function() _isConnected;
  final LocalRepository? Function() _repo;
  final Future<void> Function() _reconcileLiveStreams;
  final void Function() _nudgeLive;
  final Future<void> Function(int pattern) _buzzPattern;
  final void Function() _notify;

  // ── guided-breathing cardiac coherence ──────────────────────────────────────
  // User taps "begin breathing session": enable live RR-bearing streams,
  // collect frames continuously in _breathingFrames, and periodically recompute
  // McCraty & Zayas 2014 coherence over the FULL accumulated series so far —
  // not a sliding window, so the score stabilizes as more clean data comes in
  // rather than jittering on a short recent slice. Replaces the screen's old
  // Random()-fabricated score. Ephemeral — nothing persisted.
  static const Duration _breathingRecomputeInterval = Duration(seconds: 20);
  bool breathingActive = false;

  /// The clock a breathing session is timed by. Tests only — the app never
  /// replaces it.
  DateTime Function() breathingNow;

  /// The pattern the running session is pacing to. Coherence is only computed
  /// for a pattern that claims a resonance frequency — see
  /// [BreathPattern.coherenceRated].
  BreathPattern breathingPattern = kBreathPatterns.first;

  /// When the running session started, for the persisted history row.
  DateTime? _breathingStartedAt;

  /// When the running session began, for a view that mounts mid-session.
  DateTime? get breathingStartedAt => _breathingStartedAt;

  /// What the running session was asked to run for, or null for an open one.
  Duration? get breathingTarget => _breathingTarget;

  /// What the session was SUPPOSED to run for, or null for an open one.
  ///
  /// Held because the banked duration is otherwise wall-clock: the screen's
  /// ticker is muted while the app is suspended, so a two-minute session
  /// backgrounded at 0:30 and resumed forty minutes later stopped on resume
  /// and banked a forty-minute session, with a coherence score drawn mostly
  /// from unpaced breathing. One backgrounded session would poison the trend
  /// this history exists to build.
  Duration? _breathingTarget;
  Map<String, dynamic>?
  breathingResult; // last {ok, ratio, score, peak_hz, n_beats, confidence, tier, note}
  String? breathingError;
  final List<String> _breathingFrames = [];
  Timer? _breathingRecomputeTimer;

  // The quiet windows either side of the paced block. The window brackets the
  // session so it owns the stream before pacing and after it stops. Only the
  // quiet windows are stored.

  /// True while a quiet window is capturing outside the paced block.
  bool breathingWindowOpen = false;

  /// The frames of the PRE window, taken at the moment pacing began.
  List<String>? _preWindowFrames;

  /// The banked row the windows belong to, or null when the paced block was
  /// too short to bank one (in which case the windows have nothing to attach
  /// to and are dropped).
  int? _windowRowStartedAt;

  /// Open the quiet window: HR stream on, frames buffering, no pacing yet.
  Future<void> openBreathingWindow() async {
    if (breathingWindowOpen || breathingActive) return;
    if (!_isConnected()) {
      breathingError = 'Connect your band first.';
      _notify();
      return;
    }
    breathingWindowOpen = true;
    _preWindowFrames = null;
    _windowRowStartedAt = null;
    _breathingFrames.clear();
    _notify();
    try {
      await _reconcileLiveStreams();
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
  }

  /// Close the window, measure both quiet stretches and attach them to the
  /// banked session. Safe to call when no window is open.
  Future<void> closeBreathingWindow() async {
    if (!breathingWindowOpen) return;
    breathingWindowOpen = false;
    final post = List<String>.from(_breathingFrames);
    final pre = _preWindowFrames;
    final row = _windowRowStartedAt;
    _preWindowFrames = null;
    _windowRowStartedAt = null;
    _breathingFrames.clear();
    _nudgeLive(); // the window's HR ownership ends here
    _notify();
    if (row == null || pre == null) return;
    final before = await _windowRmssd(pre);
    final after = await _windowRmssd(post);
    // Nothing readable either side is not a measurement — leave both columns
    // NULL rather than writing a row the paired test would then have to drop.
    if (before == null && after == null) return;
    try {
      await LocalDb.updateBreathingWindows(
        startedAt: row,
        preRmssd: before,
        postRmssd: after,
      );
    } catch (_) {
      /* best-effort; a lost window is one dropped pair, not a broken session */
    }
  }

  Future<double?> _windowRmssd(List<String> frames) async {
    final r = _repo();
    if (r == null || frames.isEmpty) return null;
    try {
      final res = await r.spotCheck(frames);
      return res['ok'] == true ? (res['rmssd'] as num?)?.toDouble() : null;
    } catch (_) {
      return null;
    }
  }

  /// Begin a guided-breathing session. Requires a connected band.
  Future<void> startBreathingSession({
    BreathPattern? pattern,
    Duration? target,
  }) async {
    if (breathingActive) return;
    if (!_isConnected()) {
      breathingError = 'Connect your band first.';
      _notify();
      return;
    }
    breathingPattern = pattern ?? breathingPattern;
    _breathingTarget = target;
    breathingActive = true;
    breathingResult = null;
    breathingError = null;
    if (breathingWindowOpen) {
      _preWindowFrames = List<String>.from(_breathingFrames);
    }
    _breathingFrames.clear();
    _breathingStartedAt = breathingNow();
    _notify();
    unawaited(BreathingLiveActivity.start(startedAt: breathingNow()));
    try {
      await _reconcileLiveStreams();
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer =
        Timer.periodic(_breathingRecomputeInterval, (_) {
      unawaited(_recomputeBreathingCoherence());
    });
  }

  /// End the guided-breathing session and bank it.
  ///
  /// A session shorter than a minute is NOT recorded. Opening the screen and
  /// closing it again is not a breathing session, and a history full of
  /// 4-second entries would bury the real ones.
  Future<void> stopBreathingSession() async {
    if (!breathingActive) return;
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
    breathingActive = false;
    _nudgeLive(); // the session's HR ownership ends; an open window keeps it
    unawaited(BreathingLiveActivity.end());

    final started = _breathingStartedAt;
    final target = _breathingTarget;
    _breathingStartedAt = null;
    _breathingTarget = null;
    if (started != null) {
      final ended = breathingNow();
      var seconds = ended.difference(started).inSeconds;
      // Clamped to what was asked for. Overshoot is always suspension, never
      // extra breathing — the pacer stops the moment the app leaves the
      // foreground, so any second past the target was spent doing something
      // else.
      if (target != null && seconds > target.inSeconds) {
        seconds = target.inSeconds;
      }
      if (seconds >= 60) {
        final res = breathingResult;
        final scored = res != null && res['ok'] == true;
        // Null unless the pattern is one a coherence score means something
        // for AND the estimator actually produced one.
        final rated = breathingPattern.coherenceRated && scored;
        final put = LocalDb.putBreathingSession(
          startedAt: started.millisecondsSinceEpoch,
          endedAt: ended.millisecondsSinceEpoch,
          pattern: breathingPattern.key,
          seconds: seconds,
          coherence: rated ? (res['score'] as num?)?.toDouble() : null,
          confidence: rated ? (res['confidence'] as num?)?.toDouble() : null,
        );
        if (breathingWindowOpen) {
          // AWAITED only here: the post window's UPDATE lands on this row, and
          // an UPDATE that overtakes its own INSERT writes nothing and reports
          // success. Everywhere else the insert stays off the stop path.
          _windowRowStartedAt = started.millisecondsSinceEpoch;
          await put;
        } else {
          unawaited(put);
        }
      }
    }
    if (breathingWindowOpen) _breathingFrames.clear();
    _notify();
  }

  /// Past sessions, newest first.
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) =>
      LocalDb.breathingSessions(limit: limit);

  /// Buzz the strap at a breathing or interval phase boundary.
  void buzzBreathPhase(BreathPhaseKind kind) {
    if (!_isConnected()) return;
    final pattern = switch (kind) {
      BreathPhaseKind.inhale || BreathPhaseKind.work => 1,
      BreathPhaseKind.exhale || BreathPhaseKind.rest => 0,
      BreathPhaseKind.holdIn || BreathPhaseKind.holdOut => 2,
    };
    unawaited(_buzzPattern(pattern).catchError((_) {}));
  }

  /// The whole session is over, as opposed to one phase of it.
  void buzzSessionComplete() {
    if (!_isConnected()) return;
    unawaited(_buzzPattern(4).catchError((_) {}));
  }

  Future<void> _recomputeBreathingCoherence() async {
    if (!breathingActive || _repo() == null) return;
    final frames = List<String>.from(_breathingFrames);
    if (frames.isEmpty) return;
    try {
      final res = await _repo()!.breathingCoherence(
        frames,
        pacedHz: breathingPattern.pacedHz,
      );
      if (!breathingActive) return; // session ended while we awaited
      breathingResult = res;
      _notify();
      final score = res['ok'] == true ? (res['score'] as num?)?.toDouble() : null;
      unawaited(BreathingLiveActivity.update(coherenceScore: score));
    } catch (_) {
      /* best-effort; keep the last good result on screen rather than erroring */
    }
  }

  /// Adds an R-R-bearing frame the host router accepted.
  void tapFrame(String hex) {
    if (breathingActive || breathingWindowOpen) {
      if (_breathingFrames.length < 8000) _breathingFrames.add(hex);
    }
  }

  /// Stop a breathing session requested by its Live Activity.
  Future<void> maybeStopBreathingFromLiveActivity() async {
    // Same latch, same fix as the workout Live Activity.
    final asked = await WidgetService.consumeEndBreathingFlag();
    if (!asked) return;
    if (breathingActive) await stopBreathingSession();
    // Ending from the Live Activity ends the whole thing, quiet windows
    // included — otherwise the streams stay on with no screen left to close
    // them, which is the leak `PopScope` was added to the screen to fix.
    await closeBreathingWindow();
  }

  /// Cancels the periodic recompute without ending the session.
  void dispose() {
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
  }

  void debugArmTimer() {
    _breathingRecomputeTimer ??=
        Timer.periodic(_breathingRecomputeInterval, (_) {});
  }
}
