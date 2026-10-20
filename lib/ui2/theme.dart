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
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// ── COLOUR ────────────────────────────────────────────────────────────────
///
/// Raw pigment. These are *not* safe to paint text with directly — most of
/// them fail AA on white. Run them through [P.on] (accent as text) or
/// [P.fill] (accent as a filled surface under [P.inkOn]) first.
class C {
  // ── Volt brand ── (docs/design/DESIGN_OVERHAUL.md §4.2)
  //
  // One action colour. Volt means "act here / you are here / good"; it is
  // never TEXT on a light surface (1.37:1 on white) and never carries white
  // ink (1.37:1). [P.fill] keeps it pure and [P.inkOn] puts dark ink on it.
  static const volt = Color(0xFFB1F002);

  /// Signal, not brand: low, attention, destructive. Dark ink on it, never
  /// white (2.9:1).
  static const coral = Color(0xFFFB6B53);

  /// Secondary dark chips and inactive controls on cream.
  static const slate = Color(0xFF3A444B);

  /// The two ends of the monochrome system. `char` is the dark ink on every
  /// light fill and the chrome on cream; `cream` is the light canvas and the
  /// ScallopBadge disc in BOTH themes.
  static const char = Color(0xFF0F1014);
  static const cream = Color(0xFFF2F1EC);

  // ── the data palette ── (§4.3) domain hues for charts, aurora, hero glow.
  // Every one clears 4.5:1 as text on the dark card2 and as a fill under
  // dark ink; in light they pass through [P.on] like any accent.
  static const lavender = Color(0xFFA99BFF);
  static const sky = Color(0xFF6EC3FF);
  static const rose = Color(0xFFFF7A9A);
  static const sage = Color(0xFF9FD4B4);
  static const amber = Color(0xFFFFB547);
  static const aqua = Color(0xFF5ED3C9);

  /// The hypnogram's lavender ramp, palest to deepest (§5.5): awake, REM,
  /// light, deep. `lavender` is the light-sleep step; these are the other
  /// three. The painter solves each against the surface, so they are the HUE,
  /// not the lightness that is finally drawn.
  static const sleepAwake = Color(0xFFE6E1FF);
  static const sleepRem = Color(0xFFC7BDFF);
  static const sleepDeep = Color(0xFF6F5CF0);

  /// The bottom of the HR-zone ramp (§5.5: slate-blue → sky → volt → amber →
  /// coral). The one hue here that is not a domain colour: zone 1 has to sit
  /// below [sky] without being grey, and nothing else needs it.
  static const blueSoft = Color(0xFF93A9C9);

  // ── the old accents, kept as aliases ──
  //
  // Hundreds of call sites name these, so they stay — but each now resolves
  // to a Volt hue, so no off-palette colour survives. Nearest hue wins; where
  // two old accents land on one new one (blue/sky, purple/indigo,
  // orange/yellow) the old pair never had to be told apart.
  static const green = volt;
  static const red = coral;
  static const blue = sky;
  static const purple = lavender;
  static const indigo = lavender;
  static const teal = aqua;
  static const orange = amber;
  static const yellow = amber;
  static const pink = rose;

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
  ///
  /// Slow to fast it runs blue, sky, amber, orange: the same direction as the
  /// in-app route (blue slower, orange faster), and no red against green for
  /// a colour-blind reader to lose.
  static const routeFast = Color(0xFFFF8A30);
  static const routeMid = Color(0xFFFFC83D);
  static const routeHard = Color(0xFF7DD3FC);
  static const routeSlow = Color(0xFF3D9BFF);

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

  // neutrals — warm greys between char and cream, matching the surfaces. Only
  // the steps something still names; the rest went with the aliases (Phase 7).
  static const n900 = char;
  static const n500 = Color(0xFF5F646D);
  static const n400 = Color(0xFF8B9099);

  static const white = Color(0xFFFFFFFF);

  /// Each domain owns a hue. Since Volt (decision D1) it no longer colours the
  /// tab bar — the active tab is always volt — it lives in the screen's hero
  /// glow and aurora instead. Food and mind keep theirs as sections inside
  /// Activity and Health.
  static const domHome = volt;
  static const domSleep = lavender;
  static const domHealth = rose;
  static const domFood = amber;
  static const domMove = sky;
  static const domMind = sage;

