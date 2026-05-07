import 'package:flutter/material.dart';
import '../theme.dart';

/// Section header — "VITALS", "MOTION", etc.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Text(text,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  color: WTheme.textMuted,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Generic card surface.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? background;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.background,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? WTheme.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Single big-stat tile.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color? valueColor;
  final IconData? icon;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(icon, size: 14, color: WTheme.textMuted),
                ),
              Text(label,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      color: WTheme.textMuted,
                      fontSize: 10,
                      letterSpacing: 1.5)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(value,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: valueColor ?? WTheme.text,
                        fontSize: 24,
                        height: 1,
                        fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
              ),
              if (unit != null && unit!.isNotEmpty) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit!,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          color: WTheme.textDim,
                          fontSize: 11)),
                ),
              ]
            ],
          ),
        ],
      ),
    );
  }
}

/// Status pill — colored dot + label.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const StatusPill({super.key, required this.label, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.18) : Colors.transparent,
        border: Border.all(color: color, width: 0.8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 1.2,
                  color: color)),
        ],
      ),
    );
  }
}

/// Key/value row used in identity / debug sections.
class KvRow extends StatelessWidget {
  final String k;
  final String v;
  const KvRow(this.k, this.v, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
            width: 100,
            child: Text(k,
                style: const TextStyle(
                    fontFamily: 'monospace', color: WTheme.textMuted, fontSize: 11))),
        Expanded(
            child: Text(v,
                style: const TextStyle(
                    fontFamily: 'monospace', color: WTheme.text, fontSize: 12))),
      ]),
    );
  }
}
