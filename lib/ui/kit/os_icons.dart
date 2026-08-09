// OsAppIcon — the edge-side icon seam.
//
// This used to re-export a package of full-colour illustrated PNG/WebP icons
// (`openstrap_icons`). That dependency is GONE. `OsIcon` is now a LOCAL enum
// with the same member names it always had, so none of the ~370 call sites
// across the app (or the ~15 design-system widgets that take `OsIcon` as a
// parameter type) needed to change. Each member now resolves to a normal
// vector glyph instead of an illustration, rendered through one normalizer so
// sizing/visual weight stays consistent no matter which pack a given icon
// actually comes from.
//
// Packs are mixed deliberately, picked per concept for the best semantic fit
// ("best in its own zone"), not one pack for everything:
//  - phosphor_flutter (Duotone weight) — the primary "hero" biometric/domain
//    glyphs. It's the only pack here with a genuine two-layer duotone
//    render, which is the closest replacement for the old illustrations at
//    the 28-40px card/hero sizes those used to occupy.
//  - solar_icons (Bold weight) — literal sport glyphs (running/bicycling/
//    walking/swimming) and sleep-stage variants (moonSleep/moonStars/bed);
//    the strongest workout-icon coverage of the packs evaluated.
//  - iconsax_flutter — battery/bluetooth (both have several concrete
//    variants in this pack) and the heartbeat-zigzag "activity" glyph
//    (used for the cardio + resting-HR family).
//  - fluentui_system_icons (Regular weight) — plain monochrome chrome
//    (arrows, check, cancel, settings, calendar…). Small utility glyphs read
//    crisper as flat single-tone icons than duotone at 16-20px, so Fluent
//    (MIT, Microsoft-maintained, by far the largest/most-liked of the packs
//    evaluated) is the deliberate landing spot for all of it.
//  - hugeicons — kept installed and wired in for exactly the two concepts it
//    wins outright: a literal ECG-monitor waveform (`ecgRhythm`) and a
//    literal blood-drop (`menstrualFlow`) that none of the other four packs
//    has a real equivalent for.
//
// A handful of concepts have no literal glyph in any general-purpose icon
// pack (HRV waveform, body strain, a "recovery ring", sleep-stage glyphs,
// VO2max, "recap"). Those use the closest reasonable generic substitute —
// see the per-member comment on the enum below for which, and why.
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart' show FluentIcons;
import 'package:hugeicons/hugeicons.dart' show HugeIcons;
import 'package:iconsax_flutter/iconsax_flutter.dart' show Iconsax;
import 'package:phosphor_flutter/phosphor_flutter.dart'
    show
        PhosphorIconsDuotone,
        PhosphorIconsRegular,
        PhosphorIcon,
        PhosphorDuotoneIconData;
import 'package:solar_icons/solar_icons.dart' show SolarIconsBold;

import '../../theme/tokens.dart';
import '../design/domains.dart';

