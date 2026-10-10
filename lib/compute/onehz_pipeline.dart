// onehz_pipeline.dart — the PURE, isolate-safe per-day analytics pipeline (V2).
//
// `deriveDayBundle` is a top-level function with NO DB / IO / Flutter binding
// dependency, so it runs cleanly under `Isolate.run(...)` off the UI isolate.
//
// V2 INVARIANTS enforced here:
//   * SINGLE-SOURCE SLEEP. The day already carries ONE `SleepSegmentation`
//     (from analytics' segmentSleep, computed by the coordinator). Every sleep
//     figure — TST/WASO/efficiency/nrem/rem/wake/hypnogram — comes from THAT one
//     result. We never re-detect sleep or run a second estimator.
//   * WINDOWS ARE FIRST-CLASS. HRV/RHR/recovery run over the SLEEP window only
//     (the fix for the ~166 ms whole-day RMSSD bug). Strain (TRIMP) runs over the
//     WAKE span. Resp/ODI/CPC run over sleep. No metric runs over "the whole
//     capture".
//   * HONEST BY TYPE. Every output keeps the {value,confidence,tier,inputs_used}
//     Metric envelope; absent input → null/"—", never fabricated.
//
// CROSSING THE ISOLATE BOUNDARY (copied, not shared):
//   IN  : a serialized `DayBundleInput` (the day's sliced 1 Hz substrate arrays +
//         the precomputed sleep segmentation + the profile + baseline history).
//   OUT : Map<String,dynamic> (plain JSON) — the full derived bundle, envelopes +
//         the curve series the UI needs + indexed scalars. Survives jsonEncode.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart';

// Pure value helper only — no DB, no IO, no Flutter binding — so importing it
// does not compromise this file's isolate safety. It is here so the sex
// normalisation has ONE definition across the pipeline and the coordinator
// instead of two that can drift.
import 'inputs/garmin_inputs.dart'
    show isWearableFamily, kHrCadenceSec, kOneHzRunGapSec;
import 'hr_max.dart'
    show
        estimatedMaxHr,
        manualZoneBoundsFromProfile,
        smoothedMaxHr,
        smoothedMinHr,
        trainingZones;
import 'profile.dart' show workoutSex;
import 'step_cadence.dart' show cadenceSpmForMinutes;
// Same argument: a pure `DateTime` lookup, no DB / IO / Flutter binding. It is
// the ONE definition of "the UTC offset in effect at this instant" in the tree,
// and a second copy here would be the exact drift SLP-09's timezone guard is
// about.
import 'substrate.dart' show tzOffsetSecondsAt;

const MetricCfg _skinTempAdcCfg = MetricCfg(
  minVal: 1.0,
  maxVal: 65535.0,
  floorSpread: 25.0,
  halfLifeB: 14.0,
  halfLifeS: 21.0,
);

/// MACHINE-READABLE "a required input was missing" note — the same
/// `key:field=value` grammar as `need_baseline:have=H,need=N` (models/metric.dart
/// parses that one) and analytics' `unknown_device_family:id=…`. One grammar,
/// one parser per key; never a second format.
///
/// [name] is the INPUT that was absent, never the metric that wanted it. A
/// screen has to be able to say what to do about it, and "calories" is not an
/// action. [have]/[need] are added when the input is countable and merely short
/// (beats, minutes), so the copy can say how short.
///
/// Deliberately NOT `need_baseline:` — `needMessageFromNote` turns that one into
/// "Need N more nights", which is a lie about a missing profile field or a thin
/// beat series. A key it does not recognise renders as "we do not know", which
/// is the honest floor.
String needInputNote(String name, {num? have, num? need}) =>
    'need_input:name=$name'
    '${have == null || need == null ? '' : ',have=$have,need=$need'}';

/// The note for an absence we cannot attribute. Honest; a plausible guess is
/// not. Anything that renders a reason must be able to reach this.
const String kUnknownAbsenceNote = 'unknown_cause';

/// Physiological cap on the readiness composite z, above which the score is a
/// degenerate-baseline artefact rather than a real reading — so it is abstained
/// from the HEADLINE scalar rather than persisted.
///
/// The composite maps its weighted, sign-oriented z to a 0–100 score via a
/// logistic (`readiness_composite.dart`): `score = 100 / (1 + exp(-z))`. That
/// curve only approaches the 100 rail as z → ∞: a real composite z is a weighted
/// mean of per-input robust-z's, so even a flawless morning (every input at +2 z)
/// lands at z=2 → score 88, and +3 z all-round is z=3 → 95. Reaching z=5
/// (score 99.3) is physiologically unreachable by a genuine reading — it only
/// happens when an input's robust-z explodes because its baseline MAD is tiny.
///
/// robustZ (`util.dart`) returns null only on EXACT-zero MAD (fully-quantised
/// baseline) → the composite abstains and the ring shows a blank '—'. But a
/// baseline that is near-degenerate — e.g. duplicate-day pollution collapsing the
/// window toward one repeated value — has a tiny NON-zero MAD, so robustZ does
/// NOT null: it returns a huge z, the logistic saturates, and the headline flashes
/// ~100 before a cleaner re-derive snaps it back (the ready→ready bounce, #117).
/// Capping at 5 suppresses ONLY that saturated rail and hides zero legitimate
/// scores. This is the belt-and-braces guard; removing the degenerate baselines at
/// source is the sibling `fix/readiness-baseline-pollution` work.
const double kReadinessZCap = 5.0;

/// The weight floor of the PARTIAL readiness composite a wearable's day gets
/// (no beats, so no HRV): resting HR's 0.30 plus skin temperature's 0.10,
/// the two inputs it can measure. A 1 Hz band keeps
/// [readinessCompositeMinWeight].
const double kPartialReadinessMinWeight = 0.4;

/// The headline readiness scalar for a computed [composite], or null when it must
/// abstain: absent composite, or one whose |z| exceeds [kReadinessZCap] (a
/// saturated, degenerate-baseline artefact — see [kReadinessZCap]). Pure so the
/// gate is unit-testable without the full pipeline.
double? headlineReadinessScalar(Metric<Readiness> composite) {
  if (!composite.present) return null;
  final r = composite.value!;
  if (r.compositeZ.abs() > kReadinessZCap) return null;
  return r.score;
}

/// The `readiness_absent_diag` note for a composite that computed (unlike the
/// `!composite.present` cold-start case) but got withheld by [kReadinessZCap]
/// — a saturated, degenerate-baseline artefact. Null whenever
/// [headlineReadinessScalar] would have returned a value, i.e. there is
/// nothing to explain.
///
/// Deliberately NOT the `need_baseline:` note (edge#305): reaching a present
/// composite already means every input cleared `readinessCompositeMinBaseline`,
/// so "Need N more nights" would be a proven-false cause once this fires — the
/// UI's baseline-note convention exists precisely to prevent stating a wrong
/// cause. Pure so the gate + note format are unit-testable without the full
/// pipeline.
String? zCapAbsentNote(Metric<Readiness> composite) {
  if (!composite.present) return null;
  if (headlineReadinessScalar(composite) != null) return null;
  final z = composite.value!.compositeZ;
  return 'unstable_baseline:z=${z.toStringAsFixed(3)},cap=$kReadinessZCap';
}

/// A genuine, human reason — or a real "N more nights" estimate — for a
/// `readiness_absent_diag` the composite refused via its `need_inputs:` note:
/// at least one input usable, but too few of them (or too little combined
/// weight) to compose — see `readinessCompositeMinInputs`/
/// `readinessCompositeMinWeight` in readiness_composite.dart. Distinct from
/// [zCapAbsentNote]'s case and from the `need_baseline:` cold-start case
/// `needMessageFromNote` already covers — same reasoning as that function's
/// own doc: a wrong cause is worse than no cause.
///
/// Built ENTIRELY from data already stored in [diag] — per-input
/// `baseline_n` (already shown in "What was missing") and temp's own
/// `settled_frac` — plus the analytics package's own published thresholds.
/// Nothing here re-derives a score or changes what gets persisted, so this
/// needs no kAlgoVersion bump: it is a read-time translation of already-
/// stored data into prose, the job [needMessageFromNote] already does for a
/// different note convention.
///
/// Only for a `need_inputs:` note. A `need_baseline:` absence already gets
/// its count from [needMessageFromNote], and an `unstable_baseline:` one
/// cleared every floor it needed, so a night count there is a false cause.
///
/// The count is the [readinessCompositeMinInputs]-th closest of HRV/RHR/
/// breathing rate among the inputs actually measured today: the composite
/// scores once that many clear [readinessCompositeMinBaseline], and any two
/// of the three carry at least [readinessCompositeMinWeight]. Not the slowest
/// one, which is never the bottleneck. Deliberately names no input: the
/// per-input "X of Y nights" rows this sentence sits above already say which
/// one, by name, with its own count — this is the overall answer, not a
/// second copy of a row.
///
/// Skin temperature is reported separately, without a night count: its
/// settled-fraction gate depends on how many FUTURE nights read as genuinely
/// settled (not warming up / off-wrist), a quality threshold, not an
/// elapsed-time one — promising "N more nights" for it would be exactly the
/// fabrication this codebase's honesty rule exists to refuse.
///
/// Null when [diag] is null or nothing here applies — the existing raw-note
/// / generic fallback chain in readiness_detail.dart still covers that case.
///
/// [metricName] names the thing the sentence says cannot score — "readiness"
/// on the Readiness detail screen, "recovery" on Home, which labels the same
/// absence "Recovery" (the ring) rather than "Readiness". Same underlying
/// diagnostic and the same number either way; only the noun changes, so the
/// two screens' explanations still can't drift apart on anything that
/// matters.
String? readinessInputShortfallNote(
  Map<String, dynamic>? diag, {
  String metricName = 'readiness',
}) {
  if (diag == null) return null;
  if (!'${diag['note']}'.startsWith('need_inputs:')) return null;
  // ponytail: ignores temp as the second input (HRV 0.40 + temp 0.10 also
  // clears the weight floor), so it can overstate by a few nights then.
  final shortfalls = [
    for (final key in const ['hrv', 'rhr', 'resp'])
      if (diag[key] case {'value': true} && final e)
        math.max(0, readinessCompositeMinBaseline -
            ((e['baseline_n'] as num?)?.toInt() ?? 0)),
  ]..sort();
  final shortfall = shortfalls.length < readinessCompositeMinInputs
      ? 0
      : shortfalls[readinessCompositeMinInputs - 1];

  final tempFrac = (diag['temp'] as Map?)?['settled_frac'] as num?;
  final tempUnsettled = tempFrac != null && tempFrac < kMinSettledFraction;

  if (shortfall == 0) {
    // No input is short on raw nights — if the only thing refused is skin
    // temperature, say so honestly, without an ETA this data cannot back.
    // No input named here either: the per-input "X of Y nights" rows below
    // this sentence already say which one, by name, with its own count — this
    // banner only needs the overall answer.
    if (tempUnsettled) {
      return 'Needs more consistently measured nights before $metricName '
          'can score.';
    }
    return null;
  }

  return 'Needs $shortfall more night${shortfall == 1 ? '' : 's'} '
      'before $metricName can score.';
}

final _unstableBaselinePattern = RegExp(r'^unstable_baseline:');

/// A genuine reason for [zCapAbsentNote]'s absence: the composite actually
/// computed but got withheld as a saturated, degenerate-baseline artefact
/// (see [kReadinessZCap]) — a DIFFERENT cause than [readinessInputShortfallNote]
/// covers (which needs a baseline-count shortfall or an unsettled temp; this
/// one has neither, since reaching the z-cap check means every input already
/// cleared its own floor).
///
/// Found live on PR #510: callers that only tried
/// [readinessInputShortfallNote] and fell straight to the generic "nothing
/// recorded says why" for this case lost the specific reason a prior version
/// of the screen showed (as the raw, unreadable note) — worth a real
/// translation rather than either extreme.
///
/// Null for every other note, including no note at all — the same "a key it
/// does not recognise renders as we do not know" floor [whyFromNote] already
/// uses, so an absence this function can't name still gets the honest
/// generic fallback instead of a leaked machine string.
String? readinessUnstableBaselineNote(
  String? note, {
  String metricName = 'readiness',
}) {
  if (note == null || !_unstableBaselinePattern.hasMatch(note)) return null;
  return 'Today\'s $metricName looked too extreme to trust against your own '
      'history, so it was held back rather than shown.';
}

/// Serializable input to the isolate: one physiological day's decoded 1 Hz
/// substrate (the day slice), the PRECOMPUTED single-source sleep segmentation,
/// the profile, and trailing baseline history for the readiness pass.
///
/// `*Win` arrays are the day-slice arrays restricted to the SLEEP window — the
/// coordinator slices once so the isolate input is small and the windowing is
/// done in exactly one place. `sleepJson` is the SleepSegmentation.toJson() (the
/// single source of TST/WASO/stages/hypnogram).
class DayBundleInput {
  final String date; // wake-to-wake label (coordinator-supplied)

  // ── DAY span (wake → next wake) 1 Hz substrate ────────────────────────────
  final List<int> dayTsSec;
  final List<int> dayHr; // 0 = off-skin
  // Day-span RR (beat-end epoch ms + interval ms) for the 24/7 irregular-rhythm
  // screen. Sparse (0–4 beats/s); empty when no RR was captured.
  final List<double> dayRrTsMs;
  final List<double> dayRrMs;

