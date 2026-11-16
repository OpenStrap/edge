// The placeholder pulse's cost contract (owner review R1, performance): it runs only while a placeholder is on screen, repaints only placeholders, never walks the page, and is not
// a page animation that throttles the guide's own planning.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/grammar.dart' show Pressable, ScreenTitle, Surface;
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart'; import '../support/live_guide_stage.dart';
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
Future<void> _settle(WidgetTester t) async { await t.pump(); await t.pump(); await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50)); await t.pump(); }
/// Frames until nothing asks for another one: fails (times out) while anything keeps ticking.
Future<void> _idle(WidgetTester t) => t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
/// A page with a scrollable column of cards: the target card in the middle, so the cards
/// at both ends are placeholders and there is a scroll position to move.
Future<void> _pumpLongPage(WidgetTester t, LiveStage stage) async {
  await pushStagePage(t, stage, Scaffold(body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [ const ScreenTitle('Long', key: stageDetailsTitle),
    for (var i = 0; i < 4; i++) Padding(padding: const EdgeInsets.only(bottom: 12), child: Surface(child: SizedBox(height: 120, child: Text('Before $i')))),
    Pressable(key: stageFinish, onTap: () => stage.taps.finish++, child: const Surface(child: Text('Finish'))),
    for (var i = 0; i < 6; i++) Padding(padding: const EdgeInsets.only(top: 12), child: Surface(child: SizedBox(height: 120, child: Text('After $i')))), ])))); await _settle(t); }
