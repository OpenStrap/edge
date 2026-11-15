import 'dart:math' as math;

// GUIDE MARKERS: the parts of a guide step that are drawn the same way on every
// renderer: the "tap" / "scroll" pill, where the pill goes, which content of the
// screen is still legible (and so must not be covered), the bold-quoted caption
// text and the footer card.
//
// Two renderers use them: the live overlay (live_guide_overlay.dart, shipped)
// and the review frame (test/support/guide_view.dart, review tooling only).
// Everything here is derived from a laid-out tree; nothing knows about a screen.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../skeleton/skeleton.dart';
import '../skeleton/unit_paint.dart' show isIconParagraph;
import '../theme.dart';
import '../grammar.dart' show ScreenTitle, NavBar;
import 'guide_motion.dart';
import 'tree_geometry.dart';

/// Gap between the target and its outline, in pixels.
const kGuideOutlineGap = 4.0;

/// The yellow of the outline and the pills.
const kGuideMarkerColor = C.yellow;

/// A small yellow pill with dark text (the "tap" label; the review views' "scroll" marker).
/// [leading] sits before the text (the live "tap" label's pointing hand).
class GuideMarkerPill extends StatelessWidget {
  final String text;
  final bool arrow;
  final Widget? leading;
  final Color color;
  const GuideMarkerPill(this.text, {super.key, this.arrow = false, this.leading, this.color = C.yellow});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: R.rPill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x2 + 2, vertical: S.x1 / 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: S.x1)],
              Flexible(child: Text(text, style: F.cap.copyWith(color: C.n900, fontWeight: FontWeight.w700))),
              if (arrow) ...[
                const SizedBox(width: S.x1),
                const Icon(LucideIcons.arrowRight, size: 14, color: C.n900),
              ],
            ],
          ),
        ),
      );
}

/// How far the tap hand travels toward the target at the peak of a nudge, in pixels.
const kGuideNudgeTravel = 4.0;

/// The small pointing hand beside the "tap" label. It nudges toward the target twice per
/// 1.6 s cycle of the shared guide clock ([guideNudgeValue]); the pill is ABOVE the target
/// when [side] is above, so the hand points down and nudges down, and the reverse below.
/// Reduced motion: no nudge. Only the render transform listens to the clock; nothing rebuilds.
/// CLAIM(guide-tap-hand) [guide_r4_test R4-3a, R4-3b, R4-5b].
class GuideTapHand extends StatelessWidget {
  final Animation<double> clock;
  final ValueListenable<GuidePillSide> side;
  static const handKey = ValueKey('guide-live-tap-hand');

  const GuideTapHand({super.key, required this.clock, required this.side});

  @override
  Widget build(BuildContext context) => _GuideHandTransform(clock: clock, side: side,
    enabled: Motion.enabled(context),
    child: const Icon(LucideIcons.pointer, key: handKey, size: 14, color: C.n900));
}

/// Listen in paint, outside LayoutBuilder's build scope: an AnimatedWidget below
/// that scope dirties the overlay's layout even with a repaint boundary.
/// CLAIM(marker-repaint-isolation) [guide_r3_routing_test off-path paint/build probe].
class _GuideHandTransform extends SingleChildRenderObjectWidget {
  final Animation<double> clock;
  final ValueListenable<GuidePillSide> side;
  final bool enabled;
  const _GuideHandTransform({required this.clock, required this.side, required this.enabled, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGuideHand(clock, side, enabled);
  @override
  void updateRenderObject(BuildContext context, _RenderGuideHand renderObject) => renderObject.update(clock, side, enabled);
}

class _RenderGuideHand extends RenderTransform {
  Animation<double> _clock;
  ValueListenable<GuidePillSide> _side;
  bool _enabled;
  _RenderGuideHand(this._clock, this._side, this._enabled)
      : super(transform: Matrix4.identity(), alignment: Alignment.center);

  void _listen(bool on) {
    if (on) { _clock.addListener(_tick); _side.addListener(_tick); }
    else { _clock.removeListener(_tick); _side.removeListener(_tick); }
  }

  void update(Animation<double> clock, ValueListenable<GuidePillSide> side, bool enabled) {
    if (attached) _listen(false);
    _clock = clock;
    _side = side;
    _enabled = enabled;
    if (attached) _listen(true);
    _tick();
  }

  @override
  void attach(PipelineOwner owner) { super.attach(owner); _listen(true); _tick(); }
  @override
  void detach() { _listen(false); super.detach(); }

  void _tick() {
    final above = _side.value == GuidePillSide.above;
    final nudge = _enabled ? guideNudgeValue(_clock.value) : 0.0;
    transform = Matrix4.translationValues(0, (above ? 1 : -1) * kGuideNudgeTravel * nudge, 0)
      ..rotateZ(above ? math.pi : 0);
  }
}

/// The mid-screen scroll indicator: a swipe hand, "scroll" and a chevron that points in the
/// direction to scroll (down when the target is below, up when it is above). Shown while the
/// target is out of view. The HAND nudges in the scroll direction on the shared clock and the
/// tap hand's curve (two nudges per 1.6 s cycle); the chevron stands still. Reduced motion: both
/// still. The hand sits in its own repaint boundary and only its render transform hears the clock.
/// CLAIM(guide-scroll-indicator) [guide_r5_test R5-2, guide_r4_test R4-2a, R4-2c, R4-5c].
class GuideScrollIndicator extends StatelessWidget {
  final String text;
  final Animation<double> clock;

  /// True when the target is above the screen: the hand nudges up and the chevron points up.
  final bool up;
  static const chevronKey = ValueKey('guide-live-scroll-chevron');
  static const handKey = ValueKey('guide-live-scroll-hand');

  const GuideScrollIndicator({super.key, required this.text, required this.clock, required this.up});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: C.yellow, borderRadius: R.rPill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(child: _GuideNudge(clock: clock, sign: up ? -1 : 1, enabled: Motion.enabled(context),
              child: const Icon(LucideIcons.hand, key: handKey, size: 16, color: C.n900))),
            const SizedBox(width: S.x1),
            Text(text, style: F.cap.copyWith(color: C.n900, fontWeight: FontWeight.w700)),
            const SizedBox(width: S.x1),
            Icon(up ? LucideIcons.chevronUp : LucideIcons.chevronDown, key: chevronKey, size: 16, color: C.n900),
          ],
        ),
      ),
    );
  }
}

