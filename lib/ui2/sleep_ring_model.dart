// sleep_ring_model.dart — what the Home sleep ring says and draws, as data.
//
// PURE. No clock, no I/O, no widgets, no l10n: the ring turns this into shapes
// and strings. Kept apart so every rule below is a fixed-input unit test.
//

/// The owner's explicit default target: 5 cycles + 30 min. Used ONLY when no
/// learned need exists, and always labelled as a default where it is shown.
const int kDefaultSleepTargetMin = 480;

enum SleepArcKind { deep, rem, light, awake, solid }

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
  final List<SleepArc> arcs;
  final int targetMin;
  final bool targetIsDefault;

  /// Minutes asleep.
  final int asleepMin;

  /// Whole percent of [targetMin].
  final int pct;

  const SleepRingModel({
    required this.arcs,
    required this.targetMin,
    required this.targetIsDefault,
    required this.asleepMin,
    required this.pct,
  });

  /// Total sweep of the ring in laps: 1.0 is a full circle, above 1 a spiral.
  double get sweep => arcs.fold(0.0, (a, e) => a + e.fraction);
}

/// The scored night as a ring: the target (learned need, else the flagged 8 h
/// default), the percent of it, and the stage arcs.
SleepRingModel sleepRingModel({
  required num durationMin,
  SleepStageMin? stages,
  num? needMin,
}) {
  final learnedNeed = needMin != null && needMin.isFinite && needMin.round() > 0;
  final target = learnedNeed ? needMin.round() : kDefaultSleepTargetMin;
  return _slept(durationMin, stages, target, !learnedNeed);
}

SleepRingModel _slept(
    num durationMin, SleepStageMin? stages, int target, bool isDefault) {
  final asleep = durationMin.round();
  final asleepFrac = asleep / target;
  final pct = (asleepFrac * 100).round();

  final d = stages?.deep, r = stages?.rem, l = stages?.light;
  final split = d != null && r != null && l != null && d >= 0 && r >= 0 && l >= 0
      ? d + r + l
      : 0;

  final arcs = <SleepArc>[];
  if (split > 0 && asleep > 0) {
    // Stage proportions, including awake, divide the earned sleep sweep.
    // Awake describes the night without adding progress toward the target.
    // Keep sweeps above one lap so the picture agrees with percentages >100.
    final awake = stages?.awake;
    final awakeMin = awake != null && awake > 0 ? awake : 0;
    final k = asleepFrac / (split + awakeMin);
    arcs.addAll([
      SleepArc(SleepArcKind.deep, d! * k),
      SleepArc(SleepArcKind.rem, r! * k),
      SleepArc(SleepArcKind.light, l! * k),
    ]);
    if (awakeMin > 0) {
      arcs.add(SleepArc(SleepArcKind.awake, awakeMin * k));
    }
  } else {
    arcs.add(SleepArc(SleepArcKind.solid, asleepFrac));
  }
  return SleepRingModel(
    arcs: arcs,
    targetMin: target,
    targetIsDefault: isDefault,
    asleepMin: asleep,
    pct: pct,
  );
}
