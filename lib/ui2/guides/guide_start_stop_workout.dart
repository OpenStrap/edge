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
import 'guide_target.dart';

final _startCard = GuideTarget.label((l) => l.workoutStartSessionLabel);
final _search = GuideTarget.label((l) => l.activityPickerSearchLabel);
final _start = GuideTarget.label((l) => l.activitySetupStart);
final _finish = GuideTarget.label((l) => l.activityLiveFinishSessionLabel);

/// A fictional 70 kg user, so the picker and setup show calorie hints.
Guide get startStopWorkoutGuide => Guide(
      id: 'start-workout',
      title: (l) => l.guideStartTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'start-card',
            target: _startCard,
            anchor: _startCard,
            action: GuideAction.tap,
            caption: (l) => l.guideStartStep1(l.tabActivity, l.workoutStartSessionLabel),
          ),
          GuideStep(
            id: 'choose-activity',
            target: _search,
            anchor: _search,
            action: GuideAction.tap,
            caption: (l) => l.guideStartStep2(l.activityPickerSearchLabel),
          ),
          GuideStep(
            id: 'start',
            target: _start,
            anchor: _start,
            action: GuideAction.tap,
            caption: (l) => l.guideStartStep3(l.activitySetupStart),
          ),
          GuideStep(
            id: 'finish',
            target: _finish,
            anchor: _finish,
            action: GuideAction.tap,
            caption: (l) => l.guideStartStep4(l.activityLiveFinishSessionLabel),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideStartNoBandTitle,
          body: (l) => l.guideStartNoBandBody,
        ),
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideStartPauseTitle,
          body: (l) => l.guideStartPauseBody(l.activityLivePauseLabel, l.activityLiveResumeLabel),
        ),
      ],
    );
