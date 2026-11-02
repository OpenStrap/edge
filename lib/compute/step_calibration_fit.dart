// step_calibration_fit.dart — pure policy for calibrating the strap's LIVE
// 100 Hz pedometer per user and per activity category.
//
// WHERE THE COUNTER LIVES. Not here. The counter is `pedometer()` /
// `livePedometer()` in analytics (`onehz/motion/steps.dart`), fed from the live
// IMU stream `edge` already ingests (`frameAccel`: gen5 0x2B, gen4 0x33 / R10)
// and banked as `live_coverage.source = 'strap_100hz'`. This file only turns a
// calibration routine into numbers that counter is configured with. Nothing
// here touches BLE or the strap: every value stays on the phone, so there is
// nothing a factory reset has to undo.
//
// WHY A CALIBRATION AT ALL. Analytics' own `StepParams.gain` docstring asks for
// it: "A real strap on a real wrist may still need trimming — that is what this
// knob is for. Measure it against ground truth, per user, and store it with the
// user; never bake a population constant back in here." On clean synthetic gait
// the raw count is already exact (raw/truth 1.00 from 60 to 180 spm), so a gain
// corrects the RESIDUAL a real wrist adds. Expect values near 1.0 for gait, and
// never a population constant.
//
// ── TWO CATEGORY FAMILIES, ONE MECHANISM ────────────────────────────────────
//
// Everything below is a SCALE — `gain = truth / raw` — because the wearer
// determined the truth. What differs between the families is the REFERENCE and
// the RANGE, not the maths:
//
//   * GAIT (slow / brisk / jog): the wearer counts their own steps during the
//     calibration walk. `expectedSteps` is that count, and the gain lands near
//     1.0 because the detector is already close on real gait.
//
//   * EVERYDAY (household: carrying, lifting, moving things around a room): the
//     reference is the PHONE's own pedometer over the same span, because nobody
//     can count steps while doing chores. The gain here lands LOW, and that is
//     the point — at the wrist, ordinary arm work out-accelerates walking
//     (stirring ~104 mg, chopping ~139 mg vs walking ~66 mg ENMO), which is why
//     wrist devices emit 22-27 false steps/min during dishes, reaching and
//     driving (O'Connell 2017). A household routine produces mostly false
//     peaks, so the honest correction is a large downward scale.
//
// WHY NOT ZERO. A household routine is not zero steps — the wearer really does
// walk to the next room. Rejecting the window outright would delete those real
// steps, and it would do so precisely where the wearer asked for a number. So
// the everyday gain is floored at [kEverydayGainMin], never 0, and a routine
// that produced no phone-counted steps at all is REFUSED as a calibration run
// (there is then no reference to fit, which is different from a measured zero).
//
// WHY NOT ONE GLOBAL GAIN. The codebase already settled this: "The two errors
// have OPPOSITE sign, so no gain constant corrects both" — the wrist
// over-counts arm work and under-counts slow walking. Splitting the correction
// by cadence family is the whole reason this file exists rather than one number.
//
// DRIVING IS NOT THIS FILE'S JOB. `lib/data/live_coverage_policy.dart` already
// owns it: a phone row confirming a MOTIONLESS hour drops the band credit
// overlapping it, unless the band span's own density already looks like gait
// ([kConfirmedStillMinSpm] = 40 spm, set above the measured 22-27 spm
// false-positive ceiling and below real walking). The everyday gain is a
// backstop on top of that rule, not a replacement.
//
// HONEST LIMIT. Analytics states its own ceiling: "Every independent free-living
// wrist evaluation puts peak detection between 60% and 230% error." Nothing here
// lifts that. It trims a measured bias per wearer and per movement family. It
// does not turn a wrist into a pedometer, and no copy built on this may say it
// did.
//
// PURE Dart — no I/O, no clock, no protocol import, plain values in and out.

/// The four calibration categories. The first three are gait; `everyday` is the
/// household family and is fitted against the phone. See the file header.
enum StepCategory {
  slow,
  brisk,
  jog,
  everyday;

  /// Stable storage key. Persisted values are matched by NAME, so a reordered
  /// enum cannot silently reattach a stored gain to another category.
  String get key => switch (this) {
        StepCategory.slow => 'slow',
        StepCategory.brisk => 'brisk',
        StepCategory.jog => 'jog',
        StepCategory.everyday => 'everyday',
      };

  /// Null for an unknown key; never a silent fallback to a real category.
  static StepCategory? parse(Object? v) => switch (v) {
        'slow' => StepCategory.slow,
        'brisk' => StepCategory.brisk,
        'jog' => StepCategory.jog,
        'everyday' => StepCategory.everyday,
        _ => null,
      };

  /// True for the three foot-locomotion families. `everyday` is NOT gait, but
  /// it is still a scale — see the file header for why it is not a rejection.
  bool get isGait => this != StepCategory.everyday;

  /// The reference a run of this category is fitted against, for the UI to
  /// state plainly rather than implying the wearer counts in both cases.
  bool get referenceIsPhone => this == StepCategory.everyday;
}

