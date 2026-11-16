import 'package:flutter_test/flutter_test.dart'; import 'package:flutter/material.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Surface; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import 'package:openstrap_edge/l10n/app_localizations.dart';
import '../support/guide_r2_scroll_fixture.dart'; import '../support/guide_r2_fixture.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/guides/guide_motion.dart'; void main() {
  // WHY: every painter uses the same phase; value alone changes, by exactly 8%.
  // proves: CLAIM(guide-pulse).
  // # catches: constant placeholders, half-duration cycles and linear ramps.
  test('F: pulse has a 1.6s cycle, +/-8 percent and ease-in-out extrema', () { expect(kGuidePulseDuration.inMilliseconds, 1600);
    expect(guidePulseValue(0), closeTo(.92, .0001)); expect(guidePulseValue(.5), closeTo(1.08, .0001));
    expect(guidePulseValue(1), closeTo(.92, .0001)); expect(guidePulseValue(.25), closeTo(1, .0001));
    expect(guidePulseValue(.01) - guidePulseValue(0), lessThan(.001)); expect(guidePulseValue(.49), closeTo(guidePulseValue(.51), .0001)); });
  // WHY: the overlay must drive all in-tree placeholders with one clock.
  // # catches: a correct pulse function left unused, or per-card phase clocks.
  testWidgets('F: mounted placeholders share one controller and one periodic phase', (t) async { final fixture = R2Fixture();
    await fixture.pump(t); final first = fixture.dim.pulse; await t.pump(const Duration(milliseconds: 800));
    expect(first + fixture.dim.pulse, closeTo(2, .0001)); await t.pump(const Duration(milliseconds: 800));
    expect(fixture.dim.pulse, closeTo(first, .0001)); for (final mark in find.byType(GuideUnitMark).evaluate()) { expect(GuideDimScope.controllerOf(mark), same(fixture.dim)); } });
  // WHY: the shared ambient loop is permitted only behind the motion policy gate.
  // # catches: a token-owned loop that keeps ticking after reduced motion is enabled.
  testWidgets('F: motion policy stops the shared clock when motion is disabled', (t) async {
    final clock = AnimationController(vsync: t, duration: kGuidePulseDuration); addTearDown(clock.dispose);
    Motion.configureGuidePulse(clock, enabled: true); expect(clock.isAnimating, isTrue); await t.pump(const Duration(milliseconds: 400));
    Motion.configureGuidePulse(clock, enabled: false); expect(clock.isAnimating, isFalse); expect(guidePulseValue(clock.value), 1); });
  // WHY: the card holds its place until a scrolling target collides; movement completes before opacity is restored, within the owner's 800ms budget.
  // proves: CLAIM(guide-card-motion).
  // # catches: jumping during scroll, moving while opaque, fading before arrival.
  test('G: hold, fade on collision, move after stop, then restore', () { final m = GuideCardMotion();
    void at(int ms, double desired, {bool scrolling = false, bool collision = false}) =>
      m.place(desired, scrolling: scrolling, collision: collision, elapsed: Duration(milliseconds: ms)); at(0, 500); at(100, 80);
    expect(m.top, 500, reason: 'a new preferred gap alone cannot move this step'); at(200, 80, scrolling: true, collision: true);
    expect(m.top, 500); expect(m.opacity, closeTo(.2, .001)); at(300, 80); at(600, 80); expect(m.top, inExclusiveRange(80, 500));
    expect(m.opacity, closeTo(.2, .001)); at(900, 80); expect(m.top, 80); expect(m.opacity, closeTo(.2, .001)); at(1000, 80);
    expect(m.top, 80); expect(m.opacity, inExclusiveRange(.2, 1)); at(1100, 80); expect(m.opacity, 1); m.reset(); at(1200, 250);
    expect(m.top, 250, reason: 'next step starts a new held position'); });
  // WHY: reduced motion stops the pulse clock, so card recovery must not wait on it.
  // # catches: a permanently faded card when the animation clock is disabled.
  test('G: reduced motion holds during scroll then recovers without a ticking clock', () { final m = GuideCardMotion();
    m.place(500, scrolling: false, collision: false, elapsed: Duration.zero, animate: false);
    m.place(80, scrolling: true, collision: true, elapsed: Duration.zero, animate: false); expect(m.top, 500); expect(m.opacity, .2);
    m.place(80, scrolling: false, collision: true, elapsed: Duration.zero, animate: false); expect(m.top, 80); expect(m.opacity, 1); expect(m.isAnimating, isFalse); });
  // WHY: the instruction must stand out on the unchanged card surfaces below it.
  // # catches: a flat material or a thick/non-theme border.
  testWidgets('G: instruction has a one pixel theme outline and medium shadow', (t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: Scaffold(body: GuideStepCard(model: const GuideCardOffPath(), onExit: () {}))));
    final material = t.widget<Material>(find.byKey(GuideStepCard.cardKey)); expect(material.elevation, greaterThanOrEqualTo(4));
    final decoration = t.widget<DecoratedBox>(find.descendant( of: find.byKey(GuideStepCard.cardKey), matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;
    final border = decoration.border! as Border; expect(border.top.width, 1); expect(border.top.color, P.of(t.element(find.byKey(GuideStepCard.cardKey))).line); });
  // WHY: owner R5: a navy shadow is lighter than the dark page and reads as a glow.
  // # catches: shadowColor taken from a light-theme token in the dark theme.
  testWidgets('G: the dark theme shadow is black, the light theme keeps its token', (t) async {
    for (final b in [Brightness.dark, Brightness.light]) { await t.pumpWidget(MaterialApp(theme: buildTheme(b),
        localizationsDelegates: AppLocalizations.localizationsDelegates, supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: GuideStepCard(model: const GuideCardOffPath(), onExit: () {}))));
      await t.pumpAndSettle(); // the theme change animates
      final material = t.widget<Material>(find.byKey(GuideStepCard.cardKey)); final color = material.shadowColor!;
      if (b == Brightness.dark) { expect((color.r, color.g, color.b), (0.0, 0.0, 0.0), reason: 'a true dark shadow, not navy'); } else { expect(color, C.n900); } } });
  // WHY: the ordered policy must drive the mounted card during a real page drag.
  // # catches: a correct motion helper that is not wired to scroll activity/layout.
  testWidgets('G: mounted card holds and fades during scroll, moves, then restores', (t) async { final fixture = R2ScrollFixture();
    await fixture.pump(t); final card = find.byKey(GuideStepCard.cardKey); final initial = t.getRect(card); final drag = await t.startGesture(const Offset(8, 250));
    // A finger moves in steps: one giant move is consumed as the drag's start offset and scrolls nothing. (Round 4: the guide now scrolls the target a third of the way down
    // on arrival, so this point is on the target and the page really has to move.)
    for (var i = 0; i < 11; i++) { await drag.moveBy(const Offset(0, 40)); await t.pump(const Duration(milliseconds: 16)); }
    await t.pump(const Duration(milliseconds: 100)); await t.pump(); expect(t.getRect(card).top, closeTo(initial.top, 1));
    double opacity() => t.widget<Opacity>(find.ancestor(of: card, matching: find.byType(Opacity)).first).opacity;
    expect(opacity(), closeTo(.2, .01)); await drag.up(); (fixture.controller.position as ScrollPositionWithSingleContext).goIdle();
    await t.pump(const Duration(milliseconds: 50)); await t.pump(const Duration(milliseconds: 600)); await t.pump();
    final moved = t.getRect(card).top; expect(moved, isNot(closeTo(initial.top, 1))); expect(opacity(), closeTo(.2, .01));
    await t.pump(const Duration(milliseconds: 200)); await t.pump(); expect(t.getRect(card).top, closeTo(moved, 1)); expect(opacity(), 1); });
  // WHY: scrolling a built target away cannot change a partly visible sibling's layout-window treatment. P6 is for a target not built yet, not this unit.
  // # catches: collapsing all built cards when the target crosses a viewport edge.
  testWidgets('E: a partially clipped neighbour stays dim when the built target scrolls away', (t) async { final fixture = R2ScrollFixture(); await fixture.pump(t);
    final below = find.ancestor(of: find.text('Later information 0'), matching: find.byType(Surface)).first;
    final element = t.element(below); expect(fixture.dim.looks!.lookOf(element), GuideUnitLook.dim); fixture.controller.jumpTo(655);
    for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 100)); } final rect = t.getRect(below);
    expect(rect.top, lessThan(0)); expect(rect.bottom, greaterThan(0)); expect(fixture.dim.looks!.lookOf(element), GuideUnitLook.dim); }); }
