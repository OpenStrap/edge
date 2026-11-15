// A page with a PINNED target above a long scrolling list of every kind of unit:
// banners (coloured Surface), loose text, tappable rows, Sections, alerts. The list
// scrolls, flings and overscrolls under a running guide; the target never moves, so
// every frame can be audited. One caption-named unit ("Kept note") sits inside the
// list and MOVES with it: it must stay clear in every frame.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart' show GuideScrollBehavior;
import 'guide_r2_fixture.dart' show R2Content, r2Capture;
import 'guide_text.dart';

const flowTarget = ValueKey('flow-target');
const flowKept = ValueKey('flow-kept');

class R2FlowFixture {
  final navKey = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver();
  final dim = GuideDimController();
  final controller = ScrollController();
  late GuideRun run;
  OverlayEntry? entry;
  static const size = Size(390, 780);

  Widget get home => Scaffold(body: Column(children: [
    const ScreenTitle('Flow title'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Pressable(key: flowTarget, onTap: () {},
      child: const Surface(child: Text('Pinned target')))),
    Expanded(child: ListView(controller: controller, padding: const EdgeInsets.all(16), children: [
      for (var i = 0; i < 40; i++) ...[
        switch (i % 5) {
          0 => Surface(color: const Color(0xff7040a0), child: Text('Banner $i', style: const TextStyle(color: Colors.white))),
          1 => Text('Loose line $i of plain text'),
          2 => Pressable(onTap: () {}, child: Surface(child: Text('Row $i'))),
          3 => Section('Section $i', Surface(child: Text('Section body $i'))),
          _ => i == 4 ? const Surface(key: flowKept, child: Text('Kept note')) :
            Surface(color: const Color(0xffc03030), child: Text('Alert $i', style: const TextStyle(color: Colors.white))),
        },
        const SizedBox(height: 12),
      ],
    ])),
  ]));

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: RepaintBoundary(key: r2Capture, child: MaterialApp(
      scrollBehavior: const GuideScrollBehavior(),
      navigatorKey: navKey, navigatorObservers: [routes], theme: buildTheme(Brightness.light),
      debugShowCheckedModeBanner: false, locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: home))));
    await t.pump();
    final guide = Guide(id: 'flow-fixture', title: fnText((_) => 'Flow'), start: GuideStart.today,
      variants: [GuideVariant(steps: [GuideStep(id: 'target', target: GuideTarget.key(flowTarget),
        anchor: GuideTarget.key(flowTarget), action: GuideAction.tap,
        alsoRead: const [R2Content([flowKept])], caption: fnText((_) => 'Tap Pinned target. Read the kept note.'))])]);
    run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: navKey, routes: routes,
      onExit: run.exit, onBackToGuide: () {}));
    navKey.currentState!.overlay!.insert(entry!);
    for (var i = 0; i < 18; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry?.mounted ?? false) entry!.remove(); run.dispose(); controller.dispose(); dim.dispose(); });
  }
}
