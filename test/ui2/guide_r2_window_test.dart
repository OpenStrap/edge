// OWNER PLACEHOLDER RULE (2026-11-14, phone feedback on APK 09bc0763) as a design test.
//
// On a step the target's own card is lit; the card above and the card below it are dimmed; every other card is placeholder. Icons, card titles, headers and navigation are never
// placeholders. Off path: no placeholders, only dim; the route back and its neighbouring cards are lit. The dim reaches the drawn box (rounded corners), one layer per unit,
// fades in linearly over 800 ms; placeholders paint with a blend mode over the unit's own surface.
//
// This file REPLACES the distance falloff (kSkeletonReach) and large-unit (kLargeUnitHeight, isLargeUnit) rules and the tests that pinned them: 'r2 isLargeUnit ...' and
// 'r2 <guide>/open-history dims the Start session card whole ...' (guide_r2_structural_test), 'r2 <guide> open-history has zero skeleton outside its sub-tab group'
// (guide_r2_interaction_test).
//
// Every test states WHY and what it CATCHES.
import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/skeleton/skeleton.dart'; import 'package:openstrap_edge/ui2/theme.dart';
import '../support/guide_r2_fixture.dart'; import '../support/guide_r2_pixels.dart'; const _cards = ['A', 'B', 'C', 'D', 'E']; const _red = Color(0xFFFF0000);
ValueKey<String> _card(String k) => ValueKey('card-$k');
/// A page of five cards (A..E, each: title, body, an icon and a control) under a screen
/// title, with a loose status line, a day-selector bar (a GuideBox) above the first card and a
/// loose control after the last. The step's target sits in card [targetIn].
class _Page extends R2Fixture { final String targetIn;
  /// The first card starts inside the screen title's box (the Day strain bug: it touched the
  /// NavBar), and carries a chart's small clock-shaped axis labels.
  final bool tight;
  /// A red backdrop behind everything, to see a dim spill past rounded corners.
  final bool backdrop; bool _deferred; _Page({this.targetIn = 'C', this.tight = false, this.backdrop = false, bool deferStart = false})
      : _deferred = deferStart, super(brightness: Brightness.dark, size: const Size(390, 1100));
  /// Starts the guide when [deferStart] held it back (so a baseline raster can be taken).
  Future<void> begin(WidgetTester t) async { _deferred = false; await start(t); }
  /// [begin] without the settling frames, so a test can watch the first 800 ms.
  Future<void> beginQuiet(WidgetTester t) async { _deferred = false; run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: navKey, routes: routes,
        onExit: () => exits++, onBackToGuide: () { returns++; navKey.currentState!.pop(); })); navKey.currentState!.overlay!.insert(entry!); }
  @override Future<void> start(WidgetTester t) async { if (_deferred) return; await super.start(t); }
  Widget _cardOf(String k) => Surface( key: _card(k), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text('Title $k'), Text('Body $k'),
          if (tight && k == 'A') const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('00:00'), Text('12:00'), Text('24:00')]),
          Row(children: [ Icon(Icons.info_outline, key: ValueKey('icon-$k')), Pressable( key: k == targetIn ? r2Target : ValueKey('act-$k'),
              onTap: k == targetIn ? () => targets++ : () => others++, child: Text('Act $k'), ), ]), ]), );
  @override Widget get home => Scaffold( body: Stack(children: [ if (backdrop) const Positioned.fill(child: ColoredBox(color: _red)),
          Positioned(left: 16, right: 16, top: 0, child: ScreenTitle('Header')), Positioned.fill(
            child: ListView(padding: EdgeInsets.fromLTRB(16, tight ? 30 : 60, 16, 16), children: [ if (!tight) ...[
                const Text('Status line'), const SizedBox(height: 8), GuideBox( key: const ValueKey('daynav'), child: Container(
                    decoration: BoxDecoration(color: const Color(0xFF1D2632), borderRadius: R.rMd), child: Row(children: [
                      Pressable(onTap: () {}, semanticLabel: 'prev', child: const Icon(Icons.chevron_left)),
                      Expanded(child: Pressable(onTap: () {}, child: const Center(child: Text('Today')))),
                      Pressable(onTap: () {}, semanticLabel: 'next', child: const Icon(Icons.chevron_right)), ]), ), ),
                const SizedBox(height: 12), ], for (final k in _cards) ...[_cardOf(k), const SizedBox(height: 12)],
              Pressable(key: const ValueKey('log'), onTap: () => others++, child: const Text('Log a track')), ]), ), ]), ); }
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
Rect _rect(WidgetTester t, Key k) => t.getRect(find.byKey(k)); List<SkeletonShape> _over(WidgetTester t, Rect r) =>
    _overlay(t).paintedShapes.where((s) => s.rect.overlaps(r.deflate(1))).toList();
