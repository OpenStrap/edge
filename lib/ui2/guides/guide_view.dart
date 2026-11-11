// GUIDE VIEWS (phase 2): the demo renderer of a [Guide].
//
// A step is the REAL screen, filled with demo data, laid out at phone size
// inside a device frame, skeletonized except the step's target, with a yellow
// outline + "tap" pill on the target and, when the step needs a scroll, a
// vertical "scroll" marker. Everything is derived from the laid-out tree:
// the screens are not edited and know nothing about guides.
//
// Mating parts: `Skeletonize` (../skeleton/skeleton.dart) covers the frame;
// [revealTarget] (guide_target.dart) scrolls it to the target and reports the
// rect the markers are placed from. Both read the screen at the same root.

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../skeleton/skeleton.dart';
import '../theme.dart';
import 'guide.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

/// Logical size the demo screen is laid out at inside the frame; the frame
/// scales it down to fit its width.
const kGuidePhoneSize = Size(390, 780);

/// Device bezel around the screen, in frame pixels.
const _kBezel = 7.0;

/// Gap between the target and its outline, in frame pixels.
const _kOutlineGap = 4.0;

class GuideStepView extends StatefulWidget {
  /// 1-based, shown in the caption badge.
  final int number;
  final GuideStep step;

  /// Rendered width of the phone frame.
  final double width;

  const GuideStepView({
    super.key,
    required this.number,
    required this.step,
    this.width = 280,
  });

  static const frameKey = ValueKey('guide-frame');
  static const captionKey = ValueKey('guide-caption');
  static const numberKey = ValueKey('guide-number');
  static const outlineKey = ValueKey('guide-outline');
  static const tapPillKey = ValueKey('guide-tap-pill');
  static const scrollMarkerKey = ValueKey('guide-scroll-marker');

  /// Shown INSTEAD of the frame when the target does not resolve.
  static const failureKey = ValueKey('guide-failure');

  @override
  State<GuideStepView> createState() => _GuideStepViewState();
}

class _GuideStepViewState extends State<GuideStepView> {
  /// The demo screen's own subtree: the root for target resolution.
  final _screenKey = GlobalKey();

  /// null while the target is being looked for (the frame shows, unmarked).
  TargetResolution? _resolution;

  /// Text lines of the screen that stay readable in this step (not covered by
  /// the skeleton), in the screen's unscaled coordinates:
  /// what the tap pill must not cover. Empty while the target is searched.
  List<Rect> _legibleLines = const [];
  int _revealRound = 0;

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(GuideStepView old) {
    super.didUpdateWidget(old);
    if (!identical(old.step, widget.step)) {
      _resolution = null;
      _legibleLines = const [];
      _reveal();
    }
  }

