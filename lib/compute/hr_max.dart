// Spike-suppressed workout peak heart rate (issue #127).
//
// The Heart-rate page reports the max of per-MINUTE-averaged HR, so a brief PPG
// motion spike is averaged away (true peak ~143 bpm). The workout summary used
// to take a raw `hr.reduce(math.max)` over the 1 Hz samples with no artefact
// rejection, so a single transient could define the whole session's "max HR"
// (RR's report: 160 bpm summary vs a real 143 bpm peak). These helpers compute
// a peak that steps over such transients while STILL preserving a genuine brief
// effort peak — which a minute-mean would wrongly flatten. They are the single
// definition shared by all three producers (live tick, on-read recompute, and
// the workout-list fill) so the surfaces agree.
//
// Method:
//   1. Physiological reject — drop samples outside [kHrFloorBpm, ceiling]; the
//      ceiling is age-derived with headroom (real maxes exceed 220 − age) and
//      hard-capped. These are impossible readings, never effort.
//   2. Rolling median over a short odd window (~5 s at 1 Hz) — a 1–2 s spike can
//      never be the median of five samples, so the median steps over it; a
//      sustained climb survives because most of the window sits at the raised
//      level.
//   3. Peak = the maximum of that smoothed series.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

// ── THE app's HR ceiling for zones / TRIMP / calories ────────────────────────
//
// There used to be five of these. `220 − age` at local_repository_impl.dart,
// app_state.dart and analytics' load_trimp; Tanaka `208 − 0.7·age` inlined in
// onehz_pipeline and crossday_pipeline; and `(220 − age) + 25` here. At 30 that
// is 190 vs 187, at 60 it is 160 vs 166 — so the same day's `zone_timeline` and
// the same day's session `zone_bands` were banded off different ceilings for
// one user, with nothing on screen saying so. [estimatedMaxHr] is the one
// definition; route every zone/TRIMP/calorie caller through it.
//
// `hrCeilingForAge` below is NOT one of them and is deliberately left alone: it
// is an artefact-plausibility bound with headroom above the estimate, whose job
// is to drop impossible samples before a spike defines a peak. Folding it into
// the training ceiling would clip real effort.

/// Estimated HRmax (bpm) for [age] — Tanaka (2001), `208 − 0.7 · age`. Null
/// only when the age is unknown.
///
/// THIS IS NOT DEVICE-GATED, AND IT WAS, AND THAT WAS THE BUG. Tanaka is a
/// population regression on AGE. It reads no sensor, no accelerometer and no
/// ADC; swapping the strap does not move the number by one bpm. Dispatching it
/// through `calibrationFor` therefore refused a ceiling for every row written
/// before schema 41 — `device_family` is NULL there and is never backfilled by
/// design — and with the ceiling went zones, TRIMP, strain, Keytel calories and
/// `max_hr_used` for a user's entire history. device.dart's contract is "unknown
/// family ⇒ refuse a CALIBRATION CONSTANT"; the test is *does the sensor change
/// the answer*, and here it does not.
///
/// [deviceFamily] is accepted and DELIBERATELY UNUSED, so the ~6 call sites that
/// already resolve the strap keep compiling and the parameter stays as the hook
/// for the day a family earns its own age line. Do not re-add a null return for
/// an unstamped strap.
///
/// What this returns is an ESTIMATE and every consumer must say so: zones built
/// on it carry `source: 'tanaka'` (see [trainingZones]), which is materially
/// different from `observed`/`karvonen`. The device-dependent ceiling — the one
/// the band actually MEASURED — is `observedCeilingBpm`, and that one still
/// refuses for an unknown family, in analytics' `observed_max_hr.dart`.
double? estimatedMaxHr(num? age, String? deviceFamily) {
  if (age == null || age <= 0) return null;
  return 208.0 - 0.7 * age.toDouble();
}

