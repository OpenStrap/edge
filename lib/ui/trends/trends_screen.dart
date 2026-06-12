// Stats — metrics over a 7/30/90-day range. Backed by /history.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../net/api_client.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/charts.dart';
import '../kit/kit.dart';
import '../widgets/screen_loader.dart';

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});
  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

const _ranges = ['7d', '30d', '90d'];
const _rangeLabels = ['Week', 'Month', '3 Months'];

class _TrendsScreenState extends State<TrendsScreen>
    with ScreenLoaderMixin<TrendsScreen> {
  String _range = '30d';

  @override
  String get cacheKey => 'history:$_range';

  @override
  Future<Object?> fetch(ApiClient api) => api.getHistory(range: _range);

  @override
  bool isEmpty(Object? d) => _History(d).isEmpty;

  String get _periodWord =>
      _range == '7d' ? 'this week' : (_range == '90d' ? 'last 90 days' : 'this month');

  void _onRange(int i) {
    final r = _ranges[i];
    if (r == _range) return;
    setState(() => _range = r);
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final h = _History(data);
    final rangeIndex = _ranges.indexOf(_range).clamp(0, 2);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppColors.coral,
          onRefresh: () => refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
            children: [
              const SizedBox(height: Sp.x4),
              Row(
                children: [
                  Expanded(child: Text('Stats', style: AppText.h1)),
                  SegToggle(
                    options: _rangeLabels,
                    index: rangeIndex,
                    onChanged: _onRange,
                  ),
                ],
              ),
              const SizedBox(height: Sp.x5),
              if (phase == LoadPhase.loading)
                ..._skeleton()
              else if (phase == LoadPhase.empty)
                _empty()
              else if (phase == LoadPhase.error)
                _error()
              else
                ..._content(h),
              const SizedBox(height: 110),
            ],
          ),
        ),
      ),
    );
  }

  // ── states ──────────────────────────────────────────────────────────────
  List<Widget> _skeleton() => [
        for (final hgt in [200.0, 180.0, 150.0, 120.0])
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x4),
            child: ProCard(
              child: SizedBox(
                height: hgt,
                child: const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.coral),
                  ),
                ),
              ),
            ),
          ),
      ];

  Widget _empty() => ProCard(
        padding: const EdgeInsets.all(Sp.x7),
        child: Column(children: [
          const AppIcon(Ic.chart, size: 40, color: AppColors.inkMuted),
          const SizedBox(height: Sp.x4),
          Text('Stats build over time', style: AppText.h2),
          const SizedBox(height: Sp.x2),
          Text(
            'Keep wearing and syncing your band. Your strain, recovery, '
            'sleep and heart-rate stats appear as data accumulates.',
            textAlign: TextAlign.center,
            style: AppText.bodySoft,
          ),
        ]),
      );

  Widget _error() => ProCard(
        padding: const EdgeInsets.all(Sp.x7),
        child: Column(children: [
          const AppIcon(Ic.cloud, size: 40, color: AppColors.inkMuted),
          const SizedBox(height: Sp.x4),
          Text("Couldn't load stats", style: AppText.h2),
          const SizedBox(height: Sp.x2),
          Text(errorText ?? 'Pull to retry.',
              textAlign: TextAlign.center, style: AppText.bodySoft),
        ]),
      );

  // ── content ─────────────────────────────────────────────────────────────
  List<Widget> _content(_History h) {
    final strain = h.metric('strain');
    final readiness = h.metric('readiness');
    final rhr = h.metric('resting_hr');
    final cal = h.metric('calories');
    final sleepDur = h.metric('sleep_duration');
    final sleepEff = h.metric('sleep_efficiency');

    final strainSeries = h.series('strain');
    final readinessSeries = h.series('readiness');

    return [
      // HERO — average strain for the window.
      GlowCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const AppIcon(Ic.strain, size: 18, color: AppColors.coralDeep),
              const SizedBox(width: Sp.x2),
              Text('AVG STRAIN', style: AppText.overline),
            ]),
            const SizedBox(height: Sp.x4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_fmt(strain.avg, 1), style: AppText.display),
                const SizedBox(width: Sp.x3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DeltaChip(strain.deltaPct),
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            Text('avg strain · $_periodWord', style: AppText.bodySoft),
            const SizedBox(height: Sp.x5),
            DotMatrix(strainSeries, color: AppColors.coral, rows: 10),
          ],
        ),
      ),
      const SizedBox(height: Sp.x6),

      // SUMMARY GRID.
      Text('Averages', style: AppText.h2),
      const SizedBox(height: Sp.x3),
      _grid([
        StatTile(
          icon: Ic.strain,
          label: 'Strain',
          value: strain.has ? _fmt(strain.avg, 1) : null,
          deltaPct: strain.deltaPct,
          spark: _spark(strainSeries),
        ),
        StatTile(
          icon: Ic.recovery,
          label: 'Readiness',
          value: readiness.has ? _fmt(readiness.avg, 0) : null,
          unit: '%',
          deltaPct: readiness.deltaPct,
          accent: AppColors.good,
          spark: _spark(readinessSeries),
        ),
        StatTile(
          icon: Ic.heart,
          label: 'Resting HR',
          value: rhr.has ? _fmt(rhr.avg, 0) : null,
          unit: 'bpm',
          deltaPct: rhr.deltaPct,
          deltaGoodIsUp: false,
          accent: AppColors.coralDeep,
          spark: _spark(h.series('resting_hr')),
        ),
        StatTile(
          icon: Ic.fire,
          label: 'Active cal',
          value: cal.has ? _fmt(cal.total, 0) : null,
          unit: 'kcal',
          deltaPct: cal.deltaPct,
          accent: AppColors.warn,
          spark: _spark(h.series('calories')),
        ),
        StatTile(
          icon: Ic.bed,
          label: 'Sleep',
          value: sleepDur.has ? _fmtDuration(sleepDur.avg) : null,
          deltaPct: sleepDur.deltaPct,
          accent: AppColors.loadDetraining,
          spark: _spark(h.series('sleep_duration')),
        ),
        StatTile(
          icon: Ic.moon,
          label: 'Sleep eff.',
          // efficiency is stored 0..1 — render as a percentage.
          value: sleepEff.has ? _fmt((sleepEff.avg ?? 0) * 100, 0) : null,
          unit: '%',
          deltaPct: sleepEff.deltaPct,
          accent: AppColors.good,
          spark: _spark(h.series('sleep_efficiency')),
        ),
      ]),
      const SizedBox(height: Sp.x6),

      // HR ZONES.
      _zonesCard(h),
      const SizedBox(height: Sp.x4),

      // COVERAGE.
      _coverageCard(h),
      const SizedBox(height: Sp.x6),

      // READINESS TREND.
      Text('Readiness trend', style: AppText.h2),
      const SizedBox(height: Sp.x3),
      ProCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const AppIcon(Ic.recovery, size: 18, color: AppColors.good),
              const SizedBox(width: Sp.x2),
              Text('Recovery over $_periodWord', style: AppText.label),
              const Spacer(),
              DeltaChip(readiness.deltaPct),
            ]),
            const SizedBox(height: Sp.x4),
            AreaSpark(readinessSeries, color: AppColors.good, height: 110),
          ],
        ),
      ),
    ];
  }

  Widget _grid(List<Widget> tiles) {
    final rows = <List<Widget>>[];
    for (var i = 0; i < tiles.length; i += 2) {
      rows.add(tiles.sublist(i, math.min(i + 2, tiles.length)));
    }

    return Column(
      children: [
        for (final row in rows) ...[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int j = 0; j < row.length; j++) ...[
                  Expanded(child: row[j]),
                  if (j < row.length - 1) const SizedBox(width: Sp.x3),
                ],
                if (row.length < 2) ...[
                  const SizedBox(width: Sp.x3),
                  const Expanded(child: SizedBox()),
                ],
              ],
            ),
          ),
          if (row != rows.last) const SizedBox(height: Sp.x3),
        ],
      ],
    );
  }

  Widget _zonesCard(_History h) {
    final z = h.zones; // [z1..z5]
    final total = z.fold<double>(0, (s, v) => s + v);
    const colors = [
      AppColors.loadDetraining,
      AppColors.good,
      AppColors.coral,
      AppColors.coralDeep,
      AppColors.bad,
    ];
    const names = ['Z1', 'Z2', 'Z3', 'Z4', 'Z5'];
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const AppIcon(Ic.pulse, size: 18, color: AppColors.coral),
            const SizedBox(width: Sp.x2),
            Text('HR zones · $_periodWord', style: AppText.label),
            const Spacer(),
            Text('${total.round()} min', style: AppText.label),
          ]),
          const SizedBox(height: Sp.x4),
          SegmentBar(z, colors, height: 14),
          const SizedBox(height: Sp.x4),
          Wrap(
            spacing: Sp.x4,
            runSpacing: Sp.x2,
            children: [
              for (int i = 0; i < 5; i++)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: colors[i], shape: BoxShape.circle),
                  ),
                  const SizedBox(width: Sp.x2),
                  Text('${names[i]} · ${z[i].round()}m',
                      style: AppText.caption),
                ]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coverageCard(_History h) {
    final worn = h.wornDays;
    final total = h.totalDays;
    final t = total <= 0 ? 0.0 : (worn / total).clamp(0.0, 1.0);
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Row(children: [
        const AppIcon(Ic.watch, size: 20, color: AppColors.inkSoft),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Wear coverage', style: AppText.label),
              const SizedBox(height: Sp.x1),
              ClipRRect(
                borderRadius: BorderRadius.circular(R.pill),
                child: LinearProgressIndicator(
                  value: t,
                  minHeight: 8,
                  backgroundColor: AppColors.surfaceAlt,
                  color: AppColors.coral,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        Text('$worn / $total days', style: AppText.metricSm),
      ]),
    );
  }

  // ── formatting helpers ────────────────────────────────────────────────────
  static String _fmt(num? v, int dp) =>
      v == null ? '—' : v.toDouble().toStringAsFixed(dp);

  static String _fmtDuration(num? minutes) {
    if (minutes == null) return '—';
    final m = minutes.round();
    final h = m ~/ 60;
    final rem = m % 60;
    return '${h}h ${rem}m';
  }

  static List<double>? _spark(List<double> series) {
    if (series.isEmpty) return null;
    // Cap the number of bars so MiniBars stays legible in a tile.
    if (series.length <= 14) return series;
    final step = series.length / 14;
    return [for (int i = 0; i < 14; i++) series[(i * step).floor()]];
  }
}

