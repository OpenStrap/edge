// The activity vocabulary — ~70 things a person actually does, in eight
// groups, each carrying a published MET value except the one row that names
// no activity at all.
//
// Why MET and not a made-up "intensity": a calorie figure has to come from
// somewhere, and "somewhere" is Ainsworth et al., Compendium of Physical
// Activities (2011 update, Med Sci Sports Exerc 43(8):1575-81). The arithmetic
// is one line — kcal = MET × 3.5 × kg / 200 × minutes — and it needs body
// weight, which the app may not have. So [Activity.kcal] returns null rather
// than a number, and the screens say so. A fabricated calorie count is worse
// than no calorie count, because it looks the same as a measured one.
//
// The app's stored workout vocabulary is the free-form `sessions.type` TEXT
// column, so this table needs no schema of its own: [byName] maps a stored
// type back to its entry, and an unknown type simply falls through to null.

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';

/// How a session is tracked — which decides which live screen it opens, and
/// therefore which parameters the user is asked for.
enum Track {
  /// Strength — reps, load, rest. Entered, never measured.
  sets,

  /// Running, cycling, swimming, rowing — distance and pace.
  distance,

  /// Sports and classes — anything simply timed.
  duration,

  /// HIIT, circuits, tabata — work/rest rounds.
  interval,

  /// Yoga, stretching, breathwork — time, breath, stillness.
  stillness,
}

class Activity {
  final String name;
  final IconData icon;
  final Color color;
  final Track track;

  /// Metabolic equivalent of task — the honest basis for a calorie estimate.
  /// Compendium of Physical Activities, Ainsworth et al.
  ///
  /// NULL for a row the compendium cannot price, which is exactly one:
  /// 'General workout' means the user did not say what they did, and the
  /// compendium prices named activities. Every number that could go here
  /// would be a stand-in — which is the 'Custom activity' mistake below,
  /// whose MET of 4.0 was invented. So [kcal] returns null, the picker and
  /// the setup screen show no estimate, and the session still gets a REAL
  /// calorie figure afterwards: the post-session estimator in
  /// `compute/manual_session.dart` works from heart rate and never reads a
  /// MET. The guess is what is missing, not the calories.
  final double? met;

  /// Whether a route is worth recording. GPS activities get the map.
  final bool gps;

  /// Defaults the session's privacy toggle on. Not a different kind of
  /// activity — a different default, which the user can flip either way.
  final bool private;

  /// Locomotion on foot, so the strap's 100 Hz pedometer may count its steps.
  ///
  /// NOT the same question as [gps] — cycling records a route and takes no
  /// steps; a treadmill takes steps and records nothing. Default false: an
  /// activity is only gait when someone has said so, because the failure is
  /// silent and expensive. Wrist step error is UNBOUNDED ABOVE on rhythmic arm
  /// work (OxWalk: +199.5% worst case at the wrist against +5.3% at the hip),
  /// so rowing or boxing admitted here would bank hundreds of steps nobody
  /// took. `kGaitStepTypeKeys` is derived from this flag and pinned to it in
  /// both directions by test/gait_step_types_test.dart.
  final bool gait;

  const Activity(this.name, this.icon, this.color, this.track, this.met,
      {this.gps = false, this.private = false, this.gait = false});

  /// kcal = MET × 3.5 × kg / 200 × minutes.
  ///
  /// Null when body weight is unknown, and null when the activity carries no
  /// MET. There is no default for either: both numbers would be
  /// indistinguishable from a real one on screen.
  int? kcal(double? kg, int minutes) => kg == null || kg <= 0 || met == null
      ? null
      : (met! * 3.5 * kg / 200 * minutes).round();

  /// The stored `sessions.type` for this activity.
  String get typeKey => name.toLowerCase().replaceAll(' ', '_');
}

class ActGroup {
  final String name;
  final IconData icon;
  final List<Activity> items;
  const ActGroup(this.name, this.icon, this.items);
}

