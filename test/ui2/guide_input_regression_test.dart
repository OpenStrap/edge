// Consolidated regressions; each group retains its own test lifecycle.
import '../support/live_guide_focus.dart'; import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/app_shell.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart'; import 'package:openstrap_edge/ui2/theme.dart';
import 'package:shared_preferences/shared_preferences.dart'; import '../support/guide_text.dart'; import 'dart:async' show unawaited;
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
// Tier 2 review fix F1 (r2-review-opus-tier2.md): the BEHAVIOUR the owner sees, on real widgets (the shipped AppShell, the shipped overlay and run).
const _m0Anchor = ValueKey('t2-anchor'); const _m0Missing = ValueKey('t2-missing'); const _m0OnHealth = ValueKey('t2-on-health'); const _m0Control = ValueKey('t2-control');
Finder _m0Tabs() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabBar');
Finder _m0Tab(int i) => find.descendant(of: _m0Tabs(), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tab')).at(i);
/// The shipped [AppShell] (IndexedStack of tabs, tab bar) with one tiny screen per tab, the
/// shipped overlay inserted by hand, and a guide whose anchor is on the Activity tab.
class _M0Shell { final nav = GlobalKey<NavigatorState>(); final routes = GuideRouteObserver(); final dim = GuideDimController();
  late GuideRun run; late OverlayEntry entry; int controlTaps = 0;
  Future<void> pump(WidgetTester t, {required GuideTarget target, GuideAction action = GuideAction.tap, bool parkHealth = false}) async {
    SharedPreferences.setMockInitialValues(const {}); await Prefs.ensureLoaded(); t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1; addTearDown(t.view.reset); await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      navigatorKey: nav, navigatorObservers: [routes], scrollBehavior: const GuideScrollBehavior(),
      theme: buildTheme(Brightness.light), localizationsDelegates: AppLocalizations.localizationsDelegates, supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(initial: ShellDomain.activity, builder: (context, domain) => switch (domain) { ShellDomain.activity => Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Shell anchor line', key: _m0Anchor)),
          Pressable(key: _m0Control, onTap: () => controlTaps++, child: const Surface(child: Text('A control'))), ]),
        ShellDomain.health => Column(children: [Pressable(key: _m0OnHealth, onTap: () {}, child: const Text('Only on Health'))]),
        _ => const SizedBox.shrink(), }), ))); await t.pump(); if (parkHealth) {
      // Visit Health so its screen stays mounted (parked) under the IndexedStack, then come back.
      await t.tap(_m0Tab(3)); await t.pump(const Duration(milliseconds: 300)); await t.tap(_m0Tab(2)); await t.pump(const Duration(milliseconds: 300)); }
    final guide = Guide(id: 't2', title: fnText((_) => 'Tier 2'), start: GuideStart.activity,
      variants: [GuideVariant(steps: [GuideStep(id: 'step', target: target, anchor: GuideTarget.key(_m0Anchor),
        action: action, caption: fnText((_) => 'Tap the thing.'))])]); run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: nav, routes: routes,
      onExit: run.exit, onBackToGuide: () {})); nav.currentState!.overlay!.insert(entry); for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); dim.dispose(); }); } } void _tests0() {
  // WHY: CLAIM(absent-covers-nothing) a target that is simply not on this page gives the guide
  // nothing to point at; sending the user to "the guide's start tab" (the tab they are already
  // on) dims the whole page, outlines the current tab and leads nowhere. On a scrollThenTap step a "Scroll" marker would also point at nothing.
  // # catches: routing every TargetAbsent through the start tab (F1), a scroll marker for an
  // absent target, a skeleton layer that absorbs taps while covering nothing.
  for (final action in GuideAction.values) { testWidgets('F1 a target absent from the current tab covers nothing (${action.name})', (t) async {
      final semantics = t.ensureSemantics(); try { final shell = _M0Shell(); await shell.pump(t, target: GuideTarget.key(_m0Missing), action: action);
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        expect(shell.run.state, isA<GuideAtStep>(), reason: 'positive control: the anchor is on this tab, the step is current');
        expect(overlay.targetRect, isNull); expect(liveGuideFocus, findsNothing, reason: 'no outline');
        expect(find.byKey(LiveGuideOverlay.tapPillKey), findsNothing, reason: 'no Tap pill');
        expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsNothing, reason: 'no Scroll marker'); expect(overlay.paintedShapes, isEmpty, reason: 'no dim, no skeleton');
        expect(shell.dim.looks, isNull, reason: 'no plan published to the components');
        expect(find.byKey(LiveGuideOverlay.skeletonKey), findsNothing, reason: 'no input layer over a page nothing covers');
        expect(find.bySemanticsLabel(RegExp('^Guide: open the')), findsNothing, reason: 'no route proxy');
        await t.tapAt(t.getRect(find.byKey(_m0Control)).center); expect(shell.controlTaps, 1, reason: 'the page works as without a guide'); } finally { semantics.dispose(); } }); }
  // WHY: the target IS inside another tab's (parked) screen, so that tab is the way to it. Highlight THAT tab, not the guide's start tab.
  // # catches: the tab route dropped altogether by the F1 fix, or still pointing at the start tab.
  testWidgets('F1 a target inside another tab highlights that tab', (t) async { final semantics = t.ensureSemantics(); try {
      final shell = _M0Shell(); await shell.pump(t, target: GuideTarget.key(_m0OnHealth), parkHealth: true);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); expect(shell.run.state, isA<GuideAtStep>());
      expect(overlay.targetRect, isNull, reason: 'the target is not on this tab'); final outline = liveGuideFocus; expect(outline, findsOneWidget); final ring = t.getRect(outline);
      final health = t.getRect(_m0Tab(3)), current = t.getRect(_m0Tab(2)); expect(ring.contains(health.center), isTrue, reason: 'the outline is on the Health tab');
      expect(ring.contains(current.center), isFalse, reason: 'never the tab the user is on');
      expect((ring.center - health.center).distance, lessThan((ring.center - current.center).distance)); expect(find.byKey(LiveGuideOverlay.tapPillKey), findsOneWidget);
      final label = t.widget<Pressable>(find.descendant(of: _m0Tab(3), matching: find.byType(Pressable))).semanticLabel!;
      expect(find.bySemanticsLabel('Guide: open the $label tab'), findsOneWidget); } finally { semantics.dispose(); } }); }
