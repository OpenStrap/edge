// live_coverage_policy.dart — pure, I/O-free policy for the 100 Hz step
// COVERAGE WINDOW. Nothing here touches BLE, the DB, Flutter or the clock:
// callers hand in the facts they observed for one live-pedometer session and
// read back the window to persist. Every branch is unit-testable.
//
// WHY THE WINDOW EXISTS
// `live_coverage` rows say "over THIS wall period the live 100 Hz pedometer
// counted real steps". The derivation pass adds those real steps to the day and
// EXCLUDES the minutes the window covers from the 1 Hz estimate, so a minute is
// counted by 100 Hz or estimated by 1 Hz — never both. A window is therefore a
// measurement, not a label: get its extent wrong and either minutes get counted
// twice (window too short) or real minutes lose their estimate (too long).
//
// WHICH FAILURE WE PREFER
// Too short fabricates steps that never happened (the same minute counted by
// both paths). Too long drops an estimate for minutes we may not have covered —
// an UNDER-report of something we genuinely did not measure at 100 Hz. Under
// the honesty contract the under-report wins, so when the evidence is
// ambiguous these rules lean toward the WIDER window.

import 'dart:math' as math;

/// Sample rate of the live accel stream the pedometer runs on.
const double kLiveSampleRateHz = 100.0;

/// Fraction of the session's wall-clock hull that must actually be sampled
/// before we treat the hull as the covered period.
///
/// The streamed time is a UNION of intervals; a `live_coverage` row can only
/// store its convex HULL. At/above this duty cycle the union dominates its own
/// hull (dropouts are the exception), so the hull is the better model of the
/// counting period and, per the preference above, the safer one. Below it the
/// session was mostly NOT streaming — a link that woke for a few seconds an
/// hour — and claiming the hull would silently delete hours of 1 Hz estimate
/// for a handful of real steps. There we fall back to the only quantity we
/// actually measured: the sampled duration.
const double kCoverageDutyFloor = 0.5;

/// Cadence ceiling used to derive a LOWER BOUND on elapsed time from a step
/// count. Elite sprint cadence tops out near 220 spm; 240 leaves headroom so
/// the bound is never tighter than physiology allows. This is a bound, never an
/// estimate: N steps cannot have happened in less than N / (240/60) seconds.
const double kMaxPlausibleCadenceSpm = 240.0;

/// A persisted 100 Hz coverage window, in the SAME epoch-second base as
/// `decoded_onehz.rec_ts` (see [deriveLiveCoverageWindow]).
class LiveCoverageWindow {
  const LiveCoverageWindow(this.startTs, this.endTs);
  final int startTs;
  final int endTs;
  int get seconds => endTs - startTs;

  @override
  String toString() => 'LiveCoverageWindow($startTs..$endTs, ${seconds}s)';
}

/// The shortest elapsed time [steps] could physically span, in whole seconds.
/// 0 for a non-positive count. See [kMaxPlausibleCadenceSpm].
int minCoverageSecondsForSteps(int steps) =>
    steps <= 0 ? 0 : (steps * 60 / kMaxPlausibleCadenceSpm).ceil();