/// Moves its child [kGuideNudgeTravel] pixels along y ([sign]: +1 down, -1 up) at the peak of the
/// shared nudge ([guideNudgeValue]). Listens to the clock in its render object, never in a build.
class _GuideNudge extends SingleChildRenderObjectWidget {
  final Animation<double> clock;
  final double sign;
  final bool enabled;
  const _GuideNudge({required this.clock, required this.sign, required this.enabled, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGuideNudge(clock, sign, enabled);
  @override
  void updateRenderObject(BuildContext context, _RenderGuideNudge renderObject) => renderObject.update(clock, sign, enabled);
}

class _RenderGuideNudge extends RenderTransform {
  Animation<double> _clock;
  double _sign;
  bool _enabled;
  _RenderGuideNudge(this._clock, this._sign, this._enabled) : super(transform: Matrix4.identity(), alignment: Alignment.center);

  void update(Animation<double> clock, double sign, bool enabled) {
    if (attached) _clock.removeListener(_tick);
    _clock = clock;
    _sign = sign;
    _enabled = enabled;
    if (attached) _clock.addListener(_tick);
    _tick();
  }

  @override
  void attach(PipelineOwner owner) { super.attach(owner); _clock.addListener(_tick); _tick(); }
  @override
  void detach() { _clock.removeListener(_tick); super.detach(); }

  void _tick() {
    final nudge = _enabled ? guideNudgeValue(_clock.value) : 0.0;
    transform = Matrix4.translationValues(0, _sign * kGuideNudgeTravel * nudge, 0);
  }
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
///
/// [textOut], when given, receives the text rects alone (paragraphs; icon glyphs only inside what is
/// kept): the label slides clear of those while it may lie over a plain background.
List<Rect> legibleContent(Element root, {required List<Rect> keep, List<Rect>? textOut}) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final plan = skeletonPlan(root, keep: keep, chrome: defaultSkeletonChrome(root));
  final found = <Rect>[], text = <Rect>[];
  for (final e in onstageElements(root)) {
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is RenderParagraph && ro.hasSize) {
      final length = ro.text.toPlainText().length;
      if (length == 0) continue;
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
      // An icon glyph is dimmed with the component that holds it: it is legible (and
      // the card must keep clear of it) only inside what the guide keeps.
      final icon = isIconParagraph(ro);
      for (final local in byLine.values) {
        final r = rectInRoot(ro, rootBox, local).intersect(visible);
        if (icon && !keep.any((k) => k.overlaps(r))) continue;
        found.add(r);
        text.add(r);
      }
      continue;
    }
    if (ro is RenderBox && ro.hasSize && paintsVisual(e.widget, ro)) {
      found.add(rectInRoot(ro, rootBox).intersect(visibleBoundsInRoot(ro, rootBox)));
    }
  }
  textOut?.addAll([for (final r in text) if (!r.isEmpty && !plan.any((s) => s.rect.overlaps(r))) r]);
  return [
    for (final r in found)
      if (!r.isEmpty && !plan.any((s) => s.rect.overlaps(r))) r,
  ];
}

/// Which side of the target a pill sits on.
enum GuidePillSide { above, below }

/// Places the "tap" pill next to the outline: ABOVE it, astride the top edge at its right
/// end, and below it (astride the bottom edge) only when above would leave [bounds] (off
/// screen, or under the title / NavBar). Legible text no longer moves it: the label has one
/// place, so it never jumps between steps or frames (owner, round 4).
///
/// [previous] is the side the same step's last frame chose. Coming from below, above is
/// taken again only with [kGuidePillBand] spare pixels of room, so a target scrolling
/// through the threshold does not flip the label back and forth. A new step passes null: the
/// same geometry always gives the same side.
///
/// CLAIM(pill-clear): the pill never covers the target: the outline is grown by
/// [kGuideOutlineGap] (4) past the target and the pill reaches 2 px into it
/// [guide_view_test 'GuidePillLayout'].
/// CLAIM(pill-above): above whenever it fits, else below; hysteresis with [previous]
/// [guide_r4_test R4-4a..R4-4e].
class GuidePillLayout extends SingleChildLayoutDelegate {
  final Rect outline;
  final Rect bounds;

