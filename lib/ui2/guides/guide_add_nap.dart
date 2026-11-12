// GUIDE #3: add a nap yourself.
//
//   Sleep tab  ->  "Naps" (under the night)  ->  Naps screen "Log a nap"  ->
//   two time pickers (bed, then wake).
//
// The pickers are dialogs the overlay steps aside for (the guide yields while a
// dialog is on top): caption 2 names the two questions they ask, in the app's
// own words. One 'any' variant: sleep_detail.dart and naps.dart never branch on
// generation.

import 'guide.dart';
import 'guide_target.dart';

final _napsButton = GuideTarget.label((l) => l.sleepDetailEditNaps);
final _logANap = GuideTarget.label((l) => l.napsLogANap);

Guide get addNapGuide => Guide(
      id: 'add-nap',
      title: (l) => l.guideAddNapTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-naps',
            target: _napsButton,
            anchor: _napsButton,
            action: GuideAction.tap,
            caption: (l) => l.guideAddNapStep1(l.tabSleep, l.sleepDetailEditNaps),
          ),
          GuideStep(
            id: 'log-nap',
            target: _logANap,
            anchor: _logANap,
            action: GuideAction.tap,
            // The picker questions are shown in lower case inside the sentence.
            caption: (l) => l.guideAddNapStep2(l.napsLogANap, l.napsFellAsleepHelp.toLowerCase(), l.napsWokeUpHelp.toLowerCase()),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideAddNapFoundTitle,
          body: (l) => l.guideAddNapFoundBody(l.napsNotANapLabel),
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideAddNapRulesTitle,
          body: (l) => l.guideAddNapRulesBody,
        ),
      ],
    );
