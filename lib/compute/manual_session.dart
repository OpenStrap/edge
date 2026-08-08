// manual_session.dart — pure policy for USER-ENTERED workout windows.
//
// Two flows let the athlete own the times on a COMPLETED session:
//   * "Log a past workout" — an effort the band never surfaced at all.
//   * "Edit times"         — correcting a window that is real but wrong.
//
// WHY THIS EXISTS. The auto-detector (`analytics/.../workout/auto_detect.dart`)
// deliberately reports the HARD-EFFORT CORE, not wall-clock: a minute only
// counts at >= RHR + 0.45*(HRmax-RHR) (`hrrFloorFraction`), a dip longer than
// 90 s breaks the span (`maxDipS`), and the survivor must hold >= 12 min
// (`minSustainedMin`). That tuning is correct for a "did you work out?" prompt
// — it was calibrated against a sedentary week where a looser gate fired 30
// false windows — but it means warm-up, cool-down and inter-set rest fall out.
// An hour of mixed-intensity training routinely lands as ~25 detected minutes.
// Nothing was broken; the athlete just needs a way to say what actually
// happened. Until now the only session writer was `startWorkout`, which stamps
// `DateTime.now()`, so there was no such way.
//
// EVERYTHING HERE IS PURE — no I/O, no DB, no clock. The caller passes
// `nowSec`, the existing session spans and the 1 Hz HR samples it read, so all
// of it is unit-testable (test/manual_session_test.dart).
//
// HONESTY CONTRACT. `strain` and `calories` are computed ONLY from real 1 Hz
// HR inside the window, through the same published methods the day-level
// derivation uses (Banister TRIMP -> log-squash strain; Keytel 2005 calories).
// No HR in the window — because it predates the ~3-day `decoded_onehz`
// retention, or the band was off — means those columns stay NULL and the UI
// renders "—". A duration alone NEVER becomes a strain or a calorie figure.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'profile.dart';

/// Shortest window we accept. Below a minute the 1 Hz substrate cannot say
/// anything useful and the entry is almost certainly a mis-tap.
const int kMinManualWorkoutSec = 60;

/// Longest window we accept. This is TYPO PROTECTION (a wrong date turning a
/// 45-minute run into a 3-day session), not a physiological claim — 24 h still
/// admits a 100-mile ultra or an Ironman.
const int kMaxManualWorkoutSec = 24 * 60 * 60;

/// Why a proposed window was rejected. Ordered by check sequence.
enum ManualWindowError {
  /// end <= start — a zero or negative-length session.
  endNotAfterStart,

  /// Shorter than [kMinManualWorkoutSec].
  tooShort,

  /// Longer than [kMaxManualWorkoutSec].
  tooLong,

  /// The window ends after "now". We never accept a session from the future.
  inFuture,

  /// The window intersects one already in the log. Overlap would double-count
  /// the same minutes and confuse `savedSpans` auto-detect exclusion.
  overlapsExisting,
}

extension ManualWindowErrorMessage on ManualWindowError {
  /// User-facing copy. Plain, specific, no jargon.
  String get message => switch (this) {
        ManualWindowError.endNotAfterStart =>
          'The end time has to be after the start time.',
        ManualWindowError.tooShort => 'A workout has to be at least a minute.',
        ManualWindowError.tooLong => "That's longer than 24 hours — check the date.",
        ManualWindowError.inFuture => "That window hasn't happened yet.",
        ManualWindowError.overlapsExisting =>
          'That overlaps a workout already in your log.',
      };
}

/// Thrown by the repo when a proposed window fails [validateManualWindow].
///
/// The form validates as you type, but the form is not the only caller and its
/// overlap snapshot can be stale by the time you hit save — so the write path
/// checks again and refuses rather than trusting the UI.
class ManualWindowException implements Exception {
  final ManualWindowError error;
  const ManualWindowException(this.error);
  @override
  String toString() => 'ManualWindowException: ${error.message}';
}

/// A `[startSec, endSec]` span of a session already saved — used to reject an
/// overlapping entry. `id` lets an EDIT skip its own row.
class SessionSpan {
  final String id;
  final int startSec;
  final int endSec;
  const SessionSpan(this.id, this.startSec, this.endSec);
}