  // ── SLEEP window 1 Hz substrate (the window from segmentSleep) ────────────
  final List<int> sleepTsSec;
  final List<int> sleepHr;
  final List<double> sleepRrTsMs;
  final List<double> sleepRrMs;
  final List<int> sleepSkinTemp;

  // ── the SINGLE-SOURCE sleep segmentation (JSON of SleepSegmentation) ──────
  final Map<String, dynamic> sleepJson; // {window,tst_sec,…,confidence}
  final List<String> hypnoStages; // per-second 'wake'|'nrem'|'rem' over window
  final int sleepOnsetSec; // window onset (epoch sec), 0 if no sleep
  final int sleepOffsetSec; // window offset (epoch sec), 0 if no sleep
  // Onset of TONIGHT's sleep (the next day's main sleep, begun before this
  // day's midnight), 0 if none. Everything from it on is asleep, not waking.
  final int tonightSleepOnsetSec;

  // ── profile + trailing baseline history ───────────────────────────────────
  final Map<String, dynamic> profile;
  final List<double> lnRmssdHistory;
  final List<double> rhrHistory;
  final List<double> respHistory;

  /// Trailing nightly RMSSD (ms) — the SAME `rmssd` series the engine writes to
  /// metric_series (the sleep-session mean of 5-min-window RMSSDs; absent when
  /// that estimator abstains). Used as the history for the EWMA hrv baseline so
  /// its center and today's value are the SAME metric (was previously
  /// reconstructed from ln(whole-window RMSSD), a definition mismatch that made
  /// the z spuriously large).
  final List<double> rmssdHistory;

  /// Trailing RAW nightly skin-temp ADC means (NOT z-scores). The personal
  /// baseline for the relative skin-temp deviation: today's mean sleep-window
  /// ADC is z-scored against THIS series. Must be raw ADC means so the unit
  /// matches today's raw mean (the old z-vs-z series was a unit mismatch bug).
  final List<double> skinTempAdcHistory;

  /// Trailing per-day quiet-waking levels (`quiet_hrr`, %HRR fraction),
  /// strictly before this day, oldest→newest. Strain is priced against their
  /// median ([personalQuietWakingHrr]) — never against this day's own level,
  /// which would subtract the day's own living from itself.
  final List<double> quietHrrHistory;

  /// Trailing readiness composite z's (`readiness_z`), strictly before this
  /// day, oldest→newest — the user's own composite spread the score is
  /// calibrated against (`calibratedReadinessScore`).
  final List<double> readinessZHistory;

  /// TS-03 — the highest heart rate the band has OBSERVED (held >=15 s with
  /// corroborating motion, `observed_max_hr.dart`) on any day STRICTLY BEFORE
  /// this one, or null when there is none. Not a physiological HRmax: if the
  /// user has never gone truly hard it is an underestimate and it keeps
  /// creeping up.
  ///
  /// Strictly-before, like every other history here and for the same reason —
  /// a day must not be banded on a ceiling its own record-setting session set,
  /// or the derived output depends on nothing but itself.
  final double? observedHrCeilingBpm;

  // ── day confidence + flags (e.g. LOW_CONFIDENCE_RECOVERY for fallback days) ─
  final double dayConfidence;
  final List<String> dayFlags;

  /// The day's resolved `live_coverage` spans as `[startSec, endSec, steps]`
  /// — credited, never raw rows (band/phone overlap already settled). The
  /// energy mirror prices sub-flex-gate walking minutes off these, through
  /// the SAME `cadenceSpmForMinutes` mapping the coordinator's canonical
  /// `wakeDayEnergy` pass uses, so the early read and the derived day bill
  /// the same walk the same way. Empty when nothing measured steps.
  final List<List<int>> stepSpans;

  /// Which strap measured this day — `'gen4'`, `'gen5'`, or null for UNKNOWN
  /// (unstamped historical rows, imports, the raw-hex replay path). Null is its
  /// own case, never gen4: see [Substrate.deviceFamily] and analytics'
  /// device.dart. Per-family figures (the HR ceiling, and everything banded on
  /// it) REFUSE rather than borrow another family's constants.
  final String? deviceFamily;

  /// How the sleep window was chosen: `'manual'`/`'confirmed'` (the user's own
  /// word), `'auto'`, `'auto_fallback'`, `'none'`. Sleep-onset latency is only
  /// meaningful on a FORCED window — see `sol_sec` below.
  final String sleepSource;

  const DayBundleInput({
    required this.date,
    required this.dayTsSec,
    required this.dayHr,
    this.dayRrTsMs = const [],
    this.dayRrMs = const [],
    required this.sleepTsSec,
    required this.sleepHr,
    required this.sleepRrTsMs,
    required this.sleepRrMs,
    required this.sleepSkinTemp,
    required this.sleepJson,
    required this.hypnoStages,
    required this.sleepOnsetSec,
    required this.sleepOffsetSec,
    this.tonightSleepOnsetSec = 0,
    required this.profile,
    this.lnRmssdHistory = const [],
    this.rhrHistory = const [],
    this.respHistory = const [],
    this.rmssdHistory = const [],
    this.skinTempAdcHistory = const [],
    this.quietHrrHistory = const [],
    this.readinessZHistory = const [],
    this.observedHrCeilingBpm,
    this.dayConfidence = 0,
    this.dayFlags = const [],
    this.deviceFamily,
    this.sleepSource = 'auto',
    this.stepSpans = const [],
  });

  Map<String, dynamic> toJson() => {
    'date': date,
    'step_spans': stepSpans,
    'day_ts': dayTsSec,
    'day_hr': dayHr,
    'day_rr_ts_ms': dayRrTsMs,
    'day_rr_ms': dayRrMs,
    'sleep_ts': sleepTsSec,
    'sleep_hr': sleepHr,
    'sleep_rr_ts_ms': sleepRrTsMs,
    'sleep_rr_ms': sleepRrMs,
    'sleep_skin_temp': sleepSkinTemp,
    'sleep_json': sleepJson,
    'hypno_stages': hypnoStages,
    'sleep_onset_sec': sleepOnsetSec,
    'sleep_offset_sec': sleepOffsetSec,
    'tonight_sleep_onset_sec': tonightSleepOnsetSec,
    'profile': profile,
    'ln_rmssd_history': lnRmssdHistory,
    'rhr_history': rhrHistory,
    'resp_history': respHistory,
    'rmssd_history': rmssdHistory,
    'skin_temp_adc_history': skinTempAdcHistory,
    'quiet_hrr_history': quietHrrHistory,
    'readiness_z_history': readinessZHistory,
    'observed_hr_ceiling_bpm': observedHrCeilingBpm,
    'day_confidence': dayConfidence,
    'day_flags': dayFlags,
    'device_family': deviceFamily,
    'sleep_source': sleepSource,
  };

