// Round 3 on the spiral ring: the separator is a thin line, not an eraser, and
// a translucent (gradient) ring composites each coloured region once.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/spiral_ring.dart';

const _green = Color(0xFF00AA00);
const _bg = Color(0xFFFF00FF);
const _none = Color(0x00000000);

Future<ByteData> _raster(CustomPainter p, int px) async {
  final rec = ui.PictureRecorder();
  p.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData())!;
}

List<int> _at(ByteData d, int px, double u, double r) {
  final x = (px / 2 + r * sin(2 * pi * u)).floor().clamp(0, px - 1);
  final y = (px / 2 - r * cos(2 * pi * u)).floor().clamp(0, px - 1);
  final i = (y * px + x) * 4;
  return [for (var k = 0; k < 4; k++) d.getUint8(i + k)];
}

bool _magenta(List<int> c) =>
    c[3] > 100 && c[0] > 200 && c[2] > 200 && c[1] < 80;

void main() {
  testWidgets('20 px / stroke 3 ring at 500%: no empty or background pixel '
      'between the outer edge and the innermost lap', (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(
          Ring(5.0, _green, _none, stroke: 3, solid: true, background: _bg),
          20);
      for (var k = 0; k < 12; k++) {
        final u = k / 12 + .02;
        double? inner;
        for (var r = 1.5; r < 10; r += .25) {
          if (_at(d, 20, u, r)[3] > 200) {
            inner = r;
            break;
          }
        }
        expect(inner, isNotNull, reason: 'u=$u');
        for (var r = inner! + .5; r < 8.8; r += .25) {
          final c = _at(d, 20, u, r);
          expect(c[3], greaterThan(200), reason: 'gap at u=$u r=$r $c');
          expect(_magenta(c), isFalse, reason: 'separator at u=$u r=$r');
        }
      }
    });
  });

  testWidgets('200 px / stroke 20: the separator is present and at most '
      '1.5 px wide', (tester) async {
    await tester.runAsync(() async {
      const g = SpiralGeometry(20);
      final d = await _raster(
          Ring(1.3, _green, _none, stroke: 20, solid: true, background: _bg),
          200);
      for (final u in [.15, .2, .25]) {
        final edge = 90 - g.inset(1 + u) + 10;
        // Width = sum of the magenta share (the red channel; the ring is
        // green) along the ray, so antialiased edge pixels count fractionally.
        var w = 0.0;
        for (var r = edge - 4; r < edge + 4; r += .1) {
          w += _at(d, 200, u, r)[0] / 255 * .1;
        }
        expect(w, greaterThan(.6), reason: 'u=$u: no separator');
        expect(w, lessThanOrEqualTo(1.8), reason: 'u=$u width $w');
      }
    });
  });

  test('separator width scales with stroke and vanishes on tiny rings', () {
    expect(kSpiralSeparator, 1.5);
    expect(spiralSeparatorWidth(20), closeTo(1.5, 1e-9));
    expect(spiralSeparatorWidth(40), closeTo(1.5, 1e-9));
    expect(spiralSeparatorWidth(14), closeTo(1.05, 1e-9));
    expect(spiralSeparatorWidth(10), closeTo(.75, 1e-9));
    expect(spiralSeparatorWidth(3), 0);
    expect(spiralSeparatorWidth(6), 0);
  });

  // Round 5: a gradient ring is pre-blended against `background` and drawn
  // fully opaque, with ordinary discs and bands. No cap subtraction, so no
  // crack at the join and the 100% end cap is back.

  testWidgets('gradient ring at 66%: start and end caps blend into the band '
      'with the same colour (once)', (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(
          Ring(.66, _green, _none, stroke: 20, background: _bg), 200);
      int red(double u, double r) => _at(d, 200, u, r)[0];
      expect((red(.008, 90) - red(.05, 90)).abs(), lessThan(16),
          reason: 'start cap overlap vs band');
      expect((red(.99, 90) - red(.05, 90)).abs(), lessThan(24),
          reason: 'cap-only side vs band');
      expect((red(.655, 90) - red(.6, 90)).abs(), lessThan(16),
          reason: 'end cap overlap vs band');
    });
  });

  for (final v in [.66, 1.3]) {
    testWidgets('gradient ring at ${(v * 100).round()}%: no crack along the '
        'cap/band joins', (tester) async {
      await tester.runAsync(() async {
        const g = SpiralGeometry(20);
        final d = await _raster(
            Ring(v, _green, _none, stroke: 20, background: _bg), 200);
        // Points that are inside the band or its end caps, 3 px clear of the
        // edges: every one must be fully opaque and match its horizontal
        // neighbours (a crack is a lighter or more transparent hairline).
        final end = v % 1;
        final probes = <(double, double)>[
          for (var k = -6; k <= 6; k++) (k / 200, 90.0), // start cap region
          for (var k = -6; k <= 6; k++)
            (end + k / 200, g.radiusAt(v, 90).toDouble()), // end cap region
        ];
        for (final (u, r) in probes) {
          for (var dr = -6.0; dr <= 6; dr += 1) {
            final rr = r + dr;
            if (v > 1 && u > .5 && u < end - .5) continue;
            final c = _at(d, 200, u, rr);
            if (c[3] < 255) {
              // Allowed only outside the painted shape (track is transparent).
              continue;
            }
            final x = (100 + rr * sin(2 * pi * u)).floor();
            final y = (100 - rr * cos(2 * pi * u)).floor();
            for (final nx in [x - 1, x + 1]) {
              final i = (y * 200 + nx) * 4;
              if (d.getUint8(i + 3) < 255) continue; // shape boundary
              for (var ch = 0; ch < 3; ch++) {
                expect((d.getUint8(i + ch) - c[ch]).abs(), lessThan(40),
                    reason: 'crack at u=$u r=$rr ch=$ch');
              }
            }
          }
        }
        // Inside both band and cap the pixel is opaque and not background.
        for (final (u, r) in [(.02, 90.0), (end - .02, g.radiusAt(v, 90))]) {
          final c = _at(d, 200, u, r);
          expect(c[3], 255, reason: 'u=$u');
          expect(c[0] < 200, isTrue, reason: 'background shows at u=$u $c');
        }
      });
    });
  }

  testWidgets('gradient ring at 100% keeps its round end cap over the start',
      (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(
          Ring(1.0, _green, _none, stroke: 20, background: _bg), 200);
      // The end disc (full colour) covers (105,12); the start band there is
      // faint (mostly background pink), so the disc must be on top.
      final c = _at(d, 200, 5 / (2 * pi * 90), 88);
      expect(c[0], lessThan(40), reason: 'end cap missing: $c');
      // And it is round: the disc reaches just past the straight seam but not
      // beyond its radius.
      expect(_at(d, 200, 14 / (2 * pi * 90), 90)[0], greaterThan(60));
    });
  });
}