// Tier 2 review fix F2 (r2-review-opus-tier2.md): a page drag handed off from skeleton ink.
const _m1Control = ValueKey('t2-control'); void _tests1() {
  // WHY: CLAIM(drag-handoff-cancel) a drag handed from skeleton ink to the page's scrollable is the overlay's to end. When the input layer goes (a dialog yields the guide, the run
  // exits) nothing else ends it: the Scrollable keeps ignoring pointers and swallows the user's next tap on a perfectly legal control.
  // # catches: a dangling ScrollPosition drag after the layer is removed (F2), in either
  // removal path.
  for (final exitRun in [false, true]) {
    testWidgets('F2 a page drag cut off mid-gesture by ${exitRun ? 'the guide exiting' : 'a dialog'} does not swallow the next tap', (t) async {
      final page = _M1DragPage(); await page.pump(t); final skeleton = t.getRect(find.byKey(_m1Nearby));
      final g = await t.startGesture(skeleton.center); await g.moveBy(const Offset(0, -20)); await g.moveBy(const Offset(0, -20));
      await t.pump(); expect(page.scroll.offset, greaterThan(0), reason: 'positive control: the skeleton drag scrolled the page');
      expect(page.scroll.position.isScrollingNotifier.value, isTrue, reason: 'positive control: the page is mid-drag'); if (exitRun) {
        page.entry.remove(); page.run.exit(); } else { unawaited(showDialog<void>(context: page.nav.currentContext!, builder: (_) => const AlertDialog(content: Text('Dialog')))); }
      await t.pump(const Duration(milliseconds: 100)); await t.pump(const Duration(milliseconds: 100)); await g.up(); if (!exitRun) {
        expect(find.text('Dialog'), findsOneWidget); page.nav.currentState!.pop(); } for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 100)); }
      expect(page.scroll.position.isScrollingNotifier.value, isFalse, reason: 'the cut-off drag was ended, not left dangling');
      await t.tapAt(t.getRect(find.byKey(_m1Dimmed)).center); await t.pump();
      expect(page.dimmedTaps, 1, reason: 'exactly one callback for the one tap'); expect(page.nearbyTaps, 0); }); } }
