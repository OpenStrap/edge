// OpenStrap UI kit — the reusable surface/control vocabulary every screen uses.
// Cards, tiles, toggles, chips, icons, buttons, section headers, honesty tags.
// Charts live in charts.dart. Theme tokens come from theme/tokens.dart + AppText.

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../models/metric.dart';

/// Thin wrapper over HugeIcon so call sites stay short and consistent.
class AppIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  const AppIcon(this.icon, {super.key, this.size = 22, this.color});
  @override
  Widget build(BuildContext context) =>
      HugeIcon(icon: icon, size: size, color: color ?? AppColors.ink);
}

/// Common icon set, named once so screens don't reach into HugeIcons directly.
class Ic {
  Ic._();
  static const home = HugeIcons.strokeRoundedHome01;
  static const sleep = HugeIcons.strokeRoundedMoon02;
  static const activity = HugeIcons.strokeRoundedActivity01;
  static const stats = HugeIcons.strokeRoundedAnalytics01;
  static const profile = HugeIcons.strokeRoundedUserCircle;
  static const strain = HugeIcons.strokeRoundedEnergy;
  static const recovery = HugeIcons.strokeRoundedChampion;
  static const heart = HugeIcons.strokeRoundedFavourite;
  static const pulse = HugeIcons.strokeRoundedPulseRectangle01;
  static const fire = HugeIcons.strokeRoundedFire;
  static const bed = HugeIcons.strokeRoundedBed;
  static const moon = HugeIcons.strokeRoundedMoon02;
  static const clock = HugeIcons.strokeRoundedClock01;
  static const calendar = HugeIcons.strokeRoundedCalendar03;
  static const watch = HugeIcons.strokeRoundedSmartWatch01;
  static const bluetooth = HugeIcons.strokeRoundedBluetooth;
  static const battery = HugeIcons.strokeRoundedBatteryFull;
  static const settings = HugeIcons.strokeRoundedSettings01;
  static const logout = HugeIcons.strokeRoundedLogout01;
  static const edit = HugeIcons.strokeRoundedEdit02;
  static const server = HugeIcons.strokeRoundedServerStack01;
  static const cloud = HugeIcons.strokeRoundedCloudServer;
  static const shield = HugeIcons.strokeRoundedShieldEnergy;
  static const mail = HugeIcons.strokeRoundedMail01;
  static const info = HugeIcons.strokeRoundedInformationCircle;
  static const check = HugeIcons.strokeRoundedCheckmarkCircle02;
  static const cancel = HugeIcons.strokeRoundedCancel01;
  static const arrowRight = HugeIcons.strokeRoundedArrowRight01;
  static const arrowLeft = HugeIcons.strokeRoundedArrowLeft01;
  static const up = HugeIcons.strokeRoundedArrowUp01;
  static const down = HugeIcons.strokeRoundedArrowDown01;
  static const chart = HugeIcons.strokeRoundedChartLineData01;
  static const droplet = HugeIcons.strokeRoundedDroplet;
  static const run = HugeIcons.strokeRoundedRunningShoes;
  static const bell = HugeIcons.strokeRoundedNotification03;
}

/// White rounded card with soft warm shadow. The base surface for everything.
class ProCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;
  final List<BoxShadow> shadow;
  const ProCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.onTap,
    this.color = AppColors.surface,
    this.shadow = Shadows.card,
  });
  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: Motion.fast,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(R.card),
        boxShadow: shadow,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(R.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.card),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

/// A card with a soft coral radial glow blob in a corner (ref #3 metric cards).
class GlowCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Alignment glowAlign;
  final Color glow;
  final VoidCallback? onTap;
  const GlowCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.glowAlign = const Alignment(0.9, 1.1),
    this.glow = AppColors.coral,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(R.card),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: glowAlign,
                  radius: 0.9,
                  colors: [glow.withValues(alpha: 0.55), Colors.transparent],
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
    return ProCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: body,
    );
  }
}

/// Dark hero card (device, splash overlays).
class NightCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const NightCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x6),
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => ProCard(
        padding: padding,
        onTap: onTap,
        color: AppColors.night,
        shadow: Shadows.lift,
        child: child,
      );
}

/// Section header — overline/title + optional trailing action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  final VoidCallback? onTrailing;
  const SectionHeader(this.title, {super.key, this.trailing, this.onTrailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3, top: Sp.x2),
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppText.h2)),
          if (trailing != null)
            GestureDetector(
              onTap: onTrailing,
              child: Row(children: [
                Text(trailing!,
                    style: AppText.label.copyWith(color: AppColors.coralDeep)),
                const SizedBox(width: 2),
                const AppIcon(Ic.arrowRight,
                    size: 16, color: AppColors.coralDeep),
              ]),
            ),
        ],
      ),
    );
  }
}

