// ConcernScreen — the ONE reusable screen every concern (Sleep/Heart/Body/…) plugs
// into. Title + right-aligned scale toggle (Today·Week·Month·3M), exactly like the
// hand-written Stats screen. The over-time view is a GlowCard HERO (overline → big
// display number + delta → subtitle → tappable bars inside it), then inline drill:
// tap a month bar → its weeks expand below → tap a week → its 7 days → tap a day →
// the concern's rich detail. All from the existing kit; numbers on every bar.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

typedef DetailBuilder = Widget Function(BuildContext context);
typedef DayDetailBuilder = Widget Function(BuildContext context, String date);

const _tabs = ['Today', 'Week', 'Month', '3M'];
const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class ConcernScreen extends StatefulWidget {
  final String title;
  final String metric; // /trend key for the bars
  final IconData icon;
  final Color accent;
  final String Function(double v)? valueFmt;
  final DetailBuilder todayDetail;
  final DayDetailBuilder dayDetail;
  const ConcernScreen({
    super.key,
    required this.title,
    required this.metric,
    required this.icon,
    required this.accent,
    required this.todayDetail,
    required this.dayDetail,
    this.valueFmt,
  });

  @override
  State<ConcernScreen> createState() => _ConcernScreenState();
}

class _ConcernScreenState extends State<ConcernScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final scale = _tab == 1 ? 'week' : _tab == 2 ? 'month' : 'quarter';
    return Scaffold(
      // Opaque bg so a PUSHED concern screen (from a gauge / driver) isn't a black
      // backdrop; as a tab it matches the shell background anyway.
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            Row(children: [
              // Back button only when this screen was pushed (not when it's a tab).
              if (Navigator.of(context).canPop()) ...[
                RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
                const SizedBox(width: Sp.x3),
              ],
              Expanded(child: Text(widget.title, style: AppText.h1)),
              SegToggle(options: _tabs, index: _tab, onChanged: (i) => setState(() => _tab = i)),
            ]),
            const SizedBox(height: Sp.x5),
            if (_tab == 0)
              widget.todayDetail(context)
            else
              _DrillLevel(
                key: ValueKey('$scale-root'),
                title: widget.title,
                icon: widget.icon,
                metric: widget.metric,
                scale: scale,
                anchor: null,
                accent: widget.accent,
                valueFmt: widget.valueFmt,
                dayDetail: widget.dayDetail,
              ),
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }
}

/// One level of bars (a /trend call) rendered as a GlowCard hero. Tapping a bar
/// expands a finer level (quarter→month→week) or, at week, the day detail — inline.
class _DrillLevel extends StatefulWidget {
  final String title;
  final IconData icon;
  final String metric;
  final String scale; // 'week' | 'month' | 'quarter'
  final String? anchor;
  final Color accent;
  final String Function(double v)? valueFmt;
  final DayDetailBuilder dayDetail;
  const _DrillLevel({
    super.key,
    required this.title,
    required this.icon,
    required this.metric,
    required this.scale,
    required this.anchor,
    required this.accent,
    required this.dayDetail,
    this.valueFmt,
  });

  @override
  State<_DrillLevel> createState() => _DrillLevelState();
}

