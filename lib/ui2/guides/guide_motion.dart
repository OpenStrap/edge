// One overlay clock supplies every placeholder and the instruction card. This
// module owns only presentation state, never navigation or app data.
import 'dart:math' as math;
import 'package:flutter/animation.dart';
import '../theme.dart' show Motion;

const kGuidePulseDuration = Motion.guidePulse;

// CLAIM(guide-pulse): value +/-8%, one smooth full cycle every 1.6s; callers
// multiply HSV value only [guide_r3_motion_test].
double guidePulseValue(double phase) => 1 - .08 * math.cos(phase * 2 * math.pi);

/// The tap hand's nudge, 0..1: two out-and-back pushes in the first half of the 1.6 s cycle
/// (peaks at 1/8 and 3/8), still for the second half. 0 at the start, so a stopped clock
/// (reduced motion) leaves the hand at rest. CLAIM(guide-nudge) [guide_r4_test R4-3a].
double guideNudgeValue(double phase) {
  final p = phase - phase.floorToDouble();
  if (p >= .5) return 0;
  return .5 - .5 * math.cos(p * 8 * math.pi);
}

/// Where the auto-scroll puts the target: this fraction down the visible area (owner,
/// round 4).
const kGuideScrollAnchor = 1 / 3;

/// The held instruction position for one step. A collision during scroll fades
/// it immediately; after scroll ends, move for 600ms, then restore for 200ms.
/// CLAIM(guide-card-motion) [guide_r3_motion_test].
class GuideCardMotion {
  double? top;
  double opacity = 1;
  bool _pending = false;
  Duration? _started;
  double _from = 0, _to = 0;
  bool get isAnimating => _pending || _started != null;

  void reset() {
    top = null;
    opacity = 1;
    _pending = false;
    _started = null;
  }

  void place(
    double desired, {
    required bool scrolling,
    required bool collision,
    required Duration elapsed,
    bool animate = true,
  }) {
    if (!animate) {
      top ??= desired;
      if (scrolling) {
        if (collision) { opacity = .2; _pending = true; }
      } else {
        if (_pending || collision) top = desired;
        opacity = 1;
        _pending = false;
        _started = null;
      }
      return;
    }
    if (top == null) {
      top = desired;
      return;
    }
    if (scrolling) {
      if (collision || _started != null) {
        _pending = true;
        _started = null;
        opacity = .2;
      }
      return;
    }
    // Late data can also move the target under the held card. Treat that
    // collision like a completed scroll so the target cannot stay covered.
    if (collision && _started == null) {
      _pending = true;
      opacity = .2;
    }
    if (_pending) {
      _pending = false;
      _started = elapsed;
      _from = top!;
      _to = desired;
    }
    final started = _started;
    if (started == null) return;
    final ms = (elapsed - started).inMicroseconds / 1000;
    top =
        _from +
        (_to - _from) * Curves.easeInOut.transform((ms / 600).clamp(0.0, 1.0));
    opacity =
        .2 +
        .8 * Curves.easeInOut.transform(((ms - 600) / 200).clamp(0.0, 1.0));
    if (ms >= 800) {
      _started = null;
      opacity = 1;
    }
  }
}
