// GUIDE REVIEW VIEWS (test tooling, never shipped): the demo renderer of a [Guide].
//
// The shipped app walks the user's REAL screens live (lib/ui2/guides/
// live_guide_overlay.dart). This file renders the same steps on demo data
// (test/support/guide_demo_data.dart) for the owner's sign-off images and for
// the frame/marker tests; it shares the marker rules with the overlay through
// lib/ui2/guides/guide_markers.dart.
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

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_markers.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'guide_demo_screens.dart';

/// Logical size the demo screen is laid out at inside the frame; the frame
/// scales it down to fit its width.
const kGuidePhoneSize = Size(390, 780);

/// Device bezel around the screen, in frame pixels.
const _kBezel = 7.0;

class GuideStepView extends StatefulWidget {
  /// 1-based, shown in the caption badge.
  final int number;
  final GuideStep step;

  /// Rendered width of the phone frame.
  final double width;

  /// The demo screen of this step; defaults to the one registered for
  /// `step.id` in [kGuideDemoScreens].
  final WidgetBuilder? screen;

  const GuideStepView({
    super.key,
    required this.number,
    required this.step,
    this.width = 280,
    this.screen,
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

  /// Text lines and visuals of the screen that stay readable in this step (not
  /// covered by the skeleton), in the screen's unscaled coordinates:
  /// what the tap pill must not cover. Empty while the target is searched.
  List<Rect> _legible = const [];
  int _revealRound = 0;

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(GuideStepView old) {
    super.didUpdateWidget(old);
    // By id, not identity: guides are built by getters, so a parent rebuild
    // (theme, locale, MediaQuery) hands over an equal step in a new object, and
    // resetting on that would drop the markers and jump the demo's scroll.
    if (old.step.id != widget.step.id) {
      _resolution = null;
      _legible = const [];
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
      setState(() {
        _resolution = found;
        _legible = _legibleFor(found, l);
      });
      _track(round);
    });
  }

  /// The same plan Skeletonize paints: same function, same keep rects, same
  /// chrome, read from the tree as it is laid out now.
  List<Rect> _legibleFor(TargetResolution found, AppLocalizations l) =>
      switch ((_screenKey.currentContext, found)) {
        (final Element screenElement, TargetFound(:final rect)) => legibleContent(screenElement, keep: [
            rect,
            for (final extra in widget.step.alsoKeep)
              if (extra.resolve(screenElement, l) case TargetFound(rect: final kept)) kept,
          ]),
        _ => const <Rect>[],
      };

  /// Skeletonize re-plans after every layout; the markers must too. The screen
  /// can move under them without this widget rebuilding (Home inserts and
  /// removes its sync-status card above the rings, home_screen.dart:2059).
  /// After each drawn frame, re-resolve without scrolling and update only when
  /// something moved, so an idle guide schedules no work and the loop settles.
  void _track(int round) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || round != _revealRound) return;
      final root = _screenKey.currentContext;
      if (root is Element) {
        final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
        final now = widget.step.target.resolve(root, l);
        final lines = _legibleFor(now, l);
        final moved = switch ((now, _resolution)) {
          (TargetFound(rect: final a), TargetFound(rect: final b)) => a != b,
          _ => now.runtimeType != _resolution.runtimeType,
        };
        if (moved || !listEquals(lines, _legible)) {
          setState(() {
            _resolution = now;
            _legible = lines;
          });
        }
      }
      _track(round);
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
              child: guideBoldQuoted(text, F.body.copyWith(color: p.ink)),
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
          ).inflate(kGuideOutlineGap).intersect(screen);

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
                        child: KeyedSubtree(key: _screenKey, child: Builder(builder: widget.screen ?? demoScreenFor(step))),
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
                      for (final r in _legible)
                        Rect.fromLTWH(
                          screen.left + r.left * scale,
                          screen.top + r.top * scale,
                          r.width * scale,
                          r.height * scale,
                        ),
                    ]),
                    child: KeyedSubtree(key: GuideStepView.tapPillKey, child: GuideMarkerPill(l.guideTapMarker)),
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
                      child: KeyedSubtree(key: GuideStepView.scrollMarkerKey, child: GuideMarkerPill(l.guideScrollMarker, arrow: true)),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

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
                    child: GuideFooterCard(title: f.title(l), body: f.body(l)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

