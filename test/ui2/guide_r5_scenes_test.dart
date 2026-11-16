// Guides round 5 (owner, 2026-11-15, APK 4ccf169d): design checks over EVERY page the guides
// push or visit (test/support/guide_r2_scenes.dart: the real shell plus each real page, on the fake repository), one check per rule, not per symptom.
//
// Spec: edge.research/guides/spec-r2-dim-and-card.md, "Round 5" items 3, 4 and 7.   4. the app bar's back arrow is never a placeholder and always takes taps;
//      chrome is never dimmed on a step (P4: the owner's shot 1 shows a dim title and arrow);
//   7. on a step, the previous and the next step's targets are never placeholders: they stay      real controls (dim at most) and take taps.
//   3. off path with a chrome route back (a tab), every content unit dims, the route's      neighbouring card too.
import 'package:flutter/material.dart'; import 'package:flutter/rendering.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart'; import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;
import 'package:openstrap_edge/ui2/grammar.dart' show NavBar, Pressable;
import 'package:openstrap_edge/ui2/screens/detected_activities.dart'; import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_content.dart' show PressableRows; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart' show GuideOffPath, GuideRun;
import 'package:openstrap_edge/ui2/guides/guide_runner.dart'; import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/guides/tree_geometry.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart' show isGuideControl;
import '../support/guide_r2_manifest.dart'; import '../support/guide_r2_scenes.dart'; import '../support/live_guide_harness.dart';
/// The pushed-page scenes: the ones with an app bar and so a back arrow to check.
///
/// The live workout screen has no app bar at all (a running session has no back arrow: the user ends it),
/// so it has nothing to check here.
const _noAppBar = {'start-workout/finish'}; final _pageScenes = [for (final s in r2Scenes) if (s.page != null && !_noAppBar.contains(s.id)) s];
Element? _backArrow(Element page) { for (final bar in onstageElements(page)) { if (bar.widget is! NavBar) continue;
    for (final c in onstageElements(bar)) { if (c.widget is Pressable && laidOutBox(c) != null) return c; } } return null; }
