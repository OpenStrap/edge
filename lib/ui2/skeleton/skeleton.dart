// SKELETON OVERLAY (phase 1) — RED-PHASE STUBS ONLY. No behaviour yet.
//
// Turns the real, laid-out screen into skeleton except the guide's target.
// Card rule the implementation must rely on (lib/ui2/grammar.dart:225 `Surface`,
// :264 `Section`): a "section" is the OUTERMOST `Surface` or `Section` element
// under the root. Cards are found by widget type, because the render tree alone
// cannot tell a `Section` (title + card) from its parts.

import 'package:flutter/widgets.dart';

enum SkeletonKind {
  /// A card rect repainted in its own surface colour ([SkeletonShape.color]).
  surface,

  /// One per text line box.
  bar,

  /// One per chart / image / custom paint.
  block,
}

@immutable
class SkeletonShape {
  final SkeletonKind kind;

  /// In paint coordinates of the plan's root (origin = root's top-left).
  final Rect rect;

  /// Set for [SkeletonKind.surface] only: the card's own colour.
  final Color? color;

  /// 0-based index of the skeletonized unit (a card / `Section`, or one loose
  /// text paragraph) this shape belongs to. Ascends with the plan order and is
  /// contiguous: a plan with N units uses 0..N-1.
  final int section;

  const SkeletonShape({
    required this.kind,
    required this.rect,
    required this.section,
    this.color,
  });
}

/// PURE over an already laid-out subtree. Output order: unit by unit,
/// top-to-bottom; inside a unit, containers before what they contain, then by
/// (top, left). Shapes are clipped to the root's bounds.
List<SkeletonShape> skeletonPlan(
  Element root, {
  required List<Rect> keep,
  List<Rect> chrome = const [],
}) =>
    throw UnimplementedError();

/// The shapes `progress` (0..1, clamped) reveals: WHOLE units only,
/// `floor(progress * unitCount)` of them, from the top.
List<SkeletonShape> revealedShapes(List<SkeletonShape> plan, double progress) =>
    throw UnimplementedError();

/// A rounded placeholder line. Reusable for loading states. No animation.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// A rounded placeholder block (chart / image). No animation.
class SkeletonBlock extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBlock({super.key, this.width, required this.height});

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Wraps [child]; after it paints, paints [revealedShapes] of the plan.
/// Revealed (painted) units absorb pointer events; [keep] rects stay tappable.
class Skeletonize extends StatefulWidget {
  final Widget child;

  /// Resolved targets, in this widget's local coordinates.
  final List<Rect> keep;
  final List<Rect> chrome;
  final double progress;

  const Skeletonize({
    super.key,
    required this.child,
    this.keep = const [],
    this.chrome = const [],
    this.progress = 1,
  });

  @override
  State<Skeletonize> createState() => SkeletonizeState();
}

class SkeletonizeState extends State<Skeletonize> {
  /// The full plan as of the last paint (valid after the first frame).
  List<SkeletonShape> get shapes => throw UnimplementedError();

  /// The subset actually painted at the current `progress`.
  List<SkeletonShape> get paintedShapes => throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
