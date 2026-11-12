// GUIDE MARKERS: the parts of a guide step that are drawn the same way on every
// renderer: the "tap" / "scroll" pill, where the pill goes, which content of the
// screen is still legible (and so must not be covered), the bold-quoted caption
// text and the footer card.
//
// Two renderers use them: the live overlay (live_guide_overlay.dart, shipped)
// and the review frame (test/support/guide_view.dart, review tooling only).
// Everything here is derived from a laid-out tree; nothing knows about a screen.

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../skeleton/skeleton.dart';
import '../theme.dart';
import 'tree_geometry.dart';

/// Gap between the target and its outline, in pixels.
const kGuideOutlineGap = 4.0;

/// The yellow of the outline and the pills.
const kGuideMarkerColor = C.yellow;

/// A small yellow pill with dark text (the "tap" / "scroll" markers).
class GuideMarkerPill extends StatelessWidget {
  final String text;
  final bool arrow;
  const GuideMarkerPill(this.text, {super.key, this.arrow = false});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: C.yellow, borderRadius: R.rPill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x2 + 2, vertical: S.x1 / 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, style: F.cap.copyWith(color: C.n900, fontWeight: FontWeight.w700)),
              if (arrow) ...[
                const SizedBox(width: S.x1),
                const Icon(LucideIcons.arrowRight, size: 14, color: C.n900),
              ],
            ],
          ),
        ),
      );
}

/// Everything under [root] that the step leaves readable and the tap pill must
/// not hide: every laid-out text line AND every visual (ring, chart, image;
/// [paintsVisual]) that no shape of the skeleton plan for [keep] covers (so
/// inside a kept unit or chrome). Rects are in [root]'s coordinates. The
/// target's own content is included: the pill stops 2 px inside the outline,
/// which is 4 px clear of the target, so it never constrains it.
///
/// ↳ CLAIM(pill-legible): "legible" is defined by the same [skeletonPlan] that
/// [Skeletonize] paints, so the two cannot disagree on what is covered
/// [guide_view_test 'the tap pill never covers legible text'; guide #1 step 1
/// 'pill overlaps no legible text or visual'].
@visibleForTesting
List<Rect> legibleContent(Element root, {required List<Rect> keep}) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final plan = skeletonPlan(root, keep: keep, chrome: defaultSkeletonChrome(root));
  final found = <Rect>[];
  visitOnstage(root, (e) {
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is RenderParagraph && ro.hasSize) {
      final length = ro.text.toPlainText().length;
      if (length == 0) return;
      final visible = visibleBoundsInRoot(ro, rootBox);
      final boxes = ro.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length));
      // One rect per line: boxes sharing a line (several spans) are merged.
      final byLine = <int, Rect>{};
      for (final b in boxes) {
        final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
        if (r.isEmpty) continue;
        final key = (r.top * 2).round();
        byLine[key] = byLine[key]?.expandToInclude(r) ?? r;
      }
      for (final local in byLine.values) {
        found.add(rectInRoot(ro, rootBox, local).intersect(visible));
      }
      return;
    }
    if (ro is RenderBox && ro.hasSize && paintsVisual(e.widget, ro)) {
      found.add(rectInRoot(ro, rootBox).intersect(visibleBoundsInRoot(ro, rootBox)));
    }
  });
  return [
    for (final r in found)
      if (!r.isEmpty && !plan.any((s) => s.rect.overlaps(r))) r,
  ];
}

/// Places the "tap" pill next to the outline. Order of preference:
///  1. beside it: to the LEFT, vertically centred on the outline;
///  2. above it, astride the top edge at its right end;
///  3. below it, astride the bottom edge at its right end.
/// A position is taken only when it is inside [bounds] and overlaps none of
/// [avoid] (the step's legible text lines). When none qualifies the one that
/// covers the least text is used (always inside [bounds]).
///
/// CLAIM(pill-clear): the pill never covers the target: the outline is grown by
/// [kGuideOutlineGap] (4) past the target and the pill reaches 2 px into it
/// [guide_view_test 'the tap pill sits beside the target'].
/// CLAIM(pill-order): left, then above, then below, skipping any position that
/// leaves the frame or touches legible text
/// [guide_view_test 'GuidePillLayout'].
class GuidePillLayout extends SingleChildLayoutDelegate {
  final Rect outline;
  final Rect bounds;
  final List<Rect> avoid;
  const GuidePillLayout(this.outline, this.bounds, [this.avoid = const []]);

  // The default would hand the pill the whole frame as TIGHT constraints.
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  /// The three candidate boxes for a pill of [size], in preference order, each
  /// only when it lies inside [bounds].
  List<Rect> candidates(Size size) {
    final rightEnd = (outline.right - size.width - S.x2).clamp(bounds.left, bounds.right - size.width).toDouble();
    final all = [
      Rect.fromLTWH(outline.left + 2 - size.width, outline.center.dy - size.height / 2, size.width, size.height),
      Rect.fromLTWH(rightEnd, outline.top - size.height + 2, size.width, size.height),
      Rect.fromLTWH(rightEnd, outline.bottom - 2, size.width, size.height),
    ];
    return [
      for (final c in all)
        if (c.left >= bounds.left - .01 && c.right <= bounds.right + .01 && c.top >= bounds.top - .01 && c.bottom <= bounds.bottom + .01) c,
    ];
  }

  static double _overlapArea(Rect a, Rect b) {
    final i = a.intersect(b);
    return i.width <= 0 || i.height <= 0 ? 0 : i.width * i.height;
  }

  /// Where the pill goes (its box), see the class doc.
  Rect place(Size size) {
    final fits = candidates(size);
    for (final c in fits) {
      if (!avoid.any((r) => r.overlaps(c))) return c;
    }
    if (fits.isNotEmpty) {
      // Nothing is free: cover the least text.
      Rect best = fits.first;
      var bestCover = double.infinity;
      for (final c in fits) {
        final cover = avoid.fold<double>(0, (sum, r) => sum + _overlapArea(r, c));
        if (cover < bestCover) {
          best = c;
          bestCover = cover;
        }
      }
      return best;
    }
    // No candidate fits the frame at all: above, pushed inside.
    final x = (outline.right - size.width - S.x2).clamp(bounds.left, bounds.right - size.width).toDouble();
    final y = (outline.top - size.height + 2).clamp(bounds.top, bounds.bottom - size.height).toDouble();
    return Rect.fromLTWH(x, y, size.width, size.height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => place(childSize).topLeft;

  @override
  bool shouldRelayout(GuidePillLayout old) =>
      old.outline != outline || old.bounds != bounds || !listEquals(old.avoid, avoid);
}

/// [text] with every `**quoted**` run in bold: the captions quote the app's own
/// labels, and the bold marks which words to look for on the screen. Plain
/// `Text` when there is nothing to bold.
Widget guideBoldQuoted(String text, TextStyle style) {
  if (!text.contains('**')) return Text(text, style: style);
  final parts = text.split('**');
  return Text.rich(
    TextSpan(
      style: style,
      children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].isNotEmpty)
            TextSpan(text: parts[i], style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null),
      ],
    ),
  );
}

/// A footer card ("Another way in", "Don't see X?").
class GuideFooterCard extends StatelessWidget {
  final String title, body;
  const GuideFooterCard({super.key, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: R.rLg,
        border: Border.all(color: p.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(S.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: F.head.copyWith(color: p.ink)),
            const SizedBox(height: S.x2),
            guideBoldQuoted(body, F.body.copyWith(color: p.ink2)),
          ],
        ),
      ),
    );
  }
}
