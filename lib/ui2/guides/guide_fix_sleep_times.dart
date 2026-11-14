// GUIDE #5: fix your sleep times.
//
// All on the Sleep tab, in the night's window card (sleep_detail.dart:977):
//   "Change the times" (once the times are yours; "Set the times myself" on an
//   automatic night) opens two time pickers, bed then wake; "Back to automatic"
//   appears only after the user set times.
// Step 1 accepts either label of the first button. The pickers are dialogs: the
// caption describes them. Step 2's anchor appears once the times are the user's own.
// One 'any' variant.

import 'guide.dart';
import 'guide_target.dart';

/// The button's text flips with the source, so both labels.
final _timesButton = GuideTarget.anyLabel([
  (l) => l.sleepDetailChangeTimes,
  (l) => l.sleepDetailSetTimesMyself,
]);
final _backToAutomatic = GuideTarget.label((l) => l.sleepDetailBackToAutomatic);

Guide get fixSleepTimesGuide => Guide(
      id: 'fix-sleep-times',
      title: (l) => l.guideFixTimesTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'change-times',
            target: _timesButton,
            anchor: _timesButton,
            action: GuideAction.tap,
            caption: (l) => l.guideFixTimesStep1(l.tabSleep, l.sleepDetailChangeTimes, l.sleepDetailSetTimesMyself),
          ),
          GuideStep(
            id: 'back-to-automatic',
            target: _backToAutomatic,
            anchor: _backToAutomatic,
            action: GuideAction.tap,
            caption: (l) => l.guideFixTimesStep2(l.sleepDetailBackToAutomatic),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideFixTimesBackTitle(l.sleepDetailBackToAutomatic),
          body: (l) => l.guideFixTimesBackBody(l.sleepDetailBackToAutomatic),
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideFixTimesAskTitle,
          body: (l) => l.guideFixTimesAskBody,
        ),
      ],
    );
