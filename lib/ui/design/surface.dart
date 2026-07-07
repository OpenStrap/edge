// SurfaceCard — the depth-correct card surface of the design system.
//
// Depth contract (see [Elevation]):
//  • Paper (light): soft warm drop shadow, strength grows with [level].
//  • Char (dark): hairline border + lighter lifted fill; level 2 adds a faint
//    penumbra, level 3 a subtle warm ember under-glow. Never flat black-on-black.
//
// Interactivity: pass [onTap] for press-scale + ripple + haptic (via
// [Pressable]); [entranceIndex] gives the staggered fade-up on first build.
//
// The legacy [ProCard] stays untouched for existing screens; new components
// and the screen rollout build on this.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'motion.dart';
import 'pressable.dart';

class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Semantic depth 0..3 — see [Elevation].
  final int level;

  /// Corner radius; defaults to the standard card radius.
  final double radius;

  /// Override fill (defaults to the mode-correct surface for [level]).
  final Color? color;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// When non-null, the card fades + rises on first build, staggered by index.
  final int? entranceIndex;

  /// An ember radial glow blob in a corner (hero/accent cards).
  final bool accentGlow;
  final Alignment glowAlignment;

  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.level = 1,
    this.radius = R.card,
    this.color,
    this.onTap,
    this.onLongPress,
    this.entranceIndex,
    this.accentGlow = false,
    this.glowAlignment = const Alignment(0.9, 1.1),
  });

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark;
    final br = BorderRadius.circular(radius);

    Widget body = Padding(padding: padding, child: child);
    if (accentGlow) {
      // On char the blob is a low warm ember; on paper it can sing.
      final glowAlpha = dark ? 0.26 : 0.5;
      final glowRadius = dark ? 0.62 : 0.9;
      body = ClipRRect(
        borderRadius: br,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: glowAlignment,
                    radius: glowRadius,
                    colors: [
                      AppColors.accent.withValues(alpha: glowAlpha),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            body,
          ],
        ),
      );
    }

    Widget card = AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: color ?? Elevation.surfaceAt(level, dark: dark),
        borderRadius: br,
        boxShadow: Elevation.shadows(level, dark: dark),
        border: Elevation.border(level, dark: dark),
      ),
      child: body,
    );

    if (onTap != null || onLongPress != null) {
      card = Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: br,
        child: card,
      );
    }
    if (entranceIndex != null) card = card.dsEnter(index: entranceIndex!);
    return card;
  }
}
