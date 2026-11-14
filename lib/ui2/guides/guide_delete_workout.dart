// GUIDE #6: delete a workout.
//
//   Activity tab  ->  sub-tab "History"  ->  the bin icon at the end of the
//   session's row  ->  a confirm dialog (not framed; the first footer says what
//   confirming does).
//
// There is no delete on a session's summary: the bin is an icon with only a
// semantics label (workout_screen.dart:1113). The row shows it only for a
// session with an id. With several sessions the label is several controls: the
// target is the topmost bin (firstLabel; a plain label was ambiguous). One
// 'any' variant.

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_content.dart';
import 'guide_target.dart';

final _historyTab = GuideTarget.label(((l) => l.workoutTabHistory));
// Several sessions each have a bin with this label; the guide points at the topmost
// (owner, device: a plain label was "ambiguous" on a real history and showed nothing).
final _bin = GuideTarget.firstLabel(((l) => l.workoutDeleteSessionLabel));

Guide get deleteWorkoutGuide => Guide(
      id: 'delete-workout',
      title: (l) => l.guideDeleteTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-history',
            node: GuideNode.activityOverview,
            target: _historyTab,
            anchor: _historyTab,
            action: GuideAction.tap,
            caption: (l) => l.guideDeleteStep1(l.tabActivity, l.workoutTabHistory),
          ),
          GuideStep(
            id: 'delete-session',
            node: GuideNode.activityHistory,
            target: _bin,
            anchor: GuideTarget.label(((l) => l.workoutTrackedLabel)),
            alsoTap: [EveryLabelled([((l) => l.workoutDeleteSessionLabel)])], // every session has a bin
            action: GuideAction.tap,
            caption: (l) => l.guideDeleteStep2(l.workoutDeleteSessionLabel),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideDeleteWhatTitle,
          body: (l) => l.guideDeleteWhatBody,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideDeleteNoneTitle,
          body: (l) => l.guideDeleteNoneBody(l.workoutNoSessionsTitle, l.workoutStartWorkoutFix, l.workoutLogPastFix),
        ),
      ],
    );
