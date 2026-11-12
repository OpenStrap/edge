// LIVE GUIDES ON THE REAL APP: the real AppMainShell (AppShell + the four real
// tab screens), the real Help list, a real GuideRunner and the real overlay,
// fed by a fake repository (test/support/live_guide_harness.dart). Nothing of
// the guide machinery is stubbed.
//
// The first test is the harness's own check and passes today; the rest are RED
// until the green phase implements GuideRun, GuideRunner, LiveGuideOverlay and
// the shell's registration (AppMainShell -> GuideRunner.attachShell).
//
// Covered guides: #1 heart-rate zones (all three steps, every locale for
// step 1), #7 start a workout (step 1 -> 2) and #8 log a past workout (steps
// 1 -> 3). Cross-cutting claims: skeletonizes the REAL screen, the real target
// tap advances the run, wrong navigation shows the off-path card, Exit leaves
// the app where the user is.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show AppMainShell;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart' show DayStrainDetail;
import 'package:openstrap_edge/ui2/activity/zones.dart' show ZonesDetail;
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/live_guide_harness.dart';

// skipOffstage: false - while Help is open the shell is offstage under it.
AppLocalizations _l(WidgetTester t) => AppLocalizations.of(t.element(find.byType(AppMainShell, skipOffstage: false)))!;

/// A text finder ignoring letter case: Home and the tab bar print some labels in capitals.
Finder _label(String s) => find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').trim().toLowerCase() == s.trim().toLowerCase());

String _plain(String markup) => markup.replaceAll('**', '');

/// The caption the card shows, without the bold markup.
String _caption(WidgetTester t) =>
    t.widget<RichText>(find.descendant(of: find.byKey(GuideStepCard.captionKey), matching: find.byType(RichText)).first).text.toPlainText();

LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));

GuideRun _run(LiveGuideApp app) => app.runner.activeRun!;

int _step(LiveGuideApp app) => (_run(app).state as GuideAtStep).index;

Guide _guide(String id) => kGuideCatalogue.firstWhere((e) => e.guide.id == id).guide;

/// Opens the real Help list on top of the shell and taps [guideId]'s row, as a
/// user would, then lets the run bring the app to the start and reveal step 1.
Future<void> _startFromHelp(WidgetTester t, LiveGuideApp app, String guideId) async {
  app.navigator.push(MaterialPageRoute<void>(builder: (_) => const HelpScreen()));
  await settleLiveGuide(t);
  await t.tap(find.byKey(HelpScreen.guideRowKey(guideId)));
  await settleLiveGuide(t, frames: 12);
}

