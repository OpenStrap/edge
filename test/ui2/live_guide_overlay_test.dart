// LiveGuideOverlay: the live renderer of a GuideRun over REAL pages (the stage
// in test/support/live_guide_stage.dart: a real MaterialApp, root Navigator,
// ui2 cards and Pressables). RED until the green phase implements
// lib/ui2/guides/live_guide_overlay.dart and guide_step_card.dart.
//
// The overlay is inserted into the ROOT overlay by the test itself, so these
// tests cover drawing, input and semantics apart from GuideRunner's navigation
// (live_guide_runner_test.dart) and from the full app (live_guide_integration_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_markers.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';

import '../support/live_guide_stage.dart';

final _en = lookupAppLocalizations(const Locale('en'));

LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));

/// Frames until the overlay has noticed the page and finished revealing it.
Future<void> _settleReveal(WidgetTester t) async {
  await t.pump();
  await t.pump();
  await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50));
  await t.pump();
}

Rect _rectOf(WidgetTester t, Finder f) => t.getRect(f);

bool _anyShapeOverlaps(Iterable<SkeletonShape> shapes, Rect r) => shapes.any((s) => s.rect.overlaps(r.deflate(1)));

/// Step 1 asks for a tap on "Ask first" (opens a confirm dialog), step 2 is Details' "Finish".
Guide _askFirstGuide() {
  final base = stageGuide();
  final variant = (base.variantFor(null) as GuideVariantFound).variant;
  return Guide(id: 'ask', title: (_) => 'Ask', start: GuideStart.today, variants: [
    GuideVariant(steps: [
      GuideStep(
        id: 'ask',
        target: GuideTarget.key(stageAskFirst),
        anchor: GuideTarget.key(stageHomeTitle),
        action: GuideAction.tap,
        caption: (_) => 'Tap **Ask first**.',
      ),
      variant.steps[1],
    ]),
  ], footers: base.footers);
}

