// The metric screens — thin wrappers that configure the reusable MetricScreen
// with each metric's trend series + detail card. Reached from the navbar and from
// Today's per-metric cards (one canonical screen, reached from everywhere).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../sleep/sleep_detail_screen.dart';
import '../activity/strain_detail_screen.dart';
import '../heart/live_hr_tile.dart';
import '../cycle/cycle_screen.dart';
import '../spotcheck/spot_check_screen.dart';
import '../coach/ai_coach_screen.dart';
import '../today/step_goal_screen.dart';
import '../today/step_calibration_screen.dart';
import '../insights/coach_cards.dart';
import 'metric_screen.dart';
import 'detail_cards.dart';

String todayUtc() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

class SleepScreen extends StatelessWidget {
  const SleepScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Sleep',
    metric: 'sleep',
    icon: Ic.moon,
    accent: AppColors.loadDetraining,
    valueFmt: (v) =>
        v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
    todayDetail: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SleepCoachCard(),
        const SizedBox(height: Sp.x4),
        SleepDetailScreen(date: todayUtc(), embedded: true),
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
    accent: AppColors.coral,
    todayDetail: (ctx) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LiveHrTile(),
        const SizedBox(height: Sp.x4),
        const SpotCheckEntryCard(),
        const SizedBox(height: Sp.x4),
        HeartDayCard(date: todayUtc()),
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
    accent: AppColors.coralDeep,
    valueFmt: (v) => v == 0 ? '0' : v.toStringAsFixed(1),
    todayDetail: (ctx) => OxygenDayCard(date: todayUtc()),
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
    todayDetail: (ctx) => WearDayCard(date: todayUtc()),
    dayDetail: (ctx, date) => WearDayCard(date: date),
  );
}

/// Body — strain / training load / calories / steps / activity. Bars track daily
/// strain; the detail is the rich Strain screen (embedded), reused over time.
/// (Respiratory rate + SpO₂ moved to Sleep + Heart; Lungs no longer a tab.)
class BodyScreen extends StatelessWidget {
  const BodyScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Body',
    metric: 'strain',
    icon: Ic.strain,
    accent: AppColors.coral,
    action: Builder(
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(
          ctx,
        ).push(MaterialPageRoute(builder: (_) => const AiCoachScreen())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.coral,
            borderRadius: BorderRadius.circular(R.pill),
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
        const SizedBox(height: Sp.x4),
        StrainDetailScreen(date: todayUtc(), embedded: true),
        const SizedBox(height: Sp.x4),
        const WhoopAgeCard(),
        const SizedBox(height: Sp.x4),
        const PerformanceAssessmentCard(),
        const CycleEntryCard(),
        const SectionExtras(section: 'body'),
      ],
    ),
    dayDetail: (ctx, date) => StrainDetailScreen(date: date, embedded: true),
  );
}

/// Steps — daily step ESTIMATE. The band's always-on 1 Hz stream can't COUNT
/// steps (Nyquist), so the 24/7 number is ambulatory-minutes × your cadence; the
/// live 100 Hz workout stream counts real steps AND tunes that cadence. Bars
/// track the daily step estimate; the detail explains it honestly and keeps the
/// daily step-goal setter. Reached from the home "Steps" tile.
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
    title: 'Steps',
    metric: 'steps',
    icon: Ic.run,
    accent: AppColors.good,
    valueFmt: (v) => v == 0 ? '' : v.toStringAsFixed(0),
    todayDetail: (ctx) => const _ActivityDetail(),
    dayDetail: (ctx, date) => _ActivityDetail(date: date),
  );
}

/// Detail under the Steps trend: explains the estimate honestly (24/7 estimate,
/// real counts during live workouts that personalize your cadence) + a tappable
/// row to set the daily step goal.
class _ActivityDetail extends StatefulWidget {
  final String? date; // null → today
  const _ActivityDetail({this.date});
  @override
  State<_ActivityDetail> createState() => _ActivityDetailState();
}

class _ActivityDetailState extends State<_ActivityDetail> {
  double? _steps;