Future<void> _reveal(WidgetTester t) => settleLiveGuide(t, frames: 12);

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'live_guide_integration_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async => LocalDb.close());

  testWidgets('HARNESS: the real shell mounts on Today with the Strain ring and the Help list opens over it', (t) async {
    // why: the other tests assume the fake repository makes the real screens show
    // their guide targets; this one pins it, so a harness gap fails HERE, named.
    final app = await pumpLiveGuideApp(t);
    final l = _l(t);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(_label(l.homeRingStrain), findsOneWidget);
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => const HelpScreen()));
    await settleLiveGuide(t);
    expect(find.byType(HelpScreen), findsOneWidget);
    expect(find.byKey(HelpScreen.guideRowKey('heart-rate-zones')), findsOneWidget);
  });

  testWidgets('alarm starts on the real Sleep content and stays matched after revealing its lazy target', (t) async {
    // why: a Sleep title must not be ambiguous with the shell's Sleep button,
    // and revealing Alarm can dispose that title in the lazy list.
    final app = await pumpLiveGuideApp(t);
    app.runner.start(_guide('alarm-schedule'), band: null);
    await _reveal(t);
    await _reveal(t);
    expect(_step(app), 0);
    expect(_run(app).currentStep!.id, 'open-alarm');
    expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
    final target = _overlay(t).targetRect!;
    expect(target.overlaps(t.getRect(_label(_l(t).settingsAlarmRowTitle))), isTrue);
    expect(target.top, greaterThanOrEqualTo(0));
    expect(target.bottom, lessThanOrEqualTo(844));
    expect(t.takeException(), isNull);
  });

  group('wiring', () {
    testWidgets('the shell registers itself with the runner: start does not answer "no shell"', (t) async {
      // why: GuideRunner needs the shell\'s tab selection; AppMainShell must attach
      // its link on mount (CLAIM run-no-new-stack needs a shell to select on).
      final app = await pumpLiveGuideApp(t);
      expect(app.runner.start(_guide('heart-rate-zones'), band: null), isA<GuideStarted>());
    });

    testWidgets('the shell unregisters on dispose: a later start answers "no shell"', (t) async {
      // why: a stale link would select tabs on a disposed shell.
      final app = await pumpLiveGuideApp(t);
      await t.pumpWidget(const SizedBox());
      expect(app.runner.start(_guide('heart-rate-zones'), band: null), isA<GuideStartNoShell>());
    });
  });

  group('guide #1 heart-rate zones, on the real screens', () {
    testWidgets('start from Help: Help is gone, Today is on screen, step 1 skeletonizes the REAL Today and keeps the Strain ring', (t) async {
      // why: the headline integration claim: Help -> live overlay on the user\'s
      // own Today tab, everything but the Strain ring collapsed.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);

      expect(find.byType(HelpScreen), findsNothing, reason: 'popped to the shell root');
      expect(find.byType(LiveGuideOverlay), findsOneWidget);
      expect(app.navigator.canPop(), isFalse);
      expect(_step(app), 0);
      expect(_caption(t), _plain(l.guideHrZonesStep1(l.tabToday, l.homeRingStrain)));

      final shapes = _overlay(t).paintedShapes;
      final ring = t.getRect(_label(l.homeRingStrain));
      expect(shapes, isNotEmpty);
      expect(shapes.any((s) => s.rect.overlaps(ring.deflate(1))), isFalse, reason: 'the Strain ring stays legible');
      final recovery = t.getRect(_label(l.homeRingRecovery));
      expect(shapes.any((s) => s.rect.overlaps(recovery.deflate(1))), isTrue, reason: 'the other rings are skeleton');
    });

    testWidgets('tapping the real Strain ring opens the real Day strain screen and the run advances to step 2', (t) async {
      // why: spec "the tap passes through to the real control ... the run advances".
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.homeRingStrain));
      await _reveal(t);
      expect(find.byType(DayStrainDetail), findsOneWidget);
      expect(_step(app), 1);
      expect(_caption(t), _plain(l.guideHrZonesStep2(l.dayStrainTimeInZonesSection, l.dayStrainHowSet)));
      expect(find.byKey(GuideStepCard.dotKey(1)), findsOneWidget);
    });

    testWidgets('all three steps on the real screens, then the Done card with "Another way in"', (t) async {
      // why: the whole path, end to end, with real taps on real controls.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.homeRingStrain));
      await _reveal(t);
      await t.tap(_label(l.dayStrainHowSet));
      await _reveal(t);
      expect(find.byType(ZonesDetail), findsOneWidget);
      expect(_step(app), 2);
      expect(_caption(t), _plain(l.guideHrZonesStep3(l.activityZonesTitle, l.activityZonesSetYourOwnLink)));

      await t.tap(_label(l.activityZonesSetYourOwnLink));
      await _reveal(t);
      // The real control opens the app\'s own editor; the overlay steps aside for
      // it, and the Done card shows once it is closed.
      await t.binding.handlePopRoute();
      await _reveal(t);
      expect(_run(app).state, isA<GuideFinished>());
      expect(find.byKey(GuideStepCard.doneKey), findsOneWidget);
      expect(find.text(l.guideHrZonesAltTitle), findsOneWidget);
    });

    testWidgets('wrong navigation (another tab) shows "You\'ve left the path"; "Back to the guide" returns to Today and step 1', (t) async {
      // why: spec off-path card. Switching tabs is the commonest way to leave;
      // the tab bar is chrome, so the tap passes through.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.tabHealth).last);
      await _reveal(t);
      expect(find.byType(HealthScreen), findsOneWidget);
      expect(_run(app).state, isA<GuideOffPath>());
      expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
      expect(find.text(l.guideOffPathTitle), findsOneWidget);

      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      await _reveal(t);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(_step(app), 0);
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
    });

    testWidgets('Exit removes the overlay and leaves the app exactly where the user is (on Day strain)', (t) async {
      // why: CLAIM(run-exit-in-place) on the real shell.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.homeRingStrain));
      await _reveal(t);
      await t.tap(find.byKey(GuideStepCard.exitKey));
      await _reveal(t);
      expect(find.byType(LiveGuideOverlay), findsNothing);
      expect(app.runner.activeRun, isNull);
      expect(find.byType(DayStrainDetail), findsOneWidget, reason: 'still on the screen the user was on');
      // Every control works again (no leftover absorbing layer): Back returns to Today.
      await t.binding.handlePopRoute();
      await _reveal(t);
      expect(find.byType(DayStrainDetail), findsNothing);
      expect(_label(l.homeRingStrain), findsOneWidget);
    });

    testWidgets('system Back from step 2 returns to Today and the guide returns to step 1', (t) async {
      // why: spec "system Back works as normal".
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.homeRingStrain));
      await _reveal(t);
      expect(_step(app), 1);
      await t.binding.handlePopRoute();
      await _reveal(t);
      expect(find.byType(DayStrainDetail), findsNothing);
      expect(_step(app), 0);
    });

    testWidgets('taps on other real controls of the page are absorbed (the Recovery ring does not open)', (t) async {
      // why: spec "taps elsewhere are absorbed" on the real Today, whose rings are
      // real buttons.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'heart-rate-zones');
      final l = _l(t);
      await t.tap(_label(l.homeRingRecovery), warnIfMissed: false);
      await _reveal(t);
      expect(find.byType(ReadinessDetail), findsNothing);
      expect(_step(app), 0);
    });

    for (final locale in const [Locale('en'), Locale('de'), Locale('ru'), Locale('zh'), Locale('th'), Locale('hi'), Locale('fr'), Locale('es')]) {
      testWidgets('step 1 in ${locale.languageCode}: caption quotes the screen\'s own label; card and target do not collide', (t) async {
        // why: the owner\'s language requirement on the live path (text scale 1.3,
        // phone width). The caption is the translated sentence, the card keeps
        // clear of the outline and the pill.
        final app = await pumpLiveGuideApp(t, locale: locale, textScale: 1.3);
        await _startFromHelp(t, app, 'heart-rate-zones');
        final l = lookupAppLocalizations(locale);
        expect(t.takeException(), isNull);
        expect(_caption(t), _plain(l.guideHrZonesStep1(l.tabToday, l.homeRingStrain)));
        final card = t.getRect(find.byKey(GuideStepCard.cardKey));
        expect(card.overlaps(t.getRect(find.byKey(LiveGuideOverlay.outlineKey))), isFalse);
        expect(card.overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);
        final tabBar = t.getRect(_label(l.tabToday).last);
        expect(card.bottom, lessThanOrEqualTo(tabBar.top + 1), reason: 'the bottom card sits above the tab bar');
      });
    }
  });

  group('guide #7 start a workout', () {
    testWidgets('start from Help selects the Activity tab; tapping the real "start a session" card opens the real picker and the run advances', (t) async {
      // why: a second guide, another tab, a pushed route that is not a detail screen.
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'start-workout');
      final l = _l(t);
      expect(find.byType(WorkoutScreen), findsOneWidget);
      expect(_step(app), 0);
      expect(_caption(t), _plain(l.guideStartStep1(l.tabActivity, l.workoutStartSessionLabel)));
      // The StartCard is edge to edge; growing its outline must not draw offscreen.
      final outline = t.getRect(find.byKey(LiveGuideOverlay.outlineKey));
      expect(outline.left, greaterThanOrEqualTo(0));
      expect(outline.right, lessThanOrEqualTo(390));
      expect(outline.top, greaterThanOrEqualTo(0));
      expect(outline.bottom, lessThanOrEqualTo(844));
      await t.tap(_label(l.workoutStartSessionLabel));
      await _reveal(t);
      expect(_step(app), 1);
      expect(_caption(t), _plain(l.guideStartStep2(l.activityPickerSearchLabel)));
    });
  });

  group('guide #8 log a past workout', () {
    testWidgets('History tab -> the far "Log a past workout" card is revealed with the scroll marker -> the real form', (t) async {
      // why: a third guide, with a scroll step on a real lazy list and a
      // sub-tab tap that changes the same screen (the later anchor appears).
      final app = await pumpLiveGuideApp(t);
      await _startFromHelp(t, app, 'log-past-workout');
      final l = _l(t);
      expect(_step(app), 0);
      await t.tap(_label(l.workoutTabHistory));
      await _reveal(t);
      expect(_step(app), 1);
      expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsOneWidget);
      expect(_label(l.workoutLogPastFix), findsOneWidget);
      await t.tap(_label(l.workoutLogPastFix));
      await _reveal(t);
      expect(_step(app), 2);
      expect(_caption(t), _plain(l.guideLogPastStep3(l.logWorkoutWhenGroup, l.logWorkoutLogIt)));
    });
  });
}
