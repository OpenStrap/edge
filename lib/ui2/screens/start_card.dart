// The way into a tab. Full-bleed, a mascot, and one number.
//
// One widget, two uses: Workout's "start a session" and Wellness's "start a
// sitting". They are the same card with a different accent, a different
// mascot and a different noun, so they are the same code — a second copy is
// how the two drift a corner radius apart and nobody notices for a month.
//
// THREE THINGS THIS GOT WRONG THE FIRST TIME, all of which a rendered check
// caught and none of which a reading would have:
//
//   · Full bleed was tried twice and both were wrong. A negative
//     `Container.margin` asserts (`margin.isNonNegative`) and painted a
//     358x100000 overflow stripe. An [OverflowBox] then blanked the entire
//     tab on device: inside a ListView the cross axis is bounded but the MAIN
//     axis is not, and an OverflowBox handed an unbounded height takes it,
//     which takes the whole list down with it.
//     So the card no longer bleeds ITSELF. The LIST drops its side padding and
//     gives it back to every other child — the card is simply the one child
//     that does not get it. Layout stays ordinary and predictable, which is
//     what a hero card at the top of a scroll view has to be.
//   · The mascot was in a `Stack` UNDER the copy, at 176 px inside a 190 px
//     box with no clip. The two fought for the same pixels and the headline
//     ellipsised to "71 activit…". It is a `Row` now: the copy takes the width
//     that is left and the mascot cannot reach it.
//   · The height was fixed at 190. At 2x text the play button clipped off the
//     bottom. It is a floor now.
//
// It is deliberately NOT in the gallery: every case there is laid out in a
// ~179 logical-px cell, and a full-bleed card photographed in one shows the
// fixture squeezing it rather than the card. `start_session_card_test.dart`
// renders it at a real phone width instead, which is where those three defects
// actually became visible.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../ui2.dart';

class StartCard extends StatelessWidget {
  const StartCard({
    super.key,
    required this.label,
    required this.count,
    required this.noun,
    required this.asset,
    required this.accent,
    required this.deep,
    this.sub,
    this.mascotHeight = 126,
    this.onTap,
  });

  /// The overline — "START A SESSION".
  final String label;

  /// How many things are behind the tap, and what to call them. A number the
  /// screen can actually stand behind: the count of what the picker offers,
  /// never a total that includes things this tab cannot start.
  final int count;
  final String noun;

  /// Basename under `assets/images/`, e.g. `mascot_workout.png`. The 2.0x and
  /// 3.0x buckets are picked up by Flutter automatically.
  final String asset;

  /// The tab's own colour, and the darker end of the gradient.
  ///
  /// Two grounds rather than one: both mascots are CREAM, and a pale card
  /// swallows a cream character. So the light end goes deeper rather than
  /// lighter — the opposite of the usual instinct — and the dark end drops far
  /// enough that the mascot is the brightest thing on the card.
  final Color accent, deep;

  /// The subline under the count, e.g. "Pick one and go". Nullable so the
  /// default copy can be localized in [build] rather than baked into a
  /// const-context default parameter value.
  final String? sub;

  /// The height of the ART, which is only true while the assets are cropped to
  /// their own alpha bounds. A mascot exported with transparent padding renders
  /// smaller than its sibling at the same value here, and the temptation is to
  /// fix that with a bigger number — which scales the padding too and takes the
  /// extra width out of the copy. Crop the asset instead.
  final double mascotHeight;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final subText = sub ?? (l?.startCardDefaultSub ?? 'Pick one and go');
    // No side radius when bleeding — a rounded corner against the screen edge
    // reads as a card that failed to fit.
    final card = Pressable(
      onTap: onTap,
      semanticLabel: label.toLowerCase(),
      child: ClipRect(
        child: Container(
          // A FLOOR, not a fixed height, so the copy can grow.
          constraints: const BoxConstraints(minHeight: 190),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: p.dark
                    ? [
                        Color.lerp(C.n900, deep, .55)!,
                        Color.lerp(C.n900, accent, .70)!,
                      ]
                    : [
                        Color.lerp(accent, C.n900, .28)!,
                        p.fill(accent),
                      ]),
            boxShadow: p.el(3),
          ),
          // IntrinsicHeight: in a scrolling page the height is unbounded and
          // the Spacer below would assert; this gives the Column the height
          // its own copy needs (never under the 190 floor above).
          child: IntrinsicHeight(
           child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x2, S.x4),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: F.over.copyWith(
                                color: C.white.withValues(alpha: .75))),
                        const Spacer(),
                        Text('$count $noun',
                            style: F.t2.copyWith(color: C.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: S.x1),
                        Text(subText,
                            style: F.cap.copyWith(
                                color: C.white.withValues(alpha: .8)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: S.x3),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                              color: C.white, shape: BoxShape.circle),
                          child: Icon(LucideIcons.play,
                              size: 22, color: p.fill(accent)),
                        ),
                      ]),
                ),
              ),
              // Bottom right, standing on the base of the card. Decoration
              // only: no semantics, no hit test, and the one thing here allowed
              // to be cut off by the edge — which is what the ClipRect is for.
              ExcludeSemantics(
                child: IgnorePointer(
                  child: Image.asset('assets/images/$asset',
                      height: mascotHeight,
                      filterQuality: FilterQuality.medium),
                ),
              ),
            ],
           ),
          ),
        ),
      ),
    );

    return card;
  }
}
