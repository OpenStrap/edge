// Where annotations come from, and how they reach a chart.
//
// The layout (chart_annotation_layout_test.dart) is pure arithmetic; this file
// pins the seams in front of it: the algorithm-version marks keep landing where
// the dotted lines used to, the day timeline's moments become typed
// annotations, and an intraday item reaches a daily chart on its LOCAL day.
// (Ported from the fork's chart_annotation_sources_test.dart; the day-timeline
// and hero-stamp groups are left to the screens that own them on upstream.)
//
// Fixed dates only; no test reads the clock. The suite runs under TZ=UTC, so
// the day arithmetic below is built from calendar fields (DateTime(y, m, d,
// h, m)) exactly as production does — never from a day start plus 86400.

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';

import 'support/process_tz.dart';

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

final int _day = _sec(2026, 8, 14);
int _sec(int y, int mo, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;


ChartAnnotation _timed(String id, int at,
        {int? until, AnnotationKind kind = AnnotationKind.journal}) =>
    ChartAnnotation(
        id: id,
        kind: kind,
        at: at.toDouble(),
        until: until?.toDouble(),
        label: id);

void main() {
  group('algorithm-version marks join the annotation system', () {
    // The formula the dotted marks used (metric_detail.dart `marks`): a break
    // `b` days behind today, in a series of n slots, sat at
    // (n - 1 - b - .5) / (n - 1) of the way across.
    double old(int b, int n) => (n - 1 - b - .5) / (n - 1);

    test('each break lands exactly where its dotted line used to', () {
      const n = 30;
      final a = algoBreakAnnotations(
          breakDaysBehind: const [3, 12, 20], seriesLength: n, label: 'Algo');
      expect(a.length, 3);
      for (var i = 0; i < a.length; i++) {
        final b = const [3, 12, 20][i];
        expect(a[i].at / (n - 1), moreOrLessEquals(old(b, n), epsilon: 1e-12));
        expect(a[i].kind, AnnotationKind.algoVersion);
        expect(a[i].until, isNull, reason: 'a boundary, not a span');
        expect(a[i].label, 'Algo');
      }
    });

    test('a break at slot 0, behind the window or in the future is dropped', () {
      const n = 10;
      final a = algoBreakAnnotations(
          breakDaysBehind: const [9, 10, 400, -1, 0],
          seriesLength: n,
          label: 'Algo');
      // 9 -> slot 0: nothing before it to be incomparable with. 10, 400: older
      // than the window. -1: after today. 0 -> today's slot: kept (half a slot
      // left of it).
      expect(a.length, 1);
      expect(a.one.at, n - 1 - 0 - .5);
    });

    test('a one-slot or empty series has no boundary to mark', () {
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [0], seriesLength: 1, label: 'x'),
          isEmpty);
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [0], seriesLength: 0, label: 'x'),
          isEmpty);
    });

    test('no breaks, no marks', () {
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [], seriesLength: 30, label: 'x'),
          isEmpty);
    });

    test('ids are unique and stable across calls', () {
      List<String> ids() => [
            for (final a in algoBreakAnnotations(
                breakDaysBehind: const [3, 12, 20], seriesLength: 30, label: 'x'))
              a.id
          ];
      expect(ids().toSet().length, 3);
      expect(ids(), ids());
    });

    test('a mark keeps its own icon beside a journal item at the same place',
        () {
      final mark = algoBreakAnnotations(
          breakDaysBehind: const [5], seriesLength: 30, label: 'Algo').one;
      final water = ChartAnnotation(
          id: 'water',
          kind: AnnotationKind.water,
          at: mark.at + .01,
          label: 'Water');
      final l = layoutAnnotations(
        annotations: [water, mark],
        scale: const AnnotationScale(
            domainStart: 0, domainEnd: 29, width: 290),
      );
      // Provenance is not an event: it never folds into a journal cluster.
      expect(l.items.length, 2);
      expect([for (final i in l.items) i.more], [0, 0]);
      expect({for (final i in l.items) i.id}, {mark.id, 'water'});
      // ...but it still avoids the other icon: nudged, not overlapped.
      expect(l.items, hasLength(2));
      final a = l.items[0], b = l.items[1];
      expect(a.footprintRight, lessThanOrEqualTo(b.iconLeft + 1e-9));
      expect(_pick(l.items, (i) => i.id == mark.id).x,
          moreOrLessEquals(mark.at * 10, epsilon: 1e-9),
          reason: 'the line stays on the boundary');
    });

    test('two marks close together are two icons, never a +n', () {
      final marks = algoBreakAnnotations(
          breakDaysBehind: const [5, 6], seriesLength: 30, label: 'Algo');
      final l = layoutAnnotations(
        annotations: marks,
        scale: const AnnotationScale(
            domainStart: 0, domainEnd: 29, width: 290),
      );
      expect(l.items.length, 2);
      expect([for (final i in l.items) i.more], [0, 0]);
    });
  });

  group('dailyAnnotations: an intraday item on a daily chart', () {
    const days = [
      '2026-08-10',
      '2026-08-11',
      '2026-08-12',
      '2026-08-13',
      '2026-08-14',
      '2026-08-15',
      '2026-08-16',
    ];

    test('a point is on its local day\'s slot, however late in the day', () {
      final a = dailyAnnotations([
        _timed('early', _sec(2026, 8, 12, 0, 5)),
        _timed('late', _sec(2026, 8, 12, 23, 55)),
        _timed('next', _sec(2026, 8, 13, 0, 5)),
      ], days);
      expect({for (final x in a) x.id: x.at}, {
        'early': 2.0,
        'late': 2.0,
        'next': 3.0,
      });
      expect(a.every((x) => x.until == null), isTrue);
    });

    test('a range inside one day is that day\'s point', () {
      final a = dailyAnnotations([
        _timed('run', _sec(2026, 8, 14, 18),
            until: _sec(2026, 8, 14, 19), kind: AnnotationKind.workout),
      ], days);
      expect(a.one.at, 4.0);
      expect(a.one.until, isNull);
      expect(a.one.kind, AnnotationKind.workout);
    });

    test('a range across days spans its first slot to its last', () {
      final a = dailyAnnotations([
        _timed('trip', _sec(2026, 8, 11, 22),
            until: _sec(2026, 8, 13, 7), kind: AnnotationKind.review),
      ], days);
      expect(a.one.at, 1.0);
      expect(a.one.until, 3.0);
    });

    test('a range that runs past the window keeps its off-window end', () {
      final a = dailyAnnotations([
        _timed('long', _sec(2026, 8, 15, 20),
            until: _sec(2026, 8, 18, 6), kind: AnnotationKind.review),
      ], days);
      // Starts on slot 5. Its end is three days past slot 6 (the last), and it
      // stays off the chart: clamping it to slot 6 made the layout draw a
      // dashed END edge on a day the range did not end on.
      expect(a.one.at, 5.0);
      expect(a.one.until, greaterThan(6.0),
          reason: 'off-window bounds go through to the layout, which clips');
    });

    test('a range that began before the window keeps its off-window start', () {
      final a = dailyAnnotations([
        _timed('long', _sec(2026, 8, 7, 20),
            until: _sec(2026, 8, 11, 6), kind: AnnotationKind.review),
      ], days);
      expect(a.one.at, lessThan(0.0));
      expect(a.one.until, 1.0);
    });

    test('a range ending on the last visible day still ends there', () {
      final a = dailyAnnotations([
        _timed('trip', _sec(2026, 8, 15, 20),
            until: _sec(2026, 8, 16, 6), kind: AnnotationKind.review),
      ], days);
      expect(a.one.at, 5.0);
      expect(a.one.until, 6.0);
    });

    test('items outside the window are dropped, not clamped onto an edge', () {
      final a = dailyAnnotations([
        _timed('old', _sec(2026, 8, 9, 12)),
        _timed('future', _sec(2026, 8, 17, 12)),
      ], days);
      expect(a, isEmpty);
    });

    test('nothing in, nothing out; no labels, nothing', () {
      expect(dailyAnnotations(const [], days), isEmpty);
      expect(dailyAnnotations([_timed('x', _day)], const []), isEmpty);
    });

    test('several items on one day share its slot and keep their identity', () {
      final a = dailyAnnotations([
        _timed('a', _sec(2026, 8, 14, 8), kind: AnnotationKind.water),
        _timed('b', _sec(2026, 8, 14, 9), kind: AnnotationKind.water),
        _timed('c', _sec(2026, 8, 14, 21), kind: AnnotationKind.symptom),
      ], days);
      expect([for (final x in a) x.id], ['a', 'b', 'c']);
      expect({for (final x in a) x.at}, {4.0});
      expect([for (final x in a) x.kind],
          [AnnotationKind.water, AnnotationKind.water, AnnotationKind.symptom]);
    });

    test('a day with no data of its own is still a day with an item', () {
      // The labels say nothing about whether the metric derived that day; the
      // journal entry is real either way. No item is invented for the others.
      final a = dailyAnnotations([_timed('a', _sec(2026, 8, 13, 12))], days);
      expect(a.length, 1);
      expect(a.one.at, 3.0);
    });
  });

  // ── across both DST transitions, in a zone that has them ──────────────────
  //
  // America/New_York: 2026-03-08 springs forward (a 23 h day), 2026-11-01 falls
  // back (a 25 h day). The expected slots are literal; the timestamps are
  // literal UTC seconds, so nothing here is computed the way production does.
  // A UTC-placed day, or a day that is start + 86400, puts at least one of
  // these on the wrong slot.
  group('dailyAnnotations on the local day across DST (New York)', () {
    final originalTz = Platform.environment['TZ'];
    setUpAll(() => setProcessTz('America/New_York'));
    tearDownAll(() => setProcessTz(originalTz));

    test('the fixture timezone actually applied (guards the group)', () {
      expect(DateTime(2026, 3, 8).timeZoneOffset, const Duration(hours: -5),
          reason: 'setenv(TZ)+tzset() did not re-home the local calendar; '
              'the assertions below would be vacuous');
      expect(DateTime(2026, 3, 9).timeZoneOffset, const Duration(hours: -4));
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

    const spring = [
      '2026-03-06',
      '2026-03-07',
      '2026-03-08',
      '2026-03-09',
      '2026-03-10',
    ];
    const fall = [
      '2026-10-30',
      '2026-10-31',
      '2026-11-01',
      '2026-11-02',
      '2026-11-03',
    ];

    Map<String, double> slots(List<String> days, Map<String, int> at) => {
          for (final a in dailyAnnotations([
            for (final e in at.entries) _timed(e.key, e.value),
          ], days))
            a.id: a.at,
        };

    test('spring forward: the 23 h day ends at its own midnight', () {
      expect(
        slots(spring, {
          // 23:59:59 EST on 03-07, then 00:00:00 EST on 03-08.
          'last-of-07': 1772945999,
          'first-of-08': 1772946000,
          // 23:59:59 EDT on 03-08 (the 23 h day), then 00:00:00 EDT on 03-09.
          'last-of-08': 1773028799,
          'first-of-09': 1773028800,
        }),
        {
          'last-of-07': 1.0,
          'first-of-08': 2.0,
          'last-of-08': 2.0,
          'first-of-09': 3.0,
        },
      );
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

    test('fall back: the 25 h day keeps its extra hour', () {
      expect(
        slots(fall, {
          // 23:59:59 EDT on 10-31, then 00:00:00 EDT on 11-01.
          'last-of-31': 1793505599,
          'first-of-01': 1793505600,
          // 01:30 EDT and the repeated 01:30 EST: both 11-01.
          'first-130': 1793511000,
          'second-130': 1793514600,
          // 23:59:59 EST on 11-01 (25 h after its start), then 00:00:00 EST.
          'last-of-01': 1793595599,
          'first-of-02': 1793595600,
        }),
        {
          'last-of-31': 1.0,
          'first-of-01': 2.0,
          'first-130': 2.0,
          'second-130': 2.0,
          'last-of-01': 2.0,
          'first-of-02': 3.0,
        },
      );
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

    test('a range over the fall-back day spans its first to its last day', () {
      final a = dailyAnnotations([
        // 22:00 EDT on 10-31 to 00:30 EST on 11-02.
        _timed('trip', 1793498400,
            until: 1793595600 + 1800, kind: AnnotationKind.review),
      ], fall);
      expect(a.one.at, 1.0);
      expect(a.one.until, 3.0);
    }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);
  });
}
