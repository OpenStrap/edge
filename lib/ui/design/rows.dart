// ListRow — the standard tappable list row: icon-in-tile, title (+ optional
// subtitle), trailing value / chevron / custom widget. Settings, drill-downs,
// session lists. Press feedback + haptic come free via [Pressable].

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon;
import '../kit/os_icons.dart';
import 'pressable.dart';

class ListRow extends StatelessWidget {
  /// Monochrome stroke glyph — the default. Rendered at 18px via [AppIcon].
  final OsIcon? icon;

  /// Illustrated variant — takes precedence over [icon] inside the chip.
  /// Rendered at 46px (the art carries built-in transparent padding, so it
  /// needs a larger canvas than a stroke glyph to read at the same weight).
  final OsIcon? osIcon;

  final Color? iconColor;
  final String title;
  final String? subtitle;

  /// Right-aligned value text (muted).
  final String? value;

  /// Custom trailing widget (overrides the chevron).
  final Widget? trailing;

  final VoidCallback? onTap;

  /// Draw a hairline divider under the row (for stacked rows in one card).
  final bool divider;

  const ListRow({
    super.key,
    this.icon,
    this.osIcon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.divider = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Row(
          children: [
            if (osIcon != null || icon != null) ...[
              Container(
                padding: EdgeInsets.all(Sp.x2),
                decoration: BoxDecoration(
                  color: (iconColor ?? AppColors.onSurfaceMuted).withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: osIcon != null
                    ? OsAppIcon(osIcon!, size: 46)
                    : AppIcon(
                        icon!,
                        size: 18,
                        color: iconColor ?? AppColors.onSurfaceMuted,
                      ),
              ),
              const SizedBox(width: Sp.x3),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: AppText.captionMuted,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: Sp.x3),
              Text(
                value!,
                style: AppText.body.copyWith(color: AppColors.onSurfaceMuted),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: Sp.x2),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: Sp.x2),
              AppIcon(OsIcon.arrowRight, size: 16, color: AppColors.onSurfaceFaint),
            ],
          ],
        ),
      ),
    );

    final body = divider
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              Divider(height: 1, thickness: 1, color: AppColors.divider),
            ],
          )
        : row;

    if (onTap == null) return body;
    return Pressable(
      onTap: onTap,
      pressedScale: 0.99,
      borderRadius: BorderRadius.circular(R.cardSm),
      child: body,
    );
  }
}