void main() {
  group('skeleton over the real page', () {
    testWidgets('covers the text of every card that is not the target, keeps the target and the title', (t) async {
      // why: the headline behaviour: the user's OWN screen with everything but the
      // path collapsed. Oracle: engine rects of the real widgets, not the plan.
      await pumpLiveStage(t);
      await _settleReveal(t);
      final shapes = _overlay(t).paintedShapes;
      expect(shapes, isNotEmpty);
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.text('First card text'))), isTrue, reason: 'first card is skeletonized');
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.text('Second card text'))), isTrue, reason: 'second card is skeletonized');
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.text('Other action'))), isTrue, reason: 'other controls are skeletonized');
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.byKey(stageOpenDetails))), isFalse, reason: 'the target stays legible');
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.byKey(stageHomeTitle))), isFalse, reason: 'the title is chrome');
    });

    testWidgets('reports the target\'s rect in its own coordinates', (t) async {
      // why: markers are placed from it; a stale or offset rect misplaces the outline.
      await pumpLiveStage(t);
      await _settleReveal(t);
      final reported = _overlay(t).targetRect!;
      final real = _rectOf(t, find.byKey(stageOpenDetails));
      expect((reported.left - real.left).abs() < 1 && (reported.top - real.top).abs() < 1, isTrue, reason: '$reported vs $real');
      expect((reported.width - real.width).abs() < 1 && (reported.height - real.height).abs() < 1, isTrue);
    });

    testWidgets('plans over the page that is on top NOW: after navigating, the new page is skeletonized', (t) async {
      // why: CLAIM(overlay-follows-top-route). The overlay sits above every
      // route and must not keep planning over the page that was covered.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await _settleReveal(t);
      final shapes = _overlay(t).paintedShapes;
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.text('Details card text'))), isTrue);
      expect(_anyShapeOverlaps(shapes, _rectOf(t, find.byKey(stageFinish))), isFalse);
      expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 1));
    });

    testWidgets('an idle guide schedules no frames', (t) async {
      // why: the overlay re-plans after each frame; the loop must settle
      // (PR 1 'markers follow layout' made the same promise for the frame view).
      await pumpLiveStage(t);
      await _settleReveal(t);
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    });
  });

  group('a target that cannot be found', () {
    testWidgets('the card stays, nothing is covered, the page stays usable (a guide must never lock the user in)', (t) async {
      // why: PR 1 "unresolved target = typed failure, no silent empty guide" plus
      // spec "Exit always available". Step 1 anchors on Home (matches) but its
      // target key is on no widget: there is nothing to keep legible, so covering
      // and absorbing would trap the user behind a skeleton with no way forward.
      // Default taken: the step card is shown, the page is NOT covered or
      // blocked, and "Don't see it?" is offered (the guide's missing-target help).
      final base = stageGuide();
      final broken = Guide(id: 'broken', title: (_) => 'Broken', start: GuideStart.today, variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'lost',
            target: GuideTarget.key(const ValueKey('no-such-widget')),
            anchor: GuideTarget.key(stageHomeTitle),
            action: GuideAction.tap,
            caption: (_) => 'Tap **Nothing**.',
          ),
        ]),
      ], footers: base.footers);
      final stage = await pumpLiveStage(t, guide: broken);
      await _settleReveal(t);
      expect(t.takeException(), isNull);
      expect(stage.run.state, isA<GuideAtStep>());
      expect(find.byKey(GuideStepCard.cardKey), findsOneWidget);
      expect(find.byKey(GuideStepCard.dontSeeItKey), findsOneWidget);
      expect(_overlay(t).paintedShapes, isEmpty);
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing);
      await t.tap(find.byKey(stageOtherAction));
      expect(stage.taps.otherAction, 1, reason: 'the page underneath is usable');
      await t.tap(find.byKey(GuideStepCard.exitKey));
      expect(stage.exitCount, 1);
    });
  });

  group('progressive reveal', () {
    testWidgets('sections fade in from the top over the reveal time, then the outline and pill appear', (t) async {
      // why: CLAIM(overlay-reveal). Spec: "progressively ... over ~600 ms per
      // step (revealedShapes), then the outline and pill appear".
      await pumpLiveStage(t);
      await t.pump();
      await t.pump();
      final s = _overlay(t);
      expect(s.revealProgress, lessThan(.2), reason: 'a new step starts hidden');
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing);
      expect(find.byKey(LiveGuideOverlay.tapPillKey), findsNothing);
      final fewShapes = s.paintedShapes.length;

      await t.pump(kGuideRevealDuration ~/ 2);
      expect(s.revealProgress, closeTo(.5, .15));
      final halfShapes = s.paintedShapes.length;
      expect(halfShapes, greaterThanOrEqualTo(fewShapes));
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing, reason: 'markers wait for the full reveal');

      await t.pump(kGuideRevealDuration);
      await t.pump();
      expect(s.revealProgress, 1);
      expect(s.paintedShapes.length, greaterThan(halfShapes), reason: 'more of the page is covered at the end');
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
      expect(find.byKey(LiveGuideOverlay.tapPillKey), findsOneWidget);
    });

    testWidgets('a revealed prefix is whole sections from the top (never half a card)', (t) async {
      // why: revealedShapes reveals whole units; the overlay must paint through it.
      await pumpLiveStage(t);
      await t.pump();
      await t.pump();
      await t.pump(kGuideRevealDuration ~/ 2);
      final sections = {for (final s in _overlay(t).paintedShapes) s.section};
      if (sections.isNotEmpty) {
        expect(sections, {for (var i = 0; i <= sections.reduce((a, b) => a > b ? a : b); i++) i}, reason: 'contiguous from the top');
      }
    });

    testWidgets('a new step restarts the reveal', (t) async {
      // why: each step fades in; step 2 must not appear already complete.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      expect(_overlay(t).revealProgress, 1);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await t.pump();
      await t.pump();
      expect(_overlay(t).revealProgress, lessThan(.2));
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing);
    });
  });

  group('markers', () {
    testWidgets('outline hugs the target (4 px gap) and the tap pill stays off the target and off legible text', (t) async {
      // why: PR 1 marker rules (CLAIM pill-clear / pill-legible) now on the real page.
      await pumpLiveStage(t);
      await _settleReveal(t);
      final target = _rectOf(t, find.byKey(stageOpenDetails));
      final outline = _rectOf(t, find.byKey(LiveGuideOverlay.outlineKey));
      final pill = _rectOf(t, find.byKey(LiveGuideOverlay.tapPillKey));
      expect(outline.contains(target.topLeft) && outline.contains(target.bottomRight), isTrue);
      expect(outline.left, closeTo(target.left - kGuideOutlineGap, 1.5));
      expect(pill.overlaps(target), isFalse, reason: 'the pill never covers the target');
      final legible = legibleContent(t.element(find.byType(Scaffold).last), keep: [target]);
      for (final r in legible) {
        if (target.overlaps(r)) continue;
        expect(pill.overlaps(r.deflate(1)), isFalse, reason: 'pill $pill covers legible $r');
      }
    });

    testWidgets('a scrollThenTap step reveals a far target, shows the scroll marker and ends with the target on screen', (t) async {
      // why: spec "scroll steps reveal the target (revealTarget) and show the
      // scroll marker". Finish is 3000 px down a lazily built list.
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true), detailsGap: 3000);
      await _settleReveal(t);
      expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsNothing, reason: 'step 1 is a plain tap');
      await pushStagePage(t, stage, StagePages(stage.taps, detailsGap: 3000).details());
      await _settleReveal(t);
      await _settleReveal(t);
      expect(find.byKey(stageFinish), findsOneWidget);
      final finish = _rectOf(t, find.byKey(stageFinish));
      expect(finish.top >= 0 && finish.bottom <= 780, isTrue, reason: 'scrolled into view: $finish');
      expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsOneWidget);
    });
  });

  group('pointer rules', () {
    testWidgets('a tap on the target reaches the real control, which does what it always does', (t) async {
      // why: CLAIM(overlay-pass-through) + spec "taps on the target pass through
      // to the real control (it does exactly what it always does)".
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await t.tap(find.byKey(stageOpenDetails));
      await t.pump(const Duration(milliseconds: 400));
      expect(stage.taps.openDetails, 1);
      expect(find.byKey(stageDetailsTitle), findsOneWidget, reason: 'the real navigation happened');
    });

    testWidgets('taps anywhere else on the page are absorbed (with a positive control without the overlay)', (t) async {
      // why: spec "taps elsewhere are absorbed" - a skeleton you can still press
      // through is a trap. Positive control: the very same tap works once the
      // overlay is gone, so the 0 above is the overlay's doing.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await t.tap(find.byKey(stageOtherAction), warnIfMissed: false);
      await t.tap(find.text('Second card text'), warnIfMissed: false);
      await t.pump();
      expect(stage.taps.otherAction, 0);
      stage.entry!.remove();
      await t.pump();
      await t.tap(find.byKey(stageOtherAction));
      expect(stage.taps.otherAction, 1, reason: 'positive control: the control works without the overlay');
    });

    testWidgets('the card\'s Exit works and asks the owner of the run to end it, once', (t) async {
      // why: spec "a fixed Exit control is always available". The overlay does
      // not remove itself: GuideRunner does (CLAIM run-exit-in-place).
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await t.tap(find.byKey(GuideStepCard.exitKey));
      await t.pump();
      expect(stage.exitCount, 1);
    });

    testWidgets('system Back works as normal: it pops the real route and the guide follows', (t) async {
      // why: spec "system Back works as normal". The overlay must neither eat the
      // pop nor leave the card on the old step.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await _settleReveal(t);
      expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 1));
      await t.binding.handlePopRoute();
      await t.pump(const Duration(milliseconds: 400));
      await _settleReveal(t);
      expect(find.byKey(stageDetailsTitle), findsNothing);
      expect(find.byKey(stageHomeTitle), findsOneWidget);
      expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
    });

    testWidgets('a dialog on top is not leaving the path: the overlay yields, the dialog is fully usable', (t) async {
      // why: CLAIM(overlay-yields-to-dialogs). The target\'s tap may open the
      // app\'s own confirmation; absorbing taps there would trap the user in a
      // dialog they cannot answer, and an off-path card over it would be wrong.
      final stage = await pumpLiveStage(t, guide: _askFirstGuide());
      await _settleReveal(t);
      await t.tap(find.byKey(stageAskFirst));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Sure?'), findsOneWidget);
      await t.pump();
      expect(_overlay(t).isYielding, isTrue);
      expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0), reason: 'a dialog is not off the path');
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
      expect(find.byKey(GuideStepCard.cardKey), findsNothing, reason: 'nothing is drawn over the dialog');
      expect(_overlay(t).paintedShapes, isEmpty);

      await t.tap(find.text('Confirm'));
      await t.pump(const Duration(milliseconds: 400));
      expect(stage.taps.dialogConfirm, 1, reason: 'the dialog\'s own button received the tap');
      await _settleReveal(t);
      expect(_overlay(t).isYielding, isFalse);
      expect(find.byKey(GuideStepCard.cardKey), findsOneWidget, reason: 'the card is back after the dialog');
    });
  });

  group('off the path', () {
    testWidgets('a page the guide does not know gets the "You\'ve left the path" card, no skeleton, no absorbing', (t) async {
      // why: spec "No step matches -> a small card". Default taken: off the path
      // the page is NOT covered or blocked (the user is free to look around; only
      // Exit / Back to the guide are offered).
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      await _settleReveal(t);
      expect(stage.run.state, isA<GuideOffPath>());
      expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
      expect(find.text(_en.guideOffPathTitle), findsOneWidget);
      expect(_overlay(t).paintedShapes, isEmpty);
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing);
      await t.tap(find.byKey(stageElsewhereAction));
      expect(stage.taps.elsewhere, 1, reason: 'the page underneath is usable');
    });

    testWidgets('"Back to the guide" is handed to the owner of the run, "Exit" too', (t) async {
      // why: navigation is GuideRunner's job (backToGuide); the overlay only asks.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      await _settleReveal(t);
      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      expect(stage.backToGuideCount, 1);
      await t.tap(find.byKey(GuideStepCard.exitKey));
      expect(stage.exitCount, 1);
    });

    testWidgets('coming back to a step page brings the step card back', (t) async {
      // why: the card follows the run state in both directions.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).other());
      await _settleReveal(t);
      stage.navigator.pop();
      await t.pump(const Duration(milliseconds: 400));
      await _settleReveal(t);
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
      expect(find.byKey(GuideStepCard.captionKey), findsOneWidget);
      expect(_overlay(t).paintedShapes, isNotEmpty);
    });
  });

  group('last step and Done', () {
    testWidgets('the last tap passes through, then the Done card shows the guide\'s footers (not the missing-target help)', (t) async {
      // why: spec "Last step: highlight + caption, the tap passes through, then a
      // Done card; footers ... are shown on that card".
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await _settleReveal(t);
      await t.tap(find.byKey(stageFinish));
      await t.pump(const Duration(milliseconds: 100));
      expect(stage.taps.finish, 1, reason: 'the real control got the tap');
      await t.pump(const Duration(milliseconds: 400));
      expect(stage.run.state, isA<GuideFinished>());
      expect(find.byKey(GuideStepCard.doneKey), findsOneWidget);
      expect(find.text(_en.guideDoneTitle), findsOneWidget);
      expect(find.text('Another way in'), findsOneWidget);
      expect(find.text("Don't see Open details?"), findsNothing, reason: 'moot once done');
      expect(_overlay(t).paintedShapes, isEmpty, reason: 'nothing is covered any more');
    });

    testWidgets('a tap that lands elsewhere on the last step does NOT finish the guide', (t) async {
      // why: only the target\'s tap completes the guide (an absorbed tap is not it).
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await _settleReveal(t);
      await t.tap(find.text('Details card text'), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 400));
      expect(stage.run.state, isA<GuideAtStep>());
      expect(find.byKey(GuideStepCard.doneKey), findsNothing);
    });
  });

  group('the card', () {
    testWidgets('a target in the upper part: the card is at the bottom; low on the screen: at the top; never over the target or pill', (t) async {
      // why: CLAIM(card-never-covers-target) with real geometry. Home\'s target is
      // mid-screen (card at the bottom); Details\' Finish sits low (card on top).
      final stage = await pumpLiveStage(t, detailsGap: 520);
      await _settleReveal(t);
      var card = _rectOf(t, find.byKey(GuideStepCard.cardKey));
      var target = _rectOf(t, find.byKey(stageOpenDetails));
      expect(card.top, greaterThan(target.bottom), reason: 'bottom card sits below the target');
      expect(card.bottom, lessThanOrEqualTo(780));
      expect(card.overlaps(_rectOf(t, find.byKey(LiveGuideOverlay.outlineKey))), isFalse);
      expect(card.overlaps(_rectOf(t, find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);

      await pushStagePage(t, stage, StagePages(stage.taps, detailsGap: 520).details());
      await _settleReveal(t);
      card = _rectOf(t, find.byKey(GuideStepCard.cardKey));
      target = _rectOf(t, find.byKey(stageFinish));
      expect(target.top, greaterThan(390), reason: 'precondition: the target is in the lower half');
      expect(card.bottom, lessThan(target.top), reason: 'top card sits above the target');
      expect(card.overlaps(_rectOf(t, find.byKey(LiveGuideOverlay.outlineKey))), isFalse);
      expect(card.overlaps(_rectOf(t, find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);
    });

    testWidgets('the card shows the step caption and the number of the step the run is on', (t) async {
      // why: caption and badge come from the run\'s current step, in the app\'s language.
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      expect(find.descendant(of: find.byKey(GuideStepCard.badgeKey), matching: find.text('1')), findsOneWidget);
      expect(find.textContaining('Tap Open details on the home page.', findRichText: true), findsOneWidget);
      await pushStagePage(t, stage, StagePages(stage.taps).details());
      await _settleReveal(t);
      expect(find.descendant(of: find.byKey(GuideStepCard.badgeKey), matching: find.text('2')), findsOneWidget);
      expect(find.textContaining('Tap Finish at the bottom.', findRichText: true), findsOneWidget);
    });

    testWidgets('"Don\'t see it?" on a live step opens the guide\'s missing-target help', (t) async {
      // why: spec: expands during the step. The link is wired to the guide\'s
      // missingTarget footer, not to a note or the "another way in" footer.
      await pumpLiveStage(t);
      await _settleReveal(t);
      await t.tap(find.byKey(GuideStepCard.dontSeeItKey));
      await t.pump();
      final help = find.byKey(GuideStepCard.missingHelpKey);
      expect(find.descendant(of: help, matching: find.text("Don't see Open details?")), findsOneWidget);
      expect(find.descendant(of: help, matching: find.text('Another way in')), findsNothing);
    });
  });

  group('screen readers', () {
    testWidgets('the target gets ONE proxy node "Guide target: <caption>" that performs the tap', (t) async {
      // why: spec "the target gets a proxy node that says Guide target: <caption>".
      // Activating it must do what tapping the control does.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      final stage = await pumpLiveStage(t);
      await _settleReveal(t);
      final proxy = find.semantics.byLabel(_en.guideTargetProxy('Tap Open details on the home page.'));
      expect(proxy, findsOneWidget);
      t.semantics.tap(proxy);
      await t.pump(const Duration(milliseconds: 400));
      expect(stage.taps.openDetails, 1);
    });

    testWidgets('the tap pill, scroll marker and outline add no duplicate labels', (t) async {
      // why: PR 1 item 7 "markers carry no duplicate labels": the proxy already
      // says what to do.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await pumpLiveStage(t);
      await _settleReveal(t);
      expect(find.bySemanticsLabel(_en.guideTapMarker), findsNothing);
      expect(find.bySemanticsLabel(_en.guideScrollMarker), findsNothing);
    });

    testWidgets('covered content stays in the semantics tree (foreign semantics cannot be excluded)', (t) async {
      // why: spec states the limit; this pins that we do not pretend otherwise.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await pumpLiveStage(t);
      await _settleReveal(t);
      expect(find.bySemanticsLabel('Second card text'), findsOneWidget);
    });
  });

  group('languages', () {
    testWidgets('Russian at 1.3x text: no exception, the card keeps clear of the target', (t) async {
      // why: the owner\'s language requirement; long Russian card text must not
      // overflow or reach the target.
      t.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpLiveStage(t, locale: const Locale('ru'));
      await _settleReveal(t);
      expect(t.takeException(), isNull);
      final card = _rectOf(t, find.byKey(GuideStepCard.cardKey));
      expect(card.overlaps(_rectOf(t, find.byKey(LiveGuideOverlay.outlineKey))), isFalse);
      expect(find.text(lookupAppLocalizations(const Locale('ru')).guideExit), findsOneWidget);
    });
  });
}