  /// Every accent the contrast test sweeps. Adding a colour above without
  /// adding it here means it ships unverified.
  static const all = <Color>[
    volt, coral, slate, lavender, sky, rose, sage, amber, aqua, blueSoft,
    sleepAwake, sleepRem, sleepDeep,
    green, blue, purple, orange, red, teal, yellow, pink, indigo,
    domHome, domSleep, domHealth, domFood, domMove, domMind,
  ];
}

/// ── SURFACES + LEGIBLE INK ────────────────────────────────────────────────
///
/// Brightness-resolved. `P.of(context)` in every build method.
class P {
  final bool dark;
  const P(this.dark);

  static P of(BuildContext c) => P(Theme.of(c).brightness == Brightness.dark);

  // ── surfaces ── (§4.1) "Char" in dark, "Cream" in light.
  Color get bg => dark ? const Color(0xFF08090B) : C.cream;
  Color get card => dark ? const Color(0xFF131418) : C.white;
  Color get card2 => dark ? const Color(0xFF1C1E23) : const Color(0xFFE9E8E2);
  Color get line => dark ? const Color(0xFF25282E) : const Color(0xFFDCDBD4);
  Color get track => dark ? const Color(0xFF2A2D33) : const Color(0xFFE2E1DA);

  Color get ink => dark ? const Color(0xFFF4F4F1) : C.char;
  Color get ink2 => dark ? const Color(0xFFA7AAB1) : const Color(0xFF474B53);

  /// The muted caption ink. Hand-solved to clear 4.5:1 on [card2], the darkest
  /// (light theme) / lightest (dark theme) surface it can sit on — so it is
  /// legible on every surface, not just the one it was eyeballed against.
  /// 5.2:1 (dark) and 4.85:1 (light) on card2.
  Color get ink3 => dark ? const Color(0xFF8B9099) : const Color(0xFF5F646D);

  /// The frosted-glass tint: the card at 72%, under a 24 px blur. Its solid
  /// fallback (high contrast, `Perf.lowGlass`) is this blended over [bg].
  Color get glass => card.withValues(alpha: .72);

  /// Black chrome on cream, cream chrome on char — the round icon buttons,
  /// the active SubTabs pill, snackbars. Monochrome on purpose: volt is
  /// spent on action, not on "selected".
  Color get inverse => dark ? const Color(0xFFF4F4F1) : C.char;
  Color get onInverse => dark ? C.char : const Color(0xFFF4F4F1);

  /// The ink that goes on top of a [fill] — whichever of dark ink or white
  /// clears 4.5:1 on it, dark preferred. Volt, coral and every data hue take
  /// dark ink; only a fill dark enough to have been solved for white gets it.
  Color inkOn(Color fill) =>
      contrast(C.char, fill) >= _aa ? C.char : C.white;


  /// [accent] rendered as TEXT on one of this brightness' surfaces, nudged
  /// toward the page ink until it clears [_aa] against the worst legal
  /// surface ([card2]). `C.volt` on cream measures 1.3:1 raw; `on(C.volt)`
  /// clears 4.5:1 and still reads as a green.
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

  /// [accent] rendered as a FILLED surface under [inkOn]. Buttons, chips,
  /// CTA badges.
  ///
  /// The pure pigment whenever dark ink clears [_aa] on it — volt stays volt
  /// instead of being darkened into olive for white text. Only a pigment too
  /// dark for dark ink (slate, say) falls back to the old solve: darkened
  /// until WHITE clears [_aa], and [inkOn] then picks white.
  Color fill(Color accent) => contrast(C.char, accent) >= _aa
      ? accent
      : _solve(accent, const Color(0xFF000000), C.white, false);

  /// A tinted wash of [accent] — the InsightCard / Pill / active-tab
  /// background. Never carries text of its own colour; pair it with [on].
  ///
  /// [strength] is capped at 1: full strength is the tint [on] and [ink3] were
  /// solved against, and a caller asking for 1.6 was pushing muted ink to
  /// 2.99:1 on its own card. A wash darker than a wash is a fill.
  Color wash(Color accent, {double strength = 1}) =>
      accent.withValues(alpha: (dark ? .18 : .11) * strength.clamp(0.0, 1.0));

