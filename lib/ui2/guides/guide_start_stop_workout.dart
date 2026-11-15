// GUIDE #7: start and stop a workout.
//
//   Activity tab ("For you")  ->  the "START A SESSION" card  ->  "Choose
//   activity": search or tap one  ->  the setup screen's "Start"  ->  the live
//   screen's red square ("Finish session", an icon with only a semantics label)
//   ->  the summary.
//
// Not gated on band, permission or generation (starting works with no band; the
// setup only changes its heart-rate line): ONE 'any' variant. The user's own
// taps start and stop the real session; the guide itself writes nothing. The
// live screen runs a periodic timer, so checks pump frames and never settle.

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_content.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _startCard = GuideTarget.label(ScreenLabel.workoutStartSessionLabel);
final _search = GuideTarget.label(ScreenLabel.activityPickerSearchLabel);
final _start = GuideTarget.label(ScreenLabel.activitySetupStart);
final _finish = GuideTarget.label(ScreenLabel.activityLiveFinishSessionLabel);

/// A fictional 70 kg user, so the picker and setup show calorie hints.
Guide get startStopWorkoutGuide => Guide(
      id: 'start-workout',
      title: GuideCopy.startWorkoutTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'start-card',
            node: GuideNode.activityOverview,
            target: _startCard,
            anchor: _startCard,
            action: GuideAction.tap,
            caption: GuideCopy.startWorkoutCaptionStartCard,
          ),
          GuideStep(
            id: 'choose-activity',
            node: GuideNode.picker,
            target: _search,
            anchor: _search,
            alsoTap: [PressableRows()], // "or tap one in the list"
            // Multi-target step: the search bar, the chips and each group header; the hand opens the
            // first group once, then visits the search bar and the group's first rows.
            multi: GuideMultiTarget(
              targets: ContentList([TargetContent(_search), PickerChips(), PickerGroupHeaders()]),
              label: GuideCopy.searchOrPickLabel,
              visit: GuideVisit.list,
              opens: FirstOf(PickerGroupHeaders()),
              afterOpen: ContentList([TargetContent(_search), PickerRows(3)]),
              alreadyOpen: PickerOpenGroup(),
              labelAfterOpen: PickerRows(3),
            ),
            action: GuideAction.tap,
            caption: GuideCopy.startWorkoutCaptionChooseActivity,
          ),
          GuideStep(
            id: 'start',
            node: GuideNode.setup,
            target: _start,
            anchor: _start,
            alsoRead: [ // "Check the details"
              LabelledContent([
                ScreenLabel.activitySetupRouteLabel,
                ScreenLabel.activitySetupHeartRateLabel,
                ScreenLabel.activitySetupPrivateLabel,
              ]),
            ],
            action: GuideAction.tap,
            caption: GuideCopy.startWorkoutCaptionStart,
          ),
          GuideStep(
            id: 'finish',
            node: GuideNode.live,
            target: _finish,
            anchor: _finish,
            action: GuideAction.tap,
            caption: GuideCopy.startWorkoutCaptionFinish,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.startWorkoutFooter0Title,
          body: GuideCopy.startWorkoutFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.startWorkoutFooter1Title,
          body: GuideCopy.startWorkoutFooter1Body,
        ),
      ],
    );
