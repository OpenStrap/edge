// StateChips — the mood/state chip row from the refs: a horizontally
// scrollable set of pill chips (emoji or icon + word), single-select, calm.
// Used for journal moods, coach intents ('Energize', 'Recover', 'Focus'),
// filter rows. Selection is a soft accent fill — never a colour explosion.
//
//   StateChips(
//     chips: [StateChip('Energize', emoji: '⚡'), StateChip('Recover', …)],
//     selected: 1,                    // null = nothing selected
//     onSelect: (i) => …,
//   )

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon;
import 'pressable.dart';

class StateChip {
  final String label;
  final String? emoji;
  final IconData? icon;
  const StateChip(this.label, {this.emoji, this.icon});
}

/// ToggleChip — the multi-select sibling of [StateChips]: one independent
/// on/off pill (journal tags, cycle symptoms). Soft accent fill + tinted
/// hairline when on; calm surface otherwise. Never a colour explosion.
class ToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Domain accent; defaults to the brand accent (soft fill + accent ink).
  final Color? accent;

  const ToggleChip(
    this.label, {
    super.key,
    required this.selected,
    this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? AppColors.accent;
    final ink = accent == null ? AppColors.onAccentSoft : a;
    final fill = accent == null
        ? AppColors.accentSoft
        : Color.alphaBlend(
            a.withValues(alpha: AppColors.isDark ? 0.18 : 0.13),
            Elevation.surfaceAt(1),
          );
    return Pressable(
      pressedScale: 0.94,
      borderRadius: BorderRadius.circular(R.pill),
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: selected ? fill : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: selected ? a.withValues(alpha: 0.55) : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: AppText.label.copyWith(
            color: selected ? ink : AppColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class StateChips extends StatelessWidget {
  final List<StateChip> chips;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final Color? accent;

  /// Scroll horizontally (default) or wrap to multiple lines.
  final bool wrap;

  const StateChips({
    super.key,
    required this.chips,
    this.selected,
    this.onSelect,
    this.accent,
    this.wrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final children = [
      for (var i = 0; i < chips.length; i++)
        _chip(context, i, chips[i], i == selected),
    ];
    if (wrap) {
      return Wrap(spacing: Sp.x2, runSpacing: Sp.x2, children: children);
    }
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: Sp.x2),
        itemBuilder: (_, i) => Center(child: children[i]),
      ),
    );
  }

  Widget _chip(BuildContext context, int i, StateChip c, bool on) {
    final a = accent ?? AppColors.accent;
    return Pressable(
      pressedScale: 0.94,
      onTap: onSelect == null ? null : () => onSelect!(i),
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3 + 2, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppColors.accentSoft : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: on ? a.withValues(alpha: 0.55) : AppColors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.emoji != null) ...[
              Text(c.emoji!, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: Sp.x1 + 2),
            ] else if (c.icon != null) ...[
              AppIcon(c.icon!, size: 14, color: on ? AppColors.onAccentSoft : AppColors.inkSoft),
              const SizedBox(width: Sp.x1 + 2),
            ],
            Text(
              c.label,
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: on ? AppColors.onAccentSoft : AppColors.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