/// THE zone set every surface bands on — day zones, the day zone timeline and a
/// session's zone bands. One function so those three cannot drift (TS-03a's
/// unification, extended to the anchors rather than just the ceiling).
///
/// Which anchors it used is in `HeartRateZoneSet.source`, and the screens must
/// print it, because they are materially different claims:
///
/// * `karvonen` — %HRR bands between two heart rates the band MEASURED: the
///   observed ceiling ([observedCeilingBpm], TS-03) and the median of
///   [restingHrHistory]. Still a model — %HRR bands are a convention, not a
///   measurement of anyone's thresholds — but both ends are measured.
/// * `observed` — the ceiling is measured, the resting-HR history is still too
///   short for a reserve anchor ([HeartRateZones.reserveMinDays]), so these are
///   %HRmax bands off the observed ceiling.
/// * `tanaka` — no observed ceiling yet, OR one that does not reach the age
///   line: %HRmax off `208 − 0.7·age`, i.e. the AGE ESTIMATE. Byte-for-byte
///   what this app did before TS-03 landed.
///
/// THE CEILING IS `max(observed, estimate)`, AND THAT ASYMMETRY IS THE WHOLE
/// RULE. An observed ceiling is ONE-SIDED evidence. Holding 195 proves the
/// ceiling is AT LEAST 195 — real information the age line does not have, and
/// it wins. Holding 166 proves nothing about the top: "has never gone maximal"
/// and "genuinely maxes at 166" produce the identical number, and on a wrist
/// the first is by far the commoner. Preferring it in BOTH directions is how a
/// 25-year-old whose hardest HELD effort was 166 got Z5 at 0.9·166 ≈ 149 bpm
/// and banked 13 of the 16 minutes of a steady run in "Max effort", captioned
/// as the age estimate.
///
/// On the session-detail path the ceiling was even set by the session being
/// graded — `_zoneAnchors` takes the all-time max, today included. The day
/// pipeline and the live tick do not: `observedHrCeilingBpm` is
/// strictly-before-today by design, and the live `zoneSet` is pinned at start.
///
/// There is deliberately NO tolerance band below the estimate. A threshold at
/// `estimate − k` puts a cliff in the middle of the range the ceiling creeps
/// through: at 30 an observed 177 would anchor at 177 and 176.9 at 187, moving
/// every edge 10 bpm on a 0.1 bpm change, with nothing on screen to explain it.
/// `max` is continuous — at 186.9 vs 187.1 only the LABEL moves.
///
/// The cost, which is chosen and not overlooked: someone whose HRmax is
/// genuinely below their age line gets a Z5 they cannot reach. That is an
/// under-report — an absence — where the old behaviour was an affirmative
/// "max effort" the data did not support, and this app abstains before it
/// asserts. The set says `tanaka`, and the zones screen names the held ceiling
/// and why it is not being used (`maximal_effort`).
///
/// Null only when there is no ceiling at all — no observed ceiling AND no age.
/// An unstamped strap is no longer one of those cases: Tanaka does not read a
/// sensor, so it lands on `tanaka` with the estimate's label, not on nothing.
///
/// The age estimate is deliberately NOT run through Karvonen: reserve bands off
/// a guessed ceiling are one measured anchor and one guessed one, which is not
/// the claim `karvonen` makes here and not worth moving every existing user's
/// zone boundaries for.
/// [manualZoneLowerBpm] is the user's own override — five ascending BPM
/// thresholds, one per zone's LOWER edge. Zone 5 has no upper edge for
/// CLASSIFICATION ([zoneNumber] never checks it — same as every computed
/// set), but [_manualZones] still gives it a finite display value, because
/// `.round()` on `double.infinity` throws and every payload builder rounds
/// it unconditionally. When present and well-formed the override wins
/// outright: no age, no ceiling, no resting history is consulted. When
/// absent or
/// malformed it falls straight through to the computed set below — an
/// override that failed to save is not license to fabricate one, but nor is
/// it license to erase the honest default underneath it.
ana.HeartRateZoneSet? trainingZones({
  num? age,
  String? deviceFamily,
  double? observedCeilingBpm,
  List<double> restingHrHistory = const [],
  List<int>? manualZoneLowerBpm,
}) {
  final manual = manualZoneLowerBpm;
  if (manual != null && manual.length == 5) return _manualZones(manual);
  final est = estimatedMaxHr(age, deviceFamily);
  if (observedCeilingBpm != null &&
      observedCeilingBpm > 0 &&
      (est == null || observedCeilingBpm >= est)) {
    return ana.HeartRateZones.reserveZones(
          restingHrHistory: restingHrHistory,
          maxHr: observedCeilingBpm,
        ) ??
        ana.HeartRateZones.zonesFromMaxHr(
          observedCeilingBpm,
          source: 'observed',
        );
  }
  return est == null
      ? null
      : ana.HeartRateZones.zonesFromMaxHr(est, source: 'tanaka');
}

