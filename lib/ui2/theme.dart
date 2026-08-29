// The token boundary. Nothing below this file defines a colour, a size, a
// radius or a duration — everything else in lib/ui2 spends what is declared
// here, and `test/ui2_tokens_test.dart` fails the build if it doesn't.
//
// Three things this file owns that the previous design system did not:
//
//   1. CONTRAST IS SOLVED, NOT ASSERTED. Muted ink and every accent used as
//      text or as a fill are pushed to a WCAG AA (4.5:1) floor by `P.on` /
//      `P.fill`, against the worst surface they can legally land on. The old
//      caption token measured 2.20–2.71:1 across 223 call sites; a token that
//      *can* be misused eventually is. `test/ui2_contrast_test.dart` proves
//      the floor holds in both themes for every accent.
//   2. MOTION IS GATED ONCE. `motion()` and `animate()` are the only way to
//      get a non-zero duration, and they return `Duration.zero` when the
//      platform asks for reduced motion. No call site can opt out, and the
//      tokens test forbids `.repeat(` anywhere in lib/ui2 so an infinite loop
//      can never survive the gate. That gate reaches the NAVIGATOR too:
//      `buildTheme` installs a `pageTransitionsTheme` that returns the page
//      unanimated (22 routes were sliding at full duration under Reduce
//      Motion), and `sheetMotion()` does the same for the four modal sheets,
//      which do not consult a theme at all. Dialogs still use Flutter's own
//      fade-and-scale — small, centred, and the least nauseogenic of the
//      three — so they are deliberately left alone.
//   3. BOTH THEMES ARE DESIGNED. Every colour is defined for light and dark in
//      the same expression. There is no token that exists only inside a
//      dark-mode branch.

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// ── COLOUR ────────────────────────────────────────────────────────────────
///
/// Raw pigment. These are *not* safe to paint text with directly — most of
/// them fail AA on white. Run them through [P.on] (accent as text) or
/// [P.fill] (accent as a filled surface under [P.inkOnFill]) first.
class C {
  // primary
  static const green = Color(0xFF22C55E);
  static const greenD = Color(0xFF16A34A);
  static const blue = Color(0xFF3B82F6);
  static const purple = Color(0xFF8B5CF6);

  // secondary
  static const orange = Color(0xFFF97316);
  static const red = Color(0xFFEF4444);
  static const teal = Color(0xFF14B8A6);
  static const yellow = Color(0xFFEAB308);
  static const pink = Color(0xFFEC4899);
  static const indigo = Color(0xFF6366F1);

  /// Two light blues the ramps need and nothing else does: the light-sleep
  /// lane sits between REM and deep, and zone 1 sits below `blue`. They live
  /// here rather than inside the painters because a palette that is partly in
  /// theme.dart and partly in charts.dart is two palettes.
  static const sky = Color(0xFF7DD3FC);
  static const blueSoft = Color(0xFF93C5FD);

  /// The route ramp, and only the route ramp.
  ///
  /// Brighter and more saturated than the UI accents on purpose: this is the
  /// one mark in the app that is drawn over an arbitrary photograph and a
  /// darkened basemap rather than over a known surface, and the UI greens and
  /// reds — tuned to clear 4.5:1 as TEXT on a card — go muddy there.
  ///
  /// Deliberately NOT in [all]. `all` is the set the contrast sweep measures
  /// as ink and as fill, and these are neither: they are a line on a picture.
  /// Putting them in would be asking the wrong question of them.
  static const routeFast = Color(0xFF7CFF6B);
  static const routeMid = Color(0xFFFFC83D);
  static const routeHard = Color(0xFFFF8A30);
  static const routeSlow = Color(0xFFFF4D4D);

  /// The basemap's two ends, which is the whole of the map's styling: every
  /// tile pixel is mapped onto the line between them by `_themeFilter`.
  ///
  /// What makes the map READABLE is the distance between these two, not how
  /// low either one is. Both ends have been wrong once:
  ///
  ///   · ceiling `#4A5568` — OSM's land polygon is near-white and lands on
  ///     the ceiling, so the whole card became a mid-grey slab.
  ///   · ceiling `#232B39` — dark enough that land, water and roads all
  ///     collapsed into each other and the map vanished entirely. On a card
  ///     with no photo the map IS the content, so that is worse.
  ///
  /// This pair keeps the card unmistakably dark while leaving enough range
  /// between water, land and roads to read as a place. It is also the only
  /// lever there is on the labels and street names, which are rendered into
  /// the raster and cannot be asked for separately — they sit near the
  /// ceiling, so a ceiling this far down leaves them as texture, not type.
  static const mapFloor = Color(0xFF0A1018);
  static const mapCeil = Color(0xFF44536D);

