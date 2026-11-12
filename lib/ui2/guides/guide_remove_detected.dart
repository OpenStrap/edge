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
import 'guide_target.dart';

final _card = GuideTarget.label((l) => l.activityReviewTitle);
final _notANap = GuideTarget.label((l) => l.napsNotANapLabel);

Guide get removeDetectedGuide => Guide(
      id: 'remove-detected',
      title: (l) => l.guideRemoveTitle,
      start: GuideStart.today,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-detected',
            target: _card,
            anchor: _card,
            action: GuideAction.tap,
            caption: (l) => l.guideRemoveStep1(l.tabToday, l.activityReviewTitle),
          ),
          GuideStep(
            id: 'discard',
            target: _notANap,
            anchor: _notANap,
            action: GuideAction.tap,
            caption: (l) => l.guideRemoveStep2(l.napsNotANapLabel, l.activityNotAWorkout),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: (l) => l.guideRemoveSavedTitle,
          body: (l) => l.guideRemoveSavedBody(l.tabSleep, l.sleepDetailEditNaps, l.napsNotANapLabel, l.napsDeleteLabel),
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideRemoveMissingTitle(l.activityReviewTitle),
          body: (l) => l.guideRemoveMissingBody(l.tabSleep, l.sleepDetailEditNaps, l.tabActivity, l.workoutTabHistory),
        ),
      ],
    );
