// OpenStrap chart kit — rings, sparkline bars, labeled week bars, area sparks,
// the coral dot-matrix, and the composite StatTile. All paper-on-coral styled.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../models/metric.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'kit.dart';
import '../design/arc_gauge.dart';
import '../design/controls.dart' show StatusChip, ChipTone;
import '../design/domains.dart' show DomainAccent;

/// A circular progress gauge with a value in the center — the richer engine
/// behind [RingStat]. Adds an optional zone-tinted track, an optional target
/// notch, a confidence-aware arc (faint + dashed when the value is uncertain),
/// and the first-reveal sweep. `t` is 0..1 fill; `color` the arc color.
class Gauge extends StatelessWidget {
  final double t; // 0..1 (NaN → muted empty ring)
  final Color color;
  final double size;
  final double stroke;
  final Widget center;

  /// If set, the track is tinted with this zone's soft colour (0..5) instead of
  /// the neutral surfaceAlt — reads as "you're in zone N".
  final int? zoneTint;

  /// Optional goal marker at this 0..1 fraction — a short notch on the track.
  final double? target;

  /// 0..1 — 1.0 paints the arc solid; lower fades it (and dashes it below 0.4)
  /// so a low-confidence value reads as visually uncertain.
  final double confidence;

  const Gauge({
    super.key,
    required this.t,
    required this.color,
    required this.center,
    this.size = 160,
    this.stroke = 14,
    this.zoneTint,
    this.target,
    this.confidence = 1.0,
  });

  @override
  Widget build(BuildContext context) => ArcGauge(
    value: t,
    color: color,
    size: size,
    stroke: stroke,
    zone: zoneTint,
    target: target,
    confidence: confidence,
    center: center,
  );
}

/// A circular progress ring with a value in the center. Used for readiness /
/// strain / sleep-fill. `t` is 0..1 fill; `color` the arc color. Thin delegate
/// over [Gauge] so its ~dozens of call sites keep working unchanged.
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
  Widget build(BuildContext context) => Gauge(
    t: t,
    color: color,
    size: size,
    stroke: stroke,
    center: center,
  );
}

/// BaselineProgress — the honest "still learning you" state, rendered as a
/// partially-filled [Gauge] (nights collected / nights needed) with the count
/// remaining in the centre and a line saying what it unlocks. Replaces the bare
/// "Need N more nights" text where a baseline is still filling in.
class BaselineProgress extends StatelessWidget {
  final int collected;
  final int needed;
  final String unlocks; // e.g. 'to unlock Readiness'
  final Color? color;
  final double size;
  const BaselineProgress({
    super.key,
    required this.collected,
    required this.needed,
    this.unlocks = '',
    this.color,
    this.size = 150,
  });

  /// Build from a baseline-gated [Metric] (`need_baseline:have=H,need=N`).
  /// Returns null if the metric isn't a baseline abstention.
  static BaselineProgress? fromMetric(
    Metric m, {
    String unlocks = '',
    Color? color,
    double size = 150,
    Key? key,
  }) {
    final note = m.note;
    if (note == null || !note.contains('need_baseline:')) return null;
    final match = RegExp(r'have=(\d+),need=(\d+)').firstMatch(note);
    if (match == null) return null;
    final have = int.tryParse(match.group(1)!) ?? 0;
    final need = int.tryParse(match.group(2)!) ?? 0;
    if (need <= 0) return null;
    return BaselineProgress(
      key: key,
      collected: have.clamp(0, need),
      needed: need,
      unlocks: unlocks,
      color: color,
      size: size,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.coral;
    final remaining = (needed - collected).clamp(0, needed);
    final frac = needed == 0 ? 0.0 : (collected / needed).clamp(0.0, 1.0);
    final numSize = (size * 0.28).clamp(20.0, 44.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Gauge(
          t: frac,
          color: c,
          size: size,
          stroke: size < 110 ? 10 : 12,
          center: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$remaining', style: AppText.display.copyWith(fontSize: numSize)),
              Text(
                remaining == 1 ? 'night to go' : 'nights to go',
                style: AppText.caption.copyWith(fontSize: size < 110 ? 9.5 : 12),
              ),
            ],
          ),
        ),
        if (unlocks.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          Text(
            unlocks,
            style: AppText.bodySoft,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '$collected of $needed nights',
            style: AppText.captionMuted,
          ),
        ],
      ],
    );
  }
}

