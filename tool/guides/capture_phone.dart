// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Phone feedback round (owner, 2026-11-14, APK 09bc0763): the dim and the placeholders on the owner's three pages, on the REAL screens with device-like
// data (a drawn Day strain curve, not the fixture's trace-less day).
//
// Also an opt-in screenshot capture (GUIDE_RERENDER_DIR): 412x915, dpr 2.625, real fonts, dark, en. Not a golden.
import 'dart:io'; import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Section, Surface; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:path/path.dart' as p;
import '../../test/support/bundled_fonts.dart'; import '../../test/support/guide_r2_scenes.dart' show r2OpenDb;
import '../../test/support/live_guide_harness.dart'; import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;
final _out = Platform.environment['GUIDE_RERENDER_DIR']; const _screen = Size(412, 915); const _dpr = 2.625;
/// A day with a drawn strain curve, like the phone's (the shared fixture has none).
class DeviceLikeRepo extends GuideFakeRepo { @override Future<Map<String, dynamic>> getDayStrain(String date) async {
    final n = DateTime.now(); final start = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch ~/ 1000; return {
      ...await super.getDayStrain(date), 'strain': 3.2, 'hr': {'max': 141}, 'curve': [
        for (var m = 0; m < 305; m++) {'t': start + m * 60, 'v': 3.3 * (1 - 1 / (1 + m / 20))}, ], }; }
  @override Future<Map<String, dynamic>> getDayWear(String date) async => const {'worn_min': 304, 'coverage_pct': 94}; }
Guide _guide(String id) => kGuideCatalogue.map((e) => e.guide).firstWhere((g) => g.id == id);
Future<LiveGuideApp> _start(WidgetTester t, String id, GlobalKey key) async { final app = await pumpLiveGuideApp(t,
      size: _screen, devicePixelRatio: _dpr, brightness: Brightness.dark, captureKey: key, repo: DeviceLikeRepo());
  final started = await app.runner.start(_guide(id), band: null); expect(started, isA<GuideStarted>()); await settleLiveGuide(t, frames: 14); return app; }
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
Future<void> _png(WidgetTester t, GlobalKey key, String name) async { final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key)); await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint(); final image = await boundary.toImage(pixelRatio: _dpr); try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png); final file = File(p.join(_out!, name));
      await file.parent.create(recursive: true); await file.writeAsBytes(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
/// The shapes covering [at] (a point in screen coordinates).
void _dump(WidgetTester t, String tag) { final o = _overlay(t); final buf = StringBuffer('DUMP $tag\n'); for (final s in o.paintedShapes) {
    buf.writeln('  shape ${s.kind.name} sec=${s.section} ${s.rect}'); }
  for (final e in find.byType(Surface).evaluate().followedBy(find.byType(Section).evaluate())) { final b = e.renderObject;
    if (b is RenderBox && b.hasSize) { final r = MatrixUtils.transformRect(b.getTransformTo(null), Offset.zero & b.size); buf.writeln('  comp ${e.widget.runtimeType} $r'); } }
  // ignore: avoid_print
  print(buf); } void main() { setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_phone_capture.db'); });
  testWidgets('capture the four owner pages', (t) async { final dir = _out!; { final key = GlobalKey();
      final app = await _start(t, 'heart-rate-zones', key); _dump(t, 'hrz1'); await _png(t, key, '1-hrz-step1-home-strain.png');
      await t.tapAt(_overlay(t).targetRect!.center); await settleLiveGuide(t, frames: 14); _dump(t, 'hrz2');
      await _png(t, key, '2-hrz-step2-day-strain.png'); app.runner.exit(); await t.pumpWidget(const SizedBox()); await t.pump(); } {
      final key = GlobalKey(); final app = await _start(t, 'fix-sleep-times', key); _dump(t, 'sleep1');
      await _png(t, key, '3-fix-sleep-times-step1-sleep.png'); app.runner.exit(); await t.pumpWidget(const SizedBox()); await t.pump(); } {
      final key = GlobalKey(); await _start(t, 'log-past-workout', key); _dump(t, 'history1');
      await _png(t, key, '4-log-past-workout-step1-activity-history.png'); } expect(Directory(dir).existsSync(), isTrue); }, skip: _out == null || _out!.isEmpty); }
