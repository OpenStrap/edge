// Pure filtering/sorting policy for the workout list. Lives apart from
// workouts_screen.dart so the rules are unit-testable without pumping a
// widget — the screen wires, this decides.
//
// Everything here operates on the session maps the repo already returns
// (`start_ts`, `status`, `type`, `duration_min`, `strain`, `calories`,
// `zone_min`); nothing re-reads the database.

import 'workout_types.dart';

/// Ordering for the filtered list.
enum WorkoutSort {
  newest,
  oldest,
  longest,
  hardest;

  String get label => switch (this) {
    WorkoutSort.newest => 'Newest',
    WorkoutSort.oldest => 'Oldest',
    WorkoutSort.longest => 'Longest',
    WorkoutSort.hardest => 'Hardest',
  };

  /// Whether the order still runs along the calendar. The feed groups by week,
  /// which only means anything for a chronological order — the other two sorts
  /// render as one flat list instead.
  bool get isChronological =>
      this == WorkoutSort.newest || this == WorkoutSort.oldest;
}

/// Canonical type key for filtering. Alternate spellings resolve to their real
/// family via [resolveWorkoutTypeKey] — an imported session stored as
/// `running` must be found by the Run chip, not hidden under Other while the
/// feed shows it titled "Run".
///
/// Anything genuinely outside the vocabulary — an auto-detector string, a type
/// from an older release — still collapses to `other`, so the Other chip
/// catches those rather than leaving them unreachable by any filter.
String canonicalWorkoutType(String? raw) => resolveWorkoutTypeKey(raw) ?? 'other';

/// A filter over the workout feed. All fields are floors, not ranges — the
/// range picker above the list already bounds the window in time.
class WorkoutFilter {
  const WorkoutFilter({
    this.types = const <String>{},
    this.minMinutes = 0,
    this.minStrain = 0,
    this.sort = WorkoutSort.newest,
  });

  /// Empty means every type. Keys are [kWorkoutTypes] keys.
  final Set<String> types;
  final int minMinutes;
  final double minStrain;
  final WorkoutSort sort;

  /// Whether anything is actually narrowing the list. Sort alone doesn't
  /// count — reordering hides nothing, so the summary stays truthful.
  bool get isNarrowing => types.isNotEmpty || minMinutes > 0 || minStrain > 0;

  bool get isDefault => !isNarrowing && sort == WorkoutSort.newest;

  WorkoutFilter copyWith({
    Set<String>? types,
    int? minMinutes,
    double? minStrain,
    WorkoutSort? sort,
  }) => WorkoutFilter(
    types: types ?? this.types,
    minMinutes: minMinutes ?? this.minMinutes,
    minStrain: minStrain ?? this.minStrain,
    sort: sort ?? this.sort,
  );

  /// One-line description of what's active, for the chip under the header.
  /// Empty when nothing is narrowing.
  String get description {
    final parts = <String>[];
    if (types.isNotEmpty) {
      final names = types.map(workoutTypeLabel).toList()..sort();
      parts.add(names.length <= 2 ? names.join(', ') : '${names.length} types');
    }
    if (minMinutes > 0) parts.add('${minMinutes}m+');
    if (minStrain > 0) parts.add('strain ${minStrain.toStringAsFixed(0)}+');
    return parts.join(' · ');
  }

  bool _matches(Map<String, dynamic> w) {
    // Type is known the moment a session starts, so it applies to a live one
    // like any other — filtering to runs should not surface the ride that is
    // in progress.
    if (types.isNotEmpty &&
        !types.contains(canonicalWorkoutType(w['type'] as String?))) {
      return false;
    }
    // The numeric floors are different: a session happening right now has no
    // final duration or strain to clear them with, so holding it to them would
    // hide the one thing the user is most likely looking at.
    if (w['status'] == 'live') return true;
    if (minMinutes > 0 && ((w['duration_min'] as num?) ?? 0) < minMinutes) {
      return false;
    }
    // An unscored session (null strain — the profile lacked an anchor, or the
    // window has no HR) cannot be shown to clear a strain floor, so a floor
    // excludes it. That is the conservative reading and it is deliberate: the
    // alternative is listing sessions under "strain 10+" that may be nothing
    // of the sort.
    if (minStrain > 0) {
      final s = (w['strain'] as num?)?.toDouble();
      if (s == null || s < minStrain) return false;
    }
    return true;
  }

  List<Map<String, dynamic>> apply(List<Map<String, dynamic>> workouts) {
    final out = workouts.where(_matches).toList();
    int startOf(Map<String, dynamic> w) => (w['start_ts'] as int?) ?? 0;
    num durOf(Map<String, dynamic> w) => (w['duration_min'] as num?) ?? 0;
    num? strainOf(Map<String, dynamic> w) => (w['strain'] as num?);
    switch (sort) {
      case WorkoutSort.newest:
        out.sort((a, b) => startOf(b).compareTo(startOf(a)));
      case WorkoutSort.oldest:
        out.sort((a, b) => startOf(a).compareTo(startOf(b)));
      // Ties fall back to newest-first so the order is stable rather than
      // dependent on however the query happened to return equal rows.
      case WorkoutSort.longest:
        out.sort((a, b) {
          final c = durOf(b).compareTo(durOf(a));
          return c != 0 ? c : startOf(b).compareTo(startOf(a));
        });
      // An unscored session sinks below every scored one rather than ranking
      // as a genuine zero — "hardest last" should not be a list of sessions we
      // could not score.
      case WorkoutSort.hardest:
        out.sort((a, b) {
          final sa = strainOf(a);
          final sb = strainOf(b);
          if (sa == null || sb == null) {
            if (sa != sb) return sa == null ? 1 : -1;
          } else {
            final c = sb.compareTo(sa);
            if (c != 0) return c;
          }
          return startOf(b).compareTo(startOf(a));
        });
    }
    return out;
  }
}

/// Re-aggregate the training summary over a filtered list, mirroring the
/// repo's own aggregation (`getWorkouts`) so a filtered feed never shows
/// whole-range totals above a narrowed list.
///
/// Live sessions are excluded exactly as the repo excludes them — they have no
/// final numbers to add up.
Map<String, dynamic> summarizeWorkouts(List<Map<String, dynamic>> workouts) {
  var count = 0, totalMin = 0;
  // Null until something actually contributes. A range where every session
  // was uncosted must report nothing, not a confident 0 kcal — the same
  // fabrication this whole change removes, one level up.
  int? totalCal;
  final zoneSum = <num>[];
  for (final w in workouts) {
    if (w['status'] == 'live') continue;
    count++;
    totalMin += ((w['duration_min'] as num?) ?? 0).toInt();
    // An absent calorie figure is skipped, not defaulted — and if EVERY
    // session is absent the total stays null rather than collapsing to a
    // confident zero.
    final cal = (w['calories'] as num?)?.toInt();
    if (cal != null) totalCal = (totalCal ?? 0) + cal;
    final zm = (w['zone_min'] as List?) ?? const [];
    for (var i = 0; i < zm.length; i++) {
      final v = (zm[i] as num?) ?? 0;
      if (i < zoneSum.length) {
        zoneSum[i] += v;
      } else {
        zoneSum.add(v);
      }
    }
  }
  return {
    'count': count,
    'total_min': totalMin,
    'total_calories': totalCal,
    'zone_min': zoneSum,
  };
}
