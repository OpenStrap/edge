// Strain detail for one day — total, the accumulation curve, HR zones, HR stats,
// and workouts. Backed by /day/strain.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../screens/metric_row.dart';
import '../screens/trend_screen.dart';

class StrainDetailScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  // Embedded (no Scaffold/back bar) for use inside the Body screen.
  final bool embedded;
  const StrainDetailScreen({
    super.key,
    required this.date,
    this.embedded = false,
  });
  @override
  State<StrainDetailScreen> createState() => _StrainDetailScreenState();
}

enum _Phase { loading, ready, empty, error }

class _StrainDetailScreenState extends State<StrainDetailScreen> {
  static const double _strainChartLeftPad = 18;
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getDayStrain(widget.date);
      if (!mounted) return;
      setState(() {
        _data = res;
        _phase = _isEmpty(res) ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  bool _isEmpty(Map<String, dynamic> d) {
    final strain = _num(d['strain'])?.toDouble() ?? 0;
    return _curve().isEmpty && strain <= 0;
  }

  // ── defensive parsing helpers ───────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  List<dynamic> _list(Object? v) => v is List ? v : const [];

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  double _strain() => (_num(_data['strain'])?.toDouble() ?? 0).clamp(0.0, 21.0);

  /// Cumulative strain curve with timestamps.
  List<TimeSeriesPoint> _curve() {
    final out = <TimeSeriesPoint>[];
    for (final p in _list(_data['curve'])) {
      final m = _map(p);
      final t = _num(m['t'])?.toDouble();
      final v = _num(m['v'])?.toDouble();
      if (t != null && v != null) out.add(TimeSeriesPoint(t, v));
    }
    return out;
  }

  List<TimeSeriesPoint> _zoneTimeline() {
    final out = <TimeSeriesPoint>[];
    for (final p in _list(_data['zone_timeline'])) {
      final m = _map(p);
      final t = _num(m['t'])?.toDouble();
      final z = _num(m['z'])?.toDouble();
      if (t != null && z != null) out.add(TimeSeriesPoint(t, z));
    }
    return out;
  }

  /// Zone minutes z1..z5 (missing zones → 0).
  List<double> _zones() {
    final z = _map(_data['zones']);
    return [
      for (final k in const ['z1', 'z2', 'z3', 'z4', 'z5'])
        (_num(z[k])?.toDouble() ?? 0),
    ];
  }

  Map<String, dynamic> _hr() => _map(_data['hr']);

  List<Map<String, dynamic>> _sessions() => [
    for (final s in _list(_data['sessions'])) _map(s),
  ];

  List<_SessionRange> _sessionRanges() {
    final out = <_SessionRange>[];
    for (final s in _sessions()) {
      final start = _num(s['start_ts'])?.toDouble();
      final end = _num(s['end_ts'])?.toDouble();
      if (start == null || end == null || end <= start) continue;
      out.add(
        _SessionRange(
          start,
          end,
          (s['type'] as String?) ?? 'Autodetected workout',
          (s['source'] as String?) ?? 'auto',
        ),
      );
    }
    return out;
  }

  // ── formatting (no intl) ─────────────────────────────────────────────────────

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// 'YYYY-MM-DD' → 'Mon 12, 2026' (falls back to the raw string).
  String _prettyDate() {
    final parts = widget.date.split('-');
    if (parts.length != 3) return widget.date;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null || m < 1 || m > 12) {
      return widget.date;
    }
    return '${_months[m - 1]} $d, $y';
  }

  String _mins(num? minutes) {
    final m = (minutes ?? 0).round();
    final h = m ~/ 60;
    final min = m % 60;
    if (h > 0 && min > 0) return '${h}h ${min}m';
    if (h > 0) return '${h}h';
    return '${min}m';
  }

  int _zoneAt(double ts, List<TimeSeriesPoint> timeline) {
    if (timeline.isEmpty) return 0;
    var zone = timeline.first.y.round().clamp(0, 5);
    for (final p in timeline) {
      if (p.x > ts) break;
      zone = p.y.round().clamp(0, 5);
    }
    return zone;
  }

  bool _hasWorkoutAt(double ts, List<_SessionRange> sessions) {
    for (final s in sessions) {
      if (ts >= s.start && ts <= s.end) return true;
    }
    return false;
  }

  String _timeRange(num? startSec, num? endSec) {
    if (startSec == null || endSec == null) return '—';
    String fmt(num sec) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        (sec * 1000).round(),
      ).toLocal();
      final mm = dt.minute.toString().padLeft(2, '0');
      return '${dt.hour}:$mm';
    }

