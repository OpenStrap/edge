// The annotation lane and its place in a ChartFrame.
//
// The layout maths is pinned in chart_annotation_layout_test.dart. This file
// pins what a person sees: an icon and a DASHED line per item, bold on the
// focused one, ONE label that stays where it is while the finger moves, a
// shaded area per range in the colour of its kind, a "+n" after a crowd's one
// icon — and that the plot's RepaintBoundary (AGENTS.md §4.11) is untouched.
//
// Domain 0..300 over a 300 px lane, so one unit is one pixel. Fixed numbers
// only; nothing reads the clock.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A test that reads the one item a layout should hold must FAIL ON AN
/// ASSERTION when the layout is empty, not die with a StateError.
extension _One<T> on Iterable<T> {
  T get one {
    expect(this, hasLength(1), reason: 'expected exactly one');
    return first;
  }
}

T _pick<T>(Iterable<T> xs, bool Function(T) f) {
  final m = xs.where(f).toList();
  expect(m, isNotEmpty, reason: 'nothing matching was laid out');
  return m.first;
}

/// Geometry reads that fail on an ASSERTION when the thing was never drawn.
Rect _rect(WidgetTester t, Finder f) {
  expect(f, findsOneWidget, reason: 'not drawn');
  return t.getRect(f);
}

Offset _topLeft(WidgetTester t, Finder f) {
  expect(f, findsOneWidget, reason: 'not drawn');
  return t.getTopLeft(f);
}

Offset _centre(WidgetTester t, Finder f) {
  expect(f, findsOneWidget, reason: 'not drawn');
  return t.getCenter(f);
}

const _w = 300.0;
const _plotH = 100.0;

ChartAnnotation _pt(String id, double at,
        {AnnotationKind kind = AnnotationKind.moment, String? label}) =>
    ChartAnnotation(id: id, kind: kind, at: at, label: label ?? 'L-$id');

ChartAnnotation _range(String id, double at, double until,
        {AnnotationKind kind = AnnotationKind.workout}) =>
    ChartAnnotation(id: id, kind: kind, at: at, until: until, label: 'L-$id');

AnnotationSet _set(List<ChartAnnotation> a) =>
    AnnotationSet(items: a, domainStart: 0, domainEnd: 300);

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(child: SizedBox(width: _w, child: child)),
      ),
    );

Widget _lane(List<ChartAnnotation> a, {double? cursorPx}) => _app(
      ChartAnnotationLane(
        set: _set(a),
        cursor: cursorPx == null ? null : cursorPx / _w,
        plotHeight: _plotH,
      ),
    );

Future<void> _pumpLane(WidgetTester t, List<ChartAnnotation> a,
    {double? cursorPx}) async {
  await t.pumpWidget(_lane(a, cursorPx: cursorPx));
  await t.pump();
}

double _laneLeft(WidgetTester t) =>
    _topLeft(t, find.byKey(ChartAnnotationLane.laneKey)).dx;

double _iconCentre(WidgetTester t, String id) =>
    _centre(t, find.byKey(ChartAnnotationLane.iconKey(id))).dx - _laneLeft(t);

AnnotationIcon _icon(WidgetTester t, String id) {
  final f = find.byKey(ChartAnnotationLane.iconKey(id));
  expect(f, findsOneWidget, reason: 'no icon was drawn for "$id"');
  return t.widget<AnnotationIcon>(f);
}

List<AnnotationLine> _lines(WidgetTester t) {
  final f = find.byKey(ChartAnnotationLane.linesKey);
  expect(f, findsOneWidget, reason: 'no dashed lines were drawn');
  final cp = t.widget<CustomPaint>(f);
  return (cp.painter as AnnotationLinesPainter).lines;
}

AnnotationLine _line(WidgetTester t, String id) =>
    _pick(_lines(t), (l) => l.id == id);

Text _label(WidgetTester t) {
  final f = find.byKey(ChartAnnotationLane.labelKey);
  expect(f, findsOneWidget, reason: 'no label was drawn');
  return t.widget<Text>(f);
}