/// Where a run's ground truth came from.
enum StepReference {
  /// The wearer counted their own steps during the calibration walk.
  wearerCount,

  /// The phone's own pedometer over the same span. The only usable reference
  /// while doing chores, and a better sensor for this quantity than the wrist —
  /// see `lib/health/phone_pedometer.dart`.
  phonePedometer,
}

/// One supervised calibration run: a routine was performed, the strap's counter
/// saw what it saw, and something independent says how many steps were real.
class StepCalibrationRun {
  const StepCalibrationRun({
    required this.category,
    required this.reference,
    required this.expectedSteps,
    required this.rawSteps,
    required this.cadenceSpm,
    required this.peakToPeakG,
    required this.confidence,
  });

  final StepCategory category;
  final StepReference reference;

  /// Ground truth for this span: the wearer's own count for the gait families,
  /// the phone's pedometer for `everyday`. Never an estimate we invented.
  final int expectedSteps;

  /// `PedometerResult.steps` over the same span — the strap's raw count.
  final int rawSteps;

  /// `PedometerResult.cadenceSpm` over the run's span.
  final double cadenceSpm;

  /// `PedometerResult.peakToPeakG` — median stride amplitude, the motion
  /// strength. Carrying and lifting push this above a walk's.
  ///
  /// NULLABLE BECAUSE IT IS OPTIONAL, NOT BECAUSE 0 IS MEANINGFUL. Nothing in
  /// the fit reads it today; it is stored so the wearer can be shown WHY a
  /// routine looked the way it did. A routine whose caller never measured it
  /// stores NULL, and 0.0 would be a fabricated reading — a real still reading
  /// is 0, so a made-up zero would be indistinguishable from a measurement at
  /// exactly the end of the scale where the discriminator matters.
  final double? peakToPeakG;

  /// `PedometerResult.confidence` — amplitude AND rhythm regularity, 0..1.
  /// Nullable for the same reason as [peakToPeakG].
  final double? confidence;
}

/// A run smaller than this cannot carry a ratio: the noise in a 40-step walk's
/// count is larger than the bias it is meant to measure.
const int kStepCalMinExpectedSteps = 50;

/// The detector claiming almost nothing over a supervised routine is evidence
/// the run failed (band not worn, stream dropped), not a measurement of a 20x
/// gain.
const int kStepCalMinRawSteps = 20;

/// Range a GAIT gain may take. Outside it the RUN went wrong, not the counter.
const double kGaitGainMin = 0.5;
const double kGaitGainMax = 2.0;

/// Range an EVERYDAY gain may take, and it is a different axis on purpose.
///
/// The floor is deliberately far below [kGaitGainMin] because a large downward
/// correction is the EXPECTED outcome here, and it is clamped above zero because
/// a household routine contains real steps: the wearer does walk to the next
/// room, and a hard zero would delete those. The ceiling is 1.0 — an everyday
/// gain above 1.0 would claim the wrist UNDER-counts arm work, which contradicts
/// the measured 22-27 false steps/min and would be a licence to inflate.
const double kEverydayGainMin = 0.05;
const double kEverydayGainMax = 1.0;

/// Bump when the fit changes so stored profiles are ignored rather than
/// misread. Distinct namespace from `kStepCalibrationVersion` in
/// `lib/data/step_calibration.dart` (the band counter's factor) — two different
/// models must never be able to overwrite each other's stored value.
///
/// 101: moved with [kLiveStepCounterVersion] 2. A profile fitted from runs the
/// old counter scored describes that counter's residual, not this one's.
const int kLiveStepGainVersion = 101;

/// Which `pedometer()` produced a run's `rawSteps`. Bump whenever analytics
/// changes the counter's output.
///
/// A gain is `truth / raw`, so it is only meaningful for the counter that
/// produced `raw`. When the counter changes, every stored run's `rawSteps` is a
/// count this build no longer makes, and refitting from those rows would apply
/// the old counter's correction to the new counter's steps. Stored runs carry
/// this tag, and a run with any other tag (or none, from before tagging
/// existed) is not evidence: it is ignored on read and cleared on open, so the
/// wearer recalibrates against the counter they actually have.
///
///   1 — the original autocorrelation counter (implied by an untagged row).
///   2 — analytics' rewritten counter (dead-zone + run gate, scored on OxWalk).
const int kLiveStepCounterVersion = 2;

/// Cadence search window for a GAIT category band, as a fraction of the fitted
/// centre. Wide enough to absorb stride variation inside one category, narrow
/// enough that neighbouring categories do not overlap.
const double kCategoryBandSpread = 0.20;

/// Hard floor on band width (spm). A short run's median is not precise enough to
/// define a 2 spm window, and a band narrower than the wearer's own stride
/// variation would reject their real walking.
const double kCategoryBandMinWidthSpm = 20.0;