  /// After the frame has laid the screen out: scroll to the target (a no-op
  /// when it is already in view) and keep what was found. A later round
  /// supersedes an earlier one still in flight.
  void _reveal() {
    final round = ++_revealRound;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || round != _revealRound) return;
      final root = _screenKey.currentContext;
      if (root is! Element) return;
      final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
      final found = await revealTarget(root, widget.step.target, l);
      if (!mounted || round != _revealRound) return;
      // The same plan Skeletonize paints: same function, same keep rects, same
      // chrome, read from the tree after the scroll.
      final screenRoot = _screenKey.currentContext;
      final lines = switch ((screenRoot, found)) {
        (final Element screenElement, TargetFound(:final rect)) => legibleTextLines(screenElement, keep: [
            rect,
            for (final extra in widget.step.alsoKeep)
              if (extra.resolve(screenElement, l) case TargetFound(rect: final kept)) kept,
          ]),
        _ => const <Rect>[],
      };
      setState(() {
        _resolution = found;
        _legibleLines = lines;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    final p = P.of(context);
    final step = widget.step;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The caption comes first in tree (and so reading) order: a screen
          // reader says what to do before it walks the screen.
          _caption(p, step.caption(l)),
          const SizedBox(height: S.x3),
          switch (_resolution) {
            null => _frame(context, l, null),
            TargetFound(:final rect) => _frame(context, l, rect),
            TargetNotBuilt() || TargetAbsent() || TargetAmbiguous() => _failure(p, l),
          },
        ],
      ),
    );
  }

  Widget _caption(P p, String text) => Row(
        key: GuideStepView.captionKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: GuideStepView.numberKey,
            width: S.x8,
            height: S.x8,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: p.fill(C.red), shape: BoxShape.circle),
            child: Text('${widget.number}', style: F.head.copyWith(color: p.inkOnFill)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: S.x1),
              child: _boldQuoted(text, F.body.copyWith(color: p.ink)),
            ),
          ),
        ],
      );

  Widget _failure(P p, AppLocalizations l) => Container(
        key: GuideStepView.failureKey,
        width: widget.width,
        padding: const EdgeInsets.all(S.x4),
        decoration: BoxDecoration(color: p.card2, borderRadius: R.rLg),
        child: Text(l.guideStepUnavailable, style: F.body.copyWith(color: p.ink2)),
      );

  /// The phone frame. [target] is the resolved rect in the screen's own
  /// (unscaled) coordinates, or null while it is still being looked for.
  Widget _frame(BuildContext context, AppLocalizations l, Rect? target) {
    final step = widget.step;
    final screenWidth = widget.width - 2 * _kBezel;
    final scale = screenWidth / kGuidePhoneSize.width;
    final screenHeight = kGuidePhoneSize.height * scale;
    final screen = Rect.fromLTWH(_kBezel, _kBezel, screenWidth, screenHeight);

    // The target in frame pixels, and its outline: grown a little, never past
    // the screen (so outline and pill stay inside the frame).
    final outline = target == null
        ? null
        : Rect.fromLTWH(
            screen.left + target.left * scale,
            screen.top + target.top * scale,
            target.width * scale,
            target.height * scale,
          ).inflate(_kOutlineGap).intersect(screen);

    return SizedBox(
      key: GuideStepView.frameKey,
      width: widget.width,
      height: screenHeight + 2 * _kBezel,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(decoration: BoxDecoration(color: C.n900, borderRadius: R.rXl)),
          ),
          Positioned.fromRect(
            rect: screen,
            // The demo is a picture: nothing in it reacts to touch.
            child: AbsorbPointer(
              child: ClipRRect(
                borderRadius: R.rLg,
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: kGuidePhoneSize,
                    child: MediaQuery(
                      // The screen believes it is on a phone: no status-bar
                      // inset, no keyboard, 390 x 780.
                      data: MediaQuery.of(context).copyWith(
                        size: kGuidePhoneSize,
                        padding: EdgeInsets.zero,
                        viewPadding: EdgeInsets.zero,
                        viewInsets: EdgeInsets.zero,
                      ),
                      child: Skeletonize(
                        keep: [step.target],
                        alsoKeep: step.alsoKeep,
                        child: KeyedSubtree(key: _screenKey, child: Builder(builder: step.screen)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (outline != null) ...[
            Positioned.fromRect(
              rect: outline,
              child: const IgnorePointer(
                child: DecoratedBox(
                  key: GuideStepView.outlineKey,
                  decoration: BoxDecoration(
                    border: Border.fromBorderSide(BorderSide(color: C.yellow, width: 2.5)),
                    borderRadius: R.rMd,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: CustomSingleChildLayout(
                    delegate: GuidePillLayout(outline, screen, [
                      for (final r in _legibleLines)
                        Rect.fromLTWH(
                          screen.left + r.left * scale,
                          screen.top + r.top * scale,
                          r.width * scale,
                          r.height * scale,
                        ),
                    ]),
                    child: _pill(l.guideTapMarker, key: GuideStepView.tapPillKey),
                  ),
                ),
              ),
            ),
            if (step.action == GuideAction.scrollThenTap)
              Positioned(
                right: _kBezel + S.x1,
                top: screen.top + screen.height * .28,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    // Reads top-to-bottom, arrow pointing down.
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: _pill(l.guideScrollMarker, key: GuideStepView.scrollMarkerKey, arrow: true),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// A small yellow pill with dark text (the "tap" / "scroll" markers).
  Widget _pill(String text, {required Key key, bool arrow = false}) => DecoratedBox(
        key: key,
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

/// Every laid-out text line under [root] that the step leaves readable: not
/// covered by a shape of the skeleton plan for [keep] (so inside a kept unit or
/// chrome). Rects are in [root]'s coordinates. The target's own lines are
/// included: the pill stops 2 px inside the outline, which is 4 px clear of the
/// target, so they never constrain it. The tap pill avoids these (it would hide
/// text the reader is meant to read).
///
/// ↳ CLAIM(pill-legible): "legible" is defined by the same [skeletonPlan] that
/// [Skeletonize] paints, so the two cannot disagree on what is covered
/// [guide_view_test 'the tap pill never covers legible text'].
@visibleForTesting
List<Rect> legibleTextLines(Element root, {required List<Rect> keep}) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final plan = skeletonPlan(root, keep: keep, chrome: defaultSkeletonChrome(root));
  final lines = <Rect>[];
  visitOnstage(root, (e) {
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is! RenderParagraph || !ro.hasSize) return;
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
      final line = rectInRoot(ro, rootBox, local).intersect(visible);
      if (line.isEmpty) continue;
      if (plan.any((s) => s.rect.overlaps(line))) continue;
      lines.add(line);
    }
  });
  return lines;
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
/// [_kOutlineGap] (4) past the target and the pill reaches 2 px into it
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
Widget _boldQuoted(String text, TextStyle style) {
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

class GuideView extends StatelessWidget {
  final Guide guide;

  /// The user's band; null = unknown.
  final BandGeneration? band;

  const GuideView({super.key, required this.guide, this.band});

  /// Shown INSTEAD of the steps when the guide has no variant for [band].
  static const noVariantKey = ValueKey('guide-no-variant');

  /// Brand names: not translated.
  static String _bandName(BandGeneration b) => switch (b) {
        BandGeneration.whoop4 => 'WHOOP 4',
        BandGeneration.whoop5 => 'WHOOP 5',
      };

  /// Lay it in a scroll view: the steps stack taller than a phone.
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    final p = P.of(context);
    final head = <Widget>[
      Text(guide.title(l), style: F.t1.copyWith(color: p.ink)),
      if (guide.intro?.call(l) case final intro?) ...[
        const SizedBox(height: S.x2),
        Text(intro, style: F.body.copyWith(color: p.ink2)),
      ],
      const SizedBox(height: S.x6),
    ];
    return Padding(
      padding: const EdgeInsets.all(S.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...head,
          switch (guide.variantFor(band)) {
            GuideNoVariant(:final available) => Container(
                key: noVariantKey,
                padding: const EdgeInsets.all(S.x4),
                decoration: BoxDecoration(color: p.card2, borderRadius: R.rLg),
                child: Text(
                  l.guideNoVariantBody(available.isEmpty ? '-' : available.map(_bandName).join(' / ')),
                  style: F.body.copyWith(color: p.ink2),
                ),
              ),
            GuideVariantFound(:final variant) => Wrap(
                spacing: S.x6,
                runSpacing: S.x6,
                children: [
                  for (var i = 0; i < variant.steps.length; i++)
                    GuideStepView(number: i + 1, step: variant.steps[i]),
                ],
              ),
          },
          if (guide.footers.isNotEmpty) ...[
            const SizedBox(height: S.x6),
            Wrap(
              spacing: S.x4,
              runSpacing: S.x4,
              children: [
                for (final f in guide.footers)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _FooterCard(title: f.title(l), body: f.body(l)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A footer card ("Another way in", "Don't see X?").
class _FooterCard extends StatelessWidget {
  final String title, body;
  const _FooterCard({required this.title, required this.body});

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
            _boldQuoted(body, F.body.copyWith(color: p.ink2)),
          ],
        ),
      ),
    );
  }
}
