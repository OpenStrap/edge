// The way into a tab. An aurora tile, the art, and one number.
//
// One widget, two uses: Workout's "start a session" and Wellness's "start a
// sitting". They are the same card with a different accent, different art
// and a different noun, so they are the same code — a second copy is how the
// two drift a corner radius apart and nobody notices for a month.
//
// Volt (DESIGN_OVERHAUL.md §6) made it an [AuroraTile] of the tab's hue: the
// tab's colour lives in its hero, not in its chrome. Every word on it is page
// ink, because ink is the one text colour solved on an aurora field, and the
// play mark is the volt circle. It sits in the list's gutter like every other
// card — a rounded tile run into the screen edge reads as a card that failed
// to fit — so the full-bleed special case its parents used to carry is gone.
//
// THREE THINGS THIS GOT WRONG THE FIRST TIME, all of which a rendered check
// caught and none of which a reading would have:
//
//   · Full bleed was tried twice and both were wrong: a negative
//     `Container.margin` asserts, and an [OverflowBox] inside a ListView takes
//     an unbounded height and blanked the whole tab on device. The card does
//     not bleed any more, and nothing here escapes its parent.
//   · The art was in a `Stack` UNDER the copy and the headline ellipsised to
//     "71 activit…". It is a `Row`: the copy takes the width that is left and
//     the art cannot reach it.
//   · The height was fixed at 190. At 2x text the play button clipped off the
//     bottom. It is a floor now, and the copy has no Spacer to need a bound.
//
// It is deliberately NOT in the gallery: every case there is laid out in a
// ~179 logical-px cell. `start_session_card_test.dart` renders it at a real
// phone width instead, and the design snapshots photograph it in its tab.

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
    required this.art,
    required this.accent,
    this.sub,
    this.artHeight = 126,
    this.onTap,
  });

  /// The overline — "START A SESSION".
  final String label;

  /// How many things are behind the tap, and what to call them. A number the
  /// screen can actually stand behind: the count of what the picker offers,
  /// never a total that includes things this tab cannot start.
  final int count;
  final String noun;

  /// The picture, from the [Art] slots — never an asset path. A slot whose
  /// file is missing draws nothing, so the card is still a tappable tile.
  final Art art;

  /// The tab's own colour: the hue of the aurora ground.
  final Color accent;

  /// The subline under the count, e.g. "Pick one and go". Nullable so the
  /// default copy can be localized in [build] rather than baked into a
  /// const-context default parameter value.
  final String? sub;

  /// The height of the ART, which is only true while the assets are cropped to
  /// their own alpha bounds. A picture exported with transparent padding
  /// renders smaller than its sibling at the same value here, and the
  /// temptation is to fix that with a bigger number — which scales the padding
  /// too and takes the extra width out of the copy. Crop the asset instead.
  final double artHeight;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final subText = sub ?? (l?.startCardDefaultSub ?? 'Pick one and go');
    final go = p.fill(C.volt);
    return AuroraTile(
      hue: accent,
      onTap: onTap,
      semanticLabel: label.toLowerCase(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: F.over.copyWith(color: p.ink)),
              const SizedBox(height: S.x8),
              Text('$count $noun',
                  style: F.t2.copyWith(color: p.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: S.x1),
              Text(subText,
                  style: F.cap.copyWith(color: p.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: S.x4),
              // A mark, not a second button: the whole tile is the tap.
              Container(
                width: S.x12 + S.x2,
                height: S.x12 + S.x2,
                decoration: BoxDecoration(color: go, shape: BoxShape.circle),
                child: Icon(LucideIcons.play, size: I.md, color: p.inkOn(go)),
              ),
            ]),
          ),
          // Decoration only: no semantics, no hit test.
          ExcludeSemantics(
            child: IgnorePointer(child: art.image(height: artHeight)),
          ),
        ],
      ),
    );
  }
}
