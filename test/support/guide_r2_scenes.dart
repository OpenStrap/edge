// Real shell + real page fixtures for the cross-cutting r2 guard. The scene table is independent of the guide definitions; coverage is checked exactly.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart'; import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart'; import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/live.dart'; import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/activity/setup.dart'; import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart'; import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart'; import 'package:openstrap_edge/ui2/screens/naps.dart';
import 'package:path/path.dart' as p; import 'package:sqflite_common_ffi/sqflite_ffi.dart'; import 'live_guide_harness.dart';
const r2Size = Size(412, 915); final r2Locale = lookupAppLocalizations(const Locale('en')); Guide r2Guide(String id) => kGuideCatalogue.firstWhere((e) => e.guide.id == id).guide;
Finder r2Tabs({bool hidden = false}) => find.byWidgetPredicate( (w) => w.runtimeType.toString() == '_TabBar', skipOffstage: !hidden);
Finder r2Tab(int index, {bool hidden = false}) => find.descendant( of: r2Tabs(hidden: hidden), matching: find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_Tab', skipOffstage: !hidden), skipOffstage: !hidden).at(index);
class R2Scene { final String guide, step; final Widget Function()? page; final bool history, staged, manual;
  const R2Scene(this.guide, this.step, {this.page, this.history = false, this.staged = false, this.manual = false});
  String get id => '$guide/$step'; bool get shell => page == null; } final r2Scenes = <R2Scene>[ const R2Scene('heart-rate-zones', 'open-strain'),
  R2Scene('heart-rate-zones', 'open-zones', page: () => const DayStrainDetail()),
  R2Scene('heart-rate-zones', 'set-own-zones', page: () => const ZonesDetail()), const R2Scene('alarm-schedule', 'open-alarm'),
  R2Scene('alarm-schedule', 'pick-day', page: () => AlarmScreenView( connected: true, schedule: fillDefaultAlarmSchedule(const []))),
  R2Scene('alarm-schedule', 'set-wake-time', page: () => AlarmScreenView( connected: true, schedule: fillDefaultAlarmSchedule([
      const AlarmScheduleEntry(weekday: 1, hour: 7, minute: 30)]))), const R2Scene('add-nap', 'open-naps'),
  R2Scene('add-nap', 'log-nap', page: () => const NapsScreen()), const R2Scene('remove-detected', 'open-detected'),
  R2Scene('remove-detected', 'discard', page: () => const DetectedActivitiesScreen()), const R2Scene('fix-sleep-times', 'change-times'),
  const R2Scene('fix-sleep-times', 'back-to-automatic', manual: true), const R2Scene('delete-workout', 'open-history'),
  const R2Scene('delete-workout', 'delete-session', history: true), const R2Scene('start-workout', 'start-card'),
  R2Scene('start-workout', 'choose-activity', page: () => const ActivityPicker(weightKg: 70)),
  R2Scene('start-workout', 'start', page: () => ActivitySetup(quickStart.first, weightKg: 70)),
  R2Scene('start-workout', 'finish', page: () => liveFor(quickStart.first, weightKg: 70)),
  const R2Scene('log-past-workout', 'open-history'), const R2Scene('log-past-workout', 'log-past', history: true),
  R2Scene('log-past-workout', 'log-it', page: () => const LogWorkout()), ];
Future<void> r2OpenDb(String name) async { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; await LocalDb.close();
  LocalDb.dbName = name; await databaseFactory.deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name)); }
class R2Mounted { final LiveGuideApp app; final GuideRun run; final OverlayEntry? entry; final TargetResolution? initialTarget;
  R2Mounted(this.app, this.run, this.entry, {this.initialTarget}); void removeOverlay() { if (entry == null) { app.runner.exit(); }
    else if (entry!.mounted) { entry!.remove(); } } }
// Shell scenes use the shipped runner; pushed scenes install the actual overlay/run after page preparation under the real shell. Staging Discard
// prepares a fixture; the dedicated pointer tests prove input pass-through.
Future<R2Mounted> pumpR2Scene(WidgetTester t, R2Scene scene, {Size size = r2Size, Brightness brightness = Brightness.light,
  bool singlePending = true, GuideFakeRepo? repo, GlobalKey? captureKey, double devicePixelRatio = 1}) async {
  final guide = r2Guide(scene.guide); repo ??= GuideFakeRepo(sleepSource: scene.manual ? 'manual' : 'auto', singlePending: singlePending);
  final app = await pumpLiveGuideApp(t, size: size, repo: repo, brightness: brightness, captureKey: captureKey, devicePixelRatio: devicePixelRatio); if (scene.shell) {
    // Use the shipped runner here: tab-navigation signals may be owned by GuideRunner. A separately inserted run would bypass that real seam.
    final started = await app.runner.start(guide, band: null); expect(started, isA<GuideStarted>());
    final run = (started as GuideStarted).run;
    // Undo scenes represent a run that has already opened the time editor.
    // Starting fresh on an existing manual night is covered separately.
    if (scene.manual) run.targetTapped();
    if (scene.history) { await settleLiveGuide(t, frames: 12);
      await t.tap(find.text(r2Locale.workoutTabHistory)); } final mounted = R2Mounted(app, run, null);
    addTearDown(() { mounted.removeOverlay(); run.dispose(); }); return mounted; }
  final index = [GuideStart.today, GuideStart.sleep, GuideStart.activity, GuideStart.health, GuideStart.settings].indexOf(guide.start);
  await t.tap(r2Tab(index)); await settleLiveGuide(t); if (scene.page != null) {
    // Pin the review's pending data at entry: unrelated remembered moment follow-ups must not select another day in this activity-only fixture.
    final page = scene.guide == 'remove-detected' ? DetectedActivitiesScreen(preloaded: await repo.pendingActivities()) : scene.page!();
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => page)); await settleLiveGuide(t); }
  final run = GuideRun(guide: guide, variant: (guide.variantFor(null) as GuideVariantFound).variant);
  final entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: app.navigatorKey, routes: app.runner.routes,
    onExit: run.exit, onBackToGuide: () => app.navigator.maybePop())); app.navigator.overlay!.insert(entry);
  final initial = run.variant.steps.firstWhere((s) => s.id == scene.step).target .resolve(app.runner.routes.page!, r2Locale);
  final mounted = R2Mounted(app, run, entry, initialTarget: initial); addTearDown(() { mounted.removeOverlay(); run.dispose(); }); return mounted; }
Future<void> disposeR2(WidgetTester t, R2Mounted mounted) async { mounted.removeOverlay(); await t.pumpWidget(const SizedBox()); mounted.app.dispose(); await t.pump(); }
