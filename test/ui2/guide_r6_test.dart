// Retained Round 6 path and multi-target behavior checks, now shared structurally.
import 'dart:math' as math; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart'; import 'package:openstrap_edge/ui2/activity/picker.dart' show ActivityPicker, ActivityRow;
import 'package:openstrap_edge/ui2/activity/setup.dart' show ActivitySetup; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide_content.dart';
import 'package:openstrap_edge/ui2/guides/guide_hand.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart' show onstageElements; import '../support/guide_r2_scenes.dart'; import '../support/live_guide_harness.dart';
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
GuideStep _step(String guide, String id) => r2Guide(guide).variants.single.steps.firstWhere((s) => s.id == id);
/// A machine run over [rects] for [ms] milliseconds in [dt] steps: the fingertip and angle after each step,
/// and the presses with the time they happened.
({List<Offset> tips, List<double> angles, List<(int, double)> presses}) _run(GuideHandMode mode, List<Rect> rects, double ms, {double dt = 4}) {
  final events = _Presses(); final m = GuideHandMachine(events: events)..setMode(mode); final tips = <Offset>[], angles = <double>[];
  for (var t = 0.0; t < ms; t += dt) { events.now = t; m.advance(dt, rects); tips.add(m.tip); angles.add(m.angle); } return (tips: tips, angles: angles, presses: events.log); }
