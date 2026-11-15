import '../support/live_guide_focus.dart'; import 'package:flutter/material.dart'; import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show ScreenTitle; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_fixture.dart'; import '../support/live_guide_stage.dart'; Rect _card(WidgetTester t) => t.getRect(find.byKey(GuideStepCard.cardKey));
Offset _blank(Rect r) => Offset(r.right - 7, r.top + r.height / 2); Future<void> _drag(WidgetTester t, Offset delta) async {
  await t.dragFrom(_blank(_card(t)), delta); await t.pump(); }
void main() { setUpAll(() => r2OpenDb('guide_r2_card.db')); tearDownAll(LocalDb.close); const bounds = Rect.fromLTRB(0, 60, 390, 720); const card = Size(366, 120);
  // WHY: D-S6 user height wins only after target/pill, chrome and avoid list.
  // # catches: continuing to choose only top/bottom and ignoring preferredTop.
  test('r2 placement respects clear user height and keeps full width', () {
    final r = placeGuideCard(bounds: bounds, cardSize: card, preferredTop: 300, keepClear: [const Rect.fromLTWH(20, 100, 350, 44)]);
    expect(r, const Rect.fromLTWH(12, 300, 366, 120)); });
  // WHY: overlap temporarily moves the card, never destroys the user's choice.
  // # catches: clamping preference onto target, or making automatic snap permanent.
  // proves: CLAIM(card-never-covers-target).
  test('r2 target and pill snap to a clear edge then return to user height', () {
    Rect place(List<Rect> keep) => placeGuideCard(bounds: bounds, cardSize: card, preferredTop: 300, keepClear: keep);
    final target = const Rect.fromLTWH(20, 320, 350, 44); final snapped = place([target]);
    expect([72.0, 588.0], contains(snapped.top)); // 60+12; 720-12-120.
    expect(snapped.overlaps(target), isFalse); final pill = const Rect.fromLTWH(20, 290, 60, 24);
    final pillSnap = place([const Rect.fromLTWH(20, 245, 350, 40), pill]); expect([72.0, 588.0], contains(pillSnap.top));
    expect(pillSnap.overlaps(pill), isFalse); expect(place([const Rect.fromLTWH(20, 100, 350, 44)]).top, 300); });
  // WHY: dragging to either screen edge must preserve width and safe bounds.
  // # catches: unbounded drag translation or changing x along with y.
  // proves: CLAIM(card-never-covers-target).
  test('r2 every user height is safe for every target and pill position', () { for (var userY = -300.0; userY <= 1100; userY += 20) {
      for (var targetY = 60.0; targetY <= 660; targetY += 20) { final target = Rect.fromLTWH(20, targetY, 350, 44);
        final pill = Rect.fromLTWH(300, targetY - 16, 60, 20).intersect(bounds);
        final r = placeGuideCard(bounds: bounds, cardSize: card, preferredTop: userY, keepClear: [target, pill]);
        expect(r.left, 12, reason: 'userY=$userY targetY=$targetY'); expect(r.width, 366); expect(r.top, greaterThanOrEqualTo(bounds.top));
        expect(r.bottom, lessThanOrEqualTo(bounds.bottom)); expect(r.overlaps(target), isFalse, reason: 'userY=$userY targetY=$targetY card=$r');
        expect(r.overlaps(pill), isFalse, reason: 'pill userY=$userY targetY=$targetY');
        final clamped = userY.clamp(bounds.top + kGuideCardGap, bounds.bottom - kGuideCardGap - card.height).toDouble();
        final preferred = Rect.fromLTWH(12, clamped, 366, 120); if (!preferred.overlaps(target) && !preferred.overlaps(pill)) {
          expect(r, preferred, reason: 'a safe user height is retained'); } } } });
  // WHY: the card must be movable with ordinary pointer gestures on blank space.
  // # catches: implementing preferredTop in the helper without wiring gestures.
  testWidgets('r2 blank-space drag moves vertically and keeps full width', (t) async { final f = R2Fixture(); await f.pump(t);
    final before = _card(t); await _drag(t, const Offset(80, -180)); final after = _card(t);
    expect(after.top, closeTo(before.top - 180, 1)); expect(after.left, before.left); expect(after.width, before.width);
    expect(after.left, kGuideCardGap); expect(after.right, 390 - kGuideCardGap); expect(after.top, greaterThanOrEqualTo(0)); expect(after.bottom, lessThanOrEqualTo(780)); });
  // WHY: a card drag detector must not steal taps from its embedded actions.
  // # catches: absorbing the complete card to handle drag or disabling buttons.
  testWidgets('r2 actions remain taps after dragging the card', (t) async { final f = R2Fixture(); await f.pump(t);
    await _drag(t, const Offset(0, -140)); await t.tap(find.byKey(GuideStepCard.dontSeeItKey)); await f.frames(t);
    expect(find.byKey(GuideStepCard.missingHelpKey), findsOneWidget); await t.tap(find.byKey(GuideStepCard.dontSeeItKey));
    await f.frames(t); expect(find.byKey(GuideStepCard.missingHelpKey), findsNothing); await t.tap(find.byKey(GuideStepCard.exitKey)); await t.pump(); expect(f.exits, 1); });
  // WHY: late content cannot leave a target behind the card. Owner 14 Nov: after moving clear, hold the new position for the rest of this step.
  // # catches: a covered target, or returning to an old gap during the same step.
  // proves: CLAIM(card-never-covers-target).
  testWidgets('r3 mounted card moves clear of late content then holds its position', (t) async { final f = R2Fixture(); await f.pump(t);
    final initial = _card(t); await _drag(t, const Offset(0, -180)); final chosen = _card(t);
    expect(chosen.top, closeTo(initial.top - 180, 1), reason: 'precondition: a real drag set a height');
    f.targetTop.value = chosen.top + 20; await f.frames(t); final snapped = _card(t); expect(snapped.top, isNot(closeTo(chosen.top, 1)));
    expect(snapped.overlaps(t.getRect(liveGuideFocus)), isFalse);
    expect(snapped.overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse); f.targetTop.value = 100; await f.frames(t);
    expect(_card(t).top, closeTo(snapped.top, 1)); });
  // WHY: the user's height belongs to the run, so advancing to another step must not reset it when the new target is clear of the chosen position.
  // # catches: resetting preferredTop on every step/route change.
  testWidgets('r2 dragged height survives an actual step and route change', (t) async { final stage = await pumpLiveStage(t);
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); } final initial = _card(t); await _drag(t, const Offset(0, -180)); final chosen = _card(t);
    expect(chosen.top, closeTo(initial.top - 180, 1), reason: 'a real drag moved the card'); await t.tap(find.byKey(stageOpenDetails));
    for (var i = 0; i < 16; i++) { await t.pump(const Duration(milliseconds: 100)); } expect(stage.run.currentStep?.id, 'finish');
    expect(_card(t).top, closeTo(chosen.top, 1)); expect(_card(t).overlaps(t.getRect(liveGuideFocus)), isFalse); });
  // WHY: blank-space drag belongs to the card, never the page underneath it.
  // # catches: letting the page's scroll recognizer win the drag, even if target
  // reveal later jumps the scroll offset back and hides that movement.
  testWidgets('r2 card blank-space drag moves card without scrolling the page', (t) async {
    final stage = await pumpLiveStage(t, guide: stageGuide(scrollLast: true), detailsGap: 1800);
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); } await t.tap(find.byKey(stageOpenDetails));
    for (var i = 0; i < 24; i++) { await t.pump(const Duration(milliseconds: 100)); } final page = stage.routes.page!;
    final scrollable = find.descendant(of: find.byElementPredicate((e) => identical(e, page)), matching: find.byType(Scrollable)).first;
    final position = t.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(500), reason: 'positive control: page really can scroll'); var changes = 0;
    void changed() { changes++; } position.addListener(changed); final before = _card(t); try {
      await _drag(t, Offset(0, before.top < 200 ? 60 : -60)); expect(changes, 0, reason: 'no transient page scroll either');
      expect(_card(t).top, isNot(closeTo(before.top, 1)), reason: 'gesture actually moved the card'); } finally { position.removeListener(changed); } });
  // WHY: user height lasts for this run only, not a later guide in the same app.
  // # catches: storing dragged position in prefs or a static/global field.
  testWidgets('r2 a new run resets the dragged card height', (t) async { final f = R2Fixture(); await f.pump(t); final initial = _card(t);
    await _drag(t, const Offset(0, -180)); expect(_card(t).top, closeTo(initial.top - 180, 1), reason: 'precondition: height changed');
    await f.restart(t); expect(_card(t), initial); });
  // WHY: arbitrary long drags cannot move any part of the card off screen.
  // # catches: Transform.translate without clamping to layout bounds.
  testWidgets('r2 pointer drags clamp the entire card at both vertical edges', (t) async { final f = R2Fixture(); await f.pump(t);
    await _drag(t, const Offset(0, -2000)); final top = _card(t); expect(top.top, greaterThanOrEqualTo(0));
    expect(top.bottom, lessThanOrEqualTo(780)); await _drag(t, const Offset(0, 2000)); final bottom = _card(t);
    expect(bottom.top, greaterThanOrEqualTo(0)); expect(bottom.bottom, lessThanOrEqualTo(780));
    expect(top.top, lessThan(bottom.top), reason: 'both drags must actually move the card'); });
  // WHY: T2 protects real page actions hidden under blank card space. A card owns taps as well as drags, even after the page-wide shield is removed.
  // # catches: W1 translucent drag-only card leaks taps/long-press to Delete;
  // W2 pointer-up on the card incorrectly finishes the run.
  testWidgets('r2 card blank-space tap never reaches the underlying Pressable', (t) async { final f = R2Fixture(); await f.pump(t);
    final point = _blank(_card(t)); expect(t.getRect(find.byKey(r2UnderCard)).contains(point), isTrue); await t.tapAt(point);
    await t.longPressAt(point); await f.frames(t); expect(f.underlying, 0); expect(f.underlyingLongPresses, 0); expect(f.targets, 0);
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
    // Positive control: the very same point reaches the Pressable without card.
    f.entry!.remove(); await t.pump(); await t.tapAt(point); await t.pump(); expect(f.underlying, 1); await t.longPressAt(point); expect(f.underlyingLongPresses, 1); });
  // WHY: D-S6 avoid-list title/timer outranks user height but yields to the target/pill. Tab exclusion is expressed by the available bounds.
  // # catches: S6 honoring preferredTop over avoid, or avoiding title over target.
  test('r2 placement precedence target then tab bounds then avoid then preference', () {
    final avoid = const Rect.fromLTWH(20, 310, 350, 44); final target = const Rect.fromLTWH(20, 600, 350, 40);
    final placed = placeGuideCard(bounds: bounds, cardSize: card, preferredTop: 300, keepClear: [target], avoid: [avoid]);
    expect(placed, const Rect.fromLTWH(12, 72, 366, 120)); expect(placed.overlaps(avoid), isFalse);
    final unavoidable = placeGuideCard(bounds: bounds, cardSize: card, preferredTop: 300, keepClear: [target], avoid: [bounds]);
    expect(unavoidable.overlaps(target), isFalse, reason: 'target wins when avoid cannot be satisfied'); expect(unavoidable.bottom, lessThanOrEqualTo(bounds.bottom)); });
  // WHY: D-S6 never-cover is still possible when natural card height exceeds both clear edges: cap the rendered box, scroll the remaining caption.
  // # catches: S6 choosing the least target overlap instead of capping height.
  testWidgets('r2 tall card caps above target and scrolls its long caption', (t) async {
    final f = R2Fixture(caption: List.filled(45, 'Read this detailed instruction.').join(' ')); f.targetTop.value = 360; await f.pump(t);
    final target = t.getRect(find.byKey(r2Target)); expect(_card(t).overlaps(target), isFalse, reason: 'cap instead of covering central target');
    expect(_card(t).overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);
    final scroll = find.descendant(of: find.byKey(GuideStepCard.cardKey), matching: find.byType(Scrollable)).first; final position = t.state<ScrollableState>(scroll).position;
    expect(position.maxScrollExtent, greaterThan(100), reason: 'caption is longer than cap'); final before = position.pixels;
    await t.drag(scroll, const Offset(0, -80)); await t.pump();
    expect(position.pixels, greaterThan(before), reason: 'capped content remains reachable'); expect(_card(t).overlaps(target), isFalse); });
  // WHY: W6 can hide when tests construct overlays themselves. The production runner survives exit/start and must discard the previous run's preference.
  // # catches: W6 storing dragged height on GuideRunner rather than its run.
  testWidgets('r2 production runner start drag exit start resets height', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size);
    try { final first = await app.runner.start(r2Guide('log-past-workout'), band: null) as GuideStarted;
      await settleLiveGuide(t, frames: 18); final initial = _card(t); await _drag(t, const Offset(0, -140));
      expect(_card(t).top, isNot(closeTo(initial.top, 1)), reason: 'real drag set run preference'); app.runner.exit();
      await settleLiveGuide(t); expect(find.byKey(GuideStepCard.cardKey), findsNothing);
      final second = await app.runner.start(r2Guide('log-past-workout'), band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
      expect(identical(first.run, second.run), isFalse); expect(_card(t), initial); } finally { app.runner.exit();
      await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } });
  // WHY: D-S9 the keyboard reduces the card's available height, even after a user dragged to a position which would now lie under it.
  // # catches: using padding.bottom but ignoring viewInsets after a drag.
  testWidgets('r2 dragged card stays above an open keyboard', (t) async { final f = R2Fixture(); await f.pump(t);
    await _drag(t, const Offset(0, -140)); t.view.viewInsets = const FakeViewPadding(bottom: 300); await f.frames(t);
    expect(_card(t).bottom, lessThanOrEqualTo(480)); expect(_card(t).overlaps(t.getRect(find.byKey(r2Target))), isFalse); expect(f.run.currentStep?.id, 'target'); });
  // WHY: D-S9 rotation preserves the chosen fraction of available vertical travel, not an absolute pixel coordinate or a top/bottom snap.
  // # catches: storing raw preferredTop pixels across a viewport size change.
  testWidgets('r2 user height keeps its fraction after screen height changes', (t) async { final f = R2Fixture(); await f.pump(t);
    await _drag(t, const Offset(0, -200)); final chosen = _card(t);
    // Fixture ScreenTitle reserves 60 pixels; gap is 12 at each edge.
    final titleBottom = t.getRect(find.byType(ScreenTitle)).bottom; final lower = titleBottom + kGuideCardGap;
    final fraction = (chosen.top - lower) / (780 - kGuideCardGap - chosen.height - lower);
    expect(fraction, inExclusiveRange(.1, .9), reason: 'interior preference, not an edge snap');
    t.view.physicalSize = const Size(390, 1000); await f.frames(t); final resized = _card(t);
    final expected = lower + fraction * (1000 - kGuideCardGap - resized.height - lower); expect(resized.top, closeTo(expected, 1));
    expect(resized.overlaps(t.getRect(find.byKey(r2Target))), isFalse); });
  // The semantics Move up/down test moved to guide_r2_structural_test.dart (localized in
  // three non-English locales, with a readable semantics owner): this copy could not read the tree.
}
