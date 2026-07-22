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
