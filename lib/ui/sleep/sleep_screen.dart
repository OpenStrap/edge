// Sleep tab — last night's duration vs need, stages, efficiency, regularity,
// and recent nights.

import 'package:flutter/material.dart';

import '../../models/metric.dart';
import '../../models/payloads.dart';
import '../../net/api_client.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/charts.dart';
import '../kit/kit.dart';
import '../widgets/screen_loader.dart';

class SleepScreen extends StatefulWidget {
  const SleepScreen({super.key});
  @override
  State<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends State<SleepScreen>
    with ScreenLoaderMixin<SleepScreen> {
  // Stage palette — coral-forward with cool accents for depth.
  static const _light = AppColors.loadDetraining; // cool blue
  static const _deep = AppColors.coralDeep;
  static const _rem = AppColors.coral;

  @override
  String get cacheKey => 'sleep';

  @override
  Future<Object?> fetch(ApiClient api) => api.getSleep();

  @override
  bool isEmpty(Object? d) => _rows(d).isEmpty;

  List<Map<String, dynamic>> _rows(Object? d) {
    if (d is List) {
      return d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  // ── formatters ──────────────────────────────────────────────────────────
  String _dur(Metric m) {
    if (m.isEmpty) return '—';
    final mins = m.value!.toInt();
    return '${mins ~/ 60}h ${mins % 60}m';
  }

  String _durMins(int mins) => '${mins ~/ 60}h ${mins % 60}m';

  String _clock(int? epoch) {
    if (epoch == null) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal();
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  String _effPct(Metric m) {
    if (m.isEmpty) return '—';
    final v = m.value!.toDouble();
    return '${(v <= 1 ? v * 100 : v).round()}';
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data);
    final night = SleepData.fromRows(rows);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => refresh(),
        color: AppColors.coral,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _TopTitle(title: 'Sleep', freshness: freshnessLabel),
            const SizedBox(height: Sp.x4),
            if (phase == LoadPhase.loading)
              ..._skeleton()
            else if (phase == LoadPhase.error && data == null)
              _ErrorCard(message: errorText ?? 'Pull to retry.')
            else if (phase == LoadPhase.empty)
              const _EmptyCard(
                icon: Ic.moon,
                title: 'No sleep recorded yet',
                message:
                    'Wear your strap overnight. After your next sync we\'ll show '
                    'duration, efficiency and estimated stages.',
              )
            else
              ..._content(night, rows),
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }

  List<Widget> _skeleton() => const [
        _Skeleton(height: 280),
        SizedBox(height: Sp.x4),
        _Skeleton(height: 150),
        SizedBox(height: Sp.x4),
        _Skeleton(height: 120),
      ];

  List<Widget> _content(SleepData n, List<Map<String, dynamic>> rows) {
    // Sleep need: fall back to 8h unless we have a PLAUSIBLE personal need
    // (≥3h). Sparse early data can yield garbage like 1 min → "0.0h"; floor it.
    final rawNeed = n.needMin.value?.toDouble() ?? 0;
    final need = rawNeed >= 180 ? rawNeed : 480.0;
    final dur = n.durationMin;
    final fill = dur.isEmpty || need <= 0
        ? double.nan
        : (dur.value! / need).clamp(0.0, 1.0).toDouble();

    return [
      _heroRing(n, need, fill),
      const SizedBox(height: Sp.x4),
      _stagesCard(n),
      const SizedBox(height: Sp.x6),
      const SectionHeader('Details'),
      _detailTiles(n),
      const SizedBox(height: Sp.x6),
      const SectionHeader('Recent nights'),
      _RecentNights(rows: rows, durMins: _durMins),
    ];
  }

  // HERO — ring of duration vs need, big duration in center.
  Widget _heroRing(SleepData n, double need, double fill) {
    final dur = n.durationMin;
    return ProCard(
      padding: const EdgeInsets.symmetric(vertical: Sp.x7, horizontal: Sp.x5),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AppIcon(Ic.bed, size: 18, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Text('LAST NIGHT', style: AppText.overline),
              if (!dur.isEmpty) ...[
                const SizedBox(width: Sp.x2),
                ConfDot(dur.confidence),
              ],
            ],
          ),
          const SizedBox(height: Sp.x5),
          RingStat(
            t: fill,
            color: AppColors.coral,
            size: 196,
            stroke: 16,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dur.isEmpty)
                  metricDash(40)
                else
                  Text(_dur(dur), style: AppText.display),
                const SizedBox(height: Sp.x2),
                Text(
                  need > 0
                      ? 'of ${(need / 60).toStringAsFixed(1)}h need'
                      : 'sleep duration',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (!n.efficiency.isEmpty) ...[
            const SizedBox(height: Sp.x5),
            Text('${_effPct(n.efficiency)}% efficient',
                style: AppText.label.copyWith(color: AppColors.inkSoft)),
          ],
        ],
      ),
    );
  }

  // STAGES — light/deep/rem SegmentBar + legend. Beta because estimated.
  Widget _stagesCard(SleepData n) {
    final segs = <({String name, int mins, Color color})>[
      if (!n.lightMin.isEmpty)
        (name: 'Light', mins: n.lightMin.value!.toInt(), color: _light),
      if (!n.deepMin.isEmpty)
        (name: 'Deep', mins: n.deepMin.value!.toInt(), color: _deep),
      if (!n.remMin.isEmpty)
        (name: 'REM', mins: n.remMin.value!.toInt(), color: _rem),
    ];

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Stages', style: AppText.h2)),
              const Tag('beta', color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Text('estimated', style: AppText.captionMuted),
            ],
          ),
          const SizedBox(height: Sp.x4),
          if (segs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.x2),
              child: Text('Stages not available for this night.',
                  style: AppText.captionMuted),
            )
          else ...[
            SegmentBar(
              [for (final s in segs) s.mins.toDouble()],
              [for (final s in segs) s.color],
              height: 14,
            ),
            const SizedBox(height: Sp.x4),
            Wrap(
              spacing: Sp.x5,
              runSpacing: Sp.x3,
              children: [
                for (final s in segs)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                            color: s.color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: Sp.x2),
                      Text(s.name, style: AppText.caption),
                      const SizedBox(width: Sp.x1),
                      Text(_durMins(s.mins),
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailTiles(SleepData n) {
    String? sri = n.regularity.isEmpty
        ? null
        : n.regularity.value!.round().toString();
    return Column(
      children: [
        Row(children: [
          Expanded(
            child: StatTile(
              icon: Ic.pulse,
              label: 'Efficiency',
              value: n.efficiency.isEmpty ? null : _effPct(n.efficiency),
              unit: '%',
              accent: AppColors.coral,
              confidence:
                  n.efficiency.isEmpty ? null : n.efficiency.confidence,
              tag: Tag.forMetric(n.efficiency),
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: StatTile(
              icon: Ic.calendar,
              label: 'Regularity',
              value: sri,
              unit: 'SRI',
              accent: AppColors.coral,
              confidence:
                  n.regularity.isEmpty ? null : n.regularity.confidence,
              tag: Tag.forMetric(n.regularity),
            ),
          ),
        ]),
        const SizedBox(height: Sp.x3),
        Row(children: [
          Expanded(
            child: StatTile(
              icon: Ic.moon,
              label: 'Onset',
              value: n.onsetEpoch == null ? null : _clock(n.onsetEpoch),
              accent: AppColors.inkSoft,
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: StatTile(
              icon: Ic.clock,
              label: 'Wake',
              value: n.wakeEpoch == null ? null : _clock(n.wakeEpoch),
              accent: AppColors.inkSoft,
            ),
          ),
        ]),
      ],
    );
  }
}

/// Recent-nights duration history as MiniBars + a short list.
class _RecentNights extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final String Function(int) durMins;
  const _RecentNights({required this.rows, required this.durMins});

  num? _mins(Map<String, dynamic> r) {
    final m = r['duration_min'];
    final v = m is Map ? m['value'] : m;
    return v is num ? v : (v is String ? num.tryParse(v) : null);
  }

  @override
  Widget build(BuildContext context) {
    // newest first → take up to 14, reverse to chronological for the bars.
    final recent = rows.take(14).toList();
    final mins = recent
        .map((r) => (_mins(r) ?? 0).toDouble())
        .toList()
        .reversed
        .toList();
    final hasData = mins.any((m) => m > 0);

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Last ${recent.length} nights',
                  style: AppText.title),
            ),
            Text('hours asleep', style: AppText.captionMuted),
          ]),
          const SizedBox(height: Sp.x5),
          if (!hasData)
            Text('Not enough nights yet', style: AppText.captionMuted)
          else
            MiniBars(
              [for (final m in mins) m / 60.0],
              color: AppColors.coral,
              height: 90,
              gap: 4,
            ),
        ],
      ),
    );
  }
}

// ── shared little widgets (kept private; reused across both screens'
//    structure but defined per-file to avoid new imports) ──────────────────

class _TopTitle extends StatelessWidget {
  final String title;
  final String? freshness;
  const _TopTitle({required this.title, this.freshness});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: Text(title, style: AppText.h1)),
        if (freshness != null)
          Row(children: [
            const AppIcon(Ic.cloud, size: 14, color: AppColors.inkMuted),
            const SizedBox(width: Sp.x1),
            Text(freshness!, style: AppText.captionMuted),
          ]),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _EmptyCard(
      {required this.icon, required this.title, required this.message});
  @override
  Widget build(BuildContext context) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x7),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(icon, size: 26, color: AppColors.coral),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message,
              style: AppText.bodySoft, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});
  @override
  Widget build(BuildContext context) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x7),
      child: Column(
        children: [
          const AppIcon(Ic.cloud, size: 28, color: AppColors.inkMuted),
          const SizedBox(height: Sp.x3),
          Text('Couldn\'t load sleep',
              style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message,
              style: AppText.bodySoft, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  final double height;
  const _Skeleton({required this.height});
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.card),
        ),
      );
}
