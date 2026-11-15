// GUIDE #4: remove a nap or workout that wasn't real.
//
//   Today: the "Detected activities" card (shown only while something waits)
//   ->  Detected activities screen: "Not a nap" / "Not a workout".
//
// A nap or workout already saved lives elsewhere (footer 1): Sleep > Naps ("Not
// a nap" on a nap the band found, "Delete" only on one you logged yourself,
// naps.dart:480) and Activity > History (footer 2). One 'any' variant.
//
// Step 1's card exists only while something is waiting; with nothing pending
// the target is absent and the missing-target help (footer 2) says where to look.

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_content.dart';
import 'guide_target.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';

final _card = GuideTarget.label(ScreenLabel.activityReviewTitle);
final _notANap = GuideTarget.firstAnyLabel([ScreenLabel.napsNotANapLabel, ScreenLabel.activityNotAWorkout]);

Guide get removeDetectedGuide => Guide(
      id: 'remove-detected',
      title: GuideCopy.removeTitle,
      start: GuideStart.today,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-detected',
            node: GuideNode.today,
            target: _card,
            anchor: _card,
            action: GuideAction.tap,
            caption: GuideCopy.removeCaptionOpenDetected,
          ),
          GuideStep(
            id: 'discard',
            node: GuideNode.review,
            target: _notANap,
            anchor: _notANap,
            alsoTap: [EveryLabelled([ScreenLabel.napsNotANapLabel, ScreenLabel.activityNotAWorkout])],
            action: GuideAction.tap,
            caption: GuideCopy.removeCaptionDiscard,
            stillCaption: GuideCopy.removeCaptionDiscardStill,
            multi: const GuideMultiTarget(targets: ReviewRowButtons(), visit: GuideVisit.list, label: GuideCopy.tapOneOfLabel),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: GuideCopy.removeFooter0Title,
          body: GuideCopy.removeFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.removeFooter1Title,
          body: GuideCopy.removeFooter1Body,
        ),
      ],
    );
