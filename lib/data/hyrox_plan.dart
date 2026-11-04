// HYROX PLAN — pure Dart, no Flutter, no sqflite.
//
// A plan is what the athlete chose BEFORE arming: the ordered rounds, the
// station of each round, the planned targets and the optional goal times. It
// is frozen into `hyrox_session.plan_json` at arm time and never edited
// afterwards, so a finished race still says what was actually attempted
// rather than what the preset means today.
//
// Domain decision, made once and documented here: ONE SEGMENT PER ROUND. A
// HYROX round is 1 km run + one station, and this app models the round as a
// single `hyrox_round` segment (kind + `station` + `round_index` 1..8) rather
// than a run/station split. The athlete taps at round transitions — after
// each station, before the next run — which is exactly eight boundaries for
// eight rounds plus the start. The final 1 km run after round 8 is part of
// round 8's segment: segment 8 runs from the start of round 8's run to the
// finish line. The interleaved 1 km runs are NOT separate segments in this
// model; if a future PR wants run/station granularity that is a new segment
// kind, not a reinterpretation of `hyrox_round`.
//
// Two rules shape this file:
//
//  * A PLANNED distance/reps/calorie target is not a MEASURED distance. The
//    preset table below is a target the user typed or accepted, never
//    something the band measured, so it lives here and not in
//    `hyrox_segment.distance_m`.
//  * HYROX is always an indoor arena event, so there is no per-segment
//    indoor/outdoor choice (unlike triathlon): the runs happen on an indoor
//    track and no segment arms GPS.

/// Current serialization version of [HyroxPlan.toJson]. Readers refuse a
/// newer major version instead of silently dropping fields they do not know.
const int kHyroxPlanVersion = 1;

/// Every HYROX segment in this build is one round. The kind exists so the row
/// format can grow (e.g. a finer run/station split) without a schema change.
enum HyroxSegmentKind { hyroxRound }

extension HyroxSegmentKindX on HyroxSegmentKind {
  String get key => switch (this) {
        HyroxSegmentKind.hyroxRound => 'hyrox_round',
      };

  static HyroxSegmentKind? fromKey(String? key) => switch (key) {
        'hyrox_round' => HyroxSegmentKind.hyroxRound,
        _ => null,
      };
}

/// The eight stations, in the fixed HYROX race order. `key` is the on-disk
/// value; free-form presets reuse the same vocabulary.
enum HyroxStation {
  skierg,
  sledPush,
  sledPull,
  burpeeBroadJump,
  rowing,
  farmersCarry,
  sandbagLunges,
  wallBalls,
}

extension HyroxStationX on HyroxStation {
  String get key => switch (this) {
        HyroxStation.skierg => 'skierg',
        HyroxStation.sledPush => 'sled_push',
        HyroxStation.sledPull => 'sled_pull',
        HyroxStation.burpeeBroadJump => 'burpee_broad_jump',
        HyroxStation.rowing => 'rowing',
        HyroxStation.farmersCarry => 'farmers_carry',
        HyroxStation.sandbagLunges => 'sandbag_lunges',
        HyroxStation.wallBalls => 'wall_balls',
      };

  static HyroxStation? fromKey(String? key) => switch (key) {
        'skierg' => HyroxStation.skierg,
        'sled_push' => HyroxStation.sledPush,
        'sled_pull' => HyroxStation.sledPull,
        'burpee_broad_jump' => HyroxStation.burpeeBroadJump,
        'rowing' => HyroxStation.rowing,
        'farmers_carry' => HyroxStation.farmersCarry,
        'sandbag_lunges' => HyroxStation.sandbagLunges,
        'wall_balls' => HyroxStation.wallBalls,
        _ => null,
      };
}

/// The fixed station order of a HYROX race.
const List<HyroxStation> kHyroxStationOrder = [
  HyroxStation.skierg,
  HyroxStation.sledPush,
  HyroxStation.sledPull,
  HyroxStation.burpeeBroadJump,
  HyroxStation.rowing,
  HyroxStation.farmersCarry,
  HyroxStation.sandbagLunges,
  HyroxStation.wallBalls,
];

/// Every round starts with a 1 km run. Fixed by the race format, so it is a
/// constant of the domain and not a per-segment plan field.
const double kHyroxRunPerRoundM = 1000;

