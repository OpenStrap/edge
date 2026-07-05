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
const kWorkoutTypes = <(String, String, IconData, OsIcon?)>[
  ('run', 'Run', Ic.run, OsIcon.run),
  ('cycle', 'Cycle', Ic.activity, OsIcon.cycling),
  ('strength', 'Strength', Ic.weights, OsIcon.strength),
  ('walk', 'Walk', Ic.run, OsIcon.walk),
  ('swim', 'Swim', Ic.activity, OsIcon.swim),
  ('cardio', 'Cardio', Ic.pulse, OsIcon.cardio),
  ('yoga', 'Yoga', Ic.heart, OsIcon.yoga),
  ('hiit', 'HIIT', Ic.pulse, OsIcon.hiit),
  ('other', 'Other', Ic.activity, OsIcon.workoutOther),
];

/// Glyph fallback for a workout type — always returns something renderable,
/// even for autodetected/unrecognized types.
IconData workoutTypeIcon(String? type) {
  final raw = (type ?? '').toLowerCase();
  if (raw.contains('autodetected')) return Ic.weights;
  if (raw.contains('workout')) return Ic.weights;
  for (final e in kWorkoutTypes) {
    if (e.$1 == type) return e.$3;
  }
  return Ic.weights;
}

/// Illustrated art for a workout type — null only for autodetected/unknown
/// types, which stay on the glyph fallback ([workoutTypeIcon]).
OsIcon? workoutTypeOsIcon(String? type) {
  for (final e in kWorkoutTypes) {
    if (e.$1 == type) return e.$4;
  }
  return null;
}

String workoutTypeLabel(String? type) {
  if (type == null || type.isEmpty) return 'Workout';
  if (type.toLowerCase().contains('autodetected')) return 'Workout';
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
