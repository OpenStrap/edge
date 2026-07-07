// Sparkline — the ONE small-chart identity for inline trends (inside
// MetricCards, list rows, bento tiles). Line or area, with a clean solid
// "now" dot (no glow — the redesign's restraint contract).
//
//  • values may contain nulls — gaps split the line instead of lying across
//    missing data (the honesty contract, drawn).
//  • optional soft area fill, optional dashed baseline reference,
//    optional multi-stop stroke gradient (e.g. HR-zone colouring).
//  • animated left→right draw-in on first build; RepaintBoundary-wrapped;
//    the painter does no per-frame path smoothing beyond a cheap quadratic.
//
// For bar-style sparks keep using [MiniBars] (re-exported by the design
// barrel) — one bar identity, one line identity.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class Sparkline extends StatelessWidget {
  /// Series, oldest → newest. Nulls are gaps (the line splits).
  final List<double?> values;

  final Color? color;
  final double height;
  final double strokeWidth;

  /// Soft gradient fill under the line.
  final bool area;

  /// Glowing dot on the newest point.
  final bool endDot;

  /// Optional stroke gradient (left→right), e.g. zone colours across a workout.
  final List<Color>? gradient;

  /// Optional reference value drawn as a faint dashed line (e.g. baseline).
  final double? baseline;

  /// Animate the left→right draw-in on first build.
  final bool animate;

  const Sparkline(
    this.values, {
    super.key,
    this.color,
    this.height = 36,
    this.strokeWidth = 2.2,
    this.area = false,
    this.endDot = true,
    this.gradient,
    this.baseline,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;
    Widget paint(double t) => CustomPaint(
      size: Size(double.infinity, height),
      painter: _SparkPainter(
        values: values,
        color: c,
        strokeWidth: strokeWidth,
        area: area,
        endDot: endDot,
        gradient: gradient,
        baseline: baseline,
        baselineColor: AppColors.inkMuted,
        reveal: t,
      ),
    );
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        child: animate
            ? TweenAnimationBuilder<double>(
                duration: Motion.slow,
                curve: Motion.curve,
                tween: Tween(begin: 0, end: 1),
                builder: (_, t, _) => paint(t),
              )
            : paint(1),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double?> values;
  final Color color;
  final double strokeWidth;
  final bool area;
  final bool endDot;
  final List<Color>? gradient;
  final double? baseline;
  final Color baselineColor;
  final double reveal; // 0..1 left→right clip

  _SparkPainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
    required this.area,
    required this.endDot,
    required this.gradient,
    required this.baseline,
    required this.baselineColor,
    required this.reveal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0) return;

    // Normalize over non-null values (pad a flat series so it draws mid-height).
    double? lo, hi;
    for (final v in values) {
      if (v == null) continue;
      lo = lo == null ? v : (v < lo ? v : lo);
      hi = hi == null ? v : (v > hi ? v : hi);
    }
    if (lo == null || hi == null) return;
    if (hi - lo < 1e-9) {
      lo -= 1;
      hi += 1;
    }
    final range = hi - lo;
    final pad = strokeWidth + (endDot ? 4 : 0);
    final h = size.height - pad * 2;
    final dx = size.width / (values.length - 1);
    Offset pt(int i, double v) =>
        Offset(i * dx, pad + h * (1 - (v - lo!) / range));

    // Baseline reference (under the line).
    if (baseline != null && baseline! >= lo && baseline! <= hi) {
      final y = pad + h * (1 - (baseline! - lo) / range);
      final bp = Paint()
        ..color = baselineColor.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      const dash = 4.0, gap = 4.0;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + dash).clamp(0, size.width), y),
          bp,
        );
        x += dash + gap;
      }
    }

    // Build segments split on nulls, lightly smoothed.
    final segments = <Path>[];
    Path? cur;
    Offset? prev;
    Offset? last;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        cur = null;
        prev = null;
        continue;
      }
      final p = pt(i, v);
      last = p;
      if (cur == null) {
        cur = Path()..moveTo(p.dx, p.dy);
        segments.add(cur);
      } else if (prev != null) {
        // Quadratic through the midpoint — a gentle smooth, no overshoot.
        final mid = Offset((prev.dx + p.dx) / 2, (prev.dy + p.dy) / 2);
        cur.quadraticBezierTo(prev.dx, prev.dy, mid.dx, mid.dy);
        cur.lineTo(p.dx, p.dy);
      }
      prev = p;
    }
    if (segments.isEmpty || last == null) return;

    if (reveal < 1) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, size.width * reveal, size.height));
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (gradient != null && gradient!.length >= 2) {
      stroke.shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, 0),
        gradient!,
        List.generate(gradient!.length, (i) => i / (gradient!.length - 1)),
      );
    } else {
      stroke.color = color;
    }

    if (area) {
      final fill = Paint()
        ..shader = ui.Gradient.linear(Offset(0, pad), Offset(0, size.height), [
          color.withValues(alpha: 0.20),
          color.withValues(alpha: 0.0),
        ]);
      for (final s in segments) {
        final bounds = s.getBounds();
        final closed = Path.from(s)
          ..lineTo(bounds.right, size.height)
          ..lineTo(bounds.left, size.height)
          ..close();
        canvas.drawPath(closed, fill);
      }
    }
    for (final s in segments) {
      canvas.drawPath(s, stroke);
    }

    if (reveal < 1) canvas.restore();

    // Clean "now" dot on the newest point (revealed with the line) — a solid
    // mark with a quiet halo ring; deliberately NO glow/blur (restraint).
    if (endDot && reveal >= 0.98) {
      final dotColor = gradient != null && gradient!.isNotEmpty
          ? gradient!.last
          : color;
      canvas.drawCircle(
        last,
        strokeWidth * 2.0,
        Paint()..color = dotColor.withValues(alpha: 0.18),
      );
      canvas.drawCircle(last, strokeWidth * 1.05, Paint()..color = dotColor);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values ||
      old.color != color ||
      old.reveal != reveal ||
      old.area != area ||
      old.endDot != endDot ||
      old.gradient != gradient ||
      old.baseline != baseline;
}