  /// The side chosen on the previous frame of the same step (null on the first).
  final GuidePillSide? previous;
  const GuidePillLayout(this.outline, this.bounds, [this.previous]);

  /// Spare room above the target (px) that a pill coming from below needs before it goes back.
  static const kGuidePillBand = 12.0;

  // The default would hand the pill the whole frame as TIGHT constraints.
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  Rect _box(Size size, GuidePillSide side) {
    final x = (outline.right - size.width - S.x2).clamp(bounds.left, math.max(bounds.left, bounds.right - size.width)).toDouble();
    return Rect.fromLTWH(x, side == GuidePillSide.above ? outline.top - size.height + 2 : outline.bottom - 2, size.width, size.height);
  }

  bool _inside(Rect c) => c.left >= bounds.left - .01 && c.right <= bounds.right + .01 && c.top >= bounds.top - .01 && c.bottom <= bounds.bottom + .01;

  /// The side the pill of [size] takes, see the class doc.
  GuidePillSide sideFor(Size size) {
    final above = _box(size, GuidePillSide.above);
    final aboveFits = _inside(above);
    final belowFits = _inside(_box(size, GuidePillSide.below));
    if (previous == GuidePillSide.below && belowFits && !(aboveFits && above.top - bounds.top >= kGuidePillBand)) {
      return GuidePillSide.below;
    }
    if (aboveFits) return GuidePillSide.above;
    return belowFits ? GuidePillSide.below : GuidePillSide.above;
  }

  /// Where the pill goes (its box), see the class doc. When neither side fits the frame at
  /// all, it is above, pushed inside.
  Rect place(Size size) {
    final box = _box(size, sideFor(size));
    if (_inside(box)) return box;
    final y = box.top.clamp(bounds.top, math.max(bounds.top, bounds.bottom - size.height)).toDouble();
    return Rect.fromLTWH(box.left, y, size.width, size.height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => place(childSize).topLeft;

  @override
  bool shouldRelayout(GuidePillLayout old) =>
      old.outline != outline || old.bounds != bounds || old.previous != previous;
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

final _clockText = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');

/// A running timer is set in a big number; a chart's axis labels ("00:00", "12:00",
/// "24:00") are small and must not make the card they sit on count as live status
/// (on Day strain they kept the whole top card undimmed).
const _kTimerLineHeight = 24.0;

/// The page's live status lines (owner, finish scene): the topmost text line with
/// the line right under it (a screen's title and subtitle) and every clock-shaped
/// text (a running timer). The card and the paint keep clear of them. Rects are in
/// [root]'s coordinates.
List<Rect> liveStatusRects(Element root) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final lines = <(Rect, String, bool)>[];
  for (final e in onstageElements(root)) {
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is! RenderParagraph || !ro.hasSize) continue;
    final text = ro.text.toPlainText();
    if (text.isEmpty) continue;
    var card = false, scrolling = false, header = false;
    e.visitAncestorElements((a) {
      final w = a.widget;
      card |= isGuideCard(w);
      scrolling |= w is Scrollable;
      header |= w is ScreenTitle || w is NavBar || w.runtimeType.toString() == 'HeaderRows';
      return !identical(a, root);
    });
    final visible = visibleBoundsInRoot(ro, rootBox);
    final rect = rectInRoot(ro, rootBox).intersect(visible);
    if (!rect.isEmpty) lines.add((rect, text.trim(), !card && (header || !scrolling)));
  }
  final headers = lines.where((l) => l.$3);
  final top = headers.isEmpty ? double.negativeInfinity : headers.map((l) => l.$1.top).reduce(math.min);
  return [
    for (final (rect, text, header) in lines)
      if (header && rect.top < top + 28 || _clockText.hasMatch(text) && rect.height >= _kTimerLineHeight) rect,
  ];
}
