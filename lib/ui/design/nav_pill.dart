// FloatingNavPill — the floating bottom-nav pill from the reference apps: a
// lifted rounded bar, icon-only items, the selected item blooming into an
// ember-soft lozenge with its label. Every icon renders at full strength —
// selection is expressed only by the lozenge + label, never by dimming or
// shrinking the others. [NavPillAction] is the standard ember center action
// (the ▶/+ between the pill's two halves) — optional; the app shell renders
// the plain five-tab row without one.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/os_icons.dart';
import 'pressable.dart';

class NavPillItem {
  /// Illustrated tab icon (full-colour, theme-aware). Always rendered at full
  /// opacity and size — the art isn't tintable, and dimming it makes it
  /// illegible. Selection is the lozenge background + label only.
  final OsIcon icon;
  final String label;
  const NavPillItem(this.icon, this.label);
}

class FloatingNavPill extends StatelessWidget {
  final List<NavPillItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  /// Optional center action rendered between the two halves of [items].
  /// The app shell no longer uses one (starting a workout lives on the
  /// Workouts screen); when null all tabs lay out as a single even row.
  final Widget? centerAction;

  const FloatingNavPill({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.centerAction,
  });

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark;
    final half = (items.length / 2).ceil();

    Widget buildItem(int i) {
      final selected = i == index;
      return _NavPad(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (i != index) HapticFeedback.selectionClick();
            onSelect(i);
          },
          child: AnimatedContainer(
            duration: Motion.med,
            curve: Motion.emphatic,
            // Tighter than the old stroke-glyph pill: the illustrated icons
            // are larger (40px vs 21px), so the chrome gives the width back.
            // Unselected items carry no horizontal chrome — the lozenge (and
            // its padding) only shows on selection, so five 40px tabs fit at
            // narrow phone widths.
            padding: EdgeInsets.symmetric(
              horizontal: selected ? Sp.x2 : 0,
              vertical: Sp.x1,
            ),
            decoration: BoxDecoration(
              color: selected ? AppColors.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Full-colour illustration, always full opacity and full size
                // — dimming/shrinking made the art illegible. Selection is
                // carried entirely by the lozenge background + label. 40px:
                // the art has built-in transparent padding, so it needs the
                // extra size to read at a glance.
                OsAppIcon(items[i].icon, size: 40),
                // Label appears only on the selected item (numbers-first,
                // minimal text everywhere else).
                AnimatedSize(
                  duration: Motion.med,
                  curve: Motion.emphatic,
                  child: selected
                      ? Padding(
                          padding: const EdgeInsets.only(left: Sp.x2),
                          child: Text(
                            items[i].label,
                            style: AppText.label.copyWith(
                              color: AppColors.onAccentSoft,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x3),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: dark ? AppColors.surfaceElevated : AppColors.surface,
          borderRadius: BorderRadius.circular(R.pill),
          border: Elevation.border(3, dark: dark),
          boxShadow: Elevation.shadows(3, dark: dark),
        ),
        // No centerAction (the app shell) ⇒ the null-aware element drops out
        // and all tabs sit in one even spaceBetween row — no center gap.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < half; i++) buildItem(i),
            ?centerAction,
            for (var i = half; i < items.length; i++) buildItem(i),
          ],
        ),
      ),
    );
  }
}

/// The standard ember circle for [FloatingNavPill.centerAction] — press
/// feedback + haptic + semantics come free. Kept public for custom shells;
/// the app shell itself no longer renders a center action.
class NavPillAction extends StatelessWidget {
  /// Material/HugeIcons glyph, rendered on the ember circle. Ignored when
  /// [osIcon] is set.
  final OsIcon? icon;

  /// Illustrated action (e.g. [OsIcon.add]). The art is itself a soft-3D
  /// button coin, so it renders as-is — no ember circle behind it.
  final VoidCallback onTap;
  final String semanticLabel;

  const NavPillAction({
    super.key,
    this.icon,
    required this.onTap,
    this.semanticLabel = 'Start',
  }) : assert(icon != null);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Pressable(
        // Pressable fires the selection haptic itself.
        pressedScale: 0.9,
        onTap: onTap,
        // The illustrated coin IS the button — same 46px footprint.
        child: SizedBox(width: 46, height: 46, child: OsAppIcon(icon!, size: 46)),
      ),
    );
  }
}

/// Internal: keeps item hit-targets comfortable inside the tight pill.
class _NavPad extends StatelessWidget {
  final Widget child;
  const _NavPad({required this.child});
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: child);
}
