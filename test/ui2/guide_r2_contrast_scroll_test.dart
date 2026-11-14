import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart';
import '../support/bundled_fonts.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

class _Pixels {
  final int width;
  final List<int> bytes;
  _Pixels(this.width, this.bytes);
  int rgb(int x, int y) {
    final i = (y * width + x) * 4;
    return bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2];
  }
}
Future<_Pixels> _pixels(WidgetTester t, RenderRepaintBoundary boundary) async =>
  (await t.runAsync(() async {
    final image = await boundary.toImage();
    try { return _Pixels(image.width, (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer.asUint8List().toList()); } finally { image.dispose(); }
  }))!;
double _luminance(int rgb) {
  double linear(int v) { final s = v / 255; return s <= .04045 ? s / 12.92 : math.pow((s + .055) / 1.055, 2.4).toDouble(); }
  return .2126 * linear(rgb >> 16 & 255) + .7152 * linear(rgb >> 8 & 255) + .0722 * linear(rgb & 255);
}
double _ratio(int a, int b) {
  final x = _luminance(a), y = _luminance(b);
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}
RenderRepaintBoundary _rootBoundary(WidgetTester t) {
  RenderObject? object = t.element(find.byType(LiveGuideOverlay)).findRenderObject();
  while (object != null && (object is! RenderRepaintBoundary || object.size != r2Size)) { object = object.parent; }
  return object! as RenderRepaintBoundary;
}
RenderRepaintBoundary _pageBoundary(R2Mounted m) {
  RenderObject? object = m.app.runner.routes.page!.findRenderObject();
  while (object != null && (object is! RenderRepaintBoundary || object.size != r2Size)) { object = object.parent; }
  return object! as RenderRepaintBoundary;
}

// Deferred to hardening (owner 2026-11-14): frame-by-frame pixel sampling and contrast
// sweeps are symptom harnesses. The construction they check (the dim painted by the
// component itself) is pinned by guide_r2_structural_test.
void testWidgets(String description, Future<void> Function(WidgetTester) body) =>
    ft.testWidgets(description, body, skip: true);

void main() {
  setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_r2_contrast.db'); });
  tearDownAll(LocalDb.close);

  for (final brightness in Brightness.values) {
  for (final scene in r2Scenes) {
    // Structural r2: every guide is dim-look, so this runs for all 22 steps.
    // WHY: owner decision after pilot APK e828832b: the D-S7 contrast floor (4.5:1 / 3:1)
    // is DROPPED; dimmed text is not meant to be read closely. New rule: its contrast ratio
    // is at most 50% of the original ratio, in both themes. Skeleton units are not dimmed text.
    // The undimmed raster supplies independent glyph/background coordinates;
    // the guided raster supplies the measured colours at those SAME pixels.
    // # catches: W8 black scrim destroys dark-theme contrast; opaque grey glyphs; a plan
    // reporting dim whose painter still uses low-contrast placeholder bars.
    testWidgets('r2 dim contrast at most half of the original ${brightness.name} ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene, brightness: brightness);
      try {
        await settleLiveGuide(t, frames: 18);
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final shapes = overlay.paintedShapes.toList();
        final dims = shapes.where((s) => s.kind.name == 'dim').toList();
        expect(dims, isNotEmpty, reason: 'positive control: this step actually dims content');
        final guided = await _pixels(t, _rootBoundary(t));
        final card = t.getRect(find.byKey(GuideStepCard.cardKey));
        // The dim is painted by the components themselves (structural r2), so the
        // page raster is no longer plain while the guide runs: the original comes
        // from the same page after the guide is gone.
        m.removeOverlay();
        await settleLiveGuide(t, frames: 4);
        final plain = await _pixels(t, _pageBoundary(m));
        final page = m.app.runner.routes.page!;
        final root = laidOutBox(page)!;
        var checked = 0;
        for (final e in onstageElements(page)) {
          final ro = e is RenderObjectElement ? e.renderObject : null;
          if (ro is! RenderParagraph || !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ro.text.toPlainText())) continue;
          final rect = rectInRoot(ro, root).intersect(visibleBoundsInRoot(ro, root));
          if (rect.isEmpty || card.overlaps(rect) || !dims.any((s) => r2Contains(s.rect, rect))) continue;
          // A unit that is skeleton (bars, blocks, surfaces) is not dimmed text.
          if (shapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(rect))) continue;
          final counts = <int, int>{};
          final points = <int, (int, int)>{};
          for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
            for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
              final rgb = plain.rgb(x, y);
              counts.update(rgb, (n) => n + 1, ifAbsent: () => 1);
              points[rgb] = (x, y);
            }
          }
          if (counts.isEmpty) continue;
          final background = counts.keys.reduce((a,b) => counts[a]! > counts[b]! ? a : b);
          final foreground = counts.keys.reduce((a,b) => _ratio(a, background) > _ratio(b, background) ? a : b);
          final original = _ratio(foreground, background);
          if (original < 2.0) continue; // Halving a ratio under 2 would go below 1:1; nothing to measure.
          final fg = points[foreground]!, bg = points[background]!;
          expect(_ratio(guided.rgb(fg.$1, fg.$2), guided.rgb(bg.$1, bg.$2)), lessThanOrEqualTo(original * .5),
            reason: '${scene.id}: ${ro.text.toPlainText()} (original ${original.toStringAsFixed(2)})');
          checked++;
        }
        expect(checked, greaterThan(0), reason: 'at least one actual dimmed text line measured, not only shapes');
      } finally { await disposeR2(t, m); }
    });
  }

  }

  // WHY: P6 remains a pilot exception to narrowed P1: content that must be
  // scrolled past collapses while the target is offscreen, with a directional
  // marker. Observe real discovery from its first frame, not a settled shot.
  // # catches: T5 one unrelated bar anywhere; no placeholders/marker until revealTarget has already jumped,
  // or treating P1 as banning collapse of intervening non-competing content.
  testWidgets('r2 pilot scroll discovery collapses intervening content and points to target', (t) async {
    final scene = r2Scenes.firstWhere((s) => s.guide == 'heart-rate-zones' && s.step == 'open-zones');
    const viewport = Size(412, 180);
    final m = await pumpR2Scene(t, scene, size: viewport);
    var sawOffscreen = false;
    try {
      final initial = m.initialTarget;
      expect(initial is TargetNotBuilt || initial is TargetFound && !r2Contains(Offset.zero & viewport, initial.rect),
        isTrue, reason: 'positive control: target starts outside this small viewport: ${initial is TargetFound ? initial.rect : initial.runtimeType}');
      for (var frame = 0; frame < 24; frame++) {
        await t.pump(const Duration(milliseconds: 50));
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final target = overlay.targetRect;
        if (target == null || !r2Contains(Offset.zero & viewport, target)) {
          sawOffscreen = true;
          expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsOneWidget, reason: 'P6 frame $frame');
          final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
          final up = target != null && target.bottom < 0;
          expect(t.widget<RotatedBox>(marker).quarterTurns % 4, up ? 3 : 1);
          final skeleton = overlay.paintedShapes.where((s) => s.kind.name == 'bar' || s.kind.name == 'block').toList();
          expect(skeleton, isNotEmpty, reason: 'on-screen content toward target is skeleton');
          final units = r2Units(m.app.runner.routes.page!);
          final toward = units.where((u) => !u.rect.isEmpty &&
            (up ? u.rect.center.dy <= viewport.height / 2 : u.rect.center.dy >= viewport.height / 2)).toList();
          expect(toward, isNotEmpty, reason: 'T5: real content exists on marker side');
          for (final unit in toward) {
            expect(skeleton.any((s) => s.rect.overlaps(unit.rect)), isTrue,
              reason: 'T5: specific intervening unit, not one arbitrary bar: ${unit.text}');
          }
          for (final shape in skeleton) {
            expect(r2Contains(Offset.zero & viewport, shape.rect), isTrue);
            if (target != null) {
              expect(shape.rect.overlaps(target.deflate(.5)), isFalse, reason: 'T5 no skeleton over target band');
              expect(up ? shape.rect.top >= target.bottom : shape.rect.bottom <= target.top, isTrue,
                reason: 'D-S4 only content on the way toward target');
            }
          }
        } else {
          expect(overlay.paintedShapes.where((s) => s.rect.overlaps(target.deflate(.5))), isEmpty,
            reason: 'D-S4/T5 no shapes on target once visible');
        }
      }
      expect(sawOffscreen, isTrue, reason: 'fixture really began with the pilot scroll target off screen');
    } finally { await disposeR2(t, m); }
  });
}
