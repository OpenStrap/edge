// STRUCTURAL r2 (owner, 2026-11-14, after the pilot): the dim look is how EVERY guide works. RED tests for: no look opt-in, large cards dimmed, skeleton cards
// keep a dimmed heading, the dim painted by the components themselves (GuideDimScope), per-guide caption declarations, and screen-reader parity (proxy nodes, localized
// "Move card up/down", one guide finished from announced nodes only).
//
// Every test states its WHY and `# catches:`.
import 'package:flutter/material.dart'; import 'package:flutter/semantics.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart'; import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart'; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
 import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart'; import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart' show GuideScrollBehavior;
import '../support/bundled_fonts.dart'; import '../support/guide_r2_fixture.dart'; import '../support/guide_r2_pixels.dart';
import '../support/guide_r2_scenes.dart'; import '../support/live_guide_harness.dart'; import '../support/skeleton_fixture.dart' show skLoadAppFonts;
const _capture = ValueKey('structural-capture');
/// A plan keyed by the component's own key, recording which component types asked.
class _Looks implements GuideUnitLooks { final Map<Key, GuideUnitLook> byKey; final asked = <Type>{}; _Looks(this.byKey); @override
  GuideUnitLook? lookOf(BuildContext unit) { asked.add(unit.widget.runtimeType); return byKey[unit.widget.key]; } }
Future<void> _pumpScope(WidgetTester t, GuideDimController dim, Widget body, {Size size = const Size(390, 780)}) async {
  t.view.physicalSize = size; t.view.devicePixelRatio = 1; addTearDown(t.view.reset); await t.pumpWidget(GuideDimScope(controller: dim, child: RepaintBoundary(key: _capture,
    child: MaterialApp(scrollBehavior: const GuideScrollBehavior(), theme: buildTheme(Brightness.light), debugShowCheckedModeBanner: false,
      home: Scaffold(body: body))))); await t.pump(); }
/// A caption's text as the proxy announces it (the bold markers are not read out).
String _plain(GuideStep s, AppLocalizations l) => s.caption.of(l).replaceAll('**', ''); class _TwoSessionsRepo extends GuideFakeRepo { _TwoSessionsRepo() : super(); @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async { final n = DateTime.now();
    int at(int h) => DateTime(n.year, n.month, n.day, h).millisecondsSinceEpoch ~/ 1000; return {'workouts': [
      for (final (i, h) in [7, 9].indexed) {'id': 'session-$i', 'type': 'running', 'start_ts': at(h),
        'duration_min': 40, 'strain': 8.1, 'calories': 400, 'avg_hr': 148, 'max_hr': 171}, ]}; } }
/// Every control the screen prints under [label] (a Semantics label or button text).
List<Rect> _controlsLabelled(Element page, String label) { final root = laidOutBox(page)!; final out = <Rect>[]; for (final e in onstageElements(page)) { final w = e.widget;
    Element? control; if (w is Pressable && w.semanticLabel == label || w is Semantics && w.properties.label == label) control = e;
    if (w is Text && (w.data ?? w.textSpan?.toPlainText()) == label) { e.visitAncestorElements((a) { if (a.widget is Pressable) { control = a; return false; } return true; }); }
    final box = control == null ? null : laidOutBox(control!); if (box == null) continue; final r = rectInRoot(box, root).intersect(visibleBoundsInRoot(box, root));
    if (!r.isEmpty && !out.contains(r)) out.add(r); } return out; }
/// The semantics owner that actually holds the tree: the root pipeline owner has an owner
/// without a root node in this binding, the view's own pipeline owner has the tree.
SemanticsOwner? _semanticsOwner(WidgetTester t) { for (final owner in [t.binding.renderViews.first.owner?.semanticsOwner, t.binding.rootPipelineOwner.semanticsOwner]) {
    if (owner?.rootSemanticsNode != null) return owner; } return null; }