/// What the plan does to the box [r]: 'lit' (no shape), 'dim' (one whole-box dim), else 'placeholder'.
String _look(WidgetTester t, Rect r) { final over = _over(t, r); if (over.isEmpty) return 'lit';
  if (over.every((s) => s.kind == SkeletonKind.dim)) { expect(over, hasLength(1), reason: 'ONE dim layer per unit: $over');
    expect(over.single.rect, r, reason: 'the dim covers the whole drawn box'); return 'dim'; }
  expect(over.any((s) => s.kind == SkeletonKind.dim), isFalse, reason: 'a placeholder unit is never also dimmed'); return 'placeholder'; }
Future<void> _settle(WidgetTester t, _Page f) async { await f.pump(t); await t.pump(kGuideRevealDuration + const Duration(milliseconds: 100)); }
void main() { group('the three-card window', () { for (final target in ['A', 'C', 'E']) {
      // WHY: the owner rule, as a model over the position of the target's card. The card above and below (previous / next in reading order) are dimmed, the target's own
      // card stays lit, every other card is placeholder; at the ends one neighbour is missing.
      // CATCHES: a distance falloff (a nearby card that is not adjacent), the own card dimmed (the earlier reading), a card counted twice, the window not moving with the target.
      testWidgets('r2 window: target in card $target', (t) async { final f = _Page(targetIn: target); await _settle(t, f);
        final at = _cards.indexOf(target); for (final (i, k) in _cards.indexed) { final expected = i == at ? 'lit' : (i - at).abs() == 1 ? 'dim' : 'placeholder';
          expect(_look(t, _rect(t, _card(k))), expected, reason: 'card $k with the target in $target'); } }); }
    // WHY: titles are never placeholders: a placeholder card keeps its title, dimmed (one heading shape on the title's line, no bar over it).
    // CATCHES: a bar over the title, a heading on another line, no heading.
    testWidgets('r2 window: a placeholder card keeps its title as a dimmed heading', (t) async { final f = _Page(targetIn: 'C');
      await _settle(t, f); for (final k in ['A', 'E']) { final title = t.getRect(find.text('Title $k'));
        final over = _over(t, _rect(t, _card(k))); final heading = over.where((s) => s.kind == SkeletonKind.heading).toList(); expect(heading, hasLength(1), reason: 'card $k');
        expect(heading.single.rect.overlaps(title), isTrue, reason: 'the heading is the title line');
        expect(over.where((s) => (s.kind == SkeletonKind.bar || s.kind == SkeletonKind.block) && s.rect.overlaps(title.deflate(1))), isEmpty,
            reason: 'no bar over the title'); } });
    // WHY: icons are left exactly as they are: a shape of kind `icon` marks each one so no fill covers it, and no bar or block is planned over it.
    // CATCHES: icons turned into bars (the old heading rule counted them as lines), or no hole.
    testWidgets('r2 window: icons of a placeholder card are holes, never bars', (t) async { final f = _Page(targetIn: 'C');
      await _settle(t, f); for (final k in ['A', 'E']) { final icon = t.getRect(find.byKey(ValueKey('icon-$k'))); final over = _over(t, _rect(t, _card(k)));
        expect(over.where((s) => s.kind == SkeletonKind.icon && s.rect.overlaps(icon)), hasLength(1), reason: 'card $k has an icon hole');
        expect(over.where((s) => s.kind == SkeletonKind.bar && s.rect.overlaps(icon.deflate(1))), isEmpty); } });
    // WHY: the header band (everything above the first card: screen title, status line, the
    // day selector bar) is navigation, never a placeholder; a control or text after the window is. The day-selector bar is ONE unit: its arrows have no dim of their own (no seam).
    // CATCHES: the day selector as a placeholder, its arrows or label dimmed twice, the loose control after the cards left lit.
    testWidgets('r2 window: header band is dim, never placeholder; a control after the window is placeholder', (t) async {
      final f = _Page(targetIn: 'C'); await _settle(t, f); final bar = _rect(t, const ValueKey('daynav')); expect(_look(t, bar), 'dim');
      expect(_overlay(t).paintedShapes.where((s) => s.kind != SkeletonKind.dim && s.rect.overlaps(bar)), isEmpty);
      expect(_look(t, t.getRect(find.text('Status line'))), 'dim'); expect(_look(t, _rect(t, const ValueKey('log'))), 'placeholder');
      expect(_over(t, t.getRect(find.text('Header'))), isEmpty, reason: 'chrome stays lit'); });
    // WHY: on the phone NOTHING on Day strain was dimmed: its top card touched the NavBar's box
    // and carried a chart's "00:00 / 12:00 / 24:00" axis labels, which counted as live-status clocks, so the planner kept the whole card lit.
    // CATCHES: a card kept because it merely touches chrome, and small clock-shaped labels treated as a running timer.
    testWidgets('r2 window: a card touching the title box, with chart axis labels, is still dimmed', (t) async {
      final f = _Page(targetIn: 'B', tight: true); await _settle(t, f); final a = _rect(t, _card('A'));
      expect(a.top, lessThan(t.getRect(find.text('Header')).bottom), reason: 'positive control: the card overlaps the title box');
      expect(t.getRect(find.text('24:00')).height, lessThan(24), reason: 'positive control: axis labels are small');
      expect(_look(t, a), 'dim'); expect(_look(t, _rect(t, _card('B'))), 'lit'); }); }); group('off path', () {
    // WHY: off path there are no placeholders at all, only dim; the route back (NavBar arrow) alone stays
    // lit. Round 5 item 3: with a chrome route back the card next to it dims too. CATCHES: a skeleton on an off-path page, a neighbour exemption, the route dimmed.
    testWidgets('r2 off path: only dim, and only the back arrow is lit', (t) async { final f = _Page(targetIn: 'C'); await _settle(t, f);
      f.navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: Column(children: [ const NavBar('Elsewhere'),
        Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [ for (final k in ['o1', 'o2', 'o3', 'o4'])
            Padding(padding: const EdgeInsets.only(bottom: 12), child: Surface(key: ValueKey(k), child: Text('Card $k'))), ])), ]))));
      await t.pump(); await t.pump(const Duration(milliseconds: 600));
      await t.pump(kGuideRevealDuration + const Duration(milliseconds: 100)); final shapes = _overlay(t).paintedShapes; expect(shapes, isNotEmpty);
      expect(shapes.where((s) => s.kind != SkeletonKind.dim), isEmpty, reason: 'off path: no placeholders: $shapes');
      for (final k in ['o1', 'o2', 'o3', 'o4']) { expect(_look(t, _rect(t, ValueKey(k))), 'dim', reason: k); }
      final back = find.descendant(of: find.byType(NavBar), matching: find.byType(Pressable));
      expect(back, findsWidgets, reason: 'positive control: the NavBar has its back arrow');
      expect(_over(t, t.getRect(back.first)), isEmpty, reason: 'the route back is lit'); }); }); group('one layer, edges and timing', () {
    // WHY: one dim layer per unit: a Pressable inside a dimmed card has no look of its own (the phone showed darker inner rectangles and a seam at the next-day box).
    // CATCHES: nested components dimmed again, a plan that names an inner control.
    testWidgets('r2 dim: a control inside a dimmed card is not dimmed again', (t) async { final f = _Page(targetIn: 'C');
      await _settle(t, f); final looks = f.dim.looks!; Element at(Finder finder) => finder.evaluate().single; expect(looks.lookOf(at(find.byKey(_card('B')))), GuideUnitLook.dim);
      expect(looks.lookOf(at(find.byKey(const ValueKey('act-B')))), isNull, reason: 'inside B: no second layer');
      expect(looks.lookOf(at(find.byKey(const ValueKey('daynav')))), GuideUnitLook.dim);
      final arrows = find.descendant(of: find.byKey(const ValueKey('daynav')), matching: find.byType(Pressable));
      for (final arrow in arrows.evaluate()) { expect(looks.lookOf(arrow), isNull, reason: 'the day selector is one unit'); } });
    // WHY: the dim reaches the edges of the drawn box, rounded corners included: a square rect would tint the backdrop past the card's corner.
    // CATCHES: dim drawn as a plain rect over a rounded card; a dim that does not reach the edge.
    testWidgets('r2 dim: follows the rounded corners and reaches the card edge', (t) async {
      final f = _Page(targetIn: 'C', backdrop: true, deferStart: true); await f.pump(t); final b = _rect(t, _card('B'));
      final before = await r2Raster(t, find.byKey(r2Capture)); await f.begin(t);
      await t.pump(kGuideRevealDuration + const Duration(milliseconds: 100)); final after = await r2Raster(t, find.byKey(r2Capture));
      expect(_look(t, b), 'dim'); final corner = [b.left.ceil(), b.top.ceil()];
      expect(after.at(corner[0], corner[1]), before.at(corner[0], corner[1]), reason: 'outside the rounded corner: backdrop untouched');
      final edge = [b.left.ceil() + 1, (b.top + b.height / 2).round()];
      expect(after.at(edge[0], edge[1]), isNot(before.at(edge[0], edge[1])), reason: 'at the card edge: dimmed'); });
    // WHY: owner: placeholders at once on page load, the dim fades in LINEARLY over 800 ms.
    // CATCHES: a dim that is full from the first frame, a stepped or eased ramp, a placeholder that waits for the fade.
    testWidgets('r2 dim: fades in linearly over 800 ms while placeholders are there at once', (t) async {
      final f = _Page(targetIn: 'C', deferStart: true); await f.pump(t); await f.beginQuiet(t); await t.pump(); await t.pump();
      Future<int> shade() async { final b = _rect(t, _card('B')); final raster = await r2Raster(t, find.byKey(r2Capture));
        return raster.at((b.right - 6).round(), (b.bottom - 6).round())[1]; } final fade = GuideDimScope.controllerOf(t.element(find.byType(LiveGuideOverlay)))!;
      expect(_overlay(t).paintedShapes.where((s) => s.kind == SkeletonKind.bar), isNotEmpty, reason: 'placeholders at once');
      final samples = <double>[]; final shades = <int>[]; for (var i = 0; i < 4; i++) { samples.add(fade.fade); shades.add(await shade());
        await t.pump(const Duration(milliseconds: 200)); } expect(samples.first, lessThan(.3)); for (var i = 1; i < samples.length; i++) {
        expect(samples[i] - samples[i - 1], closeTo(.25, .08), reason: 'linear steps of 200 ms / 800 ms: $samples'); }
      expect(shades.first, greaterThan(shades.last), reason: 'the card darkens as it fades: $shades');
      for (var i = 1; i < shades.length; i++) { expect(shades[i], lessThanOrEqualTo(shades[i - 1]), reason: 'never lighter again: $shades'); } }); });
  group('placeholder paint', () { Future<R2Raster> paint(WidgetTester t, List<SkeletonShape> shapes, Color backdrop) async {
      final raster = await t.runAsync(() async { final recorder = ui.PictureRecorder(); final canvas = Canvas(recorder);
        canvas.drawRect(const Rect.fromLTWH(0, 0, 200, 100), Paint()..color = backdrop); paintSkeletonShapes(canvas, shapes, const P(true));
        final image = await recorder.endRecording().toImage(200, 100); final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final r = R2Raster(200, 100, data.buffer.asUint8List().toList()); image.dispose(); return r; }); return raster!; }
    // WHY: icons are never placeholders: every fill leaves a hole where an icon is. CATCHES: a surface fill, bar or block painted over an icon.
    testWidgets('r2 placeholder: an icon rect is a hole in the fill, the bar and the block', (t) async {
      const icon = Rect.fromLTWH(20, 20, 20, 20); final raster = await paint(t, const [
        SkeletonShape(kind: SkeletonKind.surface, rect: Rect.fromLTWH(0, 0, 200, 100), color: Color(0xFF0000FF), section: 0),
        SkeletonShape(kind: SkeletonKind.block, rect: Rect.fromLTWH(10, 10, 100, 60), section: 0),
        SkeletonShape(kind: SkeletonKind.bar, rect: Rect.fromLTWH(10, 15, 100, 30), section: 0),
        SkeletonShape(kind: SkeletonKind.icon, rect: icon, section: 0), ], const Color(0xFF00FF00));
      expect(raster.at(30, 30), [0, 255, 0], reason: 'inside the icon rect the original pixels show');
      expect(raster.at(150, 90), [0, 0, 255], reason: 'positive control: the fill is there outside the hole'); });
    // WHY: the bar and block tone comes from the unit's OWN surface (blend mode), so there is no
    // fixed colour pair: lighter on a dark surface, darker on a light one, a tint on a coloured one.
    // CATCHES: a bar in one fixed colour (identical over every surface), a wrong direction.
    testWidgets('r2 placeholder: bars blend with the surface under them', (t) async {
      const bar = [SkeletonShape(kind: SkeletonKind.bar, rect: Rect.fromLTWH(10, 40, 100, 20), section: 0)];
      int luma(List<int> p) => p[0] + p[1] + p[2]; final results = <Color, List<int>>{};
      for (final surface in [const Color(0xFF151C26), const Color(0xFFFFFFFF), const Color(0xFF7040A0)]) {
        final r = await paint(t, bar, surface); results[surface] = r.at(60, 50); final plain = r.at(150, 90);
        if (surface == const Color(0xFF151C26)) expect(luma(results[surface]!), greaterThan(luma(plain)), reason: 'lighter on dark');
        if (surface == const Color(0xFFFFFFFF)) expect(luma(results[surface]!), lessThan(luma(plain)), reason: 'darker on light');
        expect(results[surface], isNot(plain), reason: 'the bar is visible on $surface'); } expect(results.values.toSet(), hasLength(3), reason: 'no fixed bar colour'); }); }); }
