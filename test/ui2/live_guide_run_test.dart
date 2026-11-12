// GuideRun: the in-memory state machine of one live guide. RED until the
// green phase implements lib/ui2/guides/guide_run.dart.
//
// The trees are the live stage's real pages (test/support/live_guide_stage.dart):
// anchors are resolved by the production GuideTarget code against laid-out
// widgets, never faked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';

import '../support/live_guide_stage.dart';

final _en = lookupAppLocalizations(const Locale('en'));

GuideRun _freshRun([Guide? g]) {
  final guide = g ?? stageGuide();
  return GuideRun(guide: guide, variant: (guide.variantFor(null) as GuideVariantFound).variant);
}

/// The element of the page on top, as the overlay would hand it to the run.
Element _topPage(WidgetTester t) => t.element(find.byType(Scaffold).last);

void main() {
  group('start', () {
    test('a new run is on step 0: not off the path, not finished, not exited', () {
      // why: the first frame has not looked at the screen yet; showing "You've
      // left the path" for it would flash the off-path card on every start.
      final run = _freshRun();
      addTearDown(run.dispose);
      expect(run.state, isA<GuideAtStep>());
      expect((run.state as GuideAtStep).index, 0);
      expect(run.currentStep?.id, 'open');
      expect(run.isExited, isFalse);
    });
  });

  group('matchStep', () {
    testWidgets('takes the page it is on: home is step 0, details is step 1, elsewhere is none', (t) async {
      // why: CLAIM(run-match-furthest) base case: each anchor identifies its page.
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final variant = stage.run.variant;
      expect(GuideRun.matchStep(variant, _topPage(t), _en), 0);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      expect(GuideRun.matchStep(variant, _topPage(t), _en), 1);
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      expect(GuideRun.matchStep(variant, _topPage(t), _en), isNull);
    });

    testWidgets('takes the FURTHEST step when several anchors resolve on one page', (t) async {
      // why: CLAIM(run-match-furthest). Delete-workout's step 1 anchor (the
      // History tab) stays on screen after the tap, and step 2's anchor (the bin)
      // appears on the same page: the guide must be on step 2 then, never stuck
      // on step 1.
      final stage = await pumpLiveStage(t, insertOverlay: false);
      await t.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(children: [
            SizedBox(key: stageHomeTitle, height: 20, width: 100, child: const Text('home anchor')),
            SizedBox(key: stageDetailsTitle, height: 20, width: 100, child: const Text('details anchor')),
          ]),
        ),
      ));
      await t.pump();
      expect(GuideRun.matchStep(stage.run.variant, _topPage(t), _en), 1);
    });

    testWidgets('an anchor by label follows the language the app is shown in', (t) async {
      // why: anchors are in-app labels; a Russian user's screen says "Сон", and
      // the English getter must not match it (and vice versa).
      final ru = lookupAppLocalizations(const Locale('ru'));
      final guide = Guide(id: 'g', title: (_) => 'G', start: GuideStart.sleep, variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'only',
            target: GuideTarget.label((l) => l.tabSleep),
            anchor: GuideTarget.label((l) => l.tabSleep),
            action: GuideAction.tap,
            caption: (_) => 'c',
          ),
        ]),
      ]);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Text(ru.tabSleep))));
      final variant = (guide.variantFor(null) as GuideVariantFound).variant;
      expect(GuideRun.matchStep(variant, _topPage(t), ru), 0);
      expect(GuideRun.matchStep(variant, _topPage(t), _en), isNull, reason: 'English label is not on this Russian screen');
    });
  });

  group('observe', () {
    testWidgets('follows the user: home -> details -> off the path -> back to details', (t) async {
      // why: the whole point of live mode: the step shown is the step the user
      // is on. OffPath remembers the last matched step ("Back to the guide").
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final run = stage.run;
      run.observe(_topPage(t), _en);
      expect(run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));

      await pushStagePage(t, stage, StagePages(stage.taps).details());
      run.observe(_topPage(t), _en);
      expect(run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 1));
      expect(run.currentStep?.id, 'finish');

      await pushStagePage(t, stage, StagePages(stage.taps).other());
      run.observe(_topPage(t), _en);
      expect(run.state, isA<GuideOffPath>().having((s) => s.lastIndex, 'lastIndex', 1));
      expect(run.currentStep, isNull);

      stage.navigator.pop();
      await t.pump(); // Start the reverse transition before advancing its clock.
      await t.pump(const Duration(milliseconds: 400));
      run.observe(_topPage(t), _en);
      expect(run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 1));
    });

    testWidgets('an unmatched first frame is off the path with nothing to go back to', (t) async {
      // why: a run started on the wrong screen has no last matched step; the
      // card must not offer a "Back" to nowhere (lastIndex null).
      final stage = await pumpLiveStage(t, insertOverlay: false);
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      stage.run.observe(_topPage(t), _en);
      expect(stage.run.state, isA<GuideOffPath>().having((s) => s.lastIndex, 'lastIndex', isNull));
    });

    testWidgets('a null page (dialog on top) holds the state, whatever it was', (t) async {
      // why: CLAIM(overlay-yields-to-dialogs). The user tapped the target and
      // the app asked "Are you sure?": that is the step in progress, not
      // leaving the path.
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final run = stage.run;
      run.observe(_topPage(t), _en);
      final before = run.state;
      run.observe(null, _en);
      expect(run.state, same(before));
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      run.observe(_topPage(t), _en);
      final off = run.state;
      run.observe(null, _en);
      expect(run.state, same(off), reason: 'an off-path run also holds while a dialog is up');
    });

    testWidgets('notifies listeners on a change and only on a change', (t) async {
      // why: the overlay rebuilds on notifications; a notification per frame
      // would make an idle guide re-plan forever (the loop must settle).
      final stage = await pumpLiveStage(t, insertOverlay: false);
      var notifications = 0;
      stage.run.addListener(() => notifications++);
      stage.run.observe(_topPage(t), _en);
      expect(notifications, 0, reason: 'step 0 -> step 0 is no change');
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      stage.run.observe(_topPage(t), _en);
      stage.run.observe(_topPage(t), _en);
      stage.run.observe(_topPage(t), _en);
      expect(notifications, 1);
    });
  });

  group('targetTapped', () {
    testWidgets('on a middle step changes nothing; on the last step the run is finished', (t) async {
      // why: only the LAST target ends the guide; the middle steps advance when
      // the next screen's anchor shows up, so a tap alone must not skip a step.
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final run = stage.run;
      run.observe(_topPage(t), _en);
      run.targetTapped();
      expect(run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      run.observe(_topPage(t), _en);
      run.targetTapped();
      expect(run.state, isA<GuideFinished>());
    });

    testWidgets('a finished run stays finished however the screens change afterwards', (t) async {
      // why: the Done card must not flip to "You've left the path" because the
      // last tap navigated away (the last tap usually does).
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final run = stage.run;
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      run.observe(_topPage(t), _en);
      run.targetTapped();
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      run.observe(_topPage(t), _en);
      expect(run.state, isA<GuideFinished>());
    });
  });

  group('exit', () {
    testWidgets('ends the run for good: flag set, one notification, later calls ignored', (t) async {
      // why: Exit must be final; a late frame callback after Exit must not bring
      // the card back.
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final run = stage.run;
      var notifications = 0;
      run.addListener(() => notifications++);
      run.exit();
      expect(run.isExited, isTrue);
      expect(notifications, 1);
      final after = run.state;
      run.observe(_topPage(t), _en);
      run.targetTapped();
      run.exit();
      expect(run.state, same(after));
      expect(notifications, 1);
      expect(run.currentStep, isNull);
    });
  });
}
