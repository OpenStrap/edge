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
// [live_guide_runner_test 'a second start replaces the first';
// guide_exit_reentrancy_test].
//
// Mating parts: the app shell registers a [GuideShellLink] (attachShell) when
// it mounts and removes it when it goes; Help (help_screen.dart) and, later,
// the coach card call [start].

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'live_guide_overlay.dart';

import '../app_shell.dart' show ShellDomain;
import 'package:flutter/gestures.dart';
import '../grammar.dart' show Pressable, SubTabs;
import 'guide_navigation.dart';
import 'tree_geometry.dart';
import 'guide.dart';
import 'guide_dim.dart';
import 'guide_run.dart';
import 'guide_routes.dart';

/// What the app shell offers a run: its own tab selection and Settings. An
/// interface the shell's State implements (not a bag of closures): the heavy-calc
/// guard resolves method calls, not calls through function values.
abstract interface class GuideShellLink {
  /// Selects [tab] the way a deep link does (the notifier AppShell follows).
  void selectTab(ShellDomain tab);

  /// Pushes Settings on the root Navigator.
  Future<void> openSettings();
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

/// A route above the shell handled or refused Back. No new run was started.
final class GuideStartBlocked extends GuideStartResult {
  const GuideStartBlocked();
}

class GuideRunner extends ChangeNotifier {
  /// The key of the app's ROOT Navigator (MaterialApp.navigatorKey).
  final GlobalKey<NavigatorState> navigatorKey;

  final GuideRouteObserver routes;

  /// The plan the run's components draw from; the app root provides it through
  /// [GuideDimScope]. The overlay writes it on every plan; the components read it.
  final dim = GuideDimController();

  GuideRunner({required this.navigatorKey, GuideRouteObserver? routes})
      : routes = routes ?? GuideRouteObserver();

  /// The run in progress, or null.
  GuideRun? _run;
  GuideShellLink? _shell;
  OverlayEntry? _entry;
  /// Bumped by every [exit] (and so by every [start]). A [start] that awaits
  /// Back keeps the value it began with and stops once it is no longer current,
  /// so two overlapping starts never leave two overlays on the stack.
  int _startToken = 0;
  Future<void>? _backToGuideFuture;
  GuideRun? _backToGuideRun;
  GuideRun? get activeRun => _run;

  /// The shell registers itself on mount and unregisters on dispose. Detaching
  /// a link that is not the attached one is a no-op.
  void attachShell(GuideShellLink link) { _shell = link; }
  void detachShell(GuideShellLink link) {
    if (!identical(link, _shell)) return;
    _shell = null;
    final run = _run;
    // The shell detaches from dispose, while Flutter is finalizing the tree.
    // A microtask runs after that lock is released, but before the next frame
    // builds the overlay. A post-frame exit would leave it for an extra frame.
    scheduleMicrotask(() {
      if (_shell == null && identical(_run, run)) exit();
    });
  }

