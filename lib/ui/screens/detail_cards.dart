// Per-metric day-detail content on the design language. Each *DayCard fetches
// its /day/* endpoint and hands the payload to a PURE content widget
// (HeartDayContent / OxygenNightContent / WearDayContent — testable with a
// sample map, no repo). The look is the redesigned bento: a numbers-first hero
// (BigStat for Heart, ArcGauge coverage for Oxygen/Wear), mixed-tone BigStat
// tiles, and explanations behind (i).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/metric.dart'
    show needMoreNightsFromNote, needMessageFromNote;
import '../../state/app_state.dart';
import '../design/design.dart';
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

/// Shared async wrapper: fetch a map, render via builder; skeleton/empty states.
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
      return Column(
        children: [
          Skeleton.hero(),
          const SizedBox(height: Sp.x3),
          Skeleton.tileRow(rows: 2),
        ],
      );
    }
    if (_d == null) {
      return SurfaceCard(
        child: Text('No data', style: AppText.captionMuted),
      );
    }
    return widget.build(_d!);
  }
}

/// A quiet honest-state tile (building baseline / nothing recorded) — one icon
/// chip + title + short line. Shared by the watch cards + empty leaves.
class _QuietState extends StatelessWidget {
  final OsIcon icon;
  final String title;
  final String message;
  const _QuietState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppColors.surfaceSunk,
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(icon, size: 17, color: AppColors.inkMuted),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.label),
                const SizedBox(height: 2),
                Text(message, style: AppText.captionMuted),
              ],
            ),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayHeart(date),
      build: (d) => HeartDayContent(data: d, date: date),
    );
  }
}

