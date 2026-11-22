// Structural design checks, one per R7 rule. Actual scenes supply an independent catalogue of all 22 steps; no per-guide motion switch exists.
import 'dart:math' as math; import 'package:flutter/gestures.dart' show PointerDeviceKind; import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart' show GuideUnitLook; import 'package:openstrap_edge/ui2/guides/guide_hand.dart';
import 'package:openstrap_edge/ui2/guides/guide_markers.dart'; import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import '../support/guide_r2_scenes.dart'; import '../support/guide_r7_scenes.dart'; import '../support/skeleton_fixture.dart';
LiveGuideOverlayState _overlay(WidgetTester t) => t.state(find.byType(LiveGuideOverlay)); void main() { setUpAll(() => r2OpenDb('guide_r7.db'));
  // WHY: every guide must resolve every step and use the same style, including controls not wrapped in Pressable (search, alarm switch). CLAIM(hand-all-guides).
  for (final scene in r2Scenes) { testWidgets('R7 target-owned hover ${scene.id}', (t) async { final m = await pumpR2Scene(t, scene); try {
        await settleMovingGuide(t); final overlay = _overlay(t); expect(m.run.currentStep?.id, scene.step, reason: scene.id);
        expect(overlay.targetRect, isNotNull, reason: scene.id);
        expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget, reason: '${scene.id}: target=${overlay.targetRect} hover=${overlay.handTargets.map((t) => t.rect)} reveal=${overlay.revealProgress}');
        expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing, reason: scene.id);
        // Every target, not any one: each has its own component bound to a hover, and none of them is drawn as placeholders (paint returned before the hover there). Review F5.
        final marks = find.byType(GuideUnitMark).evaluate().map((e) => e.renderObject).whereType<RenderGuideUnit>() .where((o) => o.hover != null).toList();
        expect(marks, isNotEmpty, reason: '${scene.id}: target has no component hover painter');
        expect(marks.length, overlay.handTargets.length, reason: '${scene.id}: ${overlay.handTargets.length} targets, ${marks.length} hovers'); for (final mark in marks) {
          expect(mark.paintedLook, isNot(GuideUnitLook.skeleton), reason: '${scene.id}: a hover on a placeholder is never drawn'); }
        expect(overlay.handActive, isTrue, reason: scene.id); if (m.run.currentStep!.multi == null) expect(overlay.hand.mode, GuideHandMode.single, reason: scene.id);
      } finally { await disposeR2(t, m); } }); }
  // WHY: the owner perceived slow travel. Geometry and path work must not grow with the number of animation frames. CLAIM(hand-cached-paths).
  testWidgets('R7 idle travel reuses paths and geometry and transforms a cached cursor', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard'), singlePending: false, size: const Size(412, 1500)); try { await settleMovingGuide(t);
      final overlay = _overlay(t); for (var i = 0; i < 600; i++) { await t.pump(const Duration(milliseconds: 16)); }
      final walks = overlay.signatureChecks, paths = overlay.hand.pathBuilds;
      final cursor = find.descendant(of: find.byKey(LiveGuideOverlay.handKey), matching: find.byType(CustomPaint));
      final picture = t.widget<CustomPaint>(cursor).painter; final before = overlay.hand.tip; var moved = false; for (var i = 0; i < 180; i++) { await t.pump(const Duration(milliseconds: 16)); moved |= (overlay.hand.tip - before).distance > 1; }
      expect(overlay.signatureChecks, walks, reason: 'hand ticks must not walk elements');
      // Hover hit-tests the guide layer on every move; holes and ink reuse the planned walk.
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse); await mouse.addPointer(location: const Offset(200, 300));
      final pageWalks = overlay.pageWalks; expect(pageWalks, lessThanOrEqualTo(1), reason: 'one walk serves every later hit test');
      for (var i = 0; i < 30; i++) { await mouse.moveBy(const Offset(1, 2)); }
      expect(overlay.pageWalks, pageWalks, reason: 'hover must not walk the page'); await mouse.removePointer();
      for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 16)); } final settled = overlay.pageWalks;
      for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); }
      expect(overlay.pageWalks, settled, reason: 'pulse repaints must not walk the page');
      expect(overlay.hand.pathBuilds, paths, reason: 'repeated passes must reuse sampled segments');
      expect(t.widget<CustomPaint>(cursor).painter, same(picture), reason: 'cursor picture stays cached');
      expect(moved, isTrue, reason: 'the hand moves during a cycle, even if it ends where it began'); expect(guideSweepMs(110), 432); expect(guideSweepMs(1000), 700);
      final path = GuideHandPath(const Offset(0, 0), const Offset(100, 0), 26); expect(path.at(0), Offset.zero);
      expect(path.at(.5), const Offset(50, 26)); expect((path.at(1) - const Offset(100, 0)).distance, lessThan(1e-9)); } finally { await disposeR2(t, m); } });
  // WHY: highlight and label identify the same choices. CLAIM(hand-label-centred).
  testWidgets('R7 multi label is accent and centred above the choices', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard'), singlePending: false, size: const Size(412, 1500)); try { await settleMovingGuide(t);
      final overlay = _overlay(t); final targets = overlay.handTargets.map((e) => e.rect).toList();
      final union = targets.reduce((a, b) => a.expandToInclude(b)); final pill = find.byKey(LiveGuideOverlay.tapPillKey); expect(t.widget<GuideMarkerPill>(pill).color, C.blue);
      // Centred over the choices unless that would cover legible text; then slid along them, never off them.
      final centred = Rect.fromCenter(center: Offset(union.center.dx, t.getRect(pill).center.dy), width: t.getRect(pill).width, height: t.getRect(pill).height);
      expect(t.getRect(pill).center.dx > union.left && t.getRect(pill).center.dx < union.right, isTrue); if (!overlay.legibleTextRects.any((r) => centred.overlaps(r.deflate(1)))) {
        expect(t.getRect(pill).center.dx, closeTo(union.center.dx, 1)); } else {
        expect(t.getRect(pill).center.dx, isNot(closeTo(union.center.dx, 1)), reason: 'moved only because text was in the way'); }
      expect(t.getRect(pill).bottom, lessThanOrEqualTo(union.top)); final caption = m.run.currentStep!.caption.of(r2Locale);
      expect(caption, contains('**Not a nap**')); expect(caption, contains('the highlight shows the choices'));
      expect(caption, isNot(contains('outline'))); } finally { await disposeR2(t, m); } });
  // WHY: reduced motion is a user setting, never a per-guide variant.
  testWidgets('R7 reduced motion preserves the static aid in every guide', (t) async {
    t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); for (final id in kGuideCatalogue.map((e) => e.guide.id)) {
      final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.guide == id)); try { await settleMovingGuide(t);
        expect(find.byKey(LiveGuideOverlay.handKey), findsNothing, reason: id); expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget, reason: id);
        expect(find.byKey(LiveGuideOverlay.tapHandKey), findsOneWidget, reason: id); expect(_overlay(t).handActive, isFalse, reason: id); } finally { await disposeR2(t, m); } } });
  // WHY: Help describes tasks; the pilot's implementation labels are gone.
  testWidgets('R7 Help has no style variant labels', (t) async { skTallView(t, w: 390, h: 1600);
    await t.pumpWidget(skHost(const HelpScreen())); await t.pump(); expect(find.text('moving hand'), findsNothing);
    expect(find.text('classic'), findsNothing); expect(find.byType(GuideHandCursor), findsNothing); });
  // WHY: a single target pulls back along its finger then returns to tap, without a sideways loop. CLAIM(hand-single-along-finger).
  test('R7 single target pulls back and returns on the finger axis', () { final hand = GuideHandMachine();
    const target = Rect.fromLTWH(100, 100, 80, 44); final points = <Offset>[]; for (var i = 0; i < 250; i++) { hand.advance(16, const [target]); points.add(hand.tip); }
    final axis = Offset(-math.sin(14 * math.pi / 180), math.cos(14 * math.pi / 180)); for (final point in points) {
      final delta = point - target.center; expect((delta.dx * axis.dy - delta.dy * axis.dx).abs(), lessThan(1e-8)); }
    expect(points.any((p) => (p - target.center).distance > 25), isTrue); expect(hand.ripples, isNotEmpty); }); }
