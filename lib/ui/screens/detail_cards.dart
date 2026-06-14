// Per-metric day-detail cards. Each fetches its /day/* endpoint and renders with
// the EXISTING kit (RingStat, SegmentBar, DetailRow, ProCard, StatTile) — no new
// widget types. Used both for the "Today" tab (date = today) and as the inline
// drill leaf (date = the tapped day). One card per metric keeps it DRY.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import 'metric_row.dart';

String hm(num? minutes) {
  if (minutes == null) return '—';
  final m = minutes.round();
  return '${m ~/ 60}h ${m % 60}m';
}

/// Shared async wrapper: fetch a map, render via builder; spinner/empty states.
class _Fetch extends StatefulWidget {
  final Future<Map<String, dynamic>> Function(dynamic api) load;
  final Widget Function(Map<String, dynamic> data) build;
  const _Fetch({required this.load, required this.build});
  @override
  State<_Fetch> createState() => _FetchState();
}

class _FetchState extends State<_Fetch> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _go();
  }
  Future<void> _go() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final d = await widget.load(api);
      if (mounted) setState(() { _d = d; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(Sp.x5), child: Center(child: CircularProgressIndicator()));
    }
    if (_d == null) {
      return ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Text('No data', style: AppText.captionMuted)));
    }
    return widget.build(_d!);
  }
}

// Zone palette reused across metrics.
const _zoneColors = [AppColors.cool, AppColors.loadDetraining, AppColors.good, AppColors.warn, AppColors.coral];

// ── HEART ────────────────────────────────────────────────────────────────────
class HeartDayCard extends StatelessWidget {
  final String date;
  const HeartDayCard({super.key, required this.date});

  num? _n(Object? v) => v is num ? v : null;

