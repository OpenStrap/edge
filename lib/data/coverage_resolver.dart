// Which device owns each second of a signal, for days more than one device
// covered. Pure, zero I/O, zero Flutter — beside `live_coverage_policy.dart`,
// in its idiom.
//
// TAKES COVERAGE, NEVER VALUES. There is no parameter through which a heart
// rate could reach this file, and that is the property to defend in review:
// it is what keeps a resolver from becoming a fusion engine.

import '../ble/adapters/signals.dart' show InputSignal;

/// One device's raw coverage of one signal — a PHYSICAL FACT, never a
/// conclusion. Read straight out of `device_coverage` (schema 51).
/// `start` inclusive, `end` exclusive, both unix SECONDS in the same base as
/// `decoded_onehz.rec_ts`.
typedef CoverageInterval = ({String deviceId, int start, int end});

/// One stretch of the resolved window and its EXCLUSIVE owner.
///
/// `deviceId == null` is a first-class value meaning NOTHING WAS RECORDING —
/// not an error, not "unknown", not a lookup miss. Spans TILE the requested
/// window with no holes and no overlaps, which is what makes [spanAt] total.
typedef OwnedSpan = ({int start, int end, String? deviceId});

/// Resolution grid. 60 s, not per-sample: `hr_curve` and its siblings are
/// already bucketed series and `hourly_hr` is derived from `hr_curve`, so
/// resolving finer than the thing you draw is work thrown away — 86,400
/// decisions to produce a 1,440-point chart. It also makes sub-second
/// cross-device clock alignment irrelevant, which is the point: timestamp
/// shifting to make two sources merge was tried and deleted
/// (`ClockPolicy.correctRecordTs` snapped to a 5-minute grid, which at 1 Hz
/// REPLACEs 299 of every 300 rows).
const int kOwnershipBucketSeconds = 60;

/// Buckets of consecutive disagreement required before ownership moves BETWEEN
/// TWO REAL DEVICES.
///
/// Without it, "highest-ranked device present in this bucket wins" sawtooths
/// on ordinary dropouts: a band with a 1-in-5 dropout rate emits hundreds of
/// alternating spans, the span list stops being small, and the cursor readout
/// flickers between two device names across ten pixels. Below the threshold
/// the span keeps its owner and the missing buckets are gaps WITHIN that
/// owner's span — exactly what a single-device chart already shows for a
/// dropout.
///
/// ponytail: fixed 3. Make it per-signal only if a real capture shows 3 is
/// wrong; a knob here would be a knob nobody can set from evidence.
const int kOwnershipHysteresisBuckets = 3;

