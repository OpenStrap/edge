// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Opt-in review artifacts, not pixel goldens. Run on Boat with GUIDE_SHOTS_DIR set to an output directory. No app code or stored wearer data is changed.
import 'dart:convert'; import 'dart:io'; import 'dart:ui' as ui;
import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/manual_session.dart'; import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/day_label.dart'; import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart'; import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart'; import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show ProfileAvatar; import 'package:openstrap_edge/data/journal_fields.dart'
    show JournalFieldSpec, JournalMetricValue; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/theme.dart' show Motion; import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:path/path.dart' as p; import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../test/support/bundled_fonts.dart'; import '../../test/support/live_guide_harness.dart'; import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;
final _output = Platform.environment['GUIDE_SHOTS_DIR']; const _screen = Size(412, 915); const _dpr = 2.625;
List<Guide> get _guides => [for (final entry in kGuideCatalogue) entry.guide];
// Independent review inventory: a catalogue edit must update the capture path.
const _steps = <String, List<String>>{ 'heart-rate-zones': ['open-strain', 'open-zones', 'set-own-zones'],
  'alarm-schedule': ['open-alarm', 'pick-day', 'set-wake-time'], 'add-nap': ['open-naps', 'log-nap'],
  'remove-detected': ['open-detected', 'discard'], 'fix-sleep-times': ['change-times', 'back-to-automatic'],
  'delete-workout': ['open-history', 'delete-session'], 'start-workout': ['start-card', 'choose-activity', 'start', 'finish'],
  'log-past-workout': ['open-history', 'log-past', 'log-it'], };
// Only the hardware boundary is simulated: the real alarm screen and schedule persistence still execute. No radio or wearer device is used for review media.
class _ShotsBand extends BleEngine { _ShotsBand() : super(onRecord: (_, _) async {}, onState: (_) {}, log: (_) {}) { state.connection = 'connected'; }
  @override Future<({DateTime? armed, bool echoed})> armAlarm( DateTime when, { int index = 0, List<int>? haptics, }) async => (armed: when, echoed: true); }
// The shared fixture is read-only. This capture needs the actual sleep edit to expose step 2, so reflect the real override row instead of manually jumping
// the guide or changing its variant.
class _ShotsRepo extends GuideFakeRepo {
  _ShotsRepo({this.napDay});
  final String? napDay;
  @override Future<List<String>> availableDays() => napDay == null ? super.availableDays() : Future.value([napDay!]);
  final _writes = LocalRepositoryImpl(getProfileMap: () => {});
  @override Future<Map<String, dynamic>> getDayStress(String date) async => const {}; @override Future<Map<String, dynamic>> getDayHeart(String date) async => const {}; @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics( String date, ) async => const {}; @override Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override Future<Map<String, dynamic>> getDaySteps(String date) => _writes.getDaySteps(date); @override
  Future<List<SessionSpan>> savedSessionSpans() => _writes.savedSessionSpans(); @override Future<List<ActivitySuggestion>> pendingActivities() => _writes.pendingActivities();
  @override Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final fixture = await super.getWorkouts(range: range); return { ...fixture, 'workouts': [ for (final row in fixture['workouts'] as List)
          if (await LocalDb.session(row['id'] as String) != null) row, ], }; }
  @override Future<Map<String, dynamic>> getDayNaps(String date) async { final naps = [ for (final row in await LocalDb.napEdits(date))
        if (row['source'] == 'manual') { 'start': row['start_ts'], 'end': row['end_ts'], 'source': row['source'], 'duration_min':
                ((row['end_ts'] as int) - (row['start_ts'] as int)) ~/ 60, }, ]; return { 'naps': naps, 'nap_min': naps.fold<int>( 0,
        (sum, nap) => sum + (nap['duration_min'] as int), ), }; } @override Future<void> deleteWorkout(String id) => _writes.deleteWorkout(id);
  @override Future<Map<String, dynamic>> startWorkout(String type, {String? title}) => _writes.startWorkout(type, title: title);
  @override Future<Map<String, dynamic>> endWorkout(String workoutId) => _writes.endWorkout(workoutId);
  @override Future<Map<String, dynamic>> logManualWorkout({ required int startTs, required int endTs, required String type,
    String source = 'manual', }) => _writes.logManualWorkout( startTs: startTs, endTs: endTs, type: type, source: source, );
  @override Future<void> discardActivity(ActivitySuggestion suggestion) => _writes.discardActivity(suggestion);
  @override Future<Map<String, dynamic>> getDaySleepV2(String date) async { final night = await super.getDaySleepV2(date);
    final saved = await LocalDb.getSleepOverride(date); return saved == null ? night : { ...night, 'sleep_source': saved['source'],
            'onset_ts': saved['onset_ts'], 'wake_ts': saved['offset_ts'], }; } @override Future<Map<String, dynamic>> getDaySleep(String date) => getDaySleepV2(date); }