/// Semantic identifiers for every glyph the app can show. Historically these
/// mapped to illustrated asset base names; now each maps to a vector
/// [IconData] from one of the packs described above (see [_glyphs]).
enum OsIcon {
  today,
  sleep,
  heart,
  heartRate,
  restingHeartRate,
  maxHeartRate,
  heartRateZones,
  heartRateRecovery,
  hrv,
  recovery,
  bodyStrain,
  workouts,
  steps,
  distance,
  vo2max,
  awake,
  bedtime,
  lightSleep,
  deepSleep,
  sleepHypnogram,
  ecgRhythm,
  stress,
  calm,
  calories,
  intensity,
  elevation,
  skinTemperature,
  temperatureDeviation,
  activity,
  ai,
  alarm,
  edit,
  notifications,
  profile,
  recap,
  records,
  streak,
  strength,
  add,
  cardio,
  yoga,
  run,
  cycling,
  walk,
  swim,
  hiit,
  // Sport glyphs for the workout-type vocabulary beyond the original nine.
  // A type earns a place in `kWorkoutTypes` only when a pack draws something
  // recognisable for it, because a picker full of near-identical stand-ins is
  // worse than a shorter picker. That bar is "recognisable", not "literal":
  // two of these are acknowledged approximations (see `rowing` and `pilates`
  // in the map below), which is exactly why elliptical and dance were left
  // out — nothing in any pack reads as either.
  boxing,
  rowing,
  hike,
  climb,
  ski,
  snowboard,
  stairs,
  pilates,
  tennis,
  basketball,
  soccer,
  golf,
  workoutOther,
  hydration,
  /// Period/flow marker on the cycle screen. NEW member — the cycle screen
  /// used to reuse [hydration] (a plain water droplet) for this, which was a
  /// semantic mismatch (hydration reminders vs. menstrual flow). Added here
  /// with its own glyph (see [_glyphs]); the only 3 call sites that used to
  /// say `OsIcon.hydration` for this concept now say `OsIcon.menstrualFlow`
  /// (lib/ui/cycle/cycle_screen.dart).
  menstrualFlow,
  wear,
  calendar,
  history,
  battery,
  bluetooth,
  settings,
  share,
  privacy,
  sync,
  info,
  check,
  cancel,
  trash,
  plus,
  arrowRight,
  arrowLeft,
  up,
  down,
  logout,
  server,
  shield,
  // Community/social brand marks (Profile → Community links). These DID
  // exist as real call sites all along (`profile_screen.dart`'s `_socials`
  // list) — just passing `OsIcon.activity` as a stand-in for every one of
  // them, not an actual per-brand glyph. An earlier pass at this migration
  // checked for direct `OsIcon.github`-style references, found none, and
  // wrongly concluded the concept itself was unused — missed that the call
  // sites were already degraded to a generic icon rather than removed.
  github,
  discord,
  reddit,
  xTwitter,
}

