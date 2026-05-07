import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../theme.dart';

/// Apple-Watch style ring with a percentage / score in the middle.
class ScoreRing extends StatelessWidget {
  final double value; // 0..1
  final String label; // e.g. "67"
  final String unit; // e.g. "%" or ""
  final String caption; // e.g. "RECOVERY"
  final double size;
  final double strokeWidth;
  final Color? color;

  const ScoreRing({
    super.key,
    required this.value,
    required this.label,
    required this.unit,
    required this.caption,
    this.size = 220,
    this.strokeWidth = 14,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? WTheme.zoneFor(value);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(value: value.clamp(0, 1), color: c, stroke: strokeWidth),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(caption,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 2,
                      color: WTheme.textMuted)),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: size / 3.6,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          color: c)),
                  if (unit.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: size / 16, left: 2),
                      child: Text(unit,
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: size / 12,
                              color: c.withValues(alpha: 0.7))),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color color;
  final double stroke;

  _RingPainter({required this.value, required this.color, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;
    final track = Paint()
      ..color = WTheme.stroke
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    if (value <= 0) return;

    // Sweep from -90deg
    final sweep = 2 * math.pi * value;
    final paint = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: -math.pi / 2 + sweep,
        colors: [color.withValues(alpha: 0.6), color],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.color != color;
}