_ShotsRepo _repoFor(Guide guide) {
  final now = DateTime.now();
  // Yesterday makes the default 14:00–15:00 nap valid even just after midnight.
  return _ShotsRepo(napDay: guide.id == 'add-nap' ? dayLabelOf(DateTime(now.year, now.month, now.day - 1)) : null);
}
Future<void> _resetDb() => DerivationEngine.whileIdle(() async { await LocalDb.close(); final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName)); final fixture = GuideFakeRepo(); final db = await LocalDb.instance;
  for (final suggestion in await fixture.pendingActivities()) { await db.insert('activity_suggestions', { 'id': suggestion.id,
      'kind': suggestion.kind.name, 'day_id': dayLabelOf( DateTime.fromMillisecondsSinceEpoch(suggestion.startTs * 1000), ),
      'start_ts': suggestion.startTs, 'end_ts': suggestion.endTs, 'detection_start': suggestion.startTs, 'detection_end': suggestion.endTs,
      'details_json': jsonEncode(suggestion.details), 'created_at': suggestion.startTs, 'updated_at': suggestion.startTs, }); }
  final workouts = (await fixture.getWorkouts())['workouts'] as List; for (final row in workouts) { await LocalDb.putSession({
      'id': row['id'], 'type': row['type'], 'start_ts': row['start_ts'],
      'end_ts': (row['start_ts'] as int) + (row['duration_min'] as int) * 60, 'status': 'done', 'source': 'manual', 'created_at': (row['start_ts'] as int) * 1000, }); } });
List<double> _rect(Rect r) => [r.left, r.top, r.width, r.height];
Map<String, Object?> _measure(WidgetTester t, LiveGuideOverlayState overlay) { final screen = Offset.zero & _screen;
  final shapes = overlay.paintedShapes; final counts = {for (final kind in SkeletonKind.values) kind.name: 0}; var area = 0.0;
  for (final shape in shapes) { counts[shape.kind.name] = counts[shape.kind.name]! + 1; final clipped = shape.rect.intersect(screen);
    if (!clipped.isEmpty) area += clipped.width * clipped.height; } final target = overlay.targetRect!;
  final card = t.getRect(find.byKey(GuideStepCard.cardKey)); final tabs = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_TabBar', ); final tabRect = tabs.evaluate().isEmpty ? null : t.getRect(tabs); return {
    'shapeCounts': counts, 'skeletonShapeCount': shapes .where((s) => s.kind != SkeletonKind.dim) .length, 'skeletonUnitCount': shapes
        .where((s) => s.kind != SkeletonKind.dim) .map((s) => s.section) .toSet() .length, 'dimCount': counts['dim'], 'outlinePresent':
        find.byKey(LiveGuideOverlay.outlineKey).evaluate().length == 1, 'handPresent': find.byKey(LiveGuideOverlay.handKey).evaluate().length == 1, 'coverageFraction': area / (screen.width * screen.height),
    'targetRect': _rect(target), 'cardRect': _rect(card), 'tabBarRect': tabRect == null ? null : _rect(tabRect),
    'cardOverlapsTarget': card.overlaps(target), 'cardOverlapsTabBar': tabRect != null && card.overlaps(tabRect),
    'shapesOverlappingTabBar': tabRect == null ? 0 : shapes.where((s) => s.rect.overlaps(tabRect)).length, 'shapes': [
      for (final s in shapes) {'kind': s.kind.name, 'rect': _rect(s.rect), 'section': s.section}, ], }; }