/// Builds a zone set straight from five user-set bpm thresholds — no
/// percentage-of-anything, so `lowerPct`/`upperPct` (display metadata no
/// screen reads for a manual set) are left at 0.
///
/// Zone 5's upper edge is open-ended for classification ([zoneNumber] never
/// consults it there) but every caller of [trainingZones] still rounds it
/// for display, so it cannot be `double.infinity` — `.round()` on that
/// throws. [kHrHardCeilBpm] (no human sustains a heart rate above it) is the
/// same hard ceiling already used to bound implausible samples elsewhere in
/// this file, so it is not a new number being invented here.
ana.HeartRateZoneSet _manualZones(List<int> lowerBpm) {
  final z5Upper = math.max(
    lowerBpm[4] + 1,
    kHrHardCeilBpm,
  ).toDouble();
  return ana.HeartRateZoneSet(
    zones: [
      for (var i = 0; i < 5; i++)
        ana.HeartRateZone(
          number: i + 1,
          lower: lowerBpm[i].toDouble(),
          upper: i < 4 ? lowerBpm[i + 1].toDouble() : z5Upper,
          lowerPct: 0,
          upperPct: 0,
        ),
    ],
    maxHr: z5Upper,
    source: 'manual',
  );
}

/// Reads the manual zone override off a profile map — five ascending BPM
/// thresholds under `hr_zone_bounds`, or null when unset/malformed (wrong
/// length, non-numeric, or not strictly ascending). Every [trainingZones]
/// caller routes through this so the override and its validation cannot
/// drift between the day pipeline, the live tick and the zones screen.
List<int>? manualZoneBoundsFromProfile(Map<String, dynamic>? profile) {
  final raw = profile?['hr_zone_bounds'];
  if (raw is! List || raw.length != 5) return null;
  final vals = <int>[];
  for (final v in raw) {
    if (v is! num) return null;
    vals.add(v.round());
  }
  for (var i = 1; i < vals.length; i++) {
    if (vals[i] <= vals[i - 1]) return null;
  }
  return vals;
}

/// Whether [source] means BOTH zone anchors were measured on this user.
///
/// The gate TS-05 hangs on: a three-bar "your training is polarised" read off
/// bands built on 220−age is manufactured, and a caption cannot repair it, so
/// the distribution is not drawn at all unless this is true.
bool zonesAreMeasured(String? source) => source == 'karvonen';

/// Below this a sample is sensor dropout/garbage, not a heartbeat.
const int kHrFloorBpm = 30;

/// No human sustains a heart rate above this; anything higher is an artefact.
const int kHrHardCeilBpm = 220;

/// Rolling-median window (samples ≈ seconds at 1 Hz). Five is the smallest odd
/// window that fully rejects a 1–2 s transient (a two-sample spike can never be
/// the median of five) while preserving a genuine ≥3 s effort peak.
const int kHrSmoothWindow = 5;

/// Upper plausibility bound for a single HR sample, given [age]. Uses the
/// 220 − age estimate plus headroom (genuine maxes run above the estimate),
/// floored so a low estimate never clips real effort and capped at the hard
/// human ceiling. Unknown age → the hard ceiling.
int hrCeilingForAge(int? age) {
  if (age == null) return kHrHardCeilBpm;
  final withHeadroom = (220 - age) + 25;
  return math.min(kHrHardCeilBpm, math.max(200, withHeadroom));
}

