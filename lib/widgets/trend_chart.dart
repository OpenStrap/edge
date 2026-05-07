import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../theme.dart';

/// Smooth area chart used for HR / recovery / sleep trends.
class TrendChart extends StatelessWidget {
  final List<double> values;
  final List<String>? xLabels;
  final Color color;
  final double height;
  final bool showAxis;
  final double? minY;
  final double? maxY;

  const TrendChart({
    super.key,
    required this.values,
    this.xLabels,
    required this.color,
    this.height = 160,
    this.showAxis = true,
    this.minY,
    this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('Not enough data yet.',
              style: TextStyle(
                  fontFamily: 'monospace', color: WTheme.textMuted, fontSize: 12)),
        ),
      );
    }
    final spots = <FlSpot>[];
    for (var i = 0; i < values.length; i++) {
      spots.add(FlSpot(i.toDouble(), values[i]));
    }
    final lo = minY ?? values.reduce((a, b) => a < b ? a : b);
    final hi = maxY ?? values.reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo) == 0 ? 1 : (hi - lo) * 0.15;

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: (values.length - 1).toDouble(),
          minY: lo - pad,
          maxY: hi + pad,
          gridData: FlGridData(
            show: showAxis,
            drawVerticalLine: false,
            horizontalInterval: ((hi - lo) / 4).clamp(1, double.infinity),
            getDrawingHorizontalLine: (_) => const FlLine(color: WTheme.stroke, strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: showAxis,
                reservedSize: 32,
                getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0),
                    style: const TextStyle(
                        fontFamily: 'monospace', color: WTheme.textMuted, fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: showAxis && xLabels != null,
                reservedSize: 22,
                interval: (values.length / 5).clamp(1, double.infinity),
                getTitlesWidget: (v, _) {
                  final i = v.round();
                  if (xLabels == null || i < 0 || i >= xLabels!.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(xLabels![i],
                        style: const TextStyle(
                            fontFamily: 'monospace', color: WTheme.textMuted, fontSize: 9)),
                  );
                },
              ),
            ),
          ),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.0)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