  /// The brightest point of an AuroraTile's gradient of [hue], already
  /// blended over the card: the surface the tile's text has to clear 4.5:1
  /// on. Solved, not chosen — the hue's alpha is the most the page [ink] can
  /// take, capped where a colour field stops being a wash and becomes a fill.
  Color aurora(Color hue) {
    final key = Object.hash(hue.toARGB32(), dark, 'aurora');
    final hit = _cache[key];
    if (hit != null) return hit;
    Color at(double a) => Color.alphaBlend(hue.withValues(alpha: a), card);
    var lo = 0.0, hi = dark ? .55 : .45;
    if (contrast(ink, at(hi)) < _aa) {
      for (var i = 0; i < 24; i++) {
        final mid = (lo + hi) / 2;
        if (contrast(ink, at(mid)) >= _aa) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      hi = lo;
    }
    return _cache[key] = at(hi);
  }

  /// Elevation. Dark is flat — no shadow, a hairline does the work (§4.6).
  /// Light gets one soft shadow: 0 / 8 / 24, ink at 6%, deepening per level.
  List<BoxShadow> el(int level) {
    if (level <= 0 || dark) return const [];
    return [
      BoxShadow(
        color: C.char.withValues(alpha: .06 * level.clamp(1, 3)),
        blurRadius: 24.0 * level,
        offset: Offset(0, 8.0 * level),
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

/// ── TYPE ── 7 steps + 5 numerals, tabular figures on anything that changes ─
///
/// One bundled family on every platform — Outfit (SIL OFL, assets/fonts/Outfit)
/// — so iOS, Android and the golden tests render the same design. It has no
/// Cyrillic: Russian falls through to the bundled Manrope, which does, rather
/// than to whatever the platform has, so Russian measures the same everywhere.
///
/// Large type is LIGHTER than body-heavy UIs expect: display and hero numerals
/// are w500, titles w600, body w400 (§4.5).
class F {
  static const family = 'Outfit';
  static const _f = family;
  static const _fb = ['Manrope'];
  static const _tab = [FontFeature.tabularFigures()];

  // The 7 steps.
  static const display = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 36,
      height: 42 / 36,
      fontWeight: FontWeight.w500,
      letterSpacing: -.8);
  static const t1 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 28,
      height: 34 / 28,
      fontWeight: FontWeight.w500,
      letterSpacing: -.5);
  static const t2 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 22,
      height: 28 / 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -.3);
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
      fontWeight: FontWeight.w400,
      letterSpacing: -.1);
  static const cap = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w400);
  /// Callers uppercase it.
  static const over = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w600,
      letterSpacing: .6);

  // Numerals — a parallel display ramp. Tabular, so a live value never jitters
  // its own layout as digits change. Units sit beside them in cap/body, ink3.
  static const n64 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 64,
      height: 1,
      fontWeight: FontWeight.w500,
      letterSpacing: -2.4,
      fontFeatures: _tab);
  static const n48 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 48,
      height: 1,
      fontWeight: FontWeight.w500,
      letterSpacing: -1.6,
      fontFeatures: _tab);
  static const n34 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 34,
      height: 1,
      fontWeight: FontWeight.w500,
      letterSpacing: -1.0,
      fontFeatures: _tab);
  static const n24 = TextStyle(
      fontFamily: _f,
      fontFamilyFallback: _fb,
      fontSize: 24,
      height: 1,
      fontWeight: FontWeight.w600,
      letterSpacing: -.6,
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
  /// Half a step: the 2 pt optical nudge (a text baseline against an icon).
  static const half = 2.0;
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

  /// Screen side padding, one value for every screen.
  static const gutter = 20.0;

  /// The floating tab bar's height (§5.3).
  static const navBar = 64.0;

  /// Bottom padding for a tab's scroll view so its last row clears the
  /// floating bar: the bar, its gap above the safe area, and air above it.
  /// A function, not a constant — the safe area is the phone's.
  static double navClear(BuildContext c) =>
      MediaQuery.paddingOf(c).bottom + x4 + navBar + x4;
}

