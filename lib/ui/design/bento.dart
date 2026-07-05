// The bento system — the mixed-size, mixed-tone card composition of the
// reference dashboards.
//
// Two layouts:
//  • [BentoGrid] — row-packed spans (hero-wide + equal-height pairs).
//  • [BentoColumns] — two independent stacks of different heights, the true
//    masonry rhythm of the refs (a tall tile beside two short ones).
//
// One tile: [BentoTile] — a surface that also speaks TONE. The refs' boards
// mix paper cards with inverted near-black cards and one saturated accent
// card; [BentoTone] encodes exactly that, and pushes the correct foreground
// colours down to children through [ToneScope] so BigStat / labels / icons
// recolour themselves automatically inside any tone.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'motion.dart';
import 'pressable.dart';

class BentoItem {
  /// Columns this item spans (clamped to the grid's column count).
  final int span;
  final Widget child;
  const BentoItem(this.child, {this.span = 1});

  /// Full-width item (hero card / chart).
  const BentoItem.wide(this.child) : span = 1000000;
}

class BentoGrid extends StatelessWidget {
  final List<BentoItem> items;
  final int columns;
  final double gap;

  /// Stagger the rows' entrance on first build.
  final bool entrance;

  const BentoGrid({
    super.key,
    required this.items,
    this.columns = 2,
    this.gap = Sp.x3,
    this.entrance = true,
  });

  @override
  Widget build(BuildContext context) {
    assert(columns >= 1);
    // Greedy row packing.
    final rows = <List<BentoItem>>[];
    var row = <BentoItem>[];
    var used = 0;
    for (final item in items) {
      final span = item.span.clamp(1, columns);
      if (used + span > columns && row.isNotEmpty) {
        rows.add(row);
        row = <BentoItem>[];
        used = 0;
      }
      row.add(item);
      used += span;
      if (used == columns) {
        rows.add(row);
        row = <BentoItem>[];
        used = 0;
      }
    }
    if (row.isNotEmpty) rows.add(row);

    var stagger = 0;
    final children = <Widget>[];
    for (var r = 0; r < rows.length; r++) {
      final cells = rows[r];
      final usedSpan = cells.fold<int>(
        0,
        (a, c) => a + c.span.clamp(1, columns),
      );
      Widget rowWidget = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(
                flex: cells[i].span.clamp(1, columns),
                child: cells[i].child,
              ),
            ],
            // Keep partial rows on-grid: pad the missing columns.
            if (usedSpan < columns)
              Expanded(flex: columns - usedSpan, child: const SizedBox()),
          ],
        ),
      );
      if (entrance) rowWidget = rowWidget.dsEnter(index: stagger++);
      if (r > 0) children.add(SizedBox(height: gap));
      children.add(rowWidget);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// BentoColumns — the true masonry rhythm of the reference boards: two
/// independent stacks whose tiles are allowed DIFFERENT heights (a tall
/// hypnogram tile beside two short stat tiles). Entrance staggers across
/// both columns in visual (roughly top-to-bottom) order.
class BentoColumns extends StatelessWidget {
  final List<Widget> left;
  final List<Widget> right;
  final double gap;
  final bool entrance;

  const BentoColumns({
    super.key,
    required this.left,
    required this.right,
    this.gap = Sp.x3,
    this.entrance = true,
  });

  List<Widget> _stack(List<Widget> tiles, int columnOffset) => [
    for (var i = 0; i < tiles.length; i++) ...[
      if (i > 0) SizedBox(height: gap),
      entrance ? tiles[i].dsEnter(index: i * 2 + columnOffset) : tiles[i],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _stack(left, 0),
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _stack(right, 1),
          ),
        ),
      ],
    );
  }
}

/// The tonal vocabulary of a bento board (see image-10-style compositions):
/// mostly paper, one or two inverted ink tiles, a single saturated accent
/// tile, and quiet soft-tint tiles for secondary domains.
enum BentoTone { paper, ink, accent, soft }

/// Foreground palette a [BentoTile] provides to its children. Read it with
/// [ToneScope.of] — design-system atoms (BigStat, tone-aware labels) do this
/// automatically, so the same child works on paper, ink and accent tiles.
class ToneColors {
  final Color fg;
  final Color fgMuted;
  final Color fgFaint;

  /// The tile's own accent (domain colour on paper/soft, white-ish on
  /// ink/accent tiles so marks stay legible).
  final Color accent;
  const ToneColors({
    required this.fg,
    required this.fgMuted,
    required this.fgFaint,
    required this.accent,
  });

