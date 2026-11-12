// A small STAGE for live-guide tests that need full control of the screens: a
// real MaterialApp + root Navigator (with a navigatorKey) and three pages built
// from ui2 cards and Pressables, so the overlay's geometry, pointer rules and
// navigation are exercised on real widgets without the weight of the whole app.
//
//   Home    : title, two cards, "Open details" (key `openDetails`), "Other
//             action" (key `otherAction`), "Ask first" (opens a confirm dialog)
//   Details : title, "Finish" (key `finish`, low on a tall page: scroll step)
//   Other   : a page the guide does not know ("You've left the path")
//
// Counters record which real control received a tap, so "the tap reached the
// real control" is observed, not assumed.
//
// Not a test file (no _test suffix).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const stageOpenDetails = ValueKey('stage-open-details');
const stageOtherAction = ValueKey('stage-other-action');
const stageAskFirst = ValueKey('stage-ask-first');
const stageFinish = ValueKey('stage-finish');
const stageGoElsewhere = ValueKey('stage-go-elsewhere');
const stageHomeTitle = ValueKey('stage-home-title');
const stageDetailsTitle = ValueKey('stage-details-title');
const stageElsewhereAction = ValueKey('stage-elsewhere-action');

/// Which real control got a tap.
class StageTaps {
  int openDetails = 0, otherAction = 0, finish = 0, dialogConfirm = 0, elsewhere = 0;
}

class StagePages {
  final StageTaps taps;
  final double detailsGap;
  StagePages(this.taps, {this.detailsGap = 0});

  Widget home() => Builder(builder: (c) {
        final nav = Navigator.of(c);
        return Scaffold(
          body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const ScreenTitle('Stage home', key: stageHomeTitle),
              const Surface(child: Text('First card text')),
              const SizedBox(height: 12),
              const Surface(child: Text('Second card text')),
              const SizedBox(height: 12),
              Pressable(
                key: stageOpenDetails,
                onTap: () {
                  taps.openDetails++;
                  nav.push(MaterialPageRoute<void>(builder: (_) => details()));
                },
                child: const Surface(child: Text('Open details')),
              ),
              const SizedBox(height: 12),
              Pressable(
                key: stageOtherAction,
                onTap: () => taps.otherAction++,
                child: const Surface(child: Text('Other action')),
              ),
              const SizedBox(height: 12),
              Pressable(
                key: stageAskFirst,
                onTap: () => showDialog<void>(
                  context: c,
                  builder: (d) => AlertDialog(
                    title: const Text('Sure?'),
                    actions: [
                      TextButton(
                        onPressed: () {
                          taps.dialogConfirm++;
                          Navigator.of(d).pop();
                        },
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                ),
                child: const Surface(child: Text('Ask first')),
              ),
              const SizedBox(height: 12),
              Pressable(
                key: stageGoElsewhere,
                onTap: () => nav.push(MaterialPageRoute<void>(builder: (_) => other())),
                child: const Surface(child: Text('Go elsewhere')),
              ),
            ]),
          ),
        );
      });

  Widget details() => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const ScreenTitle('Stage details', key: stageDetailsTitle),
            const Surface(child: Text('Details card text')),
            SizedBox(height: detailsGap),
            Pressable(
              key: stageFinish,
              onTap: () => taps.finish++,
              child: const Surface(child: Text('Finish')),
            ),
          ]),
        ),
      );

  Widget other() => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const ScreenTitle('Somewhere else'),
            const Surface(child: Text('Not part of any guide')),
            const SizedBox(height: 12),
            Pressable(
              key: stageElsewhereAction,
              onTap: () => taps.elsewhere++,
              child: const Surface(child: Text('Elsewhere action')),
            ),
          ]),
        ),
      );
}

String stageCaption1(AppLocalizations l) => 'Tap **Open details** on the home page.';
String stageCaption2(AppLocalizations l) => 'Tap **Finish** at the bottom.';

/// Two steps: Home's "Open details" (anchor: Home's title), then Details'
/// "Finish" (anchor: Details' title; a scroll step when [scrollLast]).
Guide stageGuide({bool scrollLast = false, GuideStart start = GuideStart.today}) {
  final homeTitle = GuideTarget.key(stageHomeTitle);
  final detailsTitle = GuideTarget.key(stageDetailsTitle);
  return Guide(
    id: 'stage',
    title: (_) => 'Stage guide',
    start: start,
    variants: [
      GuideVariant(steps: [
        GuideStep(
          id: 'open',
          target: GuideTarget.key(stageOpenDetails),
          anchor: homeTitle,
          action: GuideAction.tap,
          caption: stageCaption1,
        ),
        GuideStep(
          id: 'finish',
          target: GuideTarget.key(stageFinish),
          anchor: detailsTitle,
          action: scrollLast ? GuideAction.scrollThenTap : GuideAction.tap,
          caption: stageCaption2,
        ),
      ]),
    ],
    footers: [
      GuideFooter(
        kind: GuideFooterKind.anotherWay,
        title: (_) => 'Another way in',
        body: (_) => 'Open the menu, then **Details**.',
      ),
      GuideFooter(
        kind: GuideFooterKind.missingTarget,
        title: (_) => "Don't see Open details?",
        body: (_) => 'It only shows once you have signed in.',
      ),
    ],
  );
}

class LiveStage {
  final StageTaps taps;
  final GlobalKey<NavigatorState> navigatorKey;
  final GuideRun run;
  final List<VoidCallback> exits = [];
  int exitCount = 0, backToGuideCount = 0;
  OverlayEntry? entry;
  LiveStage(this.taps, this.navigatorKey, this.run);

  NavigatorState get navigator => navigatorKey.currentState!;
}

/// Pumps the stage at 390 x 780 and inserts a [LiveGuideOverlay] for [guide]
/// into the ROOT overlay itself (not through GuideRunner), so overlay behaviour
/// is tested apart from the runner's navigation.
Future<LiveStage> pumpLiveStage(
  WidgetTester t, {
  Guide? guide,
  double detailsGap = 0,
  Locale locale = const Locale('en'),
  bool insertOverlay = true,
}) async {
  t.view.physicalSize = const Size(390, 780);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final key = GlobalKey<NavigatorState>();
  final taps = StageTaps();
  final g = guide ?? stageGuide();
  final variant = (g.variantFor(null) as GuideVariantFound).variant;
  final stage = LiveStage(taps, key, GuideRun(guide: g, variant: variant));
  addTearDown(stage.run.dispose);
  await t.pumpWidget(MaterialApp(
    navigatorKey: key,
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: StagePages(taps, detailsGap: detailsGap).home(),
  ));
  await t.pump();
  if (insertOverlay) {
    stage.entry = OverlayEntry(
      builder: (_) => LiveGuideOverlay(
        run: stage.run,
        navigatorKey: key,
        onExit: () => stage.exitCount++,
        onBackToGuide: () => stage.backToGuideCount++,
      ),
    );
    key.currentState!.overlay!.insert(stage.entry!);
    addTearDown(() {
      if (stage.entry?.mounted ?? false) stage.entry!.remove();
    });
    await t.pump();
  }
  return stage;
}

/// Pushes a stage page by its builder on the stage's root navigator.
Future<void> pushStagePage(WidgetTester t, LiveStage stage, Widget page) async {
  stage.navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}
