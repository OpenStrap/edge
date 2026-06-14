// GenericTrendScreen + TrendMetricRow — the ONE path every metric takes to show
// itself over time. A metric row anywhere taps into the same MetricScreen
// (Today/Week/Month/3M + drill), keyed by its /trend metric key. This is the
// anti-churn core: no metric gets its own bespoke trend screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import 'metric_screen.dart';
import 'metric_row.dart';

/// Open the shared trend screen for any metric key.
void openTrend(
  BuildContext context, {
  required String title,
  required String metric,
  required IconData icon,
  Color accent = AppColors.coral,
  String Function(double v)? valueFmt,
}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => GenericTrendScreen(
      title: title, metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
  ));
}

/// A reusable trend screen for a metric that doesn't need a rich per-day card —
/// the "Today" leaf is a compact current-value + explainer card; the over-time
/// tabs are the standard bars. Built entirely on MetricScreen.
class GenericTrendScreen extends StatelessWidget {
  final String title;
  final String metric;
  final IconData icon;
  final Color accent;
  final String Function(double v)? valueFmt;
  const GenericTrendScreen({
    super.key,
    required this.title,
    required this.metric,
    required this.icon,
    this.accent = AppColors.coral,
    this.valueFmt,
  });

  @override
  Widget build(BuildContext context) => MetricScreen(
        title: title,
        metric: metric,
        icon: icon,
        accent: accent,
        valueFmt: valueFmt,
        todayDetail: (ctx) => _TrendTodayCard(metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
        dayDetail: (ctx, date) => _TrendTodayCard(metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
      );
}

/// Compact "current value + change + what-this-is" leaf for a generic metric.
/// Reuses the same /trend data the bars use — no per-metric fetch wiring.
class _TrendTodayCard extends StatefulWidget {
  final String metric;
  final IconData icon;
  final Color accent;
  final String Function(double v)? valueFmt;
  const _TrendTodayCard({required this.metric, required this.icon, required this.accent, this.valueFmt});
  @override
  State<_TrendTodayCard> createState() => _TrendTodayCardState();
}

class _TrendTodayCardState extends State<_TrendTodayCard> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  @override
  void initState() { super.initState(); _go(); }
  Future<void> _go() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try { final d = await api.getTrend(widget.metric, scale: 'week'); if (mounted) setState(() { _d = d; _loading = false; }); }
    catch (_) { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ProCard(child: Padding(padding: EdgeInsets.all(Sp.x6),
          child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))));
    }
    final buckets = (_d?['buckets'] as List?) ?? const [];
    final unit = _d?['unit']?.toString() ?? '';
    final summary = (_d?['summary'] as Map?)?.cast<String, dynamic>();
    // Latest day with a value.
    double? latest;
    for (final b in buckets.reversed) {
      final v = (b as Map)['value'];
      if (v is num) { latest = v.toDouble(); break; }
    }
    final fmt = widget.valueFmt;
    final shown = latest == null ? '—' : (fmt != null ? fmt(latest) : (latest == latest.roundToDouble() ? latest.toStringAsFixed(0) : latest.toStringAsFixed(1)));
    final delta = summary?['delta_vs_prev'];
    final info = infoFor(widget.metric);

    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      glow: widget.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(widget.icon, size: 16, color: widget.accent),
          const SizedBox(width: Sp.x2),
          Text('LATEST', style: AppText.overline),
        ]),
        const SizedBox(height: Sp.x3),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(shown, style: AppText.display),
          if (unit.isNotEmpty && latest != null) ...[
            const SizedBox(width: Sp.x2),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(unit, style: AppText.bodySoft)),
          ],
          if (delta is num && delta != 0) ...[
            const SizedBox(width: Sp.x3),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: DeltaChip(delta)),
          ],
        ]),
        if (info != null) ...[
          const SizedBox(height: Sp.x3),
          Text(info, style: AppText.bodySoft),
        ],
        const SizedBox(height: Sp.x2),
        Text('Switch to Week · Month · 3M for the full trend.', style: AppText.captionMuted),
      ]),
    );
  }
}

/// A metric line that opens its trend on tap. Thin wrapper over MetricRow so the
/// look matches every other row; the chevron signals it's drillable.
class TrendMetricRow extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final String? info;
  final String value;
  final String? unit;
  final Widget? valueTag;
  final String metric;      // /trend key
  final String trendTitle;  // screen title
  final String Function(double v)? valueFmt;
  const TrendMetricRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.metric,
    required this.trendTitle,
    this.info,
    this.unit,
    this.accent = AppColors.coral,
    this.valueTag,
    this.valueFmt,
  });
  @override
  Widget build(BuildContext context) => MetricRow(
        icon: icon, accent: accent, label: label, info: info, value: value, unit: unit, valueTag: valueTag,
        onTap: () => openTrend(context, title: trendTitle, metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
      );
}
