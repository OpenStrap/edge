// The canonical (key, label, glyph, illustrated-art) table for workout/session
// "type" strings — the single seam shared by every screen that renders a
// per-type icon: the start/pick-type grid (workouts_screen.dart), workout
// list rows (journey_screen.dart), and the recap "top workout" card
// (recap_screen.dart). Extend the table HERE, never duplicate a local map
// in a screen file — divergent tables are how "Cycle" ends up two different
// icons on two different screens.

import 'package:flutter/material.dart';

import '../design/design.dart';

/// (key, label, glyph fallback, illustrated OsIcon). The type string is
/// whatever `sport`/`type`/`detected_type` carries from the repo — manual
/// start keys AND the auto-detector's output share this one vocabulary.
// The glyph (3rd element) used to fall back to a generic icon (activity/
// heartRate) for cycle/swim/hiit/cardio/yoga instead of the type's own icon
// — now that every OsIcon here is a real, distinct vector glyph (not an
// expensive illustration), there's no reason for the compact glyph and the
// "full" icon to ever differ, so every row just uses the same icon twice.
const kWorkoutTypes = <(String, String, OsIcon, OsIcon?)>[
  ('run', 'Run', OsIcon.run, OsIcon.run),
  ('cycle', 'Cycle', OsIcon.cycling, OsIcon.cycling),
  ('strength', 'Strength', OsIcon.strength, OsIcon.strength),
  ('walk', 'Walk', OsIcon.walk, OsIcon.walk),
  ('swim', 'Swim', OsIcon.swim, OsIcon.swim),
  ('cardio', 'Cardio', OsIcon.cardio, OsIcon.cardio),
  ('yoga', 'Yoga', OsIcon.yoga, OsIcon.yoga),
  ('hiit', 'HIIT', OsIcon.hiit, OsIcon.hiit),
  ('boxing', 'Boxing', OsIcon.boxing, OsIcon.boxing),
  ('rowing', 'Rowing', OsIcon.rowing, OsIcon.rowing),
  ('hike', 'Hike', OsIcon.hike, OsIcon.hike),
  ('climb', 'Climb', OsIcon.climb, OsIcon.climb),
  ('ski', 'Ski', OsIcon.ski, OsIcon.ski),
  ('snowboard', 'Snowboard', OsIcon.snowboard, OsIcon.snowboard),
  ('stairs', 'Stairs', OsIcon.stairs, OsIcon.stairs),
  ('pilates', 'Pilates', OsIcon.pilates, OsIcon.pilates),
  ('tennis', 'Racquet', OsIcon.tennis, OsIcon.tennis),
  ('basketball', 'Basketball', OsIcon.basketball, OsIcon.basketball),
  ('soccer', 'Soccer', OsIcon.soccer, OsIcon.soccer),
  ('golf', 'Golf', OsIcon.golf, OsIcon.golf),
  ('other', 'Other', OsIcon.workoutOther, OsIcon.workoutOther),
];

/// Built-ins by key, so a lookup does not walk the list.
final Map<String, (String, String, OsIcon, OsIcon?)> kWorkoutTypesByKey = {
  for (final e in kWorkoutTypes) e.$1: e,
};

/// Alternate spellings that mean an existing [kWorkoutTypes] key.
///
/// These are not hypothetical. The WHOOP importer stores the raw slug of the
/// export's "Activity name" column (`lib/import/whoop_import.dart`), so an
/// imported library is full of `running`, `weightlifting`, `functional
/// fitness` — rows the app would otherwise label by blind capitalisation and
/// treat as unrecognised. Filtering by Run would hide every imported run while
/// the feed happily showed cards titled "Running".
///
/// Keys here must be lowercase, and must never shadow a key in
/// [kWorkoutTypes].
const kWorkoutTypeAliases = <String, String>{
  'running': 'run',
  'jog': 'run',
  'jogging': 'run',
  'treadmill': 'run',
  'cycling': 'cycle',
  'bike': 'cycle',
  'biking': 'cycle',
  'ride': 'cycle',
  'spinning': 'cycle',
  'walking': 'walk',
  'rucking': 'walk',
  'swimming': 'swim',
  'weights': 'strength',
  'weightlifting': 'strength',
  'lifting': 'strength',
  'strength training': 'strength',
  'functional fitness': 'strength',
  'crossfit': 'hiit',
  'interval': 'hiit',
  'hiking': 'hike',
  'climbing': 'climb',
  'bouldering': 'climb',
  'skiing': 'ski',
  'snowboarding': 'snowboard',
  'rowing machine': 'rowing',
  'row': 'rowing',
  'erg': 'rowing',
  'stair climber': 'stairs',
  'stairmaster': 'stairs',
  'stair': 'stairs',
  'racquet': 'tennis',
  'racquetball': 'tennis',
  'squash': 'tennis',
  'padel': 'tennis',
  'badminton': 'tennis',
  'table tennis': 'tennis',
  'pickleball': 'tennis',
  'football': 'soccer',
  'boxing training': 'boxing',
  'kickboxing': 'boxing',
  'martial arts': 'boxing',
  'meditation': 'yoga',
  'stretching': 'pilates',
  'mobility': 'pilates',
};

