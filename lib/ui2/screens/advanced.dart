// The research charts, behind one door from Health.
//
// The beat-to-beat scatter, HRV through the night in half-hour blocks,
// deceleration capacity, the sleep-by-hour grid, variability while still and
// the predicted shape of today are real outputs, and the people who want them
// want them. They are not what anyone needs to read on the way to "how did I
// sleep?", so they live here rather than in the main flow.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'beats.dart';
import 'circadian_detail.dart';
import 'home_screen.dart' show go;
import 'metric_detail.dart' show detailScaffold, detailLinkRow;

class AdvancedScreen extends StatelessWidget {
  const AdvancedScreen({super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return detailScaffold(c, l?.advancedTitle ?? 'Advanced charts', [
      Text(
        l?.advancedIntro ??
            'Research views of the same data. Nothing here changes your scores.',
        style: F.cap.copyWith(color: p.ink2, height: 1.5),
      ),
      const SizedBox(height: S.x4),
      detailLinkRow(
        c,
        LucideIcons.heartPulse,
        l?.advancedBeatsTitle ?? 'Beat to beat',
        l?.advancedBeatsSub ??
            'Each beat against the last, HRV through the night, deceleration capacity',
        () => go(c, const Beats()),
      ),
      const SizedBox(height: S.x3),
      detailLinkRow(
        c,
        LucideIcons.calendarClock,
        l?.advancedRhythmTitle ?? 'Sleep timing and daily rhythm',
        l?.advancedRhythmSub ??
            'Sleep hour by hour, variability while still, the predicted shape of today',
        () => go(c, const CircadianDetail(advanced: true)),
      ),
    ]);
  }
}
