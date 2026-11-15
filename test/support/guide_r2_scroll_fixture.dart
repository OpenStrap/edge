// A non-lazy page keeps target geometry measurable when a user's drag hides it. This fixture supplies widgets and a real ScrollController, never guide policy.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart'; import 'package:openstrap_edge/ui2/guides/guide_routes.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart' show GuideScrollBehavior; import 'guide_text.dart';
const r2ScrollLookalike = ValueKey('r2-scroll-lookalike'); const r2ScrollTarget = ValueKey('r2-scroll-target'); class R2ScrollFixture {
  final controller = ScrollController(initialScrollOffset: 400); final navKey = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver(); final dim = GuideDimController(); late GuideRun run; OverlayEntry? entry; int lookalikeTaps = 0;
  Future<void> pump(WidgetTester t) async { t.view.physicalSize = const Size(390, 780); t.view.devicePixelRatio = 1; addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(scrollBehavior: const GuideScrollBehavior(), navigatorKey: navKey, navigatorObservers: [routes],
      theme: buildTheme(Brightness.light), locale: const Locale('en'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ListView(controller: controller, children: [Column(key: const ValueKey('r2-scroll-column'), children: [
        for (var i = 0; i < 6; i++) SizedBox(height: 100, child: Surface(child: Text('Earlier information $i'))),
        Pressable(key: r2ScrollTarget, onTap: () {}, child: const Surface(child: Text('Target'))),
        // The window rule: "Later information 0" is the card right below the target (dimmed); the look-alike is the one after it, so it is a placeholder.
        for (var i = 0; i < 14; i++) SizedBox(height: i == 1 ? 76 : 100, child: i == 1
          ? Pressable(key: r2ScrollLookalike, onTap: () => lookalikeTaps++, child: const Surface(child: Text('Target option')))
          : Surface(child: Text('Later information $i'))), ])]))))); await t.pump(); final target = GuideTarget.key(r2ScrollTarget);
    final guide = Guide(id: 'scroll-fixture', title: fnText((_) => 'Scroll'), start: GuideStart.today, variants: [GuideVariant(steps: [GuideStep(id: 'target',
        target: target, anchor: GuideTarget.key(const ValueKey('r2-scroll-column')), action: GuideAction.scrollThenTap,
        caption: fnText((_) => 'Find Target.'))])]); run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: navKey,
      routes: routes, onExit: run.exit, onBackToGuide: () {})); navKey.currentState!.overlay!.insert(entry!);
    for (var i = 0; i < 18; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry!.mounted) entry!.remove(); run.dispose(); controller.dispose(); dim.dispose(); }); } }
