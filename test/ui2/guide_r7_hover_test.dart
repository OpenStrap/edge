// WHY: an overlay rectangle can agree at rest and drift during stretch/scroll. Move the target's ancestor without replanning, then inspect actual pixels.
// CLAIM(hover-in-target-tree).
import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart'; import 'package:openstrap_edge/ui2/theme.dart';
void main() { testWidgets('R7 hover follows the target through translation and stretch, leaving no paint behind', (t) async {
    final controller = GuideDimController(); final transform = ValueNotifier(Matrix4.identity()); final key = GlobalKey();
    await t.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: GuideDimScope(controller: controller, child: Center(child: RepaintBoundary(key: key,
        child: SizedBox(width: 220, height: 220, child: ColoredBox(color: C.n900, child: Stack(children: [
          Positioned(left: 40, top: 40, child: ValueListenableBuilder<Matrix4>(valueListenable: transform,
            builder: (_, matrix, child) => Transform(transform: matrix, child: child), child: Builder(builder: (c) => GuideUnitMark(component: c,
              child: const SizedBox(width: 120, height: 80, child: ColoredBox(color: C.n600))))), ), ]))), )))));
    final mark = t.renderObject<RenderGuideUnit>(find.byType(GuideUnitMark));
    final hover = GuideHover(Offset.zero & mark.size, 6, C.blue)..value = 1; controller.setHovers({mark: hover}); await t.pump();
    Future<List<int>> pixels(List<Offset> points) async => (await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key)); final image = await boundary.toImage(); try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        return [for (final point in points) bytes.getUint32((point.dy.toInt() * image.width + point.dx.toInt()) * 4)]; } finally { image.dispose(); } }))!;
    final before = await pixels([const Offset(100, 80), const Offset(5, 5)]);
    // A large target's centre must receive only the reference's 26% tint. Outer-fill blur can take a rectangular fast path and add 55% in its
    // middle, leaving a conspicuous lighter patch. Use independent RGB math.
    final expected = [ (.74 * 71 + .26 * 59).round(), (.74 * 85 + .26 * 130).round(), (.74 * 105 + .26 * 246).round(), ];
    final actual = [before[0] >> 24 & 255, before[0] >> 16 & 255, before[0] >> 8 & 255]; for (var i = 0; i < 3; i++) {
      expect(actual[i], closeTo(expected[i], 2), reason: 'uniform tint, without an inner glow rectangle'); }
    expect(before[0], isNot(before[1]), reason: 'positive control: hover is visible');
    transform.value = Matrix4.identity()..translateByDouble(60, 60, 0, 1)..scaleByDouble(1, 1.3, 1, 1); await t.pump();
    final after = await pixels([const Offset(160, 152), const Offset(60, 50)]); expect(after[0], before[0], reason: 'hover stretches/moves in the exact frame its target does');
    expect(after[1], before[1], reason: 'old position has no leftover tint or glow');
    expect(mark.hover, same(hover), reason: 'no geometry plan was republished'); controller.clearHovers(); await t.pump();
    final cleared = await pixels([const Offset(160, 152)]); expect(cleared.single, isNot(after[0]), reason: 'ending a run removes hover');
    await t.pumpWidget(const SizedBox()); controller.dispose(); transform.dispose(); }); }
