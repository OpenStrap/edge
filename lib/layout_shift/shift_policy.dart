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
  final List<LatencyPoint> loadCurve;
  final double loadWeight;
  final double appearWeight;
  final double appearCoveredFree;
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
  final double sourceShiftFloor;
  final double focusShiftFloor;
  final double denseShiftFloor;
  final int disabledShieldMinMs;
  final int disabledShieldMaxMs;
  final double disabledDiscount;
  final double controlMoveScore;
  final double controlMoveRefPx;
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
    this.loadCurve = const [
      LatencyPoint(100, 0),
      LatencyPoint(400, 0.1),
      LatencyPoint(1000, 0.3),
      LatencyPoint(2000, 0.6),
      LatencyPoint(4000, 1),
    ],
    this.loadWeight = 0.25,
    this.appearWeight = 0.5,
    this.appearCoveredFree = 0.9,
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
    this.sourceShiftFloor = 0.5,
    this.focusShiftFloor = 0.5,
    this.denseShiftFloor = 0.3,
    this.disabledShieldMinMs = 400,
    this.disabledShieldMaxMs = 1000,
    this.disabledDiscount = 0.8,
    this.controlMoveScore = 0.1,
    this.controlMoveRefPx = 48,
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
    loadWeight: 0.4,
    appearWeight: 0.75,
    chainDiscount: 0.75,
    pairedDiscount: 0.75,
    focusDistanceWeight: 1.5,
    colorWeight: 0.75,
    sourceShiftFloor: 0.75,
    focusShiftFloor: 0.75,
    denseShiftFloor: 0.5,
    controlMoveScore: 0.15,
    controlMoveRefPx: 40,
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
    loadWeight: 0.15,
    appearWeight: 0.3,
    chainDiscount: 0.25,
    pairedDiscount: 0.25,
    focusDistanceWeight: 0.5,
    colorWeight: 0.25,
    sourceShiftFloor: 0.3,
    focusShiftFloor: 0.3,
    denseShiftFloor: 0.15,
    controlMoveScore: 0.06,
    controlMoveRefPx: 64,
    warnAt: 0.08,
    errorAt: 0.4,
  );

  /// Latency multiplier for [ms] after the interaction: piecewise linear
  /// between curve points, 0 before the first, the last cost after the last.
  double latencyAt(int ms) => _curveAt(latencyCurve, ms);

  /// Load multiplier for a settle time of [ms]; same shape as [latencyAt].
  double loadAt(int ms) => _curveAt(loadCurve, ms);

  static double _curveAt(List<LatencyPoint> c, int ms) {
    if (ms < c.first.ms) return 0;
    for (var i = 1; i < c.length; i++) {
      if (ms < c[i].ms) {
        final a = c[i - 1], b = c[i];
        return a.cost + (b.cost - a.cost) * (ms - a.ms) / (b.ms - a.ms);
      }
    }
    return c.last.cost;
  }

  ShiftPolicy copyWith({
    List<LatencyPoint>? latencyCurve,
    List<LatencyPoint>? loadCurve,
    double? loadWeight,
    double? appearWeight,
    double? appearCoveredFree,
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
    double? sourceShiftFloor,
    double? focusShiftFloor,
    double? denseShiftFloor,
    int? disabledShieldMinMs,
    int? disabledShieldMaxMs,
    double? disabledDiscount,
    double? controlMoveScore,
    double? controlMoveRefPx,
    double? warnAt,
    double? errorAt,
    int? firstPaintMaxMs,
    int? firstPaintMaxArgb,
    int? reducedMaxAnimationMs,
    int? reducedChainCycleMinMs,
    int? reducedChainCycleMaxMs,
  }) =>
      ShiftPolicy(
        latencyCurve: latencyCurve ?? this.latencyCurve,
        loadCurve: loadCurve ?? this.loadCurve,
        loadWeight: loadWeight ?? this.loadWeight,
        appearWeight: appearWeight ?? this.appearWeight,
        appearCoveredFree: appearCoveredFree ?? this.appearCoveredFree,
        animationGraceWindowMs: animationGraceWindowMs ?? this.animationGraceWindowMs,
        animationGraceMs: animationGraceMs ?? this.animationGraceMs,
        interactionWindowMs: interactionWindowMs ?? this.interactionWindowMs,
        outOfWindowCost: outOfWindowCost ?? this.outOfWindowCost,
        chainStartMinMs: chainStartMinMs ?? this.chainStartMinMs,
        chainEndMaxMs: chainEndMaxMs ?? this.chainEndMaxMs,
        chainCycleMinMs: chainCycleMinMs ?? this.chainCycleMinMs,
        chainCycleMaxMs: chainCycleMaxMs ?? this.chainCycleMaxMs,
        chainDiscount: chainDiscount ?? this.chainDiscount,
        roleWeight: roleWeight ?? this.roleWeight,
        colorWeight: colorWeight ?? this.colorWeight,
        focusDistanceWeight: focusDistanceWeight ?? this.focusDistanceWeight,
        focusHalfLifeMs: focusHalfLifeMs ?? this.focusHalfLifeMs,
        pairedDiscount: pairedDiscount ?? this.pairedDiscount,
        pairDistanceWeight: pairDistanceWeight ?? this.pairDistanceWeight,
        coverCost: coverCost ?? this.coverCost,
        coverMinFraction: coverMinFraction ?? this.coverMinFraction,
        focusedMultiplier: focusedMultiplier ?? this.focusedMultiplier,
        denseGapPx: denseGapPx ?? this.denseGapPx,
        denseMultiplier: denseMultiplier ?? this.denseMultiplier,
        sourceShiftFloor: sourceShiftFloor ?? this.sourceShiftFloor,
        focusShiftFloor: focusShiftFloor ?? this.focusShiftFloor,
        denseShiftFloor: denseShiftFloor ?? this.denseShiftFloor,
        disabledShieldMinMs: disabledShieldMinMs ?? this.disabledShieldMinMs,
        disabledShieldMaxMs: disabledShieldMaxMs ?? this.disabledShieldMaxMs,
        disabledDiscount: disabledDiscount ?? this.disabledDiscount,
        controlMoveScore: controlMoveScore ?? this.controlMoveScore,
        controlMoveRefPx: controlMoveRefPx ?? this.controlMoveRefPx,
        warnAt: warnAt ?? this.warnAt,
        errorAt: errorAt ?? this.errorAt,
        firstPaintMaxMs: firstPaintMaxMs ?? this.firstPaintMaxMs,
        firstPaintMaxArgb: firstPaintMaxArgb ?? this.firstPaintMaxArgb,
        reducedMaxAnimationMs: reducedMaxAnimationMs ?? this.reducedMaxAnimationMs,
        reducedChainCycleMinMs: reducedChainCycleMinMs ?? this.reducedChainCycleMinMs,
        reducedChainCycleMaxMs: reducedChainCycleMaxMs ?? this.reducedChainCycleMaxMs,
      );
}