/// Decide the coverage window for one live-pedometer session, or null when
/// there is nothing defensible to record.
///
/// TIME BASE. The window is compared against `decoded_onehz.rec_ts` by
/// `LocalDb.coverageWindowsOverlapping`, so it must stay in the BAND's record
/// time base. That is why the window is ANCHORED on [bandStartTs] — the record
/// timestamp carried by the first live frame — whenever the band supplied one,
/// and only falls back to the phone clock ([firstIngestMs]) when it never did.
/// The engine SET_CLOCKs the band to phone time on connect, so the two bases
/// agree to within the drift it already corrects, but we do not rely on that:
/// the ANCHOR comes from the band and only the DURATION comes from measurement,
/// and a duration is the same number in either base.
///
/// DURATION. Three observations bound the covered period:
///   * [samples100Hz] / [kLiveSampleRateHz] — the time we can PROVE we sampled
///     (each 100 Hz sample is 10 ms of covered signal). A lower bound.
///   * the wall-clock hull [firstIngestMs] … [lastIngestMs] — the outer extent
///     of the counting period, dropouts included. An upper bound.
///   * [bandStartTs] … [bandEndTs] — the same hull in band time, used only when
///     the phone timestamps are missing, because in practice the band repeats
///     one record timestamp for a whole live session (span 0) and cannot be
///     trusted to carry the duration.
/// The duty cycle between the first two picks which one models the session —
/// see [kCoverageDutyFloor]. The result is then raised to
/// [minCoverageSecondsForSteps] if the claimed [steps] could not physically fit
/// in it, and is never zero.
LiveCoverageWindow? deriveLiveCoverageWindow({
  required int steps,
  required int samples100Hz,
  int? bandStartTs,
  int bandEndTs = 0,
  int? firstIngestMs,
  int? lastIngestMs,
}) {
  // No real steps → nothing to exclude from the 1 Hz estimate, nothing to store.
  if (steps <= 0) return null;

  final int? anchor = (bandStartTs != null && bandStartTs > 0)
      ? bandStartTs
      : (firstIngestMs != null && firstIngestMs > 0
          ? firstIngestMs ~/ 1000
          : null);
  // Steps with no timestamp at all from either clock: we cannot place the
  // window on any timeline, and a misplaced window would exclude the WRONG
  // minutes. Drop it rather than invent a position.
  if (anchor == null) return null;

  final sampledS = samples100Hz <= 0 ? 0.0 : samples100Hz / kLiveSampleRateHz;

  double hullS = 0;
  if (firstIngestMs != null &&
      lastIngestMs != null &&
      lastIngestMs > firstIngestMs) {
    hullS = (lastIngestMs - firstIngestMs) / 1000.0;
  } else if (bandStartTs != null && bandEndTs > bandStartTs) {
    hullS = (bandEndTs - bandStartTs).toDouble();
  }

  double coveredS;
  if (hullS <= 0) {
    coveredS = sampledS; // no hull observed — the sampled time is all we have
  } else if (sampledS <= 0) {
    coveredS = hullS; // steps without sample accounting — hull is the evidence
  } else {
    final duty = sampledS / hullS;
    coveredS = duty >= kCoverageDutyFloor ? hullS : sampledS;
    // The sampled time can exceed the hull (duplicate/backlogged frames). The
    // hull is wall truth, so it also acts as the ceiling.
    if (coveredS > hullS) coveredS = hullS;
  }

  // Physiological floor — a true lower bound, applied last so a broken duration
  // measurement can never produce a window the steps could not fit into.
  var secs = coveredS.ceil();
  secs = math.max(secs, minCoverageSecondsForSteps(steps));
  // A window claiming steps is never zero-width: that silently disables the
  // no-double-count exclusion it exists to drive.
  if (secs < 1) secs = 1;
  return LiveCoverageWindow(anchor, anchor + secs);
}

// ── THE SOURCE LADDER ───────────────────────────────────────────────────────
//
// A day is not owned by one source. Each SPAN of it goes to the best source
// that actually covered that span, and the spans sum. Whole-day precedence
// ("the band reported something, so the band takes the day") reported 622 steps
// against the phone's 18,856 on a real export, because the strap only covered
// the hours it was syncing.
//
// TWO FAILURES, NOT ONE. Per-span precedence alone is not enough either.
// `live_coverage` spans say "a live link existed", not "the pedometer was
// counting", and they are deliberately biased WIDE (see [kCoverageDutyFloor]).
// On the same export the band claimed 9.35 h of coverage for 216 steps
// (0.4 spm) while the phone had 11 h for 7,775 (11.8 spm): handing the band
// that span because it is nominally the better sensor loses ~7,000 steps. So a
// band span only outranks the phone where it actually looks like gait — see
// [kBandSpanMinSpm].
//
// HOW OVERLAPS ARE SETTLED. Spans are resolved highest rank first; a lower-
// ranked span is credited its own count MINUS what the higher-ranked spans
// already counted over the time they share (pro-rated by overlap). So a strap
// session inside a phone-covered hour contributes its own minutes and the phone
// contributes the rest, and neither the walk nor the hour is counted twice. The
// subtraction is bounded at zero, so a source can lose its claim but can never
// go negative — nothing is ever fabricated and nothing is double-counted.

