// The pure annotation layout: annotations + pixel scale + focus -> placed
// icons, "+n" clusters, shaded ranges and one static label.
//
// Everything here is arithmetic on numbers, so the rules that make a chart
// honest are pinned without a frame: icons never overlap, a crowd collapses to
// ONE icon (the focused member, else the OLDEST) with "+n", a linked start/end
// pair is a shaded area with one icon, and nothing is ever invented — an item
// the chart cannot show is dropped or reported, never moved onto the plot.
//
// Pixel maths is easy to read on purpose: domain 0..300 over 300 px, so one
// domain unit is one pixel; the icon is 24 px wide and the "+n" badge 22.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';

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

const _scale = AnnotationScale(domainStart: 0, domainEnd: 300, width: 300);

ChartAnnotation _pt(String id, double at,
        {AnnotationKind kind = AnnotationKind.moment, String? label}) =>
    ChartAnnotation(id: id, kind: kind, at: at, label: label ?? 'L-$id');

ChartAnnotation _range(String id, double at, double until,
        {AnnotationKind kind = AnnotationKind.workout}) =>
    ChartAnnotation(
        id: id, kind: kind, at: at, until: until, label: 'L-$id');

AnnotationLayout _lay(List<ChartAnnotation> a,
        {String? focus, AnnotationScale scale = _scale}) =>
    layoutAnnotations(annotations: a, scale: scale, focusId: focus);

Iterable<String> _allIds(AnnotationLayout l) =>
    [for (final i in l.items) ...i.memberIds, ...l.unplaced];

void _expectNoOverlapInBounds(AnnotationLayout l, double width) {
  for (var i = 0; i < l.items.length; i++) {
    final a = l.items[i];
    expect(a.iconLeft, greaterThanOrEqualTo(-1e-9), reason: 'left of the plot');
    expect(a.footprintRight, lessThanOrEqualTo(width + 1e-9),
        reason: 'right of the plot');
    for (var j = i + 1; j < l.items.length; j++) {
      final b = l.items[j];
      final apart = a.footprintRight <= b.iconLeft + 1e-9 ||
          b.footprintRight <= a.iconLeft + 1e-9;
      expect(apart, isTrue,
          reason: '${a.id} [${a.iconLeft}, ${a.footprintRight}] overlaps '
              '${b.id} [${b.iconLeft}, ${b.footprintRight}]');
    }
  }
}