/// Validate a user-proposed window. Returns null when it is acceptable.
///
/// [editingId] is the row being retimed, if any — its own span is excluded
/// from the overlap check so a session never collides with itself.
///
/// A saved row with a null/absent `end_ts` (a stranded `status='live'` row)
/// cannot be overlap-checked and is skipped rather than guessed at.
ManualWindowError? validateManualWindow({
  required int startSec,
  required int endSec,
  required int nowSec,
  List<SessionSpan> existing = const [],
  String? editingId,
}) {
  if (endSec <= startSec) return ManualWindowError.endNotAfterStart;
  final dur = endSec - startSec;
  if (dur < kMinManualWorkoutSec) return ManualWindowError.tooShort;
  if (dur > kMaxManualWorkoutSec) return ManualWindowError.tooLong;
  if (endSec > nowSec) return ManualWindowError.inFuture;
  for (final s in existing) {
    if (s.id == editingId) continue;
    if (s.endSec <= s.startSec) continue; // stranded/live row — nothing to test
    // Half-open intersection: touching end-to-start is fine (back-to-back
    // sessions are legitimate), genuine overlap is not.
    if (startSec < s.endSec && s.startSec < endSec) {
      return ManualWindowError.overlapsExisting;
    }
  }
  return null;
}

/// Everything we could derive for a manual window from the 1 Hz substrate.
/// Every field is nullable/empty when its input was absent — see the honesty
/// contract in the file header.
class ManualSessionStats {
  /// Mean HR over the window, or null with no worn HR.
  final int? avgHr;

  /// Peak HR over the window, or null with no worn HR.
  final int? maxHr;

  /// Headline 0–21 strain (Banister TRIMP -> log squash). Null unless HR,
  /// resting HR, HRmax and sex are ALL present — every one is a term in the
  /// formula, so a missing one cannot be defaulted.
  final double? strain;

  /// Keytel 2005 active kcal. Null unless HR, age, weight, sex and HRmax are
  /// all present.
  final double? calories;

  /// Minutes in Z1..Z5 (5 elements), or empty with no HR.
  final List<double> zoneMinutes;

  /// How many 1 Hz HR samples backed the numbers above. 0 means the window has
  /// no substrate — the caller should tell the user the entry was saved but
  /// cannot be scored.
  final int hrSampleCount;

  const ManualSessionStats({
    this.avgHr,
    this.maxHr,
    this.strain,
    this.calories,
    this.zoneMinutes = const [],
    this.hrSampleCount = 0,
  });

  /// True when the window had no 1 Hz HR at all — pruned, or band not worn.
  bool get isUnscored => hrSampleCount == 0;
}

/// Mean HR per whole minute across [hrTs]/[hrBpm]. Banister weights each entry
/// as one minute, so feeding it raw 1 Hz samples would inflate TRIMP ~60x.
/// Samples are assumed ascending by ts (the DB returns them ordered); a minute
/// with no sample simply produces no entry rather than a zero.
List<double> hrPerMinute(List<int> hrTs, List<int> hrBpm) {
  if (hrTs.length != hrBpm.length || hrTs.isEmpty) return const [];
  final out = <double>[];
  var bucket = hrTs.first ~/ 60;
  var sum = 0.0;
  var n = 0;
  for (var i = 0; i < hrTs.length; i++) {
    final b = hrTs[i] ~/ 60;
    if (b != bucket) {
      if (n > 0) out.add(sum / n);
      bucket = b;
      sum = 0;
      n = 0;
    }
    if (hrBpm[i] > 0) {
      sum += hrBpm[i];
      n++;
    }
  }
  if (n > 0) out.add(sum / n);
  return out;
}

/// Minutes spent in each of Z1..Z5 (50/60/70/80/90 % of [zoneMaxHr]).
///
/// [zoneMaxHr] is the caller's DISPLAY HRmax convention. It is deliberately a
/// parameter, not derived here: the workout screens band zones on 220-age
/// (`LocalRepositoryImpl._profileMaxHr`) while the analytics anchors below use
/// Tanaka. Persisting `zone_min` on a different HRmax from the `zone_bands`
/// the same screen recomputes on read would put two disagreeing zone splits on
/// one card. (That the app carries two HRmax conventions at all is
/// pre-existing and worth converging separately — this just refuses to widen
/// the split.)
List<double> zoneMinutesFor(List<int> hrBpm, double zoneMaxHr) {
  if (hrBpm.isEmpty || zoneMaxHr <= 0) return const [];
  const loPct = [0.5, 0.6, 0.7, 0.8, 0.9];
  final secs = List<int>.filled(5, 0);
  for (final v in hrBpm) {
    if (v <= 0) continue;
    final pct = v / zoneMaxHr;
    for (var z = 4; z >= 0; z--) {
      if (pct >= loPct[z]) {
        secs[z]++;
        break;
      }
    }
  }
  return [
    for (var z = 0; z < 5; z++)
      double.parse((secs[z] / 60.0).toStringAsFixed(2)),
  ];
}