void main() {
  _dailyRangeTests();
  testWidgets(
      'a lane laid out at zero width draws nothing and does not throw '
      '(layout used to sort a const list), then draws once it has width',
      (t) async {
    Widget at(double width) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ChartAnnotationLane(
                  set: _set([_pt('a', 60)]),
                  cursor: 0.5,
                  plotHeight: _plotH,
                ),
              ),
            ),
          ),
        );
    await t.pumpWidget(at(0));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byKey(ChartAnnotationLane.iconKey('a')), findsNothing);
    // The same lane, given a plot: a chart's first layout pass can be zero
    // wide, and the mark must appear on the next one.
    await t.pumpWidget(at(_w));
    await t.pump();
    expect(find.byKey(ChartAnnotationLane.iconKey('a')), findsOneWidget);
  });
  group('icon and dashed line', () {
    testWidgets('every item has an icon of its kind on its own x', (t) async {
      await _pumpLane(t, [
        _pt('a', 60, kind: AnnotationKind.water),
        _pt('b', 200, kind: AnnotationKind.symptom),
      ]);
      expect(_icon(t, 'a').kind, AnnotationKind.water);
      expect(_icon(t, 'b').kind, AnnotationKind.symptom);
      expect(_iconCentre(t, 'a'), moreOrLessEquals(60, epsilon: 1));
      expect(_iconCentre(t, 'b'), moreOrLessEquals(200, epsilon: 1));
      expect(find.byType(AnnotationIcon), findsNWidgets(2));
    });

    testWidgets('the line is dashed, on the item, and as tall as the plot',
        (t) async {
      await _pumpLane(t, [_pt('a', 60)]);
      final l = _line(t, 'a');
      expect(l.x, moreOrLessEquals(60, epsilon: .5));
      expect(l.dashed, isTrue);
      // Dashed means many short strokes, not one long one.
      expect(
        t.renderObject(find.byKey(ChartAnnotationLane.linesKey)),
        paints
          ..line()
          ..line()
          ..line()
          ..line(),
      );
    });

    testWidgets('an unfocused item is not bold', (t) async {
      await _pumpLane(t, [_pt('a', 60)]);
      expect(_icon(t, 'a').bold, isFalse);
      expect(_line(t, 'a').bold, isFalse);
    });

    testWidgets('an icon that would sit past the edge is pulled in, its line is not',
        (t) async {
      await _pumpLane(t, [_pt('l', 0), _pt('r', 300)]);
      expect(_iconCentre(t, 'l'), moreOrLessEquals(12, epsilon: 1));
      expect(_iconCentre(t, 'r'), moreOrLessEquals(288, epsilon: 1));
      expect(_line(t, 'l').x, moreOrLessEquals(0, epsilon: .5));
      expect(_line(t, 'r').x, moreOrLessEquals(300, epsilon: .5));
    });

    testWidgets('no annotations draws nothing at all', (t) async {
      await _pumpLane(t, const []);
      expect(find.byType(AnnotationIcon), findsNothing);
      expect(find.byKey(ChartAnnotationLane.labelKey), findsNothing);
      expect(find.byKey(ChartAnnotationLane.linesKey), findsNothing,
          reason: 'a lane with nothing in it has no lines to paint');
    });

    testWidgets('items off the plot are not drawn', (t) async {
      await _pumpLane(t, [_pt('in', 100), _pt('out', 450)]);
      expect(find.byKey(ChartAnnotationLane.iconKey('in')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('out')), findsNothing);
    });

    testWidgets('icons and badges never overlap on a crowded chart', (t) async {
      // 30 items, some within a pixel of each other, some in runs.
      final a = [
        for (var i = 0; i < 30; i++)
          _pt('p$i', (i * 37 % 300).toDouble(),
              kind: AnnotationKind.values[i % 5]),
        _range('r1', 50, 120, kind: AnnotationKind.nap),
        _range('r2', 55, 90, kind: AnnotationKind.review),
      ];
      await _pumpLane(t, a);
      final rects = <Rect>[
        for (final e in find.byType(AnnotationIcon).evaluate())
          _rect(t, find.byWidget(e.widget)),
        for (final e in find.textContaining(RegExp(r'^\+\d+$')).evaluate())
          _rect(t, find.byWidget(e.widget)),
      ];
      expect(rects.length, greaterThan(2));
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse,
              reason: '${rects[i]} overlaps ${rects[j]}');
        }
      }
      final lane = _rect(t, find.byKey(ChartAnnotationLane.laneKey));
      for (final r in rects) {
        expect(r.left, greaterThanOrEqualTo(lane.left - .01));
        expect(r.right, lessThanOrEqualTo(lane.right + .01));
      }
    });
  });

  group('focus', () {
    testWidgets('the item under the cursor goes bold: icon, line and label',
        (t) async {
      await _pumpLane(t, [_pt('a', 60), _pt('b', 200)], cursorPx: 62);
      expect(_icon(t, 'a').bold, isTrue);
      expect(_line(t, 'a').bold, isTrue);
      expect(_line(t, 'a').strokeWidth, greaterThan(_line(t, 'b').strokeWidth));
      expect(_icon(t, 'b').bold, isFalse);
      expect(_line(t, 'b').bold, isFalse);
      expect(_label(t).data, 'L-a');
      expect(_label(t).style!.fontWeight!.value, greaterThanOrEqualTo(600));
    });

    testWidgets('the NEAREST item is focused when the cursor is not on one',
        (t) async {
      await _pumpLane(t, [_pt('a', 60), _pt('b', 200)], cursorPx: 150);
      expect(_icon(t, 'b').bold, isTrue);
      expect(_label(t).data, 'L-b');
    });

    testWidgets('a reach limits how far the cursor still focuses', (t) async {
      Widget lane(double px) => _app(ChartAnnotationLane(
            set: const AnnotationSet(
                items: [ChartAnnotation(
                    id: 'a',
                    kind: AnnotationKind.moment,
                    at: 60,
                    label: 'L-a')],
                domainStart: 0,
                domainEnd: 300,
                reach: 48),
            cursor: px / _w,
            plotHeight: _plotH,
          ));
      await t.pumpWidget(lane(100));
      expect(_icon(t, 'a').bold, isTrue, reason: '40 px away, inside 2 icons');
      await t.pumpWidget(lane(200));
      expect(_icon(t, 'a').bold, isFalse, reason: '140 px away');
      expect(find.byKey(ChartAnnotationLane.labelKey), findsNothing);
    });

    testWidgets('no cursor, no focus, no label', (t) async {
      await _pumpLane(t, [_pt('a', 60)]);
      expect(find.byKey(ChartAnnotationLane.labelKey), findsNothing);
    });

    testWidgets('moving the cursor moves the focus', (t) async {
      final a = [_pt('a', 60), _pt('b', 200)];
      await _pumpLane(t, a, cursorPx: 60);
      expect(_icon(t, 'a').bold, isTrue);
      await _pumpLane(t, a, cursorPx: 205);
      expect(_icon(t, 'a').bold, isFalse);
      expect(_icon(t, 'b').bold, isTrue);
      expect(_label(t).data, 'L-b');
    });

    testWidgets('bold does not change the footprint: nothing shifts on focus',
        (t) async {
      final a = [_pt('a', 60), _pt('b', 200)];
      await _pumpLane(t, a);
      final before = _rect(t, find.byKey(ChartAnnotationLane.iconKey('a')));
      final laneBefore = t.getSize(find.byKey(ChartAnnotationLane.laneKey));
      await _pumpLane(t, a, cursorPx: 60);
      expect(_rect(t, find.byKey(ChartAnnotationLane.iconKey('a'))), before);
      expect(t.getSize(find.byKey(ChartAnnotationLane.laneKey)), laneBefore,
          reason: 'the label has its own reserved room; the lane never jumps');
    });
  });

  group('the static label', () {
    testWidgets('sits in the same place whichever item is focused', (t) async {
      final a = [
        _pt('left', 20, label: 'Drank water'),
        _pt('mid', 150, label: 'Marked moment'),
        _pt('right', 280, label: 'Headache'),
      ];
      final spots = <Offset>[];
      for (final (px, text) in [
        (20.0, 'Drank water'),
        (150.0, 'Marked moment'),
        (280.0, 'Headache'),
      ]) {
        await _pumpLane(t, a, cursorPx: px);
        expect(_label(t).data, text);
        spots.add(_topLeft(t, find.byKey(ChartAnnotationLane.labelKey)));
      }
      expect(spots[1], spots[0]);
      expect(spots[2], spots[0]);
    });

    testWidgets('does not follow the finger within an item either', (t) async {
      final a = [_range('w', 50, 250, kind: AnnotationKind.workout)];
      await _pumpLane(t, a, cursorPx: 80);
      final first = _topLeft(t, find.byKey(ChartAnnotationLane.labelKey));
      await _pumpLane(t, a, cursorPx: 220);
      expect(_topLeft(t, find.byKey(ChartAnnotationLane.labelKey)), first);
    });

    testWidgets('a long label stays inside the lane', (t) async {
      await _pumpLane(
          t,
          [
            _pt('a', 290,
                label: 'A very long description of a symptom that goes on and on '
                    'and on and on and on and on and on')
          ],
          cursorPx: 290);
      final lane = _rect(t, find.byKey(ChartAnnotationLane.laneKey));
      final label = _rect(t, find.byKey(ChartAnnotationLane.labelKey));
      expect(label.left, greaterThanOrEqualTo(lane.left - .01));
      expect(label.right, lessThanOrEqualTo(lane.right + .01));
    });
  });

  group('ranges', () {
    testWidgets('a linked pair is one shaded area and ONE icon', (t) async {
      await _pumpLane(t, [_range('w', 60, 140)]);
      expect(find.byType(AnnotationIcon), findsOneWidget);
      final shade = find.byKey(ChartAnnotationLane.shadeKey('w'));
      expect(shade, findsOneWidget);
      expect(_topLeft(t, shade).dx - _laneLeft(t),
          moreOrLessEquals(60, epsilon: .5));
      expect(t.getSize(shade).width, moreOrLessEquals(80, epsilon: .5));
    });

    testWidgets('both ends of a range are dashed lines, the icon is at the start',
        (t) async {
      await _pumpLane(t, [_range('w', 60, 140)]);
      final start = _line(t, 'w'), end = _line(t, 'w:end');
      expect(start.x, moreOrLessEquals(60, epsilon: .5));
      expect(end.x, moreOrLessEquals(140, epsilon: .5));
      expect(start.dashed && end.dashed, isTrue);
      expect(_iconCentre(t, 'w'), moreOrLessEquals(60, epsilon: 1));
    });

    testWidgets('a cut end gets no line: the range did not end at the edge',
        (t) async {
      await _pumpLane(t, [_range('w', 200, 500)]);
      expect(_lines(t).map((l) => l.id), ['w']);
      await _pumpLane(t, [_range('w', -100, 120)]);
      expect(_lines(t).map((l) => l.id), ['w:end'],
          reason: 'its start is off the plot, so no start line either');
      expect(find.byKey(ChartAnnotationLane.iconKey('w')), findsOneWidget);
    });

    testWidgets('focusing a range bolds both of its lines', (t) async {
      await _pumpLane(t, [_range('w', 60, 140)], cursorPx: 100);
      expect(_line(t, 'w').bold && _line(t, 'w:end').bold, isTrue);
    });

    testWidgets('the shade takes the colour of its kind, translucent', (t) async {
      await _pumpLane(t, [
        _range('w', 10, 60, kind: AnnotationKind.workout),
        _range('n', 100, 160, kind: AnnotationKind.nap),
        _range('r', 200, 260, kind: AnnotationKind.review),
      ]);
      final colours = <String, Color>{};
      for (final (id, kind) in [
        ('w', AnnotationKind.workout),
        ('n', AnnotationKind.nap),
        ('r', AnnotationKind.review),
      ]) {
        final c = t
            .widget<ColoredBox>(find.byKey(ChartAnnotationLane.shadeKey(id)))
            .color;
        colours[id] = c;
        expect(c.a, lessThan(1), reason: 'the data behind it must still show');
        expect(c.a, greaterThan(0));
        expect(c.withValues(alpha: 1).toARGB32(),
            annotationColor(kind).toARGB32(),
            reason: '$id is a ${kind.name}');
      }
      expect({for (final c in colours.values) c.toARGB32()}.length, 3);
    });

    testWidgets('a range is clipped to the lane', (t) async {
      await _pumpLane(t, [_range('w', -100, 40), _range('x', 270, 500)]);
      final lane = _rect(t, find.byKey(ChartAnnotationLane.laneKey));
      final w = _rect(t, find.byKey(ChartAnnotationLane.shadeKey('w')));
      final x = _rect(t, find.byKey(ChartAnnotationLane.shadeKey('x')));
      expect(w.left, moreOrLessEquals(lane.left, epsilon: .5));
      expect(w.width, moreOrLessEquals(40, epsilon: .5));
      expect(x.right, moreOrLessEquals(lane.right, epsilon: .5));
    });

    testWidgets('focusing a range goes bold and says its label', (t) async {
      await _pumpLane(t, [_range('w', 60, 140)], cursorPx: 100);
      expect(_icon(t, 'w').bold, isTrue);
      expect(_label(t).data, 'L-w');
    });

    testWidgets('a range with no usable end is a point: no shade', (t) async {
      await _pumpLane(t, [
        ChartAnnotation(
            id: 'n',
            kind: AnnotationKind.nap,
            at: 100,
            until: 90,
            label: 'nap'),
      ]);
      expect(find.byKey(ChartAnnotationLane.shadeKey('n')), findsNothing);
      expect(find.byKey(ChartAnnotationLane.iconKey('n')), findsOneWidget);
    });
  });

  group('crowds collapse to one icon with +n', () {
    final crowd = [_pt('a', 100), _pt('b', 105), _pt('c', 110)];

    testWidgets('one icon, the oldest, with +2 right after it', (t) async {
      await _pumpLane(t, crowd);
      expect(find.byType(AnnotationIcon), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('a')), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      final icon = _rect(t, find.byKey(ChartAnnotationLane.iconKey('a')));
      final badge = _rect(t, find.byKey(ChartAnnotationLane.moreKey('a')));
      expect(badge.left, greaterThanOrEqualTo(icon.right - .01));
      expect(badge.left - icon.right, lessThan(8), reason: 'right after it');
      expect(badge.center.dy, moreOrLessEquals(icon.center.dy, epsilon: 4));
    });

    testWidgets('a lone item has no badge', (t) async {
      await _pumpLane(t, [_pt('a', 100)]);
      expect(find.textContaining(RegExp(r'^\+\d+$')), findsNothing);
    });

    testWidgets('focusing a hidden member reveals it, +2 stays', (t) async {
      await _pumpLane(t, crowd, cursorPx: 110);
      expect(find.byType(AnnotationIcon), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('c')), findsOneWidget);
      expect(_icon(t, 'c').bold, isTrue);
      expect(_label(t).data, 'L-c');
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('tapping the +n steps to the next member, and wraps', (t) async {
      await _pumpLane(t, crowd);
      await t.tap(find.text('+2'));
      await t.pump();
      expect(_label(t).data, 'L-a',
          reason: 'first tap reveals the shown (oldest) member');
      await t.tap(find.text('+2'));
      await t.pump();
      expect(_label(t).data, 'L-b');
      expect(find.byKey(ChartAnnotationLane.iconKey('b')), findsOneWidget);
      await t.tap(find.text('+2'));
      await t.pump();
      expect(_label(t).data, 'L-c');
      await t.tap(find.text('+2'));
      await t.pump();
      expect(_label(t).data, 'L-a', reason: 'wraps');
    });

    testWidgets('tapping the icon steps the same way', (t) async {
      await _pumpLane(t, crowd);
      await t.tap(find.byType(AnnotationIcon));
      await t.pump();
      await t.tap(find.byType(AnnotationIcon));
      await t.pump();
      expect(_label(t).data, 'L-b');
    });

    testWidgets('moving the cursor lets go of a stepped pick', (t) async {
      final a = [..._pt2(), ...crowd];
      await _pumpLane(t, a);
      await t.tap(find.text('+2'));
      await t.pump();
      await t.tap(find.text('+2'));
      await t.pump();
      expect(_label(t).data, 'L-b');
      await _pumpLane(t, a, cursorPx: 240);
      expect(_label(t).data, 'L-far');
    });
  });

  group('semantics', () {
    // Real actions, driven through the semantics tree the way a screen reader
    // drives them. A substring in one aggregate label proved nothing about
    // reaching or activating anything.
    testWidgets('each icon is its own focusable button labelled "kind, label"',
        (t) async {
      final h = t.ensureSemantics();
      await _pumpLane(t, [
        _pt('a', 60, label: 'Drank water'),
        _range('w', 120, 200, kind: AnnotationKind.workout),
        _pt('n', 250, kind: AnnotationKind.nap),
      ]);
      for (final label in ['Moment, Drank water', 'Workout, L-w', 'Nap, L-n']) {
        final node = find.semantics.byLabel(label);
        expect(node, findsOneWidget, reason: label);
        expect(
            node.evaluate().single,
            containsSemantics(
                isButton: true,
                hasTapAction: true,
                hasEnabledState: false));
      }
      expect(t.getSemantics(find.byKey(ChartAnnotationLane.laneKey)).label,
          isEmpty,
          reason: 'no flat list standing in for the controls');
      h.dispose();
    });

    testWidgets('the "+n" button steps through a cluster by semantics action, '
        'and the icon then says the member it stepped to', (t) async {
      final h = t.ensureSemantics();
      await _pumpLane(t, [
        _pt('a', 100, kind: AnnotationKind.workout),
        _pt('b', 105, kind: AnnotationKind.nap),
        _pt('c', 110),
      ]);
      final more = find.semantics.byLabel(RegExp(r'^\+2'));
      expect(more, findsOneWidget);
      expect(more.evaluate().single,
          containsSemantics(isButton: true, hasTapAction: true));
      expect(more.evaluate().single.label,
          '+2, Nap, L-b, Moment, L-c',
          reason: 'the members the icon does not show are heard too');
      expect(find.semantics.byLabel('Workout, L-a'), findsOneWidget);
      t.semantics.tap(more); // reveals the shown member
      await t.pump();
      t.semantics.tap(find.semantics.byLabel(RegExp(r'^\+2')));
      await t.pump();
      expect(find.semantics.byLabel('Nap, L-b'), findsOneWidget);
      expect(find.semantics.byLabel('Workout, L-a'), findsNothing);
      // Tapping the icon itself steps the same way.
      t.semantics.tap(find.semantics.byLabel('Nap, L-b'));
      await t.pump();
      expect(find.semantics.byLabel('Moment, L-c'), findsOneWidget);
      h.dispose();
    });

    testWidgets('the static label and the badge text add no second reading',
        (t) async {
      final h = t.ensureSemantics();
      await _pumpLane(t, [
        _pt('a', 100),
        _pt('b', 105),
      ], cursorPx: 100);
      expect(find.byKey(ChartAnnotationLane.labelKey), findsOneWidget);
      expect(find.semantics.byLabel(RegExp('L-a')), findsOneWidget,
          reason: 'spoken once, by the icon');
      expect(find.semantics.byLabel(RegExp(r'^\+1')), findsOneWidget);
      h.dispose();
    });

    testWidgets('an item that cannot have an icon is still spoken',
        (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 60,
              child: ChartAnnotationLane(
                set: AnnotationSet(items: [
                  _range('a', 0, 10),
                  _range('b', 20, 30, kind: AnnotationKind.nap),
                  _range('c', 40, 50, kind: AnnotationKind.review),
                ], domainStart: 0, domainEnd: 100),
                cursor: null,
                plotHeight: _plotH,
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      expect(find.byType(AnnotationIcon), findsNWidgets(2),
          reason: 'premise: one item got no icon');
      // Two icons, and the lane's own node for the item with none: each item
      // is spoken exactly once.
      expect(
          [
            for (final n in find.semantics.byLabel(RegExp('L-')).evaluate())
              n.label
          ]..sort(),
          ['Nap, L-b', 'Review, L-c', 'Workout, L-a']);
      h.dispose();
    });

    test('every kind has a spoken word; the localized ones differ from English',
        () {
      final es = lookupAppLocalizations(const Locale('es'));
      for (final k in AnnotationKind.values) {
        expect(annotationKindName(null, k), isNotEmpty);
        expect(annotationKindName(es, k), isNotEmpty);
      }
      expect(annotationKindName(es, AnnotationKind.moment), 'Momento');
      expect(annotationKindName(es, AnnotationKind.symptom), 'Síntoma');
      expect(annotationKindName(es, AnnotationKind.workout),
          isNot(annotationKindName(null, AnnotationKind.workout)));
    });
  });

  group('RepaintBoundary (AGENTS.md section 4.11)', () {
    testWidgets('the lane paints inside its own boundary', (t) async {
      await _pumpLane(t, [_pt('a', 60)]);
      expect(find.byKey(ChartAnnotationLane.boundaryKey), findsOneWidget);
      expect(t.widget(find.byKey(ChartAnnotationLane.boundaryKey)),
          isA<RepaintBoundary>());
    });
  });

  group('in a ChartFrame', () {
    const plotKey = ValueKey('test-plot');
    late _CountingPainter painter;

    Future<void> pumpFrame(WidgetTester t, List<ChartAnnotation> a,
        {AnnotationSet? aset, bool withAxis = true}) async {
      painter = _CountingPainter();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: _ScrubHost(
              builder: (value, set) => ChartFrame(
                title: 'Resting heart rate',
                unit: 'bpm',
                height: _plotH,
                yAxis: withAxis
                    ? AxisSpec(min: 0, max: 100, format: (v) => '${v.round()}')
                    : null,
                annotations: aset ?? _set(a),
                annotationCursor: value,
                series: const [60, 62, null, 64, 66, 65, 61],
                // Upstream's own scrub primitive drives the cursor: the
                // fork's ChartScrub does not exist here.
                child: Scrubber(
                  value: value,
                  onChanged: set,
                  label: 'Resting heart rate',
                  describe: (v) => 'day ${(v * 6).round() + 1}',
                  step: 1 / 6,
                  child: RepaintBoundary(
                    key: plotKey,
                    child: CustomPaint(size: Size.infinite, painter: painter),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('the lane lines up with the plot, not with the axis gutter',
        (t) async {
      await pumpFrame(t, [_pt('a', 0), _pt('z', 300)]);
      final lane = _rect(t, find.byKey(ChartAnnotationLane.laneKey));
      final plot = _rect(t, find.byKey(plotKey));
      expect(lane.left, moreOrLessEquals(plot.left, epsilon: .5));
      expect(lane.width, moreOrLessEquals(plot.width, epsilon: .5));
      expect(_line(t, 'a').x, moreOrLessEquals(0, epsilon: .5));
      expect(_line(t, 'z').x, moreOrLessEquals(plot.width, epsilon: .5));
    });

    testWidgets('the dashed line runs down through the plot', (t) async {
      await pumpFrame(t, [_pt('a', 150)]);
      final lines = _rect(t, find.byKey(ChartAnnotationLane.linesKey));
      final plot = _rect(t, find.byKey(plotKey));
      expect(lines.bottom, greaterThanOrEqualTo(plot.bottom - .5));
      expect(lines.top, lessThanOrEqualTo(plot.top + .5));
    });

    testWidgets('scrubbing onto an item bolds it and shows its label',
        (t) async {
      // Seven slots, domain = slot index.
      final set = const AnnotationSet(items: [
        ChartAnnotation(
            id: 'water',
            kind: AnnotationKind.water,
            at: 1,
            label: 'Drank water'),
        ChartAnnotation(
            id: 'run',
            kind: AnnotationKind.workout,
            at: 4,
            label: 'Evening run'),
      ], domainStart: 0, domainEnd: 6);
      await pumpFrame(t, const [], aset: set);
      final plot = _rect(t, find.byKey(plotKey));
      await t.tapAt(Offset(plot.left + plot.width * 4 / 6, plot.center.dy));
      await t.pump();
      expect(_icon(t, 'run').bold, isTrue);
      expect(_icon(t, 'water').bold, isFalse);
      expect(_label(t).data, 'Evening run');
      await t.tapAt(Offset(plot.left + plot.width * 1 / 6, plot.center.dy));
      await t.pump();
      expect(_icon(t, 'water').bold, isTrue);
      expect(_label(t).data, 'Drank water');
    });

    testWidgets('scrubbing repaints the lane and never the plot', (t) async {
      await pumpFrame(t, [_pt('a', 60), _pt('b', 200)]);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsOneWidget,
          reason: 'the frame must draw the annotations it was given');
      final before = painter.paints;
      expect(before, greaterThan(0));
      final plot = _rect(t, find.byKey(plotKey));
      final g = await t.startGesture(Offset(plot.left + 30, plot.center.dy));
      await t.pump();
      await g.moveTo(Offset(plot.left + 200, plot.center.dy));
      await t.pump();
      await g.up();
      await t.pump();
      expect(painter.paints, before,
          reason: 'the plot sits inside its RepaintBoundary (section 4.11); '
              'focus changes must not repaint it');
      expect(find.byKey(plotKey), findsOneWidget);
    });

    testWidgets('a frame with no annotations has no lane', (t) async {
      painter = _CountingPainter();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ChartFrame(
            title: 'x',
            unit: 'bpm',
            child: CustomPaint(size: Size.infinite, painter: painter),
          ),
        ),
      ));
      expect(find.byKey(ChartAnnotationLane.laneKey), findsNothing);
    });

    testWidgets('an empty annotation set adds no lane and no label room',
        (t) async {
      await pumpFrame(t, const []);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsNothing);
    });

    testWidgets('an algorithm-version mark is an icon with a dashed line',
        (t) async {
      final marks = algoBreakAnnotations(
          breakDaysBehind: const [2], seriesLength: 7, label: 'Algorithm v91');
      await pumpFrame(t, const [],
          aset: AnnotationSet(items: marks, domainStart: 0, domainEnd: 6));
      expect(_icon(t, marks.one.id).kind, AnnotationKind.algoVersion);
      expect(_line(t, marks.one.id).dashed, isTrue);
      final plot = _rect(t, find.byKey(plotKey));
      // 7 slots, break 2 days behind today: half a slot left of slot 4.
      expect(_line(t, marks.one.id).x,
          moreOrLessEquals(plot.width * 3.5 / 6, epsilon: .5));
    });
  });
}

/// Holds the scrub position a [Scrubber] reports and hands it back to the
/// frame, so a tap on the plot moves the annotation focus.
class _ScrubHost extends StatefulWidget {
  const _ScrubHost({required this.builder});
  final Widget Function(double? value, ValueChanged<double> set) builder;
  @override
  State<_ScrubHost> createState() => _ScrubHostState();
}

class _ScrubHostState extends State<_ScrubHost> {
  double? _v;
  @override
  Widget build(BuildContext context) =>
      widget.builder(_v, (v) => setState(() => _v = v));
}

/// Two items far from the crowd, so the cursor tests have somewhere to go.
List<ChartAnnotation> _pt2() => [_pt('far', 240)];

class _CountingPainter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0x11000000));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ── daily ranges: the rendered boundary ─────────────────────────────────────

