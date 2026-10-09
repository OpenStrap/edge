import '../../l10n/display_text.dart';
// OBSERVATIONS — the log of every health watch that has ever fired.
//
// Named for the card it is a history of: the Observation widget has printed
// "HEALTH OBSERVATION" over the illness card since the design system existed,
// and these six detectors are what that card is. Deliberately NOT "what
// changed", which is the nightly sweep's screen and a different question — the
// sweep measures every metric against your own trailing history, while these
// are standing watches with their own thresholds.
//
// Four detectors fire on every rollup and exactly one of them, illness, ever
// reached a screen. The other three — the overnight anomaly, the skin
// temperature flag, and the change-point search that says "your resting
// heart-rate trend shifted" — existed only as a push notification. One buzz,
// and dismissing it lost it for good.
//
// A LOG YOU GO TO, NOT A FEED THAT COMES TO YOU. notification_center.dart
// records that the in-app notifications feed was removed deliberately, because
// it duplicated the OS notification with no independent value, and Home bans
// observation cards. Both of those hold here: nothing on this screen is
// unread-marked, nothing badges a tab, nothing is dismissible, and the only
// way to it is a section on Health that you chose to open. It is a place to
// look something up, not a second place to be interrupted from.
//
// It is also DETECTION, NEVER DIAGNOSIS, all the way down. Every sentence is
// the detector's own, written once in findings.dart, and the medical-class
// entries carry the same "this is a screen, see a clinician" wording they
// carry in the notification.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../compute/findings.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'home_screen.dart' show prettyDay;
import 'metric_detail.dart' show detailScaffold;

/// The accent a finding is drawn in. Two, not six: the detections the design
/// sanctions interrupting for, and everything else. A palette per detector
/// would read as a severity scale nobody calibrated.
Color _ink(P p, Finding f) => p.on(f.medical ? C.orange : C.blue);

IconData _icon(Finding f) => switch (f.kind) {
      FindingKind.illness => LucideIcons.stethoscope,
      FindingKind.anomaly => LucideIcons.waves,
      FindingKind.tempElevated => LucideIcons.thermometer,
      FindingKind.irregularRhythm => LucideIcons.heartPulse,
      FindingKind.lowReadiness => LucideIcons.batteryLow,
      FindingKind.rhrShift => LucideIcons.trendingUp,
    };

class FindingsLog extends StatelessWidget {
  const FindingsLog(this.findings, {super.key});

  final List<Finding> findings;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    // Already newest-first out of findingsHistory; grouped here only so a day
    // with three findings reads as one morning rather than three events.
    final byDay = <String, List<Finding>>{};
    for (final f in findings) {
      (byDay[f.date] ??= []).add(f);
    }

    return detailScaffold(
      c,
      l?.findingsLogTitle ?? 'Observations',
      [
        if (findings.isEmpty)
          StatusCard(
            l?.findingsLogEmptyTitle ?? 'Nothing has stood out',
            l?.findingsLogEmptyBody ??
                'The watches for illness, unusual overnight physiology, skin '
                    'temperature and a shift in your resting heart rate have '
                    'all been quiet. That is an outcome, not an empty screen.',
            icon: LucideIcons.check,
          )
        else ...[
          for (final day in byDay.keys) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(S.x1, S.x5, S.x1, S.x2),
              child: Text(prettyDay(day),
                  style: F.cap.copyWith(
                      color: p.ink3, fontWeight: FontWeight.w600)),
            ),
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < byDay[day]!.length; i++) ...[
                    if (i > 0) ...[
                      const SizedBox(height: S.x3),
                      Divider(color: p.line, height: 1),
                      const SizedBox(height: S.x3),
                    ],
                    FindingRow(byDay[day]![i]),
                  ],
                ],
              ),
            ),
          ],
        const SizedBox(height: S.x5),
        // THE ONE THING A LOG OWES ITS READER: what it is a log OF. These
        // entries are worked out from the data on every open rather than
        // written down when they fired, so a day whose data was later
        // re-derived changes here with it — including out of existence.
          Text(
            l?.findingsLogDerivedNote ??
                'Worked out from your own days each time this opens, not '
                    'written down when it happened — so if a day is '
                    're-analysed, what it says here changes with it.',
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
      ],
    ]);
  }
}

/// One finding, as an icon, its title and the detector's own sentence. Public
/// because Health shows the newest one in place — the alternative was a second
/// hand-built row that would drift from this one.
class FindingRow extends StatelessWidget {
  const FindingRow(this.f, {super.key});

  final Finding f;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = _ink(p, f);
    return Semantics(
      label: '${uiText(c, f.title)}. ${uiText(c, f.detail)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: S.x1),
                child: Icon(_icon(f), size: 16, color: ink),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  uiText(c, f.title),
                    style: F.body.copyWith(
                        color: p.ink, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(
            uiText(c, f.detail),
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
        ],
      ),
    );
  }
}
