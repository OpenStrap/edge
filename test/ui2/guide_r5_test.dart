// Guides round 5 (owner, 2026-11-15, phone screenshots of APK 4ccf169d): markers in the wrong place, the scroll indicator's hand, the card's Exit.
//
// Spec: edge.research/guides/spec-r2-dim-and-card.md, "Round 5" items 1, 2 and 5. (Items 3, 4 and 7 run on the real pages: guide_r5_scenes_test.dart.)
// Real stage (test/support/live_guide_stage.dart), real scroll physics, real frame clock.
//
// DIAGNOSIS (edge.research/guides/r2-green-report.md, "Round 5 diagnosis and red"):  * 1a: the target is measured against the SCREEN, not the visible area (r4 review C4).
//  * 1b: _boundsOf takes ANY wide SubTabs whose top is below mid-screen for the bottom tab bar, so
//    on Alarm the day row shrinks the card bounds to end above itself, and the pill (clamped    into the bounds) lands at the bottom of them, far from the Wake time outline.
import '../support/live_guide_focus.dart'; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart'; import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart' show surfaceBeneath; import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/guide_text.dart'; import '../support/live_guide_stage.dart'; import '../support/skeleton_fixture.dart'; final _en = lookupAppLocalizations(const Locale('en'));
const _chevronKey = ValueKey('guide-live-scroll-chevron');
const _navKey = stageDetailsTitle; // the anchor of the stage guide's second step
/// A page shaped like the owner's shot 1: a NavBar, then a scrolling list with rows above the target.
/// [navBar] false draws edge to edge (the status bar is the only chrome).
class _ListPage extends StatelessWidget { final StageTaps taps; final ScrollController controller; final bool navBar;
  const _ListPage(this.taps, this.controller, {this.navBar = true});
  @override Widget build(BuildContext context) { final rows = Column(children: [ if (!navBar) const SizedBox(key: _navKey, height: 1),
      for (var i = 0; i < 3; i++) SizedBox(height: 100, child: Surface(child: Text('Row $i'))),
      Pressable(key: stageFinish, onTap: () => taps.finish++, child: const Surface(child: Text('Discard'))),
      for (var i = 3; i < 12; i++) SizedBox(height: 100, child: Surface(child: Text('Row $i'))), ]); return Scaffold( body: navBar
          ? SafeArea(child: Column(children: [ const NavBar('Review activities · 3', key: _navKey),
              Expanded(child: SingleChildScrollView(controller: controller, padding: const EdgeInsets.all(16), child: rows)), ]))
          : SingleChildScrollView(controller: controller, child: rows), ); } }
/// A page shaped like the owner's shot 2 (Alarm): a NavBar, two tall cards, the weekday row (a SubTabs
/// whose top lies BELOW mid-screen), then an accordion that holds the target. [open] drives the accordion.
class _AlarmShapedPage extends StatelessWidget { final StageTaps taps; final ValueNotifier<bool> open; const _AlarmShapedPage(this.taps, this.open);
  @override Widget build(BuildContext context) => Scaffold( body: SafeArea(child: Column(children: [ const NavBar('Alarm', key: _navKey),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(children: [
        const SizedBox(height: 200, width: double.infinity, child: Surface(child: Text('NEXT'))), const SizedBox(height: 12),
        const SizedBox(height: 110, width: double.infinity, child: Surface(child: Text('The band has this alarm'))),
        const SizedBox(height: 12), SubTabs(const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], 0, (_) {}), const SizedBox(height: 12),
        Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text('Alarm and wake'),
          ValueListenableBuilder<bool>(valueListenable: open, builder: (_, isOpen, _) => AnimatedSize(
            duration: const Duration(milliseconds: 300), alignment: Alignment.topCenter, child: isOpen
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const SizedBox(height: 12), const Text('Alarm  On'), const SizedBox(height: 12),
                    Pressable(key: stageFinish, onTap: () => taps.finish++, child: const Text('Wake time  13:45')),
                    const SizedBox(height: 12), const Text('Natural Wake'), ]) : const SizedBox(width: double.infinity), )), ])), const SizedBox(height: 400), ]))), ])), ); }
