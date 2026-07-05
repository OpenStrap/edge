// ArcGauge — the ONE circular-progress engine of the design system: readiness /
// recovery / strain rings, mini gauges inside MetricCards, and the open 270°
// "speedo" arc from the reference apps. The legacy [Gauge] (and through it
// [RingStat]) delegates here, so every ring in the app is this painter.
//
//  • value 0..1 (NaN → muted empty ring), animated reveal on first build
//  • full ring (default) or an open arc via [sweepFraction] (e.g. 0.75 = 270°,
//    gap centered at the bottom)
//  • zone-tinted track, target notch, confidence fade (dashed when < 0.4)
//  • optional clean end-cap dot (solid, never glowing)
//  • built-in value+label center, or pass any [center] widget
//  • wrapped in a RepaintBoundary; the painter allocates nothing per frame
//    beyond its Paint objects.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';

class ArcGauge extends StatelessWidget {
  /// Fill fraction 0..1. NaN renders a muted empty ring.
  final double value;

  /// Arc colour. Defaults to the zone colour when [zone] is set, else ember.
  final Color? color;

  /// When set, the track is tinted with this HR zone's soft colour (0..5).
  final int? zone;

  final double size;
  final double stroke;

  /// Custom center widget. When null and [valueText] is set, a value+label
  /// center is built (big tabular number over a small muted label).
  final Widget? center;
  final String? valueText;
  final String? label;

  /// Fraction of the full circle the gauge spans. 1.0 = closed ring;
  /// 0.75 = 270° open arc with the gap centered at the bottom.
  final double sweepFraction;

  /// Optional goal marker at this 0..1 fraction — a short notch on the track.
  final double? target;

  /// 0..1 — 1.0 paints the arc solid; lower fades it (dashed below 0.4) so a
  /// low-confidence value reads as visually uncertain.
  final double confidence;

  /// Glowing dot at the end of the arc.
  final bool endDot;

  /// Track colour override (else zone-soft or the neutral inset surface).
  final Color? trackColor;

  /// Animate the first reveal (sweep from 0). Disable for scrub-driven values.
  final bool animate;

  const ArcGauge({
    super.key,
    required this.value,
    this.color,
    this.zone,
    this.size = 160,
    this.stroke = 14,
    this.center,
    this.valueText,
    this.label,
    this.sweepFraction = 1.0,
    this.target,
    this.confidence = 1.0,
    this.endDot = false,
    this.trackColor,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final fill = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final arcColor =
        color ?? (zone != null ? AppColors.zone(zone!) : AppColors.accent);
    final track =
        trackColor ??
        (zone == null ? AppColors.surfaceAlt : AppColors.zoneSoft(zone!));

    final centerChild =
        center ??
        (valueText == null
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    valueText!,
                    style: AppText.metric.copyWith(fontSize: size * 0.22),
                  ),
                  if (label != null)
                    Text(
                      label!.toUpperCase(),
                      style: AppText.overline.copyWith(
                        fontSize: (size * 0.062).clamp(9.0, 12.0),
                      ),
                    ),
                ],
              ));

    Widget paint(double v) => CustomPaint(
      painter: ArcGaugePainter(
        t: v,
        color: arcColor,
        stroke: stroke,
        trackColor: track,
        sweepFraction: sweepFraction.clamp(0.1, 1.0),
        target: target,
        confidence: confidence,
        endDot: endDot,
      ),
      child: Center(child: centerChild),
    );

    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: animate
            ? TweenAnimationBuilder<double>(
                duration: Motion.ring,
                curve: Motion.emphatic,
                tween: Tween(begin: 0, end: fill),
                builder: (_, v, _) => paint(v),
              )
            : paint(fill),
      ),
    );
  }
}

/// The shared ring/arc painter. Public so the legacy [Gauge] delegates to the
/// same pixels; treat as design-system internal otherwise.
class ArcGaugePainter extends CustomPainter {
  final double t;
  final Color color;
  final double stroke;
  final Color trackColor;
  final double sweepFraction;
  final double? target;
  final double confidence;
  final bool endDot;

  ArcGaugePainter({
    required this.t,
    required this.color,
    required this.stroke,
    required this.trackColor,
    this.sweepFraction = 1.0,
    this.target,
    this.confidence = 1.0,
    this.endDot = false,
  });

  /// Closed ring starts at 12 o'clock; an open arc centers its gap at the
  /// bottom (so a 270° arc runs 135° → 45°, like the reference gauges).
  double get _start => sweepFraction >= 1.0
      ? -math.pi / 2
      : math.pi / 2 + math.pi * (1 - sweepFraction);

  double get _maxSweep => math.pi * 2 * sweepFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, _start, _maxSweep, false, track);

    final sweep = _maxSweep * t.clamp(0.0, 1.0);
    if (t > 0) {
      final alpha = confidenceRingAlpha(confidence);
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          endAngle: math.pi * 2,
          colors: [
            color.withValues(alpha: 0.85 * alpha),
            color.withValues(alpha: alpha),
          ],
          transform: GradientRotation(_start),
        ).createShader(rect);
      if (confidence < 0.4) {
        // Uncertain → dashed arc.
        const dash = 0.16, gap = 0.12;
        var a = _start;
        final end = _start + sweep;
        while (a < end) {
          final seg = math.min(dash, end - a);
          canvas.drawArc(rect, a, seg, false, arc);
          a += dash + gap;
        }
      } else {
        canvas.drawArc(rect, _start, sweep, false, arc);
      }

      if (endDot) {
        // Clean end cap — a solid white dot on the arc, no glow/blur.
        final ang = _start + sweep;
        final p = c + Offset(math.cos(ang), math.sin(ang)) * r;
        canvas.drawCircle(p, stroke * 0.52, Paint()..color = color);
        canvas.drawCircle(p, stroke * 0.30, Paint()..color = Colors.white);
      }
    }

    // Target notch — a short ink tick straddling the track at the goal fraction.
    final tgt = target;
    if (tgt != null && tgt > 0 && tgt <= 1) {
      final ang = _start + _maxSweep * tgt;
      final dir = Offset(math.cos(ang), math.sin(ang));
      final inner = c + dir * (r - stroke * 0.75);
      final outer = c + dir * (r + stroke * 0.75);
      final notch = Paint()
        ..color = AppColors.ink.withValues(alpha: 0.55)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(inner, outer, notch);
    }
  }

  @override
  bool shouldRepaint(ArcGaugePainter old) =>
      old.t != t ||
      old.color != color ||
      old.stroke != stroke ||
      old.trackColor != trackColor ||
      old.sweepFraction != sweepFraction ||
      old.target != target ||
      old.confidence != confidence ||
      old.endDot != endDot;
}
