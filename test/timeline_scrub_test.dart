// Tests for the timeline chart's scrub mapping — the pure x→time and
// time→value-on-the-drawn-line functions the crosshair reads (issue #141).
//
// The bug: the plotted lines are the 15-min bucket averages ([_Vital.avg]) but
// the scrub crosshair used to read the RAW nearest sample, so the marker sat
// off the line at a different granularity. These cover that the value the scrub
// reports is the one that lies ON the drawn (bucketed) polyline at the touched
// x, so the marker aligns with the line.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui/timeline/timeline_screen.dart';

typedef Bucket = ({double t, double v, double lo, double hi});

Bucket _b(double t, double v) => (t: t, v: v, lo: v, hi: v);

void main() {
  group('scrubTimeAt (x-pixel → time)', () {
    const t0 = 1000.0, t1 = 2000.0, leftPad = 36.0, width = 336.0;
    // usable plot width = 336 - 36 = 300px maps linearly onto [1000, 2000].

    test('left edge of the plot maps to t0', () {
      expect(scrubTimeAt(leftPad, width, leftPad: leftPad, t0: t0, t1: t1), t0);
    });

    test('right edge of the plot maps to t1', () {
      expect(scrubTimeAt(width, width, leftPad: leftPad, t0: t0, t1: t1), t1);
    });

    test('mid-plot maps to the midpoint time', () {
      // 150px into the 300px plot → halfway → 1500.
      expect(
        scrubTimeAt(leftPad + 150, width, leftPad: leftPad, t0: t0, t1: t1),
        1500.0,
      );
    });

    test('touches inside the left pad clamp to t0 (never negative time)', () {
      expect(scrubTimeAt(0, width, leftPad: leftPad, t0: t0, t1: t1), t0);
      expect(scrubTimeAt(10, width, leftPad: leftPad, t0: t0, t1: t1), t0);
    });

    test('touches past the right edge clamp to t1', () {
      expect(
        scrubTimeAt(width + 80, width, leftPad: leftPad, t0: t0, t1: t1),
        t1,
      );
    });

    test('degenerate (width <= leftPad) returns t0 without dividing by zero', () {
      expect(scrubTimeAt(20, leftPad, leftPad: leftPad, t0: t0, t1: t1), t0);
    });
  });

  group('plottedLineValueAt (time → value ON the drawn line)', () {
    // Three bucket centres — the vertices the painter's line passes through.
    final avg = [_b(100, 50), _b(200, 70), _b(300, 60)];

    test('a time exactly on a bucket centre returns that vertex value', () {
      expect(plottedLineValueAt(avg, 100), 50);
      expect(plottedLineValueAt(avg, 200), 70);
      expect(plottedLineValueAt(avg, 300), 60);
    });

    test('a time between centres lies on the straight segment (interpolated)', () {
      // Halfway 100→200: (50+70)/2 = 60 — exactly where lineTo draws.
      expect(plottedLineValueAt(avg, 150), 60);
      // Quarter 200→300: 70 + (60-70)*0.25 = 67.5.
      expect(plottedLineValueAt(avg, 225), 67.5);
    });

    test('the interpolated point sits on the line, not on a raw sample', () {
      // A raw nearest-sample reader would have snapped 150 to the 100 or 200
      // vertex (50 or 70); the on-line value is the segment midpoint, 60.
      final v = plottedLineValueAt(avg, 150)!;
      expect(v, isNot(50));
      expect(v, isNot(70));
      expect(v, 60);
    });

    test('times before the first / after the last centre clamp to the ends', () {
      expect(plottedLineValueAt(avg, 0), 50);
      expect(plottedLineValueAt(avg, 500), 60);
    });

    test('empty series returns null', () {
      expect(plottedLineValueAt(const <Bucket>[], 150), isNull);
    });

    test('single bucket returns its value for any time', () {
      final one = [_b(100, 42)];
      expect(plottedLineValueAt(one, 0), 42);
      expect(plottedLineValueAt(one, 100), 42);
      expect(plottedLineValueAt(one, 999), 42);
    });

    test('coincident bucket timestamps do not divide by zero', () {
      final dup = [_b(100, 50), _b(100, 80), _b(200, 60)];
      // Lands on the duplicate boundary — returns a finite vertex value.
      final v = plottedLineValueAt(dup, 100)!;
      expect(v.isFinite, isTrue);
    });
  });

  group('composed scrub → value stays on the line at matching granularity', () {
    const t0 = 100.0, t1 = 300.0, leftPad = 36.0, width = 236.0; // 200px plot
    final avg = [_b(100, 50), _b(200, 70), _b(300, 60)];

    test('touch at plot-mid resolves to the on-line midpoint value', () {
      final t = scrubTimeAt(leftPad + 100, width,
          leftPad: leftPad, t0: t0, t1: t1); // → 200
      expect(t, 200);
      expect(plottedLineValueAt(avg, t), 70); // the vertex at t=200
    });

    test('touch at plot-quarter resolves onto the first segment', () {
      final t = scrubTimeAt(leftPad + 50, width,
          leftPad: leftPad, t0: t0, t1: t1); // → 150
      expect(t, 150);
      expect(plottedLineValueAt(avg, t), 60); // midpoint of 50→70
    });
  });
}