  static DayBundleInput fromJson(Map<String, dynamic> m) {
    List<int> ints(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    // The substrate packs these as Float64List and the isolate boundary hands
    // them back typed; unboxing them into a plain List<double> was re-boxing
    // every element for nothing. Always a COPY, never an alias: on the direct
    // (synchronous, in-test) path returning the caller's list would share the
    // substrate's arrays across two repos with nobody enforcing read-only.
    List<double> dbls(String k) {
      final v = (m[k] as List?) ?? const [];
      if (v is List<double>) return Float64List.fromList(v);
      final out = Float64List(v.length);
      for (var i = 0; i < v.length; i++) {
        out[i] = (v[i] as num).toDouble();
      }
      return out;
    }
    List<String> strs(String k) =>
        ((m[k] as List?) ?? const []).map((e) => e.toString()).toList();
    return DayBundleInput(
      date: m['date'] as String,
      dayTsSec: ints('day_ts'),
      dayHr: ints('day_hr'),
      dayRrTsMs: dbls('day_rr_ts_ms'),
      dayRrMs: dbls('day_rr_ms'),
      sleepTsSec: ints('sleep_ts'),
      sleepHr: ints('sleep_hr'),
      sleepRrTsMs: dbls('sleep_rr_ts_ms'),
      sleepRrMs: dbls('sleep_rr_ms'),
      sleepSkinTemp: ints('sleep_skin_temp'),
      sleepJson: ((m['sleep_json'] as Map?) ?? const {})
          .cast<String, dynamic>(),
      hypnoStages: strs('hypno_stages'),
      sleepOnsetSec: (m['sleep_onset_sec'] as num?)?.toInt() ?? 0,
      sleepOffsetSec: (m['sleep_offset_sec'] as num?)?.toInt() ?? 0,
      tonightSleepOnsetSec:
          (m['tonight_sleep_onset_sec'] as num?)?.toInt() ?? 0,
      profile: ((m['profile'] as Map?) ?? const {}).cast<String, dynamic>(),
      lnRmssdHistory: dbls('ln_rmssd_history'),
      rhrHistory: dbls('rhr_history'),
      respHistory: dbls('resp_history'),
      rmssdHistory: dbls('rmssd_history'),
      skinTempAdcHistory: dbls('skin_temp_adc_history'),
      quietHrrHistory: dbls('quiet_hrr_history'),
      readinessZHistory: dbls('readiness_z_history'),
      observedHrCeilingBpm: (m['observed_hr_ceiling_bpm'] as num?)?.toDouble(),
      dayConfidence: (m['day_confidence'] as num?)?.toDouble() ?? 0,
      dayFlags: strs('day_flags'),
      deviceFamily: m['device_family'] as String?,
      sleepSource: m['sleep_source'] as String? ?? 'auto',
      stepSpans: [
        for (final r in (m['step_spans'] as List? ?? const []))
          [for (final v in (r as List)) (v as num).toInt()],
      ],
    );
  }
}

/// THE ISOLATE ENTRY POINT.
///
/// Pure: takes the serialized [DayBundleInput] map, returns a plain JSON map (the
/// full derived bundle). Call directly + synchronously in tests, or via
/// `Isolate.run(() => deriveDayBundle(input))` in production.
Map<String, dynamic> deriveDayBundle(Map<String, dynamic> inputJson) {
  final d = DayBundleInput.fromJson(inputJson);

  // ── HR over the DAY (for the curve, strain zones, dip day-side) ───────────
  final dayHr = [for (final h in d.dayHr) h.toDouble()];
  final dayHrValid = dayHr.where((h) => h > 0).toList();

  // ── WORN minutes — distinct wall-clock minutes that have ANY record ────────
  // Wear is RECORD presence, NOT valid HR. The band logs 1 Hz to flash only
  // while on-wrist (off-wrist it stops and emits WRIST_OFF), so a record in a
  // minute means the band was worn that minute. We deliberately do NOT gate on
  // HR>0: a valid HR needs a still wrist + good optical contact, which happens
  // mostly during SLEEP, so an HR-valid count collapses "worn" to ~the sleep
  // duration (the 24 h-worn-shows-7 h bug). Bucketing by real epoch-second
  // timestamp (not array index) is also gap-safe.
  //
  // A wearable stores one record every few minutes, so each of its records
  // stands for the span up to the next one, capped at its cadence (a band's
  // day is untouched: a record is its own second).
  final wornCap = isWearableFamily(d.deviceFamily)
      ? calibrationFor(kHrCadenceSec, d.deviceFamily) ??
            _medianGapSec(d.dayTsSec, minGapSec: 60)
      : null;
  final wornMinuteBuckets = <int>{};
  for (var i = 0; i < d.dayTsSec.length; i++) {
    final ts = d.dayTsSec[i];
    wornMinuteBuckets.add(ts ~/ 60);
    if (wornCap == null || i + 1 >= d.dayTsSec.length) continue;
    final end = math.min(d.dayTsSec[i + 1], ts + wornCap);
    for (var m = ts ~/ 60 + 1; m * 60 < end; m++) {
      wornMinuteBuckets.add(m);
    }
  }
  final wornMin = wornMinuteBuckets.length;

  // ── HR over the SLEEP WINDOW (RHR / dip night-side) ────────────────────────
  final sleepHr = [for (final h in d.sleepHr) h.toDouble()];
  // The clock for that series — parallel by construction (both are `Substrate`
  // columns, 1:1 with `tsSec`). Seconds as doubles because that is what the
  // analytics window helpers take.
  final sleepTs = [for (final t in d.sleepTsSec) t.toDouble()];

  // ── RR over the SLEEP WINDOW → cleaned NN → HRV (the V2 fix) ───────────────
  // HRV/RHR are rest/sleep-only per the catalog. Running correctRr+hrvTime over
  // the SLEEP RR (not the whole day) is what brings RMSSD back to physiological
  // tens-of-ms instead of the whole-day ~166 ms inflated value.
  final corrected = correctRr(d.sleepRrMs, rrTsMs: d.sleepRrTsMs);
  final nn = corrected.nn;
  final nnTimes = corrected.nnTimesMs;
  final artifactFraction = (1.0 - corrected.cleanFraction).clamp(0.0, 1.0);
  // Σ RR ÷ wall span of the raw sleep RR: above 1.10 the stream holds more
  // beat-time than elapsed (duplicated or interleaved beats), and every RMSSD
  // below refuses it. Null under 10 min of span.
  final rrCov = rrCoverage(d.sleepRrMs, d.sleepRrTsMs);

  final hasSleep = (d.sleepJson['tst_sec']) != null;

  // ── SLEEP: everything from the SINGLE-SOURCE segmentation ──────────────────
  final sleepWinJson = (d.sleepJson['window'] as Map?)?.cast<String, dynamic>();
  final tstSec = (d.sleepJson['tst_sec'] as num?)?.toInt();
  final wasoSec = (d.sleepJson['waso_sec'] as num?)?.toInt();
  final inBedSec = (d.sleepJson['in_bed_sec'] as num?)?.toInt();
  final effPct = (d.sleepJson['efficiency_pct'] as num?)?.toDouble();
  final nremSec = (d.sleepJson['nrem_sec'] as num?)?.toInt();
  // 4-class split of NREM into Light/Deep (Deep = LOW CONFIDENCE overlay).
  final lightSec = (d.sleepJson['light_sec'] as num?)?.toInt();
  final deepSec = (d.sleepJson['deep_sec'] as num?)?.toInt();
  final remSec = (d.sleepJson['rem_sec'] as num?)?.toInt();
  final wakeSec = (d.sleepJson['wake_sec'] as num?)?.toInt();
  final sleepConf = (d.sleepJson['confidence'] as num?)?.toDouble() ?? 0;
  // SLP-01 — `segment.dart` has always serialised both of these and edge read
  // neither, so they died at the seam. `in_bed_sec` is WALL CLOCK and includes
  // the hours we never watched; `efficiency_pct` already divides by OBSERVED
  // time on purpose, so without this key the honest denominator just reads as a
  // worse night. `absence_reason` is why a window produced nothing.
  final unobservedSec = (d.sleepJson['unobserved_sec'] as num?)?.toInt();
  final absenceReason = d.sleepJson['absence_reason'] as String?;
  final bandOffsetTrimSec = (d.sleepJson['band_offset_trim_sec'] as num?)?.toInt();
  // A night whose stages carry no wake (a device that never reports it, see
  // vendor_sleep.dart) has no awakenings to count: a 0 there would be
  // construction, not a measurement. Such a night serialises wake_sec as
  // null; every staged night of ours carries a number there.
  final runs = {
    ..._sleepRuns(d),
    if (hasSleep && d.sleepJson.containsKey('wake_sec') && wakeSec == null)
      'awakenings': null,
  };

  // ── CLINICAL (sleep-windowed) ──────────────────────────────────────────────
  // Whole-window time-domain HRV is kept for SDNN / detail rows only. The
  // nightly headline HRV is the mean of 5-min cleaned-window RMSSDs across the
  // detected sleep session, not one RMSSD over the whole night's NN stream.
  final hrvT = hrvTime(nn, nnTimesMs: nnTimes, coverage: rrCov);
  // Keep the robust estimator as a secondary detail only; the canonical nightly
  // RMSSD follows the sleep-session windowed formulation.
  final nremMask = _nremMaskAlignedToNn(d, nnTimes, d.sleepRrTsMs);
  final robustRmssd = nocturnalRmssd(nn, nnTimes,
      stageMaskPerSec: nremMask, coverage: rrCov);
  final sleepSessionRmssdMetric = sleepSessionRmssdDetail(
    d.sleepRrMs,
    d.sleepRrTsMs,
    startSec: d.sleepOnsetSec,
    endSec: d.sleepOffsetSec,
  );
  final sessionDetail = sleepSessionRmssdMetric.value;
  final sleepSessionRmssd =
      sleepSessionRmssdMetric.present ? sessionDetail!.rmssd : null;
  final hrvF = nn.length >= 20
      ? hrvFreq(nn, nnTimes, artifactFraction: artifactFraction)
      : Metric<HrvFreq>.absent(
          tier: Tier.high,
          inputs_used: const ['rr_cleaned'],
          note: needInputNote('nn_beats', have: nn.length, need: 20),
        );
  // Nocturnal RHR over the SLEEP HR. NO SLEEP ⇒ NO RESTING HR.
  //
  // This used to fall back to the whole-day HR when no sleep was scored, and
  // published the result as resting heart rate. On the owner's own export a
  // 213-minute day with no scored night published 88.0 bpm for a man whose
  // measured resting HR is 55.7–64.2; a second export published 116.7. That is
  // the lowest 30-minute mean of a day spent AWAKE, which is not a resting
  // heart rate at any tier — it is a different quantity wearing the label. The
  // only honest output is absence, so the card says why instead.
  //
  // THE 30 MINUTES ARE NOW 30 MINUTES. `nocturnalRhr` used to slide a window of
  // 1800 POSITIONS, which is half an hour only where every position is exactly
  // one second — so the series had to be positionally dense at 1 Hz or "the
  // lowest 30-minute mean" quietly became "the lowest mean over whatever 1800
  // samples survived". It is a real condition, not a hypothetical: the owner's
  // own export has sleep windows missing 506 seconds of 25,262, and a 15 s band
  // publishes a measured 59.7 bpm night as 66.4.
  //
  // Passing `sleepTs` moves the window onto the WALL CLOCK, so density stops
  // being a precondition: 30 min is 30 min at any cadence, off-skin gaps are
  // still never compacted away (a window must carry `minCoverage` of the
  // samples it SHOULD hold at the stream's own measured cadence), and a stream
  // with no measurable cadence yields ABSENCE rather than a guess. The
  // no-sleep-no-RHR branch above is untouched by any of that.
  final rhr = (hasSleep && sleepHr.isNotEmpty)
      ? nocturnalRhr(sleepHr, tsSec: sleepTs)
      : const Metric<NocturnalRhr>.absent(
          tier: Tier.high,
          inputs_used: ['hr_1hz', 'sleep_window'],
          note: 'no sleep was scored for this day — resting HR is only ever '
              'measured over a sleep window, never over waking hours',
        );
  // HR dip: day-side = waking HR outside the sleep window; night-side = sleep HR.
  final dayOnly = _dayHrOutsideSleep(d);
  final dip = hrDip(dayOnly, sleepHr);
  final dc = decelerationCapacity(nn);
  final ac = accelerationCapacity(nn);
  // Baevsky Stress Index over the sleep NN — resting autonomic tension (a
  // transparent RR-histogram metric; no ML). Daily resting-stress indicator.
  // nnTimesMs lets it segment at a charging/off-wrist gap instead of letting
  // a sliding window straddle it (same gap-aware pattern as cvhrApneaScreen
  // below).
  final stress = baevskyStressIndex(nn, nnTimesMs: nnTimes);

  // ── RESPIRATION (sleep-windowed) ───────────────────────────────────────────
  final resp = nn.length >= 30
      ? rsaRespRate(nn, nnTimes, artifactFraction: artifactFraction)
      : Metric<RespEstimate>.absent(
          tier: Tier.estimate,
          inputs_used: const ['rr_cleaned'],
          note: needInputNote('nn_beats', have: nn.length, need: 30),
        );
  final cvhr = nn.length >= 60
      ? cvhrApneaScreen(nn, nnTimes, artifactFraction: artifactFraction)
      : Metric<CvhrResult>.absent(
          tier: Tier.estimate,
          inputs_used: const ['rr_cleaned'],
          note: needInputNote('nn_beats', have: nn.length, need: 60),
        );
  // ── 24/7 IRREGULAR-RHYTHM SCREEN (day-span RR; not a diagnosis) ────────────
  // Runs over the WHOLE-DAY cleaned RR (not just sleep) so an arrhythmia screen
  // isn't limited to the sleep window. Hard-gated on beat count + artifact inside
  // irregularBeatScreen; returns absent on a thin/noisy day.
  final dayCorrected = correctRr(d.dayRrMs,
      rrTsMs: d.dayRrTsMs.isEmpty ? null : d.dayRrTsMs);
  final irregular24h = irregularBeatScreen(
    dayCorrected.nn,
    // Require sustained irregularity in independent short windows, not just
    // in one ratio blended across sleep+rest+exercise+posture changes — see
    // irregularBeatScreen's doc. Without this, real data showed the screen
    // firing on effectively every day regardless of actual cardiac health.
    nnTimesMs: dayCorrected.nnTimesMs,
    artifactFraction: (1.0 - dayCorrected.cleanFraction).clamp(0.0, 1.0),
  );

  // ── BREATHING-RATE VARIABILITY (per-window RSA over the sleep NN) ──────────
  // Window the cleaned sleep NN into ~30-min bins, take each bin's RSA resp rate,
  // then BRV = dispersion + Theil-Sen trend of those per-window rates.
  final respWindows = _respPerWindow(nn, nnTimes);
  final brv = respWindows.length >= 3
      ? breathingRateVariability(respWindows)
      : Metric<BrvResult>.absent(
          tier: Tier.estimate,
          inputs_used: const ['resp_rate_series'],
          note: needInputNote(
            'resp_windows',
            have: respWindows.length,
            need: 3,
          ),
        );

  // No SpO2 is derived from the band's red/IR channels. `spo2RedRaw` and
  // `spo2IrRaw` are one signal: `ir - red` is a fixed integer within a capture
  // session (see protocol/records.dart) while both drift together, so any
  // ratio built from them measures that drift, not oxygenation. Imported WHOOP
  // blood oxygen is a separate `spo2` metric_series key and does not pass
  // through here.
  const kSpo2Refusal = 'refused: the red and IR channels are one signal — '
      'ir − red is a fixed offset within a session, so any ratio built from '
      'them measures baseline drift, not oxygenation';
  const odi = Metric<RelativeOdiResult>.absent(
    tier: Tier.relative,
    inputs_used: ['spo2_red_raw', 'spo2_ir_raw'],
    note: kSpo2Refusal,
  );

  // ── WELLNESS: relative skin-temp deviation (z) vs personal baseline ────────
  // STEP 1 — today's RAW mean sleep-window skin-temp ADC. ALWAYS computable when
  // there's sleep + temp data; stored EVERY day to build the baseline series so
  // z starts computing once ≥3 prior days exist (honest bootstrap: first ~3 days
  // legitimately read "—", then it works).
  final tempValid = d.sleepSkinTemp
      .where((v) => v > 0)
      .map((v) => v.toDouble())
      .toList();
  // Sixty samples: a minute of a 1 Hz band. A wearable that stores one value
  // every few minutes ([kHrCadenceSec]) needs an hour of its readings, not
  // sixty of them (five hours of a ring's night).
  final hrCadence = calibrationFor(kHrCadenceSec, d.deviceFamily);
  // A wearable with no HR cadence (a ring that stores temperature events
  // only) is spaced by its own readings: the median gap between them.
  final tempCadence =
      hrCadence ??
      (isWearableFamily(d.deviceFamily)
          ? _medianGapSec([
              for (var i = 0;
                  i < d.sleepSkinTemp.length && i < d.sleepTsSec.length;
                  i++)
                if (d.sleepSkinTemp[i] > 0) d.sleepTsSec[i],
            ])
          : null);
  final minTempSamples =
      tempCadence == null ? 60 : math.max(1, 3600 ~/ tempCadence);
  final double? skinTempAdc =
      tempValid.length >= minTempSamples ? _mean(tempValid) : null;
  // WH-11a — how much of the night that mean is actually made of. The gate above
  // is sixty 1 Hz samples, i.e. one minute; on real hardware the temp channel
  // runs 35-90 samples/hour, so a "last night" skin temperature can be ~1.5% of
  // the window and nothing said so. NO THRESHOLD IS APPLIED and none should be
  // guessed here — emit the number, look at what it reads on real nights first.
  // A wearable whose spacing is unknown has no coverage to report.
  final double? skinTempCoverage = (inBedSec == null || inBedSec <= 0) ||
          (tempCadence == null && isWearableFamily(d.deviceFamily))
      ? null
      : (tempValid.length * (tempCadence ?? 1) / inBedSec).clamp(0.0, 1.0);
  // HOW MUCH OF THE NIGHT THE STRAP SPENT AT SKIN TEMPERATURE (#250).
  //
  // `tempInput` refuses readiness's temp driver outright when this is null, and
  // nothing in this app has ever passed it — so the documented FOURTH DRIVER
  // has never contributed on any night, the other three renormalised over 0.90,
  // and "Skin temperature" could not appear in a breakdown. This is the number
  // it wants: the share of the night's valid samples sitting within the
  // family's settle band of the night's OWN median (warm-up and off-body read
  // low; a fever reads high and passes through).
  //
  // MEASURED HERE, GATED IN `tempInput` — hence `minSettledFraction: 0`.
  // `nightlySkinTemp` would otherwise go absent on an unsettled night and the
  // fraction would be lost, which lands on the "nobody measured it" refusal
  // instead of the true "the strap was cold for two hours" one. It still goes
  // absent for a family whose settle band nobody has measured (gen5 has none)
  // and for a night under sixty samples, and those genuinely ARE "no fraction
  // measured".
  //
  // Ts is not read by `nightlySkinTemp` (it is a median + a mean over the
  // night's samples), and `tempValid` has no parallel timestamp series, so 0
  // is passed rather than a fabricated clock.
  final settledTemp = nightlySkinTemp(
    [for (final v in tempValid) AdcSample(0, v)],
    deviceFamily: d.deviceFamily,
    minSettledFraction: 0.0,
    minSamples: minTempSamples,
  );
  final double? skinTempSettledFrac = settledTemp.value?.settledFraction;
  // A ring's settle band was set on synthetic nights (analytics `_tempCal`):
  // every number that leans on it below is served at half confidence and
  // marked provisional. Always false on a band, so its payload is unchanged.
  final tempProvisional = settledTemp.value?.provisional ?? false;
  // STEP 2 — z-score today's RAW mean against the RAW-ADC baseline history (NOT
  // the previously-computed z-scores; that unit mismatch was the bug). Gated on
  // ≥3 prior raw means.
  double? skinTempZ;
  if (skinTempAdc != null && d.skinTempAdcHistory.length >= 3) {
    final base = _mean(d.skinTempAdcHistory)!;
    final sd = _stddev(d.skinTempAdcHistory);
    // Quantum floor matches analytics' tempInput(quantum: 1) guard
    // (readiness_composite.dart) for this same raw-ADC channel: a baseline
    // oscillating between two adjacent ADC counts has a nonzero but
    // sub-quantum SD, which standardizes ordinary quantization noise into
    // an inflated z. Below 1 ADC count of dispersion, abstain instead.
    if (sd != null && sd >= 1) skinTempZ = (skinTempAdc - base) / sd;
  }

  // ── READINESS (the canonical composite, baseline-dependent) ───────────────
  final lnToday = (sleepSessionRmssd != null && sleepSessionRmssd > 0)
      ? math.log(sleepSessionRmssd)
      : null;
  // Readiness's RHR input must come from an ACTUAL detected sleep session —
  // feeding a daytime number into readiness let a handful of minutes of live HR
  // masquerade as an overnight resting rate, the sole reason a same-day score
  // of 100 could appear ~10 minutes after first wearing the strap. That gate
  // used to live HERE, on top of a `rhr` that fell back to daytime; it now
  // lives in `rhr` itself, so this is the same number the card shows.
  final rhrToday = rhr.present ? rhr.value!.low30Mean : null;
  final respToday = resp.present ? resp.value!.brpm : null;
  final composite = readinessComposite([
    hrvInput(lnToday, d.lnRmssdHistory),
    rhrInput(rhrToday, d.rhrHistory),
    respInput(respToday, d.respHistory),
    // Feed the RAW ADC mean + the RAW-ADC baseline so the composite computes its
    // own oriented robust-z internally (consistent with the other inputs, which
    // pass raw values + their raw baselines).
    //
    // The mean stays RAW — value and baseline have to be the same quantity, and
    // the stored history is a series of raw nightly means. The settled fraction
    // is the GATE on using it at all: below 0.80 the driver is refused for this
    // night, by name, and readiness renormalises over the three that are left.
    tempInput(
      skinTempAdc,
      d.skinTempAdcHistory,
      settledFraction: skinTempSettledFrac,
    ),
  ],
      // A wearable gives no beats, so HRV (and resp) never enter: the
      // composite is PARTIAL, resting HR and skin temperature, which weigh
      // 0.30 + 0.10. Still two measured inputs, never one; the band's own
      // floor is untouched.
      minWeightSum: hrCadence == null
          ? readinessCompositeMinWeight
          : kPartialReadinessMinWeight,
      compositeZHistory: d.readinessZHistory);
  // Populated when readiness comes back absent, so the main isolate can log WHY
  // instead of a bare null (this runs inside Isolate.run, so it can't call
  // Firebase directly; it just returns data). TWO consumers now, and the second
  // is why the shape below is what it is: `readiness_detail.dart` renders these
  // rows TO THE USER — "Measured · 6 nights of your own history" — so every key
  // here is either something a person is owed or something a crash report needs.
  //
  // `baseline_sd` USED TO BE HERE and is gone. It existed to identify a
  // degenerate-dispersion baseline BY ELIMINATION, back when readinessComposite
  // abstained on that silently. It no longer does: the quantized inputs (RHR,
  // temp) refuse by name with the number in the note —
  // `baseline_dispersion_below_quantum:sd=…,quantum=…,n=…`. The two continuous
  // inputs (lnRMSSD, resp) have no quantum and so still fall through to the
  // mean/SD z, which only returns null on an EXACTLY constant baseline of
  // doubles — a case that cannot be reached by real nightly values. So the
  // field diagnosed nothing the note does not say, and shipped an unexplained
  // number to a Crashlytics field that had to be read by someone who knew all
  // of the above.
  Map<String, dynamic>? readinessAbsentDiag;
  if (!composite.present) {
    readinessAbsentDiag = {
      'hrv': {
        'value': lnToday != null,
        'baseline_n': d.lnRmssdHistory.length,
      },
      'rhr': {
        'value': rhrToday != null,
        'baseline_n': d.rhrHistory.length,
      },
      'resp': {
        'value': respToday != null,
        'baseline_n': d.respHistory.length,
      },
      'temp': {
        'value': skinTempAdc != null,
        'baseline_n': d.skinTempAdcHistory.length,
        // The gate, not the value: a temp driver can be refused with a perfectly
        // good mean and a full baseline. Null = the fraction was unmeasurable.
        'settled_frac': skinTempSettledFrac,
      },
      'note': composite.note,
    };
  }
  // Plews lnRMSSD readiness. `readinessLnRmssd` is contractually handed the
  // trailing history with TONIGHT AS THE LAST ELEMENT and takes strictly the
  // prior elements as its baseline (analytics v38). So appending `lnToday`
  // exactly once is right — PROVIDED `d.lnRmssdHistory` holds only days BEFORE
  // this one. It didn't: the engine filled it from an unfiltered trailing
  // `metric_series` window that already contained the row a previous derive of
  // THIS day wrote, so today was in its own baseline AND counted a second time
  // by this append. The engine now self-excludes the target date
  // (`_attachHistory` → `_BaselineHistoryCache.valuesBefore`), which is what
  // makes this single append the correct, non-duplicating one.
  final lnHist = [...d.lnRmssdHistory, ?lnToday];
  final lnReadiness = lnHist.length >= 4
      ? readinessLnRmssd(lnHist)
      : Metric<ReadinessLnRmssd>.absent(
          tier: Tier.high,
          inputs_used: const ['ln_rmssd_history'],
          // A BASELINE shortfall, so it gets the baseline grammar the UI
          // already turns into "Need N more nights".
          note: needBaselineNote(have: lnHist.length, need: 4),
        );

  // ── STRAIN: Banister TRIMP over the WAKE span (per-minute day HR) ──────────
  final prof = d.profile;
  final age = (prof['age'] as num?)?.toDouble();
  final sex = (prof['sex'] as String?)?.toLowerCase();
  // ONE definition (hr_max.dart). Null without an age, which takes
  // TRIMP/strain/calories with it. Zones do not need it (`zoneSet` below).
  final hrMax = estimatedMaxHr(age, d.deviceFamily);
  // TS-04 — THE zone set (hr_max.dart). Karvonen %HRR between the OBSERVED
  // ceiling and the 28-day median resting HR once both exist; %HRmax off the
  // age estimate until then, which is exactly what this line used to do alone.
  // `zone_source` below is what the screens print, and TRIMP/calories are
  // deliberately NOT moved onto the observed ceiling here — that re-scores
  // every historical strain and is its own decision.
  final zoneSet = trainingZones(
    age: age,
    deviceFamily: d.deviceFamily,
    observedCeilingBpm: d.observedHrCeilingBpm,
    restingHrHistory: d.rhrHistory,
    manualZoneLowerBpm: manualZoneBoundsFromProfile(prof),
  );
  final rhrForTrimp = rhrToday ?? (prof['resting_hr'] as num?)?.toDouble();
  final weightKg = (prof['weight_kg'] as num?)?.toDouble();
  final heightCm = (prof['height_cm'] as num?)?.toDouble();
  // Wake-span per-minute mean HR = the day minus the sleep window (shared by
  // TRIMP, HR zones, and calories so all three see the same wake series).
  final wakeHr = _perMinuteWakeSeries(d);
  final perMin = [for (final p in wakeHr) p.hr];
  // THIS user's quiet-waking level: the median of the trailing days' own
  // levels, strictly before today. Absent below three days — strain then
  // abstains with the baseline grammar rather than pricing being awake at a
  // population constant.
  final quiet = personalQuietWakingHrr(d.quietHrrHistory);
  // ── WHY the activity family is absent, named AT THE GATE THAT CAUSED IT ────
  //
  // These four figures — strain/TRIMP, the zone minutes, the ceiling they were
  // banded on, and active calories — fail on OVERLAPPING but DIFFERENT inputs,
  // and they used to go absent with no reason at all while the reason was
  // written onto `daytime_hrv` and `hr_ceiling`, which no screen that renders
  // them reads. The screens then guessed, and guessed wrong ("add your age" on
  // a profile whose age is set). Each figure now carries its own root cause, in
  // the order the gates below actually apply, so nothing has to infer a cause
  // from a sibling.
  //
  // Same order and same vocabulary as `DerivationEngine._wakeDayFeatures` —
  // that half recomputes strain, the ceiling and calories off the nocturnal
  // resting HR and its answer is the one that lands on the day, so the two must
  // not disagree about WHY. The zone minutes are NOT recomputed there: `zones`
  // and its note are this pipeline's alone, binned on `zoneSet` like
  // `zone_timeline`, so they gate on the set and not on the age estimate.
  final ceilingAbsentNote = hrMax != null
      ? null
      : age == null
      ? needInputNote('age')
      // The age is known; what measured this HR is not, so there is no ceiling
      // to band it against (analytics' device.dart contract).
      : unknownFamilyNote(d.deviceFamily);
  final strainAbsentNote = perMin.isEmpty
      ? needInputNote('wake_hr')
      : hrMax == null
      ? ceilingAbsentNote
      : dayHrValid.isEmpty
      ? needInputNote('hr_samples')
      : rhrForTrimp == null
      ? needInputNote('resting_hr')
      : sex == null
      ? needInputNote('sex')
      : !quiet.present
      ? (quiet.note ?? kUnknownAbsenceNote)
      : null;
  final caloriesAbsentNote = perMin.isEmpty
      ? needInputNote('wake_hr')
      : hrMax == null
      ? ceilingAbsentNote
      : age == null
      ? needInputNote('age')
      : sex == null
      ? needInputNote('sex')
      : weightKg == null
      ? needInputNote('weight_kg')
      // Keytel does not read height; `dailyEnergy`'s ACTIVE term nets out a
      // Mifflin basal minute, which does. See the long note below.
      : heightCm == null
      ? needInputNote('height_cm')
      : null;
  final zonesAbsentNote = perMin.isEmpty
      ? needInputNote('wake_hr')
      : zoneSet == null
      ? (ceilingAbsentNote ?? kUnknownAbsenceNote)
      : null;
  Metric<double> trimp = Metric<double>.absent(
    tier: Tier.estimate,
    inputs_used: const ['hr_1hz', 'profile'],
    note: strainAbsentNote ?? kUnknownAbsenceNote,
  );
  Map<String, int> hrZones = const {};
  double? caloriesKcal;
  // Off the set, not `hrMax`: a manual or observed set needs no age.
  if (zoneSet != null && perMin.isNotEmpty) {
    hrZones = _wakeZoneMinutesFromSeries(wakeHr, zoneSet);
  }
  if (hrMax != null && perMin.isNotEmpty) {
    if (rhrForTrimp != null && sex != null && dayHrValid.isNotEmpty) {
      trimp = banisterTrimp(
        perMin,
        restingHr: rhrForTrimp,
        maxHr: hrMax,
        sex: workoutSex(sex) == 'female' ? Sex.female : Sex.male,
      );
    }
    // ACTIVE energy only, over the WAKE series — the same quantity, from the
    // same series, that `DerivationEngine.wakeDayEnergy` publishes as the day's
    // `calories`. That method is canonical; this is the early-read mirror the
    // pure pipeline can compute without the coordinator, and the two must stay
    // on the same series AND the same gate. `basal`/`total` are deliberately
    // not read here: the pipeline does not know how many minutes of the
    // calendar day the substrate covers, so it cannot pro-rate the BMR floor
    // honestly.
    //
    // HEIGHT IS REQUIRED, and it used to be defaulted to 170 cm. Keytel does
    // not read height but `dailyEnergy`'s ACTIVE term is the surplus over the
    // Mifflin basal minute, and Mifflin does — so a stand-in height moves the
    // active figure this line publishes (about 117 kcal/day across a
    // 150-195 cm profile). `wakeDayEnergy` abstains for that reason; so does
    // this, or Today shows an imputed number the derived day then withdraws.
    //
    // The RESTING HR is required for the same class of reason: `dailyEnergy`'s
    // active gate is a %HRR flex point, so without the lower reserve anchor
    // there is no gate and every wake minute bills as active. `wakeDayEnergy`
    // abstains without it; so does this, or the two drift again.
    if (age != null &&
        sex != null &&
        weightKg != null &&
        heightCm != null &&
        rhrForTrimp != null) {
      caloriesKcal = Calories.dailyEnergy(
        perMin,
        profile: WorkoutUserProfile(
          weightKg: weightKg,
          heightCm: heightCm,
          age: age,
          sex: workoutSex(sex),
        ),
        hrmax: hrMax,
        restingHr: rhrForTrimp,
        // The SAME minute-aligned cadence the canonical pass uses — one
        // mapping (`cadenceSpmForMinutes`) fed by the same credited spans, so
        // this early read and the derived day bill a walk identically instead
        // of the number growing when the coordinator's pass lands.
        cadenceSpmPerMin: d.stepSpans.isEmpty
            ? null
            : cadenceSpmForMinutes(
                [for (final p in wakeHr) p.tsSec ~/ 60],
                d.stepSpans,
              ),
        // `?.` — `dailyEnergy` abstains outright when the anchors cannot
        // define a gate, rather than billing every waking minute as active.
        // Absent stays absent here, same as every other input on this seam.
      )?.active; // active-energy component (Keytel surplus + walking term)
    }
  }

  // HEADLINE STRAIN = 0–21 map of the TRIMP earned ABOVE this user's
  // quiet-waking level, exercise minutes (≥ 40 % HRR) never offset by quiet
  // ones; raw TRIMP kept as a detail. Same analytics arithmetic as the curve
  // below and the engine's recompute, so the three cannot disagree.
  final sexEnum = workoutSex(sex) == 'female' ? Sex.female : Sex.male;
  final strainMetric = strainAbsentNote != null || !quiet.present
      ? Metric<double>.absent(
          tier: Tier.estimate,
          inputs_used: const ['hr_1hz', 'profile', 'quiet_waking_hrr_history'],
          note: strainAbsentNote ?? kUnknownAbsenceNote,
        )
      : strainScoreFromSeries(
          perMin,
          restingHr: rhrForTrimp,
          maxHr: hrMax,
          quietHrr: quiet.value!.hrr,
          sex: sexEnum,
          quietSettled: quiet.value!.settled,
        );

  // ── curve series for the UI ────────────────────────────────────────────────
  final hrCurve = _downsampleHr(d.dayTsSec, d.dayHr);
  final hypnogram = _hypnogramSegments(d);
  // `nnTimes` is re-based to ~0 by `correctRr` (it sums RR intervals from a
  // zero clock), so the timeline needs the wall-clock instant that clock starts
  // at: the START of the first RR interval = its END stamp minus its own
  // length. Without it the stored `t` was seconds-since-first-beat on a view
  // (`v_series`) whose contract — and the coach prompt — say epoch seconds.
  final hrvOriginMs = (d.sleepRrTsMs.isEmpty || d.sleepRrMs.isEmpty)
      ? null
      : d.sleepRrTsMs.first - d.sleepRrMs.first;
  // A rolling RMSSD of the same beats: none on an over-counted stream.
  final hrvTimeline = rrCov?.overCounted == true
      ? const <Map<String, num>>[]
      : _hrvTimeline(nn, nnTimes, hrvOriginMs);
  // CV-06 — the SHAPE of the night: per-bin RMSSD over the same cleaned NN the
  // headline uses, so the curve and the number can never disagree. Bins that
  // fall under the beat floor stay in the series as HOLES on purpose — dropping
  // them lets a reader draw a straight line across a charging gap and call it
  // flat variability. Every bin ships lo/hi: render a BAND, not a line.
  //
  // A DESCRIPTION, never a cause. A suppressed first third is equally
  // consistent with alcohol, a late meal, late training, a warm room, illness
  // onset, or nothing, and nothing here can tell those apart.
  //
  // `startSec` is seconds from the FIRST BEAT, not an epoch — `origin_ms` is
  // the wall-clock instant that clock starts at, the same `hrvOriginMs` the
  // timeline above is placed on.
  // Every bin is an RMSSD of the same beats: absent with them on an
  // over-counted stream.
  final nightShape = nightHrvShape(nn, nnTimes, coverage: rrCov);
  final strainCurve = _strainCurve(
    wakeHr,
    restingHr: rhrForTrimp,
    maxHr: hrMax,
    sex: sex,
    quietHrr: quiet.value?.hrr,
  );
  final zoneTimeline = zoneSet == null
      ? const <Map<String, num>>[]
      : _zoneTimeline(wakeHr, zoneSet);

  // ── ASSEMBLE the bundle (envelopes are plain JSON) ─────────────────────────
  // ── HRV stability (CV = SDNN/meanNN) + Poincaré irregular-beat screen ──────
  // Both over the sleep NN. CV is a normalized variability stability index;
  // SD1/SD2 are the Poincaré descriptors; a high SD1/SD2 ratio flags erratic
  // beat-to-beat timing (a SCREEN, not a diagnosis).
  double? hrvCv;
  if (nn.length >= 20) {
    final meanNn = nn.reduce((a, b) => a + b) / nn.length;
    final sdnn = hrvT.present ? hrvT.value!.sdnn : null;
    if (sdnn != null && meanNn > 0) hrvCv = sdnn / meanNn * 100;
  }
  // SLEEP Poincaré screen — the SHARED analytics one, called exactly the way
  // `irregular24h` above is. Edge used to hand-roll a second copy here, which
  // meant it never got the three fixes analytics made to the shared screen: it
  // differenced straight down the compacted NN (so every artifact run the
  // corrector dropped manufactured one huge spurious difference, inflating
  // sdsd → sd1), it published `sd2: 0.0` with `flag: false` on a degenerate
  // series — "perfectly regular" as a measurement of nothing — and its
  // confidence was a hard-coded 0.5 however noisy the night was.
  final irregularSleep = irregularBeatScreen(
    nn,
    nnTimesMs: nnTimes,
    artifactFraction: artifactFraction,
  );
  final irrSleep = irregularSleep.present ? irregularSleep.value : null;

  final clinical = <String, dynamic>{
    'hrv_time': hrvT.toJson((v) => v.toJson()),
    // HRV stability (CV %) + Poincaré irregular-beat screen.
    'cv': hrvCv == null ? null : _round(hrvCv, 1),
    // Keys kept as-is (Investigate reads sd1/sd2/flag); absent is null, not a
    // zero and not a "clear".
    'irregular': <String, dynamic>{
      'sd1': irrSleep == null ? null : _round(irrSleep.sd1, 1),
      'sd2': irrSleep == null ? null : _round(irrSleep.sd2, 1),
      'flag': irrSleep?.flag,
      'confidence': irregularSleep.present
          ? _round(irregularSleep.confidence, 4)
          : 0.0,
      'note': irregularSleep.note,
    },
    // 24/7 irregular-rhythm SCREEN over the whole-day RR (the headline screen
    // that drives the opt-in notification). Sleep-only `irregular` kept above.
    'irregular_24h': irregular24h.toJson((v) => v.toJson()),
    // Breathing-rate variability trend (within-user only).
    'brv': brv.toJson((v) => v.toJson()),
    // Canonical nightly HRV, matching the sleep-session windowed RMSSD
    // aggregation over the chosen sleep session. The robust estimator is
    // retained alongside it as a secondary detail for comparison/debugging.
    'rmssd_sleep_session': {
      'value': sleepSessionRmssd == null ? '—' : _round(sleepSessionRmssd, 1),
      'confidence': sleepSessionRmssdMetric.present
          ? _round(sleepSessionRmssdMetric.confidence, 4)
          : 0,
      'tier': Tier.high,
      'inputs_used': const ['rr_sleep_window'],
      'note': sleepSessionRmssdMetric.note,
      // Diagnostics of the same estimate; null when it is absent (the
      // whole-night `hrv_time` envelope still carries diff_acf1).
      'windows': sessionDetail?.windows,
      'diff_acf1': sessionDetail?.diffAcf1 == null
          ? null
          : _round(sessionDetail!.diffAcf1!, 4),
      'rr_coverage': sessionDetail?.rrCoverage == null
          ? null
          : _round(sessionDetail!.rrCoverage!, 4),
      'overcounted_windows': sessionDetail?.overCountedWindows,
      // Windows under the floor of clean successive differences, and that
      // floor: how much of the night the mean does NOT rest on.
      'thin_windows': sessionDetail?.thinWindows,
      'min_diffs_per_window': sessionDetail?.minDiffsPerWindow,
    },
    'rmssd_nocturnal': robustRmssd.toJson(),
    'hrv_freq': hrvF.toJson((v) => v.toJson()),
    'resting_hr': rhr.toJson((v) => v.toJson()),
    'hr_dip': dip.toJson((v) => v.toJson()),
    'prsa_dc': dc.toJson((v) => v.toJson()),
    'prsa_ac': ac.toJson((v) => v.toJson()),
    'readiness_lnrmssd': lnReadiness.toJson((v) => v.toJson()),
    'readiness_composite': {
      ...composite.toJson((v) => v.toJson()),
      if (tempProvisional && composite.inputs_used.contains('temp')) ...{
        'confidence': _round(composite.confidence * 0.5, 6),
        'provisional': true,
      },
    },
    // Headline 0–21 strain envelope; raw Banister TRIMP kept as `trimp`.
    // The ROOT cause replaces the shared scorer's "strain needs a TRIMP and the
    // wake window it was measured over" — true, and useless to a reader, since
    // it names a sibling metric rather than the input that is actually missing.
    'strain': {
      ...strainMetric.toJson(),
      if (!strainMetric.present)
        'note': strainAbsentNote ?? strainMetric.note ?? kUnknownAbsenceNote,
    },
    'trimp': trimp.toJson(),
  };

  // Sleep section — ALL fields from the single SleepSegmentation. We re-emit the
  // serve-seam-expected envelopes (window/accounting/stager .value sub-maps) but
  // every figure traces to the one segmentation result (no second estimator).
  final sleep = <String, dynamic>{
    'window': _envelope(
      hasSleep ? sleepWinJson : null,
      confidence: sleepConf,
      tier: Tier.high,
      // What the window was actually read off: the device's own staged night,
      // a wearable's sparse HR (no accelerometer), or our 1 Hz streams.
      inputs: d.sleepSource == 'vendor_staged'
          ? const ['vendor_sleep_epoch']
          : isWearableFamily(d.deviceFamily)
              ? const ['hr_sparse']
              : const ['accel_1hz', 'hr_1hz'],
    ),
    'accounting': _envelope(
      hasSleep
          ? {
              'tst_sec': tstSec,
              'waso_sec': wasoSec,
              'in_bed_sec': inBedSec,
              // Wall-clock in-bed MINUS the seconds nobody watched. This is the
              // denominator `efficiency_pct` actually uses.
              'unobserved_sec': unobservedSec,
              'observed_in_bed_sec': (inBedSec == null || unobservedSec == null)
                  ? null
                  : math.max(0, inBedSec - unobservedSec),
              'efficiency_pct': effPct,
              'nrem_sec': nremSec,
              // 4-class split: Light + Deep == NREM. Deep is LOW CONFIDENCE.
              'light_sec': lightSec,
              'deep_sec': deepSec,
              'rem_sec': remSec,
              'wake_sec': wakeSec,
              'deep_low_confidence': true,
              // SLP-03 — the shape of the night, from the same per-second labels
              // the hypnogram is drawn from. `awakenings` is a FLOOR (wake
              // specificity is 29-52 %, so the true count is higher) and
              // `longest_sleep_sec` never bridges an unobserved gap.
              ...runs,
            }
          : null,
      confidence: sleepConf,
      tier: Tier.estimate,
      inputs: const ['sleep_stages'],
    ),
    // Why this night produced nothing, when the segmenter knows. Null on a
    // normal night; never render a bare dash for an absence that carries one.
    'absence_reason': absenceReason,
    // Seconds the band's own last SLEEP cut off the end of the auto window; null = rule did not apply. Provenance, never a metric.
    'band_offset_trim_sec': bandOffsetTrimSec,
    'stager': _envelope(
      hasSleep
          ? {
              // Null, not 0, for a stage the night's source does not report.
              'wake_pct': wakeSec == null ||
                      tstSec == null ||
                      inBedSec == null ||
                      inBedSec == 0
                  ? null
                  : 100.0 * wakeSec / inBedSec,
              'nrem_pct': tstSec == null || tstSec == 0
                  ? null
                  : 100.0 * (nremSec ?? 0) / tstSec,
              'rem_pct': remSec == null || tstSec == null || tstSec == 0
                  ? null
                  : 100.0 * remSec / tstSec,
              'epoch_sec': 1,
              'epochs': d.hypnoStages.length,
            }
          : null,
      confidence: sleepConf,
      tier: Tier.estimate,
      inputs: const ['hr_1hz', 'immobility'],
    ),
    // CPC is WITHDRAWN, not merely absent. Its "respiration surrogate" was the
    // NN series itself, so cpc_ratio was the RR periodogram HF/LF ratio wearing
    // a different name (measured agreement 1.0000085) — never cardiopulmonary
    // coupling. Reinstate only with a real respiration channel in the
    // signature; until then there is nothing honest to publish here.
  };

  final respiration = <String, dynamic>{
    'rsa': resp.toJson((v) => v.toJson()),
    'cvhr_apnea': cvhr.toJson((v) => v.toJson()),
    'odi': odi.toJson((v) => v.toJson()),
  };

  final wellness = <String, dynamic>{
    'skin_temp': {
      'value': skinTempZ == null ? '—' : _round(skinTempZ, 4),
      'confidence': skinTempZ == null ? 0 : (tempProvisional ? 0.25 : 0.5),
      if (skinTempZ != null && tempProvisional) 'provisional': true,
      'tier': Tier.relative,
      // Both columns: gen4 stores a raw ADC count, gen5 centi-°C. Either way
      // this is only ever a deviation from the user's OWN baseline. The two
      // never mix within one day's array — see derive_prepare.dart's
      // _skinTempFor / _skinTempUnit for the read-side gate.
      'inputs_used': const ['skin_temp_raw', 'skin_temp_c'],
      'note':
          'relative deviation (z) vs your baseline; raw sensor units, '
          'never an absolute °C',
    },
  };

  // Indexed scalars (also surfaced to metric_series by the engine).
  // ONE ESTIMATOR. `rmssd` is the sleep-session mean of 5-min-window RMSSDs —
  // the same number `ln_rmssd` (→ readiness) is the log of — or it is absent.
  // The NREM median (`clinical.rmssd_nocturnal`) and the whole-night RMSSD
  // (`scalars.rmssd_whole`, `clinical.hrv_time`) stay published under their
  // own keys; they are different statistics over differently-cleaned beats and
  // never stand in for this one (AGENTS §3.3). The fallback used to keep the
  // chart unbroken by mixing three estimators into one series.
  final rmssdScalar = sleepSessionRmssd;
  // Whole-window RMSSD kept available as a secondary detail (NOT the headline).
  final rmssdWholeScalar = (hrvT.present && hrvT.value!.rmssd != null)
      ? hrvT.value!.rmssd
      : null;
  // Abstain from a saturated, degenerate-baseline readiness rather than persist a
  // bogus ~100 that a cleaner re-derive would then snap back down (#117 bounce).
  final readinessScalar = headlineReadinessScalar(composite);
  // The z-cap can abstain even when the composite itself is `present` — a
  // saturated, degenerate-baseline artefact, not a cold-start — and that used
  // to leave `readinessAbsentDiag` null (only the `!composite.present` branch
  // above sets it), so the UI fell through to the composite's own prose, which
  // names whichever driver its renormalisation happened to refuse (e.g. temp)
  // rather than the real reason the headline is blank (edge#305). Do NOT reuse
  // `need_baseline:` here: on main an input needs >=`readinessCompositeMinBaseline`
  // points before the composite is even present, so by the time THIS branch can
  // fire "Need N more nights" is a proven-false cause. Give it its own reason,
  // carrying the z that tripped the cap plus the same per-input counts the
  // cold-start diag carries, so it renders with an actual explanation instead
  // of a bare blank.
  final zCapNote = zCapAbsentNote(composite);
  if (readinessAbsentDiag == null && zCapNote != null) {
    readinessAbsentDiag = {
      'hrv': {'value': lnToday != null, 'baseline_n': d.lnRmssdHistory.length},
      'rhr': {'value': rhrToday != null, 'baseline_n': d.rhrHistory.length},
      'resp': {'value': respToday != null, 'baseline_n': d.respHistory.length},
      'temp': {
        'value': skinTempAdc != null,
        'baseline_n': d.skinTempAdcHistory.length,
        'settled_frac': skinTempSettledFrac,
      },
      'note': zCapNote,
    };
  }
  final strainScalar = strainMetric.present ? strainMetric.value : null;

  // ── STRESS: Baevsky SI → a transparent 0–100 score (log-mapped over the
  //    plausible resting SI range [20, 600]). Resting autonomic tension; the
  //    stress screen reads this {score, si, lf_hf, rmssd, level} block directly.
  final si = stress.present ? stress.value!.si : null;
  final lfhf = hrvF.present ? hrvF.value!.lfhf : null;
  double? stressScore;
  if (si != null && si > 0) {
    final lo = math.log(20), hi = math.log(600);
    stressScore = (100 * (math.log(si) - lo) / (hi - lo)).clamp(0.0, 100.0);
  }
  final stressBlock = <String, dynamic>{
    'value': stressScore == null ? '—' : _round(stressScore, 1),
    'score': stressScore == null ? null : _round(stressScore, 1),
    'si': si == null ? null : _round(si, 2),
    'level': stress.present ? stress.value!.level : null,
    'lf_hf': lfhf == null ? null : _round(lfhf, 3),
    'rmssd': rmssdScalar == null ? null : _round(rmssdScalar, 1),
    'confidence': stress.present ? _round(stress.confidence, 4) : 0,
    'tier': Tier.estimate,
    'inputs_used': const ['rr_cleaned'],
    'note': 'Baevsky Stress Index → 0–100; resting autonomic tension (PRV).',
  };

  // ── SpO₂ from the band: none. See kSpo2Refusal above: the red and IR ADCs
  //    are one signal. The block stays so old bundles keep a shape, and it
  //    says why.
  final rejectCounts = odi.present ? odi.value!.rejectCounts : null;
  final severityCounts = odi.present ? odi.value!.severityCounts : null;
  final spo2Block = <String, dynamic>{
    'disabled': true,
    'value': null,
    'odi_per_hour': null,
    'dip_count': null,
    'analyzed_hours': null,
    'mean_dip_pct': null,
    'max_dip_pct': null,
    'longest_dip_sec': null,
    'burden_pct': null,
    'signal_coverage': null,
    'trusted_coverage': null,
    'reject_counts': rejectCounts,
    'severity_counts': severityCounts,
    'confidence': 0,
    'tier': Tier.relative,
    'inputs_used': const ['spo2_red_raw', 'spo2_ir_raw'],
    'note': kSpo2Refusal,
    'debug': <String, dynamic>{
      'sleep_samples': d.sleepTsSec.length,
    },
  };

  // ── NOCTURNAL detail: sleeping-HR nadir + waking HR. Both computable today
  //    with NO baseline; the "vs baseline" comparison is added at the seam from
  //    the rhr history series.
  final nadir = rhr.present ? rhr.value!.p1 : null;
  final wakingHr = dip.present ? dip.value!.dayMean : null;
  // Nadir INSTANT: epoch-second of the lowest valid sleeping-HR second, so the
  // nocturnal card can render "@ HH:MM" instead of "@ -". From the sleep-window
  // HR series (parallel to sleepTsSec); null when no valid sleep HR.
  int? nadirTs;
  {
    var lo = 1 << 30;
    for (var i = 0; i < d.sleepHr.length && i < d.sleepTsSec.length; i++) {
      final h = d.sleepHr[i];
      if (h > 0 && h < lo) {
        lo = h;
        nadirTs = d.sleepTsSec[i];
      }
    }
  }

  // ── HR stats over the day's valid HR (for the strain detail hr {max,avg,min}).
  //
  // THE DAY PEAK GOES THROUGH THE SAME SMOOTHING AS EVERY WORKOUT PEAK (#127).
  // This used to be a bare `reduce(math.max)` over raw 1 Hz, so one PPG motion
  // transient WAS the day's "Peak HR" on the strain card while the Heart page —
  // reading per-minute means — showed the real peak: the 160-vs-143 pair the
  // issue reported, moved to a different screen rather than fixed. `hr_max.dart`
  // is the one definition (physiological reject + 5 s rolling median, which
  // steps over a 1-2 s spike but keeps a genuine brief effort peak). Min is the
  // symmetric case: a 1 s dropout must not define the day's low either.
  final dayHrInt = [for (final h in dayHrValid) h.round()];
  final hrStats = dayHrValid.isEmpty
      ? null
      : {
          'max': smoothedMaxHr(dayHrInt, age: age?.round()) ??
              dayHrValid.reduce(math.max).round(),
          'min': smoothedMinHr(dayHrInt, age: age?.round()) ??
              dayHrValid.reduce(math.min).round(),
          'avg': _mean(dayHrValid)!.round(),
        };

  // ── SLEEP CYCLES from the per-second hypnogram (NREM→REM completions).
  // Sleep cycles — Rosenblum 2024 "fractal cycles", HRV-adapted: peak-to-peak of
  // the smoothed per-minute RMSSD series (REM peaks / NREM troughs), NOT
  // categorical REM-episode counting. Over the sleep window's RR.
  final cyc = detectSleepCycles(
    d.sleepRrMs,
    d.sleepRrTsMs,
    d.sleepOnsetSec,
    d.sleepOffsetSec,
  );
  sleep['cycles'] = [for (final c in cyc.cycles) c.toJson()];
  sleep['cycle_count'] = cyc.n;
  sleep['cycles_mean_min'] = cyc.meanDurationMin;
  // The SAME detection, in its published Metric envelope. `detectSleepCycles`
  // is the bare algorithm and returns n=0 both for "no cycles" and for "not
  // enough RR to look" — indistinguishable downstream, and the raw keys above
  // carry no tier or confidence, so the UI had to assert its own. This is the
  // honest wrapper: ESTIMATE tier, HRV-derived, absent with a reason when the
  // window cannot support detection. The raw keys stay for existing readers.
  sleep['cycles_metric'] = sleepCyclesMetric(
    d.sleepRrMs,
    d.sleepRrTsMs,
    d.sleepOnsetSec,
    d.sleepOffsetSec,
  ).toJson((v) => v.toJson());
  // The continuous z-RMSSD wave the cycle GRAPH plots ({t: epochSec, z}).
  sleep['cycle_series'] = cyc.series;

  // ── PERSONAL BASELINES (Winsorized-EWMA) ───────────────────────────────────
  // Robust, recency-weighted personal centers + spread for the metrics whose
  // units match the engine configs (rhr bpm, hrv RMSSD ms, resp brpm). Fold the
  // trailing history + today's value, then z/delta/ratio + cold-start status.
  // ADDITIVE: a richer, calibration-honest baseline block the recovery/illness
  // layer can consume; the existing readiness/skin_temp_z headlines are untouched.
  // skin_temp is intentionally EXCLUDED — its series is raw ADC, not the °C the
  // skin_temp cfg bounds expect, so feed it through a raw-ADC cfg instead.
  Map<String, dynamic> baselineBlock(
    List<double> history,
    double? today,
    MetricCfg cfg,
  ) {
    final state = Baselines.foldHistory(<double?>[
      for (final v in history) v,
    ], cfg);
    // NO STATE → NO DEVIATION. `foldHistory` returns null when not one usable
    // night has been folded; it used to hand back a state seeded at the
    // MIDPOINT of the metric's physiological bounds, and z/delta/ratio/
    // in_normal_range were then computed against a number nobody measured
    // (z ≈ −13 on a first night). Today's reading still publishes — it IS a
    // measurement — but the comparison withholds, with its reason.
    if (state == null) {
      return <String, dynamic>{
        'baseline': null,
        'spread': null,
        'n_valid': 0,
        'nights_since_update': 0,
        'status': BaselineStatus.calibrating.name,
        'value': today,
        'z': null,
        'delta': null,
        'ratio': null,
        'in_normal_range': null,
        'note': 'no_baseline:have=0,need=1',
        'mdc': null,
        'mdc_multiples': null,
      };
    }
    final dev = today == null ? null : Baselines.deviation(today, state);
    // RESP-03 — the change in DETECTABLE units. MDC = 1.96·√2·typical error;
    // `deviation` already treats σ as 1.253·spread (mean-abs-dev → sd), so feed
    // that same σ rather than a second convention. Null spread ⇒ no honest noise
    // estimate ⇒ never claim a change. `mdc_multiples` is signed: −1.4 is 1.4
    // MDC BELOW your own normal, which for HRV is the direction that matters.
    final sigma = 1.253 * state.spread;
    final m = mdc(
      RobustBaseline(
        center: state.baseline,
        scale: sigma,
        nValid: state.nValid,
        nWindow: state.nValid,
        sufficient: true,
      ),
    );
    return <String, dynamic>{
      ...state.toJson(),
      'value': today,
      'z': dev == null ? null : _round(dev.z, 3),
      'delta': dev == null ? null : _round(dev.delta, 3),
      'ratio': dev == null ? null : _round(dev.ratio, 4),
      'in_normal_range': dev?.inNormalRange,
      'mdc': m == null ? null : _round(m, 3),
      'mdc_multiples': (m == null || m <= 0 || dev == null)
          ? null
          : _round(dev.delta / m, 2),
    };
  }

  final baselines = <String, dynamic>{
    'resting_hr': baselineBlock(
      d.rhrHistory,
      rhrToday,
      Baselines.restingHRCfg,
    ),
    'hrv': baselineBlock(d.rmssdHistory, rmssdScalar, Baselines.hrvCfg),
    'resp': baselineBlock(d.respHistory, respToday, Baselines.respCfg),
    'skin_temp': baselineBlock(
      d.skinTempAdcHistory,
      skinTempAdc,
      _skinTempAdcCfg,
    ),
  };

  return <String, dynamic>{
    'date': d.date,
    'day_confidence': _round(d.dayConfidence, 4),
    'flags': d.dayFlags,
    'clinical': clinical,
    'baselines': baselines,
    'sleep': sleep,
    'zones': hrZones,
    'max_hr_used': hrMax,
    // TS-04 — WHICH ANCHORS the `zones` block above was binned on, stored with
    // the bins so a later reader can never present them as something they are
    // not. 'karvonen' = observed ceiling + measured resting HR, 'observed' =
    // measured ceiling only, 'tanaka' = the age estimate. Null when there were
    // no zones. TS-05's 28-day distribution is gated on this, not captioned.
    // WHICH STRAP measured this day, echoed onto the bundle. The zone ceiling
    // is a per-family constant, so a screen printing zone EDGES has to name the
    // strap — and `decoded_onehz` is pruned at `rawRetentionDays`, so the
    // derived day is the only place that provenance survives a quiet week.
    'device_family': d.deviceFamily,
    'zone_source': zoneSet?.source,
    'zone_max_hr': zoneSet == null ? null : _round(zoneSet.maxHr, 0),
    'zone_lower_bpm': zoneSet == null
        ? null
        : [for (final z in zoneSet.zones) _round(z.lower, 0)],
    'hr_stats': ?hrStats,
    'calories': caloriesKcal == null ? null : _round(caloriesKcal, 0),
    // WHY each absent activity figure is absent, keyed BY THE FIGURE'S OWN
    // NAME. `zones`, `max_hr_used`, `calories` and `calories_total` are stored
    // as bare values, so there is no envelope on them to carry a tier and a
    // note — this is where their reason lives, and the serve seam
    // (`LocalRepositoryImpl.getDayStrain`) attaches it to the value it hands a
    // screen. A key is present ONLY when that figure is absent.
    //
    // `calories_total` is the engine's (`_applyWakeDayFeatures`); it is listed
    // here so the two calorie figures cannot end up explained differently when
    // one gate killed both.
    'absent_notes': <String, String>{
      if (hrMax == null && ceilingAbsentNote != null)
        'max_hr_used': ceilingAbsentNote,
      if (hrZones.isEmpty) 'zones': zonesAbsentNote ?? kUnknownAbsenceNote,
      if (caloriesKcal == null && caloriesAbsentNote != null) ...{
        'calories': caloriesAbsentNote,
        'calories_total': caloriesAbsentNote,
      },
      if (strainScalar == null)
        'strain': strainAbsentNote ?? strainMetric.note ?? kUnknownAbsenceNote,
      if (!trimp.present)
        'trimp': strainAbsentNote ?? trimp.note ?? kUnknownAbsenceNote,
    },
    'respiration': respiration,
    // CV-06 (see `nightShape` above). Envelope + the epoch origin its bin
    // offsets are counted from; null origin means there were no beats to place.
    'hrv_night_shape': {
      ...nightShape.toJson((v) => v.toJson()),
      'origin_ms': hrvOriginMs,
    },
    'wellness': wellness,
    'stress': stressBlock,
    'spo2': spo2Block,
    'series': {
      'hr_curve': hrCurve,
      'strain_curve': strainCurve,
      'zone_timeline': zoneTimeline,
      'hrv_timeline': hrvTimeline,
      'hypnogram': hypnogram,
    },
    'coverage': {
      'hr_samples': d.dayHr.length,
      'hr_valid': dayHrValid.length,
      'rr_beats': d.sleepRrMs.length,
      'nn_clean': nn.length,
      'clean_fraction': _round(corrected.cleanFraction, 4),
      'sleep_seconds': inBedSec ?? 0,
      'rr_coverage': rrCov == null ? null : _round(rrCov.coverage, 4),
      'rr_duplicate_beats': rrCov?.duplicateBeats,
    },
    'readiness_absent_diag': ?readinessAbsentDiag,
    'scalars': {
      // ONE resting HR. It is nocturnal or it is absent — `rhr` and
      // `rhr_nocturnal` are now the same number, and the second key survives
      // only so the strain recompute keeps reading a key that was never wrong
      // on a bundle stored before this change. Two keys, one honest and one
      // not, is how the daytime fallback outlived the v46→47 fix: readiness
      // moved to the gated key and the CHARTED series stayed on the ungated
      // one. Delete `rhr_nocturnal` with the kAlgoVersion bump that re-derives
      // every stored bundle.
      'rhr': rhrToday,
      'rhr_nocturnal': rhrToday,
      // Headline RMSSD (sleep-session mean of 5-min windows; no fallback).
      // Whole-night RMSSD kept separately.
      'rmssd': rmssdScalar,
      'rmssd_whole': rmssdWholeScalar,
      'readiness': readinessScalar,
      // The composite z behind it — the series later days' scores are
      // calibrated against. Only when the headline itself published: a z the
      // cap withheld is an artefact, not this user's spread.
      'readiness_z': readinessScalar == null ? null : composite.value!.compositeZ,
      // Headline 0–21 strain (the screens already expect a 0–21 scale); raw
      // Banister TRIMP stays under `trimp` as the secondary "training load".
      'strain': strainScalar,
      'max_hr_used': hrMax,
      'ln_rmssd': lnToday,
      'resp_rate': respToday,
      'skin_temp_z': skinTempZ,
      // RAW nightly skin-temp ADC mean — the personal BASELINE series for
      // skin_temp_z. ALWAYS present when there's sleep+temp data (even while z is
      // still null in the ≤3-day bootstrap), so the series fills and z starts
      // computing from ~day 4. This is the series _attachHistory must feed back.
      'skin_temp_adc': skinTempAdc,
      // WH-11a — the fraction of the sleep window the temp channel actually
      // covered. Emitted, NOT gated on: no floor is defensible until we have
      // looked at what this reads on real nights.
      'skin_temp_coverage_frac': skinTempCoverage == null
          ? null
          : _round(skinTempCoverage, 4),
      // RD-15 — the settled fraction readiness's temp driver is gated on, so a
      // night whose driver was refused can be told apart from one where the
      // gate never ran. NULL means the fraction itself is unmeasurable (no
      // settle band for this band's family, or under sixty samples).
      'skin_temp_settled_frac': skinTempSettledFrac == null
          ? null
          : _round(skinTempSettledFrac, 4),
      'sdnn': hrvT.present ? hrvT.value!.sdnn : null,
      // #315 — short-window SDNN (mean of 5-min-window SDNNs over the sleep
      // NN). The whole-night `sdnn` above folds hours of HR drift into the
      // spread (~2x on a real night), which is not what Apple Health's HRV
      // SDNN means; this is what the iOS export writes. Absent with the
      // headline RMSSD's own refusal of an over-counted stream.
      'sdnn_window': rrCov?.overCounted == true
          ? null
          : sleepSdnnIndex(nn, nnTimes),
      // CV-03 — deceleration capacity (ms). Personal trend only: PRSA anchors on
      // decelerations and pulse-arrival jitter attenuates DC by an amount that
      // varies with signal quality night to night, so a rising line can be a
      // cleaner-signal line. Never a reference range, never a threshold.
      'prsa_dc': dc.present ? _round(dc.value!.capacity, 3) : null,
      // The anchors it was averaged over — belongs next to the number, always.
      'prsa_dc_anchors': dc.present ? dc.value!.anchors.toDouble() : null,
      'dip_pct': dip.present ? dip.value!.dipPct : null,
      'trimp': trimp.present ? trimp.value : null,
      'odi_per_hour': null,
      // Stress score (0–100) + SI for trends.
      'stress': stressScore,
      'stress_si': si,
      'spo2': null,
      // Active calories (Keytel) + nocturnal HR detail (nadir / waking HR).
      'calories': caloriesKcal == null ? null : _round(caloriesKcal, 0),
      'sleeping_hr_nadir': nadir,
      'sleeping_hr_nadir_ts': nadirTs?.toDouble(),
      'waking_hr': wakingHr,
      // Sleep-stage minutes + HRV freq/stability — surfaced as scalars so they
      // flow to metric_series and get day/week/month/3M trends.
      'rem_min': remSec == null ? null : (remSec / 60).roundToDouble(),
      'deep_min': deepSec == null ? null : (deepSec / 60).roundToDouble(),
      'light_min': lightSec == null ? null : (lightSec / 60).roundToDouble(),
      'tst_min': tstSec == null ? null : (tstSec / 60).roundToDouble(),
      'lf_hf': lfhf == null ? null : _round(lfhf, 3),
      'hrv_cv': hrvCv == null ? null : _round(hrvCv, 1),
      // 24/7 irregular-rhythm screen flag (1/0) → drives trend + notification.
      'irregular_rhythm_flag': irregular24h.present
          ? (irregular24h.value!.flag ? 1.0 : 0.0)
          : null,
      // Breathing-rate variability (CV) + Theil-Sen trend slope.
      'brv_cv': brv.present ? _round(brv.value!.cv, 4) : null,
      'brv_slope': brv.present && brv.value!.trendSlope != null
          ? _round(brv.value!.trendSlope!, 4)
          : null,
      // Sleep efficiency % + worn minutes → their own day/week/month/3M trends.
      'efficiency': effPct == null ? null : _round(effPct, 1),
      'worn_min': wornMin == 0 ? null : wornMin.toDouble(),
      // SLP-01 — minutes of the in-bed window nobody watched. Trended so a band
      // that has started dropping hours shows up as a trend, not as worse sleep.
      'unobserved_min': unobservedSec == null
          ? null
          : (unobservedSec / 60).roundToDouble(),
      // SLP-03 — sustained awakenings (a floor) + the longest unbroken stretch.
      'awakenings': (runs['awakenings'] as int?)?.toDouble(),
      'longest_sleep_min': (runs['longest_sleep_sec'] as int?) == null
          ? null
          : ((runs['longest_sleep_sec'] as int) / 60).roundToDouble(),
      // SLP-02 — forced-window sleep-onset latency only (see [_sleepRuns]).
      'sol_min': (runs['sol_sec'] as int?) == null
          ? null
          : ((runs['sol_sec'] as int) / 60).roundToDouble(),
      // SLP-09 / L10 — WHERE ON THE CLOCK the night sat. Mid-sleep is computed
      // every night and was thrown away; nothing can reconstruct it once the
      // 1 Hz substrate is pruned, so the value of writing it is that history
      // starts accruing NOW. FUTURE NIGHTS ONLY — there is no backfill and
      // there cannot be one.
      //
      // Both are tz-corrected LOCAL clock positions in seconds, signed,
      // relative to 04:00 local — see [sleepClockOffsetSec] for why they are
      // not a plain second-of-day.
      'midsleep_sec': sleepClockOffsetSec(
        d.sleepOffsetSec > d.sleepOnsetSec && d.sleepOnsetSec > 0
            ? d.sleepOnsetSec + (d.sleepOffsetSec - d.sleepOnsetSec) ~/ 2
            : 0,
      ),
      'sleep_onset_sec': sleepClockOffsetSec(
        d.sleepOffsetSec > d.sleepOnsetSec ? d.sleepOnsetSec : 0,
      ),
    },
  };
}

/// The anchor the two SLP-09 clock series are measured from: 04:00 local.
///
/// Any fixed hour would do; 04:00 is the one furthest from a normal bedtime
/// AND from a normal wake time, so neither series sits near the wrap.
const int _sleepClockAnchorSec = 4 * 3600;

/// A sleep instant's LOCAL clock position, in seconds either side of 04:00 —
/// negative before, positive after. Null for an absent window (never 0, which
/// is a real reading: exactly 04:00).
///
/// STORED UNWRAPPED, and that is the whole point. As a plain second-of-day,
/// 23:30 → 01:30 is a two-hour shift that reads as MINUS 22 hours, and binary
/// segmentation over that series finds a beautiful change-point which is a
/// modulo artifact and nothing else. Measuring signed distance from an anchor
/// nobody sleeps through puts a night's normal range on one continuous stretch
/// of the axis, so a difference between two nights is the real difference.
///
/// TIMEZONE. Converted with the offset in effect AT THAT INSTANT, not today's:
/// a flight or a DST transition moves the clock without moving the behaviour,
/// and a change-point search reading raw UTC would report the flight as a
/// lifestyle shift. That is the guard, not a nicety — see [tzOffsetSecondsAt].
double? sleepClockOffsetSec(int epochSec) {
  if (epochSec <= 0) return null;
  final local = epochSec + tzOffsetSecondsAt(epochSec);
  final secOfDay = ((local % 86400) + 86400) % 86400;
  var offset = secOfDay - _sleepClockAnchorSec;
  if (offset > 43200) offset -= 86400;
  if (offset <= -43200) offset += 86400;
  return offset.toDouble();
}

// ── helpers (pure) ───────────────────────────────────────────────────────────

/// Per-window RSA respiratory rates (br/min) for the BRV estimator. Buckets the
/// cleaned NN into [windowMs] (~30-min) bins by beat time and runs [rsaRespRate]
/// on each bin with ≥[minBeats] beats; keeps only resolved windows.
List<double> _respPerWindow(
  List<double> nn,
  List<double> nnTimes, {
  double windowMs = 1800000.0,
  int minBeats = 60,
}) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = ((nnTimes[i] - t0) / windowMs).floor();
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < minBeats) continue;
    // NN is already artifact-corrected upstream → artifactFraction 0.
    final r = rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
  return out;
}

