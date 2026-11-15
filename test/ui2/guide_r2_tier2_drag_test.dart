// Tier 2 review fix F2 (r2-review-opus-tier2.md): a page drag handed off from skeleton ink.
import 'dart:async' show unawaited;

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
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/guide_text.dart';

const _control = ValueKey('t2-control');

void main() {
  // WHY: CLAIM(drag-handoff-cancel) a drag handed from skeleton ink to the page's scrollable
  // is the overlay's to end. When the input layer goes (a dialog yields the guide, the run
  // exits) nothing else ends it: the Scrollable keeps ignoring pointers and swallows the
  // user's next tap on a perfectly legal control.
  // # catches: a dangling ScrollPosition drag after the layer is removed (F2), in either
  // removal path.
  for (final exitRun in [false, true]) {
    testWidgets('F2 a page drag cut off mid-gesture by ${exitRun ? 'the guide exiting' : 'a dialog'} does not swallow the next tap', (t) async {
      final page = _DragPage();
      await page.pump(t);
      final skeleton = t.getRect(find.byKey(_nearby));
      final g = await t.startGesture(skeleton.center);
      await g.moveBy(const Offset(0, -20));
      await g.moveBy(const Offset(0, -20));
      await t.pump();
      expect(page.scroll.offset, greaterThan(0), reason: 'positive control: the skeleton drag scrolled the page');
      expect(page.scroll.position.isScrollingNotifier.value, isTrue, reason: 'positive control: the page is mid-drag');
      if (exitRun) {
        page.entry.remove();
        page.run.exit();
      } else {
        unawaited(showDialog<void>(context: page.nav.currentContext!, builder: (_) => const AlertDialog(content: Text('Dialog'))));
      }
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      await g.up();
      if (!exitRun) {
        expect(find.text('Dialog'), findsOneWidget);
        page.nav.currentState!.pop();
      }
      for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 100)); }
      expect(page.scroll.position.isScrollingNotifier.value, isFalse, reason: 'the cut-off drag was ended, not left dangling');
      await t.tapAt(t.getRect(find.byKey(_dimmed)).center);
      await t.pump();
      expect(page.dimmedTaps, 1, reason: 'exactly one callback for the one tap');
      expect(page.nearbyTaps, 0);
    });
  }
}

const _nearby = ValueKey('t2-nearby');
const _dimmed = ValueKey('t2-dimmed');

/// A scrolling page under the shipped overlay: a placeholder card two cards before the target's
/// card, a dimmed card right above it.
class _DragPage {
  final scroll = ScrollController();
  final dim = GuideDimController();
  final nav = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver();
  late GuideRun run;
  late OverlayEntry entry;
  int nearbyTaps = 0, dimmedTaps = 0;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      navigatorKey: nav, navigatorObservers: [routes], scrollBehavior: const GuideScrollBehavior(),
      theme: buildTheme(Brightness.light), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Stack(children: [
        // The topmost text line is live status (kept lit): a title keeps the "Nearby" card out of that.
        const Positioned(top: 16, left: 16, child: Text('Page title')),
        Positioned(top: 80, left: 16, right: 16, bottom: 0, child: SingleChildScrollView(controller: scroll,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Window rule: the target's card is the 4th; "Different" is right above it (dimmed);
            // "Nearby" is two cards before the window (a placeholder).
            Pressable(key: _nearby, onTap: () => nearbyTaps++, child: const Surface(child: Text('Nearby'))),
            const SizedBox(height: 60),
            const Surface(child: Text('Filler card')),
            const SizedBox(height: 12),
            Pressable(key: _dimmed, onTap: () => dimmedTaps++, child: const Surface(child: Text('Different'))),
            const SizedBox(height: 12),
            Surface(child: Pressable(key: _control, onTap: () {}, child: const Text('Target'))),
            const SizedBox(height: 1400),
          ]))),
      ])))));
    await t.pump();
    final guide = Guide(id: 't2-drag', title: fnText((_) => 'Drag'), start: GuideStart.today,
      variants: [GuideVariant(steps: [GuideStep(id: 'target', target: GuideTarget.key(_control),
        anchor: GuideTarget.key(_control), action: GuideAction.tap, caption: fnText((_) => 'Tap Target.'))])]);
    run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: nav, routes: routes,
      onExit: run.exit, onBackToGuide: () {}));
    nav.currentState!.overlay!.insert(entry);
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); scroll.dispose(); dim.dispose(); });
  }
}