  // neutrals
  static const n900 = Color(0xFF0F172A);
  static const n800 = Color(0xFF1E293B);
  static const n600 = Color(0xFF475569);
  static const n500 = Color(0xFF64748B);
  static const n400 = Color(0xFF94A3B8);
  static const n300 = Color(0xFFCBD5E1);
  static const n200 = Color(0xFFE2E8F0);
  static const n100 = Color(0xFFF1F5F9);
  static const n50 = Color(0xFFF8FAFC);

  static const white = Color(0xFFFFFFFF);

  /// Each domain owns an accent — the mental map is colour-coded, and the map
  /// is the point. These five are the five tabs, in order, forever.
  static const domHome = green;
  static const domHealth = blue;
  static const domFood = orange;
  static const domMove = purple;
  static const domMind = teal;

  /// Every accent the contrast test sweeps. Adding a colour above without
  /// adding it here means it ships unverified.
  static const all = <Color>[
    green, greenD, blue, purple, orange, red, teal, yellow, pink, indigo,
    sky, blueSoft,
    domHome, domHealth, domFood, domMove, domMind,
  ];
}

/// ── SURFACES + LEGIBLE INK ────────────────────────────────────────────────
///
/// Brightness-resolved. `P.of(context)` in every build method.
class P {
  final bool dark;
  const P(this.dark);

  static P of(BuildContext c) => P(Theme.of(c).brightness == Brightness.dark);

  Color get bg => dark ? const Color(0xFF0B1017) : C.n50;
  Color get card => dark ? const Color(0xFF151C26) : C.white;
  Color get card2 => dark ? const Color(0xFF1D2632) : C.n100;
  Color get line => dark ? const Color(0xFF232D3B) : C.n200;
  Color get track => dark ? const Color(0xFF232D3B) : C.n200;

  Color get ink => dark ? const Color(0xFFF1F5F9) : C.n900;
  Color get ink2 => dark ? const Color(0xFF94A3B8) : C.n600;

  /// The muted caption ink. Hand-solved to clear 4.5:1 on [card2], the darkest
  /// (light theme) / lightest (dark theme) surface it can sit on — so it is
  /// legible on every surface, not just the one it was eyeballed against.
  /// The values it replaces measured 4.34:1 and 3.21:1 respectively.
  Color get ink3 => dark ? const Color(0xFF7F8DA0) : const Color(0xFF627188);

  /// The ink that goes on top of a [fill]. White by construction — [fill]
  /// darkens the accent until white clears AA on it.
  Color get inkOnFill => C.white;

  /// [accent] rendered as TEXT on one of this brightness' surfaces, nudged
  /// toward the page ink until it clears [_aa] against the worst legal
  /// surface ([card2]). `C.green` on white measures 2.28:1 raw; `on(C.green)`
  /// measures 4.53:1 and still reads unmistakably green.
  ///
  /// Solved TWICE, against the two worst surfaces it can land on. `card2` is
  /// the flat one; the other is `wash(accent)` over it — the Pill and the
  /// active SubTabs chip put this ink on a tinted background nothing was
  /// solving against, and five of six accents measured 4.30–4.49 there. The
  /// solver only ever nudges toward the page ink, so clearing the second
  /// surface cannot un-clear the first.
  Color on(Color accent) {
    final toward = dark ? ink : C.n900;
    final flat = _solve(accent, toward, card2, dark);
    return _solve(flat, toward, Color.alphaBlend(wash(accent), card2), dark);
  }

  /// [accent] rendered as a FILLED surface under [inkOnFill], darkened until
  /// white text on it clears [_aa]. Buttons, chips, CTA badges.
  Color fill(Color accent) => _solve(accent, const Color(0xFF000000), C.white, false);

  /// A tinted wash of [accent] — the InsightCard / Pill / active-tab
  /// background. Never carries text of its own colour; pair it with [on].
  ///
  /// [strength] is capped at 1: full strength is the tint [on] and [ink3] were
  /// solved against, and a caller asking for 1.6 was pushing muted ink to
  /// 2.99:1 on its own card. A wash darker than a wash is a fill.
  Color wash(Color accent, {double strength = 1}) =>
      accent.withValues(alpha: (dark ? .18 : .11) * strength.clamp(0.0, 1.0));