const activityLibrary = <ActGroup>[
  ActGroup('Cardio', LucideIcons.heartPulse, [
    Activity('Running', LucideIcons.footprints, C.green, Track.distance, 9.8,
        gps: true, gait: true),
    Activity(
        'Trail running', LucideIcons.mountain, C.green, Track.distance, 10.5,
        gps: true, gait: true),
    Activity('Walking', LucideIcons.footprints, C.teal, Track.distance, 3.5,
        gps: true, gait: true),
    Activity('Hiking', LucideIcons.mountainSnow, C.green, Track.distance, 6.0,
        gps: true, gait: true),
    Activity('Cycling', LucideIcons.bike, C.blue, Track.distance, 8.0,
        gps: true),
    Activity('Indoor bike', LucideIcons.bike, C.blue, Track.duration, 7.0),
    Activity('Rowing', LucideIcons.sailboat, C.teal, Track.distance, 7.0),
    Activity('Swimming', LucideIcons.waves, C.blue, Track.distance, 8.3),
    Activity('Elliptical', LucideIcons.activity, C.purple, Track.duration, 5.0),
    Activity(
        'Stair climber', LucideIcons.trendingUp, C.orange, Track.duration, 9.0),
    // Tracked by duration, not distance: a treadmill belt reports nothing to
    // this app and a wrist cannot measure indoor distance, so the session is
    // its heart rate and its clock.
    Activity('Treadmill', LucideIcons.footprints, C.green, Track.duration, 8.3, gait: true),
    Activity('Jump rope', LucideIcons.circleDashed, C.red, Track.interval, 12.3),
  ]),
  ActGroup('Strength', LucideIcons.dumbbell, [
    Activity('Weight training', LucideIcons.dumbbell, C.purple, Track.sets, 6.0),
    Activity('Powerlifting', LucideIcons.dumbbell, C.purple, Track.sets, 6.0),
    Activity(
        'Bodyweight', LucideIcons.personStanding, C.purple, Track.sets, 4.5),
    Activity(
        'Calisthenics', LucideIcons.personStanding, C.purple, Track.sets, 5.0),
    Activity('Kettlebell', LucideIcons.dumbbell, C.orange, Track.interval, 8.0),
    Activity('CrossFit', LucideIcons.flame, C.red, Track.interval, 9.0),
    Activity('HIIT', LucideIcons.zap, C.red, Track.interval, 10.0),
    Activity(
        'Circuit training', LucideIcons.repeat2, C.orange, Track.interval, 7.5),
    Activity('Functional', LucideIcons.boxes, C.purple, Track.sets, 5.5),
  ]),
  ActGroup('Sports', LucideIcons.trophy, [
    Activity('Football', LucideIcons.volleyball, C.green, Track.duration, 8.0),
    Activity('Basketball', LucideIcons.volleyball, C.orange, Track.duration, 8.0),
    Activity('Cricket', LucideIcons.target, C.green, Track.duration, 5.0),
    Activity('Tennis', LucideIcons.volleyball, C.yellow, Track.duration, 7.3),
    Activity('Badminton', LucideIcons.volleyball, C.teal, Track.duration, 5.5),
    Activity(
        'Table tennis', LucideIcons.volleyball, C.blue, Track.duration, 4.0),
    Activity('Squash', LucideIcons.volleyball, C.red, Track.duration, 12.0),
    Activity('Volleyball', LucideIcons.volleyball, C.orange, Track.duration, 6.0),
    Activity('Hockey', LucideIcons.target, C.blue, Track.duration, 8.0),
    Activity('Baseball', LucideIcons.target, C.red, Track.duration, 5.0),
    Activity('Rugby', LucideIcons.volleyball, C.green, Track.duration, 8.3),
    Activity('Golf', LucideIcons.flag, C.green, Track.duration, 4.8, gps: true),
    // Compendium 15092, "bowling, indoor, bowling alley". This row IS the
    // alley — that assumption is the choice being made here, not a fact about
    // what users do — because the alternative is two near-identical rows. The
    // bare 15090 "bowling" is 3.0, and neither number is the measured one.
    Activity('Bowling', LucideIcons.circleDot, C.indigo, Track.duration, 3.8),
    Activity('Boxing', LucideIcons.hand, C.red, Track.interval, 12.8),
    Activity('Martial arts', LucideIcons.hand, C.red, Track.duration, 10.3),
    Activity('Wrestling', LucideIcons.users, C.orange, Track.duration, 6.0),
    Activity('Climbing', LucideIcons.mountain, C.orange, Track.duration, 8.0),
  ]),
  ActGroup('Athletics', LucideIcons.medal, [
    Activity('Sprinting', LucideIcons.zap, C.red, Track.interval, 23.0),
    Activity('Track intervals', LucideIcons.timer, C.red, Track.interval, 11.8),
    Activity(
        'Cross country', LucideIcons.mountain, C.green, Track.distance, 9.0,
        gps: true, gait: true),
    Activity('Hurdles', LucideIcons.zap, C.orange, Track.interval, 10.0),
    Activity('Long jump', LucideIcons.moveUpRight, C.orange, Track.duration, 6.0),
    Activity('Shot put', LucideIcons.circle, C.purple, Track.duration, 4.0),
    Activity('Javelin', LucideIcons.moveUpRight, C.purple, Track.duration, 4.0),
    Activity('Pole vault', LucideIcons.moveUp, C.orange, Track.duration, 6.0),
  ]),
  ActGroup('Outdoor', LucideIcons.trees, [
    Activity('Mountain biking', LucideIcons.bike, C.green, Track.distance, 8.5,
        gps: true),
    Activity('Kayaking', LucideIcons.sailboat, C.blue, Track.distance, 5.0,
        gps: true),
    Activity('Surfing', LucideIcons.waves, C.blue, Track.duration, 5.0),
    Activity('Paddleboard', LucideIcons.sailboat, C.teal, Track.distance, 6.0,
        gps: true),
    Activity('Skiing', LucideIcons.snowflake, C.blue, Track.distance, 7.0,
        gps: true),
    Activity(
        'Snowboarding', LucideIcons.snowflake, C.indigo, Track.distance, 5.3,
        gps: true),
    Activity('Skating', LucideIcons.circleDashed, C.purple, Track.distance, 7.0,
        gps: true),
    Activity('Horse riding', LucideIcons.rabbit, C.orange, Track.duration, 5.5),
  ]),
  ActGroup('Mind & body', LucideIcons.leaf, [
    Activity('Yoga', LucideIcons.personStanding, C.teal, Track.stillness, 3.0),
    Activity('Pilates', LucideIcons.personStanding, C.teal, Track.stillness, 3.8),
    Activity(
        'Stretching', LucideIcons.personStanding, C.green, Track.stillness, 2.3),
    Activity(
        'Mobility', LucideIcons.personStanding, C.green, Track.stillness, 3.0),
    Activity('Tai chi', LucideIcons.wind, C.teal, Track.stillness, 3.0),
    Activity('Breathwork', LucideIcons.wind, C.teal, Track.stillness, 1.5),
    Activity('Meditation', LucideIcons.brain, C.purple, Track.stillness, 1.3),
  ]),
  ActGroup('Everyday', LucideIcons.house, [
    Activity('Housework', LucideIcons.house, C.n500, Track.duration, 3.3),
    Activity('Gardening', LucideIcons.sprout, C.green, Track.duration, 3.8),
    Activity('Dog walking', LucideIcons.dog, C.teal, Track.distance, 3.0,
        gps: true, gait: true),
    Activity('Childcare', LucideIcons.baby, C.pink, Track.duration, 3.0),
    Activity('DIY', LucideIcons.hammer, C.orange, Track.duration, 4.5),
    Activity('Shopping', LucideIcons.shoppingBag, C.n500, Track.duration, 2.3),
    Activity('Stairs', LucideIcons.trendingUp, C.orange, Track.duration, 8.0),
  ]),
  ActGroup('Other', LucideIcons.ellipsis, [
    // The catch-all: nothing in the catalogue matched, or hunting for the
    // match was not worth it. NO MET, and that is the whole design of the row
    // — see [Activity.met]. 02060 "health club exercise, general" was the
    // near miss, and it prices a gym session, which is not what this row
    // means. Tracked by duration because the clock and the heart-rate trace
    // are everything the app knows about a workout nobody named.
    Activity('General workout', LucideIcons.activity, C.purple,
        Track.duration, null),
    Activity('Dancing', LucideIcons.music, C.pink, Track.duration, 7.8),
    // A normal entry with a real MET and a privacy default, exactly as Apple
    // Health carries it. Coyness here would be its own kind of judgement.
    Activity('Intimacy', LucideIcons.heart, C.pink, Track.duration, 5.8,
        private: true),
    Activity(
        'Physiotherapy', LucideIcons.stethoscope, C.blue, Track.duration, 3.0),
    Activity('Sauna', LucideIcons.thermometer, C.orange, Track.stillness, 1.5),
    Activity('Cold plunge', LucideIcons.snowflake, C.blue, Track.stillness, 2.0),
    // There is no 'Custom activity' row. It carried a MET of 4.0, which is not
    // in the compendium and could not be — the whole point of a custom entry
    // is that the app does not know what it is — and every session made with
    // it banked a specific-looking calorie figure derived from nothing about
    // what the user did, under one shared type key, with no name field
    // anywhere to say what it had been.
  ]),
];