const _m1Nearby = ValueKey('t2-nearby'); const _m1Dimmed = ValueKey('t2-dimmed');
/// A scrolling page under the shipped overlay: a placeholder card two cards before the target's
/// card, a dimmed card right above it.
class _M1DragPage { final scroll = ScrollController(); final dim = GuideDimController(); final nav = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver(); late GuideRun run; late OverlayEntry entry; int nearbyTaps = 0, dimmedTaps = 0;
  Future<void> pump(WidgetTester t) async { t.view.physicalSize = const Size(390, 780); t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset); await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      navigatorKey: nav, navigatorObservers: [routes], scrollBehavior: const GuideScrollBehavior(),
      theme: buildTheme(Brightness.light), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: Scaffold(body: Stack(children: [
        // The topmost text line is live status (kept lit): a title keeps the "Nearby" card out of that.
        const Positioned(top: 16, left: 16, child: Text('Page title')), Positioned(top: 80, left: 16, right: 16, bottom: 0, child: SingleChildScrollView(controller: scroll,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Window rule: the target's card is the 4th; "Different" is right above it (dimmed); "Nearby" is two cards before the window (a placeholder).
            Pressable(key: _m1Nearby, onTap: () => nearbyTaps++, child: const Surface(child: Text('Nearby'))), const SizedBox(height: 60),
            const Surface(child: Text('Filler card')), const SizedBox(height: 12),
            Pressable(key: _m1Dimmed, onTap: () => dimmedTaps++, child: const Surface(child: Text('Different'))),
            const SizedBox(height: 12), Surface(child: Pressable(key: _m1Control, onTap: () {}, child: const Text('Target'))),
            const SizedBox(height: 1400), ]))), ]))))); await t.pump(); final guide = Guide(id: 't2-drag', title: fnText((_) => 'Drag'), start: GuideStart.today,
      variants: [GuideVariant(steps: [GuideStep(id: 'target', target: GuideTarget.key(_m1Control),
        anchor: GuideTarget.key(_m1Control), action: GuideAction.tap, caption: fnText((_) => 'Tap Target.'))])]); run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: nav, routes: routes,
      onExit: run.exit, onBackToGuide: () {})); nav.currentState!.overlay!.insert(entry); for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); scroll.dispose(); dim.dispose(); }); } }
// Tier 2 review fix F3 (r2-review-opus-tier2.md): the loose-text layer and the planner see the same text.
const _m2Control = ValueKey('t2-control'); void _tests2() {
  // WHY: CLAIM(loose-same-walk) the loose text layer and the planner must see the same text. The planner walks the element tree; the layer walked the SEMANTICS tree, which
  // ExcludeSemantics / Semantics(excludeSemantics: true) cut: such text was planned but never painted, so it stayed bright on a dimmed page.
  // # catches: a loose paragraph under an excluded-semantics subtree left undimmed (F3).
  testWidgets('F3 loose text under ExcludeSemantics is dimmed like any other', (t) async { final dim = GuideDimController();
    addTearDown(dim.dispose); await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      scrollBehavior: const GuideScrollBehavior(), theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Pressable(key: _m2Control, onTap: () {}, child: const Text('Target')), const Text('Plain words'), const ExcludeSemantics(child: Text('Excluded widget words')),
        Semantics(excludeSemantics: true, label: 'x', child: const Text('Excluded flag words')), const SizedBox(height: 1500), ]))))));
    await t.pump(); final root = t.element(find.byType(Scaffold)); final targetBox = t.renderObject<RenderBox>(find.byKey(_m2Control));
    final target = TargetFound(t.getRect(find.byKey(_m2Control)), renderObject: targetBox); final plan = planSkeleton(root, keep: [target.rect], dim: DimPolicy.of(root, target));
    final planned = {for (final u in plan.units) if (u.paragraph != null) u.paragraph!.text.toPlainText()};
    expect(planned, containsAll(['Plain words', 'Excluded widget words', 'Excluded flag words']),
      reason: 'positive control: the planner sees all three loose paragraphs'); dim.setLooks(GuidePlan.from(root, plan, keep: [targetBox]));
    await t.pump(); final dimColor = scaffoldOf(root).withValues(alpha: kDimOpacity); final layer = t.renderObject<RenderGuideLoose>(find.byType(GuideLooseLayer));
    expect(layer, paints..rect(color: dimColor)..rect(color: dimColor)..rect(color: dimColor),
      reason: 'one dim per loose paragraph, the excluded ones included'); }); } void main() { group('guide_r2_tier2', _tests0);
  group('guide_r2_tier2_drag', _tests1); group('guide_r2_tier2_loose', _tests2); }
