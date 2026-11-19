// Tunable knobs for the layout shift scorer. Defaults are the `standard`
// preset from docs/LAYOUT_SHIFT.md. Immutable; change one with copyWith.

import 'shift_model.dart';

class LatencyPoint {
  final int ms;
  final double cost;
  const LatencyPoint(this.ms, this.cost);
}

class ShiftPolicy {
  final List<LatencyPoint> latencyCurve;
  final int animationGraceWindowMs;
  final int animationGraceMs;
  final int interactionWindowMs;
  final double outOfWindowCost;
  final int chainStartMinMs;
  final int chainEndMaxMs;
  final int chainCycleMinMs;
  final int chainCycleMaxMs;
  final double chainDiscount;
  final Map<ElementRole, double> roleWeight;
  final double colorWeight;
  final double focusDistanceWeight;
  final int focusHalfLifeMs;
  final double pairedDiscount;
  final double pairDistanceWeight;
  final double coverCost;
  final double coverMinFraction;
  final double focusedMultiplier;
  final double denseGapPx;
  final double denseMultiplier;
  final int disabledShieldMinMs;
  final int disabledShieldMaxMs;
  final double disabledDiscount;
  final double warnAt;
  final double errorAt;
  final int firstPaintMaxMs;
  final int firstPaintMaxArgb;
  final int reducedMaxAnimationMs;
  final int reducedChainCycleMinMs;
  final int reducedChainCycleMaxMs;

  const ShiftPolicy({
    this.latencyCurve = const [
      LatencyPoint(100, 0),
      LatencyPoint(200, 0.1),
      LatencyPoint(300, 0.3),
      LatencyPoint(400, 0.5),
      LatencyPoint(500, 1),
    ],
    this.animationGraceWindowMs = 100,
    this.animationGraceMs = 100,
    this.interactionWindowMs = 500,
    this.outOfWindowCost = 1.0,
    this.chainStartMinMs = 75,
    this.chainEndMaxMs = 2000,
    this.chainCycleMinMs = 200,
    this.chainCycleMaxMs = 400,
    this.chainDiscount = 0.5,
    this.roleWeight = const {
      ElementRole.paragraph: 2,
      ElementRole.input: 3,
      ElementRole.control: 1.5,
      ElementRole.media: 1,
      ElementRole.decorative: 0.5,
      ElementRole.other: 1,
    },
    this.colorWeight = 0.5,
    this.focusDistanceWeight = 1.0,
    this.focusHalfLifeMs = 2000,
    this.pairedDiscount = 0.5,
    this.pairDistanceWeight = 0.5,
    this.coverCost = 1.0,
    this.coverMinFraction = 0.25,
    this.focusedMultiplier = 2.0,
    this.denseGapPx = 8,
    this.denseMultiplier = 3.0,
    this.disabledShieldMinMs = 400,
    this.disabledShieldMaxMs = 1000,
    this.disabledDiscount = 0.8,
    this.warnAt = 0.05,
    this.errorAt = 0.25,
    this.firstPaintMaxMs = 20,
    this.firstPaintMaxArgb = 0xFF222222,
    this.reducedMaxAnimationMs = 150,
    this.reducedChainCycleMinMs = 750,
    this.reducedChainCycleMaxMs = 2000,
  });

  static const standard = ShiftPolicy();

  /// Costs more everywhere: later curve discounts, weaker pair/chain breaks.
  static const strict = ShiftPolicy(
    latencyCurve: [
      LatencyPoint(100, 0.1),
      LatencyPoint(200, 0.2),
      LatencyPoint(300, 0.5),
      LatencyPoint(400, 0.75),
      LatencyPoint(500, 1),
    ],
    chainDiscount: 0.75,
    pairedDiscount: 0.75,
    focusDistanceWeight: 1.5,
    colorWeight: 0.75,
    warnAt: 0.03,
    errorAt: 0.15,
  );

  static const lenient = ShiftPolicy(
    latencyCurve: [
      LatencyPoint(100, 0),
      LatencyPoint(200, 0.05),
      LatencyPoint(300, 0.15),
      LatencyPoint(400, 0.3),
      LatencyPoint(500, 1),
    ],
    chainDiscount: 0.25,
    pairedDiscount: 0.25,
    focusDistanceWeight: 0.5,
    colorWeight: 0.25,
    warnAt: 0.08,
    errorAt: 0.4,
  );

  /// Latency multiplier for [ms] after the interaction: piecewise linear
  /// between curve points, 0 before the first, the last cost after the last.
  double latencyAt(int ms) => throw UnimplementedError();

  ShiftPolicy copyWith({
    List<LatencyPoint>? latencyCurve,
    int? animationGraceWindowMs,
    int? animationGraceMs,
    int? interactionWindowMs,
    double? outOfWindowCost,
    int? chainStartMinMs,
    int? chainEndMaxMs,
    int? chainCycleMinMs,
    int? chainCycleMaxMs,
    double? chainDiscount,
    Map<ElementRole, double>? roleWeight,
    double? colorWeight,
    double? focusDistanceWeight,
    int? focusHalfLifeMs,
    double? pairedDiscount,
    double? pairDistanceWeight,
    double? coverCost,
    double? coverMinFraction,
    double? focusedMultiplier,
    double? denseGapPx,
    double? denseMultiplier,
    int? disabledShieldMinMs,
    int? disabledShieldMaxMs,
    double? disabledDiscount,
    double? warnAt,
    double? errorAt,
    int? firstPaintMaxMs,
    int? firstPaintMaxArgb,
    int? reducedMaxAnimationMs,
    int? reducedChainCycleMinMs,
    int? reducedChainCycleMaxMs,
  }) =>
      throw UnimplementedError();
}