  /// The mode-correct palette for content sitting directly on cards/screens
  /// (identical to a paper tile's).
  static ToneColors paper([Color? accent]) => ToneColors(
    fg: AppColors.ink,
    fgMuted: AppColors.inkSoft,
    fgFaint: AppColors.inkMuted,
    accent: accent ?? AppColors.accent,
  );
}

class ToneScope extends InheritedWidget {
  final ToneColors colors;
  const ToneScope({super.key, required this.colors, required super.child});

  static ToneColors of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ToneScope>()?.colors ??
      ToneColors.paper();

  @override
  bool updateShouldNotify(ToneScope old) => old.colors != colors;
}

/// BentoTile — the tile surface of the bento system. Chooses fill + depth for
/// its [tone], wires press/haptics via [Pressable], and provides the correct
/// foreground palette to children through [ToneScope].
///
///   BentoTile(
///     tone: BentoTone.ink,
///     accent: DomainAccent.steps,
///     onTap: …,
///     child: BigStat(value: '8 412', label: 'STEPS'),
///   )
class BentoTile extends StatelessWidget {
  final Widget child;
  final BentoTone tone;

  /// Domain accent — tints the soft tone's fill, colours the accent tone's
  /// whole card, and becomes [ToneColors.accent] for children.
  final Color? accent;

  final EdgeInsetsGeometry padding;
  final double radius;

  /// Floor for the tile's height (0 = content-sized). Short stat tiles pass a
  /// shared floor so a bento board keeps a steady rhythm and numbers never
  /// feel cropped into their box.
  final double minHeight;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const BentoTile({
    super.key,
    required this.child,
    this.tone = BentoTone.paper,
    this.accent,
    this.padding = const EdgeInsets.all(Sp.x4),
    this.radius = R.card,
    this.minHeight = 0,
    this.onTap,
    this.onLongPress,
  });

  (Color fill, ToneColors colors, Border? border, List<BoxShadow> shadow)
  _resolve() {
    final dark = AppColors.isDark;
    final a = accent ?? AppColors.accent;
    switch (tone) {
      case BentoTone.paper:
        return (
          Elevation.surfaceAt(1, dark: dark),
          ToneColors.paper(a),
          Elevation.border(1, dark: dark),
          Elevation.shadows(1, dark: dark),
        );
      case BentoTone.ink:
        // Inverted near-black tile — invariant char so it reads as THE dark
        // tile in light mode and as a deliberately deeper well in dark mode.
        return (
          dark ? AppColors.nightAlt : AppColors.night,
          ToneColors(
            fg: AppColors.onNight,
            fgMuted: AppColors.onNightSoft,
            fgFaint: AppColors.onNightSoft.withValues(alpha: 0.55),
            accent: Color.lerp(a, Colors.white, dark ? 0.15 : 0.25)!,
          ),
          dark ? Border.all(color: const Color(0xFF3D362C)) : null,
          Elevation.shadows(1, dark: dark),
        );
      case BentoTone.accent:
        // One saturated card per board — white ink on the domain colour.
        return (
          a,
          ToneColors(
            fg: Colors.white,
            fgMuted: Colors.white.withValues(alpha: 0.78),
            fgFaint: Colors.white.withValues(alpha: 0.55),
            accent: Colors.white,
          ),
          null,
          dark ? const [] : Elevation.shadows(1, dark: false),
        );
      case BentoTone.soft:
        // Quiet tint of the domain colour; ink stays the normal mode ink.
        return (
          Color.alphaBlend(
            a.withValues(alpha: dark ? 0.16 : 0.13),
            Elevation.surfaceAt(1, dark: dark),
          ),
          ToneColors(
            fg: AppColors.ink,
            fgMuted: AppColors.inkSoft,
            fgFaint: AppColors.inkMuted,
            accent: a,
          ),
          Elevation.border(1, dark: dark),
          Elevation.shadows(1, dark: dark),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fill, colors, border, shadow) = _resolve();
    final br = BorderRadius.circular(radius);
    Widget tile = Container(
      constraints:
          minHeight > 0 ? BoxConstraints(minHeight: minHeight) : null,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: br,
        border: border,
        boxShadow: shadow,
      ),
      child: Padding(
        padding: padding,
        child: ToneScope(colors: colors, child: child),
      ),
    );
    if (onTap != null || onLongPress != null) {
      tile = Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: br,
        child: tile,
      );
    }
    return tile;
  }
}
