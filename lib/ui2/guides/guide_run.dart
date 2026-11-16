// GUIDE RUN (live mode): the in-memory state machine of one guide being walked
// on the user's REAL screens. No widgets, no navigation, no storage.
//
//   AtStep(i)  --the next step's anchor resolves-->  AtStep(i+1)
//   AtStep(i)  --no anchor resolves-->               OffPath(last = i)
//   OffPath    --an anchor resolves again-->         AtStep(j)
//   AtStep(last) --the user taps the target-->       Finished
//   any        --exit()-->                           exited (terminal)
//
// CLAIM(run-memory-only): a run keeps its state in this object and writes
// nothing, anywhere (no database, no preferences, no files)
// [live_guide_run_test 'a run writes nothing'].
// CLAIM(run-match-furthest): after a frame the step shown is the HIGHEST index
// whose progress requirement is met and anchor resolves on the current page (steps can share a screen;
// the later anchor only appears once the user has done step 1)
// [live_guide_run_test 'matchStep takes the furthest step'].
//
// Mating parts: [GuideRunner] (guide_runner.dart) owns the run and the
// navigation around it; [LiveGuideOverlay] (live_guide_overlay.dart) feeds it
// the top page after every frame and draws its state.

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/widgets.dart' show Element, IndexedStack;

import '../../l10n/app_localizations.dart';
import '../app_shell.dart' show AppShell;
import 'tree_geometry.dart';
import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_target.dart';

sealed class GuideRunState {
  const GuideRunState();
}

/// The user is on the screen of step [index] (0-based).
final class GuideAtStep extends GuideRunState {
  final int index;
  const GuideAtStep(this.index);
}

/// The top page matches no step. [lastIndex] is the last step that did match
/// (what "Back to the guide" returns to); null when none ever has.
final class GuideOffPath extends GuideRunState {
  final int? lastIndex;
  const GuideOffPath(this.lastIndex);
}

/// The last step's target was tapped; the Done card shows.
final class GuideFinished extends GuideRunState {
  const GuideFinished();
}

class GuideRun extends ChangeNotifier {
  final Guide guide;

  /// The variant picked for the user's band; its steps are the run's steps.
  final GuideVariant variant;

  GuideRun({required this.guide, required this.variant});

  /// Starts at step 0 ([GuideAtStep]) until the first frame says otherwise.
  GuideRunState _state = const GuideAtStep(0);
  int? _lastIndex;
  final _tappedSteps = <int>{};
  final _matchedPages = <Element, int>{};
  @visibleForTesting
  int get rememberedPageCount => _matchedPages.length;

  bool _exited = false;
  GuideRunState get state => _state;

  /// True after [exit]; an exited run ignores every later call.
  bool get isExited => _exited;

  /// The step shown now, or null when off the path / finished / exited.
  GuideStep? get currentStep => !_exited && _state is GuideAtStep
      ? variant.steps[(_state as GuideAtStep).index] : null;

  /// The index of the HIGHEST step of [variant] whose anchor resolves
  /// ([TargetFound]) under [root] and whose tap requirement is met; null when none does.
  /// ↳ CLAIM(run-match-furthest)
  static int? matchStep(GuideVariant variant, Element root, AppLocalizations l, {Set<int> tappedSteps = const {}}) {
    // Shell labels name destinations even when those tabs are not selected.
    // Match the visible content, so a Sleep title cannot match the tab button
    // on every other screen (or become ambiguous with that button).
    final content = _contentOf(root);
    return [for (var i = 0; i < variant.steps.length; i++)
      if ((!variant.steps[i].requiresPreviousTap || tappedSteps.contains(i - 1)) &&
          _anchorMatches(variant.steps[i].anchor.resolve(content, l))) i].lastOrNull;
  }

  static bool _anchorMatches(TargetResolution resolution) =>
      resolution is TargetFound || resolution is TargetBehindAccordion;