/// Preset keys. `hyrox` and `hyrox_doubles` are the fixed eight-station race
/// (doubles only changes who does which round — a pairing concern, not a
/// storage one, so the segments are identical); `hyrox_training` and `custom`
/// are free-form ordered lists. No event-brand marks, see TRADEMARKS.md.
const List<String> kHyroxPresets = [
  'hyrox',
  'hyrox_doubles',
  'hyrox_training',
  'custom',
];

/// True for the two fixed-race presets that must always be the canonical
/// eight rounds in order.
bool _isFixedRacePreset(String preset) =>
    preset == 'hyrox' || preset == 'hyrox_doubles';

/// Planned targets per station for the fixed race: (distance m, reps, cal).
/// Matches the official HYROX rulebook (Singles/Doubles/Relay 26/27): every
/// round is a 1000 m run followed by one station — SkiErg 1000 m, sled push
/// 4×12.5 m = 50 m, sled pull 50 m, burpee broad jumps 80 m, rowing 1000 m,
/// farmers carry 200 m, sandbag lunges 100 m, wall balls 100 reps. Loads
/// (sled/kettlebell/sandbag/ball weights) vary by division and are a gym-setup
/// detail, not stored. `planned_cal` exists only for free-form training plans
/// that target calories instead of metres on an erg.
const Map<HyroxStation, (double?, int?, int?)> kHyroxStationTargets = {
  HyroxStation.skierg: (1000, null, null),
  HyroxStation.sledPush: (50, null, null),
  HyroxStation.sledPull: (50, null, null),
  HyroxStation.burpeeBroadJump: (80, null, null),
  HyroxStation.rowing: (1000, null, null),
  HyroxStation.farmersCarry: (200, null, null),
  HyroxStation.sandbagLunges: (100, null, null),
  HyroxStation.wallBalls: (null, 100, null),
};

class HyroxSegmentPlan {
  const HyroxSegmentPlan({
    required this.kind,
    required this.station,
    this.roundIndex,
    this.plannedDistanceM,
    this.plannedReps,
    this.plannedCal,
    this.goalSec,
  });

  final HyroxSegmentKind kind;

  /// Which station this round ends with.
  final HyroxStation station;

  /// 1..8 in a fixed race; null in a free-form plan. A plan target, not a
  /// measurement.
  final int? roundIndex;

  /// Target distance in metres for distance-based stations, or null. This is
  /// a PLAN, not a measurement.
  final double? plannedDistanceM;

  /// Target repetitions for rep-based stations (wall balls), or null.
  final int? plannedReps;

  /// Target calories for cal-based stations (skierg/rowing alternative), or
  /// null.
  final int? plannedCal;

  /// Optional goal time in seconds for the whole round. Null = no goal.
  final int? goalSec;

  Map<String, Object?> toJson() => {
        'kind': kind.key,
        'station': station.key,
        'round_index': roundIndex,
        'planned_distance_m': plannedDistanceM,
        'planned_reps': plannedReps,
        'planned_cal': plannedCal,
        'goal_sec': goalSec,
      };

  static HyroxSegmentPlan? fromJson(Map<String, Object?> j) {
    final rawKind = j['kind'];
    final rawStation = j['station'];
    final kind = HyroxSegmentKindX.fromKey(rawKind is String ? rawKind : null);
    final station =
        HyroxStationX.fromKey(rawStation is String ? rawStation : null);
    if (kind == null || station == null) return null;
    final dist = j['planned_distance_m'];
    final reps = j['planned_reps'];
    final cal = j['planned_cal'];
    final round = j['round_index'];
    final goal = j['goal_sec'];
    return HyroxSegmentPlan(
      kind: kind,
      station: station,
      roundIndex: round is num ? round.toInt() : null,
      plannedDistanceM: dist is num ? dist.toDouble() : null,
      plannedReps: reps is num ? reps.toInt() : null,
      plannedCal: cal is num ? cal.toInt() : null,
      goalSec: goal is num ? goal.toInt() : null,
    );
  }
}

class HyroxPlan {
  const HyroxPlan({
    required this.preset,
    required this.segments,
  });

