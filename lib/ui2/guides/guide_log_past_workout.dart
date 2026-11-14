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
import 'guide_target.dart';

final _historyTab = GuideTarget.label((l) => l.workoutTabHistory);
final _logPast = GuideTarget.label((l) => l.workoutLogPastFix);
final _logIt = GuideTarget.label((l) => l.logWorkoutLogIt);

Guide get logPastWorkoutGuide => Guide(
      id: 'log-past-workout',
      title: (l) => l.guideLogPastTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-history',
            target: _historyTab,
            anchor: _historyTab,
            action: GuideAction.tap,
            caption: (l) => l.guideLogPastStep1(l.tabActivity, l.workoutTabHistory),
          ),
          GuideStep(
            id: 'log-past',
            target: _logPast,
            anchor: GuideTarget.anyLabel([
              (l) => l.workoutTrackedLabel,
              (l) => l.workoutNoSessionsTitle,
            ]),
            action: GuideAction.scrollThenTap,
            caption: (l) => l.guideLogPastStep2(l.workoutLogPastFix),
          ),
          GuideStep(
            id: 'log-it',
            target: _logIt,
            anchor: _logIt,
            alsoKeep: [GuideTarget.label((l) => l.logWorkoutWhenGroup)],
            action: GuideAction.tap,
            caption: (l) => l.guideLogPastStep3(l.logWorkoutWhenGroup, l.logWorkoutLogIt),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: (l) => l.guideLogPastScoreTitle,
          body: (l) => l.guideLogPastScoreBody,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideLogPastMissingTitle(l.workoutLogPastFix),
          body: (l) => l.guideLogPastMissingBody(l.workoutTabHistory),
        ),
      ],
    );
