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

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../skeleton/skeleton.dart';
import '../theme.dart';
import 'guide.dart';
import 'guide_target.dart';

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
      setState(() => _resolution = found);
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
                    delegate: _PillLayout(outline, screen),
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

/// Places the "tap" pill astride the top edge of the outline, at its right end;
/// below the outline instead when there is no room above. Always inside
/// [bounds]. CLAIM(pill-clear): the pill never covers the target: the outline
/// is grown by [_kOutlineGap] (4) past the target and the pill reaches 2 px
/// into it [guide_view_test 'the tap pill sits beside the target'].
class _PillLayout extends SingleChildLayoutDelegate {
  final Rect outline;
  final Rect bounds;
  const _PillLayout(this.outline, this.bounds);

  // The default would hand the pill the whole frame as TIGHT constraints.
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (outline.right - childSize.width - S.x2).clamp(bounds.left, bounds.right - childSize.width);
    var y = outline.top - childSize.height + 2;
    if (y < bounds.top) y = outline.bottom - 2;
    return Offset(x.toDouble(), y.clamp(bounds.top, bounds.bottom - childSize.height).toDouble());
  }

  @override
  bool shouldRelayout(_PillLayout old) => old.outline != outline || old.bounds != bounds;
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
