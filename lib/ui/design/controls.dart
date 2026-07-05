// Design-system controls — SegmentedControl (day/week/month), StatusChip,
// PrBadge, ProgressPill, and the InfoDot (i) affordance that keeps secondary
// text OFF the main view (it opens an InfoSheet instead).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'info_sheet.dart';

/// Segmented pill control with a sliding ink thumb. Like the kit's [SegToggle]
/// but with equal-width segments that can stretch full-width ([expanded]) —
/// the day/week/month/6M switcher of the reference apps.
class SegmentedControl extends StatelessWidget {
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  /// Stretch to the parent's width with equal-width segments.
  final bool expanded;

  const SegmentedControl({
    super.key,
    required this.options,
    required this.index,
    required this.onChanged,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    assert(options.isNotEmpty);
    final n = options.length;
    final control = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Stack(
        children: [
          // Sliding thumb — one segment wide, eased to the selection.
          AnimatedAlign(
            duration: Motion.med,
            curve: Motion.emphatic,
            alignment: Alignment(
              n == 1 ? 0 : -1 + 2 * (index.clamp(0, n - 1) / (n - 1)),
              0,
            ),
            child: FractionallySizedBox(
              widthFactor: 1 / n,
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(R.pill),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (i != index) HapticFeedback.selectionClick();
                      onChanged(i);
                    },
                    child: SizedBox(
                      height: 34,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.fast,
                          style: AppText.label.copyWith(
                            // Thumb is ink → contrast with surface;
                            // unselected labels stay soft.
                            color: i == index
                                ? AppColors.surface
                                : AppColors.inkSoft,
                            fontWeight: FontWeight.w800,
                          ),
                          child: Text(
                            options[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    if (expanded) return control;
    // Shrink-wrap: give each segment an intrinsic-ish width via a Row cap.
    return IntrinsicWidth(child: control);
  }
}

/// Tone vocabulary for [StatusChip].
enum ChipTone { neutral, accent, positive, warn, critical }

/// A small labelled chip — soft tint fill + strong ink, optional leading icon.
/// The generic sibling of the honesty [Tag] (est/beta/rel), for statuses like
/// "Synced", "In zone 3", "Low battery".
class StatusChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final ChipTone tone;
  const StatusChip(
    this.text, {
    super.key,
    this.icon,
    this.tone = ChipTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      ChipTone.neutral => (AppColors.surfaceAlt, AppColors.inkSoft),
      ChipTone.accent => (AppColors.accentSoft, AppColors.onAccentSoft),
      ChipTone.positive => (AppColors.positiveSoft, AppColors.positive),
      ChipTone.warn => (AppColors.warnSoft, AppColors.warn),
      ChipTone.critical => (AppColors.criticalSoft, AppColors.critical),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2 + 2, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Personal-record pill — ember fill, one celebratory shimmer pass on build.
class PrBadge extends StatelessWidget {
  final String text;
  const PrBadge(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(R.pill),
            boxShadow: AppColors.isDark ? const [] : Shadows.coral,
          ),
          child: Text(
            text.toUpperCase(),
            style: AppText.overline.copyWith(
              color: Colors.white,
              fontSize: 10,
              letterSpacing: 1.2,
            ),
          ),
        )
        .animate()
        .scaleXY(
          begin: 0.8,
          end: 1,
          duration: Motion.springy.d,
          curve: Motion.springy.c,
        )
        .shimmer(
          delay: Motion.springy.d,
          duration: const Duration(milliseconds: 800),
          color: Colors.white.withValues(alpha: 0.5),
        );
  }
}

/// Rounded progress bar with an animated fill and an optional inline label —
/// goals, baseline fill, storage.
class ProgressPill extends StatelessWidget {
  /// 0..1 fill (clamped; NaN → 0).
  final double value;
  final Color? color;
  final double height;

  /// Optional label drawn to the left of the pill.
  final String? label;

  const ProgressPill(
    this.value, {
    super.key,
    this.color,
    this.height = 10,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final c = color ?? AppColors.accent;
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(R.pill),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: AppColors.surfaceAlt)),
            TweenAnimationBuilder<double>(
              duration: Motion.slow,
              curve: Motion.emphatic,
              tween: Tween(begin: 0, end: v),
              builder: (_, t, _) => FractionallySizedBox(
                widthFactor: t.clamp(0.001, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(R.pill),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (label == null) return bar;
    return Row(
      children: [
        Text(label!, style: AppText.caption),
        const SizedBox(width: Sp.x3),
        Expanded(child: bar),
      ],
    );
  }
}

/// The (i) affordance — a small, quiet circle that opens an [InfoSheet] with
/// the explanatory copy the main view deliberately doesn't show. 40px hit
/// target around a 18px glyph so it never dominates the card.
class InfoDot extends StatelessWidget {
  final String title;
  final String? body;
  final List<String> bullets;
  final String? methodNote;

  /// Override the default sheet-opening behaviour.
  final VoidCallback? onTap;

  const InfoDot({
    super.key,
    required this.title,
    this.body,
    this.bullets = const [],
    this.methodNote,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      radius: 20,
      onTap:
          onTap ??
          () {
            HapticFeedback.selectionClick();
            showInfoSheet(
              context,
              title: title,
              body: body,
              bullets: bullets,
              methodNote: methodNote,
            );
          },
      child: Padding(
        padding: const EdgeInsets.all(Sp.x2 + 3),
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.inkMuted, width: 1.3),
          ),
          child: Center(
            child: Text(
              'i',
              style: AppText.caption.copyWith(
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w800,
                color: AppColors.inkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