/// A page whose NavBar is re-keyed when [keyed] flips: a new element subtree under the same page.
class _RekeyPage extends StatelessWidget { final StageTaps taps; final ValueNotifier<bool> keyed; const _RekeyPage(this.taps, this.keyed);
  @override Widget build(BuildContext context) => ValueListenableBuilder<bool>(valueListenable: keyed, builder: (_, k, _) => Scaffold(
    body: SafeArea(child: Column(children: [ NavBar('Review activities', key: k ? const ValueKey('r5-rekeyed') : _navKeyStable),
      Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [ for (var i = 0; i < 4; i++) const SizedBox(height: 90, child: Surface(child: Text('Row'))),
        Pressable(key: stageFinish, onTap: () => taps.finish++, child: const Surface(child: Text('Discard'))), ])), ])), )); }
// The stage guide anchors on this key until the NavBar is re-keyed (the anchor then resolves by the run's memory).
const _navKeyStable = stageDetailsTitle;
/// A page with the target [gap] pixels down a scrolling body (for the scroll indicator).
class _FarPage extends StatelessWidget { final StageTaps taps; const _FarPage(this.taps);
  @override Widget build(BuildContext context) => Scaffold( body: SafeArea(child: Column(children: [ const NavBar('Stage details', key: _navKey),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(children: [ const SizedBox(height: 1400),
        Pressable(key: stageFinish, onTap: () => taps.finish++, child: const Surface(child: Text('Finish'))), const SizedBox(height: 1600), ]))), ])), ); }
Future<void> _settle(WidgetTester t) async { await t.pump(); await t.pump(); await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50)); await t.pump(); }
/// The stage on Home with the two-step guide, then [page] pushed and settled.
Future<LiveStage> _arrive(WidgetTester t, Widget Function(StageTaps) page) async {
  final stage = await pumpLiveStage(t, guide: stageGuide()); await _settle(t); await pushStagePage(t, stage, page(stage.taps)); await _settle(t); return stage; }
final _outline = liveGuideFocus; final _pill = find.byKey(LiveGuideOverlay.tapPillKey); final _indicator = find.byKey(LiveGuideOverlay.scrollMarkerKey);
/// null when the pill sits against its own outline (above or below it), else why not.
String? _pillAgainstOutline(WidgetTester t) { final outline = t.getRect(_outline), pill = t.getRect(_pill);
  final above = (pill.bottom - outline.top + 8).abs() <= 3, below = (pill.top - outline.bottom - 8).abs() <= 3;
  if (!above && !below) return 'pill $pill is not against its outline $outline';
  if (pill.right > outline.right + .5 || pill.left < outline.left - .5) return 'pill $pill is beside, not on, its outline $outline'; return null; }
