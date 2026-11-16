// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Round 5 captures (owner, 2026-11-15): opt-in PNGs on the REAL screens, 412x915, dpr 2.625,
// real fonts, dark, en. Set GUIDE_RERENDER_DIR to write them. Not a golden. The six round 4 shots come from guide_r4_capture_test.dart (same directory).
//
//   1a  remove-detected step 2, the first Discard scrolled under the NavBar: no outline, no label, indicator up
//   1b  alarm-schedule step 3 (Alarm page): the label sits against the Wake time outline   3   off path on Health (route back = Today): every content card dims
//   5   the step card, "Don't see it?" open, and the off-path card: Exit bottom right, accent
//   7   remove-detected completes after a real Discard.
import 'dart:io'; import 'dart:ui' as ui; import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart'; import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart'; import 'package:openstrap_edge/ui2/screens/detected_activities.dart'; import 'package:path/path.dart' as p;
import '../../test/support/bundled_fonts.dart'; import '../../test/support/guide_r2_scenes.dart' show r2OpenDb, r2Tab;
import '../../test/support/live_guide_harness.dart'; import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;
final _out = Platform.environment['GUIDE_RERENDER_DIR']; const _screen = Size(412, 915); const _dpr = 2.625;
Guide _guide(String id) => kGuideCatalogue.map((e) => e.guide).firstWhere((g) => g.id == id);
LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
// Owns the mutable review list for this capture; the page and repository share it
// so a real Discard updates the preloaded list rather than showing a fixture error.
class _ChromeRepo extends GuideFakeRepo {
  _ChromeRepo() : super(singlePending: false);
  late final _items = super.pendingActivities();
  @override Future<List<ActivitySuggestion>> pendingActivities() => _items;
  @override Future<void> discardActivity(ActivitySuggestion suggestion) async {
    (await _items).removeWhere((item) => item.id == suggestion.id);
  }
}
Future<void> _png(WidgetTester t, GlobalKey key, String name) async { final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key)); await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint(); final image = await boundary.toImage(pixelRatio: _dpr); try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png); final file = File(p.join(_out!, name));
      await file.parent.create(recursive: true); await file.writeAsBytes(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
/// The real app on [guideId]'s start tab with [page] pushed and a run inserted over it, as a
/// user arrives at a step of that page.
Future<(LiveGuideApp, GuideRun)> _onPage(WidgetTester t, String guideId, GlobalKey key, Widget Function(GuideFakeRepo) page, {Size size = _screen, GuideFakeRepo? repo}) async {
  final captureRepo = repo ?? _ChromeRepo();
  final app = await pumpLiveGuideApp(t, size: size, devicePixelRatio: _dpr, brightness: Brightness.dark, captureKey: key, repo: captureRepo);
  final guide = _guide(guideId); await t.tap(r2Tab(ShellDomain.values.byName(guide.start.name).index)); await settleLiveGuide(t);
  app.navigator.push(MaterialPageRoute<void>(builder: (_) => page(captureRepo))); await settleLiveGuide(t);
  final run = GuideRun(guide: guide, variant: (guide.variantFor(null) as GuideVariantFound).variant);
  final entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: app.navigatorKey, routes: app.runner.routes,
      onExit: run.exit, onBackToGuide: () {})); app.navigator.overlay!.insert(entry);
  addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); }); await settleLiveGuide(t, frames: 18); return (app, run); }
Future<void> _leave(WidgetTester t) async { await t.pumpWidget(const SizedBox()); await t.pump(); } void main() { TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_r5_capture.db'); }); testWidgets('capture the round 5 fixes', (t) async { {
      // 1a, then 7, on the same real review page.
      final key = GlobalKey(); final repo = _ChromeRepo(); final pending = await repo.pendingActivities();
      final (app, run) = await _onPage(t, 'remove-detected', key, (_) => DetectedActivitiesScreen(preloaded: pending), repo: repo);
      expect(run.currentStep?.id, 'discard'); await _png(t, key, '6-review-step2-discard.png');
      // 7: press the real Discard; the two-step guide completes.
      await t.tapAt(_overlay(t).targetRect!.center); await settleLiveGuide(t, frames: 24); expect(run.state, isA<GuideFinished>());
      expect(pending.map((item) => item.id), ['w1'], reason: 'Discard must remove the nap in the capture fixture');
      expect(find.text('Could not finish'), findsNothing);
      await _png(t, key, '8-7-discard-done.png'); run.exit(); await _leave(t); app.dispose(); } {
      // 1a on a short phone (the demo review is two items; a 250 px screen makes it scroll).
      final key = GlobalKey(); final repo = _ChromeRepo(); final pending = await repo.pendingActivities();
      final (app, run) = await _onPage(t, 'remove-detected', key, (_) => DetectedActivitiesScreen(preloaded: pending), size: const Size(412, 250), repo: repo);
      final list = find.byType(DetectedActivitiesScreen);
      final position = t.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first).position;
      final target = _overlay(t).targetRect!; position.jumpTo(position.pixels + target.bottom - 36); await settleLiveGuide(t, frames: 30);
      await _png(t, key, '7-1a-discard-under-navbar.png'); run.exit(); await _leave(t); app.dispose(); } {
      // 1b: the Alarm page, step 3.
      final key = GlobalKey(); final (app, run) = await _onPage(t, 'alarm-schedule', key,
          (_) => AlarmScreenView(connected: true, schedule: fillDefaultAlarmSchedule([const AlarmScheduleEntry(weekday: 1, hour: 7, minute: 30)])));
      expect(run.currentStep?.id, 'set-wake-time'); await _png(t, key, '9-1b-alarm-step3.png'); run.exit(); await _leave(t); app.dispose(); } {
      // 3 and 5: off path on Health, then the step card with "Don't see it?" open.
      final key = GlobalKey(); final app = await pumpLiveGuideApp(t, size: _screen, devicePixelRatio: _dpr, brightness: Brightness.dark, captureKey: key, repo: GuideFakeRepo());
      final started = await app.runner.start(_guide('heart-rate-zones'), band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
      await t.tap(find.byKey(GuideStepCard.dontSeeItKey)); await settleLiveGuide(t, frames: 4);
      await _png(t, key, '10-5-step-card-dont-see-it-open.png'); await t.tapAt(t.getRect(r2Tab(3)).center);
      await settleLiveGuide(t, frames: 14); expect(started.run.state, isA<GuideOffPath>());
      await _png(t, key, '11-3-5-off-path-health.png'); app.runner.exit(); await _leave(t); } expect(Directory(_out!).existsSync(), isTrue);
    // ignore: avoid_print
    print('CAPTURED ${Directory(_out!).listSync().map((e) => p.basename(e.path)).toList()..sort()}'); }, skip: _out == null || _out!.isEmpty); }