/// The cadence band that identifies gait in this codebase, in spm.
///
/// THESE MUST EQUAL `kMinCadenceSpm` / `kMaxCadenceSpm` in
/// `lib/ble/live_cadence.dart` — the same band `livePedometer` treats as
/// confident gait. Two definitions of "this minute was walking" would let the
/// calibration build a band the session logic disagrees with, which is the
/// drift class `step_cadence.dart` was created to prevent on the windows→minutes
/// side.
///
/// They are redeclared rather than imported because this file is deliberately
/// dependency-free (pure, no analytics, no I/O), and pinned by a test that
/// asserts equality in both directions — the same DERIVED-OR-PINNED convention
/// `live_step_runs.dart` uses for `kRouteTypeKeys`. A silent drift is then
/// impossible; a deliberate change fails a test.
///
/// NOT AN-2554's 0.5-5 steps/s (30-300 spm). That is the interval bound the
/// COUNTER accepts — the widest range a human gait interval may have — and it is
/// not the narrower band that identifies a minute as ambulation. A 40 spm
/// "minute" is a few steps to the kettle, which `live_cadence.dart` states
/// outright: "A minute below this is not sustained walking."
const double kGaitCadenceMinSpm = 60.0;
const double kGaitCadenceMaxSpm = 200.0;

/// Why a run was refused. Every rejection is a claim about the RUN, and the
/// caller must show it rather than silently discarding a routine the wearer just
/// performed.
enum StepRunRejection {
  expectedTooSmall,
  rawTooSmall,
  nonFiniteFeature,
  rawExceedsExpectedByTooMuch,
  referenceWrongSource,

  /// An `everyday` run whose reference counted no steps at all. That is not a
  /// measured zero to scale toward — it is the absence of a reference (the phone
  /// was on a table), and fitting a 0.0 gain from it would delete every real
  /// step in every later household window.
  noReferenceSteps,

  /// The ratio this run implies falls outside the category's gain range.
  ///
  /// A run is REFUSED here rather than clamped into range. Clamping a single
  /// run silently converts "this routine did not measure what it claims" into a
  /// value at the edge of the legal band — the exact shape of a fabricated
  /// metric. A wearer who taps Done after a third of their walk produces
  /// expected 100 against raw 30, i.e. a gain of 3.3; clamped to 2.0 that would
  /// DOUBLE every later step they take. The clamp stays in [fittedGain] as
  /// defence for stored or imported rows, but no run may reach it from here.
  ratioOutsideGainRange,

  /// A TIMED routine that did not run for its full duration. The household
  /// family has no step target to fall short of, so this is its equivalent —
  /// and `stepRunRejection` cannot carry it, because a run does not know how
  /// long its routine was asked to be. [CalibrationSession.finish] raises it.
  routineTooShort,

  /// A gait routine whose band cadence is outside the walking range
  /// ([kGaitCadenceMinSpm]..[kGaitCadenceMaxSpm]). [categoryBand] ignores such
  /// a run, so saving it would count toward the fit without ever giving the
  /// family a band to own its walks.
  cadenceOutsideGaitRange,
}

/// Null when the run may be used to fit; otherwise why it may not.
StepRunRejection? stepRunRejection(StepCalibrationRun r) {
  if (!r.cadenceSpm.isFinite) return StepRunRejection.nonFiniteFeature;
  // Absent is fine; PRESENT-BUT-NOT-A-NUMBER is not. A NaN that reaches the fit
  // would poison every later run's ratio, so it is refused here rather than
  // filtered silently downstream.
  final p2p = r.peakToPeakG;
  if (p2p != null && !p2p.isFinite) {
    return StepRunRejection.nonFiniteFeature;
  }
  final conf = r.confidence;
  if (conf != null && !conf.isFinite) {
    return StepRunRejection.nonFiniteFeature;
  }
  if (r.category.referenceIsPhone != (r.reference == StepReference.phonePedometer)) {
    return StepRunRejection.referenceWrongSource;
  }
  if (r.rawSteps < kStepCalMinRawSteps) return StepRunRejection.rawTooSmall;

  if (r.category.isGait) {
    if (r.expectedSteps < kStepCalMinExpectedSteps) {
      return StepRunRejection.expectedTooSmall;
    }
    // `raw / expected` is clamped to kGaitGainMax, so a walk beyond the clamp is
    // no longer a measurement of the gain.
    if (r.rawSteps > (r.expectedSteps * kGaitGainMax).ceil()) {
      return StepRunRejection.rawExceedsExpectedByTooMuch;
    }
    if (r.cadenceSpm < kGaitCadenceMinSpm || r.cadenceSpm > kGaitCadenceMaxSpm) {
      return StepRunRejection.cadenceOutsideGaitRange;
    }
    return _ratioAdmissible(r);
  }

  // EVERYDAY. The band is EXPECTED to see far more than the phone — that is the
  // over-count being measured — so the gait floor and ceiling both invert:
  // a reference of 0 is refused (no reference), and the truth must not exceed
  // what the band saw (that would be an under-count, the opposite family).
  if (r.expectedSteps <= 0) return StepRunRejection.noReferenceSteps;
  if (r.expectedSteps > r.rawSteps) {
    return StepRunRejection.rawExceedsExpectedByTooMuch;
  }
  return _ratioAdmissible(r);
}

