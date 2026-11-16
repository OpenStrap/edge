// GUIDE #5: fix your sleep times.
//
// All on the Sleep tab, in the night's window card (sleep_detail.dart:977):
//   "Change the times" (once the times are yours; "Set the times myself" on an
//   automatic night) opens two time pickers, bed then wake; "Back to automatic"
//   appears only after the user set times.
// Step 1 accepts either label of the first button. The pickers are dialogs: the
// caption describes them. Step 2 requires a tap on step 1 in this run, because
// an existing manual night can already show its undo control.
// One 'any' variant.

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

/// The button's text flips with the source, so both labels.
final _timesButton = GuideTarget.anyLabel([
  ScreenLabel.sleepDetailChangeTimes,
  ScreenLabel.sleepDetailSetTimesMyself,
]);
final _backToAutomatic = GuideTarget.label(ScreenLabel.sleepDetailBackToAutomatic);

Guide get fixSleepTimesGuide => Guide(
      id: 'fix-sleep-times',
      title: GuideCopy.fixTimesTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'change-times',
            node: GuideNode.sleep,
            target: _timesButton,
            anchor: _timesButton,
            action: GuideAction.tap,
            caption: GuideCopy.fixTimesCaptionChangeTimes,
          ),
          GuideStep(
            id: 'back-to-automatic',
            node: GuideNode.sleep,
            target: _backToAutomatic,
            anchor: _backToAutomatic,
            requiresPreviousTap: true,
            action: GuideAction.tap,
            caption: GuideCopy.fixTimesCaptionBackToAutomatic,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.fixTimesFooter0Title,
          body: GuideCopy.fixTimesFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.fixTimesFooter1Title,
          body: GuideCopy.fixTimesFooter1Body,
        ),
      ],
    );