/// The pack-specific glyph for each [OsIcon]. `IconData` is the common
/// currency every pack here exports (phosphor's Duotone data subclasses
/// `IconData`, so it fits the same map without a wrapper type).
const Map<OsIcon, IconData> _glyphs = {
  OsIcon.today: PhosphorIconsDuotone.house,
  OsIcon.sleep: PhosphorIconsDuotone.moon,
  OsIcon.heart: PhosphorIconsDuotone.heart,
  // Distinct from `heart` — a "straight line" heart glyph reads as the
  // measurement (rate) rather than the organ/domain.
  OsIcon.heartRate: PhosphorIconsDuotone.heartStraight,
  OsIcon.restingHeartRate: SolarIconsBold.heartPulse,
  OsIcon.maxHeartRate: PhosphorIconsDuotone.heartbeat,
  // No pack has a literal "HR zones" glyph — a gauge/dial is the closest
  // generic stand-in (approximation).
  OsIcon.heartRateZones: FluentIcons.gauge_24_regular,
  OsIcon.heartRateRecovery: SolarIconsBold.heartPulse2,
  // HRV as a waveform (distinct from a generic heart) — the best available
  // semantic match; no pack draws an actual beat-to-beat variability glyph.
  OsIcon.hrv: PhosphorIconsDuotone.waveSine,
  // No pack has a "recovery ring" glyph — a gauge/dial approximates the
  // readiness-score-dial concept.
  OsIcon.recovery: PhosphorIconsDuotone.gauge,
  // No pack has a literal "body strain" glyph — a barbell approximates
  // physical exertion/training load.
  OsIcon.bodyStrain: PhosphorIconsDuotone.barbell,
  OsIcon.workouts: SolarIconsBold.runningRound,
  OsIcon.steps: PhosphorIconsDuotone.footprints,
  OsIcon.distance: FluentIcons.ruler_24_regular,
  // No pack has a literal VO2max glyph — a speedometer approximates an
  // aerobic-capacity/output metric.
  OsIcon.vo2max: PhosphorIconsDuotone.speedometer,
  OsIcon.awake: PhosphorIconsDuotone.sunHorizon,
  OsIcon.bedtime: SolarIconsBold.bed,
  // Sleep-stage glyphs don't exist in any general-purpose pack; lightSleep/
  // deepSleep use two visually-distinct moon variants as an approximation
  // (deliberately different from the plain `sleep` moon above).
  OsIcon.lightSleep: SolarIconsBold.moonSleep,
  OsIcon.deepSleep: SolarIconsBold.moonStars,
  // A stepped square wave reads as a hypnogram staircase — a good literal
  // fit, not just an approximation.
  OsIcon.sleepHypnogram: PhosphorIconsDuotone.waveSquare,
  // Literal ECG-monitor waveform — the one concept hugeicons was picked for.
  OsIcon.ecgRhythm: HugeIcons.strokeRoundedPulseRectangle01,
  // Stress: cognitive/nervous-system load reads better as "brain" than
  // another heart glyph (approximation, but a distinct one).
  OsIcon.stress: PhosphorIconsDuotone.brain,
  OsIcon.calm: PhosphorIconsDuotone.leaf,
  OsIcon.calories: PhosphorIconsDuotone.flame,
  OsIcon.intensity: PhosphorIconsDuotone.lightning,
  OsIcon.elevation: FluentIcons.mountain_location_top_24_regular,
  OsIcon.skinTemperature: PhosphorIconsDuotone.thermometer,
  OsIcon.temperatureDeviation: PhosphorIconsDuotone.thermometerHot,
  OsIcon.activity: PhosphorIconsDuotone.pulse,
  OsIcon.ai: PhosphorIconsDuotone.sparkle,
  OsIcon.alarm: SolarIconsBold.alarm,
  OsIcon.edit: FluentIcons.edit_24_regular,
  OsIcon.notifications: FluentIcons.alert_24_regular,
  OsIcon.profile: FluentIcons.person_24_regular,
  // No pack has a "weekly recap" glyph — an open book approximates a
  // summary/read-back concept.
  OsIcon.recap: PhosphorIconsDuotone.bookOpenText,
  OsIcon.records: PhosphorIconsDuotone.trophy,
  OsIcon.streak: SolarIconsBold.medalRibbonStar,
  OsIcon.strength: SolarIconsBold.dumbbell,
  OsIcon.add: FluentIcons.add_24_regular,
  // Cardio: iconsax's canonical "activity" glyph is a heartbeat zigzag —
  // gives iconsax real, well-fitted use beyond battery/bluetooth/wear.
  OsIcon.cardio: Iconsax.activity,
  OsIcon.yoga: PhosphorIconsDuotone.personSimpleTaiChi,
  OsIcon.run: SolarIconsBold.running,
  OsIcon.cycling: SolarIconsBold.bicycling,
  OsIcon.walk: SolarIconsBold.walking,
  OsIcon.swim: SolarIconsBold.swimming,
  // No pack has a literal "HIIT" glyph — a lightning bolt approximates
  // explosive interval training.
  OsIcon.hiit: PhosphorIconsDuotone.lightning,
  OsIcon.boxing: PhosphorIconsDuotone.boxingGlove,
  // An indoor rower has no glyph in any pack; a rowing boat is the nearest
  // honest read of the movement.
  OsIcon.rowing: PhosphorIconsDuotone.boat,
  OsIcon.hike: PhosphorIconsDuotone.personSimpleHike,
  // A ladder, not `mountains`. Mountains is terrain rather than a person, and
  // it sits next to `hike: personSimpleHike` in the picker — between "a person
  // hiking" and "some mountains", the mountains are the tile that reads as
  // hiking. A ladder reads as vertical ascent and separates the pair.
  OsIcon.climb: PhosphorIconsDuotone.ladderSimple,
  OsIcon.ski: PhosphorIconsDuotone.personSimpleSki,
  OsIcon.snowboard: PhosphorIconsDuotone.personSimpleSnowboard,
  OsIcon.stairs: PhosphorIconsDuotone.stairs,
  // `personSimpleTaiChi` is already spoken for by yoga — arms-spread reads as
  // the mat/mobility register without colliding with it.
  OsIcon.pilates: PhosphorIconsDuotone.personArmsSpread,
  // One racquet glyph stands for the whole racquet family (tennis, squash,
  // padel, badminton) rather than four tiles that all look the same.
  OsIcon.tennis: PhosphorIconsDuotone.racquet,
  OsIcon.basketball: PhosphorIconsDuotone.basketball,
  OsIcon.soccer: PhosphorIconsDuotone.soccerBall,
  OsIcon.golf: PhosphorIconsDuotone.golf,
  OsIcon.workoutOther: FluentIcons.sport_24_regular,
  OsIcon.hydration: PhosphorIconsDuotone.drop,
  // Literal blood-drop — the second concept hugeicons was picked for (see
  // the `menstrualFlow` doc comment on the enum).
  OsIcon.menstrualFlow: HugeIcons.strokeRoundedBlood,
  OsIcon.wear: Iconsax.watch_status,
  OsIcon.calendar: FluentIcons.calendar_24_regular,
  OsIcon.history: FluentIcons.history_24_regular,
  OsIcon.battery: Iconsax.battery_full,
  OsIcon.bluetooth: Iconsax.bluetooth,
  OsIcon.settings: FluentIcons.settings_24_regular,
  // Utility chrome → Fluent, per the pack policy in this file's header.
  OsIcon.share: FluentIcons.share_24_regular,
  OsIcon.privacy: PhosphorIconsDuotone.shield,
  OsIcon.sync: PhosphorIconsDuotone.arrowsClockwise,
  OsIcon.info: FluentIcons.info_24_regular,
  OsIcon.check: FluentIcons.checkmark_24_regular,
  OsIcon.cancel: FluentIcons.dismiss_24_regular,
  OsIcon.trash: FluentIcons.delete_24_regular,
  OsIcon.plus: FluentIcons.add_24_regular,
  OsIcon.arrowRight: FluentIcons.chevron_right_24_regular,
  OsIcon.arrowLeft: FluentIcons.chevron_left_24_regular,
  OsIcon.up: FluentIcons.arrow_up_24_regular,
  OsIcon.down: FluentIcons.arrow_down_24_regular,
  OsIcon.logout: PhosphorIconsDuotone.signOut,
  OsIcon.server: PhosphorIconsDuotone.database,
  OsIcon.shield: PhosphorIconsDuotone.shield,
  // Real brand marks, not duotone (a two-tone render would misrepresent a
  // monochrome brand logo) — Phosphor's flat Regular weight, same "plain
  // chrome" register Fluent already occupies elsewhere in this map.
  OsIcon.github: PhosphorIconsRegular.githubLogo,
  OsIcon.discord: PhosphorIconsRegular.discordLogo,
  OsIcon.reddit: PhosphorIconsRegular.redditLogo,
  OsIcon.xTwitter: PhosphorIconsRegular.xLogo,
};