/// Wrap a value sub-map in the {value,confidence,tier,inputs_used} envelope the
/// serve seam reads via `.value`. Null inner → honest "—".
Map<String, dynamic> _envelope(
  Map<String, dynamic>? value, {
  required double confidence,
  required String tier,
  required List<String> inputs,
}) => {
  'value': value ?? '—',
  'confidence': value == null ? 0 : _round(confidence, 6),
  'tier': tier,
  'inputs_used': inputs,
};

/// Build a per-second NREM bool mask ALIGNED to the NN window the robust
/// nocturnal-RMSSD estimator uses.
///
/// `nocturnalRmssd` is t0-relative to `nnTimes.first`, masking a window by its
/// midpoint SECOND counted from that t0. CRUCIAL: `correctRr` RE-BASES nnTimesMs
/// to start near zero (NOT epoch ms), so the mask is indexed in seconds elapsed
/// since the first NN beat — NOT epoch seconds. The first NN beat's absolute
/// instant is the first ORIGINAL RR timestamp (`d.sleepRrTsMs.first`, epoch ms),
/// so mask index `s` maps to absolute second `firstRrSec + s`, then to the hypno
/// index `firstRrSec + s − sleepOnsetSec` (hypnoStages run per-second from
/// sleepOnsetSec). Returns null if we lack NN times / RR times / stages (the
/// estimator then runs unmasked over all sleep windows — still robust, just not
/// NREM-restricted).
List<bool>? _nremMaskAlignedToNn(
  DayBundleInput d,
  List<double> nnTimes,
  List<double> nnTimesSrcMs,
) {
  if (nnTimes.isEmpty ||
      nnTimesSrcMs.isEmpty ||
      d.hypnoStages.isEmpty ||
      d.sleepOnsetSec == 0) {
    return null;
  }
  // Absolute epoch second of the first NN beat (from the ORIGINAL RR times).
  final firstRrSec = (nnTimesSrcMs.first / 1000.0).floor();
  // Span in seconds is measured on the RE-BASED nn time base (starts ~0).
  final span = (nnTimes.last / 1000.0).floor() + 1;
  if (span <= 0) return null;
  final mask = List<bool>.filled(span, false);
  for (var s = 0; s < span; s++) {
    final hypnoIdx = (firstRrSec + s) - d.sleepOnsetSec;
    if (hypnoIdx >= 0 && hypnoIdx < d.hypnoStages.length) {
      // NREM = Light + Deep in the 4-class stream (was the single 'nrem' label).
      final lbl = d.hypnoStages[hypnoIdx];
      mask[s] = lbl == 'light' || lbl == 'deep' || lbl == 'nrem';
    }
  }
  return mask;
}

