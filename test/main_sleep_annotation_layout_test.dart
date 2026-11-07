// The main-sleep annotation kind in the pure annotation layout.
//
// The night's main sleep is drawn on the day chart as an annotation (a moon,
// its own colour), not as a band. In the layout it has PRIORITY over every
// other kind:
//   1. it is NEVER folded into a "+n" cluster (other icons are nudged or
//      clustered around it), whether it arrives as a range or as a point;
//   2. it is the last icon given up when the chart is too narrow for all;
//   3. when nothing is focused, ITS label is the static label. Any focus
//      (a scrub, a tap) replaces it; an absent or off-chart night leaves the
//      label empty -- nothing is invented.
// Every other kind behaves exactly as before (chart_annotation_layout_test).
//
// Pixel maths as in the other layout tests: domain 0..300 over 300 px, the icon
// is 24 px wide and the "+n" badge 22.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
        {AnnotationKind kind = AnnotationKind.moment}) =>
    ChartAnnotation(id: id, kind: kind, at: at, label: 'L-$id');

/// The main sleep as a POINT (a degenerate or one-sided night): the case a
/// plain point would fold into a cluster.
ChartAnnotation _sleepPt(double at, {String id = 'sleep'}) =>
    ChartAnnotation(
        id: id,
        kind: AnnotationKind.mainSleep,
        at: at,
        label: 'Main sleep L-$id');

ChartAnnotation _sleep(double at, double until, {String id = 'sleep'}) =>
    ChartAnnotation(
        id: id,
        kind: AnnotationKind.mainSleep,
        at: at,
        until: until,
        label: 'Main sleep L-$id');

AnnotationLayout _lay(List<ChartAnnotation> a,
        {String? focus, AnnotationScale scale = _scale}) =>
    layoutAnnotations(annotations: a, scale: scale, focusId: focus);

PlacedAnnotation _icon(AnnotationLayout l, String id) =>
    l.items.singleWhere((i) => i.id == id,
        orElse: () => throw TestFailure(
            '$id has no icon of its own; icons: '
            '${[for (final i in l.items) '${i.id}${i.memberIds}']}'));

Iterable<String> _allIds(AnnotationLayout l) =>
    [for (final i in l.items) ...i.memberIds, ...l.unplaced];

void _expectNoOverlapInBounds(AnnotationLayout l, double width) {
  for (var i = 0; i < l.items.length; i++) {
    final a = l.items[i];
    expect(a.iconLeft, greaterThanOrEqualTo(-1e-9));
    expect(a.footprintRight, lessThanOrEqualTo(width + 1e-9));
    for (var j = i + 1; j < l.items.length; j++) {
      final b = l.items[j];
      expect(
          a.footprintRight <= b.iconLeft + 1e-9 ||
              b.footprintRight <= a.iconLeft + 1e-9,
          isTrue,
          reason: '${a.id} overlaps ${b.id}');
    }
  }
}