/// Spike-suppressed extreme HR over a raw 1 Hz [hr] series. [wantMax] selects
/// the peak (largest smoothed value) vs the trough (smallest). The min side is
/// symmetric to the max: a 1–2 s LOW dropout can no more be the median of the
/// window than a high spike, and the same physiological reject drops garbage
/// (a stray <30 bpm reading) before it can define the trough.
(int, int)? _smoothedExtremeHrAt(
  List<int> hr, {
  required bool wantMax,
  int? age,
  int window = kHrSmoothWindow,
}) {
  if (hr.isEmpty) return null;
  final ceil = hrCeilingForAge(age);

  // Physiological reject, keeping the ORIGINAL index of each kept sample so the
  // returned index maps back onto the caller's raw series (time-to-peak).
  final vals = <int>[];
  final srcIdx = <int>[];
  for (var i = 0; i < hr.length; i++) {
    if (hr[i] >= kHrFloorBpm && hr[i] <= ceil) {
      vals.add(hr[i]);
      srcIdx.add(i);
    }
  }
  if (vals.isEmpty) return null;

  final w = window.isOdd ? window : window + 1;
  // Too short to form a full window — fall back to the plausible extreme
  // (already artefact-bounded by the reject above).
  if (vals.length < w) {
    var best = vals[0], bi = 0;
    for (var i = 1; i < vals.length; i++) {
      if (wantMax ? vals[i] > best : vals[i] < best) {
        best = vals[i];
        bi = i;
      }
    }
    return (best, srcIdx[bi]);
  }

  final half = w ~/ 2;
  final scratch = List<int>.filled(w, 0);
  int? bestMed;
  var bestIdx = srcIdx[half];
  for (var c = half; c < vals.length - half; c++) {
    for (var k = 0; k < w; k++) {
      scratch[k] = vals[c - half + k];
    }
    scratch.sort();
    final med = scratch[half];
    if (bestMed == null || (wantMax ? med > bestMed : med < bestMed)) {
      bestMed = med;
      bestIdx = srcIdx[c];
    }
  }
  return (bestMed!, bestIdx);
}

/// Spike-suppressed peak HR over a raw 1 Hz [hr] series, as `(value, index)`:
/// the peak bpm and the index in [hr] at which it occurs (the centre of the
/// winning window — for time-to-peak). Null when no plausible sample survives
/// the physiological reject.
(int, int)? smoothedMaxHrAt(List<int> hr,
        {int? age, int window = kHrSmoothWindow}) =>
    _smoothedExtremeHrAt(hr, wantMax: true, age: age, window: window);

/// Spike-suppressed trough HR — the min counterpart of [smoothedMaxHrAt], so a
/// single low PPG dropout can't define the workout min.
(int, int)? smoothedMinHrAt(List<int> hr,
        {int? age, int window = kHrSmoothWindow}) =>
    _smoothedExtremeHrAt(hr, wantMax: false, age: age, window: window);

/// Spike-suppressed peak HR (value only) — see [smoothedMaxHrAt].
int? smoothedMaxHr(List<int> hr, {int? age, int window = kHrSmoothWindow}) =>
    smoothedMaxHrAt(hr, age: age, window: window)?.$1;

/// Spike-suppressed trough HR (value only) — see [smoothedMinHrAt].
int? smoothedMinHr(List<int> hr, {int? age, int window = kHrSmoothWindow}) =>
    smoothedMinHrAt(hr, age: age, window: window)?.$1;

/// Streaming counterpart of [smoothedMaxHr] for the live workout tick: feed each
/// 1 Hz sample with [add] and read [max], the spike-suppressed running peak.
/// Uses the identical window + physiological reject so the live "new max!" value
/// and the persisted session max agree with the on-read recompute.
class RollingMaxHr {
  RollingMaxHr({this.age, int window = kHrSmoothWindow})
      : _window = window.isOdd ? window : window + 1;

  final int? age;
  final int _window;
  final List<int> _buf = <int>[];

  /// Spike-suppressed peak seen so far (bpm); 0 until a full window has passed.
  int max = 0;

  void add(int hr) {
    if (hr < kHrFloorBpm || hr > hrCeilingForAge(age)) return; // reject
    _buf.add(hr);
    if (_buf.length > _window) _buf.removeAt(0);
    if (_buf.length < _window) return; // wait for a full window before trusting
    final sorted = List<int>.of(_buf)..sort();
    final med = sorted[_window ~/ 2];
    if (med > max) max = med;
  }
}