/// Day-side HR: the day-span HR samples that fall OUTSIDE the sleep window
/// (and before tonight's sleep, see [DayBundleInput.tonightSleepOnsetSec]).
List<double> _dayHrOutsideSleep(DayBundleInput d) {
  final out = <double>[];
  for (var i = 0; i < d.dayHr.length; i++) {
    final t = d.dayTsSec[i];
    if (_asleepAt(d, t)) continue;
    out.add(d.dayHr[i].toDouble());
  }
  return out;
}

/// Whether [t] is inside this morning's sleep window or tonight's sleep.
bool _asleepAt(DayBundleInput d, int t) =>
    (t >= d.sleepOnsetSec && t < d.sleepOffsetSec) ||
    (d.tonightSleepOnsetSec > 0 && t >= d.tonightSleepOnsetSec);

/// Per-minute mean HR over the WAKE span (day minus sleep window), valid only.
class _WakeMinuteHr {
  final int tsSec;
  final double hr;
  const _WakeMinuteHr(this.tsSec, this.hr);
}

List<_WakeMinuteHr> _perMinuteWakeSeries(DayBundleInput d) {
  // A wearable that stores one HR every few minutes (inputs/garmin_inputs.dart)
  // has each reading stand for the minutes up to the next; every other
  // family, the bands included, is one minute per bucket as before. A strap's
  // 1 Hz seconds laid over such a day ([withStrapSessions]) stand for their
  // own minute only, and no reading spreads past the next one.
  final span = (calibrationFor(kHrCadenceSec, d.deviceFamily) ?? 60) ~/ 60;
  final n = d.dayHr.length;
  final buckets = <int, List<double>>{};
  for (var i = 0; i < n; i++) {
    if (d.dayHr[i] <= 0) continue;
    final t = d.dayTsSec[i];
    if (_asleepAt(d, t)) continue; // skip sleep
    (buckets[t ~/ 60] ??= []).add(d.dayHr[i].toDouble());
    // Inside a 1 Hz run (a second or two after the one before); a
    // reading further off is the wearable's own, the first after a strap
    // run included, and stands for its minutes.
    if (i > 0 && t - d.dayTsSec[i - 1] <= kOneHzRunGapSec) continue;
    final next = i + 1 < n ? d.dayTsSec[i + 1] : t + 60 * span;
    if (next - t < 60) continue;
    for (var k = 1;
        k < span && t + 60 * k < next && !_asleepAt(d, t + 60 * k);
        k++) {
      (buckets[t ~/ 60 + k] ??= []).add(d.dayHr[i].toDouble());
    }
  }
  final keys = buckets.keys.toList()..sort();
  return [for (final k in keys) _WakeMinuteHr(k * 60, _mean(buckets[k]!)!)];
}

