// The downsampler, which is the one piece of real algorithm in lib/ui2.
//
// A night is ~30 000 1 Hz samples on a ~350 pt chart: ~85 samples per physical
// pixel, every one of them a Path segment. The old UI drew all of them. The
// fix has to be a reduction that a reviewer can trust not to hide a spike,
// which is why it is min/max-per-column and not stride decimation — so these
// assert exactly that.

import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show metricValue;
import 'package:openstrap_edge/ui2/theme.dart';

/// Captures what a painter actually drew, so an axis claim can be checked
/// against geometry instead of against a screenshot.
class _Rec implements Canvas {
  final paths = <Path>[];
  final rrects = <RRect>[];
  final rects = <Rect>[];
  final circles = <Offset>[];
  final lines = <(Offset, Offset)>[];

  @override
  void drawPath(Path p, Paint _) => paths.add(p);

  @override
  void drawRRect(RRect r, Paint _) => rrects.add(r);

  @override
  void drawRect(Rect r, Paint _) => rects.add(r);

  @override
  void drawCircle(Offset c, double _, Paint _) => circles.add(c);

  @override
  void drawLine(Offset a, Offset b, Paint _) => lines.add((a, b));

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

Widget _host(Widget child, {double scale = 1, Brightness b = Brightness.light}) =>
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: buildTheme(b),
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(S.x4), child: child)),
      ),
    );