/// The [kWorkoutTypes] key a stored type string means, or null when it belongs
/// to no known family. One seam for every lookup here and for the filter — a
/// row must not render as "Running" in the feed and as "Other" to the filter.
String? resolveWorkoutTypeKey(String? type) {
  final raw = (type ?? '').toLowerCase().trim();
  if (raw.isEmpty) return null;
  if (kWorkoutTypesByKey.containsKey(raw)) return raw;
  return kWorkoutTypeAliases[raw];
}

/// Glyph fallback for a workout type — always returns something renderable,
/// even for autodetected/unrecognized types.
OsIcon workoutTypeIcon(String? type) {
  final raw = (type ?? '').toLowerCase();
  if (raw.contains('autodetected')) return OsIcon.strength;
  if (raw.contains('workout')) return OsIcon.strength;
  final e = kWorkoutTypesByKey[resolveWorkoutTypeKey(type)];
  return e?.$3 ?? OsIcon.strength;
}

/// Illustrated art for a workout type — null only for autodetected/unknown
/// types, which stay on the glyph fallback ([workoutTypeIcon]).
OsIcon? workoutTypeOsIcon(String? type) {
  return kWorkoutTypesByKey[resolveWorkoutTypeKey(type)]?.$4;
}

String workoutTypeLabel(String? type) {
  if (type == null || type.isEmpty) return 'Workout';
  // The stored `type` column is free-form text, so rows written by older
  // releases, by an import, or by hand can arrive in any case. Every lookup in
  // this file normalizes first for that reason.
  if (type.toLowerCase().contains('autodetected')) return 'Workout';
  // The table's own label wins over capitalising the key, so the list row and
  // the picker tile always read the same. Capitalising blind is how 'hiit'
  // rendered as "Hiit" everywhere except the picker.
  final e = kWorkoutTypesByKey[resolveWorkoutTypeKey(type)];
  if (e != null) return e.$2;
  return type[0].toUpperCase() + type.substring(1);
}

/// Shared exercise grid used by both the "start a workout" and "pick/correct
/// type" bottom sheets — tap a tile to choose that type's key.
Widget workoutTypeGrid(BuildContext context) => Wrap(
  spacing: Sp.x3,
  runSpacing: Sp.x3,
  children: [
    for (final e in kWorkoutTypes)
      Pressable(
        pressedScale: 0.94,
        onTap: () => Navigator.pop(context, e.$1),
        child: Container(
          width: 96,
          padding: const EdgeInsets.symmetric(vertical: Sp.x4),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(R.cardSm),
          ),
          child: Column(
            children: [
              // Fixed 32px slot so illustrated and glyph tiles line up.
              SizedBox(
                height: 32,
                child: Center(
                  child: e.$4 != null
                      ? OsAppIcon(e.$4!, size: 32)
                      : AppIcon(e.$3, size: 26, color: AppColors.accent),
                ),
              ),
              const SizedBox(height: Sp.x2),
              Text(e.$2, style: AppText.label),
            ],
          ),
        ),
      ),
  ],
);

/// The body every type-picking bottom sheet shares: a title over a scrollable
/// grid, capped at 3/4 of the screen.
///
/// The grid MUST stay scrollable and the sheet MUST be opened with
/// `isScrollControlled: true`. A plain `showModalBottomSheet` caps itself at
/// 9/16 of the screen (~475 pt on a 390x844 device); the type list outgrew
/// that the moment it went past nine tiles, and the overflow is invisible in
/// release — the last rows are simply clipped off and untappable, with no
/// overflow stripes to give it away.
Widget workoutTypeSheet(BuildContext context, String title) {
  final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
  return SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppText.h2),
            const SizedBox(height: Sp.x4),
            Flexible(
              child: SingleChildScrollView(
                child: Builder(builder: workoutTypeGrid),
              ),
            ),
            const SizedBox(height: Sp.x4),
          ],
        ),
      ),
    ),
  );
}

/// Bottom-sheet type picker (no workout start) — used to confirm/correct an
/// auto-detected workout's type and to set the type on a manually logged one.
/// Returns the chosen type, or null if dismissed.
///
/// Lives here rather than in workouts_screen.dart so the manual-entry form can
/// reach it without the two screen files importing each other.
Future<String?> pickWorkoutType(
  BuildContext context, {
  String title = 'Set workout type',
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => workoutTypeSheet(ctx, title),
  );
}
