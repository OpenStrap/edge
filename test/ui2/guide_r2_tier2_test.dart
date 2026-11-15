// Tier 2 review fix F1 (r2-review-opus-tier2.md): the BEHAVIOUR the owner sees, on real
// widgets (the shipped AppShell, the shipped overlay and run).
import '../support/live_guide_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/guide_text.dart';

const _anchor = ValueKey('t2-anchor');
const _missing = ValueKey('t2-missing');
const _onHealth = ValueKey('t2-on-health');
const _control = ValueKey('t2-control');

Finder _tabs() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabBar');
Finder _tab(int i) => find.descendant(of: _tabs(), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tab')).at(i);

/// The shipped [AppShell] (IndexedStack of tabs, tab bar) with one tiny screen per tab, the
/// shipped overlay inserted by hand, and a guide whose anchor is on the Activity tab.
class _Shell {
  final nav = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver();
  final dim = GuideDimController();
  late GuideRun run;
  late OverlayEntry entry;
  int controlTaps = 0;

  Future<void> pump(WidgetTester t, {required GuideTarget target, GuideAction action = GuideAction.tap,
      bool parkHealth = false}) async {
    SharedPreferences.setMockInitialValues(const {});
    await Prefs.ensureLoaded();
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      navigatorKey: nav, navigatorObservers: [routes], scrollBehavior: const GuideScrollBehavior(),
      theme: buildTheme(Brightness.light), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(initial: ShellDomain.activity, builder: (context, domain) => switch (domain) {
        ShellDomain.activity => Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Shell anchor line', key: _anchor)),
          Pressable(key: _control, onTap: () => controlTaps++, child: const Surface(child: Text('A control'))),
        ]),
        ShellDomain.health => Column(children: [Pressable(key: _onHealth, onTap: () {}, child: const Text('Only on Health'))]),
        _ => const SizedBox.shrink(),
      }),
    )));
    await t.pump();
    if (parkHealth) {
      // Visit Health so its screen stays mounted (parked) under the IndexedStack, then come back.
      await t.tap(_tab(3));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(_tab(2));
      await t.pump(const Duration(milliseconds: 300));
    }
    final guide = Guide(id: 't2', title: fnText((_) => 'Tier 2'), start: GuideStart.activity,
      variants: [GuideVariant(steps: [GuideStep(id: 'step', target: target, anchor: GuideTarget.key(_anchor),
        action: action, caption: fnText((_) => 'Tap the thing.'))])]);
    run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: nav, routes: routes,
      onExit: run.exit, onBackToGuide: () {}));
    nav.currentState!.overlay!.insert(entry);
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); dim.dispose(); });
  }
}

void main() {
  // WHY: CLAIM(absent-covers-nothing) a target that is simply not on this page gives the guide
  // nothing to point at; sending the user to "the guide's start tab" (the tab they are already
  // on) dims the whole page, outlines the current tab and leads nowhere. On a scrollThenTap
  // step a "Scroll" marker would also point at nothing.
  // # catches: routing every TargetAbsent through the start tab (F1), a scroll marker for an
  // absent target, a skeleton layer that absorbs taps while covering nothing.
  for (final action in GuideAction.values) {
    testWidgets('F1 a target absent from the current tab covers nothing (${action.name})', (t) async {
      final semantics = t.ensureSemantics();
      try {
        final shell = _Shell();
        await shell.pump(t, target: GuideTarget.key(_missing), action: action);
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        expect(shell.run.state, isA<GuideAtStep>(), reason: 'positive control: the anchor is on this tab, the step is current');
        expect(overlay.targetRect, isNull);
        expect(liveGuideFocus, findsNothing, reason: 'no outline');
        expect(find.byKey(LiveGuideOverlay.tapPillKey), findsNothing, reason: 'no Tap pill');
        expect(find.byKey(LiveGuideOverlay.scrollMarkerKey), findsNothing, reason: 'no Scroll marker');
        expect(overlay.paintedShapes, isEmpty, reason: 'no dim, no skeleton');
        expect(shell.dim.looks, isNull, reason: 'no plan published to the components');
        expect(find.byKey(LiveGuideOverlay.skeletonKey), findsNothing, reason: 'no input layer over a page nothing covers');
        expect(find.bySemanticsLabel(RegExp('^Guide: open the')), findsNothing, reason: 'no route proxy');
        await t.tapAt(t.getRect(find.byKey(_control)).center);
        expect(shell.controlTaps, 1, reason: 'the page works as without a guide');
      } finally {
        semantics.dispose();
      }
    });
  }

  // WHY: the target IS inside another tab's (parked) screen, so that tab is the way to it.
  // Highlight THAT tab, not the guide's start tab.
  // # catches: the tab route dropped altogether by the F1 fix, or still pointing at the start tab.
  testWidgets('F1 a target inside another tab highlights that tab', (t) async {
    final semantics = t.ensureSemantics();
    try {
      final shell = _Shell();
      await shell.pump(t, target: GuideTarget.key(_onHealth), parkHealth: true);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(shell.run.state, isA<GuideAtStep>());
      expect(overlay.targetRect, isNull, reason: 'the target is not on this tab');
      final outline = liveGuideFocus;
      expect(outline, findsOneWidget);
      final ring = t.getRect(outline);
      final health = t.getRect(_tab(3)), current = t.getRect(_tab(2));
      expect(ring.contains(health.center), isTrue, reason: 'the outline is on the Health tab');
      expect(ring.contains(current.center), isFalse, reason: 'never the tab the user is on');
      expect((ring.center - health.center).distance, lessThan((ring.center - current.center).distance));
      expect(find.byKey(LiveGuideOverlay.tapPillKey), findsOneWidget);
      final label = t.widget<Pressable>(find.descendant(of: _tab(3), matching: find.byType(Pressable))).semanticLabel!;
      expect(find.bySemanticsLabel('Guide: open the $label tab'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

}