  List<BoxShadow> el(int level) {
    if (level <= 0) return const [];
    if (dark) {
      return [
        BoxShadow(
          color: const Color(0xFF000000).withValues(alpha: .32 + level * .06),
          blurRadius: 6.0 * level,
          offset: Offset(0, level.toDouble()),
        ),
      ];
    }
    return [
      BoxShadow(
        color: C.n900.withValues(alpha: .04 + level * .015),
        blurRadius: 5.0 * level,
        offset: Offset(0, level * 1.2),
      ),
    ];
  }

  // ── the solver ──────────────────────────────────────────────────────────
  // WCAG 2.1 AA for body text. Non-text UI is allowed 3:1, but a caption that
  // is "technically an indicator" is how the 2.20:1 tokens got shipped, so
  // there is one floor here and it is the strict one.
  static const _aa = 4.5;

  static final _cache = <int, Color>{};

  /// Binary-search the lerp from [c] toward [toward] for the first colour that
  /// clears [_aa] against [against]. 24 steps is well past 8-bit resolution.
  static Color _solve(Color c, Color toward, Color against, bool dark) {
    final key = Object.hash(c.toARGB32(), toward.toARGB32(),
        against.toARGB32(), dark);
    final hit = _cache[key];
    if (hit != null) return hit;
    var out = c;
    if (contrast(c, against) < _aa) {
      var lo = 0.0, hi = 1.0;
      for (var i = 0; i < 24; i++) {
        final mid = (lo + hi) / 2;
        if (contrast(Color.lerp(c, toward, mid)!, against) >= _aa) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      out = Color.lerp(c, toward, hi)!;
    }
    // Bounded: one entry per (accent, brightness) pair actually used, and the
    // accent set is a compile-time constant.
    _cache[key] = out;
    return out;
  }

  /// WCAG 2.1 contrast ratio, 1.0 … 21.0. Public so the contrast test and any
  /// future palette work measure with exactly the same function the tokens do.
  /// Luminance is `Color.computeLuminance()` — same WCAG formula, no need to
  /// carry our own copy of it.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = math.max(la, lb), lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }
}

/// ── TYPE ── 7 steps, 3 weights, tabular figures on anything that changes ──
///
/// The family is the platform's own text face where it exists, falling back to
/// the bundled Manrope (assets/fonts/Manrope) everywhere else — so Android and
/// the golden tests render the same shapes the design was drawn in rather than
/// silently landing on Roboto.
class F {
  static const _f = '.SF Pro Text';
  static const _fb = ['Manrope'];
  static const _tab = [FontFeature.tabularFigures()];

  // The 7 steps.
  static const display = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 34,
      height: 40 / 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -.8);
  static const t1 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 28,
      height: 34 / 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -.5);
  static const t2 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 22,
      height: 28 / 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -.4);
  static const head = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 17,
      height: 24 / 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -.2);
  static const body = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 15,
      height: 22 / 15,
      letterSpacing: -.1);
  static const cap = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb, fontSize: 13, height: 18 / 13);
  static const over = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w600,
      letterSpacing: .5);

  // Numerals — a parallel display ramp. Tabular, so a live value never jitters
  // its own layout as digits change.
  static const n48 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 48,
      height: 1,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.8,
      fontFeatures: _tab);
  static const n34 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 34,
      height: 1,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.2,
      fontFeatures: _tab);
  static const n24 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 24,
      height: 1,
      fontWeight: FontWeight.w700,
      letterSpacing: -.7,
      fontFeatures: _tab);
  static const n17 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 17,
      height: 1,
      fontWeight: FontWeight.w600,
      letterSpacing: -.3,
      fontFeatures: _tab);
}

/// ── SPACING ── 4pt base ───────────────────────────────────────────────────
class S {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;
  static const x16 = 64.0;

  /// The minimum comfortable target, enforced inside `Pressable`. Apple HIG
  /// and WCAG 2.5.5 both land here.
  static const tap = 44.0;
}

/// ── RADII ─────────────────────────────────────────────────────────────────
class R {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const pill = 999.0;