/// For ONE signal over ONE window, the exclusive-owner spans, in time order.
///
/// [priority] is highest-first FOR THIS SIGNAL and is also the CANDIDATE list
/// — a device absent from it is not competing, because it does not declare
/// the signal (`BandAdapter.signals`). Candidacy before rank.
List<OwnedSpan> resolveOwnership({
  required List<CoverageInterval> coverage,
  required List<String> priority,
  required int from,
  required int to,
  required InputSignal signal,
}) {
  // Credit for the step path is overlap-SUBTRACTION across spans
  // (`resolveDaySteps`, live_coverage_policy.dart), not exclusive ownership,
  // and folding it in here reintroduces the double-count that guard exists
  // to prevent. An assert, not a comment: a comment does not survive the
  // next person who sees two resolvers and tries to be helpful.
  // NOTE there is no `InputSignal.steps` — `accelHighRate` IS the step path.
  assert(signal != InputSignal.accelHighRate,
      'steps resolve additively in live_coverage_policy, not by owner');
  // A duplicate id would make two ranks equal and the winner would depend on
  // iteration order.
  assert(priority.toSet().length == priority.length, 'priority has duplicates');
  if (to <= from || priority.isEmpty) return const [];

  final rank = <String, int>{
    for (var i = 0; i < priority.length; i++) priority[i]: i,
  };

  // ── THE IDENTITY SHORT-CIRCUIT. Not an optimization. ──────────────────────
  // With at most one candidate device actually covering this window there is
  // nothing to arbitrate, so no arbitration runs: one span, the whole window,
  // that device. No grid, no hysteresis, no bucket arithmetic — so no code
  // that could exclude one of its rows is even entered.
  String? sole;
  var candidates = 0;
  for (final iv in coverage) {
    if (!rank.containsKey(iv.deviceId)) continue;
    if (iv.end <= iv.start || iv.end <= from || iv.start >= to) continue;
    if (iv.deviceId != sole) {
      if (sole != null) {
        candidates = 2;
        break;
      }
      sole = iv.deviceId;
      candidates = 1;
    }
  }
  if (candidates == 0) return [(start: from, end: to, deviceId: null)];
  if (candidates == 1) return [(start: from, end: to, deviceId: sole)];

  // ── PASS 1 — raw per-bucket winner ────────────────────────────────────────
  const g = kOwnershipBucketSeconds;
  final b0 = from ~/ g; // floor: the bucket `from` falls in
  final b1 = (to + g - 1) ~/ g; // ceil, exclusive
  final n = b1 - b0;
  final raw = List<String?>.filled(n, null);
  final best = List<int>.filled(n, priority.length);
  for (final iv in coverage) {
    final r = rank[iv.deviceId];
    if (r == null || iv.end <= iv.start) continue;
    var lo = (iv.start ~/ g) - b0;
    var hi = ((iv.end + g - 1) ~/ g) - b0; // one past the last bucket touched
    if (lo < 0) lo = 0;
    if (hi > n) hi = n;
    for (var b = lo; b < hi; b++) {
      if (r < best[b]) {
        best[b] = r;
        raw[b] = iv.deviceId;
      }
    }
  }

  // ── PASS 2 — hysteresis ───────────────────────────────────────────────────
  // SEEDING: the first bucket's raw winner, with no warm-up. The alternative
  // is a leading "undetermined" state, which is a FOURTH value the span shape
  // has no room for and the JSON cannot express. Coverage intervals are hours
  // long and `from`/`to` are day bounds, so this only ever decides the first
  // minute.
  final owner = List<String?>.filled(n, null);
  var current = raw[0];
  var candidate = current;
  var run = 0;
  for (var b = 0; b < n; b++) {
    final w = raw[b];
    if (current == null && w != null) {
      // ASYMMETRIC ON PURPOSE, and this is the single most load-bearing
      // branch in the file. Hysteresis exists to stop two REAL devices
      // trading a span back and forth. "Nothing was recording" is not a
      // competitor, it is the absence of one — so a covering device takes an
      // uncovered stretch IMMEDIATELY. Made symmetric, a device that appears
      // for two buckets inside a gap would lose them to null, and its rows
      // would be EXCLUDED FROM THE SUBSTRATE. That is data loss at derive
      // time, not a label that flickers.
      current = w;
      candidate = w;
      run = 0;
    } else if (w == current) {
      candidate = current;
      run = 0;
    } else if (w == candidate && run > 0) {
      run++;
    } else {
      candidate = w;
      run = 1;
    }
    owner[b] = current;
    if (run >= kOwnershipHysteresisBuckets) {
      current = candidate;
      // RETROACTIVE to the first bucket of the run. Without the backfill the
      // boundary lags the real handover by kOwnershipHysteresisBuckets-1
      // buckets, and those two minutes of the NEW owner's rows are
      // attributed to a device that had none.
      for (var k = b - run + 1; k <= b; k++) {
        owner[k] = current;
      }
      run = 0;
    }
  }

  // ── PASS 3 — coalesce, and clamp the outer edges to the requested window ──
  // The clamp is what makes the output TILE [from, to) exactly: no span
  // starts before `from`, none ends after `to`, and there is no gap between
  // consecutive spans.
  final out = <OwnedSpan>[];
  var s = 0;
  for (var b = 1; b <= n; b++) {
    if (b < n && owner[b] == owner[s]) continue;
    out.add((
      start: s == 0 ? from : (b0 + s) * g,
      end: b == n ? to : (b0 + b) * g,
      deviceId: owner[s],
    ));
    s = b;
  }
  return out;
}
// ponytail: O(buckets x intervals) — 1,440 x a handful per day. If a real
// device ever yields hundreds of intervals a day, pre-bucket the intervals
// by start and sweep instead.

/// The span containing [ts], or null when [ts] is outside the resolved
/// window.
///
/// Null means OUTSIDE, never "gap" — a gap is a found span whose `deviceId`
/// is null. Binary search, no allocation: callers may fire on every pointer
/// move.
OwnedSpan? spanAt(List<OwnedSpan> spans, int ts) {
  var lo = 0, hi = spans.length - 1;
  while (lo <= hi) {
    final m = (lo + hi) >> 1;
    final s = spans[m];
    if (ts < s.start) {
      hi = m - 1;
    } else if (ts >= s.end) {
      lo = m + 1;
    } else {
      return s;
    }
  }
  return null;
}

/// The `series.coverage[signal]` wire shape. Short keys because this rides in
/// a bundle that is never pruned.
List<Map<String, Object?>> coverageToJson(List<OwnedSpan> spans) => [
      for (final s in spans) {'s': s.start, 'e': s.end, 'd': s.deviceId},
    ];

/// Tolerant by design: a malformed entry is DROPPED, never guessed at. A
/// bundle written by a build this one does not know about must degrade to
/// "no attribution", which is the same honest answer as a pre-migration day.
List<OwnedSpan> coverageFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <OwnedSpan>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final s = e['s'], en = e['e'], d = e['d'];
    if (s is! int || en is! int || en <= s) continue;
    out.add((start: s, end: en, deviceId: d is String ? d : null));
  }
  return out;
}

/// The distinct non-null owners across every signal's span list — "how many
/// devices actually contributed to this day".
Set<String> ownersOf(Map<InputSignal, List<OwnedSpan>> ownership) => {
      for (final spans in ownership.values)
        for (final s in spans)
          if (s.deviceId != null) s.deviceId!,
    };

/// The priority order in force when a day derived, canonically encoded:
/// signals ordered by name, devices in rank order, e.g.
///   `hr1Hz=|oura-A1B2;rrIntervals=|oura-A1B2`
/// (`` is the primary — `LocalDb.kPrimaryDeviceId`). Compared with `!=`,
/// never parsed. No `crypto` dependency exists in this app and none is added
/// for a value a few bytes long — see `metric_series_version.priority_hash`.
String priorityKey(Map<InputSignal, List<String>> priority) =>
    (priority.entries.toList()
          ..sort((a, b) => a.key.name.compareTo(b.key.name)))
        .map((e) => '${e.key.name}=${e.value.join('|')}')
        .join(';');
