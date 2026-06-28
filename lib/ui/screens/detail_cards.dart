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
                  MetricRow(
                    icon: Ic.droplet,
                    accent: AppColors.coralDeep,
                    label: 'Blood-oxygen',
                    info: infoFor('spo2'),
                    value: '${spo2['value']}',
                    unit: 'Δ',
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
