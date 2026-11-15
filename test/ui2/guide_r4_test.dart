import '../support/live_guide_focus.dart'; import 'dart:async';
// Guides round 4 (owner, 2026-11-14, after APK 5e7c00dd): arriving at a step whose target is off screen scrolls to it gently; a scroll indicator replaces the old side marker;
// the tap label gets a nudging hand; every marker keeps ONE side of its target; reduced motion makes all of it still.
//
// Spec: edge.research/guides/spec-r2-dim-and-card.md, section "Round 4". Real stage (test/support/live_guide_stage.dart), real scroll physics, real frame clock.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart'; import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable, ScreenTitle, Surface;
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_markers.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_text.dart'; import '../support/live_guide_stage.dart'; final _en = lookupAppLocalizations(const Locale('en'));
const _handKey = ValueKey('guide-live-tap-hand'); const _chevronKey = ValueKey('guide-live-scroll-chevron');
const _scrollHandKey = ValueKey('guide-live-scroll-hand'); const _secondKey = ValueKey('r4-second-target');
const _secondTitle = ValueKey('r4-second-title'); const _probeKey = ValueKey('r4-probe');
/// A details page with a PINNED title and a scrollable body: [gap] pixels, the target,
/// then [after] pixels. All of it is built (a SingleChildScrollView), so the target is
/// found at once and simply off screen.
class _R4Page extends StatelessWidget { final StageTaps taps; final double gap; static const after = 1600.0;
  final ScrollController? controller; final Key targetKey, titleKey; final VoidCallback? onBuild;
  /// A lazily built list (ListView.builder): the target is row 60 of 120, so it is not built
  /// until the reveal search scrolls near it, and there is room to scroll past it.
  final bool lazy; const _R4Page(this.taps, {this.gap = 1400, this.lazy = false, this.controller, this.targetKey = stageFinish, this.titleKey = stageDetailsTitle, this.onBuild});
  @override Widget build(BuildContext context) { onBuild?.call(); return Scaffold( body: SafeArea( child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: ScreenTitle('Stage details', key: titleKey)), Expanded(
            child: lazy ? ListView.builder( controller: controller, itemCount: 120, itemBuilder: (_, i) => i == 60
                        ? Pressable(key: targetKey, onTap: () => taps.finish++, child: const Surface(child: Text('Finish')))
                        : SizedBox(height: 60, child: Surface(child: Text('Row $i'))), ) : SingleChildScrollView( controller: controller,
              padding: const EdgeInsets.all(16), child: Column(children: [ Pressable(key: _probeKey, onTap: () => taps.otherAction++, child: const Surface(child: Text('Probe'))),
                SizedBox(height: gap), Pressable(key: targetKey, onTap: () => taps.finish++, child: const Surface(child: Text('Finish'))),
                SizedBox(height: after), ]), ), ), ]), ), ); } } Finder get _pageScroll => find.descendant(of: find.byType(_R4Page).last, matching: find.byType(Scrollable)).first;
ScrollPosition _position(WidgetTester t) => t.state<ScrollableState>(_pageScroll).position; Future<void> _settle(WidgetTester t) async { await t.pump(); await t.pump();
  await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50)); await t.pump(); }
/// The stage on its home page with the scroll guide, then Details pushed WITHOUT waiting
/// for the route transition, so the first frames of the step are observable.
Future<LiveStage> _arrive(WidgetTester t, {double gap = 1400, ScrollController? controller, VoidCallback? onBuild}) async {
  final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
  stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, gap: gap, controller: controller, onBuild: onBuild))); return stage; }
/// Pumps 16 ms frames until the page's scroll position exists, then returns it.
Future<ScrollPosition> _awaitPage(WidgetTester t) async { for (var i = 0; i < 30; i++) { await t.pump(const Duration(milliseconds: 16));
    if (find.byType(_R4Page).evaluate().isNotEmpty && _pageScroll.evaluate().isNotEmpty) return _position(t); } throw StateError('the page never appeared'); }
/// Scroll offsets, one per 16 ms frame, from the first frame the guide moved the page.
Future<List<double>> _trace(WidgetTester t, ScrollPosition position, {int frames = 90}) async { final out = <double>[];
  for (var i = 0; i < frames; i++) { await t.pump(const Duration(milliseconds: 16)); out.add(position.pixels); } return out; }