  /// 'hyrox' | 'hyrox_doubles' | 'hyrox_training' | 'custom'. Free-form on
  /// disk on purpose: an older build must still be able to SHOW a plan whose
  /// preset it does not know.
  final String preset;
  final List<HyroxSegmentPlan> segments;

  bool get isTraining => preset == 'hyrox_training' || preset == 'custom';

  /// The fixed eight-round race. `preset` must be 'hyrox' or 'hyrox_doubles';
  /// [goalSec] optionally overrides the per-round goal times.
  factory HyroxPlan.race(
    String preset, {
    Map<HyroxStation, int>? goalSec,
  }) {
    if (!_isFixedRacePreset(preset)) {
      throw ArgumentError('race() needs a fixed preset, got "$preset"');
    }
    return HyroxPlan(
      preset: preset,
      segments: [
        for (var i = 0; i < kHyroxStationOrder.length; i++)
          HyroxSegmentPlan(
            kind: HyroxSegmentKind.hyroxRound,
            station: kHyroxStationOrder[i],
            roundIndex: i + 1,
            plannedDistanceM: kHyroxStationTargets[kHyroxStationOrder[i]]?.$1,
            plannedReps: kHyroxStationTargets[kHyroxStationOrder[i]]?.$2,
            plannedCal: kHyroxStationTargets[kHyroxStationOrder[i]]?.$3,
            goalSec: goalSec?[kHyroxStationOrder[i]],
          ),
      ],
    );
  }

  /// Free-form training: any ordered subset/repetition of stations (e.g. a
  /// single-station drill or a 4-round opener).
  factory HyroxPlan.training(List<HyroxSegmentPlan> segments) =>
      HyroxPlan(preset: 'hyrox_training', segments: segments);

  /// Free-form custom session.
  factory HyroxPlan.custom(List<HyroxSegmentPlan> segments) =>
      HyroxPlan(preset: 'custom', segments: segments);

  /// Structural validation. Returns a human-readable problem, or null when the
  /// plan is storable. This is not a judgement about whether the workout is a
  /// good idea — only whether the row can be interpreted later.
  String? validate() {
    if (segments.isEmpty) return 'a plan needs at least one segment';
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final r = s.roundIndex;
      if (r != null && r <= 0) return 'a round index is positive or absent';
      final d = s.plannedDistanceM;
      if (d != null && (!d.isFinite || d <= 0)) {
        return 'a planned distance is finite and positive, or absent';
      }
      final reps = s.plannedReps;
      if (reps != null && reps <= 0) {
        return 'a planned rep count is positive or absent';
      }
      final cal = s.plannedCal;
      if (cal != null && cal <= 0) {
        return 'a planned calorie target is positive or absent';
      }
      final g = s.goalSec;
      if (g != null && g <= 0) return 'a goal time is positive or absent';
    }
    if (_isFixedRacePreset(preset)) {
      if (segments.length != kHyroxStationOrder.length) {
        return 'a fixed race plan is exactly the eight stations in order';
      }
      for (var i = 0; i < kHyroxStationOrder.length; i++) {
        final s = segments[i];
        if (s.station != kHyroxStationOrder[i] || s.roundIndex != i + 1) {
          return 'a fixed race plan is exactly the eight stations in order';
        }
      }
    }
    return null;
  }

  /// HYROX is an indoor arena event end to end — the runs are on an indoor
  /// track — so no segment ever arms GPS.
  bool get needsGps => false;

  Map<String, Object?> toJson() => {
        'v': kHyroxPlanVersion,
        'preset': preset,
        'segments': [for (final s in segments) s.toJson()],
      };

  /// Null when the payload is not a plan this build can read. Callers treat
  /// that as "unknown plan", never as an empty race.
  static HyroxPlan? fromJson(Map<String, Object?> j) {
    final rawV = j['v'];
    final v = rawV is num ? rawV.toInt() : null;
    if (v == null || v < 1 || v > kHyroxPlanVersion) return null;
    final preset = j['preset'];
    final raw = j['segments'];
    if (preset is! String || raw is! List) return null;
    final segments = <HyroxSegmentPlan>[];
    for (final e in raw) {
      if (e is! Map) return null;
      final s = HyroxSegmentPlan.fromJson(e.cast<String, Object?>());
      if (s == null) return null;
      segments.add(s);
    }
    return HyroxPlan(preset: preset, segments: segments);
  }
}