/// HeartDayContent — the pure heart-day board: a headline BigStat hero
/// (recovery or resting HR as the big figure), a mixed-tone bento of the
/// day's cardiac numbers, the 24 h HR curve, zones, the HRV suite, and the
/// always-honest illness / irregular-beat watches.
class HeartDayContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final String date;
  const HeartDayContent({super.key, required this.data, required this.date});

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
    final d = data;
    final hr = _hrPoints((d['hr'] as List?) ?? const []);
    final rhr = _n(d['resting_hr']);
    final rhrBase = _n(d['resting_hr_baseline']);
    final rec = _n(d['recovery']);
    final hrv = (d['hrv'] as Map?);
    final zones = (d['zones'] as Map?);
    final noct = (d['nocturnal'] as Map?);
    final illness = (d['illness'] as Map?);
    final resp = (d['resp'] as Map?);
    final spo2 = (d['spo2'] as Map?);
    final irr24 = (d['irregular_24h'] as Map?);
    final irr24v = (irr24?['value'] is Map)
        ? (irr24!['value'] as Map).cast<String, dynamic>()
        : null;
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
    final peak = hr.isEmpty ? null : hr.reduce((a, b) => a.y >= b.y ? a : b);
    final low = hr.isEmpty ? null : hr.reduce((a, b) => a.y <= b.y ? a : b);
    final sleepingHr = _n(noct?['sleeping_hr_avg']);
    final dipPct = _n(noct?['dip_pct']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── hero: the anatomical heart beside the day's headline figure ─────
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TileHeader(
                rec != null ? 'Recovery' : 'Resting HR',
                icon: rec != null ? OsIcon.recovery : OsIcon.restingHeartRate,
                trailing: InfoDot(
                  title: rec != null ? 'Recovery' : 'Resting heart rate',
                  body: rec != null
                      ? infoFor('recovery')!
                      : infoFor('resting_hr')!,
                  methodNote: rec != null
                      ? 'Plews lnRMSSD readiness vs your own baseline'
                      : null,
                ),
              ),
              const SizedBox(height: Sp.x2),
              rec != null
                  ? BigStat(
                      value: '${rec.round()}',
                      unit: '/100',
                      caption: 'HRV-based recovery',
                      captionAccent: true,
                      size: BigStatSize.xl,
                      color: AppColors.scoreColor(
                        (rec / 100).clamp(0.0, 1.0),
                      ),
                    )
                  : BigStat(
                      value: rhr == null ? null : '${rhr.round()}',
                      unit: 'bpm',
                      caption: (rhr != null && rhrBase != null)
                          ? '${(rhr - rhrBase) >= 0 ? '+' : ''}'
                                '${(rhr - rhrBase).toStringAsFixed(1)} vs baseline'
                          : 'resting heart rate',
                      size: BigStatSize.xl,
                    ),
            ],
          ),
        ).dsEnter(),
        const SizedBox(height: Sp.x3),

        // ── the cardiac bento ────────────────────────────────────────────────
        BentoColumns(
          left: [
            // HRV — the recovery-green tile.
            BentoTile(
              tone: BentoTone.soft,
              accent: DomainAccent.recovery,
              onTap: hrv == null
                  ? null
                  : () => openTrend(context, icon: OsIcon.activity, 
                      title: 'HRV (RMSSD)',
                      metric: 'hrv',
                      accent: DomainAccent.recovery),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('HRV'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: hrv?['rmssd']?.toString(),
                    unit: 'ms',
                  ),
                  if (_n(hrv?['baseline']) != null &&
                      _n(hrv?['rmssd']) != null) ...[
                    const SizedBox(height: Sp.x2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: BaselineDeltaChip(
                        _n(hrv!['rmssd'])!.toDouble() -
                            _n(hrv['baseline'])!.toDouble(),
                        unit: 'ms',
                        showVsNormal: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Sleeping HR + dip — the board's ink tile.
            BentoTile(
              tone: BentoTone.ink,
              accent: DomainAccent.heart,
              onTap: dipPct == null
                  ? null
                  : () => openTrend(context, icon: OsIcon.activity, 
                      title: 'Nocturnal HR dip',
                      metric: 'dip',
                      accent: DomainAccent.heart),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Sleeping HR'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: sleepingHr == null ? null : '${sleepingHr.round()}',
                    unit: 'bpm',
                    caption: dipPct == null
                        ? null
                        : 'dip ${(dipPct * 100).round()}%',
                    captionAccent: true,
                  ),
                ],
              ),
            ),
          ],
          right: [
            // Resting HR.
            BentoTile(
              accent: DomainAccent.heart,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Resting HR'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: rhr == null ? null : '${rhr.round()}',
                    unit: 'bpm',
                    caption: rhrBase == null ? null : 'usual ${rhrBase.round()}',
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── 24 h heart-rate curve (recent days only) ─────────────────────────
        if (detailedAvailable(date) && hr.length > 1) ...[
          const SizedBox(height: Sp.x3),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileHeader(
                  'Heart rate',
                  trailing: InfoDot(
                    title: 'Heart rate',
                    body:
                        'Your minute-by-minute heart rate across the day, on a '
                        'real time scale. Missing periods stay missing.',
                    methodNote:
                        'avg ${d['avg_hr'] ?? '—'} · max ${d['max_hr'] ?? '—'} bpm',
                  ),
                ),
                const SizedBox(height: Sp.x3),
                TimeSeriesChart(
                  points: hr,
                  color: DomainAccent.heart,
                  height: 200,
                  yUnit: ' bpm',
                  tooltip: (p) {
                    final dt = DateTime.fromMillisecondsSinceEpoch(
                      (p.x * 1000).round(),
                    ).toLocal();
                    final mm = dt.minute.toString().padLeft(2, '0');
                    return '${dt.hour}:$mm\n${p.y.round()} bpm';
                  },
                ),
                const SizedBox(height: Sp.x3),
                Wrap(
                  spacing: Sp.x2,
                  runSpacing: Sp.x1,
                  children: [
                    if (latest != null)
                      StatusChip('Now ${latest.y.round()}',
                          tone: ChipTone.accent),
                    if (peak != null) StatusChip('Peak ${peak.y.round()}'),
                    if (low != null) StatusChip('Low ${low.y.round()}'),
                  ],
                ),
              ],
            ),
          ).dsEnter(index: 2),
        ] else if (!detailedAvailable(date)) ...[
          const SizedBox(height: Sp.x3),
          const DetailRetentionNote(what: 'minute-by-minute heart rate'),
        ],

        // ── HR zones ────────────────────────────────────────────────────────
        if (zones != null &&
            _zoneVals(zones).fold<double>(0, (s, v) => s + v) > 0) ...[
          const SizedBox(height: Sp.x3),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileHeader(
                  'Effort zones',
                  trailing: InfoDot(
                    title: 'Effort zones',
                    body: 'Minutes spent in each heart-rate zone today, '
                        'from easy (Z1) to maximal (Z5).',
                  ),
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

        // ── HRV suite — full Task-Force set, each tappable into its trend ───
        if (hrv != null) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Heart-rate variability'),
          MetricGroup([
            TrendMetricRow(
              icon: OsIcon.heartRate,
              // The headline HRV number gets the illustrated icon; the sibling
              // SDNN/LF-HF rows stay monochrome so the group doesn't repeat art.

              accent: DomainAccent.recovery,
              label: 'RMSSD',
              info: infoFor('rmssd'),
              value: '${hrv['rmssd'] ?? '—'}',
              unit: 'ms',
              metric: 'hrv',
              trendTitle: 'HRV (RMSSD)',
            ),
            if (hrv['sdnn'] != null)
              TrendMetricRow(
                icon: OsIcon.heartRate,
                accent: DomainAccent.recovery,
                label: 'SDNN',
                info: infoFor('sdnn'),
                value: '${hrv['sdnn']}',
                unit: 'ms',
                metric: 'sdnn',
                trendTitle: 'HRV (SDNN)',
              ),
            if (hrv['lf_hf'] != null)
              TrendMetricRow(
                icon: OsIcon.heartRate,
                accent: DomainAccent.recovery,
                label: 'LF / HF',
                info: infoFor('lf_hf'),
                value: '${hrv['lf_hf']}',
                metric: 'lf_hf',
                trendTitle: 'LF / HF',
              ),
            if (hrv['cv'] != null)
              TrendMetricRow(
                icon: OsIcon.activity,
                accent: DomainAccent.recovery,
                label: 'HRV stability',
                info: infoFor('hrv_cv'),
                value: '${hrv['cv']}',
                unit: '%',
                metric: 'hrv_cv',
                trendTitle: 'HRV stability (CV)',
              ),
            if (hrv['baseline'] != null)
              MetricRow(
                icon: OsIcon.activity,
                accent: AppColors.inkSoft,
                label: 'Your baseline',
                info: 'Your typical RMSSD — recovery is measured against this.',
                value: '${(_n(hrv['baseline']) ?? 0).round()}',
                unit: 'ms',
              ),
            if (brvHas)
              TrendMetricRow(
                icon: OsIcon.activity,
                accent: DomainAccent.recovery,
                label: 'Breathing variability',
                info: 'How much your breathing rate varied overnight '
                    '(within-user trend), tracked against your own history.',
                value: () {
                  final cv = _n((((d['brv'] as Map)['value']) as Map)['cv']);
                  return cv == null ? '—' : cv.toStringAsFixed(2);
                }(),
                metric: 'brv',
                trendTitle: 'Breathing-rate variability',
              ),
          ]),
        ],

        // ── 24/7 irregular-rhythm SCREEN (not a diagnosis) ───────────────────
        const SizedBox(height: Sp.x6),
        const SectionHeader('Rhythm screen'),
        Builder(builder: (context) {
          if (irr24v == null) {
            return const _QuietState(
              icon: OsIcon.heartRate,
              title: 'Not enough clean beats today',
              message:
                  'The 24/7 rhythm screen needs more artifact-free beat data '
                  'to read today.',
            );
          }
          final flag = irr24v['flag'] == true;
          final ratio = _n(irr24v['sd1_sd2']);
          final pnn = _n(irr24v['pnn_pct']);
          final accent = flag ? AppColors.warn : AppColors.good;
          return BentoTile(
            tone: BentoTone.soft,
            accent: accent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const OsAppIcon(OsIcon.ecgRhythm, size: 34),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: StatusChip(
                        flag ? 'Irregular pattern today' : 'Normal',
                        icon: flag
                            ? OsIcon.activity
                            : OsIcon.check,
                        tone: flag ? ChipTone.warn : ChipTone.positive,
                      ),
                    ),
                    InfoDot(
                      title: 'Rhythm screen',
                      body:
                          "A screen, not a diagnosis — wrist pulse can't see "
                          "the heart's electrical signal. See a clinician if "
                          'you have symptoms (palpitations, dizziness, '
                          'breathlessness).',
                      methodNote:
                          'Poincaré SD1/SD2 + pNN70 over the day’s clean beats',
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x3),
                Row(
                  children: [
                    Expanded(
                      child: BigStat(
                        value: ratio?.toStringAsFixed(2),
                        label: 'SD1/SD2',
                        size: BigStatSize.md,
                      ),
                    ),
                    Expanded(
                      child: BigStat(
                        value: pnn?.toStringAsFixed(0),
                        unit: '%',
                        label: 'pNN',
                        size: BigStatSize.md,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),

        // ── Personal baselines (Winsorized-EWMA) ─────────────────────────────
        if (baselines != null && baselines.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Personal baselines'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileHeader(
                  'You vs your normal',
                  trailing: InfoDot(
                    title: 'Personal baselines',
                    body:
                        'Robust, recency-weighted baselines (Winsorized EWMA). '
                        '"z" is today vs your personal range; the tag shows how '
                        'settled each baseline is (calibrating → trusted).',
                  ),
                ),
                for (final e in const [
                  ['resting_hr', 'Resting HR', 'bpm', false],
                  ['hrv', 'HRV (RMSSD)', 'ms', false],
                  ['resp', 'Respiratory rate', 'rpm', false],
                  ['skin_temp', 'Skin temp', '', true], // relative-only (ADC)
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

        // ── Respiratory + skin temperature ───────────────────────────────────
        if (resp != null || spo2 != null || dmap['desaturation'] is Map) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Respiratory'),
          MetricGroup([
            if (resp != null)
              MetricRow(
                icon: OsIcon.activity,
                accent: DomainAccent.oxygen,
                label: 'Respiratory rate',
                info: infoFor('resp'),
                value: '${resp['value']}',
                unit: 'brpm',
              ),
            if (spo2 != null)
              TrendMetricRow(
                icon: OsIcon.hydration,
                accent: DomainAccent.oxygen,
                label: 'Oxygen dips',
                info: infoFor('spo2'),
                value: '${spo2['odi_per_hour'] ?? spo2['value']}',
                unit: '/h',
                metric: 'spo2',
                trendTitle: 'Overnight oxygen dips',
              ),
            // Overnight desaturation screen (RELATIVE, not diagnostic).
            if (dmap['desaturation'] is Map)
              MetricRow(
                icon: OsIcon.hydration,
                accent: AppColors.warn,
                label: 'Desaturation dips',
                info:
                    'Number of relative blood-oxygen dips overnight (per hour). '
                    'A screen, not a diagnosis — talk to a clinician if it '
                    'stays high.',
                value: '${(dmap['desaturation'] as Map)['events'] ?? 0}',
                unit: '· ${(dmap['desaturation'] as Map)['odi'] ?? 0}/h',
              ),
          ]),
        ],

        if (spo2 != null || d['skin_temp'] is Map) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Skin temperature'),
          MetricGroup([
            if (d['skin_temp'] is Map &&
                _n((d['skin_temp'] as Map)['value']) != null)
              TrendMetricRow(
                icon: OsIcon.temperatureDeviation,
                accent: AppColors.coralDeep,
                label: 'Skin temp vs baseline',
                info: infoFor('skin_temp'),
                value: _signed(_n((d['skin_temp'] as Map)['value'])),
                unit: 'Δ',
                metric: 'skin_temp',
                trendTitle: 'Skin temp vs baseline',
              )
            else
              // No value yet → honest "Need N more nights" from the
              // need_baseline note, instead of a bare "—".
              MetricRow(
                icon: OsIcon.temperatureDeviation,
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

        // ── Illness watch — ALWAYS shown, three honest states ───────────────
        const SizedBox(height: Sp.x6),
        const SectionHeader('Illness watch'),
        _IllnessCard(illness),

        // ── Irregular-beat watch (nocturnal Poincaré) — ALWAYS shown ────────
        const SizedBox(height: Sp.x6),
        const SectionHeader('Irregular-beat watch'),
        _IrregularCard(d['irregular'] is Map ? d['irregular'] as Map : null),

        // ── What affected this — display-only ───────────────────────────────
        if (heartDrivers.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('What affected this'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
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
  }
}

// ── OXYGEN ───────────────────────────────────────────────────────────────────

class OxygenDayCard extends StatelessWidget {
  final String date;
  const OxygenDayCard({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayLungs(date),
      build: (d) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OxygenNightContent(data: d, date: date),
          if ((d['spo2'] as Map?) != null) ...[
            const SizedBox(height: Sp.x3),
            _OxygenRecentStrip(date: date),
          ],
        ],
      ),
    );
  }
}

/// OxygenNightContent — the pure overnight-oxygen board (slate domain): ODI
/// hero with a signal-coverage ArcGauge, verdict + severity tiles, the dip
/// trace, and the numbers group. RELATIVE red/IR screen — never absolute SpO₂.
class OxygenNightContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final String date;
  const OxygenNightContent({super.key, required this.data, required this.date});

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
    final d = data;
    final accent = DomainAccent.oxygen;
    final spo2 = (d['spo2'] as Map?)?.cast<String, dynamic>();
    final resp = (d['resp'] as Map?)?.cast<String, dynamic>();
    final points = _series(spo2);
    final events = ((spo2?['events'] as List?) ?? const [])
        .whereType<Map>()
        .cast<Map<String, dynamic>>()
        .toList();
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
    final sleepWindow = (d['sleep_window'] as Map?)?.cast<String, dynamic>();
    final sleepStart = (sleepWindow?['start'] as num?)?.toDouble();
    final sleepEnd = (sleepWindow?['end'] as num?)?.toDouble();
    final odiPerHour = (spo2?['odi_per_hour'] as num?)?.toDouble();
    final dipCount = (spo2?['dip_count'] as num?)?.toInt() ?? events.length;
    final verdict = _oxygenVerdict({
      'trusted_coverage': trustedCoverage,
      'signal_coverage': signalCoverage,
      'reject_total': rejectTotal,
      'dip_count': dipCount,
    });
    final severity = _oxygenSeverity(
      odiPerHour: odiPerHour,
      maxDipPct: maxDipPct,
      burdenPct: burdenPct,
      trustedCoverage: trustedCoverage,
      dipCount: dipCount,
    );

    if (spo2 == null) {
      return const _QuietState(
        icon: OsIcon.hydration,
        title: 'No overnight oxygen signal yet',
        message:
            'Wear the strap through the night — the red/IR channels need a '
            'full night of stable contact to read.',
      );
    }
    if (spo2['disabled'] == true) {
      return const _QuietState(
        icon: OsIcon.hydration,
        title: 'Overnight oxygen tracking is off',
        message:
            'This screen is temporarily disabled pending hardware-verified '
            'decoding — it will come back once that lands.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── hero: ODI beside the signal-coverage gauge ───────────────────────
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TileHeader(
                'Overnight oxygen',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tag('rel', color: accent),
                    InfoDot(
                      title: 'Overnight oxygen',
                      body: infoFor('spo2')!,
                      methodNote:
                          'Relative red/IR ratio vs your own nightly baseline '
                          '— a screening signal, never an absolute SpO₂%.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: BigStat(
                      value: odiPerHour?.toStringAsFixed(1),
                      unit: 'dips/h',
                      caption:
                          '${(spo2['dip_count'] as num?)?.toInt() ?? 0} dips · '
                          '${_nightSpan(analyzedHours)}',
                      size: BigStatSize.xl,
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  ArcGauge(
                    value: signalCoverage ?? double.nan,
                    color: accent,
                    size: 96,
                    stroke: 10,
                    valueText: signalCoverage == null
                        ? '—'
                        : '${(signalCoverage * 100).round()}%',
                    label: 'signal',
                  ),
                ],
              ),
            ],
          ),
        ).dsEnter(),
        const SizedBox(height: Sp.x3),

        // ── verdict + severity tiles ─────────────────────────────────────────
        BentoColumns(
          left: [
            BentoTile(
              tone: BentoTone.soft,
              accent: verdict.color,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TileHeader(
                    'Signal verdict',
                    trailing: InfoDot(
                      title: 'Signal verdict',
                      body: verdict.reason,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: verdict.label,
                    caption: trustedCoverage == null
                        ? null
                        : 'trusted ${(trustedCoverage * 100).round()}%',
                    size: BigStatSize.md,
                    color: verdict.color,
                  ),
                ],
              ),
            ),
            BentoTile(
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Burden'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: burdenPct?.toStringAsFixed(1),
                    unit: '%',
                    caption: 'of night in dips',
                  ),
                ],
              ),
            ),
          ],
          right: [
            BentoTile(
              tone: BentoTone.soft,
              accent: severity.color,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TileHeader(
                    'Overnight load',
                    trailing: InfoDot(
                      title: 'Overnight load',
                      body: severity.reason,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: severity.label,
                    caption: maxDipPct == null
                        ? null
                        : 'strongest ${maxDipPct.toStringAsFixed(1)}%',
                    size: BigStatSize.md,
                    color: severity.color,
                  ),
                ],
              ),
            ),
            BentoTile(
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Longest dip'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: longestDipSec == null ? null : '$longestDipSec',
                    unit: 's',
                    caption: meanDipPct == null
                        ? null
                        : 'mean depth ${meanDipPct.toStringAsFixed(1)}%',
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── dip-severity mix ─────────────────────────────────────────────────
        if (severityCounts != null) ...[
          const SizedBox(height: Sp.x3),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TileHeader('Dip severity mix'),
                const SizedBox(height: Sp.x3),
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
                Wrap(
                  spacing: Sp.x2,
                  runSpacing: Sp.x1,
                  children: [
                    StatusChip(
                      'Mild ${(severityCounts['mild'] as num?)?.toInt() ?? 0}',
                      tone: ChipTone.positive,
                    ),
                    StatusChip(
                      'Moderate ${(severityCounts['moderate'] as num?)?.toInt() ?? 0}',
                    ),
                    StatusChip(
                      'Severe ${(severityCounts['severe'] as num?)?.toInt() ?? 0}',
                      tone: ChipTone.warn,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],

        // ── the dip trace ────────────────────────────────────────────────────
        const SizedBox(height: Sp.x3),
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TileHeader(
                'Overnight dip signal',
                trailing: InfoDot(
                  title: 'Overnight dip signal',
                  body:
                      'Tracks overnight oxygen dips from the red/IR channel '
                      'pair against your own nightly baseline. A screening '
                      'signal, not an absolute saturation %.',
                ),
              ),
              const SizedBox(height: Sp.x3),
              if (points.length > 1)
                TimeSeriesChart(
                  points: points,
                  color: accent,
                  height: 200,
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
              if (points.length > 1) ...[
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
            ],
          ),
        ),

        // ── the numbers ──────────────────────────────────────────────────────
        const SizedBox(height: Sp.x6),
        const SectionHeader('The numbers'),
        MetricGroup([
          MetricRow(
            icon: OsIcon.hydration,
            accent: accent,
            label: 'Oxygen dips',
            info: infoFor('spo2'),
            value: odiPerHour?.toStringAsFixed(1) ?? '—',
            unit: '/h',
          ),
          MetricRow(
            icon: OsIcon.activity,
            accent: AppColors.warn,
            label: 'Dip burden',
            info: 'Share of the analyzed overnight signal spent in dip events.',
            value: burdenPct?.toStringAsFixed(1) ?? '—',
            unit: '%',
          ),
          MetricRow(
            icon: OsIcon.activity,
            accent: AppColors.good,
            label: 'Mean dip depth',
            info:
                'Average size of the accepted relative dips versus the rolling '
                'baseline.',
            value: meanDipPct?.toStringAsFixed(1) ?? '—',
            unit: '%',
          ),
          MetricRow(
            icon: OsIcon.activity,
            accent: accent,
            label: 'Strongest dip',
            info:
                'Largest accepted relative dip versus the rolling nightly '
                'baseline.',
            value: maxDipPct?.toStringAsFixed(1) ?? '—',
            unit: '%',
          ),
          MetricRow(
            icon: OsIcon.wear,
            accent: AppColors.inkSoft,
            label: 'Signal coverage',
            info:
                'Share of the overnight red/IR signal that was usable after '
                'contact and stability checks.',
            value: signalCoverage == null
                ? '—'
                : (signalCoverage * 100).toStringAsFixed(0),
            unit: '%',
          ),
          MetricRow(
            icon: OsIcon.wear,
            accent: AppColors.inkMuted,
            label: 'Trusted coverage',
            info:
                'Share of the overnight red/IR signal that survived the '
                'stricter artifact gate used for dip detection.',
            value: trustedCoverage == null
                ? '—'
                : (trustedCoverage * 100).toStringAsFixed(0),
            unit: '%',
          ),
          if (resp?['value'] != null)
            MetricRow(
              icon: OsIcon.activity,
              accent: AppColors.good,
              label: 'Respiratory rate',
              info: infoFor('resp'),
              value: '${resp!['value']}',
              unit: 'brpm',
            ),
        ]),

        // ── signal quality diagnostics ───────────────────────────────────────
        if (rejectCounts != null) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Signal quality'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
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

        // ── detected dips list ───────────────────────────────────────────────
        if (events.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Detected dips'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
            child: Column(
              children: [
                for (final e in events)
                  DetailRow(
                    label:
                        '${_hm((e['start'] as num?)?.toInt())} → ${_hm((e['end'] as num?)?.toInt())}',
                    value:
                        '${(e['duration_sec'] as num?)?.toInt() ?? 0}s · ${((e['peak_rise_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}%',
                  ),
              ],
            ),
          ),
        ],
      ],
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
      label: 'Noisy',
      color: AppColors.warn,
      reason: 'Low trusted coverage or too many rejected samples.',
    );
  }
  if (trusted < 0.65 || coverage < 0.75 || rejects > 500) {
    return (
      label: 'Shaky',
      color: AppColors.coral,
      reason: 'Usable, but signal quality is not stable enough to fully trust.',
    );
  }
  return (
    label: dips > 0 ? 'Usable' : 'Clean',
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
  required int dipCount,
}) {
  final trusted = trustedCoverage ?? 0;
  if (trusted < 0.6) {
    return (
      label: 'Uncertain',
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
      label: 'High',
      color: AppColors.warn,
      reason:
          'Tonight shows frequent or pronounced oxygen dips for this relative '
          'overnight screen.',
    );
  }
  if (odi >= 5 || maxDip >= 5 || burden >= 2) {
    return (
      label: 'Elevated',
      color: AppColors.coral,
      reason:
          'Tonight has a noticeable oxygen-dip load, but not an extreme one.',
    );
  }
  // Require a repeated pattern (>=2 dips) plus a real per-hour rate/burden
  // before calling anything out — a single stray dip is common PPG/motion
  // noise, not a finding, and used to fire "Mild" on almost every night.
  if (dipCount >= 2 && (odi >= 1 || maxDip >= 2 || burden >= 0.5)) {
    return (
      label: 'Mild',
      color: AppColors.good,
      reason:
          'Some dips were detected, but the overall overnight burden looks '
          'limited.',
    );
  }
  return (
    label: 'Quiet',
    color: AppColors.good,
    reason: 'No meaningful overnight oxygen dips were detected in this signal.',
  );
}

String _nightSpan(double? hours) {
  if (hours == null || hours <= 0) return '—';
  if (hours < 1) return '${(hours * 60).round()} min analyzed';
  return '${hours.toStringAsFixed(1)} h analyzed';
}

/// Last-7-nights strip — fetches the week trend anchored on [date] and grades
/// the pattern (spike / rising / settling / steady) honestly.
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
    if (_loading) return Skeleton.chart(height: 160);

    final buckets = ((_trend?['buckets'] as List?) ?? const [])
        .whereType<Map>()
        .cast<Map>()
        .toList();
    final present = buckets.where((b) => b['has'] == true).toList();
    if (present.isEmpty) {
      return const _QuietState(
        icon: OsIcon.hydration,
        title: 'No recent oxygen trend yet',
        message: 'A few more nights of wear build the 7-night pattern.',
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
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TileHeader(
            'Last 7 nights',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tag(pattern.label, color: pattern.color),
                InfoDot(title: 'Last 7 nights', body: pattern.reason),
              ],
            ),
          ),
          const SizedBox(height: Sp.x3),
          SizedBox(
            height: 150,
            child: LabeledBars(
              values: values,
              labels: labels,
              color: DomainAccent.oxygen,
              highlight: values.length - 1,
              valueFmt: (v) => v == 0 ? '' : v.toStringAsFixed(1),
            ),
          ),
          const SizedBox(height: Sp.x3),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x1,
            children: [
              StatusChip('Latest ${latest.toStringAsFixed(1)}/h',
                  tone: ChipTone.accent),
              StatusChip('Avg ${avg.toStringAsFixed(1)}/h'),
              StatusChip(
                '${(latest - avg >= 0 ? '+' : '')}${(latest - avg).toStringAsFixed(1)} vs avg',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── ILLNESS + IRREGULAR watches ──────────────────────────────────────────────

// Illness watch — always visible. One of three honest states from the
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

    // No baseline yet → honest "Need N more nights" state.
    if (illness == null || (cusum == null && !signal)) {
      final needLine = needNights != null
          ? 'Need $needNights more night${needNights == 1 ? '' : 's'} of wear to start.'
          : 'It needs about 7 nights of wear to start.';
      return _QuietState(
        icon: OsIcon.info,
        title: needNights != null
            ? 'Need $needNights more night${needNights == 1 ? '' : 's'}'
            : 'Building your baseline',
        message:
            'Illness watch compares today’s resting HR, HRV and skin '
            'temperature against your normal range. $needLine',
      );
    }

    final accent = signal ? AppColors.warn : AppColors.good;
    final title = signal ? 'Elevated body signal' : 'All clear';
    final blurb = signal
        ? 'Your resting HR, HRV and temperature are deviating together — a '
              'pattern that can precede illness. A signal, not a diagnosis.'
        : 'Your resting HR, HRV and temperature are within your normal range.';

    return BentoTile(
      tone: BentoTone.soft,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: StatusChip(
                  title,
                  icon: signal
                      ? OsIcon.activity
                      : OsIcon.check,
                  tone: signal ? ChipTone.warn : ChipTone.positive,
                ),
              ),
              if (cusum != null)
                Text(
                  'index ${cusum.toStringAsFixed(1)}',
                  style: AppText.captionMuted,
                ),
              InfoDot(
                title: 'Illness watch',
                body: blurb,
                methodNote:
                    'NightSignal CUSUM over resting HR / HRV / skin temp vs '
                    'your own baselines — a signal, not a diagnosis.',
              ),
            ],
          ),
          // Per-feature deviations (what's moving), when present.
          if (drivers.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            for (final dr in drivers)
              DetailRow(
                label: dr['label']?.toString() ?? '',
                value: dr['detail']?.toString() ?? '',
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
      return const _QuietState(
        icon: OsIcon.info,
        title: 'Listening for your rhythm',
        message:
            'This screens your beat-to-beat (RR) timing overnight for '
            'irregularity. It needs a night of good wear with heart-rate '
            'variability data to read.',
      );
    }
    final flag = irr!['flag'] == true;
    final accent = flag ? AppColors.warn : AppColors.good;
    return BentoTile(
      tone: BentoTone.soft,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: StatusChip(
                  flag ? 'Irregular rhythm pattern' : 'Rhythm looks regular',
                  icon: flag
                      ? OsIcon.activity
                      : OsIcon.check,
                  tone: flag ? ChipTone.warn : ChipTone.positive,
                ),
              ),
              InfoDot(
                title: 'Irregular-beat watch',
                body: flag
                    ? 'Your beat-to-beat timing was unusually irregular '
                          'overnight. A screen, not a diagnosis — if it '
                          'persists, see a clinician.'
                    : 'Beat-to-beat timing was within a normal range overnight.',
                methodNote: 'Poincaré SD1/SD2 + pNN from nocturnal RR',
              ),
            ],
          ),
          if (irr!['sd1'] != null && irr!['sd2'] != null) ...[
            const SizedBox(height: Sp.x2),
            DetailRow(
              label: 'Poincaré SD1 / SD2',
              value: '${irr!['sd1']} / ${irr!['sd2']} ms',
            ),
            if (irr!['pnn50'] != null)
              DetailRow(label: 'pNN50', value: '${irr!['pnn50']}%'),
          ],
        ],
      ),
    );
  }
}

