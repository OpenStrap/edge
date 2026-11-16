// Consolidated regressions; each group retains its own test lifecycle.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart'; import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/skeleton/guide_plot.dart'; import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import 'dart:io'; import '../support/guide_r2_pixels.dart'; import 'dart:ui' as ui;
import 'package:openstrap_edge/ui2/charts.dart'; import '../support/guide_text.dart'; void _tests0() {
  // WHY: a correct rectangle plan is insufficient if the original chart still paints beneath it. The guide replaces the plot's source paint, and retains
  // the independent background paint. No raster/frame harness is involved.
  // # catches: surface erasure after normal child paint, and plan-only sines.
  testWidgets('C: replace chart source paint and preserve its own background', ( t, ) async { final controller = GuideDimController();
    addTearDown(controller.dispose); final plot = _M0Plot(); final background = _M0Background();
    const root = ValueKey('root'), target = ValueKey('target'); await t.pumpWidget( GuideDimScope( controller: controller,
        child: MaterialApp( theme: buildTheme(Brightness.dark), home: Scaffold( body: Column( key: root, children: [
                const Surface(child: Text('Target', key: target)), const Surface(child: Text('Neighbour')), Surface( child: CustomPaint(
                    painter: background, child: Column( children: [ const Text('Chart title'), SizedBox( width: 280, height: 60,
                          child: CustomPaint(painter: plot), ), ], ), ), ), ], ), ), ), ), ); expect( plot.paints, greaterThan(0),
      reason: 'positive control: original plot paints with no guide', ); final page = t.element(find.byKey(root)); final found =
        GuideTarget.key( target, ).resolve(page, lookupAppLocalizations(const Locale('en'))) as TargetFound;
    plot.paints = background.paints = 0; controller.setLooks( GuidePlan.from( page,
        planSkeleton(page, keep: [found.rect], dim: DimPolicy.of(page, found)), ), ); await t.pump(); expect( plot.paints, 0,
      reason: 'no original chart, axes or labels paint under the sine', ); expect( background.paints, greaterThan(0),
      reason: 'the existing decoration still supplies its background', ); controller.clear(); await t.pump(); expect( plot.paints,
      greaterThan(0), reason: 'ending the guide restores original chart painting', ); }); }
class _M0Plot extends CustomPainter implements GuidePlot { int paints = 0; @override Color get guideLineColor => C.blue; @override
  void paint(Canvas canvas, Size size) { paints++; canvas.drawLine( Offset.zero, size.bottomRight(Offset.zero), Paint()..color = C.blue, ); }
  @override bool shouldRepaint(_M0Plot oldDelegate) => true; }
class _M0Background extends CustomPainter implements GuideDecoration { int paints = 0; @override void paint(Canvas canvas, Size size) {
    paints++; canvas.drawRect(Offset.zero & size, Paint()..color = C.purple); } @override bool shouldRepaint(_M0Background oldDelegate) => true; }
