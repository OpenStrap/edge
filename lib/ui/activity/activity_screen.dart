// Activity tab — today's strain, HR zones, training load, and detected workouts.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/metric.dart';
import '../../models/payloads.dart';
import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/charts.dart';
import '../kit/kit.dart';
import '../widgets/screen_loader.dart';
import 'live_session_screen.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});
  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen>
    with ScreenLoaderMixin<ActivityScreen> {
  // HR zone palette: light → vivid coral, deep red top end.
  static const zoneColors = <Color>[
    AppColors.loadDetraining,
    AppColors.good,
    AppColors.warn,
    AppColors.coral,
    AppColors.coralDeep,
  ];
  static const zoneLabels = ['Z1', 'Z2', 'Z3', 'Z4', 'Z5'];

  List<Session> _sessions = const [];

  @override
  String get cacheKey => 'activity';

  @override
  Future<Object?> fetch(ApiClient api) async {
    final strain = await api.getStrain();
    try {
      final sess = await api.getSessions();
      if (mounted) {
        setState(() => _sessions = sess.map((e) => Session(e)).toList());
      }
    } catch (_) {}
    return strain;
  }

  @override
  bool isEmpty(Object? d) => _rows(d).isEmpty && _sessions.isEmpty;

  List<Map<String, dynamic>> _rows(Object? d) {
    if (d is List) {
      return d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  ({String label, Color color}) _band(double v) {
    if (v < 0.8) return (label: 'Detraining', color: AppColors.loadDetraining);
    if (v <= 1.3) return (label: 'Optimal', color: AppColors.loadOptimal);
    if (v <= 1.5) return (label: 'Caution', color: AppColors.loadCaution);
    return (label: 'High', color: AppColors.loadHigh);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final today = StrainData.fromRows(_rows(data));

    return SafeArea(
      bottom: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: RefreshIndicator(
          onRefresh: () => refresh(),
          color: AppColors.coral,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
            children: [
              const SizedBox(height: Sp.x4),
              _TopTitle(
                title: 'Activity',
                freshness: freshnessLabel,
                trailing: app.isConnected
                    ? _StartButton(onPressed: () {
                        app.startWorkout(targetKcal: 300);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const LiveSessionScreen()),
                        );
                      })
                    : null,
              ),
              const SizedBox(height: Sp.x4),
              if (phase == LoadPhase.loading)
                ..._skeleton()
              else if (phase == LoadPhase.error && data == null)
                _ErrorCard(message: errorText ?? 'Pull to retry.')
              else if (phase == LoadPhase.empty)
                const _EmptyCard(
                  icon: Ic.run,
                  title: 'No activity yet',
                  message:
                      'Move while wearing your strap. Workouts are auto-detected '
                      'from heart-rate elevation and motion after your next sync.',
                )
              else
                ..._content(today),
              const SizedBox(height: 110),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _skeleton() => const [
        _Skeleton(height: 280),
        SizedBox(height: Sp.x4),
        _Skeleton(height: 130),
        SizedBox(height: Sp.x4),
        _Skeleton(height: 120),
      ];

  List<Widget> _content(StrainData t) {
    final strain = t.dailyStrain;
    final fill = strain.isEmpty
        ? double.nan
        : (strain.value! / 21.0).clamp(0.0, 1.0).toDouble();

    return [
      _heroRing(t, strain, fill),
      const SizedBox(height: Sp.x4),
      Row(children: [
        Expanded(
          child: StatTile(
            icon: Ic.run,
            label: 'Steps',
            value: t.steps.isEmpty ? null : t.steps.value!.round().toString(),
            accent: AppColors.good,
            confidence: t.steps.isEmpty ? null : t.steps.confidence,
            tag: Tag.forMetric(t.steps),
          ),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: StatTile(
            icon: Ic.fire,
            label: 'Active calories',
            value: t.calories.isEmpty ? null : t.calories.value!.round().toString(),
            unit: 'kcal',
            accent: AppColors.warn,
            confidence: t.calories.isEmpty ? null : t.calories.confidence,
            tag: Tag.forMetric(t.calories),
          ),
        ),
      ]),
      const SizedBox(height: Sp.x4),
      if (t.zoneMinutes.any((z) => z > 0)) ...[
        _zonesCard(t.zoneMinutes),
        const SizedBox(height: Sp.x4),
      ],
      _loadCard(t.acwr),
      const SizedBox(height: Sp.x6),
      const SectionHeader('Workouts'),
      if (_sessions.isEmpty)
        ProCard(
          child: Row(
            children: [
              const AppIcon(Ic.run, size: 22, color: AppColors.inkMuted),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Text('No workouts auto-detected today.',
                    style: AppText.bodySoft),
              ),
            ],
          ),
        )
      else
        for (final s in _sessions)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x3),
            child: _SessionCard(
              session: s,
              zoneColors: zoneColors,
            ),
          ),
    ];
  }

  // HERO — day-strain ring + active calories.
  Widget _heroRing(StrainData t, Metric strain, double fill) {
    final cals = t.calories;
    return ProCard(
      padding: const EdgeInsets.symmetric(vertical: Sp.x7, horizontal: Sp.x5),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AppIcon(Ic.strain, size: 18, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Text('DAY STRAIN', style: AppText.overline),
              if (!strain.isEmpty) ...[
                const SizedBox(width: Sp.x2),
                ConfDot(strain.confidence),
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
                if (strain.isEmpty)
                  metricDash(40)
                else
                  Text(strain.value!.toStringAsFixed(1),
                      style: AppText.display),
                const SizedBox(height: Sp.x2),
                Text('of 21',
                    style:
                        AppText.caption.copyWith(color: AppColors.inkMuted)),
              ],
            ),
          ),
          const SizedBox(height: Sp.x5),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const AppIcon(Ic.fire, size: 18, color: AppColors.coralDeep),
              const SizedBox(width: Sp.x2),
              if (cals.isEmpty)
                metricDash(22)
              else
                Text('${cals.value!.round()}', style: AppText.metricSm),
              const SizedBox(width: Sp.x1),
              Text('active cal',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted)),
              const SizedBox(width: Sp.x2),
              const Tag('est', color: AppColors.warn),
            ],
          ),
        ],
      ),
    );
  }

  // HR zones z1..z5.
  Widget _zonesCard(List<int> zones) {
    final total = zones.fold<int>(0, (s, v) => s + v);
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text('Heart-rate zones', style: AppText.h2)),
            Text('$total min', style: AppText.captionMuted),
          ]),
          const SizedBox(height: Sp.x4),
          SegmentBar(
            [for (final z in zones) z.toDouble()],
            zoneColors,
            height: 14,
          ),
          const SizedBox(height: Sp.x4),
          Wrap(
            spacing: Sp.x5,
            runSpacing: Sp.x3,
            children: [
              for (int i = 0; i < zones.length; i++)
                if (zones[i] > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                            color: zoneColors[i], shape: BoxShape.circle),
                      ),
                      const SizedBox(width: Sp.x2),
                      Text(zoneLabels[i], style: AppText.caption),
                      const SizedBox(width: Sp.x1),
                      Text('${zones[i]}m',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                  ),
            ],
          ),
        ],
      ),
    );
  }

  // Training load / ACWR with band label.
  Widget _loadCard(Metric acwr) {
    final has = !acwr.isEmpty;
    final v = (acwr.value ?? 0).toDouble();
    final band = _band(v);
    final fill = (v / 2.0).clamp(0.0, 1.0).toDouble();

    return ProCard(
      child: Row(
        children: [
          RingStat(
            t: has ? fill : double.nan,
            color: has ? band.color : AppColors.confLow,
            size: 92,
            stroke: 10,
            center: Text(has ? v.toStringAsFixed(2) : '—',
                style: AppText.metricSm),
          ),
          const SizedBox(width: Sp.x5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('Training load', style: AppText.title),
                  const SizedBox(width: Sp.x2),
                  if (has) ConfDot(acwr.confidence),
                  if (Tag.forMetric(acwr) != null) ...[
                    const SizedBox(width: Sp.x2),
                    Tag.forMetric(acwr)!,
                  ],
                ]),
                const SizedBox(height: Sp.x2),
                Text(
                  has ? band.label : 'No data yet',
                  style: AppText.metricSm.copyWith(
                    color: has ? band.color : AppColors.inkMuted,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  'Acute:chronic workload ratio. 0.8–1.3 is the sweet spot.',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single auto-detected workout card.
class _SessionCard extends StatelessWidget {
  final Session session;
  final List<Color> zoneColors;
  const _SessionCard({required this.session, required this.zoneColors});

  String _start(int? epoch) {
    if (epoch == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal();
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  String _dur(int? mins) {
    if (mins == null) return '—';
    if (mins < 60) return '${mins}m';
    return '${mins ~/ 60}h ${mins % 60}m';
  }

  @override
  Widget build(BuildContext context) {
    final s = session;
    final zones = s.zoneMinutes;
    final hasZones = zones.any((z) => z > 0);
    final start = _start(s.startEpoch);

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: const AppIcon(Ic.run, size: 18, color: AppColors.coral),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.type, style: AppText.title),
                    Text(
                      [
                        if (start.isNotEmpty) start,
                        _dur(s.durationMin),
                      ].join('  ·  '),
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
              if (!s.strain.isEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(s.strain.value!.toStringAsFixed(1),
                        style: AppText.metricSm),
                    Text('strain', style: AppText.captionMuted),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              _stat('Avg HR', s.avgHr, 'bpm'),
              _stat('Max HR', s.maxHr, 'bpm'),
              _stat('HRR60', s.hrr60, 'bpm'),
              _stat('Active cal', s.calories, '',
                  tag: const Tag('est', color: AppColors.warn)),
            ],
          ),
          if (hasZones) ...[
            const SizedBox(height: Sp.x4),
            SegmentBar(
              [for (final z in zones) z.toDouble()],
              zoneColors,
              height: 10,
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, Metric m, String unit, {Widget? tag}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(
              child: Text(label,
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: Sp.x1),
          if (m.isEmpty)
            metricDash(18)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(m.value!.round().toString(),
                      style: AppText.metricSm.copyWith(fontSize: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 2),
                  Text(unit,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkMuted, fontSize: 10)),
                ],
              ],
            ),
          if (tag != null) ...[
            const SizedBox(height: 2),
            tag,
          ],
        ],
      ),
    );
  }
}

// ── shared little widgets ──────────────────────────────────────────────────

class _TopTitle extends StatelessWidget {
  final String title;
  final String? freshness;
  final Widget? trailing;
  const _TopTitle({required this.title, this.freshness, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.h1),
              if (freshness != null) ...[
                const SizedBox(height: 2),
                Row(children: [
                  const AppIcon(Ic.cloud, size: 14, color: AppColors.inkMuted),
                  const SizedBox(width: Sp.x1),
                  Text(freshness!, style: AppText.captionMuted),
                ]),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _StartButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _StartButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.coralSoft,
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(R.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(Ic.run, size: 16, color: AppColors.coralDeep),
                const SizedBox(width: Sp.x2),
                Text('START',
                    style: AppText.label.copyWith(
                        color: AppColors.coralDeep,
                        fontWeight: FontWeight.w900,
                        fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
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
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
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
          Text('Couldn\'t load activity',
              style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
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