  bool get _isToday => widget.date == null;
  String get _day {
    if (widget.date != null) return widget.date!;
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await LocalDb.metricValueOn(_day, 'steps');
    if (!mounted) return;
    setState(() => _steps = s);
  }

  @override
  Widget build(BuildContext context) {
    // Live steps from the in-flight session count toward TODAY only.
    final live = _isToday
        ? context.select<AppState, int>((a) => a.liveSteps)
        : 0;
    final steps = (_steps?.round() ?? 0) + live;
    final app = context.watch<AppState>();
    final goal = (app.user?['step_goal'] as num?)?.toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ActivityStat(
          icon: Ic.run,
          label: 'Steps',
          value: steps > 0 ? '$steps' : '—',
          badge: 'est.',
        ),
        const SizedBox(height: Sp.x4),
        ProCard(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.good.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(Ic.run, size: 18, color: AppColors.good),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('How steps are counted', style: AppText.label),
                    const SizedBox(height: 2),
                    Text(
                      'While the band streams live (a workout or with the app open) we '
                      'count REAL steps from its 100 Hz motion sensor. The rest of the '
                      'day the sensor samples too slowly to count each step, so those '
                      'hours are ESTIMATED from your walking minutes and cadence. Walk '
                      'with the app open to sharpen the estimate.',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x4),
        Builder(
          builder: (ctx) {
            return ProCard(
              onTap: () => Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => StepGoalScreen(goal: goal)),
              ),
              child: Row(
                children: [
                  AppIcon(Ic.strain, size: 18, color: AppColors.inkMuted),
                  const SizedBox(width: Sp.x3),
                  Expanded(
                    child: Text('Daily step goal', style: AppText.label),
                  ),
                  Text(
                    goal == null ? 'Set' : '$goal',
                    style: AppText.label.copyWith(color: AppColors.inkMuted),
                  ),
                  const SizedBox(width: Sp.x2),
                  AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: Sp.x3),
        // Calibration walk — anchors the off-workout estimate to the user's stride.
        ProCard(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const StepCalibrationScreen()),
          ),
          child: Row(
            children: [
              AppIcon(Ic.run, size: 18, color: AppColors.good),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Calibrate steps', style: AppText.label),
                    const SizedBox(height: 1),
                    Text(
                      'Walk ~250 steps with the app open to sharpen the estimate',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact stat card for the activity detail (one big number + label).
class _ActivityStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? badge;
  const _ActivityStat({
    required this.icon,
    required this.label,
    required this.value,
    this.badge,
  });
  @override
  Widget build(BuildContext context) => ProCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppIcon(icon, size: 16, color: AppColors.good),
            const SizedBox(width: Sp.x2),
            Text(label, style: AppText.overline),
            if (badge != null) ...[
              const Spacer(),
              Tag(badge!, color: AppColors.coral),
            ],
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text(value, style: AppText.metricSm.copyWith(fontSize: 28)),
      ],
    ),
  );
}

/// Tappable entry to the live HRV spot-check.
class SpotCheckEntryCard extends StatelessWidget {
  const SpotCheckEntryCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ProCard(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SpotCheckScreen())),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppColors.good.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(Ic.pulse, size: 18, color: AppColors.good),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Live HRV spot check', style: AppText.label),
                const SizedBox(height: 2),
                Text(
                  'A quick 60-second reading, any time',
                  style: AppText.captionMuted,
                ),
              ],
            ),
          ),
          AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
        ],
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
      padding: const EdgeInsets.only(top: Sp.x6),
      child: ProCard(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const CycleScreen())),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.coral.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(R.chip),
              ),
              child: AppIcon(Ic.calendar, size: 18, color: AppColors.coral),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cycle tracking', style: AppText.label),
                  const SizedBox(height: 2),
                  Text(
                    'Phase, next period & fertile window',
                    style: AppText.captionMuted,
                  ),
                ],
              ),
            ),
            AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
          ],
        ),
      ),
    );
  }
}