/// Tiny sparkline bars (for inside cards). Values normalized to their own max.
class MiniBars extends StatelessWidget {
  final List<double> values;
  final Color? color;
  final double height;
  final double gap;
  const MiniBars(
    this.values, {
    super.key,
    this.color,
    this.height = 40,
    this.gap = 3,
  });
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.coral;
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
                tween: Tween(begin: 0, end: maxV == 0 ? 0 : (values[i] / maxV)),
                builder: (_, v, _) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: math.max(3, v * height),
                    decoration: BoxDecoration(
                      color: color.withValues(
                        alpha: 0.4 + 0.6 * (maxV == 0 ? 0 : values[i] / maxV),
                      ),
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                  ),
                ),
              ),
            ),
            if (i != values.length - 1) SizedBox(width: gap),
          ],
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
  final Color? color;
  final double height;
  final int? highlight;
  final bool showValues;
  final String Function(double v)? valueFmt; // how to render the number
  final void Function(int i)? onTapBar;
  const LabeledBars({
    super.key,
    required this.values,
    required this.labels,
    this.color,
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
    final color = this.color ?? AppColors.coral;
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
                        Text(
                          _fmt(values[i]),
                          style: AppText.caption.copyWith(
                            fontWeight: FontWeight.w600,
                            color: (highlight == null || highlight == i)
                                ? AppColors.ink
                                : AppColors.inkMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                        ),
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
                      Text(
                        labels.length > i ? labels[i] : '',
                        style: AppText.caption,
                      ),
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
  final Color? color;
  final double height;
  const AreaSpark(this.values, {super.key, this.color, this.height = 90});
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.coral;
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('Not enough data yet', style: AppText.captionMuted),
        ),
      );
    }
    final spots = [
      for (int i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
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

class TimeSeriesPoint {
  final double x;
  final double y;
  const TimeSeriesPoint(this.x, this.y);
}

class HorizontalBand {
  final double fromY;
  final double toY;
  final Color color;
  const HorizontalBand(this.fromY, this.toY, this.color);
}

class VerticalSpan {
  final double fromX;
  final double toX;
  final Color color;
  const VerticalSpan(this.fromX, this.toX, this.color);
}

class VerticalMarker {
  final double x;
  final Color color;
  final double strokeWidth;
  const VerticalMarker(this.x, this.color, {this.strokeWidth = 1.5});
}

class TimeSeriesChart extends StatefulWidget {
  final List<TimeSeriesPoint> points;
  final Color? color;
  final double height;
  final double? minX;
  final double? maxX;
  final String? yUnit;
  final String Function(double value)? yLabel;
  final String Function(double value)? xLabel;
  final String Function(TimeSeriesPoint point)? tooltip;
  final bool fill;
  final double gapThresholdSec;
  final double lineWidth;
  final double? minY;
  final double? maxY;
  final List<HorizontalBand> bands;
  final List<VerticalSpan> spans;
  final List<VerticalMarker> markers;
  final double leftPad;
  const TimeSeriesChart({
    super.key,
    required this.points,
    this.color,
    this.height = 220,
    this.minX,
    this.maxX,
    this.yUnit,
    this.yLabel,
    this.xLabel,
    this.tooltip,
    this.fill = true,
    this.gapThresholdSec = 900,
    this.lineWidth = 2.6,
    this.minY,
    this.maxY,
    this.bands = const [],
    this.spans = const [],
    this.markers = const [],
    this.leftPad = 52,
  });

  /// The snapped x upper bound the chart ACTUALLY draws with (the raw hiX is
  /// ceilinged to a span-dependent grid so a live axis doesn't jitter). Any
  /// overlay that maps timestamps to pixels over this chart (HrReplayOverlay,
  /// positioned markers) MUST use this same bound, or its geometry drifts off
  /// the drawn line.
  static double stableTimeUpperBound(double loX, double hiX) {
    final span = hiX - loX;
    if (span <= 0) return hiX;
    double snapSec;
    if (span >= 18 * 3600) {
      snapSec = 15 * 60;
    } else if (span >= 6 * 3600) {
      snapSec = 10 * 60;
    } else if (span >= 3600) {
      snapSec = 5 * 60;
    } else {
      snapSec = 60;
    }
    return (hiX / snapSec).ceilToDouble() * snapSec;
  }

  @override
  State<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends State<TimeSeriesChart> {
  TimeSeriesPoint? _active;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.coral;
    if (widget.points.length < 2) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text('Not enough data yet', style: AppText.captionMuted),
        ),
      );
    }
    final sorted = [...widget.points]..sort((a, b) => a.x.compareTo(b.x));
    final loX = widget.minX ?? sorted.first.x;
    final rawHiX = math.max(widget.maxX ?? sorted.last.x, loX + 1);
    final hiX = _stabilizeTimeUpperBound(loX, rawHiX);
    final ys = [for (final p in sorted) p.y];
    final minYRaw = ys.reduce(math.min);
    final maxYRaw = ys.reduce(math.max);
    final yPad = math.max(2.0, (maxYRaw - minYRaw) * 0.12);
    final loY = widget.minY ?? (minYRaw - yPad);
    final hiY = widget.maxY ?? (maxYRaw + yPad);
    final xInterval = _axisInterval(hiX - loX, targetTicks: 4);
    final yInterval = _axisInterval(hiY - loY, targetTicks: 5);
    final bars = _buildBars(
      sorted,
      color,
      loY,
      widget.fill,
      widget.gapThresholdSec,
      widget.lineWidth,
    );
    final leftPad = widget.leftPad;
    const bottomPad = 30.0;

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chartW = math.max(1.0, constraints.maxWidth - leftPad);
          final chartH = math.max(1.0, widget.height - bottomPad);

          void updateSelection(Offset local) {
            final dx = (local.dx - leftPad).clamp(0.0, chartW);
            final x = loX + (dx / chartW) * (hiX - loX);
            final nearest = _nearest(sorted, x);
            if (nearest != _active) {
              setState(() => _active = nearest);
            }
          }

          final active = _active;
          final activeDx = active == null
              ? null
              : leftPad + ((active.x - loX) / (hiX - loX)) * chartW;
          final activeDy = active == null
              ? null
              : chartH - ((active.y - loY) / (hiY - loY)) * chartH;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) => updateSelection(e.localPosition),
            onHorizontalDragStart: (e) => updateSelection(e.localPosition),
            onHorizontalDragUpdate: (e) => updateSelection(e.localPosition),
            onHorizontalDragEnd: (_) => setState(() => _active = null),
            onHorizontalDragCancel: () => setState(() => _active = null),
            child: Stack(
              children: [
                ExcludeSemantics(
                  child: LineChart(
                    LineChartData(
                      minX: loX,
                      maxX: hiX,
                      minY: loY,
                      maxY: hiY,
                      rangeAnnotations: RangeAnnotations(
                        horizontalRangeAnnotations: [
                          for (final band in widget.bands)
                            HorizontalRangeAnnotation(
                              y1: band.fromY,
                              y2: band.toY,
                              color: band.color,
                            ),
                        ],
                        verticalRangeAnnotations: [
                          for (final span in widget.spans)
                            VerticalRangeAnnotation(
                              x1: span.fromX,
                              x2: span.toX,
                              color: span.color,
                            ),
                        ],
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        horizontalInterval: yInterval,
                        verticalInterval: xInterval,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: AppColors.divider.withValues(alpha: 0.45),
                          strokeWidth: 1,
                        ),
                        getDrawingVerticalLine: (_) => FlLine(
                          color: AppColors.divider.withValues(alpha: 0.24),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: leftPad,
                            interval: yInterval,
                            minIncluded: false,
                            maxIncluded: false,
                            getTitlesWidget: (value, meta) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  widget.yLabel?.call(value) ??
                                      _defaultYLabel(value, widget.yUnit),
                                  style: AppText.captionMuted.copyWith(
                                    fontSize: 10,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: bottomPad,
                            interval: xInterval,
                            minIncluded: false,
                            maxIncluded: false,
                            getTitlesWidget: (value, meta) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  widget.xLabel?.call(value) ??
                                      _defaultXLabel(value),
                                  style: AppText.captionMuted.copyWith(
                                    fontSize: 10,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border(
                          left: BorderSide(
                            color: AppColors.divider.withValues(alpha: 0.7),
                          ),
                          bottom: BorderSide(
                            color: AppColors.divider.withValues(alpha: 0.7),
                          ),
                          right: BorderSide.none,
                          top: BorderSide.none,
                        ),
                      ),
                      extraLinesData: ExtraLinesData(
                        verticalLines: [
                          for (final marker in widget.markers)
                            VerticalLine(
                              x: marker.x,
                              color: marker.color,
                              strokeWidth: marker.strokeWidth,
                              dashArray: const [5, 4],
                            ),
                        ],
                      ),
                      lineTouchData: const LineTouchData(enabled: false),
                      lineBarsData: bars,
                    ),
                  ),
                ),
                if (active != null && activeDx != null && activeDy != null) ...[
                  Positioned(
                    left: activeDx,
                    top: 0,
                    bottom: bottomPad,
                    child: IgnorePointer(
                      child: Container(
                        width: 1.5,
                        color: color.withValues(alpha: 0.32),
                      ),
                    ),
                  ),
                  Positioned(
                    left: activeDx - 5,
                    top: activeDy - 5,
                    child: IgnorePointer(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (activeDx + 8).clamp(
                      leftPad,
                      constraints.maxWidth - 120,
                    ),
                    top: 8,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.night,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Sp.x3,
                            vertical: Sp.x2,
                          ),
                          child: Text(
                            widget.tooltip?.call(active) ??
                                _defaultTooltip(active, widget.yUnit),
                            style: AppText.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  static TimeSeriesPoint _nearest(List<TimeSeriesPoint> points, double x) {
    var best = points.first;
    var bestDist = (best.x - x).abs();
    for (final p in points.skip(1)) {
      final d = (p.x - x).abs();
      if (d < bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  static List<LineChartBarData> _buildBars(
    List<TimeSeriesPoint> sorted,
    Color color,
    double floorY,
    bool fill,
    double gapThresholdSec,
    double lineWidth,
  ) {
    final segments = <List<FlSpot>>[];
    var current = <FlSpot>[];
    for (final p in sorted) {
      if (current.isNotEmpty && p.x - current.last.x > gapThresholdSec) {
        if (current.length >= 2) segments.add(current);
        current = <FlSpot>[];
      }
      current.add(FlSpot(p.x, p.y));
    }
    if (current.length >= 2) segments.add(current);
    return [
      for (final seg in segments)
        LineChartBarData(
          spots: seg,
          isCurved: false,
          color: color,
          barWidth: lineWidth,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: fill,
            cutOffY: floorY,
            applyCutOffY: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.22),
                color.withValues(alpha: 0.02),
              ],
            ),
          ),
        ),
    ];
  }

  static double _axisInterval(double span, {required int targetTicks}) {
    if (span <= 0) return 1;
    return span / math.max(1, targetTicks - 1);
  }

  static double _stabilizeTimeUpperBound(double loX, double hiX) =>
      TimeSeriesChart.stableTimeUpperBound(loX, hiX);

  static String _defaultXLabel(double value) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
    ).toLocal();
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.hour}:$mm';
  }

  static String _defaultYLabel(double value, String? unit) {
    final rounded = value.round();
    return unit == null || unit.isEmpty ? '$rounded' : '$rounded$unit';
  }

  static String _defaultTooltip(TimeSeriesPoint point, String? unit) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (point.x * 1000).round(),
    ).toLocal();
    final mm = dt.minute.toString().padLeft(2, '0');
    final v = point.y.round();
    return '${dt.hour}:$mm\n$v${unit == null || unit.isEmpty ? '' : ' $unit'}';
  }
}

