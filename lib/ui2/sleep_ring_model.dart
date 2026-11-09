// RED-PHASE STUB (phase 0, Home + labels). Shapes only, no behaviour: every
// function returns the empty answer so the red tests fail on assertions. The
// green phase replaces this file with the model described in
// edge.research/sol/home/scope-map.md (fork origin/integrate/next:
// lib/ui2/sleep_ring_model.dart, minus ExpectedSleepSchedule).

enum SleepRingPhase { slept, estimate, none }

enum SleepArcKind { deep, rem, light, awake, solid, estimate }

enum WindowStartSource { coach, learned }

enum WakeSource { alarm, learned }

/// STUB: the real constants are 480 and 90.
const int kDefaultSleepTargetMin = 0;
const int kDefaultCycleLenMin = 0;

class SleepStageMin {
  final int? deep, rem, light, awake;
  const SleepStageMin({this.deep, this.rem, this.light, this.awake});
}

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
  final int? asleepMin, pct, estimateMin, cycles;
  final int cycleLenMin;
  final DateTime? windowStart, wakeAt;
  final WindowStartSource? startSource;
  final WakeSource? wakeSource;

  const SleepRingModel({
    required this.phase,
    this.arcs = const [],
    this.targetMin = 0,
    this.targetIsDefault = false,
    this.asleepMin,
    this.pct,
    this.estimateMin,
    this.cycles,
    this.cycleLenMin = 0,
    this.windowStart,
    this.wakeAt,
    this.startSource,
    this.wakeSource,
  });

  double get sweep => arcs.fold(0.0, (a, e) => a + e.fraction);
}

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
}) =>
    const SleepRingModel(phase: SleepRingPhase.none);

({int? onsetMin, int? wakeMin}) learnedClockMinutes(
  List<Map<String, dynamic>> windows, {
  int minSamples = 3,
}) =>
    (onsetMin: null, wakeMin: null);