Rect _card(WidgetTester t) => t.getRect(find.byKey(GuideStepCard.cardKey)); void main() { group('auto-scroll on arrival', () {
    // WHY: spec Round 4 item 1. "gently (~600 ms ease-in-out)": the page used to JUMP to the target (revealTarget's ensureVisible with a zero duration).
    // catches: a jump (one big step), a different duration, a linear or stepped ease.
    testWidgets('R4-1a: an off-screen target is scrolled to over about 600 ms, easing in and out', (t) async { await _arrive(t);
      final position = await _awaitPage(t); final trace = await _trace(t, position); final first = trace.indexWhere((p) => p > 0);
      expect(first, isNonNegative, reason: 'the guide scrolled the page at all'); final last = trace.lastIndexWhere((p) => p != trace.last) + 1; final end = trace.last;
      expect(end, greaterThan(500), reason: 'the target was 1400 px down'); final ms = (last - first) * 16; expect(ms, inInclusiveRange(480, 800), reason: 'about 600 ms: $ms');
      expect(trace.toSet().length, greaterThan(15), reason: 'a glide, not a jump'); for (var i = 1; i < trace.length; i++) {
        expect(trace[i], greaterThanOrEqualTo(trace[i - 1] - .01), reason: 'monotone'); } double at(double f) => (trace[first + ((last - first) * f).round()]) / end;
      expect(at(.25), lessThan(.25), reason: 'ease-in: slower than linear at a quarter');
      expect(at(.75), greaterThan(.75), reason: 'ease-out: faster than linear at three quarters'); });
    // WHY: item 1 "to ~1/3 down the visible area, clear of the card".
    testWidgets('R4-1b: it ends with the target about a third down the visible area, outlined, clear of the card', (t) async {
      await _arrive(t); await _awaitPage(t); await _settle(t); await _settle(t); final target = t.getRect(find.byKey(stageFinish));
      expect(target.center.dy, inInclusiveRange(780 * .2, 780 * .46), reason: 'about a third down: $target');
      expect(target.top >= 0 && target.bottom <= 780, isTrue); expect(liveGuideFocus, findsOneWidget);
      expect(_card(t).overlaps(t.getRect(liveGuideFocus)), isFalse, reason: 'clear of the card');
      expect(_card(t).overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse); });
    // WHY: item 1 applies on arrival when the target is OFF screen only.
    // catches: a guide that recentres a target that was already visible.
    testWidgets('R4-1c: a target already on screen does not move the page', (t) async { await _arrive(t, gap: 120);
      final position = await _awaitPage(t); final trace = await _trace(t, position, frames: 70); expect(trace.toSet(), {0.0}, reason: 'the target was visible: no scrolling'); });
    // WHY: item 1 "any user pointer-down cancels it". catches: a glide that finishes regardless, or one that starts again after the finger lifts.
    testWidgets('R4-1d: a touch stops the glide where it is, and nothing resumes it', (t) async { await _arrive(t);
      final position = await _awaitPage(t); while (position.pixels <= 0) { await t.pump(const Duration(milliseconds: 16)); }
      for (var i = 0; i < 8; i++) { await t.pump(const Duration(milliseconds: 16)); } final held = position.pixels;
      expect(held, greaterThan(0)); final finger = await t.startGesture(const Offset(30, 420)); final stopped = position.pixels;
      for (var i = 0; i < 20; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(position.pixels, closeTo(stopped, .5), reason: 'the touch froze the page'); await finger.up(); for (var i = 0; i < 100; i++) {
        await t.pump(const Duration(milliseconds: 16)); } expect(position.pixels, closeTo(stopped, .5), reason: 'it does not resume after the finger lifts');
      expect(position.pixels, lessThan(1200), reason: 'it never reached the end it was heading for'); });
    // WHY: item 1 "never fights the user's own scroll afterwards (the reveal-once rule stays)".
    testWidgets('R4-1e: once settled, a page the user scrolls away is left where they put it', (t) async { await _arrive(t);
      final position = await _awaitPage(t); await _trace(t, position, frames: 60); await _settle(t); position.jumpTo(0);
      for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); } expect(position.pixels, 0, reason: 'the guide does not scroll back under the user'); });
    // WHY: data safety: a touch during the glide is never taken for a tap on the target (no duplicate or redirected tap) and the run does not move. (A placeholder swallows taps by
    // design, so the touch lands on the page's first card, which is one.)
    testWidgets('R4-1f: a tap during the glide does not tap the target or move the run, and stops the glide', (t) async {
      final stage = await _arrive(t); final position = await _awaitPage(t); while (position.pixels <= 0) {
        await t.pump(const Duration(milliseconds: 16)); } for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 16)); }
      final probe = t.getRect(find.byKey(_probeKey)); expect(probe.bottom, greaterThan(0)); await t.tapAt(probe.center);
      final stopped = position.pixels; for (var i = 0; i < 60; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(position.pixels, closeTo(stopped, .5), reason: 'the tap stopped the glide');
      expect(stage.taps.finish, 0, reason: 'the target was not tapped'); expect(stage.run.state, isA<GuideAtStep>()); expect(stage.run.currentStep?.id, 'finish'); });
    // WHY: C1 / CLAIM(reveal-touch-cancel): the first probe must yield the page to the finger, without either another probe or restoration to the search origin.
    // catches: search checking only the step gate, or restoring origin on cancellation.
    testWidgets('R4-fix-C1: a touch after the first lazy probe leaves only finger movement', (t) async {
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
      stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, lazy: true))); final position = await _awaitPage(t);
      for (var i = 0; i < 60 && position.pixels == 0; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(position.pixels, greaterThan(0), reason: 'positive control: first search probe happened');
      expect(find.byKey(stageFinish), findsNothing, reason: 'the distant target is still unbuilt');
      final finger = await t.startGesture(const Offset(30, 420)); final stopped = position.pixels;
      await t.pump(const Duration(milliseconds: 16)); expect(position.pixels, stopped, reason: 'no next probe and no origin restoration');
      await finger.moveBy(const Offset(0, -40)); // acquire the drag
      await t.pump(const Duration(milliseconds: 16)); final dragging = position.pixels; for (var i = 0; i < 60; i++) {
        await finger.moveBy(const Offset(0, -2)); await t.pump(const Duration(milliseconds: 16));
        expect(position.pixels, closeTo(dragging + (i + 1) * 2, .01), reason: 'frame $i follows only the finger'); } await finger.cancel();
      await _trace(t, position, frames: 60); expect(position.pixels, closeTo(dragging + 120, .01)); });
    // WHY: D1 / CLAIM(glide-tap-stops): Flutter ignores the first activation on a moving scrollable. Cancelling must never turn that stop tap into an activation.
    testWidgets('R4-fix-D1: tapping the lit target during a glide stops without activation', (t) async { final stage = await _arrive(t);
      final position = await _awaitPage(t); for (var i = 0; i < 70; i++) { await t.pump(const Duration(milliseconds: 16)); final target = t.getRect(find.byKey(stageFinish));
        if (position.isScrollingNotifier.value && target.top > 100 && target.bottom < 650 && !_card(t).overlaps(target)) break; }
      expect(position.isScrollingNotifier.value, isTrue); final target = t.getRect(find.byKey(stageFinish));
      expect(target.top, greaterThan(100)); expect(target.bottom, lessThan(650)); expect(_card(t).overlaps(target), isFalse);
      await t.tapAt(target.center); final stopped = position.pixels; await _trace(t, position, frames: 60);
      expect(position.pixels, stopped); expect(stage.taps.finish, 0); expect(stage.run.currentStep?.id, 'finish'); await t.tap(find.byKey(stageFinish)); await t.pump();
      expect(stage.taps.finish, 1, reason: 'positive control: a second tap activates normally'); });
    // WHY: C5 / CLAIM(reveal-route-cancel): system navigation has no pointer-down.
    // catches: a driven scroll continuing underneath a popup or a pushed route.
    testWidgets('R4-fix-C5: a route change stops the glide underneath', (t) async { final stage = await _arrive(t);
      final position = await _awaitPage(t); for (var i = 0; i < 60 && position.pixels == 0; i++) {
        await t.pump(const Duration(milliseconds: 16)); } expect(position.isScrollingNotifier.value, isTrue);
      unawaited(showDialog<void>(context: stage.navigator.context, builder: (_) => const AlertDialog(title: Text('Pause'))));
      final stopped = position.pixels; await _trace(t, position, frames: 60); expect(position.pixels, stopped, reason: 'the page stopped as soon as its route changed'); });
    // WHY: C6 / CLAIM(reveal-touch-scope): a pending visible-target check moves nothing. A touch then must preserve the late-content reveal.
    testWidgets('R4-fix-C6a: touching an idle pending reveal still permits late content', (t) async { final gap = ValueNotifier<double>(120); addTearDown(gap.dispose);
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
      stage.navigator.push(PageRouteBuilder<void>(transitionDuration: Duration.zero, pageBuilder: (_, _, _) => ValueListenableBuilder<double>(
        valueListenable: gap, builder: (_, value, _) => _R4Page(stage.taps, gap: value)))); final position = await _awaitPage(t);
      for (var i = 0; i < 60 && stage.run.currentStep?.id != 'finish'; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(stage.run.currentStep?.id, 'finish'); expect(position.isScrollingNotifier.value, isFalse);
      final finger = await t.startGesture(const Offset(30, 25)); await finger.up(); await _trace(t, position, frames: 60); gap.value = 1400; await _trace(t, position, frames: 120);
      expect(position.pixels, greaterThan(500), reason: 'the nonmoving reveal touch did not suppress late arrival');
      expect(t.getRect(find.byKey(stageFinish)).bottom, lessThan(780)); });
    // WHY: C6 / CLAIM(reveal-touch-scope): S -> S+1 -> S in the same page while dragging cannot clear the user's ownership of the interrupted S arrival.
    testWidgets('R4-fix-C6b: returning to a step under the finger does not reveal again', (t) async {
      final second = ValueNotifier<bool>(false); addTearDown(second.dispose); final stage = await pumpLiveStage(t, guide: _twoPageGuide());
      await _settle(t); stage.navigator.push(MaterialPageRoute<void>(builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: second, builder: (_, value, _) => _R4Page(stage.taps, targetKey: value ? _secondKey : stageFinish, titleKey: value ? _secondTitle : stageDetailsTitle))));
      final position = await _awaitPage(t); for (var i = 0; i < 60 && position.pixels == 0; i++) {
        await t.pump(const Duration(milliseconds: 16)); } final finger = await t.startGesture(const Offset(30, 420));
      await finger.moveBy(const Offset(0, -40)); await t.pump(const Duration(milliseconds: 16)); await finger.moveBy(const Offset(0, -4));
      await t.pump(const Duration(milliseconds: 16)); await t.pump(); await t.pump(); final held = position.pixels; second.value = true;
      await t.pump(); await t.pump(); expect(stage.run.currentStep?.id, 'two');
      // Let the new reveal enter its moving phase before returning to S.
      await t.pump(const Duration(milliseconds: 16)); second.value = false; await t.pump(); await t.pump();
      stage.run.observe(stage.routes.page!, _en); await t.pump(); expect(stage.run.currentStep?.id, 'one'); for (var i = 0; i < 60; i++) {
        await finger.moveBy(const Offset(0, -2)); await t.pump(const Duration(milliseconds: 16));
        expect(position.pixels, closeTo(held + 2 * (i + 1), .01), reason: 'a returning step leaves the drag alone'); } await finger.cancel(); });
    // WHY: lazy lists build the target only after the reveal search jumped to it; the glide applies to the settled position all the same (the search leaves it anywhere in view).
    testWidgets('R4-1g: a target in a lazily built list ends a third down as well', (t) async {
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
      stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, lazy: true))); await _awaitPage(t);
      expect(find.byKey(stageFinish, skipOffstage: false), findsNothing, reason: 'positive control: not built yet'); await _settle(t);
      await _settle(t); await _settle(t); final target = t.getRect(find.byKey(stageFinish));
      expect(target.center.dy, inInclusiveRange(780 * .2, 780 * .46), reason: 'about a third down: $target'); }); }); group('scroll indicator', () {
    // WHY: item 2. The old marker sat at the edge and stayed after the page had scrolled; the indicator is mid-screen, localized, and only while the target is out of view.
    // catches: an edge marker, a marker that stays once the target is in view, a missing
    // chevron, a wrong direction.
    testWidgets('R4-2a: mid-screen, with a hand icon, the word and a chevron down while the target is below; gone once it is in view', (t) async {
      await _arrive(t); final position = await _awaitPage(t); while (position.pixels <= 0) { await t.pump(const Duration(milliseconds: 16));
      } await t.pump(const Duration(milliseconds: 100)); final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
      expect(marker, findsNothing, reason: 'R4-fix-C3: no indicator while the arrival glide moves');
      final finger = await t.startGesture(const Offset(30, 420)); await finger.up(); await t.pump(); await t.pump();
      expect(marker, findsOneWidget, reason: 'stopped with target still out of view'); final box = t.getRect(marker);
      expect(box.center.dx, closeTo(390 / 2, 12), reason: 'centred across the screen'); expect(box.center.dy, inInclusiveRange(780 * .35, 780 * .65), reason: 'mid-screen');
      expect(find.descendant(of: marker, matching: find.text(_en.guideScrollMarker)), findsOneWidget);
      expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.hand)), findsOneWidget, reason: 'swipe hand');
      expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.chevronDown)), findsOneWidget);
      expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.chevronUp)), findsNothing); position.jumpTo(1400);
      await t.pump(); await t.pump(); expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsNothing, reason: 'in view: hidden'); });
    // WHY: item 2 "excluded from semantics as before; no taps absorbed (IgnorePointer)".
    testWidgets('R4-2b: it ignores pointers and is outside semantics', (t) async { final stage = await _arrive(t);
      final position = await _awaitPage(t); while (position.pixels <= 0) { await t.pump(const Duration(milliseconds: 16)); }
      final finger = await t.startGesture(const Offset(30, 420)); await finger.up(); await t.pump(); await t.pump();
      final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey); expect(marker, findsOneWidget);
      expect(find.ancestor(of: marker, matching: find.byType(IgnorePointer)), findsWidgets);
      expect(find.ancestor(of: marker, matching: find.byType(ExcludeSemantics)), findsWidgets);
      expect(find.bySemanticsLabel(_en.guideScrollMarker), findsNothing); expect(stage.run.state, isA<GuideAtStep>()); });
    // WHY: item 2; the user can scroll the target off the TOP too, and then the way is up. Round 5
    // item 2 moved the motion from the chevron (now static) to the hand, in the same direction.
    testWidgets('R4-2c: the chevron points up when the target is above, the hand nudges up', (t) async { await _arrive(t);
      final position = await _awaitPage(t); await _trace(t, position, frames: 60); await _settle(t);
      position.jumpTo(position.maxScrollExtent); await t.pump(); await t.pump(); final finger = await t.startGesture(const Offset(30, 420));
      await finger.up(); await t.pump(); await t.pump(); final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
      expect(marker, findsOneWidget); expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.chevronUp)), findsOneWidget);
      expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.chevronDown)), findsNothing); expect(find.byKey(_chevronKey), findsOneWidget);
      // Round 5 item 2: the HAND nudges (up, toward the target) and the chevron stands still.
      final hand = find.descendant(of: marker, matching: find.byKey(_scrollHandKey)); final chevron = <double>{}, hands = <double>[];
      for (var i = 0; i < 100; i++) { await t.pump(const Duration(milliseconds: 16));
        chevron.add(t.getRect(find.byKey(_chevronKey)).center.dy); hands.add(t.getRect(hand).center.dy); }
      expect(chevron, hasLength(1), reason: 'the chevron is static: $chevron'); final rest = hands.reduce((a, b) => a > b ? a : b);
      expect(rest - hands.reduce((a, b) => a < b ? a : b), greaterThan(2), reason: 'the hand travels up, toward the target'); }); }); group('tap hand', () {
    // WHY: item 3: a small pointing hand beside the "tap" label nudges toward the target twice per 1.6 s cycle. catches: no hand, a hand on every frame, one nudge, a wrong
    // direction (the pill sits above the target, so toward it is DOWN).
    testWidgets('R4-3a: the moving hand visits the target and pulls back along its finger', (t) async { await pumpLiveStage(t);
      await _settle(t); expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget);
      expect(find.descendant(of: find.byKey(LiveGuideOverlay.tapPillKey), matching: find.byKey(_handKey)), findsNothing);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); final distances = <double>[];
      for (var i = 0; i < 200; i++) { await t.pump(const Duration(milliseconds: 16)); distances.add((overlay.hand.tip - overlay.targetRect!.center).distance); }
      expect(distances.reduce((a, b) => a < b ? a : b), lessThan(.1)); expect(distances.reduce((a, b) => a > b ? a : b), greaterThan(25)); });
    // WHY: item 3 "shared clock; no per-frame rebuilds of the page". catches: a ticker per pill, setState on the overlay or the page for every frame.
    testWidgets('R4-3b: the nudge rebuilds nothing of the page', (t) async { var builds = 0;
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
      stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, gap: 120, onBuild: () => builds++)));
      await _awaitPage(t); await _settle(t); await _settle(t); expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget);
      final before = builds; for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(builds, before, reason: 'the page was not rebuilt by the hand'); });
    // WHY: item 3 "only ticks while visible". The Done card has no pill and no placeholders: the guide then asks for no frame at all.
    testWidgets('R4-3c: no pill, no frames', (t) async { final stage = await pumpLiveStage(t); await _settle(t);
      await pushStagePage(t, stage, StagePages(stage.taps).details()); await _settle(t); await t.tap(find.byKey(stageFinish));
      await _settle(t); expect(stage.run.state, isA<GuideFinished>()); expect(find.byKey(_handKey), findsNothing);
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2)); }); });
  // WHY: P1 / CLAIM(marker-repaint-isolation): hand/chevron ticks must stop at their own repaint boundary, before reaching the card, outline, or overlay painter.
  testWidgets('R4-fix-P1a: each animated marker owns a repaint boundary', (t) async { await _arrive(t, gap: 120); await _awaitPage(t);
    await _settle(t); await _settle(t); final pill = find.byKey(LiveGuideOverlay.tapPillKey); expect(pill, findsOneWidget);
    final pillBoundary = find.ancestor(of: pill, matching: find.byType(RepaintBoundary)).first;
    expect(find.descendant(of: pillBoundary, matching: find.byKey(GuideStepCard.cardKey)), findsNothing);
    expect(find.descendant(of: pillBoundary, matching: liveGuideFocus), findsNothing);
    expect(find.descendant(of: pillBoundary, matching: find.byKey(LiveGuideOverlay.skeletonKey)), findsNothing); _position(t).jumpTo(1100);
    await t.pump(); await t.pump(); final indicator = find.byKey(LiveGuideOverlay.scrollMarkerKey); expect(indicator, findsOneWidget);
    final indicatorBoundary = find.ancestor(of: indicator, matching: find.byType(RepaintBoundary)).first;
    expect(find.descendant(of: indicatorBoundary, matching: find.byKey(GuideStepCard.cardKey)), findsNothing);
    expect(find.descendant(of: indicatorBoundary, matching: find.byKey(LiveGuideOverlay.skeletonKey)), findsNothing);
    final handBoundary = find.ancestor(of: find.byKey(_scrollHandKey), matching: find.byType(RepaintBoundary)).first;
    expect(find.descendant(of: handBoundary, matching: find.text(_en.guideScrollMarker)), findsNothing, reason: 'the hand tick must not repaint its static label or chevron');
    expect(find.descendant(of: handBoundary, matching: find.byKey(_chevronKey)), findsNothing); });
  // WHY: P1 / CLAIM(hand-clock-rest): two 200 ms nudge peaks, then 800 ms of stillness per 1600 ms cycle. Inspect the clock and scheduled work, not pixels.
  // catches: repeat() throughout the hand-only cycle or restarting from zero too early.
  testWidgets('R4-fix-P1b: the moving hand has its own clock while placeholders rest', (t) async { final stage = await pumpLiveStage(t);
    await _settle(t); await pushStagePage(t, stage, StagePages(stage.taps).details()); await _settle(t);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); expect(overlay.hasPlaceholders, isFalse);
    expect(overlay.isPulsing, isFalse); expect(overlay.handActive, isTrue); final before = overlay.hand.tip;
    for (var i = 0; i < 30; i++) { await t.pump(const Duration(milliseconds: 16)); } expect(overlay.hand.tip, isNot(before)); expect(stage.dim.pulse, 1); });
  group('placement', () { const bounds = Rect.fromLTWH(0, 100, 300, 500); const size = Size(60, 22);
    // WHY: item 4: the label is ABOVE its target; no more "beside, on the left".
    test('R4-4a: above whenever it fits, even with room on the left', () { const outline = Rect.fromLTWH(150, 300, 100, 30);
      final pill = const GuidePillLayout(outline, bounds).place(size); expect(pill.bottom, closeTo(outline.top + 2, .01), reason: 'astride the top edge, above');
      expect(pill.right, lessThanOrEqualTo(outline.right)); });
    // WHY: item 4 "below only when above would be off screen or under chrome".
    test('R4-4b: below only when above leaves the visible area', () {
      const outline = Rect.fromLTWH(150, 110, 100, 30); // 10 px under the chrome edge (y 100)
      final pill = const GuidePillLayout(outline, bounds).place(size); expect(pill.top, closeTo(outline.bottom - 2, .01)); });
    // WHY: item 4 "must not flip frame to frame (hysteresis)": coming from below, above needs 12 px of spare room before it is taken again; going from above, below only when above
    // no longer fits.
    test('R4-4c: hysteresis keeps the side near the threshold', () {
      // Above needs outline.top >= bounds.top + size.height - 2 = 120.
      const barely = Rect.fromLTWH(150, 122, 100, 30); // fits by 2 px
      const roomy = Rect.fromLTWH(150, 140, 100, 30); // fits by 20 px
      const tight = Rect.fromLTWH(150, 118, 100, 30); // short by 2 px
      expect(const GuidePillLayout(barely, bounds).place(size).bottom, closeTo(124, .01), reason: 'fresh: above when it fits');
      expect(const GuidePillLayout(barely, bounds, GuidePillSide.below).place(size).top, closeTo(150, .01), reason: 'coming from below, 2 px of room is not enough to flip back');
      expect(const GuidePillLayout(roomy, bounds, GuidePillSide.below).place(size).bottom, closeTo(142, .01), reason: 'coming from below, 20 px of room flips back');
      expect(const GuidePillLayout(barely, bounds, GuidePillSide.above).place(size).bottom, closeTo(124, .01));
      expect(const GuidePillLayout(tight, bounds, GuidePillSide.above).place(size).top, closeTo(146, .01), reason: 'above no longer fits: below'); });
    /// null: beside the target (neither above nor below).
    GuidePillSide? sideOf(WidgetTester t, [Key target = stageFinish]) { final pill = t.getRect(find.byKey(LiveGuideOverlay.tapPillKey));
      final rect = t.getRect(find.byKey(target)); if (pill.center.dy < rect.top) return GuidePillSide.above;
      if (pill.center.dy > rect.bottom) return GuidePillSide.below; return null; }
    // WHY: item 4 on the live overlay: above in the middle of the screen, below under the title, never flickering while a scroll crosses the threshold, and the same side for the
    // same geometry on the next step.
    testWidgets('R4-4d: live: above mid-screen, below under chrome, no flicker while scrolling through', (t) async {
      final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true)); await _settle(t);
      stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, gap: 300))); await _awaitPage(t); await _settle(t);
      await _settle(t); final position = _position(t); expect(position.pixels, 0, reason: 'visible target: no scroll');
      expect(sideOf(t), GuidePillSide.above); final sides = <GuidePillSide?>[]; double? flip; for (var o = 0.0; o <= 520; o += 1) {
        position.jumpTo(o); await t.pump(); if (find.byKey(LiveGuideOverlay.tapPillKey).evaluate().isEmpty) break; final side = sideOf(t);
        if (sides.isNotEmpty && side != sides.last) flip ??= o; sides.add(side); }
      expect(flip, isNotNull, reason: 'scrolling the target under the title flips the pill below once');
      expect(sides.last, GuidePillSide.below); var flips = 0; for (var i = 1; i < sides.length; i++) {
        if (sides[i] != sides[i - 1]) flips++; } expect(flips, 1, reason: 'one flip on the way through');
      // Back to the flip point, then jitter 6 px either side of it: nothing flickers.
      position.jumpTo(flip!); await t.pump(); expect(sideOf(t), GuidePillSide.below); for (var i = 0; i < 6; i++) {
        for (final o in [flip - 6, flip + 4]) { position.jumpTo(o); await t.pump();
          expect(sideOf(t), GuidePillSide.below, reason: 'offset $o is inside the band'); } } position.jumpTo(flip - 40); await t.pump();
      expect(sideOf(t), GuidePillSide.above, reason: 'well clear of the band it goes back above'); });
    // WHY: item 4 "or between steps for the same geometry": the previous step's side must not leak into the next. Step 2 arrives scrolled to a geometry inside the band, where a
    // remembered 'below' would be kept.
    testWidgets('R4-4e: a new step starts from the geometry, not from the last step\'s side', (t) async { final guide = _twoPageGuide();
      final stage = await pumpLiveStage(t, guide: guide); await _settle(t);
      stage.navigator.push(MaterialPageRoute<void>(builder: (_) => _R4Page(stage.taps, gap: 300))); await _awaitPage(t); await _settle(t);
      await _settle(t); final position = _position(t); double? flip; GuidePillSide? last; for (var o = 0.0; o <= 520; o += 1) {
        position.jumpTo(o); await t.pump(); final side = sideOf(t); if (last != null && side != last) { flip = o; break; } last = side; }
      expect(flip, isNotNull, reason: 'step 1 flips below somewhere on the way up'); await t.tap(find.byKey(stageFinish)); await t.pump();
      expect(stage.run.state, isA<GuideAtStep>());
      // The same page again, scrolled to 3 px short of the flip: inside the band.
      stage.navigator.push(MaterialPageRoute<void>(
        builder: (_) => _R4Page(stage.taps, gap: 300, controller: ScrollController(initialScrollOffset: flip! - 3), targetKey: _secondKey, titleKey: _secondTitle)));
      await _awaitPage(t); await _settle(t); await _settle(t);
      expect(sideOf(t, _secondKey), GuidePillSide.above, reason: 'fresh step, fits above: above, whatever step 1 ended on'); }); });
  group('reduced motion', () { void reduce(WidgetTester t) { t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); }
    // WHY: item 5: the auto-scroll jumps (no glide).
    testWidgets('R4-5a: the page jumps to the target', (t) async { reduce(t); await _arrive(t); final position = await _awaitPage(t);
      final trace = await _trace(t, position, frames: 40);
      expect(trace.toSet().length, lessThanOrEqualTo(3), reason: 'a jump: ${trace.toSet()}'); expect(trace.last, greaterThan(500)); await _settle(t);
      expect(t.getRect(find.byKey(stageFinish)).center.dy, inInclusiveRange(780 * .2, 780 * .46), reason: 'a third down, jumped'); });
    // WHY: item 5: hand and chevron static, and then nothing asks for frames.
    testWidgets('R4-5b: the hand is still, and an idle guide schedules no frames', (t) async { reduce(t); await pumpLiveStage(t);
      await _settle(t); final hand = find.byKey(_handKey); expect(hand, findsOneWidget); final ys = <double>{};
      for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); ys.add(t.getRect(hand).center.dy); } expect(ys.length, 1, reason: 'static: $ys');
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2)); });
    testWidgets('R4-5c: the indicator\'s hand and chevron are still', (t) async { reduce(t); await _arrive(t);
      final position = await _awaitPage(t); await _trace(t, position, frames: 10); await _settle(t); position.jumpTo(0); await t.pump();
      await t.pump(); expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsOneWidget); final ys = <double>{};
      for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); ys.add(t.getRect(find.byKey(_chevronKey)).center.dy);
        ys.add(t.getRect(find.byKey(_scrollHandKey)).center.dy + 1000); } expect(ys.length, 2, reason: 'static: $ys'); }); }); }
Guide _twoPageGuide() { final first = GuideTarget.key(stageFinish); final second = GuideTarget.key(_secondKey); return Guide( id: 'r4',
    title: fnText((_) => 'R4 guide'), start: GuideStart.today, variants: [ GuideVariant(steps: [
        GuideStep(id: 'one', target: first, anchor: GuideTarget.key(stageDetailsTitle), action: GuideAction.tap, caption: stageCaption2),
        GuideStep(id: 'two', target: second, anchor: GuideTarget.key(_secondTitle), action: GuideAction.tap, caption: stageCaption2), ]), ],
    footers: [ GuideFooter(kind: GuideFooterKind.anotherWay, title: fnText((_) => 'Another way in'), body: fnText((_) => 'Open the menu.')),
      GuideFooter(kind: GuideFooterKind.missingTarget, title: fnText((_) => 'Not here?'), body: fnText((_) => 'It only shows later.')), ], ); }
