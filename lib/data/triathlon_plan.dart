// Triathlon / multisport PLAN — pure Dart, no Flutter, no sqflite.
//
// A plan is what the athlete chose BEFORE arming: the ordered segments, the
// environment of each discipline, the planned distances and the optional goal
// times. It is frozen into `triathlon_session.plan_json` at arm time and never
// edited afterwards, so a finished race still says what was actually attempted
// rather than what the preset means today.
//
// Two rules shape this file:
//
//  * A PLANNED distance is not a MEASURED distance. The preset table below is
//    a target the user typed or accepted, never something the band measured,
//    so it lives here and not in `triathlon_segment.distance_m`.
//  * Environment is PER SEGMENT, because a real race can be mixed (open-water
//    swim, outdoor bike, treadmill run in a winter training block) and the
//    honest metric set differs per segment, not per session. Indoor segments
//    must never inherit a route or a pace from an outdoor sibling.

import '../gps/route_types.dart';

/// Current serialization version of [TriathlonPlan.toJson]. Readers refuse a
/// newer major version instead of silently dropping fields they do not know.
const int kTriathlonPlanVersion = 1;

enum TriSegmentKind { swim, t1, bike, t2, run }

enum TriEnvironment { indoor, outdoor }

extension TriSegmentKindX on TriSegmentKind {
  String get key => switch (this) {
        TriSegmentKind.swim => 'swim',
        TriSegmentKind.t1 => 't1',
        TriSegmentKind.bike => 'bike',
        TriSegmentKind.t2 => 't2',
        TriSegmentKind.run => 'run',
      };

  /// T1/T2 are first-class timed segments, but they are not a discipline: no
  /// route, no distance, no `sessions` row of their own.
  bool get isTransition =>
      this == TriSegmentKind.t1 || this == TriSegmentKind.t2;

  static TriSegmentKind? fromKey(String? key) => switch (key) {
        'swim' => TriSegmentKind.swim,
        't1' => TriSegmentKind.t1,
        'bike' => TriSegmentKind.bike,
        't2' => TriSegmentKind.t2,
        'run' => TriSegmentKind.run,
        _ => null,
      };
}

extension TriEnvironmentX on TriEnvironment {
  String get key => this == TriEnvironment.indoor ? 'indoor' : 'outdoor';

  static TriEnvironment? fromKey(String? key) => switch (key) {
        'indoor' => TriEnvironment.indoor,
        'outdoor' => TriEnvironment.outdoor,
        _ => null,
      };
}

/// The `sessions.type` a timed segment is banked as, or null for a transition.
///
/// These are the EXISTING catalogue keys, deliberately not new ones: banking a
/// bike leg as `cycling` is what lets the existing route, zone, split and
/// Health-export code read it without a second code path. A swim maps to
/// `swimming` in BOTH environments because this app records no swim route —
/// open water included, since a wrist GPS fix under water is not a measurement
/// this stack can stand behind.
String? triathlonSessionType(TriSegmentKind kind, TriEnvironment? env) {
  if (kind.isTransition) return null;
  return switch (kind) {
    TriSegmentKind.swim => 'swimming',
    TriSegmentKind.bike =>
      env == TriEnvironment.indoor ? 'indoor_bike' : 'cycling',
    TriSegmentKind.run =>
      env == TriEnvironment.indoor ? 'treadmill' : 'running',
    _ => null,
  };
}

/// True when this segment may arm GPS. Derived from the shared route gate, so
/// a new catalogue entry cannot drift away from it (pinned by test).
bool triathlonSegmentRecordsRoute(TriSegmentKind kind, TriEnvironment? env) {
  final type = triathlonSessionType(kind, env);
  return type != null && typeRecordsRoute(type);
}

/// Preset keys. Generic distance names only — no event-brand marks, see
/// TRADEMARKS.md. `custom` keeps the race segment order with user distances;
/// `training` is a free ordered list (brick, aquathlon, single discipline).
const List<String> kTriathlonRacePresets = [
  'sprint',
  'olympic',
  'half_distance',
  'full_distance',
];

/// Planned distances in METRES for (swim, bike, run). These are the commonly
/// published nominal distances for each format, stored as an editable default:
/// the user's own race may differ, which is exactly why the plan is frozen per
/// session instead of looked up at display time.
const Map<String, List<double>> kTriathlonPresetDistancesM = {
  'sprint': [750, 20000, 5000],
  'olympic': [1500, 40000, 10000],
  'half_distance': [1900, 90000, 21100],
  'full_distance': [3800, 180000, 42200],
};

class TriSegmentPlan {
  const TriSegmentPlan({
    required this.kind,
    this.environment,
    this.plannedDistanceM,
    this.goalSec,
  });

  final TriSegmentKind kind;

  /// Null for transitions (a transition has no environment of its own) and
  /// null when the user genuinely did not say. Never defaulted on read.
  final TriEnvironment? environment;

  /// Target distance in metres, or null when there is no target. A transition
  /// never has one. This is a PLAN, not a measurement.
  final double? plannedDistanceM;

  /// Optional goal time in seconds. Null = no goal, not zero.
  final int? goalSec;

  Map<String, Object?> toJson() => {
        'kind': kind.key,
        'environment': environment?.key,
        'planned_distance_m': plannedDistanceM,
        'goal_sec': goalSec,
      };

