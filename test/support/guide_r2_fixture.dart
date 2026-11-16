import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart'; import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart'; import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart'; import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart'; import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/theme.dart'; import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart' show GuideScrollBehavior; import 'guide_text.dart';
const r2Target = ValueKey('r2-target'); const r2Alternative = ValueKey('r2-alternative'); const r2Quiet = ValueKey('r2-quiet');
const r2Details = ValueKey('r2-details'); const r2Other = ValueKey('r2-other'); const r2Group = ValueKey('r2-group');
const r2Sibling = ValueKey('r2-sibling'); const r2UnderCard = ValueKey('r2-under-card'); const r2Back = ValueKey('r2-back');
const r2Capture = ValueKey('r2-capture'); const r2HeadedCard = ValueKey('r2-headed-card'); const r2HeadedSection = ValueKey('r2-headed-section');
// Test-side selector supplies real laid-out target boxes to the new interface. It does not replace the overlay's planning, painting or shield.
class R2Content implements GuideContent { final List<Key> keys; const R2Content(this.keys); @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [ for (final key in keys) if (GuideTarget.key(key).resolve(root, l) case final TargetFound found) found, ]; }
class R2Fixture { final navKey = GlobalKey<NavigatorState>(); final routes = GuideRouteObserver(); final dim = GuideDimController();
  final targetTop = ValueNotifier<double>(100); final Guide guide; late GuideRun run;
  final bool lookalike, grouped, wrapTarget, separateRows, headed; final Locale locale; final String targetLabel, quietLabel, caption;
  final Brightness brightness; final Size size; final double textScale;
  int longPresses = 0, doubleTaps = 0, dragUpdates = 0, underlying = 0, underlyingLongPresses = 0; OverlayEntry? entry;
  int targets = 0, alternatives = 0, others = 0, exits = 0, returns = 0; R2Fixture({bool declarations = false, this.lookalike = false,
    this.grouped = false, this.wrapTarget = false, this.separateRows = false, this.headed = false, this.locale = const Locale('en'),
    this.targetLabel = 'Target', this.quietLabel = 'Quiet information', this.caption = 'Tap Target or Alternative. Check the details.',
    this.brightness = Brightness.light, this.size = const Size(390, 780), this.textScale = 1}) : guide = Guide(id: 'r2-fixture',
    title: fnText((_) => 'Fixture'), start: GuideStart.today, variants: [GuideVariant(steps: [
      GuideStep(id: 'target', target: GuideTarget.key(r2Target), anchor: GuideTarget.key(r2Target),
        action: GuideAction.tap, caption: fnText((_) => caption), alsoTap: declarations ? [const R2Content([r2Alternative])] : const [],
        alsoRead: declarations ? [const R2Content([r2Details])] : const []), ])], footers: [GuideFooter(kind: GuideFooterKind.missingTarget,
      title: fnText((_) => 'Missing?'), body: fnText((_) => 'Details help.'))]);
  Widget get home => Scaffold(body: ValueListenableBuilder<double>( valueListenable: targetTop, builder: (_, y, _) => Stack(children: [
      Positioned.fill(child: GestureDetector(key: r2UnderCard, behavior: HitTestBehavior.opaque,
        onTap: () => underlying++, onLongPress: () => underlyingLongPresses++, child: const SizedBox.expand())),
      const Positioned(top: 8, left: 16, right: 16, child: ScreenTitle('Fixture title')),
      Positioned(top: y, left: 16, right: grouped ? 104 : 16, child: grouped ? separateRows ? Column(key: r2Group, children: [ Row(children: [Expanded(child: targetControl)]),
            Row(children: [Expanded(child: Pressable(key: r2Sibling, onTap: () => alternatives++,
              child: const Surface(child: Text('Sibling'))))])]) : Row(key: r2Group, children: [Expanded(child: wrapTarget
            ? Padding(padding: const EdgeInsets.all(4), child: targetControl) : targetControl),
          Expanded(child: Pressable(key: r2Sibling, onTap: () => alternatives++, child: const Surface(child: Text('Sibling'))))]) : targetControl), if (lookalike) ...[
      Positioned(top: lookalike ? y + 60 : 310, left: 16, right: 16, child: GestureDetector(key: r2Alternative, behavior: HitTestBehavior.opaque,
        onTap: () => alternatives++, onLongPress: () => longPresses++,
        onDoubleTap: () => doubleTaps++, onVerticalDragUpdate: (_) => dragUpdates++, child: Surface(child: Text(lookalike ? 'Target option' : 'Alternative')))),
      Positioned(top: 220, left: 16, right: 16, child: Surface(key: r2Quiet,
        color: const Color(0xff7040a0), child: Text(quietLabel, style: const TextStyle(color: Colors.white)))), ] else ...[
      Positioned(top: 220, left: 16, right: 16, child: Surface(key: r2Quiet, color: const Color(0xff7040a0), child: Text(quietLabel, style: const TextStyle(color: Colors.white)))),
      Positioned(top: lookalike ? y + 60 : 310, left: 16, right: 16, child: GestureDetector(key: r2Alternative, behavior: HitTestBehavior.opaque,
        onTap: () => alternatives++, onLongPress: () => longPresses++,
        onDoubleTap: () => doubleTaps++, onVerticalDragUpdate: (_) => dragUpdates++, child: Surface(child: Text(lookalike ? 'Target option' : 'Alternative')))), ],
      const Positioned(top: 390, left: 16, right: 16, child: Section('Details', Surface(child: Text('Read this context')), key: r2Details)),
      // Two look-alike cards with a body (they share "Target" with the label): a skeleton card keeps its heading, dimmed, at the top-left; the body lines are bars.
      if (headed) const Positioned(top: 480, left: 16, right: 16, child: Surface(key: r2HeadedCard, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Target notes'), Text('Alpha beta gamma'), Text('Delta epsilon zeta')]))),
      if (headed) const Positioned(top: 600, left: 16, right: 16, child: Section('Target section', Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Body line one'), Text('Body line two')])), key: r2HeadedSection)), ])));
  Widget get targetControl => Pressable(key: r2Target, onTap: () => targets++, child: Surface(child: Text(targetLabel)));
  Future<void> pump(WidgetTester t) async { t.view.physicalSize = size; t.view.devicePixelRatio = 1; addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: RepaintBoundary(key: r2Capture, child: MaterialApp(
      scrollBehavior: const GuideScrollBehavior(), navigatorKey: navKey, navigatorObservers: [routes], theme: buildTheme(brightness),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale)), child: child!), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, locale: locale, home: home)))); await t.pump(); await start(t);
    addTearDown(() { if (entry?.mounted ?? false) entry!.remove(); run.dispose(); targetTop.dispose(); dim.dispose(); }); }
  Future<void> start(WidgetTester t) async { run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: navKey,
      routes: routes, onExit: () => exits++, onBackToGuide: () { returns++; navKey.currentState!.pop(); }));
    navKey.currentState!.overlay!.insert(entry!); await frames(t); } Future<void> restart(WidgetTester t) async { entry!.remove();
    await t.pump(); run.dispose(); await start(t); } Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); } } Future<void> elsewhere(WidgetTester t) async {
    navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: Column(children: [ const NavBar('Elsewhere'),
      Pressable(key: r2Other, onTap: () => others++, child: const Surface(child: Text('Other action'))), const Surface(child: Text('Second card')), ])))); await frames(t); } }
