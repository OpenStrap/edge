// Design tokens — OpenStrap "Ember on Paper" (day) / "Ember on Char" (night).
// Day: warm off-white surfaces, near-black ink, a single confident coral accent.
// Night: the paper burns down to warm charcoal — same ember, never cold black.
// The accent stays coral across both modes; warmth is the constant, not lightness.
//
// Big tabular numbers (Space Grotesk) over clean body (Inter) — see theme.dart.
// The honesty system (confidence dots, est./relative/beta labels) is preserved.
//
// Mode switching: every mode-varying role lives on [Palette]; [AppColors] exposes
// the same names it always did, resolved through [AppColors.active]. The theme
// controller swaps `active` (synchronously) the instant the mode changes, so the
// 546 `AppColors.x` call sites keep working untouched and re-theme on rebuild.

import 'package:flutter/material.dart';

/// Light-sleep stage colour — a soft light orange (warm, distinct from the
/// coral REM/Deep tones; replaces the old cool-blue which clashed with the
/// ember palette).
const Color kLightStageColor = Color(0xFFF6B07A);

/// A complete set of mode-varying colour roles. Two const instances exist
/// ([kLightPalette], [kDarkPalette]); the active one is swapped at runtime.
@immutable
class Palette {
  final Brightness brightness;

  // Surfaces.
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceSunk;
  final Color cool;
  final Color coolInk;
  final Color divider;

  // Ink.
  final Color ink;
  final Color inkSoft;
  final Color inkMuted;

  // Accent — ember coral.
  final Color coral;
  final Color coralDeep;
  final Color coralSoft;
  final Color coralInk;

  // Status.
  final Color good;
  final Color goodSoft;
  final Color warn;
  final Color warnSoft;
  final Color bad;
  final Color badSoft;

  // Confidence + load (independent tones; the rest derive from status).
  final Color confLow;
  final Color loadDetraining;

  const Palette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceSunk,
    required this.cool,
    required this.coolInk,
    required this.divider,
    required this.ink,
    required this.inkSoft,
    required this.inkMuted,
    required this.coral,
    required this.coralDeep,
    required this.coralSoft,
    required this.coralInk,
    required this.good,
    required this.goodSoft,
    required this.warn,
    required this.warnSoft,
    required this.bad,
    required this.badSoft,
    required this.confLow,
    required this.loadDetraining,
  });

  bool get isDark => brightness == Brightness.dark;
}

/// Day — "Ember on Paper". The original, beloved palette, unchanged in value.
const Palette kLightPalette = Palette(
  brightness: Brightness.light,
  bg: Color(0xFFF4F1EC), // warm paper background
  surface: Color(0xFFFFFFFF), // cards
  surfaceAlt: Color(0xFFECE7DF), // inset / skeleton base
  surfaceSunk: Color(0xFFEDE9E1), // subtle wells
  cool: Color(0xFFE7EBF5), // cool secondary section
  coolInk: Color(0xFF2B3350), // ink on the cool surface
  divider: Color(0xFFE6E0D6),
  ink: Color(0xFF16130F), // near-black, warm
  inkSoft: Color(0xFF6B6157), // secondary
  inkMuted: Color(0xFFA59C90), // tertiary / placeholders
  coral: Color(0xFFFF5A36),
  coralDeep: Color(0xFFE8431F),
  coralSoft: Color(0xFFFFE7DF), // tint fill
  coralInk: Color(0xFF7A2A16), // ink on coralSoft
  good: Color(0xFF2BB673),
  goodSoft: Color(0xFFDBF3E7),
  warn: Color(0xFFF5A623),
  warnSoft: Color(0xFFFBEBCF),
  bad: Color(0xFFE5484D),
  badSoft: Color(0xFFFAE0E0),
  confLow: Color(0xFFC9C0B4),
  loadDetraining: Color(0xFF7CA8F0),
);