/// The gain this run implies must lie inside the category's own range.
///
/// Split out so both families cannot drift apart: the check is identical, only
/// the range differs, and the range already lives in [gainFloor]/[gainCeiling].
/// This is what turns "the fit would have clamped it" into "the run is refused",
/// and it is the only guard against a routine that stopped early — the app can
/// never know how many steps the wearer really took, but it CAN know that the
/// count it saw is not consistent with the walk that was asked for.
StepRunRejection? _ratioAdmissible(StepCalibrationRun r) {
  if (r.rawSteps <= 0) return StepRunRejection.rawTooSmall;
  final ratio = r.expectedSteps / r.rawSteps;
  if (ratio < gainFloor(r.category) || ratio > gainCeiling(r.category)) {
    return StepRunRejection.ratioOutsideGainRange;
  }
  return null;
}

/// A fitted per-user, per-category correction for the live 100 Hz pedometer.
class LiveStepGainProfile {
  const LiveStepGainProfile({
    required this.version,
    required this.category,
    required this.gain,
    required this.nRuns,
    required this.updatedAt,
  });

  final int version;
  final StepCategory category;

  /// Clamped to the category's own range: [kGaitGainMin]..[kGaitGainMax] for
  /// gait, [kEverydayGainMin]..[kEverydayGainMax] for everyday. Exactly 1.0 when
  /// nothing was learned — and 1.0 is not "unset", it is the shipped behaviour,
  /// which is why an uncalibrated category and a fitted 1.0 behave identically.
  final double gain;

  /// Admitted runs behind [gain]; 0 = no calibration, use the default.
  final int nRuns;
  final DateTime updatedAt;

  /// A category is calibrated as soon as one admitted run exists — the reference
  /// is either the wearer's own count or a vendor pedometer, not an inference.
  bool get isCalibrated => nRuns > 0;

  /// The profile every uncalibrated category resolves to. `gain` 1.0 is what
  /// analytics ships as its default.
  static LiveStepGainProfile uncalibrated(StepCategory category, DateTime? now) =>
      LiveStepGainProfile(
        version: kLiveStepGainVersion,
        category: category,
        gain: 1.0,
        nRuns: 0,
        updatedAt: now ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        'cat': category.key,
        'gain': gain,
        'n': nRuns,
        'ts': updatedAt.toIso8601String(),
      };

  /// Defensive: a stored profile is user data that may predate a field, and a
  /// malformed one must yield null (fall back to default behaviour) rather than
  /// throw inside the derive path or, worse, load as a fabricated gain.
  static LiveStepGainProfile? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final category = StepCategory.parse(raw['cat']);
    if (category == null) return null;
    if (raw['v'] != kLiveStepGainVersion) return null;
    final gain = raw['gain'];
    if (gain is! num || !gain.isFinite) return null;
    final lo = gainFloor(category);
    final hi = gainCeiling(category);
    if (gain < lo || gain > hi) return null;
    final nRuns = raw['n'];
    if (nRuns is! int || nRuns < 0) return null;
    final ts = raw['ts'];
    final updatedAt = ts is String ? DateTime.tryParse(ts) : null;
    if (updatedAt == null) return null;
    return LiveStepGainProfile(
      version: kLiveStepGainVersion,
      category: category,
      gain: gain.toDouble(),
      nRuns: nRuns,
      updatedAt: updatedAt,
    );
  }
}

/// Lowest gain the category may hold. `everyday` is allowed far below 1.0
/// because a large downward correction is its expected outcome — see the file
/// header for why it is nonetheless never 0.
double gainFloor(StepCategory category) =>
    category.isGait ? kGaitGainMin : kEverydayGainMin;

/// Highest gain the category may hold.
double gainCeiling(StepCategory category) =>
    category.isGait ? kGaitGainMax : kEverydayGainMax;

/// The fitted gain and its evidence, or null when the category has no admitted
/// run. Split out so [creditLiveSteps] can apply a correction without inventing
/// a timestamp to wrap in a profile.
({double gain, int nRuns})? fittedGain(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
  final admitted = [
    for (final r in runs)
      if (r.category == category && stepRunRejection(r) == null) r,
  ];
  if (admitted.isEmpty) return null;

  final expected = admitted.fold<int>(0, (a, r) => a + r.expectedSteps);
  final raw = admitted.fold<int>(0, (a, r) => a + r.rawSteps);
  if (raw <= 0 || expected <= 0) return null;

  // Ratio of SUMS, not the mean of per-run ratios: each run is weighted by the
  // evidence it carries, so a 500-step walk is not cancelled out by a 60-step
  // one. Repeated runs then refine the estimate for free.
  //
  // NO PRIOR WEIGHT, deliberately deviating from `lib/data/step_calibration.dart`
  // (which blends three pseudo-days of factor 1.0). That prior guards an
  // INFERRED reference — a day counts only when the phone happened to be
  // alongside. This fit's reference is either the wearer's own supervised count
  // or the phone's pedometer over the SAME span. Admissibility and the clamp
  // already bound a bad run, and the prior cost more than it bought: blending
  // three pseudo-runs of 1.0 meant a first 100-said/110-seen calibration
  // resolved to 0.977 and corrected a fifth of the bias just measured. A wearer
  // who walks their calibration walk and sees nothing change has been told the
  // feature does not work.
  final ratio = expected / raw;
  return (
    // `.toDouble()` is a NO-OP if Dart's static special case for `clamp` applies
    // here (receiver and both bounds `double` ⇒ `double`), and it is REQUIRED if
    // it does not. The shipped `lib/data/step_calibration.dart:122` returns
    // `corrected.clamp(0, int)` straight out of an `int` function with no cast,
    // which only compiles if the special case exists — so I believe this is a
    // false positive. But the conversion costs nothing, the risk it removes is a
    // build failure in a toolchain no check here can run, and neither reading
    // argues against being explicit.
    gain: ratio.clamp(gainFloor(category), gainCeiling(category)).toDouble(),
    nRuns: admitted.length,
  );
}