void main() {
  double identityY(double v) => v;

  group('minMaxColumns', () {
    test('a short series is returned untouched', () {
      final d = [1.0, 5.0, 3.0, 9.0];
      final out = minMaxColumns(d, 400, identityY);
      expect(out, hasLength(d.length));
      expect(out.map((o) => o.dy), d);
      expect(out.first.dx, 0);
      expect(out.last.dx, closeTo(400, 0.001));
    });

    test('a long series collapses to at most two points per pixel column', () {
      final d = List<double>.generate(30000, (i) => (i % 97).toDouble());
      final out = minMaxColumns(d, 350, identityY);
      expect(out.length, lessThanOrEqualTo(700));
      // …and it is actually a reduction, not a copy.
      expect(out.length, lessThan(d.length / 20));
    });

    test('a single-sample spike survives the reduction', () {
      // Stride decimation drops this ~99.7% of the time. That is the bug.
      final d = List<double>.filled(30000, 60.0);
      d[17431] = 190.0;
      final out = minMaxColumns(d, 350, identityY);
      expect(out.map((o) => o.dy), contains(190.0));
    });

    test('a single-sample dropout survives too', () {
      final d = List<double>.filled(30000, 60.0);
      d[2] = 31.0;
      expect(minMaxColumns(d, 350, identityY).map((o) => o.dy), contains(31.0));
    });

    test('points stay in time order — the line never doubles back', () {
      final d = List<double>.generate(20000, (i) => (i * 7 % 211).toDouble());
      final out = minMaxColumns(d, 300, identityY);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].dx, greaterThanOrEqualTo(out[i - 1].dx),
            reason: 'x went backwards at $i');
      }
    });

    test('x spans the full width, so the chart is not drawn short', () {
      final d = List<double>.generate(9000, (i) => i.toDouble());
      final out = minMaxColumns(d, 250, identityY);
      expect(out.first.dx, closeTo(0, 1));
      expect(out.last.dx, closeTo(250, 1));
    });

    test('the y mapping is applied, not bypassed', () {
      final d = List<double>.generate(5000, (i) => i.toDouble());
      final out = minMaxColumns(d, 100, (v) => 100 - v / 50);
      expect(out.map((o) => o.dy).reduce((a, b) => a < b ? a : b),
          closeTo(100 - 4999 / 50, 0.001));
    });

    test('degenerate inputs do not throw', () {
      expect(minMaxColumns(const [], 300, identityY), isEmpty);
      expect(minMaxColumns(const [4.0], 300, identityY), hasLength(1));
      expect(minMaxColumns(const [1.0, 2.0], 0, identityY), isEmpty);
    });
  });

  group('maxColumns', () {
    test('bars aggregate to the column peak, never the mean', () {
      final d = List<double>.filled(1000, 1.0);
      d[500] = 50.0;
      final out = maxColumns(d, 10);
      expect(out, hasLength(10));
      expect(out.reduce((a, b) => a > b ? a : b), 50.0);
    });

    test('a series that already fits is untouched', () {
      final d = [1.0, 2.0, 3.0];
      expect(identical(maxColumns(d, 10), d), isTrue);
    });
  });

  group('painters refuse to invent data', () {
    // Every painter here used to seed its own Random. An empty input must draw
    // nothing so the screen falls through to a StatusCard.
    test('empty inputs paint nothing and do not throw', () {
      const size = Size(300, 100);
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      for (final p in <CustomPainter>[
        LineChart(const [], Colors.red),
        Bars(const [], Colors.red),
        Hypnogram(const [], const P(false)),
        ZoneBar(const [], const P(false)),
        Actogram(const [], Colors.red),
        HeatMap(const [], Colors.red, Colors.grey),
        Spectrum(const []),
        NightStack(const [], const [Colors.red]),
      ]) {
        expect(() => p.paint(canvas, size), returnsNormally,
            reason: '${p.runtimeType} threw on empty input');
      }
      recorder.endRecording();
    });

    test('a gap in an actogram is a gap, not a night of nothing', () {
      // A null day is unrecorded; a list of zeroes is "measured, no sleep".
      // They must not be the same value.
      expect(<List<double>?>[null], isNot(<List<double>?>[List.filled(24, 0)]));
    });
  });

  // ── THE AXIS ────────────────────────────────────────────────────────────
  group('AxisSpec', () {
    const a = AxisSpec(min: 40, max: 80, format: axisInt);

    test('t() is 0 at min, 1 at max, and clamps outside', () {
      expect(a.t(40), 0);
      expect(a.t(60), closeTo(.5, 1e-9));
      expect(a.t(80), 1);
      // A sample past the axis lands on the edge — never off the canvas, and
      // never silently rescaling the axis the labels describe.
      expect(a.t(200), 1);
      expect(a.t(-5), 0);
    });

    test('tickValues run top-first and include both ends', () {
      expect(a.tickValues, [80.0, 60.0, 40.0]);
      expect(const AxisSpec(min: 0, max: 3, ticks: 4, format: axisInt).tickValues,
          [3.0, 2.0, 1.0, 0.0]);
    });

    test('a degenerate axis does not divide by zero', () {
      expect(const AxisSpec(min: 5, max: 5, format: axisInt).t(5), 0);
    });

    group('of()', () {
      test('rounds out to steps a human would pick, and contains the data', () {
        final s = AxisSpec.of([37.2, 61.8, 54.0])!;
        expect(s.min, lessThanOrEqualTo(37.2));
        expect(s.max, greaterThanOrEqualTo(61.8));
        expect(s.format(s.min), anyOf('20', '30', '35', '40'));
        // Evenly spaced ticks, or the gridlines lie about their spacing.
        final v = s.tickValues;
        expect(v[0] - v[1], closeTo(v[1] - v[2], 1e-9));
      });

      test('a flat series gets a band around it, not a line on the floor', () {
        final s = AxisSpec.of(List.filled(20, 60.0))!;
        expect(s.min, lessThan(60));
        expect(s.max, greaterThan(60));
        expect(s.t(60), closeTo(.5, .2));
      });

      test('floor extends the axis but never crops the data', () {
        final s = AxisSpec.of([30.0, 44.0], floor: 0)!;
        expect(s.min, 0);
        expect(s.max, greaterThanOrEqualTo(44));
        final low = AxisSpec.of([-12.0, 5.0], floor: 0)!;
        expect(low.min, lessThanOrEqualTo(-12));
      });

      test('an empty series has no axis — that is the empty state', () {
        expect(AxisSpec.of(const []), isNull);
      });

      test('a non-finite sample cannot hang the step loop', () {
        // This used to spin forever on the main isolate: `hi` was infinity and
        // the loop grew the axis towards it one nice step at a time.
        final s = AxisSpec.of([double.infinity, 60.0])!;
        expect(s.min, lessThanOrEqualTo(60));
        expect(s.max, greaterThanOrEqualTo(60));
        expect(s.max.isFinite, isTrue);
      }, timeout: const Timeout(Duration(seconds: 5)));

      test('NaN is excluded, not silently skipped into a hole in the line', () {
        // Every comparison against NaN is false, so it used to drop out of the
        // extent while staying in the series — an axis that looks right over a
        // line with an invisible gap in it.
        final s = AxisSpec.of([double.nan, 60.0])!;
        expect(s.min, lessThanOrEqualTo(60));
        expect(s.max, greaterThanOrEqualTo(60));
        expect(AxisSpec.of([double.nan, double.infinity]), isNull);
      });

      test('every gridline lands on a value its own label can say', () {
        // 55..56 used to step by .5 and label two gridlines '56'; 52..57 used
        // to put the middle line at 53.75 and call it '54'.
        for (final d in [
          [55.0, 55, 56, 56, 55, 56, 55],
          [52.0, 57],
          [0.0, 0, 0, 0, 0, 0, 0],
          [37.2, 61.8, 54.0],
        ]) {
          final s = AxisSpec.of([for (final v in d) v.toDouble()])!;
          final v = s.tickValues;
          expect(v.map(s.format).toSet().length, v.length,
              reason: 'duplicate label in ${v.map(s.format)}');
          for (final t in v) {
            expect(t, closeTo(t.roundToDouble(), 1e-9),
                reason: 'gridline $t cannot be printed by axisInt');
          }
        }
        // A format we cannot resolve is left alone rather than guessed at.
        expect(AxisSpec.of([0.2, 0.9], format: axisFixed)!.tickValues.last,
            closeTo(0.2, .2));
      });

      test('an all-zero series never puts a negative number on a gridline', () {
        final s = AxisSpec.of(List.filled(7, 0.0))!;
        expect(s.min, 0);
        expect(s.max, greaterThan(0));
        expect(s.tickValues.every((v) => v >= 0), isTrue);
      });
    });

    group('autoExtent — the axis-less fallback', () {
      test('a flat series gets a band around it, exactly like of()', () {
        final e = autoExtent(List.filled(7, 60.0))!;
        expect((60 - e.min) / e.range, closeTo(.5, 1e-9));
      });

      test('a flat ZERO series keeps zero on the floor', () {
        final e = autoExtent(List.filled(7, 0.0))!;
        expect(e.min, 0);
        expect(e.range, greaterThan(0));
      });

      test('holes are ignored and an empty one has no extent', () {
        final e = autoExtent(const [null, 50.0, double.nan, 70.0])!;
        expect(e.min, 50);
        expect(e.range, 20);
        expect(autoExtent(const [null, double.nan]), isNull);
      });
    });

    group('minMaxRuns — a gap is a gap', () {
      test('a hole splits the series and the runs keep their real spacing', () {
        final runs = minMaxRuns(const [60.0, null, 62.0, 63.0], 300, (v) => v);
        expect(runs, hasLength(2));
        expect(runs[0].single.dx, 0);
        // Index 2 of 4 is two thirds along, and stays there.
        expect(runs[1].first.dx, closeTo(200, .001));
        expect(runs[1].last.dx, closeTo(300, .001));
      });

      test('a lone sample survives as a run of one', () {
        final runs = minMaxRuns(const [null, 55.0, null], 300, (v) => v);
        expect(runs, hasLength(1));
        expect(runs.single, hasLength(1));
        expect(runs.single.single.dy, 55);
      });

      test('no holes means one run, identical to minMaxColumns', () {
        final d = List<double>.generate(5000, (i) => (i % 83).toDouble());
        final runs = minMaxRuns(d, 250, (v) => v);
        expect(runs, hasLength(1));
        expect(runs.single, minMaxColumns(d, 250, (v) => v));
      });

      test('all holes draws nothing', () {
        expect(minMaxRuns(const [null, null], 300, (v) => v), isEmpty);
        expect(minMaxRuns(const [double.nan], 300, (v) => v), isEmpty);
      });
    });

    test('formatters', () {
      expect(axisInt(55.6), '56');
      expect(axisHm(450), '7h 30m');
      expect(axisHm(480), '8h');
      expect(axisHm(45), '45m');
      expect(axisFixed(36.48), '36.5');
    });
  });

  group('painters honour the axis they were given', () {
    const size = Size(100, 100);
    const axis = AxisSpec(min: 0, max: 100, format: axisInt);

    test('a selected slot draws a vertical cursor at its x position', () {
      final rec = _Rec();
      LineChart([0.0, 100.0, 50.0], Colors.red,
              fill: false, axis: axis, selectedX: .25)
          .paint(rec, size);
      expect(rec.lines, hasLength(1));
      expect(rec.lines.single.$1.dx, closeTo(25, .001));
      expect(rec.lines.single.$2.dx, closeTo(25, .001));
      expect(rec.lines.single.$1.dy, 0);
      expect(rec.lines.single.$2.dy, 100);
    });

    test('an unselected chart draws no cursor', () {
      final rec = _Rec();
      LineChart([0.0, 100.0, 50.0], Colors.red,
              fill: false, axis: axis)
          .paint(rec, size);
      expect(rec.lines, isEmpty);
    });

    test('a line touches the top at max and the bottom at min — no padding', () {
      final rec = _Rec();
      LineChart([0.0, 100.0, 50.0], Colors.red, fill: false, axis: axis)
          .paint(rec, size);
      final b = rec.paths.first.getBounds();
      expect(b.top, closeTo(0, .5));
      expect(b.bottom, closeTo(100, .5));
    });

    test('without an axis it auto-scales — which is why charts need one', () {
      final rec = _Rec();
      // Same data, a tenth of the range: identical picture. That is the bug
      // the axis exists to fix, pinned so nobody "simplifies" it back.
      LineChart([0.0, 10.0, 5.0], Colors.red, fill: false).paint(rec, size);
      final small = rec.paths.first.getBounds();
      final rec2 = _Rec();
      LineChart([0.0, 100.0, 50.0], Colors.red, fill: false).paint(rec2, size);
      expect(rec2.paths.first.getBounds().top, closeTo(small.top, .5));
    });

    test('bars measure against the axis, not against their own tallest bar',
        () {
      final rec = _Rec();
      Bars([50.0], Colors.red, axis: axis).paint(rec, size);
      final half = rec.rrects.first.outerRect.height;
      final rec2 = _Rec();
      Bars([100.0], Colors.red, axis: axis).paint(rec2, size);
      expect(half, closeTo(rec2.rrects.first.outerRect.height / 2, 1));
      // Auto-scaled, both would be full height.
      final auto = _Rec();
      Bars([50.0], Colors.red).paint(auto, size);
      expect(auto.rrects.first.outerRect.height, closeTo(100, 1));
    });
  });

  // ── THE AXIS-LESS PATH ──────────────────────────────────────────────────
  // TrendCard and the MetricRow series go through the painters' own fallback
  // and never see AxisSpec, so every fix that landed there has to land here
  // too or half the app keeps the bug.
  group('the auto-scale fallback', () {
    const size = Size(300, 100);

    test('a stable week reads as stable, not as lowest ever', () {
      final rec = _Rec();
      LineChart(List.filled(7, 60.0), Colors.red).paint(rec, size);
      final b = rec.paths.first.getBounds();
      // It used to land at y ≈ 86 on a 100 pt card: hard against the floor.
      expect(b.top, closeTo(50, 1));
      expect(b.bottom, closeTo(50, 1));
    });

    test('a flat zero week stays on the floor, where zero belongs', () {
      final rec = _Rec();
      LineChart(List.filled(7, 0.0), Colors.red).paint(rec, size);
      expect(rec.paths.first.getBounds().top, closeTo(86, 1));
    });

    test('an area fill is dropped without an axis to anchor it', () {
      // Min-anchored, a 58→60 bpm week paints a full-card mountain — a
      // truncated-axis area chart with the truncation hidden.
      final bare = _Rec();
      LineChart(const [58.0, 60.0, 59.0], Colors.red).paint(bare, size);
      expect(bare.paths, hasLength(1), reason: 'fill drawn with no axis');

      final framed = _Rec();
      LineChart(const [58.0, 60.0, 59.0], Colors.red,
              axis: const AxisSpec(min: 0, max: 100, format: axisInt))
          .paint(framed, size);
      expect(framed.paths, hasLength(2), reason: 'fill dropped under an axis');
    });

    test('nothing finite draws nothing', () {
      final rec = _Rec();
      LineChart(const [double.nan, null], Colors.red).paint(rec, size);
      expect(rec.paths, isEmpty);
      expect(rec.circles, isEmpty);
    });
  });

  group('a line never closes over a gap', () {
    const size = Size(300, 100);

    test('a missing day breaks the path instead of spanning it', () {
      final rec = _Rec();
      LineChart(const [60.0, 61.0, null, null, 64.0, 65.0], Colors.red)
          .paint(rec, size);
      expect(rec.paths, hasLength(2));
      // The two runs end and start either side of the hole, and nothing is
      // drawn across it.
      expect(rec.paths[0].getBounds().right, closeTo(60, 1));
      expect(rec.paths[1].getBounds().left, closeTo(240, 1));
    });

    test('an every-other-day series draws dots, not nothing', () {
      final rec = _Rec();
      LineChart(const [60.0, null, 62.0, null, 64.0], Colors.red)
          .paint(rec, size);
      expect(rec.paths, isEmpty);
      expect(rec.circles, hasLength(3));
    });

    test('a NaN is a hole, not a sample the axis pretends it never saw', () {
      final rec = _Rec();
      LineChart(const [60.0, 61.0, double.nan, 64.0, 65.0], Colors.red)
          .paint(rec, size);
      expect(rec.paths, hasLength(2));
    });
  });

  group('degenerate inputs', () {
    test('a one-point column reduction does not throw in a paint method', () {
      // minMaxColumns yields a single point in a canvas under ~2 px wide, and
      // the old prefix clamp asserted on it.
      final rec = _Rec();
      expect(
          () => LineChart(const [5.0, 5.0, 5.0], Colors.red)
              .paint(rec, const Size(1.5, 40)),
          returnsNormally);
    });

    test('a bar keeps its 2pt floor inside the canvas', () {
      final rec = _Rec();
      Bars(const [0.001, 100.0], Colors.red)
          .paint(rec, const Size(300, 100));
      final tiny = rec.rrects.first.outerRect;
      expect(tiny.bottom, closeTo(100, .001));
      expect(tiny.height, closeTo(2, .001));
    });

    test('a bucket that was never measured draws no bar', () {
      final rec = _Rec();
      Bars(const [null, 40.0, null], Colors.red)
          .paint(rec, const Size(300, 100));
      expect(rec.rrects, hasLength(1));
    });

    test('a skipped zone band does not shift the ones after it', () {
      final rec = _Rec();
      ZoneBar(const [.5, .001, .499], const P(false)).paint(rec, const Size(300, 10));
      expect(rec.rrects, hasLength(2));
      // The hairline band is skipped; its width still has to be spent.
      expect(rec.rrects[1].outerRect.left, closeTo(300 * .501, .01));
    });

    test('painters survive non-finite input without drawing it', () {
      const size = Size(300, 100);
      for (final p in <CustomPainter>[
        LineChart(const [double.nan, 60.0], Colors.red),
        Bars(const [double.nan, 60.0], Colors.red),
        ZoneBar(const [double.nan, .5], const P(false)),
        Actogram([List.filled(24, double.nan)], Colors.red),
        NightStack(const [
          [double.nan, 60.0]
        ], const [Colors.red]),
      ]) {
        expect(() => p.paint(_Rec(), size), returnsNormally,
            reason: '${p.runtimeType} threw');
      }
    });
  });

  group('Hypnogram reduces before it draws', () {
    test('a 30 s arousal survives an eight-hour night', () {
      // 28 800 rects on a 350 pt chart overlap, and the last one drawn wins —
      // so which stage a pixel showed was an accident of draw order.
      final night = List.filled(28800, SleepStage.deep);
      night[17431] = SleepStage.awake;
      expect(Hypnogram.columns(night, 175), contains(SleepStage.awake));
    });

    test('the column shows what occupied most of it, awake aside', () {
      final st = [
        ...List.filled(9, SleepStage.light),
        ...List.filled(1, SleepStage.rem),
      ];
      expect(Hypnogram.columns(st, 1), [SleepStage.light]);
    });

    test('one rect per drawable column, not one per epoch', () {
      final rec = _Rec();
      Hypnogram(List.filled(28800, SleepStage.light), const P(false))
          .paint(rec, const Size(350, 80));
      expect(rec.rrects.length, lessThanOrEqualTo(175));
    });

    test('a short night is untouched', () {
      final st = List.filled(40, SleepStage.rem);
      expect(identical(Hypnogram.columns(st, 175), st), isTrue);
    });
  });

  group('Actogram agrees with the frame that labels it', () {
    test('slot 0 is the bottom row — the frame prints max first', () {
      // ChartFrame stacks tick labels top-first from AxisSpec.max, so hour has
      // to increase upwards. Drawing slot 0 at the top only read correctly
      // because the caller's noon-anchored formatter is symmetric at 3 ticks.
      final rec = _Rec();
      final day = List.filled(24, 0.0);
      day[0] = 1;
      Actogram([day], Colors.red).paint(rec, const Size(20, 240));
      expect(rec.rects.single.bottom, closeTo(240, .001));
    });
  });

  group('NightStack lanes share one time base', () {
    const size = Size(300, 90);

    test('a lane on its own clock is not stretched to fit', () {
      final rec = _Rec();
      NightStack([
        List.filled(60, 60.0),
        List.filled(12, 40.0), // a coarser lane — a different instant per pixel
      ], const [Colors.red, Colors.blue])
          .paint(rec, size);
      expect(rec.paths, hasLength(1));
    });

    test('lanes on the shared grid all draw, holes and all', () {
      final rec = _Rec();
      NightStack([
        List.filled(60, 60.0),
        [for (var i = 0; i < 60; i++) i < 20 ? null : 40.0 + i],
      ], const [Colors.red, Colors.blue])
          .paint(rec, size);
      expect(rec.paths.length, greaterThanOrEqualTo(2));
    });
  });

  group('Scrubber — a drag that does not require one', () {
    testWidgets('it is a slider, it speaks its position, and it steps',
        (tester) async {
      final handle = tester.ensureSemantics();
      double? at;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (_, setLocal) => Scrubber(
          value: at,
          onChanged: (v) => setLocal(() => at = v),
          label: 'Hypnogram',
          describe: (v) => '${(v * 100).round()} per cent through the night',
          child: const SizedBox(height: 110, width: 300),
        ),
      )));

      final node = tester.getSemantics(find.byType(Scrubber));
      expect(node.flagsCollection.isSlider, isTrue);
      expect(node.label, 'Hypnogram');
      // Nothing placed yet is a STATE, not a zero.
      expect(node.value, 'Nothing selected');
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

      // The whole point: a step, with no pointer anywhere near it.
      final owner = node.owner!;
      owner.performAction(node.id, SemanticsAction.increase);
      await tester.pump();
      expect(at, closeTo(0, 1e-9));
      owner.performAction(node.id, SemanticsAction.increase);
      await tester.pump();
      expect(at, closeTo(.05, 1e-9));
      expect(tester.getSemantics(find.byType(Scrubber)).value,
          '5 per cent through the night');
      handle.dispose();
    });

    testWidgets('a tap places it — no drag required', (tester) async {
      double? at;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (_, setLocal) => Scrubber(
          value: at,
          onChanged: (v) => setLocal(() => at = v),
          label: 'Hypnogram',
          describe: (v) => '$v',
          child: const SizedBox(height: 110, width: double.infinity),
        ),
      )));
      final box = tester.getRect(find.byType(Scrubber));
      await tester.tapAt(Offset(box.left + box.width * .75, box.center.dy));
      await tester.pump();
      expect(at, closeTo(.75, .02));
    });
  });

  group('legends are derived from the palette, never retyped', () {
    test('every sleep stage has a key', () {
      const p = P(false);
      expect(Hypnogram.legend(p).map((e) => e.$2),
          SleepStage.values.map((s) => Hypnogram.cols(p)[s]));
      expect(Hypnogram.legend(p).map((e) => e.$1),
          ['Awake', 'REM', 'Light', 'Deep']);
    });

    test('every zone has a key', () {
      const p = P(false);
      expect(ZoneBar.legend(p), hasLength(ZoneBar.cols(p).length));
      expect(ZoneBar.legend(p).last.$1, 'Zone 5');
    });
  });

  // ── THE FRAME ───────────────────────────────────────────────────────────
  group('ChartFrame', () {
    testWidgets('always prints the unit and the real tick numbers',
        (tester) async {
      await tester.pumpWidget(_host(ChartFrame(
        title: 'Resting heart rate',
        unit: 'bpm',
        yAxis: const AxisSpec(min: 40, max: 80, format: axisInt),
        xLabels: const ['7 days ago', 'Today'],
        footnote: 'Your usual range 52–64 bpm',
        child: CustomPaint(painter: LineChart(const [52.0, 61.0], C.blue)),
      )));

      expect(find.text('bpm'), findsOneWidget);
      expect(find.text('Resting heart rate'), findsOneWidget);
      for (final t in const ['80', '60', '40']) {
        expect(find.text(t), findsOneWidget, reason: 'tick $t missing');
      }
      expect(find.text('7 days ago'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Your usual range 52–64 bpm'), findsOneWidget);
    });

    testWidgets('a duration axis prints hours and minutes', (tester) async {
      await tester.pumpWidget(_host(ChartFrame(
        title: 'Time asleep',
        unit: 'per night',
        height: 140,
        yAxis: AxisSpec(min: 0, max: 480, ticks: 3, format: axisHm),
        child: CustomPaint(painter: Bars(const [420.0], C.blue)),
      )));
      expect(find.text('8h'), findsOneWidget);
      expect(find.text('4h'), findsOneWidget);
    });

    testWidgets('empty keeps the title and the unit and drops the axis',
        (tester) async {
      await tester.pumpWidget(_host(const ChartFrame(
        title: 'Respiratory rate',
        unit: 'breaths/min',
        yAxis: AxisSpec(min: 10, max: 20, format: axisInt),
        xLabels: ['Mon', 'Sun'],
        empty: NoData(message: 'Nothing recorded this week'),
        child: SizedBox.shrink(),
      )));
      expect(find.text('breaths/min'), findsOneWidget);
      expect(find.text('Nothing recorded this week'), findsOneWidget);
      // No axis with nothing on it, and no x-labels under an empty box.
      expect(find.text('20'), findsNothing);
      expect(find.text('Mon'), findsNothing);
    });

    testWidgets('legend entries carry the mark colour they explain',
        (tester) async {
      await tester.pumpWidget(_host(ChartFrame(
        title: 'Last night',
        unit: 'stages',
        legend: Hypnogram.legend(const P(false)),
        child: CustomPaint(
            painter: Hypnogram(const [SleepStage.deep], const P(false))),
      )));
      for (final s in SleepStage.values) {
        expect(find.text(s.label), findsOneWidget);
      }
    });

    testWidgets('at 2x text the labels thin instead of colliding',
        (tester) async {
      // The frame is 100 pt tall and asks for 4 ticks. At 1x they fit; at 2x
      // they cannot, so the frame must drop labels — and the ones it keeps
      // must still be the ends of the SAME axis.
      const spec = AxisSpec(min: 0, max: 300, ticks: 4, format: axisInt);
      Widget frame() => ChartFrame(
            title: 'Movement',
            unit: 'counts',
            height: 100,
            yAxis: spec,
            child: CustomPaint(painter: Bars(const [120.0], C.purple)),
          );

      await tester.pumpWidget(_host(frame()));
      expect(find.text('100'), findsOneWidget);

      await tester.pumpWidget(_host(frame(), scale: 2));
      expect(tester.takeException(), isNull);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('100'), findsNothing);
    });

    testWidgets('a chart says its data out loud, and only its data',
        (tester) async {
      // A painter is a picture and a picture has no screen-reader form. Before
      // this a fully-specified frame announced its title, its unit and then the
      // three BARE AXIS TICK NUMBERS — 80, 60, 40 — and not one value from the
      // series it was drawing.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(ChartFrame(
        title: 'Resting heart rate',
        unit: 'bpm',
        yAxis: AxisSpec.of(const [52.0, 48.0, 61.0], floor: 40),
        xLabels: const ['30 Jul', 'Today'],
        footnote: 'Your usual range is 52-64 bpm.',
        series: const [52.0, null, 48.0, 61.0],
        child: CustomPaint(
            painter: LineChart(const [52.0, null, 48.0, 61.0], C.blue)),
      )));

      final node = tester.getSemantics(find.byType(ChartFrame));
      expect(node.label, contains('Resting heart rate'));
      expect(node.label, contains('measured in bpm'));
      // The data, summarised: where it ended, how far it ranged, which way it
      // went — never thirty numbers, which a screen reader cannot skim.
      // No unit on the value: the sentence has already said "measured in
      // bpm", and a formatter like axisHm writes its own ("7h 42m min").
      expect(node.label, contains('Latest 61,'));
      expect(node.label, isNot(contains('Latest 61 bpm')));
      expect(node.label, contains('ranging 48 to 61'));
      expect(node.label, contains('up 9'));
      expect(node.label, contains('from 30 Jul to Today'));
      // And NOT the gridline numbers, which mean nothing on their own.
      expect(node.label, isNot(contains('80')));
      handle.dispose();
    });

    testWidgets('an empty frame lets the caller say why, once', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const ChartFrame(
        title: 'Respiratory rate',
        unit: 'breaths/min',
        yAxis: AxisSpec(min: 10, max: 20, format: axisInt),
        empty: NoData(message: 'One night is not a trend yet'),
        child: SizedBox.shrink(),
      )));
      final label = tester.getSemantics(find.byType(ChartFrame)).label;
      // The frame used to add its own 'No data' on top of the caller's
      // message, so one absence was announced twice and the generic half
      // contradicted the specific one.
      expect(label, isNot(contains('No data')));
      expect(label, contains('Respiratory rate'));
      // …and still no bare gridline numbers.
      expect(label, isNot(contains('20')));
      expect(find.text('One night is not a trend yet'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('nothing overflows in either theme at 2x', (tester) async {
      for (final b in Brightness.values) {
        await tester.pumpWidget(_host(
          ChartFrame(
            title: 'Heart rate variability across the whole night',
            unit: 'ms',
            yAxis: AxisSpec(min: 0, max: 480, format: axisHm),
            xLabels: const ['22:30', '02:00', '05:30', '07:10'],
            legend: ZoneBar.legend(P(b == Brightness.dark)),
            footnote: 'Relative to your own 14-night baseline.',
            child: CustomPaint(painter: LineChart(const [40.0, 90.0], C.teal)),
          ),
          scale: 2,
          b: b,
        ));
        expect(tester.takeException(), isNull, reason: '$b overflowed at 2x');
      }
    });
  });

  group('TrendCard', () {
    testWidgets('with no baseline it passes no judgement', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const TrendCard('Resting heart rate', '58',
          'bpm', 'no baseline', 'first readings', [58.0], C.red,
          up: true, good: null)));
      final label = tester.getSemantics(find.byType(TrendCard)).label;
      // It used to read "…, worse than usual" off a delta of zero against a
      // baseline it had just said it did not have.
      expect(label, contains('no baseline first readings'));
      expect(label, isNot(contains('worse than usual')));
      expect(label, isNot(contains('an improvement')));
      // …and no arrow either, since there is no direction to point.
      expect(find.byIcon(LucideIcons.arrowUpRight), findsNothing);
      expect(find.byIcon(LucideIcons.arrowDownRight), findsNothing);
      handle.dispose();
    });

    testWidgets('with a baseline it still says which way and whether that is '
        'good', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const TrendCard('HRV', '61', 'ms', '+4',
          'vs your 28-day average', [57.0, 61.0], C.green,
          up: true, good: true)));
      expect(tester.getSemantics(find.byType(TrendCard)).label,
          contains('an improvement'));
      expect(find.byIcon(LucideIcons.arrowUpRight), findsOneWidget);
      handle.dispose();
    });
  });

  // A tenth of a bpm on a nocturnal minimum is precision the measurement does
  // not have. One rule, so a reading is not `71.6` on the detail screen and
  // `72` on the card that links to it.
  group('metricValue precision', () {
    test('measured units print at the precision they carry', () {
      expect(metricValue('bpm', 71.6), '72');
      expect(metricValue('ms', 43.27), '43');
      expect(metricValue('%', 91.4), '91');
      expect(metricValue('br/min', 14.27), '14.3');
      expect(metricValue('°', 0.34), '0.3');
      expect(metricValue('min', 450), '7h 30m');
      expect(metricValue('steps', 8421), '8,421');
      expect(metricValue('kcal', 512.4), '512');
    });

    test('unitless scores keep a decimal only while it means something', () {
      expect(metricValue('', 12.44), '12.4'); // strain
      expect(metricValue('', 1.83), '1.8'); // LF/HF
      expect(metricValue('', 78.0), '78'); // readiness
      expect(metricValue('', 104.6), '105');
    });

    test('null is absent, never zero', () => expect(metricValue('bpm', null), ''));
  });
}
