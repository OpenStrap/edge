// Uses Flutter instrumentation to compare guide screens before and after a tab footer change.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../../test/support/bundled_fonts.dart';
import '../../test/support/guide_r2_scenes.dart';
import '../../test/support/guide_r7_scenes.dart';
import '../../test/support/live_guide_harness.dart';
import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;

final _out = Platform.environment['HELP_GUIDE_SHOTS'];
void main() {
  setUpAll(() async {
    if (_out == null) return;
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('help_guide_comparison.db');
  });
  for (final scene in r2Scenes) {
    testWidgets('compare ${scene.id}', (t) async {
      final key = GlobalKey();
      final mounted = await pumpR2Scene(
        t,
        scene,
        size: const Size(412, 915),
        brightness: Brightness.dark,
        captureKey: key,
      );
      try {
        await settleMovingGuide(t);
        for (
          var i = 0;
          i < 100 && t.any(find.byType(CircularProgressIndicator));
          i++
        ) {
          await settleLiveGuide(t, frames: 4);
        }
        await settleMovingGuide(t);
        final overlay = t.state<LiveGuideOverlayState>(
          find.byType(LiveGuideOverlay),
        );
        expect(overlay.targetRect, isNotNull, reason: scene.id);
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'do not compare a loading page',
        );
        final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
        await t.runAsync(() async {
          t.binding.rootPipelineOwner.flushPaint();
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final path = '$_out/${scene.id.replaceAll('/', '-')}';
            await File('$path.png').parent.create(recursive: true);
            await File('$path.png').writeAsBytes(bytes!.buffer.asUint8List());
            await File('$path.json').writeAsString(
              jsonEncode({
                'target': overlay.targetRect.toString(),
                'shapes': [
                  for (final s in overlay.paintedShapes)
                    '${s.kind.name}: ${s.rect}',
                ],
              }),
            );
          } finally {
            image.dispose();
          }
        });
      } finally {
        await disposeR2(t, mounted);
      }
    }, skip: _out == null);
  }
}