/// Whether a tap at [box]'s centre reaches [box] (nothing on top absorbs it).
bool _takesTaps(WidgetTester t, RenderBox box) { final at = box.localToGlobal(box.size.center(Offset.zero)); final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, at, t.view.viewId); return result.path.any((entry) => identical(entry.target, box)); }
/// null when the component stays as it is, or no plan is in force (nothing is covered then).
GuideUnitLook? _look(Element e) => GuideDimScope.controllerOf(e)?.looks?.lookOf(e); void main() { setUpAll(() => r2OpenDb('guide_r5_scenes.db')); tearDownAll(LocalDb.close);
  group('R5-4 the app bar back arrow', () { for (final scene in _pageScenes) {
      // WHY: spec Round 5 item 4. The owner hit a pushed page whose top-left back arrow was a
      // placeholder and could not be pressed. Whatever the page, its app bar's leading control is chrome: never a placeholder, and the overlay's ink never absorbs a tap on it.
      // CLAIM(back-arrow-always-usable).
      // catches: a back control the chrome finder misses (so the plan covers it), an app bar built
      // after the plan, a skeleton unit laid over the bar.
      testWidgets('R5-4a ${scene.id}: the back arrow is no placeholder and takes taps', (t) async {
        final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18);
          final page = m.app.runner.routes.page!; final back = _backArrow(page); expect(back, isNotNull, reason: '${scene.id}: the page has an app bar with a back arrow (NavBar)');
          expect(_look(back!), isNot(GuideUnitLook.skeleton), reason: '${scene.id}: the back arrow is a placeholder');
          expect(_takesTaps(t, laidOutBox(back)!), isTrue, reason: '${scene.id}: a tap on the back arrow is absorbed by the guide'); } finally { await disposeR2(t, m); } });
      // WHY: P4 (chrome is never dimmed on a step) and the owner's shot 1, where the app bar's title and arrow are visibly dimmer than on the Alarm page.
      // catches: chrome the plan does not know (unseen components fall back to the dim look).
      testWidgets('R5-4b ${scene.id}: the app bar is neither dimmed nor a placeholder', (t) async {
        final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18);
          final page = m.app.runner.routes.page!; final bar = onstageElements(page).firstWhere((e) => e.widget is NavBar);
          final looks = <String>[]; for (final e in [bar, ...onstageElements(bar)]) {
            if (isGuideControl(e.widget) || e.widget.runtimeType.toString() == 'Surface') { final look = _look(e);
              if (look != null) looks.add('${e.widget.runtimeType}: $look'); } } for (final e in onstageElements(bar)) {
            final ro = e is RenderObjectElement ? e.renderObject : null; final all = GuideDimScope.controllerOf(e)!.looks;
            if (ro is RenderParagraph && all is GuideLooseLooks) { final look = all.looseLookOf(ro); if (look != null) looks.add('text "${ro.text.toPlainText()}": $look'); } }
          expect(looks, isEmpty, reason: '${scene.id}: the app bar is chrome and must be lit'); } finally { await disposeR2(t, m); } }); } });
  group('R5-4 while the page arrives', () {
    // WHY: spec Round 5 item 4, over TIME. The owner's back arrow was a placeholder on a real device while a
    // page was loading and rebuilding (the review page re-keys its NavBar when the review opens). Components
    // the plan has not seen yet fall back to the dim or placeholder look, so a NavBar built after the last plan
    // is covered until the next one. At NO frame from the push on may the back arrow be a placeholder or absorb a tap. CLAIM(back-arrow-always-usable).
    // catches: GuidePlan._unseen treating chrome like content.
    for (final scene in _pageScenes) { testWidgets('R5-4c ${scene.id}: the back arrow is usable in every frame of the page\'s arrival', (t) async {
        final repo = GuideFakeRepo(singlePending: false); final app = await pumpLiveGuideApp(t, size: r2Size, repo: repo); final guide = r2Guide(scene.guide);
        final run = GuideRun(guide: guide, variant: (guide.variantFor(null) as GuideVariantFound).variant); try {
          await t.tap(r2Tab(ShellDomain.values.byName(guide.start.name).index)); await settleLiveGuide(t); final entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run,
            navigatorKey: app.navigatorKey, routes: app.runner.routes, onExit: run.exit, onBackToGuide: () {}));
          app.navigator.overlay!.insert(entry); addTearDown(() { if (entry.mounted) entry.remove(); }); await t.pump();
          final page = scene.guide == 'remove-detected' ? DetectedActivitiesScreen(preloaded: await repo.pendingActivities())
              : scene.page!(); app.navigator.push(MaterialPageRoute<void>(builder: (_) => page)); final bad = <String>[]; var sampled = 0;
          for (var i = 0; i < 90; i++) { await t.pump(const Duration(milliseconds: 16));
            if (i % 10 == 0) await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
            final current = app.runner.routes.page; final back = current == null ? null : _backArrow(current); if (back == null) continue;
            sampled++; final look = _look(back); if (look == GuideUnitLook.skeleton) bad.add('frame $i: placeholder');
            if (!_takesTaps(t, laidOutBox(back)!)) bad.add('frame $i: tap absorbed'); } expect(sampled, greaterThan(0), reason: '${scene.id}: the arrival showed an app bar');
          expect(bad, isEmpty, reason: '${scene.id}: ${bad.take(6).toList()} (${bad.length} frames of $sampled)'); } finally {
          run.dispose(); await disposeR2(t, R2Mounted(app, run, null)); } }); } }); group('R5-4 off path', () {
    // WHY: spec Round 5 item 4, OFF path ("on path and off"). A user who wanders onto any page the guides
    // visit while ANOTHER guide runs is off path there; the page's app bar back arrow is then the route
    // back (or at least chrome): lit, not a placeholder, and it takes taps. CLAIM(back-arrow-always-usable).
    // catches: off-path plans that dim or cover the app bar, a route control that is not the arrow.
    for (final scene in _pageScenes) { testWidgets('R5-4d ${scene.id}: off path, the back arrow is lit and takes taps', (t) async {
        final repo = GuideFakeRepo(singlePending: false); final app = await pumpLiveGuideApp(t, size: r2Size, repo: repo);
        final guide = r2Guide(scene.guide == 'heart-rate-zones' ? 'alarm-schedule' : 'heart-rate-zones');
        final run = GuideRun(guide: guide, variant: (guide.variantFor(null) as GuideVariantFound).variant); try {
          final entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: app.navigatorKey, routes: app.runner.routes, onExit: run.exit, onBackToGuide: () {}));
          app.navigator.overlay!.insert(entry); addTearDown(() { if (entry.mounted) entry.remove(); });
          final page = scene.guide == 'remove-detected' ? DetectedActivitiesScreen(preloaded: await repo.pendingActivities())
              : scene.page!(); app.navigator.push(MaterialPageRoute<void>(builder: (_) => page)); await settleLiveGuide(t, frames: 18);
          expect(run.state, isA<GuideOffPath>(), reason: 'fixture: the page is off path for this guide'); final back = _backArrow(app.runner.routes.page!);
          expect(back, isNotNull, reason: '${scene.id}: the page has an app bar with a back arrow');
          expect(_look(back!), isNull, reason: '${scene.id}: off path, the back arrow is dimmed or a placeholder');
          expect(_takesTaps(t, laidOutBox(back)!), isTrue, reason: '${scene.id}: off path, a tap on the back arrow is absorbed');
        } finally { run.dispose(); await disposeR2(t, R2Mounted(app, run, null)); } }); } }); group('R5-7 neighbouring steps keep real controls', () {
    /// The controls of [step] that its page shows right now (target, alsoKeep, alsoTap).
    List<TargetFound> shown(Element page, GuideStep step) { final found = <TargetFound>[];
      for (final target in [step.target, ...step.alsoKeep]) { if (target.resolve(page, r2Locale) case final TargetFound f) found.add(f); } for (final content in step.alsoTap) {
        // "Every pressable row" names no particular control: on another page it is unrelated rows.
        if (content is PressableRows) continue; found.addAll(content.resolve(page, r2Locale)); } return found; } for (final scene in r2Scenes) {
      // WHY: spec Round 5 item 7 (owner: "the buttons you just pressed suddenly become placeholders
      // and inaccessible"). For step N, the targets of N-1 and N+1 that are on screen are real
      // controls: not a placeholder, and a tap on them reaches them (dim at most). Generic over every step of every guide. CLAIM(neighbour-targets-real).
      // catches: the placeholder rule applied to the control the user just used, or is about to.
      testWidgets('R5-7 ${scene.id}: the previous and next steps\' controls are not placeholders', (t) async {
        final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18);
          final page = m.app.runner.routes.page!; final steps = m.run.variant.steps; final index = steps.indexWhere((s) => s.id == scene.step); final problems = <String>[];
          for (final other in [index - 1, index + 1]) { if (other < 0 || other >= steps.length) continue;
            for (final f in shown(page, steps[other])) { final box = f.renderObject; if (!box.attached || !box.hasSize) continue;
              final onScreen = rectInRoot(box, laidOutBox(page)!).intersect(visibleBoundsInRoot(box, laidOutBox(page)!)); if (onScreen.isEmpty) continue;
              final control = onstageElements(page).where((e) => isGuideControl(e.widget) && identical(laidOutBox(e), box)).firstOrNull;
              if (control != null && _look(control) == GuideUnitLook.skeleton) { problems.add('${steps[other].id}: ${control.widget.runtimeType} at ${f.rect} is a placeholder'); }
              if (!_takesTaps(t, box)) problems.add('${steps[other].id}: a tap at ${f.rect.center} does not reach the control'); } }
          expect(problems, isEmpty, reason: '${scene.id}: neighbouring steps\' controls must stay real'); } finally { await disposeR2(t, m); } }); }
    // WHY: owner, round 5 item 7: "the buttons you just pressed suddenly become placeholders and inaccessible"
    // (remove-detected). Drive the real flow: with the guide on step 2, press a real Discard, and look at every
    // frame after it: every Discard still on the page (step 2's targets) stays a real control that takes taps,
    // and so does the Save bar that step 3 points at. CLAIM(neighbour-targets-real).
    // catches: the placeholder rule covering the previous step's controls once the run moves on.
    testWidgets('R5-7 flow: after pressing Discard on remove-detected, step 2\'s buttons and step 3\'s Save stay real in every frame', (t) async {
      final scene = r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard');
      final m = await pumpR2Scene(t, scene, singlePending: false, size: const Size(412, 1500)); try { await settleLiveGuide(t, frames: 18);
        final steps = m.run.variant.steps; final page0 = m.app.runner.routes.page!;
        final first = steps[1].target.resolve(page0, r2Locale) as TargetFound; await t.tapAt(first.rect.center); final bad = <String>[];
        var checked = 0; for (var i = 0; i < 60; i++) { await t.pump(const Duration(milliseconds: 16));
          final page = m.app.runner.routes.page; if (page == null) continue; for (final step in [steps[1]]) {
            // Save is step 3's target: real once the run is there (the frame the bar appears in, the guide card may still sit over it for a frame while the run moves on).
            final controls = [ for (final c in step.alsoTap) if (c is! PressableRows) ...c.resolve(page, r2Locale),
              if (step.target.resolve(page, r2Locale) case final TargetFound f) f, ]; for (final f in controls) {
              final box = f.renderObject; if (!box.attached || !box.hasSize) continue;
              final visible = rectInRoot(box, laidOutBox(page)!).intersect(visibleBoundsInRoot(box, laidOutBox(page)!)); if (visible.isEmpty) continue; checked++;
              final control = onstageElements(page).where((e) => isGuideControl(e.widget) && identical(laidOutBox(e), box)).firstOrNull;
              if (control != null && _look(control) == GuideUnitLook.skeleton) bad.add('frame $i: ${step.id} control at ${f.rect} is a placeholder');
              if (!_takesTaps(t, box)) bad.add('frame $i: ${step.id} control at ${f.rect} takes no taps'); } } }
        expect(checked, greaterThan(0), reason: 'the flow showed step 2\'s or step 3\'s controls');
        expect(bad, isEmpty, reason: '${bad.take(6).toList()} (${bad.length} findings in $checked checks)'); } finally { await disposeR2(t, m); } }); });
  group('R5-3 off path with a chrome route back', () {
    // WHY: spec Round 5 item 3 (shot 3: Hardware dim, Alerts lit). With a tab as the route back,
    // EVERY non-navigation unit dims, the route's neighbouring card included; only the route back
    // and the card's own buttons stay lit. Supersedes the "neighbour lit" rule of round 3 (R4). CLAIM(off-path-all-dim).
    // catches: the neighbour exemption applied when the route back is a tab in the bottom bar.
    testWidgets('R5-3: every content unit on Health is dimmed, with Today as the route back', (t) async { final app = await pumpLiveGuideApp(t, size: r2Size); try {
        final started = await app.runner.start(r2Guide('heart-rate-zones'), band: null) as GuideStarted;
        await settleLiveGuide(t, frames: 18); await t.tapAt(t.getRect(r2Tab(3)).center); await settleLiveGuide(t, frames: 12);
        expect(started.run.state, isA<GuideOffPath>()); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final page = app.runner.routes.page!; final back = t.getRect(r2Tab(0)); final lit = <String>[]; for (final unit in r2Units(page)) { if (unit.rect.overlaps(back)) continue;
          if (!overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, unit.rect))) {
            lit.add('${unit.element.widget.runtimeType} "${unit.text}" at ${unit.rect}'); } } expect(lit, isEmpty, reason: 'off path, route back = a tab: every content unit dims');
        expect(overlay.paintedShapes.where((s) => s.kind.name != 'dim'), isEmpty, reason: 'and none is a placeholder'); } finally {
        app.runner.exit(); await t.pumpWidget(const SizedBox()); app.dispose(); await t.pump(); } }); }); }