  static const rSm = BorderRadius.all(Radius.circular(sm));
  static const rMd = BorderRadius.all(Radius.circular(md));
  static const rLg = BorderRadius.all(Radius.circular(lg));
  static const rXl = BorderRadius.all(Radius.circular(xl));
  static const rXxl = BorderRadius.all(Radius.circular(xxl));
  static const rPill = BorderRadius.all(Radius.circular(pill));
}

/// ── MOTION ── one gate, no exceptions ─────────────────────────────────────
///
/// The audit found zero reduced-motion support and 13 infinite `.repeat()`
/// loops. Both are structural problems, so both get structural answers: these
/// are the only durations in the system, and `test/ui2_tokens_test.dart`
/// forbids `.repeat(` in lib/ui2 outright. Ambient motion that genuinely needs
/// to loop takes its phase from a caller-owned value (see `BreathRing.t`), so
/// the screen owns the ticker and the same gate stops it.
class Motion {
  /// True when the platform is NOT asking for reduced motion.
  static bool enabled(BuildContext c) =>
      MediaQuery.maybeDisableAnimationsOf(c) != true;

  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 280);

  /// The session clock. A live workout counts REAL seconds, so this is the one
  /// duration that must NOT pass through [motion] — reduced motion silences
  /// animation, it does not stop time. It lives here because theme.dart is the
  /// only file allowed to write a `Duration(…)`, and a screen inventing its own
  /// tick is how thirteen ungated tickers happened last time.
  static const tick = Duration(seconds: 1);

  /// One full breath cycle for the paced-breathing ring — 5 s in, 5 s out is
  /// the pace the breathing session already uses. The PHASE is still owned by
  /// the screen (see `BreathRing.t`); this is only how long a cycle lasts, and
  /// the screen must not start it at all when [enabled] is false.
  static const breath = Duration(seconds: 5);
}

/// Collapse [d] to zero when the user has asked for reduced motion. Every
/// `AnimatedFoo`, `AnimationController` and implicit transition in lib/ui2
/// takes its duration from here.
Duration motion(BuildContext c, Duration d) =>
    Motion.enabled(c) ? d : Duration.zero;

/// The animated-progress form: returns `1` (finished) instead of `t` when
/// motion is off, so a chart that draws itself in still ends up fully drawn.
double animate(BuildContext c, double t) => Motion.enabled(c) ? t : 1;

/// The motion gate for `showModalBottomSheet`, which takes an [AnimationStyle]
/// rather than reading [ThemeData.pageTransitionsTheme] like a route does.
/// Null keeps the platform default; [AnimationStyle.noAnimation] cuts straight
/// to the open sheet.
AnimationStyle? sheetMotion(BuildContext c) =>
    Motion.enabled(c) ? null : AnimationStyle.noAnimation;

/// True once the user's text scale has passed the point where a card's header
/// can no longer be one line. The number is not a device class — it is where
/// `label · value · unit` stops fitting a phone's width — and it is shared so
/// that every card that has to restack does it at the same moment.
bool bigText(BuildContext c) => MediaQuery.textScalerOf(c).scale(1) > 1.3;

/// Reduced motion has to reach the NAVIGATOR, not only the widgets inside it.
/// `TransitionRoute` builds its controller straight from `transitionDuration`
/// and never asks whether animations are disabled, so before this every push
/// slid at full duration for exactly the people who turned the setting on —
/// and a full-screen slide is the most nauseogenic thing the app does.
///
/// Sheets and dialogs do not consult a theme at all; those pass
/// `AnimationStyle.noAnimation` at their call sites.
class _Gated extends PageTransitionsBuilder {
  /// Whatever the SDK ships for this platform — taken from the default theme
  /// rather than named here, so the app keeps the native transition and this
  /// gate does not quietly become a second opinion about what it should be.
  final PageTransitionsBuilder inner;
  const _Gated(this.inner);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext c,
      Animation<double> animation, Animation<double> secondary, Widget child) {
    if (!Motion.enabled(c)) return child;
    return inner.buildTransitions(route, c, animation, secondary, child);
  }
}

ThemeData buildTheme(Brightness b) {
  final p = P(b == Brightness.dark);
  return ThemeData(
    brightness: b,
    scaffoldBackgroundColor: p.bg,
    colorScheme:
        ColorScheme.fromSeed(seedColor: C.green, brightness: b, surface: p.card),
    fontFamily: '.SF Pro Text',
    fontFamilyFallback: const ['Manrope'],
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final e in const PageTransitionsTheme().builders.entries)
        e.key: _Gated(e.value),
    }),
  );
}