  /// Starts [guide] for [band] (null = unknown band, which gets only an "any"
  /// variant, see [Guide.variantFor]). See the file header for the steps.
  /// ↳ CLAIM(run-no-new-stack) ↳ CLAIM(run-one-at-a-time)
  Future<GuideStartResult> start(Guide guide, {required BandGeneration? band}) async {
    final choice = guide.variantFor(band);
    if (choice is GuideNoVariant) return GuideStartNoVariant(choice);
    final nav = navigatorKey.currentState;
    if (_shell == null || nav == null) return const GuideStartNoShell();
    // Exit listeners may synchronously start another run. That newer request
    // owns installation, just as it does across an awaited Back decision.
    final token = _startToken + 1;
    exit();
    if (token != _startToken) return const GuideStartBlocked();
    final shell = _shell;
    while (nav.canPop()) {
      final before = routes.topRoute;
      // maybePop invokes the screen's own refusal/cleanup handler. A handled
      // Back can return true without removing the route (PopScope, capture).
      final handled = await nav.maybePop();
      if (!nav.mounted || !identical(shell, _shell)) return const GuideStartNoShell();
      // A newer start or an exit took over while Back was being handled.
      if (token != _startToken) return const GuideStartBlocked();
      if (!handled || before?.isActive != false || identical(before, routes.topRoute)) return const GuideStartBlocked();
    }
    _selectStart(guide.start);
    final run = GuideRun(guide: guide, variant: (choice as GuideVariantFound).variant);
    _run = run;
    run.addListener(_runChanged);
    _entry = OverlayEntry(builder: (_) => LiveGuideOverlay(
      run: run, navigatorKey: navigatorKey, routes: routes, onExit: exit,
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
  ///
  /// Concurrent calls for the same run share one walk. The walk is tied to its
  /// run: a call for a newer run never gets an older run's walk back.
  Future<void> backToGuide() {
    final run = _run;
    final pending = _backToGuideFuture;
    if (pending != null && identical(_backToGuideRun, run)) return pending;
    _backToGuideRun = run;
    late final Future<void> walk;
    walk = _backToGuide().whenComplete(() {
      if (identical(_backToGuideFuture, walk)) {
        _backToGuideFuture = null;
        _backToGuideRun = null;
      }
    });
    return _backToGuideFuture = walk;
  }

  Future<void> _backToGuide() async {
    final run = _run;
    final nav = navigatorKey.currentState;
    if (run == null || nav == null) return;
    final l = AppLocalizations.of(nav.context);
    while (identical(_run, run) && nav.mounted) {
      // After a pop, the next page is current before the outgoing page has
      // finished leaving. Wait to match it before deciding to pop again.
      if (routes.isTransitioning) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      final page = routes.page;
      if (page != null && l != null) {
        run.observe(page, l);
        if (run.state is GuideAtStep) return;
      }
      if (run.state is GuideFinished) return;
      if (!nav.canPop()) {
        // Only an off-path run has a place to go back to; a finished run has none.
        if (run.state case GuideOffPath(:final lastIndex)) {
          await _walkHops(run, lastIndex ?? 0, l);
        }
        return;
      }
      final before = routes.topRoute;
      final handled = await nav.maybePop();
      if (!handled || before?.isActive != false || identical(before, routes.topRoute)) return;
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// The most hops one press of "Back to the guide" walks. The deepest route in the
  /// tree is a tab, its sub-tab and a page; more means the tree and the app disagree.
  static const _maxHops = 6;

  /// Walks the card's own hop list ([GuideRouteObserver.routeTo]: the retained sub-tab
  /// counts) in one go, so the "N taps back" the card shows is what one press does.
  /// Stops when a step matches, when a hop cannot be made by the runner (a pushed
  /// page), or when a hop changed nothing. If nothing moved the run, it selects the
  /// guide's start again. CLAIM(back-walks-all-hops) [guide_r3_routing_test 'R2'].
  Future<void> _walkHops(GuideRun run, int index, AppLocalizations? l) async {
    final node = run.variant.steps[index].node;
    // After every hop the walk waits for the screen to change and looks again: the card's
    // count is a forecast (the shell's tab selection can show another sub-tab than the one
    // parked), the next control only exists once the screen has changed.
    var moved = false;
    GuideHop? previous;
    for (var i = 0; node != null && i < _maxHops && identical(_run, run); i++) {
      final page = routes.page;
      final hop = routes.routeTo(node).firstOrNull;
      if (page == null || hop == null) break;
      // The same hop again means the last press changed nothing: stop, don't spin.
      if (previous != null && previous.node == hop.node && previous.kind == hop.kind) break;
      if (!_makeHop(hop, page)) break;
      previous = hop;
      moved = true;
      // One frame shows the new screen, the next lets the guide's overlay plan it (its
      // input layer must let the next control through before the next tap is made).
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      while (routes.isTransitioning && identical(_run, run)) {
        await WidgetsBinding.instance.endOfFrame;
      }
      final now = routes.page;
      if (now != null && l != null) run.observe(now, l);
      if (run.state is GuideAtStep) return;
    }
    if (moved || !identical(_run, run)) return;
    final tab = node == null ? null : GuideNavigation.tabIndex(node);
    if (tab != null && tab < ShellDomain.values.length) {
      _shell?.selectTab(ShellDomain.values[tab]);
    } else {
      _selectStart(run.guide.start);
    }
  }

  /// Does one hop with the app's own controls; false when it is not one the runner can make.
  bool _makeHop(GuideHop hop, Element page) {
    switch (hop.kind) {
      case GuideHopKind.subTab:
        // A real tap on the sub-tab's own control, as a user would make it: no closure of
        // the screen is called from here.
        final index = GuideNavigation.subTabIndex(hop.node);
        if (index == null) return false;
        for (final e in onstageElements(page)) {
          if (e.widget is! SubTabs) continue;
          final controls = onstageElements(e).where((c) => c.widget is Pressable && laidOutBox(c) != null).toList();
          return index < controls.length && _tap(controls[index], page);
        }
        return false;
      case GuideHopKind.tab || GuideHopKind.page:
        final tab = GuideNavigation.tabIndex(hop.node);
        if (tab == null || tab >= ShellDomain.values.length || _shell == null) return false;
        _shell!.selectTab(ShellDomain.values[tab]);
        return true;
      case GuideHopKind.back:
        return false;
    }
  }

  /// A pointer down and up at the visible centre of [control], if the tap would reach it.
  bool _tap(Element control, Element page) {
    final box = laidOutBox(control), root = laidOutBox(page);
    if (box == null || root == null || !control.mounted) return false;
    final visible = rectInRoot(box, root).intersect(visibleBoundsInRoot(box, root));
    if (visible.isEmpty) return false;
    final position = root.localToGlobal(visible.center);
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(control).viewId);
    if (!result.path.any((entry) => identical(entry.target, box))) return false;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -3, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -3, position: position));
    return true;
  }

  /// Ends the active run (no-op without one).
  /// ↳ CLAIM(run-exit-in-place)
  void exit() {
    _startToken++;
    final run = _run;
    if (run == null) return;
    final entry = _entry;
    _run = null;
    _entry = null;
    run.removeListener(_runChanged);
    // Release ownership before notifying: a listener may install a new entry.
    run.exit();
    entry?.remove();
    entry?.dispose();
    notifyListeners();
  }

  @override
  void dispose() {
    exit();
    dim.dispose();
    super.dispose();
  }
}
