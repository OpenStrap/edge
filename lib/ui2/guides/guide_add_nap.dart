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
import 'guide_navigation.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _napsButton = GuideTarget.label(ScreenLabel.sleepDetailEditNaps);
final _logANap = GuideTarget.label(ScreenLabel.napsLogANap);

Guide get addNapGuide => Guide(
      id: 'add-nap',
      title: GuideCopy.addNapTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-naps',
            node: GuideNode.sleep,
            target: _napsButton,
            anchor: GuideTarget.label(ScreenLabel.sleepDetailNavTitle),
            action: GuideAction.tap,
            caption: GuideCopy.addNapCaptionOpenNaps,
          ),
          GuideStep(
            id: 'log-nap',
            node: GuideNode.naps,
            target: _logANap,
            anchor: _logANap,
            action: GuideAction.tap,
            // The picker questions are shown in lower case inside the sentence.
            caption: GuideCopy.addNapCaptionLogNap,
          ),
        ]),
      ],
      footers: [
        // Sleep renders the Naps button below the night, including unscored
        // nights. The help offers scrolling, which works on both paths.
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.addNapFooter0Title,
          body: GuideCopy.addNapFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.addNapFooter1Title,
          body: GuideCopy.addNapFooter1Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.addNapFooter2Title,
          body: GuideCopy.addNapFooter2Body,
        ),
      ],
    );
