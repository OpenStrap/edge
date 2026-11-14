import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_navigation.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

LiveGuideOverlayState _overlay(WidgetTester t) => t.state(find.byType(LiveGuideOverlay));
void main() {
  setUpAll(() => r2OpenDb('guide_r3_routing.db'));
  tearDownAll(LocalDb.close);

  // WHY: the tree has to be used by the shipped steps, not only policy tests.
  // # catches: incomplete migration that silently falls back to anchor matching.
  test('A: every shipped step is attached to a declared navigation node', () {
    for (final entry in kGuideCatalogue) {
      for (final variant in entry.guide.variants) {
        for (final step in variant.steps) {
          expect(step.node, isNotNull, reason: '${entry.guide.id}/${step.id}');
          expect(guideNavigationTree.containsKey(step.node), isTrue);
        }
      }
    }
  });

  // WHY: after reaching History, another Activity branch needs the History
  // sub-tab as the route back, rather than a redundant Activity tab tap.
  // # catches: a correct policy disconnected from the overlay and progress rewinding.
  testWidgets('A: leaving History highlights History and the recovery button selects it', (t) async {
    final app = await pumpLiveGuideApp(t);
    try {
      await app.runner.start(r2Guide('log-past-workout'), band: null);
      await settleLiveGuide(t, frames: 18);
      final focus = _overlay(t).targetRect!;
      // Structural diagnostics distinguish a swallowed tap from an offscreen
      // target and remain useful if this contract fails again.
      expect(focus.center.dx, inInclusiveRange(0, 390), reason: '$focus');
      expect(focus.overlaps(t.getRect(find.byKey(GuideStepCard.cardKey))), isFalse, reason: 'target/card $focus');
      final overlay = _overlay(t);
      // Sub-tabs can be horizontally clipped. Tap the visible part, computed
      // from the real viewport, independently of the overlay's input holes.
      final point = focus.intersect(t.getRect(find.byType(SubTabs))).center;
      expect(overlay.layerHoles.any((r) => r.contains(point)), isTrue);
      await t.tapAt(point);
      await settleLiveGuide(t, frames: 18);
      expect(GuideNavigation.location(app.runner.routes.page!), GuideNode.activityHistory);
      expect(app.runner.activeRun!.currentStep!.id, 'log-past');
      // History reveals its target at the bottom of a lazy page. Scroll back
      // to the navigation row before choosing another sub-tab, as a user does.
      final pageScroll = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      t.state<ScrollableState>(pageScroll).position.jumpTo(0);
      await settleLiveGuide(t, frames: 18);
      final tabs = find.byType(SubTabs);
      final subTabs = t.widget<SubTabs>(tabs);
      final activities = find.descendant(of: tabs, matching: find.widgetWithText(Pressable, subTabs.items[1])).first;
      await t.tapAt(t.getRect(activities).intersect(t.getRect(tabs)).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.state, isA<GuideOffPath>());
      final history = find.descendant(of: tabs, matching: find.widgetWithText(Pressable, subTabs.items[2]));
      expect(t.getRect(find.byKey(LiveGuideOverlay.outlineKey)).contains(t.getRect(history.first).intersect(t.getRect(tabs)).center), isTrue);
      expect(find.text('1 tap back'), findsOneWidget);
      // WHY: owner review R4: off path the cards next to the route-back control stay lit,
      // also when that control is a sub-tab; the cards further away dim.
      // # catches: neighbour lighting skipped for tab-like route-back controls.
      final page = app.runner.routes.page!;
      final looks = GuideDimScope.controllerOf(page)!.looks!;
      final cards = [for (final u in r2Units(page)) if (u.element.widget is Section || u.element.widget is Surface) u]
        ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
      final below = cards.where((u) => u.rect.top >= t.getRect(tabs).bottom - 1).toList();
      expect(below, isNotEmpty, reason: 'the page has cards under the sub-tabs');
      expect(looks.lookOf(below.first.element), isNull, reason: 'the card next to the route back is lit');
      expect(cards.any((u) => looks.lookOf(u.element) == GuideUnitLook.dim), isTrue, reason: 'cards further away dim');
      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      await settleLiveGuide(t, frames: 18);
      expect(GuideNavigation.location(app.runner.routes.page!), GuideNode.activityHistory);
      expect(app.runner.activeRun!.currentStep!.id, 'log-past');
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });

  // WHY: switching tabs restores a parked sub-tab; the route cannot count a
  // second History tap when History will already be selected on return.
  // # catches: canonical default-entry paths overstating the actual hop count.
  testWidgets('A: returning to a parked History sub-tab is one tab hop', (t) async {
    final app = await pumpLiveGuideApp(t);
    try {
      await app.runner.start(r2Guide('log-past-workout'), band: null);
      await settleLiveGuide(t, frames: 18);
      final target = _overlay(t).targetRect!;
      await t.tapAt(target.intersect(t.getRect(find.byType(SubTabs))).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.currentStep!.id, 'log-past');
      await t.tapAt(t.getRect(r2Tab(3)).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.state, isA<GuideOffPath>());
      expect(find.text('1 tap back'), findsOneWidget);
      expect(t.getRect(find.byKey(LiveGuideOverlay.outlineKey)).contains(t.getRect(r2Tab(2)).center), isTrue);
      await t.tapAt(t.getRect(r2Tab(2)).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.currentStep!.id, 'log-past');
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });

  // WHY: owner review R2. The card counts every hop of the way back, so one press of
  // "Back to the guide" must take all of them, also the sub-tab still selected from an
  // earlier visit (History stays selected on Activity while the user is elsewhere).
  // # catches: a walk that selects the tab and stops, leaving a second press to the user.
  testWidgets('R2: one Back to the guide press from Today reaches Activity > Overview with History parked', (t) async {
    final app = await pumpLiveGuideApp(t);
    try {
      await app.runner.start(r2Guide('start-workout'), band: null);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.currentStep!.id, 'start-card');
      final tabs = find.byType(SubTabs);
      final items = t.widget<SubTabs>(tabs).items;
      final history = find.descendant(of: tabs, matching: find.widgetWithText(Pressable, items[2])).first;
      await t.tapAt(t.getRect(history).intersect(t.getRect(tabs)).center);
      await settleLiveGuide(t, frames: 18);
      expect(GuideNavigation.location(app.runner.routes.page!), GuideNode.activityHistory);
      expect(app.runner.activeRun!.state, isA<GuideOffPath>(), reason: 'History is not on this guide\'s path');
      await t.tapAt(t.getRect(r2Tab(0)).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.state, isA<GuideOffPath>());
      expect(find.text('2 taps back'), findsOneWidget, reason: 'Activity tab, then the Overview sub-tab');
      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      await settleLiveGuide(t, frames: 30);
      expect(GuideNavigation.location(app.runner.routes.page!), GuideNode.activityOverview);
      expect(app.runner.activeRun!.state, isA<GuideAtStep>(), reason: 'one press, not two');
      expect(app.runner.activeRun!.currentStep!.id, 'start-card');
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });

  // WHY: owner review R2, the case the shell's own tab selection makes real: the guide is on
  // History, the user is on Today, and selecting the Activity tab shows Overview, so the way
  // back is two hops (tab, then the History sub-tab) and ONE press must take both.
  // # catches: a walk that selects the tab and returns, leaving the second hop to the user.
  testWidgets('R2: one Back to the guide press from Today reaches Activity > History', (t) async {
    final app = await pumpLiveGuideApp(t);
    try {
      await app.runner.start(r2Guide('log-past-workout'), band: null);
      await settleLiveGuide(t, frames: 18);
      await t.tapAt(_overlay(t).targetRect!.intersect(t.getRect(find.byType(SubTabs))).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.currentStep!.id, 'log-past');
      await t.tapAt(t.getRect(r2Tab(0)).center);
      await settleLiveGuide(t, frames: 18);
      expect(app.runner.activeRun!.state, isA<GuideOffPath>());
      await t.tap(find.byKey(GuideStepCard.backToGuideKey));
      await settleLiveGuide(t, frames: 30);
      expect(GuideNavigation.location(app.runner.routes.page!), GuideNode.activityHistory);
      expect(app.runner.activeRun!.currentStep?.id, 'log-past', reason: 'one press, not two');
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });

  // WHY: Day strain's page exists before its future supplies How these are set.
  // # catches: the loading page flashing an off-path instruction.
  testWidgets('A: real Day strain stays on path while its data future is pending', (t) async {
    final repo = _DelayedStrain();
    final app = await pumpLiveGuideApp(t, repo: repo);
    try {
      await app.runner.start(r2Guide('heart-rate-zones'), band: null);
      await settleLiveGuide(t, frames: 18);
      await t.tapAt(_overlay(t).targetRect!.center);
      await settleLiveGuide(t, frames: 18);
      expect(repo.pending.isCompleted, isFalse);
      expect(app.runner.activeRun!.state, isA<GuideAtStep>());
      expect(app.runner.activeRun!.currentStep!.id, 'open-zones');
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
    } finally {
      repo.pending.complete(await GuideFakeRepo().getDayStrain('2026-11-14'));
      await settleLiveGuide(t, frames: 4);
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });
}
class _DelayedStrain extends GuideFakeRepo {
  final pending = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) => pending.future;
}
