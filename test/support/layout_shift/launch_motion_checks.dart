// Launch brightness/timing and reduced-motion checks.

import 'dart:math';

import 'shift_model.dart';
import 'shift_policy.dart';
import 'shift_scorer.dart';

/// WCAG relative luminance of the RGB part of [argb].
double _luminance(int argb) {
  double lin(int shift) {
    final c = ((argb >> shift) & 0xFF) / 255;
    return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(16) + 0.7152 * lin(8) + 0.0722 * lin(0);
}

/// error when first paint is later than `firstPaintMaxMs` or brighter
/// (relative luminance) than `firstPaintMaxArgb`; otherwise none.
ShiftSeverity checkFirstPaint(int atMs, int argb, ShiftPolicy p) =>
    atMs > p.firstPaintMaxMs || _luminance(argb) > _luminance(p.firstPaintMaxArgb)
        ? ShiftSeverity.error
        : ShiftSeverity.none;

/// One error finding per span longer than `reducedMaxAnimationMs`, unless the
/// span belongs to a chain whose every cycle is in `reducedChainCycleMinMs..
/// reducedChainCycleMaxMs`.
List<ShiftFinding> checkReducedMotion(
    List<AnimationSpan> animations, ShiftPolicy p) {
  bool slowChain(AnimationSpan n) =>
      n.chainId != null &&
      chainCyclesWithin(
          animations.where((m) => m.chainId == n.chainId).toList(),
          p.reducedChainCycleMinMs,
          p.reducedChainCycleMaxMs);
  return [
    for (final n in animations)
      if (n.endMs - n.startMs > p.reducedMaxAnimationMs && !slowChain(n))
        ShiftFinding(
          rule: 'reduced-motion',
          elementId: n.elementId ?? n.chainId ?? '',
          atMs: n.startMs,
          score: p.errorAt,
          severity: ShiftSeverity.error,
        ),
  ];
}
