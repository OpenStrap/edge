import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import '../support/guide_text.dart';

const _target = ValueKey('target');
const _root = ValueKey('page-column');
Widget _card(String id, {Widget? body}) => Surface(key: ValueKey(id), child: Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [Text('Title $id'), body ?? Text('Value for $id')],
));
Element _element(WidgetTester t, String id) => t.element(find.byKey(ValueKey(id)));
SkeletonPlan _plan(WidgetTester t, {DimPolicy? policy, bool tab = false}) {
  final root = t.element(find.byKey(_root));
  final l = lookupAppLocalizations(const Locale('en'));
  final target = (tab ? GuideTarget.label(fnText((_) => 'History')) : GuideTarget.key(_target)).resolve(root, l) as TargetFound;
  return planSkeleton(root, keep: [target.rect], dim: policy ?? DimPolicy.of(root, target));
}
GuideUnitLook? _look(WidgetTester t, SkeletonPlan plan, String id) =>
  GuidePlan.from(t.element(find.byKey(_root)), plan).lookOf(_element(t, id));
Future<void> _pump(WidgetTester t, Widget child) => t.pumpWidget(MaterialApp(
  theme: buildTheme(Brightness.dark), home: Scaffold(body: child)));

void main() {
  // WHY: a visual transform does not move a unit to another layout sibling slot.
  // proves: CLAIM(guide-layout-neighbours).
  // # catches: sorting clipped/global rectangles to find cards above and below.
  testWidgets('B: neighbours follow the target column through a visual reorder', (t) async {
    await _pump(t, Column(key: _root, children: [
      _card('outside'),
      Column(children: [
        _card('above'),
        _card('own', body: const Text('Target', key: _target)),
        Transform.translate(offset: const Offset(0, -200), child: _card('below')),
      ]),
      _card('far'),
    ]));
    final plan = _plan(t);
    expect(_look(t, plan, 'own'), isNull);
    expect(_look(t, plan, 'above'), GuideUnitLook.dim);
    expect(_look(t, plan, 'below'), GuideUnitLook.dim);
    expect(_look(t, plan, 'outside'), GuideUnitLook.skeleton);
    expect(_look(t, plan, 'far'), GuideUnitLook.skeleton);
  });

  // WHY: another layout sibling may paint over the same coordinates, but it
  // cannot become the target's own card.
  // # catches: finding the target's owner by rectangle containment.
  testWidgets('B: overlapping sibling paint does not change target ownership', (t) async {
    await _pump(t, Column(key: _root, children: [
      Transform.translate(offset: const Offset(0, 64), child: _card('above')),
      _card('own', body: const Text('Target', key: _target)), _card('below'),
    ]));
    expect(t.getRect(find.byKey(const ValueKey('above'))).overlaps(t.getRect(find.byKey(const ValueKey('own')))), isTrue);
    final plan = _plan(t);
    expect(_look(t, plan, 'own'), isNull);
    expect(_look(t, plan, 'above'), GuideUnitLook.dim);
    expect(_look(t, plan, 'below'), GuideUnitLook.dim);
  });

  // WHY: a lazy page has no outer Column, and a one-card wrapper does not
  // define its neighbours. The ListView is the ordering layout.
  // # catches: stopping at an incidental one-card Column above a lazy list.
  testWidgets('B: a lazy page orders cards through one-card column wrappers', (t) async {
    await _pump(t, ListView(key: _root, children: [
      Column(children: [_card('above')]),
      Column(children: [_card('own', body: const Text('Target', key: _target))]),
      Column(children: [_card('below')]),
      Column(children: [_card('far')]),
    ]));
    final plan = _plan(t);
    expect(_look(t, plan, 'own'), isNull);
    expect(_look(t, plan, 'above'), GuideUnitLook.dim);
    expect(_look(t, plan, 'below'), GuideUnitLook.dim);
    expect(_look(t, plan, 'far'), GuideUnitLook.skeleton);
  });

  // WHY: a route-back arrow is in a header, whose next layout sibling is a card.
  // # catches: treating every non-card focus as having no card neighbours.
  testWidgets('B: a NavBar focus keeps its next card sibling lit off path', (t) async {
    await _pump(t, Column(key: _root, children: [const NavBar('Detour'), _card('first'), _card('second')]));
    final root = t.element(find.byKey(_root));
    final arrow = find.descendant(of: find.byType(NavBar), matching: find.byType(Pressable)).first;
    final focus = t.getRect(arrow);
    final plan = planSkeleton(root, keep: [focus], dim: DimPolicy(focus: focus, placeholders: false, neighboursLit: true));
    expect(_look(t, plan, 'first'), isNull);
    expect(_look(t, plan, 'second'), GuideUnitLook.dim);
  });

  // WHY: a navigation target has no content-card window.
  // # catches: keeping the first card below the sub-tabs dimmed.
  testWidgets('B: a sub-tab target makes every content card a placeholder', (t) async {
    await _pump(t, Column(key: _root, children: [
      const SubTabs(['Overview', 'History'], 0, _ignore),
      _card('first'), _card('second'), _card('third'),
    ]));
    final plan = _plan(t, tab: true);
    for (final id in ['first', 'second', 'third']) {
      expect(_look(t, plan, id), GuideUnitLook.skeleton, reason: id);
    }
  });

  // WHY: tab identity survives clipping; a tab's centre may be outside its viewport.
  // # catches: identifying navigation by rectangle containment instead of ancestry.
  testWidgets('B: a clipped sub-tab target still makes every card a placeholder', (t) async {
    t.view.physicalSize = const Size(180, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await _pump(t, Column(key: _root, children: [
      const SubTabs(['Overview', 'History'], 0, _ignore),
      _card('first'), _card('second'),
    ]));
    final plan = _plan(t, tab: true);
    expect(_look(t, plan, 'first'), GuideUnitLook.skeleton);
    expect(_look(t, plan, 'second'), GuideUnitLook.skeleton);
  });

  // WHY: original surfaces, icons and images survive the placeholder treatment.
  // proves: CLAIM(guide-placeholder-types).
  // # catches: repainting a surface, erasing text with a fill, or image blocks.
  testWidgets('C: placeholders have no background fills and leave image/icon ink alone', (t) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final image = await t.runAsync(() => recorder.endRecording().toImage(8, 8));
    await _pump(t, Column(key: _root, children: [
      _card('own', body: const Text('Target', key: _target)),
      _card('adjacent'),
      _card('placeholder', body: Row(children: [const Icon(Icons.music_note), RawImage(image: image), const Text('Log a track')])),
    ]));
    final plan = _plan(t);
    final unit = plan.units.singleWhere((u) => u.component == _element(t, 'placeholder'));
    final shapes = plan.shapes.where((s) => s.section == unit.section).toList();
    expect(shapes.where((s) => s.kind == SkeletonKind.surface || s.kind == SkeletonKind.erase), isEmpty);
    expect(shapes.where((s) => s.kind == SkeletonKind.block), isEmpty, reason: 'images are preserved, never blocks');
    expect(shapes.where((s) => s.kind == SkeletonKind.bar), isNotEmpty);
    image!.dispose();
  });

  // WHY: a chart's placeholder describes a graph without leaking axes or values.
  // # catches: rectangular chart blocks and a fixed colour unrelated to the series.
  testWidgets('C: a graph becomes one sine in its own muted line colour', (t) async {
    const line = Color(0xff4589db);
    await _pump(t, Column(key: _root, children: [
      _card('own', body: const Text('Target', key: _target)), _card('adjacent'),
      _card('graph', body: SizedBox(height: 60, width: 280, child: CustomPaint(painter: LineChart([1, 3, 2], line)))),
    ]));
    final plan = _plan(t);
    final unit = plan.units.singleWhere((u) => u.component == _element(t, 'graph'));
    final sine = plan.shapes.where((s) => s.section == unit.section && s.kind == SkeletonKind.sine);
    expect(sine, hasLength(1));
    final hsv = HSVColor.fromColor(sine.single.color!);
    final original = HSVColor.fromColor(line);
    // 8-bit pigment rounding may move hue by <1 degree.
    expect(hsv.hue, closeTo(original.hue, 1));
    expect(hsv.saturation, lessThan(original.saturation));
    expect(sine.single.rect.width, 280);
    expect(sine.single.rect.height, 60);
  });

  // WHY: a dim belongs to the whole outer card, including nested controls.
  // proves: CLAIM(off-path-one-dim).
  // # catches: planning the inner Surface or Pressable as a second dim layer.
  testWidgets('D: a dimmed nested card has exactly one owner', (t) async {
    await _pump(t, Column(key: _root, children: [
      _card('own', body: const Text('Target', key: _target)),
      _card('adjacent', body: Pressable(key: const ValueKey('control'), onTap: () {}, child: _card('inner'))),
    ]));
    final plan = _plan(t);
    expect(_look(t, plan, 'adjacent'), GuideUnitLook.dim);
    expect(_look(t, plan, 'inner'), isNull);
    expect(_look(t, plan, 'control'), isNull);
    expect(plan.units.where((u) => !u.skeleton), hasLength(1));
  });

  // WHY: clipping the true title cannot promote a body line to a live heading.
  // proves: CLAIM(guide-edge-consistency).
  // # catches: selecting a heading after clipping text lines to the viewport.
  testWidgets('E: partly clipped placeholder keeps the same title and body treatment', (t) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pump(t, SingleChildScrollView(key: _root, controller: scroll, child: Column(children: [
      _card('edge', body: const Column(children: [Text('Body must stay bars'), Text('Second body line'), SizedBox(height: 180)])),
      _card('adjacent'), _card('own', body: const Text('Target', key: _target)),
      const SizedBox(height: 800),
    ])));
    var plan = _plan(t);
    expect(_look(t, plan, 'edge'), GuideUnitLook.skeleton);
    scroll.jumpTo(40);
    await t.pump();
    plan = _plan(t);
    expect(_look(t, plan, 'edge'), GuideUnitLook.skeleton);
    final edge = plan.units.singleWhere((u) => u.component == _element(t, 'edge'));
    expect(plan.shapes.where((s) => s.section == edge.section && s.kind == SkeletonKind.heading), isEmpty,
      reason: 'the true title is clipped; body lines are never promoted');
    expect(plan.shapes.where((s) => s.section == edge.section && s.kind == SkeletonKind.bar), isNotEmpty);
  });
}
void _ignore(int _) {}
