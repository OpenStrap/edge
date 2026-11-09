// Round 2 on the spiral ring: what is VISIBLE at stage joins, lap boundaries
// and on small rings at high ratios. Pixel probes, not call counts.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/spiral_ring.dart';

const _a = Color(0xFF0000FF);
const _b = Color(0xFFFF0000);
const _bg = Color(0xFFFF00FF);
const _none = Color(0x00000000);
const _side = 200;
const _w = 20.0;
const _r0 = 100 - _w / 2;

Future<ByteData> _raster(CustomPainter p, {int px = _side}) async {
  final rec = ui.PictureRecorder();
  p.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData())!;
}

List<int> _px(ByteData d, double x, double y, {int px = _side}) {
  final i = (y.floor() * px + x.floor()) * 4;
  return [for (var k = 0; k < 4; k++) d.getUint8(i + k)];
}

List<int> _polar(ByteData d, double u, double r) =>
    _px(d, 100 + r * sin(2 * pi * u), 100 - r * cos(2 * pi * u));

bool _is(List<int> c, Color k) =>
    c[3] > 200 &&
    (c[0] - (k.r * 255)).abs() < 40 &&
    (c[1] - (k.g * 255)).abs() < 40 &&
    (c[2] - (k.b * 255)).abs() < 40;

class _Count implements Canvas {
  int paths = 0;
  @override
  void drawPath(Path p, Paint paint) => paths++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const g = SpiralGeometry(_w);

  testWidgets('separator halos never cut a hole in the clockwise neighbour',
      (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(StageRing(const [
        RingArc(_a, 1.5),
        RingArc(_b, .5),
      ], _none, stroke: _w, background: _bg));
      // B's centre-line just clockwise of A's end (inside A's old halo).
      for (final u in [.5228, .53, .56, .6, .8]) {
        final c = _polar(d, u, g.radiusAt(1 + u, _r0));
        expect(_is(c, _b), isTrue, reason: 'u=$u px=$c');
      }
    });
  });

  testWidgets('a segment ending exactly on a lap boundary keeps its round cap '
      'over the neighbour', (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(StageRing(const [
        RingArc(_a, 1.0),
        RingArc(_b, .5),
      ], _none, stroke: _w, background: _bg));
      // A ends at 12 o'clock. Its disc (r 10) covers (105,12), which B's lap-1
      // band starts under; the cap must be on top.
      expect(_is(_px(d, 105, 12), _a), isTrue, reason: _px(d, 105, 12).toString());
      expect(_is(_px(d, 100, 16), _a), isTrue);
      // Away from the cap B is on top.
      expect(_is(_polar(d, .3, g.radiusAt(1.3, _r0)), _b), isTrue);
    });
  });

  testWidgets('full-circle seam: the last segment\'s round end is visible over '
      'the first segment\'s start', (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(StageRing(const [
        RingArc(_a, .5),
        RingArc(_b, .5),
      ], _none, stroke: _w, background: _bg));
      // B ends at 12 o'clock; its disc covers (105,12) clockwise of the seam.
      expect(_is(_px(d, 105, 12), _b), isTrue, reason: _px(d, 105, 12).toString());
      // The first segment's own start is square: well clockwise it is A.
      expect(_is(_polar(d, .1, _r0), _a), isTrue);
    });
  });

  group('small rings saturate', () {
    const small = SpiralGeometry(3);
    const r0 = 10 - 1.5;

    test('saturationLaps: the lap after which every lap looks the same', () {
      // Hold radius of lap L is r0 - 2.25 L; the floor is 4.5: lap 2 sits on it.
      expect(small.saturationLaps(r0), 3);
      expect(g.saturationLaps(_r0), 5); // 90 - 15 L <= 30 -> L = 4 -> 5 laps
      // A ring too small to inset at all is one lap.
      expect(const SpiralGeometry(10).saturationLaps(12), 1);
    });

    testWidgets('1000% builds a bounded number of paths, same as the '
        'saturation point', (tester) async {
      Ring ring(double v) => Ring(v, _a, _none,
          stroke: 3, solid: true, background: _bg);
      int paths(double v) {
        final c = _Count();
        ring(v).paint(c, const Size(20, 20));
        return c.paths;
      }

      expect(paths(200), lessThanOrEqualTo(paths(3.0)));
      expect(paths(200), lessThan(30));
      expect(paths(10), paths(3.0));
      await tester.runAsync(() async {
        final sat = await _raster(ring(3.0), px: 20);
        for (final v in [5.0, 10.0, 200.0]) {
          final d = await _raster(ring(v), px: 20);
          expect(d.buffer.asUint8List(), sat.buffer.asUint8List(),
              reason: 'v=$v');
        }
      });
    });

    test('the value itself is still reported unclamped by pieces', () {
      expect(Ring(10, _a, _none, stroke: 3).pieces.last.to, 10.0);
    });
  });
}