void main() {
  group('scale', () {
    test('xOf is linear from the domain onto the width', () {
      expect(_scale.xOf(0), 0);
      expect(_scale.xOf(150), 150);
      expect(_scale.xOf(300), 300);
      const wide = AnnotationScale(domainStart: 100, domainEnd: 200, width: 400);
      expect(wide.xOf(150), 200);
    });

    test('a 23-hour DST day maps its own length, not 86400 s', () {
      // Epoch-second domain of a spring-forward day: 23 h, not 24.
      const day = 23 * 3600.0;
      const s = AnnotationScale(domainStart: 0, domainEnd: day, width: 460);
      expect(s.xOf(day), 460);
      expect(s.xOf(day / 2), 230);
      final l = _lay([_pt('late', day)], scale: s);
      expect(l.items.one.x, 460,
          reason: 'the last instant of the day is the right edge');
      // A 25 h fall-back day: the same wall time is NOT the same x.
      const fall = AnnotationScale(domainStart: 0, domainEnd: 25 * 3600.0, width: 500);
      expect(fall.xOf(3600 * 12.5), 250);
    });
  });

  group('placing points', () {
    test('nothing in, nothing out: no annotations never invents an item', () {
      final l = _lay(const []);
      expect(l.items, isEmpty);
      expect(l.shades, isEmpty);
      expect(l.unplaced, isEmpty);
      expect(l.focusedId, isNull);
      expect(l.labelText, isNull);
    });

    test('one point: line at its true x, icon centred on it, no badge', () {
      final l = _lay([_pt('a', 100)]);
      final a = l.items.one;
      expect(a.id, 'a');
      expect(a.x, 100);
      expect(a.iconLeft, 88);
      expect(a.iconWidth, 24);
      expect(a.more, 0);
      expect(a.memberIds, ['a']);
      expect(a.focused, isFalse);
      expect(a.isRange, isFalse);
      expect(a.kind, AnnotationKind.moment);
      expect(l.shades, isEmpty);
    });

    test('points outside the plot are dropped, the edges are kept', () {
      final l = _lay([
        _pt('before', -1),
        _pt('start', 0),
        _pt('end', 300),
        _pt('after', 300.5),
      ]);
      expect([for (final i in l.items) i.id], ['start', 'end']);
      expect(l.unplaced, isEmpty,
          reason: 'outside the window is not "no room": it is not on this chart');
    });

    test('a non-finite position is dropped, never drawn at 0', () {
      final l = _lay([
        _pt('nan', double.nan),
        _pt('inf', double.infinity),
        _pt('ok', 50),
      ]);
      expect([for (final i in l.items) i.id], ['ok']);
    });

    test('the icon stays inside the plot while its line stays on the item', () {
      final l = _lay([_pt('l', 0), _pt('r', 300)]);
      expect(l.items, hasLength(2));
      expect(l.items[0].x, 0);
      expect(l.items[0].iconLeft, 0);
      expect(l.items[1].x, 300);
      expect(l.items[1].iconLeft, 276);
      _expectNoOverlapInBounds(l, 300);
    });

    test('items come back left to right whatever order they went in', () {
      final l = _lay([_pt('c', 250), _pt('a', 20), _pt('b', 140)]);
      expect([for (final i in l.items) i.id], ['a', 'b', 'c']);
    });
  });

  group('clusters', () {
    test('exactly one icon width apart is two icons, closer is one', () {
      final apart = _lay([_pt('a', 100), _pt('b', 124)]);
      expect(apart.items.length, 2);
      expect([for (final i in apart.items) i.more], [0, 0]);
      final close = _lay([_pt('a', 100), _pt('b', 123.9)]);
      expect(close.items.length, 1);
      expect(close.items.one.more, 1);
    });

    test('a crowd is ONE icon, oldest shown, "+n" counts the rest', () {
      // Fed newest-first on purpose.
      final l = _lay([_pt('c', 110), _pt('b', 105), _pt('a', 100)]);
      final i = l.items.one;
      expect(i.id, 'a', reason: 'oldest in the neighbourhood');
      expect(i.more, 2);
      expect(i.memberIds, ['a', 'b', 'c'], reason: 'oldest first');
      expect(i.focused, isFalse);
      expect(i.x, 100, reason: 'the shown item\'s own position');
    });

    test('oldest is by time, then by id when the times are equal', () {
      final byTime = _lay([_pt('z', 100), _pt('y', 100.2)]);
      expect(byTime.items.one.id, 'z');
      final byId = _lay([_pt('b', 100), _pt('a', 100)]);
      expect(byId.items.one.id, 'a');
      expect(byId.items.one.memberIds, ['a', 'b']);
    });

    test('focus on a hidden member shows THAT member, the cluster is unchanged',
        () {
      final plain = _lay([_pt('a', 100), _pt('b', 105), _pt('c', 110)]);
      final l = _lay([_pt('a', 100), _pt('b', 105), _pt('c', 110)], focus: 'c');
      final i = l.items.one;
      expect(i.id, 'c');
      expect(i.focused, isTrue);
      expect(i.more, 2, reason: 'still two more behind it');
      expect(i.memberIds, plain.items.one.memberIds);
      expect(i.x, 110, reason: 'its line moves to where it really is');
      expect(l.focusedId, 'c');
      expect(l.labelText, 'L-c');
    });

    test('focus never changes who is in which cluster', () {
      final all = [
        _pt('a', 20), _pt('b', 30), // one cluster
        _pt('c', 120), // alone
        _pt('d', 220), _pt('e', 230), _pt('f', 240), // one cluster
      ];
      List<List<String>> sets(AnnotationLayout l) =>
          [for (final i in l.items) i.memberIds];
      final base = sets(_lay(all));
      expect(base, [
        ['a', 'b'],
        ['c'],
        ['d', 'e', 'f'],
      ]);
      for (final f in ['a', 'b', 'c', 'd', 'e', 'f']) {
        expect(sets(_lay(all, focus: f)), base, reason: 'focus $f');
      }
    });

    test('a chain of near points splits into clusters no wider than one icon', () {
      // Two runs of 8 points 5 px apart. A naive single-link chain would make
      // each run one 35 px "cluster"; the sweep starts a new one once a point
      // is a full icon width from the first member: 5 + 3 in each run.
      final pts = [
        for (final base in [20, 180])
          for (var i = 0; i < 8; i++) _pt('p$base-$i', base + i * 5.0),
      ];
      final l = _lay(pts);
      expect([for (final i in l.items) i.memberIds.length], [5, 3, 5, 3]);
      for (final i in l.items) {
        final xs = [
          for (final m in i.memberIds) 20.0 + int.parse(m.split('-')[1]) * 5.0
        ];
        expect(xs.reduce(math.max) - xs.reduce(math.min), lessThan(24));
      }
      expect(_allIds(l).toSet().length, 16);
      _expectNoOverlapInBounds(l, 300);
    });

    test('the "+n" badge takes room: the next icon is nudged, its line is not',
        () {
      // a(+2) at 100 -> icon 88..112, badge 112..134. b is 30 px away so it is
      // its own icon, but its centred box (118..142) would sit on the badge.
      final l = _lay([_pt('a', 100), _pt('a2', 101), _pt('a3', 102), _pt('b', 130)]);
      expect(l.items, hasLength(2));
      final a = l.items[0], b = l.items[1];
      expect(a.more, 2);
      expect(b.id, 'b');
      expect(b.iconLeft, greaterThanOrEqualTo(a.footprintRight));
      expect(b.x, 130, reason: 'the line stays on the item');
      _expectNoOverlapInBounds(l, 300);
    });

    test('a badge at the right edge is pulled in, not clipped', () {
      final l = _lay([_pt('a', 290), _pt('b', 295)]);
      final i = l.items.one;
      expect(i.more, 1);
      expect(i.footprintRight, lessThanOrEqualTo(300));
      expect(i.x, 290);
      _expectNoOverlapInBounds(l, 300);
    });

    test('PlacedAnnotation.next walks the members and wraps', () {
      final i =
          _lay([_pt('a', 100), _pt('b', 101), _pt('c', 102)]).items.one;
      expect(i.next(null), 'a');
      expect(i.next('a'), 'b');
      expect(i.next('b'), 'c');
      expect(i.next('c'), 'a');
      expect(i.next('nope'), 'a');
    });
  });

  group('ranges', () {
    test('a linked pair is a shaded area with ONE icon', () {
      final l = _lay([_range('w', 60, 140)]);
      expect(l.shades.length, 1);
      final s = l.shades.one;
      expect([s.id, s.kind, s.left, s.right],
          ['w', AnnotationKind.workout, 60, 140]);
      expect(l.items.length, 1);
      expect(l.items.one.id, 'w');
      expect(l.items.one.isRange, isTrue);
      expect(l.items.one.x, 60, reason: 'the icon and line sit at the start');
      expect(l.items.one.more, 0);
    });

    test('the shade is clipped to the plot and a range off the plot is gone', () {
      final l = _lay([
        _range('left', -50, 40, kind: AnnotationKind.nap),
        _range('right', 260, 400, kind: AnnotationKind.workout),
        _range('gone', -80, -10, kind: AnnotationKind.review),
        _range('gone2', 310, 400, kind: AnnotationKind.review),
      ]);
      final byId = {for (final s in l.shades) s.id: s};
      expect(byId.keys.toSet(), {'left', 'right'});
      expect([byId['left']!.left, byId['left']!.right], [0, 40]);
      expect([byId['right']!.left, byId['right']!.right], [260, 300]);
      final icons = {for (final i in l.items) i.id: i};
      expect(icons['left']!.x, 0, reason: 'icon at the first VISIBLE instant');
      expect(icons['right']!.x, 260);
      expect(l.items.length, 2);
    });

    test('a range with no usable end is a point, never a made-up span', () {
      for (final until in <double?>[null, 100, 90, double.nan]) {
        final l = _lay([
          ChartAnnotation(
              id: 'r',
              kind: AnnotationKind.nap,
              at: 100,
              until: until,
              label: 'nap')
        ]);
        expect(l.shades, isEmpty, reason: 'until=$until');
        expect(l.items.one.isRange, isFalse, reason: 'until=$until');
        expect(l.items.one.x, 100, reason: 'until=$until');
      }
    });

    test('a range never joins a cluster, and points inside it stay separate', () {
      final l = _lay([
        _range('w', 100, 200),
        _pt('p', 100.5),
        _pt('q', 150),
      ]);
      expect(l.shades.length, 1);
      final w = _pick(l.items, (i) => i.id == 'w');
      expect(w.more, 0);
      expect(w.memberIds, ['w']);
      expect(l.items.length, 3, reason: 'range icon + p + q');
      _expectNoOverlapInBounds(l, 300);
    });

    test('two ranges starting together both keep their icon and their shade', () {
      final l = _lay([
        _range('a', 100, 200, kind: AnnotationKind.workout),
        _range('b', 100, 150, kind: AnnotationKind.nap),
      ]);
      expect(l.shades.length, 2);
      expect(l.items.length, 2);
      expect([for (final s in l.shades) s.left], [100, 100],
          reason: 'collision nudging moves icons, never shaded areas');
      _expectNoOverlapInBounds(l, 300);
    });

    test('focus inside a cluster-free range marks the range focused', () {
      final l = _lay([_range('w', 60, 140)], focus: 'w');
      expect(l.shades.one.focused, isTrue);
      expect(l.items.one.focused, isTrue);
      expect(l.labelText, 'L-w');
    });
  });

  group('kinds', () {
    test('every kind has its own icon and its own colour', () {
      final icons = {for (final k in AnnotationKind.values) annotationIcon(k)};
      final colours = {
        for (final k in AnnotationKind.values) annotationColor(k).toARGB32()
      };
      expect(icons.length, AnnotationKind.values.length);
      expect(colours.length, AnnotationKind.values.length,
          reason: 'a shade is told apart by colour, so no two kinds share one');
    });

    test('ranges carry their kind through to the shade', () {
      final l = _lay([
        _range('w', 10, 30, kind: AnnotationKind.workout),
        _range('n', 100, 130, kind: AnnotationKind.nap),
        _range('r', 200, 230, kind: AnnotationKind.review),
      ]);
      expect({for (final s in l.shades) s.id: s.kind}, {
        'w': AnnotationKind.workout,
        'n': AnnotationKind.nap,
        'r': AnnotationKind.review,
      });
    });
  });

  group('never overlap, never lose, never invent', () {
    test('a dense random chart: no overlap, in bounds, every id exactly once', () {
      final rnd = math.Random(7);
      final all = <ChartAnnotation>[
        for (var i = 0; i < 200; i++)
          if (i % 9 == 0)
            () {
              final s = rnd.nextDouble() * 280;
              return _range('r$i', s, s + 1 + rnd.nextDouble() * 60,
                  kind: AnnotationKind.values[3 + i % 3]);
            }()
          else
            _pt('p$i', rnd.nextDouble() * 300,
                kind: AnnotationKind.values[i % AnnotationKind.values.length]),
      ];
      final l = _lay(all);
      _expectNoOverlapInBounds(l, 300);
      final ids = _allIds(l).toList();
      expect(ids.toSet().length, ids.length, reason: 'no id twice');
      expect(ids.toSet(), {for (final a in all) a.id},
          reason: 'every item is under an icon or reported unplaced');
    });

    test('a chart too narrow for its icons reports them instead of overlapping',
        () {
      const narrow = AnnotationScale(domainStart: 0, domainEnd: 100, width: 60);
      final l = _lay([for (var i = 0; i < 10; i++) _pt('p$i', i * 10.0)],
          scale: narrow);
      _expectNoOverlapInBounds(l, 60);
      expect(l.items.length, lessThanOrEqualTo(2));
      expect(_allIds(l).toSet().length, 10,
          reason: 'folded into a cluster or listed as unplaced');
    });

    test('ranges that cannot all have an icon keep their shade and are reported',
        () {
      const narrow = AnnotationScale(domainStart: 0, domainEnd: 100, width: 60);
      final l = _lay([
        _range('a', 0, 10),
        _range('b', 20, 30, kind: AnnotationKind.nap),
        _range('c', 40, 50, kind: AnnotationKind.review),
      ], scale: narrow);
      _expectNoOverlapInBounds(l, 60);
      expect(l.shades.length, 3);
      expect(l.unplaced, isNotEmpty);
      expect(_allIds(l).toSet(), {'a', 'b', 'c'});
    });

    test('an id that is not on the chart is not focused and has no label', () {
      final l = _lay([_pt('a', 100)], focus: 'ghost');
      expect(l.focusedId, isNull);
      expect(l.labelText, isNull);
      expect(l.items.one.focused, isFalse);
    });

    test('a focused item outside the plot is not focused either', () {
      final l = _lay([_pt('a', 100), _pt('off', 999)], focus: 'off');
      expect(l.focusedId, isNull);
      expect(l.labelText, isNull);
    });

    test('20,000 annotations lay out fast and to a bounded icon count', () {
      final rnd = math.Random(3);
      final all = [
        for (var i = 0; i < 20000; i++) _pt('p$i', rnd.nextDouble() * 300),
      ];
      final sw = Stopwatch()..start();
      final l = _lay(all, focus: 'p123');
      sw.stop();
      expect(l.items.length, lessThanOrEqualTo((300 / 24).floor()));
      _expectNoOverlapInBounds(l, 300);
      expect(_allIds(l).length, 20000);
      // O(n log n); a quadratic pass would be ~4e8 steps. Generous on purpose.
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('the static label', () {
    test('no focus, no label', () {
      final l = _lay([_pt('a', 100)]);
      expect(l.labelText, isNull);
    });

    test('the label is the focused item\'s label', () {
      expect(_lay([_pt('a', 100, label: 'Drank water')], focus: 'a').labelText,
          'Drank water');
    });

    test('the slot is the same wherever the focus is', () {
      final pts = [_pt('left', 10), _pt('mid', 150), _pt('right', 290)];
      final slots = {
        for (final f in <String?>[null, 'left', 'mid', 'right'])
          _lay(pts, focus: f).labelSlot,
      };
      expect(slots, {AnnotationLabelSlot.topStart});
    });
  });

  group('picking the focus from the scrub cursor', () {
    final pts = [_pt('a', 100), _pt('b', 120), _pt('c', 250)];

    test('nearest wins, on or near', () {
      String? pick(double px) => pickAnnotationFocus(
          annotations: pts, scale: _scale, cursorPx: px);
      expect(pick(100), 'a');
      expect(pick(98), 'a');
      expect(pick(113), 'b');
      expect(pick(200), 'c');
      expect(pick(0), 'a');
      expect(pick(-40), 'a', reason: 'past the edge is the edge');
      expect(pick(999), 'c');
    });

    test('no cursor or nothing to pick is null', () {
      expect(
          pickAnnotationFocus(
              annotations: pts, scale: _scale, cursorPx: null),
          isNull);
      expect(
          pickAnnotationFocus(
              annotations: const [], scale: _scale, cursorPx: 50),
          isNull);
    });

    test('equally near picks the older', () {
      expect(
          pickAnnotationFocus(
              annotations: pts, scale: _scale, cursorPx: 110),
          'a');
    });

    test('items at one x pick the oldest, then the lowest id', () {
      final same = [_pt('z', 100), _pt('m', 100), _pt('k', 100.0)];
      expect(
          pickAnnotationFocus(
              annotations: same, scale: _scale, cursorPx: 100),
          'k');
    });

    test('reach limits "nearest": too far is nothing, not the least-bad item',
        () {
      expect(
          pickAnnotationFocus(
              annotations: [_pt('a', 100)],
              scale: _scale,
              cursorPx: 200,
              reach: 30),
          isNull);
      expect(
          pickAnnotationFocus(
              annotations: [_pt('a', 100)],
              scale: _scale,
              cursorPx: 125,
              reach: 30),
          'a');
      expect(
          pickAnnotationFocus(
              annotations: [_pt('a', 100)], scale: _scale, cursorPx: 290),
          'a',
          reason: 'no reach given: the nearest, however far');
    });

    test('a cursor inside a range is ON it, even with a point nearer an edge',
        () {
      final a = [_range('w', 100, 200), _pt('p', 205)];
      expect(
          pickAnnotationFocus(annotations: a, scale: _scale, cursorPx: 190),
          'w');
    });

    test('inside a range with a point at the cursor, the point wins', () {
      final a = [_range('w', 100, 200), _pt('p', 150)];
      expect(
          pickAnnotationFocus(annotations: a, scale: _scale, cursorPx: 150),
          'p');
    });

    test('items off the plot are never picked', () {
      expect(
          pickAnnotationFocus(
              annotations: [_pt('off', 500)], scale: _scale, cursorPx: 290),
          isNull);
    });

    test('a dense cluster is walked by moving the finger across it', () {
      final dense = [_pt('a', 100), _pt('b', 108), _pt('c', 116)];
      String? pick(double px) => pickAnnotationFocus(
          annotations: dense, scale: _scale, cursorPx: px);
      expect([pick(99), pick(107), pick(117)], ['a', 'b', 'c']);
    });
  });

  group('an unusable scale lays out nothing (and a usable one lays out)', () {
    final one = [_pt('a', 100)];
    AnnotationLayout on(AnnotationScale s) =>
        layoutAnnotations(annotations: one, scale: s);

    test('control: a usable scale places the item', () {
      expect(
          on(const AnnotationScale(domainStart: 0, domainEnd: 300, width: 300))
              .items
              .one
              .id,
          'a');
    });

    for (final (name, scale) in [
      ('zero width',
          const AnnotationScale(domainStart: 0, domainEnd: 300, width: 0)),
      ('empty domain',
          const AnnotationScale(domainStart: 100, domainEnd: 100, width: 300)),
      ('inverted domain',
          const AnnotationScale(domainStart: 300, domainEnd: 0, width: 300)),
      ('non-finite domain',
          const AnnotationScale(
              domainStart: 0, domainEnd: double.infinity, width: 300)),
    ]) {
      test('$name: no items, no shades, nothing unplaced, no throw', () {
        // Not "usable" means not drawn; it never means "dropped silently as
        // unplaced" and never a crash.
        expect(scale.usable, isFalse);
        final l = on(scale);
        expect(l.items, isEmpty);
        expect(l.shades, isEmpty);
        expect(l.unplaced, isEmpty);
        expect(l.labelText, isNull);
        // And the same item on a scale that works is still placed, so the
        // empty answer above is the scale's doing.
        expect(
            on(const AnnotationScale(domainStart: 0, domainEnd: 300, width: 300))
                .items,
            hasLength(1));
      });
    }
  });
}
