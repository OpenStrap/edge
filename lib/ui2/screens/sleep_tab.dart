// The Sleep tab.
//
// Sleep used to be spread over the Home ring, a Health row that opened a
// generic chart, Wellness's "Recovery" sub-tab (need, debt, bedtime), Health's
// Body clock and the alarm in Settings. This tab is the Sleep screen itself,
// with those pieces under the night. The screens are the same ones; only
// where they live changed.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../profile/alarm.dart';
import '../ui2.dart';
import 'circadian_detail.dart';
import 'metric_detail.dart' show detailLinkRow;
import 'sleep_detail.dart';
import 'wellness_screen.dart';

class SleepTab extends StatelessWidget {
  const SleepTab({super.key});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return SleepDetail(
      embedded: true,
      footer: [
        Section(
          l?.sleepTabPlanTitle ?? 'Your sleep plan',
          const WellnessScreen(sleepPlanOnly: true),
        ),
        Section(
          l?.sleepTabMoreTitle ?? 'Alarm and body clock',
          Column(children: [
            detailLinkRow(
                c,
                LucideIcons.alarmClock,
                l?.settingsAlarmRowTitle ?? 'Alarm',
                l?.settingsAlarmRowSub ??
                    'Buzzes on your wrist, on the band’s own clock',
                () => Navigator.of(c).push(MaterialPageRoute<void>(
                    builder: (_) => const AlarmScreen()))),
            const SizedBox(height: S.x3),
            detailLinkRow(
                c,
                LucideIcons.sunMoon,
                l?.healthBodyClockTitle ?? 'Body clock',
                l?.healthChronotypeJetlagRegularity ??
                    'Natural bedtime, weekend shift and schedule consistency',
                () => Navigator.of(c).push(MaterialPageRoute<void>(
                    builder: (_) => const CircadianDetail()))),
          ]),
        ),
      ],
    );
  }
}