    return '${fmt(startSec)}–${fmt(endSec)}';
  }

  String _bpmRange(int zone, int? maxHr) {
    if (maxHr == null || maxHr <= 0) return '—';
    final lowerPct = 0.5 + (zone - 1) * 0.1;
    final upperPct = zone == 5 ? 1.0 : lowerPct + 0.1;
    final lo = (maxHr * lowerPct).round();
    final hi = (maxHr * upperPct).round();
    return '$lo–$hi bpm';
  }

  // ── build ────────────────────────────────────────────────────────────────────

  List<Widget> _sections() {
    if (_phase == _Phase.loading) return [_loading()];
    if (_phase == _Phase.empty) {
      return [
        _stateCard(
          Ic.strain,
          'No strain for this day',
          'Wear your strap and sync to capture all-day heart rate. Strain '
              'appears once there is data to score.',
        ),
      ];
    }
    if (_phase == _Phase.error) {
      return [
        _stateCard(
          Ic.cloud,
          "Couldn't load strain",
          _error ?? 'Please try again.',
        ),
      ];
    }
    return _content();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _sections(),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),
            ..._sections(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        RoundIconButton(
          Ic.arrowLeft,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Strain', style: AppText.h1),
              const SizedBox(height: 2),
              Text(_prettyDate(), style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _content() {
    final load = _map(_data['load']);
    final fitness = _data['fitness_trend']?.toString();
    final cals = _num(_data['calories']);
    final steps = _num(_data['steps']);
    final effort = _num(_data['effort']);
    final hasLoad =
        load.isNotEmpty ||
        fitness != null ||
        cals != null ||
        steps != null ||
        effort != null;
    final drivers = [
      for (final dr in _list(_map(_data['drivers'])['strain'])) _map(dr),
    ].where((dr) => (dr['label']?.toString() ?? '').isNotEmpty).toList();
    return [
      _hero(),
      const SizedBox(height: Sp.x4),
      if (hasLoad) ...[
        const SectionHeader('Training load'),
        _loadCard(load, fitness, cals, steps, effort),
        const SizedBox(height: Sp.x4),
      ],
      ..._fitnessSection(),
      _curveCard(),
      const SizedBox(height: Sp.x4),
      _zonesCard(),
      const SizedBox(height: Sp.x4),
      _hrStatsRow(),
      const SizedBox(height: Sp.x4),
      ..._workouts(),
      if (drivers.isNotEmpty) ...[
        const SizedBox(height: Sp.x4),
        const SectionHeader('What affected this'),
        // Display-only (no navigation): default card padding gives proper inset.
        ProCard(
          child: Column(
            children: [
              for (final dr in drivers)
                DetailRow(
                  label: dr['label']?.toString() ?? '',
                  value: dr['detail']?.toString() ?? '',
                ),
            ],
          ),
        ),
      ],
    ];
  }

  // Fitness modeling — VO₂max, Banister fitness/fatigue/form curves, monotony.
  List<Widget> _fitnessSection() {
    final vo2 = _num(_data['vo2max']);
    final fm = _map(_data['fitness_model']);
    final monotony = _num(_data['monotony']);
    final acwr = _num(_map(_data['load'])['acwr']);
    final rows = <Widget>[];
    if (vo2 != null) {
      rows.add(
        TrendMetricRow(
          icon: Ic.pulse,
          accent: AppColors.good,
          label: 'VO₂max',
          info: infoFor('vo2max'),
          value: vo2.toStringAsFixed(1),
          unit: 'ml/kg/min',
          metric: 'vo2max',
          trendTitle: 'VO₂max',
        ),
      );
    }
    if (acwr != null) {
      rows.add(
        TrendMetricRow(
          icon: Ic.strain,
          accent: AppColors.coral,
          label: 'Training load (ACWR)',
          info: infoFor('load'),
          value: acwr.toStringAsFixed(2),
          metric: 'acwr',
          trendTitle: 'Training load (ACWR)',
        ),
      );
    }
    if (monotony != null) {
      rows.add(
        TrendMetricRow(
          icon: Ic.chart,
          accent: AppColors.warn,
          label: 'Monotony',
          info: infoFor('monotony'),
          value: monotony.toStringAsFixed(2),
          metric: 'monotony',
          trendTitle: 'Training monotony',
        ),
      );
    }
    final hasModel =
        fm['fitness'] != null || fm['fatigue'] != null || fm['form'] != null;
    // Nothing computed yet → an HONEST unlock card (not a hidden section / bare
    // "—"): VO₂max needs a hard effort; the Banister model needs weeks of data.
    if (rows.isEmpty && !hasModel) {
      return [
        const SectionHeader('Fitness'),
        ProCard(
          child: Padding(
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSunk,
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: AppIcon(Ic.pulse, size: 17, color: AppColors.inkMuted),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Building your fitness picture',
                        style: AppText.label,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'VO₂max needs a hard, near-max effort to estimate; '
                        'fitness, fatigue & form build over ~2–3 weeks of '
                        'training. Keep wearing it and training as usual.',
                        style: AppText.captionMuted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Sp.x4),
      ];
    }
    return [
      const SectionHeader('Fitness'),
      if (hasModel) ...[
        _FitnessModelCard(
          fitness: _num(fm['fitness']),
          fatigue: _num(fm['fatigue']),
          form: _num(fm['form']),
        ),
        const SizedBox(height: Sp.x3),
      ],
      if (rows.isNotEmpty) MetricGroup(rows),
      const SizedBox(height: Sp.x4),
    ];
  }

  Widget _loadCard(
    Map<String, dynamic> load,
    String? fitness,
    num? cals,
    num? steps,
    num? effort,
  ) {
    final acwr = _num(load['acwr']);
    final band = load['band']?.toString();
    Color bandColor() {
      switch (band) {
        case 'optimal':
          return AppColors.good;
        case 'caution':
          return AppColors.warn;
        case 'high-risk':
          return AppColors.bad;
        default:
          return AppColors.loadDetraining;
      }
    }

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (acwr != null) ...[
            Row(
              children: [
                AppIcon(Ic.strain, size: 18, color: AppColors.coralDeep),
                const SizedBox(width: Sp.x2),
                Text('Acute:chronic load', style: AppText.label),
                const Spacer(),
                Text(
                  acwr.toStringAsFixed(2),
                  style: AppText.metricSm.copyWith(fontSize: 18),
                ),
                const SizedBox(width: Sp.x2),
                if (band != null) Tag(band, color: bandColor()),
              ],
            ),
            if (fitness != null || cals != null || steps != null)
              const SizedBox(height: Sp.x3),
          ],
          if (fitness != null)
            DetailRow(label: 'Fitness trend', value: fitness),
          if (cals != null)
            DetailRow(label: 'Active calories', value: '${cals.round()} kcal'),
          if (_num(_data['calories_total']) != null)
            DetailRow(
              label: 'Total calories',
              value: '${_num(_data['calories_total'])!.round()} kcal',
            ),
          if (steps != null)
            DetailRow(label: 'Steps (est.)', value: '${steps.round()}'),
          // Edwards zone-weighted "effort" (0–100) — finer-grained intensity read
          // than the 0–21 headline, over the per-second wake HR.
          if (effort != null)
            DetailRow(label: 'Effort (0–100)', value: '${effort.round()}'),
        ],
      ),
    );
  }

  // ── 2. HERO ───────────────────────────────────────────────────────────────────

  Widget _hero() {
    final strain = _strain();
    return GlowCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.coralSoft,
                        borderRadius: BorderRadius.circular(R.chip),
                      ),
                      child: AppIcon(
                        Ic.strain,
                        size: 16,
                        color: AppColors.coralDeep,
                      ),
                    ),
                    const SizedBox(width: Sp.x2),
                    Text('DAY STRAIN', style: AppText.overline),
                  ],
                ),
                const SizedBox(height: Sp.x4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      strain.toStringAsFixed(1),
                      style: AppText.display.copyWith(color: AppColors.coral),
                    ),
                    const SizedBox(width: Sp.x2),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('of 21', style: AppText.caption),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Sp.x4),
          RingStat(
            t: strain / 21.0,
            color: AppColors.coral,
            size: 92,
            stroke: 10,
            center: Text(
              strain.toStringAsFixed(1),
              style: AppText.metricSm.copyWith(color: AppColors.coral),
            ),
          ),
        ],
      ),
    );
  }

  // ── strain curve ───────────────────────────────────────────

  Widget _curveCard() {
    final curve = _curve();
    final timeline = _zoneTimeline();
    final sessions = _sessionRanges();
    final loX = curve.isEmpty ? null : curve.first.x;
    final hiX = curve.isEmpty ? null : curve.last.x;
    final zoneColors = [
      AppColors.surfaceAlt,
      AppColors.loadDetraining,
      AppColors.good,
      AppColors.warn,
      AppColors.coral,
      AppColors.coralDeep,
    ];
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Strain build'),
          TimeSeriesChart(
            points: curve,
            color: AppColors.coral,
            height: 220,
            leftPad: _strainChartLeftPad,
            minY: 0,
            maxY: 21,
            yLabel: (v) => v.round().toString(),
            tooltip: (p) {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                (p.x * 1000).round(),
              ).toLocal();
              final mm = dt.minute.toString().padLeft(2, '0');
              final zone = _zoneAt(p.x, timeline);
              final workout = _hasWorkoutAt(p.x, sessions) ? 'yes' : 'no';
              return '${dt.hour}:$mm\n'
                  'strain ${p.y.toStringAsFixed(1)}\n'
                  'zone Z$zone\n'
                  'workout $workout';
            },
            bands: const [
              HorizontalBand(0, 5, Color(0x102B3C50)),
              HorizontalBand(5, 10, Color(0x102EA66B)),
              HorizontalBand(10, 15, Color(0x10F2B544)),
              HorizontalBand(15, 18, Color(0x10F08A4B)),
              HorizontalBand(18, 21, Color(0x10C95B5B)),
            ],
          ),
          const SizedBox(height: Sp.x3),
          if (loX != null && hiX != null)
            ZoneTimelineBar(
              points: timeline,
              colors: zoneColors,
              minX: loX,
              maxX: hiX,
              height: 12,
              leftPad: _strainChartLeftPad,
            ),
          if (loX != null && hiX != null && sessions.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            _WorkoutTimelineBar(
              sessions: sessions,
              minX: loX,
              maxX: hiX,
              leftInset: _strainChartLeftPad,
            ),
          ],
        ],
      ),
    );
  }

  // ── 4. HR ZONES ─────────────────────────────────────────────────────────────

  Widget _zonesCard() {
    final zones = _zones();
    final palette = [
      AppColors.loadDetraining,
      AppColors.good,
      AppColors.warn,
      AppColors.coral,
      AppColors.coralDeep,
    ];
    final maxHr = _num(_data['max_hr_used'])?.round();
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('HR zones'),
          SegmentBar(zones, palette, height: 14),
          const SizedBox(height: Sp.x4),
          for (int i = 0; i < zones.length; i++) ...[
            if (i != 0) const SizedBox(height: Sp.x2),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: palette[i],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: Sp.x3),
                SizedBox(
                  width: 28,
                  child: Text('Z${i + 1}', style: AppText.label),
                ),
                Expanded(
                  child: Text(
                    _bpmRange(i + 1, maxHr),
                    style: AppText.captionMuted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Sp.x3),
                SizedBox(
                  width: 64,
                  child: Text(
                    _mins(zones[i]),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: AppText.body.copyWith(
                      color: AppColors.inkSoft,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── 5. HR STATS ──────────────────────────────────────────────────────────────

  Widget _hrStatsRow() {
    final hr = _hr();
    return Row(
      children: [
        Expanded(child: _hrStat('Max', _num(hr['max']))),
        const SizedBox(width: Sp.x3),
        Expanded(child: _hrStat('Avg', _num(hr['avg']))),
        const SizedBox(width: Sp.x3),
        Expanded(child: _hrStat('Min', _num(hr['min']))),
      ],
    );
  }

  Widget _hrStat(String label, num? bpm) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppText.overline),
          const SizedBox(height: Sp.x2),
          if (bpm == null)
            metricDash(22)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    '${bpm.round()}',
                    style: AppText.metricSm,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    'bpm',
                    style: AppText.captionMuted.copyWith(fontSize: 10),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── 6. WORKOUTS ──────────────────────────────────────────────────────────────

  List<Widget> _workouts() {
    final sessions = _sessions();
    if (sessions.isEmpty) {
      return [
        ProCard(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(Sp.x3),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  shape: BoxShape.circle,
                ),
                child: AppIcon(Ic.run, size: 20, color: AppColors.coralDeep),
              ),
              const SizedBox(width: Sp.x4),
              Expanded(
                child: Text(
                  'No workouts auto-detected — strain still accrues from all-day '
                  'heart rate.',
                  style: AppText.bodySoft,
                ),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      const SectionHeader('Workouts'),
      for (int i = 0; i < sessions.length; i++) ...[
        if (i != 0) const SizedBox(height: Sp.x3),
        _sessionCard(sessions[i]),
      ],
    ];
  }

  Widget _sessionCard(Map<String, dynamic> s) {
    final type = (s['type'] is String && (s['type'] as String).isNotEmpty)
        ? s['type'] as String
        : 'Workout';
    final dur = _num(s['duration_min']);
    final start = _num(s['start_ts']);
    final end = _num(s['end_ts']);
    final avgHr = _num(s['avg_hr']);
    final maxHr = _num(s['max_hr']);
    final calories = _num(s['calories']);
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(Sp.x3),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  shape: BoxShape.circle,
                ),
                child: AppIcon(Ic.run, size: 18, color: AppColors.coralDeep),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Text(
                  type,
                  style: AppText.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dur != null) ...[
                const SizedBox(width: Sp.x2),
                Text(
                  _mins(dur),
                  style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x1),
          Text(_timeRange(start, end), style: AppText.captionMuted),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              _sessionStat(
                'Calories',
                calories == null ? '—' : '${calories.round()}',
              ),
              _sessionStat('AVG HR', avgHr == null ? '—' : '${avgHr.round()}'),
              _sessionStat('MAX HR', maxHr == null ? '—' : '${maxHr.round()}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sessionStat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppText.overline),
          const SizedBox(height: Sp.x1),
          Text(value, style: AppText.metricSm),
        ],
      ),
    );
  }

  // ── states ─────────────────────────────────────────────────────────────────

  Widget _loading() => ProCard(
    padding: const EdgeInsets.all(Sp.x6),
    child: SizedBox(
      height: 320,
      child: Center(child: CircularProgressIndicator(color: AppColors.coral)),
    ),
  );

  Widget _stateCard(IconData icon, String title, String message) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              shape: BoxShape.circle,
            ),
            child: AppIcon(icon, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x5),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _SessionRange {
  final double start;
  final double end;
  final String label;
  final String source;
  const _SessionRange(this.start, this.end, this.label, this.source);
}

class _WorkoutTimelineBar extends StatelessWidget {
  final List<_SessionRange> sessions;
  final double minX;
  final double maxX;
  final double leftInset;
  const _WorkoutTimelineBar({
    required this.sessions,
    required this.minX,
    required this.maxX,
    this.leftInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final span = (maxX - minX).abs() < 1 ? 1.0 : (maxX - minX);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(1.0, constraints.maxWidth - leftInset);
            return SizedBox(
              height: 10,
              child: Padding(
                padding: EdgeInsets.only(left: leftInset),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(R.pill),
                  child: Stack(
                    children: [
                      Container(color: AppColors.surfaceAlt),
                      for (final s in sessions)
                        Positioned(
                          left:
                              ((s.start - minX) / span).clamp(0.0, 1.0) * width,
                          width: math.max(
                            4,
                            ((s.end - s.start) / span).clamp(0.0, 1.0) * width,
                          ),
                          top: 0,
                          bottom: 0,
                          child: Container(
                            decoration: BoxDecoration(
                              color: s.source == 'auto'
                                  ? AppColors.coralDeep
                                  : AppColors.good,
                              borderRadius: BorderRadius.circular(R.pill),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x3,
          runSpacing: Sp.x2,
          children: [
            for (final s in sessions)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: s.source == 'auto'
                          ? AppColors.coralDeep
                          : AppColors.good,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  Text(s.label, style: AppText.captionMuted),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Banister Fitness/Fatigue/Form — today's values + a dual-line trend (fetched
/// from /trend/fitness & /trend/fatigue). The Body tab's fitness centerpiece.
class _FitnessModelCard extends StatefulWidget {
  final num? fitness;
  final num? fatigue;
  final num? form;
  const _FitnessModelCard({this.fitness, this.fatigue, this.form});
  @override
  State<_FitnessModelCard> createState() => _FitnessModelCardState();
}

class _FitnessModelCardState extends State<_FitnessModelCard> {
  List<double?> _fit = const [];
  List<double?> _fat = const [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final f = await api.getTrend('fitness', scale: 'quarter');
      final g = await api.getTrend('fatigue', scale: 'quarter');
      List<double?> vals(Map<String, dynamic> d) => [
        for (final b in ((d['buckets'] as List?) ?? const []))
          ((b as Map)['value'] as num?)?.toDouble(),
      ];
      if (mounted) {
        setState(() {
          _fit = vals(f);
          _fat = vals(g);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _stat(String label, num? v, Color c) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          v == null ? '—' : v.toStringAsFixed(1),
          style: AppText.metricSm.copyWith(fontSize: 20, color: c),
        ),
        Text(label, style: AppText.captionMuted),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fitness · Fatigue · Form', style: AppText.label),
          const SizedBox(height: Sp.x1),
          Text(
            'Built-up fitness vs recent fatigue. Form = fitness − fatigue (freshness).',
            style: AppText.captionMuted,
          ),
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              _stat('FITNESS', widget.fitness, AppColors.coral),
              _stat('FATIGUE', widget.fatigue, AppColors.loadDetraining),
              _stat(
                'FORM',
                widget.form,
                widget.form != null && widget.form! >= 0
                    ? AppColors.good
                    : AppColors.warn,
              ),
            ],
          ),
          if (!_loading &&
              (_fit.where((v) => v != null).length > 1 ||
                  _fat.where((v) => v != null).length > 1)) ...[
            const SizedBox(height: Sp.x4),
            FormChart(fitness: _fit, fatigue: _fat),
            const SizedBox(height: Sp.x2),
            Row(
              children: [
                _legendDot(AppColors.coral),
                Text(' Fitness   ', style: AppText.caption),
                _legendDot(AppColors.loadDetraining),
                Text(' Fatigue', style: AppText.caption),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color c) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}
