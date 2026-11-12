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
// whose anchor resolves on the current page (steps 1 and 2 can share a screen;
// the later anchor only appears once the user has done step 1)
// [live_guide_run_test 'matchStep takes the furthest step'].
//
// Mating parts: [GuideRunner] (guide_runner.dart) owns the run and the
// navigation around it; [LiveGuideOverlay] (live_guide_overlay.dart) feeds it
// the top page after every frame and draws its state.

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart' show Element;

import '../../l10n/app_localizations.dart';
import 'guide.dart';

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
  GuideRunState get state => throw UnimplementedError('GuideRun.state');

  /// True after [exit]; an exited run ignores every later call.
  bool get isExited => throw UnimplementedError('GuideRun.isExited');

  /// The step shown now, or null when off the path / finished / exited.
  GuideStep? get currentStep => throw UnimplementedError('GuideRun.currentStep');

  /// The index of the HIGHEST step of [variant] whose anchor resolves
  /// ([TargetFound]) under [root]; null when none does.
  /// ↳ CLAIM(run-match-furthest)
  static int? matchStep(GuideVariant variant, Element root, AppLocalizations l) =>
      throw UnimplementedError('GuideRun.matchStep');

  /// Called after every frame with the top PAGE's element, or null while a
  /// dialog / sheet / picker is on top (the run holds its state then: the
  /// user is acting on the step, not leaving it). Notifies only on change.
  void observe(Element? topPage, AppLocalizations l) => throw UnimplementedError('GuideRun.observe');

  /// The user tapped the highlighted target. On the last step: [GuideFinished].
  /// On any other step: no change (the next frame decides).
  void targetTapped() => throw UnimplementedError('GuideRun.targetTapped');

  /// Ends the run for good.
  void exit() => throw UnimplementedError('GuideRun.exit');
}