Finder _pointingAid(WidgetTester t) => find.byKey(Motion.enabled(t.element(find.byType(LiveGuideOverlay))) ? LiveGuideOverlay.handKey : LiveGuideOverlay.outlineKey);
Future<void> _png( WidgetTester t, RenderRepaintBoundary boundary, String path, { double pixelRatio = _dpr, }) async {
  // Let the framework rebuild and composite post-frame guide updates without advancing the capture clock.
  await t.pump();
  expect(boundary.size, _screen, reason: 'capture the whole phone viewport'); await t.runAsync(() async {
    // A guide plan can dirty the boundary after painting. Capture the completed frame's layer rather than forcing a partial pipeline outside a frame.
    final image = await (boundary.debugLayer! as OffsetLayer).toImage(Offset.zero & boundary.size, pixelRatio: pixelRatio); try {
      expect(image.width, (_screen.width * pixelRatio).ceil()); expect(image.height, (_screen.height * pixelRatio).ceil());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png); final file = File(path);
      await file.parent.create(recursive: true); await file.writeAsBytes(bytes!.buffer.asUint8List()); } finally { image.dispose(); } }); }
// Capture real test-time frames rather than manufacturing a slideshow from the settled stills. Pointer actions, dialogs and navigation share this clock.
class _PathFrames { final WidgetTester tester; final GlobalKey captureKey; final String directory; final bool enabled;
  final records = <Map<String, Object?>>[]; final actions = <Map<String, Object?>>[]; int elapsedMs = 0; _PathFrames(this.tester, this.captureKey, this.directory, this.enabled);
  Future<void> capture(String phase) async { if (!enabled) { return; } final path = 'frames/${records.length.toString().padLeft(5, '0')}.png'; await _png( tester,
      tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)), p.join(directory, path), pixelRatio: 1, );
    records.add({'path': path, 'timeMs': elapsedMs, 'phase': phase}); }
  Future<void> frames(String phase, {int count = 18}) async { for (var i = 0; i < count; i++) { await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)), ); await tester.pump(const Duration(milliseconds: 100));
      elapsedMs += 100; await capture(phase); expect(tester.takeException(), isNull, reason: phase); } }
  Future<void> tap(Offset point, String action) async { actions.add({ 'timeMs': elapsedMs, 'action': action, 'point': [point.dx, point.dy], }); await tester.tapAt(point);
    // Do not advance the clock here: the next 100 ms sample includes the route transition's first frame, rather than silently settling past it.
  } Future<void> acceptTime(String phase) async { expect(find.byType(TimePickerDialog), findsOneWidget, reason: phase);
    final dialog = find.byType(TimePickerDialog); final context = tester.element(dialog); final ok = find.descendant( of: dialog,
      matching: find.text(MaterialLocalizations.of(context).okButtonLabel), ); expect(ok, findsOneWidget); await tap(tester.getCenter(ok), phase); await frames(phase); } }
