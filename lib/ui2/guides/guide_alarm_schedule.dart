// GUIDE #2: set an alarm, or a different time each day.
//
//   Sleep tab, scroll to "Alarm and body clock"  ->  "Alarm"  ->  Alarm screen
//   "Weekly schedule": tap a day to turn it on  ->  its "Wake time".
//
// Also: Profile -> Settings -> "The band" -> "Alarm" (footer 1). The schedule
// only draws while the band is connected (footer 2 says so).
//
// One path serves both band generations: alarm.dart and sleep_tab.dart never
// branch on generation (checked by reading them), so ONE 'any' variant.
//
// Step 3's anchor ("Wake time") exists once a day is on; until then the run
// stays on step 2.

import 'guide.dart';
import 'guide_target.dart';

final _alarmRow = GuideTarget.label((l) => l.settingsAlarmRowTitle);
final _sectionHeading = GuideTarget.label((l) => l.sleepTabMoreTitle);
final _tuesday = GuideTarget.label((l) => l.wellnessTue);
final _wakeTime = GuideTarget.label((l) => l.alarmWakeTimeRowTitle);

Guide get alarmScheduleGuide => Guide(
      id: 'alarm-schedule',
      title: (l) => l.guideAlarmTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-alarm',
            target: _alarmRow,
            anchor: _sectionHeading,
            action: GuideAction.scrollThenTap,
            caption: (l) => l.guideAlarmStep1(l.tabSleep, l.sleepTabMoreTitle, l.settingsAlarmRowTitle),
          ),
          GuideStep(
            id: 'pick-day',
            target: _tuesday,
            anchor: GuideTarget.label((l) => l.alarmScheduleGroup),
            action: GuideAction.tap,
            caption: (l) => l.guideAlarmStep2(l.alarmScheduleGroup, l.wellnessTue),
          ),
          GuideStep(
            id: 'set-wake-time',
            target: _wakeTime,
            anchor: _wakeTime,
            action: GuideAction.tap,
            caption: (l) => l.guideAlarmStep3(l.alarmWakeTimeRowTitle),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: (l) => l.guideAnotherWayInTitle,
          body: (l) => l.guideAlarmAltBody(l.profileTitle, l.profileSettingsRow, l.settingsGroupTheBand, l.settingsAlarmRowTitle),
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideAlarmMissingTitle(l.alarmScheduleGroup),
          body: (l) => l.guideAlarmMissingBody(l.alarmScheduleGroup),
        ),
      ],
    );
