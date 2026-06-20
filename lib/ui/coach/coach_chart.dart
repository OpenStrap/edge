// Renders a ChartSpec (built by the coach from real data) as an ANIMATED native
// chart, using the app's look. Bars reuse LabeledBars; line/area use an animated
// multi-series painter. Honest: it only ever plots the numbers the model passed.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../coach/coach_engine.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class CoachChart extends StatelessWidget {
  final ChartSpec spec;
  const CoachChart({super.key, required this.spec});

  List<Color> get _colors => [
        AppColors.coral,
        AppColors.good,
        AppColors.loadDetraining,
        AppColors.warn,
        AppColors.coralDeep,
      ];

  @override
  Widget build(BuildContext context) {
    final single = spec.series.length == 1;
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (spec.title.isNotEmpty) Text(spec.title, style: AppText.title),
        if (spec.unit.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(spec.unit, style: AppText.captionMuted),
        ],
        const SizedBox(height: Sp.x4),
        if (spec.type == 'bar' && single)
          LabeledBars(
            values: spec.series.first.values.map((v) => v ?? 0).toList(),
            labels: _fitLabels(spec.xLabels, spec.series.first.values.length),
            color: AppColors.coral,
            height: 160,
          )
        else
          _AnimatedLineChart(spec: spec, colors: _colors, filled: spec.type == 'area'),
        if (!single) ...[
          const SizedBox(height: Sp.x3),
          Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
            for (int i = 0; i < spec.series.length; i++)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 9, height: 9, decoration: BoxDecoration(
                    color: _colors[i % _colors.length], shape: BoxShape.circle)),
                const SizedBox(width: Sp.x2),
                Text(spec.series[i].name, style: AppText.caption),
              ]),
          ]),
        ],
        if (spec.note != null && spec.note!.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          Text(spec.note!, style: AppText.captionMuted),
        ],
      ]),
    );
  }

  List<String> _fitLabels(List<String> labels, int n) {
    if (labels.length == n) return labels;
    return List.generate(n, (i) => i < labels.length ? labels[i] : '');
  }
}

class _AnimatedLineChart extends StatelessWidget {
  final ChartSpec spec;
  final List<Color> colors;
  final bool filled;
  const _AnimatedLineChart({required this.spec, required this.colors, required this.filled});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (_, t, _) => SizedBox(
        height: 170,
        width: double.infinity,
        child: CustomPaint(
          painter: _LinePainter(spec: spec, colors: colors, filled: filled, progress: t,
              grid: AppColors.divider, label: AppColors.inkMuted),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final ChartSpec spec;
  final List<Color> colors;
  final bool filled;
  final double progress;
  final Color grid;
  final Color label;
  _LinePainter({required this.spec, required this.colors, required this.filled,
      required this.progress, required this.grid, required this.label});

  @override
  void paint(Canvas canvas, Size size) {
    final all = <double>[];
    for (final s in spec.series) {
      for (final v in s.values) {
        if (v != null) all.add(v);
      }
    }
    if (all.isEmpty) return;
    var lo = all.reduce(math.min), hi = all.reduce(math.max);
    if (lo == hi) { lo -= 1; hi += 1; }
    final pad = (hi - lo) * 0.1;
    lo -= pad; hi += pad;

    const leftPad = 4.0, bottomPad = 16.0, topPad = 4.0;
    final chartW = size.width - leftPad;
    final chartH = size.height - bottomPad - topPad;

    // baseline grid
    final gridPaint = Paint()..color = grid..strokeWidth = 1;
    for (int g = 0; g <= 2; g++) {
      final y = topPad + chartH * g / 2;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
    }

    final maxLen = spec.series.map((s) => s.values.length).fold<int>(0, math.max);
    if (maxLen < 1) return;
    // guard the single-point case (no divide-by-zero) → place it centered.
    double xAt(int i) => maxLen == 1 ? leftPad + chartW / 2 : leftPad + chartW * i / (maxLen - 1);
    double yAt(double v) => topPad + chartH * (1 - (v - lo) / (hi - lo));

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    for (int si = 0; si < spec.series.length; si++) {
      final s = spec.series[si];
      final color = colors[si % colors.length];
      final path = Path();
      final pts = <Offset>[];
      bool started = false;
      for (int i = 0; i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) continue;
        final pt = Offset(xAt(i), yAt(v));
        pts.add(pt);
        if (!started) { path.moveTo(pt.dx, pt.dy); started = true; }
        else { path.lineTo(pt.dx, pt.dy); }
      }
      if (!started) continue;

      if (filled && pts.length > 1) {
        final fill = Path.from(path)
          ..lineTo(pts.last.dx, topPad + chartH)
          ..lineTo(pts.first.dx, topPad + chartH)
          ..close();
        canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.14)..style = PaintingStyle.fill);
      }
      // the line (only meaningful with ≥2 points)
      if (pts.length > 1) {
        canvas.drawPath(path, Paint()
          ..color = color
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
      }
      // dots at every point so single values + vertices are always visible
      final dot = Paint()..color = color..style = PaintingStyle.fill;
      for (final p in pts) {
        canvas.drawCircle(p, pts.length == 1 ? 5 : 3, dot);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.progress != progress || old.spec != spec;
}