/// Headline 0–21 strain from per-minute mean HR, or null when an anchor the
/// Banister formula actually needs is missing.
///
/// THE ONE STRAIN METHOD. Everything that puts a number on the 0–21 dial goes
/// through here: the day-level pipeline, a manually logged session, a retimed
/// one, an auto-detected one, and the live gauge. They used to disagree —
/// the live session accrued `strain += %HRR * 0.01` per second, which is
/// uncited, uncapped, and measured 25.33 where this returns 11.62 for the same
/// hour (2.18x, and past the top of its own scale after ~50 min); auto-detected
/// sessions wrote no strain at all. Sharing a dial while not sharing a method
/// made "workout strain" and "daily strain" incomparable numbers that merely
/// looked alike.
///
/// [restingHr] and the profile's Tanaka HRmax and sex are all TERMS in the
/// formula — a missing one abstains rather than substituting a default (the
/// old live path silently used 30 y / 70 kg / 60 bpm).
double? strainFromPerMinuteHr(
  List<double> perMinuteHr, {
  required Profile profile,
  required double? restingHr,
}) {
  final hrMax = profile.hrMaxTanaka; // null when age is unknown
  final sex = profile.sex?.toLowerCase();
  if (perMinuteHr.isEmpty || hrMax == null || restingHr == null || sex == null) {
    return null;
  }
  final trimp = ana.banisterTrimp(
    perMinuteHr,
    restingHr: restingHr,
    maxHr: hrMax,
    sex: sex == 'f' || sex == 'female' ? ana.Sex.female : ana.Sex.male,
  );
  if (!trimp.present || trimp.value == null) return null;
  final score = ana.strainScoreMetric(trimp.value);
  return score.present ? score.value : null;
}

/// Score a manual window from its 1 Hz HR.
///
/// [hrTs]/[hrBpm] are the substrate samples INSIDE the window (ascending,
/// same length, `hr > 0` — exactly what `LocalDb.hrSamplesInRange` returns).
/// [restingHr] is the nightly/user RHR; [profile] supplies age/weight/sex.
///
/// Uses the SAME published methods as the day-level derivation so a manual
/// session and the day it sits in are on one scale: `ana.banisterTrimp` ->
/// `ana.strainScoreMetric` for strain, `ana.Calories.estimateBoutCalories`
/// (Keytel 2005) for kcal. Anchors come from Tanaka HRmax (`Profile`), never a
/// 220-age default — a missing anchor makes the dependent metric null.
ManualSessionStats computeManualSessionStats({
  required List<int> hrTs,
  required List<int> hrBpm,
  required Profile profile,
  required double zoneMaxHr,
  double? restingHr,
}) {
  if (hrTs.isEmpty || hrTs.length != hrBpm.length) {
    return const ManualSessionStats();
  }
  // Off-skin samples are dropped ONCE, here, and every scored field below is
  // built from the survivors. `hrSamplesInRange` already filters `hr > 0` in
  // SQL so production never sees a zero, but the filter must not depend on
  // that: forwarding the raw list to the calorie estimator billed each dropped
  // second at the resting rate, so a window with lost contact scored kcal that
  // avgHr, strain and the zone bands had all correctly ignored.
  final wornTs = <int>[];
  final worn = <int>[];
  for (var i = 0; i < hrBpm.length; i++) {
    if (hrBpm[i] > 0) {
      wornTs.add(hrTs[i]);
      worn.add(hrBpm[i]);
    }
  }
  if (worn.isEmpty) return const ManualSessionStats();

  final avg = worn.reduce((a, b) => a + b) / worn.length;
  final peak = worn.reduce((a, b) => a > b ? a : b);
  final perMin = hrPerMinute(wornTs, worn);

  final age = profile.ageYears?.toDouble();
  final weightKg = profile.weightKg;
  final sex = profile.sex?.toLowerCase();
  final hrMax = profile.hrMaxTanaka; // null when age is unknown

  final strain =
      strainFromPerMinuteHr(perMin, profile: profile, restingHr: restingHr);

  double? calories;
  if (hrMax != null && age != null && weightKg != null && sex != null) {
    // Real anchors only — `usedDefaultAnchors` stays false, so we are never
    // persisting a kcal figure built on a fabricated 220/60.
    final bout = ana.Calories.estimateBoutCalories(
      wornTs,
      [for (final v in worn) v.toDouble()],
      profile: ana.WorkoutUserProfile(
        weightKg: weightKg,
        heightCm: profile.heightCm ?? 170.0,
        age: age,
        sex: sex == 'f' || sex == 'female' ? 'female' : 'male',
      ),
      hrmax: hrMax,
      restingHr: restingHr,
    );
    if (!bout.usedDefaultAnchors && bout.kcal > 0) calories = bout.kcal;
  }

  return ManualSessionStats(
    avgHr: avg.round(),
    maxHr: peak,
    strain: strain,
    calories: calories,
    zoneMinutes: zoneMinutesFor(worn, zoneMaxHr),
    hrSampleCount: worn.length,
  );
}