/// ── RADII ─────────────────────────────────────────────────────────────────
///
/// Rounder than before (§4.6): every `Surface` card is [xl], hero tiles and
/// sheet tops [xxl], buttons, chips and the nav a [pill].
class R {
  static const sm = 10.0;
  static const md = 16.0;
  static const lg = 22.0;
  static const xl = 28.0;
  static const xxl = 36.0;
  static const pill = 999.0;

  static const rSm = BorderRadius.all(Radius.circular(sm));
  static const rMd = BorderRadius.all(Radius.circular(md));
  static const rLg = BorderRadius.all(Radius.circular(lg));
  static const rXl = BorderRadius.all(Radius.circular(xl));
  static const rXxl = BorderRadius.all(Radius.circular(xxl));
  static const rPill = BorderRadius.all(Radius.circular(pill));
}

/// ── ICON SIZES ── five steps; every `Icon(size:)` in lib/ui2 uses one ────
class I {
  static const sm = 16.0;
  static const md = 20.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const hero = 48.0;
}

/// ── ART ── the bundled imagery slots (§5.6) ───────────────────────────────
///
/// The ONLY way a screen names an image: no screen writes an asset path. Files
/// are transparent PNGs/WebP under assets/images/ (with 2.0x / 3.0x variants
/// Flutter picks by itself); see docs/design/IMAGE_PROMPTS.md. A slot whose
/// file has not landed yet draws NOTHING — never a broken-image icon — so
/// code can ship before art does.
enum Art {
  // The band: pictures of the device, WebP with 2.0x and 3.0x siblings.
  bandHero('art_band_hero', 'webp'),
  bandSide('art_band_side', 'webp'),
  bandTop('art_band_top', 'webp'),
  // Everything else is drawn: flat, hand-cut silhouettes in one cream and one
  // data hue, as SVG — a few hundred bytes each, sharp at any size, and the
  // same on every platform. 400 x 400 viewBox, centred.
  ring('art_ring', 'svg'),
  watch('art_watch', 'svg'),
  chestStrap('art_chest_strap', 'svg'),
  workout('art_workout', 'svg'),
  wellness('art_wellness', 'svg'),
  sleep('art_sleep', 'svg'),
  food('art_food', 'svg'),
  heart('art_heart', 'svg');

  const Art(this.stem, this.ext);
  final String stem, ext;

  String get asset => 'assets/images/$stem.$ext';

