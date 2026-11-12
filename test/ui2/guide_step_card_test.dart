// GuideStepCard and placeGuideCard: the one card live guides show (spec
// "Live mode: the step card"). RED until the green phase implements
// lib/ui2/guides/guide_step_card.dart.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';

import '../support/skeleton_fixture.dart';

final _l = lookupAppLocalizations(const Locale('en'));

GuideFooter _missing() => GuideFooter(
      kind: GuideFooterKind.missingTarget,
      title: (_) => "Don't see Open details?",
      body: (_) => 'It only shows once you have signed in.',
    );

GuideFooter _alt() => GuideFooter(
      kind: GuideFooterKind.anotherWay,
      title: (_) => 'Another way in',
      body: (_) => 'Open the menu, then **Details**.',
    );

GuideFooter _note() => GuideFooter(
      kind: GuideFooterKind.note,
      title: (_) => 'What deleting does',
      body: (_) => 'The session disappears from the app.',
    );

Future<({List<String> exits, List<String> backs})> _pumpCard(
  WidgetTester t,
  GuideCardModel model, {
  bool withBack = true,
  Locale locale = const Locale('en'),
  double width = 358,
}) async {
  final calls = (exits: <String>[], backs: <String>[]);
  skTallView(t, w: 390, h: 780);
  await t.pumpWidget(skHost(
    Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: width,
        child: GuideStepCard(
          model: model,
          onExit: () => calls.exits.add('exit'),
          onBackToGuide: withBack ? () => calls.backs.add('back') : null,
        ),
      ),
    ),
    locale: locale,
  ));
  await t.pump();
  return calls;
}

const _step2of3 = GuideCardOnStep(number: 2, total: 3, caption: 'Tap **Open details** on the home page.');

GuideCardOnStep _withHelp() => GuideCardOnStep(
      number: 2,
      total: 3,
      caption: 'Tap **Open details** on the home page.',
      missingHelp: _missing(),
    );

Color _dotColor(WidgetTester t, int i) {
  final box = t.widget<DecoratedBox>(find.byKey(GuideStepCard.dotKey(i)));
  return (box.decoration as BoxDecoration).color!;
}

