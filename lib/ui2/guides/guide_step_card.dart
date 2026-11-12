// GUIDE STEP CARD (live mode): the one card the overlay shows, in three states.
//
//   on a step : red step badge + caption (the app's own labels in bold),
//               progress dots (one per step), "Don't see it?" and "Exit";
//               "Don't see it?" expands IN PLACE to the guide's missing-target
//               footer and collapses again.
//   off path  : "You've left the path" + "Back to the guide" + "Exit".
//   done      : "Done" + the guide's other footers ("Another way in", notes) + "Exit".
//
// Placement: [placeGuideCard] puts it at the bottom, above the tab bar, and
// moves it to the top when the target (or its pill) or legible content would
// be under it.
//
// CLAIM(card-never-covers-target): the card's rect never intersects the
// target's outline or the tap pill, wherever the target is on screen
// [guide_step_card_test 'the card never covers the target'].
// CLAIM(card-live-region): the caption (and the off-path / done title) is a
// live region, so a screen reader announces it on every step change
// [guide_step_card_test 'the caption is a live region'].
//
// Mating parts: [LiveGuideOverlay] builds the model from a [GuideRun] and
// positions the card with [placeGuideCard].

import 'package:flutter/widgets.dart';

import 'guide.dart';

sealed class GuideCardModel {
  const GuideCardModel();
}

final class GuideCardOnStep extends GuideCardModel {
  /// 1-based.
  final int number;
  final int total;

  /// Already translated; `**quoted**` runs are the app's own labels (bold).
  final String caption;

  /// The guide's missing-target footer; null hides the "Don't see it?" link.
  final GuideFooter? missingHelp;
  const GuideCardOnStep({required this.number, required this.total, required this.caption, this.missingHelp});
}

final class GuideCardOffPath extends GuideCardModel {
  const GuideCardOffPath();
}

final class GuideCardDone extends GuideCardModel {
  /// [Guide.doneFooters].
  final List<GuideFooter> footers;
  const GuideCardDone(this.footers);
}

/// The progress dots are one [DecoratedBox] per step, keyed
/// [GuideStepCard.dotKey]; each has a [BoxDecoration] with a `color`, and the
/// current step's colour is the only one that differs.
///
/// "Don't see it?" is a button-role semantics node with an expanded state
/// (`hasExpandedState` / `isExpanded`); "Exit" is labelled `guideExitLabel`.
class GuideStepCard extends StatefulWidget {
  final GuideCardModel model;
  final VoidCallback onExit;

  /// Shown on the off-path state only.
  final VoidCallback? onBackToGuide;

  const GuideStepCard({super.key, required this.model, required this.onExit, this.onBackToGuide});

  static const cardKey = ValueKey('guide-card');
  static const badgeKey = ValueKey('guide-card-badge');
  static const captionKey = ValueKey('guide-card-caption');
  static const dotsKey = ValueKey('guide-card-dots');
  static ValueKey<String> dotKey(int index) => ValueKey('guide-card-dot-$index');
  static const dontSeeItKey = ValueKey('guide-card-dont-see-it');
  static const missingHelpKey = ValueKey('guide-card-missing-help');
  static const exitKey = ValueKey('guide-card-exit');
  static const offPathKey = ValueKey('guide-card-off-path');
  static const backToGuideKey = ValueKey('guide-card-back-to-guide');
  static const doneKey = ValueKey('guide-card-done');
  static ValueKey<String> footerKey(int index) => ValueKey('guide-card-footer-$index');

  @override
  State<GuideStepCard> createState() => _GuideStepCardState();
}

class _GuideStepCardState extends State<GuideStepCard> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError('GuideStepCard.build');
}

/// Margin between the card and the edge of [placeGuideCard]'s bounds.
const kGuideCardGap = 12.0;

/// Where the card goes: horizontally centred in [bounds]; vertically at the
/// bottom (`bounds.bottom - kGuideCardGap - height`) or at the top
/// (`bounds.top + kGuideCardGap`).
///
///  * [bounds]: the area the card may use (the screen between the top chrome
///    and the tab bar's top edge), so "bottom" is always above the tab bar.
///  * [keepClear]: the target's outline and its pill. The card NEVER overlaps
///    these when either side can avoid them.
///  * [avoid]: legible content (see [legibleContent]); the card avoids it like
///    the pill does, covering the least when it cannot be avoided.
///
/// Order: bottom if it is clear of [keepClear] and [avoid]; else top if clear;
/// else the side that clears [keepClear] and covers the least of [avoid]; if
/// both sides overlap [keepClear] (a card taller than the room), the side that
/// overlaps it least.
/// ↳ CLAIM(card-never-covers-target)
Rect placeGuideCard({
  required Rect bounds,
  required Size cardSize,
  required List<Rect> keepClear,
  List<Rect> avoid = const [],
}) =>
    throw UnimplementedError('placeGuideCard');
