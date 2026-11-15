// GUIDE #8: log a workout you forgot to record.
//
//   Activity tab  ->  sub-tab "History"  ->  at the bottom the card "Did
//   something the band missed?" with "Log a past workout"  ->  the form:
//   activity, date, started, ended, length (the "When" group)  ->  "Log it".
//
// The card is on History only (workout_screen.dart:584), on the empty and the
// filled list alike, not on "For you". One 'any' variant. Step 3 is the form;
// it keeps the "When" group readable.

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _historyTab = GuideTarget.label(ScreenLabel.workoutTabHistory);
final _logPast = GuideTarget.label(ScreenLabel.workoutLogPastFix);
final _logIt = GuideTarget.label(ScreenLabel.logWorkoutLogIt);

Guide get logPastWorkoutGuide => Guide(
      id: 'log-past-workout',
      title: GuideCopy.logPastTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-history',
            node: GuideNode.activityOverview,
            target: _historyTab,
            anchor: _historyTab,
            action: GuideAction.tap,
            caption: GuideCopy.logPastCaptionOpenHistory,
          ),
          GuideStep(
            id: 'log-past',
            node: GuideNode.activityHistory,
            target: _logPast,
            anchor: GuideTarget.anyLabel([
              ScreenLabel.workoutTrackedLabel,
              ScreenLabel.workoutNoSessionsTitle,
            ]),
            action: GuideAction.scrollThenTap,
            caption: GuideCopy.logPastCaptionLogPast,
          ),
          GuideStep(
            id: 'log-it',
            node: GuideNode.logWorkout,
            target: _logIt,
            anchor: _logIt,
            alsoKeep: [GuideTarget.label(ScreenLabel.logWorkoutWhenGroup)],
            action: GuideAction.tap,
            caption: GuideCopy.logPastCaptionLogIt,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.logPastFooter0Title,
          body: GuideCopy.logPastFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.logPastFooter1Title,
          body: GuideCopy.logPastFooter1Body,
        ),
      ],
    );
