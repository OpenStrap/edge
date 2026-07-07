// Design-system motion — the flutter_animate vocabulary every new component
// speaks. One entrance, one pop, one celebration; durations/curves come from
// the [Motion] tokens so hand-rolled controllers and these stay in sync.
//
// Usage:
//   MetricCard(...).dsEnter(index: i)      // staggered fade-up on first build
//   PrBadge('PR').dsPop()                  // springy scale-in
//   bigNumber.dsCelebrate()                // slow reveal + one shimmer pass

import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../theme/tokens.dart';

/// Per-item stagger step for list/grid entrances.
const Duration kDsStaggerStep = Duration(milliseconds: 40);

/// Cap the total stagger so deep lists don't feel sluggish.
const Duration kDsStaggerCap = Duration(milliseconds: 400);

Duration _staggerDelay(int index) {
  final ms = (index * kDsStaggerStep.inMilliseconds).clamp(
    0,
    kDsStaggerCap.inMilliseconds,
  );
  return Duration(milliseconds: ms);
}

extension DsMotion on Widget {
  /// Content settling into place: fade 0→1 + rise 12px, staggered by [index].
  /// The design-system twin of the kit's [Entrance]; plays once on first build.
  Widget dsEnter({int index = 0, double rise = 12}) =>
      animate(delay: _staggerDelay(index))
          .fadeIn(duration: Motion.enter.d, curve: Motion.enter.c)
          .moveY(
            begin: rise,
            end: 0,
            duration: Motion.enter.d,
            curve: Motion.enter.c,
          );

  /// A responsive, slightly-overshooting scale-in (badges, chips, PR pills).
  Widget dsPop({int index = 0}) => animate(delay: _staggerDelay(index))
      .fadeIn(duration: Motion.fast, curve: Curves.easeOut)
      .scaleXY(
        begin: 0.85,
        end: 1,
        duration: Motion.springy.d,
        curve: Motion.springy.c,
      );

  /// A drawn-out celebratory reveal with a single ember shimmer pass —
  /// finish cards, new records, unlocked baselines.
  Widget dsCelebrate() => animate()
      .fadeIn(duration: Motion.celebratory.d, curve: Motion.celebratory.c)
      .scaleXY(
        begin: 0.94,
        end: 1,
        duration: Motion.celebratory.d,
        curve: Motion.celebratory.c,
      )
      .shimmer(
        delay: Motion.celebratory.d,
        duration: const Duration(milliseconds: 900),
        color: AppColors.accent.withValues(alpha: 0.35),
      );
}

/// Stagger a hand-built list of children with [DsMotion.dsEnter]. Bare
/// [SizedBox] spacers pass through untouched so gaps don't animate.
List<Widget> dsStaggered(List<Widget> items) {
  var i = 0;
  return [
    for (final w in items)
      if (w is SizedBox) w else w.dsEnter(index: i++),
  ];
}
