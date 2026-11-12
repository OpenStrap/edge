// GuideStepView / GuideView (test/support: review tooling, never shipped): the demo
// frame around a skeletonized real screen. The marker rules it shares with the
// live overlay (GuidePillLayout, legibleContent) live in guide_markers.dart.
// Hand-built screens of real ui2 cards; the real guide #1 is covered in
// guide_heart_rate_zones_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/guide_markers.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/guide_demo_screens.dart';
import '../support/guide_view.dart';
import '../support/skeleton_fixture.dart';

const _fk = GuideStepView.frameKey;

/// A screen: title (chrome), one ordinary card, [gap] of space, then a Section
/// whose ACTION is the target. A big gap pushes the target below the frame.
Widget _screen(double gap) => Builder(builder: (c) {
      final l = AppLocalizations.of(c)!;
      return Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ScreenTitle('Screen title', key: ValueKey('screenTitle')),
            const Surface(child: Text('other card text')),
            SizedBox(height: gap),
            Section(l.dayStrainTimeInZonesSection, const Surface(child: Text('chart')),
                action: l.dayStrainHowSet, onAction: () {}),
          ],
        ),
      );
    });

GuideStep _step(double gap, GuideAction a,
        {GuideTarget? target, int n = 0, List<GuideTarget> alsoKeep = const []}) =>
    demoStep(
      id: 'step-$n',
      screen: (_) => _screen(gap),
      target: target ?? GuideTarget.label((l) => l.dayStrainHowSet),
      anchor: GuideTarget.label((l) => l.dayStrainTimeInZonesSection),
      alsoKeep: alsoKeep,
      action: a,
      caption: (l) => 'Step caption $n: ${l.dayStrainTimeInZonesSection}',
    );

Future<void> _pump(WidgetTester t, GuideStep step, {int number = 2, Locale locale = const Locale('en')}) async {
  skTallView(t);
  await t.pumpWidget(skHost(
    Scaffold(body: SingleChildScrollView(child: Center(child: GuideStepView(number: number, step: step)))),
    locale: locale,
  ));
  await t.pumpAndSettle();
}

Rect _inSkeleton(WidgetTester t, Rect global) {
  final rb = t.renderObject<RenderBox>(find.byType(Skeletonize));
  return Rect.fromPoints(rb.globalToLocal(global.topLeft), rb.globalToLocal(global.bottomRight));
}

