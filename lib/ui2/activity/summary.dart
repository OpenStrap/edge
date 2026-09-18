// The activity summary — eight archetypes, eight centres of gravity.
//
// The rule the whole file exists to enforce: a strength session is NOT a run
// with the map removed. A run is a route coloured by pace; a hike is an
// elevation profile; a swim is a lap ladder; HIIT is an interval ladder; a
// match is heart rate and hard minutes. Same grammar — same cards, same type,
// same spacing — different defining object.
//
// A lift is the exception that proves it: it has NO defining visual object,
// because nothing here measures one. The muscle map that used to hold the
// slot was a static exercise→group table times the volume the user typed,
// painted onto a body — a picture that looks measured and is not.
//
// [ActivityResult] is the seam. Everything on screen comes out of it, every
// field is nullable or empty by default, and an absent field renders a
// StatusCard rather than a zero. That is not politeness: `sessions` has no
// distance, no lap and no set columns of its own, so several of these fields
// come from elsewhere (`workout_route`, `strength_set`) or not at all, and the
// screen has to be honest about it without falling apart.

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/db.dart';
import '../../gps/gpx_export.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../../state/units_controller.dart';
import '../charts.dart';
import '../grammar.dart';
import '../paint_activity.dart';
import '../profile/profile.dart';
import '../screens/home_screen.dart' show unitsOf;
import '../screens/log_workout.dart' show bumpInsights;
import '../theme.dart';
import 'catalogue.dart';
import 'picker.dart';
// The share card and this screen describe the same session, so they draw its
// stats with the same widget and split its values with the same function.
// poster.dart imports this file back for [ActivityResult]; that is the seam,
// not a layering mistake.
import 'poster.dart' show PosterStatRow, posterStatIcon, splitStatUnit;
import 'share.dart';

/// The defining visual object of an activity. Everything else supports it.
///
/// There is no `power`. Cycling power is watts at the crank, and nothing in
/// this stack measures them: no power meter is paired, no opcode carries them,
/// and a wrist cannot infer them. The indoor machines that used to claim the
/// archetype (bike, treadmill, elliptical, stair climber) are [basic] — their
/// defining object is the heart-rate trace, which is measured.
enum Arch { route, strength, interval, flow, laps, journey, match, basic }

const _sports = {
  'Football', 'Basketball', 'Cricket', 'Tennis', 'Badminton', 'Table tennis',
  'Squash', 'Volleyball', 'Hockey', 'Baseball', 'Rugby', 'Boxing',
  'Martial arts', 'Wrestling',
};
const _laps = {'Swimming', 'Rowing'};
const _journey = {
  'Hiking', 'Trail running', 'Mountain biking', 'Skiing', 'Snowboarding',
};

/// MT-08 — deliberate heat and cold. Not an archetype: both are
/// `Track.stillness`, so both land on [Arch.flow], and what they need is a
/// different defining object inside it rather than an eighth centre of
/// gravity. The reason they need one is physiological — **cold exposure causes
/// peripheral vasoconstriction, which is exactly when wrist reflectance PPG
/// has nothing to measure** — so a plunge whose card says the sensor could not
/// find a pulse is the correct outcome, not a failure state to design around.
const _thermal = {'Sauna', 'Cold plunge'};

/// Name first, then track. The named sets are the activities whose defining
/// object is not what their tracking mode would suggest — a hike is tracked by
/// distance but is *about* the climb, and swimming is tracked by distance but
/// is *about* the lap.
Arch archOf(Activity a) {
  if (_journey.contains(a.name)) return Arch.journey;
  if (_laps.contains(a.name)) return Arch.laps;
  if (_sports.contains(a.name)) return Arch.match;
  return switch (a.track) {
    Track.sets => Arch.strength,
    Track.interval => Arch.interval,
    Track.stillness => Arch.flow,
    Track.distance => Arch.route,
    Track.duration => Arch.basic,
  };
}

String archLabel(Arch a) => switch (a) {
      Arch.route => 'Route',
      Arch.strength => 'Sets and load',
      Arch.interval => 'Intervals',
      Arch.flow => 'Flow',
      Arch.laps => 'Laps',
      Arch.journey => 'Elevation',
      Arch.match => 'Effort',
      Arch.basic => 'Session',
    };

// ── THE RECORD ─────────────────────────────────────────────────────────────

/// One logged set. `loadKg` is nullable and that is load-bearing: a bodyweight
/// pull-up stored as 0 kg makes session volume report zero for a real session
/// (UI_WIRING §5.4).
class LoggedSet {
  final String exerciseKey;
  final int reps;
  final double? loadKg;
  final int? rpe;
  final int? restSec;
  final DateTime at;

  const LoggedSet(this.exerciseKey, this.reps,
      {this.loadKg, this.rpe, this.restSec, required this.at});

  /// Volume for this set, or null when the load was never recorded.
  double? get volume => loadKg == null ? null : loadKg! * reps;
}

/// A strength session's sets, in log order.
class StrengthLog {
  final List<LoggedSet> sets;
  const StrengthLog(this.sets);

  static const empty = StrengthLog([]);

  bool get isEmpty => sets.isEmpty;
  int get setCount => sets.length;
  int get repCount => sets.fold(0, (a, s) => a + s.reps);
  List<String> get exercises {
    final seen = <String>[];
    for (final s in sets) {
      if (!seen.contains(s.exerciseKey)) seen.add(s.exerciseKey);
    }
    return seen;
  }

  /// Σ load × reps over the sets that HAVE a load. Null when none of them do —
  /// a bodyweight-only session has a real volume nobody measured.
  double? get volumeKg {
    var total = 0.0;
    var any = false;
    for (final s in sets) {
      final v = s.volume;
      if (v == null) continue;
      total += v;
      any = true;
    }
    return any ? total : null;
  }

  /// Whether any set was logged without a load — the total is then a floor,
  /// not a total, and the screen says so.
  bool get hasUnloadedSets => sets.any((s) => s.loadKg == null);

  Map<String, double> get volumeByExercise {
    final out = <String, double>{};
    for (final s in sets) {
      final v = s.volume;
      if (v == null) continue;
      out[s.exerciseKey] = (out[s.exerciseKey] ?? 0) + v;
    }
    return out;
  }

  /// Heaviest set by load, ties broken by reps. Null when nothing was loaded.
  LoggedSet? get topSet {
    LoggedSet? best;
    for (final s in sets) {
      if (s.loadKg == null) continue;
      if (best == null ||
          s.loadKg! > best.loadKg! ||
          (s.loadKg == best.loadKg && s.reps > best.reps)) {
        best = s;
      }
    }
    return best;
  }

  List<LoggedSet> forExercise(String key) =>
      [for (final s in sets) if (s.exerciseKey == key) s];
}

/// Epley 1RM estimate — ALWAYS an estimate, never shown without saying so.
/// Epley B. (1985), Poundage Chart. Boone's/Brzycki disagree by a few kg; at
/// six reps or fewer they are all within noise of each other.
double? oneRepMax(LoggedSet? s) =>
    s?.loadKg == null || s!.reps < 1 ? null : s.loadKg! * (1 + s.reps / 30);

/// One HIIT round.
class IntervalRound {
  final int workSec, restSec;
  final int? avgHr;
  const IntervalRound(this.workSec, this.restSec, {this.avgHr});
}

/// One distance split. Named `KmSplit` because Flutter's animation library
/// already owns `Split`, and a screen importing both should not have to.
class KmSplit {
  final double km;
  final int sec;
  final int? avgHr;
  const KmSplit(this.km, this.sec, {this.avgHr});
}

/// Everything a finished session knows about itself. Absent means absent.
class ActivityResult {
  final Activity activity;
  final DateTime start;
  final Duration duration;
  final bool private;

  /// `sessions.id`, once the session is durably written. Null on a draft, on a
  /// session whose write threw, and in every fixture — and the RPE prompt is
  /// gated on it, because there is nowhere to put an answer without one.
  final String? sessionId;

  /// TS-09 — session RPE, 1–10. A SELF-REPORT and labelled as one wherever it
  /// is shown. Null means UNRATED, which is not a 0 and not a 7: the
  /// set-level picker's default of 7 is the garbage-data mechanism this field
  /// exists to avoid, so nothing here is ever pre-selected.
  final double? rpe;

  // measured by the band / phone
  final int? avgHr, maxHr, calories;

  /// Heart-rate recovery: the bpm drop over the 60 s after the session ended.
  /// Backfilled into `sessions.hrr_bpm` during derivation and served on every
  /// session row — 11 of 14 sessions on the real export carry one, and nothing
  /// read it. Null is UNMEASURED (no trace over the minute after, or a session
  /// that ended into another one), never a zero drop.
  final int? hrr60;
  final double? strain;
  // Per-MINUTE mean heart rate, live (`LiveWorkoutState.perMinuteHr`) and
  // stored (`getWorkout()['hr']`) alike. Nothing on this screen has ever been
  // per-second, whatever the copy used to say.
  /// DENSE — one slot per minute of the session, `null` where the band
  /// recorded nothing. A compacted curve under an axis labelled `Start …
  /// duration` draws a dropout as though it had been measured.
  final List<double?> hr;
  final List<double> zoneMinutes; // five, Z1..Z5

  /// WHICH anchors [zoneMinutes] was binned against — `karvonen` · `observed` ·
  /// `tanaka`, the stamp `trainingZones` puts on the set — and the ceiling that
  /// set is 100 % of.
  ///
  /// Carried rather than re-derived so this card cannot describe the split it
  /// is drawing as coming from anchors it did not use. Null while the split has
  /// not been enriched (the history row, a preview): the footnote then says the
  /// estimate, which is the claim that needs no ceiling to back it.
  final String? zoneSource;
  final num? zoneMaxHr;