final _m1Declaration = RegExp(r'class\s+(\w+)\s+extends\s+CustomPainter\b([^{]*)\{'); final _m1Classes = RegExp(r'\b(GuidePlot|GuideRing|GuideDecoration|GuidePlotOverlay)\b');
/// The painters of [source] that declare no placeholder treatment.
List<String> _m1Unclassified(String source) => [ for (final m in _m1Declaration.allMatches(source)) if (!_m1Classes.hasMatch(m.group(2)!)) m.group(1)!, ];
Map<String, String> _m1Painters() { final found = <String, String>{};
  for (final f in Directory('lib/ui2').listSync(recursive: true).whereType<File>()) { if (!f.path.endsWith('.dart')) continue;
    for (final m in _m1Declaration.allMatches(f.readAsStringSync())) { found[m.group(1)!] = m.group(2)!; } } return found; } void _tests1() {
  // WHY: owner review R3. A painter that draws data and was never classified leaks its real values into a placeholder, and nothing noticed the next one. Every CustomPainter
  // in lib/ui2 declares one of GuidePlot / GuideRing / GuideDecoration / GuidePlotOverlay.
  // # catches: a new chart painter added without a placeholder treatment.
  test('R3: every CustomPainter in lib/ui2 declares its placeholder treatment', () { final all = _m1Painters();
    expect(all.keys, containsAll(['LineChart', 'EcgWaveformPainter', 'Elevation', 'RouteMap', '_GuidePainter']),
      reason: 'positive control: the scan sees painters in many files'); expect(all.length, greaterThan(20));
    expect(_m1Unclassified('class _New extends CustomPainter {\n}'), ['_New'], reason: 'the check rejects an undeclared painter');
    expect(_m1Unclassified('class _Old extends CustomPainter implements GuideDecoration {}'), isEmpty);
    expect([for (final e in all.entries) if (!_m1Classes.hasMatch(e.value)) e.key], isEmpty,
      reason: 'declare implements GuidePlot (data), GuideRing (dial), GuidePlotOverlay (marks over a plot) or GuideDecoration (no data)'); });
  // WHY: the allow-list for decoration must not become the way out of the guard: these painters draw the user's data (review R3) and must stay plots.
  // # catches: silencing the guard by calling a data painter a decoration.
  test('R3: the painters named in the review are plots, not decorations', () { const data = ['EcgWaveformPainter', 'EcgLivePainter', 'Elevation', 'RouteMap', 'IntervalLadder', '_SideStrip', 'PosterMap', 'BreathRing', 'LineChart', 'Bars', 'Ring'];
    final all = _m1Painters(); for (final name in data) { expect(all[name], matches(RegExp(r'GuidePlot|GuideRing')), reason: name); } });
  // WHY: a painter nobody classified must not draw its values in a placeholder; one that is declared decoration is left alone; a plot is replaced; a dial becomes an empty
  // ring and a chart a wave. The runtime default is the safety net behind the guard.
  // # catches: unclassified painters painting real data under the placeholder.
  testWidgets('R3/R9: placeholder paint hides unclassified painters, keeps decoration, ring is empty and chart is a wave', (t) async {
    final controller = GuideDimController(); addTearDown(controller.dispose); final unknown = _M1Probe(), decoration = _M1Probe(), plot = _M1Probe(), dial = _M1Probe();
    const root = ValueKey('root'), boundary = ValueKey('boundary');
    final ringBox = GlobalKey(), waveBox = GlobalKey(), surface = GlobalKey(); t.view.physicalSize = const Size(400, 600); t.view.devicePixelRatio = 1; addTearDown(t.view.reset);
    Widget paint(CustomPainter p, {Key? key}) => Center(child: SizedBox(key: key, width: 80, height: 80, child: CustomPaint(painter: p)));
    await t.pumpWidget(GuideDimScope( controller: controller, child: MaterialApp( theme: buildTheme(Brightness.dark),
        home: Scaffold(body: RepaintBoundary(key: boundary, child: Column(key: root, children: [
          Surface(child: paint(_M1Unknown(unknown))), Surface(child: paint(_M1Decor(decoration))),
          Surface(child: paint(_M1Wave(plot), key: waveBox)), Surface(key: surface, child: paint(_M1Dial(dial), key: ringBox)), ]))), ),
    )); for (final probe in [unknown, decoration, plot, dial]) { expect(probe.paints, greaterThan(0), reason: 'positive control: paints with no guide'); probe.paints = 0; }
    final page = t.element(find.byKey(root)); controller.setLooks(GuidePlan.from(page, planSkeleton(page, keep: const [], chrome: const [],
      dim: const DimPolicy(skeletonAll: true)), skeletonAll: true)); await t.pump(); expect(unknown.paints, 0, reason: 'unclassified: no data under the placeholder');
    expect(plot.paints, 0, reason: 'a plot is replaced by its wave'); expect(dial.paints, 0, reason: 'a dial is replaced by its ring track');
    expect(decoration.paints, greaterThan(0), reason: 'a decoration is left as it is');
    final raster = await r2Raster(t, find.byKey(boundary)); List<int> pixel(GlobalKey box, Offset at) {
      final rect = t.getRect(find.byKey(box)); return raster.at((rect.left + at.dx).round(), (rect.top + at.dy).round()); } final card = r2Rgb(P(true).card);
    // Ring: empty in the middle, coloured on the circle. Wave: the line crosses the middle.
    expect(r2Distance(pixel(ringBox, const Offset(40, 40)), card), lessThan(4), reason: 'the ring track is empty (no arc, no value)');
    final onRing = [for (var x = 62; x <= 76; x++) pixel(ringBox, Offset(x.toDouble(), 40))] .any((px) => r2Distance(px, card) > 6);
    expect(onRing, isTrue, reason: 'the ring track is drawn');
    final waveMiddle = [for (var y = 38; y <= 42; y++) pixel(waveBox, Offset(40, y.toDouble()))] .any((px) => r2Distance(px, card) > 6);
    expect(waveMiddle, isTrue, reason: 'a chart becomes one wave through its middle'); controller.clear(); await t.pump();
    expect(unknown.paints, greaterThan(0), reason: 'ending the guide restores the painter'); }); } class _M1Probe { int paints = 0; }