void main() {
  group('GuidePillLayout', () {
    // Frame 300 x 600; pill 40 x 20. Candidate boxes, by hand (S.x2 = ${S.x2}):
    //   left  : x = outline.left + 2 - 40, y = outline.centre.dy - 10
    //   above : x = outline.right - 40 - S.x2, y = outline.top - 20 + 2
    //   below : x = same,                      y = outline.bottom - 2
    const bounds = Rect.fromLTWH(0, 0, 300, 600);
    const size = Size(40, 20);

    test('beside the outline (left, vertically centred) when it fits', () {
      // why: new rule - the pill no longer sits above, where it covered text.
      const outline = Rect.fromLTWH(150, 300, 100, 30);
      final pill = const GuidePillLayout(outline, bounds).place(size);
      expect(pill, const Rect.fromLTWH(112, 305, 40, 20)); // 150 + 2 - 40; 315 - 10
    });

    test('above when there is no room on the left', () {
      // why: second preference. Outline at x=20: left box would start at -18.
      const outline = Rect.fromLTWH(20, 300, 100, 30);
      final pill = const GuidePillLayout(outline, bounds).place(size);
      expect(pill, Rect.fromLTWH(120 - 40 - S.x2, 282, 40, 20)); // 300 - 20 + 2
    });

    test('below when left does not fit and above leaves the frame', () {
      // why: third preference. Outline 5 px from the top: above would start at -13.
      const outline = Rect.fromLTWH(20, 5, 100, 30);
      final pill = const GuidePillLayout(outline, bounds).place(size);
      expect(pill, Rect.fromLTWH(120 - 40 - S.x2, 33, 40, 20)); // 35 - 2
    });

    test('a position that overlaps legible text is skipped', () {
      // why: step 3 of guide #1 - text right above the link must stay readable.
      const outline = Rect.fromLTWH(20, 300, 100, 30);
      const textAbove = Rect.fromLTWH(30, 285, 80, 14); // inside the above box (72..112 x 282..302)
      final pill = const GuidePillLayout(outline, bounds, [textAbove]).place(size);
      expect(pill, Rect.fromLTWH(120 - 40 - S.x2, 328, 40, 20)); // below: 330 - 2
      // and a text line to the left pushes the pill off the left slot
      const outline2 = Rect.fromLTWH(150, 300, 100, 30);
      const textLeft = Rect.fromLTWH(100, 305, 40, 14); // overlaps the left box 112..152
      final pill2 = const GuidePillLayout(outline2, bounds, [textLeft]).place(size);
      expect(pill2, Rect.fromLTWH(250 - 40 - S.x2, 282, 40, 20));
    });

    test('text that only touches the pill\'s edge does not block it', () {
      // why: boundary - Rect.overlaps is strict; touching is not covering.
      const outline = Rect.fromLTWH(150, 300, 100, 30);
      const touching = Rect.fromLTWH(60, 305, 52, 14); // right edge 112 = pill.left
      expect(const GuidePillLayout(outline, bounds, [touching]).place(size), const Rect.fromLTWH(112, 305, 40, 20));
    });

    test('with every position blocked, the one covering the least text wins and stays inside the frame', () {
      // why: never off-screen, never silently the old behaviour; deterministic.
      const outline = Rect.fromLTWH(150, 300, 100, 30);
      // left box 112..152 x 305..325; above 202..242 x 282..302; below 202..242 x 328..348
      final big = [
        const Rect.fromLTWH(112, 305, 40, 20), // fully covers left (area 800)
        const Rect.fromLTWH(202, 282, 40, 20), // fully covers above (800)
        const Rect.fromLTWH(202, 328, 40, 5), // covers 5 of 20 rows of below (200)
      ];
      final pill = GuidePillLayout(outline, bounds, big).place(size);
      expect(pill, const Rect.fromLTWH(202, 328, 40, 20));
      expect(bounds.contains(pill.topLeft) && bounds.contains(pill.bottomRight), isTrue);
    });

    test('getPositionForChild is the placed box\'s corner and constraints are loose', () {
      // why: the delegate must hand the pill loose constraints (tight ones
      // stretched it over the whole frame once) and use place().
      const outline = Rect.fromLTWH(150, 300, 100, 30);
      const d = GuidePillLayout(outline, bounds);
      expect(d.getPositionForChild(const Size(300, 600), size), const Offset(112, 305));
      expect(d.getConstraintsForChild(BoxConstraints.tight(const Size(300, 600))).minWidth, 0);
    });
  });

  const howSet = 'How these are set'; // app_en.arb dayStrainHowSet

  group('GuideStepView', () {
    testWidgets('numbered caption sits above the frame', (t) async {
      // why: the mock-up reads "(2) Scroll down to ... and tap ..." above its
      // phone. Fails if the badge number is wrong, the text is not the step's
      // caption, or the caption is not above the frame.
      await _pump(t, _step(0, GuideAction.tap, n: 2));
      final caption = find.byKey(GuideStepView.captionKey);
      expect(find.descendant(of: caption, matching: find.text('Step caption 2: Time in zones')), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepView.numberKey), matching: find.text('2')), findsOneWidget);
      expect(t.getRect(caption).bottom, lessThanOrEqualTo(t.getRect(find.byKey(_fk)).top + 0.5));
    });

    testWidgets('outline wraps the target; the tap pill sits beside it, not on it', (t) async {
      // why: "yellow outline + tap pill on the target". The pill on top of the
      // label would hide what it points at.
      await _pump(t, _step(0, GuideAction.tap));
      final target = t.getRect(find.text(howSet));
      final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
      final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(skContains(outline, target), isTrue, reason: 'outline $outline must contain target $target');
      expect(pill.overlaps(target), isFalse);
      expect(pill.overlaps(outline.inflate(pill.height)), isTrue, reason: 'pill must be next to the outline');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsNothing, reason: 'no scroll needed here');
    });

    testWidgets('a scrollThenTap step scrolls the target into the frame and shows the scroll marker',
        (t) async {
      // why: step 2 of guide #1. The target starts ~3000 px (4 viewports) below the 780 px
      // phone; without the programmatic scroll it is outside the frame.
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      expect(skContains(t.getRect(find.byKey(_fk)), t.getRect(find.text(howSet))), isTrue,
          reason: 'target must end up inside the frame');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsOneWidget);
      expect(find.byKey(GuideStepView.outlineKey), findsOneWidget);
    });

    testWidgets('the screen inside is skeletonized except the target\'s section; chrome stays', (t) async {
      // why: the point of the feature. 'other card text' must be covered by a
      // bar; the target's own section and the screen title must not be touched.
      await _pump(t, _step(0, GuideAction.tap));
      final state = t.state<SkeletonizeState>(find.byType(Skeletonize));
      final other = _inSkeleton(t, t.getRect(find.text('other card text')));
      final bars = state.paintedShapes.where((s) => s.kind == SkeletonKind.bar);
      expect(bars.any((b) => b.rect.overlaps(other)), isTrue, reason: 'ordinary card text must be covered');

      for (final id in [howSet, 'chart', 'Screen title']) {
        final r = _inSkeleton(t, t.getRect(find.text(id)));
        expect(state.paintedShapes.where((s) => s.rect.overlaps(r)), isEmpty, reason: '"$id" must stay legible');
      }
    });

    testWidgets('an unresolvable target shows a failure INSTEAD of a guide, without throwing', (t) async {
      // why: "unresolved target = typed failure (no silent empty guide)" at the
      // view level: the reader must see that this step is broken.
      await _pump(t, _step(0, GuideAction.tap, target: GuideTarget.label((_) => 'No such label')));
      expect(t.takeException(), isNull);
      expect(find.byKey(GuideStepView.failureKey), findsOneWidget);
      expect(find.byKey(GuideStepView.outlineKey), findsNothing);
      expect(find.byKey(GuideStepView.tapPillKey), findsNothing);
    });

    testWidgets('the tap pill and scroll marker speak the app language', (t) async {
      // why: the markers are strings (new l10n), not hard-coded English.
      String pill(WidgetTester t) => t
          .widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first)
          .data!;
      String marker(WidgetTester t) => t
          .widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first)
          .data!;
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      final (enPill, enMarker) = (pill(t), marker(t));
      await _pump(t, _step(3000, GuideAction.scrollThenTap), locale: const Locale('de'));
      expect(enPill, isNotEmpty);
      expect(enMarker, isNotEmpty);
      expect(pill(t), isNot(enPill));
      expect(marker(t), isNot(enMarker));
    });
  });

  group('GuideStepView markers follow layout (PR 1 review S1)', () {
    testWidgets('a card appearing above the target moves the outline with it', (t) async {
      // why: Skeletonize re-plans after every layout, but the outline and pill
      // were measured once per step. Home inserts and removes a sync-status card
      // above the rings without rebuilding the guide, which left the outline
      // where the ring used to be. The markers must follow the target.
      final extra = ValueNotifier<bool>(false);
      addTearDown(extra.dispose);
      final step = demoStep(
        id: 'moving',
        screen: (_) => Builder(builder: (c) {
          final l = AppLocalizations.of(c)!;
          return Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: extra,
                  builder: (_, on, _) => SizedBox(height: on ? 120 : 0),
                ),
                Section(l.dayStrainTimeInZonesSection, const Surface(child: Text('chart')),
                    action: l.dayStrainHowSet, onAction: () {}),
              ],
            ),
          );
        }),
        target: GuideTarget.label((l) => l.dayStrainHowSet),
        anchor: GuideTarget.label((l) => l.dayStrainTimeInZonesSection),
        action: GuideAction.tap,
        caption: (_) => 'caption',
      );
      await _pump(t, step);
      final l = lookupAppLocalizations(const Locale('en'));
      final targetBefore = t.getRect(find.text(l.dayStrainHowSet));
      final outlineBefore = t.getRect(find.byKey(GuideStepView.outlineKey));

      extra.value = true;
      await t.pumpAndSettle();

      final targetAfter = t.getRect(find.text(l.dayStrainHowSet));
      final outlineAfter = t.getRect(find.byKey(GuideStepView.outlineKey));
      // The screen is drawn scaled down inside the phone frame, so 120 logical
      // px of new content move the target by less than 120 on screen.
      final moved = targetAfter.top - targetBefore.top;
      expect(moved, greaterThan(40), reason: 'control: the target really moved');
      expect(outlineAfter.top - outlineBefore.top, closeTo(moved, 0.5));
      expect(skContains(outlineAfter, targetAfter), isTrue, reason: 'outline $outlineAfter target $targetAfter');
    });
  });

  group('GuideStepView pill placement', () {
    // A screen where legible text sits directly above the target, left-aligned
    // like the target: the old "above the outline" spot lands on that text.
    GuideStep hintAbove() => demoStep(
          id: 'hint-above',
          screen: (_) => Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                ScreenTitle('Screen title'),
                SizedBox(height: 40),
                Align(alignment: Alignment.centerLeft, child: Text('Legible hint line')),
                SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: Pressable(child: Text('Go link'))),
              ],
            ),
          ),
          target: GuideTarget.label((_) => 'Go link'),
          anchor: GuideTarget.label((_) => 'Go link'),
          alsoKeep: [GuideTarget.label((_) => 'Legible hint line')],
          action: GuideAction.tap,
          caption: (_) => 'Tap Go link',
        );

    testWidgets('the tap pill never covers legible text: it goes below when left has no room and above is taken', (t) async {
      // why: guide #1 step 3 - the pill covered the line of text above the link.
      // Deterministic version: the hint is kept legible (alsoKeep) and sits 6 px
      // above the target at the same x. proves: CLAIM(pill-legible), CLAIM(pill-order)
      await _pump(t, hintAbove());
      final frame = t.getRect(find.byKey(_fk));
      final hint = t.getRect(find.text('Legible hint line'));
      final target = t.getRect(find.text('Go link'));
      final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
      final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(hint.bottom, lessThan(target.top), reason: 'fixture sanity: the hint is above the target');
      expect(pill.overlaps(hint), isFalse, reason: 'pill $pill covers the hint $hint');
      expect(pill.overlaps(target), isFalse);
      expect(skContains(frame, pill), isTrue);
      expect(pill.top, greaterThanOrEqualTo(outline.bottom - 2.5), reason: 'left has no room (target at the margin) and above is taken: below');
      // control: without the text knowledge the same layout picks the old spot, onto the hint
      final blind = GuidePillLayout(outline, frame.deflate(7)).place(pill.size);
      expect(blind.overlaps(hint), isTrue, reason: 'positive control: the blind spot $blind covers the hint $hint');
    });

    testWidgets('with nothing legible nearby and room on the left, the pill sits beside the target', (t) async {
      // why: the new first preference. The target is a label pushed to the right
      // of the screen so there is room on its left.
      final step = demoStep(
        id: 'right',
        screen: (_) => Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              ScreenTitle('Screen title'),
              SizedBox(height: 120),
              Align(alignment: Alignment.centerRight, child: Pressable(child: Text('Go link'))),
            ],
          ),
        ),
        target: GuideTarget.label((_) => 'Go link'),
        anchor: GuideTarget.label((_) => 'Go link'),
        action: GuideAction.tap,
        caption: (_) => 'Tap Go link',
      );
      await _pump(t, step);
      final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
      final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(pill.right, closeTo(outline.left + 2, 0.6), reason: 'pill ends 2 px inside the outline, on its left');
      expect(pill.center.dy, closeTo(outline.center.dy, 0.6), reason: 'vertically centred on the outline');
    });
  });

  group('GuideStepView semantics (item 7)', () {
    testWidgets('the caption is announced before anything in the frame; the target once; covered text never',
        (t) async {
      // why: a screen-reader user hears "what to do" first, then the screen. The
      // outline and pills are decoration: they must not repeat the target's
      // label or add context-free "tap" / "scroll" announcements.
      final h = t.ensureSemantics();
      await _pump(t, _step(0, GuideAction.tap, n: 2));
      final labels = skTraversalLabels(t);
      final caption = labels.indexWhere((l) => l.contains('Step caption 2'));
      expect(caption, isNonNegative, reason: 'caption must be announced; got $labels');
      for (final inFrame in [howSet, 'chart']) {
        final i = labels.indexWhere((l) => l.contains(inFrame));
        expect(i, greaterThan(caption), reason: '"$inFrame" must come after the caption; got $labels');
      }
      expect(labels.where((l) => l.contains(howSet)), hasLength(1), reason: 'target label announced exactly once');
      expect(labels.any((l) => l.contains('other card text')), isFalse, reason: 'covered text must not be announced');
      expect(labels.any((l) => l.contains('Screen title')), isTrue, reason: 'chrome stays announced');

      final pill = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first).data!;
      expect(labels.any((l) => l == pill), isFalse, reason: 'the tap pill is decoration, not an announcement');
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });

    testWidgets('the scroll marker is not announced', (t) async {
      // why: "scroll" with no context is noise; the caption already says it.
      final h = t.ensureSemantics();
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      final marker = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first).data!;
      expect(skTraversalLabels(t).any((l) => l == marker), isFalse);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });

    testWidgets('alsoKeep leaves its unit readable (text and semantics)', (t) async {
      // why: step 3 of guide #1 keeps "Your zones" besides the link.
      final h = t.ensureSemantics();
      await _pump(t, _step(0, GuideAction.tap, alsoKeep: [GuideTarget.label((_) => 'other card text')]));
      final state = t.state<SkeletonizeState>(find.byType(Skeletonize));
      final other = _inSkeleton(t, t.getRect(find.text('other card text')));
      expect(state.paintedShapes.where((s) => s.rect.overlaps(other)), isEmpty);
      expect(skTraversalLabels(t).any((l) => l.contains('other card text')), isTrue);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });
  });

  group('GuideView', () {
    GuideStep s(String label) => demoStep(
          id: 'id-$label',
          anchor: GuideTarget.label((_) => label),
          screen: (_) => Scaffold(body: Center(child: Pressable(onTap: () {}, child: Text(label)))),
          target: GuideTarget.label((_) => label),
          action: GuideAction.tap,
          caption: (_) => 'Caption for $label',
        );
    final footers = [
      GuideFooter(title: (_) => 'Another way in', body: (_) => 'Open the Activity tab.'),
      GuideFooter(title: (_) => "Don't see it?", body: (_) => 'Wear the band for a while.'),
    ];

    Future<void> pumpGuide(WidgetTester t, Guide g, BandGeneration? band) async {
      skTallView(t, w: 1200, h: 4000);
      await t.pumpWidget(skHost(Scaffold(body: GuideView(guide: g, band: band))));
      await t.pumpAndSettle();
    }

    testWidgets('shows the title, the steps in order with numbers 1..n, then the footer cards', (t) async {
      // why: spec 2.3: "the steps in order plus footer cards". Order is
      // pinned by tree order AND by numbers, so a reversed list fails.
      final steps = [s('Alpha'), s('Beta'), s('Gamma')];
      final g = Guide(
        start: GuideStart.today,
        id: 'g',
        title: (_) => 'Where to find Alpha',
        variants: [GuideVariant(steps: steps)],
        footers: footers,
      );
      await pumpGuide(t, g, BandGeneration.whoop4);

      expect(find.text('Where to find Alpha'), findsOneWidget);
      final views = t.widgetList<GuideStepView>(find.byType(GuideStepView)).toList();
      expect(views.map((v) => v.number), [1, 2, 3]);
      for (var i = 0; i < 3; i++) {
        expect(views[i].step, same(steps[i]));
      }
      for (final f in ['Another way in', "Don't see it?", 'Open the Activity tab.', 'Wear the band for a while.']) {
        expect(find.text(f), findsOneWidget, reason: f);
      }
      // footers come after the last step
      expect(t.getRect(find.text('Another way in')).top, greaterThan(t.getRect(find.byType(GuideStepView).last).bottom - 1));
    });

    testWidgets('the band picks the variant: WHOOP 5 gets its own, longer path', (t) async {
      // why: separate WHOOP 4 / 5 variants where the path differs (owner).
      final g = Guide(id: 'g', title: (_) => 'T', start: GuideStart.today, variants: [
        GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]),
        GuideVariant(devices: {BandGeneration.whoop5}, steps: [s('Alpha'), s('Beta')]),
      ]);
      await pumpGuide(t, g, BandGeneration.whoop5);
      expect(find.byType(GuideStepView), findsNWidgets(2));
      await pumpGuide(t, g, BandGeneration.whoop4);
      expect(find.byType(GuideStepView), findsOneWidget);
    });

    testWidgets('a guide with no variant for the band says so instead of rendering steps', (t) async {
      // why: "a guide with no variant for the user's band says so".
      final g = Guide(id: 'g', title: (_) => 'T', start: GuideStart.today, variants: [
        GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]),
      ]);
      await pumpGuide(t, g, BandGeneration.whoop5);
      expect(t.takeException(), isNull);
      expect(find.byKey(GuideView.noVariantKey), findsOneWidget);
      expect(find.byType(GuideStepView), findsNothing);
    });
  });
}