/// What the app has to say about a calorie figure, in one place because it was
/// said in four and drifted: one site kept quoting a "±15%" error bar that no
/// estimator computes, long after the others dropped it.
const kCalorieWhy = 'MET value × your weight, refined by heart rate — or '
    'heart rate alone, for an activity that carries no MET.';

/// TS-03 — what every zone chart in the app has to admit about its own edges.
///
/// The five bands are percentages of a ceiling nobody measured on this user:
/// `estimatedMaxHr(age, family)`, Tanaka's age line for the strap that recorded
/// it. At 30 that is 187 and a real ceiling can sit 20 bpm either side of it,
/// so every boundary drawn off it moves with it. Saying that on the chart is a
/// materially different claim from printing five confident bpm ranges, and it
/// is the claim we can actually support.
///
/// One string because two screens draw a full zone chart (the session summary
/// and the day-strain detail) and it has to say the same thing on both. The
/// compact bar on a history row does not carry it — that row taps straight
/// through to the summary, which does.
///
/// Never "fat burning zone", never "aerobic threshold": these are convention
/// edges on a guessed ceiling, not measurements of anything metabolic.
/// NOT "your age and your strap": [estimatedMaxHr] takes `deviceFamily` and
/// DELIBERATELY IGNORES IT (hr_max.dart) — Tanaka is a population regression on
/// age alone, and swapping the strap does not move it by one bpm. The sentence
/// named an input that provably has no effect on the number it describes.
const kZonesWhy = 'Zone edges are percentages of a maximum heart rate '
    'estimated from your age — not one measured on you.';

