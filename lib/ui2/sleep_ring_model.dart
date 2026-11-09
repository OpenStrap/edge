// sleep_ring_model.dart — what the Home sleep ring says and draws, as data.
//
// PURE. No clock (the caller passes `now`), no I/O, no widgets, no l10n: the
// ring turns this into shapes and strings. Kept apart so every rule below is a
// fixed-date unit test, including the DST night.
//
import 'dart:math' as math;

/// The owner's explicit default target: 5 cycles + 30 min. Used ONLY when no
/// learned need exists, and always labelled as a default where it is shown.
const int kDefaultSleepTargetMin = 480;

/// Assumed length of one sleep cycle, until a per-user value exists.
const int kDefaultCycleLenMin = 90;

enum SleepRingPhase { slept, estimate, none }

enum SleepArcKind { deep, rem, light, awake, solid, estimate }

enum WindowStartSource { coach, learned }

enum WakeSource { alarm, learned }

/// One night's stage totals, minutes. Null means the pipeline had no figure.
class SleepStageMin {
  final int? deep, rem, light, awake;
  const SleepStageMin({this.deep, this.rem, this.light, this.awake});
}

/// One contiguous arc of the ring: [fraction] of the FULL circle.
class SleepArc {
  final SleepArcKind kind;
  final double fraction;
  const SleepArc(this.kind, this.fraction);
}

class SleepRingModel {
  final SleepRingPhase phase;
  final List<SleepArc> arcs;
  final int targetMin;
  final bool targetIsDefault;

  /// Slept: minutes asleep. Null otherwise.
  final int? asleepMin;

  /// Slept: whole percent of [targetMin]. Null otherwise.
  final int? pct;

  /// Estimate: minutes between the window start and the wake. Null otherwise.
  final int? estimateMin;

  /// Estimate: whole cycles in [estimateMin]. Null otherwise.
  final int? cycles;
  final int cycleLenMin;

  /// Estimate: the instants the estimate was measured between, and where each
  /// came from. [startSource] is null when the estimate runs from `now`.
  final DateTime? windowStart, wakeAt;
  final WindowStartSource? startSource;
  final WakeSource? wakeSource;

  const SleepRingModel({
    required this.phase,
    this.arcs = const [],
    this.targetMin = kDefaultSleepTargetMin,
    this.targetIsDefault = true,
    this.asleepMin,
    this.pct,
    this.estimateMin,
    this.cycles,
    this.cycleLenMin = kDefaultCycleLenMin,
    this.windowStart,
    this.wakeAt,
    this.startSource,
    this.wakeSource,
  });

  /// Total sweep of the ring in laps: 1.0 is a full circle, above 1 a spiral.
  double get sweep => arcs.fold(0.0, (a, e) => a + e.fraction);
}

/// Cycle lengths outside this are not a sleep cycle; the 90 min assumption
/// stands instead.
const int _minCycleLenMin = 60, _maxCycleLenMin = 150;

SleepRingModel sleepRingModel({
  required DateTime now,
  num? durationMin,
  SleepStageMin? stages,
  num? needMin,
  num? coachBedtimeMinOfDay,
  DateTime? nextAlarm,
  int? learnedOnsetMin,
  int? learnedWakeMin,
  int? cycleLenMin,
}) {
  final learnedNeed = needMin != null && needMin > 0;
  final target = learnedNeed ? needMin.round() : kDefaultSleepTargetMin;
  final isDefault = !learnedNeed;
  final cycleLen = cycleLenMin != null &&
          cycleLenMin >= _minCycleLenMin &&
          cycleLenMin <= _maxCycleLenMin
      ? cycleLenMin
      : kDefaultCycleLenMin;

  if (durationMin != null) {
    return _slept(durationMin, stages, target, isDefault, cycleLen);
  }

  // ── unslept: wake ────────────────────────────────────────────────────────
  final n = now.toLocal();
  DateTime? wake;
  WakeSource? wakeSource;
  // An alarm past the same wall-clock time tomorrow is not tonight's wake (a
  // weekday alarm seen from Friday evening), so the learned wake answers
  // instead. The cutoff is a calendar step, not `+ 24 h`: across a fall-back
  // tomorrow's 07:00 alarm is 24 h 30 min away and is still tonight's.
  final horizon =
      DateTime(n.year, n.month, n.day + 1, n.hour, n.minute, n.second);
  if (nextAlarm != null &&
      nextAlarm.isAfter(now) &&
      !nextAlarm.isAfter(horizon)) {
    wake = nextAlarm.toLocal();
    wakeSource = WakeSource.alarm;
  } else if (learnedWakeMin != null) {
    wake = _nextClock(n, learnedWakeMin);
    wakeSource = WakeSource.learned;
  }
  if (wake == null) {
    return SleepRingModel(
      phase: SleepRingPhase.none,
      targetMin: target,
      targetIsDefault: isDefault,
      cycleLenMin: cycleLen,
    );
  }

  // ── unslept: window start ────────────────────────────────────────────────
  int? onsetMinute;
  WindowStartSource? startSource;
  if (coachBedtimeMinOfDay != null) {
    onsetMinute = coachBedtimeMinOfDay.round() % 1440;
    startSource = WindowStartSource.coach;
  } else if (learnedOnsetMin != null) {
    onsetMinute = learnedOnsetMin;
    startSource = WindowStartSource.learned;
  }
  DateTime start = n;
  if (onsetMinute != null) {
    final onset = _clockBefore(wake, onsetMinute);
    if (onset.isAfter(n)) start = onset;
  }

  // Real elapsed time between two instants, so a DST night is 7 h or 9 h.
  final est = wake.difference(start).inMinutes;
  if (est <= 0) {
    return SleepRingModel(
      phase: SleepRingPhase.none,
      targetMin: target,
      targetIsDefault: isDefault,
      cycleLenMin: cycleLen,
    );
  }
  return SleepRingModel(
    phase: SleepRingPhase.estimate,
    arcs: [SleepArc(SleepArcKind.estimate, math.min(1.0, est / target))],
    targetMin: target,
    targetIsDefault: isDefault,
    estimateMin: est,
    cycles: est ~/ cycleLen,
    cycleLenMin: cycleLen,
    windowStart: start,
    wakeAt: wake,
    startSource: startSource,
    wakeSource: wakeSource,
  );
}

