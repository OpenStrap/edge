// OpenStrap UI kit — the reusable surface/control vocabulary every screen uses.
// Cards, tiles, toggles, chips, icons, buttons, section headers, honesty tags.
// Charts live in charts.dart. Theme tokens come from theme/tokens.dart + AppText.

// The illustrated icon set rides along with the kit so every screen that
// imports kit/design gets OsAppIcon + OsIcon without touching the package.
export 'os_icons.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../theme/theme.dart';
import '../../theme/theme_controller.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../../models/metric.dart';
import 'os_icons.dart';

/// Thin wrapper over OsIcon so call sites stay short and consistent.
class AppIcon extends StatelessWidget {
  final OsIcon icon;
  final double size;
  final Color? color; // Kept for API compatibility, but ignored by illustrated icons
  const AppIcon(this.icon, {super.key, this.size = 22, this.color});
  @override
  Widget build(BuildContext context) =>
      OsAppIcon(icon, size: size);
}

/// Common icon set, mapped to OsIcon.
class Ic {
  Ic._();
  static const home = OsIcon.today;
  static const sleep = OsIcon.sleep;
  static const activity = OsIcon.activity;
  static const stats = OsIcon.records;
  static const profile = OsIcon.profile;
  static const strain = OsIcon.bodyStrain;
  static const recovery = OsIcon.recovery;
  static const heart = OsIcon.heart;
  static const pulse = OsIcon.heartRate;
  static const fire = OsIcon.calories;
  static const bed = OsIcon.bedtime;
  static const moon = OsIcon.sleep;
  static const clock = OsIcon.history;
  static const calendar = OsIcon.calendar;
  static const watch = OsIcon.wear;
  static const bluetooth = OsIcon.bluetooth;
  static const battery = OsIcon.battery;
  static const settings = OsIcon.settings;
  static const logout = OsIcon.logout;
  static const edit = OsIcon.edit;
  static const server = OsIcon.server;
  static const cloud = OsIcon.sync;
  static const shield = OsIcon.shield;
  static const info = OsIcon.info;
  static const check = OsIcon.check;
  static const cancel = OsIcon.cancel;
  static const arrowRight = OsIcon.arrowRight;
  static const arrowLeft = OsIcon.arrowLeft;
  static const up = OsIcon.up;
  static const down = OsIcon.down;
  static const chart = OsIcon.activity;
  static const droplet = OsIcon.hydration;
  static const run = OsIcon.run;
  static const weights = OsIcon.strength;
  static const bell = OsIcon.notifications;
  static const thermometer = OsIcon.skinTemperature;
  static const ai = OsIcon.ai;
  static const plus = OsIcon.plus;
  static const history = OsIcon.history;
  static const trash = OsIcon.trash;
  static const github = OsIcon.github;
  static const discord = OsIcon.discord;
  static const reddit = OsIcon.reddit;
  static const twitter = OsIcon.twitter;
}

/// White rounded card with soft warm shadow. The base surface for everything.
///
/// Opt-in polish (both default off, so the ~hundreds of existing call sites are
/// untouched): [entrance] gives a staggered fade-up on first build (delay =
/// index × 40 ms); [pressScale] dips to 0.98 on tap-down for a tactile press.
class ProCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final List<BoxShadow>? shadow;

  /// When non-null, the card fades + slides up on first build, staggered by
  /// this index (pass the ListView item index).
  final int? entrance;

  /// When true (with [onTap]), the card scales to 0.98 while pressed.
  final bool pressScale;

  const ProCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.onTap,
    this.color,
    this.shadow,
    this.entrance,
    this.pressScale = false,
  });
  @override
  Widget build(BuildContext context) {
    final dark = AppColors.isDark;
    final fill = color ?? AppColors.surface;
    // Dark elevation comes from the lifted surface + a hairline border; drop
    // shadows are invisible on char. Light keeps its soft warm shadow.
    final resolvedShadow = shadow ?? Shadows.cardFor(dark);
    final card = AnimatedContainer(
      duration: Motion.fast,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(R.card),
        boxShadow: resolvedShadow,
        border: dark ? Border.all(color: AppColors.divider, width: 1) : null,
      ),
      child: child,
    );
    Widget result;
    if (onTap == null) {
      result = card;
    } else {
      result = Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(R.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(R.card),
          onTap: onTap,
          child: card,
        ),
      );
      if (pressScale) result = _PressScale(child: result);
    }
    if (entrance != null) result = Entrance(index: entrance!, child: result);
    return result;
  }
}