/// Minimum step density (steps per minute, over the span's own extent) a BAND
/// span must show before it outranks the phone over time they both cover.
///
/// This is a WEAR-vs-GAIT discriminator, not a cadence gate — a real bout
/// includes pauses, so it sits far below the 60–200 spm walking band. Measured
/// band spans from a real export: 0.4, 3.0 (link idle, phone was right) and
/// 101.6 spm (an 11-minute walk, band was right). It only ever changes the
/// ORDER between band and phone: on a day with no phone data the band keeps
/// every step it counted regardless of this number.
///
/// Left as a knob on purpose — a different strap, worn differently, will sit
/// somewhere else on this axis.
const double kBandSpanMinSpm = 10.0;

/// Floor a BAND span must clear to survive overlapping an hour the PHONE
/// confirms was motionless (a `steps == 0` phone row — see
/// [LocalDb.replacePhoneCoverageForDay]).
///
/// [kBandSpanMinSpm] alone does not reject the exact failure this codebase's
/// own OxWalk citation warns about: 22-27 FALSE steps/min at the wrist during
/// dishes and driving — comfortably above 10. Nothing used to compete against
/// that span at all, because a confirmed-zero hour was never persisted (see
/// the phone sync's old `n <= 0` skip), so it was credited in full and summed
/// straight onto the phone's real count — issue #366's "adding the phone's
/// steps to the strap's steps" on a WHOOP 4, whose only step source outside a
/// tracked walk/run IS this passive-wear arm-motion counter.
///
/// Set above the measured false-positive ceiling (27 spm) with margin, and
/// comfortably below real walking cadence (60+ spm), so a genuine walk the
/// phone missed for an unrelated reason (left at home, still in a bag) keeps
/// its steps — the phone's zero only overrides density in the range that is
/// itself evidence of arm work, not gait.
const double kConfirmedStillMinSpm = 40.0;

/// Drop the portion of any BAND span that overlaps an hour the phone
/// confirms was motionless, unless that span's own density already looks
/// like real gait ([kConfirmedStillMinSpm]). Phone rows are passed through
/// unchanged — this only ever removes band credit, never adds any.
///
/// Pure pre-pass ahead of the ranking loop below, so the ladder itself (and
/// every test pinned against it) is untouched for every day that has no
/// confirmed-zero phone hour at all.
List<CoverageSpan> _vetoAgainstConfirmedStill(List<CoverageSpan> rows) {
  final stillWindows = [
    for (final r in rows)
      if (!r.fromBand && r.steps == 0 && r.endTs > r.startTs) r,
  ];
  if (stillWindows.isEmpty) return rows;
  // ponytail: sums overlap against every still window rather than merging
  // them first, so two OVERLAPPING zero-phone rows over the same band span
  // would double-void it. Phone rows are hourly and non-overlapping by
  // construction (`replacePhoneCoverageForDay` is delete-then-insert per
  // day), so this cannot happen today; merge stillWindows first if that ever
  // changes (e.g. sub-hour phone buckets).
  final out = <CoverageSpan>[];
  for (final r in rows) {
    if (!r.fromBand || r.steps <= 0 || r.endTs <= r.startTs) {
      out.add(r);
      continue;
    }
    final dur = r.endTs - r.startTs;
    final spm = r.steps * 60 / dur;
    if (spm >= kConfirmedStillMinSpm) {
      out.add(r); // looks like real gait — the phone's zero does not win
      continue;
    }
    var voidedSec = 0;
    for (final z in stillWindows) {
      final int lo = math.max(r.startTs, z.startTs);
      final int hi = math.min(r.endTs, z.endTs);
      if (hi > lo) voidedSec += hi - lo;
    }
    if (voidedSec <= 0) {
      out.add(r);
      continue;
    }
    final keptSec = math.max(0, dur - voidedSec);
    if (keptSec <= 0) continue; // fully inside a confirmed-still hour — drop
    final keptSteps = (r.steps * keptSec / dur).round();
    if (keptSteps <= 0) continue;
    out.add(CoverageSpan(
      startTs: r.startTs,
      endTs: r.endTs,
      steps: keptSteps,
      fromBand: true,
      deviceId: r.deviceId,
    ));
  }
  return out;
}