/// Where the peak/low/"now" chip row sits relative to the HR curve.
enum HrChipsPosition { above, below }

/// The shared HR line-chart + chip row. Previously the Today lookback card
/// and the Heart screen's day-detail section each hand-rolled their own copy
/// of this (chips above vs. below, a "now" chip present or not, a same-day
/// `maxX` cutoff or the full day, and a manually re-implemented tooltip that
/// happened to exactly match [TimeSeriesChart]'s own default formatter) — three
/// near-identical HR charts drifting slightly apart. This is the one
/// definition; screens choose position/cutoff/now-chip, nothing else differs.
class HrCurveWithChips extends StatelessWidget {
  final List<TimeSeriesPoint> points;
  final double height;
  final HrChipsPosition chipsPosition;

  /// True caps the x-axis at "now" (Today's still-in-progress day); false
  /// shows the full day (a past, complete day on the Heart screen).
  final bool cutoffToNow;

  /// Show a "Now NNN" chip for the latest point (Heart screen does; Today's
  /// lookback card doesn't — it isn't a live gauge).
  final bool showNowChip;

  const HrCurveWithChips({
    super.key,
    required this.points,
    this.height = 200,
    this.chipsPosition = HrChipsPosition.below,
    this.cutoffToNow = false,
    this.showNowChip = false,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final latest = points.last;
    final peak = points.reduce((a, b) => a.y >= b.y ? a : b);
    final low = points.reduce((a, b) => a.y <= b.y ? a : b);
    final chips = Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x1,
      children: [
        if (showNowChip)
          StatusChip('Now ${latest.y.round()}', tone: ChipTone.accent),
        StatusChip('Peak ${peak.y.round()}',
            tone: showNowChip ? ChipTone.neutral : ChipTone.accent),
        StatusChip('Low ${low.y.round()}'),
      ],
    );
    final chart = TimeSeriesChart(
      points: points,
      color: DomainAccent.heart,
      height: height,
      maxX: cutoffToNow
          ? DateTime.now().millisecondsSinceEpoch / 1000.0
          : null,
      yUnit: ' bpm', // relies on TimeSeriesChart's own default tooltip/labels
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: chipsPosition == HrChipsPosition.above
          ? [chips, const SizedBox(height: Sp.x4), chart]
          : [chart, const SizedBox(height: Sp.x3), chips],
    );
  }
}