Map<String, int> _wakeZoneMinutesFromSeries(
  List<_WakeMinuteHr> wakeHr,
  HeartRateZoneSet zoneSet,
) {
  final samples = <HrSample>[
    for (final p in wakeHr) HrSample(p.tsSec * 1000.0, p.hr),
  ];
  // Null = no cadence `sampleCadenceSeconds` will vouch for; `const {}` is the
  // caller's existing absent state (see `hrZones` at its declaration).
  return HeartRateZones.timeInZone(samples, zoneSet)?.toRoundedMinuteMap() ??
      const {};
}

List<Map<String, num>> _zoneTimeline(
  List<_WakeMinuteHr> wakeHr,
  HeartRateZoneSet zoneSet,
) {
  return [
    for (final p in wakeHr) {'t': p.tsSec, 'z': zoneSet.zoneNumber(p.hr)},
  ];
}

List<Map<String, num>> _strainCurve(
  List<_WakeMinuteHr> wakeHr, {
  required double? restingHr,
  required double? maxHr,
  required String? sex,
  required double? quietHrr,
}) {
  if (wakeHr.isEmpty || sex == null) return const [];
  // The headline's own arithmetic, minute by minute (`strainCurveFromSeries`),
  // so the last point IS the headline and exercise already banked never falls
  // back out through a quiet afternoon. Null — no level, or bad anchors —
  // leaves the curve empty, which the strain screen explains from the note.
  final curve = strainCurveFromSeries(
    [for (final p in wakeHr) p.hr],
    restingHr: restingHr,
    maxHr: maxHr,
    quietHrr: quietHrr,
    sex: workoutSex(sex) == 'female' ? Sex.female : Sex.male,
  );
  if (curve == null) return const [];
  return [
    for (var i = 0; i < wakeHr.length; i++)
      {'t': wakeHr[i].tsSec, 'v': _round(curve[i], 2)},
  ];
}