/// Every custom action label on the semantics tree, with the node and id to perform it.
Map<String, (SemanticsNode, int)> _customActions(WidgetTester t) { final owner = _semanticsOwner(t); final out = <String, (SemanticsNode, int)>{}; void visit(SemanticsNode node) {
    for (final id in node.getSemanticsData().customSemanticsActionIds ?? const <int>[]) {
      final label = CustomSemanticsAction.getAction(id)?.label; if (label != null) out[label] = (node, id); }
    node.visitChildren((child) { visit(child); return true; }); } final root = owner?.rootSemanticsNode; if (root != null) visit(root); return out; }
void main() { setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_r2_structural.db'); }); tearDownAll(LocalDb.close);
  group('skeleton cards keep a dimmed heading', () {
    // WHY: owner item F: a skeleton card with a body still says what it is. The plan must emit ONE heading shape on the first line (the Section title, else the first text line)
    // and bars for the body.
    // # catches: bars over the heading, no heading, a heading that is not the first line,
    // body lines left as text.
    testWidgets('r2 skeleton card and Section: heading shape on the first line, body lines are bars', (t) async { final f = R2Fixture(headed: true); await f.pump(t);
      // P6 intentionally skeletonizes distant units too. Shared words alone no longer bypass reach, so move the target off screen for this heading test.
      f.targetTop.value = -200; await f.frames(t); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      for (final (key, heading, body) in [ (r2HeadedCard, 'Target notes', ['Alpha beta gamma', 'Delta epsilon zeta']),
        (r2HeadedSection, 'Target section', ['Body line one', 'Body line two']), ]) { final unit = t.getRect(find.byKey(key)); final headingRect = t.getRect(find.text(heading));
        final inside = overlay.paintedShapes.where((s) => unit.inflate(1).contains(s.rect.center)).toList();
        final headings = inside.where((s) => s.kind.name == 'heading').toList(); expect(headings, hasLength(1), reason: '$heading: one dimmed heading');
        expect(headings.single.rect.inflate(1).contains(headingRect.center), isTrue, reason: '$heading: on the first line');
        expect(inside.where((s) => s.kind.name == 'bar' && s.rect.overlaps(headingRect.deflate(1))), isEmpty,
          reason: '$heading: no bar over the heading'); for (final line in body) {
          expect(inside.any((s) => s.kind.name == 'bar' && s.rect.overlaps(t.getRect(find.text(line)).deflate(1))), isTrue,
            reason: '$line is a bar'); } expect(inside.where((s) => s.kind.name == 'erase'), isEmpty, reason: 'no erase patches'); } });
    // WHY: a plan can say "heading" while the screen still shows a bar or the full text. The user sees pixels: the heading keeps its ink at reduced contrast (<= half of the
    // original, but still visible), the body lines hold nothing but the card colour and the placeholder colour.
    // # catches: heading painted at full contrast, heading erased, body text left readable.
    testWidgets('r2 a skeleton Surface paints its heading dimmed and its body as bars itself', (t) async { final dim = GuideDimController();
      addTearDown(dim.dispose); const key = ValueKey('headed-surface');
      await _pumpScope(t, dim, const Align(alignment: Alignment.topCenter, child: Padding(padding: EdgeInsets.all(16),
        child: Surface(key: key, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Heading words'), Text('First body line'), Text('Second body line')]))))); final unit = t.getRect(find.byKey(key));
      final heading = t.getRect(find.text('Heading words')); final body = [t.getRect(find.text('First body line')), t.getRect(find.text('Second body line'))];
      final plain = await r2Raster(t, find.byKey(_capture)); final card = plain.at(unit.left.round() + 6, unit.center.dy.round());
      dim.setLooks(_Looks({key: GuideUnitLook.skeleton})); await t.pump(); final guided = await r2Raster(t, find.byKey(_capture));
      final original = r2MaxDistance(plain, heading, card); expect(original, greaterThan(100), reason: 'positive control: the heading text is dark ink on the card');
      final kept = r2MaxDistance(guided, heading, card); expect(kept, greaterThanOrEqualTo((original * .08).round()), reason: 'the heading is still there, dimmed');
      expect(kept, lessThanOrEqualTo((original * .5).round()), reason: 'at most half of the original contrast');
      // A bar is blended with the surface under it (BlendMode.difference against white).
      final line = [for (final c in card) (c * (1 - kPlaceholderStrength) + (255 - c) * kPlaceholderStrength).round()]; var barPixels = 0;
      for (final rect in body) { for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
          for (var x = rect.left.ceil(); x < rect.right.floor(); x++) { final px = guided.at(x, y); for (var c = 0; c < 3; c++) {
              final lo = card[c] < line[c] ? card[c] : line[c], hi = card[c] < line[c] ? line[c] : card[c];
              expect(px[c], inInclusiveRange(lo - 6, hi + 6), reason: 'no text ink left in a body line at ($x,$y)'); }
            if (r2Distance(px, line) <= 6) barPixels++; } } } expect(barPixels, greaterThan(80), reason: 'the body lines really are bars'); }); });
  group('the dim is painted by the component itself (GuideDimScope)', () {
    // WHY: owner design decision: the dim lives in the SAME widget structure as the dimmed content, so it scrolls, flings and overscroll-stretches with it. With no overlay
    // mounted at all, a Surface under a plan that dims it must paint the whole-box dim.
    // # catches: a regression back to overlay-painted dim (no overlay exists here), or a dim
    // over only the glyphs.
    testWidgets('r2 a Surface paints a whole-box dim from the scope; an untouched one is unchanged', (t) async { final dim = GuideDimController(); addTearDown(dim.dispose);
      const quiet = ValueKey('quiet-surface'), clear = ValueKey('clear-surface'); await _pumpScope(t, dim, Column(children: [ const SizedBox(height: 40),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Surface(key: quiet, color: const Color(0xff7040a0),
          child: const Text('Quiet', style: TextStyle(color: Colors.white)))), const SizedBox(height: 20),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Surface(key: clear, child: Text('Clear'))), ]));
      final q = t.getRect(find.byKey(quiet)), c = t.getRect(find.byKey(clear)); final plain = await r2Raster(t, find.byKey(_capture));
      dim.setLooks(_Looks({quiet: GuideUnitLook.dim})); await t.pump(); final guided = await r2Raster(t, find.byKey(_capture));
      final scaffold = r2Rgb(buildTheme(Brightness.light).scaffoldBackgroundColor);
      for (final p in [Offset(q.left + 24, q.top + 8), Offset(q.center.dx, q.bottom - 6), Offset(q.right - 30, q.center.dy)]) {
        final before = plain.at(p.dx.round(), p.dy.round()), after = guided.at(p.dx.round(), p.dy.round());
        expect(r2Distance(after, r2Veiled(before, scaffold, kDimOpacity)), lessThanOrEqualTo(3),
          reason: 'padding pixel $p: one scaffold-coloured veil at kDimOpacity over the whole box'); } for (var y = c.top.ceil(); y < c.bottom.floor(); y += 3) {
        expect(guided.at(c.center.dx.round(), y), plain.at(c.center.dx.round(), y), reason: 'the untouched Surface is unchanged'); }
      dim.clear(); await t.pump(); expect(await r2Raster(t, find.byKey(_capture)).then((r) => r.at(q.left.round() + 24, q.top.round() + 8)),
        plain.at(q.left.round() + 24, q.top.round() + 8), reason: 'clearing the plan restores the component'); });
    // WHY: the whole point of in-tree paint: it moves with whatever moves the content.
    // # catches: dim stuck at the layout position (overlay-style) under a transform or scroll.
    testWidgets('r2 the dim moves with its component under a transform and a scroll', (t) async { final dim = GuideDimController();
      addTearDown(dim.dispose); const key = ValueKey('moving-surface'); final controller = ScrollController();
      addTearDown(controller.dispose); await _pumpScope(t, dim, ListView(controller: controller, children: [ const SizedBox(height: 60),
        Transform.translate(offset: const Offset(0, 40), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 16),
          child: Surface(key: key, color: Color(0xff7040a0), child: Text('Moving', style: TextStyle(color: Colors.white))))),
        const SizedBox(height: 1500), ])); final scaffold = r2Rgb(buildTheme(Brightness.light).scaffoldBackgroundColor);
      dim.setLooks(_Looks({key: GuideUnitLook.dim})); await t.pump(); Future<void> expectDimAt(String when) async {
        final rect = t.getRect(find.byKey(key)); final px = Offset(rect.left + 24, rect.top + 8); final guided = await r2Raster(t, find.byKey(_capture));
        expect(r2Distance(guided.at(px.dx.round(), px.dy.round()), r2Veiled(const [112, 64, 160], scaffold, kDimOpacity)),
          lessThanOrEqualTo(3), reason: '$when: dim at the component\'s CURRENT position $px'); } await expectDimAt('transformed, at rest');
      controller.jumpTo(30); await t.pump(); await expectDimAt('after scrolling 30 px'); });
    // WHY: the plan is only honoured by the shared grammar components; an unlisted type would be silently left undimmed.
    // # catches: dim support on Surface only (Section titles and bare Pressables stay bright).
    testWidgets('r2 Surface, Section and Pressable all ask the scope how to draw themselves', (t) async { final dim = GuideDimController();
      addTearDown(dim.dispose); final looks = _Looks(const {}); dim.setLooks(looks); await _pumpScope(t, dim, ListView(children: [
        const Section('A section', Surface(child: Text('Body'))), Pressable(onTap: () {}, child: const Text('A bare control')), ]));
      expect(looks.asked, containsAll(<Type>[Surface, Section, Pressable])); }); }); group('declarations for the five newly covered guides', () {
    // The caption of a step that OFFERS choices names more than one control; the step declares them (P7 alsoTap) or content to read (P8 alsoRead). A step with a single
    // named control declares nothing: an over-declared step would light up the page. step: (alsoTap, alsoRead) and why.
    const expected = <String, (bool, bool)>{
      'alarm-schedule/open-alarm': (false, false), // one row to tap
      'alarm-schedule/pick-day': (true, false), // "Tap the tab of the day you want": seven day tabs
      'alarm-schedule/set-wake-time': (true, false), // every enabled day has a wake-time row
      'add-nap/open-naps': (false, false), // one button
      'add-nap/log-nap': (false, false), // one button; the two questions are the app's dialogs
      'remove-detected/open-detected': (false, false), // one card
      'remove-detected/discard': (true, false), // "Every item has its own Discard"; the row is kept with its Discard
      'fix-sleep-times/change-times': (false, false), // anyLabel already covers both labels of ONE button
      'fix-sleep-times/back-to-automatic': (false, false), // one button
      'delete-workout/open-history': (false, false), // one sub-tab
      'delete-workout/delete-session': (true, false), // "the bin at the end of the session's row": every session has one
    };
    // WHY: the table above is the contract; nothing else may drift in unnoticed.
    // # catches: a missing declaration on a step that offers choices, an over-declared
    // single-target step, a step added to the five guides without a decision here.
    test('r2 exactly the choice-offering steps declare alsoTap/alsoRead', () { final seen = <String>{};
      for (final id in ['alarm-schedule', 'add-nap', 'remove-detected', 'fix-sleep-times', 'delete-workout']) {
        for (final v in r2Guide(id).variants) { for (final step in v.steps) { final key = '$id/${step.id}'; seen.add(key);
            expect(expected.containsKey(key), isTrue, reason: '$key needs a decision in the table');
            expect((step.alsoTap.isNotEmpty, step.alsoRead.isNotEmpty), expected[key], reason: key); } } } expect(seen, expected.keys.toSet()); });
    // WHY: a declaration that resolves to nothing on the real screen keeps nothing legible.
    // # catches: alsoTap pointing at keys/labels the screen does not print, or at too little
    // (one day tab instead of seven).
    testWidgets('r2 alarm pick-day alsoTap resolves to all seven day tabs', (t) async {
      final scene = r2Scenes.firstWhere((s) => s.id == 'alarm-schedule/pick-day'); final m = await pumpR2Scene(t, scene); try {
        await settleLiveGuide(t, frames: 18); final page = m.app.runner.routes.page!; final step = m.run.variant.steps.firstWhere((s) => s.id == scene.step);
        final found = [for (final c in step.alsoTap) ...c.resolve(page, r2Locale)];         final tabs = [for (final label in [r2Locale.wellnessMon, r2Locale.wellnessTue,
          r2Locale.wellnessWed, r2Locale.wellnessThu, r2Locale.wellnessFri, r2Locale.wellnessSat, r2Locale.wellnessSun]) ..._controlsLabelled(page, label)];
        expect(tabs, hasLength(7), reason: 'positive control: the screen has seven day tabs'); for (final tab in tabs) {
          expect(found.any((f) => f.rect.overlaps(tab)), isTrue, reason: 'day tab $tab is declared'); } } finally { await disposeR2(t, m); } });
    // WHY: "Every item has its own Discard": with two pending items BOTH Discard buttons must stay legible and tappable, and tapping the one that is not the outlined target
    // does its real thing and completes the guide.
    // # catches: declaring only the first Discard, shielding the others, or ignoring an
    // offered choice for completion.
    testWidgets('r2 remove-detected/discard keeps every Discard legible and tappable', (t) async { final scene = r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard');
      final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18); final page = m.app.runner.routes.page!;
        final discards = [..._controlsLabelled(page, r2Locale.napsNotANapLabel), ..._controlsLabelled(page, r2Locale.activityNotAWorkout)];
        expect(discards.length, greaterThanOrEqualTo(2), reason: 'positive control: two items are waiting');
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final card = t.getRect(find.byKey(GuideStepCard.cardKey)); for (final d in discards) { if (card.overlaps(d)) continue;
          expect(overlay.paintedShapes.where((s) => s.rect.overlaps(d.deflate(1))), isEmpty, reason: 'Discard $d is legible'); }
        final last = discards.reduce((a, b) => a.top > b.top ? a : b); if (!card.overlaps(last)) { await t.tapAt(last.center); await settleLiveGuide(t, frames: 8);
          expect(m.run.state, isA<GuideFinished>(), reason: 'main discards immediately; either offered correction completes the guide'); } } finally { await disposeR2(t, m); } });
    // WHY: "the bin at the end of the session's row": with two sessions, the second bin is an offered choice. Same obligations as Discard.
    // # catches: only the topmost bin (the target) being tappable and legible.
    testWidgets('r2 delete-workout/delete-session keeps every session bin legible and tappable', (t) async {
      final scene = r2Scenes.firstWhere((s) => s.id == 'delete-workout/delete-session');
      // Tall enough that both session rows (about 290 px each) are on screen.
      final m = await pumpR2Scene(t, scene, repo: _TwoSessionsRepo(), size: const Size(412, 1500)); try {
        await settleLiveGuide(t, frames: 18); final page = m.app.runner.routes.page!; final bins = _controlsLabelled(page, r2Locale.workoutDeleteSessionLabel);
        expect(bins.length, 2, reason: 'positive control: two sessions, two bins'); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final card = t.getRect(find.byKey(GuideStepCard.cardKey)); final second = bins.reduce((a, b) => a.top > b.top ? a : b);
        expect(card.overlaps(second), isFalse, reason: 'the second offered bin must be tappable');
        expect(overlay.paintedShapes.where((s) => s.rect.overlaps(second.deflate(1))), isEmpty, reason: 'second bin is legible');
        await t.tapAt(second.center); await settleLiveGuide(t, frames: 8);
        expect(find.textContaining(RegExp(r'^Delete this .*\?')), findsOneWidget, reason: 'the real confirmation opened');
        expect(m.run.state, isA<GuideFinished>(), reason: 'the second offered bin also completes the step'); } finally { await disposeR2(t, m); } }); }); group('screen readers', () {
    // WHY: owner deferred these until after the pilot; now in scope. The same strings reach every language the app ships; an English fallback in German is a defect.
    // # catches: keys added to the template only, a locale falling back to English, a
    // placeholder dropped from a translation.
    test('r2 the four guide accessibility strings exist in every locale, translated', () {
      final en = lookupAppLocalizations(const Locale('en')); expect(en.guideMoveCardUp, 'Move card up');
      expect(en.guideMoveCardDown, 'Move card down'); expect(en.guideBackProxy, 'Guide: back to the path'); expect(en.guideTabProxy('Sleep'), 'Guide: open the Sleep tab');
      expect(AppLocalizations.supportedLocales.length, greaterThanOrEqualTo(7)); for (final locale in AppLocalizations.supportedLocales.where((l) => l.languageCode != 'en')) {
        final l = lookupAppLocalizations(locale); expect(l.guideMoveCardUp, isNot(en.guideMoveCardUp), reason: '$locale move up');
        expect(l.guideMoveCardDown, isNot(en.guideMoveCardDown), reason: '$locale move down');
        expect(l.guideMoveCardUp, isNot(l.guideMoveCardDown), reason: '$locale: up and down differ');
        expect(l.guideBackProxy, isNot(en.guideBackProxy), reason: '$locale back proxy'); expect(l.guideTabProxy('XYZ'), contains('XYZ'), reason: '$locale tab name placeholder');
        expect(l.guideTabProxy('XYZ'), isNot(en.guideTabProxy('XYZ')), reason: '$locale tab proxy'); } }); for (final locale in const [Locale('de'), Locale('ru'), Locale('zh')]) {
      // WHY: D-S9 an alternative to dragging for people who cannot drag; its labels follow the app's language. Today's labels are English literals.
      // # catches: hard-coded English action labels; actions that are labelled but do nothing.
      testWidgets('r2 card Move up/down actions are localized and move the card (${locale.languageCode})', (t) async {
        final handle = t.ensureSemantics(); try { final f = R2Fixture(locale: locale); await f.pump(t); final l = lookupAppLocalizations(locale); final actions = _customActions(t);
          expect(_semanticsOwner(t)?.rootSemanticsNode, isNotNull, reason: 'harness: the semantics tree is readable');
          expect(actions.keys, containsAll([l.guideMoveCardUp, l.guideMoveCardDown])); if (locale.languageCode != 'en') {
            expect(actions.keys, isNot(anyOf(contains('Move card up'), contains('Move card down'))), reason: 'no English action label under ${locale.languageCode}'); }
          final before = t.getRect(find.byKey(GuideStepCard.cardKey)); final up = actions[l.guideMoveCardUp]!;
          _semanticsOwner(t)!.performAction(up.$1.id, SemanticsAction.customAction, up.$2); await f.frames(t);
          final moved = t.getRect(find.byKey(GuideStepCard.cardKey)); expect(moved.top, lessThan(before.top));
          expect(moved.left, before.left); final down = actions[l.guideMoveCardDown]!;
          _semanticsOwner(t)!.performAction(down.$1.id, SemanticsAction.customAction, down.$2); await f.frames(t);
          expect(t.getRect(find.byKey(GuideStepCard.cardKey)).top, greaterThan(moved.top)); } finally { handle.dispose(); } }); }
    // WHY: when the highlighted control is a TAB, a screen-reader user must be able to find and activate it like the target proxy: "Guide: open the <tab> tab". It exists only
    // while that tab is the highlighted route (a proxy that is always there is noise).
    // # catches: no proxy for the focused tab, a proxy that does not activate it, a proxy
    // present on a normal step.
    testWidgets('r2 off path on the shell: the route-back tab has a "Guide: open the Today tab" proxy', (t) async {
      final handle = t.ensureSemantics(); final app = await pumpLiveGuideApp(t, size: r2Size); try {
        final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
        await settleLiveGuide(t, frames: 18); final proxy = find.semantics.byLabel(r2Locale.guideTabProxy(r2Locale.tabToday));
        expect(proxy, findsNothing, reason: 'on the path the tab is not highlighted, so there is no proxy');
        await t.tapAt(t.getRect(r2Tab(3)).center); await settleLiveGuide(t, frames: 12); expect(started.run.state, isA<GuideOffPath>());
        expect(proxy, findsOneWidget, reason: 'off path the Today tab is the highlighted route back'); t.semantics.tap(proxy); await settleLiveGuide(t, frames: 12);
        expect(started.run.currentStep?.id, 'open-strain', reason: 'the proxy performed the real tab tap'); expect(proxy, findsNothing); } finally {
        handle.dispose(); // before the end-of-test check, which runs ahead of tear-downs
        app.runner.exit(); await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } });
    // WHY: the route back on a pushed page is the NavBar arrow; it gets the target treatment visually, so it needs the matching spoken node "Guide: back to the path".
    // # catches: an outlined back arrow that a screen reader cannot find or activate.
    testWidgets('r2 off path on a pushed page: the back arrow has a "Guide: back to the path" proxy', (t) async {
      final handle = t.ensureSemantics(); final app = await pumpLiveGuideApp(t, size: r2Size); try {
        final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
        await settleLiveGuide(t, frames: 18); app.navigator.push(MaterialPageRoute<void>(builder: (_) =>
          const Scaffold(body: Column(children: [NavBar('Detour'), Text('Outside the guide')])))); await settleLiveGuide(t, frames: 12);
        expect(started.run.state, isA<GuideOffPath>()); final proxy = find.semantics.byLabel(r2Locale.guideBackProxy);
        expect(proxy, findsOneWidget); t.semantics.tap(proxy); await settleLiveGuide(t, frames: 12);
        expect(find.text('Detour'), findsNothing, reason: 'the proxy performed the real back tap');
        expect(started.run.currentStep?.id, 'open-strain'); expect(proxy, findsNothing); } finally {
        handle.dispose(); // before the end-of-test check, which runs ahead of tear-downs
        app.runner.exit(); await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } });
    // WHY: the end-to-end promise: someone who never sees the screen can finish a guide with the nodes the app announces: the target proxy of each step, and the tab proxy to get
    // back after a wrong turn. Raw pointer taps are used nowhere in this test.
    // # catches: any link in that chain missing (no target proxy, no way back, a Done card
    // that is not announced).
    testWidgets('r2 a screen-reader user finishes Delete a workout using only announced nodes', (t) async {
      final handle = t.ensureSemantics(); final app = await pumpLiveGuideApp(t, size: r2Size); try {
        final guide = r2Guide('delete-workout'); final started = await app.runner.start(guide, band: null) as GuideStarted;
        final run = started.run; await settleLiveGuide(t, frames: 18); final steps = run.variant.steps;
        SemanticsFinder targetProxy(int i) => find.semantics.byLabel(r2Locale.guideTargetProxy(_plain(steps[i], r2Locale)));
        expect(run.currentStep?.id, 'open-history'); expect(targetProxy(0), findsOneWidget, reason: 'step 1 announces its target');
        t.semantics.tap(targetProxy(0)); await settleLiveGuide(t, frames: 14); expect(run.currentStep?.id, 'delete-session');
        // A wrong turn, made through the announced tab, then the announced way back.
        _semanticsOwner(t)!.performAction(t.getSemantics(r2Tab(0)).id, SemanticsAction.tap); await settleLiveGuide(t, frames: 12);
        expect(run.state, isA<GuideOffPath>()); final back = find.semantics.byLabel(r2Locale.guideTabProxy(r2Locale.tabActivity));
        expect(back, findsOneWidget, reason: 'the way back to the path is announced'); t.semantics.tap(back);
        await settleLiveGuide(t, frames: 14); for (var guard = 0; guard < 4 && run.state is! GuideFinished; guard++) {
          final i = (run.state as GuideAtStep).index; expect(targetProxy(i), findsOneWidget, reason: 'step ${i + 1} announces its target');
          t.semantics.tap(targetProxy(i)); await settleLiveGuide(t, frames: 14); } expect(run.state, isA<GuideFinished>());
        // The last control opens the app's confirm sheet, a modal: the overlay steps aside for it (D-S9; live_guide_integration_test), so Done is announced once the user has
        // answered it. The sheet's own announced node answers it ("Keep it": nothing is deleted).
        final keep = find.semantics.byLabel(RegExp('^Keep it')); expect(keep, findsOneWidget, reason: 'the confirm sheet is announced');
        t.semantics.tap(keep); await settleLiveGuide(t, frames: 14);
        expect(find.semantics.byLabel(r2Locale.guideDoneTitle), findsOneWidget, reason: 'Done is announced'); } finally {
        handle.dispose(); // before the end-of-test check, which runs ahead of tear-downs
        app.runner.exit(); await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); }); }