  /// Steps the strap's own 100 Hz pedometer counted over this session —
  /// `AppState.workoutStepsMeasured` while it runs, `sessions.steps` once it is
  /// banked. That column has exactly one producer (an import and a hand-logged
  /// session write it null on purpose), so this number has one provenance.
  ///
  /// NULL IS UNMEASURED, and it is the common case: no live link, the raw
  /// stream suppressed by the standard-HR fallback, a session logged by hand,
  /// or an activity the counter is not allowed to count. Never a 0 standing in
  /// for any of those — that is issue #183, a mile walked under '0 STEPS'.
  ///
  /// Read [stepsCounted], not this. The gait gate lives there.
  final int? steps;

  /// How much of the session window the stored trace actually covers, 0–100.
  /// 1 Hz means one sample a second, so the banked sample count against the
  /// window length is the honest coverage of everything drawn off it. Null on a
  /// live session (nothing has been banked yet) and on any session scored
  /// before the trace column existed.
  final int? traceCoveragePct;

  // route / journey
  final List<Offset> route; // normalised 0…1
  /// The SAME points in degrees, in the same order — kept alongside [route]
  /// rather than instead of it because the painters want a unit box and a
  /// basemap wants the globe. Empty when the session had no GPS.
  final List<(double lat, double lng)> geo;
  final List<double>? routePace; // per-point 0…1, colours the route
  final double? distanceKm;
  final List<double> elevationM;
  final double? gainM, lossM;
  final List<KmSplit> splits;

  // strength
  final StrengthLog strength;

  // laps — seconds per lap, in order. The bar chart's relative speeds are
  // derived from these rather than stored beside them: two fields for one
  // measurement is how a chart ends up disagreeing with its own axis.
  final List<int> lapSecs;
  final int? poolLengthM;
  final String? stroke;

  // intervals
  final List<IntervalRound> rounds;

  // flow
  final List<String> poses;
  final double? breathsPerMin;

  // match
  final List<(int, int)> gameScore;

  const ActivityResult(
    this.activity, {
    required this.start,
    required this.duration,
    this.private = false,
    this.sessionId,
    this.rpe,
    this.avgHr,
    this.maxHr,
    this.hrr60,
    this.calories,
    this.strain,
    this.hr = const [],
    this.zoneMinutes = const [],
    this.zoneSource,
    this.zoneMaxHr,
    this.steps,
    this.traceCoveragePct,
    this.route = const [],
    this.geo = const [],
    this.routePace,
    this.distanceKm,
    this.elevationM = const [],
    this.gainM,
    this.lossM,
    this.splits = const [],
    this.strength = StrengthLog.empty,
    this.lapSecs = const [],
    this.poolLengthM,
    this.stroke,
    this.rounds = const [],
    this.poses = const [],
    this.breathsPerMin,
    this.gameScore = const [],
  });

  /// A copy carrying the things a session can only learn after it ends — the
  /// recorded route above all. Every field defaults to `this`, so enrichment
  /// can never silently drop the sets or the score the user typed.
  ActivityResult copyWith({
    String? sessionId,
    double? rpe,
    int? avgHr,
    int? maxHr,
    int? hrr60,
    List<double?>? hr,
    List<double>? zoneMinutes,
    String? zoneSource,
    num? zoneMaxHr,
    int? traceCoveragePct,
    List<Offset>? route,
    List<(double lat, double lng)>? geo,
    List<double>? routePace,
    double? distanceKm,
    List<double>? elevationM,
    double? gainM,
    double? lossM,
    List<KmSplit>? splits,
    StrengthLog? strength,
  }) =>
      ActivityResult(
        activity,
        start: start,
        duration: duration,
        private: private,
        sessionId: sessionId ?? this.sessionId,
        rpe: rpe ?? this.rpe,
        avgHr: avgHr ?? this.avgHr,
        maxHr: maxHr ?? this.maxHr,
        hrr60: hrr60 ?? this.hrr60,
        calories: calories,
        strain: strain,
        hr: hr ?? this.hr,
        zoneMinutes: zoneMinutes ?? this.zoneMinutes,
        zoneSource: zoneSource ?? this.zoneSource,
        zoneMaxHr: zoneMaxHr ?? this.zoneMaxHr,
        // Carried, never re-derived: every enrichment pass on this object goes
        // through here, and a field left off this list is a measurement the
        // detail screen silently loses the moment it opens.
        steps: steps,
        traceCoveragePct: traceCoveragePct ?? this.traceCoveragePct,
        route: route ?? this.route,
        geo: geo ?? this.geo,
        routePace: routePace ?? this.routePace,
        distanceKm: distanceKm ?? this.distanceKm,
        elevationM: elevationM ?? this.elevationM,
        gainM: gainM ?? this.gainM,
        lossM: lossM ?? this.lossM,
        splits: splits ?? this.splits,
        strength: strength ?? this.strength,
        lapSecs: lapSecs,
        poolLengthM: poolLengthM,
        stroke: stroke,
        rounds: rounds,
        poses: poses,
        breathsPerMin: breathsPerMin,
        gameScore: gameScore,
      );

  Arch get arch => archOf(activity);

  /// [steps], but only for an activity the pedometer is allowed to count.
  ///
  /// The counter's own gate is on the session TYPE at ingest
  /// (`isGaitStepType`, `ble/live_step_runs.dart`) and it is not a nicety: on a
  /// free-living wrist the counter over-counts by up to +199.5%, and rowing,
  /// boxing and lifting are an hour of exactly the rhythmic arm work that does
  /// it. [Activity.gait] is that same law spelled in the catalogue — the two are
  /// pinned equal by `gait_step_types_test` — so a count banked under one type
  /// can never surface on a screen for another.
  int? get stepsCounted => activity.gait ? steps : null;

  /// Per-lap speed relative to the fastest lap — what [LapBars] draws. The
  /// fastest lap is the only reference the swim itself provides.
  List<double> get lapSpeeds {
    if (lapSecs.isEmpty) return const [];
    final fastest = lapSecs.reduce((x, y) => x < y ? x : y);
    return [for (final t in lapSecs) t <= 0 ? 1.0 : fastest / t];
  }

  /// Minutes above 80% of max heart rate — Z4 and Z5. Null when the session
  /// banked no zone split, because "0 hard minutes" and "nobody counted" are
  /// different sessions.
  double? get hardMinutes => zoneMinutes.length == 5
      ? zoneMinutes[3] + zoneMinutes[4]
      : null;

  /// `(minutes that carry a heart rate, minutes in the session)`.
  ///
  /// `(0, n)` is the band reading nothing for the whole session. On a cold
  /// plunge that is the EXPECTED reading and not an error — see [_thermal].
  (int, int) get hrMinutes {
    var have = 0;
    for (final v in hr) {
      if (v != null) have++;
    }
    return (have, hr.length);
  }

  /// Seconds per kilometre. Null without a distance — there is no pace
  /// without one, and a duration alone will not do.
  int? get paceSecPerKm => distanceKm == null || distanceKm! <= 0
      ? null
      : (duration.inSeconds / distanceKm!).round();

  int? get lapCount => lapSecs.isEmpty ? null : lapSecs.length;

  double? get swimMetres => poolLengthM == null || lapCount == null
      ? null
      : (poolLengthM! * lapCount!).toDouble();
}

// ── FORMATTING ─────────────────────────────────────────────────────────────

/// mm:ss, or h:mm:ss past the hour.
String clock(int seconds) {
  final s = seconds.abs();
  final m = (s ~/ 60) % 60, h = s ~/ 3600;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s % 60)}' : '${two(m)}:${two(s % 60)}';
}

String hms(Duration d) => clock(d.inSeconds);

