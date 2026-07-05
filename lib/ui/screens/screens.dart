// The metric screens — thin wrappers that configure the reusable MetricScreen
// with each domain's accent (DomainAccent), hero visual and detail card.
// Reached from the navbar and from Today's tiles (one canonical screen,
// reached from everywhere).
//
//   Sleep → indigo, the redesigned night board (sleep_detail_screen)
//   Heart → coral, recovery/RHR BigStat hero (detail_cards.HeartDayContent)
//   Body  → amber, week-load RadialHeatmap hero over the strain detail
//   Steps → teal, goal ArcGauge + RingWeek week strip
//   Oxygen→ slate, ODI + signal-coverage gauge (detail_cards)
//   Wear  → coverage gauge + hourly bars (detail_cards)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../state/app_state.dart';
import '../activity/strain_detail_screen.dart';
import '../coach/ai_coach_screen.dart';
import '../cycle/cycle_screen.dart';
import '../design/design.dart';
import '../heart/live_hr_tile.dart';
import '../insights/coach_cards.dart';
import '../sleep/sleep_detail_screen.dart';
import '../spotcheck/spot_check_screen.dart';
import '../today/step_calibration_screen.dart';
import '../today/step_goal_screen.dart';
import 'detail_cards.dart';
import 'metric_row.dart' show infoFor;
import 'metric_screen.dart';

class SleepScreen extends StatelessWidget {
  const SleepScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Sleep',
    metric: 'sleep',
    icon: Ic.moon,
    osIcon: OsIcon.sleep,
    accent: DomainAccent.sleep,
    valueFmt: (v) =>
        v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
    todayDetail: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SleepCoachCard(),
        const SizedBox(height: Sp.x3),
        SleepDetailScreen(date: todayLabel(), embedded: true),
        const SectionExtras(section: 'sleep'),
      ],
    ),
    dayDetail: (ctx, date) => SleepDetailScreen(date: date, embedded: true),
  );
}

class HeartScreen extends StatelessWidget {
  const HeartScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Heart',
    metric: 'resting_hr',
    icon: Ic.heart,
    osIcon: OsIcon.heart,
    accent: DomainAccent.heart,
    todayDetail: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LiveHrTile(),
        const SizedBox(height: Sp.x3),
        const SpotCheckEntryCard(),
        const SizedBox(height: Sp.x3),
        HeartDayCard(date: todayLabel()),
        const SectionExtras(section: 'heart'),
      ],
    ),
    dayDetail: (ctx, date) => HeartDayCard(date: date),
  );
}

class OxygenScreen extends StatelessWidget {
  const OxygenScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Overnight oxygen',
    metric: 'spo2',
    icon: Ic.droplet,
    accent: DomainAccent.oxygen,
    valueFmt: (v) => v == 0 ? '0' : v.toStringAsFixed(1),
    todayDetail: (ctx) => OxygenDayCard(date: todayLabel()),
    dayDetail: (ctx, date) => OxygenDayCard(date: date),
  );
}

/// Wear time — how long the strap was actually on the wrist. Bars track daily
/// worn hours over time; the detail is the per-day wear card (hourly coverage,
/// when it went on/off, longest gap). Reached from the home "Wear time" tile.
class WearScreen extends StatelessWidget {
  const WearScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Wear time',
    metric: 'wear',
    icon: Ic.watch,
    accent: AppColors.coralDeep,
    valueFmt: (v) =>
        v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
    todayDetail: (ctx) => WearDayCard(date: todayLabel()),
    dayDetail: (ctx, date) => WearDayCard(date: date),
  );
}