/// A play button + a dot that replays an HR line — an [AnimationController]
/// sweeps x across the series while a dot rides the curve. Drop it in as the
/// last child of the host's Stack (it returns a [Positioned.fill]); the host
/// passes the same pixel geometry it used to lay out its [TimeSeriesChart].
class HrReplayOverlay extends StatefulWidget {
  final List<TimeSeriesPoint> points;
  final double loX, hiX, loY, hiY;
  final double leftPad, topInset, chartHeight, bottomPad;
  final Color color;
  const HrReplayOverlay({
    super.key,
    required this.points,
    required this.loX,
    required this.hiX,
    required this.loY,
    required this.hiY,
    required this.chartHeight,
    this.leftPad = 28,
    this.topInset = 8,
    this.bottomPad = 30,
    this.color = const Color(0xFFFF5A36),
  });
  @override
  State<HrReplayOverlay> createState() => _HrReplayOverlayState();
}

class _HrReplayOverlayState extends State<HrReplayOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6000),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_c.isAnimating) {
      _c.stop();
    } else {
      if (_c.value >= 1.0) _c.value = 0;
      _c.forward();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playing = _c.isAnimating;
    return Positioned.fill(
      child: Stack(
        children: [
          if (_c.value > 0 && _c.value < 1)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => CustomPaint(
                    painter: _ReplayDotPainter(
                      points: widget.points,
                      t: _c.value,
                      loX: widget.loX,
                      hiX: widget.hiX,
                      loY: widget.loY,
                      hiY: widget.hiY,
                      leftPad: widget.leftPad,
                      topInset: widget.topInset,
                      plotH: widget.chartHeight - widget.bottomPad,
                      color: widget.color,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 0,
            top: widget.topInset,
            child: Material(
              color: widget.color,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplayDotPainter extends CustomPainter {
  final List<TimeSeriesPoint> points;
  final double t, loX, hiX, loY, hiY, leftPad, topInset, plotH;
  final Color color;
  _ReplayDotPainter({
    required this.points,
    required this.t,
    required this.loX,
    required this.hiX,
    required this.loY,
    required this.hiY,
    required this.leftPad,
    required this.topInset,
    required this.plotH,
    required this.color,
  });

  double _yAt(double x) {
    if (points.isEmpty) return loY;
    if (x <= points.first.x) return points.first.y;
    if (x >= points.last.x) return points.last.y;
    for (var i = 1; i < points.length; i++) {
      if (points[i].x >= x) {
        final a = points[i - 1], b = points[i];
        final f = (b.x - a.x) == 0 ? 0.0 : (x - a.x) / (b.x - a.x);
        return a.y + (b.y - a.y) * f;
      }
    }
    return points.last.y;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - leftPad;
    final x = loX + t * (hiX - loX);
    final y = _yAt(x);
    final px = leftPad + ((x - loX) / (hiX - loX)).clamp(0.0, 1.0) * chartW;
    final py = topInset +
        (1 - ((y - loY) / (hiY - loY)).clamp(0.0, 1.0)) * plotH;
    canvas.drawCircle(Offset(px, py), 9, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawCircle(Offset(px, py), 5, Paint()..color = color);
    canvas.drawCircle(
      Offset(px, py),
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ReplayDotPainter old) => old.t != t;
}

class ZoneTimelineBar extends StatelessWidget {
  final List<TimeSeriesPoint> points; // x=time sec, y=zone number
  final List<Color> colors; // index 0 = below zone 1, 1..5 = z1..z5
  final double minX;
  final double maxX;
  final double height;
  final double leftPad;

  const ZoneTimelineBar({
    super.key,
    required this.points,
    required this.colors,
    required this.minX,
    required this.maxX,
    this.height = 12,
    this.leftPad = 52,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty || maxX <= minX) {
      return Padding(
        padding: EdgeInsets.only(left: leftPad),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(R.pill),
          ),
        ),
      );
    }
    final sorted = [...points]..sort((a, b) => a.x.compareTo(b.x));
    final total = maxX - minX;
    final segments = <({double start, double end, int zone})>[];
    var start = sorted.first.x;
    var zone = sorted.first.y.round().clamp(0, 5);
    for (var i = 1; i < sorted.length; i++) {
      final nextZone = sorted[i].y.round().clamp(0, 5);
      if (nextZone != zone) {
        segments.add((start: start, end: sorted[i].x, zone: zone));
        start = sorted[i].x;
        zone = nextZone;
      }
    }
    segments.add((start: start, end: maxX, zone: zone));

    return Row(
      children: [
        SizedBox(width: leftPad),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(R.pill),
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  for (final seg in segments)
                    if (seg.end > seg.start)
                      Expanded(
                        flex: math.max(
                          1,
                          (((seg.end - seg.start) / total) * 1000).round(),
                        ),
                        child: Container(color: colors[seg.zone]),
                      ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Coral dot-matrix column chart (ref #2 Stats). Each column is a stack of
/// rounded squares; filled count ∝ value. Great for week/month step-like data.
class DotMatrix extends StatelessWidget {
  final List<double> values;
  final int rows;
  final Color? color;
  final double cell;
  const DotMatrix(
    this.values, {
    super.key,
    this.rows = 12,
    this.color,
    this.cell = 12,
  });
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.coral;
    if (values.isEmpty) return const SizedBox.shrink();
    final maxV = math.max(1.0, values.reduce(math.max));
    return LayoutBuilder(
      builder: (context, c) {
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
                                      alpha: 0.45 + 0.55 * (r / rows),
                                    )
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
      },
    );
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
          borderRadius: BorderRadius.circular(R.pill),
        ),
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
                    margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  ),
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
  final OsIcon icon;
  final String label;
  final String? value;
  final String? unit;
  final num? deltaPct;
  final bool deltaGoodIsUp;
  final List<double>? spark;
  final Color? accent;
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
    this.accent,
    this.confidence,
    this.tag,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final accent = this.accent ?? AppColors.coral;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 110),
      child: ProCard(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        pressScale: onTap != null,
        padding: const EdgeInsets.all(Sp.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
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
                      child: Text(
                        label,
                        style: AppText.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (confidence != null) ConfDot(confidence!),
                  ],
                ),
                const SizedBox(height: Sp.x3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    if (value == null)
                      metricDash(24)
                    else
                      Flexible(
                        child: Text(
                          value!,
                          style: AppText.metric.copyWith(fontSize: 22),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (unit != null && value != null) ...[
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          unit!,
                          style: AppText.caption.copyWith(
                            color: AppColors.inkMuted,
                            fontSize: 11,
                          ),
                        ),
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
                            child: DeltaChip(deltaPct, goodIsUp: deltaGoodIsUp),
                          ),
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
                        child: MiniBars(spark!, color: accent, height: 22),
                      ),
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
  const FormChart({
    super.key,
    required this.fitness,
    required this.fatigue,
    this.height = 130,
  });
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
      return SizedBox(
        height: height,
        child: Center(
          child: Text('Not enough data yet', style: AppText.captionMuted),
        ),
      );
    }
    final all = [...fit, ...fat].map((s) => s.y);
    final minY = all.reduce(math.min), maxY = all.reduce(math.max);
    LineChartBarData bar(List<FlSpot> s, Color c, {bool fill = false}) =>
        LineChartBarData(
          spots: s,
          isCurved: true,
          curveSmoothness: 0.3,
          color: c,
          barWidth: 2.5,
          dotData: const FlDotData(show: false),
          belowBarData: fill
              ? BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.withValues(alpha: 0.18), Colors.transparent],
                  ),
                )
              : BarAreaData(show: false),
        );
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
            bar(fit, AppColors.coral, fill: true),
            bar(fat, AppColors.loadDetraining),
          ],
        ),
      ),
    );
  }
}

/// CalendarHeatmap — a month grid (weeks × 7) of cells colored by a metric. Pass
/// day entries with a 0..1 intensity `t` and a base color; null `t` = no data.
class CalendarHeatmap extends StatelessWidget {
  final List<({DateTime date, double? t})> days;
  final Color? color;
  final double cell;
  const CalendarHeatmap({
    super.key,
    required this.days,
    this.color,
    this.cell = 16,
  });
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.good;
    if (days.isEmpty) return const SizedBox.shrink();
    const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    // Pad the front so the first day lands on its weekday column (Mon=0).
    final first = days.first.date;
    final lead = (first.weekday + 6) % 7; // Mon=0
    final cells = <({DateTime? date, double? t})>[
      for (int i = 0; i < lead; i++) (date: null, t: null),
      for (final d in days) (date: d.date, t: d.t),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final l in wd)
              SizedBox(
                width: cell + 4,
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: AppText.captionMuted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final c in cells)
              Container(
                width: cell,
                height: cell,
                decoration: BoxDecoration(
                  color: c.date == null
                      ? Colors.transparent
                      : (c.t == null
                            ? AppColors.surfaceSunk
                            : color.withValues(
                                alpha: (0.18 + 0.82 * c.t!.clamp(0, 1)),
                              )),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
