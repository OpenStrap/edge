// GuideRunner: starting, owning and ending the one live run, and the navigation
// around it. RED until the green phase implements lib/ui2/guides/guide_runner.dart.
//
// The shell is represented by a recording [GuideShellLink]: its two methods are
// the ONLY thing a run asks of the shell, so the order and arguments of those
// calls are the contract. The full app (real AppShell) is covered in
// live_guide_integration_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/app_shell.dart' show ShellDomain;
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/live_guide_harness.dart' show prefsSnapshot;
import '../support/live_guide_stage.dart';

/// What the shell was asked, in order, with whether routes were still stacked.
class _ShellLog {
  final events = <String>[];
  late GuideShellLink link;
  _ShellLog(LiveStage stage) {
    link = GuideShellLink(
      selectTab: (tab) => events.add('tab:${tab.name} canPop=${stage.navigator.canPop()}'),
      openSettings: () async => events.add('settings canPop=${stage.navigator.canPop()}'),
    );
  }
}

Future<({LiveStage stage, GuideRunner runner, _ShellLog shell})> _pump(WidgetTester t, {Guide? guide, bool attach = true}) async {
  final stage = await pumpLiveStage(t, guide: guide, insertOverlay: false);
  final runner = GuideRunner(navigatorKey: stage.navigatorKey, routes: stage.routes);
  addTearDown(runner.dispose);
  final shell = _ShellLog(stage);
  if (attach) runner.attachShell(shell.link);
  return (stage: stage, runner: runner, shell: shell);
}

Guide _twoBandGuide() => Guide(id: 'two', title: (_) => 'Two', start: GuideStart.today, variants: [
      GuideVariant(devices: {BandGeneration.whoop4}, steps: [
        GuideStep(id: 'four', target: GuideTarget.key(stageOpenDetails), anchor: GuideTarget.key(stageHomeTitle), action: GuideAction.tap, caption: (_) => 'four'),
      ]),
      GuideVariant(devices: {BandGeneration.whoop5}, steps: [
        GuideStep(id: 'five', target: GuideTarget.key(stageOpenDetails), anchor: GuideTarget.key(stageHomeTitle), action: GuideAction.tap, caption: (_) => 'five'),
      ]),
    ]);

int _overlays(WidgetTester t) => find.byType(LiveGuideOverlay).evaluate().length;

Future<void> _frames(WidgetTester t) async {
  await t.pump();
  await t.pump();
  await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50));
}

Future<int> _dbChanges() async {
  final db = await LocalDb.instance;
  return ((await db.rawQuery('SELECT total_changes() AS n')).single['n'] as num).toInt();
}

