// Launch brightness/timing and reduced-motion checks.

import 'shift_model.dart';
import 'shift_policy.dart';
import 'shift_scorer.dart';

/// error when first paint is later than `firstPaintMaxMs` or brighter
/// (relative luminance) than `firstPaintMaxArgb`; otherwise none.
ShiftSeverity checkFirstPaint(int atMs, int argb, ShiftPolicy p) =>
    throw UnimplementedError();

/// One error finding per span longer than `reducedMaxAnimationMs`, unless the
/// span belongs to a chain whose every cycle is in `reducedChainCycleMinMs..
/// reducedChainCycleMaxMs`.
List<ShiftFinding> checkReducedMotion(
        List<AnimationSpan> animations, ShiftPolicy p) =>
    throw UnimplementedError();
