// CONFORMANCE BATTERY: every shipped guide's steps resolve on their REAL screens
// in every shipped language.
//
// Live guides run on the user's own screens, so the battery mounts the real
// screen class (HomeScreen, DayStrainDetail, SleepTab, WorkoutScreen, ...) under
// the real app providers with the harness's fake repository
// (test/support/live_guide_harness.dart). There are no demo builders and no
// `data:` seams: what the user would see is what is resolved.
//
// The oracle for each step is a table written by hand from reading the screens
// (the AppLocalizations getter whose text the control prints), never the
// guide's own code. Claims, per step and locale:
//  * CLAIM(guide-resolves): the step's ANCHOR and TARGET resolve (found, not
//    ambiguous, not absent) inside the ONE real screen of the expected class,
//    and the target is the very control that prints the oracle label.
//  * CLAIM(anchor-built): the anchor is found on the fresh screen without scrolling
//    (the live run matches steps by anchor after each frame and never scrolls to look).
//  * CLAIM(guide-quotes): the caption quotes that label verbatim.
//  * CLAIM(guide-covered): the table covers exactly the catalogue's steps (a new
//    guide or step without a scene fails here).
//  * CLAIM(guide-copy): every guide string exists in every locale, differs from
//    English where English is not a brand, and has balanced bold markup.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart' show quickStart;
import 'package:openstrap_edge/ui2/activity/day_strain.dart' show DayStrainDetail;
import 'package:openstrap_edge/ui2/activity/live.dart' show liveFor;
import 'package:openstrap_edge/ui2/activity/picker.dart' show ActivityPicker;
import 'package:openstrap_edge/ui2/activity/setup.dart' show ActivitySetup;
import 'package:openstrap_edge/ui2/activity/zones.dart' show ZonesDetail;
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart' show AlarmScreenView;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart' show DetectedActivitiesScreen;
import 'package:openstrap_edge/ui2/screens/log_workout.dart' show LogWorkout;
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart' show SleepTab;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/live_guide_harness.dart';

/// One step on its real screen.
class _Scene {
  final String guideId, stepId;

  /// The ONE real screen class the anchor and the target must be found inside.
  final Type screen;
  final Widget Function() home;

  /// What the control prints (or, for an icon, its semantics label), by hand.
  final String Function(AppLocalizations l) label;
  final bool printed;

  /// The state the user is in when the step shows (a sub-tab already tapped).
  final Future<void> Function(WidgetTester t, AppLocalizations l)? prepare;

  /// 'manual' = the user has set the sleep times themselves.
  final String sleepSource;

  const _Scene(this.guideId, this.stepId, this.screen, this.home, this.label,
      {this.printed = true, this.prepare, this.sleepSource = 'auto'});
}

Widget _tab(Widget w) => Scaffold(body: w);

Future<void> _tapHistory(WidgetTester t, AppLocalizations l) async {
  await t.tap(find.text(l.workoutTabHistory));
  await settleLiveGuide(t);
}

final _tuesdayOn = fillDefaultAlarmSchedule([const AlarmScheduleEntry(weekday: 1, hour: 7, minute: 30)]);

final List<_Scene> _scenes = [
  _Scene('heart-rate-zones', 'open-strain', HomeScreen, () => _tab(const HomeScreen()), (l) => l.homeRingStrain),
  _Scene('heart-rate-zones', 'open-zones', DayStrainDetail, () => const DayStrainDetail(), (l) => l.dayStrainHowSet),
  _Scene('heart-rate-zones', 'set-own-zones', ZonesDetail, () => const ZonesDetail(), (l) => l.activityZonesSetYourOwnLink),
  _Scene('alarm-schedule', 'open-alarm', SleepTab, () => _tab(const SleepTab()), (l) => l.settingsAlarmRowTitle),
  _Scene('alarm-schedule', 'pick-day', AlarmScreenView, () => AlarmScreenView(connected: true, schedule: fillDefaultAlarmSchedule(const [])), (l) => l.wellnessTue),
  _Scene('alarm-schedule', 'set-wake-time', AlarmScreenView, () => AlarmScreenView(connected: true, schedule: _tuesdayOn), (l) => l.alarmWakeTimeRowTitle),
  _Scene('add-nap', 'open-naps', SleepTab, () => _tab(const SleepTab()), (l) => l.sleepDetailEditNaps),
  _Scene('add-nap', 'log-nap', NapsScreen, () => const NapsScreen(), (l) => l.napsLogANap),
  _Scene('remove-detected', 'open-detected', HomeScreen, () => _tab(const HomeScreen()), (l) => l.activityReviewTitle),
  _Scene('remove-detected', 'discard', DetectedActivitiesScreen, () => const DetectedActivitiesScreen(), (l) => l.napsNotANapLabel),
  _Scene('fix-sleep-times', 'change-times', SleepTab, () => _tab(const SleepTab()), (l) => l.sleepDetailSetTimesMyself),
  _Scene('fix-sleep-times', 'back-to-automatic', SleepTab, () => _tab(const SleepTab()), (l) => l.sleepDetailBackToAutomatic, sleepSource: 'manual'),
  _Scene('delete-workout', 'open-history', WorkoutScreen, () => _tab(const WorkoutScreen()), (l) => l.workoutTabHistory),
  _Scene('delete-workout', 'delete-session', WorkoutScreen, () => _tab(const WorkoutScreen()), (l) => l.workoutDeleteSessionLabel, printed: false, prepare: _tapHistory),
  _Scene('start-workout', 'start-card', WorkoutScreen, () => _tab(const WorkoutScreen()), (l) => l.workoutStartSessionLabel),
  _Scene('start-workout', 'choose-activity', ActivityPicker, () => const ActivityPicker(weightKg: 70), (l) => l.activityPickerSearchLabel, printed: false),
  _Scene('start-workout', 'start', ActivitySetup, () => ActivitySetup(quickStart.first, weightKg: 70), (l) => l.activitySetupStart),
  _Scene('start-workout', 'finish', Scaffold, () => liveFor(quickStart.first, weightKg: 70), (l) => l.activityLiveFinishSessionLabel, printed: false),
  _Scene('log-past-workout', 'open-history', WorkoutScreen, () => _tab(const WorkoutScreen()), (l) => l.workoutTabHistory),
  _Scene('log-past-workout', 'log-past', WorkoutScreen, () => _tab(const WorkoutScreen()), (l) => l.workoutLogPastFix, prepare: _tapHistory),
  _Scene('log-past-workout', 'log-it', LogWorkout, () => const LogWorkout(), (l) => l.logWorkoutLogIt),
];