/// English, non-localized fallback/test seam — see [zonesWhyFootnote] and
/// [zonesWhy] for the localized callers actually used by the UI.
String zonesWhyFootnote([AppLocalizations? l]) => l?.catalogueZonesWhy ?? kZonesWhy;

/// THE sentence a zone chart carries, for the anchors THAT chart was banded on.
///
/// [source] is the set's own stamp (`karvonen` · `observed` · `tanaka`) and
/// [maxHr] the ceiling it is 100 % of. One function because the day-strain
/// detail and a session's summary card draw the same bands off the same
/// `trainingZones` set, and only one of them was reading the stamp: the summary
/// hard-coded [kZonesWhy] and so told a user whose zones were banded on a
/// MEASURED ceiling that they came from their age. A card that reports 13
/// minutes above a boundary its own footnote misattributes is unanswerable —
/// there is no number on screen to check it against.
///
/// [kZonesWhy] (via [zonesWhyFootnote]) is the fallback rather than a fourth
/// branch: an unknown stamp and a measured stamp with no ceiling to name are
/// both "we cannot say this was measured on you", which is what the estimate
/// sentence already says. [l] is optional so the non-UI test seam
/// (`hr_ceiling_zones_test.dart`) can call this with the plain English copy.
String zonesWhy(String? source, num? maxHr, [AppLocalizations? l]) => maxHr == null
    ? zonesWhyFootnote(l)
    : switch (source) {
        'karvonen' =>
          l?.dayStrainZoneFootnoteKarvonen(maxHr.round()) ??
              'Zone edges span the gap between your measured resting heart rate '
                  'and the highest we have seen (${maxHr.round()} bpm). Both '
                  'measured on you.',
        'observed' =>
          l?.dayStrainZoneFootnoteObserved(maxHr.round()) ??
              'Zone edges are percentages of the highest heart rate we have seen '
                  '(${maxHr.round()} bpm) — measured, not estimated.',
        _ => zonesWhyFootnote(l),
      };

/// The row that means most people never open the catalogue.
const quickStart = <Activity>[
  Activity('Running', LucideIcons.footprints, C.green, Track.distance, 9.8,
      gps: true, gait: true),
  Activity('Weight training', LucideIcons.dumbbell, C.purple, Track.sets, 6.0),
  Activity('Cycling', LucideIcons.bike, C.blue, Track.distance, 8.0, gps: true),
  Activity('Walking', LucideIcons.footprints, C.teal, Track.distance, 3.5,
      gps: true, gait: true),
  Activity('Football', LucideIcons.volleyball, C.green, Track.duration, 8.0),
  Activity('Yoga', LucideIcons.personStanding, C.teal, Track.stillness, 3.0),
];

