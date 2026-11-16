// GuideStepView / GuideView (test/support: review tooling, never shipped): the demo frame around a skeletonized real screen. The marker rules it shares with the
// live overlay (GuidePillLayout, legibleContent) live in guide_markers.dart. Hand-built screens of real ui2 cards; the real guide #1 is covered in
// guide_heart_rate_zones_test.dart.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/guide_markers.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart'; import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/guide_demo_screens.dart'; import '../support/guide_view.dart'; import '../support/skeleton_fixture.dart'; import '../support/guide_text.dart';
const _fk = GuideStepView.frameKey;
/// A screen: title (chrome), one ordinary card, [gap] of space, then a Section
/// whose ACTION is the target. A big gap pushes the target below the frame.
Widget _screen(double gap) => Builder(builder: (c) { final l = AppLocalizations.of(c)!; return Scaffold( body: ListView(
          padding: const EdgeInsets.all(16), children: [ const ScreenTitle('Screen title', key: ValueKey('screenTitle')),
            const Surface(child: Text('other card text')), SizedBox(height: gap),
            Section(l.dayStrainTimeInZonesSection, const Surface(child: Text('chart')), action: l.dayStrainHowSet, onAction: () {}), ], ), ); });
GuideStep _step(double gap, GuideAction a, {GuideTarget? target, int n = 0, List<GuideTarget> alsoKeep = const []}) => demoStep(
      id: 'step-$n', screen: (_) => _screen(gap), target: target ?? GuideTarget.label(fnText((l) => l.dayStrainHowSet)),
      anchor: GuideTarget.label(fnText((l) => l.dayStrainTimeInZonesSection)), alsoKeep: alsoKeep, action: a,
      caption: fnText((l) => 'Step caption $n: ${l.dayStrainTimeInZonesSection}'), );
Future<void> _pump(WidgetTester t, GuideStep step, {int number = 2, Locale locale = const Locale('en')}) async { skTallView(t);
  await t.pumpWidget(skHost( Scaffold(body: SingleChildScrollView(child: Center(child: GuideStepView(number: number, step: step)))), locale: locale, )); await t.pumpAndSettle(); }
Future<void> _showReviewIndicator(WidgetTester t, {Locale locale = const Locale('en')}) async { final step = demoStep(id: 'indicator',
    screen: (_) => const Scaffold(body: SingleChildScrollView(child: Column(children: [
      Text('Page'), SizedBox(height: 2200), Text('Target', key: ValueKey('review-indicator-target')), SizedBox(height: 1500), ]))),
    target: GuideTarget.key(const ValueKey('review-indicator-target')), anchor: GuideTarget.key(const ValueKey('review-indicator-target')),
    action: GuideAction.scrollThenTap, caption: fnText((_) => 'Tap Target')); await _pump(t, step, locale: locale);
  final scroll = find.descendant(of: find.byType(Skeletonize), matching: find.byType(Scrollable));
  t.state<ScrollableState>(scroll.first).position.jumpTo(0); await t.pump(); await t.pump(); }