/// 1 234 → "1,234". Thousands separators, because six-thousand-eight-hundred
/// and forty-two kilos should not read as a phone number.
String grouped(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _shortDate(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${months[t.month - 1]} ${t.day}, ${t.year} at $h:'
      '${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

// ── THE SUPPORTING STATS ───────────────────────────────────────────────────

/// The glyph for a stat name.
///
/// [posterStatIcon] already owns every name a share card can offer; these are
/// the ones only a session screen prints, and everything else falls through to
/// it. One mapping, so `Pace` cannot end up with two marks.
IconData statIcon(String name) => switch (name) {
      'Reps' => LucideIcons.repeat2,
      'Rounds' => LucideIcons.repeat,
      'Poses' => LucideIcons.personStanding,
      'Breathing' => LucideIcons.wind,
      'Hard minutes' => LucideIcons.zap,
      'Strain' => LucideIcons.trendingUp,
      'Avg HR' => LucideIcons.heart,
      'Max HR' => LucideIcons.heartPulse,
      // A person, not an instrument — the one row on this card the band had
      // no part in.
      'Your rating' => LucideIcons.userRound,
      _ => posterStatIcon(name),
    };

/// The supporting numbers a finished session can honestly print, as
/// `(name, formatted value)` — the shape [shareStats] hands the share card, so
/// one session cannot describe itself two ways.
///
/// A stat with nothing behind it is DROPPED, never dashed. There is no cap:
/// the three-across strip this replaced could hold exactly three, so a lift's
/// calories and a run's strain were measured, banked, and then binned by a
/// layout. A column has room for the ones the session actually has.
///
/// The one the hero is already showing is dropped too — see [_heroStatName].
List<(String, String)> sessionStats(ActivityResult r, UnitsController? u) {
  final out = <(String, String)>[];
  final hero = _heroStatName(r);
  void add(String name, String? v) {
    if (v != null && name != hero) out.add((name, v));
  }

  final distanceUnit = u?.distanceUnit ?? 'km';
  final secPerKm = r.paceSecPerKm;
  final perUnit = u == null ? 1.0 : u.distanceUnitMeters / 1000;
  final pace = secPerKm == null
      ? null
      : UnitsController.formatPace(secPerKm * perUnit);

  add('Time', hms(r.duration));
  switch (r.arch) {
    case Arch.route:
      add('Pace', pace == null ? null : '$pace /$distanceUnit');
    case Arch.strength:
      // Guarded like Arch.match below. 'SETS 0' and 'REPS 0' used to sit
      // directly under the card saying nothing was logged, and the share card
      // for the same session — which does gate on this — printed neither.
      add('Sets', r.strength.isEmpty ? null : '${r.strength.setCount}');
      add('Reps', r.strength.isEmpty ? null : '${r.strength.repCount}');
    case Arch.laps:
      add('Laps', r.lapCount?.toString());
    case Arch.journey:
      add('Elevation', r.gainM == null ? null : '+${r.gainM!.round()} m');
    case Arch.interval:
      add('Rounds', r.rounds.isEmpty ? null : '${r.rounds.length}');
    case Arch.flow:
      add('Poses', r.poses.isEmpty ? null : '${r.poses.length}');
      add(
          'Breathing',
          r.breathsPerMin == null
              ? null
              : '${r.breathsPerMin!.toStringAsFixed(1)} br/min');
    case Arch.match:
      add('Sets', r.gameScore.isEmpty ? null : '${r.gameScore.length}');
      add('Hard minutes',
          r.hardMinutes == null ? null : '${r.hardMinutes!.round()} min');
    case Arch.basic:
      break; // time, heart rate and calories are the whole story
  }
  // Beside the other movement facts, above the heart. Offered only where the
  // strap was allowed to count — see [ActivityResult.stepsCounted].
  add('Steps', r.stepsCounted == null ? null : grouped(r.stepsCounted!));
  // 'Avg HR', not 'Heart rate': the trace above is the heart rate, this is its
  // mean, and the two sat on one screen under one word.
  add('Avg HR', r.avgHr == null ? null : '${r.avgHr} bpm');
  // The peak. Measured, spike-suppressed, banked in `sessions.max_hr` and read
  // back on the history path — and until now printed on the history ROW and
  // nowhere on the screen that row opens.
  add('Max HR', r.maxHr == null ? null : '${r.maxHr} bpm');
  // How far it fell in the minute after. Computed at derive time, stored on the
  // session, and until now read by nothing at all. The window is in the value
  // rather than the label because 'HR recovery 24 bpm' is not a claim anybody
  // can check — recovery over WHAT is the whole measurement.
  add('HR recovery', r.hrr60 == null ? null : '${r.hrr60} bpm in 60 s');
  add('Calories', r.calories == null ? null : '${grouped(r.calories!)} kcal');
  add('Strain', r.strain?.toStringAsFixed(1));
  // TS-09 — last, under the measurements, and named 'Your rating' rather than
  // 'RPE' so the row cannot read as something the band found out. It is not on
  // the share card: `shareStats` is its own list and a self-report is not one
  // of the things a session measured.
  add('Your rating', r.rpe == null ? null : '${r.rpe!.round()} of 10');
  return out;
}

/// The stat the hero is already showing large, or null when the hero is a
/// number this list does not carry anyway (a distance, a volume, a swim).
///
/// The poster subtracts its hero from its grid for exactly this reason; the
/// screen the poster is generated from printed '45:12' at 48 pt and then
/// 'TIME 45:12' as the next card's first row.
String? _heroStatName(ActivityResult r) => switch (r.arch) {
      Arch.route || Arch.journey => r.distanceKm == null ? 'Time' : null,
      // Without a volume the hero falls back to the set COUNT, not the clock.
      Arch.strength => r.strength.volumeKg == null ? 'Sets' : null,
      Arch.laps => r.swimMetres == null ? 'Time' : null,
      Arch.interval || Arch.flow || Arch.match || Arch.basic => 'Time',
    };

/// A finished session's supporting stats, one to a row.
///
/// The three-across strip this replaces set three bare numbers side by side
/// with a caption under each. The value column was a third of a card, so
/// '5:08 /mi' had to hide its unit inside the label, and the fourth stat was
/// dropped without saying so. One row per stat gives every one of them the
/// same ringed mark, the same caps name, and the same value/unit pair the
/// share card sets — [PosterStatRow], not a second row that agrees with it
/// until somebody edits one of them.
class SessionStats extends StatelessWidget {
  final ActivityResult r;
  const SessionStats(this.r, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    // Solved against the page, not raw pigment: the poster paints its rings on
    // one dark card it controls, and this one lands on both themes.
    final accent = p.on(r.activity.color);
    final rows = <Widget>[];
    for (final s in sessionStats(r, unitsOf(c))) {
      if (rows.isNotEmpty) rows.add(Divider(color: p.line, height: S.x5));
      final (value, unit) = splitStatUnit(s.$2);
      rows.add(PosterStatRow(
        icon: statIcon(s.$1),
        label: s.$1,
        value: value,
        unit: unit,
        accent: accent,
      ));
    }
    return Surface(child: Column(children: rows));
  }
}

// ── THE SCREEN ─────────────────────────────────────────────────────────────

class ActivitySummary extends StatefulWidget {
  final ActivityResult result;

  /// Body weight, for the calorie note. Null when the profile has none.
  final double? weightKg;

  /// Set only when persisting the session threw. Non-null means this summary
  /// is drawn from something that is NOT in the database, and calling it tries
  /// the write again.
  final Future<ActivityResult> Function()? onRetrySave;

  /// True only on the screen a session lands on the moment it ends. TS-09's
  /// prompt appears here and nowhere else: "how hard did that feel" asked
  /// three weeks later is a memory test, and re-asking on every open is the
  /// escalation the spec refuses.
  final bool justFinished;

  const ActivitySummary(this.result,
      {super.key,
      this.weightKg,
      this.onRetrySave,
      this.justFinished = false});

  @override
  State<ActivitySummary> createState() => _ActivitySummaryState();
}

class _ActivitySummaryState extends State<ActivitySummary> {
  int tab = 0;

  /// A yoga session, a tennis match and an untracked session do not break into
  /// pieces — not "have none today", never. So they do not get the tab. The
  /// card that used to sit inside it explaining its own absence was the tab
  /// justifying its existence to the person who opened it.
  List<String> get _tabs => switch (arch) {
        Arch.flow || Arch.match || Arch.basic => const ['Overview', 'Graphs'],
        _ => const ['Overview', 'Splits', 'Graphs'],
      };

  /// Whether the session is still only on screen. Starts true whenever a
  /// retry was handed down, because that is what being handed one means.
  late bool unsaved = widget.onRetrySave != null;
  bool _saving = false;

  /// The session as this screen currently knows it.
  ///
  /// [widget.result] is the source of truth; [_rated] is set only by TS-09, so
  /// the rating the user just typed reaches [sessionStats] without a reload.
  /// It is NOT seeded from `widget.result` in a field initialiser: Flutter
  /// reuses this State when the same route is rebuilt with a different
  /// session, and a `late` copy taken once would then describe the previous
  /// one for the rest of the screen's life.
  ActivityResult? _rated;

  ActivityResult get r => _rated ?? widget.result;

  @override
  void didUpdateWidget(covariant ActivitySummary old) {
    super.didUpdateWidget(old);
    if (!identical(old.result, widget.result)) {
      _rated = null;
      _rpeDismissed = false;
    }
  }
  Activity get a => r.activity;
  Arch get arch => r.arch;

  /// Both are heat/cold exposure sessions — see [_thermal].
  bool get thermal => _thermal.contains(a.name);

  /// The user's unit system, watched in [build] so a switch in Settings
  /// repaints this screen. Null only in a golden, where metric is what the
  /// store holds.
  UnitsController? _u;

  /// This session's distance in the user's unit, and that unit's name.
  (double, String)? get _distance {
    final km = r.distanceKm;
    if (km == null) return null;
    final u = _u;
    return u == null ? (km, 'km') : (u.distanceValue(km * 1000), u.distanceUnit);
  }

  String get _distanceUnit => _u?.distanceUnit ?? 'km';

  // ─────────────────── TS-09 · SESSION RPE ───────────────────
  //
  // Scores the sessions heart rate cannot see — lifting, climbing, anything
  // intermittent. Three rules, all of them refusals:
  //
  //   * NOTHING IS PRE-SELECTED. The set-level picker defaults to 7 and that
  //     default is a garbage-data mechanism already running. Here a tap IS the
  //     answer, so an untouched card leaves the column NULL.
  //   * SKIPPABLE FOREVER, and the app stops asking rather than escalating —
  //     [_kRpeSkips] counts the passes and the prompt retires at [_maxSkips].
  //   * IT IS A FEELING, not a measurement, and every surface says so.
  //
  // What is NOT built: no sRPE score fused into training load, no comparison
  // against TRIMP. The interesting thing about this number is where it
  // DISAGREES with the measured load, and that needs weeks of both.
  static const _kRpeSkips = 'workout.rpe_skips';
  static const _maxSkips = 3;

  /// Set when the user passes on this session, so the card goes away for this
  /// screen without waiting on the write.
  bool _rpeDismissed = false;

  bool get _askRpe =>
      widget.justFinished &&
      r.sessionId != null &&
      r.rpe == null &&
      !_rpeDismissed &&
      Prefs.getInt(_kRpeSkips, 0) < _maxSkips;

  Future<void> _saveRpe(int v) async {
    final id = r.sessionId;
    if (id == null) return;
    try {
      await LocalDb.setSessionRpe(id, v.toDouble());
    } catch (_) {
      return; // the row is unchanged, so the card stays and says nothing false
    }
    if (!mounted) return;
    // Rating one resets the skip count: the feature retires because it is
    // being ignored, not because it was once inconvenient.
    Prefs.setInt(_kRpeSkips, 0);
    setState(() => _rated = r.copyWith(rpe: v.toDouble()));
  }

  void _skipRpe() {
    Prefs.setInt(_kRpeSkips, Prefs.getInt(_kRpeSkips, 0) + 1);
    setState(() => _rpeDismissed = true);
  }

  /// Ten choices, two rows of five, none of them lit. A tap saves and the card
  /// is replaced by the rating in [SessionStats] — there is no confirm step,
  /// because a picker with a default and a Save button is how a 7 ends up in
  /// the database on behalf of somebody who never touched it.
  Widget _rpePrompt(P p) {
    final l = AppLocalizations.of(context);
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l?.activitySummaryRpeHeadline ?? 'HOW HARD DID THAT FEEL?',
            style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
        Text(
            l?.activitySummaryRpeBody ??
                'Your own rating of the effort. It is a feeling, not a '
                    'measurement — which is the point, because it can '
                    'disagree with the numbers above.',
            style: F.cap.copyWith(color: p.ink2, height: 1.4)),
        const SizedBox(height: S.x4),
        for (var row = 0; row < 2; row++) ...[
          if (row > 0) const SizedBox(height: S.x2),
          Row(children: [
            for (var i = 0; i < 5; i++) ...[
              if (i > 0) const SizedBox(width: S.x2),
              Expanded(
                child: Pressable(
                  semanticLabel: l?.activitySummaryRateEffort(
                          row * 5 + i + 1) ??
                      'Rate this effort ${row * 5 + i + 1} of 10',
                  onTap: () => _saveRpe(row * 5 + i + 1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: p.wash(a.color), borderRadius: R.rMd),
                    child: Text('${row * 5 + i + 1}',
                        style: F.n17.copyWith(color: p.on(a.color))),
                  ),
                ),
              ),
            ],
          ]),
        ],
        const SizedBox(height: S.x3),
        Row(children: [
          Text(l?.activitySummaryRpeVeryEasy ?? '1 · very easy',
              style: F.over.copyWith(color: p.ink3)),
          const Spacer(),
          Text(l?.activitySummaryRpeMaximal ?? '10 · maximal',
              style: F.over.copyWith(color: p.ink3)),
        ]),
        const SizedBox(height: S.x2),
        Align(
          alignment: Alignment.centerLeft,
          child: Pressable(
            onTap: _skipRpe,
            child: Text(l?.activitySummaryNotNow ?? 'Not now',
                style: F.body.copyWith(
                    color: p.ink2, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  /// Correct a session's activity type — the band's own guess, or a hand-typed
  /// one that was wrong. `LocalDb.setSessionType` is the narrow UPDATE this
  /// reuses; it used to have no caller at all (lost in the ui2 rewrite along
  /// with the screen that called it).
  ///
  /// Archetype-specific fields on [r] (sets, route, splits…) belong to the OLD
  /// type and cannot be salvaged for the new one, so this does not try to
  /// patch [r] in place — it hands back to whatever list pushed this screen,
  /// which re-reads on the revision bump below.
  Future<void> _changeType(BuildContext c) async {
    final id = r.sessionId;
    if (id == null) return;
    // Only true once a pick actually landed — pressing back out of the picker
    // must return to this screen, not fall through and pop it too.
    var picked = false;
    await Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => ActivityPicker(onPick: (pc, newActivity) async {
        // The stored key everywhere else uses — `startWorkout(type:
        // a.typeKey)` is the live path's own write. `a.name` here would still
        // resolve through `activityByName`'s normalized lookup, but it would
        // store a different string than every other producer of this column.
        try {
          await LocalDb.setSessionType(id, newActivity.typeKey);
        } catch (_) {
          // Same rule as `_saveRpe`: the row is unchanged, so leave the
          // picker open rather than close it over a write that never
          // happened — `onPick` is a `void Function`, so there is no caller
          // to hand this failure back to.
          return;
        }
        picked = true;
        if (!pc.mounted) return;
        bumpInsights(pc);
        Navigator.of(pc).pop();
      }),
    ));
    if (c.mounted && picked) Navigator.of(c).pop();
  }

  /// Guards against a double tap firing two competing native share sheets —
  /// `share_plus` completes the first pending share as `unavailable` the
  /// moment a second one starts. A plain field, not `setState`: nothing on
  /// screen needs to repaint over this, it only needs to stay clear through
  /// every exit (including a thrown error) — see the `finally` below.
  bool _exportingGpx = false;

  /// Scoped export: the GPS route this phone already recorded, as a GPX file
  /// handed to the OS share sheet — so it can be manually uploaded to Strava
  /// or anywhere else that reads GPX. There is no Strava account involved:
  /// no OAuth, no upload call, just a file.
  Future<void> _exportGpx(BuildContext c) async {
    final id = r.sessionId;
    if (id == null || _exportingGpx) return;
    _exportingGpx = true;
    final l = AppLocalizations.of(c);
    final origin = shareOrigin(c);
    final messenger = ScaffoldMessenger.of(c);
    try {
      final route = await c.read<AppState>().repo?.getWorkoutRoute(id);
      if (!c.mounted) return;
      if (route == null || route.points.length < 2) {
        messenger.showSnackBar(SnackBar(
            content: Text(l?.activitySummaryNoRouteBody ??
                'Location was off, or this activity was not recorded with '
                    'GPS.')));
        return;
      }
      final gpx = buildGpx(route, name: a.name);
      await Share.shareXFiles(
        [
          XFile.fromData(Uint8List.fromList(utf8.encode(gpx)),
              mimeType: 'application/gpx+xml', name: '${a.typeKey}.gpx'),
        ],
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!c.mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(
              l?.activityShareOpenFailed ?? 'Could not open the share sheet.')));
      debugPrint('gpx export failed: $e');
    } finally {
      _exportingGpx = false;
    }
  }

  Future<void> _retrySave() async {
    if (_saving) return;
    setState(() => _saving = true);
    var ok = false;
    try {
      await widget.onRetrySave!();
      ok = true;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      unsaved = !ok;
    });
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    _u = unitsOf(c);
    // Only a saved session has an id to correct — a draft on screen because
    // the write threw has nowhere to put it. Reserving the two-icon width
    // for a row that only ever draws one icon would shove the title left on
    // every unsaved-session summary for no reason.
    final canChangeType = r.sessionId != null;
    // GPX export only makes sense for a session with an actual recorded
    // route — offering it on a lift or a match would be a button that can
    // only ever fail. Gated on `geo` (raw lat/lng), not the normalised
    // `route` used to draw the map: `_normalise` returns empty for a
    // zero-span route (every fix at the same spot — a stationary GPS lock),
    // which would hide the export for a session `getWorkoutRoute` can still
    // export.
    final canExportGpx = r.sessionId != null &&
        (arch == Arch.route || arch == Arch.journey) &&
        r.geo.length >= 2;
    final l = AppLocalizations.of(c);
    final iconCount = 1 + (canChangeType ? 1 : 0) + (canExportGpx ? 1 : 0);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(
              a.name,
              sub: _shortDate(r.start).toUpperCase(),
              // Each icon is a Pressable with S.tap's own 44 pt minimum hit
              // box (grammar.dart's accessibility floor, not optional) —
              // S.tap * n alone is short of that plus the gaps between them,
              // which is exactly the RenderFlex overflow this avoids.
              trailingWidth: iconCount == 1
                  ? S.tap
                  : S.tap * iconCount + S.x3 * (iconCount - 1),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (canChangeType) ...[
                  Pressable(
                    semanticLabel:
                        l?.activitySummaryChangeType ?? 'Change activity type',
                    onTap: () => _changeType(c),
                    child: Icon(LucideIcons.pencil, size: 18, color: p.ink2),
                  ),
                  const SizedBox(width: S.x3),
                ],
                if (canExportGpx) ...[
                  Pressable(
                    semanticLabel:
                        l?.activitySummaryExportGpx ?? 'Export route as GPX',
                    onTap: () => _exportGpx(c),
                    child: Icon(LucideIcons.download, size: 18, color: p.ink2),
                  ),
                  const SizedBox(width: S.x3),
                ],
                Pressable(
                  semanticLabel: l?.activitySummaryShareThis(
                          a.name.toLowerCase()) ??
                      'Share this ${a.name.toLowerCase()}',
                  onTap: () => Navigator.of(c).push(MaterialPageRoute(
                      builder: (_) => ShareSheet(r))),
                  child: Icon(LucideIcons.share2, size: 19, color: p.ink2),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            // Display labels are localized; `_tabs` itself stays the fixed
            // English keys the switch below matches by NAME.
            child: SubTabs(
                [
                  for (final t in _tabs)
                    switch (t) {
                      'Overview' => l?.activitySummaryTabOverview ?? 'Overview',
                      'Splits' => l?.activitySummaryTabSplits ?? 'Splits',
                      _ => l?.activitySummaryTabGraphs ?? 'Graphs',
                    },
                ],
                tab,
                (i) => setState(() => tab = i),
                color: a.color),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x10),
              // By NAME: the tab list is shorter for the archetypes that have
              // no splits, so index 1 is not always the same tab.
              children: switch (_tabs[tab]) {
                'Overview' => _overview(c, p),
                'Splits' => _splits(c, p),
                _ => _graphs(c, p),
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ─────────────────── OVERVIEW ───────────────────
  List<Widget> _overview(BuildContext c, P p) {
    final hero = _hero();
    final l = AppLocalizations.of(c);
    return [
      if (unsaved) ...[
        StatusCard(
          l?.activitySummaryUnsavedTitle ?? 'This session is not saved yet',
          l?.activitySummaryUnsavedBody ?? 'Writing it to this phone failed.',
          fix: _saving
              ? (l?.activitySummarySaving ?? 'Saving')
              : (l?.activitySummaryTryAgain ?? 'Try again'),
          onFix: _saving ? null : _retrySave,
          icon: LucideIcons.triangleAlert,
        ),
        const SizedBox(height: S.x5),
      ],
      // ONE flexible child. A `Flexible` hero next to a `Spacer` split the row
      // by flex, so the headline got half the width whatever it said, and a
      // 1,500 m swim printed '1,…' at 2x text. The privacy pill keeps its
      // natural width; the hero takes the rest and, like the share card's,
      // scales down rather than truncating — a cut-off measurement is not a
      // measurement.
      Row(children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(hero.$1,
                      style: F.n48.copyWith(color: p.ink), maxLines: 1),
                  if (hero.$2.isNotEmpty) ...[
                    const SizedBox(width: S.x2),
                    Text(hero.$2, style: F.body.copyWith(color: p.ink3)),
                  ],
                ]),
          ),
        ),
        if (r.private) ...[
          const SizedBox(width: S.x3),
          Pill(l?.activitySummaryPrivate ?? 'Private', C.n500,
              icon: LucideIcons.lock),
        ],
      ]),
      const SizedBox(height: S.x1),
      Text(hero.$3, style: F.cap.copyWith(color: p.ink2)),
      const SizedBox(height: S.x5),
      ..._definingObject(c, p),
      const SizedBox(height: S.x5),
      SessionStats(r),
      // TS-09 — directly under the measurements, because that is what it is
      // being asked against, and directly where the answer lands: once rated,
      // this card is gone and 'Your rating' is the last row of the card above.
      if (_askRpe) ...[
        const SizedBox(height: S.x3),
        _rpePrompt(p),
      ],
      ..._body(c, p),
      // Zones belong to any session that banked a split — a lift and a yoga
      // class have heart-rate zones too.
      ..._zoneSection(p),
      const SizedBox(height: S.x5),
      _basisNote(p),
    ];
  }

  /// What the numbers on this screen were made of. The calorie sentence is
  /// always here; the step one joins it whenever a count is on the card,
  /// because a step row that does not name its sensor is weaker than the day
  /// screens beside it, which have named theirs all along.
  Widget _basisNote(P p) {
    final l = AppLocalizations.of(context);
    return Surface(
      elevation: 0,
      color: p.card2,
      child: Row(children: [
        Expanded(
          child: Text(
              [
                _calorieBasis(),
                if (r.stepsCounted != null)
                  l?.activitySummaryStepsBasis ??
                      "Steps came from the strap's own motion sensor, which "
                          'only counts them on foot.',
              ].join(' '),
              style: F.cap.copyWith(color: p.ink3, height: 1.5)),
        ),
      ]),
    );
  }

  /// What the calorie figure was actually made of — or why there isn't one.
  ///
  /// It claimed heart rate on every session, including the ones scored from
  /// MET and weight alone because no beat ever arrived — printed three cards
  /// under 'The band reported nothing while this was running'. Without a curve
  /// there is no heart rate in the number: `_kcal` falls through to
  /// `Activity.kcal`, which is MET × weight × minutes and nothing else.
  ///
  /// It also described a figure that was not on the screen. A session scored
  /// from the substrate only banks kcal when the profile carries a real HRmax
  /// AND a real resting HR (`manual_session.dart` refuses to persist one built
  /// on the 220/60 fallback), so a stored session very often has no calorie
  /// stat at all — and this card still explained how it had been estimated.
  /// When there is no number, say which anchor is missing and point at the
  /// effort measure that does not need one.
  String _calorieBasis() {
    final l = AppLocalizations.of(context);
    if (widget.weightKg == null) {
      return l?.activitySummaryCaloriesNeedWeight ??
          'Calories need your weight.';
    }
    final met = a.met?.toStringAsFixed(1);
    if (r.calories == null) {
      return r.strain == null
          ? l?.activitySummaryNoCalorieNoStrain ??
              'No calorie figure for this session. An energy estimate from '
                  'heart rate needs your maximum and resting heart rates, and '
                  'one of them is not set.'
          : l?.activitySummaryNoCalorieWithStrain ??
              'No calorie figure for this session — an energy estimate from '
                  'heart rate needs your maximum and resting heart rates, and '
                  'one of them is not set. Strain above is the effort that '
                  'was measured, on its own 0–21 scale.';
    }
    // No MET is the catch-all activity, whose figure is therefore entirely
    // the heart-rate estimate — saying "from MET" over it would name a basis
    // this session does not have.
    if (met == null) {
      return l?.activitySummaryCalorieNoMet ??
          'Estimated from your heart rate and your weight. No MET is in '
              'this figure: the session named no activity for one to apply '
              'to.';
    }
    return r.avgHr == null
        ? l?.activitySummaryCalorieNoHr(met) ??
            'Estimated from $met MET and your weight. No heart rate reached '
                'this session, so none of it is in the figure.'
        : l?.activitySummaryCalorieWithHr(met) ??
            'Estimated from $met MET, your weight and heart rate.';
  }

  /// (value, unit, caption). The hero is the archetype's own headline — and
  /// falls back to elapsed time, which is the one number every session has.
  (String, String, String) _hero() {
    final l = AppLocalizations.of(context);
    final fallback = (hms(r.duration), '', l?.activitySummaryElapsedTime ?? 'Elapsed time');
    return switch (arch) {
      Arch.route || Arch.journey => _distance == null
          ? fallback
          : (
              _distance!.$1.toStringAsFixed(2),
              _distance!.$2,
              arch == Arch.journey && r.gainM != null
                  ? (l?.activitySummaryClimbed(r.gainM!.round()) ??
                      '+${r.gainM!.round()} m climbed')
                  : a.name
            ),
      Arch.strength => r.strength.volumeKg == null
          ? (
              '${r.strength.setCount}',
              l?.activitySummarySetUnit(r.strength.setCount) ??
                  (r.strength.setCount == 1 ? 'set' : 'sets'),
              l?.activitySummaryNothingLoggedWithLoad ??
                  'Nothing was logged with a load'
            )
          : (
              grouped(r.strength.volumeKg!),
              'kg',
              r.strength.hasUnloadedSets
                  ? (l?.activitySummaryVolumeLoadedSets ??
                      'Volume of the loaded sets')
                  : (l?.activitySummaryTotalVolume ?? 'Total volume')
            ),
      Arch.laps => r.swimMetres == null
          ? fallback
          : (
              grouped(r.swimMetres!),
              'm',
              l?.activitySummaryLapsCaption(r.lapCount ?? 0) ??
                  '${r.lapCount} laps'
            ),
      Arch.flow ||
      Arch.match ||
      Arch.interval ||
      Arch.basic =>
        fallback,
    };
  }

  // ─────────── THE DEFINING VISUAL OBJECT ───────────
  List<Widget> _definingObject(BuildContext c, P p) {
    final l = AppLocalizations.of(c);
    switch (arch) {
      case Arch.route:
        if (r.route.length < 2) {
          return [
            // No `fix`: there is no "how route recording works" screen, and
            // StatusCard paints any fix string as a blue call to action —
            // a button that cannot be tapped is worse than no button.
            StatusCard(
              l?.activitySummaryNoRouteTitle ?? 'No route for this session',
              l?.activitySummaryNoRouteBody ??
                  'Location was off, or this activity was not recorded with '
                      'GPS.',
              icon: LucideIcons.map,
            ),
          ];
        }
        return [
          Surface(
            child: ChartFrame(
              title: l?.activitySummaryRouteTitle ?? 'ROUTE',
              unit: _distanceUnit,
              height: 200,
              legend: r.routePace == null
                  ? const []
                  // Fast is GREEN, matching `paceColor` on the share card.
                  // These were opposite: the same run read green at its
                  // slowest here and green at its fastest on the poster, so a
                  // card and the screen it came from disagreed about the run.
                  : [
                      (l?.activitySummarySlower ?? 'Slower', p.on(C.red)),
                      (l?.activitySummaryFaster ?? 'Faster', p.on(C.green)),
                    ],
              footnote: _distance == null
                  ? (l?.activitySummaryStartFinishPinned ??
                      'Start and finish are pinned.')
                  : (l?.activitySummaryRouteFootnote(
                          _distance!.$1.toStringAsFixed(2), _distance!.$2) ??
                      '${_distance!.$1.toStringAsFixed(2)} ${_distance!.$2}, '
                          'start and finish pinned.'),
              child: ClipRRect(
                borderRadius: R.rLg,
                child: Container(
                  color: p.card2,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: RouteMap(r.route,
                        pace: r.routePace,
                        slow: p.on(C.red),
                        fast: p.on(C.green),
                        pinStart: p.on(C.green),
                        pinEnd: p.on(C.red),
                        pinInk: p.card),
                  ),
                ),
              ),
            ),
          ),
        ];

      // A lift has no defining visual object. The muscle map that used to sit
      // here was not a measurement — it was a static exercise→group table
      // multiplied by the volume the user typed, drawn as a body with shaded
      // regions, which is the picture a scan produces. What the session
      // actually knows is on the screen already: the stats, the top set, and
      // every set as logged.
      //
      // Absence is still explained. A lift with no sets in it has nothing on
      // the screen at all, and a blank overview reads as a bug rather than as
      // an empty log.
      case Arch.strength:
        return r.strength.isEmpty
            ? [
                StatusCard(
                  l?.activitySummaryNoSetsTitle ?? 'No sets logged',
                  l?.activitySummaryNoSetsBody ??
                      'Nothing was entered for this session, so there is no '
                          'load and no volume to total.',
                  icon: LucideIcons.dumbbell,
                ),
              ]
            : const [];

      case Arch.interval:
        if (r.rounds.isEmpty) {
          return [
            StatusCard(
              l?.activitySummaryNoRoundsTitle ?? 'No rounds recorded',
              l?.activitySummaryNoRoundsBody ?? '0 rounds logged.',
              icon: LucideIcons.timer,
            ),
          ];
        }
        final peak = r.rounds
            .map((x) => x.workSec > x.restSec ? x.workSec : x.restSec)
            .reduce((x, y) => x > y ? x : y)
            .toDouble();
        return [
          Surface(
            child: ChartFrame(
              title: l?.activitySummaryIntervalLadderTitle ?? 'INTERVAL LADDER',
              unit: 'seconds',
              height: 110,
              legend: [
                (l?.activitySummaryWork ?? 'Work', p.on(C.red)),
                (l?.activitySummaryRest ?? 'Rest', p.on(C.teal)),
              ],
              xLabels: [
                l?.activitySummaryRoundLabel(1) ?? 'Round 1',
                l?.activitySummaryRoundLabel(r.rounds.length) ??
                    'Round ${r.rounds.length}',
              ],
              footnote: l?.activitySummaryLongestBlock(clock(peak.round())) ??
                  'Longest block ${clock(peak.round())}.',
              child: CustomPaint(
                size: Size.infinite,
                painter: IntervalLadder([
                  for (final x in r.rounds)
                    (work: x.workSec / peak, rest: x.restSec / peak),
                ], p.on(C.red), p.on(C.teal)),
              ),
            ),
          ),
        ];

      case Arch.flow:
        // MT-08 — a sauna and a cold plunge are not a yoga flow. They have no
        // poses and no paced breath; what they have is a heart rate the
        // sensor may or may not have been able to read.
        if (thermal) return _thermalObject(p);
        // No breath ring here. The live screen's ring is a PACER driven by a
        // controller the user breathes along with; on a finished session there
        // is no phase to draw, and a static ring at some pleasing fraction is
        // a measurement-shaped decoration.
        return [
          Container(
            height: 170,
            decoration: BoxDecoration(
                borderRadius: R.rLg,
                color: p.wash(C.teal, strength: 1.6),
                boxShadow: p.el(1)),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.personStanding, size: 44, color: p.on(C.teal)),
                  const SizedBox(height: S.x2),
                  Text(
                      r.poses.isEmpty
                          ? hms(r.duration)
                          : (l?.activitySummaryPosesCount(r.poses.length) ??
                              '${r.poses.length} poses'),
                      style: F.head.copyWith(color: p.ink)),
                  Text(
                      r.breathsPerMin == null
                          ? a.name
                          : '${r.breathsPerMin!.toStringAsFixed(1)} breaths/min',
                      style: F.over.copyWith(color: p.on(C.teal))),
                ]),
          ),
        ];

      case Arch.laps:
        if (r.lapSecs.isEmpty) {
          return [
            StatusCard(
              l?.activitySummaryNoLapsTitle ?? 'No laps counted',
              l?.activitySummaryNoLapsBody ?? '0 laps tapped.',
              icon: LucideIcons.waves,
            ),
          ];
        }
        final fastest = r.lapSecs.reduce((x, y) => x < y ? x : y);
        final slowest = r.lapSecs.reduce((x, y) => x > y ? x : y);
        return [
          Surface(
            child: ChartFrame(
              title: l?.activitySummaryLapsTitle ?? 'LAPS',
              unit: l?.activitySummarySecondsPerLap ?? 'seconds per lap',
              height: 150,
              xLabels: [
                l?.activitySummaryLapLabel(1) ?? 'Lap 1',
                l?.activitySummaryLapLabel(r.lapSecs.length) ??
                    'Lap ${r.lapSecs.length}',
              ],
              footnote: [
                if (r.poolLengthM != null)
                  l?.activitySummaryPoolLength(r.poolLengthM!) ??
                      '${r.poolLengthM} m pool',
                l?.activitySummaryFastest(clock(fastest)) ??
                    'fastest ${clock(fastest)}',
                l?.activitySummarySlowest(clock(slowest)) ??
                    'slowest ${clock(slowest)}',
              ].join(' · '),
              child: CustomPaint(
                  size: Size.infinite,
                  painter: LapBars(r.lapSpeeds, p.on(C.blue), p.track)),
            ),
          ),
        ];

      case Arch.journey:
        if (r.elevationM.length < 2) {
          return [
            StatusCard(
              l?.activitySummaryNoElevationTitle ?? 'No elevation profile',
              l?.activitySummaryNoElevationBody ??
                  'No route, or the route carried no altitude.',
              icon: LucideIcons.mountain,
            ),
          ];
        }
        final peak = r.elevationM.reduce((x, y) => x > y ? x : y);
        final axis = AxisSpec.of(r.elevationM);
        return [
          Surface(
            child: Column(children: [
              ChartFrame(
                title: l?.activitySummaryElevationTitle ?? 'ELEVATION',
                unit: 'm',
                height: 130,
                yAxis: axis,
                xLabels: [
                  l?.activitySummaryStart ?? 'Start',
                  l?.activitySummaryFinish ?? 'Finish',
                ],
                series: r.elevationM,
                child: CustomPaint(
                    size: Size.infinite,
                    painter: Elevation(r.elevationM, p.on(C.green),
                        markerInk: p.card, axis: axis)),
              ),
              const SizedBox(height: S.x4),
              InlineMetrics([
                if (r.gainM != null)
                  (l?.activitySummaryGain ?? 'Gain',
                      '+${r.gainM!.round()} m', C.green),
                if (r.lossM != null)
                  (l?.activitySummaryLoss ?? 'Loss',
                      '−${r.lossM!.round()} m', C.orange),
                (l?.activitySummaryPeak ?? 'Peak', '${grouped(peak)} m',
                    C.n500),
              ]),
            ]),
          ),
        ];

      // A match is heart rate and hard minutes. There is no court map: the
      // only positioning this app has is GPS at wrist accuracy, which indoors
      // is nothing at all — the old map drew a decorative scatter that looked
      // exactly like a measurement.
      case Arch.match || Arch.basic:
        if (r.hr.length < 2) {
          return [_noHrCard(c)];
        }
        return [Surface(child: _hrFrame(p))];
    }
  }

  // ─────────────────── MT-08 · HEAT AND COLD ───────────────────
  //
  // THE CARD IS BUILT AROUND ITS OWN NO-SIGNAL STATE, and on a cold plunge
  // that state is the common one. Cold water triggers peripheral
  // vasoconstriction — the vessels in the wrist close — and a reflectance PPG
  // sensor reads a pulse through exactly those vessels. So "the band could not
  // find your pulse" is the physiologically expected reading of a plunge, not
  // a fault, not a strap problem, and not something to hide behind an average
  // computed from four surviving seconds.
  //
  // What is deliberately NOT here, and must not be added: thermal load, a heat
  // or cold adaptation score, core temperature, brown fat, and above all any
  // duration target or "go longer next time". Cold-water immersion carries
  // real cardiac and drowning risk and this app is not going to nudge anybody
  // deeper into it.

  /// Why a heat/cold session has no pulse in it — or null when the session is
  /// not one, in which case a missing trace really is a link problem and the
  /// sources list really is the fix.
  ///
  /// The one string, so the overview card, the Graphs tab and the shared
  /// [_noHrCard] cannot end up telling three different stories about the same
  /// silent sensor. Offering "Check band connection" for a plunge is a fix for
  /// a problem the user does not have.
  String? get _thermalWhy {
    if (!thermal) return null;
    final l = AppLocalizations.of(context);
    return a.name == 'Cold plunge'
        ? l?.activitySummaryColdPlungeWhy ??
            'Cold closes the blood vessels the sensor reads through. Finding '
                'nothing here is expected, not a fault.'
        : l?.activitySummaryHeatWhy ??
            'Heat, sweat and a strap that loosens as you warm up all stop '
                'the sensor seeing a pulse. Finding nothing here is '
                'ordinary, not a fault.';
  }

  IconData get _thermalIcon =>
      a.name == 'Cold plunge' ? LucideIcons.snowflake : LucideIcons.thermometer;

  List<Widget> _thermalObject(P p) {
    final l = AppLocalizations.of(context);
    final (have, total) = r.hrMinutes;
    // Under two readings there is no line to draw — one point is not a trace.
    // The two headlines are not the same statement: nothing arrived, or one
    // minute did and a single point is not a curve.
    if (have < 2) {
      return [
        StatusCard(
          have == 0
              ? (l?.activitySummaryNoPulseTitle(a.name.toLowerCase()) ??
                  'No pulse reading for this ${a.name.toLowerCase()}')
              : (l?.activitySummaryOneMinutePulse ??
                  'One minute of pulse, and no more'),
          _thermalWhy!,
          icon: _thermalIcon,
        ),
      ];
    }
    return [
      Surface(
        child: _hrFrame(
          p,
          extra: have < total
              ? (l?.activitySummaryPulseGapNote(have, total) ??
                  'The band found a pulse in $have of $total minutes. The '
                      'gaps are expected, so what is drawn is the part it '
                      'could see.')
              : null,
        ),
      ),
    ];
  }

  /// Why there is no trace — and the two reasons are not the same reason.
  ///
  /// The curve is per-MINUTE, so a session stopped after forty-five seconds
  /// holds exactly one point with a band that streamed perfectly. Both cases
  /// used to get 'The band reported nothing while this was running' and a
  /// Check-band button, which is a false reason and a fix for a problem the
  /// user does not have.
  Widget _noHrCard(BuildContext c) {
    final l = AppLocalizations.of(c);
    return r.hr.any((v) => v != null)
        ? StatusCard(
            l?.activitySummaryTooShortTitle ?? 'Too short to chart',
            l?.activitySummaryTooShortBody ??
                'One minute of heart rate is a point, not a line.',
            icon: LucideIcons.heartPulse,
          )
        // MT-08 — a third reason, and it is not a fault. On a heat or cold
        // session the sensor is working and the blood is not where it can
        // see it, so there is no connection to check and no button that
        // helps.
        : thermal
            ? StatusCard(
                l?.activitySummaryNoPulseTitle(a.name.toLowerCase()) ??
                    'No pulse reading for this ${a.name.toLowerCase()}',
                _thermalWhy!,
                icon: _thermalIcon,
              )
            : StatusCard(
                l?.activitySummaryNoHrTitle ?? 'No heart rate for this session',
                l?.activitySummaryNoHrBody ??
                    'The band reported nothing while this was running.',
                fix: l?.activitySummaryCheckBandConnection ??
                    'Check band connection',
                // The band, its battery and its link all live behind the
                // profile's sources list. The CTA used to be paint.
                onFix: () => openProfile(c),
                icon: LucideIcons.heartPulse,
              );
  }

  /// The heart-rate trace, framed — the one chart both `basic` and `match`
  /// are built on, so they cannot end up with two different axes for one
  /// measurement.
  /// What the trace does NOT cover.
  ///
  /// A session older than `rawRetentionDays` is drawn from the trace frozen at
  /// score time, and a band that dropped the link mid-session froze a trace
  /// with holes in it. Without this the chart draws a confident thin line
  /// across a sync gap and nothing on the screen says the minutes are missing.
  // ponytail: one threshold, no band. 90% is "a couple of minutes lost on an
  // hour"; below that the gap is worth a sentence.
  String? get _traceNote {
    final pct = r.traceCoveragePct;
    if (pct == null || pct >= 90) return null;
    final l = AppLocalizations.of(context);
    return l?.activitySummaryPartialTrace(pct) ??
        'Partial trace — the band handed over $pct% of these minutes.';
  }

  Widget _hrFrame(P p, {double height = 130, String? extra}) {
    final l = AppLocalizations.of(context);
    final axis = AxisSpec.of(r.hr.whereType<double>());
    final hard = r.hardMinutes;
    final note = [
      if (hard != null)
        l?.activitySummaryHardMinutesNote(hard.round()) ??
            '${hard.round()} min above 80% of your maximum.',
      ?_traceNote,
      ?extra,
    ];
    return ChartFrame(
      title: l?.activitySummaryHeartRateTitle ?? 'HEART RATE',
      unit: 'bpm',
      height: height,
      yAxis: axis,
      xLabels: [l?.activitySummaryStart ?? 'Start', hms(r.duration)],
      footnote: note.isEmpty ? null : note.join(' '),
      series: r.hr,
      child: CustomPaint(
          size: Size.infinite,
          painter: LineChart(r.hr, p.on(C.red),
              axis: axis, t: animate(context, 1))),
    );
  }

  /// The zone split, with the minutes in the key rather than in a second row
  /// underneath it that has to be kept in step by hand.
  Widget _zoneFrame(P p) => ChartFrame(
        title: AppLocalizations.of(context)?.activitySummaryTimeInZonesTitle ??
            'TIME IN ZONES',
        unit: 'minutes',
        height: 10,
        legend: [
          for (var i = 0; i < 5; i++)
            ('Z${i + 1} · ${r.zoneMinutes[i].round()}m', ZoneBar.cols(p)[i]),
        ],
        footnote: zonesWhy(r.zoneSource, r.zoneMaxHr, AppLocalizations.of(context)),
        child: CustomPaint(
            size: Size.infinite, painter: ZoneBar(_zoneFractions(), p)),
      );

  // ─────────── ARCHETYPE BODY ───────────
  List<Widget> _body(BuildContext c, P p) {
    final l = AppLocalizations.of(c);
    switch (arch) {
      case Arch.strength:
        final top = r.strength.topSet;
        final rm = oneRepMax(top);
        return [
          if (top != null)
            Section(
              l?.activitySummaryTopSet ?? 'Top set',
              Surface(
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: p.wash(C.yellow), borderRadius: R.rMd),
                    child: Icon(LucideIcons.trophy,
                        size: 19, color: p.on(C.yellow)),
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              exerciseByKey(top.exerciseKey)?.label ??
                                  top.exerciseKey,
                              style: F.body.copyWith(
                                  color: p.ink, fontWeight: FontWeight.w600)),
                          Row(children: [
                            Flexible(
                                child: Text(
                                    l?.activitySummaryOneRepMax(
                                            rm!.round()) ??
                                        '1RM estimate ${rm!.round()} kg',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: F.over.copyWith(color: p.ink3))),
                          ]),
                        ]),
                  ),
                  const SizedBox(width: S.x2),
                  // The row rule: the name gives way, the measurement keeps
                  // its natural width and sits flush at the card edge.
                  Text('${_kg(top.loadKg!)} × ${top.reps}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: F.n17.copyWith(color: p.ink)),
                ]),
              ),
            ),
          if (r.strength.hasUnloadedSets)
            Padding(
              padding: const EdgeInsets.only(top: S.x4),
              child: StatusCard(
                l?.activitySummarySomeSetsNoLoadTitle ??
                    'Some sets had no load',
                l?.activitySummarySomeSetsNoLoadBody ??
                    'Counted in sets and reps, but left out of volume.',
                icon: LucideIcons.info,
              ),
            ),
        ];

      // A pacer is not a measurement and a mood picker with nowhere to write
      // is not a question — `sessions` has no mood column and `journal_metric`
      // is per-day, not per-session. Both were removed rather than explained.
      case Arch.flow:
        return const [];

      case Arch.match:
        return [
          if (r.gameScore.isNotEmpty)
            Section(
              l?.activitySummaryScore ?? 'Score',
              Surface(
                pad: const EdgeInsets.symmetric(horizontal: S.x4),
                child: Column(children: [
                  for (var i = 0; i < r.gameScore.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: S.x3),
                      child: Row(children: [
                        Expanded(
                            child: Text(
                                l?.activitySummaryGameSetLabel(i + 1) ??
                                    'Set ${i + 1}',
                                style: F.body.copyWith(color: p.ink3))),
                        Text('${r.gameScore[i].$1} — ${r.gameScore[i].$2}',
                            style: F.n17.copyWith(
                                color: r.gameScore[i].$1 > r.gameScore[i].$2
                                    ? p.on(a.color)
                                    : p.ink3)),
                      ]),
                    ),
                    if (i < r.gameScore.length - 1)
                      Divider(color: p.line, height: 1),
                  ],
                ]),
              ),
            ),
        ];

      case Arch.route ||
            Arch.journey ||
            Arch.laps ||
            Arch.interval ||
            Arch.basic:
        return const [];
    }
  }

  List<Widget> _zoneSection(P p) => r.zoneMinutes.length != 5
      ? const []
      : [
          Section(
              AppLocalizations.of(context)?.activitySummaryHeartRateZones ??
                  'Heart-rate zones',
              Surface(child: _zoneFrame(p))),
        ];

  List<double> _zoneFractions() {
    final total = r.zoneMinutes.fold<double>(0, (x, y) => x + y);
    if (total <= 0) return const [0, 0, 0, 0, 0];
    return [for (final z in r.zoneMinutes) z / total];
  }

  String _kg(double v) =>
      v == v.roundToDouble() ? '${v.round()} kg' : '${v.toStringAsFixed(1)} kg';

  // ─────────────────── SPLITS ───────────────────
  // "Splits" is whatever this archetype breaks into: kilometres for a run,
  // sets for a lift, rounds for HIIT, laps for a swim.
  List<Widget> _splits(BuildContext c, P p) {
    final l = AppLocalizations.of(c);
    switch (arch) {
      case Arch.route || Arch.journey:
        if (r.splits.isEmpty) {
          return [
            StatusCard(
              l?.activitySummaryNoSplitsTitle ?? 'No splits for this session',
              l?.activitySummaryNoSplitsBody ??
                  'Splits need a recorded distance.',
              icon: LucideIcons.list,
            ),
          ];
        }
        // PACE, not duration. The route tracker emits a trailing PARTIAL split
        // for whatever is left over — 0.4 km in 144 s — and this table printed
        // the 144 as if it were a kilometre's pace, so the last row of every
        // run read 2:24 and became the fastest-split reference every real
        // kilometre was drawn against. `KmSplit.km` was on the record the
        // whole time and read by nothing.
        final paces = <double?>[
          for (final s in r.splits) s.km <= 0 ? null : s.sec / s.km,
        ];
        final measured = [for (final v in paces) ?v];
        final fastest = measured.isEmpty
            ? null
            : measured.reduce((x, y) => x < y ? x : y);
        // SPLITS STAY PER-KILOMETRE in either unit system, and the header says
        // so. The route tracker cuts them at each kilometre (`route.splitsKm`);
        // showing them as miles would mean re-cutting the route, which is a
        // compute change, not a formatting one. Relabelling them 'MI' without
        // re-cutting would simply be a wrong number.
        return [
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
            child: Column(children: [
              Row(children: [
                SizedBox(
                    width: 26,
                    child: Text(l?.activitySummaryKm ?? 'KM',
                        style: F.over.copyWith(color: p.ink3))),
                SizedBox(
                    width: 46,
                    child: Text(l?.activitySummaryPace ?? 'PACE',
                        style: F.over.copyWith(color: p.ink3))),
                const Expanded(child: SizedBox()),
                SizedBox(
                    width: 34,
                    child: Text(l?.activitySummaryHr ?? 'HR',
                        textAlign: TextAlign.right,
                        style: F.over.copyWith(color: p.ink3))),
              ]),
              const SizedBox(height: S.x2),
              for (var i = 0; i < r.splits.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: S.x1),
                  child: Row(children: [
                    SizedBox(
                        width: 26,
                        // A partial split is not kilometre N — it is the
                        // 0.4 km that was left, and it says so.
                        child: Text(
                            r.splits[i].km >= .95
                                ? '${i + 1}'
                                : r.splits[i].km.toStringAsFixed(1),
                            style: F.cap.copyWith(color: p.ink3))),
                    SizedBox(
                        width: 46,
                        child: Text(
                            paces[i] == null
                                ? ''
                                : UnitsController.formatPace(paces[i]!) ?? '',
                            style: F.cap.copyWith(
                                color: p.ink, fontWeight: FontWeight.w600))),
                    Expanded(
                        child: fastest == null || paces[i] == null
                            ? const SizedBox()
                            : PaceBar(fastest / paces[i]!, C.green)),
                    SizedBox(
                        width: 34,
                        child: Text(r.splits[i].avgHr?.toString() ?? '',
                            textAlign: TextAlign.right,
                            style: F.cap.copyWith(color: p.ink2))),
                  ]),
                ),
            ]),
          ),
        ];

      case Arch.strength:
        if (r.strength.isEmpty) {
          return [
            StatusCard(
              l?.activitySummaryNoSetsTitle ?? 'No sets logged',
              l?.activitySummarySetsLoggedZero ?? '0 sets logged.',
              icon: LucideIcons.dumbbell,
            ),
          ];
        }
        return [
          for (final key in r.strength.exercises) ...[
            Section(
              exerciseByKey(key)?.label ?? key,
              Surface(
                pad: const EdgeInsets.symmetric(horizontal: S.x4),
                child: Column(children: [
                  for (var i = 0;
                      i < r.strength.forExercise(key).length;
                      i++) ...[
                    _setRow(p, i + 1, r.strength.forExercise(key)[i]),
                    if (i < r.strength.forExercise(key).length - 1)
                      Divider(color: p.line, height: 1),
                  ],
                ]),
              ),
            ),
          ],
        ];

      case Arch.interval:
        if (r.rounds.isEmpty) {
          return [
            StatusCard(l?.activitySummaryNoRoundsTitle ?? 'No rounds recorded',
                l?.activitySummaryNoRoundsBody ?? '0 rounds logged.',
                icon: LucideIcons.timer),
          ];
        }
        // The heart-rate column exists only when the rounds carry one. A
        // header over four blank cells reads as "your heart stopped".
        final anyHr = r.rounds.any((x) => x.avgHr != null);
        return [
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
            child: Column(children: [
              Row(children: [
                SizedBox(
                    width: 34,
                    child: Text(l?.activitySummaryRoundHeader ?? 'R',
                        style: F.over.copyWith(color: p.ink3))),
                Expanded(
                    child: Text(l?.activitySummaryWorkHeader ?? 'WORK',
                        style: F.over.copyWith(color: p.ink3))),
                Expanded(
                    child: Text(l?.activitySummaryRestHeader ?? 'REST',
                        style: F.over.copyWith(color: p.ink3))),
                if (anyHr)
                  SizedBox(
                      width: 52,
                      child: Text(l?.activitySummaryAvgBpm ?? 'AVG BPM',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: F.over.copyWith(color: p.ink3))),
              ]),
              const SizedBox(height: S.x2),
              for (var i = 0; i < r.rounds.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: S.x1),
                  child: Row(children: [
                    SizedBox(
                      width: 34,
                      child: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: p.wash(C.red), borderRadius: R.rSm),
                        child: Text('${i + 1}',
                            style: F.over.copyWith(color: p.on(C.red))),
                      ),
                    ),
                    Expanded(
                        child: Text(clock(r.rounds[i].workSec),
                            style: F.cap.copyWith(color: p.ink))),
                    Expanded(
                        child: Text(clock(r.rounds[i].restSec),
                            style: F.cap.copyWith(color: p.ink3))),
                    if (anyHr)
                      SizedBox(
                        width: 52,
                        child: Text(r.rounds[i].avgHr?.toString() ?? '',
                            textAlign: TextAlign.right,
                            style: F.cap.copyWith(
                                color: p.ink, fontWeight: FontWeight.w600)),
                      ),
                  ]),
                ),
            ]),
          ),
        ];

      case Arch.laps:
        if (r.lapSecs.isEmpty) {
          return [
            StatusCard(l?.activitySummaryNoLapsTitle ?? 'No laps counted',
                l?.activitySummaryNoLapsBody ?? '0 laps tapped.',
                icon: LucideIcons.waves),
          ];
        }
        final fastest = r.lapSecs.reduce((x, y) => x < y ? x : y);
        return [
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
            child: Column(children: [
              Row(children: [
                SizedBox(
                    width: 34,
                    child: Text(l?.activitySummaryLapHeader ?? 'LAP',
                        style: F.over.copyWith(color: p.ink3))),
                SizedBox(
                    width: 52,
                    child: Text(l?.activitySummaryTimeHeader ?? 'TIME',
                        style: F.over.copyWith(color: p.ink3))),
                Expanded(
                    child: Text(
                        l?.activitySummarySpeedVsFastest ?? 'SPEED vs FASTEST',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: F.over.copyWith(color: p.ink3))),
              ]),
              const SizedBox(height: S.x2),
              for (var i = 0; i < r.lapSecs.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: S.x1),
                  child: Row(children: [
                    SizedBox(
                        width: 34,
                        child: Text('${i + 1}',
                            style: F.cap.copyWith(color: p.ink3))),
                    SizedBox(
                        width: 52,
                        child: Text(clock(r.lapSecs[i]),
                            style: F.cap.copyWith(
                                color: p.ink, fontWeight: FontWeight.w600))),
                    Expanded(
                        child: PaceBar(
                            r.lapSecs[i] <= 0 ? 1 : fastest / r.lapSecs[i],
                            C.blue)),
                  ]),
                ),
            ]),
          ),
        ];

      // Unreachable — `_tabs` gives these archetypes no Splits tab to open.
      case Arch.flow || Arch.match || Arch.basic:
        return const [];
    }
  }

  Widget _setRow(P p, int n, LoggedSet s) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: p.wash(C.purple), borderRadius: R.rSm),
          child: Text('$n', style: F.over.copyWith(color: p.on(C.purple))),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Text(
              s.loadKg == null
                  ? (l?.activitySummaryBodyweightReps(s.reps) ??
                      '${s.reps} reps · bodyweight')
                  : '${_kg(s.loadKg!)} × ${s.reps}',
              style: F.body.copyWith(color: p.ink)),
        ),
        if (s.rpe != null)
          Text(l?.activitySummaryRpeValue(s.rpe!) ?? 'RPE ${s.rpe}',
              style: F.cap.copyWith(color: p.ink3)),
        if (s.volume != null) ...[
          const SizedBox(width: S.x3),
          Text('${grouped(s.volume!)} kg',
              style: F.cap
                  .copyWith(color: p.ink2, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }

  // ─────────────────── GRAPHS ───────────────────
  List<Widget> _graphs(BuildContext c, P p) {
    final l = AppLocalizations.of(c);
    final series = <(String, String, Color, List<double?>)>[
      if (r.hr.length > 1) ('Heart rate', 'bpm', C.red, r.hr),
      if (r.elevationM.length > 1)
        ('Elevation', 'm', C.teal, r.elevationM),
    ];
    if (series.isEmpty) {
      // Same distinction the overview draws: a session with one minute in it
      // is too short to plot, which is not the band's fault and not fixable
      // from the sources list.
      return [
        if (r.hr.any((v) => v != null))
          StatusCard(
            l?.activitySummaryTooShortTitle ?? 'Too short to chart',
            l?.activitySummaryTooShortBody ??
                'One minute of heart rate is a point, not a line.',
            icon: LucideIcons.chartLine,
          )
        // MT-08 — same guard as `_noHrCard`: a plunge with no trace has a
        // reason, and "check band connection" is not it.
        else if (thermal)
          StatusCard(
            l?.activitySummaryNothingToPlot(a.name.toLowerCase()) ??
                'Nothing to plot for this ${a.name.toLowerCase()}',
            _thermalWhy!,
            icon: _thermalIcon,
          )
        else
          StatusCard(
            l?.activitySummaryNoSeriesTitle ?? 'No series to plot',
            l?.activitySummaryNoSeriesBody ??
                'This session recorded no per-minute streams.',
            fix: l?.activitySummaryCheckBandConnection ??
                'Check band connection',
            onFix: () => openProfile(c),
            icon: LucideIcons.chartLine,
          ),
      ];
    }
    return [
      for (final g in series)
        Padding(
          padding: const EdgeInsets.only(bottom: S.x3),
          child: Surface(
            child: Builder(builder: (_) {
              final axis = AxisSpec.of(g.$4.whereType<double>());
              return ChartFrame(
                title: g.$1.toUpperCase(),
                unit: g.$2,
                height: 110,
                yAxis: axis,
                xLabels: ['Start', hms(r.duration)],
                // The gap belongs to the heart-rate trace, not to the altitude
                // the phone recorded alongside it.
                footnote: g.$1 == 'Heart rate' ? _traceNote : null,
                series: g.$4,
                child: CustomPaint(
                    size: Size.infinite,
                    painter: LineChart(g.$4, p.on(g.$3),
                        axis: axis, t: animate(context, 1))),
              );
            }),
          ),
        ),
    ];
  }
}

