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

import 'package:flutter/widgets.dart';

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
  GuideRun? get activeRun => throw UnimplementedError('GuideRunner.activeRun');

  /// The shell registers itself on mount and unregisters on dispose. Detaching
  /// a link that is not the attached one is a no-op.
  void attachShell(GuideShellLink link) => throw UnimplementedError('GuideRunner.attachShell');
  void detachShell(GuideShellLink link) => throw UnimplementedError('GuideRunner.detachShell');

  /// Starts [guide] for [band] (null = unknown band, which gets only an "any"
  /// variant, see [Guide.variantFor]). See the file header for the steps.
  /// ↳ CLAIM(run-no-new-stack) ↳ CLAIM(run-one-at-a-time)
  GuideStartResult start(Guide guide, {required BandGeneration? band}) =>
      throw UnimplementedError('GuideRunner.start');

  /// Navigator back, one route at a time, until a step matches or only the
  /// shell is left; if the shell root still matches nothing, selects
  /// [Guide.start] again. Completes when the run is back on a step.
  Future<void> backToGuide() => throw UnimplementedError('GuideRunner.backToGuide');

  /// Ends the active run (no-op without one).
  /// ↳ CLAIM(run-exit-in-place)
  void exit() => throw UnimplementedError('GuideRunner.exit');
}