/// Fit one category's gain. The `now` parameter exists only so the stored
/// `updatedAt` is supplied by the caller, keeping this function clock-free.
LiveStepGainProfile estimateLiveStepGain(
  StepCategory category,
  List<StepCalibrationRun> runs, {
  required DateTime now,
}) {
  final fit = fittedGain(category, runs);
  if (fit == null) return LiveStepGainProfile.uncalibrated(category, now);
  return LiveStepGainProfile(
    version: kLiveStepGainVersion,
    category: category,
    gain: fit.gain,
    nRuns: fit.nRuns,
    updatedAt: now,
  );
}

/// A cadence window a calibrated GAIT category owns.
class StepCategoryBand {
  const StepCategoryBand({
    required this.category,
    required this.minSpm,
    required this.maxSpm,
  });

  final StepCategory category;
  final double minSpm;
  final double maxSpm;

  bool contains(double spm) => spm >= minSpm && spm <= maxSpm;
}

/// Band for one gait category from its admitted runs: median cadence, opened by
/// [kCategoryBandSpread] and floored at [kCategoryBandMinWidthSpm].
///
/// The median, not the mean: one run walked at a wrong tempo must not drag the
/// window off the wearer's real cadence. Null for `everyday` (which has no gait
/// band by definition) and for an uncalibrated category.
StepCategoryBand? categoryBand(
  StepCategory category,
  List<StepCalibrationRun> runs,
) {
  if (!category.isGait) return null;
  final cadences = [
    for (final r in runs)
      if (r.category == category &&
          stepRunRejection(r) == null &&
          // A run whose own cadence sits outside the gait band did not walk what
          // this band is meant to describe. Letting it define the band would
          // widen or shift the window onto cadences no gait minute occupies.
          r.cadenceSpm >= kGaitCadenceMinSpm &&
          r.cadenceSpm <= kGaitCadenceMaxSpm)
        r.cadenceSpm,
  ]..sort();
  if (cadences.isEmpty) return null;

  final n = cadences.length;
  final median =
      n.isOdd ? cadences[n ~/ 2] : (cadences[n ~/ 2 - 1] + cadences[n ~/ 2]) / 2;
  final half = (median * kCategoryBandSpread)
      .clamp(kCategoryBandMinWidthSpm / 2, kGaitCadenceMaxSpm)
      .toDouble();
  var lo = median - half;
  var hi = median + half;
  // Clamp to human gait without letting the clamp collapse the band.
  if (lo < kGaitCadenceMinSpm) {
    hi += kGaitCadenceMinSpm - lo;
    lo = kGaitCadenceMinSpm;
  }
  if (hi > kGaitCadenceMaxSpm) {
    lo -= hi - kGaitCadenceMaxSpm;
    hi = kGaitCadenceMaxSpm;
  }
  return StepCategoryBand(
    category: category,
    minSpm: lo < kGaitCadenceMinSpm ? kGaitCadenceMinSpm : lo,
    maxSpm: hi > kGaitCadenceMaxSpm ? kGaitCadenceMaxSpm : hi,
  );
}

/// Which calibrated GAIT category owns a live window's cadence.
///
/// Nearest band centre among the calibrated gait categories, but only when the
/// cadence actually lands inside that band. A window between two bands, or
/// outside every calibrated band, belongs to NO gait category — it falls
/// through to the everyday gain rather than being forced into the nearest gait
/// band, because forcing it would apply a correction measured on a different
/// kind of movement.
StepCategory? gaitCategoryForCadence(
  double spm,
  List<StepCalibrationRun> runs,
) {
  if (!spm.isFinite || spm <= 0) return null;
  StepCategory? best;
  var bestDistance = double.infinity;
  for (final c in StepCategory.values) {
    final band = categoryBand(c, runs);
    if (band == null || !band.contains(spm)) continue;
    final distance = (spm - (band.minSpm + band.maxSpm) / 2).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = c;
    }
  }
  return best;
}

/// What a live window's raw count is finally credited as.
class StepCredit {
  const StepCredit({
    required this.creditedSteps,
    required this.rawSteps,
    required this.category,
    required this.gainApplied,
    required this.calibrated,
  });

  final int creditedSteps;
  final int rawSteps;

  /// The family the correction came from. Null only when nothing was applied.
  final StepCategory? category;

  /// The gain actually used — 1.0 when nothing was calibrated, so a caller can
  /// log "no correction applied" without a second lookup.
  final double gainApplied;