  static TriSegmentPlan? fromJson(Map<String, Object?> j) {
    final kind = TriSegmentKindX.fromKey(j['kind'] as String?);
    if (kind == null) return null;
    return TriSegmentPlan(
      kind: kind,
      environment: TriEnvironmentX.fromKey(j['environment'] as String?),
      plannedDistanceM: (j['planned_distance_m'] as num?)?.toDouble(),
      goalSec: (j['goal_sec'] as num?)?.toInt(),
    );
  }
}

class TriathlonPlan {
  const TriathlonPlan({
    required this.preset,
    required this.segments,
  });

  /// 'sprint' | 'olympic' | 'half_distance' | 'full_distance' | 'custom' |
  /// 'training'. Free-form on disk on purpose: an older build must still be
  /// able to SHOW a plan whose preset it does not know.
  final String preset;
  final List<TriSegmentPlan> segments;

  bool get isTraining => preset == 'training';

  /// A standard race order. [swimEnv]/[bikeEnv]/[runEnv] are required because
  /// "the user decides before starting" is the whole point of the setting;
  /// silently defaulting to outdoor would arm GPS nobody asked for.
  factory TriathlonPlan.race(
    String preset, {
    required TriEnvironment swimEnv,
    required TriEnvironment bikeEnv,
    required TriEnvironment runEnv,
    Map<TriSegmentKind, double>? distanceOverridesM,
    Map<TriSegmentKind, int>? goalSec,
  }) {
    final defaults = kTriathlonPresetDistancesM[preset];
    double? distance(TriSegmentKind kind, int index) {
      final override = distanceOverridesM?[kind];
      if (override != null) return override;
      return defaults == null ? null : defaults[index];
    }

    return TriathlonPlan(
      preset: preset,
      segments: [
        TriSegmentPlan(
          kind: TriSegmentKind.swim,
          environment: swimEnv,
          plannedDistanceM: distance(TriSegmentKind.swim, 0),
          goalSec: goalSec?[TriSegmentKind.swim],
        ),
        const TriSegmentPlan(kind: TriSegmentKind.t1),
        TriSegmentPlan(
          kind: TriSegmentKind.bike,
          environment: bikeEnv,
          plannedDistanceM: distance(TriSegmentKind.bike, 1),
          goalSec: goalSec?[TriSegmentKind.bike],
        ),
        const TriSegmentPlan(kind: TriSegmentKind.t2),
        TriSegmentPlan(
          kind: TriSegmentKind.run,
          environment: runEnv,
          plannedDistanceM: distance(TriSegmentKind.run, 2),
          goalSec: goalSec?[TriSegmentKind.run],
        ),
      ],
    );
  }

  /// Free-form training: brick (bike→run), aquathlon (swim→run), or a single
  /// discipline. Transitions are inserted by the caller where they belong.
  factory TriathlonPlan.training(List<TriSegmentPlan> segments) =>
      TriathlonPlan(preset: 'training', segments: segments);

  /// Structural validation. Returns a human-readable problem, or null when the
  /// plan is storable. This is not a judgement about whether the workout is a
  /// good idea — only whether the row can be interpreted later.
  String? validate() {
    if (segments.isEmpty) return 'a plan needs at least one segment';
    if (segments.first.kind.isTransition || segments.last.kind.isTransition) {
      return 'a plan starts and ends with a discipline, not a transition';
    }
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.kind.isTransition) {
        if (i > 0 && segments[i - 1].kind.isTransition) {
          return 'two transitions cannot be adjacent';
        }
        if (s.environment != null || s.plannedDistanceM != null) {
          return 'a transition has no environment or distance';
        }
        continue;
      }
      if (s.environment == null) {
        return 'every discipline needs an indoor/outdoor choice';
      }
      final d = s.plannedDistanceM;
      if (d != null && (!d.isFinite || d <= 0)) {
        return 'a planned distance is finite and positive, or absent';
      }
    }
    if (!isTraining) {
      const order = [
        TriSegmentKind.swim,
        TriSegmentKind.t1,
        TriSegmentKind.bike,
        TriSegmentKind.t2,
        TriSegmentKind.run,
      ];
      if (segments.length != order.length) {
        return 'a race plan is swim, T1, bike, T2, run';
      }
      for (var i = 0; i < order.length; i++) {
        if (segments[i].kind != order[i]) {
          return 'a race plan is swim, T1, bike, T2, run';
        }
      }
    }
    for (final s in segments) {
      final g = s.goalSec;
      if (g != null && g <= 0) return 'a goal time is positive or absent';
    }
    return null;
  }

  /// True when ANY segment may record a route — the only case in which the
  /// setup flow should ask for location permission at all.
  bool get needsGps => segments.any(
        (s) => triathlonSegmentRecordsRoute(s.kind, s.environment),
      );

  Map<String, Object?> toJson() => {
        'v': kTriathlonPlanVersion,
        'preset': preset,
        'segments': [for (final s in segments) s.toJson()],
      };

  /// Null when the payload is not a plan this build can read. Callers treat
  /// that as "unknown plan", never as an empty race.
  static TriathlonPlan? fromJson(Map<String, Object?> j) {
    final v = (j['v'] as num?)?.toInt();
    if (v == null || v > kTriathlonPlanVersion) return null;
    final preset = j['preset'];
    final raw = j['segments'];
    if (preset is! String || raw is! List) return null;
    final segments = <TriSegmentPlan>[];
    for (final e in raw) {
      if (e is! Map) return null;
      final s = TriSegmentPlan.fromJson(e.cast<String, Object?>());
      if (s == null) return null;
      segments.add(s);
    }
    return TriathlonPlan(preset: preset, segments: segments);
  }
}
