// RecapCard + MedalCard — the "weekly recap" and "achievement medal"
// compositions from the refs.
//
//  • [RecapCard] — a headline period recap: title, one highlight sentence in
//    a soft banner, a big average figure, and a quiet bar strip of the week.
//    The whole card taps through to the full recap screen.
//  • [MedalCard] — an inverted (ink) achievement card with an engraved medal
//    disc: personal records, streak milestones. Restrained metal, no confetti.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/charts.dart' show MiniBars;
import '../kit/kit.dart' show AppIcon, OsIcon;
import 'bento.dart';
import 'big_stat.dart';

class RecapCard extends StatelessWidget {
  /// 'Weekly recap', 'January'…
  final String title;

  /// One highlight sentence ('You slept 40 min more than usual').
  final String? highlight;

  /// The headline figure ('7h 12m', '11 840').
  final String? value;
  final String? unit;

  /// Label under the value ('daily average').
  final String? caption;

  /// A small bar strip (e.g. 7 daily values; nulls = gaps).
  final List<double?>? bars;

  final Color? accent;
  final VoidCallback? onTap;

  const RecapCard({
    super.key,
    required this.title,
    this.highlight,
    this.value,
    this.unit,
    this.caption,
    this.bars,
    this.accent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? AppColors.accent;
    final barsClean = bars?.whereType<double>().toList() ?? const <double>[];
    return BentoTile(
      tone: BentoTone.paper,
      accent: a,
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            title,
            trailing: onTap == null
                ? null
                : AppIcon(OsIcon.arrowRight, size: 14, color: AppColors.inkMuted),
          ),
          if (highlight != null) ...[
            const SizedBox(height: Sp.x3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x3,
                vertical: Sp.x2 + 2,
              ),
              decoration: BoxDecoration(
                color: a.withValues(alpha: AppColors.isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(R.chip),
              ),
              child: Text(
                highlight!,
                style: AppText.caption.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (value != null) ...[
            const SizedBox(height: Sp.x3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: BigStat(
                    value: value,
                    unit: unit,
                    caption: caption,
                    size: BigStatSize.md,
                  ),
                ),
                if (barsClean.length >= 2) ...[
                  const SizedBox(width: Sp.x3),
                  SizedBox(
                    width: 96,
                    child: MiniBars(barsClean, color: a, height: 34),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// An inverted achievement card with an engraved medal disc.
class MedalCard extends StatelessWidget {
  /// Engraving on the medal ('5K', '30d', 'PR').
  final String medal;

  /// 'Personal record', 'Achievement'…
  final String overline;

  /// 'Fastest 5k — 24:31'.
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const MedalCard({
    super.key,
    required this.medal,
    required this.title,
    this.overline = 'Achievement',
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BentoTile(
      tone: BentoTone.ink,
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      child: Row(
        children: [
          _MedalDisc(medal),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  overline.toUpperCase(),
                  style: AppText.overline.copyWith(
                    color: AppColors.onNightSoft,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  title,
                  style: AppText.title.copyWith(color: AppColors.onNight),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppText.caption.copyWith(
                      color: AppColors.onNightSoft,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null)
            AppIcon(OsIcon.arrowRight, size: 15, color: AppColors.onNightSoft),
        ],
      ),
    );
  }
}

class _MedalDisc extends StatelessWidget {
  final String text;
  const _MedalDisc(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD8D4CC), Color(0xFF908B82), Color(0xFFC5C0B7)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFB9B4AA), Color(0xFF7E7A72)],
          ),
        ),
        child: Center(
          child: Text(
            text,
            style: AppText.metricSm.copyWith(
              fontSize: 16,
              color: const Color(0xFF2E2B26),
              letterSpacing: -0.2,
            ),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}
