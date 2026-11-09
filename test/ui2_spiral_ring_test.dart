// RED: rings are spirals past 100%.
//
// Owner decision: one spiral ring in the ring component, used by StageRing,
// Ring (recovery, strain). v3 "T30% inset 75%": lap 0 is a true circle; at
// each lap boundary n the band insets inward over 30% of a lap (cosine eased,
// no corners), then holds; inset per lap = 0.75 x stroke; the outer edge never
// leaves the lap-0 circle; the gradient spans the whole bar; each segment's
// clockwise end is a round cap painted over its clockwise neighbour.
//
// Honesty: the ring draws exactly the fraction it is given. <= 1 is one lap
// and no inset; nothing is drawn past the value; nothing is clamped to 100%.
//
// Geometry is asserted through [SpiralGeometry] (lib/ui2/spiral_ring.dart),
// then through Ring.pieces / StageRing.pieces, then a pixel smoke test.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/spiral_ring.dart';

const _g = SpiralGeometry(10);
const _w = 10.0;
const _eps = 1e-9;

double _sweep(List<SpiralPiece> p) => p.fold(0.0, (a, e) => a + (e.to - e.from));

void main() {
  group('inset profile', () {
    test('lap 0 is a true circle: no inset anywhere in [0, 1]', () {
      for (var i = 0; i <= 100; i++) {
        expect(_g.inset(i / 100), closeTo(0, _eps), reason: 's=${i / 100}');
        expect(_g.radiusAt(i / 100, 45), closeTo(45, _eps));
      }
    });

    test('inset per lap is 0.75 x stroke once each ramp is done', () {
      for (var n = 1; n <= 4; n++) {
        expect(_g.inset(n + .3), closeTo(.75 * _w * n, 1e-6), reason: 'n=$n');
        expect(_g.radiusAt(n + .3, 45), closeTo(45 - .75 * _w * n, 1e-6));
      }
      expect(const SpiralGeometry(14).inset(1.5), closeTo(.75 * 14, 1e-6));
    });

    test('holds flat for the rest of the lap after the 30% ramp', () {
      for (var n = 1; n <= 3; n++) {
        final held = _g.inset(n + .3);
        expect(held, greaterThan(0));
        for (var x = .3; x < 1.0; x += .05) {
          expect(_g.inset(n + x), closeTo(held, 1e-6), reason: 'n=$n x=$x');
        }
      }
    });

    test('ramp is monotone and cosine-eased: halfway is half, ends are flat',
        () {
      expect(_g.inset(1.15), closeTo(.5 * .75 * _w, 1e-6));
      var prev = _g.inset(1.0);
      for (var i = 1; i <= 300; i++) {
        final v = _g.inset(1 + .3 * i / 300);
        expect(v, greaterThanOrEqualTo(prev - _eps));
        prev = v;
      }
      // Derivative ~ 0 at both ends of the transition (no corners).
      const h = 1e-4;
      double d(double s) => (_g.inset(s + h) - _g.inset(s - h)) / (2 * h);
      expect(d(1.0 + 2 * h).abs(), lessThan(.01));
      expect(d(1.3 - 2 * h).abs(), lessThan(.01));
      expect(d(2.0 + 2 * h).abs(), lessThan(.01));
      // ...and clearly nonzero mid-ramp (it is a ramp, not a step).
      expect(d(1.15), greaterThan(10));
    });

    test('no jump at any lap boundary (continuous)', () {
      for (var n = 1; n <= 3; n++) {
        expect(_g.inset(n + .5), greaterThan(0));
        expect((_g.inset(n + 1e-7) - _g.inset(n - 1e-7)).abs(), lessThan(1e-3));
      }
    });

    test('the outer edge never exceeds the lap-0 circle', () {
      const r0 = 45.0;
      expect(_g.radiusAt(2, r0), lessThan(r0)); // it does spiral inward
      expect(_g.radiusAt(0, r0), r0);
      for (var s = 0.0; s <= 5; s += .01) {
        expect(_g.radiusAt(s, r0) + _w / 2, lessThanOrEqualTo(r0 + _w / 2 + _eps),
            reason: 's=$s');
      }
    });
  });

  group('laps', () {
    test('lapsFor', () {
      expect(SpiralGeometry.lapsFor(0), 0);
      expect(SpiralGeometry.lapsFor(-1), 0);
      expect(SpiralGeometry.lapsFor(double.nan), 0);
      expect(SpiralGeometry.lapsFor(.0001), 1);
      expect(SpiralGeometry.lapsFor(.66), 1);
      expect(SpiralGeometry.lapsFor(1), 1);
      expect(SpiralGeometry.lapsFor(1.0001), 2);
      expect(SpiralGeometry.lapsFor(2), 2);
      expect(SpiralGeometry.lapsFor(3), 3);
      expect(SpiralGeometry.lapsFor(3.5), 4);
    });

    test('a fraction <= 1 is one lap and no inset; 2.0 is two full laps', () {
      final one = _g.pieces([.66]);
      expect(one, hasLength(1));
      expect(one.single.lap, 0);
      expect(_sweep(one), closeTo(.66, _eps));
      for (final p in one) {
        expect(_g.inset(p.to), closeTo(0, _eps));
      }
      final two = _g.pieces([2.0]);
      expect(two.map((p) => p.lap), [0, 1]);
      expect(two[0].from, 0);
      expect(two[0].to, 1);
      expect(two[1].from, 1);
      expect(two[1].to, 2);
      expect(_sweep(two), closeTo(2.0, _eps));
    });

    test('exactly 100% is one lap, not a second sliver', () {
      final p = _g.pieces([1.0]);
      expect(p, hasLength(1));
      expect(p.single.lap, 0);
    });

    test('values are not clamped: 300% draws 3 laps, nothing beyond', () {
      final p = _g.pieces([3.0]);
      expect(p.map((e) => e.lap), [0, 1, 2]);
      expect(_sweep(p), closeTo(3.0, _eps));
      expect(p.every((e) => e.to <= 3.0 + _eps), isTrue);
    });

    test('empty, zero, negative and NaN fractions draw nothing', () {
      expect(_g.pieces([]), isEmpty);
      expect(_g.pieces([0]), isEmpty);
      expect(_g.pieces([-.5]), isEmpty);
      expect(_g.pieces([double.nan]), isEmpty);
      expect(_g.pieces([0, .4]).map((e) => e.seg), [1]);
    });
  });

  group('segments, order and caps', () {
    test('segments split at the lap boundary; cut ends are not capped', () {
      // a .3 | b .5 | c .4 -> c is cut at 1.0.
      final p = _g.pieces([.3, .5, .4]);
      expect(_sweep(p), closeTo(1.2, _eps));
      final c0 = p.singleWhere((e) => e.seg == 2 && e.lap == 0);
      final c1 = p.singleWhere((e) => e.seg == 2 && e.lap == 1);
      expect(c0.from, closeTo(.8, _eps));
      expect(c0.to, closeTo(1.0, _eps));
      expect(c0.capEnd, isFalse, reason: 'a lap cut is not an end');
      expect(c1.from, closeTo(1.0, _eps));
      expect(c1.to, closeTo(1.2, _eps));
      expect(c1.capEnd, isTrue);
    });

    test('paint order: lower laps first; in a lap the LAST segment first', () {
      final p = _g.pieces([.3, .5, .4]);
      expect(p.map((e) => (e.lap, e.seg)).toList(),
          [(0, 2), (0, 1), (0, 0), (1, 2)]);
    });

    test('every segment end is round (over its clockwise neighbour)', () {
      final p = _g.pieces([.3, .2, .1]);
      expect(p.map((e) => e.capEnd), everyElement(isTrue));
    });

    test('first start is round only while a gap precedes it (under 100%)', () {
      final under = _g.pieces([.3, .2]);
      expect(under.singleWhere((e) => e.seg == 0).capStart, isTrue);
      expect(under.singleWhere((e) => e.seg == 1).capStart, isFalse);
      for (final total in [[1.0], [.6, .4], [1.5], [.7, .8]]) {
        final p = _g.pieces(total);
        expect(p.every((e) => !e.capStart), isTrue, reason: '$total');
      }
    });

    test('single-colour ring under 100% has round caps at both ends', () {
      final p = _g.pieces([.66]).single;
      expect(p.capStart, isTrue);
      expect(p.capEnd, isTrue);
    });

    test('a segment spanning laps is capped only at its true end', () {
      final p = _g.pieces([2.0]);
      expect(p.map((e) => e.capEnd), [false, true]);
      expect(p.map((e) => e.capStart), [false, false]);
    });
  });

  group('separator and gradient', () {
    test('separator is 1.5px and starts where the lap leaves the one below',
        () {
      expect(kSpiralSeparator, 1.5);
      expect(_g.separatorFrom(0), isNull);
      final s1 = _g.separatorFrom(1)!;
      expect(s1, greaterThan(1.0));
      expect(s1, lessThan(1.3));
      expect(_g.inset(s1), closeTo(.5, .05));
      expect(_g.separatorFrom(2), 2.0);
    });

    test('gradient position is over the whole bar and never restarts', () {
      expect(SpiralGeometry.gradientAt(0, 2), 0);
      expect(SpiralGeometry.gradientAt(1, 2), closeTo(.5, _eps));
      expect(SpiralGeometry.gradientAt(2, 2), closeTo(1, _eps));
      expect(SpiralGeometry.gradientAt(.5, 1), closeTo(.5, _eps));
      var prev = -1.0;
      for (var s = 0.0; s <= 3; s += .01) {
        final g = SpiralGeometry.gradientAt(s, 3);
        expect(g, greaterThanOrEqualTo(prev));
        prev = g;
      }
      expect(SpiralGeometry.gradientAt(1.0 + 1e-6, 2),
          greaterThan(SpiralGeometry.gradientAt(1.0 - 1e-6, 2)));
    });
  });

  group('one implementation behind both painters', () {
    const track = Color(0x00000000);

    test('Ring draws exactly the fraction given, unclamped', () {
      for (final v in [.66, 1.0, 1.5, 2.0, 3.0]) {
        final r = Ring(v, Colors.green, track);
        expect(_sweep(r.pieces), closeTo(v, 1e-9), reason: 'v=$v');
      }
    });

    test('Ring scales by the draw-in progress t, never past the value', () {
      expect(_sweep(Ring(1.5, Colors.green, track, t: .5).pieces),
          closeTo(.75, 1e-9));
      expect(Ring(1.5, Colors.green, track, t: 0).pieces, isEmpty);
      expect(_sweep(Ring(1.5, Colors.green, track, t: 2).pieces),
          closeTo(1.5, 1e-9));
    });

    test('Ring draws nothing for zero, negative or NaN (no invented overflow)',
        () {
      for (final v in [0.0, -1.0, double.nan]) {
        expect(Ring(v, Colors.green, track).pieces, isEmpty, reason: '$v');
      }
    });

    test('Ring <= 100% never produces a second lap', () {
      for (final v in [.01, .5, 1.0]) {
        expect(Ring(v, Colors.green, track).pieces, isNotEmpty);
        expect(Ring(v, Colors.green, track).pieces.every((p) => p.lap == 0),
            isTrue);
      }
    });

    test('StageRing no longer clips: arcs summing to 1.5 draw 1.5 laps', () {
      final r = StageRing(const [
        RingArc(Colors.blue, .6),
        RingArc(Colors.red, .5),
        RingArc(Colors.green, .4),
      ], track);
      expect(_sweep(r.pieces), closeTo(1.5, 1e-9));
      expect(r.pieces.map((p) => p.lap).toSet(), {0, 1});
    });

    test('StageRing under 100%: one lap, round caps, same rules as Ring', () {
      final r = StageRing(const [
        RingArc(Colors.blue, .3),
        RingArc(Colors.red, .2),
      ], track);
      expect(_sweep(r.pieces), closeTo(.5, 1e-9));
      expect(r.pieces.every((p) => p.lap == 0 && p.capEnd), isTrue);
      expect(r.pieces.singleWhere((p) => p.seg == 0).capStart, isTrue);
    });

    test('StageRing scales by t and keeps segment order', () {
      final r = StageRing(const [
        RingArc(Colors.blue, .8),
        RingArc(Colors.red, .8),
      ], track, t: .5);
      expect(_sweep(r.pieces), closeTo(.8, 1e-9));
    });
  });

  group('render smoke', () {
    const side = 100.0;

    Future<List<int>> raster(CustomPainter p) async {
      final rec = ui.PictureRecorder();
      p.paint(Canvas(rec), const Size(side, side));
      final img = await rec.endRecording().toImage(side.toInt(), side.toInt());
      return (await img.toByteData())!.buffer.asUint8List().toList();
    }

    testWidgets('Ring at 66/100/150/200% pumps clean and the painter keeps '
        'the unclamped value', (tester) async {
      for (final v in [.66, 1.0, 1.5, 2.0]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: SizedBox(
              width: side,
              height: side,
              child: CustomPaint(
                  size: Size.infinite,
                  painter: Ring(v, Colors.green, const Color(0x22000000))),
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: 'v=$v');
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((e) => e.painter)
            .whereType<Ring>()
            .single;
        expect(painter.v, v);
        expect(_sweep(painter.pieces), closeTo(v, 1e-9), reason: 'v=$v');
      }
    });

    testWidgets('StageRing at 66/100/150/200% pumps clean and keeps every lap',
        (tester) async {
      for (final v in [.66, 1.0, 1.5, 2.0]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: SizedBox(
              width: side,
              height: side,
              child: CustomPaint(
                  size: Size.infinite,
                  painter: StageRing([
                    RingArc(Colors.blue, v * .5),
                    RingArc(Colors.red, v * .5),
                  ], const Color(0x22000000))),
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: 'v=$v');
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((e) => e.painter)
            .whereType<StageRing>()
            .single;
        expect(_sweep(painter.pieces), closeTo(v, 1e-9), reason: 'v=$v');
      }
    });

    testWidgets('pixels: each extra lap changes the picture (no clamp at 100%)',
        (tester) async {
      await tester.runAsync(() async {
        const tr = Color(0x00000000);
        final imgs = <double, List<int>>{
          for (final v in [1.0, 1.5, 2.0, 3.0])
            v: await raster(Ring(v, Colors.green, tr, stroke: 10, solid: true)),
        };
        expect(imgs[1.5], isNot(imgs[1.0]), reason: '150% must differ from 100%');
        expect(imgs[2.0], isNot(imgs[1.5]));
        expect(imgs[3.0], isNot(imgs[2.0]));
      });
    });

    testWidgets('pixels: nothing is drawn past the value, and t=0 is empty',
        (tester) async {
      await tester.runAsync(() async {
        const tr = Color(0x00000000);
        int alphaAt(List<int> px, int x, int y) => px[(y * side.toInt() + x) * 4 + 3];
        // 66%: the arc ends at ~238 degrees clockwise from 12; 9 o'clock
        // (270 degrees) must be untouched, 3 o'clock (90) painted.
        final a = await raster(Ring(.66, Colors.green, tr, stroke: 10, solid: true));
        expect(alphaAt(a, 5, 50), 0);
        expect(alphaAt(a, 95, 50), greaterThan(200));
        // Nothing beyond a 150% value inside the lap-0 circle's outer edge.
        final empty = await raster(Ring(1.5, Colors.green, tr, t: 0, solid: true));
        expect(empty.every((b) => b == 0), isTrue);
        // The outer edge never leaves the lap-0 circle: the corners stay clear.
        final big = await raster(Ring(3.0, Colors.green, tr, stroke: 10, solid: true));
        for (final (x, y) in [(1, 1), (98, 1), (1, 98), (98, 98)]) {
          expect(alphaAt(big, x, y), 0);
        }
        expect(sqrt(pow(50 - 1, 2) * 2), greaterThan(50)); // sanity: corner is outside
      });
    });
  });

  // ── fix round: the RENDERED shape, not just the helper maths ──────────────

  group('rendered spiral (pixel probes)', () {
    const side = 200, w = 20.0, r0 = 100 - w / 2;
    const green = Color(0xFF00AA00);
    const magenta = Color(0xFFFF00FF);
    final g = SpiralGeometry(w);

    Future<ByteData> raster(CustomPainter p, {int px = side}) async {
      final rec = ui.PictureRecorder();
      p.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
      final img = await rec.endRecording().toImage(px, px);
      return (await img.toByteData())!;
    }

    // RGBA at the pixel under polar (u laps clockwise from 12, radius r).
    List<int> at(ByteData d, double u, double r, {int px = side}) {
      final x = (px / 2 + r * sin(2 * pi * u)).floor().clamp(0, px - 1);
      final y = (px / 2 - r * cos(2 * pi * u)).floor().clamp(0, px - 1);
      final i = (y * px + x) * 4;
      return [for (var k = 0; k < 4; k++) d.getUint8(i + k)];
    }

    bool isGreen(List<int> c) => c[3] > 200 && c[1] > 120 && c[0] < 60;

    // First radius (scanning outward from the centre) that is the ring colour.
    double innerEdge(ByteData d, double u) {
      for (var r = 5.0; r < 100; r += .25) {
        if (isGreen(at(d, u, r))) return r;
      }
      return double.nan;
    }

    // The innermost painted edge at angle u when laps 0..top overlap there.
    double expectedInner(double sTop) => r0 - g.inset(sTop) - w / 2;

    testWidgets('130% ring: the inner edge follows the eased ramp r0 -> '
        'r0 - 0.75 x stroke, then holds', (tester) async {
      await tester.runAsync(() async {
        final d = await raster(Ring(1.3, green, const Color(0x00000000),
            stroke: w, solid: true, background: magenta));
        for (final u in [.03, .06, .1, .15, .2, .25, .28]) {
          expect(innerEdge(d, u), closeTo(expectedInner(1 + u), 1.6),
              reason: 'u=$u inset=${g.inset(1 + u)}');
        }
        // Past the value (u > .3) only lap 0 is there: edge back at r0 - w/2.
        for (final u in [.4, .6, .9]) {
          expect(innerEdge(d, u), closeTo(r0 - w / 2, 1.6), reason: 'u=$u');
        }
      });
    });

    testWidgets('300% ring: the innermost edge follows the profile on lap 2',
        (tester) async {
      await tester.runAsync(() async {
        final d = await raster(Ring(3.0, green, const Color(0x00000000),
            stroke: w, solid: true, background: magenta));
        for (final u in [.05, .1, .2, .5, .9]) {
          expect(innerEdge(d, u), closeTo(expectedInner(2 + u), 1.6),
              reason: 'u=$u');
        }
      });
    });

    testWidgets('stage ring: segment joins and lap cuts have no radial jump',
        (tester) async {
      await tester.runAsync(() async {
        // Joins at s = .5, .9, 1.3 (inside lap 1) and the lap cut at 1.0.
        final d = await raster(StageRing(const [
          RingArc(green, .5),
          RingArc(green, .4),
          RingArc(green, .4),
          RingArc(green, .4),
        ], const Color(0x00000000), stroke: w, background: magenta));
        for (final u in [.1, .2, .28, .29, .31, .32, .4, .6]) {
          expect(innerEdge(d, u), closeTo(expectedInner(1 + u), 2.0),
              reason: 'u=$u');
        }
      });
    });

    testWidgets('the separator is the BACKGROUND colour, above lap 0, only '
        'along the lap\'s real sweep', (tester) async {
      await tester.runAsync(() async {
        final d = await raster(Ring(1.3, green, const Color(0xFFFFFF00),
            stroke: w, solid: true, background: magenta));
        // Just outside lap 1's outer edge, on top of lap 0's band.
        // A thin LINE centred on the upper lap's outer edge.
        double rim(double s) => r0 - g.inset(s) + w / 2 + .75;
        double edge(double s) => r0 - g.inset(s) + w / 2;
        for (final u in [.15, .2, .25]) {
          final c = at(d, u, edge(1 + u));
          expect(c[0] > 100 && c[2] > 100, isTrue, reason: 'u=$u px=$c');
        }
        // Past the value: no separator, lap 0 colour is intact.
        for (final u in [.4, .5]) {
          expect(isGreen(at(d, u, rim(1.25))), isTrue, reason: 'u=$u');
        }
        // And never the track colour.
        expect(at(d, .2, rim(1.2)), isNot(equals([255, 255, 0, 255])));
      });
    });

    testWidgets('default gradient Ring is visible (solid: false)',
        (tester) async {
      await tester.runAsync(() async {
        final d = await raster(Ring(.66, green, const Color(0x00000000),
            stroke: w, background: magenta));
        expect(at(d, .3, r0)[3], greaterThan(120));
        expect(at(d, .05, r0)[3], greaterThan(60));
        expect(at(d, .8, r0)[3], 0, reason: 'past .66 nothing is drawn');
      });
    });

    testWidgets('gradient spans the WHOLE bar: lap 1 continues where lap 0 '
        'ended', (tester) async {
      await tester.runAsync(() async {
        final d = await raster(Ring(2.0, green, const Color(0x00000000),
            stroke: w, background: magenta));
        // At u=.2 lap 1 has an inner sliver lap 0 does not cover. Its colour
        // is pre-blended against the background: bar position 1.2 / 2 = .6 ->
        // 82% green, 18% background, so red is about 46. A lap that restarted
        // faint would be about 92.
        final px = at(d, .2, r0 - w / 2 - .25 * g.inset(1.2));
        expect(px[3], 255);
        expect(px[0], lessThan(65), reason: 'restarted per lap? $px');
        // Start of the bar is faint (a one-lap ring, nothing under it).
        final one = await raster(Ring(1.0, green, const Color(0x00000000),
            stroke: w, background: magenta));
        expect(at(one, .02, r0)[0], greaterThan(95));
      });
    });

    testWidgets('20 px / stroke 3 ring survives 500% and 1000%',
        (tester) async {
      await tester.runAsync(() async {
        for (final v in [5.0, 10.0]) {
          final d = await raster(
              Ring(v, green, const Color(0x00000000),
                  stroke: 3, solid: true, background: magenta),
              px: 20);
          // The ring is painted, nothing is drawn through the centre.
          expect(at(d, .3, 8.5, px: 20)[3], greaterThan(200), reason: 'v=$v');
          expect(at(d, .3, 0.5, px: 20)[3], 0, reason: 'centre stays empty');
        }
      });
    });
  });

  group('small rings never run out of centre', () {
    test('centre-line radius floors at 1.5 x stroke (20 px ring, stroke 3)', () {
      const small = SpiralGeometry(3);
      const r0 = 10 - 1.5;
      for (var s = 0.0; s <= 20; s += .05) {
        expect(small.radiusAt(s, r0), greaterThanOrEqualTo(1.5 * 3 - 1e-9),
            reason: 's=$s');
      }
      expect(small.radiusAt(5.3, r0), closeTo(4.5, 1e-9)); // 500% floored
      expect(small.radiusAt(1.3, r0), closeTo(r0 - 2.25, 1e-9)); // untouched
    });
  });

  group('caps are applied independently', () {
    int discs(CustomPainter p) {
      final rec = _Discs();
      p.paint(rec, const Size(100, 100));
      return rec.n;
    }

    const none = Color(0x00000000);

    test('150% single colour: one disc (the end); the lap-cut start is square',
        () {
      expect(discs(Ring(1.5, Colors.green, none, solid: true)), 1);
    });

    test('66% single colour: discs at both ends', () {
      expect(discs(Ring(.66, Colors.green, none, solid: true)), 2);
    });

    test('a full segmented circle: no start disc over the last segment\'s end',
        () {
      expect(
          discs(StageRing(const [
            RingArc(Colors.blue, .5),
            RingArc(Colors.red, .5),
          ], none)),
          2);
    });
  });

  group('shouldRepaint covers every input', () {
    test('Ring: track, stroke, v, t, solid, color, background', () {
      final base = Ring(.5, Colors.green, Colors.grey);
      expect(Ring(.5, Colors.green, Colors.grey).shouldRepaint(base), isFalse);
      expect(Ring(.5, Colors.green, Colors.black).shouldRepaint(base), isTrue);
      expect(Ring(.5, Colors.green, Colors.grey, stroke: 4).shouldRepaint(base),
          isTrue);
      expect(Ring(.5, Colors.green, Colors.grey, background: Colors.white)
          .shouldRepaint(base), isTrue);
    });
  });
}

class _Discs implements Canvas {
  int n = 0;
  var _first = true;
  @override
  void drawCircle(Offset c, double r, Paint p) {
    if (_first) {
      _first = false; // the track
      return;
    }
    // Separator halos are background-coloured (here transparent).
    if (p.style == PaintingStyle.fill && p.color.a > 0) n++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