/// Sensible per-domain default tint, used whenever a call site doesn't pass
/// an explicit `color`. Mirrors [DomainAccent] so a bare `OsAppIcon(icon)` —
/// the ~40 call sites that used to just render the illustration as-is —
/// keeps a domain-appropriate identity instead of flattening to one neutral
/// tone. Plain UI chrome (arrows, check, settings, …) defaults to the
/// ordinary muted-ink chrome color.
Color _defaultTint(OsIcon icon) {
  switch (icon) {
    case OsIcon.heart:
    case OsIcon.heartRate:
    case OsIcon.restingHeartRate:
    case OsIcon.maxHeartRate:
    case OsIcon.heartRateZones:
    case OsIcon.heartRateRecovery:
    case OsIcon.ecgRhythm:
      return DomainAccent.heart;
    case OsIcon.hrv:
    case OsIcon.recovery:
      return DomainAccent.recovery;
    case OsIcon.bodyStrain:
    case OsIcon.workouts:
    case OsIcon.run:
    case OsIcon.cycling:
    case OsIcon.walk:
    case OsIcon.swim:
    case OsIcon.yoga:
    case OsIcon.hiit:
    case OsIcon.cardio:
    case OsIcon.boxing:
    case OsIcon.rowing:
    case OsIcon.hike:
    case OsIcon.climb:
    case OsIcon.ski:
    case OsIcon.snowboard:
    case OsIcon.stairs:
    case OsIcon.pilates:
    case OsIcon.tennis:
    case OsIcon.basketball:
    case OsIcon.soccer:
    case OsIcon.golf:
    case OsIcon.workoutOther:
    case OsIcon.strength:
    case OsIcon.streak:
    case OsIcon.records:
    case OsIcon.vo2max:
    case OsIcon.intensity:
      return DomainAccent.strain;
    case OsIcon.steps:
    case OsIcon.distance:
    case OsIcon.elevation:
      return DomainAccent.steps;
    case OsIcon.sleep:
    case OsIcon.awake:
    case OsIcon.bedtime:
    case OsIcon.lightSleep:
    case OsIcon.deepSleep:
    case OsIcon.sleepHypnogram:
      return DomainAccent.sleep;
    case OsIcon.stress:
      return DomainAccent.stress;
    case OsIcon.calm:
      return DomainAccent.oxygen;
    case OsIcon.calories:
      return DomainAccent.calories;
    case OsIcon.hydration:
    case OsIcon.menstrualFlow:
      return DomainAccent.cycle;
    case OsIcon.ai:
      return AppColors.coral;
    default:
      return AppColors.inkSoft;
  }
}