/// Seven local days, drawn as a 0..6 slot domain over a 300 px lane (the
/// metric-detail hero's), through the SAME seam the hero uses.
const _week = [
  '2026-08-10',
  '2026-08-11',
  '2026-08-12',
  '2026-08-13',
  '2026-08-14',
  '2026-08-15',
  '2026-08-16',
];

double _sec(int d, [int h = 12]) =>
    DateTime(2026, 8, d, h).millisecondsSinceEpoch / 1000;

Widget _weekLane(List<ChartAnnotation> timed) => _app(ChartAnnotationLane(
      set: AnnotationSet(
          items: dailyAnnotations(timed, _week), domainStart: 0, domainEnd: 6),
      cursor: null,
      plotHeight: _plotH,
    ));

void _dailyRangeTests() {
  group('a daily range at the edge of its window', () {
    testWidgets('one that runs past the last day has no end edge there',
        (t) async {
      await t.pumpWidget(_weekLane([
        ChartAnnotation(
            id: 'trip',
            kind: AnnotationKind.review,
            at: _sec(15),
            until: _sec(19),
            label: 'trip'),
      ]));
      await t.pump();
      expect(_lines(t).map((l) => l.id), ['trip'],
          reason: 'the range did not end on the last visible day');
      final lane = _rect(t, find.byKey(ChartAnnotationLane.laneKey));
      final shade = _rect(t, find.byKey(ChartAnnotationLane.shadeKey('trip')));
      expect(shade.left - lane.left, moreOrLessEquals(_w * 5 / 6, epsilon: .5));
      expect(shade.right, moreOrLessEquals(lane.right, epsilon: .5),
          reason: 'it still shades to the edge of the plot');
    });

    testWidgets('one that began before the first day has no start edge there',
        (t) async {
      await t.pumpWidget(_weekLane([
        ChartAnnotation(
            id: 'trip',
            kind: AnnotationKind.review,
            at: _sec(7),
            until: _sec(12),
            label: 'trip'),
      ]));
      await t.pump();
      expect(_lines(t).map((l) => l.id), ['trip:end']);
      expect(_line(t, 'trip:end').x, moreOrLessEquals(_w * 2 / 6, epsilon: .5));
    });

    testWidgets('one that ends ON the last day keeps its end edge',
        (t) async {
      await t.pumpWidget(_weekLane([
        ChartAnnotation(
            id: 'trip',
            kind: AnnotationKind.review,
            at: _sec(15),
            until: _sec(16, 18),
            label: 'trip'),
      ]));
      await t.pump();
      expect(_lines(t).map((l) => l.id), unorderedEquals(['trip', 'trip:end']));
      expect(_line(t, 'trip:end').x, moreOrLessEquals(_w, epsilon: .5));
    });

    testWidgets('one spanning the whole window has neither edge', (t) async {
      await t.pumpWidget(_weekLane([
        ChartAnnotation(
            id: 'trip',
            kind: AnnotationKind.review,
            at: _sec(1),
            until: _sec(28),
            label: 'trip'),
      ]));
      await t.pump();
      expect(find.byKey(ChartAnnotationLane.shadeKey('trip')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.linesKey), findsNothing,
          reason: 'no edge is on the plot, so there is nothing to dash');
    });
  });
}