class _M1Unknown extends CustomPainter { _M1Unknown(this.probe); final _M1Probe probe; @override void paint(Canvas canvas, Size size) {
    probe.paints++; canvas.drawLine(Offset.zero, size.bottomRight(Offset.zero), Paint()..color = C.red..strokeWidth = 4); } @override bool shouldRepaint(_M1Unknown old) => true; }
class _M1Decor extends _M1Unknown implements GuideDecoration { _M1Decor(super.probe); }
class _M1Wave extends _M1Unknown implements GuidePlot { _M1Wave(super.probe); @override Color get guideLineColor => C.blue; }
class _M1Dial extends _M1Unknown implements GuideRing { _M1Dial(super.probe); @override Color get guideLineColor => C.green; }
const _m2Target = ValueKey('target'); const _m2Root = ValueKey('page-column');
Widget _m2Card(String id, {Widget? body}) => Surface(key: ValueKey(id), child: Column( crossAxisAlignment: CrossAxisAlignment.start,
  children: [Text('Title $id'), body ?? Text('Value for $id')], )); Element _m2Element(WidgetTester t, String id) => t.element(find.byKey(ValueKey(id)));
SkeletonPlan _m2Plan(WidgetTester t, {DimPolicy? policy, bool tab = false}) { final root = t.element(find.byKey(_m2Root)); final l = lookupAppLocalizations(const Locale('en'));
  final target = (tab ? GuideTarget.label(fnText((_) => 'History')) : GuideTarget.key(_m2Target)).resolve(root, l) as TargetFound;
  return planSkeleton(root, keep: [target.rect], dim: policy ?? DimPolicy.of(root, target)); } GuideUnitLook? _m2Look(WidgetTester t, SkeletonPlan plan, String id) =>
  GuidePlan.from(t.element(find.byKey(_m2Root)), plan).lookOf(_m2Element(t, id)); Future<void> _m2Pump(WidgetTester t, Widget child) => t.pumpWidget(MaterialApp(
  theme: buildTheme(Brightness.dark), home: Scaffold(body: child))); void _tests2() {
  // WHY: a visual transform does not move a unit to another layout sibling slot.
  // proves: CLAIM(guide-layout-neighbours).
  // # catches: sorting clipped/global rectangles to find cards above and below.
  testWidgets('B: neighbours follow the target column through a visual reorder', (t) async {
    await _m2Pump(t, Column(key: _m2Root, children: [ _m2Card('outside'), Column(children: [ _m2Card('above'), _m2Card('own', body: const Text('Target', key: _m2Target)),
        Transform.translate(offset: const Offset(0, -200), child: _m2Card('below')), ]), _m2Card('far'), ])); final plan = _m2Plan(t);
    expect(_m2Look(t, plan, 'own'), isNull); expect(_m2Look(t, plan, 'above'), GuideUnitLook.dim);
    expect(_m2Look(t, plan, 'below'), GuideUnitLook.dim); expect(_m2Look(t, plan, 'outside'), GuideUnitLook.skeleton); expect(_m2Look(t, plan, 'far'), GuideUnitLook.skeleton); });
  // WHY: another layout sibling may paint over the same coordinates, but it cannot become the target's own card.
  // # catches: finding the target's owner by rectangle containment.
  testWidgets('B: overlapping sibling paint does not change target ownership', (t) async {
    await _m2Pump(t, Column(key: _m2Root, children: [ Transform.translate(offset: const Offset(0, 64), child: _m2Card('above')),
      _m2Card('own', body: const Text('Target', key: _m2Target)), _m2Card('below'), ]));
    expect(t.getRect(find.byKey(const ValueKey('above'))).overlaps(t.getRect(find.byKey(const ValueKey('own')))), isTrue);
    final plan = _m2Plan(t); expect(_m2Look(t, plan, 'own'), isNull); expect(_m2Look(t, plan, 'above'), GuideUnitLook.dim);
    expect(_m2Look(t, plan, 'below'), GuideUnitLook.dim); });
  // WHY: a lazy page has no outer Column, and a one-card wrapper does not define its neighbours. The ListView is the ordering layout.
  // # catches: stopping at an incidental one-card Column above a lazy list.
  testWidgets('B: a lazy page orders cards through one-card column wrappers', (t) async { await _m2Pump(t, ListView(key: _m2Root, children: [ Column(children: [_m2Card('above')]),
      Column(children: [_m2Card('own', body: const Text('Target', key: _m2Target))]), Column(children: [_m2Card('below')]),
      Column(children: [_m2Card('far')]), ])); final plan = _m2Plan(t); expect(_m2Look(t, plan, 'own'), isNull);
    expect(_m2Look(t, plan, 'above'), GuideUnitLook.dim); expect(_m2Look(t, plan, 'below'), GuideUnitLook.dim); expect(_m2Look(t, plan, 'far'), GuideUnitLook.skeleton); });
  // WHY: a route-back arrow is in a header, whose next layout sibling is a card.
  // # catches: treating every non-card focus as having no card neighbours.
  testWidgets('B: a NavBar focus keeps its next card sibling lit off path', (t) async {
    await _m2Pump(t, Column(key: _m2Root, children: [const NavBar('Detour'), _m2Card('first'), _m2Card('second')])); final root = t.element(find.byKey(_m2Root));
    final arrow = find.descendant(of: find.byType(NavBar), matching: find.byType(Pressable)).first; final focus = t.getRect(arrow);
    final plan = planSkeleton(root, keep: [focus], dim: DimPolicy(focus: focus, placeholders: false, neighboursLit: true));
    expect(_m2Look(t, plan, 'first'), isNull); expect(_m2Look(t, plan, 'second'), GuideUnitLook.dim); });
  // WHY: a navigation target has no content-card window.
  // # catches: keeping the first card below the sub-tabs dimmed.
  testWidgets('B: a sub-tab target makes every content card a placeholder', (t) async { await _m2Pump(t, Column(key: _m2Root, children: [
      const SubTabs(['Overview', 'History'], 0, _m2Ignore), _m2Card('first'), _m2Card('second'), _m2Card('third'), ]));
    final plan = _m2Plan(t, tab: true); for (final id in ['first', 'second', 'third']) { expect(_m2Look(t, plan, id), GuideUnitLook.skeleton, reason: id); } });
  // WHY: tab identity survives clipping; a tab's centre may be outside its viewport.
  // # catches: identifying navigation by rectangle containment instead of ancestry.
  testWidgets('B: a clipped sub-tab target still makes every card a placeholder', (t) async { t.view.physicalSize = const Size(180, 600);
    t.view.devicePixelRatio = 1; addTearDown(t.view.reset); await _m2Pump(t, Column(key: _m2Root, children: [
      const SubTabs(['Overview', 'History'], 0, _m2Ignore), _m2Card('first'), _m2Card('second'), ]));
    final plan = _m2Plan(t, tab: true); expect(_m2Look(t, plan, 'first'), GuideUnitLook.skeleton); expect(_m2Look(t, plan, 'second'), GuideUnitLook.skeleton); });
  // WHY: original surfaces, icons and images survive the placeholder treatment.
  // proves: CLAIM(guide-placeholder-types).
  // # catches: repainting a surface, erasing text with a fill, or image blocks.
  testWidgets('C: placeholders have no background fills and leave image/icon ink alone', (t) async { final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.red, BlendMode.src); final image = await t.runAsync(() => recorder.endRecording().toImage(8, 8));
    await _m2Pump(t, Column(key: _m2Root, children: [ _m2Card('own', body: const Text('Target', key: _m2Target)), _m2Card('adjacent'),
      _m2Card('placeholder', body: Row(children: [const Icon(Icons.music_note), RawImage(image: image), const Text('Log a track')])), ]));
    final plan = _m2Plan(t); final unit = plan.units.singleWhere((u) => u.component == _m2Element(t, 'placeholder'));
    final shapes = plan.shapes.where((s) => s.section == unit.section).toList();
    expect(shapes.where((s) => s.kind == SkeletonKind.surface || s.kind == SkeletonKind.erase), isEmpty);
    expect(shapes.where((s) => s.kind == SkeletonKind.block), isEmpty, reason: 'images are preserved, never blocks');
    expect(shapes.where((s) => s.kind == SkeletonKind.bar), isNotEmpty); image!.dispose(); });
  // WHY: a chart's placeholder describes a graph without leaking axes or values.
  // # catches: rectangular chart blocks and a fixed colour unrelated to the series.
  testWidgets('C: a graph becomes one sine in its own muted line colour', (t) async { const line = Color(0xff4589db);
    await _m2Pump(t, Column(key: _m2Root, children: [ _m2Card('own', body: const Text('Target', key: _m2Target)), _m2Card('adjacent'),
      _m2Card('graph', body: SizedBox(height: 60, width: 280, child: CustomPaint(painter: LineChart([1, 3, 2], line)))), ]));
    final plan = _m2Plan(t); final unit = plan.units.singleWhere((u) => u.component == _m2Element(t, 'graph'));
    final sine = plan.shapes.where((s) => s.section == unit.section && s.kind == SkeletonKind.sine); expect(sine, hasLength(1));
    final hsv = HSVColor.fromColor(sine.single.color!); final original = HSVColor.fromColor(line);
    // 8-bit pigment rounding may move hue by <1 degree.
    expect(hsv.hue, closeTo(original.hue, 1)); expect(hsv.saturation, lessThan(original.saturation)); expect(sine.single.rect.width, 280); expect(sine.single.rect.height, 60); });
  // WHY: a dim belongs to the whole outer card, including nested controls.
  // proves: CLAIM(off-path-one-dim).
  // # catches: planning the inner Surface or Pressable as a second dim layer.
  testWidgets('D: a dimmed nested card has exactly one owner', (t) async { await _m2Pump(t, Column(key: _m2Root, children: [
      _m2Card('own', body: const Text('Target', key: _m2Target)), _m2Card('adjacent', body: Pressable(key: const ValueKey('control'), onTap: () {}, child: _m2Card('inner'))), ]));
    final plan = _m2Plan(t); expect(_m2Look(t, plan, 'adjacent'), GuideUnitLook.dim); expect(_m2Look(t, plan, 'inner'), isNull);
    expect(_m2Look(t, plan, 'control'), isNull); expect(plan.units.where((u) => !u.skeleton), hasLength(1)); });
  // WHY: clipping the true title cannot promote a body line to a live heading.
  // proves: CLAIM(guide-edge-consistency).
  // # catches: selecting a heading after clipping text lines to the viewport.
  testWidgets('E: partly clipped placeholder keeps the same title and body treatment', (t) async { final scroll = ScrollController();
    addTearDown(scroll.dispose); await _m2Pump(t, SingleChildScrollView(key: _m2Root, controller: scroll, child: Column(children: [
      _m2Card('edge', body: const Column(children: [Text('Body must stay bars'), Text('Second body line'), SizedBox(height: 180)])),
      _m2Card('adjacent'), _m2Card('own', body: const Text('Target', key: _m2Target)), const SizedBox(height: 800), ])));
    var plan = _m2Plan(t); expect(_m2Look(t, plan, 'edge'), GuideUnitLook.skeleton); scroll.jumpTo(40); await t.pump();
    plan = _m2Plan(t); expect(_m2Look(t, plan, 'edge'), GuideUnitLook.skeleton); final edge = plan.units.singleWhere((u) => u.component == _m2Element(t, 'edge'));
    expect(plan.shapes.where((s) => s.section == edge.section && s.kind == SkeletonKind.heading), isEmpty, reason: 'the true title is clipped; body lines are never promoted');
    expect(plan.shapes.where((s) => s.section == edge.section && s.kind == SkeletonKind.bar), isNotEmpty); }); } void _m2Ignore(int _) {}
void main() { group('guide_r3_paint', _tests0); group('guide_r3_painters', _tests1); group('guide_r3_structure', _tests2); }
