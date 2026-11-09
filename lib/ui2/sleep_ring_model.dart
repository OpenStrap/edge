// sleep_ring_model.dart — what the Home sleep ring says and draws, as data.
//
// PURE. No clock, no I/O, no widgets, no l10n: the ring turns this into shapes
// and strings. Kept apart so every rule below is a fixed-input unit test.
//
import 'dart:math' as math;

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
  final learnedNeed = needMin != null && needMin > 0;
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
    arcs: arcs,
    targetMin: target,
    targetIsDefault: isDefault,
    asleepMin: asleep,
    pct: pct,
  );
}