void main() { group('R5-1a a target under the top chrome is out of view', () {
    // WHY: spec Round 5 item 1a (shot 1). The outline was drawn over the status bar and the app bar:
    // the first Discard had been scrolled up under the NavBar, and "out of view" was measured against
    // the screen (r4 review C4). A target whose rect lies under the app bar or the status bar counts
    // as OUT of view: no outline, no "tap" label, and the scroll indicator points up. CLAIM(out-of-view-is-visible-area).
    // catches: measuring against the screen; an outline over chrome; a pill over the list's first row.
    Future<(LiveStage, ScrollPosition)> arrive(WidgetTester t, {bool navBar = true}) async { final controller = ScrollController();
      addTearDown(controller.dispose); final stage = await _arrive(t, (taps) => _ListPage(taps, controller, navBar: navBar)); return (stage, controller.position); }
    Rect chrome(WidgetTester t, {required bool navBar}) => navBar ? t.getRect(find.byType(NavBar)) : const Offset(0, 0) & const Size(390, 60);
    // Moves the list so that the target's bottom edge is [under] px below the chrome's bottom edge (negative: wholly under the chrome).
    Future<void> scrollTo(WidgetTester t, ScrollPosition p, Rect bar, double bottomAt) async {
      p.jumpTo(p.pixels + t.getRect(find.byKey(stageFinish)).bottom - bottomAt); await t.pump(); await t.pump(); await t.pump(const Duration(milliseconds: 100)); }
    for (final navBar in [true, false]) { final what = navBar ? 'the NavBar' : 'the status bar';
      testWidgets('R5-1a: with the target in view it is outlined and labelled (control, $what)', (t) async {
        if (!navBar) t.view.padding = const FakeViewPadding(top: 60); if (!navBar) t.view.viewPadding = const FakeViewPadding(top: 60);
        addTearDown(t.view.resetPadding); addTearDown(t.view.resetViewPadding); await arrive(t, navBar: navBar);
        expect(_outline, findsOneWidget); expect(_pill, findsOneWidget); expect(_indicator, findsNothing); });
      testWidgets('R5-1a: a target wholly under $what has no outline and no label, and the indicator points up', (t) async {
        if (!navBar) t.view.padding = const FakeViewPadding(top: 60); if (!navBar) t.view.viewPadding = const FakeViewPadding(top: 60);
        addTearDown(t.view.resetPadding); addTearDown(t.view.resetViewPadding); final (_, position) = await arrive(t, navBar: navBar);
        final bar = chrome(t, navBar: navBar); await scrollTo(t, position, bar, bar.bottom - 2); final target = t.getRect(find.byKey(stageFinish));
        expect(target.bottom, lessThanOrEqualTo(bar.bottom), reason: 'fixture: the target lies under $what: $target vs $bar');
        expect(target.bottom, greaterThan(0), reason: 'fixture: and is still on the screen');
        expect(_outline, findsNothing, reason: 'an outline over $what'); expect(_pill, findsNothing, reason: 'a "tap" label over the list');
        expect(_indicator, findsOneWidget, reason: 'the way to the target is up');
        expect(find.descendant(of: _indicator, matching: find.byIcon(LucideIcons.chevronUp)), findsOneWidget); });
      testWidgets('R5-1a: a target half under $what is not fully in view either', (t) async {
        if (!navBar) t.view.padding = const FakeViewPadding(top: 60); if (!navBar) t.view.viewPadding = const FakeViewPadding(top: 60);
        addTearDown(t.view.resetPadding); addTearDown(t.view.resetViewPadding); final (_, position) = await arrive(t, navBar: navBar);
        final bar = chrome(t, navBar: navBar); final height = t.getRect(find.byKey(stageFinish)).height;
        await scrollTo(t, position, bar, bar.bottom + height / 2); final target = t.getRect(find.byKey(stageFinish));
        expect(target.top, lessThan(bar.bottom), reason: 'fixture: the top half is under $what'); expect(_outline, findsNothing);
        expect(_pill, findsNothing); expect(_indicator, findsOneWidget); }); }
    // WHY: spec Round 5 item 4 / the owner's shot 1: with the first Discard scrolled up under the NavBar, the
    // NavBar's title and back arrow were dimmed. Chrome is never dimmed (P4), whatever is scrolled under it.
    // catches: a unit whose visible box reaches into the bar, or a plan that dims what the bar holds.
    testWidgets('R5-4f: with the target scrolled under the NavBar, the NavBar is not dimmed', (t) async {
      final controller = ScrollController(); addTearDown(controller.dispose); await _arrive(t, (taps) => _ListPage(taps, controller)); final bar = t.getRect(find.byType(NavBar));
      controller.position.jumpTo(controller.position.pixels + t.getRect(find.byKey(stageFinish)).bottom - (bar.bottom - 2)); await t.pump();
      await t.pump(); await t.pump(const Duration(milliseconds: 100)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(bar.deflate(1))), isEmpty, reason: 'a dim or placeholder shape reaches into the NavBar');
      final looks = GuideDimScope.controllerOf(t.element(find.byType(NavBar)))!.looks!;
      final back = t.element(find.descendant(of: find.byType(NavBar), matching: find.byType(Pressable)).first);
      expect(looks.lookOf(back), isNull); final title = t.renderObject<RenderParagraph>(find.text('Review activities · 3'));
      expect((looks as GuideLooseLooks).looseLookOf(title), isNull, reason: 'the title is dimmed'); });
    // WHY: a fix that treats "under chrome" by hiding every marker would pass the tests above. This pins that scrolling the target back to the visible area brings the marker back.
    testWidgets('R5-1a: scrolled back into the visible area, the outline and the label return', (t) async {
      final (_, position) = await arrive(t); final bar = chrome(t, navBar: true); await scrollTo(t, position, bar, bar.bottom - 2);
      expect(_outline, findsNothing); await scrollTo(t, position, bar, 300); expect(_outline, findsOneWidget);
      expect(t.getRect(_outline).top, greaterThanOrEqualTo(bar.bottom)); expect(_pill, findsOneWidget); expect(_indicator, findsNothing); }); });
  group('R5-1b the label is always against its own outline', () {
    // WHY: spec Round 5 item 1b (shot 2). On Alarm the "tap" label sat ~360 px above the Wake time
    // outline: the weekday row (SubTabs) lies below mid-screen, so _boundsOf counted it as the bottom
    // tab bar, cut the card bounds above it, and the label (clamped into the bounds) went to their bottom edge. The label's x still followed Wake time, its y followed the bounds.
    // CLAIM(pill-against-outline): the pill is adjacent to its own outline in every frame.
    // catches: bounds shrunk by mid-page chrome; stale hysteresis; a stale rect after an accordion opens.
    testWidgets('R5-1b: with a weekday row below mid-screen, the label is against the Wake time outline', (t) async {
      final open = ValueNotifier(true); addTearDown(open.dispose); await _arrive(t, (taps) => _AlarmShapedPage(taps, open)); final row = t.getRect(find.byType(SubTabs));
      expect(row.top, greaterThan(780 / 2), reason: 'fixture: the weekday row lies below mid-screen like the owner\'s: $row');
      expect(t.getRect(find.byKey(stageFinish)).top, greaterThan(row.bottom), reason: 'fixture: Wake time is under the row');
      expect(_outline, findsOneWidget); expect(_pill, findsOneWidget); expect(_pillAgainstOutline(t), isNull); });
    testWidgets('R5-1b: with the accordion opening on arrival, the label is against the outline in every frame', (t) async {
      final open = ValueNotifier(false); addTearDown(open.dispose); await _arrive(t, (taps) => _AlarmShapedPage(taps, open));
      expect(_outline, findsNothing, reason: 'fixture: the target is not built while the accordion is shut'); open.value = true;
      final violations = <String>[]; var seen = 0; for (var i = 0; i < 60; i++) { await t.pump(const Duration(milliseconds: 16));
        if (_outline.evaluate().isEmpty || _pill.evaluate().isEmpty) continue; seen++;
        if (_pillAgainstOutline(t) case final why?) violations.add('frame $i: $why'); } await _settle(t);
      expect(_outline, findsOneWidget, reason: 'the target is outlined once the accordion is open'); expect(seen, greaterThan(0), reason: 'the label was on screen in some frame');
      expect(_pillAgainstOutline(t), isNull, reason: 'after settling'); expect(violations, isEmpty, reason: 'the label left its outline in ${violations.length} frames'); }); });
  group('R5-4 chrome built after the plan', () {
    // WHY: spec Round 5 item 4 (owner screen unknown, so fixed by design). A NavBar that a rebuild
    // re-keys (the review page does it when reviewing starts) is a NEW element the plan has never seen,
    // and an unseen component fell back to the dim / placeholder look until the next plan. The OLD plan
    // must say nothing about it: chrome is never covered, however new. CLAIM(chrome-never-covered).
    // catches: GuidePlan._unseen without a chrome exemption.
    testWidgets('R5-4e: the old plan leaves a re-keyed NavBar and its back arrow lit', (t) async { final keyed = ValueNotifier(false);
      addTearDown(keyed.dispose); await _arrive(t, (taps) => _RekeyPage(taps, keyed));
      final ctl = GuideDimScope.controllerOf(t.element(find.byType(NavBar)))!; final old = ctl.looks;
      expect(old, isNotNull, reason: 'fixture: a plan is in force'); final before = t.element(find.byType(NavBar)); keyed.value = true;
      await t.pump(); final bar = t.element(find.byType(NavBar)); expect(identical(bar, before), isFalse, reason: 'fixture: the NavBar is a new element');
      final back = find.descendant(of: find.byType(NavBar), matching: find.byType(Pressable)).first;
      expect(old!.lookOf(t.element(back)), isNull, reason: 'the old plan covers a NavBar it has not seen'); }); }); group('R5-7 the veil over loose text', () {
    // WHY: owner round 5 item 7: a dark box behind "1 staged". A dim over loose text must be the colour
    // of what is drawn beneath the text, with the Opacity above each box (a disabled button is drawn at 40%), or the veil shows as a box. CLAIM(dim-has-no-box).
    // catches: a scaffold-coloured veil; ignoring Opacity; ignoring the box order.
    testWidgets('R5-7: surfaceBeneath blends the boxes around a text, outermost first, under each Opacity', (t) async { const card = Color(0xFF102030), wash = Color(0xFF804020);
      await t.pumpWidget(skHost(Container(decoration: const BoxDecoration(color: card), child: Opacity(opacity: .5,
        child: Container(decoration: const BoxDecoration(color: wash), child: const Text('Cancel'))))));
      final paragraph = t.renderObject<RenderParagraph>(find.text('Cancel')); const scaffold = Color(0xFFF8FAFC); final got = surfaceBeneath(paragraph, scaffold);
      // card over the scaffold (opaque), then the wash at 50% over that.
      final want = Color.alphaBlend(wash.withValues(alpha: .5), Color.alphaBlend(card, scaffold));
      expect([got.r, got.g, got.b].map((x) => (x * 255).round()), [want.r, want.g, want.b].map((x) => (x * 255).round()));
      // and a text on nothing at all is on the scaffold itself.
      await t.pumpWidget(skHost(const Text('Loose')));
      expect(surfaceBeneath(t.renderObject<RenderParagraph>(find.text('Loose')), scaffold), isNot(const Color(0x00000000))); }); });
  group('R5-2 the scroll indicator\'s hand nudges, the chevron stands still', () {
    // WHY: spec Round 5 item 2. The HAND moves, on the tap hand's clock and curve (two nudges per
    // 1.6 s cycle), in the scroll direction; the chevron is static. Reduced motion: static.
    // CLAIM(scroll-hand-nudges). Asserts the design (what moves, how far, which way), not frame counts.
    // catches: a moving chevron; a still hand; a nudge against the scroll direction; a different curve.
    Future<List<double>> trace(WidgetTester t, Finder f, {int frames = 200}) async { final ys = <double>[];
      for (var i = 0; i < frames; i++) { await t.pump(const Duration(milliseconds: 16)); ys.add(t.getRect(f).center.dy); } return ys; }
    Future<ScrollPosition> arriveFar(WidgetTester t) async { await _arrive(t, (taps) => _FarPage(taps));
      final position = t.state<ScrollableState>(find.descendant(of: find.byType(_FarPage), matching: find.byType(Scrollable)).first).position;
      for (var i = 0; i < 60; i++) { await t.pump(const Duration(milliseconds: 16)); } await _settle(t); return position; }
    final indicatorHand = find.descendant(of: _indicator, matching: find.byIcon(LucideIcons.hand));
    final indicatorChevron = find.descendant(of: _indicator, matching: find.byKey(_chevronKey)); for (final below in [true, false]) {
      testWidgets('R5-2: with the target ${below ? 'below' : 'above'} the hand nudges ${below ? 'down' : 'up'} and the chevron is still', (t) async {
        final position = await arriveFar(t); position.jumpTo(below ? 0 : position.maxScrollExtent); await t.pump(); await t.pump(); expect(_indicator, findsOneWidget);
        expect(find.descendant(of: _indicator, matching: find.byIcon(below ? LucideIcons.chevronDown : LucideIcons.chevronUp)), findsOneWidget);
        final hand = await trace(t, indicatorHand); final chevron = await trace(t, indicatorChevron); final counts = <double, int>{};
        for (final y in hand) { counts.update((y * 10).round() / 10, (n) => n + 1, ifAbsent: () => 1); }
        final rest = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key; final far = hand.reduce((a, b) => (a - rest).abs() > (b - rest).abs() ? a : b);
        expect((far - rest).abs(), inInclusiveRange(2, 8), reason: 'a small nudge of the hand'); expect(far > rest, below, reason: 'the hand nudges toward the target');
        expect(chevron.toSet(), hasLength(1), reason: 'the chevron stands still: ${chevron.toSet()}');
        // The tap hand's curve: two pushes per 1.6 s cycle, still for the second half.
        var rises = 0; final level = rest + .6 * (far - rest); for (var i = 1; i < hand.length; i++) {
          final over = below ? (double v) => v >= level : (double v) => v <= level; if (!over(hand[i - 1]) && over(hand[i])) rises++; }
        expect(rises, inInclusiveRange(3, 5), reason: 'two nudges per 1.6 s over 3.2 s'); }); }
    testWidgets('R5-2: under reduced motion the hand and the chevron are still', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); final position = await arriveFar(t); position.jumpTo(0);
      await t.pump(); await t.pump(); expect(_indicator, findsOneWidget); expect((await trace(t, indicatorHand, frames: 120)).toSet(), hasLength(1));
      expect((await trace(t, indicatorChevron, frames: 120)).toSet(), hasLength(1)); }); }); group('R5-5 Exit', () {
    // WHY: spec Round 5 item 5. Exit is in ONE place in every card state (bottom row, right edge)
    // and in the accent colour, not grey. The off-path card (shot 3) and the Done card put it at the
    // left, under the text; the step card puts it at the right. CLAIM(exit-one-place).
    // catches: a row whose only action sits at the start; a content-dependent position; grey ink.
    final footer = GuideFooter(kind: GuideFooterKind.missingTarget, title: fnText((_) => 'Not here?'), body: fnText((_) => 'It only shows later.'));
    final models = <String, (GuideCardModel, bool)>{ 'step': (GuideCardOnStep(number: 2, total: 3, caption: 'Tap **Finish** at the bottom.', missingHelp: footer), true),
      'step without help': (const GuideCardOnStep(number: 2, total: 3, caption: 'Tap **Finish** at the bottom.'), true),
      'off path with Back to the guide': (const GuideCardOffPath(tapsBack: 1), true),
      'off path without Back to the guide': (const GuideCardOffPath(tapsBack: 1), false), 'done': (GuideCardDone([footer]), true), };
    Future<({Rect card, Rect exit, Color? ink})> pumpCard(WidgetTester t, GuideCardModel model, {required bool withBack, bool expand = false}) async {
      skTallView(t, w: 390, h: 780); await t.pumpWidget(skHost(Align(alignment: Alignment.bottomCenter,
        child: SizedBox(width: 358, child: GuideStepCard(model: model, onExit: () {}, onBackToGuide: withBack ? () {} : null)))));
      await t.pump(); if (expand) { await t.tap(find.byKey(GuideStepCard.dontSeeItKey)); await t.pump(); }
      final text = find.descendant(of: find.byKey(GuideStepCard.exitKey), matching: find.text(_en.guideExit));
      return (card: t.getRect(find.byKey(GuideStepCard.cardKey)), exit: t.getRect(find.byKey(GuideStepCard.exitKey)), ink: t.widget<Text>(text).style?.color); }
    testWidgets('R5-5: Exit sits at the same place in the card (bottom row, right) in every state', (t) async { final offsets = <String, Offset>{};
      for (final e in [...models.entries.map((e) => (e.key, e.value.$1, e.value.$2, false)), ('step, Don\'t see it? open', models['step']!.$1, true, true)]) {
        final m = await pumpCard(t, e.$2, withBack: e.$3, expand: e.$4);
        offsets[e.$1] = Offset(m.card.right - m.exit.right, m.card.bottom - m.exit.bottom); } final first = offsets.values.first; for (final e in offsets.entries) {
        expect((e.value - first).distance, lessThan(.5), reason: '"${e.key}": Exit is ${e.value} from the card\'s bottom right, the step card\'s is $first: $offsets');
      } expect(first.dx, lessThanOrEqualTo(S.x4 + 1), reason: 'at the right edge, inside the card\'s padding'); });
    testWidgets('R5-5: Exit is in the accent colour in every state, not grey', (t) async { for (final e in models.entries) {
        final m = await pumpCard(t, e.value.$1, withBack: e.value.$2); final p = P.of(t.element(find.byKey(GuideStepCard.cardKey)));
        expect(m.ink, p.on(C.blue), reason: '"${e.key}": Exit uses the accent the card\'s other links use'); expect(m.ink, isNot(p.ink2), reason: '"${e.key}": not grey'); } });
    // WHY: CLS. Opening "Don't see it?" grows the card; Exit must not move on the screen.
    // catches: a card that grows downward, or from the top, pushing Exit.
    testWidgets('R5-5: opening "Don\'t see it?" on the overlay does not move Exit', (t) async { await pumpLiveStage(t); await _settle(t);
      final before = t.getRect(find.byKey(GuideStepCard.exitKey)); await t.tap(find.byKey(GuideStepCard.dontSeeItKey)); await _settle(t);
      expect(find.byKey(GuideStepCard.missingHelpKey), findsOneWidget, reason: 'fixture: the help is open');
      expect(t.getRect(find.byKey(GuideStepCard.exitKey)), before, reason: 'Exit stays where it was'); }); }); }