double? _mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// SDNN index over the night: the arithmetic mean of the SDNNs of consecutive
/// 5-minute windows of cleaned NN (Task Force of the ESC/NASPE 1996, "SDNN
/// index"). Windows are counted from the first beat, as `hrvTime` segments
/// them, but a window joins the mean only with at least [minBeats] beats, the
/// same floor the nightly RMSSD puts on its windows, so a few beats across a
/// dropout edge never weigh as much as a full window. Null when no window
/// qualifies.
double? sleepSdnnIndex(
  List<double> nnMs,
  List<double> nnTimesMs, {
  int minBeats = kMinDiffsPerRmssdWindow + 1,
}) {
  if (nnMs.isEmpty || nnMs.length != nnTimesMs.length) return null;
  final windows = <int, List<double>>{};
  final t0 = nnTimesMs.first;
  for (var i = 0; i < nnMs.length; i++) {
    (windows[((nnTimesMs[i] - t0) / 300000).floor()] ??= []).add(nnMs[i]);
  }
  final sds = [
    for (final w in windows.values)
      if (w.length >= minBeats) _stddev(w)!,
  ];
  return _mean(sds);
}

double? _stddev(List<double> xs) {
  if (xs.length < 2) return null;
  final m = _mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

double _round(double v, int dp) {
  final p = math.pow(10, dp);
  return (v * p).round() / p;
}

/// HR curve downsampled to ~per-minute {t: epochSec, v: bpm} (valid only).
List<Map<String, num>> _downsampleHr(List<int> tsSec, List<int> hr) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < hr.length; i++) {
    if (hr[i] <= 0) continue;
    final min = tsSec[i] ~/ 60;
    (buckets[min] ??= []).add(hr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [
    for (final k in keys) {'t': k * 60, 'v': _mean(buckets[k]!)!.round()},
  ];
}

/// HRV timeline: RMSSD over rolling 5-min windows of cleaned NN, {t, v}.
///
/// `t` is EPOCH SECONDS. [originMs] is the wall clock at `nnTimes == 0` (see
/// the call site); with no origin there is no honest x-axis, so nothing is
/// emitted rather than a curve stamped in 1970.
List<Map<String, num>> _hrvTimeline(
  List<double> nn,
  List<double> nnTimes,
  double? originMs,
) {
  if (nn.length < 10 || nnTimes.length != nn.length || originMs == null) {
    return const [];
  }
  const winMs = 300000.0; // 5 min
  final out = <Map<String, num>>[];
  var lo = 0;
  for (var i = 0; i < nn.length; i++) {
    while (nnTimes[i] - nnTimes[lo] > winMs) {
      lo++;
    }
    // A FULL window, or nothing. `lo` cannot move until 5 min have elapsed, so
    // before that `[lo..i]` is a partial window — the first point used to be an
    // RMSSD over 10 beats (~8 s) drawn on a line documented as rolling 5-min
    // windows, with nothing marking it as the outlier-prone sample it is.
    if (nnTimes[i] - nnTimes[0] < winMs) continue;
    if (i - lo >= 10) {
      var ssd = 0.0;
      for (var k = lo + 1; k <= i; k++) {
        final diff = nn[k] - nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / (i - lo));
      final tSec = ((originMs + nnTimes[i]) / 1000).round();
      if (out.isEmpty || tSec - out.last['t']! > 60) {
        out.add({'t': tSec, 'v': _round(rmssd, 1)});
      }
    }
  }
  return out;
}

/// Hypnogram segments {start,end,stage} (epoch seconds) from the single-source
/// per-second stage labels (d.hypnoStages over the sleep window). Display-ready.
List<Map<String, dynamic>> _hypnogramSegments(DayBundleInput d) {
  final stages = d.hypnoStages;
  if (stages.isEmpty || d.sleepOnsetSec == 0) return const [];
  final t0 = d.sleepOnsetSec;
  final segs = <Map<String, dynamic>>[];
  int segStart = 0;
  String cur = stages.first;
  for (var i = 1; i < stages.length; i++) {
    if (stages[i] != cur) {
      segs.add({'start': t0 + segStart, 'end': t0 + i, 'stage': cur});
      cur = stages[i];
      segStart = i;
    }
  }
  segs.add({'start': t0 + segStart, 'end': t0 + stages.length, 'stage': cur});
  return segs;
}

/// Whether a 4-class label is SLEEP. `unobserved` is not a stage and not wake —
/// it is a second the band did not watch, and it belongs to neither side.
bool _isSleepStage(String s) => s == 'light' || s == 'deep' || s == 'rem';

/// Sustained-awakening threshold. A CHOICE, not physiology: the 3-15 s cortical
/// arousals PSG counts are invisible to a 1 Hz wrist, so anything shorter than
/// this we cannot see and anything we do count is a floor, never a total.
const int kAwakeningMinSec = 300;

/// Run decomposition over the same per-second labels [_hypnogramSegments] uses,
/// so both readers share one definition of where a run ends.
///
/// Returns `{awakenings, longest_sleep_sec, sol_sec}`, each null when it cannot
/// be said honestly:
///   * `awakenings` — WAKE runs of ≥ [kAwakeningMinSec] strictly INSIDE the
///     sleep period (leading/trailing wake is not an awakening).
///   * `longest_sleep_sec` — the longest unbroken sleep run. Runs TERMINATE at
///     `unobserved`, never merge across it: bridging a three-hour hole prints a
///     fabricated five-hour stretch.
///   * `sol_sec` — seconds from window start to the first sleep second, and ONLY
///     on a user-forced window. On the auto path the window is built by
///     `_classifyStill` over gravity, gated on HR-in-band, so it cannot begin
///     before you are already lying still with a sleep-ish heart rate — the
///     40-minutes-of-tossing case falls OUTSIDE the window and would report a
///     latency near zero. Also null when the leading edge is unobserved: we did
///     not watch you fall asleep.
Map<String, dynamic> _sleepRuns(DayBundleInput d) {
  final stages = d.hypnoStages;
  const absent = {
    'awakenings': null,
    'longest_sleep_sec': null,
    'sol_sec': null,
  };
  if (stages.isEmpty) return absent;

  final firstSleep = stages.indexWhere(_isSleepStage);
  if (firstSleep < 0) return absent; // nothing staged as sleep — no runs

  var lastSleep = stages.length - 1;
  while (lastSleep > firstSleep && !_isSleepStage(stages[lastSleep])) {
    lastSleep--;
  }

  var awakenings = 0, longest = 0, run = 0, wake = 0;
  for (var i = firstSleep; i <= lastSleep; i++) {
    final s = stages[i];
    if (_isSleepStage(s)) {
      run++;
      if (run > longest) longest = run;
      if (wake >= kAwakeningMinSec) awakenings++;
      wake = 0;
    } else {
      run = 0;
      // Only a WAKE run counts toward an awakening; an unobserved gap breaks
      // the sleep run (above) but is not evidence that you woke up.
      wake = s == 'wake' ? wake + 1 : 0;
    }
  }
  // A trailing wake run inside the sleep period is only possible if it is
  // followed by sleep, which the loop already counted, so nothing to flush.

  final forced = d.sleepSource == 'manual' || d.sleepSource == 'confirmed';
  final leadingObserved = !stages
      .sublist(0, firstSleep)
      .any((s) => s == 'unobserved');
  return {
    'awakenings': awakenings,
    'longest_sleep_sec': longest,
    'sol_sec': (forced && leadingObserved) ? firstSleep : null,
  };
}

/// The median gap (seconds) between consecutive [tsSec] at or over
/// [minGapSec] (so a strap's 1 Hz seconds laid into a wearable's day do not
/// set it), or null with no such gap.
int? _medianGapSec(List<int> tsSec, {int minGapSec = 1}) {
  final gaps = [
    for (var i = 1; i < tsSec.length; i++)
      if (tsSec[i] - tsSec[i - 1] >= minGapSec) tsSec[i] - tsSec[i - 1],
  ]..sort();
  return gaps.isEmpty ? null : gaps[gaps.length ~/ 2];
}
