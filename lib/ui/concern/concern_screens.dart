// The concern screens — thin wrappers that configure the reusable ConcernScreen
// with each concern's trend metric + detail card. Reached from the navbar and from
// Today's per-concern cards (one canonical screen, reached from everywhere).

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../sleep/sleep_detail_screen.dart';
import '../activity/strain_detail_screen.dart';
import 'concern_screen.dart';
import 'detail_cards.dart';

String todayUtc() => DateTime.now().toUtc().toIso8601String().substring(0, 10);


class SleepConcernScreen extends StatelessWidget {
  const SleepConcernScreen({super.key});
  @override
  Widget build(BuildContext context) => ConcernScreen(
        title: 'Sleep',
        metric: 'sleep',
        icon: Ic.moon,
        accent: AppColors.loadDetraining,
        valueFmt: (v) => v == 0 ? '' : (v / 60).toStringAsFixed(1), // minutes → hours on bars
        // The exact rich Sleep screen you love, embedded under the time toggle,
        // plus sleep records + journal patterns on Today.
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SleepDetailScreen(date: todayUtc(), embedded: true),
          const ConcernExtras(concern: 'sleep'),
        ]),
        dayDetail: (ctx, date) => SleepDetailScreen(date: date, embedded: true),
      );
}

class HeartConcernScreen extends StatelessWidget {
  const HeartConcernScreen({super.key});
  @override
  Widget build(BuildContext context) => ConcernScreen(
        title: 'Heart',
        metric: 'resting_hr', // stable daily series for the bars
        icon: Ic.heart,
        accent: AppColors.coral,
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HeartDayCard(date: todayUtc()),
          const ConcernExtras(concern: 'heart'),
        ]),
        dayDetail: (ctx, date) => HeartDayCard(date: date),
      );
}

/// Body — strain / training load / calories / steps / activity. Bars track daily
/// strain; the detail is the rich Strain screen (embedded), reused over time.
/// (Respiratory rate + SpO₂ moved to Sleep + Heart; Lungs no longer a tab.)
class BodyConcernScreen extends StatelessWidget {
  const BodyConcernScreen({super.key});
  @override
  Widget build(BuildContext context) => ConcernScreen(
        title: 'Body',
        metric: 'strain',
        icon: Ic.strain,
        accent: AppColors.coral,
        todayDetail: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          StrainDetailScreen(date: todayUtc(), embedded: true),
          const ConcernExtras(concern: 'body'),
        ]),
        dayDetail: (ctx, date) => StrainDetailScreen(date: date, embedded: true),
      );
}