void main() {
  group('start', () {
    for (final (start, tab) in [
      (GuideStart.today, ShellDomain.today),
      (GuideStart.sleep, ShellDomain.sleep),
      (GuideStart.activity, ShellDomain.activity),
      (GuideStart.health, ShellDomain.health),
    ]) {
      testWidgets('${start.name}: pops every route above the shell root, THEN selects the ${tab.name} tab', (t) async {
        // why: spec "pop to the shell's root route and select that destination
        // with the shell's own API". The order matters: selecting a tab under a
        // pushed route would change a tab nobody can see.
        final h = await _pump(t, guide: stageGuide(start: start));
        await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
        await pushStagePage(t, h.stage, StagePages(h.stage.taps).other());
        expect(h.stage.navigator.canPop(), isTrue);

        final result = h.runner.start(stageGuide(start: start), band: null);
        await _frames(t);

        expect(result, isA<GuideStarted>());
        expect(h.shell.events, ['tab:${tab.name} canPop=false']);
        expect(h.stage.navigator.canPop(), isFalse, reason: 'only the shell root route is left');
      });
    }

    testWidgets('settings: pops to the root, then opens Settings through the shell, selecting no tab', (t) async {
      // why: Settings is a pushed screen, not a tab; the shell link owns that push.
      final h = await _pump(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      h.runner.start(stageGuide(start: GuideStart.settings), band: null);
      await _frames(t);
      expect(h.shell.events, ['settings canPop=false']);
    });

    testWidgets('puts exactly one overlay into the root overlay and adds no route', (t) async {
      // why: CLAIM(run-no-new-stack): a run is an OverlayEntry, not a Navigator or a route.
      final h = await _pump(t);
      expect(_overlays(t), 0);
      final result = h.runner.start(stageGuide(), band: null) as GuideStarted;
      await _frames(t);
      expect(_overlays(t), 1);
      expect(h.runner.activeRun, same(result.run));
      expect(h.stage.navigator.canPop(), isFalse);
      expect(find.byType(Navigator), findsOneWidget, reason: 'no second Navigator');
    });

    testWidgets('the overlay stays ABOVE routes pushed after it started', (t) async {
      // why: Flutter inserts a pushed route\'s entries just above its predecessor
      // route; an overlay entry added earlier must not end up underneath, or the
      // off-path card would be hidden by the very page that makes it necessary.
      final h = await _pump(t);
      h.runner.start(stageGuide(), band: null);
      await _frames(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).other());
      await _frames(t);
      expect(find.byKey(GuideStepCard.offPathKey).hitTestable(), findsOneWidget);
    });

    testWidgets('a second start replaces the first: one overlay, the first run exited', (t) async {
      // why: CLAIM(run-one-at-a-time).
      final h = await _pump(t);
      final first = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      final second = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      expect(first.isExited, isTrue);
      expect(h.runner.activeRun, same(second));
      expect(_overlays(t), 1);
    });

    testWidgets('with no shell attached nothing moves and no overlay appears', (t) async {
      // why: before the main screen exists there is nowhere to bring the app to.
      final h = await _pump(t, attach: false);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      final result = h.runner.start(stageGuide(), band: null);
      await _frames(t);
      expect(result, isA<GuideStartNoShell>());
      expect(h.stage.navigator.canPop(), isTrue, reason: 'no pop happened');
      expect(h.runner.activeRun, isNull);
      expect(_overlays(t), 0);
    });
  });

  group('band variants (unchanged by live mode)', () {
    testWidgets('a known band runs its own variant\'s steps', (t) async {
      // why: WHOOP 4 and 5 differ in paths; the run must carry the right steps.
      final h = await _pump(t);
      final run = (h.runner.start(_twoBandGuide(), band: BandGeneration.whoop5) as GuideStarted).run;
      expect(run.variant.steps.single.id, 'five');
      h.runner.exit();
      final run4 = (h.runner.start(_twoBandGuide(), band: BandGeneration.whoop4) as GuideStarted).run;
      expect(run4.variant.steps.single.id, 'four');
    });

    testWidgets('no variant for the band: said, with the bands covered; nothing moves, no overlay', (t) async {
      // why: "a guide with no variant for the user\'s band says so" - never an empty guide.
      final h = await _pump(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      final result = h.runner.start(_twoBandGuide(), band: null);
      await _frames(t);
      expect(result, isA<GuideStartNoVariant>());
      final reason = (result as GuideStartNoVariant).reason;
      expect(reason.available, {BandGeneration.whoop4, BandGeneration.whoop5});
      expect(h.stage.navigator.canPop(), isTrue);
      expect(h.shell.events, isEmpty);
      expect(_overlays(t), 0);
    });
  });

  group('exit', () {
    testWidgets('removes the overlay and leaves the app exactly where the user is', (t) async {
      // why: CLAIM(run-exit-in-place). Spec: Exit "always available"; leaving the
      // user on another screen/tab than the one they are looking at would be a
      // surprise.
      final h = await _pump(t);
      h.runner.start(stageGuide(), band: null);
      await _frames(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      await _frames(t);
      final eventsBefore = List.of(h.shell.events);
      h.runner.exit();
      await t.pump();
      expect(_overlays(t), 0);
      expect(h.runner.activeRun, isNull);
      expect(find.byKey(stageDetailsTitle), findsOneWidget, reason: 'still on the page the user was on');
      expect(h.stage.navigator.canPop(), isTrue, reason: 'no pop');
      expect(h.shell.events, eventsBefore, reason: 'no tab change');
    });

    testWidgets('exit with no run is a no-op; exit twice is a no-op', (t) async {
      // why: Exit can race a finished frame callback.
      final h = await _pump(t);
      h.runner.exit();
      h.runner.start(stageGuide(), band: null);
      await _frames(t);
      h.runner.exit();
      h.runner.exit();
      await t.pump();
      expect(_overlays(t), 0);
    });

    testWidgets('a run that exits itself (GuideRun.exit) takes its overlay with it', (t) async {
      // why: one path to "ended": whoever ends the run, the overlay goes and activeRun clears.
      final h = await _pump(t);
      final run = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      run.exit();
      await t.pump();
      expect(h.runner.activeRun, isNull);
      expect(_overlays(t), 0);
    });

    testWidgets('the shell going away ends the run', (t) async {
      // why: a run needs a shell to be brought to; without one it would sit over a dead app.
      final h = await _pump(t);
      final run = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      h.runner.detachShell(h.shell.link);
      await t.pump();
      expect(run.isExited, isTrue);
      expect(_overlays(t), 0);
    });

    testWidgets('detaching a shell that is not the attached one is ignored', (t) async {
      // why: a stale shell disposing late (hot restart, re-mount) must not end a live run.
      final h = await _pump(t);
      final run = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      h.runner.detachShell(_ShellLog(h.stage).link);
      await t.pump();
      expect(run.isExited, isFalse);
      expect(_overlays(t), 1);
    });
  });

  group('backToGuide', () {
    testWidgets('pops one route at a time until a step matches', (t) async {
      // why: spec "Back to the guide (returns to the last matched step's screen
      // via Navigator back)". Stack: home, details (step 2), other (off path).
      final h = await _pump(t);
      final run = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      await _frames(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).other());
      await _frames(t);
      expect(run.state, isA<GuideOffPath>());

      final back = h.runner.backToGuide();
      await _frames(t);
      await back.timeout(const Duration(seconds: 5));
      await _frames(t);
      expect(find.byKey(stageDetailsTitle), findsOneWidget, reason: 'popped only as far as the step page');
      expect(run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 1));
    });

    testWidgets('when the shell root itself is off the path, it selects the guide\'s start again and completes', (t) async {
      // why: the user left by switching tab (no route to pop). The way back is the
      // start; the future must complete (bounded) rather than pop forever.
      final h = await _pump(t);
      h.runner.start(stageGuide(), band: null);
      await _frames(t);
      h.shell.events.clear();
      h.stage.navigator.pushReplacement(MaterialPageRoute<void>(builder: (_) => StagePages(h.stage.taps).other()));
      await t.pump(const Duration(milliseconds: 400));
      await _frames(t);
      final back = h.runner.backToGuide();
      await _frames(t);
      await back.timeout(const Duration(seconds: 5));
      expect(h.shell.events, ['tab:today canPop=false']);
    });
  });

  group('the run writes nothing', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'live_guide_runner_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async => LocalDb.close());

    testWidgets('start, step changes, off path, back, done and exit change no preference and no database row', (t) async {
      // why: CLAIM(run-memory-only) / spec "The guide writes nothing, anywhere".
      // The probes are shown to move on a real write first (a probe that cannot
      // move proves nothing).
      SharedPreferences.setMockInitialValues({'seed': 1});
      await Prefs.ensureLoaded();
      final prefsBefore = await t.runAsync(prefsSnapshot);
      final dbBefore = await t.runAsync(_dbChanges);
      Prefs.setInt('probe', 7);
      await t.runAsync(() => LocalDb.setCursor('probe', '1'));
      expect(await t.runAsync(prefsSnapshot), isNot(prefsBefore), reason: 'positive control: prefs probe moves');
      expect(await t.runAsync(_dbChanges), greaterThan(dbBefore!), reason: 'positive control: db probe moves');

      final prefs = await t.runAsync(prefsSnapshot);
      final db = await t.runAsync(_dbChanges);

      final h = await _pump(t);
      final run = (h.runner.start(stageGuide(), band: null) as GuideStarted).run;
      await _frames(t);
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).details());
      await _frames(t);
      await t.tap(find.byKey(stageFinish));
      await _frames(t);
      expect(run.state, isA<GuideFinished>());
      await pushStagePage(t, h.stage, StagePages(h.stage.taps).other());
      h.runner.exit();
      await t.pump();

      expect(await t.runAsync(prefsSnapshot), prefs, reason: 'no preference written by the run');
      expect(await t.runAsync(_dbChanges), db, reason: 'no database change by the run');
    });
  });
}