/// Stable id for a manually logged session. Keyed on the START SECOND so
/// re-logging the same window is idempotent under `putSession`'s
/// INSERT-OR-REPLACE rather than piling up near-duplicates.
String manualSessionId(int startSec) => 'manual:$startSec';

/// Build the `sessions` row for a manual entry or a retimed session.
///
/// [existing] is the current row when EDITING — its `id`, `source` and
/// `created_at` are preserved so a retimed live session stays attributed to
/// how it was originally captured (the detail screen's AUTO tag depends on
/// this) and does not jump to the top of any created-at ordering.
///
/// Absent stats are written as explicit nulls, NOT omitted: `putSession` is
/// INSERT-OR-REPLACE, so an omitted key on an edit would silently retain the
/// stale value computed for the OLD window.
/// [sessionId] and [source] override the defaults for a session that is not
/// hand-entered — an auto-detected bout confirmed by the athlete keeps its
/// `auto:` id and `auto` attribution while still being scored through this one
/// path. Ignored when [existing] is given (an edit keeps what it already had).
Map<String, dynamic> buildManualSessionRow({
  required int startSec,
  required int endSec,
  required String type,
  required ManualSessionStats stats,
  required int createdAtMs,
  Map<String, dynamic>? existing,
  String? sessionId,
  String source = 'manual',
}) {
  final id =
      (existing?['id'] as String?) ?? sessionId ?? manualSessionId(startSec);
  final zone = stats.zoneMinutes;
  return {
    'id': id,
    'start_ts': startSec,
    'end_ts': endSec,
    'type': type,
    'status': 'done',
    'calories': stats.calories,
    'strain': stats.strain,
    'max_hr': stats.maxHr,
    'duration_min': (endSec - startSec) ~/ 60,
    'zone_min_json': jsonEncode(zone.any((v) => v > 0) ? zone : const <num>[]),
    // Steps and HRR belong to the window, not the entry: `steps` came from the
    // live pedometer we never ran, and `hrr_bpm` is refilled retrospectively
    // by the derivation engine from the substrate around `end_ts`. Clearing
    // them on an edit is correct — the old values described the old window.
    'steps': null,
    'hrr_bpm': null,
    'source': (existing?['source'] as String?) ?? source,
    'created_at':
        (existing?['created_at'] as num?)?.toInt() ?? createdAtMs,
  };
}

/// Ids of active suggestions whose window intersects a just-saved session.
///
/// A manual entry that covers the detector's fragment must retire that
/// fragment, or the athlete is left staring at a "did you work out?" card for
/// the workout they just logged. Same half-open intersection as the overlap
/// check. [suggestions] are `workout_suggestions` rows.
List<String> supersededSuggestionIds(
  List<Map<String, dynamic>> suggestions, {
  required int startSec,
  required int endSec,
}) {
  final out = <String>[];
  for (final s in suggestions) {
    final id = s['id'];
    final sStart = (s['start_ts'] as num?)?.toInt();
    final sEnd = (s['end_ts'] as num?)?.toInt();
    if (id is! String || sStart == null || sEnd == null) continue;
    if (sEnd <= sStart) continue;
    if (startSec < sEnd && sStart < endSec) out.add(id);
  }
  return out;
}

/// The best available scoring of a live-captured session's window: the tallies
/// the live gauge accumulated in RAM, reconciled against a re-score of the SAME
/// window from the 1 Hz substrate.
class ReconciledSessionScore {
  const ReconciledSessionScore({
    this.strain,
    this.calories,
    this.maxHr,
    this.zoneMinutes = const [],
    this.changed = false,
  });

  final double? strain;
  final double? calories;
  final int? maxHr;
  final List<double> zoneMinutes;

  /// True when the substrate improved on at least one stored field — the only
  /// case worth a write.
  final bool changed;
}

