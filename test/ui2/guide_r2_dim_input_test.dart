import 'dart:ui' as ui; import 'package:flutter/rendering.dart'; import 'package:flutter/material.dart';
import 'package:openstrap_edge/ui2/grammar.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/theme.dart'; import '../support/guide_r2_fixture.dart'; void main() {
  // WHY: P2/P9 protect the purple component's background, not just its glyphs.
  // # catches: opaque per-line erase fills, duplicate dim layers, or text-only dim.
  testWidgets('r2 dim is one translucent whole coloured component with no erase', (t) async { final f = R2Fixture(); await f.pump(t);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); final rect = t.getRect(find.byKey(r2Quiet));
    final shapes = overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))).toList();
    expect(shapes.map((s) => s.kind.name), ['dim'], reason: 'one layer; no per-line surface/bar/erase');
    expect(shapes.single.rect, rect, reason: 'includes purple padding/background');
    expect(shapes.single.color!.a, inExclusiveRange(0, 1), reason: 'light dim must preserve original content'); });
  // WHY: a diagnostic plan can claim dim while the painter still erases it.
  // # catches: painting only glyphs or painting opaque scaffold over purple.
  testWidgets('r2 dim changes coloured padding pixels without erasing the component', (t) async { final f = R2Fixture(); await f.pump(t);
    final rect = t.getRect(find.byKey(r2Quiet)); Future<List<int>> sample() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(r2Capture)); return (await t.runAsync(() async {
        final image = await boundary.toImage(); try { final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final i = ((rect.top + 8).toInt() * image.width + rect.left.toInt() + 24) * 4;
          return [for (var c = 0; c < 4; c++) bytes.getUint8(i + c)]; } finally { image.dispose(); } }))!; } final guided = await sample();
    f.entry!.remove(); await t.pump(); final plain = await sample(); expect(plain, [112, 64, 160, 255], reason: 'positive control: sample is purple component padding');
    expect(guided, isNot(plain), reason: 'the whole background receives dim'); expect(guided[3], 255, reason: 'composited onto an opaque app');
    // Owner (pilot APK e828832b): dim FURTHER, so the old fixed hue margins (12 and 24 levels) no longer hold. The intent stays: the tint DIRECTION survives (not a
    // grey erase) and the pixel is not the bare scaffold colour, yet it moved at least halfway from the original towards the scaffold.
    final scaffold = buildTheme(Brightness.light).scaffoldBackgroundColor; final bg = [(scaffold.r * 255).round(), (scaffold.g * 255).round(), (scaffold.b * 255).round()];
    int far(List<int> px) => [for (var c = 0; c < 3; c++) (px[c] - bg[c]).abs()].reduce((a, b) => a > b ? a : b);
    expect(guided[0], greaterThan(guided[1]), reason: 'T8: purple retains red over green, not a grey erase');
    expect(guided[2], greaterThan(guided[1]), reason: 'purple retains blue over green');
    expect(far(guided), greaterThanOrEqualTo(4), reason: 'not an opaque scaffold-coloured erase patch');
    expect(far(guided), lessThanOrEqualTo(far(plain) * .5), reason: 'dimmed at least halfway to the scaffold'); });
  // WHY: P7 offers an alternative action, not merely a readable label.
  // # catches: T9 ignoring caption alternatives when planning paint, or swallowing their real input.
  // proves: CLAIM(overlay-pass-through).
  testWidgets('r2 declared alternative is legible and its pointer reaches the real control', (t) async {
    final f = R2Fixture(declarations: true); await f.pump(t); final rect = t.getRect(find.byKey(r2Alternative)); await t.tapAt(rect.center);
    await t.pump(const Duration(milliseconds: 400)); expect(f.alternatives, 1, reason: 'actual callback observed, never called by the test');
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))), isEmpty); });
  // WHY: P8 asks the user to read the named details.
  // # catches: ignoring alsoRead and keeping only the primary target.
  testWidgets('r2 caption details stay legible', (t) async { final f = R2Fixture(declarations: true); await f.pump(t);
    final rect = t.getRect(find.byKey(r2Details)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))), isEmpty); });
  // WHY: off-path r2 decision dims all page components, including their boxes.
  // # catches: W7 dimming the back arrow; step==null disables the painter and leaves the entire page full colour.
  testWidgets('r2 off path dims content and non-return chrome', (t) async { final f = R2Fixture(); await f.pump(t); await f.elsewhere(t);
    expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget); final rect = t.getRect(find.byKey(r2Other));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    // Owner round 5 item 3: with a chrome route back (the NavBar arrow) every card is dimmed, the one next to the route back too.
    expect(overlay.paintedShapes.where((s) => s.kind.name == 'dim' && s.rect.overlaps(rect.deflate(1))), isNotEmpty, reason: 'the route back\'s neighbouring card dims');
    final second = t.getRect(find.text('Second card')); expect(overlay.paintedShapes.where((s) => s.kind.name == 'dim' && s.rect.overlaps(second)), isNotEmpty);
    expect(overlay.paintedShapes.where((s) => s.kind.name != 'dim'), isEmpty, reason: 'off path: no placeholders'); final back = t.getRect(find.descendant(of: find.byType(NavBar),
      matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first); expect(overlay.paintedShapes.where((s) => s.rect.overlaps(back.deflate(.5))), isEmpty,
      reason: 'T6/W7: the arrow one route closer stays full colour'); final title = t.getRect(find.text('Elsewhere'));
    expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && s.rect.overlaps(title)), isTrue, reason: 'only back arrow, not the entire NavBar, is exempt off path'); });
  // WHY: amendment A/C keeps dimmed controls interactive even off path.
  // # catches: keeping a shield that absorbs off-path dimmed controls.
  testWidgets('r2 off path dimmed controls and route-back arrow still work', (t) async { final f = R2Fixture(); await f.pump(t);
    await f.elsewhere(t); await t.tapAt(t.getRect(find.byKey(r2Other)).center); await t.pump();
    expect(f.others, 1, reason: 'one real tap, one real callback'); await t.tapAt(const Offset(24, 28)); await f.frames(t);
    expect(find.text('Elsewhere'), findsNothing, reason: 'real NavBar back returns to step'); });
  // WHY: the explicit return action is the other full-colour off-path escape.
  // # catches: dim/shield covers Back to the guide or swallows its tap.
  testWidgets('r2 off path Back to the guide remains tappable', (t) async { final f = R2Fixture(); await f.pump(t); await f.elsewhere(t);
    await t.tap(find.byKey(GuideStepCard.backToGuideKey)); await f.frames(t); expect(f.returns, 1); expect(find.byKey(GuideStepCard.offPathKey), findsNothing); });
  for (final word in ['a', 'it', 'to', 'of', 'on', 'in', 'or', 'how', 'are', 'these', 'your', 'the', 'and', 'for']) {
    // WHY: D-S2 function words and short words cannot turn unrelated prose into a competing label. This drives the overlay, not just an oracle.
    // # catches: S2 matching any token, including stopwords and two-letter words.
    testWidgets('r2 look-alike matching ignores $word', (t) async { final f = R2Fixture(targetLabel: '$word Target', quietLabel: '$word information'); await f.pump(t);
      final rect = t.getRect(find.byKey(r2Quiet)); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(.5))) .map((s) => s.kind.name), ['dim']); }); }
  // WHY: D-S9 visual dim never hides ordinary page content from assistive tech.
  // # catches: wrapping dimmed units in ExcludeSemantics to simplify hit testing.
  testWidgets('r2 dimmed content remains in the semantics tree', (t) async { final semantics = t.ensureSemantics(); try {
      final f = R2Fixture(); await f.pump(t); expect(find.bySemanticsLabel('Quiet information'), findsOneWidget);
      expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0)); } finally {
      // Disposed here, not in a tear-down: the framework checks handles BEFORE tear-downs run (the old copy of this test failed on that, not on the behaviour it names).
      semantics.dispose(); } }); }