/// One `live_coverage` row, as the resolver sees it.
class CoverageSpan {
  const CoverageSpan({
    required this.startTs,
    required this.endTs,
    required this.steps,
    required this.fromBand,
    this.deviceId = '',
  });

  final int startTs;
  final int endTs;
  final int steps;

  /// `source != 'phone'` — the band's own 100 Hz pedometer, live or imported.
  final bool fromBand;

  /// WHICH PHYSICAL SENSOR counted these steps. `''` is permanently reserved
  /// for the primary band (and for the phone, which is likewise one of it),
  /// so a single-device install is entirely `''` and behaves exactly as it did
  /// before this field existed.
  ///
  /// It exists because two sensors that are not the same sensor can produce
  /// two spans of the same rank over the same walk — see [resolveDaySteps].
  final String deviceId;
}

/// A day's steps after the ladder has run, split by the sensor that counted.
class ResolvedDaySteps {
  const ResolvedDaySteps({
    this.strap = 0,
    this.phone = 0,
    this.spans = const [],
  });

  /// Steps credited to the band's 100 Hz pedometer.
  final int strap;

  /// Steps credited to the phone's pedometer.
  final int phone;

  /// The spans AS CREDITED, in time order — never the raw table rows.
  ///
  /// A screen that draws the day's spans has to draw these: a raw row still
  /// carries the steps the ladder took back off it, so a strap session inside a
  /// phone-covered hour would be drawn twice, showing the user a walk the total
  /// (correctly) only counts once. Spans credited nothing are dropped for the
  /// same reason.
  ///
  /// Each span is rounded on its own, so re-summing this list can differ from
  /// [total] by a step or two. [total] is the number to publish.
  final List<CoverageSpan> spans;

  int get total => strap + phone;

  /// The sensor that counted most of the day, or null when nothing counted.
  /// Ties go to the strap — it is the higher-ranked sensor.
  String? get dominant =>
      total <= 0 ? null : (strap >= phone ? 'strap' : 'phone');

  bool get mixed => strap > 0 && phone > 0;

  static const none = ResolvedDaySteps();
}

class _Ranked {
  _Ranked(this.startTs, this.endTs, this.steps, this.rank, this.fromBand,
      this.deviceId);
  final int startTs, endTs, rank;
  final double steps;
  final bool fromBand;
  final String deviceId;
  double credited = 0;
}

