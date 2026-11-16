// Round 7 fix 1: one check per blocking review finding (r7-review-opus.md F1..F6).
import 'dart:async'; import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/activity/picker.dart' show ActivityPicker, ActivityRow;
import 'package:openstrap_edge/ui2/guides/guide_content.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_hand.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart'; import 'package:openstrap_edge/ui2/theme.dart';
import '../support/bundled_fonts.dart'; import '../support/guide_r2_scenes.dart'; import '../support/guide_r7_scenes.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts; LiveGuideOverlayState _overlay(WidgetTester t) => t.state(find.byType(LiveGuideOverlay));
final _picker = r2Scenes.firstWhere((s) => s.id == 'start-workout/choose-activity'); final _review = r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard');
List<RenderGuideUnit> _units(WidgetTester t) => find.byType(GuideUnitMark).evaluate().map((e) => e.renderObject).whereType<RenderGuideUnit>().toList();
List<RenderGuideUnit> _bound(WidgetTester t) => [for (final u in _units(t)) if (u.hover != null) u];
/// Frames until the hand heads for the first group header (the arrival; the press is about a second away).
Future<void> _untilOpening(WidgetTester t) async {
  for (var i = 0; i < 60 && _overlay(t).hand.mode != GuideHandMode.opening; i++) { await t.pump(const Duration(milliseconds: 16)); }
  expect(_overlay(t).hand.mode, GuideHandMode.opening, reason: 'fixture: the arrival'); }