  List<double> _zoneVals(Map z) => [
        (z['zone1_min'] as num?)?.toDouble() ?? 0, (z['zone2_min'] as num?)?.toDouble() ?? 0,
        (z['zone3_min'] as num?)?.toDouble() ?? 0, (z['zone4_min'] as num?)?.toDouble() ?? 0,
        (z['zone5_min'] as num?)?.toDouble() ?? 0,
      ];

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayHeart(date),
      build: (d) {
        final hr = (d['hr'] as List?)?.map((e) => ((e as Map)['v'] as num?)?.toDouble() ?? 0).where((v) => v > 0).toList() ?? <double>[];
        final rhr = _n(d['resting_hr']);
        final rhrBase = _n(d['resting_hr_baseline']);
        final rec = _n(d['recovery']);
        final hrv = (d['hrv'] as Map?);
        final zones = (d['zones'] as Map?);
        final noct = (d['nocturnal'] as Map?);
        final stress = (d['stress'] as Map?);
        final illness = (d['illness'] as Map?);
        final resp = (d['resp'] as Map?);
        final spo2 = (d['spo2'] as Map?);
        final dmap = (d['drivers'] as Map?) ?? const {};
        final heartDrivers = [
          ...((dmap['recovery'] as List?) ?? const []),
          ...((dmap['stress'] as List?) ?? const []),
        ].whereType<Map>().where((dr) => (dr['label']?.toString() ?? '').isNotEmpty).toList();

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // HERO — recovery (HRV) if we have it, else resting HR.
          GlowCard(
            padding: const EdgeInsets.all(Sp.x6),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  AppIcon(rec != null ? Ic.recovery : Ic.heart, size: 16, color: AppColors.coralDeep),
                  const SizedBox(width: Sp.x2),
                  Text(rec != null ? 'RECOVERY' : 'RESTING HR', style: AppText.overline),
                  if (rec != null) ...[const SizedBox(width: Sp.x2), const Tag('HRV', color: AppColors.good)],
                ]),
                const SizedBox(height: Sp.x3),
                if (rec != null)
                  Text('${rec.round()}', style: AppText.display)
                else if (rhr != null)
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${rhr.round()}', style: AppText.display),
                    const SizedBox(width: Sp.x2),
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('bpm', style: AppText.bodySoft)),
                  ])
                else metricDash(44),
                const SizedBox(height: Sp.x2),
                Text(rec != null
                    ? 'HRV-based recovery'
                    : (rhr != null && rhrBase != null
                        ? '${(rhr - rhrBase) >= 0 ? '+' : ''}${(rhr - rhrBase).toStringAsFixed(1)} bpm vs baseline'
                        : 'resting heart rate'),
                    style: AppText.bodySoft),
              ])),
              if (rec != null)
                RingStat(t: (rec / 100).clamp(0.0, 1.0), color: AppColors.good, size: 96, stroke: 11,
                    center: Text('${rec.round()}%', style: AppText.metricSm)),
            ]),
          ),

          if (hr.length > 1) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Heart rate'),
            ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AreaSpark(hr, color: AppColors.coral, height: 96),
              const SizedBox(height: Sp.x3),
              Text('avg ${d['avg_hr'] ?? '—'} · max ${d['max_hr'] ?? '—'} bpm', style: AppText.captionMuted),
            ])),
          ],

          // HRV — full Task-Force suite, each with what-it-means.
          if (hrv != null) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Heart-rate variability'),
            MetricGroup([
              MetricRow(icon: Ic.pulse, accent: AppColors.good, label: 'RMSSD', info: infoFor('rmssd'),
                  value: '${hrv['rmssd'] ?? '—'}', unit: 'ms'),
              if (hrv['sdnn'] != null)
                MetricRow(icon: Ic.pulse, accent: AppColors.good, label: 'SDNN', info: infoFor('sdnn'),
                    value: '${hrv['sdnn']}', unit: 'ms'),
              if (hrv['lf_hf'] != null)
                MetricRow(icon: Ic.pulse, accent: AppColors.good, label: 'LF / HF', info: infoFor('lf_hf'),
                    value: '${hrv['lf_hf']}'),
              if (hrv['baseline'] != null)
                MetricRow(icon: Ic.chart, accent: AppColors.inkSoft, label: 'Your baseline',
                    info: 'Your typical RMSSD — recovery is measured against this.',
                    value: '${(_n(hrv['baseline']) ?? 0).round()}', unit: 'ms'),
            ]),
          ],

          // Stress (HRV-based).
          if (stress != null && (stress['si'] != null || stress['score'] != null)) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Stress'),
            MetricGroup([
              MetricRow(icon: Ic.strain, accent: AppColors.warn, label: 'Stress',
                  info: infoFor('stress'),
                  value: '${stress['score'] ?? stress['si']}',
                  valueTag: stress['level'] != null
                      ? Tag('${stress['level']}'.toUpperCase(), color: AppColors.warn) : null),
              if (stress['lf_hf'] != null)
                MetricRow(icon: Ic.pulse, accent: AppColors.warn, label: 'Sympatho-vagal balance',
                    info: infoFor('lf_hf'), value: '${stress['lf_hf']}'),
            ]),
          ],

          if (zones != null && _zoneVals(zones).fold<double>(0, (s, v) => s + v) > 0) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('HR zones'),
            ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Minutes spent in each effort zone today.', style: AppText.captionMuted),
              const SizedBox(height: Sp.x3),
              SegmentBar(_zoneVals(zones), _zoneColors, height: 14),
              const SizedBox(height: Sp.x3),
              Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
                for (int i = 0; i < 5; i++)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 9, height: 9, decoration: BoxDecoration(color: _zoneColors[i], shape: BoxShape.circle)),
                    const SizedBox(width: Sp.x2),
                    Text('Z${i + 1} · ${_zoneVals(zones)[i].round()}m', style: AppText.caption),
                  ]),
              ]),
            ])),
          ],

          if (noct != null && noct['sleeping_hr_avg'] != null) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Nocturnal heart'),
            MetricGroup([
              MetricRow(icon: Ic.moon, accent: AppColors.loadDetraining, label: 'Sleeping HR',
                  info: infoFor('sleeping_hr'), value: '${noct['sleeping_hr_avg']}', unit: 'bpm'),
              if (noct['dip_pct'] != null)
                MetricRow(icon: Ic.down, accent: AppColors.good, label: 'Nocturnal dip',
                    info: infoFor('nocturnal_dip'), value: '${((noct['dip_pct'] as num) * 100).round()}', unit: '%'),
              if (noct['vs_baseline_bpm'] != null)
                MetricRow(icon: Ic.chart, accent: AppColors.inkSoft, label: 'vs baseline',
                    info: 'Tonight vs your typical sleeping heart rate.',
                    value: '${noct['vs_baseline_bpm']}', unit: 'bpm'),
            ]),
          ],

          if (resp != null || spo2 != null) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Respiratory'),
            MetricGroup([
              if (resp != null)
                MetricRow(icon: Ic.activity, accent: AppColors.good, label: 'Respiratory rate',
                    info: infoFor('resp'), value: '${resp['value']}', unit: 'brpm'),
              if (spo2 != null)
                MetricRow(icon: Ic.droplet, accent: AppColors.coralDeep, label: 'Blood-oxygen',
                    info: infoFor('spo2'), value: '${spo2['value']}', unit: 'Δ'),
            ]),
          ],

          // Illness watch — ALWAYS shown (Mahalanobis of resting HR / HRV / temp).
          // Three honest states: active signal, all-clear, or still building baseline.
          ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('Illness watch'),
            _IllnessCard(illness),
          ],

          // What affected this — display-only (no navigation loop), properly padded.
          if (heartDrivers.isNotEmpty) ...[
            const SizedBox(height: Sp.x6),
            SectionHeader('What affected this'),
            ProCard(child: Column(children: [
              for (final dr in heartDrivers)
                DetailRow(label: dr['label']?.toString() ?? '', value: dr['detail']?.toString() ?? ''),
            ])),
          ],
        ]);
      },
    );
  }
}