/// Night — "Ember on Char". Warm charcoal, never cold black. Ink is the paper
/// colour; coral lifts ~8% so it reads cleanly on dark; the pale "*Soft" tints
/// become deep warm ember/earth fills so light ink sits on them comfortably.
const Palette kDarkPalette = Palette(
  brightness: Brightness.dark,
  bg: Color(0xFF14110D), // warm near-black char
  surface: Color(0xFF1E1A15), // cards, lifted off bg
  surfaceAlt: Color(0xFF2A251F), // inset / skeleton base
  surfaceSunk: Color(0xFF100E0A), // wells, darker than bg
  cool: Color(0xFF20242E), // cool secondary, darkened
  coolInk: Color(0xFFC3CADB), // ink on the cool surface
  divider: Color(0xFF302A22),
  ink: Color(0xFFF1ECE3), // warm off-white — the paper becomes the ink
  inkSoft: Color(0xFFB6AB9C),
  inkMuted: Color(0xFF7E7466),
  coral: Color(0xFFFF6B47), // a hair brighter on dark
  coralDeep: Color(0xFFFF8159), // "deep" = stronger/lighter coral on dark text
  coralSoft: Color(0xFF3A2018), // deep warm ember tint fill
  coralInk: Color(0xFFFFB59E), // light coral text on coralSoft
  good: Color(0xFF34C988),
  goodSoft: Color(0xFF15281F),
  warn: Color(0xFFF7B53A),
  warnSoft: Color(0xFF31280F),
  bad: Color(0xFFF26168),
  badSoft: Color(0xFF331A1B),
  confLow: Color(0xFF5A5248),
  loadDetraining: Color(0xFF8FB4F2),
);

/// Palette — warm paper + coral. Same public names as before; mode-varying roles
/// now resolve through [active], which the theme controller swaps at runtime.
class AppColors {
  AppColors._();

  /// The currently-rendered palette. Swapped (synchronously) by the theme
  /// controller before the tree rebuilds, so getters below always match the
  /// mode MaterialApp is painting.
  static Palette active = kLightPalette;

  static bool get isDark => active.isDark;

  // ── Surfaces (mode-varying) ──
  static Color get bg => active.bg;
  static Color get surface => active.surface;
  static Color get surfaceAlt => active.surfaceAlt;
  static Color get surfaceSunk => active.surfaceSunk;
  static Color get cool => active.cool;
  static Color get coolInk => active.coolInk;
  static Color get divider => active.divider;

  // ── Ink (mode-varying) ──
  static Color get ink => active.ink;
  static Color get inkSoft => active.inkSoft;
  static Color get inkMuted => active.inkMuted;

  // ── Dark hero surfaces — INVARIANT across modes (always-dark cards: the
  //    device card, the live-workout screen, splash overlays). ──
  static const night = Color(0xFF181613);
  static const nightAlt = Color(0xFF24211D);
  static const onNight = Color(0xFFF4F1EC);
  static const onNightSoft = Color(0xFFA8A096);

  // ── Accent — ember coral (mode-varying) ──
  static Color get coral => active.coral;
  static Color get coralDeep => active.coralDeep;
  static Color get coralSoft => active.coralSoft;
  static Color get coralInk => active.coralInk;

  // ── Status (mode-varying) ──
  static Color get good => active.good;
  static Color get goodSoft => active.goodSoft;
  static Color get warn => active.warn;
  static Color get warnSoft => active.warnSoft;
  static Color get bad => active.bad;
  static Color get badSoft => active.badSoft;

  // ── Confidence dot ──
  static Color get confHigh => active.good;
  static Color get confMid => active.warn;
  static Color get confLow => active.confLow;

  // ── Load (ACWR) bands ──
  static Color get loadDetraining => active.loadDetraining;
  static Color get loadOptimal => active.good;
  static Color get loadCaution => active.warn;
  static Color get loadHigh => active.bad;

  // ── Live-session ember glow — INVARIANT (always on the dark live screen). ──
  static const glow1 = Color(0xFFFF7A4D);
  static const glow2 = Color(0xFFFF3D1F);

  /// Color band for a normalized 0..1 score. Coral-forward: low scores trend
  /// deep, high scores vivid; green reserved for genuinely strong.
  static Color scoreColor(double t) {
    if (t.isNaN) return confLow;
    if (t >= 0.75) return good;
    if (t >= 0.45) return coral;
    return coralDeep;
  }

  static Color confidenceColor(double c) {
    if (c >= 0.75) return confHigh;
    if (c >= 0.4) return confMid;
    return confLow;
  }

