// GUIDE RUNNER (live mode): starts, owns and ends the one [GuideRun] of the
// app, and does the navigation around it.
//
//  * start: bring the app to the guide's start (pop every route above the
//    shell's root route, then select [Guide.start] with the SHELL'S OWN API:
//    the tab selection AppShell already follows, or the Settings screen), then
//    put a [LiveGuideOverlay] into the ROOT Overlay of the app's Navigator,
//    above every route.
//  * exit: remove the overlay and nothing else. The app stays exactly where the
//    user is: no pop, no tab change.
//  * backToGuide: from the off-path card, Navigator back until a step matches.
//
// CLAIM(run-no-new-stack): a run adds no Navigator and no route; its only
// footprint is one OverlayEntry [live_guide_integration_test 'start pops to the
// shell root'].
// CLAIM(run-exit-in-place): exit leaves routes and the selected tab untouched
// [live_guide_integration_test 'Exit removes the overlay'].
// CLAIM(run-one-at-a-time): starting a run while another is active ends the
// first; there is never more than one overlay entry
// [live_guide_runner_test 'a second start replaces the first'].
//
// Mating parts: the app shell registers a [GuideShellLink] (attachShell) when
// it mounts and removes it when it goes; Help (help_screen.dart) and, later,
// the coach card call [start].

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'live_guide_overlay.dart';

import '../app_shell.dart' show ShellDomain;
import 'guide.dart';
import 'guide_run.dart';

/// What the app shell offers a run: its own tab selection and Settings.
class GuideShellLink {
  /// Selects [tab] the way a deep link does (the notifier AppShell follows).
  final void Function(ShellDomain tab) selectTab;

  /// Pushes Settings on the root Navigator.
  final Future<void> Function() openSettings;

  const GuideShellLink({required this.selectTab, required this.openSettings});
}

sealed class GuideStartResult {
  const GuideStartResult();
}

final class GuideStarted extends GuideStartResult {
  final GuideRun run;
  const GuideStarted(this.run);
}

/// The guide has nothing for the user's band ([GuideNoVariant] says which bands
/// it covers); no overlay was shown and nothing moved.
final class GuideStartNoVariant extends GuideStartResult {
  final GuideNoVariant reason;
  const GuideStartNoVariant(this.reason);
}

/// No shell is attached (the app is not on its main screen yet): nothing moved.
final class GuideStartNoShell extends GuideStartResult {
  const GuideStartNoShell();
}

class GuideRunner extends ChangeNotifier {
  /// The key of the app's ROOT Navigator (MaterialApp.navigatorKey).
  final GlobalKey<NavigatorState> navigatorKey;

  GuideRunner({required this.navigatorKey});

  /// The run in progress, or null.
  GuideRun? _run;
  GuideShellLink? _shell;
  OverlayEntry? _entry;
  GuideRun? get activeRun => _run;

  /// The shell registers itself on mount and unregisters on dispose. Detaching
  /// a link that is not the attached one is a no-op.
  void attachShell(GuideShellLink link) { _shell = link; }
  void detachShell(GuideShellLink link) {
    if (!identical(link, _shell)) return;
    _shell = null;
    exit();
  }

  /// Starts [guide] for [band] (null = unknown band, which gets only an "any"
  /// variant, see [Guide.variantFor]). See the file header for the steps.
  /// ↳ CLAIM(run-no-new-stack) ↳ CLAIM(run-one-at-a-time)
  GuideStartResult start(Guide guide, {required BandGeneration? band}) {
    final choice = guide.variantFor(band);
    if (choice is GuideNoVariant) return GuideStartNoVariant(choice);
    final nav = navigatorKey.currentState;
    if (_shell == null || nav == null) return const GuideStartNoShell();
    exit();
    nav.popUntil((route) => route.isFirst);
    _selectStart(guide.start);
    final run = GuideRun(guide: guide, variant: (choice as GuideVariantFound).variant);
    _run = run;
    run.addListener(_runChanged);
    _entry = OverlayEntry(builder: (_) => LiveGuideOverlay(
      run: run, navigatorKey: navigatorKey, onExit: exit,
      onBackToGuide: () => unawaited(backToGuide()),
    ));
    nav.overlay!.insert(_entry!);
    notifyListeners();
    return GuideStarted(run);
  }

  void _selectStart(GuideStart start) {
    switch (start) {
      case GuideStart.today: _shell?.selectTab(ShellDomain.today);
      case GuideStart.sleep: _shell?.selectTab(ShellDomain.sleep);
      case GuideStart.activity: _shell?.selectTab(ShellDomain.activity);
      case GuideStart.health: _shell?.selectTab(ShellDomain.health);
      case GuideStart.settings:
        final future = _shell?.openSettings();
        if (future != null) unawaited(future);
    }
  }

  void _runChanged() { if (_run?.isExited ?? false) exit(); }

  /// Navigator back, one route at a time, until a step matches or only the
  /// shell is left; if the shell root still matches nothing, selects
  /// [Guide.start] again. Completes when the run is back on a step.
  Future<void> backToGuide() async {
    final run = _run;
    final nav = navigatorKey.currentState;
    if (run == null || nav == null) return;
    final l = AppLocalizations.of(nav.context);
    while (identical(_run, run) && nav.mounted) {
      final page = topPageRoot(nav);
      if (page != null && l != null && GuideRun.matchStep(run.variant, page, l) != null) {
        run.observe(page, l);
        return;
      }
      if (!nav.canPop()) {
        _selectStart(run.guide.start);
        return;
      }
      nav.pop();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Ends the active run (no-op without one).
  /// ↳ CLAIM(run-exit-in-place)
  void exit() {
    final run = _run;
    if (run == null) return;
    _run = null;
    run.removeListener(_runChanged);
    run.exit();
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    notifyListeners();
  }

  @override
  void dispose() {
    exit();
    super.dispose();
  }
}
