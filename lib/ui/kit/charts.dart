// OpenStrap chart kit — rings, sparkline bars, labeled week bars, area sparks,
// the coral dot-matrix, and the composite StatTile. All paper-on-coral styled.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'kit.dart';

/// A circular progress ring with a value in the center. Used for readiness /
/// strain / sleep-fill. `t` is 0..1 fill; `color` the arc color.
class RingStat extends StatelessWidget {
  final double t; // 0..1 (NaN → muted empty ring)
  final Color color;
  final double size;
  final double stroke;
  final Widget center;
  const RingStat({
    super.key,
    required this.t,
    required this.color,
    required this.center,
    this.size = 160,
    this.stroke = 14,
  });
  @override
  Widget build(BuildContext context) {
    final fill = t.isNaN ? 0.0 : t.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        duration: Motion.ring,
        curve: Motion.emphatic,
        tween: Tween(begin: 0, end: fill),
        builder: (_, v, _) => CustomPaint(
          painter: _RingPainter(v, color, stroke),
          child: Center(child: center),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double t;
  final Color color;
  final double stroke;
  _RingPainter(this.t, this.color, this.stroke);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = (size.width - stroke) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AppColors.surfaceAlt;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), 0, math.pi * 2, false,
        track);
    if (t <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: [color.withValues(alpha: 0.85), color],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        math.pi * 2 * t, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.t != t || old.color != color || old.stroke != stroke;
}

/// Tiny sparkline bars (for inside cards). Values normalized to their own max.
class MiniBars extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  final double gap;
  const MiniBars(this.values,
      {super.key, this.color = AppColors.coral, this.height = 40, this.gap = 3});
  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return SizedBox(height: height);
    final maxV = values.reduce(math.max);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < values.length; i++) ...[
            Expanded(
              child: TweenAnimationBuilder<double>(
                duration: Motion.med,
                curve: Motion.curve,
                tween: Tween(
                    begin: 0, end: maxV == 0 ? 0 : (values[i] / maxV)),
                builder: (_, v, _) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: math.max(3, v * height),
                    decoration: BoxDecoration(
                      color: color.withValues(
                          alpha: 0.4 + 0.6 * (maxV == 0 ? 0 : values[i] / maxV)),
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                  ),
                ),
              ),
            ),
            if (i != values.length - 1) SizedBox(width: gap),
          ]
        ],
      ),
    );
  }
}