class _DrillLevelState extends State<_DrillLevel> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  int? _selected;
  Widget? _child;
  String? _childLabel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final d = await api.getTrend(widget.metric, scale: widget.scale, anchor: widget.anchor);
      if (!mounted) return;
      setState(() { _data = d; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // Nicer bar labels than the raw backend strings.
  String _barLabel(int i, Map b) {
    final ts = (b['t_start'] as num?)?.toInt();
    if (ts == null) return b['label']?.toString() ?? '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
    switch (widget.scale) {
      case 'week':
        return _wd[(d.weekday - 1) % 7];
      case 'month':
        return 'W${i + 1}';
      default: // quarter → month
        return _mon[d.month - 1];
    }
  }

  void _tap(int i, List<dynamic> buckets) {
    if (i >= buckets.length) return;
    final b = buckets[i] as Map<String, dynamic>;
    final endTs = (b['t_end'] as num?)?.toInt();
    if (endTs == null) return;
    final lastDay = DateTime.fromMillisecondsSinceEpoch((endTs - 86400) * 1000, isUtc: true)
        .toIso8601String().substring(0, 10);
    setState(() {
      if (_selected == i) { _selected = null; _child = null; return; }
      _selected = i;
      _childLabel = _barLabel(i, b);
      if (widget.scale == 'week') {
        final d = DateTime.fromMillisecondsSinceEpoch((endTs - 86400) * 1000, isUtc: true);
        _childLabel = '${_wd[(d.weekday - 1) % 7]}, ${_mon[d.month - 1]} ${d.day}';
        _child = KeyedSubtree(key: ValueKey('day-$lastDay'), child: widget.dayDetail(context, lastDay));
      } else {
        _child = _DrillLevel(
          key: ValueKey('${widget.scale}-$lastDay'),
          title: widget.title, icon: widget.icon, metric: widget.metric,
          scale: widget.scale == 'quarter' ? 'month' : 'week',
          anchor: lastDay, accent: widget.accent, valueFmt: widget.valueFmt, dayDetail: widget.dayDetail,
        );
      }
    });
  }

  String get _period => widget.scale == 'week'
      ? 'this week' : widget.scale == 'month' ? 'this month' : 'last 3 months';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ProCard(
        padding: EdgeInsets.all(Sp.x6),
        child: SizedBox(height: 200, child: Center(
          child: SizedBox(width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.coral)))),
      );
    }
    final buckets = (_data?['buckets'] as List?) ?? const [];
    final unit = _data?['unit']?.toString() ?? '';
    final label = _data?['label']?.toString() ?? widget.title;
    final summary = (_data?['summary'] as Map?)?.cast<String, dynamic>();
    final values = [for (final b in buckets) ((b as Map)['value'] as num?)?.toDouble() ?? 0.0];
    final labels = [for (int i = 0; i < buckets.length; i++) _barLabel(i, buckets[i] as Map)];
    final allZero = values.every((v) => v == 0);
    final avg = summary?['avg'];
    final delta = summary?['delta_vs_prev'];
    final met = summary?['met_count'], total = summary?['total'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlowCard(
          padding: const EdgeInsets.all(Sp.x6),
          glow: widget.accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                AppIcon(widget.icon, size: 18, color: widget.accent),
                const SizedBox(width: Sp.x2),
                Text('AVG ${label.toUpperCase()}', style: AppText.overline),
                const Spacer(),
                if (met != null && total != null && (total as num) > 0)
                  Text('$met/$total met', style: AppText.caption),
              ]),
              const SizedBox(height: Sp.x4),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_fmtAvg(avg, unit), style: AppText.display),
                if (unit.isNotEmpty && avg != null && widget.metric != 'sleep') ...[
                  const SizedBox(width: Sp.x2),
                  Padding(padding: const EdgeInsets.only(bottom: 8),
                      child: Text(unit, style: AppText.bodySoft)),
                ],
                if (delta != null && (delta as num) != 0) ...[
                  const SizedBox(width: Sp.x3),
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: DeltaChip(delta)),
                ],
              ]),
              const SizedBox(height: Sp.x2),
              Text('avg · $_period', style: AppText.bodySoft),
              const SizedBox(height: Sp.x5),
              if (allZero)
                SizedBox(height: 120, child: Center(
                  child: Text('No data in this period', style: AppText.captionMuted)))
              else
                LabeledBars(
                  values: values, labels: labels, color: widget.accent,
                  highlight: _selected, valueFmt: widget.valueFmt, onTapBar: (i) => _tap(i, buckets),
                ),
            ],
          ),
        ),
        if (!allZero) ...[
          const SizedBox(height: Sp.x2),
          Center(child: Text(
            widget.scale == 'week' ? 'Tap a day for the full breakdown' : 'Tap a bar to drill in',
            style: AppText.captionMuted)),
        ],
        if (_child != null) ...[
          const SizedBox(height: Sp.x6),
          SectionHeader(_childLabel ?? 'Detail'),
          _child!,
        ],
      ],
    );
  }

  String _fmtAvg(Object? avg, String unit) {
    if (avg == null) return '—';
    final v = (avg as num).toDouble();
    // Sleep avg comes in minutes → show as Hh Mm in the hero.
    if (widget.metric == 'sleep') {
      final m = v.round();
      return '${m ~/ 60}h ${m % 60}m';
    }
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }
}
