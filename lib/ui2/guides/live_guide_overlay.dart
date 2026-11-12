// LIVE GUIDE OVERLAY (live mode): draws a [GuideRun] over the user's own
// screens. It is one entry in the app's ROOT Overlay, above every route.
//
// After EVERY frame it
//   1. finds the top PAGE route's subtree ([topPageRoot]; null while a dialog,
//      sheet or picker is on top),
//   2. lets the run match a step by anchor ([GuideRun.observe]),
//   3. plans the skeleton over that subtree (the same [skeletonPlan] as
//      PR 1: keep = the step's target + alsoKeep + chrome) and paints it in the
//      overlay's own coordinates, progressively: whole sections fade to
//      skeleton from the top over [kGuideRevealDuration], then the outline and
//      the pill appear,
//   4. scrolls a lazy target into view ([revealTarget]) and shows the scroll
//      marker on `scrollThenTap` steps.
//
// Input: a tap on the target goes THROUGH to the real control (it does exactly
// what it always does, confirmation dialogs included); every other tap on the
// page is absorbed; the card's buttons work; system Back is untouched. While a
// dialog / sheet / picker is on top the overlay is inert and draws nothing, so
// the app's own dialog is fully usable.
//
// Semantics: the step card's caption is a live region; the target gets a proxy
// node "Guide target: <caption>" that performs the tap; covered content stays
// in the semantics tree (foreign semantics cannot be excluded).
//
// CLAIM(overlay-pass-through): the target's tap reaches the real control; other
// taps on the page do not [live_guide_overlay_test 'pointer rules'].
// CLAIM(overlay-yields-to-dialogs): with a dialog on top the overlay neither
// absorbs taps nor changes the run's state
// [live_guide_overlay_test 'a dialog on top is not leaving the path'].
// CLAIM(overlay-reveal): progress goes 0 -> 1 over [kGuideRevealDuration] per
// step; the outline and pill show only at 1
// [live_guide_overlay_test 'the reveal is progressive'].
//
// Mating parts: [GuideRunner] inserts/removes it; [GuideStepCard] is its card;
// guide_markers.dart holds the pill/outline rules shared with the review views.

import 'package:flutter/widgets.dart';

import '../skeleton/skeleton.dart';
import '../theme.dart' show Motion;
import 'guide_run.dart';

/// How long one step's skeleton takes to fade in, top to bottom.
const kGuideRevealDuration = Motion.reveal;

/// The subtree of the page route on top of [navigator], or null when the top
/// route is not a page (dialog, bottom sheet, picker) or has no built subtree.
Element? topPageRoot(NavigatorState navigator) => throw UnimplementedError('topPageRoot');

class LiveGuideOverlay extends StatefulWidget {
  final GuideRun run;

  /// The app's root Navigator: where the top page is looked for.
  final GlobalKey<NavigatorState> navigatorKey;

  /// "Exit" on the card.
  final VoidCallback onExit;

  /// "Back to the guide" on the off-path card.
  final VoidCallback onBackToGuide;

  const LiveGuideOverlay({
    super.key,
    required this.run,
    required this.navigatorKey,
    required this.onExit,
    required this.onBackToGuide,
  });

  static const skeletonKey = ValueKey('guide-live-skeleton');
  static const outlineKey = ValueKey('guide-live-outline');
  static const tapPillKey = ValueKey('guide-live-tap-pill');
  static const scrollMarkerKey = ValueKey('guide-live-scroll-marker');
  static const targetProxyKey = ValueKey('guide-live-target-proxy');

  @override
  State<LiveGuideOverlay> createState() => LiveGuideOverlayState();
}

class LiveGuideOverlayState extends State<LiveGuideOverlay> {
  /// The skeleton shapes painted right now, in the overlay's coordinates
  /// (empty before the first plan and while yielding).
  @visibleForTesting
  List<SkeletonShape> get paintedShapes => throw UnimplementedError('paintedShapes');

  /// The target's rect in the overlay's coordinates, or null when none.
  @visibleForTesting
  Rect? get targetRect => throw UnimplementedError('targetRect');

  /// 0..1: how much of the current step's skeleton is revealed.
  @visibleForTesting
  double get revealProgress => throw UnimplementedError('revealProgress');

  /// True while a dialog / sheet / picker is on top and the overlay is inert.
  @visibleForTesting
  bool get isYielding => throw UnimplementedError('isYielding');

  @override
  Widget build(BuildContext context) => throw UnimplementedError('LiveGuideOverlay.build');
}