Future<void> _advance( WidgetTester t, LiveGuideApp app, Guide guide, GuideStep step, Rect target, _PathFrames path, ) async {
  await path.tap(target.center, '${step.id}: target'); await path.frames('${step.id}: after target');
  if (guide.id == 'heart-rate-zones' && step.id == 'set-own-zones') { expect(find.byType(BottomSheet), findsOneWidget);
    await path.frames('set-own-zones: edit sheet'); await path.tap(const Offset(4, 8), 'set-own-zones: dismiss editor barrier');
    await path.frames('set-own-zones: return to Done'); } if (guide.id == 'start-workout' && step.id == 'choose-activity') {
    final search = find.descendant( of: find.byType(ActivityPicker), matching: find.byType(TextField), ); expect(search, findsOneWidget);
    await t.enterText(search, 'Running'); path.actions.add({ 'timeMs': path.elapsedMs, 'action': 'enter Running in search', });
    await path.frames('choose-activity: search results'); final row = find.byType(ActivityRow).first; expect( row, findsOneWidget,
      reason: 'real search result before pointer selection', ); await path.tap(t.getRect(row).center, 'choose-activity: Running row');
    await path.frames('choose-activity: navigate to setup'); } if (guide.id == 'fix-sleep-times' && step.id == 'change-times') {
    await path.acceptTime('change-times: accept bed time'); await path.acceptTime('change-times: accept wake time');
    await path.frames('change-times: apply'); } if (guide.id == 'add-nap' && step.id == 'log-nap') {
    await path.acceptTime('log-nap: accept fell-asleep time'); await path.acceptTime('log-nap: accept wake time');
    final day = (await app.state.repo!.availableDays()).single;
    final rows = await t.runAsync(() => LocalDb.napEdits(day));
    expect(rows!.where((row) => row['source'] == 'manual'), hasLength(1), reason: 'real nap saved before recording completion');
    await path.frames('log-nap: recompute and publish', count: 40); } if (guide.id == 'alarm-schedule' && step.id == 'set-wake-time') {
    await path.acceptTime('set-wake-time: accept time'); } if (guide.id == 'delete-workout' && step.id == 'delete-session') {
    final remove = find.descendant( of: find.byType(BottomSheet), matching: find.text('Remove'), ); expect(remove, findsOneWidget);
    await path.tap(t.getCenter(remove), 'delete-session: confirm removal'); await path.frames('delete-session: removed'); } if (guide.id == 'fix-sleep-times') {
    // The isolate and SQLite futures use real time. Record both saves through completion, including Back to automatic, before another theme may reset the database.
    for (var i = 0; i < 500 && app.state.reanalyzing; i++) { await path.frames('${step.id}: waiting for recompute/publish', count: 1); }
    expect( app.state.reanalyzing, isFalse, reason: '${step.id} worker completed before DB reset', ); await path.frames('${step.id}: saved state', count: 4); } }
Future<Map<String, Object?>> _offPath( WidgetTester t, Guide guide, GuideRun run, GlobalKey captureKey, String directory, ) async {
  final l = lookupAppLocalizations(const Locale('en')); final dimControl = switch (guide.id) {
    'heart-rate-zones' || 'remove-detected' => find.byType(ProfileAvatar), 'fix-sleep-times' => find.text(l.sleepDetailEditNaps), _ => null, };
  // Navigation-target steps make every other card a pointer-blocking skeleton. Other first-step dim controls either stay on the same page or are accepted
  // shortcuts within the guide. Capture their real off-path state via a tab, and record this evidence limitation instead of changing production paint.
  final controlFinder = dimControl ?? find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tab').at(0);
  expect(controlFinder, findsOneWidget); expect(run.currentStep?.id, _steps[guide.id]!.first); final control = t.getRect(controlFinder);
  final before = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); final coveringKinds = before.paintedShapes
      .where((s) => s.rect.overlaps(control)) .map((s) => s.kind.name) .toSet() .toList(); if (dimControl != null) { expect( coveringKinds,
      contains('dim'), reason: 'real dim-painted departure control', ); } await t.tapAt(control.center);
  await settleLiveGuide(t, frames: 18); expect(run.state, isA<GuideOffPath>());
  expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget); expect(find.text("You've left the path"), findsOneWidget); expect(
    _pointingAid(t), findsOneWidget, reason: 'off-path capture must include the pointing aid for the route back', );
  final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
  final route = find.byKey(LiveGuideOverlay.routeProxyKey); expect(route, findsOneWidget);
  final routeRect = t.getRect(route); final card = t.getRect(find.byKey(GuideStepCard.cardKey)); await _png(
    t, t.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)), p.join(directory, 'offpath-light.png'), ); return {
    'file': 'offpath-light.png', 'departedStep': _steps[guide.id]!.first, 'tapRect': _rect(control), 'controlShapeKinds': coveringKinds,
    'departureControl': dimControl != null ? 'dim-painted control' : 'bright Today tab', 'departureLimitation': dimControl == null
        ? 'No dim-painted navigational control outside the guide is available on step 1; skeleton controls block pointer input. Used the real bright Today tab.'
        : null, 'routeTargetRect': _rect(routeRect), 'cardRect': _rect(card), 'cardOverlapsRoute': card.overlaps(routeRect),
    'shapeKinds': overlay.paintedShapes .map((s) => s.kind.name) .toSet() .toList(), }; }