  /// The picture, or nothing. Decorative unless [semanticLabel] is given, in
  /// which case a screen reader says it.
  Widget image({String? semanticLabel, double? height, BoxFit fit = BoxFit.contain}) {
    if (ext == 'svg') {
      return SvgPicture.asset(
        asset,
        height: height,
        fit: fit,
        semanticsLabel: semanticLabel,
        excludeFromSemantics: semanticLabel == null,
        // A missing file draws nothing, never an error box.
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Image.asset(
      asset,
      height: height,
      fit: fit,
      semanticLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// ── EFFECTS ── the numbers behind Glass, AuroraTile and ScallopBadge ──────
class Fx {
  /// Glass blur radius (both axes), under a [P.glass] tint.
  static const glassBlur = 24.0;

  /// The AuroraTile grain (assets/images/grain.png), tiled, at this opacity.
  static const grainOpacity = .04;
  static const grainAsset = 'assets/images/grain.png';

  /// The ScallopBadge outline: [scallopLobes] bumps, each [scallopDepth] of
  /// the radius deep.
  static const scallopLobes = 12;
  static const scallopDepth = .06;

  /// The onboarding StepPath stroke.
  static const stepPathStroke = 10.0;
}

/// ── PERFORMANCE ── escape hatches (§5.7) ─────────────────────────────────
class Perf {
  /// When true every `Glass` renders solid, with no BackdropFilter. Wired to
  /// nothing yet: it is the switch to throw if Android jank shows up.
  static const lowGlass = false;
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

  /// One-time hero draw-ins only — a ring filling, the scallop arriving.
  /// Never on layout, never looped.
  static const hero = Duration(milliseconds: 420);

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

  /// One pulse of the ECG capture screen's contact rings. Phase is owned by
  /// the screen (like [breath]); nothing runs when [enabled] is false.
  static const ecgPulse = Duration(seconds: 2);

  /// The ECG live-preview repaint cadence: incoming packets only mark the
  /// ring dirty, and the screen's clock repaints at most this often.
  static const ecgPreviewTick = Duration(milliseconds: 100);
}

/// The two curves. [emphasized] overshoots, so it is for SCALE only — on a
/// layout property the overshoot would push its neighbours around.
class Ease {
  static const standard = Curves.easeOutCubic;
  static const emphasized = Curves.easeOutBack;
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

/// The Material theme. ui2 components never read it — they spend `P` and `F`
/// directly — so this exists for the Material widgets screens still use
/// (pickers, snackbars, dividers, progress, dialogs, sheets: docs/design/
/// AUDIT.md §2). Each gets a sub-theme here instead of an edit at ~180 call
/// sites (decision D8).
///
/// `primary` is the colour Material spends on TEXT (dialog actions, the
/// selected day in a picker's header), so it is volt only where volt is
/// legible as text: in dark. In light it is the char ink, and volt appears
/// only as a fill under dark ink.
ThemeData buildTheme(Brightness b) {
  final p = P(b == Brightness.dark);
  final primary = p.dark ? C.volt : C.char;
  final scheme = ColorScheme.fromSeed(
    seedColor: C.volt,
    brightness: b,
    surface: p.card,
  ).copyWith(
    primary: primary,
    onPrimary: p.inkOn(primary),
    primaryContainer: p.fill(C.volt),
    onPrimaryContainer: p.inkOn(p.fill(C.volt)),
    secondary: p.inverse,
    onSecondary: p.onInverse,
    surface: p.card,
    onSurface: p.ink,
    onSurfaceVariant: p.ink2,
    surfaceContainerHighest: p.card2,
    surfaceContainerHigh: p.card2,
    surfaceContainer: p.card,
    surfaceContainerLow: p.card,
    outline: p.line,
    outlineVariant: p.line,
    error: p.on(C.coral),
    onError: p.card,
  );
  const sheetTop = BorderRadius.vertical(top: Radius.circular(R.xxl));
  return ThemeData(
    brightness: b,
    scaffoldBackgroundColor: p.bg,
    colorScheme: scheme,
    fontFamily: F.family,
    fontFamilyFallback: const ['Manrope'],
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.ink,
      linearTrackColor: p.track,
      circularTrackColor: const Color(0x00000000),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.inverse,
      contentTextStyle: F.body.copyWith(color: p.onInverse),
      actionTextColor: p.onInverse,
      shape: const RoundedRectangleBorder(borderRadius: R.rLg),
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      titleTextStyle: F.t2.copyWith(color: p.ink),
      contentTextStyle: F.body.copyWith(color: p.ink2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.card,
      modalBackgroundColor: p.card,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(borderRadius: sheetTop),
      dragHandleColor: p.line,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.card,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      headerForegroundColor: p.ink,
      dividerColor: p.line,
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: p.card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      dialBackgroundColor: p.card2,
      hourMinuteShape: const RoundedRectangleBorder(borderRadius: R.rMd),
      dayPeriodShape: const RoundedRectangleBorder(borderRadius: R.rMd),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(borderRadius: R.rLg),
      textStyle: F.body.copyWith(color: p.ink),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: F.body.copyWith(color: p.ink),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.card),
        shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: R.rLg)),
      ),
    ),
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final e in const PageTransitionsTheme().builders.entries)
        e.key: _Gated(e.value),
    }),
  );
}

/// Char in both themes: the two surfaces allowed to stay dark when the app is
/// light — onboarding and the live workout (DESIGN_OVERHAUL.md §6, D4).
///
/// The ONE theme override in lib/ui2. `P.of` reads the ambient [Theme], so a
/// subtree that must be Char needs one, and keeping it here means no screen
/// writes its own `Theme(...)`. The dark theme is built once and shared.
class AlwaysChar extends StatelessWidget {
  final Widget child;
  const AlwaysChar({super.key, required this.child});

  static final _char = buildTheme(Brightness.dark);

  @override
  Widget build(BuildContext c) => AnnotatedRegion<SystemUiOverlayStyle>(
        // Light status-bar glyphs over the char page, whatever the app is.
        value: SystemUiOverlayStyle.light,
        child: Theme(data: _char, child: child),
      );
}
