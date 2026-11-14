// Composited-pixel helpers for the r2 tests. The structural r2 dim is painted by
// the components themselves, so tests read pixels (what the user sees) rather
// than the overlay's plan.
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class R2Raster {
  final int width, height;
  final List<int> bytes;
  R2Raster(this.width, this.height, this.bytes);

  /// The pixel at ([x], [y]) as [r, g, b].
  List<int> at(int x, int y) {
    final i = (y.clamp(0, height - 1) * width + x.clamp(0, width - 1)) * 4;
    return [bytes[i], bytes[i + 1], bytes[i + 2]];
  }
}

/// The composited raster of the repaint boundary under [key] (1 logical px = 1 pixel).
Future<R2Raster> r2Raster(WidgetTester t, Finder boundary) =>
  r2RasterOf(t, t.renderObject<RenderRepaintBoundary>(boundary));

/// The root repaint boundary that holds the page AND the guide overlay (the screen).
RenderRepaintBoundary r2RootBoundary(WidgetTester t, Finder inside) {
  RenderObject? object = t.element(inside).findRenderObject();
  final view = t.view.physicalSize / t.view.devicePixelRatio;
  while (object != null && (object is! RenderRepaintBoundary || object.size != view)) { object = object.parent; }
  return object! as RenderRepaintBoundary;
}

Future<R2Raster> r2RasterOf(WidgetTester t, RenderRepaintBoundary object) async {
  return (await t.runAsync(() async {
    final image = await object.toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return R2Raster(image.width, image.height, data.buffer.asUint8List().toList());
    } finally { image.dispose(); }
  }))!;
}

/// The largest per-channel distance between two pixels.
int r2Distance(List<int> a, List<int> b) =>
  [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()].reduce(math.max);

/// The largest distance from [reference] over the pixels of [rect].
int r2MaxDistance(R2Raster r, Rect rect, List<int> reference) {
  var best = 0;
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      best = math.max(best, r2Distance(r.at(x, y), reference));
    }
  }
  return best;
}

List<int> r2Rgb(Color c) => [(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round()];

/// What a pixel of colour [original] becomes under a veil of [veil] at [opacity].
List<int> r2Veiled(List<int> original, List<int> veil, double opacity) =>
  [for (var c = 0; c < 3; c++) (original[c] * (1 - opacity) + veil[c] * opacity).round()];
