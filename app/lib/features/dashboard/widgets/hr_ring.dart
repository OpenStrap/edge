import 'dart:math';
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

class HrRing extends StatefulWidget {
  final int? heartRate;
  final double size;

  const HrRing({super.key, this.heartRate, this.size = 220});

  @override
  State<HrRing> createState() => _HrRingState();
}

class _HrRingState extends State<HrRing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<double> _pulse;

  int? _lastHr;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _resetPulse();
  }

  @override
  void didUpdateWidget(HrRing old) {
    super.didUpdateWidget(old);
    if (widget.heartRate != _lastHr && widget.heartRate != null) {
      _lastHr = widget.heartRate;
      _triggerBeat();
    }
  }

  void _resetPulse() {
    _pulse = Tween<double>(begin: 1.0, end: 1.0).animate(_ctrl);
  }

  void _triggerBeat() {
    _pulse = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.05).chain(CurveTween(curve: Curves.easeOut)),
          weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 1.05, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
          weight: 70),
    ]).animate(_ctrl);
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hr = widget.heartRate;
    final progress = hr != null ? (hr / 200.0).clamp(0.0, 1.0) : 0.0;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        return Transform.scale(
          scale: _pulse.value,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Ring painter
                CustomPaint(
                  size: Size(widget.size, widget.size),
                  painter: _RingPainter(progress: progress, hr: hr),
                ),
                // HR value
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hr != null ? '$hr' : '--',
                      style: TextStyle(
                        color: WhoopColors.textPrimary,
                        fontSize: widget.size * 0.36,
                        fontWeight: FontWeight.w200,
                        letterSpacing: -4,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'BPM',
                      style: TextStyle(
                        color: WhoopColors.textSecondary,
                        fontSize: 11,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final int? hr;

  _RingPainter({required this.progress, required this.hr});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;
    const strokeWidth = 8.0;

    // Background track
    final trackPaint = Paint()
      ..color = WhoopColors.cardBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    if (progress <= 0) return;

    // Progress arc — red gradient
    final sweepAngle = 2 * pi * progress;
    const startAngle = -pi / 2;

    final arcColor = _hrColor(hr);

    final arcPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          arcColor.withOpacity(0.7),
          arcColor,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      arcPaint,
    );

    // Glow effect at tip
    final tipAngle = startAngle + sweepAngle;
    final tipX = center.dx + radius * cos(tipAngle);
    final tipY = center.dy + radius * sin(tipAngle);

    final glowPaint = Paint()
      ..color = arcColor.withOpacity(0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(tipX, tipY), 8, glowPaint);

    final dotPaint = Paint()..color = arcColor;
    canvas.drawCircle(Offset(tipX, tipY), strokeWidth / 2, dotPaint);
  }

  Color _hrColor(int? hr) {
    if (hr == null) return WhoopColors.primary;
    if (hr < 60) return const Color(0xFF42A5F5);  // low — blue
    if (hr < 100) return WhoopColors.primary;      // normal — red
    if (hr < 140) return WhoopColors.accent;       // moderate — orange
    return const Color(0xFFFF1744);                 // high — bright red
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.hr != hr;
}