SleepRingModel _slept(num durationMin, SleepStageMin? stages, int target,
    bool isDefault, int cycleLen) {
  final asleep = durationMin.round();
  final asleepFrac = asleep / target;
  final pct = (asleepFrac * 100).round();

  final d = stages?.deep, r = stages?.rem, l = stages?.light;
  final split = d != null && r != null && l != null && d >= 0 && r >= 0 && l >= 0
      ? d + r + l
      : 0;

  final arcs = <SleepArc>[];
  if (split > 0 && asleep > 0) {
    // Rescale to the night's duration so rounding in the stage totals cannot
    // move the sweep. Fractions are minutes / NEED and stay unscaled past a
    // full circle: 12 h against an 8 h need is 150%, a second lap, as the
    // label says.
    final k = asleepFrac / split;
    arcs.addAll([
      SleepArc(SleepArcKind.deep, d! * k),
      SleepArc(SleepArcKind.rem, r! * k),
      SleepArc(SleepArcKind.light, l! * k),
    ]);
    final awake = stages!.awake;
    final room = 1 - math.min(1.0, asleepFrac);
    if (awake != null && awake > 0) {
      final f = math.min(awake / target, room).toDouble();
      if (f > 1e-12) arcs.add(SleepArc(SleepArcKind.awake, f));
    }
  } else {
    arcs.add(SleepArc(SleepArcKind.solid, asleepFrac));
  }
  return SleepRingModel(
    phase: SleepRingPhase.slept,
    arcs: arcs,
    targetMin: target,
    targetIsDefault: isDefault,
    asleepMin: asleep,
    pct: pct,
    cycleLenMin: cycleLen,
  );
}

/// The first local [minuteOfDay] strictly after [from]. Calendar arithmetic,
/// not `+ 24 h`, so the wall-clock time survives a DST change.
DateTime _nextClock(DateTime from, int minuteOfDay) {
  final today = DateTime(
      from.year, from.month, from.day, minuteOfDay ~/ 60, minuteOfDay % 60);
  return today.isAfter(from)
      ? today
      : DateTime(from.year, from.month, from.day + 1, minuteOfDay ~/ 60,
          minuteOfDay % 60);
}

/// The latest local [minuteOfDay] strictly before [wake].
DateTime _clockBefore(DateTime wake, int minuteOfDay) {
  final same = DateTime(
      wake.year, wake.month, wake.day, minuteOfDay ~/ 60, minuteOfDay % 60);
  return same.isBefore(wake)
      ? same
      : DateTime(wake.year, wake.month, wake.day - 1, minuteOfDay ~/ 60,
          minuteOfDay % 60);
}

/// Median local clock minute-of-day of the onsets and of the wakes in
/// [windows] (`LocalRepository.sleepWindows` rows: epoch-second `onset_ts` /
/// `wake_ts`, either may be null). A side is null with fewer than
/// [minSamples] usable nights. Onsets are medianed on a noon-to-noon axis so
/// 23:30 and 00:10 average to ~23:50, not 11:50.
({int? onsetMin, int? wakeMin}) learnedClockMinutes(
  List<Map<String, dynamic>> windows, {
  int minSamples = 3,
}) {
  int minuteOf(num sec) {
    final t = DateTime.fromMillisecondsSinceEpoch(sec.toInt() * 1000);
    return t.hour * 60 + t.minute;
  }

  int? median(List<int> v) {
    if (v.length < minSamples || v.isEmpty) return null;
    v.sort();
    final mid = v.length ~/ 2;
    return v.length.isOdd ? v[mid] : ((v[mid - 1] + v[mid]) / 2).round();
  }

  final onsets = <int>[], wakes = <int>[];
  for (final w in windows) {
    final o = w['onset_ts'], k = w['wake_ts'];
    if (o is num) {
      final m = minuteOf(o);
      onsets.add(m < 720 ? m + 1440 : m);
    }
    if (k is num) wakes.add(minuteOf(k));
  }
  final on = median(onsets);
  return (onsetMin: on == null ? null : on % 1440, wakeMin: median(wakes));
}