// ── defensive parsing of the /history payload ───────────────────────────────

class _Summary {
  final num? avg, min, max, latest, total, deltaPct;
  final String trend;
  const _Summary(
      {this.avg,
      this.min,
      this.max,
      this.latest,
      this.total,
      this.deltaPct,
      this.trend = 'flat'});

  bool get has => avg != null || total != null || latest != null;
}

class _History {
  final Map<String, dynamic> _root;

  _History(Object? raw)
      : _root = (raw is Map) ? raw.cast<String, dynamic>() : const {};

  Map<String, dynamic> get _metrics {
    final m = _root['metrics'];
    return m is Map ? m.cast<String, dynamic>() : const {};
  }

  Map<String, dynamic> get _series {
    final s = _root['series'];
    return s is Map ? s.cast<String, dynamic>() : const {};
  }

  _Summary metric(String key) {
    final raw = _metrics[key];
    if (raw is! Map) return const _Summary();
    final m = raw.cast<String, dynamic>();
    return _Summary(
      avg: _num(m['avg']),
      min: _num(m['min']),
      max: _num(m['max']),
      latest: _num(m['latest']),
      total: _num(m['total']),
      deltaPct: _num(m['delta_pct']),
      trend: m['trend']?.toString() ?? 'flat',
    );
  }

  /// A metric's daily series as plain `v` values (skips nulls).
  List<double> series(String key) {
    final raw = _series[key];
    if (raw is! List) return const [];
    final out = <double>[];
    for (final e in raw) {
      if (e is Map) {
        final v = _num(e['v']);
        if (v != null) out.add(v.toDouble());
      }
    }
    return out;
  }

  /// HR zone minutes as [z1..z5].
  List<double> get zones {
    final z = _root['hr_zones'];
    if (z is! Map) return const [0, 0, 0, 0, 0];
    final m = z.cast<String, dynamic>();
    return [
      for (final k in ['z1', 'z2', 'z3', 'z4', 'z5'])
        (_num(m[k]) ?? 0).toDouble()
    ];
  }

  int get wornDays => (_num(_root['worn_days']) ?? 0).round();
  int get totalDays {
    final t = _num(_root['total_days']) ?? _num(_root['days']);
    return (t ?? 0).round();
  }

  bool get isEmpty {
    final anyMetric = _metrics.values.any((v) => v is Map && (v).isNotEmpty);
    final anySeries =
        _series.values.any((v) => v is List && v.isNotEmpty);
    return !anyMetric && !anySeries;
  }

  static num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }
}