/// Body — strain / training load / calories / steps / activity. Bars track
/// daily strain (amber); the Today leaf opens with the week-load radial hero,
/// then the rich strain detail. (Respiratory rate + SpO₂ live under Sleep +
/// Heart; Lungs is no longer a tab.)
class BodyScreen extends StatelessWidget {
  const BodyScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Body',
    metric: 'strain',
    icon: Ic.strain,
    osIcon: OsIcon.bodyStrain,
    accent: DomainAccent.strain,
    action: Builder(
      builder: (ctx) => Pressable(
        onTap: () => Navigator.of(
          ctx,
        ).push(MaterialPageRoute(builder: (_) => const AiCoachScreen())),
        borderRadius: BorderRadius.circular(R.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(R.pill),
            boxShadow: AppColors.isDark ? const [] : Shadows.coral,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(Ic.ai, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                'AI Coach',
                style: AppText.label.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    ),
    todayDetail: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StrainCoachCard(),
        const SizedBox(height: Sp.x3),
        const BodyWeekLoadHero(),
        const SizedBox(height: Sp.x3),
        StrainDetailScreen(date: todayLabel(), embedded: true),
        const SizedBox(height: Sp.x3),
        const WhoopAgeCard(),
        const SizedBox(height: Sp.x3),
        const PerformanceAssessmentCard(),
        const CycleEntryCard(),
        const SectionExtras(section: 'body'),
      ],
    ),
    dayDetail: (ctx, date) => StrainDetailScreen(date: date, embedded: true),
  );
}

/// BodyWeekLoadHero — the Body domain's hero visual: the CURRENT week's
/// training load (Mon→Sun) as a RadialHeatmap, one labelled segment per day
/// filled by strain/21; missing/future days stay honest empties. Deliberately
/// number-free — the day's strain figure lives exactly once on the Body
/// screen, in the strain detail hero below. Hides itself until at least one
/// day this week has loaded (no fake wheel).
class BodyWeekLoadHero extends StatefulWidget {
  const BodyWeekLoadHero({super.key});
  @override
  State<BodyWeekLoadHero> createState() => _BodyWeekLoadHeroState();
}

class _BodyWeekLoadHeroState extends State<BodyWeekLoadHero> {
  Map<String, dynamic>? _trend;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      // Anchor the 7-day trend window on this week's Sunday so the wheel is
      // always the current Mon→Sun calendar week. The unanchored default ends
      // at the LAST DATA DAY, i.e. a rolling window whose segments drift
      // around the wheel — which is what rendered as a lone mislabelled day.
      final now = DateTime.now();
      final sunday = DateTime(
        now.year,
        now.month,
        now.day + (DateTime.daysPerWeek - now.weekday),
      );
      final t = await api.getTrend(
        'strain',
        scale: 'week',
        anchor: dayLabelOf(sunday),
      );
      if (mounted) setState(() => _trend = t);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final wheel = weekLoadWheelData(_trend);
    if (wheel.values.whereType<double>().isEmpty) {
      return const SizedBox.shrink();
    }
    return WeekLoadWheelTile(
      values: wheel.values,
      labels: wheel.labels,
    ).dsEnter();
  }
}

