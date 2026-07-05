// MetricCard — the glanceable workhorse of the numbers-first design.
//
// Big tabular number + unit + a tiny overline label; everything else is
// optional and quiet: an inline Sparkline OR a mini ArcGauge, a delta/baseline
// chip, a confidence dot, an honesty tag, an (i) that opens the InfoSheet, and
// whole-card tap-through to the detail screen. Explanatory copy NEVER renders
// on the card itself.
//
//   MetricCard(
//     label: 'Resting HR', icon: Ic.heart,
//     value: '52', unit: 'bpm', animateFrom: 52,
//     delta: BaselineDeltaChip(-2, unit: 'bpm', goodIsUp: false),
//     spark: rhr7d,
//     info: MetricInfo(title: 'Resting heart rate', body: '…'),
//     onTap: () => …detail…,
//   )

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon, ConfDot, metricDash;
import '../kit/os_icons.dart';
import 'controls.dart';
import 'motion.dart';
import 'spark.dart';
import 'surface.dart';

/// The copy behind a MetricCard's (i) — shown only in the InfoSheet.
class MetricInfo {
  final String title;
  final String? body;
  final List<String> bullets;
  final String? methodNote;
  const MetricInfo({
    required this.title,
    this.body,
    this.bullets = const [],
    this.methodNote,
  });
}

class MetricCard extends StatelessWidget {
  /// Tiny overline label ("RESTING HR").
  final String label;
  final IconData? icon;

  /// Illustrated variant — takes precedence over [icon] inside the chip.
  /// Rendered at 32px (the art carries built-in transparent padding).
  final OsIcon? osIcon;

  /// The formatted value ("52", "7:42"). Null renders the honest em-dash.
  final String? value;
  final String? unit;

  /// When set (and [value] parses as a plain number), the number counts up to
  /// it on first build — the celebratory reveal from the refs.
  final num? animateFrom;

  /// Formatter for the count-up frames (defaults to round-to-[value]'s
  /// decimal places).
  final String Function(num v)? format;

  /// Optional chip row content (DeltaChip / BaselineDeltaChip / StatusChip).
  final Widget? delta;

  /// Optional honesty tag (est/beta/rel) beside the label.
  final Widget? tag;

  /// Inline 7-day trend. Mutually exclusive with [gauge] (spark wins).
  final List<double?>? spark;

  /// Mini ring (e.g. goal fill) rendered on the trailing edge.
  final Widget? gauge;

  final Color? accent;
  final double? confidence;

  /// The (i) affordance — opens an InfoSheet; nothing renders up-front.
  final MetricInfo? info;

  /// Whole-card tap-through to the metric's detail screen.
  final VoidCallback? onTap;

  /// Staggered fade-up on first build (pass the grid/list index).
  final int? entranceIndex;

  /// Semantic size: hero cards get the display-size number.
  final bool hero;

  const MetricCard({
    super.key,
    required this.label,
    this.icon,
    this.osIcon,
    required this.value,
    this.unit,
    this.animateFrom,
    this.format,
    this.delta,
    this.tag,
    this.spark,
    this.gauge,
    this.accent,
    this.confidence,
    this.info,
    this.onTap,
    this.entranceIndex,
    this.hero = false,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? AppColors.accent;
    final valueStyle = hero
        ? AppText.display
        : AppText.metric.copyWith(fontSize: 26, letterSpacing: -0.5);

    final header = Row(
      children: [
        if (osIcon != null || icon != null) ...[
          Container(
            padding: EdgeInsets.all(osIcon != null ? 1 : 6),
            decoration: BoxDecoration(
              color: a.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: osIcon != null
                ? OsAppIcon(osIcon!, size: 32)
                : AppIcon(icon!, size: 15, color: a),
          ),
          const SizedBox(width: Sp.x2),
        ],
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: AppText.overline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (tag != null) ...[tag!, const SizedBox(width: 2)],
        if (confidence != null) ConfDot(confidence!),
        if (info != null)
          // Pull the padded hit-target back so the glyph aligns to the edge.
          SizedBox(
            width: 26,
            height: 26,
            child: FittedBox(
              child: InfoDot(
                title: info!.title,
                body: info!.body,
                bullets: info!.bullets,
                methodNote: info!.methodNote,
              ),
            ),
          ),
      ],
    );

    final valueRow = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (value == null)
          metricDash(hero ? 40 : 26)
        else
          Flexible(
            child: animateFrom == null
                ? Text(
                    value!,
                    style: valueStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : _CountUpText(
                    target: animateFrom!,
                    finalText: value!,
                    format: format,
                    style: valueStyle,
                  ),
          ),
        if (unit != null && value != null) ...[
          const SizedBox(width: Sp.x1),
          Text(
            unit!,
            style: AppText.caption.copyWith(
              color: AppColors.onSurfaceFaint,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );

    final trailingGauge = gauge;
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      entranceIndex: entranceIndex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          SizedBox(height: hero ? Sp.x3 : Sp.x2 + 2),
          if (trailingGauge != null)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      valueRow,
                      if (delta != null) ...[
                        const SizedBox(height: Sp.x2),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: delta!.dsPop(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Sp.x3),
                trailingGauge,
              ],
            )
          else ...[
            valueRow,
            if (delta != null || (spark?.isNotEmpty ?? false)) ...[
              const SizedBox(height: Sp.x3),
              Row(
                children: [
                  if (delta != null)
                    Flexible(fit: FlexFit.loose, child: delta!.dsPop()),
                  if (spark != null && spark!.isNotEmpty) ...[
                    if (delta != null) const SizedBox(width: Sp.x3),
                    Expanded(
                      child: Sparkline(
                        spark!,
                        color: a,
                        height: hero ? 40 : 28,
                      ),
                    ),
                  ] else if (delta != null)
                    const Spacer(),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Big-number count-up: sweeps 0 → target with tabular figures (no jitter),
/// then snaps to the exact [finalText] so formatting is always right.
class _CountUpText extends StatelessWidget {
  final num target;
  final String finalText;
  final String Function(num v)? format;
  final TextStyle style;
  const _CountUpText({
    required this.target,
    required this.finalText,
    required this.format,
    required this.style,
  });

  String _fmt(num v) {
    if (format != null) return format!(v);
    // Match the final text's decimal places.
    final dot = finalText.indexOf('.');
    final places = dot < 0 ? 0 : finalText.length - dot - 1;
    return v.toStringAsFixed(places);
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: Motion.celebratory.d,
      curve: Motion.celebratory.c,
      tween: Tween(begin: 0, end: target.toDouble()),
      builder: (_, v, _) {
        final done = (v - target.toDouble()).abs() < 1e-9;
        return Text(
          done ? finalText : _fmt(v),
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