final List<Activity> allActivities = [
  for (final g in activityLibrary) ...g.items,
];

final Map<String, Activity> _byKey = {
  for (final a in allActivities) a.typeKey: a,
};

/// Resolve a stored `sessions.type` (or a display name) back to its entry.
/// Null for a type this build does not know — the caller renders the row with
/// what it has rather than guessing an icon and a MET.
Activity? activityByName(String? type) =>
    type == null ? null : _byKey[type.toLowerCase().replaceAll(' ', '_')];

// ── EXERCISES ──────────────────────────────────────────────────────────────
// The strength catalogue. `muscles` is the fraction of the set's work each
// group takes, and it is what the muscle map is drawn from — so it is a claim
// about anatomy, not decoration. Values are the conventional prime-mover /
// synergist split; they are approximate and the map is labelled relative.

class ExerciseDef {
  final String key;
  final String label;

  /// group → 0…1 share of the work. Only the primary mover is shown, as the
  /// category label in the exercise picker — nothing paints these any more.
  final Map<String, double> muscles;

  /// The plate/dumbbell increment this lift is normally loaded in, kg. A
  /// barbell moves in 2.5, a dumbbell in 2 — a single global step is what
  /// makes every strength app feel like a spreadsheet.
  final double step;

  const ExerciseDef(this.key, this.label, this.muscles, {this.step = 2.5});
}

const exerciseLibrary = <ExerciseDef>[
  ExerciseDef('bench_press', 'Bench press',
      {'chest': .6, 'triceps': .25, 'shoulders': .15}),
  ExerciseDef('incline_db_press', 'Incline DB press',
      {'chest': .5, 'shoulders': .3, 'triceps': .2},
      step: 2),
  ExerciseDef('cable_fly', 'Cable fly', {'chest': .8, 'shoulders': .2}),
  ExerciseDef('overhead_press', 'Overhead press',
      {'shoulders': .6, 'triceps': .3, 'core': .1}),
  ExerciseDef('triceps_pushdown', 'Triceps pushdown', {'triceps': 1.0}),
  ExerciseDef('overhead_extension', 'Overhead extension', {'triceps': 1.0}),
  ExerciseDef('barbell_row', 'Barbell row',
      {'back': .65, 'biceps': .25, 'core': .1}),
  ExerciseDef('lat_pulldown', 'Lat pulldown', {'back': .7, 'biceps': .3}),
  ExerciseDef('pull_up', 'Pull-up', {'back': .65, 'biceps': .25, 'core': .1}),
  ExerciseDef('barbell_curl', 'Barbell curl', {'biceps': 1.0}),
  ExerciseDef('back_squat', 'Back squat',
      {'legs': .65, 'glutes': .25, 'core': .1}),
  ExerciseDef('front_squat', 'Front squat',
      {'legs': .6, 'glutes': .2, 'core': .2}),
  ExerciseDef('deadlift', 'Deadlift',
      {'back': .35, 'legs': .3, 'glutes': .3, 'core': .05}),
  ExerciseDef('romanian_deadlift', 'Romanian deadlift',
      {'glutes': .45, 'legs': .35, 'back': .2}),
  ExerciseDef('hip_thrust', 'Hip thrust', {'glutes': .8, 'legs': .2}),
  ExerciseDef('leg_press', 'Leg press', {'legs': .75, 'glutes': .25}),
  ExerciseDef('plank', 'Plank', {'core': 1.0}, step: 0),
  ExerciseDef('hanging_leg_raise', 'Hanging leg raise', {'core': 1.0}, step: 0),
  // Bodyweight movement: repetitions are user-entered; this is not inferred
  // from wearable motion and carries no external load estimate.
  ExerciseDef(
    'push_up',
    'Push-ups',
    {'chest': .6, 'triceps': .25, 'shoulders': .15},
    step: 0,
  ),
];

final Map<String, ExerciseDef> _exercisesByKey = {
  for (final e in exerciseLibrary) e.key: e,
};

ExerciseDef? exerciseByKey(String key) => _exercisesByKey[key];