void main() { TestWidgetsFlutterBinding.ensureInitialized(); final enabled = _output?.isNotEmpty ?? false; setUpAll(() async {
    if (!enabled) return; expect( _guides.map((g) => g.id), unorderedEquals(_steps.keys), reason: 'all eight review paths must match the shipped catalogue', );
    await loadFonts(); // Manrope and Barlow Condensed, including bundled weights.
    await skLoadAppFonts(); // Package-scoped Lucide and SDK MaterialIcons too.
    sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; LocalDb.dbName = 'guide_activity_shots_test.db'; await _resetDb(); });
  tearDownAll(() async { if (enabled) await LocalDb.close(); }); for (final guide in _guides) {
    // why: the owner needs every live step in both themes to assess what the skeleton hides. A missing/incorrect step fails before capture.
    // proves: CLAIM(overlay-pass-through), CLAIM(overlay-reveal).
    testWidgets( 'capture every live catalogue step: ${guide.id}', (t) async {
        // Widget tests replace blurred shadows with hard outlines by default. Review media uses the app's actual elevation shadows.
        final previousShadows = debugDisableShadows; debugDisableShadows = false; try {
          final l = lookupAppLocalizations(const Locale('en')); final records = <Map<String, Object?>>[];
          final directory = p.join(_output!, guide.id); final manifest = File(p.join(directory, 'manifest.json'));
          await t.runAsync(() async { final old = Directory(directory); if (await old.exists()) await old.delete(recursive: true); });
          final manifestData = <String, Object?>{ 'guideId': guide.id, 'title': guide.title.of(l), 'locale': 'en',
            'logicalSize': [_screen.width, _screen.height], 'devicePixelRatio': _dpr, 'coverageDefinition':
                'Sum of clipped shape rectangle areas / screen area; overlaps counted repeatedly, not union coverage.', 'driverNotes': [
              'Every advance uses real pointer taps; search text uses enterText.', 'Real blurred elevation shadows are enabled; settled stills wait for page-loading spinners.',
              'Alarm hardware is a connected BleEngine fixture that echoes armAlarm; real schedule writes and UI execute.',
              'Sleep fixture reads the real override row after the time-picker save.',
              'Display metrics are fixtures; edits and workout actions use the isolated test database.', ], 'steps': records, };
          for (final brightness in [Brightness.light, Brightness.dark]) { await t.runAsync(_resetDb); final captureKey = GlobalKey();
            final app = await pumpLiveGuideApp( t, size: _screen, devicePixelRatio: _dpr, brightness: brightness, captureKey: captureKey,
              repo: _repoFor(guide), engine: guide.id == 'alarm-schedule' ? _ShotsBand() : null, ); final dark = brightness == Brightness.dark;
            final path = _PathFrames(t, captureKey, directory, !dark); if (!dark) { manifestData['sequence'] = { 'frameIntervalMs': 100,
                'frameSize': [412, 915], 'gifPath': '../gifs/${guide.id}.gif', 'frames': path.records, 'actions': path.actions, }; }
            final started = await app.runner.start(guide, band: null); expect(started, isA<GuideStarted>());
            final run = (started as GuideStarted).run; expect( run.variant.steps.map((s) => s.id), orderedEquals(_steps[guide.id]!), );
            for (var i = 0; i < run.variant.steps.length; i++) { await path.frames('${run.variant.steps[i].id}: reveal');
              // Real SQLite futures can finish after the nominal reveal budget, especially on the dark pass which does not encode sequence PNGs.
              // Keep sampling until the actual pointing aid and reveal are ready.
              for (var wait = 0; wait < 100; wait++) { final overlays = find.byType(LiveGuideOverlay);
                final overlay = t.state<LiveGuideOverlayState>(overlays); if (run.currentStep?.id == run.variant.steps[i].id &&
                    !overlay.isYielding && overlay.revealProgress == 1 && _pointingAid(t).evaluate()
                        .isNotEmpty && find.byType(CircularProgressIndicator).evaluate().isEmpty) { break; } await path.frames(
                  '${run.variant.steps[i].id}: awaiting visible target', count: 1, ); } await path.frames(
                '${run.variant.steps[i].id}: settle page layout', count: 18, ); expect(run.state, isA<GuideAtStep>()); expect(
                (run.state as GuideAtStep).index, i, reason: 'no skipped or off-path steps', ); final step = run.variant.steps[i];
              final overlay = t.state<LiveGuideOverlayState>( find.byType(LiveGuideOverlay), ); expect(overlay.isYielding, isFalse);
              expect(overlay.revealProgress, 1); expect(overlay.targetRect, isNotNull); expect( find.byType(CircularProgressIndicator),
                findsNothing, reason: 'settled review still must not capture a loading page', );
              expect(_pointingAid(t), findsOneWidget); expect(t.takeException(), isNull);
              final name = '${(i + 1).toString().padLeft(2, '0')}-${step.id}'; final guided = '$name-${dark ? 'dark' : 'light'}.png';
              final measured = _measure(t, overlay); await _png( t, t.renderObject<RenderRepaintBoundary>(find.byKey(captureKey)),
                p.join(directory, guided), ); if (!dark) { records.add({ 'id': step.id, 'number': i + 1,
                  'text': step.caption.of(l).replaceAll('**', ''), 'pngPaths': {'guided': guided, 'dark': '$name-dark.png'}, ...measured,
                }); } else { records[i]['dark'] = measured; } await t.runAsync(() async { await manifest.parent.create(recursive: true);
                await manifest.writeAsString( const JsonEncoder.withIndent('  ').convert(manifestData), ); });
              await _advance(t, app, guide, step, overlay.targetRect!, path); if (i == run.variant.steps.length - 1) {
                await path.frames('Done card', count: 20); expect(find.byKey(GuideStepCard.doneKey), findsOneWidget); expect( run.state,
                  isA<GuideFinished>(), reason: 'last expected target tap completes the run', ); } } await t.runAsync(
              () => manifest.writeAsString( const JsonEncoder.withIndent('  ').convert(manifestData), ), ); app.runner.exit();
            await t.pumpWidget(const SizedBox()); await t.pump(); app.dispose();
            // A publish already in its warm timeout may finish after disposal.
            await settleLiveGuide(t, frames: 30); expect(t.takeException(), isNull); }
          // A fresh app keeps completed workout/sleep edits from changing step 1 and leaves the uninterrupted light GIF timeline intact.
          await t.runAsync(_resetDb); final offPathKey = GlobalKey(); final offPathApp = await pumpLiveGuideApp( t, size: _screen,
            devicePixelRatio: _dpr, captureKey: offPathKey, repo: _repoFor(guide), engine: guide.id == 'alarm-schedule' ? _ShotsBand() : null,
          ); final offPathStart = await offPathApp.runner.start(guide, band: null) as GuideStarted; await settleLiveGuide(t, frames: 18);
          expect(offPathStart.run.currentStep?.id, _steps[guide.id]!.first); manifestData['offPath'] = await _offPath( t, guide,
            offPathStart.run, offPathKey, directory, ); await t.runAsync( () => manifest.writeAsString(
              const JsonEncoder.withIndent('  ').convert(manifestData), ), ); offPathApp.runner.exit();
          await t.pumpWidget(const SizedBox()); offPathApp.dispose(); await settleLiveGuide(t, frames: 30);
          expect(t.takeException(), isNull); } finally { debugDisableShadows = previousShadows; } }, skip: !enabled, timeout: const Timeout(Duration(minutes: 12)), ); } }