  // ── HR zone palette (Z0..Z5) — the single source for zone colours. Reads the
  //    active palette at call time, so it re-themes for free. Both the live
  //    session ladder and the workouts zone bars source their colours here. ──
  static Color zone(int z) {
    switch (z.clamp(0, 5)) {
      case 0:
        return cool; // resting / below zone 1
      case 1:
        return loadDetraining; // warm-up
      case 2:
        return good; // fat burn
      case 3:
        return warn; // aerobic
      case 4:
        return coral; // threshold
      default:
        return coralDeep; // max effort (Z5)
    }
  }

  /// A soft tint of a zone colour — for faint backfills / legend swatches.
  static Color zoneSoft(int z) => zone(z).withValues(alpha: 0.16);

  // ── Semantic aliases — the design-system vocabulary. One canonical name per
  //    role, resolved through [active] like everything else. New components
  //    (lib/ui/design/) speak these; the legacy names above keep working. ──

  /// Screen background (warm paper / deep char).
  static Color get background => active.bg;

  /// A surface lifted above [surface] — sheets, popovers, the top bento card.
  /// On char, elevation is a *lighter* surface (shadows vanish on near-black);
  /// on paper the same white surface carries a stronger shadow instead.
  static Color get surfaceElevated =>
      active.isDark ? active.surfaceAlt : active.surface;

  /// Primary content colour on any surface.
  static Color get onSurface => active.ink;

  /// Secondary content — labels, captions, supporting copy.
  static Color get onSurfaceMuted => active.inkSoft;

  /// Tertiary content — placeholders, disabled, hairline glyphs.
  static Color get onSurfaceFaint => active.inkMuted;

  /// THE brand accent — ember coral.
  static Color get accent => active.coral;

  /// Ember tint fill (chips, soft badges); pair text with [onAccentSoft].
  static Color get accentSoft => active.coralSoft;
  static Color get onAccentSoft => active.coralInk;

  /// Status roles.
  static Color get positive => active.good;
  static Color get positiveSoft => active.goodSoft;
  static Color get critical => active.bad;
  static Color get criticalSoft => active.badSoft;
  // (warn / warnSoft already exist above.)
}

/// Faint arc alpha for a low-confidence ring — high confidence paints the arc
/// solid, low confidence fades it so uncertainty reads visually. Used by [Gauge]
/// and any confidence-aware ring. Clamped to a legible floor.
double confidenceRingAlpha(double c) {
  if (c.isNaN) return 0.35;
  return (0.35 + 0.65 * c.clamp(0.0, 1.0)).clamp(0.35, 1.0);
}

/// Spacing — 4-pt grid.
class Sp {
  Sp._();
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x7 = 28.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const screen = 20.0; // generous side gutter
}

/// Radii — soft, generous (modern rounded cards).
class R {
  R._();
  static const card = 28.0;
  static const cardSm = 20.0;
  static const chip = 14.0;
  static const pill = 999.0;
}

/// Soft warm elevation. Light theme leans on gentle shadow; dark theme leans on
/// a hairline border + lifted surface (drop shadows vanish on char), see ProCard.
class Shadows {
  Shadows._();
  static const card = [
    BoxShadow(color: Color(0x14201A12), blurRadius: 24, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A201A12), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const lift = [
    BoxShadow(color: Color(0x1F201A12), blurRadius: 32, offset: Offset(0, 16)),
  ];
  static const coral = [
    BoxShadow(color: Color(0x40FF5A36), blurRadius: 28, offset: Offset(0, 12)),
  ];

  /// A medium sheet/finish-card shadow — stronger than [card], softer than
  /// [lift]. Used by bottom sheets and the cinematic finish card on paper.
  static const sheet = [
    BoxShadow(color: Color(0x1A201A12), blurRadius: 40, offset: Offset(0, 20)),
    BoxShadow(color: Color(0x0F201A12), blurRadius: 6, offset: Offset(0, 2)),
  ];

  /// Elevation for a card by mode. In dark we drop shadows entirely (invisible
  /// on char) and let the lifted surface + border carry depth.
  static List<BoxShadow> cardFor(bool dark) => dark ? const [] : card;
}

/// Elevation scale — semantic depths mapped onto [Shadows]. Every level honours
/// the dark=border rule (drop shadows vanish on char) via [forMode]:
///   e0 = flush • e1 = card • e2 = sheet/finish card • e3 = lifted hero.
///
/// Depth by mode (the design-system contract, see lib/ui/design/surface.dart):
///  • Paper (light): soft warm drop shadows, strength grows e1→e3. No border.
///  • Char (dark): a hairline border + a *lighter lifted surface* carry depth;
///    e2 adds a faint black penumbra for sheet separation, e3 adds a subtle
///    warm ember under-glow so hero cards read as lifted, never flat-on-black.
class Elevation {
  Elevation._();
  static const List<BoxShadow> e0 = [];
  static const List<BoxShadow> e1 = Shadows.card;
  static const List<BoxShadow> e2 = Shadows.sheet;
  static const List<BoxShadow> e3 = Shadows.lift;

