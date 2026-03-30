import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final Color? valueColor;
  final bool isLoading;
  final String? subLabel;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.valueColor,
    this.isLoading = false,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null)
                Icon(icon!, color: WhoopColors.textSecondary, size: 14),
              if (icon != null) const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: WhoopColors.textSecondary,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isLoading)
            Container(
              width: 48,
              height: 28,
              decoration: BoxDecoration(
                color: WhoopColors.cardBorder,
                borderRadius: BorderRadius.circular(4),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? WhoopColors.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    letterSpacing: -0.5,
                    height: 1,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      unit!,
                      style: const TextStyle(
                        color: WhoopColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          if (subLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              subLabel!,
              style: const TextStyle(
                color: WhoopColors.textDim,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class StatusTile extends StatelessWidget {
  final String label;
  final bool? isActive;
  final String activeText;
  final String inactiveText;
  final IconData activeIcon;
  final IconData inactiveIcon;

  const StatusTile({
    super.key,
    required this.label,
    required this.isActive,
    required this.activeText,
    required this.inactiveText,
    required this.activeIcon,
    required this.inactiveIcon,
  });

  @override
  Widget build(BuildContext context) {
    final active = isActive;
    final color = active == true
        ? WhoopColors.green
        : active == false
            ? WhoopColors.textDim
            : WhoopColors.textSecondary;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WhoopColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WhoopColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: WhoopColors.textSecondary,
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                active == true ? activeIcon : inactiveIcon,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                active == true
                    ? activeText
                    : active == false
                        ? inactiveText
                        : '—',
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
