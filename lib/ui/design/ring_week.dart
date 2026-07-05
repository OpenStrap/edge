// RingWeek — the M–S week-of-mini-rings tracker from the refs: seven small
// progress rings with weekday initials, today emphasized, honest empty rings
// for missing days. One glance answers "how consistent was my week?".
//
//   RingWeek(values: [0.8, 1.0, null, 0.4, …], todayIndex: 4)
//
// values are 0..1 fills aligned Monday→Sunday (null = no data that day).

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'arc_gauge.dart';

class RingWeek extends StatelessWidget {
  /// Monday→Sunday fills, 0..1; null = no data (empty ring).
  final List<double?> values;

  /// Which index is today (highlighted label + full-strength ring).
  final int? todayIndex;

  final Color? color;
  final double ringSize;

  /// Day initials under the rings; defaults to Monday-first M…S. Pass your own
  /// when the 7-day window doesn't start on Monday.
  final List<String>? labels;

  const RingWeek({
    super.key,
    required this.values,
    this.todayIndex,
    this.color,
    this.ringSize = 30,
    this.labels,
  });

  static const _days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;
    final n = values.length.clamp(0, 7);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < n; i++)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArcGauge(
                value: values[i] == null
                    ? double.nan
                    : values[i]!.clamp(0.0, 1.0),
                color: i == todayIndex ? c : c.withValues(alpha: 0.55),
                size: ringSize,
                stroke: 3.5,
                animate: false,
              ),
              const SizedBox(height: Sp.x1),
              Text(
                (labels != null && i < labels!.length)
                    ? labels![i]
                    : _days[i % 7],
                style: AppText.captionMuted.copyWith(
                  fontSize: 10,
                  fontWeight: i == todayIndex
                      ? FontWeight.w800
                      : FontWeight.w600,
                  color: i == todayIndex ? AppColors.ink : null,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