void main() {
  group('the kind', () {
    test('a moon, and a colour no other kind uses', () {
      expect(annotationIcon(AnnotationKind.mainSleep), LucideIcons.moon);
      final others = [
        for (final k in AnnotationKind.values)
          if (k != AnnotationKind.mainSleep) k
      ];
      expect(
          others.map(annotationIcon),
          isNot(contains(annotationIcon(AnnotationKind.mainSleep))));
      expect(
          others.map((k) => annotationColor(k).toARGB32()),
          isNot(contains(
              annotationColor(AnnotationKind.mainSleep).toARGB32())));
    });
  });

  group('(1) never folded into a "+n" cluster', () {
    test('a main-sleep point between two moments next to it keeps its own '
        'icon, with no badge', () {
      final l = _lay([_pt('a', 100), _sleepPt(110), _pt('b', 120)]);
      final s = _icon(l, 'sleep');
      expect(s.memberIds, ['sleep']);
      expect(s.more, 0, reason: 'no +n on the sleep icon');
      expect(s.x, 110, reason: 'its dashed line is on its true x');
      expect(_allIds(l).toSet(), {'a', 'sleep', 'b'});
      _expectNoOverlapInBounds(l, 300);
    });

    test('the other icons are nudged or clustered around it, not under it',
        () {
      final l = _lay([_pt('a', 100), _sleepPt(104), _pt('b', 108)]);
      expect(_icon(l, 'sleep').memberIds, ['sleep']);
      // a and b may share one icon (a "+1"), but never the sleep's.
      for (final i in l.items) {
        if (i.id != 'sleep') expect(i.memberIds, isNot(contains('sleep')));
      }
      _expectNoOverlapInBounds(l, 300);
    });

    test('earlier than every neighbour (it would have been the OLDEST, shown '
        'and swallowing the rest) it still stands alone', () {
      final l = _lay([_sleepPt(95), _pt('a', 100), _pt('b', 108)]);
      expect(_icon(l, 'sleep').memberIds, ['sleep']);
      expect(_allIds(l).toSet(), {'sleep', 'a', 'b'});
    });

    test('later than every neighbour (a plain point would be a "+n" member '
        'behind an older icon) it still stands alone', () {
      final l = _lay([_pt('a', 100), _pt('b', 108), _sleepPt(116)]);
      final s = _icon(l, 'sleep');
      expect(s.memberIds, ['sleep']);
      expect(s.more, 0);
      expect(l.unplaced, isEmpty);
    });

    test('a crowd of 60 moments across the chart cannot swallow it', () {
      final rnd = math.Random(11);
      final crowd = [
        for (var i = 0; i < 60; i++) _pt('p$i', rnd.nextDouble() * 300),
        _sleepPt(150),
      ];
      final l = _lay(crowd);
      final s = _icon(l, 'sleep');
      expect(s.memberIds, ['sleep']);
      expect(l.unplaced, isNot(contains('sleep')));
      expect(_allIds(l).toSet(), {for (final a in crowd) a.id});
      _expectNoOverlapInBounds(l, 300);
    });

    test('as a range it is shaded, has one icon and members of nobody else',
        () {
      final l = _lay([_pt('a', 20), _sleep(0, 120), _pt('b', 30)]);
      expect(l.shades.map((s) => s.id), ['sleep']);
      expect(l.shades.one.kind, AnnotationKind.mainSleep);
      expect(_icon(l, 'sleep').memberIds, ['sleep']);
      expect(_icon(l, 'sleep').isRange, isTrue);
      _expectNoOverlapInBounds(l, 300);
    });

    test('a night that began before the chart is clipped to its edge and '
        'still stands alone next to a crowd at that edge', () {
      final l = _lay([
        _pt('a', 2),
        _sleep(-3600, 80),
        _pt('b', 6),
        _pt('c', 10),
      ]);
      final s = _icon(l, 'sleep');
      expect(s.memberIds, ['sleep']);
      expect(l.shades.one.startsInside, isFalse);
      expect(l.shades.one.endsInside, isTrue);
      _expectNoOverlapInBounds(l, 300);
    });
  });

  group('(2) the last icon to be given up', () {
    // A 60 px chart holds two icons, or one icon with a badge and one without.
    const narrow = AnnotationScale(domainStart: 0, domainEnd: 60, width: 60);

    test('when the chart is too narrow for everything the others go, '
        'not the sleep', () {
      final l = _lay([_pt('a', 5), _pt('b', 25), _sleepPt(58)], scale: narrow);
      expect(l.items.map((i) => i.id), contains('sleep'),
          reason: 'the sleep keeps an icon');
      expect(l.unplaced, isNot(contains('sleep')));
      expect(l.unplaced.toSet(), {'a', 'b'},
          reason: 'the rest are REPORTED, never silently dropped');
      _expectNoOverlapInBounds(l, 60);
    });

    test('with several kinds in the way it is still the one that stays', () {
      final l = _lay([
        _pt('a', 5, kind: AnnotationKind.water),
        _pt('b', 20, kind: AnnotationKind.symptom),
        _sleepPt(40),
        _pt('c', 58, kind: AnnotationKind.journal),
      ], scale: narrow);
      expect(l.items.map((i) => i.id), contains('sleep'));
      expect(l.unplaced, isNot(contains('sleep')));
      _expectNoOverlapInBounds(l, 60);
      expect(_allIds(l).toSet(), {'a', 'b', 'sleep', 'c'});
    });

    // The night outranks FOCUS too: a focused item keeps the fixed label slot,
    // but its icon may be folded or reported unplaced to leave the night's.
    for (final focus in ['a', 'b']) {
      test('a scrub or a pin on "$focus" (a 2-moment cluster, 46 px) does not '
          'push the night off a 60 px chart', () {
        final l = _lay([_pt('a', 5), _pt('b', 25), _sleepPt(58)],
            scale: narrow, focus: focus);
        expect(l.items.map((i) => i.id), contains('sleep'),
            reason: 'the night keeps its icon whatever is focused');
        expect(l.unplaced, isNot(contains('sleep')));
        expect(l.focusedId, focus);
        expect(l.labelText, 'L-$focus',
            reason: 'the focused item still owns the label slot');
        expect(_allIds(l).toSet(), {'a', 'b', 'sleep'},
            reason: 'nothing vanishes: reported unplaced at worst');
        _expectNoOverlapInBounds(l, 60);
      });
    }

    test('a focused lone moment is given up before the night, and still '
        'labels', () {
      // 40 px: two 24 px icons cannot both fit.
      const tiny = AnnotationScale(domainStart: 0, domainEnd: 40, width: 40);
      final l =
          _lay([_pt('a', 5), _sleepPt(36)], scale: tiny, focus: 'a');
      expect(l.items.map((i) => i.id), ['sleep']);
      expect(l.unplaced, ['a']);
      expect(l.labelText, 'L-a');
    });

    test('a night that is a range is held the same way', () {
      final l = _lay([_pt('a', 5), _pt('b', 25), _sleep(40, 59)],
          scale: narrow, focus: 'b');
      expect(l.items.map((i) => i.id), contains('sleep'));
      expect(l.shades.map((s) => s.id), ['sleep']);
      expect(l.labelText, 'L-b');
    });
  });

  group('(3) its label is the default label', () {
    final night = _sleep(0, 90, id: 'sleep');

    test('nothing focused: the label is the main sleep\'s, nothing is focused',
        () {
      final l = _lay([_pt('a', 150), night]);
      expect(l.focusedId, isNull);
      expect(l.labelText, 'Main sleep L-sleep');
      expect(l.labelSlot, AnnotationLabelSlot.topStart,
          reason: 'the same one fixed slot');
      expect(l.items.every((i) => !i.focused), isTrue,
          reason: 'a default label is not a focus: no bold icon');
    });

    test('focusing another item replaces it', () {
      final l = _lay([_pt('a', 150), night], focus: 'a');
      expect(l.focusedId, 'a');
      expect(l.labelText, 'L-a');
    });

    test('focusing the sleep itself shows the same label, now focused', () {
      final l = _lay([_pt('a', 150), night], focus: 'sleep');
      expect(l.focusedId, 'sleep');
      expect(l.labelText, 'Main sleep L-sleep');
      expect(_icon(l, 'sleep').focused, isTrue);
    });

    test('a focus id that is not on the chart falls back to the default',
        () {
      final l = _lay([_pt('a', 150), night], focus: 'ghost');
      expect(l.focusedId, isNull);
      expect(l.labelText, 'Main sleep L-sleep');
    });

    test('works for a night that is only a point as well', () {
      final l = _lay([_pt('a', 150), _sleepPt(100)]);
      expect(l.labelText, 'Main sleep L-sleep');
    });

    test('a night clipped at the chart\'s start still labels', () {
      final l = _lay([_sleep(-7200, 60)]);
      expect(l.labelText, 'Main sleep L-sleep');
    });

    test('NO night: no default label, however many other items', () {
      final l = _lay([_pt('a', 100), _pt('b', 200)]);
      expect(l.focusedId, isNull);
      expect(l.labelText, isNull, reason: 'nothing focused, nothing said');
      expect(_lay(const []).labelText, isNull);
    });

    test('a night wholly off the chart is not on it: no label', () {
      expect(_lay([_pt('a', 100), _sleep(-9000, -100)]).labelText, isNull);
      expect(_lay([_pt('a', 100), _sleep(400, 900)]).labelText, isNull);
      expect(_lay([_pt('a', 100), _sleepPt(-5)]).labelText, isNull);
    });

    test('other kinds never get a default label of their own', () {
      for (final k in AnnotationKind.values) {
        if (k == AnnotationKind.mainSleep) continue;
        expect(_lay([_pt('x', 100, kind: k)]).labelText, isNull,
            reason: k.name);
      }
    });
  });

  group('everything else behaves as before', () {
    test('a nap has no priority: a nap point folds into a neighbour like '
        'any other point, and a nap range is its own shaded icon beside the '
        'night', () {
      final l = _lay([
        _pt('n1', 100, kind: AnnotationKind.nap),
        _pt('b', 110),
        _sleep(0, 60),
        ChartAnnotation(
            id: 'n2',
            kind: AnnotationKind.nap,
            at: 200,
            until: 230,
            label: 'L-n2'),
      ]);
      final folded = _pick(l.items, (i) => i.memberIds.contains('n1'));
      expect(folded.memberIds, ['n1', 'b']);
      expect(folded.more, 1);
      expect(l.shades.map((s) => s.id).toSet(), {'sleep', 'n2'});
      expect(_icon(l, 'n2').memberIds, ['n2']);
      expect(_icon(l, 'sleep').memberIds, ['sleep']);
      expect(l.labelText, 'Main sleep L-sleep');
    });

    test('two points close together still collapse to one icon with +1', () {
      final l = _lay([_pt('a', 100), _pt('b', 110), _sleep(200, 250)]);
      final c = _pick(l.items, (i) => i.memberIds.contains('a'));
      expect(c.memberIds, ['a', 'b']);
      expect(c.more, 1);
    });
  });
}
