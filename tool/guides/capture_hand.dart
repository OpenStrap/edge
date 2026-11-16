// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Round 7 evidence: every step, real app pages, dark, bundled fonts.
import 'dart:io'; import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:path/path.dart' as p;
import '../../test/support/bundled_fonts.dart'; import '../../test/support/guide_r2_scenes.dart';
import '../../test/support/guide_r7_scenes.dart'; import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;
final _out = Platform.environment['GUIDE_RERENDER_DIR']; const _dpr = 2.625;
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
Future<void> _png(WidgetTester t, GlobalKey key, String name) async { final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key)); await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint(); final image = await boundary.toImage(pixelRatio: _dpr); try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png); final file = File(p.join(_out!, name));
      await file.parent.create(recursive: true); await file.writeAsBytes(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
void main() { TestWidgetsFlutterBinding.ensureInitialized(); setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_r7_capture.db'); });
  // WHY: the collected record covers every real step, including a moving hand frame rather than only a still arrival. This is opt-in evidence.
  for (final scene in r2Scenes) { testWidgets('R7 capture ${scene.id}', (t) async { final key = GlobalKey();
      final m = await pumpR2Scene(t, scene, brightness: Brightness.dark, captureKey: key, devicePixelRatio: _dpr); try {
        await settleMovingGuide(t); expect(m.run.currentStep?.id, scene.step); final overlay = _overlay(t);
        expect(overlay.handActive, isTrue); await _png(t, key, '${scene.guide}-${scene.step}.png'); final tip = overlay.hand.tip;
        for (var i = 0; i < 120; i++) { await t.pump(const Duration(milliseconds: 16)); if ((overlay.hand.tip - tip).distance > 8 && overlay.hand.press == 1) break; }
        expect((overlay.hand.tip - tip).distance, greaterThan(8)); await _png(t, key, '${scene.guide}-${scene.step}-motion.png');
      } finally { await disposeR2(t, m); } }, skip: _out == null || _out!.isEmpty); } }
