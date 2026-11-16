// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Round 4 captures (owner, 2026-11-14): opt-in PNGs of the new markers on the REAL screens,
// 412x915, dpr 2.625, real fonts, dark, en. Set GUIDE_RERENDER_DIR to write them. Not a golden.
//
//   heart-rate-zones  step 1 (Home Strain ring): a moving-hand frame   heart-rate-zones  step 2 (Day strain): a frame mid-auto-scroll with the scroll indicator,
//                     then the settled step   log-past-workout  step 1 (History sub-tab): a moving-hand frame
//   log-past-workout  step 2 (History, scroll step): settled; and on a short phone (412x560),
//                     where the target starts below the fold: mid-auto-scroll with the indicator, then settled
import 'dart:io'; import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:path/path.dart' as p;
import '../../test/support/bundled_fonts.dart'; import '../../test/support/guide_r2_scenes.dart' show r2OpenDb;
import '../../test/support/live_guide_harness.dart'; import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;
import '../../test/ui2/guide_phone_feedback_test.dart' show DeviceLikeRepo;
final _out = Platform.environment['GUIDE_RERENDER_DIR']; const _screen = Size(412, 915); const _dpr = 2.625;
Guide _guide(String id) => kGuideCatalogue.map((e) => e.guide).firstWhere((g) => g.id == id);
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
Future<void> _png(WidgetTester t, GlobalKey key, String name) async { final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key)); await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint(); final image = await boundary.toImage(pixelRatio: _dpr); try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png); final file = File(p.join(_out!, name));
      await file.parent.create(recursive: true); await file.writeAsBytes(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
/// Stop on a moving-hand frame away from arrival, between presses.
Future<void> _toMovingFrame(WidgetTester t) async {
  final overlay = _overlay(t);
  expect(find.byKey(LiveGuideOverlay.handKey), findsOneWidget);
  expect(overlay.handActive, isTrue);
  final tip = overlay.hand.tip;
  for (var i = 0; i < 200; i++) {
    await t.pump(const Duration(milliseconds: 16));
    if ((overlay.hand.tip - tip).distance > 8 && overlay.hand.press == 1) return;
  }
  fail('Moving hand never reached a frame away from arrival');
}
/// Frames until the scroll indicator is up and the target has moved well along the glide.
/// False when the step arrived with its target already in view (nothing to scroll).
Future<bool> _toMidScroll(WidgetTester t) async { var seen = 0; for (var i = 0; i < 40; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5))); await t.pump(const Duration(milliseconds: 20));
    final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey).evaluate().isNotEmpty;
    if (marker && ++seen >= 9) return true; // a few frames into the glide, still out of view
  } return false; } Future<LiveGuideApp> _start(WidgetTester t, String id, GlobalKey key, {Size size = _screen}) async { final app = await pumpLiveGuideApp(t,
      size: size, devicePixelRatio: _dpr, brightness: Brightness.dark, captureKey: key, repo: DeviceLikeRepo());
  expect(await app.runner.start(_guide(id), band: null), isA<GuideStarted>()); await settleLiveGuide(t, frames: 14); return app; }
void main() { TestWidgetsFlutterBinding.ensureInitialized(); setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_r4_capture.db'); });
  testWidgets('capture the round 4 markers', (t) async { { final key = GlobalKey(); final app = await _start(t, 'heart-rate-zones', key);
      await _toMovingFrame(t); await _png(t, key, '1-hrz-step1-tap-hand-at-peak.png'); await t.tapAt(_overlay(t).targetRect!.center);
      if (await _toMidScroll(t)) await _png(t, key, '2a-hrz-step2-mid-auto-scroll-indicator.png'); await settleLiveGuide(t, frames: 16);
      await _png(t, key, '2b-hrz-step2-settled.png'); app.runner.exit(); await t.pumpWidget(const SizedBox()); await t.pump(); } {
      final key = GlobalKey(); await _start(t, 'log-past-workout', key); await _toMovingFrame(t);
      await _png(t, key, '3-lpw-step1-tap-hand-at-peak.png'); await t.tapAt(_overlay(t).targetRect!.center);
      final scrolled = await _toMidScroll(t); if (scrolled) await _png(t, key, '4a-lpw-step2-mid-auto-scroll-indicator.png');
      await settleLiveGuide(t, frames: 16); await _png(t, key, '4b-lpw-step2-settled.png'); } {
      // A short phone: the History list's last card starts below the fold, so the guide has to scroll to it (the 915 px screens above show it at once).
      final key = GlobalKey(); await _start(t, 'log-past-workout', key, size: const Size(412, 560)); await t.tapAt(_overlay(t).targetRect!.center);
      if (await _toMidScroll(t)) await _png(t, key, '5a-lpw-step2-short-screen-mid-auto-scroll-indicator.png');
      await settleLiveGuide(t, frames: 16); await _png(t, key, '5b-lpw-step2-short-screen-settled.png'); } expect(Directory(_out!).existsSync(), isTrue);
    // ignore: avoid_print
    print('CAPTURED ${Directory(_out!).listSync().map((e) => p.basename(e.path)).toList()..sort()}'); }, skip: _out == null || _out!.isEmpty); }