void main() {
  // WHY: owner review R1. Placeholders own the pulse; a lit or dimmed component has no business repainting 60 times a second for it.
  // # catches: every guide component listening to the plan notifier for the pulse.
  testWidgets('R1: a pulse tick repaints the placeholders and nothing else', (t) async { final stage = await pumpLiveStage(t);
    await _settle(t); final marks = t.elementList(find.byType(GuideUnitMark)).toList(); final looks = stage.dim.looks!;
    GuideUnitLook? lookOf(Element mark) => looks.lookOf((mark.widget as GuideUnitMark).component); RenderGuideUnit unit(Element mark) => mark.renderObject! as RenderGuideUnit;
    final placeholders = [for (final m in marks) if (lookOf(m) == GuideUnitLook.skeleton) m]; final others = [for (final m in marks) if (lookOf(m) != GuideUnitLook.skeleton) m];
    expect(placeholders, isNotEmpty, reason: 'the stage home has placeholders (positive control)');
    expect(others.any((m) => lookOf(m) == GuideUnitLook.dim), isTrue, reason: 'and dimmed components');
    expect(others.any((m) => lookOf(m) == null), isTrue, reason: 'and a lit one'); final plans = {for (final m in marks) m: unit(m).planRepaints}; for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 200)); } expect(stage.dim.pulse, isNot(1), reason: 'the pulse moved');
    for (final m in placeholders) { expect(unit(m).pulseRepaints, greaterThan(0), reason: 'a placeholder follows the pulse'); }
    for (final m in others) { expect(unit(m).pulseRepaints, 0, reason: 'a ${lookOf(m)} component never hears the pulse'); }
    for (final m in marks) { expect(unit(m).planRepaints, plans[m], reason: 'the pulse is not a plan change'); } });
  // WHY: a component that stops being a placeholder (the plan changed) must drop its pulse subscription, or it repaints for ever.
  // # catches: a subscription that outlives the placeholder look.
  testWidgets('R1: a component that stops being a placeholder stops following the pulse', (t) async { final stage = await pumpLiveStage(t);
    await _settle(t); final marks = t.elementList(find.byType(GuideUnitMark)).toList(); final looks = stage.dim.looks!;
    final placeholder = marks.firstWhere((m) => looks.lookOf((m.widget as GuideUnitMark).component) == GuideUnitLook.skeleton);
    final render = placeholder.renderObject! as RenderGuideUnit; final heard = render.pulseRepaints;
    expect(heard, greaterThan(0), reason: 'positive control: it followed the pulse'); stage.dim.clear(); await t.pump();
    final after = render.pulseRepaints; stage.dim.setPulse(1.07); stage.dim.setPulse(.93); expect(render.pulseRepaints, after); });
  // WHY: with nothing to pulse, a guide that asks for frames wastes the battery of a person who only wants to read the card. Round 4: the tap hand and the scroll chevron
  // share the clock, so on a screen without placeholders it still runs while the "tap" label is up, but the placeholder pulse itself stays at rest.
  // # catches: a placeholder pulse that runs for the whole guide.
  testWidgets('R1: the placeholder pulse runs on a screen with placeholders and rests on one without', (t) async {
    final stage = await pumpLiveStage(t); await _settle(t); final overlay = _overlay(t); expect(overlay.hasPlaceholders, isTrue);
    expect(overlay.isPulsing, isTrue); expect(t.binding.hasScheduledFrame, isTrue);
    await pushStagePage(t, stage, StagePages(stage.taps).details()); await _settle(t); expect(stage.run.state, isA<GuideAtStep>());
    expect(overlay.hasPlaceholders, isFalse, reason: 'Details has a target card and one neighbour: all lit or dim');
    expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget, reason: 'the moving hand owns its clock'); for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 50)); expect(stage.dim.pulse, 1, reason: 'no placeholder, so the placeholder pulse never leaves rest'); } });
  testWidgets('R1: off path without a route-back pill, and the Done card, schedule no frames', (t) async {
    final stage = await pumpLiveStage(t); await _settle(t); final overlay = _overlay(t);
    await pushStagePage(t, stage, StagePages(stage.taps).other()); await _settle(t); expect(stage.run.state, isA<GuideOffPath>());
    expect(find.byKey(LiveGuideOverlay.tapHandKey), findsNothing, reason: 'this stage has no route-back control');
    expect(overlay.isPulsing, isFalse, reason: 'no hand and no placeholders'); await _idle(t);
    // Back to the step, then to the Done card: finishing the last step.
    stage.navigator.pop(); await t.pump(); await t.pump(const Duration(milliseconds: 400));
    await pushStagePage(t, stage, StagePages(stage.taps).details()); await _settle(t); await t.tap(find.byKey(stageFinish));
    await _settle(t); expect(stage.run.state, isA<GuideFinished>()); expect(overlay.isPulsing, isFalse, reason: 'the Done card has nothing to pulse'); await _idle(t); });
  // WHY: the pulse repaints; it is no reason to hash every built element of the page.
  // # catches: a plan walk on every pulse frame.
  testWidgets('R1: pulse frames do not walk the page, input still does at once', (t) async { final stage = await pumpLiveStage(t);
    await _settle(t); await _pumpLongPage(t, stage); final overlay = _overlay(t);
    expect(overlay.isPulsing, isTrue, reason: 'the long page has placeholders'); final start = overlay.signatureChecks;
    for (var i = 0; i < 24; i++) { await t.pump(const Duration(milliseconds: 16)); }
    expect(overlay.signatureChecks - start, lessThanOrEqualTo(4), reason: '24 pulse frames in 384 ms');
    final idle = overlay.signatureChecks; t.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(30); await t.pump(const Duration(milliseconds: 16));
    expect(overlay.signatureChecks, greaterThan(idle), reason: 'a scroll is read in its own frame'); });
  // WHY: the 50 ms throttle exists for page animations; the overlay's own clock is not one.
  // # catches: the pulse counted as a running animation, delaying every plan update.
  testWidgets('R1: the pulse does not throttle plan updates', (t) async { final stage = await pumpLiveStage(t); await _settle(t);
    await _pumpLongPage(t, stage); final overlay = _overlay(t); expect(overlay.isPulsing, isTrue);
    final position = t.state<ScrollableState>(find.byType(Scrollable).first).position; final before = overlay.planningCount;
    position.jumpTo(20); await t.pump(const Duration(milliseconds: 10)); position.jumpTo(60); await t.pump(const Duration(milliseconds: 10));
    expect(overlay.planningCount - before, greaterThanOrEqualTo(2), reason: 'two scrolls 10 ms apart, two plans'); }); }
