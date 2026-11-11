// SKELETON OVERLAY (phase 1) — RED-PHASE STUBS ONLY. No behaviour yet.
//
// Turns the real, laid-out screen into skeleton except the guide's target.
// Card rule the implementation must rely on (lib/ui2/grammar.dart:225 `Surface`,
// :264 `Section`): a "section" is the OUTERMOST `Surface` or `Section` element
// under the root. Cards are found by widget type, because the render tree alone
// cannot tell a `Section` (title + card) from its parts.

import 'package:flutter/widgets.dart';

import '../guides/guide_target.dart';

enum SkeletonKind {
  /// A card rect repainted in its own surface colour ([SkeletonShape.color]).
  surface,

  /// One per text line box.
  bar,

  /// One per chart / image / custom paint.
  block,

  /// An OPAQUE fill in the scaffold background colour, painted before the bar
  /// of loose text and of Section headings/actions (text that sits on the
  /// scaffold, not on a card), so no glyph pixel survives at a bar's rounded
  /// corners. Carries [SkeletonShape.color].
  erase,
}

@immutable
class SkeletonShape {
  final SkeletonKind kind;

  /// In paint coordinates of the plan's root (origin = root's top-left).
  final Rect rect;

  /// Set for [SkeletonKind.surface] (the card's own colour) and
  /// [SkeletonKind.erase] (the background colour) only.
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
/// top-to-bottom; inside a unit, containers before what they contain (an erase
/// before its bar), then by (top, left). Shapes are in the root's local space,
/// after applying every ancestor clip (viewports, ClipRect, the root bounds)
/// and transform between the root and the shape's render object; a shape whose
/// clipped rect is empty is dropped.
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

/// Resolver for the regions that must stay legible and interactive. Rects in
/// the root element's local space.
typedef SkeletonChromeResolver = List<Rect> Function(Element root);

/// The default: finds `ScreenTitle` and `NavBar` by widget type, and AppShell's
/// private tab bar by its runtime type (app_shell.dart:215), without editing
/// app_shell.dart.
List<Rect> defaultSkeletonChrome(Element root) => throw UnimplementedError();

/// Wraps [child]; after every layout it re-resolves [keep] / [alsoKeep] against
/// the LIVE tree and recomputes the plan; paints [revealedShapes]. Revealed
/// units absorb pointer events and are excluded from semantics; kept targets
/// and chrome stay tappable and keep their semantics.
///
/// A [keep] target that does not resolve (absent / ambiguous / not built)
/// yields an EMPTY plan - never cover a screen whose target cannot be found -
/// and the reason is in [SkeletonizeState.resolutions]. An unresolved
/// [alsoKeep] target is skipped.
class Skeletonize extends StatefulWidget {
  final Widget child;

  /// The targets the guide points at.
  final List<GuideTarget> keep;

  /// Extra units to leave readable (e.g. "Your zones" in step 3).
  final List<GuideTarget> alsoKeep;
  final SkeletonChromeResolver chrome;
  final double progress;

  const Skeletonize({
    super.key,
    required this.child,
    required this.keep,
    this.alsoKeep = const [],
    this.chrome = defaultSkeletonChrome,
    this.progress = 1,
  });

  @override
  State<Skeletonize> createState() => SkeletonizeState();
}

class SkeletonizeState extends State<Skeletonize> {
  /// The full plan as of the last layout (valid after the first frame).
  List<SkeletonShape> get shapes => throw UnimplementedError();

  /// The subset actually painted at the current `progress`.
  List<SkeletonShape> get paintedShapes => throw UnimplementedError();

  /// One resolution per [Skeletonize.keep] target, same order, as of the last
  /// layout.
  List<TargetResolution> get resolutions => throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