// ── WEAR TIME ────────────────────────────────────────────────────────────────

class WearDayCard extends StatelessWidget {
  final String date;
  const WearDayCard({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    return _Fetch(
      load: (api) => api.getDayWear(date),
      build: (d) => WearDayContent(data: d, date: date),
    );
  }
}

/// WearDayContent — the pure wear-day board: worn-time hero with a coverage
/// ArcGauge, the 24-hour coverage bars (recent days only), and on/off tiles.
/// All from /day/wear (device wrist sensor, tier AUTH).
class WearDayContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final String date;
  const WearDayContent({super.key, required this.data, required this.date});

  num? _n(Object? v) => v is num ? v : null;

  // unix seconds → local "h:mm AM/PM"
  String _clock(num? ts) {
    if (ts == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000).toLocal();
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '$h:${d.minute.toString().padLeft(2, '0')} $ap';
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final accent = AppColors.coralDeep;
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
      return const _QuietState(
        icon: OsIcon.wear,
        title: 'Not worn on this day',
        message: 'No wrist contact was recorded — nothing to analyze.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── hero: worn time beside the coverage gauge ────────────────────────
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TileHeader(
                'Time worn',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tag('AUTH', color: AppColors.good),
                    InfoDot(
                      title: 'Wear time',
                      body:
                          'How long the strap was actually on your wrist, from '
                          'the device wrist sensor. More wear = better sleep, '
                          'recovery and baseline quality.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: BigStat(
                      value: hm(worn),
                      caption: '$cov% of the day',
                      size: BigStatSize.xl,
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  ArcGauge(
                    value: (cov / 100).clamp(0.0, 1.0),
                    color: AppColors.coralDeep,
                    size: 96,
                    stroke: 10,
                    valueText: '$cov%',
                    label: 'of day',
                  ),
                ],
              ),
            ],
          ),
        ).dsEnter(),

        // ── 24-hour coverage strip (recent days only) ────────────────────────
        if (!detailedAvailable(date)) ...[
          const SizedBox(height: Sp.x3),
          const DetailRetentionNote(what: 'hourly wear breakdown'),
        ] else if (hourly.length == 24) ...[
          const SizedBox(height: Sp.x3),
          SurfaceCard(
            padding: const EdgeInsets.all(Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileHeader(
                  'Hourly coverage',
                  trailing: InfoDot(
                    title: 'Hourly coverage',
                    body: 'Minutes worn in each hour of the day.',
                  ),
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

        // ── when + how continuous ────────────────────────────────────────────
        const SizedBox(height: Sp.x3),
        BentoColumns(
          left: [
            BentoTile(
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('First put on'),
                  const SizedBox(height: Sp.x2),
                  BigStat(value: _clock(firstOn), size: BigStatSize.md),
                ],
              ),
            ),
            BentoTile(
              tone: BentoTone.soft,
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Wear stretches'),
                  const SizedBox(height: Sp.x2),
                  BigStat(value: '$segments', size: BigStatSize.md),
                ],
              ),
            ),
          ],
          right: [
            BentoTile(
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Last worn'),
                  const SizedBox(height: Sp.x2),
                  BigStat(value: _clock(lastOn), size: BigStatSize.md),
                ],
              ),
            ),
            BentoTile(
              tone: BentoTone.soft,
              accent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Longest off'),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: longestOff > 0 ? hm(longestOff) : 'none',
                    size: BigStatSize.md,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
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

  Color get _accent => switch (widget.section) {
    'sleep' => DomainAccent.sleep,
    'body' => DomainAccent.strain,
    _ => DomainAccent.heart,
  };

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final cfg = _recordCfg[widget.section] ?? const [];
    final recs = (_records?['records'] as Map?) ?? const {};
    final tiles = <BentoItem>[];
    for (final c in cfg) {
      final rec = (recs[c.$1] as Map?);
      final v = rec == null ? null : (rec['value'] as num?);
      if (v == null) continue;
      tiles.add(
        BentoItem(
          BentoTile(
            tone: BentoTone.soft,
            accent: _accent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TileHeader(c.$2),
                const SizedBox(height: Sp.x2),
                BigStat(value: _fmt(v, c.$3), size: BigStatSize.md),
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
              better ? OsIcon.up : OsIcon.down,
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
          BentoGrid(items: tiles),
        ],
        if (patternRows.isNotEmpty) ...[
          const SizedBox(height: Sp.x6),
          const SectionHeader('Patterns'),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TileHeader(
                  'Your tagged days',
                  trailing: InfoDot(
                    title: 'Patterns',
                    body:
                        'How your tagged journal days compare with the rest — '
                        'descriptive, not causal.',
                  ),
                ),
                ...patternRows,
              ],
            ),
          ),
        ],
      ],
    );
  }
}
