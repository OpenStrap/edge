// skeletonPlan: the pure plan behind the "Need help?" skeleton overlay.
// Hand-built trees of REAL ui2 card primitives (Surface, Section, ScreenTitle).
//
// Card rule these tests pin (lib/ui2/grammar.dart:225 Surface, :264 Section):
// a section is the OUTERMOST Surface or Section; text outside any section is
// its own unit. Geometry oracles are the engine's own line boxes (skLineRects),
// never the plan.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

const _root = ValueKey('root');
const _cardA = ValueKey('cardA');
const _cardB = ValueKey('cardB');
const _title = ValueKey('title');
const _tabs = ValueKey('tabs');

// Ahem: every glyph is a font-size square, so line widths are exact.
const _ahem = TextStyle(fontSize: 10, height: 1);

/// Title (chrome) / card A (3 text lines, one wrapped) / card B (1 line + a
/// 200x40 custom paint) / one loose line / Section C (title, action, card with
/// one line) / tab bar (chrome). Offset inside the view so root-relative
/// coordinates differ from global ones.
Widget _screen({Color? cardBColor}) => skHost(
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 30, 0, 0),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: _root,
              width: 360,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ScreenTitle('Screen title', key: _title),
                  Surface(
                    key: _cardA,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('A one', style: _ahem),
                        // 7 glyphs * 10 = 70 > 60: wraps to TWO lines.
                        SizedBox(
                          width: 60,
                          child: const Text('aaa bbb', style: _ahem, key: ValueKey('wrapped')),
                        ),
                      ],
                    ),
                  ),
                  Surface(
                    key: _cardB,
                    color: cardBColor,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('B one', style: _ahem),
                        const SizedBox(
                          width: 200,
                          height: 40,
                          child: CustomPaint(painter: SkPainter()),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('loose line', style: _ahem),
                  ),
                  Section(
                    'Sect',
                    const Surface(child: Text('C one', style: _ahem)),
                    action: 'Act',
                    onAction: () {},
                  ),
                  SizedBox(
                    key: _tabs,
                    height: 40,
                    child: const Row(
                      children: [Text('Today', style: _ahem), SizedBox(width: 20), Text('Sleep', style: _ahem)],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

/// Pumps the fixture, then plans with the rects of [keepTexts] kept (resolved
/// AFTER the pump, since rects need a laid-out tree).
Future<List<SkeletonShape>> _plan(
  WidgetTester t, {
  List<String> keepTexts = const [],
  bool withChrome = true,
  Widget? screen,
}) async {
  skTallView(t);
  await t.pumpWidget(screen ?? _screen());
  final root = find.byKey(_root);
  final keep = [for (final k in keepTexts) skLocalRect(t, find.text(k), root)];
  final chrome = withChrome
      ? [skLocalRect(t, find.byKey(_title), root), skLocalRect(t, find.byKey(_tabs), root)]
      : const <Rect>[];
  return skeletonPlan(t.element(root), keep: keep, chrome: chrome);
}

Rect _r(WidgetTester t, Finder f) => skLocalRect(t, f, find.byKey(_root));

Iterable<SkeletonShape> _of(List<SkeletonShape> p, SkeletonKind k) => p.where((s) => s.kind == k);

void main() {
  group('what becomes a shape', () {
    testWidgets('exactly: one surface per skeletonized card, one bar per text line, one block per paint',
        (t) async {
      // why: the whole contract in one count. Keep = "C one" (Section C legible);
      // chrome = title + tabs. Skeletonized: card A (3 lines: 1 + 2 wrapped),
      // card B (1 line + 1 paint), loose line (1) -> 2 surfaces, 5 bars, 1 block.
      // Fails if wrapped lines merge into one bar, if the paint is skipped, or
      // if chrome / the kept section leak shapes.
      final probe = await _plan(t);
      expect(probe, isNotEmpty, reason: 'positive control: with nothing kept, there are shapes');

      final p = await _plan(t, keepTexts: ['C one']);
      expect(_of(p, SkeletonKind.surface), hasLength(2));
      expect(_of(p, SkeletonKind.bar), hasLength(5));
      expect(_of(p, SkeletonKind.block), hasLength(1));
    });

    testWidgets('a block sits exactly on the chart / custom paint', (t) async {
      // why: visuals are blocks "at the exact rects"; a block at the card rect
      // (or missing) would hide the card's own padding or misplace the chart.
      final p = await _plan(t, keepTexts: ['C one']);
      final paint = _r(t, find.descendant(of: find.byKey(_cardB), matching: find.byType(CustomPaint)).last);
      final block = _of(p, SkeletonKind.block).single;
      expect(block.rect.left, closeTo(paint.left, 0.5));
      expect(block.rect.top, closeTo(paint.top, 0.5));
      expect(block.rect.size.width, closeTo(200, 0.5));
      expect(block.rect.size.height, closeTo(40, 0.5));
    });

    testWidgets('every other text line is covered by a bar, in root-relative coordinates', (t) async {
      // why: "every other text line covered". Oracle = the engine's own line
      // boxes for each skeletonized Text, relative to the ROOT (the root sits at
      // (20, 30) in the view, so a global-coordinate bug fails here).
      final p = await _plan(t, keepTexts: ['C one']);
      final bars = _of(p, SkeletonKind.bar).map((s) => s.rect).toList();
      final root = find.byKey(_root);
      final lines = <Rect>[
        for (final txt in ['A one', 'aaa bbb', 'B one', 'loose line']) ...skLineRects(t, find.text(txt), root),
      ];
      expect(lines, hasLength(5), reason: 'oracle sanity: 1 + 2 + 1 + 1 lines');
      for (final line in lines) {
        expect(bars.any((b) => skContains(b, line)), isTrue, reason: 'no bar covers line $line; bars=$bars');
      }
    });

    testWidgets('a wrapped paragraph gets one bar per LINE', (t) async {
      // why: one bar for the whole paragraph rect would paint over the gap and
      // misread as a different layout.
      final p = await _plan(t, keepTexts: ['C one']);
      final wrapped = skLineRects(t, find.byKey(const ValueKey('wrapped')), find.byKey(_root));
      expect(wrapped, hasLength(2));
      final inside = _of(p, SkeletonKind.bar).where((b) => wrapped.any((w) => skContains(b.rect, w)));
      expect(inside, hasLength(2));
    });

    testWidgets('two spans on one line make one bar; empty text makes none', (t) async {
      // why: getBoxesForSelection returns one box per run. Per-run bars would
      // leave seams between spans; an empty Text has no line to cover.
      skTallView(t);
      await t.pumpWidget(skHost(Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: _root,
            width: 300,
            child: Surface(
              child: Column(children: [
                Text.rich(const TextSpan(style: _ahem, children: [
                  TextSpan(text: 'one '),
                  TextSpan(text: 'two', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                ])),
                const Text('', style: _ahem),
              ]),
            ),
          ),
        ),
      )));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const []);
      expect(_of(p, SkeletonKind.bar), hasLength(1));
    });

    testWidgets('a surface shape carries its own colour (default and custom)', (t) async {
      // why: the shape repaints the card "in its own surface colour"; a fixed
      // colour would show a different card tone than the real screen.
      final custom = const Color(0xFF123456);
      final p = await _plan(t, screen: _screen(cardBColor: custom), keepTexts: ['C one']);
      final surfaces = _of(p, SkeletonKind.surface).toList();
      final a = surfaces.firstWhere((s) => skContains(s.rect, _r(t, find.text('A one'))));
      final b = surfaces.firstWhere((s) => skContains(s.rect, _r(t, find.text('B one'))));
      expect(b.color, custom);
      expect(a.color, P.of(t.element(find.byKey(_cardA))).card);
      expect(_of(p, SkeletonKind.bar).every((s) => s.color == null), isTrue);
    });

    testWidgets('a card nested in a card: two surfaces, one unit', (t) async {
      // why: RingTrio-style nesting. Only the OUTERMOST card is a section, but
      // the inner card still needs its own tone repainted.
      skTallView(t);
      await t.pumpWidget(skHost(Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: _root,
            width: 300,
            child: const Surface(
              child: Surface(elevation: 0, child: Text('inner', style: _ahem)),
            ),
          ),
        ),
      )));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const []);
      expect(_of(p, SkeletonKind.surface), hasLength(2));
      expect(p.map((s) => s.section).toSet(), {0});
      // containers before contents: the outer surface leads.
      expect(p.first.kind, SkeletonKind.surface);
      expect(p.first.rect.size.width, greaterThan(p[1].rect.size.width));
    });

    testWidgets('content scrolled out of the root bounds yields no shapes', (t) async {
      // why: shapes are in the root's paint coordinates; a card far below a
      // 200 px viewport would paint outside it (or, worse, over other widgets).
      skTallView(t);
      await t.pumpWidget(skHost(Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: _root,
            width: 300,
            height: 200,
            child: ListView(
              cacheExtent: 2000, // built, but off-screen
              children: [
                const Surface(child: Text('visible', style: _ahem)),
                const SizedBox(height: 600),
                const Surface(child: Text('far below', style: _ahem)),
              ],
            ),
          ),
        ),
      )));
      expect(find.text('far below', skipOffstage: false), findsOneWidget, reason: 'built, so the test is meaningful');
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const []);
      final bounds = const Offset(0, 0) & const Size(300, 200);
      expect(p, isNotEmpty);
      for (final s in p) {
        expect(skContains(bounds, s.rect), isTrue, reason: '${s.kind} ${s.rect} escapes $bounds');
      }
    });
  });

  group('what stays legible', () {
    testWidgets('no shape intersects a kept rect (target inside a card)', (t) async {
      // why: the headline invariant. The target must be untouched.
      await _prime(t);
      final keep = _r(t, find.text('B one'));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: [keep], chrome: _chrome(t));
      for (final s in p) {
        expect(skOverlaps(s.rect, keep), isFalse, reason: '${s.kind} ${s.rect} hits kept $keep');
      }
    });

    testWidgets('no shape intersects a kept rect that is OUTSIDE every card', (t) async {
      // why: "Set your own zones" is a bare Pressable, not in a card. The
      // overlay must not paint a bar over it just because it has no section.
      await _prime(t);
      final keep = _r(t, find.text('loose line'));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: [keep], chrome: _chrome(t));
      expect(p, isNotEmpty, reason: 'positive control: the cards are still skeletonized');
      for (final s in p) {
        expect(skOverlaps(s.rect, keep), isFalse, reason: '${s.kind} ${s.rect} hits kept $keep');
      }
    });

    testWidgets("the target's whole card stays legible, the others do not", (t) async {
      // why: mock-up step 2: the section holding the target keeps its chart and
      // heading readable. Fails if only the kept rect (not its card) is spared.
      await _prime(t);
      final keep = _r(t, find.text('B one'));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: [keep], chrome: _chrome(t));
      final cardB = _r(t, find.byKey(_cardB));
      final cardA = _r(t, find.byKey(_cardA));
      expect(p.where((s) => skOverlaps(s.rect, cardB)), isEmpty, reason: 'card B incl. its chart must be untouched');
      expect(p.where((s) => skOverlaps(s.rect, cardA)), isNotEmpty, reason: 'card A must be skeletonized');
    });

    testWidgets('a target in a Section header keeps the whole Section (title, action, card)', (t) async {
      // why: "How these are set" is the Section's ACTION, outside its card; the
      // Section's heading and card must still stay readable (mock-up step 2).
      await _prime(t);
      final keep = _r(t, find.text('Act'));
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: [keep], chrome: _chrome(t));
      final section = _r(t, find.byType(Section));
      expect(p.where((s) => skOverlaps(s.rect, section)), isEmpty);
      expect(p, isNotEmpty);
    });

    testWidgets('two kept targets keep both of their cards', (t) async {
      // why: a plan may be asked for several targets (a step with two marks).
      await _prime(t);
      final keeps = [_r(t, find.text('A one')), _r(t, find.text('B one'))];
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: keeps, chrome: _chrome(t));
      for (final id in [_cardA, _cardB]) {
        expect(p.where((s) => skOverlaps(s.rect, _r(t, find.byKey(id)))), isEmpty, reason: '$id');
      }
      expect(_of(p, SkeletonKind.bar), isNotEmpty, reason: 'loose line and Section C still skeletonized');
    });

    testWidgets('chrome stays legible, and the chrome argument is what protects it', (t) async {
      // why: title and bottom tabs stay readable. Positive control: WITHOUT the
      // chrome rects the same title / tab text becomes bars, so the argument
      // (not an accident of layout) is what spares them.
      await _prime(t);
      final title = _r(t, find.byKey(_title));
      final tabs = _r(t, find.byKey(_tabs));
      final root = t.element(find.byKey(_root));

      final without = skeletonPlan(root, keep: const []);
      expect(without.where((s) => skOverlaps(s.rect, title)), isNotEmpty);
      expect(without.where((s) => skOverlaps(s.rect, tabs)), isNotEmpty);

      final withChrome = skeletonPlan(root, keep: const [], chrome: [title, tabs]);
      expect(withChrome.where((s) => skOverlaps(s.rect, title)), isEmpty);
      expect(withChrome.where((s) => skOverlaps(s.rect, tabs)), isEmpty);
    });

    testWidgets('nothing kept, no chrome: every card is skeletonized (no silent no-op)', (t) async {
      // why: guards the degenerate plan: an empty list would trivially satisfy
      // every "no shape intersects" test above.
      await _prime(t);
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const []);
      expect(_of(p, SkeletonKind.surface), hasLength(3), reason: 'A, B and the card inside Section C');
    });
  });

  group('order', () {
    testWidgets('units ascend top to bottom and are numbered 0..N-1', (t) async {
      // why: progress reveals whole units from the top, so unit order IS the
      // visual order. Units: card A, card B, loose line, Section C = 4.
      await _prime(t);
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const [], chrome: _chrome(t));
      expect(p.map((s) => s.section).toSet(), {0, 1, 2, 3});
      // contiguous and non-decreasing along the list
      for (var i = 1; i < p.length; i++) {
        expect(p[i].section, greaterThanOrEqualTo(p[i - 1].section), reason: 'index $i');
      }
      // each unit's top is below the previous unit's top
      double top(int u) => p.where((s) => s.section == u).map((s) => s.rect.top).reduce((a, b) => a < b ? a : b);
      for (var u = 1; u < 4; u++) {
        expect(top(u), greaterThan(top(u - 1)), reason: 'unit $u');
      }
      // unit 0 is card A, unit 1 is card B (hand-checked against the fixture order)
      final a = _r(t, find.byKey(_cardA));
      final b = _r(t, find.byKey(_cardB));
      expect(p.where((s) => s.section == 0).every((s) => skContains(a, s.rect)), isTrue);
      expect(p.where((s) => s.section == 1).every((s) => skContains(b, s.rect)), isTrue);
    });

    testWidgets('inside a unit the surface comes before the bars it holds', (t) async {
      // why: painted in list order, a bar drawn before its card is hidden by it.
      await _prime(t);
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const [], chrome: _chrome(t));
      for (final surf in _of(p, SkeletonKind.surface)) {
        final i = p.indexOf(surf);
        for (final inner in p.where((s) => s.kind != SkeletonKind.surface && skContains(surf.rect, s.rect))) {
          expect(p.indexOf(inner), greaterThan(i), reason: '${inner.kind} ${inner.rect} before its card');
        }
      }
    });

    testWidgets('a kept section is absent from the numbering (units count only skeletonized ones)', (t) async {
      // why: with card B kept there are 3 units (A, loose, Section C), numbered
      // 0..2 - not 0,2,3; progress arithmetic divides by the count.
      await _prime(t);
      final p = skeletonPlan(t.element(find.byKey(_root)),
          keep: [_r(t, find.text('B one'))], chrome: _chrome(t));
      expect(p.map((s) => s.section).toSet(), {0, 1, 2});
    });
  });

  group('progress (revealedShapes, pure)', () {
    // Hand-built plan: 4 units, 2 shapes each. No widgets involved.
    final plan = [
      for (var u = 0; u < 4; u++)
        for (var k = 0; k < 2; k++)
          SkeletonShape(
            kind: k == 0 ? SkeletonKind.surface : SkeletonKind.bar,
            rect: Rect.fromLTWH(0, u * 100.0 + k * 10, 50, 8),
            section: u,
          ),
    ];

    test('0 paints nothing, 1 paints everything', () {
      // why: the two ends of the scale; 0 must be exactly empty (the overlay
      // is invisible), 1 exactly the whole plan.
      expect(revealedShapes(plan, 0), isEmpty);
      expect(revealedShapes(plan, 1), plan);
    });

    test('0.5 of 4 units reveals exactly units 0 and 1, whole', () {
      // why: "0.5 -> whole sections only": never half a card.
      final r = revealedShapes(plan, 0.5);
      expect(r, hasLength(4));
      expect(r.map((s) => s.section).toSet(), {0, 1});
      expect(r, plan.sublist(0, 4));
    });

    test('rounds DOWN: 0.74 of 4 units is still 2, 0.75 is 3', () {
      // why: floor(progress * N) so a unit never appears early. Boundary pair.
      expect(revealedShapes(plan, 0.74).map((s) => s.section).toSet(), {0, 1});
      expect(revealedShapes(plan, 0.75).map((s) => s.section).toSet(), {0, 1, 2});
    });

    test('out-of-range progress is clamped', () {
      // why: an animation overshoot (1.02) or undershoot must not throw or
      // reveal a phantom unit.
      expect(revealedShapes(plan, -0.3), isEmpty);
      expect(revealedShapes(plan, 1.7), plan);
    });

    test('an empty plan reveals an empty plan at any progress', () {
      // why: a screen with nothing to skeletonize must not divide by zero.
      expect(revealedShapes(const [], 0.5), isEmpty);
      expect(revealedShapes(const [], 1), isEmpty);
    });

    testWidgets('on a real plan, 0.5 of 4 units is whole units 0 and 1', (t) async {
      // why: ties the pure helper to the plan the widget really produces.
      await _prime(t);
      final p = skeletonPlan(t.element(find.byKey(_root)), keep: const [], chrome: _chrome(t));
      final half = revealedShapes(p, 0.5);
      expect(half.map((s) => s.section).toSet(), {0, 1});
      expect(half.length, p.where((s) => s.section < 2).length);
    });
  });
}

/// Pump the fixture and return the root finder's context holder (the tester).
Future<WidgetTester> _prime(WidgetTester t) async {
  skTallView(t);
  await t.pumpWidget(_screen());
  return t;
}

List<Rect> _chrome(WidgetTester t) => [
      skLocalRect(t, find.byKey(_title), find.byKey(_root)),
      skLocalRect(t, find.byKey(_tabs), find.byKey(_root)),
    ];