/// Pure mapper for the week-load wheel: a /trend week payload → one segment
/// per bucket (strain/21, null = no data) plus its weekday label derived from
/// the bucket's own `t_start` (so labels can never drift from the data).
@visibleForTesting
({List<double?> values, List<String> labels}) weekLoadWheelData(
  Map<String, dynamic>? trend,
) {
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final buckets = ((trend?['buckets'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  final values = <double?>[];
  final labels = <String>[];
  for (final b in buckets) {
    values.add(
      b['has'] == true
          ? (((b['value'] as num?)?.toDouble() ?? 0) / 21).clamp(0.0, 1.0)
          : null,
    );
    final ts = (b['t_start'] as num?)?.toInt();
    labels.add(
      ts == null
          ? ''
          : wd[(DateTime.fromMillisecondsSinceEpoch(
                      ts * 1000,
                      isUtc: true,
                    ).weekday -
                    1) %
                7],
    );
  }
  return (values: values, labels: labels);
}

/// Pure presentation of the week-load wheel: the RadialHeatmap alone with all
/// day segments labelled — no strain BigStat here, so the Body screen keeps
/// exactly one strain figure (the strain detail hero).
@visibleForTesting
class WeekLoadWheelTile extends StatelessWidget {
  final List<double?> values;
  final List<String> labels;
  const WeekLoadWheelTile({
    super.key,
    required this.values,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) => BentoTile(
    accent: DomainAccent.strain,
    padding: const EdgeInsets.all(Sp.x5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TileHeader(
          'Week load',
          icon: Ic.strain,
          osIcon: OsIcon.bodyStrain,
          trailing: InfoDot(
            title: 'Week load',
            body:
                'Each spoke is one day of this week, Monday through Sunday, '
                'filled by its strain (0–21). A balanced wheel means steady '
                'training; one hot spoke is a spike day; empty spokes have '
                'no data yet.',
            methodNote: infoFor('strain'),
          ),
        ),
        const SizedBox(height: Sp.x3),
        Center(
          child: RadialHeatmap(
            values: values,
            rings: 3,
            color: DomainAccent.strain,
            size: 176,
            labels: labels,
          ),
        ),
      ],
    ),
  );
}

/// Steps — daily step ESTIMATE. The band's always-on 1 Hz stream can't COUNT
/// steps (Nyquist), so the 24/7 number is ambulatory-minutes × your cadence;
/// the live 100 Hz workout stream counts real steps AND tunes that cadence.
/// Bars track the daily step estimate; the detail keeps the goal ring, the
/// week of rings, and the honest how-it-works behind (i).
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Steps',
    metric: 'steps',
    icon: Ic.run,
    osIcon: OsIcon.steps,
    accent: DomainAccent.steps,
    valueFmt: (v) => v == 0 ? '' : v.toStringAsFixed(0),
    todayDetail: (ctx) => const _ActivityDetail(),
    dayDetail: (ctx, date) => _ActivityDetail(date: date),
  );
}

/// Fetches the day's steps + the surrounding week, then renders the pure
/// [StepsDayContent] (live steps fold into TODAY only).
class _ActivityDetail extends StatefulWidget {
  final String? date; // null → today
  const _ActivityDetail({this.date});
  @override
  State<_ActivityDetail> createState() => _ActivityDetailState();
}

class _ActivityDetailState extends State<_ActivityDetail> {
  double? _steps;
  List<double?> _week = const [];
  List<String> _weekLabels = const [];

  bool get _isToday => widget.date == null;
  String get _day => widget.date ?? todayLabel();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await LocalDb.metricValueOn(_day, 'steps');
    if (!mounted) return;
    setState(() => _steps = s);
    // Week-of-rings strip (best-effort).
    try {
      final t = await context
          .read<AppState>()
          .repo
          ?.getTrend('steps', scale: 'week', anchor: widget.date);
      final buckets = ((t?['buckets'] as List?) ?? const [])
          .whereType<Map>()
          .toList();
      const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
      if (!mounted) return;
      setState(() {
        _week = [
          for (final b in buckets)
            b['has'] == true ? ((b['value'] as num?)?.toDouble()) : null,
        ];
        _weekLabels = [
          for (final b in buckets)
            () {
              final ts = (b['t_start'] as num?)?.toInt();
              if (ts == null) return '';
              final d = DateTime.fromMillisecondsSinceEpoch(
                ts * 1000,
                isUtc: true,
              );
              return wd[(d.weekday - 1) % 7];
            }(),
        ];
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Live steps from the in-flight session count toward TODAY only.
    final live = _isToday
        ? context.select<AppState, int>((a) => a.liveSteps)
        : 0;
    final app = context.watch<AppState>();
    final goal = (app.user?['step_goal'] as num?)?.toInt();
    return StepsDayContent(
      steps: (_steps?.round() ?? 0) + live,
      goal: goal,
      weekValues: _week,
      weekLabels: _weekLabels,
      onSetGoal: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StepGoalScreen(goal: goal)),
      ),
      onCalibrate: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const StepCalibrationScreen()),
      ),
    );
  }
}

/// StepsDayContent — the pure steps board (teal domain): a BigStat + goal
/// ArcGauge hero, the week of rings, and the goal / calibration rows. The
/// "how steps are counted" honesty lives behind the (i).
class StepsDayContent extends StatelessWidget {
  final int steps;
  final int? goal;
  final List<double?> weekValues; // raw step counts (nulls = no data)
  final List<String> weekLabels;
  final VoidCallback? onSetGoal;
  final VoidCallback? onCalibrate;

  const StepsDayContent({
    super.key,
    required this.steps,
    this.goal,
    this.weekValues = const [],
    this.weekLabels = const [],
    this.onSetGoal,
    this.onCalibrate,
  });

