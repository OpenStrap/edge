// The metric screens — thin wrappers that configure the reusable MetricScreen
// with each metric's trend series + detail card. Reached from the navbar and from
// Today's per-metric cards (one canonical screen, reached from everywhere).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
        valueFmt: (v) => v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
        // The exact rich Sleep screen you love, embedded under the time toggle,
        // plus sleep records + journal patterns on Today.
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SleepDetailScreen(date: todayUtc(), embedded: true),
          const SectionExtras(section: 'sleep'),
        ]),
        dayDetail: (ctx, date) => SleepDetailScreen(date: date, embedded: true),
      );
}

class HeartScreen extends StatelessWidget {
  const HeartScreen({super.key});
  @override
  Widget build(BuildContext context) => MetricScreen(
        title: 'Heart',
        metric: 'resting_hr', // stable daily series for the bars
        icon: Ic.heart,
        accent: AppColors.coral,
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const LiveHrTile(),
          const SizedBox(height: Sp.x4),
          const SpotCheckEntryCard(),
          const SizedBox(height: Sp.x4),
          HeartDayCard(date: todayUtc()),
          const SectionExtras(section: 'heart'),
        ]),
        dayDetail: (ctx, date) => HeartDayCard(date: date),
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
        valueFmt: (v) => v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
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
        action: Builder(builder: (ctx) => GestureDetector(
              onTap: () => Navigator.of(ctx).push(
                  MaterialPageRoute(builder: (_) => const AiCoachScreen())),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 8),
                decoration: BoxDecoration(
                    color: AppColors.coral, borderRadius: BorderRadius.circular(R.pill)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const AppIcon(Ic.ai, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text('AI Coach', style: AppText.label.copyWith(color: Colors.white)),
                ]),
              ),
            )),
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          StrainDetailScreen(date: todayUtc(), embedded: true),
          const CycleEntryCard(),
          const SectionExtras(section: 'body'),
        ]),
        dayDetail: (ctx, date) => StrainDetailScreen(date: date, embedded: true),
      );
}

/// Tappable entry to the live HRV spot-check.
class SpotCheckEntryCard extends StatelessWidget {
  const SpotCheckEntryCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ProCard(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SpotCheckScreen())),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
              color: AppColors.good.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(R.chip)),
          child: AppIcon(Ic.pulse, size: 18, color: AppColors.good),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Live HRV spot check', style: AppText.label),
          const SizedBox(height: 2),
          Text('A quick 60-second reading, any time', style: AppText.captionMuted),
        ])),
        AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
      ]),
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
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CycleScreen())),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: AppColors.coral.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(R.chip)),
            child: AppIcon(Ic.calendar, size: 18, color: AppColors.coral),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Cycle tracking', style: AppText.label),
            const SizedBox(height: 2),
            Text('Phase, next period & fertile window', style: AppText.captionMuted),
          ])),
          AppIcon(Ic.arrowRight, size: 18, color: AppColors.inkMuted),
        ]),
      ),
    );
  }
}