  /// The app shell's tab stack under [root] (what the user is looking at), else [root].
  static Element _contentOf(Element root) {
    Element content = root;
    for (final e in onstageElements(root)) {
      if (e.widget is AppShell) {
        for (final child in onstageElements(e)) {
          if (child.widget is IndexedStack) content = child;
        }
      }
    }
    return content;
  }

  /// What a page is remembered by. The app shell is ONE page for every tab, so a tab
  /// is remembered by its own element: another tab that happens to print the same
  /// words as the target (Today has an "Alarm" tile) must not revive a step that
  /// was matched on the Sleep tab.
  static Element _memoryKey(Element root) {
    final content = _contentOf(root);
    if (identical(content, root)) return root;
    // Pre-order: the IndexedStack, its raw stack, then the one current tab.
    return onstageElements(content).skip(2).firstOrNull ?? root;
  }

  /// Called after every frame with the top PAGE's element, or null while a
  /// dialog / sheet / picker is on top (the run holds its state then: the
  /// user is acting on the step, not leaving it). Notifies only on change.
  void observe(Element? topPage, AppLocalizations l) {
    _matchedPages.removeWhere((page, _) => !page.mounted);
    if (_exited || _state is GuideFinished || topPage == null) return;
    final location = GuideNavigation.location(topPage);
    int? index;
    if (variant.steps.every((s) => s.node != null)) {
      final exact = [
        for (var i = 0; i < variant.steps.length; i++)
          if (variant.steps[i].node == location &&
              (!variant.steps[i].requiresPreviousTap || _tappedSteps.contains(i - 1))) i,
      ];
      if (exact.isNotEmpty) {
        final anchored = exact.where(
          (i) =>
              _anchorMatches(variant.steps[i].anchor.resolve(_contentOf(topPage), l)),
        );
        index =
            anchored.lastOrNull ??
            (exact.contains(_lastIndex) ? _lastIndex : exact.first);
      } else {
        final pending = _lastIndex ?? 0;
        final node = variant.steps[pending].node!;
        if (location != null && GuideNavigation.onPath(location, node)) {
          index = pending;
        }
      }
    } else {
      index = matchStep(variant, topPage, l, tappedSteps: _tappedSteps);
    }
    // Returning to an earlier branch cannot rewind the pending action. An
    // ancestor is still on the way to it; a sibling requires a route back. A
    // pending step with no node of its own has no path to be on, so it counts
    // as off it (a variant may mix node-backed and node-less steps).
    bool rewindRejected(int candidate) {
      final last = _lastIndex;
      if (last == null || candidate >= last) return false;
      final to = variant.steps[candidate].node;
      final from = variant.steps[last].node;
      if (to == null || to == from) return false;
      return from == null || location == null || !GuideNavigation.onPath(location, from);
    }
    if (index != null && rewindRejected(index)) index = null;
    // A reveal may dispose the anchor in a lazy list. Only restore a step
    // whose anchor was already observed on THIS page, with its action still
    // found. This also works when Back returns from a later step's route.
    final key = _memoryKey(topPage);
    final remembered = _matchedPages[key];
    if (index == null && remembered != null && !rewindRejected(remembered) &&
        _anchorMatches(variant.steps[remembered].target.resolve(topPage, l))) {
      index = remembered;
    }
    if (index != null) {
      _lastIndex = index;
      _matchedPages[key] = index;
      if (_state case GuideAtStep(index: final old) when old == index) return;
      _state = GuideAtStep(index);
    } else {
      if (_state is GuideOffPath) return;
      _state = GuideOffPath(_lastIndex);
    }
    notifyListeners();
  }

  /// The user tapped the highlighted target. On the last step: [GuideFinished].
  /// On any other step: no change (the next frame decides).
  void targetTapped() {
    if (_exited) return;
    if (_state case GuideAtStep(:final index)) _tappedSteps.add(index);
    if (_state case GuideAtStep(:final index) when index == variant.steps.length - 1) {
      _matchedPages.clear();
      _state = const GuideFinished();
      notifyListeners();
    }
  }

  /// Ends the run for good.
  void exit() {
    if (_exited) return;
    _exited = true;
    _matchedPages.clear();
    notifyListeners();
  }
}