  // Dark-mode depth: shadows are useless on char EXCEPT a faint penumbra
  // (separates a sheet from the surface under it) and, at e3, a low warm glow.
  static const List<BoxShadow> _darkE2 = [
    BoxShadow(color: Color(0x66000000), blurRadius: 28, offset: Offset(0, 14)),
  ];
  static const List<BoxShadow> _darkE3 = [
    BoxShadow(color: Color(0x73000000), blurRadius: 32, offset: Offset(0, 16)),
    BoxShadow(color: Color(0x1AFF7A4D), blurRadius: 36, offset: Offset(0, 6)),
  ];

  /// Resolve a level for the current mode — dark drops the drop-shadow entirely.
  /// (Legacy resolver — kept verbatim for existing call sites. New components
  /// use [shadows]/[border], which give dark its penumbra + glow.)
  static List<BoxShadow> forMode(List<BoxShadow> level, bool dark) =>
      dark ? const [] : level;

  /// Mode-correct shadow list for a semantic level 0..3.
  static List<BoxShadow> shadows(int level, {bool? dark}) {
    final d = dark ?? AppColors.isDark;
    return switch (level.clamp(0, 3)) {
      0 => e0,
      1 => d ? e0 : e1,
      2 => d ? _darkE2 : e2,
      _ => d ? _darkE3 : e3,
    };
  }

  /// Mode-correct hairline border for a level — dark gets the border (its
  /// primary depth cue, brightening slightly with level); light gets none.
  static Border? border(int level, {bool? dark}) {
    final d = dark ?? AppColors.isDark;
    if (!d || level <= 0) return null;
    final c = level >= 3
        ? const Color(0xFF3D362C) // brighter hairline on the lifted hero
        : AppColors.divider;
    return Border.all(color: c, width: 1);
  }

  /// Mode-correct fill for a level — on char, higher levels sit on lighter
  /// surfaces (surface → surfaceAlt); on paper everything is card white.
  static Color surfaceAt(int level, {bool? dark}) {
    final d = dark ?? AppColors.isDark;
    if (!d) return AppColors.surface;
    return level >= 2 ? AppColors.surfaceElevated : AppColors.surface;
  }
}

/// Motion.
class Motion {
  Motion._();
  static const fast = Duration(milliseconds: 180);
  static const med = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 520);
  static const ring = Duration(milliseconds: 1000);
  static const curve = Curves.easeOutCubic;
  static const emphatic = Curves.easeOutQuint;

  // ── Motion semantics — (duration, curve) pairs naming *why* something moves.
  //    Use like `Motion.enter.d` / `Motion.enter.c`. ──

  /// Content settling into place (list items, cards revealing).
  static const ({Duration d, Curve c}) enter = (d: med, c: curve);

  /// A responsive, slightly-overshooting pop (press, badge, chip).
  static const ({Duration d, Curve c}) springy = (
    d: med,
    c: Curves.easeOutBack,
  );

  /// A drawn-out, celebratory reveal (count-ups, finish card, PR pops).
  static const ({Duration d, Curve c}) celebratory = (d: slow, c: emphatic);

  /// Direct-manipulation follow (scrub thumbs, drag handles, seg-control
  /// thumbs tracking a finger) — near-instant and linear so it never lags
  /// the gesture.
  static const ({Duration d, Curve c}) scrub = (
    d: Duration(milliseconds: 90),
    c: Curves.linear,
  );
}