/// A one-shot staggered fade-up (opacity 0→1, translateY 12→0, delay =
/// index × 40 ms). Runs once on first build; cheap (a single short-lived
/// controller, disposed when scrolled away). Wrap any list item to stagger it;
/// [ProCard.entrance] uses this internally.
class Entrance extends StatefulWidget {
  final int index;
  final Widget child;
  const Entrance({super.key, required this.index, required this.child});
  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.enter.d,
  );
  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: (widget.index * 40).clamp(0, 400));
    Future.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = CurvedAnimation(parent: _c, curve: Motion.enter.c);
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - anim.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Scales its child to 0.98 while pressed. Uses a [Listener] so it never steals
/// the underlying InkWell's tap / ripple.
class _PressScale extends StatefulWidget {
  final Widget child;
  const _PressScale({required this.child});
  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.98 : 1.0,
        duration: Motion.fast,
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}

/// A card with a soft coral radial glow blob in a corner (ref #3 metric cards).
class GlowCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Alignment glowAlign;
  final Color? glow;
  final VoidCallback? onTap;
  const GlowCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.glowAlign = const Alignment(0.9, 1.1),
    this.glow,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final glowColor = glow ?? AppColors.coral;
    // On char the blob blooms — keep it a low, warm ember; on paper it can sing.
    final glowAlpha = AppColors.isDark ? 0.28 : 0.55;
    // Clamp the bloom radius on OLED char so it doesn't smear across the card;
    // paper can carry a wider, softer wash.
    final glowRadius = AppColors.isDark ? 0.62 : 0.9;
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(R.card),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: glowAlign,
                  radius: glowRadius,
                  colors: [
                    glowColor.withValues(alpha: glowAlpha),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
    return ProCard(padding: EdgeInsets.zero, onTap: onTap, child: body);
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

/// Wrap each non-spacer widget in a hand-built list with a staggered [Entrance]
/// (delay by list position), for a one-time fade-up reveal of a ListView's
/// children. Bare [SizedBox] spacers pass through untouched so gaps don't move.
List<Widget> staggered(List<Widget> items) {
  var i = 0;
  return [
    for (final w in items)
      if (w is SizedBox) w else Entrance(index: i++, child: w),
  ];
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
              child: Row(
                children: [
                  Text(
                    trailing!,
                    style: AppText.label.copyWith(color: AppColors.coralDeep),
                  ),
                  const SizedBox(width: 2),
                  AppIcon(OsIcon.arrowRight, size: 16, color: AppColors.coralDeep),
                ],
              ),
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
  const SegToggle({
    super.key,
    required this.options,
    required this.index,
    required this.onChanged,
  });
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
            onTap: () {
              if (i != index) HapticFeedback.selectionClick();
              onChanged(i);
            },
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.curve,
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x4,
                vertical: Sp.x2,
              ),
              decoration: BoxDecoration(
                color: sel ? AppColors.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Text(
                options[i],
                style: AppText.label.copyWith(
                  // The selected pill is AppColors.ink (dark in light mode,
                  // light in dark mode). The label must contrast with it:
                  // AppColors.surface inverts correctly in both modes.
                  color: sel ? AppColors.surface : AppColors.inkSoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
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
  const DeltaChip(
    this.pct, {
    super.key,
    this.suffix = '',
    this.goodIsUp = true,
  });
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(up ? OsIcon.up : OsIcon.down, size: 13, color: c),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              '${v.abs().toStringAsFixed(1)}%$suffix',
              style: AppText.caption.copyWith(
                color: c,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Baseline-delta chip — "+3 vs normal" / "−8" with an absolute value (not %),
/// colored by whether the move is good. Used on tiles + trend cards to show how
/// today compares to the user's own baseline.
class BaselineDeltaChip extends StatelessWidget {
  final num? delta; // signed, in the metric's unit
  final String unit; // e.g. 'bpm', 'ms', ''
  final bool goodIsUp; // RHR: down is good → false
  final bool showVsNormal;
  const BaselineDeltaChip(
    this.delta, {
    super.key,
    this.unit = '',
    this.goodIsUp = true,
    this.showVsNormal = true,
  });
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
    final num shownMag = mag == mag.roundToDouble()
        ? mag.round()
        : (mag * 10).round() / 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Text(
        '$sign$shownMag${unit.isNotEmpty ? ' $unit' : ''}${showVsNormal ? ' vs normal' : ''}',
        style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Appearance picker — System / Light / Dark, wired live to [ThemeController].
/// Used in onboarding (inline) and Profile (inside a ProCard). Switching updates
/// the whole app immediately. "System" follows the phone; the others pin a mode.
class AppearanceSelector extends StatelessWidget {
  /// Show the "APPEARANCE" overline + a one-line description above the toggle.
  final bool labeled;
  const AppearanceSelector({super.key, this.labeled = true});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ThemeController>();
    final idx = switch (ctrl.choice) {
      AppThemeChoice.system => 0,
      AppThemeChoice.light => 1,
      AppThemeChoice.dark => 2,
    };
    final toggle = SegToggle(
      options: const ['System', 'Light', 'Dark'],
      index: idx,
      onChanged: (i) {
        final next = switch (i) {
          1 => AppThemeChoice.light,
          2 => AppThemeChoice.dark,
          _ => AppThemeChoice.system,
        };
        if (next == ctrl.choice) return;
        // Cross-fade the whole app from the old look to the new one.
        final overlay = themeSwitchKey.currentState;
        if (overlay != null) {
          overlay.run(() => ctrl.setChoice(next));
        } else {
          ctrl.setChoice(next);
        }
      },
    );
    if (!labeled) return toggle;
    final desc = ctrl.choice == AppThemeChoice.system
        ? 'Following your phone — ${ctrl.isDark ? 'Ember on Char' : 'Ember on Paper'}'
        : 'Ember on ${ctrl.isDark ? 'Char' : 'Paper'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('APPEARANCE', style: AppText.overline),
        const SizedBox(height: Sp.x3),
        Align(alignment: Alignment.centerLeft, child: toggle),
        const SizedBox(height: Sp.x2),
        Text(desc, style: AppText.captionMuted),
      ],
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
  final Color? color;
  const Tag(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(R.pill),
      ),
      child: Text(
        text.toUpperCase(),
        style: AppText.overline.copyWith(
          color: c,
          fontSize: 9.5,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  static Widget? forMetric(Metric m) {
    if (m.isEstimate) return const Tag('est');
    if (m.isRelative) return _RelTag();
    if (m.beta) return _BetaTag();
    return null;
  }
}

/// Honesty tags whose colour is mode-resolved (can't be a const Tag arg).
class _RelTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Tag('rel', color: AppColors.loadDetraining);
}

class _BetaTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Tag('beta', color: AppColors.coral);
}

/// Compact round icon button (top-bar actions, like the ref's circular buttons).
class RoundIconButton extends StatelessWidget {
  final OsIcon icon;
  final VoidCallback? onTap;
  final Color? bg;
  final Color? fg; // Ignored for illustrated icons, kept for API compat
  
  const RoundIconButton(
    this.icon, {
    super.key,
    this.onTap,
    this.bg,
    this.fg,
  });
  
  @override
  Widget build(BuildContext context) => Material(
    color: bg ?? AppColors.surface,
    shape: const CircleBorder(),
    elevation: 0,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Sp.x3 - 3),
        child: OsAppIcon(icon, size: 26),
      ),
    ),
  );
}

/// A label/value list row used in detail sheets and profile sections.
class DetailRow extends StatelessWidget {
  final OsIcon? icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final Widget? trailing;
  const DetailRow({
    super.key,
    this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(R.cardSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x3),
        child: Row(
          children: [
            if (icon != null) ...[
              AppIcon(icon!, size: 19, color: AppColors.inkSoft),
              const SizedBox(width: Sp.x3),
            ],
            // Label + value are flexible with ellipsis so long strings squeeze
            // instead of overflowing the row (values keep priority).
            Expanded(
              child: Text(
                label,
                style: AppText.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: Sp.x3),
            Flexible(
              child: Text(
                value,
                style: AppText.body.copyWith(color: AppColors.inkSoft),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Sp.x2),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: Sp.x2),
              AppIcon(OsIcon.arrowRight, size: 16, color: AppColors.inkMuted),
            ],
          ],
        ),
      ),
    );
  }
}

/// Empty/placeholder line shown when a metric has no confident value.
Widget metricDash([double size = 30]) => Text(
  '—',
  style: AppText.metric.copyWith(color: AppColors.inkMuted, fontSize: size),
);

/// Minute-level detail (hypnogram, 24h timelines, wear histogram) is retained for
/// this many days; older days show the daily summary only. Keep in sync with the
/// backend's minute-table retention.
const int kDetailWindowDays = 7;

/// True when a 'YYYY-MM-DD' date is recent enough to still have minute-level detail.
bool detailedAvailable(String ymd) {
  final p = ymd.split('-');
  if (p.length != 3) return true;
  final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return true;
  // The label is a LOCAL day label, so "today" must be the LOCAL calendar day
  // (UTC here shifted the window by a day near midnight). The subtraction is
  // done on UTC-constructed midnights purely for stable day arithmetic.
  final date = DateTime.utc(y, m, d);
  final now = DateTime.now();
  final today = DateTime.utc(now.year, now.month, now.day);
  return today.difference(date).inDays <= kDetailWindowDays;
}

/// Shown in place of a minute-level chart for dates older than the detail window.
class DetailRetentionNote extends StatelessWidget {
  final String what; // e.g. 'hypnogram', 'minute-by-minute heart rate'
  const DetailRetentionNote({super.key, this.what = 'minute-by-minute detail'});
  @override
  Widget build(BuildContext context) => ProCard(
    child: Row(
      children: [
        AppIcon(OsIcon.history, size: 20, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Text(
            'Detailed $what is kept for the last $kDetailWindowDays days. '
            'For older dates we show your daily summary.',
            style: AppText.caption.copyWith(color: AppColors.inkSoft),
          ),
        ),
      ],
    ),
  );
}
