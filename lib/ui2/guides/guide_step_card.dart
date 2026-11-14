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

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';
import '../grammar.dart' show Pressable;
import 'guide_markers.dart';

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
  bool _expanded = false;

  @override
  void didUpdateWidget(GuideStepCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.model;
    final now = widget.model;
    if (old is! GuideCardOnStep || now is! GuideCardOnStep || old.number != now.number || old.caption != now.caption) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final l = AppLocalizations.of(context)!;
    Widget title(String text) => Semantics(
      container: true, liveRegion: true, child: Text(text, style: F.head.copyWith(color: p.ink)),
    );
    Widget footer(GuideFooter f, Key key) => Padding(
      key: key, padding: const EdgeInsets.only(top: S.x2),
      child: GuideFooterCard(title: f.title(l), body: f.body(l)),
    );
    final model = widget.model;
    final content = <Widget>[];
    switch (model) {
      case GuideCardOnStep():
        content.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DecoratedBox(
            key: GuideStepCard.badgeKey,
            decoration: BoxDecoration(color: p.fill(C.red), borderRadius: R.rPill),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
              child: Text('${model.number}', style: F.body.copyWith(color: p.inkOnFill, fontWeight: FontWeight.w700))),
          ),
          const SizedBox(width: S.x2),
          Expanded(child: Semantics(
            key: GuideStepCard.captionKey, container: true, liveRegion: true,
            child: guideBoldQuoted(model.caption, F.body.copyWith(color: p.ink)),
          )),
        ]));
        content.add(const SizedBox(height: S.x2));
        content.add(Semantics(
          key: GuideStepCard.dotsKey, container: true, label: l.guideStepOf('${model.number}', '${model.total}'),
          child: ExcludeSemantics(child: Wrap(spacing: S.x1, runSpacing: S.x1, children: [
            for (var i = 0; i < model.total; i++) DecoratedBox(
              key: GuideStepCard.dotKey(i),
              decoration: BoxDecoration(color: i == model.number - 1 ? C.red : p.line, borderRadius: R.rPill),
              child: const SizedBox(width: S.x2, height: S.x2),
            ),
          ])),
        ));
        if (_expanded && model.missingHelp != null) content.add(footer(model.missingHelp!, GuideStepCard.missingHelpKey));
      case GuideCardOffPath():
        content.add(Column(key: GuideStepCard.offPathKey, crossAxisAlignment: CrossAxisAlignment.start, children: [
          title(l.guideOffPathTitle), const SizedBox(height: S.x1),
          Text(l.guideOffPathBody, style: F.body.copyWith(color: p.ink2)),
        ]));
      case GuideCardDone():
        content.add(Column(key: GuideStepCard.doneKey, crossAxisAlignment: CrossAxisAlignment.start, children: [
          title(l.guideDoneTitle), const SizedBox(height: S.x1),
          Text(l.guideDoneBody, style: F.body.copyWith(color: p.ink2)),
        ]));
        for (var i = 0; i < model.footers.length; i++) {
          content.add(footer(model.footers[i], GuideStepCard.footerKey(i)));
        }
    }
    final actions = <Widget>[];
    if (model is GuideCardOnStep && model.missingHelp != null) {
      actions.add(Flexible(child: Semantics(
        key: GuideStepCard.dontSeeItKey, container: true, button: true, expanded: _expanded,
        child: Pressable(onTap: () => setState(() => _expanded = !_expanded),
          child: Text(l.guideDontSeeIt, style: F.cap.copyWith(color: p.on(C.blue)))),
      )));
    }
    if (model is GuideCardOffPath && widget.onBackToGuide != null) {
      actions.add(Flexible(child: Pressable(key: GuideStepCard.backToGuideKey,
        onTap: widget.onBackToGuide, child: Text(l.guideBackToGuide, style: F.cap.copyWith(color: p.on(C.blue))))));
    }
    actions.add(Semantics(container: true, label: l.guideExitLabel, button: true, onTap: widget.onExit,
      child: ExcludeSemantics(child: Pressable(key: GuideStepCard.exitKey, onTap: widget.onExit,
        child: Text(l.guideExit, style: F.cap.copyWith(color: p.ink2))))));
    return Material(
      key: GuideStepCard.cardKey, color: p.card, borderRadius: R.rLg,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: R.rLg),
        child: Padding(padding: const EdgeInsets.all(S.x4),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Flexible(fit: FlexFit.loose, child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: content),
            )),
            const SizedBox(height: S.x1),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: actions),
          ])),
      ),
    );
  }
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
}) {
  final width = math.min(cardSize.width, bounds.width);
  final height = math.min(cardSize.height, bounds.height);
  final x = bounds.center.dx - width / 2;
  final top = Rect.fromLTWH(x, math.min(bounds.top + kGuideCardGap, bounds.bottom - height), width, height);
  final bottom = Rect.fromLTWH(x, math.max(bounds.top, bounds.bottom - kGuideCardGap - height), width, height);
  double overlap(Rect candidate, List<Rect> rects) => rects.fold(0, (sum, rect) {
    final intersection = candidate.intersect(rect);
    return sum + (intersection.isEmpty ? 0 : intersection.width * intersection.height);
  });
  final bottomKeep = overlap(bottom, keepClear), topKeep = overlap(top, keepClear);
  if (bottomKeep < topKeep) return bottom;
  if (topKeep < bottomKeep) return top;
  return overlap(top, avoid) < overlap(bottom, avoid) ? top : bottom;
}