// Illness watch — always visible. Renders one of three honest states from the
// Mahalanobis illness object: a fired signal (amber), all-clear (green), or
// "still building baseline" (muted) when there aren't yet ~7 nights to compare.
class _IllnessCard extends StatelessWidget {
  final Map? illness;
  const _IllnessCard(this.illness);

  num? _num(Object? v) => v is num ? v : null;

  @override
  Widget build(BuildContext context) {
    final dist = _num(illness?['distance']);
    final signal = illness?['signal'] == true;
    final drivers = (illness?['drivers'] as List?)?.whereType<Map>().toList() ?? const [];

    // No baseline yet → honest "building" state.
    if (illness == null || dist == null) {
      return ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Row(children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: AppColors.surfaceSunk, borderRadius: BorderRadius.circular(R.chip)),
          child: const AppIcon(Ic.info, size: 17, color: AppColors.inkMuted),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Building your baseline', style: AppText.label),
          const SizedBox(height: 2),
          Text('Illness watch compares today’s resting HR, HRV and skin temperature '
              'against your normal range. It needs about 7 nights of wear to start.',
              style: AppText.captionMuted),
        ])),
      ])));
    }

    final accent = signal ? AppColors.warn : AppColors.good;
    final softBg = signal ? AppColors.warnSoft : AppColors.goodSoft;
    final title = signal ? 'Elevated body signal' : 'All clear';
    final blurb = signal
        ? 'Your resting HR, HRV and temperature are deviating together — a pattern that can precede illness. A signal, not a diagnosis.'
        : 'Your resting HR, HRV and temperature are within your normal range.';

    return ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.all(Sp.x4), child: Row(children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: softBg, borderRadius: BorderRadius.circular(R.chip)),
          child: AppIcon(signal ? Ic.info : Ic.check, size: 17, color: accent),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: AppText.label.copyWith(color: accent)),
            const Spacer(),
            Text('index ${dist.toStringAsFixed(1)}', style: AppText.captionMuted),
          ]),
          const SizedBox(height: 2),
          Text(blurb, style: AppText.captionMuted),
        ])),
      ])),
      // Per-feature deviations (what's moving), when present.
      if (drivers.isNotEmpty) ...[
        const Divider(height: 1, color: AppColors.divider),
        Padding(padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2), child: Column(
          children: [
            for (final dr in drivers)
              DetailRow(label: dr['label']?.toString() ?? '', value: dr['detail']?.toString() ?? ''),
          ],
        )),
      ],
    ]));
  }
}

