// workout_idle.dart — PURE policy: when has an open live workout gone quiet
// for long enough that the user probably forgot to finish it?
//
// The failure this exists for: a session started and never stopped. The band
// keeps recording rest, `startWorkout` refuses every later workout while one
// is open, and the session counts as a live consumer so the full 100 Hz
// streams stay armed all night. Nothing in the app said anything — the first
// sign was Home going bare the next morning.
//
// The policy only ever ASKS. There is deliberately no auto-stop: ending a
// session writes a record only the user can vouch for, and a long stretch at
// resting heart rate is also what yin yoga, a lunch break mid-hike, or a
// phone left on the kitchen counter look like. The watch reports a measured
// quiet stretch and leaves the decision where it belongs.

/// Tracks the trailing quiet stretch of one live session and decides when to
/// ask "Still working out?".
///
/// Fed once per 1 Hz workout tick. A tick is ACTIVE when it carries a real
/// reading (positive bpm) at or above the [gate] the caller passes. The app
/// passes the calorie pipeline's `Calories.activeGateHr`, capped at the
/// zone-1 floor but never below halfway from resting HR to that gate, so
/// "quiet" means billed as rest AND shown as rest on the live zone bar. With no gate (a profile
/// without calorie anchors), intensity cannot be judged and any real reading
/// counts as active: a worn strap is never nudged on a guess, and only
/// absence — off skin, or the link gone — builds the streak.
///
/// Asking is retried: the flagship case is an evening session forgotten
/// overnight, whose first ask lands inside the default 22:00–07:00 quiet
/// window and is dropped by the notification gate. [onTick] keeps returning
/// true every [retryEvery] until the caller reports a presented notification
/// via [confirmFired] — which ends it for good: one nudge per session, ever.
class WorkoutIdleWatch {
  WorkoutIdleWatch({
    required DateTime startedAt,
    this.nudgeAfter = const Duration(minutes: 20),
    this.retryEvery = const Duration(minutes: 10),
  }) : _lastActive = startedAt;

  /// Quiet time before the first ask. Twenty minutes is long enough that
  /// rest between sets and a water stop never trigger it, and short enough
  /// that a genuinely forgotten session is asked about while the user still
  /// remembers starting it.
  final Duration nudgeAfter;

  /// Backoff between unconfirmed asks — a 1 Hz tick loop must not hammer the
  /// notification gate while quiet hours are dropping the event.
  final Duration retryEvery;

  DateTime _lastActive;
  DateTime? _lastAsk;
  bool _fired = false;

  /// When the watch last asked, or null if it never has. Read by the wiring
  /// test; the emit site keys off [onTick]'s return instead.
  DateTime? get lastAskAt => _lastAsk;

  /// Feed one tick. Returns true when the caller should try to nudge NOW.
  ///
  /// [hr] is this second's live reading (null when the band is stale or
  /// dropped — the workout tick already refuses those); [gate] is the
  /// session's activity line (see the class doc), or null when the anchors
  /// cannot define one.
  bool onTick(DateTime now, {required int? hr, required num? gate}) {
    final active = hr != null && hr > 0 && (gate == null || hr >= gate);
    if (active) {
      _lastActive = now;
      // A real bout after an ask starts a fresh story: a NEW quiet stretch
      // asks at its own threshold rather than inheriting the old backoff.
      _lastAsk = null;
      return false;
    }
    if (_fired) return false;
    if (now.difference(_lastActive) < nudgeAfter) return false;
    final ask = _lastAsk;
    if (ask != null && now.difference(ask) < retryEvery) return false;
    _lastAsk = now;
    return true;
  }

  /// The nudge actually reached the shade — stop asking, permanently. Only a
  /// PRESENTED notification confirms; a drop (quiet hours, muted category)
  /// leaves the retry loop running so the ask survives the night.
  void confirmFired() => _fired = true;
}