Future<void> _frames(WidgetTester t, int n) async { for (var i = 0; i < n; i++) { await t.pump(const Duration(milliseconds: 16)); } }
void main() { setUpAll(() => r2OpenDb('guide_r7_fix1.db')); group('F1 scrolling moves positions, it does not rebind', () {
    // WHY: review F1. Every scroll frame used to rebind every hover (a repaint of every component
    // through the plan listeners), restart the hand and rebuild its paths: the hand froze while the
    // list moved. A hover is local to its component, so a scroll changes only the overlay-space
    // centres. catches: setHovers on scroll, restart() on scroll, whole-app plan repaints.
    testWidgets('R7-fix1 F1: a list scroll repaints no component, keeps the hovers and the hand loop', (t) async {
      final m = await pumpR2Scene(t, _picker); try { await settleMovingGuide(t); final overlay = _overlay(t);
        final scrollable = find.descendant(of: find.byType(ActivityPicker), matching: find.byType(Scrollable)).evaluate()
            .map((e) => (e as StatefulElement).state as ScrollableState) .where((s) => s.position.axis == Axis.vertical).first; final position = scrollable.position;
        expect(position.maxScrollExtent, greaterThan(120), reason: 'fixture: the open picker scrolls');
        // Start from a scrolled list so the rows move DOWN and stay inside the usable area.
        position.jumpTo(60); await _frames(t, 40); final units = _units(t); final hoversBefore = [for (final u in units) u.hover];
        final repaints = [for (final u in units) u.planRepaints]; final restarts = overlay.hand.restartCount, paths = overlay.hand.pathBuilds; final visits = overlay.visitCount;
        expect(hoversBefore.whereType<GuideHover>(), isNotEmpty, reason: 'positive control: hovers are bound');
        for (var i = 1; i <= 10; i++) { position.jumpTo(60.0 - 5 * i); await t.pump(const Duration(milliseconds: 16)); }
        expect(overlay.visitCount, visits, reason: 'fixture: the scroll keeps the same targets in view');
        expect([for (final u in units) u.planRepaints], repaints, reason: 'a scroll frame must not repaint components through the plan');
        final hoversAfter = [for (final u in units) u.hover]; var kept = 0; for (var i = 0; i < units.length; i++) {
          if (hoversBefore[i] == null || hoversAfter[i] == null) continue; // a target that left the view loses its hover
          expect(hoversAfter[i], same(hoversBefore[i]), reason: 'unit $i keeps its hover object through a scroll'); kept++; }
        expect(kept, greaterThanOrEqualTo(3), reason: 'positive control: several hovers persist');
        expect(overlay.hand.restartCount, restarts, reason: 'the hand keeps its loop phase');
        expect(overlay.hand.pathBuilds - paths, lessThanOrEqualTo(4), reason: 'paths are not rebuilt per frame');
        // The overlay's positions follow the real rows.
        for (var i = 0; i < 3; i++) { final row = t.getRect(find.byType(ActivityRow).at(i));
          expect(overlay.handTargets.any((h) => (h.rect.top - row.top).abs() < 1 && (h.rect.left - row.left).abs() < 1), isTrue,
              reason: 'row $i at $row is tracked at its new place'); } } finally { await disposeR2(t, m); } });
    // WHY: review F1: the hand froze while scrolling. The loop is a function of the targets' positions,
    // so carrying every rect by the same amount must carry the hand by that amount and nothing else.
    // catches: restart() on a geometry change, a sweep that keeps ending at the old place.
    for (final mode in [GuideHandMode.row, GuideHandMode.list, GuideHandMode.single]) {
      test('R7-fix1 F1: the hand follows a scroll of its targets and keeps its phase ($mode)', () {
        final base = [for (var i = 0; i < 4; i++) Rect.fromLTWH(20, 200 + i * 70.0, 300, 56)]; final rects = mode == GuideHandMode.single ? [base[1]] : base;
        final still = GuideHandMachine()..setMode(mode), moved = GuideHandMachine()..setMode(mode); var d = Offset.zero;
        for (var step = 0; step < 900; step++) { if (step >= 117 && step < 127) d += const Offset(3, -9); still.advance(16, rects);
          moved.advance(16, [for (final r in rects) r.shift(d)]); } expect(moved.restartCount, 0, reason: 'no restart');
        expect((moved.tip - (still.tip + d)).distance, lessThan(1e-6), reason: '$mode: tip');
        expect(moved.angle, closeTo(still.angle, 1e-6)); expect(moved.press, closeTo(still.press, 1e-9)); }); } });
  group('F2 a guide never undoes what the user opened', () { List<String> rowTexts(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.descendant(of: find.byType(ActivityRow), matching: find.byType(Text)))) w.data ?? '', ];
    // WHY: review F2. The picker header toggles, so the guide's one-time "open the first group" press
    // closed a group the user opened first, or switched away from it. The spec: "expanding is the most
    // a guide may do". catches: tapping without checking, a replay after the user's own open.
    for (final which in [0, 1]) { testWidgets('R7-fix1 F2: the user opens group $which first; the guide leaves it alone', (t) async {
        final m = await pumpR2Scene(t, _picker); try { await t.pump(); await _untilOpening(t); final overlay = _overlay(t);
          expect(overlay.expandCount, 0); final page = m.app.runner.routes.page!;
          final header = const PickerGroupHeaders().resolve(page, r2Locale)[which]; await t.tapAt(header.rect.center); await _frames(t, 30);
          final rows = rowTexts(t); expect(rows, isNotEmpty, reason: 'positive control: the user opened a group'); await _frames(t, 200);
          expect(overlay.expandCount, 0, reason: 'the guide must not press'); expect(rowTexts(t), rows, reason: 'the group the user opened is still the one that is open');
          expect(overlay.hand.mode, GuideHandMode.list); } finally { await disposeR2(t, m); } }); }
    // catches: a press that was already on its way when the user's tap landed (no plan in between).
    testWidgets('R7-fix1 F2: a press that arrives after the user\'s tap does nothing', (t) async { final m = await pumpR2Scene(t, _picker);
      try { await t.pump(); await _untilOpening(t); final overlay = _overlay(t); final page = m.app.runner.routes.page!;
        await t.tapAt(const PickerGroupHeaders().resolve(page, r2Locale).first.rect.center); await t.pump(const Duration(milliseconds: 16));
        final rows = rowTexts(t); expect(rows, isNotEmpty); overlay.handPressed(0); await _frames(t, 30); expect(rowTexts(t), rows);
        expect(overlay.expandCount, 0); } finally { await disposeR2(t, m); } }); }); group('F3 reduced motion has its own caption', () {
    final step = r2Guide('remove-detected').variants.single.steps.firstWhere((s) => s.id == 'discard');
    // The word each language uses for the static outline.
    const outlineWord = {'en': 'outline', 'de': 'Umrandung', 'es': 'contorno', 'fr': 'contour', 'hi': 'आउटलाइन', 'ru': 'рамка', 'th': 'เส้นกรอบ', 'zh': '轮廓'};
    const highlightWord = {'en': 'highlight', 'de': 'Hervorhebung', 'es': 'resaltado', 'fr': 'surbrillance', 'hi': 'हाइलाइट', 'ru': 'подсветка', 'th': 'ไฮไลต์', 'zh': '高亮'};
    const firstItem = {'en': 'first one', 'de': 'erste', 'es': 'primero', 'fr': 'premier', 'hi': 'पहले', 'ru': 'первый пункт', 'th': 'รายการแรก', 'zh': '第一个'};
    // WHY: review F3 / CLAIM(guide-still-first-item). Reduced motion draws no hover, so "the highlight shows the choices" was untrue
    // there. The still caption points at the outline in each language. catches: one caption for both modes.
    test('R7-fix1 F3: the reduced-motion caption names the outline, never the highlight, in all eight locales', () {
      expect(step.stillCaption, isNotNull); for (final code in outlineWord.keys) { final l = lookupAppLocalizations(Locale(code));
        final still = step.stillCaption!.of(l), moving = step.caption.of(l); expect(still, contains(outlineWord[code]!), reason: code);
        expect(still, contains(firstItem[code]!), reason: '$code identifies the first item');
        expect(still, isNot(contains(highlightWord[code]!)), reason: code); expect(still, contains('**${l.napsNotANapLabel}**'), reason: '$code keeps the quoted Discard');
        expect(moving, contains(highlightWord[code]!), reason: code); expect(moving, isNot(contains(outlineWord[code]!)), reason: code); } });
    testWidgets('R7-fix1 F3: the card shows the still caption in reduced motion and the moving one otherwise', (t) async {
      final plain = r2Locale; final m = await pumpR2Scene(t, _review); try { await settleMovingGuide(t);
        Text caption() => t.widget<Text>(find.descendant(of: find.byKey(GuideStepCard.captionKey), matching: find.byType(Text)).first);
        expect(caption().textSpan!.toPlainText(), contains('highlight'));
        t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); await _frames(t, 20);
        final text = caption().textSpan!.toPlainText(); expect(text, isNot(contains('highlight'))); expect(text, contains('outline'));
        expect(step.stillCaption!.of(plain).replaceAll('**', ''), text); } finally { await disposeR2(t, m); } }); }); group('F4 the overlay clears the hover it owns', () {
    // WHY: review F4. guide_r7_hover_test calls clearHovers itself, so nothing proved the overlay's own
    // clearing paths. One real scene, a positive check before each cause. catches: deleting the
    // `clearHovers` call in _syncHand (the reduced-motion and next-step causes), a hover left bound to an offstage route's target.
    testWidgets('R7-fix1 F4: exit, yield, completion, reduced motion and teardown each leave no hover bound', (t) async {
      final m = await pumpR2Scene(t, _review, singlePending: false, size: const Size(412, 1500)); try { await settleMovingGuide(t); final first = _bound(t);
        expect(first.length, 2, reason: 'positive control: both correction controls are bound');
        // Yield: a dialog on top of the page (the guide steps aside, then resumes).
        final navigator = m.app.navigator; unawaited(showDialog<void>(context: navigator.context, builder: (_) => const AlertDialog(title: Text('Unrelated'))));
        await _frames(t, 20); expect(_bound(t), isEmpty, reason: 'yield'); navigator.pop(); await settleMovingGuide(t);
        expect(_bound(t), isNotEmpty, reason: 'positive control: the guide resumed');
        // Reduced motion turned on during the run.
        t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        await _frames(t, 20); expect(_bound(t), isEmpty, reason: 'reduced motion'); t.platformDispatcher.clearAccessibilityFeaturesTestValue(); await settleMovingGuide(t);
        expect(_bound(t), isNotEmpty, reason: 'positive control: motion is back');
        // Main's correction is immediate: Done must clear the old hovers too.
        final old = _bound(t); final page = m.app.runner.routes.page!;
        final found = r2Guide('remove-detected').variants.single.steps.firstWhere((s) => s.id == 'discard').multi!.targets.resolve(page, r2Locale);
        await t.tapAt(found[1].rect.center); await _frames(t, 20); expect(m.run.state, isA<GuideFinished>());
        for (final unit in old) { if (unit.attached) expect(unit.hover, isNull, reason: 'the completed step leaves no hover'); }
        // Exit.
        m.run.exit(); await _frames(t, 6); expect(_bound(t), isEmpty, reason: 'exit'); } finally { await disposeR2(t, m); } });
    testWidgets('R7-fix1 F4: removing the overlay leaves no hover bound', (t) async {
      final m = await pumpR2Scene(t, _review, singlePending: false, size: const Size(412, 1500)); try { await settleMovingGuide(t);
        expect(_bound(t), isNotEmpty, reason: 'positive control'); m.removeOverlay(); await _frames(t, 4);
        expect(_bound(t), isEmpty, reason: 'teardown'); } finally { await disposeR2(t, m); } }); }); group('F5 every target is highlighted, and painted', () {
    // The per-scene check (one bound, painted hover per target) is in guide_r7_test.dart.
    // catches: paint returning before the hover when the component is drawn as placeholders.
    testWidgets('R7-fix1 F5: a hover on a placeholder component is drawn', (t) async { final controller = GuideDimController();
      final key = GlobalKey(); await t.pumpWidget(Directionality(textDirection: TextDirection.ltr,
        child: GuideDimScope(controller: controller, child: Center(child: RepaintBoundary(key: key, child: SizedBox(width: 200, height: 120, child: ColoredBox(color: C.n900,
            child: Builder(builder: (c) => GuideUnitMark(component: c, child: const SizedBox(width: 200, height: 120))))))))));
      final mark = t.renderObject<RenderGuideUnit>(find.byType(GuideUnitMark)); controller.setLooks(_AllSkeleton());
      final hover = GuideHover(const Rect.fromLTWH(20, 20, 100, 60), 6, C.blue)..value = 1; controller.setHovers({mark: hover});
      await t.pump(); await t.pump(); expect(mark.paintedLook, GuideUnitLook.skeleton, reason: 'fixture');
      final pixel = (await t.runAsync(() async { final image = await t.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!; final at = (70 * image.width + 70) * 4, corner = 2 * 4;
        image.dispose(); return [bytes.getUint32(at), bytes.getUint32(corner)]; }))!;
      expect(pixel[0], isNot(pixel[1]), reason: 'the tint shows over the placeholder component'); await t.pumpWidget(const SizedBox()); controller.dispose(); });
    // WHY: an ancestor mark outside the target's scrollable would paint a rect that the scroll has made
    // stale and that the viewport does not clip: the drifting overlay the owner rejected.
    testWidgets('R7-fix1 F5: the hover mark is never found above a scrollable', (t) async { final controller = GuideDimController();
      final targetKey = GlobalKey(), plainKey = GlobalKey(); await t.pumpWidget(Directionality(textDirection: TextDirection.ltr,
        child: GuideDimScope(controller: controller, child: Column(children: [
          SizedBox(height: 200, child: Builder(builder: (c) => GuideUnitMark(component: c, child: ListView(children: [ SizedBox(key: targetKey, height: 40, width: 100), ])))),
          Builder(builder: (c) => GuideUnitMark(component: c, child: Column(children: [SizedBox(key: plainKey, height: 40, width: 100)]))),
        ])))); expect(guideHoverMark(t.renderObject<RenderBox>(find.byKey(targetKey))), isNull, reason: 'inside a list: no ancestor mark');
      expect(guideHoverMark(t.renderObject<RenderBox>(find.byKey(plainKey))), isNotNull, reason: 'a plain ancestor stays valid');
      await t.pumpWidget(const SizedBox()); controller.dispose(); }); }); group('F8 the build-scheduled hook', () {
    // WHY: review F8. The overlay chains the binding's own onBuildScheduled; if removal is skipped, every
    // setState in the app depends on that chain. catches: a leaked handler after the last overlay goes.
    testWidgets('R7-fix1 F8: the binding\'s own handler is back when the last overlay is gone, and setState still schedules a frame', (t) async {
      final owner = WidgetsBinding.instance.buildOwner!; final original = owner.onBuildScheduled; final m = await pumpR2Scene(t, _review);
      await settleMovingGuide(t); expect(owner.onBuildScheduled, isNot(original), reason: 'positive control: the overlay hooked it');
      await disposeR2(t, m); expect(owner.onBuildScheduled, original); late StateSetter set;
      await t.pumpWidget(StatefulBuilder(builder: (c, setState) { set = setState; return const SizedBox(); })); await t.pump();
      expect(t.binding.hasScheduledFrame, isFalse); set(() {}); expect(t.binding.hasScheduledFrame, isTrue); }); }); group('F6 labels stay off the content they label', () {
    // WHY: review F6: "tap one of" covered "40 min" and "search or pick" covered the Hiking row.
    // catches: a label placed by the union alone, ignoring legible text.
    for (final scene in [_review, _picker]) { testWidgets('R7-fix1 F6: the label of ${scene.id} covers no legible text', (t) async {
        final m = await pumpR2Scene(t, scene, singlePending: scene != _review); try { await settleMovingGuide(t);
          final overlay = _overlay(t); final pill = t.getRect(find.byKey(LiveGuideOverlay.tapPillKey)); for (final text in overlay.legibleTextRects) {
            expect(pill.overlaps(text.deflate(1)), isFalse, reason: '${scene.id}: label $pill covers $text'); }
        } finally { await disposeR2(t, m); } }); } }); group('N1 text never moves a label to the other side', () {
    // WHY: review r7-2 N1: the text-avoiding search flipped both Fix-sleep-times "tap" labels below their
    // target, under the hand. Owner rule: always above unless above is off screen or under chrome.
    // catches: a search that tries the other side to dodge text.
    // Real fonts, dark, the phone's ratio: the capture conditions the flip was seen under (test fonts don't show it).
    setUpAll(() async { await loadFonts(); await skLoadAppFonts(); }); for (final scene in r2Scenes.where((s) => s.guide == 'fix-sleep-times')) {
      testWidgets('R7-fix2 N1: the label of ${scene.id} stays above its target', (t) async {
        final m = await pumpR2Scene(t, scene, brightness: Brightness.dark, devicePixelRatio: 2.625); try { await settleMovingGuide(t);
          final target = _overlay(t).targetRect!; final pill = t.getRect(find.byKey(LiveGuideOverlay.tapPillKey));
          expect(pill.bottom, lessThanOrEqualTo(target.top), reason: '${scene.id}: label $pill, target $target'); } finally { await disposeR2(t, m); } }); } }); }
class _AllSkeleton implements GuideUnitLooks { @override GuideUnitLook? lookOf(BuildContext unit) => GuideUnitLook.skeleton; }