Rect _inSkeleton(WidgetTester t, Rect global) { final rb = t.renderObject<RenderBox>(find.byType(Skeletonize));
  return Rect.fromPoints(rb.globalToLocal(global.topLeft), rb.globalToLocal(global.bottomRight)); } void main() { group('GuidePillLayout', () {
    // Frame 300 x 600; pill 40 x 20. Candidate boxes, by hand (S.x2 = ${S.x2}):   above : x = outline.right - 40 - S.x2, y = outline.top - 20 + 2
    //   below : x = same,                      y = outline.bottom - 2 Round 4 (owner): the label is ABOVE its target, below only when above leaves the frame;
    // legible text no longer moves it, and the old "beside, on the left" spot is gone. Hysteresis is covered by guide_r4_test.dart.
    const bounds = Rect.fromLTWH(0, 0, 300, 600); const size = Size(40, 20); test('above, astride the top edge at its right end, when it fits', () {
      // why: CLAIM(pill-above). Room on the left no longer attracts the pill.
      const outline = Rect.fromLTWH(150, 300, 100, 30); final pill = const GuidePillLayout(outline, bounds).place(size);
      expect(pill, Rect.fromLTWH(250 - 40 - S.x2, 282, 40, 20)); // 300 - 20 + 2
    }); test('below only when above leaves the frame', () {
      // why: the one exception. Outline 5 px from the top: above would start at -13.
      const outline = Rect.fromLTWH(20, 5, 100, 30); final pill = const GuidePillLayout(outline, bounds).place(size);
      expect(pill, Rect.fromLTWH(120 - 40 - S.x2, 33, 40, 20)); // 35 - 2
    }); test('with neither side in the frame it is above, pushed inside, never off-screen', () {
      // why: never off-screen, deterministic. A frame shorter than outline + pill.
      const tight = Rect.fromLTWH(0, 0, 300, 30); const outline = Rect.fromLTWH(20, 2, 100, 26); final pill = const GuidePillLayout(outline, tight).place(size);
      expect(tight.contains(pill.topLeft) && tight.contains(pill.bottomRight - const Offset(.01, .01)), isTrue, reason: '$pill'); });
    test('getPositionForChild is the placed box\'s corner and constraints are loose', () {
      // why: the delegate must hand the pill loose constraints (tight ones stretched it over the whole frame once) and use place().
      const outline = Rect.fromLTWH(150, 300, 100, 30); const d = GuidePillLayout(outline, bounds);
      expect(d.getPositionForChild(const Size(300, 600), size), Offset(250 - 40 - S.x2, 282));
      expect(d.getConstraintsForChild(BoxConstraints.tight(const Size(300, 600))).minWidth, 0); }); });
  const howSet = 'How these are set'; // app_en.arb dayStrainHowSet
  group('GuideStepView', () { testWidgets('numbered caption sits above the frame', (t) async {
      // why: the mock-up reads "(2) Scroll down to ... and tap ..." above its phone. Fails if the badge number is wrong, the text is not the step's
      // caption, or the caption is not above the frame.
      await _pump(t, _step(0, GuideAction.tap, n: 2)); final caption = find.byKey(GuideStepView.captionKey);
      expect(find.descendant(of: caption, matching: find.text('Step caption 2: Time in zones')), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepView.numberKey), matching: find.text('2')), findsOneWidget);
      expect(t.getRect(caption).bottom, lessThanOrEqualTo(t.getRect(find.byKey(_fk)).top + 0.5)); });
    testWidgets('outline wraps the target; the tap pill sits beside it, not on it', (t) async {
      // why: "yellow outline + tap pill on the target". The pill on top of the label would hide what it points at.
      await _pump(t, _step(0, GuideAction.tap)); final target = t.getRect(find.text(howSet));
      final outline = t.getRect(find.byKey(GuideStepView.outlineKey)); final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(skContains(outline, target), isTrue, reason: 'outline $outline must contain target $target'); expect(pill.overlaps(target), isFalse);
      expect(pill.overlaps(outline.inflate(pill.height)), isTrue, reason: 'pill must be next to the outline');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsNothing, reason: 'no scroll needed here'); });
    testWidgets('a scrollThenTap step scrolls into the frame and hides the settled indicator', (t) async {
      // why: step 2 of guide #1. The target starts ~3000 px (4 viewports) below the 780 px phone; without the programmatic scroll it is outside the frame.
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      expect(skContains(t.getRect(find.byKey(_fk)), t.getRect(find.text(howSet))), isTrue, reason: 'target must end up inside the frame');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsNothing, reason: 'M1: review and live indicators both hide once the target is visible');
      expect(find.byKey(GuideStepView.outlineKey), findsOneWidget); });
    // WHY: M1 / CLAIM(guide-scroll-indicator): the review uses the same mid-screen component and direction as the live guide, only while the target is hidden.
    testWidgets('M1: review scroll indicator is centred and shares the live component', (t) async { await _showReviewIndicator(t);
      final marker = find.byKey(GuideStepView.scrollMarkerKey); expect(marker, findsOneWidget);
      expect(t.widget(marker), isA<GuideScrollIndicator>()); final frame = t.getRect(find.byKey(_fk)); expect(t.getRect(marker).center.dx, closeTo(frame.center.dx, .01));
      expect(t.getRect(marker).center.dy, closeTo(frame.center.dy, .01)); expect(t.widget<GuideScrollIndicator>(marker).up, isFalse); });
    testWidgets('the screen inside is skeletonized except the target\'s section; chrome stays', (t) async {
      // why: the point of the feature. 'other card text' must be covered by a bar; the target's own section and the screen title must not be touched.
      await _pump(t, _step(0, GuideAction.tap)); final state = t.state<SkeletonizeState>(find.byType(Skeletonize));
      final other = _inSkeleton(t, t.getRect(find.text('other card text'))); final bars = state.paintedShapes.where((s) => s.kind == SkeletonKind.bar);
      expect(bars.any((b) => b.rect.overlaps(other)), isTrue, reason: 'ordinary card text must be covered');
      for (final id in [howSet, 'chart', 'Screen title']) { final r = _inSkeleton(t, t.getRect(find.text(id)));
        expect(state.paintedShapes.where((s) => s.rect.overlaps(r)), isEmpty, reason: '"$id" must stay legible'); } });
    testWidgets('an unresolvable target shows a failure INSTEAD of a guide, without throwing', (t) async {
      // why: "unresolved target = typed failure (no silent empty guide)" at the view level: the reader must see that this step is broken.
      await _pump(t, _step(0, GuideAction.tap, target: GuideTarget.label(fnText((_) => 'No such label'))));
      expect(t.takeException(), isNull); expect(find.byKey(GuideStepView.failureKey), findsOneWidget);
      expect(find.byKey(GuideStepView.outlineKey), findsNothing); expect(find.byKey(GuideStepView.tapPillKey), findsNothing); });
    testWidgets('the tap pill and scroll marker speak the app language', (t) async {
      // why: the markers are strings (new l10n), not hard-coded English.
      String pill(WidgetTester t) => t .widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first) .data!;
      String marker(WidgetTester t) => t .widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first) .data!;
      await _pump(t, _step(0, GuideAction.tap)); final enPill = pill(t);
      await _pump(t, _step(0, GuideAction.tap), locale: const Locale('de')); expect(pill(t), isNot(enPill)); await _showReviewIndicator(t);
      final enMarker = marker(t); await _showReviewIndicator(t, locale: const Locale('de')); expect(marker(t), isNot(enMarker)); }); });
  group('GuideStepView markers follow layout (PR 1 review S1)', () { testWidgets('a card appearing above the target moves the outline with it', (t) async {
      // why: Skeletonize re-plans after every layout, but the outline and pill were measured once per step. Home inserts and removes a sync-status card
      // above the rings without rebuilding the guide, which left the outline where the ring used to be. The markers must follow the target.
      final extra = ValueNotifier<bool>(false); addTearDown(extra.dispose); final step = demoStep( id: 'moving',
        screen: (_) => Builder(builder: (c) { final l = AppLocalizations.of(c)!; return Scaffold( body: ListView(
              padding: const EdgeInsets.all(16), children: [ ValueListenableBuilder<bool>( valueListenable: extra, builder: (_, on, _) => SizedBox(height: on ? 120 : 0), ),
                Section(l.dayStrainTimeInZonesSection, const Surface(child: Text('chart')), action: l.dayStrainHowSet, onAction: () {}), ],
            ), ); }), target: GuideTarget.label(fnText((l) => l.dayStrainHowSet)),
        anchor: GuideTarget.label(fnText((l) => l.dayStrainTimeInZonesSection)), action: GuideAction.tap, caption: fnText((_) => 'caption'),
      ); await _pump(t, step); final l = lookupAppLocalizations(const Locale('en'));
      final targetBefore = t.getRect(find.text(l.dayStrainHowSet)); final outlineBefore = t.getRect(find.byKey(GuideStepView.outlineKey));
      extra.value = true; await t.pumpAndSettle();
      final targetAfter = t.getRect(find.text(l.dayStrainHowSet)); final outlineAfter = t.getRect(find.byKey(GuideStepView.outlineKey));
      // The screen is drawn scaled down inside the phone frame, so 120 logical px of new content move the target by less than 120 on screen.
      final moved = targetAfter.top - targetBefore.top; expect(moved, greaterThan(40), reason: 'control: the target really moved');
      expect(outlineAfter.top - outlineBefore.top, closeTo(moved, 0.5));
      expect(skContains(outlineAfter, targetAfter), isTrue, reason: 'outline $outlineAfter target $targetAfter'); }); }); group('GuideStepView pill placement', () {
    // A screen where legible text sits directly above the target, left-aligned like the target: the old "above the outline" spot lands on that text.
    GuideStep hintAbove() => demoStep( id: 'hint-above', screen: (_) => Scaffold( body: ListView( padding: const EdgeInsets.all(16),
              children: const [ ScreenTitle('Screen title'), SizedBox(height: 40), Align(alignment: Alignment.centerLeft, child: Text('Legible hint line')), SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: Pressable(child: Text('Go link'))), ], ), ),
          target: GuideTarget.label(fnText((_) => 'Go link')), anchor: GuideTarget.label(fnText((_) => 'Go link')),
          alsoKeep: [GuideTarget.label(fnText((_) => 'Legible hint line'))], action: GuideAction.tap, caption: fnText((_) => 'Tap Go link'), );
    testWidgets('the tap pill stays above the target even over a legible line (round 4)', (t) async {
      // why: guide #1 step 3 had a hint line right above the link. The pill used to dodge it (and jumped between steps); the owner's rule is one place: above. It never covers the
      // target and stays in the frame. proves: CLAIM(pill-above)
      await _pump(t, hintAbove()); final frame = t.getRect(find.byKey(_fk)); final hint = t.getRect(find.text('Legible hint line'));
      final target = t.getRect(find.text('Go link')); final outline = t.getRect(find.byKey(GuideStepView.outlineKey)); final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(hint.bottom, lessThan(target.top), reason: 'fixture sanity: the hint is above the target');
      expect(pill.overlaps(target), isFalse); expect(skContains(frame, pill), isTrue); expect(pill.bottom, closeTo(outline.top + 2, .6), reason: 'above, astride the top edge'); });
    testWidgets('with room on the left, the pill still sits above the target', (t) async {
      // why: the old first preference (beside, on the left) is gone. The target is a label pushed to the right of the screen so there is room on its left.
      final step = demoStep( id: 'right', screen: (_) => Scaffold( body: ListView( padding: const EdgeInsets.all(16), children: const [
              ScreenTitle('Screen title'), SizedBox(height: 120), Align(alignment: Alignment.centerRight, child: Pressable(child: Text('Go link'))), ], ), ),
        target: GuideTarget.label(fnText((_) => 'Go link')), anchor: GuideTarget.label(fnText((_) => 'Go link')), action: GuideAction.tap,
        caption: fnText((_) => 'Tap Go link'), ); await _pump(t, step); final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
      final pill = t.getRect(find.byKey(GuideStepView.tapPillKey)); expect(pill.bottom, closeTo(outline.top + 2, 0.6), reason: 'pill ends 2 px inside the outline, above it');
      expect(pill.right, lessThanOrEqualTo(outline.right + .6)); }); }); group('GuideStepView semantics (item 7)', () {
    testWidgets('the caption is announced before anything in the frame; the target once; covered text never', (t) async {
      // why: a screen-reader user hears "what to do" first, then the screen. The outline and pills are decoration: they must not repeat the target's
      // label or add context-free "tap" / "scroll" announcements.
      final h = t.ensureSemantics(); await _pump(t, _step(0, GuideAction.tap, n: 2)); final labels = skTraversalLabels(t);
      final caption = labels.indexWhere((l) => l.contains('Step caption 2'));
      expect(caption, isNonNegative, reason: 'caption must be announced; got $labels'); for (final inFrame in [howSet, 'chart']) {
        final i = labels.indexWhere((l) => l.contains(inFrame)); expect(i, greaterThan(caption), reason: '"$inFrame" must come after the caption; got $labels'); }
      expect(labels.where((l) => l.contains(howSet)), hasLength(1), reason: 'target label announced exactly once');
      expect(labels.any((l) => l.contains('other card text')), isFalse, reason: 'covered text must not be announced');
      expect(labels.any((l) => l.contains('Screen title')), isTrue, reason: 'chrome stays announced');
      final pill = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first).data!;
      expect(labels.any((l) => l == pill), isFalse, reason: 'the tap pill is decoration, not an announcement');
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose(); }); testWidgets('the scroll marker is not announced', (t) async {
      // why: "scroll" with no context is noise; the caption already says it.
      final h = t.ensureSemantics(); await _showReviewIndicator(t);
      final marker = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first).data!;
      expect(skTraversalLabels(t).any((l) => l == marker), isFalse);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose(); }); testWidgets('alsoKeep leaves its unit readable (text and semantics)', (t) async {
      // why: step 3 of guide #1 keeps "Your zones" besides the link.
      final h = t.ensureSemantics(); await _pump(t, _step(0, GuideAction.tap, alsoKeep: [GuideTarget.label(fnText((_) => 'other card text'))]));
      final state = t.state<SkeletonizeState>(find.byType(Skeletonize)); final other = _inSkeleton(t, t.getRect(find.text('other card text')));
      expect(state.paintedShapes.where((s) => s.rect.overlaps(other)), isEmpty); expect(skTraversalLabels(t).any((l) => l.contains('other card text')), isTrue);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose(); }); }); group('GuideView', () { GuideStep s(String label) => demoStep( id: 'id-$label', anchor: GuideTarget.label(fnText((_) => label)),
          screen: (_) => Scaffold(body: Center(child: Pressable(onTap: () {}, child: Text(label)))),
          target: GuideTarget.label(fnText((_) => label)), action: GuideAction.tap, caption: fnText((_) => 'Caption for $label'), ); final footers = [
      GuideFooter(kind: GuideFooterKind.anotherWay, title: fnText((_) => 'Another way in'), body: fnText((_) => 'Open the Activity tab.')),
      GuideFooter(kind: GuideFooterKind.missingTarget, title: fnText((_) => "Don't see it?"), body: fnText((_) => 'Wear the band for a while.')), ];
    Future<void> pumpGuide(WidgetTester t, Guide g, BandGeneration? band) async { skTallView(t, w: 1200, h: 4000);
      await t.pumpWidget(skHost(Scaffold(body: GuideView(guide: g, band: band)))); await t.pumpAndSettle(); }
    testWidgets('shows the title, the steps in order with numbers 1..n, then the footer cards', (t) async {
      // why: spec 2.3: "the steps in order plus footer cards". Order is pinned by tree order AND by numbers, so a reversed list fails.
      final steps = [s('Alpha'), s('Beta'), s('Gamma')]; final g = Guide( start: GuideStart.today, id: 'g',
        title: fnText((_) => 'Where to find Alpha'), variants: [GuideVariant(steps: steps)], footers: footers, ); await pumpGuide(t, g, BandGeneration.whoop4);
      expect(find.text('Where to find Alpha'), findsOneWidget);
      final views = t.widgetList<GuideStepView>(find.byType(GuideStepView)).toList(); expect(views.map((v) => v.number), [1, 2, 3]);
      for (var i = 0; i < 3; i++) { expect(views[i].step, same(steps[i])); }
      for (final f in ['Another way in', "Don't see it?", 'Open the Activity tab.', 'Wear the band for a while.']) { expect(find.text(f), findsOneWidget, reason: f); }
      // footers come after the last step
      expect(t.getRect(find.text('Another way in')).top, greaterThan(t.getRect(find.byType(GuideStepView).last).bottom - 1)); });
    testWidgets('the band picks the variant: WHOOP 5 gets its own, longer path', (t) async {
      // why: separate WHOOP 4 / 5 variants where the path differs (owner).
      final g = Guide(id: 'g', title: fnText((_) => 'T'), start: GuideStart.today, variants: [ GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]),
        GuideVariant(devices: {BandGeneration.whoop5}, steps: [s('Alpha'), s('Beta')]), ]); await pumpGuide(t, g, BandGeneration.whoop5);
      expect(find.byType(GuideStepView), findsNWidgets(2)); await pumpGuide(t, g, BandGeneration.whoop4); expect(find.byType(GuideStepView), findsOneWidget); });
    testWidgets('a guide with no variant for the band says so instead of rendering steps', (t) async {
      // why: "a guide with no variant for the user's band says so".
      final g = Guide(id: 'g', title: fnText((_) => 'T'), start: GuideStart.today, variants: [
        GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]), ]); await pumpGuide(t, g, BandGeneration.whoop5);
      expect(t.takeException(), isNull); expect(find.byKey(GuideView.noVariantKey), findsOneWidget); expect(find.byType(GuideStepView), findsNothing); }); }); }
