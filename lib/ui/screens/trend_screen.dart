// GenericTrendScreen + TrendMetricRow — the ONE path every metric takes to show
// itself over time. A metric row anywhere taps into the same MetricScreen
// (Today/Week/Month/3M + drill), keyed by its /trend metric key. This is the
// anti-churn core: no metric gets its own bespoke trend screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
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
  Color? accent,
  String Function(double v)? valueFmt,
}) {
  Navigator.of(context).push(themedRoute((_) => GenericTrendScreen(
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
  final Color? accent;
  final String Function(double v)? valueFmt;
  const GenericTrendScreen({
    super.key,
    required this.title,
    required this.metric,
    required this.icon,
    this.accent,
    this.valueFmt,
  });

  @override
  Widget build(BuildContext context) {
    final accent = this.accent ?? AppColors.coral;
    return MetricScreen(
      title: title,
      metric: metric,
      icon: icon,
      accent: accent,
      valueFmt: valueFmt,
      todayDetail: (ctx) => _TrendTodayCard(metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
      // Drill selection: render the SELECTED day's value, not the latest (the
      // card keys off `date` — without it every bar showed today's number).
      dayDetail: (ctx, date) => _TrendTodayCard(
          key: ValueKey('trendday-$metric-$date'),
          metric: metric, icon: icon, accent: accent, valueFmt: valueFmt, date: date),
    );
  }
}

/// Compact "current value + change + what-this-is" leaf for a generic metric.
/// Reuses the same /trend data the bars use — no per-metric fetch wiring.
class _TrendTodayCard extends StatefulWidget {
  final String metric;
  final IconData icon;
  final Color accent;
  final String Function(double v)? valueFmt;
  /// When set, this card is a DRILL selection: show THIS day's value (the bar the
  /// user tapped), not the latest. Null = the Today leaf (latest value).
  final String? date;
  const _TrendTodayCard({super.key, required this.metric, required this.icon, required this.accent, this.valueFmt, this.date});
  @override
  State<_TrendTodayCard> createState() => _TrendTodayCardState();
}

class _TrendTodayCardState extends State<_TrendTodayCard> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  @override
  void initState() { super.initState(); _go(); }
  Future<void> _go() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      // For a drill selection, anchor the week on the selected day so its bucket
      // is in the result; otherwise the default (latest) week.
      final d = await api.getTrend(widget.metric, scale: 'week', anchor: widget.date);
      if (mounted) setState(() { _d = d; _loading = false; });
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  /// 'YYYY-MM-DD' → 'Mon, Jun 18' (UTC, matching the bucket/day keys).
  String _prettyDate(String ymd) {
    final d = DateTime.tryParse(ymd);
    if (d == null) return ymd;
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[(d.weekday - 1) % 7]}, ${mon[d.month - 1]} ${d.day}';
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
    final isDay = widget.date != null;

    double? value;
    if (isDay) {
      // The exact selected day's bucket (match by t_start → date string).
      for (final b in buckets) {
        final bm = b as Map;
        final ts = (bm['t_start'] as num?)?.toInt();
        if (ts == null) continue;
        final dstr = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
            .toIso8601String().substring(0, 10);
        if (dstr == widget.date) {
          if (bm['has'] == true && bm['value'] is num) value = (bm['value'] as num).toDouble();
          break;
        }
      }
    } else {
      // Today leaf: latest day with a value.
      for (final b in buckets.reversed) {
        final v = (b as Map)['value'];
        if (v is num) { value = v.toDouble(); break; }
      }
    }

    final fmt = widget.valueFmt;
    final shown = value == null ? '—' : (fmt != null ? fmt(value) : (value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1)));
    final delta = summary?['delta_vs_prev'];
    final info = infoFor(widget.metric);
    final header = isDay ? _prettyDate(widget.date!).toUpperCase() : 'LATEST';

    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      glow: widget.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(widget.icon, size: 16, color: widget.accent),
          const SizedBox(width: Sp.x2),
          Text(header, style: AppText.overline),
        ]),
        const SizedBox(height: Sp.x3),
        if (isDay && value == null)
          Text('No data for this day', style: AppText.title.copyWith(color: AppColors.inkSoft))
        else
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(shown, style: AppText.display),
            if (unit.isNotEmpty && value != null) ...[
              const SizedBox(width: Sp.x2),
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(unit, style: AppText.bodySoft)),
            ],
            // Week-over-week delta only makes sense on the latest (non-day) leaf.
            if (!isDay && delta is num && delta != 0) ...[
              const SizedBox(width: Sp.x3),
              Padding(padding: const EdgeInsets.only(bottom: 8), child: DeltaChip(delta)),
            ],
          ]),
        if (info != null) ...[
          const SizedBox(height: Sp.x3),
          Text(info, style: AppText.bodySoft),
        ],
        if (!isDay) ...[
          const SizedBox(height: Sp.x2),
          Text('Switch to Week · Month · 3M for the full trend.', style: AppText.captionMuted),
        ],
      ]),
    );
  }
}

/// A metric line that opens its trend on tap. Thin wrapper over MetricRow so the
/// look matches every other row; the chevron signals it's drillable.
class TrendMetricRow extends StatelessWidget {
  final IconData icon;
  final Color? accent;
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
    this.accent,
    this.valueTag,
    this.valueFmt,
  });
  @override
  Widget build(BuildContext context) => MetricRow(
        icon: icon, accent: accent, label: label, info: info, value: value, unit: unit, valueTag: valueTag,
        onTap: () => openTrend(context, title: trendTitle, metric: metric, icon: icon, accent: accent, valueFmt: valueFmt),
      );
}