/// Labeled bar chart (e.g. weekly goal, Mon..Sun) — big rounded coral bars.
/// Shows the numeric value above each bar (set [showValues] false to hide).
/// [onTapBar] makes a bar tappable (drill-down in the Metric Explorer).
class LabeledBars extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;
  final int? highlight;
  final bool showValues;
  final String Function(double v)? valueFmt; // how to render the number
  final void Function(int i)? onTapBar;
  const LabeledBars({
    super.key,
    required this.values,
    required this.labels,
    this.color = AppColors.coral,
    this.height = 200,
    this.highlight,
    this.showValues = true,
    this.valueFmt,
    this.onTapBar,
  });

  String _fmt(double v) {
    if (valueFmt != null) return valueFmt!(v);
    // tidy default: integers when whole, else one decimal; blank for exact 0.
    if (v == 0) return '';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final maxV = values.isEmpty ? 1.0 : math.max(1.0, values.reduce(math.max));
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < values.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: onTapBar == null ? null : () => onTapBar!(i),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (showValues)
                        Text(_fmt(values[i]),
                            style: AppText.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: (highlight == null || highlight == i)
                                  ? AppColors.ink
                                  : AppColors.inkMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.visible),
                      if (showValues) const SizedBox(height: 2),
                      Expanded(
                        child: TweenAnimationBuilder<double>(
                          duration: Motion.med,
                          curve: Motion.emphatic,
                          tween: Tween(begin: 0, end: values[i] / maxV),
                          builder: (_, v, _) => FractionallySizedBox(
                            heightFactor: v.clamp(0.02, 1.0),
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: (highlight == null || highlight == i)
                                    ? color
                                    : color.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(R.pill),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: Sp.x2),
                      Text(labels.length > i ? labels[i] : '',
                          style: AppText.caption),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Smooth area spark (HR / strain over a window) using fl_chart.
class AreaSpark extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  const AreaSpark(this.values,
      {super.key, this.color = AppColors.coral, this.height = 90});
  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
          height: height,
          child: Center(
              child: Text('Not enough data yet', style: AppText.captionMuted)));
    }
    final spots = [
      for (int i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])
    ];
    final minY = values.reduce(math.min);
    final maxY = values.reduce(math.max);
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minY - (maxY - minY) * 0.15 - 0.5,
          maxY: maxY + (maxY - minY) * 0.15 + 0.5,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: color,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.28), Colors.transparent],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Coral dot-matrix column chart (ref #2 Stats). Each column is a stack of
/// rounded squares; filled count ∝ value. Great for week/month step-like data.
class DotMatrix extends StatelessWidget {
  final List<double> values;
  final int rows;
  final Color color;
  final double cell;
  const DotMatrix(this.values,
      {super.key, this.rows = 12, this.color = AppColors.coral, this.cell = 12});
  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final maxV = math.max(1.0, values.reduce(math.max));
    return LayoutBuilder(builder: (context, c) {
      return SizedBox(
        height: rows * (cell + 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final v in values)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (int r = rows - 1; r >= 0; r--)
                      Padding(
                        padding: const EdgeInsets.all(2),
                        child: Container(
                          height: cell,
                          decoration: BoxDecoration(
                            color: ((v / maxV) * rows) > r
                                ? color.withValues(
                                    alpha: 0.45 + 0.55 * (r / rows))
                                : color.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// Horizontal multi-segment bar (HR zones z1..z5).
class SegmentBar extends StatelessWidget {
  final List<double> values;
  final List<Color> colors;
  final double height;
  const SegmentBar(this.values, this.colors, {super.key, this.height = 12});
  @override
  Widget build(BuildContext context) {
    final total = values.fold<double>(0, (s, v) => s + v);
    if (total <= 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(R.pill)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.pill),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (int i = 0; i < values.length; i++)
              if (values[i] > 0)
                Expanded(
                  flex: math.max(1, (values[i] / total * 1000).round()),
                  child: Container(
                      color: colors[i % colors.length],
                      margin: const EdgeInsets.symmetric(horizontal: 0.5)),
                ),
          ],
        ),
      ),
    );
  }
}

/// Composite stat tile: icon + label, big number + unit, optional delta + spark.
/// Renders "—" muted when [value] is null. Confidence dot + honesty tag optional.
class StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final String? unit;
  final num? deltaPct;
  final bool deltaGoodIsUp;
  final List<double>? spark;
  final Color accent;
  final double? confidence;
  final Widget? tag;
  final VoidCallback? onTap;
  const StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.deltaPct,
    this.deltaGoodIsUp = true,
    this.spark,
    this.accent = AppColors.coral,
    this.confidence,
    this.tag,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 110),
      child: ProCard(
        onTap: onTap,
        padding: const EdgeInsets.all(Sp.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(R.chip),
                    ),
                    child: AppIcon(icon, size: 16, color: accent),
                  ),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: Text(label,
                        style: AppText.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (confidence != null) ConfDot(confidence!),
                ]),
                const SizedBox(height: Sp.x3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    if (value == null)
                      metricDash(24)
                    else
                      Flexible(
                        child: Text(value!,
                            style: AppText.metric.copyWith(fontSize: 22),
                            overflow: TextOverflow.ellipsis),
                      ),
                    if (unit != null && value != null) ...[
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(unit!,
                            style: AppText.caption.copyWith(
                                color: AppColors.inkMuted, fontSize: 11)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (deltaPct != null || tag != null || spark != null) ...[
              const SizedBox(height: Sp.x2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (deltaPct != null)
                          Flexible(
                              child: DeltaChip(deltaPct,
                                  goodIsUp: deltaGoodIsUp)),
                        if (tag != null) ...[
                          if (deltaPct != null) const SizedBox(width: Sp.x2),
                          Flexible(child: tag!),
                        ],
                      ],
                    ),
                  ),
                  if (spark != null && spark!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: Sp.x2),
                      child: SizedBox(
                          width: 48,
                          child: MiniBars(spark!, color: accent, height: 22)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// FormChart — Banister Fitness vs Fatigue dual line (with a soft band between),
/// for the Body tab. Pass aligned series (oldest→newest); nulls are skipped.
class FormChart extends StatelessWidget {
  final List<double?> fitness;
  final List<double?> fatigue;
  final double height;
  const FormChart({super.key, required this.fitness, required this.fatigue, this.height = 130});
  @override
  Widget build(BuildContext context) {
    final fit = <FlSpot>[];
    final fat = <FlSpot>[];
    for (int i = 0; i < fitness.length; i++) {
      final v = fitness[i];
      if (v != null) fit.add(FlSpot(i.toDouble(), v));
    }
    for (int i = 0; i < fatigue.length; i++) {
      final v = fatigue[i];
      if (v != null) fat.add(FlSpot(i.toDouble(), v));
    }
    if (fit.length < 2 && fat.length < 2) {
      return SizedBox(height: height, child: Center(child: Text('Not enough data yet', style: AppText.captionMuted)));
    }
    final all = [...fit, ...fat].map((s) => s.y);
    final minY = all.reduce(math.min), maxY = all.reduce(math.max);
    LineChartBarData bar(List<FlSpot> s, Color c, {bool fill = false}) => LineChartBarData(
          spots: s, isCurved: true, curveSmoothness: 0.3, color: c, barWidth: 2.5,
          dotData: const FlDotData(show: false),
          belowBarData: fill
              ? BarAreaData(show: true, gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [c.withValues(alpha: 0.18), Colors.transparent]))
              : BarAreaData(show: false),
        );
    return SizedBox(
      height: height,
      child: LineChart(LineChartData(
        minY: minY - (maxY - minY) * 0.15 - 0.5,
        maxY: maxY + (maxY - minY) * 0.15 + 0.5,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [bar(fit, AppColors.coral, fill: true), bar(fat, AppColors.loadDetraining)],
      )),
    );
  }
}

/// CalendarHeatmap — a month grid (weeks × 7) of cells colored by a metric. Pass
/// day entries with a 0..1 intensity `t` and a base color; null `t` = no data.
class CalendarHeatmap extends StatelessWidget {
  final List<({DateTime date, double? t})> days;
  final Color color;
  final double cell;
  const CalendarHeatmap({super.key, required this.days, this.color = AppColors.good, this.cell = 16});
  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    // Pad the front so the first day lands on its weekday column (Mon=0).
    final first = days.first.date;
    final lead = (first.weekday + 6) % 7; // Mon=0
    final cells = <({DateTime? date, double? t})>[
      for (int i = 0; i < lead; i++) (date: null, t: null),
      for (final d in days) (date: d.date, t: d.t),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        for (final l in wd)
          SizedBox(width: cell + 4, child: Text(l, textAlign: TextAlign.center, style: AppText.captionMuted)),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4, children: [
        for (final c in cells)
          Container(
            width: cell, height: cell,
            decoration: BoxDecoration(
              color: c.date == null
                  ? Colors.transparent
                  : (c.t == null ? AppColors.surfaceSunk : color.withValues(alpha: (0.18 + 0.82 * c.t!.clamp(0, 1)))),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ]),
    ]);
  }
}