// ── SECTION EXTRAS: personal records + journal patterns ─────────────────────
// Resurfaces the Records (personal bests) and the journal correlation engine,
// scoped to a section, shown on its Today tab. Honest descriptive stats only.
const _recordCfg = {
  'sleep': [
    ('longest_sleep', 'Longest sleep', 'dur'),
    ('best_efficiency', 'Best efficiency', 'pct'),
  ],
  'heart': [
    ('lowest_rhr', 'Lowest resting HR', 'bpm'),
    ('lowest_sleeping_hr', 'Lowest sleeping HR', 'bpm'),
  ],
  'body': [
    ('top_strain', 'Top strain', 'strain'),
    ('most_steps', 'Most steps', 'int'),
  ],
};
const _journalCols = {
  'sleep': ['efficiency', 'duration_min'],
  'heart': ['resting_hr', 'recovery'],
  'body': ['strain'],
};

class SectionExtras extends StatefulWidget {
  final String section; // 'sleep' | 'heart' | 'body'
  const SectionExtras({super.key, required this.section});
  @override
  State<SectionExtras> createState() => _SectionExtrasState();
}

class _SectionExtrasState extends State<SectionExtras> {
  Map<String, dynamic>? _records;
  Map<String, dynamic>? _insights;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final r = await api.getRecords();
      Map<String, dynamic>? ins;
      try { ins = await api.getJournalInsights(range: '90d'); } catch (_) {}
      if (mounted) setState(() { _records = r; _insights = ins; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(num v, String kind) {
    switch (kind) {
      case 'dur': return hm(v);
      case 'pct': return '${(v * 100).round()}%';
      case 'strain': return v.toStringAsFixed(1);
      case 'int': return v.round().toString();
      default: return '${v.round()}';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final cfg = _recordCfg[widget.section] ?? const [];
    final recs = (_records?['records'] as Map?) ?? const {};
    final tiles = <Widget>[];
    for (final c in cfg) {
      final rec = (recs[c.$1] as Map?);
      final v = rec == null ? null : (rec['value'] as num?);
      if (v == null) continue;
      tiles.add(Expanded(child: ProCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.$2.toUpperCase(), style: AppText.overline, maxLines: 2),
          const SizedBox(height: Sp.x3),
          Text(_fmt(v, c.$3), style: AppText.metricSm.copyWith(fontSize: 20)),
        ]),
      )));
    }

    // Journal patterns relevant to this section.
    final cols = _journalCols[widget.section] ?? const [];
    final patternRows = <Widget>[];
    for (final ins in ((_insights?['insights'] as List?) ?? const [])) {
      final tag = (ins as Map)['tag']?.toString() ?? '';
      for (final e in ((ins['effects'] as List?) ?? const [])) {
        final em = e as Map;
        if (!cols.contains(em['col'])) continue;
        final pct = (em['delta_pct'] as num?)?.toDouble() ?? 0;
        if (pct.abs() < 3) continue; // skip negligible
        final better = em['better'] == true;
        patternRows.add(DetailRow(
          label: 'On "$tag" days',
          value: '${em['label']} ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%',
          trailing: AppIcon(better ? Ic.up : Ic.down, size: 16,
              color: better ? AppColors.good : AppColors.warn),
        ));
        if (patternRows.length >= 4) break;
      }
      if (patternRows.length >= 4) break;
    }

    if (tiles.isEmpty && patternRows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (tiles.isNotEmpty) ...[
        const SizedBox(height: Sp.x6),
        const SectionHeader('Records'),
        Row(children: [
          for (int i = 0; i < tiles.length; i++) ...[
            tiles[i],
            if (i < tiles.length - 1) const SizedBox(width: Sp.x3),
          ],
        ]),
      ],
      if (patternRows.isNotEmpty) ...[
        const SizedBox(height: Sp.x6),
        const SectionHeader('Patterns'),
        Text('How your tagged days compare — descriptive, not causal.',
            style: AppText.captionMuted),
        const SizedBox(height: Sp.x2),
        ProCard(child: Column(children: patternRows)),
      ],
    ]);
  }
}

