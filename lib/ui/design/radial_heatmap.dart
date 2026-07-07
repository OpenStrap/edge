// RadialHeatmap — the radial segmented heatmap from the refs' muscle map: a
// disc of sectors × rings where each sector is a category (muscle group,
// hour-of-day, domain) and fill intensity encodes 0..1 load. Meaningful, not
// decorative: sectors with no data stay honest track-grey, and the strongest
// sector can carry a label callout.
//
//   RadialHeatmap(
//     values: strainByHour,          // one 0..1 (or null) per sector
//     rings: 3,                      // intensity quantized across rings
//     color: DomainAccent.strain,
//     labels: ['12a', '6a', '12p', '6p'],   // quiet compass labels (optional)
//   )

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';

class RadialHeatmap extends StatelessWidget {
  /// One intensity per sector, 0..1; null = no data (honest empty sector).
  final List<double?> values;

  /// Concentric intensity rings (inner fills first — like the refs' map).
  final int rings;

  final Color? color;
  final double size;

  /// Quiet labels. Pass exactly one per sector to label every sector at its
  /// own mid-angle (e.g. seven weekday names); any other count falls back to
  /// up to four compass labels at N/E/S/W.
  final List<String>? labels;

  /// Start angle of sector 0 (default: 12 o'clock).
  final double startAngle;

  const RadialHeatmap({
    super.key,
    required this.values,
    this.rings = 3,
    this.color,
    this.size = 168,
    this.labels,
    this.startAngle = -math.pi / 2,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          duration: Motion.ring,
          curve: Motion.emphatic,
          tween: Tween(begin: 0, end: 1),
          builder: (_, t, _) => CustomPaint(
            painter: _RadialHeatmapPainter(
              values: values,
              rings: rings.clamp(1, 6),
              color: c,
              track: AppColors.surfaceAlt,
              labelColor: AppColors.inkMuted,
              labelStyle: AppText.captionMuted.copyWith(fontSize: 9),
              labels: labels,
              startAngle: startAngle,
              reveal: t,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadialHeatmapPainter extends CustomPainter {
  final List<double?> values;
  final int rings;
  final Color color;
  final Color track;
  final Color labelColor;
  final TextStyle labelStyle;
  final List<String>? labels;
  final double startAngle;
  final double reveal;

  _RadialHeatmapPainter({
    required this.values,
    required this.rings,
    required this.color,
    required this.track,
    required this.labelColor,
    required this.labelStyle,
    required this.labels,
    required this.startAngle,
    required this.reveal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final c = size.center(Offset.zero);
    final outerR = size.shortestSide / 2 - (labels == null ? 2 : 12);
    final innerR = outerR * 0.30;
    final ringW = (outerR - innerR) / rings;
    final n = values.length;
    final sweep = 2 * math.pi / n;
    const gap = 0.035; // radians between sectors

    final paintSeg = Paint()..style = PaintingStyle.stroke;

    for (var i = 0; i < n; i++) {
      final v = values[i];
      final a0 = startAngle + sweep * i + gap / 2;
      final sw = sweep - gap;
      final level = v == null ? 0 : (v.clamp(0.0, 1.0) * rings * reveal);
      for (var r = 0; r < rings; r++) {
        final radius = innerR + ringW * r + ringW / 2;
        paintSeg.strokeWidth = ringW - 2.5;
        // Ring r is "on" when intensity reaches it; partial top ring fades in.
        final fill = (level - r).clamp(0.0, 1.0);
        paintSeg.color = fill <= 0
            ? track
            : Color.lerp(track, color, 0.25 + 0.75 * fill)!;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: radius),
          a0,
          sw,
          false,
          paintSeg,
        );
      }
    }

    // Quiet labels: one per sector (drawn at its mid-angle) when the counts
    // match, else the classic ≤4 compass labels at N/E/S/W.
    final ls = labels;
    if (ls != null && ls.isNotEmpty) {
      final perSector = ls.length == n;
      final count = perSector ? n : math.min(ls.length, 4);
      for (var k = 0; k < count; k++) {
        final a = perSector
            ? startAngle + sweep * (k + 0.5)
            : startAngle + (2 * math.pi / math.min(ls.length, 4)) * k;
        final p = c + Offset(math.cos(a), math.sin(a)) * (outerR + 7);
        final tp = TextPainter(
          text: TextSpan(text: ls[k], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_RadialHeatmapPainter old) =>
      old.values != values ||
      old.color != color ||
      old.reveal != reveal ||
      old.rings != rings;
}
