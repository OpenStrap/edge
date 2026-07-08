// AiHero — the AI briefing/ask hero from the refs: a quietly elevated card
// with a whispered overline, the briefing line in confident type, and an
// optional "ask" input-look pill that invites conversation. Restrained: a
// faint tinted wash instead of a glow, one sparkle glyph, no shimmer loops.
//
//   AiHero(
//     overline: 'GOOD MORNING',
//     line: 'Solid recovery — a good day to push.',
//     hint: 'Ask about your day…',       // null hides the ask pill
//     busy: false,
//     onTap: openBreakdown,
//     onAsk: openChat,
//   )

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon, OsAppIcon, OsIcon;
import 'pressable.dart';

class AiHero extends StatelessWidget {
  final String overline;

  /// The one-line briefing. Null → graceful placeholder state.
  final String? line;

  /// Placeholder copy for the ask pill; null hides the pill.
  final String? hint;

  /// Quiet trailing call-to-action under the line ('Tap for the breakdown').
  final String? cta;

  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onAsk;

  const AiHero({
    super.key,
    required this.overline,
    required this.line,
    this.hint,
    this.cta,
    this.busy = false,
    this.onTap,
    this.onAsk,
  });

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark;
    final hasLine = line != null && line!.trim().isNotEmpty;
    final br = BorderRadius.circular(R.card);

    Widget card = Container(
      decoration: BoxDecoration(
        borderRadius: br,
        border: Elevation.border(2),
        boxShadow: Elevation.shadows(2),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              AppColors.accent.withValues(alpha: dark ? 0.10 : 0.06),
              Elevation.surfaceAt(2),
            ),
            Elevation.surfaceAt(2),
          ],
        ),
      ),
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                // Art carries its own padding: 2 + 28 ≈ the old 8 + 16 chip;
                // the busy spinner fills the same 28px box so layout is
                // stable across states.
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: busy
                    ? SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.onAccentSoft,
                            ),
                          ),
                        ),
                      )
                    : const OsAppIcon(OsIcon.ai, size: 28),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(overline.toUpperCase(), style: AppText.overline),
                    const SizedBox(height: Sp.x1),
                    Text(
                      hasLine
                          ? line!
                          : (busy
                                ? 'Writing your briefing…'
                                : 'Your morning briefing will appear here.'),
                      style: hasLine
                          ? AppText.title.copyWith(height: 1.3)
                          : AppText.bodySoft.copyWith(
                              color: AppColors.onSurfaceFaint,
                            ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (cta != null) ...[
                      const SizedBox(height: Sp.x1),
                      Text(cta!, style: AppText.captionMuted),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: Sp.x2),
                Padding(
                  padding: const EdgeInsets.only(top: Sp.x2),
                  child: AppIcon(
                    OsIcon.arrowRight,
                    size: 15,
                    color: AppColors.onSurfaceFaint,
                  ),
                ),
              ],
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: Sp.x3),
            Pressable(
              pressedScale: 0.98,
              onTap: onAsk,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x4,
                  vertical: Sp.x2 + 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.isDark
                      ? AppColors.surfaceSunk
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(R.pill),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hint!,
                        style: AppText.bodySoft.copyWith(
                          fontSize: 13.5,
                          color: AppColors.onSurfaceFaint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppColors.ink,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: AppIcon(
                          OsIcon.arrowRight,
                          size: 13,
                          color: AppColors.surface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap != null) {
      card = Pressable(onTap: onTap, borderRadius: br, child: card);
    }
    return card;
  }
}
