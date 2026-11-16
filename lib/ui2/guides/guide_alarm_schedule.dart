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
import 'guide_navigation.dart';
import 'guide_content.dart';
import 'guide_target.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';

final _alarmRow = GuideTarget.label(ScreenLabel.settingsAlarmRowTitle);
final _tuesday = GuideTarget.label(ScreenLabel.wellnessTue);
final _wakeTime = GuideTarget.firstLabel(ScreenLabel.alarmWakeTimeRowTitle);

Guide get alarmScheduleGuide => Guide(
      id: 'alarm-schedule',
      title: GuideCopy.alarmTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-alarm',
            node: GuideNode.sleep,
            target: _alarmRow,
            anchor: GuideTarget.firstLabel(ScreenLabel.sleepDetailNavTitle),
            action: GuideAction.scrollThenTap,
            caption: GuideCopy.alarmCaptionOpenAlarm,
          ),
          GuideStep(
            id: 'pick-day',
            node: GuideNode.alarm,
            target: _tuesday,
            alsoTap: [LabelledContent([ScreenLabel.wellnessMon, ScreenLabel.wellnessTue, ScreenLabel.wellnessWed, ScreenLabel.wellnessThu, ScreenLabel.wellnessFri, ScreenLabel.wellnessSat, ScreenLabel.wellnessSun])],
            anchor: GuideTarget.label(ScreenLabel.alarmScheduleGroup),
            action: GuideAction.tap,
            caption: GuideCopy.alarmCaptionPickDay,
          ),
          GuideStep(
            id: 'set-wake-time',
            node: GuideNode.alarm,
            target: _wakeTime,
            anchor: _wakeTime,
            alsoTap: [EveryLabelled([ScreenLabel.alarmWakeTimeRowTitle])],
            action: GuideAction.tap,
            caption: GuideCopy.alarmCaptionSetWakeTime,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: GuideCopy.alarmFooter0Title,
          body: GuideCopy.alarmFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.alarmFooter1Title,
          body: GuideCopy.alarmFooter1Body,
        ),
      ],
    );
