import 'package:flutter/material.dart';
import '../theme.dart';

/// Horizontal timeline of sleep stages — one rectangle per epoch.
class SleepTimeline extends StatelessWidget {
  final List<int> stages; // 0=wake, 1=light, 2=deep, 3=rem
  final double height;
  const SleepTimeline({super.key, required this.stages, this.height = 64});

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('No stages computed.',
              style: TextStyle(fontFamily: 'monospace', color: WTheme.textMuted, fontSize: 11)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TimelinePainter(stages),
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final List<int> stages;
  _TimelinePainter(this.stages);

  Color _colorFor(int stage) => switch (stage) {
        0 => WTheme.danger,
        1 => WTheme.zoneGreen,
        2 => WTheme.zoneBlue,
        3 => WTheme.zonePurple,
        _ => WTheme.stroke,
      };

  /// Stage Y-band: WAKE high, LIGHT mid-high, REM mid-low, DEEP bottom
  double _yFor(int stage, double h) => switch (stage) {
        0 => h * 0.05,
        1 => h * 0.30,
        3 => h * 0.55,
        2 => h * 0.80,
        _ => h * 0.5,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = WTheme.cardElevated);
    final dx = w / stages.length;
    final barH = h * 0.18;
    for (var i = 0; i < stages.length; i++) {
      final x = i * dx;
      final y = _yFor(stages[i], h);
      canvas.drawRect(
        Rect.fromLTWH(x, y, dx + 0.5, barH),
        Paint()..color = _colorFor(stages[i]),
      );
    }
    // Stage labels.
    final tp = (String text, double y) {
      final p = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
              fontFamily: 'monospace',
              color: WTheme.textMuted,
              fontSize: 9,
              letterSpacing: 1.2),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, Offset(4, y - 2));
    };
    tp('WAKE', h * 0.05);
    tp('LIGHT', h * 0.30);
    tp('REM', h * 0.55);
    tp('DEEP', h * 0.80);
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => old.stages != stages;
}
