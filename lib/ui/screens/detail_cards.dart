// Per-metric day-detail cards. Each fetches its /day/* endpoint and renders with
// the EXISTING kit (RingStat, SegmentBar, DetailRow, ProCard, StatTile) — no new
// widget types. Used both for the "Today" tab (date = today) and as the inline
// drill leaf (date = the tapped day). One card per metric keeps it DRY.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/metric.dart'
    show needMoreNightsFromNote, needMessageFromNote;
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import 'metric_row.dart';
import 'trend_screen.dart';

String hm(num? minutes) {
  if (minutes == null) return '—';
  final m = minutes.round();
  return '${m ~/ 60}h ${m % 60}m';
}

/// Signed deviation string for relative metrics ("+0.3", "-0.2", "0.0").
String _signed(num? v) {
  if (v == null) return '—';
  final s = v.toStringAsFixed(1);
  return v > 0 ? '+$s' : s;
}

/// One Winsorized-EWMA baseline row: "center unit · z value" plus a status tag.
/// [relative] metrics (skin temp, raw ADC) show only z + status (no absolute).
Widget _baselineRow(
  Map<String, dynamic> b,
  String label,
  String unit, {
  bool relative = false,
}) {
  num? n(Object? v) => v is num ? v : null;
  final center = n(b['baseline']);
  final z = n(b['z']);
  final status = (b['status'] as String?) ?? 'calibrating';
  // status → tag colour: trusted=good, provisional=warn, calibrating/stale=muted.
  final tagColor = status == 'trusted'
      ? AppColors.good
      : (status == 'provisional' ? AppColors.warn : AppColors.inkSoft);
  final parts = <String>[];
  if (!relative && center != null) {
    parts.add('${center.round()}${unit.isEmpty ? '' : ' $unit'}');
  }
  if (z != null) parts.add('z ${_signed(z)}');
  final value = parts.isEmpty ? '—' : parts.join(' · ');
  return DetailRow(
    label: label,
    value: value,
    trailing: Tag(status, color: tagColor),
  );
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
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final d = await widget.load(api);
      if (mounted) {
        setState(() {
          _d = d;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(Sp.x5),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_d == null) {
      return ProCard(
        child: Padding(
          padding: const EdgeInsets.all(Sp.x4),
          child: Text('No data', style: AppText.captionMuted),
        ),
      );
    }
    return widget.build(_d!);
  }
}

// Zone palette reused across metrics.
final _zoneColors = [
  AppColors.cool,
  AppColors.loadDetraining,
  AppColors.good,
  AppColors.warn,
  AppColors.coral,
];

// ── HEART ────────────────────────────────────────────────────────────────────
class HeartDayCard extends StatelessWidget {
  final String date;
  const HeartDayCard({super.key, required this.date});

  num? _n(Object? v) => v is num ? v : null;

  List<double> _zoneVals(Map z) => [
    (z['zone1_min'] as num?)?.toDouble() ?? 0,
    (z['zone2_min'] as num?)?.toDouble() ?? 0,
    (z['zone3_min'] as num?)?.toDouble() ?? 0,
    (z['zone4_min'] as num?)?.toDouble() ?? 0,
    (z['zone5_min'] as num?)?.toDouble() ?? 0,
  ];

  List<TimeSeriesPoint> _hrPoints(List raw) {
    final out = <TimeSeriesPoint>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final t = (e['t'] as num?)?.toDouble();
      final v = (e['v'] as num?)?.toDouble();
      if (t != null && v != null && v > 0) out.add(TimeSeriesPoint(t, v));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayHeart(date),
      build: (d) {
        final hrRaw = (d['hr'] as List?) ?? const [];
        final hr = _hrPoints(hrRaw);
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
        final irr24 = (d['irregular_24h'] as Map?);
        final irr24v = (irr24?['value'] is Map)
            ? (irr24!['value'] as Map).cast<String, dynamic>()
            : null;
        final hrr = _n(d['hrr']);
        final brvHas = (d['brv'] is Map) && ((d['brv'] as Map)['value'] is Map);
        final baselines = (d['baselines'] as Map?);
        final dmap = (d['drivers'] as Map?) ?? const {};
        final heartDrivers =
            [
                  ...((dmap['recovery'] as List?) ?? const []),
                  ...((dmap['stress'] as List?) ?? const []),
                ]
                .whereType<Map>()
                .where((dr) => (dr['label']?.toString() ?? '').isNotEmpty)
                .toList();
        final latest = hr.isEmpty ? null : hr.last;
        final peak = hr.isEmpty
            ? null
            : hr.reduce((a, b) => a.y >= b.y ? a : b);
        final low = hr.isEmpty ? null : hr.reduce((a, b) => a.y <= b.y ? a : b);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // HERO — recovery (HRV) if we have it, else resting HR.
            GlowCard(
              padding: const EdgeInsets.all(Sp.x6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            AppIcon(
                              rec != null ? Ic.recovery : Ic.heart,
                              size: 16,
                              color: AppColors.coralDeep,
                            ),
                            const SizedBox(width: Sp.x2),
                            Text(
                              rec != null ? 'RECOVERY' : 'RESTING HR',
                              style: AppText.overline,
                            ),
                            if (rec != null) ...[
                              const SizedBox(width: Sp.x2),
                              Tag('HRV', color: AppColors.good),
                            ],
                          ],
                        ),
                        const SizedBox(height: Sp.x3),
                        if (rec != null)
                          Text('${rec.round()}', style: AppText.display)
                        else if (rhr != null)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${rhr.round()}', style: AppText.display),
                              const SizedBox(width: Sp.x2),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text('bpm', style: AppText.bodySoft),
                              ),
                            ],
                          )
                        else
                          metricDash(44),
                        const SizedBox(height: Sp.x2),
                        Text(
                          rec != null
                              ? 'HRV-based recovery'
                              : (rhr != null && rhrBase != null
                                    ? '${(rhr - rhrBase) >= 0 ? '+' : ''}${(rhr - rhrBase).toStringAsFixed(1)} bpm vs baseline'
                                    : 'resting heart rate'),
                          style: AppText.bodySoft,
                        ),
                      ],
                    ),
                  ),
                  if (rec != null)
                    RingStat(
                      t: (rec / 100).clamp(0.0, 1.0),
                      color: AppColors.good,
                      size: 96,
                      stroke: 11,
                      center: Text('${rec.round()}%', style: AppText.metricSm),
                    ),
                ],
              ),
            ),

            // Minute-level 24h HR only for recent days; recovery/HRV/zones below are
            // permanent summaries and always show.
            if (detailedAvailable(date) && hr.length > 1) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Heart rate'),
              ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TimeSeriesChart(
                      points: hr,
                      color: AppColors.coral,
                      height: 220,
                      yUnit: ' bpm',
                      tooltip: (p) {
                        final dt = DateTime.fromMillisecondsSinceEpoch(
                          (p.x * 1000).round(),
                        ).toLocal();
                        final mm = dt.minute.toString().padLeft(2, '0');
                        return '${dt.hour}:$mm\n${p.y.round()} bpm';
                      },
                    ),
                    const SizedBox(height: Sp.x4),
                    Row(
                      children: [
                        if (latest != null)
                          Expanded(
                            child: _HeartMetricCell(
                              'Latest',
                              '${latest.y.round()}',
                            ),
                          ),
                        if (latest != null && peak != null)
                          const SizedBox(width: Sp.x2),
                        if (peak != null)
                          Expanded(
                            child: _HeartMetricCell(
                              'Peak',
                              '${peak.y.round()}',
                            ),
                          ),
                        if ((latest != null || peak != null) && low != null)
                          const SizedBox(width: Sp.x2),
                        if (low != null)
                          Expanded(
                            child: _HeartMetricCell('Low', '${low.y.round()}'),
                          ),
                      ],
                    ),
                    const SizedBox(height: Sp.x3),
                    Text(
                      'Real time scale. Missing periods stay missing. '
                      'avg ${d['avg_hr'] ?? '—'} · max ${d['max_hr'] ?? '—'} bpm',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
            ] else if (!detailedAvailable(date)) ...[
              const SizedBox(height: Sp.x6),
              const DetailRetentionNote(what: 'minute-by-minute heart rate'),
            ],

            // HRV — full Task-Force suite, each tappable into its trend.
            if (hrv != null) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Heart-rate variability'),
              MetricGroup([
                TrendMetricRow(
                  icon: Ic.pulse,
                  accent: AppColors.good,
                  label: 'RMSSD',
                  info: infoFor('rmssd'),
                  value: '${hrv['rmssd'] ?? '—'}',
                  unit: 'ms',
                  metric: 'hrv',
                  trendTitle: 'HRV (RMSSD)',
                ),
                if (hrv['sdnn'] != null)
                  TrendMetricRow(
                    icon: Ic.pulse,
                    accent: AppColors.good,
                    label: 'SDNN',
                    info: infoFor('sdnn'),
                    value: '${hrv['sdnn']}',
                    unit: 'ms',
                    metric: 'sdnn',
                    trendTitle: 'HRV (SDNN)',
                  ),
                if (hrv['lf_hf'] != null)
                  TrendMetricRow(
                    icon: Ic.pulse,
                    accent: AppColors.good,
                    label: 'LF / HF',
                    info: infoFor('lf_hf'),
                    value: '${hrv['lf_hf']}',
                    metric: 'lf_hf',
                    trendTitle: 'LF / HF',
                  ),
                if (hrv['cv'] != null)
                  TrendMetricRow(
                    icon: Ic.chart,
                    accent: AppColors.good,
                    label: 'HRV stability',
                    info: infoFor('hrv_cv'),
                    value: '${hrv['cv']}',
                    unit: '%',
                    metric: 'hrv_cv',
                    trendTitle: 'HRV stability (CV)',
                  ),
                if (hrv['baseline'] != null)
                  MetricRow(
                    icon: Ic.chart,
                    accent: AppColors.inkSoft,
                    label: 'Your baseline',
                    info:
                        'Your typical RMSSD — recovery is measured against this.',
                    value: '${(_n(hrv['baseline']) ?? 0).round()}',
                    unit: 'ms',
                  ),
              ]),
            ],

            // ── 24/7 irregular-rhythm SCREEN (not a diagnosis) ──────────────
            const SizedBox(height: Sp.x6),
            const SectionHeader('Rhythm screen'),
            Builder(builder: (_) {
              if (irr24v == null) {
                return ProCard(
                  child: Text(
                    'Not enough clean beats today to screen your heart rhythm.',
                    style: AppText.captionMuted,
                  ),
                );
              }
              final flag = irr24v['flag'] == true;
              final ratio = _n(irr24v['sd1_sd2']);
              final pnn = _n(irr24v['pnn_pct']);
              final accent = flag ? AppColors.coral : AppColors.good;
              return ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      AppIcon(flag ? Ic.heart : Ic.pulse,
                          size: 18, color: accent),
                      const SizedBox(width: Sp.x3),
                      Expanded(
                        child: Text(
                          flag
                              ? 'Irregular pattern detected today'
                              : 'Rhythm screen: normal',
                          style: AppText.label.copyWith(color: accent),
                        ),
                      ),
                      Tag('SCREEN', color: accent),
                    ]),
                    const SizedBox(height: Sp.x3),
                    Text(
                      "A screen, not a diagnosis — wrist pulse can't see the "
                      "heart's electrical signal. See a clinician if you have "
                      'symptoms (palpitations, dizziness, breathlessness).',
                      style: AppText.captionMuted,
                    ),
                    const SizedBox(height: Sp.x3),
                    Row(children: [
                      Expanded(
                        child: Text(
                          'SD1/SD2 ${ratio == null ? '—' : ratio.toStringAsFixed(2)}',
                          style: AppText.captionMuted,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'pNN ${pnn == null ? '—' : '${pnn.toStringAsFixed(0)}%'}',
                          style: AppText.captionMuted,
                        ),
                      ),
                    ]),
                  ],
                ),
              );
            }),

            // ── Heart-rate recovery + breathing-rate variability trends ─────
            if (hrr != null || brvHas) ...[
              const SizedBox(height: Sp.x6),
              const SectionHeader('Fitness & breathing'),
              MetricGroup([
                if (hrr != null)
                  TrendMetricRow(
                    icon: Ic.recovery,
                    accent: AppColors.good,
                    label: 'HR recovery',
                    info: 'Drop in heart rate 60 s after exercise. Faster '
                        'recovery means a fitter, better-regulated heart.',
                    value: hrr.toStringAsFixed(0),
                    unit: 'bpm',
                    metric: 'hrr',
                    trendTitle: 'Heart-rate recovery',
                  ),
                if (brvHas)
                  TrendMetricRow(
                    icon: Ic.chart,
                    accent: AppColors.good,
                    label: 'Breathing variability',
                    info: 'How much your breathing rate varied overnight '
                        '(within-user trend), tracked against your own history.',
                    value: () {
                      final cv =
                          _n((((d['brv'] as Map)['value']) as Map)['cv']);
                      return cv == null ? '—' : cv.toStringAsFixed(2);
                    }(),
                    metric: 'brv',
                    trendTitle: 'Breathing-rate variability',
                  ),
              ]),
            ],

            // Personal baselines (Winsorized-EWMA) — robust center + how settled
            // each baseline is (calibrating → trusted), with today's z vs your range.
            if (baselines != null && baselines.isNotEmpty) ...[
              const SizedBox(height: Sp.x6),
              const SectionHeader('Personal baselines'),
              ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Robust, recency-weighted (Winsorized EWMA). "z" is today vs your '
                      'personal range; status shows how settled each baseline is.',
                      style: AppText.captionMuted,
                    ),
                    const SizedBox(height: Sp.x3),
                    for (final e in const [
                      ['resting_hr', 'Resting HR', 'bpm', false],
                      ['hrv', 'HRV (RMSSD)', 'ms', false],
                      ['resp', 'Respiratory rate', 'rpm', false],
                      [
                        'skin_temp',
                        'Skin temp',
                        '',
                        true,
                      ], // relative-only (raw ADC)
                    ])
                      if (baselines[e[0] as String] is Map)
                        _baselineRow(
                          (baselines[e[0] as String] as Map)
                              .cast<String, dynamic>(),
                          e[1] as String,
                          e[2] as String,
                          relative: e[3] as bool,
                        ),
                  ],
                ),
              ),
            ],

            // Stress (HRV-based).
            if (stress != null &&
                (stress['si'] != null || stress['score'] != null)) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Stress'),
              MetricGroup([
                MetricRow(
                  icon: Ic.strain,
                  accent: AppColors.warn,
                  label: 'Stress',
                  info: infoFor('stress'),
                  value: '${stress['score'] ?? stress['si']}',
                  valueTag: stress['level'] != null
                      ? Tag(
                          '${stress['level']}'.toUpperCase(),
                          color: AppColors.warn,
                        )
                      : null,
                ),
                if (stress['lf_hf'] != null)
                  MetricRow(
                    icon: Ic.pulse,
                    accent: AppColors.warn,
                    label: 'Sympatho-vagal balance',
                    info: infoFor('lf_hf'),
                    value: '${stress['lf_hf']}',
                  ),
              ]),
            ],

            if (zones != null &&
                _zoneVals(zones).fold<double>(0, (s, v) => s + v) > 0) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('HR zones'),
              ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Minutes spent in each effort zone today.',
                      style: AppText.captionMuted,
                    ),
                    const SizedBox(height: Sp.x3),
                    SegmentBar(_zoneVals(zones), _zoneColors, height: 14),
                    const SizedBox(height: Sp.x3),
                    Wrap(
                      spacing: Sp.x4,
                      runSpacing: Sp.x2,
                      children: [
                        for (int i = 0; i < 5; i++)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: _zoneColors[i],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: Sp.x2),
                              Text(
                                'Z${i + 1} · ${_zoneVals(zones)[i].round()}m',
                                style: AppText.caption,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            if (noct != null && noct['sleeping_hr_avg'] != null) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Nocturnal heart'),
              MetricGroup([
                MetricRow(
                  icon: Ic.moon,
                  accent: AppColors.loadDetraining,
                  label: 'Sleeping HR',
                  info: infoFor('sleeping_hr'),
                  value: '${noct['sleeping_hr_avg']}',
                  unit: 'bpm',
                ),
                if (noct['dip_pct'] != null)
                  TrendMetricRow(
                    icon: Ic.down,
                    accent: AppColors.good,
                    label: 'Nocturnal dip',
                    info: infoFor('dip'),
                    value: '${((noct['dip_pct'] as num) * 100).round()}',
                    unit: '%',
                    metric: 'dip',
                    trendTitle: 'Nocturnal HR dip',
                  ),
                if (noct['vs_baseline_bpm'] != null)
                  MetricRow(
                    icon: Ic.chart,
                    accent: AppColors.inkSoft,
                    label: 'vs baseline',
                    info: 'Tonight vs your typical sleeping heart rate.',
                    value: '${noct['vs_baseline_bpm']}',
                    unit: 'bpm',
                  ),
              ]),
            ],

            if (resp != null ||
                spo2 != null ||
                dmap['desaturation'] is Map) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Respiratory'),
              MetricGroup([
                if (resp != null)
                  MetricRow(
                    icon: Ic.activity,
                    accent: AppColors.good,
                    label: 'Respiratory rate',
                    info: infoFor('resp'),
                    value: '${resp['value']}',
                    unit: 'brpm',
                  ),
                if (spo2 != null)
                  TrendMetricRow(
                    icon: Ic.droplet,
                    accent: AppColors.coralDeep,
                    label: 'Oxygen dips',
                    info: infoFor('spo2'),
                    value: '${spo2['odi_per_hour'] ?? spo2['value']}',
                    unit: '/h',
                    metric: 'spo2',
                    trendTitle: 'Overnight oxygen dips',
                  ),
                // Overnight desaturation screen (RELATIVE, not diagnostic) — clustered dips
                // in the red/IR ratio vs your baseline. An apnea-style screening signal only.
                if (dmap['desaturation'] is Map)
                  MetricRow(
                    icon: Ic.droplet,
                    accent: AppColors.warn,
                    label: 'Desaturation dips',
                    info:
                        'Number of relative blood-oxygen dips overnight (per hour). A screen, not a diagnosis — talk to a clinician if it stays high.',
                    value: '${(dmap['desaturation'] as Map)['events'] ?? 0}',
                    unit: '· ${(dmap['desaturation'] as Map)['odi'] ?? 0}/h',
                  ),
              ]),
            ],

            // Skin temperature — relative deviation vs your personal baseline (°),
            // tappable into its trend. Honest: relative, not an absolute thermometer.
            if (spo2 != null || d['skin_temp'] is Map) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Skin temperature'),
              MetricGroup([
                if (d['skin_temp'] is Map &&
                    _n((d['skin_temp'] as Map)['value']) != null)
                  TrendMetricRow(
                    icon: Ic.thermometer,
                    accent: AppColors.coralDeep,
                    label: 'Skin temp vs baseline',
                    info: infoFor('skin_temp'),
                    value: _signed(_n((d['skin_temp'] as Map)['value'])),
                    unit: 'Δ',
                    metric: 'skin_temp',
                    trendTitle: 'Skin temp vs baseline',
                  )
                else
                  // No value yet → honest "Need N more nights" (baseline building),
                  // from the need_baseline note, instead of a bare "—".
                  MetricRow(
                    icon: Ic.thermometer,
                    accent: AppColors.inkSoft,
                    label: 'Skin temp vs baseline',
                    info: infoFor('skin_temp'),
                    value:
                        needMessageFromNote(
                          (d['skin_temp'] as Map?)?['note'] as String?,
                        ) ??
                        '—',
                  ),
              ]),
            ],

            // Illness watch — ALWAYS shown (Mahalanobis of resting HR / HRV / temp).
            // Three honest states: active signal, all-clear, or still building baseline.
            ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Illness watch'),
              _IllnessCard(illness),
            ],

            // Irregular-rhythm screen (Poincaré from nocturnal RR) — ALWAYS shown,
            // with a "building" state until there's a night of RR to read.
            ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Irregular-beat watch'),
              _IrregularCard(
                d['irregular'] is Map ? d['irregular'] as Map : null,
              ),
            ],

            // What affected this — display-only (no navigation loop), properly padded.
            if (heartDrivers.isNotEmpty) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('What affected this'),
              ProCard(
                child: Column(
                  children: [
                    for (final dr in heartDrivers)
                      DetailRow(
                        label: dr['label']?.toString() ?? '',
                        value: dr['detail']?.toString() ?? '',
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class OxygenDayCard extends StatelessWidget {
  final String date;
  const OxygenDayCard({super.key, required this.date});

  List<TimeSeriesPoint> _series(Map<String, dynamic>? spo2) {
    final raw = (spo2?['series'] as List?) ?? const [];
    final out = <TimeSeriesPoint>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final t = (e['t'] as num?)?.toDouble();
      final v = (e['rise_pct'] as num?)?.toDouble();
      if (t != null && v != null) out.add(TimeSeriesPoint(t, v));
    }
    return out;
  }

  String _hm(int? ts) {
    if (ts == null) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.hour}:$mm';
  }

  Map<String, dynamic>? _eventAt(
    List<Map<String, dynamic>> events,
    double tsSec,
  ) {
    for (final e in events) {
      final start = (e['start'] as num?)?.toDouble();
      final end = (e['end'] as num?)?.toDouble();
      if (start == null || end == null) continue;
      if (tsSec >= start && tsSec <= end) return e;
    }
    return null;
  }

  String _tooltipForPoint(
    TimeSeriesPoint p,
    List<Map<String, dynamic>> events, {
    double? sleepStart,
    double? sleepEnd,
  }) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (p.x * 1000).round(),
    ).toLocal();
    final mm = dt.minute.toString().padLeft(2, '0');
    final inSleep =
        sleepStart != null &&
        sleepEnd != null &&
        p.x >= sleepStart &&
        p.x <= sleepEnd;
    final event = _eventAt(events, p.x);
    final lines = <String>[
      '${dt.hour}:$mm',
      '${p.y.toStringAsFixed(1)}% above baseline',
      inSleep ? 'Sleep window' : 'Outside sleep window',
    ];
    if (event != null) {
      final peak = ((event['peak_rise_pct'] as num?)?.toDouble() ?? 0)
          .toStringAsFixed(1);
      final dur = (event['duration_sec'] as num?)?.toInt() ?? 0;
      lines.add('Dip event · ${dur}s · peak $peak%');
    }
    return lines.join('\n');
  }

  List<VerticalSpan> _eventSpans(List<Map<String, dynamic>> events) {
    return [
      for (final e in events)
        if ((e['start'] as num?) != null && (e['end'] as num?) != null)
          VerticalSpan(
            ((e['start'] as num).toDouble()),
            ((e['end'] as num).toDouble()),
            AppColors.warn.withValues(alpha: 0.12),
          ),
    ];
  }

  List<VerticalMarker> _eventMarkers(List<Map<String, dynamic>> events) {
    return [
      for (final e in events)
        if ((e['start'] as num?) != null)
          VerticalMarker(
            ((e['start'] as num).toDouble()),
            AppColors.warn.withValues(alpha: 0.65),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayLungs(date),
      build: (d) {
        final spo2 = (d['spo2'] as Map?)?.cast<String, dynamic>();
        final resp = (d['resp'] as Map?)?.cast<String, dynamic>();
        final points = _series(spo2);
        final events = ((spo2?['events'] as List?) ?? const [])
            .whereType<Map>()
            .cast<Map<String, dynamic>>()
            .toList();
        final latestEvent = events.isEmpty ? null : events.last;
        final signalCoverage = (spo2?['signal_coverage'] as num?)?.toDouble();
        final trustedCoverage = (spo2?['trusted_coverage'] as num?)?.toDouble();
        final analyzedHours = (spo2?['analyzed_hours'] as num?)?.toDouble();
        final burdenPct = (spo2?['burden_pct'] as num?)?.toDouble();
        final meanDipPct = (spo2?['mean_dip_pct'] as num?)?.toDouble();
        final maxDipPct = (spo2?['max_dip_pct'] as num?)?.toDouble();
        final longestDipSec = (spo2?['longest_dip_sec'] as num?)?.toInt();
        final rejectCounts = (spo2?['reject_counts'] as Map?)
            ?.cast<String, dynamic>();
        final severityCounts = (spo2?['severity_counts'] as Map?)
            ?.cast<String, dynamic>();
        final rejectTotal =
            rejectCounts?.values.whereType<num>().fold<int>(
              0,
              (sum, v) => sum + v.toInt(),
            ) ??
            0;
        final sleepWindow = (d['sleep_window'] as Map?)
            ?.cast<String, dynamic>();
        final sleepStart = (sleepWindow?['start'] as num?)?.toDouble();
        final sleepEnd = (sleepWindow?['end'] as num?)?.toDouble();
        final odiPerHour = (spo2?['odi_per_hour'] as num?)?.toDouble();
        final verdict = _oxygenVerdict({
          'trusted_coverage': trustedCoverage,
          'signal_coverage': signalCoverage,
          'reject_total': rejectTotal,
          'dip_count': (spo2?['dip_count'] as num?)?.toInt() ?? events.length,
        });
        final severity = _oxygenSeverity(
          odiPerHour: odiPerHour,
          maxDipPct: maxDipPct,
          burdenPct: burdenPct,
          trustedCoverage: trustedCoverage,
        );

        if (spo2 == null) {
          return ProCard(
            child: Padding(
              padding: const EdgeInsets.all(Sp.x4),
              child: Text(
                'No overnight red/IR oxygen signal yet.',
                style: AppText.captionMuted,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlowCard(
              padding: const EdgeInsets.all(Sp.x6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            AppIcon(
                              Ic.droplet,
                              size: 16,
                              color: AppColors.coralDeep,
                            ),
                            const SizedBox(width: Sp.x2),
                            Text('OVERNIGHT OXYGEN', style: AppText.overline),
                          ],
                        ),
                        const SizedBox(height: Sp.x3),
                        Text(
                          (spo2['odi_per_hour'] as num?)?.toStringAsFixed(1) ??
                              '—',
                          style: AppText.display,
                        ),
                        const SizedBox(height: Sp.x1),
                        Text(
                          '${(spo2['dip_count'] as num?)?.toInt() ?? 0} dips · '
                          '${analyzedHours?.toStringAsFixed(1) ?? '—'} h analyzed',
                          style: AppText.bodySoft,
                        ),
                      ],
                    ),
                  ),
                  RingStat(
                    t: (((signalCoverage ?? 0) * 100) / 100).clamp(0.0, 1.0),
                    color: AppColors.coralDeep,
                    size: 96,
                    stroke: 11,
                    center: Text(
                      signalCoverage == null
                          ? '—'
                          : '${(signalCoverage * 100).round()}%',
                      style: AppText.metricSm,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader('Tonight at a glance'),
            ProCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Verdict', style: AppText.label),
                      const Spacer(),
                      Tag(verdict.label, color: verdict.color),
                    ],
                  ),
                  const SizedBox(height: Sp.x2),
                  Text(verdict.reason, style: AppText.bodySoft),
                  const SizedBox(height: Sp.x4),
                  Row(
                    children: [
                      Expanded(
                        child: _MiniMetricCell(
                          'ODI',
                          '${(spo2['odi_per_hour'] as num?)?.toStringAsFixed(1) ?? '—'} /h',
                        ),
                      ),
                      const SizedBox(width: Sp.x3),
                      Expanded(
                        child: _MiniMetricCell(
                          'Signal',
                          signalCoverage == null
                              ? '—'
                              : '${(signalCoverage * 100).round()}%',
                        ),
                      ),
                      const SizedBox(width: Sp.x3),
                      Expanded(
                        child: _MiniMetricCell(
                          'Night',
                          _nightSpan(analyzedHours),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader('Overnight severity'),
            ProCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Assessment', style: AppText.label),
                      const Spacer(),
                      Tag(severity.label, color: severity.color),
                    ],
                  ),
                  const SizedBox(height: Sp.x2),
                  Text(severity.reason, style: AppText.bodySoft),
                  const SizedBox(height: Sp.x4),
                  Row(
                    children: [
                      Expanded(
                        child: _MiniMetricCell(
                          'Strongest dip',
                          maxDipPct == null
                              ? '—'
                              : '${maxDipPct.toStringAsFixed(1)}%',
                        ),
                      ),
                      const SizedBox(width: Sp.x3),
                      Expanded(
                        child: _MiniMetricCell(
                          'Burden',
                          burdenPct == null
                              ? '—'
                              : '${burdenPct.toStringAsFixed(1)}%',
                        ),
                      ),
                      const SizedBox(width: Sp.x3),
                      Expanded(
                        child: _MiniMetricCell(
                          'Longest',
                          longestDipSec == null ? '—' : '${longestDipSec}s',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            if (severityCounts != null) ...[
              SectionHeader('Dip severity mix'),
              ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentBar(
                      [
                        (severityCounts['mild'] as num?)?.toDouble() ?? 0,
                        (severityCounts['moderate'] as num?)?.toDouble() ?? 0,
                        (severityCounts['severe'] as num?)?.toDouble() ?? 0,
                      ],
                      [AppColors.good, AppColors.coral, AppColors.warn],
                      height: 14,
                    ),
                    const SizedBox(height: Sp.x3),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniMetricCell(
                            'Mild',
                            '${(severityCounts['mild'] as num?)?.toInt() ?? 0}',
                          ),
                        ),
                        const SizedBox(width: Sp.x3),
                        Expanded(
                          child: _MiniMetricCell(
                            'Moderate',
                            '${(severityCounts['moderate'] as num?)?.toInt() ?? 0}',
                          ),
                        ),
                        const SizedBox(width: Sp.x3),
                        Expanded(
                          child: _MiniMetricCell(
                            'Severe',
                            '${(severityCounts['severe'] as num?)?.toInt() ?? 0}',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x6),
            ],
            _OxygenRecentStrip(date: date),
            const SizedBox(height: Sp.x6),
            SectionHeader('Overnight dip signal'),
            ProCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (points.length > 1)
                    TimeSeriesChart(
                      points: points,
                      color: AppColors.coralDeep,
                      height: 220,
                      yUnit: '%',
                      minY: -1,
                      spans: [
                        if (sleepStart != null && sleepEnd != null)
                          VerticalSpan(
                            sleepStart,
                            sleepEnd,
                            AppColors.cool.withValues(alpha: 0.08),
                          ),
                        ..._eventSpans(events),
                      ],
                      markers: _eventMarkers(events),
                      bands: const [
                        HorizontalBand(0, 3, Color(0x1426A69A)),
                        HorizontalBand(3, 6, Color(0x14F4B942)),
                        HorizontalBand(6, 100, Color(0x14E57373)),
                      ],
                      tooltip: (p) => _tooltipForPoint(
                        p,
                        events,
                        sleepStart: sleepStart,
                        sleepEnd: sleepEnd,
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sp.x4),
                      child: Text(
                        'Not enough stable overnight signal for a dip trace yet.',
                        style: AppText.captionMuted,
                      ),
                    ),
                  const SizedBox(height: Sp.x3),
                  Text(
                    'Tracks overnight oxygen dips from the red/IR channel pair against your own nightly baseline. This is a screening signal, not an absolute saturation %. ',
                    style: AppText.captionMuted,
                  ),
                  const SizedBox(height: Sp.x2),
                  Wrap(
                    spacing: Sp.x4,
                    runSpacing: Sp.x2,
                    children: [
                      _legendPill(
                        'Sleep window',
                        AppColors.cool.withValues(alpha: 0.28),
                      ),
                      _legendPill(
                        'Detected dips',
                        AppColors.warn.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x6),
            SectionHeader('Summary'),
            MetricGroup([
              MetricRow(
                icon: Ic.droplet,
                accent: AppColors.coralDeep,
                label: 'Oxygen dips',
                info: infoFor('spo2'),
                value:
                    (spo2['odi_per_hour'] as num?)?.toStringAsFixed(1) ?? '—',
                unit: '/h',
              ),
              MetricRow(
                icon: Ic.chart,
                accent: AppColors.warn,
                label: 'Dip burden',
                info:
                    'Share of the analyzed overnight signal spent in dip events.',
                value: burdenPct?.toStringAsFixed(1) ?? '—',
                unit: '%',
              ),
              MetricRow(
                icon: Ic.activity,
                accent: AppColors.good,
                label: 'Mean dip depth',
                info:
                    'Average size of the accepted relative dips versus the rolling baseline.',
                value: meanDipPct?.toStringAsFixed(1) ?? '—',
                unit: '%',
              ),
              MetricRow(
                icon: Ic.chart,
                accent: AppColors.coralDeep,
                label: 'Strongest dip',
                info:
                    'Largest accepted relative dip versus the rolling nightly baseline.',
                value: maxDipPct?.toStringAsFixed(1) ?? '—',
                unit: '%',
              ),
              MetricRow(
                icon: Ic.watch,
                accent: AppColors.warn,
                label: 'Longest dip',
                info:
                    'Longest accepted dip event duration in the overnight signal.',
                value: longestDipSec == null ? '—' : '$longestDipSec',
                unit: 's',
              ),
              MetricRow(
                icon: Ic.watch,
                accent: AppColors.inkSoft,
                label: 'Signal coverage',
                info:
                    'Share of the overnight red/IR signal that was usable after contact and stability checks.',
                value: signalCoverage == null
                    ? '—'
                    : (signalCoverage * 100).toStringAsFixed(0),
                unit: '%',
              ),
              MetricRow(
                icon: Ic.watch,
                accent: AppColors.inkMuted,
                label: 'Trusted coverage',
                info:
                    'Share of the overnight red/IR signal that survived the stricter artifact gate used for dip detection.',
                value: trustedCoverage == null
                    ? '—'
                    : (trustedCoverage * 100).toStringAsFixed(0),
                unit: '%',
              ),
              if (resp?['value'] != null)
                MetricRow(
                  icon: Ic.activity,
                  accent: AppColors.good,
                  label: 'Respiratory rate',
                  info: infoFor('resp'),
                  value: '${resp!['value']}',
                  unit: 'brpm',
                ),
            ]),
            if (rejectCounts != null) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Signal quality'),
              ProCard(
                child: Column(
                  children: [
                    DetailRow(
                      label: 'Rejected: non-positive',
                      value: '${rejectCounts['non_positive'] ?? 0}',
                    ),
                    DetailRow(
                      label: 'Rejected: flatline',
                      value: '${rejectCounts['flatline'] ?? 0}',
                    ),
                    DetailRow(
                      label: 'Rejected: jump',
                      value: '${rejectCounts['jump'] ?? 0}',
                    ),
                    DetailRow(
                      label: 'Rejected: ratio outlier',
                      value: '${rejectCounts['ratio_outlier'] ?? 0}',
                    ),
                  ],
                ),
              ),
            ],
            if (latestEvent != null) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Latest dip'),
              ProCard(
                child: Column(
                  children: [
                    DetailRow(
                      label: 'Window',
                      value:
                          '${_hm((latestEvent['start'] as num?)?.toInt())} → ${_hm((latestEvent['end'] as num?)?.toInt())}',
                    ),
                    DetailRow(
                      label: 'Duration',
                      value:
                          '${(latestEvent['duration_sec'] as num?)?.toInt() ?? 0}s',
                    ),
                    DetailRow(
                      label: 'Peak rise',
                      value:
                          '${((latestEvent['peak_rise_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}%',
                    ),
                  ],
                ),
              ),
            ],
            if (events.isNotEmpty) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Detected dips'),
              ProCard(
                child: Column(
                  children: [
                    for (final e in events) ...[
                      DetailRow(
                        label:
                            '${_hm((e['start'] as num?)?.toInt())} → ${_hm((e['end'] as num?)?.toInt())}',
                        value:
                            '${(e['duration_sec'] as num?)?.toInt() ?? 0}s · ${((e['peak_rise_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}%',
                      ),
                      if (e != events.last)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Sp.x1),
                          child: Divider(height: 1),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

Widget _legendPill(String label, Color color) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: Sp.x2),
      Text(label, style: AppText.caption),
    ],
  );
}

({String label, Color color, String reason}) _oxygenVerdict(
  Map<String, dynamic> night,
) {
  final trusted = (night['trusted_coverage'] as num?)?.toDouble() ?? 0;
  final coverage = (night['signal_coverage'] as num?)?.toDouble() ?? 0;
  final rejects = (night['reject_total'] as num?)?.toInt() ?? 0;
  final dips = (night['dip_count'] as num?)?.toInt() ?? 0;

  if (trusted < 0.35 || (coverage < 0.5 && rejects > 100)) {
    return (
      label: 'noisy',
      color: AppColors.warn,
      reason: 'Low trusted coverage or too many rejected samples.',
    );
  }
  if (trusted < 0.65 || coverage < 0.75 || rejects > 500) {
    return (
      label: 'questionable',
      color: AppColors.coral,
      reason: 'Usable, but signal quality is not stable enough to fully trust.',
    );
  }
  return (
    label: dips > 0 ? 'usable' : 'clean',
    color: AppColors.good,
    reason: dips > 0
        ? 'Signal quality looks good enough to inspect the detected dips.'
        : 'Signal quality looks good and no dips were detected.',
  );
}

({String label, Color color, String reason}) _oxygenSeverity({
  required double? odiPerHour,
  required double? maxDipPct,
  required double? burdenPct,
  required double? trustedCoverage,
}) {
  final trusted = trustedCoverage ?? 0;
  if (trusted < 0.6) {
    return (
      label: 'uncertain',
      color: AppColors.inkSoft,
      reason:
          'Signal trust is too low to grade tonight’s oxygen burden confidently.',
    );
  }

  final odi = odiPerHour ?? 0;
  final maxDip = maxDipPct ?? 0;
  final burden = burdenPct ?? 0;

  if (odi >= 12 || maxDip >= 8 || burden >= 6) {
    return (
      label: 'high',
      color: AppColors.warn,
      reason:
          'Tonight shows frequent or pronounced oxygen dips for this relative overnight screen.',
    );
  }
  if (odi >= 5 || maxDip >= 5 || burden >= 2) {
    return (
      label: 'elevated',
      color: AppColors.coral,
      reason:
          'Tonight has a noticeable oxygen-dip load, but not an extreme one.',
    );
  }
  if (odi > 0 || maxDip > 0 || burden > 0) {
    return (
      label: 'mild',
      color: AppColors.good,
      reason:
          'Some dips were detected, but the overall overnight burden looks limited.',
    );
  }
  return (
    label: 'quiet',
    color: AppColors.good,
    reason: 'No meaningful overnight oxygen dips were detected in this signal.',
  );
}

String _nightSpan(double? hours) {
  if (hours == null || hours <= 0) return '—';
  if (hours < 1) return '${(hours * 60).round()} min analyzed';
  return '${hours.toStringAsFixed(1)} h analyzed';
}

class _OxygenRecentStrip extends StatefulWidget {
  final String date;
  const _OxygenRecentStrip({required this.date});

  @override
  State<_OxygenRecentStrip> createState() => _OxygenRecentStripState();
}

class _OxygenRecentStripState extends State<_OxygenRecentStrip> {
  Map<String, dynamic>? _trend;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final trend = await api.getTrend(
        'spo2',
        scale: 'week',
        anchor: widget.date,
      );
      if (!mounted) return;
      setState(() {
        _trend = trend;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _label(int ts) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
    return wd[(d.weekday - 1) % 7];
  }

  ({String label, Color color, String reason}) _patternVerdict(
    List<double> values,
  ) {
    if (values.length < 2) {
      return (
        label: 'early',
        color: AppColors.inkSoft,
        reason: 'Need a few more nights before a pattern is meaningful.',
      );
    }
    final latest = values.last;
    final avg = values.reduce((a, b) => a + b) / values.length;
    final recentCount = values.length >= 3 ? 3 : values.length;
    final recent =
        values.sublist(values.length - recentCount).reduce((a, b) => a + b) /
        recentCount;
    final olderValues = values.length > recentCount
        ? values.sublist(0, values.length - recentCount)
        : <double>[];
    final older = olderValues.isEmpty
        ? avg
        : olderValues.reduce((a, b) => a + b) / olderValues.length;
    final drift = recent - older;
    final outlier = avg > 0 && latest >= avg * 1.5 && latest - avg >= 1.5;

    if (outlier) {
      return (
        label: 'spike',
        color: AppColors.warn,
        reason: 'Tonight stands well above your recent oxygen-dip pattern.',
      );
    }
    if (drift >= 1.0) {
      return (
        label: 'rising',
        color: AppColors.coral,
        reason:
            'Recent nights are trending higher than the earlier part of the week.',
      );
    }
    if (drift <= -1.0) {
      return (
        label: 'settling',
        color: AppColors.good,
        reason:
            'Recent nights are trending lower than the earlier part of the week.',
      );
    }
    return (
      label: 'steady',
      color: AppColors.good,
      reason:
          'This week looks fairly stable rather than clearly rising or falling.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ProCard(
        child: Padding(
          padding: EdgeInsets.all(Sp.x4),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final buckets = ((_trend?['buckets'] as List?) ?? const [])
        .whereType<Map>()
        .cast<Map>()
        .toList();
    final present = buckets.where((b) => b['has'] == true).toList();
    if (present.isEmpty) {
      return ProCard(
        child: Padding(
          padding: const EdgeInsets.all(Sp.x4),
          child: Text(
            'No recent overnight oxygen trend yet.',
            style: AppText.captionMuted,
          ),
        ),
      );
    }
    final values = [
      for (final b in present) ((b['value'] as num?)?.toDouble() ?? 0),
    ];
    final labels = [
      for (final b in present) _label((b['t_start'] as num?)?.toInt() ?? 0),
    ];
    final avg = values.reduce((a, b) => a + b) / values.length;
    final latest = values.last;
    final pattern = _patternVerdict(values);
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Last 7 nights', style: AppText.label),
              const Spacer(),
              Tag(pattern.label, color: pattern.color),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(pattern.reason, style: AppText.captionMuted),
          const SizedBox(height: Sp.x4),
          SizedBox(
            height: 180,
            child: LabeledBars(
              values: values,
              labels: labels,
              color: AppColors.coralDeep,
              highlight: values.length - 1,
              valueFmt: (v) => v == 0 ? '' : v.toStringAsFixed(1),
            ),
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              Expanded(
                child: _MiniMetricCell(
                  'Latest',
                  '${latest.toStringAsFixed(1)} /h',
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: _MiniMetricCell(
                  'Week avg',
                  '${avg.toStringAsFixed(1)} /h',
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: _MiniMetricCell(
                  'Delta',
                  '${(latest - avg >= 0 ? '+' : '')}${(latest - avg).toStringAsFixed(1)} /h',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeartMetricCell extends StatelessWidget {
  final String label;
  final String value;
  const _HeartMetricCell(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppText.overline),
          const SizedBox(height: 2),
          Text('$value bpm', style: AppText.label),
        ],
      ),
    );
  }
}

class _MiniMetricCell extends StatelessWidget {
  final String label;
  final String value;
  const _MiniMetricCell(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppText.overline),
          const SizedBox(height: 2),
          Text(value, style: AppText.label, textAlign: TextAlign.center),
        ],
      ),
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
    // The 1 Hz illness day (CUSUM/NightSignal) exposes: state (green|yellow|red),
    // optional cusum, and `note` carrying the need_baseline:have=H,need=N
    // convention while the baseline is still too short.
    final state = illness?['state']?.toString();
    final cusum = _num(illness?['cusum']);
    final note = illness?['note']?.toString();
    final needNights = needMoreNightsFromNote(note);
    final signal = state == 'red' || state == 'yellow';
    final drivers =
        (illness?['drivers'] as List?)?.whereType<Map>().toList() ?? const [];

    // No baseline yet → honest "Need N more nights" state (precise when the note
    // carries the count; otherwise the generic ~7-night copy).
    if (illness == null || (cusum == null && !signal)) {
      final needLine = needNights != null
          ? 'Need $needNights more night${needNights == 1 ? '' : 's'} of wear to start.'
          : 'It needs about 7 nights of wear to start.';
      return ProCard(
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
                child: AppIcon(Ic.info, size: 17, color: AppColors.inkMuted),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      needNights != null
                          ? 'Need $needNights more night${needNights == 1 ? '' : 's'}'
                          : 'Building your baseline',
                      style: AppText.label,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Illness watch compares today’s resting HR, HRV and skin temperature '
                      'against your normal range. $needLine',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final accent = signal ? AppColors.warn : AppColors.good;
    final softBg = signal ? AppColors.warnSoft : AppColors.goodSoft;
    final title = signal ? 'Elevated body signal' : 'All clear';
    final blurb = signal
        ? 'Your resting HR, HRV and temperature are deviating together — a pattern that can precede illness. A signal, not a diagnosis.'
        : 'Your resting HR, HRV and temperature are within your normal range.';

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: softBg,
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: AppIcon(
                    signal ? Ic.info : Ic.check,
                    size: 17,
                    color: accent,
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: AppText.label.copyWith(color: accent),
                          ),
                          const Spacer(),
                          if (cusum != null)
                            Text(
                              'index ${cusum.toStringAsFixed(1)}',
                              style: AppText.captionMuted,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(blurb, style: AppText.captionMuted),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Per-feature deviations (what's moving), when present.
          if (drivers.isNotEmpty) ...[
            Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x4,
                vertical: Sp.x2,
              ),
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
        ],
      ),
    );
  }
}

// Irregular-rhythm screen card — ALWAYS shown, three honest states:
// "building baseline" (no data yet), green "looks regular", amber "irregular".
// A SCREEN, not a diagnosis. Conservative; shows the Poincaré descriptors.
class _IrregularCard extends StatelessWidget {
  final Map? irr;
  const _IrregularCard(this.irr);
  @override
  Widget build(BuildContext context) {
    final conf = (irr?['confidence'] as num?) ?? 0;
    // No usable nocturnal RR yet → honest "building" state.
    if (irr == null || conf <= 0) {
      return ProCard(
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
                child: AppIcon(Ic.info, size: 17, color: AppColors.inkMuted),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Listening for your rhythm', style: AppText.label),
                    const SizedBox(height: 2),
                    Text(
                      'This screens your beat-to-beat (RR) timing overnight for irregularity. '
                      'It needs a night of good wear with heart-rate variability data to read.',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final flag = irr!['flag'] == true;
    final accent = flag ? AppColors.warn : AppColors.good;
    final softBg = flag ? AppColors.warnSoft : AppColors.goodSoft;
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Sp.x4),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: softBg,
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: AppIcon(
                    flag ? Ic.info : Ic.check,
                    size: 17,
                    color: accent,
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        flag
                            ? 'Irregular rhythm pattern'
                            : 'Rhythm looks regular',
                        style: AppText.label.copyWith(color: accent),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        flag
                            ? 'Your beat-to-beat timing was unusually irregular overnight. A screen, not a diagnosis — if it persists, see a clinician.'
                            : 'Beat-to-beat timing was within a normal range overnight.',
                        style: AppText.captionMuted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (irr!['sd1'] != null && irr!['sd2'] != null) ...[
            Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x4,
                vertical: Sp.x2,
              ),
              child: Column(
                children: [
                  DetailRow(
                    label: 'Poincaré SD1 / SD2',
                    value: '${irr!['sd1']} / ${irr!['sd2']} ms',
                  ),
                  if (irr!['pnn50'] != null)
                    DetailRow(label: 'pNN50', value: '${irr!['pnn50']}%'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── WEAR TIME ────────────────────────────────────────────────────────────────
// How long the strap was on the wrist for a day: a coverage ring + worn time hero,
// a 24-hour coverage strip (minutes worn each hour), and when it went on/off.
// All from /day/wear (device wrist sensor, tier AUTH). Existing kit only.
class WearDayCard extends StatelessWidget {
  final String date;
  const WearDayCard({super.key, required this.date});

  num? _n(Object? v) => v is num ? v : null;

  // unix seconds → local "h:mm a"
  String _clock(num? ts) {
    if (ts == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000).toLocal();
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '$h:${d.minute.toString().padLeft(2, '0')} $ap';
  }

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayWear(date),
      build: (d) {
        final worn = (_n(d['worn_min']) ?? 0).toInt();
        final cov = (_n(d['coverage_pct']) ?? 0).toInt();
        final hourly = ((d['hourly'] as List?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList();
        final firstOn = _n(d['first_on']);
        final lastOn = _n(d['last_on']);
        final segments = (_n(d['segments']) ?? 0).toInt();
        final longestOff = (_n(d['longest_off_min']) ?? 0).toInt();

        if (worn == 0) {
          return ProCard(
            child: Padding(
              padding: const EdgeInsets.all(Sp.x5),
              child: Center(
                child: Text(
                  'The strap wasn’t worn on this day',
                  style: AppText.captionMuted,
                ),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero — worn time + coverage ring.
            GlowCard(
              padding: const EdgeInsets.all(Sp.x6),
              glow: AppColors.coralDeep,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            AppIcon(
                              Ic.watch,
                              size: 16,
                              color: AppColors.coralDeep,
                            ),
                            const SizedBox(width: Sp.x2),
                            Text('TIME WORN', style: AppText.overline),
                            const SizedBox(width: Sp.x2),
                            Tag('AUTH', color: AppColors.good),
                          ],
                        ),
                        const SizedBox(height: Sp.x3),
                        Text(hm(worn), style: AppText.display),
                        const SizedBox(height: Sp.x2),
                        Text('$cov% of the day', style: AppText.bodySoft),
                      ],
                    ),
                  ),
                  RingStat(
                    t: (cov / 100).clamp(0.0, 1.0),
                    color: AppColors.coralDeep,
                    size: 96,
                    stroke: 11,
                    center: Text('$cov%', style: AppText.metricSm),
                  ),
                ],
              ),
            ),

            // 24-hour coverage strip — minute-level, recent days only. The worn-time
            // total + first/last/segments summary above is permanent.
            if (!detailedAvailable(date)) ...[
              const SizedBox(height: Sp.x6),
              const DetailRetentionNote(what: 'hourly wear breakdown'),
            ] else if (hourly.length == 24) ...[
              const SizedBox(height: Sp.x6),
              SectionHeader('Hourly coverage'),
              ProCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Minutes worn in each hour of the day.',
                      style: AppText.captionMuted,
                    ),
                    const SizedBox(height: Sp.x3),
                    MiniBars(hourly, color: AppColors.coralDeep, height: 64),
                    const SizedBox(height: Sp.x2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('12a', style: AppText.captionMuted),
                        Text('6a', style: AppText.captionMuted),
                        Text('12p', style: AppText.captionMuted),
                        Text('6p', style: AppText.captionMuted),
                        Text('12a', style: AppText.captionMuted),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            // When + how continuous.
            const SizedBox(height: Sp.x6),
            SectionHeader('Details'),
            ProCard(
              child: Column(
                children: [
                  DetailRow(label: 'First put on', value: _clock(firstOn)),
                  DetailRow(label: 'Last worn', value: _clock(lastOn)),
                  DetailRow(label: 'Wear stretches', value: '$segments'),
                  DetailRow(
                    label: 'Longest off-wrist',
                    value: longestOff > 0 ? hm(longestOff) : 'none',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
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
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final r = await api.getRecords();
      Map<String, dynamic>? ins;
      try {
        ins = await api.getJournalInsights(range: '90d');
      } catch (_) {}
      if (mounted) {
        setState(() {
          _records = r;
          _insights = ins;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(num v, String kind) {
    switch (kind) {
      case 'dur':
        return hm(v);
      case 'pct':
        return '${(v * 100).round()}%';
      case 'strain':
        return v.toStringAsFixed(1);
      case 'int':
        return v.round().toString();
      default:
        return '${v.round()}';
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
      tiles.add(
        Expanded(
          child: ProCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.$2.toUpperCase(), style: AppText.overline, maxLines: 2),
                const SizedBox(height: Sp.x3),
                Text(
                  _fmt(v, c.$3),
                  style: AppText.metricSm.copyWith(fontSize: 20),
                ),
              ],
            ),
          ),
        ),
      );
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
        patternRows.add(
          DetailRow(
            label: 'On "$tag" days',
            value:
                '${em['label']} ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%',
            trailing: AppIcon(
              better ? Ic.up : Ic.down,
              size: 16,
              color: better ? AppColors.good : AppColors.warn,
            ),
          ),
        );
        if (patternRows.length >= 4) break;
      }
      if (patternRows.length >= 4) break;
    }

    if (tiles.isEmpty && patternRows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tiles.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Records'),
          Row(
            children: [
              for (int i = 0; i < tiles.length; i++) ...[
                tiles[i],
                if (i < tiles.length - 1) const SizedBox(width: Sp.x3),
              ],
            ],
          ),
        ],
        if (patternRows.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Patterns'),
          Text(
            'How your tagged days compare — descriptive, not causal.',
            style: AppText.captionMuted,
          ),
          const SizedBox(height: Sp.x2),
          ProCard(child: Column(children: patternRows)),
        ],
      ],
    );
  }
}