/// Reconcile a stored live session against a substrate re-score of its window.
///
/// WHY THIS EXISTS (issue #206): a live session's strain/calories/zone minutes
/// are accumulated in RAM, one tick per second, by the foreground app. That
/// accumulator sees nothing while the app is suspended — iOS suspends the 1 Hz
/// `Timer.periodic` the moment the app backgrounds, and an app the OS kills
/// mid-workout resumes with an EMPTY accumulator (`_reconcileOrphanedLiveWorkout`
/// rehydrates the row, not the tallies). Stop the workout after that and the
/// stored strain describes only the handful of minutes the app happened to be
/// awake for — commonly a few sub-resting minutes, whose Banister TRIMP is
/// exactly 0, which `strainScore` reports as a confident `0.0`. The user sees a
/// real duration, real avg/max HR and real zone bands next to "0.0 Strain".
///
/// The band, meanwhile, banked the whole window at 1 Hz. Once that window has
/// drained into `decoded_onehz`, re-scoring it through the SAME method
/// ([computeManualSessionStats]) recovers the real number.
///
/// THE MERGE RULE IS `max`, and that is deliberate — not a heuristic:
/// both numbers are the same monotone function (TRIMP is a sum of
/// per-minute non-negative terms) evaluated over SUBSETS of one window's
/// minutes. The live tally saw the minutes the app was awake for; the substrate
/// sees the minutes the band has drained so far. Each is therefore a LOWER
/// BOUND on the true score, and the larger one is strictly the better estimate.
/// Taking the max can never double-count (it is a max over two views of one
/// window, not a sum) and it is monotone under repeated application, so calling
/// this again after more of the window drains only ever improves the value and
/// converges. Averaging or preferring one source outright would both be wrong:
/// the substrate is empty right after a workout (the band has not offloaded
/// yet) and the live tally is empty after an app kill.
///
/// Absent stays absent: a null on both sides stays null rather than becoming
/// `0.0`. [substrate] must be the re-score of exactly `[start_ts, end_ts)`.
ReconciledSessionScore reconcileSessionScore({
  required double? liveStrain,
  required double? liveCalories,
  required int? liveMaxHr,
  required List<double> liveZoneMinutes,
  required ManualSessionStats substrate,

  /// True when [substrate] covers essentially the whole window, i.e. the band
  /// has finished handing this workout over.
  ///
  /// It then REPLACES the live tally rather than being maxed against it, and
  /// that distinction matters more than it looks. The `max` rule is only
  /// monotone while the scoring function is fixed, and it is not: the score
  /// depends on the trailing nightly resting HR and on Tanaka HRmax, both of
  /// which move. Maxing every re-score against the stored value would make a
  /// session converge to the highest strain ANY resting-HR the profile has
  /// ever reported would have produced — one artefactually low nightly RHR
  /// would inflate a workout permanently, with no way back down. Once the
  /// window is fully covered there is nothing left to recover, so the honest
  /// value is simply the current score.
  bool substrateIsComplete = false,
}) {
  // No substrate for this window (not drained yet, or pruned) — the live tally
  // is all the evidence there is.
  if (substrate.isUnscored) {
    return ReconciledSessionScore(
      strain: liveStrain,
      calories: liveCalories,
      maxHr: liveMaxHr,
      zoneMinutes: liveZoneMinutes,
    );
  }

  // ONE definition of the rule, for every scalar. Complete coverage: the
  // substrate IS the answer, falling back to the live value only where it has
  // nothing to say. Partial: both sides are lower bounds over subsets of the
  // same minutes, so the larger is the better estimate and the smaller is just
  // a less complete view.
  T? better<T extends num>(T? live, T? sub) {
    if (substrateIsComplete) return sub ?? live;
    if (live == null) return sub;
    if (sub == null) return live;
    return live >= sub ? live : sub;
  }

  final strain = better<double>(liveStrain, substrate.strain);
  final calories = better<double>(liveCalories, substrate.calories);
  final maxHr = better<int>(liveMaxHr, substrate.maxHr);

  // Zone minutes are a vector of the same lower-bound quantity, so take the
  // side with more total measured minutes rather than mixing two partial
  // splits (a per-element max would invent a total neither source observed).
  // Same shape as `better`: an empty substrate vector says nothing, so it must
  // not wipe a stored split just because coverage is complete (zone minutes
  // need a HRmax the profile may not carry, so an empty vector is a real case).
  double total(List<double> z) => z.fold(0.0, (a, b) => a + b);
  final zone = substrate.zoneMinutes.isEmpty
      ? liveZoneMinutes
      : (substrateIsComplete ||
                total(substrate.zoneMinutes) > total(liveZoneMinutes)
            ? substrate.zoneMinutes
            : liveZoneMinutes);

  final changed =
      strain != liveStrain ||
      calories != liveCalories ||
      maxHr != liveMaxHr ||
      !identical(zone, liveZoneMinutes);

  return ReconciledSessionScore(
    strain: strain,
    calories: calories,
    maxHr: maxHr,
    zoneMinutes: zone,
    changed: changed,
  );
}