GuideStep _stepOf(_Scene s) {
  final guide = kGuideCatalogue.firstWhere((e) => e.guide.id == s.guideId).guide;
  final variant = (guide.variantFor(null) as GuideVariantFound).variant;
  return variant.steps.firstWhere((x) => x.id == s.stepId);
}

Finder _printed(String label) => find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').trim().toLowerCase() == label.trim().toLowerCase());

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'guide_conformance_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async => LocalDb.close());

  test('CLAIM(guide-covered): the table covers exactly the catalogue\'s steps, once each', () {
    // why: a new guide or step without a scene would ship unproven.
    final shipped = {
      for (final e in kGuideCatalogue)
        for (final v in e.guide.variants)
          for (final s in v.steps) '${e.guide.id}/${s.id}',
    };
    final covered = [for (final s in _scenes) '${s.guideId}/${s.stepId}'];
    expect(covered.toSet(), hasLength(covered.length), reason: 'no scene twice');
    expect(covered.toSet(), shipped);
    expect(shipped, hasLength(21), reason: 'guide #1 has 3 steps, #2 3, #3 2, #4 2, #5 2, #6 2, #7 4, #8 3');
  });

  for (final locale in AppLocalizations.supportedLocales) {
    group(locale.languageCode, () {
      for (final scene in _scenes) {
        testWidgets('${scene.guideId} / ${scene.stepId}: anchor and target resolve on the real ${scene.screen}', (t) async {
          final l = lookupAppLocalizations(locale);
          await pumpLiveGuideApp(t,
              home: scene.home(),
              locale: locale,
              textScale: 1.3,
              repo: GuideFakeRepo(sleepSource: scene.sleepSource));
          await settleLiveGuide(t, frames: 30);
          await scene.prepare?.call(t, l);
          await settleLiveGuide(t, frames: 30);
          final step = _stepOf(scene);

          final screens = find.byType(scene.screen).evaluate().toList();
          expect(screens, hasLength(1), reason: 'exactly one ${scene.screen} on screen');
          final root = screens.single;

          // Looked at BEFORE any scrolling: this is what the run sees after a frame.
          final anchor = step.anchor.resolve(root, l);
          final target = await revealTarget(root, step.target, l);
          expect(target, isA<TargetFound>(), reason: 'target: $target (anchor before scrolling: $anchor)');
          // CLAIM(anchor-built): the run matches steps by anchor after each frame
          // WITHOUT scrolling, so an anchor deep in a lazy list (not built yet) would
          // read as "you've left the path". The anchor must be on screen at once.
          expect(anchor, isA<TargetFound>(), reason: 'CLAIM(anchor-built): anchor $anchor is not found without scrolling');
          final rect = (target as TargetFound).rect;

          if (scene.printed) {
            // The target is the control that prints the oracle label, not another one.
            final printedAt = _printed(scene.label(l));
            expect(printedAt, findsWidgets, reason: '"${scene.label(l)}" is printed on the screen');
            final textRect = t.getRect(printedAt.first);
            expect(rect.inflate(2).overlaps(textRect), isTrue, reason: 'target $rect is not at the label $textRect');
          }
          expect(step.caption(l).toLowerCase(), contains(scene.label(l).toLowerCase()), reason: 'CLAIM(guide-quotes)');
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        });
      }
    });
  }

  group('CLAIM(guide-copy): strings', () {
    for (final locale in AppLocalizations.supportedLocales) {
      test('${locale.languageCode}: titles, intros, captions and footers exist, are balanced and (outside English) translated', () {
        final l = lookupAppLocalizations(locale);
        final en = lookupAppLocalizations(const Locale('en'));
        for (final e in kGuideCatalogue) {
          final g = e.guide;
          final texts = <(String, String, String)>[
            ('title', g.title(l), g.title(en)),
            if (g.intro != null) ('intro', g.intro!(l), g.intro!(en)),
            for (final v in g.variants)
              for (final s in v.steps) ('caption ${s.id}', s.caption(l), s.caption(en)),
            for (final (i, f) in g.footers.indexed) ...[
              ('footer $i title', f.title(l), f.title(en)),
              ('footer $i body', f.body(l), f.body(en)),
            ],
          ];
          for (final (what, own, english) in texts) {
            expect(own.trim(), isNotEmpty, reason: '${g.id} $what');
            expect('**'.allMatches(own).length.isEven, isTrue, reason: '${g.id} $what has unbalanced ** in: $own');
            if (locale.languageCode != 'en') expect(own, isNot(english), reason: '${g.id} $what is still English in ${locale.languageCode}');
          }
        }
      });
    }
  });
}