/// These icon-font packs draw their glyph close to the full edge of their
/// em-box (near-zero internal padding); the illustrated set they replaced
/// had generous built-in transparent padding baked into every asset, so the
/// same numeric `size` used to read noticeably smaller. Rendering the glyph
/// at `size * _kGlyphScale` — centered inside an unchanged `size`×`size`
/// layout box — corrects for that so icons look right-sized again without
/// touching any of the ~370 call sites' existing `size:` numbers (which
/// would also reflow every surrounding Row/SizedBox).
const double _kGlyphScale = 0.72;

/// Renders the resolved [IconData] for [icon] at [size]/[color], routing
/// phosphor's duotone data through [PhosphorIcon] (the two-layer widget its
/// package requires) and everything else through the plain [Icon] widget —
/// callers never need to know which pack a glyph came from.
Widget _renderGlyph(OsIcon icon, double size, Color color) {
  final data = _glyphs[icon]!;
  final glyphSize = size * _kGlyphScale;
  final glyph = data is PhosphorDuotoneIconData
      ? PhosphorIcon(data, size: glyphSize, color: color)
      : Icon(data, size: glyphSize, color: color);
  // Fixed box at the ORIGINAL requested size so layout (Row/SizedBox/
  // alignment) around every existing call site is unaffected — only the
  // glyph inside shrinks.
  return SizedBox(width: size, height: size, child: Center(child: glyph));
}

/// Renders an OpenStrap glyph. Defaults to a domain-appropriate tint (see
/// [_defaultTint]) when [color] isn't given — pass an explicit [color] to
/// override (e.g. to sit on a colored background).
///
/// [opacity] is kept for source-compatibility with call sites written for
/// the old illustrated set (e.g. inactive states); 1.0 = full strength.
class OsAppIcon extends StatelessWidget {
  final OsIcon icon;
  final double size;
  final double opacity;
  final Color? color;
  final String? semanticLabel;

  const OsAppIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.opacity = 1.0,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? _defaultTint(icon);
    final child = Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      child: _renderGlyph(icon, size, resolvedColor),
    );
    if (opacity >= 1.0) return child;
    return Opacity(opacity: opacity, child: child);
  }
}