  @override
  Widget build(BuildContext context) {
    final accent = DomainAccent.steps;
    final g = goal ?? 10000;
    var ringValues = <double?>[
      for (final v in weekValues)
        v == null ? null : (v / g).clamp(0.0, 1.0).toDouble(),
    ];
    var ringLabels = weekLabels.length == ringValues.length
        ? weekLabels
        : null;
    if (ringValues.length > 7) {
      ringLabels = ringLabels?.sublist(ringLabels.length - 7);
      ringValues = ringValues.sublist(ringValues.length - 7);
    }
    final hasWeek = ringValues.whereType<double>().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── hero: steps beside the goal gauge ────────────────────────────────
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TileHeader(
                'Steps',
                icon: Ic.run,
                osIcon: OsIcon.steps,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tag('est', color: accent),
                    InfoDot(
                      title: 'How steps are counted',
                      body:
                          'While the band streams live (a workout or with the '
                          'app open) we count REAL steps from its 100 Hz motion '
                          'sensor. The rest of the day the sensor samples too '
                          'slowly to count each step, so those hours are '
                          'ESTIMATED from your walking minutes and cadence.',
                      methodNote:
                          'Walk with the app open to sharpen the estimate.',
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
                      value: steps > 0 ? '$steps' : null,
                      caption: steps > 0 ? 'goal $g' : 'no steps yet',
                      size: BigStatSize.xl,
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  ArcGauge(
                    value: steps > 0 ? (steps / g).clamp(0.0, 1.0) : double.nan,
                    color: accent,
                    size: 96,
                    stroke: 10,
                    valueText: steps > 0
                        ? '${((steps / g) * 100).clamp(0, 999).round()}%'
                        : '—',
                    label: 'of goal',
                  ),
                ],
              ),
            ],
          ),
        ).dsEnter(),

        // ── the week of rings ────────────────────────────────────────────────
        if (hasWeek) ...[
          const SizedBox(height: Sp.x3),
          BentoTile(
            accent: accent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const TileHeader('This week', icon: Ic.calendar),
                const SizedBox(height: Sp.x3),
                RingWeek(
                  values: ringValues,
                  todayIndex: ringValues.length - 1,
                  color: accent,
                  labels: ringLabels,
                ),
              ],
            ),
          ).dsEnter(index: 1),
        ],

        // ── goal + calibration ───────────────────────────────────────────────
        const SizedBox(height: Sp.x3),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x2,
          ),
          child: Column(
            children: [
              ListRow(
                icon: Ic.strain,
                iconColor: accent,
                title: 'Daily step goal',
                value: goal == null ? 'Set' : '$goal',
                divider: true,
                onTap: onSetGoal,
              ),
              ListRow(
                icon: Ic.run,
                iconColor: accent,
                title: 'Calibrate steps',
                subtitle: 'Walk ~250 steps with the app open',
                onTap: onCalibrate,
              ),
            ],
          ),
        ).dsEnter(index: 2),
      ],
    );
  }
}

/// Tappable entry to the live HRV spot-check.
class SpotCheckEntryCard extends StatelessWidget {
  const SpotCheckEntryCard({super.key});
  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: ListRow(
        icon: Ic.pulse,
        osIcon: OsIcon.hrv,
        iconColor: DomainAccent.recovery,
        title: 'Live HRV spot check',
        subtitle: 'A quick 60-second reading, any time',
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SpotCheckScreen())),
      ),
    );
  }
}

/// Tappable entry to the Cycle screen — shown only when the user has explicitly
/// opted in (Profile → Track menstrual cycle). Consent-gated, never inferred.
class CycleEntryCard extends StatelessWidget {
  const CycleEntryCard({super.key});
  @override
  Widget build(BuildContext context) {
    final track = context.select<AppState, bool>((s) {
      final v = s.user?['track_cycle'];
      return v == true || v == 1;
    });
    if (!track) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x3),
      child: SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        child: ListRow(
          icon: Ic.calendar,
          iconColor: DomainAccent.heart,
          title: 'Cycle tracking',
          subtitle: 'Phase, next period & fertile window',
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const CycleScreen())),
        ),
      ),
    );
  }
}