class _Presses implements GuideHandEvents { double now = 0; final log = <(int, double)>[]; @override void handPressed(int index) => log.add((index, now)); }
final _row = [for (var i = 0; i < 3; i++) Rect.fromLTWH(20 + i * 110.0, 300, 100, 44)];
final _list = [Rect.fromLTWH(16, 100, 380, 48), for (var i = 0; i < 3; i++) Rect.fromLTWH(16, 300 + i * 60.0, 380, 56)];
void main() { setUpAll(() => r2OpenDb('guide_r6.db')); tearDownAll(LocalDb.close); group('R6 the hand\'s path is a design', () {
    // WHY: owner round 6 item 18: the path is ONE continuous wave through the targets; segments join with
    // the same slope (Keep -> up -> Discard -> down -> Edit). The hand slows to a stop at each target, so the PATH's tangent is what must not kink there. CLAIM(wave-continuous).
    // catches: separate arcs, the same side on every segment, a bend that does not scale with the segment.
    test('R6-path: consecutive segments of a row join with the same tangent and alternate sides', () { final c = [for (final r in _row) r.center]; var sign = 1.0;
      final ends = <(Offset, Offset)>[]; // (tangent at the end of segment i, at the start of i+1)
      Offset? previousEnd; for (var i = 0; i + 1 < c.length; i++) { final k = guideWaveBend(c[i], c[i + 1], sign); sign = -sign;
        final start = guideWaveTangent(c[i], c[i + 1], 0, k), end = guideWaveTangent(c[i], c[i + 1], 1, k);
        if (previousEnd != null) ends.add((previousEnd, start)); previousEnd = end; } expect(ends, isNotEmpty); for (final (a, b) in ends) {
        expect(a.dx * b.dx + a.dy * b.dy, greaterThan(.999), reason: 'the tangent turns at a target: $a -> $b'); }
      // The wave bows to opposite sides on consecutive segments.
      final mid1 = guideWavePoint(c[0], c[1], .5, guideWaveBend(c[0], c[1], 1)); final mid2 = guideWavePoint(c[1], c[2], .5, guideWaveBend(c[1], c[2], -1));
      expect((mid1.dy - c[0].dy) * (mid2.dy - c[1].dy), lessThan(0)); });
    test('R6-path: the machine bows each sweep of a row to the other side', () { final run = _run(GuideHandMode.row, _row, 9000);
      expect(run.presses.length, greaterThan(6)); final devs = <double>[]; for (var i = 0; i + 1 < run.presses.length; i++) {
        final from = (run.presses[i].$2 / 4).floor(), to = (run.presses[i + 1].$2 / 4).floor(); final baseline = _row[run.presses[i].$1].center.dy;
        // The wave bows to one side of the HEADING: seen from the hand's own direction of travel.
        final heading = (_row[run.presses[i + 1].$1].center.dx - _row[run.presses[i].$1].center.dx).sign; var best = 0.0;
        for (var j = from; j < to; j++) { final d = (run.tips[j].dy - baseline) * heading; if (d.abs() > best.abs()) best = d; }
        devs.add(best); } for (var i = 1; i < devs.length; i++) { expect(devs[i] * devs[i - 1], lessThan(0), reason: 'sweeps $i and ${i - 1} bow the same way: $devs'); }
      // It visits Keep, Discard, Edit, Discard, Keep... one press per target in turn.
      expect([for (final p in run.presses.take(6)) p.$1], [0, 1, 2, 1, 0, 1]); });
    // WHY: item 14: rotation is rate-capped (240 deg/s); a sharp bend never snaps the hand. Item 18: the lean is at most 12 degrees in a row. CLAIM(rotation-rate-cap).
    // catches: setting the angle straight from the heading; a larger lean.
    test('R6-rate: the hand never turns faster than 240 deg/s and leans at most 12 degrees in a row', () {
      expect(capRotation(0, 90, .016), closeTo(kGuideHandRateCap * .016, 1e-9)); expect(capRotation(10, -80, .016), closeTo(10 - kGuideHandRateCap * .016, 1e-9));
      expect(capRotation(0, 90, 5), closeTo(kGuideHandRateCap * .1, 1e-9), reason: 'a long frame counts as 100 ms'); for (final mode in [GuideHandMode.row, GuideHandMode.single]) {
        final run = _run(mode, mode == GuideHandMode.row ? _row : [_row[1]], 12000, dt: 16); var worst = 0.0, lean = 0.0;
        for (var i = 1; i < run.angles.length; i++) { worst = math.max(worst, (run.angles[i] - run.angles[i - 1]).abs());
          if (mode == GuideHandMode.row) lean = math.max(lean, run.angles[i].abs()); } expect(worst, lessThanOrEqualTo(kGuideHandRateCap * .016 + 1e-6), reason: '$mode');
        if (mode == GuideHandMode.row) expect(lean, lessThanOrEqualTo(kGuideHandLean + 1e-6)); } });
    // WHY: item 19 / owner pick B: bottom up (finger first, leaning with the wave), then an upright drift
    // back down beside the list, no taps. catches: visiting top down; taps during the drift; a leaning drift.
    test('R6-list: variant B visits bottom up and drifts back down upright without tapping', () {
      final run = _run(GuideHandMode.list, _list, 20000); final firstPass = [for (final p in run.presses.take(4)) p.$1]; expect(firstPass, [3, 2, 1, 0], reason: 'bottom up');
      // Between the last press of the pass and the next pass's first press the hand drifts: no press in between, and its angle returns to upright.
      final last = run.presses[3].$2, next = run.presses[4].$2; expect(next - last, greaterThan(1000), reason: 'a drift of about 1.1 s between passes');
      final at = ((last + (next - last) * .9) / 4).floor(); expect(run.angles[at].abs(), lessThan(1), reason: 'the drift is upright');
      expect(run.tips[at].dx, greaterThan(_list[3].center.dx), reason: 'beside the list, on its right'); });
    test('R6-hover: the highlight falls with the fingertip\'s distance as (1 - d/150)^2', () { expect(guideHoverOpacity(0), 1);
      expect(guideHoverOpacity(75), closeTo(.25, 1e-9)); expect(guideHoverOpacity(150), 0); expect(guideHoverOpacity(400), 0); }); });
  group('R6 remove-detected: offered correction controls', () { final scene = r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard');
    // WHY: spec Round 6 item 5: the step's targets are Keep, Discard and Edit on ONE row, the first detected
    // item; the guide's title and text are unchanged. catches: a target set from another row, a wrong order.
    testWidgets('R6-rd: the step\'s targets resolve to both correction controls in page order', (t) async {
      final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 14);
        final page = m.app.runner.routes.page!; final multi = _step('remove-detected', 'discard').multi; expect(multi, isNotNull);
        final found = multi!.targets.resolve(page, r2Locale); expect(found, hasLength(2), reason: 'main offers Not a nap and Not a workout on separate items');
        expect(found[0].rect.top, lessThan(found[1].rect.top)); final texts = _step('remove-detected', 'discard').caption.of(r2Locale);
        expect(texts, contains('Not a nap'), reason: 'the caption keeps its Discard-focused text'); } finally { await disposeR2(t, m); } }); for (final which in [0, 1]) {
      // WHY: "any of the targets advances": Keep and Discard each stage the item and bring up Save, which is
      // what the next step anchors on. catches: only the first target advancing.
      testWidgets('R6-rd: tapping ${which == 0 ? 'Not a nap' : 'Not a workout'} completes the immediate correction guide', (t) async {
        final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 14);
          final page = m.app.runner.routes.page!; final found = _step('remove-detected', 'discard').multi!.targets.resolve(page, r2Locale);
          await t.tapAt(found[which].rect.center); await settleLiveGuide(t, frames: 18);
          expect(m.run.state, isA<GuideFinished>(), reason: 'main discards immediately'); } finally { await disposeR2(t, m); } }); }
    // WHY: hover adds foreground paint without changing the widget's background. Animated guides use the moving hand and have no outline.
    // catches: tinting a widget, an outline left beside the hover, no hand layer.
    testWidgets('R6-rd: the target paints hover and the page keeps every background', (t) async {
      final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18);
        List<String> backgrounds() => [ for (final e in onstageElements(m.app.runner.routes.page!))
            if (e.renderObject case final RenderDecoratedBox b when b.decoration is BoxDecoration) '${b.runtimeType}:${(b.decoration as BoxDecoration).color}',
        ]; final during = backgrounds(); expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget, reason: 'the hand layer');
        expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing, reason: 'no outline on an animated guide');
        expect(find.descendant(of: find.byType(LiveGuideOverlay), matching: find.byKey(LiveGuideOverlay.handKey)), findsOneWidget);
        m.removeOverlay(); await t.pump(); await t.pump();
        expect(backgrounds(), during, reason: 'a background changed when the guide ended: the guide set or removed one'); } finally { await disposeR2(t, m); } });
    testWidgets('R6-rd: a still guide (reduced motion) keeps today\'s label hand and outline', (t) async {
      t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500));
      try { await settleLiveGuide(t, frames: 18); expect(find.byKey(LiveGuideOverlay.handKey), findsNothing); expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
        expect(find.byKey(LiveGuideOverlay.tapHandKey), findsOneWidget, reason: 'the small static hand in the label'); } finally { await disposeR2(t, m); } }); });
  group('R6 start-workout: the picker', () { final scene = r2Scenes.firstWhere((s) => s.id == 'start-workout/choose-activity');
    testWidgets('R6-pk: the targets are the search bar, the chips and each group header; after opening, the search bar and the first rows', (t) async {
      final m = await pumpR2Scene(t, scene); try { await settleLiveGuide(t, frames: 6); final page = m.app.runner.routes.page!;
        final multi = _step('start-workout', 'choose-activity').multi!; expect(multi.visit, GuideVisit.list); final found = multi.targets.resolve(page, r2Locale);
        expect(found.length, greaterThanOrEqualTo(1 + 3 + 3), reason: 'search + chips + group headers'); expect(PickerChips().resolve(page, r2Locale), isNotEmpty);
        expect(PickerGroupHeaders().resolve(page, r2Locale).length, greaterThan(3));
        expect(multi.opens!.resolve(page, r2Locale), hasLength(1)); expect(multi.label!.of(r2Locale), 'search or pick'); } finally { await disposeR2(t, m); } });
    Future<void> until(WidgetTester t, bool Function() done, {int frames = 200}) async { for (var i = 0; i < frames && !done(); i++) {
        await t.pump(const Duration(milliseconds: 16)); } expect(done(), isTrue); }
    // WHY: brief 5: ONCE per arrival the hand opens the first group (the only app action a guide may take)
    // and the screen takes no taps until the expansion settles; the group stays open. Leaving and re-entering
    // replays it. catches: opening on every frame or step, blocking taps for good, never blocking, collapsing.
    testWidgets('R6-pk: the first group opens once per arrival; taps are blocked only while it opens', (t) async {
      final m = await pumpR2Scene(t, scene); try { await t.pump(); final overlay = _overlay(t); expect(overlay.expandCount, 0);
        await until(t, () => overlay.expandCount == 1, frames: 260); expect(overlay.isExpanding, isTrue, reason: 'the screen is opening');
        final page = m.app.runner.routes.page!; final chip = PickerChips().resolve(page, r2Locale).first; await t.tapAt(chip.rect.center);
        await t.pump(const Duration(milliseconds: 16)); expect(find.byType(ActivitySetup), findsNothing, reason: 'a tap during the expansion must not reach the screen');
        await until(t, () => !overlay.isExpanding, frames: 120); expect(find.byType(ActivityRow), findsWidgets, reason: 'the first group is open'); for (var i = 0; i < 160; i++) {
          await t.pump(const Duration(milliseconds: 16)); } expect(overlay.expandCount, 1, reason: 'once per arrival, however long the hand loops');
        expect(find.byType(ActivityRow), findsWidgets, reason: 'and it stays open');
        final oldHovers = find.byType(GuideUnitMark).evaluate().map((e) => e.renderObject).whereType<RenderGuideUnit>().where((e) => e.hover != null).toList();
        expect(oldHovers, isNotEmpty, reason: 'F4 positive control: picker targets have live hovers');
        await t.tapAt(chip.rect.center);
        await t.pump(const Duration(milliseconds: 16)); await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(ActivitySetup), findsOneWidget, reason: 'after the expansion the screen takes taps again');
        for (final unit in oldHovers) { if (unit.attached) expect(unit.hover, isNull, reason: 'F4: the next real step clears previous hovers'); } } finally { await disposeR2(t, m); } });
    testWidgets('R6-pk: leaving the screen and coming back replays the opening', (t) async { final m = await pumpR2Scene(t, scene); try {
        await t.pump(); final overlay = _overlay(t); await until(t, () => overlay.expandCount == 1 && !overlay.isExpanding, frames: 400);
        m.app.navigator.pop(); await settleLiveGuide(t, frames: 6); m.app.navigator.push(MaterialPageRoute<void>(builder: (_) => const ActivityPicker(weightKg: 70)));
        await settleLiveGuide(t, frames: 4); await until(t, () => overlay.expandCount == 2, frames: 400); } finally { await disposeR2(t, m); } }); }); }