  /// False when the wearer has not calibrated this family: the window is
  /// credited EXACTLY as it is today. The feature must be invisible until the
  /// wearer has calibrated.
  final bool calibrated;
}

/// Apply the calibration to one live window.
///
/// The mapping is the whole policy:
///   1. a window whose cadence falls in a calibrated gait band uses that band's
///      gain (slow / brisk / jog);
///   2. every other window — including household arm work, which has no gait
///      cadence at all — uses the everyday gain;
///   3. anything uncalibrated is credited exactly as today, raw with gain 1.0.
///
/// Driving is NOT handled here. `lib/data/live_coverage_policy.dart` already
/// drops band credit that overlaps a phone-confirmed motionless hour unless the
/// span's own density looks like gait; the everyday gain only damps what
/// survives that rule.
StepCredit creditLiveSteps({
  required int rawSteps,
  required double cadenceSpm,
  required List<StepCalibrationRun> runs,
}) {
  if (rawSteps <= 0) {
    return StepCredit(
      creditedSteps: 0,
      rawSteps: rawSteps < 0 ? 0 : rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }

  final gait = gaitCategoryForCadence(cadenceSpm, runs);

  // A cadence INSIDE the gait band that no calibrated family owns is a walk the
  // wearer has not calibrated — so it is credited EXACTLY as it is today.
  //
  // It must not fall through to the household gain. An earlier version did, on
  // the reasoning that a household gain is capped at 1.0 and so "can only damp".
  // Damping is not harmless: a wearer who calibrates only the household routine
  // would then have every real walk scaled to 5-14% of what the band counted,
  // which is a far worse error than the over-count the calibration exists to
  // fix. "Uncalibrated changes nothing" has to hold for the walk too.
  final inGaitBand =
      cadenceSpm >= kGaitCadenceMinSpm && cadenceSpm <= kGaitCadenceMaxSpm;
  if (gait == null && inGaitBand) {
    return StepCredit(
      creditedSteps: rawSteps,
      rawSteps: rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }

  // Below the gait band there is no ambulation to protect — that is the space
  // the household family owns, and live_cadence.dart defines it as "a few steps
  // to the kettle inside an otherwise still minute" rather than walking. The
  // cost is written down rather than hidden: a genuine walk slower than
  // kGaitCadenceMinSpm is damped with the household movement, and the answer is
  // to calibrate the `slow` family, whose band would then own those minutes.
  final family = gait ?? StepCategory.everyday;

  final fit = fittedGain(family, runs);
  if (fit == null) {
    return StepCredit(
      creditedSteps: rawSteps,
      rawSteps: rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }

  final credited = (rawSteps * fit.gain).round();
  // A gain below 1.0 must not be able to manufacture steps, and none may be
  // negative: the clamp mirrors `applyStepCalibration`'s.
  return StepCredit(
    creditedSteps:
        credited.clamp(0, (rawSteps * kGaitGainMax).ceil()).toInt(),
    rawSteps: rawSteps,
    category: family,
    gainApplied: fit.gain,
    calibrated: true,
  );
}

/// Credit one BANKED live run: the cadence is the run's own raw count over its
/// own sampled span, which is how `lib/ble/live_cadence.dart` already defines a
/// cadence ("a completed chunk is one minute, so its step count IS a
/// steps-per-minute reading").
///
/// The RAW count is what picks the category and the gain is applied once at the
/// end — the same "gate first, gain last" rule `live_cadence.dart` documents,
/// and for the same reason: a gain applied before the cadence test would stretch
/// the band by whatever the gain is.
StepCredit creditLiveRun({
  required int rawSteps,
  required int seconds,
  required List<StepCalibrationRun> runs,
}) {
  if (seconds <= 0) {
    // No measurable span, so no cadence, so no basis for a category. Leave the
    // count alone rather than letting it fall through to the everyday family,
    // which would damp a run we merely failed to measure.
    return StepCredit(
      creditedSteps: rawSteps < 0 ? 0 : rawSteps,
      rawSteps: rawSteps < 0 ? 0 : rawSteps,
      category: null,
      gainApplied: 1.0,
      calibrated: false,
    );
  }
  return creditLiveSteps(
    rawSteps: rawSteps,
    cadenceSpm: rawSteps * 60.0 / seconds,
    runs: runs,
  );
}

/// THE single entry point for the persistence path: what a banked run is worth.
///
/// [fallbackGain] is `ana.StepParams.gain`, the shipped trim, and it is used
/// ONLY when the wearer has calibrated nothing — so an uncalibrated app banks
/// exactly the numbers it banks today, to the digit.
///
/// When a family IS calibrated the calibrated gain REPLACES the shipped one
/// rather than multiplying into it. That distinction is not cosmetic:
/// `app_state.dart` records that applying the gain at both ends of this path
/// once "shipped a silent x1.23". There is exactly one factor per run.
int creditedStepsForRun({
  required int rawSteps,
  required int seconds,
  required List<StepCalibrationRun> runs,
  required double fallbackGain,
}) {
  final credit = creditLiveRun(rawSteps: rawSteps, seconds: seconds, runs: runs);
  if (!credit.calibrated) return (rawSteps * fallbackGain).round();
  return credit.creditedSteps;
}

/// How many steps a gait calibration asks the WEARER to count.
///
/// 100 is the smallest round number where the counting error stays well under
/// the bias being measured, and short enough that the routine still gets done.
const int kCalibrationTargetSteps = 100;

/// How long a household routine runs. Long enough that the phone's own pedometer
/// accumulates a meaningful count from the walking inside it, and that the
/// band's arm-work peaks accumulate enough to measure.
const int kCalibrationTargetSeconds = 180;

/// One calibration routine in progress: what the wearer does, what the strap
/// counts, and what independent reference backs it.
///
/// WHY THE LIVE BAND COUNT MAY NOT TERMINATE A GAIT RUN.
///
/// The obvious design is "count the steps as the wearer walks and stop at 100".
/// It calibrates nothing: the run would end when the COUNTER reached 100, so
/// [StepCalibrationRun.rawSteps] would be 100 by construction and every fitted
/// gain would be exactly 1.0 for every wearer, forever — a number that looks
/// like a calibration and is a tautology. A reference must be independent of the
/// instrument it calibrates. So:
///
///   * GAIT families — the WEARER counts. The band's live count is feedback on
///     the screen ("the band has seen 112 so far"), never the terminator, and
///     the wearer ends the run after counting [targetSteps].
///   * EVERYDAY — the PHONE is the reference, over the routine's own span, so
///     the run is timed ([targetSeconds]) and the phone must be carried.
///
/// The live count is still shown for gait, and the gap between it and the
/// target IS the measurement — 100 walked, 112 seen, gain 0.893. That is the
/// number the wearer came for; hiding it would hide the answer.
///
/// This class holds no clock: the caller supplies elapsed time, so the logic
/// stays testable and nothing here can disagree with a screen's own timer.
class CalibrationSession {
  CalibrationSession({
    required this.category,
    this.targetSteps = kCalibrationTargetSteps,
    this.targetSeconds = kCalibrationTargetSeconds,
  });

  final StepCategory category;

  /// Steps the wearer is asked to count. Gait families only.
  final int targetSteps;

  /// How long to keep a household routine going. Everyday only.
  final int targetSeconds;

  int _bandBaseline = 0;
  int _bandTotal = 0;
  int _startMs = 0;
  int _nowMs = 0;
  bool _started = false;
  int? _phoneSteps;
  double? _peakToPeakG;
  double? _confidence;
  bool _finished = false;

  /// The strap's RAW count for this ROUTINE — `pedometer()`'s count at the
  /// current observation minus the count when the routine began, pre-gain
  /// throughout, and the value that becomes the run's `rawSteps`.
  ///
  /// A DELTA, because a screen can only read the live session's cumulative
  /// counter: what a routine measured is the difference between where that
  /// counter stood at the start and where it stands now.
  int get bandRawSteps => _bandTotal - _bandBaseline;

  /// Seconds the routine's clock covered.
  ///
  /// The routine's OWN wall span, not a sampled span — the screen has no other
  /// clock, and a supervised routine is short and hand-started. A stalled link
  /// does not inflate this into a wrong cadence silently: the live path refuses
  /// to commit a window measuring under `kMinLiveSampleRateHz`, so a stall shows
  /// up as the band count standing still. A cadence that still lands outside
  /// 60-200 spm simply produces no gait band (see [categoryBand]), which costs
  /// the wearer nothing but that band.
  int get bandSeconds =>
      _started && _nowMs > _startMs ? (_nowMs - _startMs) ~/ 1000 : 0;

  /// The phone's count for the routine's window, or null when it has not been
  /// read (everyday refuses without it rather than fitting against nothing).
  int? get phoneSteps => _phoneSteps;

  bool get isFinished => _finished;

  /// Cadence the STRAP reports for the routine, in spm — its own reading, and
  /// the one [categoryBand] will later compare against. 0 until it can be
  /// measured, which is not a cadence.
  double get bandCadenceSpm =>
      bandSeconds <= 0 ? 0.0 : bandRawSteps * 60.0 / bandSeconds;

  /// 0..1 for the progress affordance.
  ///
  /// GAIT measures the BAND's progress, because that is the only progress
  /// anyone can compute live — and it is labelled as the band's count, not as
  /// the wearer's. EVERYDAY measures elapsed time, since it has no step target.
  double get progress {
    if (category.isGait) {
      if (targetSteps <= 0) return 0;
      final p = bandRawSteps / targetSteps;
      return p < 0 ? 0 : (p > 1 ? 1 : p);
    }
    if (targetSeconds <= 0) return 0;
    final p = bandSeconds / targetSeconds;
    return p < 0 ? 0 : (p > 1 ? 1 : p);
  }

  /// Begin the routine. [bandBaseline] is the live session's cumulative raw
  /// counter right now — everything the routine is credited with is measured
  /// from here, so a walk that happened before the wearer pressed start cannot
  /// land in their calibration.
  void start({required int bandBaseline, required int nowMs}) {
    if (_finished || _started) return;
    _started = true;
    _bandBaseline = bandBaseline < 0 ? 0 : bandBaseline;
    _bandTotal = _bandBaseline;
    _startMs = nowMs;
    _nowMs = nowMs;
  }

  /// The live session's cumulative raw counter, as the screen reads it. Never
  /// allowed to go backwards: the counter is reset when a session ends, and a
  /// routine that spans a reconnect must not be credited with a negative
  /// correction.
  void observe({required int bandTotal, required int nowMs}) {
    if (_finished || !_started || _held) return;
    _bandTotal = bandTotal < _bandBaseline ? _bandBaseline : bandTotal;
    if (nowMs > _nowMs) _nowMs = nowMs;
  }

  bool _held = false;

  /// Freeze the routine at the wearer's Done tap: the count and clock as of
  /// [nowMs], ignoring observations while the screen asks what they counted.
  /// Without it a dialog left open for ten seconds is added to the walk, and a
  /// slow but valid routine drops below the gait cadence range.
  void hold({required int bandTotal, required int nowMs}) {
    observe(bandTotal: bandTotal, nowMs: nowMs);
    _held = true;
  }

  /// The wearer cancelled the question and is still walking.
  void resume() => _held = false;

  /// The phone's count for this routine's window. Replaceable, because the
  /// screen re-reads it as the routine runs.
  void setPhoneSteps(int steps) {
    if (_finished) return;
    _phoneSteps = steps < 0 ? 0 : steps;
  }

  /// Drop the phone reference: the routine's final read failed, and an
  /// earlier read covers only part of it.
  void clearPhoneSteps() {
    if (_finished) return;
    _phoneSteps = null;
  }

  /// The live pedometer's own summary for the routine, when the caller has it.
  ///
  /// Stored, not judged: the fit does not read these. They are what lets the
  /// screen tell the wearer "your household movement was measurably less
  /// rhythmic than your walk" from a measurement instead of a guess. Omitted
  /// entirely when the caller never measured them — an absent feature is honest,
  /// a substituted 0.0 is not.
  void setBandFeatures({double? peakToPeakG, double? confidence}) {
    if (_finished) return;
    _peakToPeakG = peakToPeakG;
    _confidence = confidence;
  }



  /// May the wearer end the routine yet?
  ///
  /// A gate on EVIDENCE, not on the target: ending a gait run at zero strap
  /// steps produces a run the admissibility rules refuse anyway, and telling the
  /// wearer that before they press the button is kinder than a refusal after.
  bool get canFinish =>
      _started &&
      bandSeconds > 0 &&
      bandRawSteps > 0 &&
      // The household family has no step target, so its equivalent is the
      // routine's own duration: stopping it a third of the way through measures
      // a third of the movement and would be fitted as if it were all of it.
      (!category.referenceIsPhone || bandSeconds >= targetSeconds);

  /// Finish the routine and produce the run, or the reason there is none.
  ///
  /// Refusals here are about the ROUTINE and are surfaced to the wearer:
  /// "nothing was recorded" is a different message from "the phone was not
  /// carried", and neither is a silent no-op that leaves them believing their
  /// walk taught the app something.
  ///
  /// [countedSteps] is what the wearer says they counted, for a gait routine.
  /// The screen asks rather than assumes [targetSteps]: Done is live from the
  /// first band step, and a wearer who stops at 60 would otherwise be fitted
  /// as if they had walked 100 — a 1.67 gain that the clamps still accept.
  ({StepCalibrationRun? run, StepRunRejection? refusal, bool bandSilent})
      finish({int? countedSteps}) {
    _finished = true;
    if (!_started || bandSeconds <= 0 || bandRawSteps <= 0) {
      // No usable band signal at all. Not a [StepRunRejection] — that enum
      // judges a run that exists, and this one never happened.
      return (run: null, refusal: null, bandSilent: true);
    }
    if (category.referenceIsPhone && bandSeconds < targetSeconds) {
      // Raised HERE, not in [stepRunRejection]: a run does not know how long its
      // routine was asked to last, so that function could not judge this.
      return (
        run: null,
        refusal: StepRunRejection.routineTooShort,
        bandSilent: false,
      );
    }
    final run = StepCalibrationRun(
      category: category,
      reference: category.referenceIsPhone
          ? StepReference.phonePedometer
          : StepReference.wearerCount,
      // GAIT: the wearer's own count, which is the whole point of the routine.
      // EVERYDAY: the phone's count, and 0 when it was never read — which
      // [stepRunRejection] turns into `noReferenceSteps` rather than a fitted
      // 0.0 gain.
      expectedSteps: category.referenceIsPhone
          ? (_phoneSteps ?? 0)
          : (countedSteps ?? targetSteps),
      rawSteps: bandRawSteps,
      cadenceSpm: bandCadenceSpm,
      // Passed THROUGH, never defaulted: null here means the caller did not
      // measure them, which is a different claim from a measured zero.
      peakToPeakG: _peakToPeakG,
      confidence: _confidence,
    );
    return (run: run, refusal: stepRunRejection(run), bandSilent: false);
  }
}
