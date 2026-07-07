// Skeleton — shimmering ProCard-shaped placeholders shown while a screen loads,
// in place of a bare spinner. One repeating [AnimationController] drives a single
// gradient sweep over the whole composed shape (a ShaderMask), so an entire
// screen of placeholders costs one ticker + one repaint boundary.
//
// Presets mirror real content: Skeleton.hero (a big card), Skeleton.tileRow
// (the 2-up stat grid), Skeleton.chart (a chart card). Compose freely.

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

class Skeleton extends StatefulWidget {
  /// The opaque shape(s) to shimmer. Built from [SkelBox] pieces; transparent
  /// gaps (SizedBox) stay transparent — the sweep only touches opaque pixels.
  final Widget child;
  const Skeleton._(this.child, {super.key});

  /// A hero card placeholder (readiness/strain ring shape).
  static Widget hero({Key? key}) => Skeleton._(const _SkelHero(), key: key);

  /// A grid of 2-up stat tiles ([rows] rows of two).
  static Widget tileRow({Key? key, int rows = 3}) =>
      Skeleton._(_SkelTiles(rows), key: key);

  /// A chart card placeholder.
  static Widget chart({Key? key, double height = 200}) =>
      Skeleton._(_SkelChart(height), key: key);

  /// A single rounded block — the primitive the presets are built from.
  static Widget box({Key? key, double height = 96, double radius = R.card}) =>
      Skeleton._(SkelBox(height: height, radius: radius), key: key);

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.surfaceAlt;
    // A lighter band sweeping across. On paper it brightens toward white; on
    // char surfaceAlt is already the lightest well, so lift it subtly.
    final hl = Color.lerp(
      base,
      AppColors.isDark ? const Color(0xFFFFFFFF) : AppColors.surface,
      AppColors.isDark ? 0.12 : 0.7,
    )!;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, hl, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SweepTransform(_c.value),
            ).createShader(rect),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Moves the shimmer band from fully off the left edge to fully off the right.
class _SweepTransform extends GradientTransform {
  final double t; // 0..1
  const _SweepTransform(this.t);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final dx = (t * 2 - 1) * bounds.width;
    return Matrix4.translationValues(dx, 0, 0);
  }
}

/// An opaque rounded block filled with the skeleton base tone.
class SkelBox extends StatelessWidget {
  final double? height;
  final double? width;
  final double radius;
  const SkelBox({super.key, this.height, this.width, this.radius = R.cardSm});
  @override
  Widget build(BuildContext context) => Container(
    height: height,
    width: width,
    decoration: BoxDecoration(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

class _SkelHero extends StatelessWidget {
  const _SkelHero();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Sp.x5),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(R.card),
      border: AppColors.isDark
          ? Border.all(color: AppColors.divider, width: 1)
          : null,
      boxShadow: Shadows.cardFor(AppColors.isDark),
    ),
    child: Row(
      children: [
        SkelBox(height: 92, width: 92, radius: R.pill),
        const SizedBox(width: Sp.x5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              SkelBox(height: 16, width: 120, radius: R.chip),
              SizedBox(height: Sp.x3),
              SkelBox(height: 28, width: 160, radius: R.chip),
              SizedBox(height: Sp.x3),
              SkelBox(height: 14, radius: R.chip),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SkelTiles extends StatelessWidget {
  final int rows;
  const _SkelTiles(this.rows);
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: Sp.x3),
          Row(
            children: const [
              Expanded(child: SkelBox(height: 108, radius: R.card)),
              SizedBox(width: Sp.x3),
              Expanded(child: SkelBox(height: 108, radius: R.card)),
            ],
          ),
        ],
      ],
    );
  }
}

class _SkelChart extends StatelessWidget {
  final double height;
  const _SkelChart(this.height);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Sp.x5),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(R.card),
      border: AppColors.isDark
          ? Border.all(color: AppColors.divider, width: 1)
          : null,
      boxShadow: Shadows.cardFor(AppColors.isDark),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkelBox(height: 16, width: 140, radius: R.chip),
        const SizedBox(height: Sp.x4),
        SkelBox(height: height, radius: R.cardSm),
      ],
    ),
  );
}
