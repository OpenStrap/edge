import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/grammar.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_manifest.dart'; import '../support/guide_r2_scenes.dart'; import '../support/live_guide_harness.dart';
bool _selected(WidgetTester t, int i) => t.widgetList<Semantics>(find.descendant( of: r2Tab(i), matching: find.byType(Semantics))).any((w) => w.properties.selected == true);
void main() { setUpAll(() => r2OpenDb('guide_r2_off_path.db')); tearDownAll(LocalDb.close);
  // WHY: off-path dims include icon backgrounds, not only tab text, while precisely one return tab remains full colour. Exercise the shipped runner.
  // # catches: globally exempting the tab bar, dimming just each icon/text,
  // or turning off all painting when currentStep is null.
  testWidgets('r2 off-path shell dims every component except the route-back tab', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size); try {
      final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
      await t.tapAt(t.getRect(r2Tab(3)).center); await settleLiveGuide(t, frames: 12); expect(started.run.state, isA<GuideOffPath>());
      expect(_selected(t, 3), isTrue); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      final back = t.getRect(r2Tab(0)); expect(overlay.paintedShapes.where((s) => s.rect.overlaps(back)), isEmpty, reason: 'Today is the one route back');
      // WHY: a tab is how the user leaves; the card must not sit over the tab bar (found while
      // testing owner review R2: the off-path card covered most of the bar and sank the tap).
      // # catches: an off-path plan with no chrome, so the card's bounds run under the bar.
      expect(t.getRect(find.byKey(GuideStepCard.cardKey)).bottom, lessThanOrEqualTo(t.getRect(r2Tabs()).top + .5)); for (var i = 1; i < 4; i++) { final rect = t.getRect(r2Tab(i));
        expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, rect)), isTrue, reason: 'tab $i: whole box, including selected Health pigment');
        // WHY: CLAIM(off-path-one-dim): the tab paints its own foreground.
        // # catches: publishing a tab look and painting its section again in the overlay.
        final layers = overlay.paintedShapes.where((s) => s.kind.name == 'dim' && r2Contains(s.rect, rect)); expect(layers, hasLength(1));
        expect(overlay.layerStatic, isNot(contains(layers.single.section)),
          reason: 'tab $i already paints in its component; the overlay must not duplicate it'); } final page = app.runner.routes.page!;
      // Owner round 5 item 3 (supersedes the round 3 "neighbour lit" rule): with a chrome route back (a
      // tab) every content component is dimmed, the route back's neighbouring card too; nothing is a placeholder.
      // # catches: a neighbour exemption for a route back that is a tab in the bottom bar.
      final units = r2Units(page); expect(overlay.paintedShapes.where((s) => s.kind.name != 'dim'), isEmpty,
        reason: 'off path: no placeholders; got ${[for (final s in overlay.paintedShapes) if (s.kind.name != 'dim') '${s.kind.name}@${s.rect}']}');
      for (final unit in units) { expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, unit.rect)), isTrue,
          reason: 'off-path component ${unit.element.widget.runtimeType}: ${unit.text}'); } final button = t.element(find.byKey(GuideStepCard.backToGuideKey));
      expect(GuideDimScope.controllerOf(button)!.looks!.lookOf(button), isNull,
        reason: 'the instruction card belongs to the overlay, outside the dimmed page'); } finally { app.runner.exit();
      await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } });
  // WHY: amendment A/C keeps every dimmed tab interactive; the return tab alone stays full colour, and can still bring the guide back.
  // # catches: absorbing dimmed off-path tabs or blocking the return tab.
  testWidgets('r2 off-path shell keeps dimmed tabs and return tab interactive', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size); try {
      final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
      await t.tapAt(t.getRect(r2Tab(3)).center); await settleLiveGuide(t, frames: 12); expect(started.run.state, isA<GuideOffPath>());
      await t.tapAt(t.getRect(r2Tab(2)).center); await settleLiveGuide(t); expect(_selected(t, 2), isTrue, reason: 'dimmed Activity tab performs its normal navigation');
      await t.tapAt(t.getRect(r2Tab(0)).center); await settleLiveGuide(t, frames: 12); expect(_selected(t, 0), isTrue);
      expect(started.run.currentStep?.id, 'open-strain'); expect(find.byKey(GuideStepCard.offPathKey), findsNothing); } finally {
      app.runner.exit(); await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); for (var tab = 0; tab < 4; tab++) {
    // WHY: T3/D-S5 recovery must use the shipped runner, including the root re-tap case where there is nothing for Navigator to pop.
    // # catches: W4 sticky off-path state which observe/backToGuide never clears.
    testWidgets('r2 runner returns after tab $tab including current-tab re-tap', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size); try {
        final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
        await settleLiveGuide(t, frames: 18); await t.tapAt(t.getRect(r2Tab(tab)).center); await settleLiveGuide(t, frames: 12);
        expect(_selected(t, tab), isTrue); if (tab == 0) { expect(started.run.currentStep?.id, 'open-strain');
          expect(find.byKey(GuideStepCard.offPathKey), findsNothing); await app.runner.backToGuide(); } else { expect(started.run.state, isA<GuideOffPath>());
          // The button's callback is GuideRunner.backToGuide, never a test pop.
          await t.tap(find.byKey(GuideStepCard.backToGuideKey)); } await settleLiveGuide(t, frames: 18);
        expect(identical(app.runner.activeRun, started.run), isTrue); expect(started.run.currentStep?.id, 'open-strain');
        expect(find.byKey(GuideStepCard.offPathKey), findsNothing); expect(_selected(t, 0), isTrue);
        // A second invocation must also finish, not inherit a stuck walk.
        await app.runner.backToGuide(); expect(started.run.currentStep?.id, 'open-strain'); } finally { app.runner.exit();
        await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); }
  // WHY: D-S8 keeps the back arrow one step closer, even when one pop still leaves the user off path. T3 must walk both pages through GuideRunner.
  // # catches: W7 dimming the first back arrow; W4 recovery pops once and sticks.
  testWidgets('r2 two pages deep keeps each back arrow and runner walks home', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size); try {
      final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
      void push(String name) => app.navigator.push(MaterialPageRoute<void>(builder: (_) =>
        Scaffold(body: Column(children: [NavBar(name), const Text('Outside the guide')])))); push('First detour'); await settleLiveGuide(t);
      push('Second detour'); await settleLiveGuide(t); expect(started.run.state, isA<GuideOffPath>());
      // WHY: distance counts actual Back hops, including unnamed routes.
      // # catches: a fixed off-path message or a canonical-parent-only count.
      expect(find.text('2 taps back'), findsOneWidget);
      // WHY: the distance is shown ALONGSIDE the off-path text, not instead of it.
      expect(find.text("This screen isn't part of the guide."), findsOneWidget); Rect backRect() => t.getRect(find.descendant(of: find.byType(NavBar),
        matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); final failures = <String>[];
      if (overlay.paintedShapes.any((s) => s.rect.overlaps(backRect().deflate(.5)))) { failures.add('D-S8/W7: deepest back arrow dimmed'); }
      await t.tapAt(backRect().center); await settleLiveGuide(t); expect(find.text('First detour'), findsOneWidget); expect(find.text('Second detour'), findsNothing);
      expect(started.run.state, isA<GuideOffPath>(), reason: 'one step closer, still off path');
      expect(find.text('1 tap back'), findsOneWidget); if (overlay.paintedShapes.any((s) => s.rect.overlaps(backRect().deflate(.5)))) {
        failures.add('D-S8/W7: remaining back arrow dimmed'); } push('Second detour'); await settleLiveGuide(t); var completed = false;
      final returning = app.runner.backToGuide().then((_) => completed = true); await settleLiveGuide(t, frames: 30);
      expect(completed, isTrue, reason: 'runner recovery cannot hang two routes deep'); await returning;
      expect(app.navigator.canPop(), isFalse); expect(started.run.currentStep?.id, 'open-strain');
      expect(find.byKey(GuideStepCard.offPathKey), findsNothing); expect(failures, isEmpty); } finally { app.runner.exit();
      await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); }