/// Resolve one day's coverage rows into a per-sensor step split.
///
/// Order of business, per the ladder note above: rank each span, then walk them
/// highest first, subtracting from each what the higher-ranked spans already
/// counted over shared time.
///
/// A single-source day is unchanged by all of this — every span keeps its full
/// count and the total is the plain sum, exactly as before.
// ponytail: O(n²) over one day's rows (tens, typically single digits). If a day
// ever carries thousands, sort by start and sweep instead.
ResolvedDaySteps resolveDaySteps(Iterable<CoverageSpan> rows) {
  final spans = <_Ranked>[];
  for (final r in _vetoAgainstConfirmedStill(rows.toList())) {
    // Legacy zero-width rows are real counts with a lost extent; repair them
    // the same way the writer does rather than dropping a measurement.
    final w = sanitizeCoverageWindow(r.startTs, r.endTs, r.steps);
    if (w == null) continue;
    final spm = r.steps * 60 / (w.endTs - w.startTs);
    // 2 = band that looks like gait, 1 = phone, 0 = band that does not.
    final rank = r.fromBand ? (spm >= kBandSpanMinSpm ? 2 : 0) : 1;
    spans.add(
      _Ranked(w.startTs, w.endTs, r.steps.toDouble(), rank, r.fromBand,
          r.deviceId),
    );
  }
  // Rank first, then start time — `List.sort` is NOT stable in Dart, and once
  // equal-ranked spans from different devices compete (below) the winner is
  // whichever is resolved first, so the tie needs a rule of its own or the
  // day's total depends on the order SQLite happened to return the rows in.
  // Earliest span wins; it is arbitrary but it is the same arbitrary answer
  // every run, which is what a re-derive needs — and that only holds if the
  // keys reach a TOTAL order. Two devices can share rank AND start, so end and
  // then `deviceId` finish it; without them the claim above was still an
  // unstable sort's answer. Same-device ties need no rule: equal rank within
  // one device is summed, not competed (see the loop below).
  spans.sort((a, b) {
    if (b.rank != a.rank) return b.rank.compareTo(a.rank);
    if (a.startTs != b.startTs) return a.startTs.compareTo(b.startTs);
    if (a.endTs != b.endTs) return a.endTs.compareTo(b.endTs);
    return a.deviceId.compareTo(b.deviceId);
  });

  var strap = 0.0;
  var phone = 0.0;
  for (var i = 0; i < spans.length; i++) {
    final s = spans[i];
    var alreadyCounted = 0.0;
    for (var j = 0; j < i; j++) {
      final h = spans[j];
      // EQUAL RANK IS NOT COMPETITION *WITHIN ONE DEVICE*. Two band rows, or
      // two phone rows, from the SAME `device_id` are the same sensor reporting
      // twice and are summed — which is what the table has always meant and
      // what re-import idempotency relies on.
      //
      // Two DIFFERENT devices are not that. Rank is a property of the SPAN
      // (band-that-looks-like-gait / phone / band-that-does-not), so two straps
      // on the same 3,000-step walk both rank 2, skipped each other here, and
      // the day published 6,000. Different id ⇒ they compete like any other
      // pair, and the tie is broken by start time (see the sort above).
      if (h.rank <= s.rank && h.deviceId == s.deviceId) continue;
      final ov = math.min(s.endTs, h.endTs) - math.max(s.startTs, h.startTs);
      if (ov <= 0) continue;
      alreadyCounted += h.credited * ov / (h.endTs - h.startTs);
    }
    s.credited = math.max(0.0, s.steps - alreadyCounted);
    if (s.fromBand) {
      strap += s.credited;
    } else {
      phone += s.credited;
    }
  }
  return ResolvedDaySteps(
    strap: strap.round(),
    phone: phone.round(),
    spans: [
      for (final s in spans)
        if (s.credited.round() > 0)
          CoverageSpan(
            startTs: s.startTs,
            endTs: s.endTs,
            steps: s.credited.round(),
            fromBand: s.fromBand,
            deviceId: s.deviceId,
          ),
    ]..sort((a, b) => a.startTs.compareTo(b.startTs)),
  );
}

/// Persistence-boundary guard: normalise a window before it reaches the
/// `live_coverage` table, or null when it must not be stored at all.
///
/// This is defence in depth behind [deriveLiveCoverageWindow] — an upstream
/// regression that stops advancing its clock must not be able to write a
/// zero-width window again without being repaired here.
///
/// REPAIR, NOT REJECT. Dropping the row would throw away a REAL 100 Hz step
/// count (the one measurement on the day that is not an estimate) and hand
/// those minutes back to the 1 Hz estimator. Widening the window to the
/// physically implied minimum ([minCoverageSecondsForSteps]) keeps the steps,
/// restores a non-degenerate exclusion, and claims only what a bound supports.
/// The one case that IS rejected is an inverted window (`endTs < startTs`):
/// that is incoherent rather than merely imprecise, and there is no defensible
/// way to decide which end was meant.
LiveCoverageWindow? sanitizeCoverageWindow(int startTs, int endTs, int steps) {
  if (steps <= 0) return null;
  if (endTs < startTs) return null;
  final minS = math.max(1, minCoverageSecondsForSteps(steps));
  if (endTs - startTs < minS) return LiveCoverageWindow(startTs, startTs + minS);
  return LiveCoverageWindow(startTs, endTs);
}