/// Animated segmented pill toggle (Week / Month / 3M).
class SegToggle extends StatelessWidget {
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  const SegToggle(
      {super.key,
      required this.options,
      required this.index,
      required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(options.length, (i) {
          final sel = i == index;
          return GestureDetector(
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.curve,
              padding:
                  const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
              decoration: BoxDecoration(
                color: sel ? AppColors.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Text(options[i],
                  style: AppText.label.copyWith(
                    color: sel ? AppColors.onNight : AppColors.inkSoft,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          );
        }),
      ),
    );
  }
}

/// A ▲ +3.2% / ▼ −5% colored delta chip. Pass null to hide.
class DeltaChip extends StatelessWidget {
  final num? pct;
  final String suffix;
  final bool goodIsUp; // for RHR, down is good → flip the color meaning
  const DeltaChip(this.pct, {super.key, this.suffix = '', this.goodIsUp = true});
  @override
  Widget build(BuildContext context) {
    if (pct == null) return const SizedBox.shrink();
    final v = pct!;
    final up = v >= 0;
    final positive = goodIsUp ? up : !up;
    final c = v.abs() < 1
        ? AppColors.inkMuted
        : (positive ? AppColors.good : AppColors.bad);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AppIcon(up ? Ic.up : Ic.down, size: 13, color: c),
        const SizedBox(width: 2),
        Flexible(
          child: Text('${v.abs().toStringAsFixed(1)}%$suffix',
              style: AppText.caption
                  .copyWith(color: c, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

/// Baseline-delta chip — "+3 vs normal" / "−8" with an absolute value (not %),
/// colored by whether the move is good. Used on tiles + trend cards to show how
/// today compares to the user's own baseline.
class BaselineDeltaChip extends StatelessWidget {
  final num? delta;       // signed, in the metric's unit
  final String unit;      // e.g. 'bpm', 'ms', ''
  final bool goodIsUp;    // RHR: down is good → false
  final bool showVsNormal;
  const BaselineDeltaChip(this.delta, {super.key, this.unit = '', this.goodIsUp = true, this.showVsNormal = true});
  @override
  Widget build(BuildContext context) {
    if (delta == null) return const SizedBox.shrink();
    final v = delta!;
    final up = v >= 0;
    final positive = goodIsUp ? up : !up;
    final c = v.abs() < 0.05
        ? AppColors.inkMuted
        : (positive ? AppColors.good : AppColors.bad);
    final sign = up ? '+' : '−';
    final mag = v.abs();
    final num shownMag = mag == mag.roundToDouble() ? mag.round() : (mag * 10).round() / 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(R.pill)),
      child: Text(
        '$sign$shownMag${unit.isNotEmpty ? ' $unit' : ''}${showVsNormal ? ' vs normal' : ''}',
        style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Tiny confidence dot (honesty system).
class ConfDot extends StatelessWidget {
  final double confidence;
  final double size;
  const ConfDot(this.confidence, {super.key, this.size = 7});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.confidenceColor(confidence),
          shape: BoxShape.circle,
        ),
      );
}

/// Small honesty label pill (EST. / BETA / REL.).
class Tag extends StatelessWidget {
  final String text;
  final Color color;
  const Tag(this.text, {super.key, this.color = AppColors.warn});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Text(text.toUpperCase(),
            style: AppText.overline
                .copyWith(color: color, fontSize: 9.5, letterSpacing: 0.8)),
      );
  static Widget? forMetric(Metric m) {
    if (m.isEstimate) return const Tag('est', color: AppColors.warn);
    if (m.isRelative) return const Tag('rel', color: AppColors.loadDetraining);
    if (m.beta) return const Tag('beta', color: AppColors.coral);
    return null;
  }
}

/// Compact round icon button (top-bar actions, like the ref's circular buttons).
class RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color bg;
  final Color fg;
  const RoundIconButton(this.icon,
      {super.key,
      this.onTap,
      this.bg = AppColors.surface,
      this.fg = AppColors.ink});
  @override
  Widget build(BuildContext context) => Material(
        color: bg,
        shape: const CircleBorder(),
        elevation: 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Sp.x3),
            child: AppIcon(icon, size: 20, color: fg),
          ),
        ),
      );
}

/// A label/value list row used in detail sheets and profile sections.
class DetailRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final Widget? trailing;
  const DetailRow(
      {super.key,
      this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.trailing});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(R.cardSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x3),
        child: Row(children: [
          if (icon != null) ...[
            AppIcon(icon!, size: 19, color: AppColors.inkSoft),
            const SizedBox(width: Sp.x3),
          ],
          Text(label, style: AppText.body),
          const Spacer(),
          Text(value, style: AppText.body.copyWith(color: AppColors.inkSoft)),
          if (trailing != null) ...[const SizedBox(width: Sp.x2), trailing!]
          else if (onTap != null) ...[
            const SizedBox(width: Sp.x2),
            const AppIcon(Ic.arrowRight, size: 16, color: AppColors.inkMuted),
          ],
        ]),
      ),
    );
  }
}

/// Empty/placeholder line shown when a metric has no confident value.
Widget metricDash([double size = 30]) => Text('—',
    style: AppText.metric.copyWith(color: AppColors.inkMuted, fontSize: size));