void main() {
  group('on a step: content and order', () {
    testWidgets('badge, caption, dots, then "Don\'t see it?" and Exit, top to bottom', (t) async {
      // why: spec "red step badge + caption, progress dots, Don't see it? link,
      // Exit" - in that reading order, because a screen reader walks the same order.
      await _pumpCard(t, _withHelp());
      final badge = t.getRect(find.byKey(GuideStepCard.badgeKey));
      final caption = t.getRect(find.byKey(GuideStepCard.captionKey));
      final dots = t.getRect(find.byKey(GuideStepCard.dotsKey));
      final dontSee = t.getRect(find.byKey(GuideStepCard.dontSeeItKey));
      final exit = t.getRect(find.byKey(GuideStepCard.exitKey));
      expect(find.descendant(of: find.byKey(GuideStepCard.badgeKey), matching: find.text('2')), findsOneWidget);
      expect(badge.left, lessThan(caption.left), reason: 'badge is left of the caption');
      expect(caption.bottom, lessThanOrEqualTo(dots.top + 1));
      expect(dots.bottom, lessThanOrEqualTo(dontSee.top + 1));
      expect(dontSee.center.dy, closeTo(exit.center.dy, 2), reason: 'link and Exit share the bottom row');
      expect(dontSee.left, lessThan(exit.left));
    });

    testWidgets('the app\'s own labels in the caption are bold, the asterisks are not shown', (t) async {
      // why: captions quote the app's labels so the user can find them; the bold
      // marks which words to look for (same text as the approved review images).
      await _pumpCard(t, _step2of3);
      final rich = t.widget<RichText>(find.descendant(of: find.byKey(GuideStepCard.captionKey), matching: find.byType(RichText)).first);
      expect(rich.text.toPlainText(), 'Tap Open details on the home page.');
      final bold = <String>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w700 && span.text != null) bold.add(span.text!);
        return true;
      });
      expect(bold, ['Open details']);
    });

    testWidgets('the card keeps the caption whole at 1.3x text in German and Russian', (t) async {
      // why: the owner's language requirement: long translations must not clip
      // or overflow the card (the same stress PR 1's frame tests use).
      for (final locale in const [Locale('de'), Locale('ru')]) {
        await _pumpCard(t, _withHelp(), locale: locale);
        expect(t.takeException(), isNull, reason: '$locale');
        expect(find.text(AppLocalizations.of(t.element(find.byKey(GuideStepCard.cardKey)))!.guideExit), findsOneWidget);
      }
    });
  });

  group('progress dots', () {
    testWidgets('one dot per step; only the current step\'s dot is highlighted', (t) async {
      // why: the user sees where they are in the guide. 2 of 3 -> dot index 1.
      await _pumpCard(t, _step2of3);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(GuideStepCard.dotKey(i)), findsOneWidget, reason: 'dot $i');
      }
      expect(find.byKey(GuideStepCard.dotKey(3)), findsNothing);
      expect(_dotColor(t, 0), _dotColor(t, 2), reason: 'the other dots look alike');
      expect(_dotColor(t, 1), isNot(_dotColor(t, 0)), reason: 'the current dot stands out');
    });

    testWidgets('a screen reader hears ONE "Step 2 of 3", not three dots', (t) async {
      // why: three unlabeled dots would be three silent stops; one node carries
      // the whole sentence (guideStepOf).
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await _pumpCard(t, _step2of3);
      expect(find.bySemanticsLabel(_l.guideStepOf('2', '3')), findsOneWidget);
    });

    testWidgets('a one-step guide still shows its single dot', (t) async {
      // why: boundary: total 1.
      await _pumpCard(t, const GuideCardOnStep(number: 1, total: 1, caption: 'Tap **Go**.'));
      expect(find.byKey(GuideStepCard.dotKey(0)), findsOneWidget);
      expect(find.byKey(GuideStepCard.dotKey(1)), findsNothing);
    });
  });

  group('"Don\'t see it?"', () {
    testWidgets('expands the guide\'s missing-target help IN PLACE, and collapses again', (t) async {
      // why: spec: the help shows during the step, inside the card (not a new
      // route or dialog), and the caption and dots stay while it is open.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await _pumpCard(t, _withHelp());
      expect(find.byKey(GuideStepCard.missingHelpKey), findsNothing);
      final collapsedHeight = t.getSize(find.byKey(GuideStepCard.cardKey)).height;

      await t.tap(find.byKey(GuideStepCard.dontSeeItKey));
      await t.pump();
      final help = find.byKey(GuideStepCard.missingHelpKey);
      expect(help, findsOneWidget);
      expect(find.descendant(of: help, matching: find.text("Don't see Open details?")), findsOneWidget);
      expect(find.descendant(of: help, matching: find.textContaining('only shows once you have signed in')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing, reason: 'in place, not a dialog');
      expect(t.getSize(find.byKey(GuideStepCard.cardKey)).height, greaterThan(collapsedHeight));
      expect(t.getRect(find.byKey(GuideStepCard.cardKey)).contains(t.getRect(help).center), isTrue);
      expect(find.byKey(GuideStepCard.captionKey), findsOneWidget, reason: 'the step stays readable');
      expect(find.byKey(GuideStepCard.dotsKey), findsOneWidget);
      expect(t.getSemantics(find.byKey(GuideStepCard.dontSeeItKey)).flagsCollection.isExpanded, Tristate.isTrue);

      await t.tap(find.byKey(GuideStepCard.dontSeeItKey));
      await t.pump();
      expect(find.byKey(GuideStepCard.missingHelpKey), findsNothing);
      expect(t.getSize(find.byKey(GuideStepCard.cardKey)).height, collapsedHeight);
      expect(t.getSemantics(find.byKey(GuideStepCard.dontSeeItKey)).flagsCollection.isExpanded, Tristate.isFalse);
    });

    testWidgets('a guide with no missing-target help offers no link', (t) async {
      // why: a link that expands to nothing is a dead control. Guides #3 and #7
      // have only notes.
      await _pumpCard(t, _step2of3);
      expect(find.byKey(GuideStepCard.dontSeeItKey), findsNothing);
      expect(find.byKey(GuideStepCard.exitKey), findsOneWidget);
    });

    testWidgets('the help collapses when the step changes', (t) async {
      // why: help for step 2\'s missing target must not stay open over step 3.
      await _pumpCard(t, _withHelp());
      await t.tap(find.byKey(GuideStepCard.dontSeeItKey));
      await t.pump();
      expect(find.byKey(GuideStepCard.missingHelpKey), findsOneWidget);
      await t.pumpWidget(skHost(Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 358,
          child: GuideStepCard(
            model: GuideCardOnStep(number: 3, total: 3, caption: 'Tap **Finish**.', missingHelp: _missing()),
            onExit: () {},
          ),
        ),
      )));
      await t.pump();
      expect(find.byKey(GuideStepCard.missingHelpKey), findsNothing);
    });
  });

  group('Exit', () {
    testWidgets('is on every state and calls onExit once; its screen-reader label says what it exits', (t) async {
      // why: spec "Exit always available"; the visible word "Exit" alone is
      // ambiguous to a screen reader.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      for (final model in <GuideCardModel>[_withHelp(), const GuideCardOffPath(), GuideCardDone([_alt()])]) {
        final calls = await _pumpCard(t, model);
        expect(find.byKey(GuideStepCard.exitKey), findsOneWidget, reason: '${model.runtimeType}');
        expect(find.bySemanticsLabel(_l.guideExitLabel), findsOneWidget);
        await t.tap(find.byKey(GuideStepCard.exitKey));
        await t.pump();
        expect(calls.exits, hasLength(1), reason: '${model.runtimeType}');
      }
    });
  });

  group('off the path', () {
    testWidgets('"You\'ve left the path" with "Back to the guide" and "Exit", and nothing of a step', (t) async {
      // why: spec "Off-path: the same card shows ..." - no stale badge/dots.
      final calls = await _pumpCard(t, const GuideCardOffPath());
      final card = find.byKey(GuideStepCard.offPathKey);
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text(_l.guideOffPathTitle)), findsOneWidget);
      expect(find.text(_l.guideOffPathTitle), findsOneWidget);
      expect(find.byKey(GuideStepCard.backToGuideKey), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepCard.backToGuideKey), matching: find.text(_l.guideBackToGuide)), findsOneWidget);
      for (final k in [GuideStepCard.badgeKey, GuideStepCard.captionKey, GuideStepCard.dotsKey, GuideStepCard.dontSeeItKey, GuideStepCard.doneKey]) {
        expect(find.byKey(k), findsNothing, reason: '$k');
      }
      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      expect(calls.backs, hasLength(1));
      expect(calls.exits, isEmpty);
    });

    testWidgets('without a step to go back to, "Back to the guide" is not offered', (t) async {
      // why: a Back that goes nowhere is worse than no button (lastIndex null).
      await _pumpCard(t, const GuideCardOffPath(), withBack: false);
      expect(find.byKey(GuideStepCard.backToGuideKey), findsNothing);
      expect(find.byKey(GuideStepCard.exitKey), findsOneWidget);
    });
  });

  group('done', () {
    testWidgets('"Done", the guide\'s footers in order ("Another way in" first), and Exit', (t) async {
      // why: spec "Last step done: the card becomes the Done card with Another
      // way in when the guide has one". Footers keep the guide's order.
      await _pumpCard(t, GuideCardDone([_alt(), _note()]));
      final card = find.byKey(GuideStepCard.doneKey);
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text(_l.guideDoneTitle)), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepCard.footerKey(0)), matching: find.text('Another way in')), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepCard.footerKey(1)), matching: find.text('What deleting does')), findsOneWidget);
      expect(find.byKey(GuideStepCard.footerKey(2)), findsNothing);
      expect(t.getRect(find.byKey(GuideStepCard.footerKey(0))).top, lessThan(t.getRect(find.byKey(GuideStepCard.footerKey(1))).top));
      expect(find.byKey(GuideStepCard.dotsKey), findsNothing);
      expect(find.byKey(GuideStepCard.dontSeeItKey), findsNothing);
    });

    testWidgets('a guide with no footers still ends on a Done card with Exit', (t) async {
      // why: boundary: empty footer list.
      await _pumpCard(t, const GuideCardDone([]));
      expect(find.byKey(GuideStepCard.doneKey), findsOneWidget);
      expect(find.byKey(GuideStepCard.footerKey(0)), findsNothing);
      expect(find.byKey(GuideStepCard.exitKey), findsOneWidget);
    });
  });

  group('screen readers', () {
    testWidgets('the caption is a live region whose label is the caption without markup, updated on every step', (t) async {
      // why: CLAIM(card-live-region). Announced on each step change; the
      // asterisks of the bold markup must not be read out.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await _pumpCard(t, _step2of3);
      final first = find.semantics.byLabel('Tap Open details on the home page.');
      expect(first, findsOneWidget);
      expect(first.evaluate().single.flagsCollection.isLiveRegion, isTrue);
      expect(find.bySemanticsLabel(RegExp(r'\*')), findsNothing);

      await t.pumpWidget(skHost(Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 358,
          child: GuideStepCard(
            model: const GuideCardOnStep(number: 3, total: 3, caption: 'Tap **Finish** at the bottom.'),
            onExit: () {},
          ),
        ),
      )));
      await t.pump();
      final second = find.semantics.byLabel('Tap Finish at the bottom.');
      expect(second, findsOneWidget);
      expect(second.evaluate().single.flagsCollection.isLiveRegion, isTrue);
      expect(find.semantics.byLabel('Tap Open details on the home page.'), findsNothing);
    });

    testWidgets('the off-path and Done titles are live regions too', (t) async {
      // why: the state change IS the news; silence would leave a blind user on a
      // card they do not know has changed.
      final handle = t.ensureSemantics();
      addTearDown(handle.dispose);
      await _pumpCard(t, const GuideCardOffPath());
      expect(find.semantics.byLabel(_l.guideOffPathTitle).evaluate().single.flagsCollection.isLiveRegion, isTrue);
      await _pumpCard(t, const GuideCardDone([]));
      expect(find.semantics.byLabel(_l.guideDoneTitle).evaluate().single.flagsCollection.isLiveRegion, isTrue);
    });
  });

  group('placeGuideCard', () {
    // Screen 390 x 780; top chrome 60, tab bar 60: bounds 390 x 660 from y=60.
    // Card 358 x 150. By hand (kGuideCardGap = 12):
    //   bottom: x = 195 - 179 = 16, y = 720 - 12 - 150 = 558  -> 558..708
    //   top   : x = 16,             y = 60 + 12 = 72          -> 72..222
    const bounds = Rect.fromLTWH(0, 60, 390, 660);
    const card = Size(358, 150);

    test('with the target well above the bottom, the card sits at the bottom, centred', () {
      // why: the default place is bottom, above the tab bar.
      final r = placeGuideCard(bounds: bounds, cardSize: card, keepClear: [const Rect.fromLTWH(20, 200, 350, 44)]);
      expect(r, const Rect.fromLTWH(16, 558, 358, 150));
      expect(r.bottom, lessThanOrEqualTo(bounds.bottom), reason: 'above the tab bar');
    });

    test('with the target in the lower part of the screen, the card moves to the top', () {
      // why: spec "when the target (or its pill) is in the lower part of the
      // screen, the card moves to the top". Target 600..644 overlaps 558..708.
      final r = placeGuideCard(bounds: bounds, cardSize: card, keepClear: [const Rect.fromLTWH(20, 600, 350, 44)]);
      expect(r, const Rect.fromLTWH(16, 72, 358, 150));
    });

    test('the PILL counts like the target: a pill poking into the bottom slot moves the card up', () {
      // why: the target ends at 540 (clear of 558) but its pill sits 548..568.
      final r = placeGuideCard(
        bounds: bounds,
        cardSize: card,
        keepClear: [const Rect.fromLTWH(20, 496, 350, 44), const Rect.fromLTWH(300, 548, 60, 20)],
      );
      expect(r.top, 72);
    });

    test('CLAIM(card-never-covers-target): across every target position the card never touches the target or pill', () {
      // why: the headline promise. Sweep a 44-high target (with a 60x20 pill
      // just left of its top edge) from the top to the bottom of the bounds.
      for (var y = bounds.top; y <= bounds.bottom - 44; y += 12) {
        final target = Rect.fromLTWH(20, y, 350, 44);
        final pill = Rect.fromLTWH(8, y - 12, 60, 20).intersect(bounds);
        final r = placeGuideCard(bounds: bounds, cardSize: card, keepClear: [target, pill]);
        expect(r.overlaps(target), isFalse, reason: 'target at y=$y, card $r');
        expect(r.overlaps(pill), isFalse, reason: 'pill at y=$y, card $r');
        expect(bounds.contains(r.topLeft) && bounds.contains(r.bottomRight - const Offset(.01, .01)), isTrue, reason: 'inside bounds, y=$y');
      }
    });

    test('legible content is avoided like the pill avoids it', () {
      // why: spec "same legible-content avoidance as the pill". A text line in
      // the bottom slot pushes the card to the top even though the target is high.
      final r = placeGuideCard(
        bounds: bounds,
        cardSize: card,
        // Both slots must clear the target before testing the legibility tie-break.
        keepClear: [const Rect.fromLTWH(20, 330, 350, 44)],
        avoid: [const Rect.fromLTWH(20, 600, 300, 18)],
      );
      expect(r.top, 72);
      expect(r.overlaps(const Rect.fromLTWH(20, 330, 350, 44)), isFalse);
    });

    test('legible content on both sides: the side that covers less of it wins, the target stays clear', () {
      // why: the pill's fallback ("covers the least text") applies. Bottom slot
      // has 1 line, the top slot has 3.
      final r = placeGuideCard(
        bounds: bounds,
        cardSize: card,
        keepClear: [const Rect.fromLTWH(20, 330, 350, 44)],
        avoid: [
          const Rect.fromLTWH(20, 600, 300, 18),
          const Rect.fromLTWH(20, 90, 300, 18),
          const Rect.fromLTWH(20, 120, 300, 18),
          const Rect.fromLTWH(20, 150, 300, 18),
        ],
      );
      expect(r.top, 558);
      expect(r.overlaps(const Rect.fromLTWH(20, 330, 350, 44)), isFalse);
    });

    test('a target that fills the room still gets a card inside the bounds', () {
      // why: degenerate case (huge target on a short window): never off-screen.
      final r = placeGuideCard(bounds: bounds, cardSize: card, keepClear: [bounds]);
      expect(r.top >= bounds.top && r.bottom <= bounds.bottom, isTrue);
    });
  });
}
