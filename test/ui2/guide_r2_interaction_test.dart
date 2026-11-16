import '../support/live_guide_focus.dart'; import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show AppMainShell; import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import '../support/guide_text.dart';
import '../support/live_guide_stage.dart'; import '../support/guide_r2_scroll_fixture.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_fixture.dart'; import '../support/guide_r2_scenes.dart'; import '../support/live_guide_harness.dart';
void main() { setUpAll(() => r2OpenDb('guide_r2_interaction.db')); tearDownAll(LocalDb.close); for (final id in ['log-past-workout', 'delete-workout']) {
    // WHY: on a tab/sub-tab target every content card is a placeholder.
    // # catches: retaining the old large-card dim exception or leaking a real tap.
    testWidgets('r3 $id navigation target makes Start card a noninteractive placeholder', (t) async {
      final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.guide == id && s.step == 'open-history')); try {
        await settleLiveGuide(t, frames: 18); await t.tap(find.text(r2Locale.workoutStartSessionLabel));
        await settleLiveGuide(t, frames: 16); expect(find.byType(ActivityPicker), findsNothing); expect(m.run.currentStep?.id, 'open-history'); m.removeOverlay(); await t.pump();
        await t.tap(find.text(r2Locale.workoutStartSessionLabel)); await settleLiveGuide(t, frames: 16);
        expect(find.byType(ActivityPicker), findsOneWidget, reason: 'the original control works after the guide ends'); } finally { await disposeR2(t, m); } }); }
  // WHY: passing input through must preserve the exact real callback count.
  // # catches: W2 redirected advance, forwarding a synthetic tap in addition to the original pointer,
  // or absorbing the dimmed control's original tap.
  testWidgets('r2 dimmed control receives exactly one callback per real tap', (t) async {
    // lookalike: the Alternative card sits right under the target's card: in the window, dimmed.
    final f = R2Fixture(lookalike: true); await f.pump(t); await t.tapAt(t.getRect(find.byKey(r2Alternative)).center);
    await t.pump(const Duration(milliseconds: 400)); expect(f.alternatives, 1); expect(f.targets, 0, reason: 'no redirect to the highlighted control');
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0), reason: 'T1/W2: wrong tap never advances');
    await t.tapAt(t.getRect(find.byKey(r2Alternative)).center); await t.pump(const Duration(milliseconds: 400)); expect(f.alternatives, 2);
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0)); });
  // WHY: owner reversal requires skeleton look-alikes to block taps.
  // # catches: W2 redirected advance, or passing skeleton input through as dim.
  testWidgets('r2 skeleton look-alike blocks tap and preserves run', (t) async {
    // Default layout: the Alternative card is the second card below the target's: a placeholder.
    final f = R2Fixture(); await f.pump(t); final box = t.getRect(find.byKey(r2Alternative)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(box)), isTrue,
      reason: 'positive control: this test actually taps a skeleton look-alike'); await t.tapAt(box.center);
    await t.pump(const Duration(milliseconds: 400)); expect(f.alternatives, 0); expect(f.targets, 0);
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0), reason: 'T1/W2'); });
  // WHY: amendment A includes real scrolling through dimmed content. Observe drag-origin updates even if automatic target reveal later moves it back.
  // # catches: a full-page shield that passes isolated taps but swallows drags.
  testWidgets('r2 dimmed content passes a drag to the real Activity scrollable', (t) async { var dragDistance = 0.0;
    final app = await pumpLiveGuideApp(t, size: r2Size, home: NotificationListener<ScrollNotification>( onNotification: (n) {
        if (n is ScrollUpdateNotification && n.dragDetails != null && n.metrics.axis == Axis.vertical) {
          dragDistance += n.scrollDelta!.abs(); } return false; }, child: const AppMainShell())); try {
      await app.runner.start(r2Guide('log-past-workout'), band: null); await settleLiveGuide(t, frames: 18);
      final control = find.ancestor(of: find.text(r2Locale.workoutStartSessionLabel),
        matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first; dragDistance = 0; await t.dragFrom(t.getRect(control).center, const Offset(0, -140));
      expect(dragDistance, greaterThan(20), reason: 'real scroll updates caused by this pointer drag');
      expect(find.byType(ActivityPicker), findsNothing, reason: 'a drag must not be duplicated as a tap'); } finally { app.runner.exit();
      await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); for (final gesture in ['tap', 'long press', 'double tap']) {
    // WHY: owner reversal of W3 blocks all activation gestures on skeletons without advancing or finishing the run.
    // # catches: replaying taps, or blocking only single taps but leaking long/double press.
    testWidgets('r2 skeleton look-alike blocks $gesture', (t) async { final f = R2Fixture(); await f.pump(t);
      final box = t.getRect(find.byKey(r2Alternative)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(box)), isTrue); switch (gesture) {
        case 'long press': await t.longPressAt(box.center); case 'double tap': await t.tapAt(box.center);
          await t.pump(const Duration(milliseconds: 100)); await t.tapAt(box.center); case 'tap': await t.tapAt(box.center); }
      await t.pump(const Duration(milliseconds: 400)); expect(f.longPresses, 0); expect(f.doubleTaps, 0); expect(f.dragUpdates, 0);
      expect(f.alternatives, 0, reason: 'skeleton activation never reaches the underlying control'); expect(f.targets, 0);
      expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0)); }); }
  // WHY: D-S9 a normal dimmed control may open a dialog. The guide yields paint and input until it closes, preserving both the dialog and run.
  // # catches: keeping the guide shield/card above a dialog opened off target.
  testWidgets('r2 dimmed dialog opener yields overlay and preserves run', (t) async {
    // The target is "Other action"; "Ask first" is the card right below it: dimmed, clickable.
    final base = stageGuide(); final guide = Guide(id: base.id, title: base.title, start: base.start, footers: base.footers,
      variants: [GuideVariant(steps: [GuideStep(id: 'open', target: GuideTarget.key(stageOtherAction),
        anchor: GuideTarget.key(stageHomeTitle), action: GuideAction.tap, caption: fnText((_) => 'Tap Other action.'))])]);
    final stage = await pumpLiveStage(t, guide: guide); for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    await t.tap(find.byKey(stageAskFirst)); await t.pump(const Duration(milliseconds: 400)); expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(GuideStepCard.cardKey), findsNothing, reason: 'overlay yields to modal'); expect(liveGuideFocus, findsNothing);
    expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0)); await t.tap(find.text('Confirm'));
    await t.pump(const Duration(milliseconds: 400)); for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    expect(stage.taps.dialogConfirm, 1); expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(GuideStepCard.cardKey), findsOneWidget); expect(stage.run.currentStep?.id, 'open'); });
  // WHY: owner reversal of W3 still permits vertical scroll beginning on a skeleton; otherwise users cannot scroll through P6 placeholders.
  // # catches: using AbsorbPointer over skeletons and swallowing scroll drags.
  testWidgets('r2 vertical drag starting on skeleton scrolls the real page', (t) async { final f = R2ScrollFixture(); await f.pump(t);
    final box = t.getRect(find.byKey(r2ScrollLookalike)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    final shapes = overlay.paintedShapes.where((s) => s.kind.name != 'dim' && s.rect.overlaps(box)).toList();
    expect(shapes, isNotEmpty, reason: 'gesture begins on actual skeleton ink'); final before = f.controller.offset;
    await t.dragFrom(shapes.first.rect.intersect(box).center, const Offset(0, -100)); await t.pump(const Duration(milliseconds: 50));
    expect(f.controller.offset, greaterThan(before + 40)); expect(f.lookalikeTaps, 0, reason: 'scroll does not synthesize activation');
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0)); }); }
