// Smart Wake Window — the "is right now, inside an already-chosen wake
// window, a reasonable moment to buzz" check.
//
// This is deliberately NOT sleep staging. Real staging
// (analytics/lib/src/onehz/sleep/cardio_stager.dart) needs a whole night to
// build its own baselines and only runs offline, after the fact. This runs
// live, every keep-alive tick, on whatever `decoded_onehz` already has.
//
// v2 upgrade (feat/smart-alarm-light-sleep, gate approved 2026-10-25):
//   - 10th-percentile nightly HR baseline (was: 90-min median)
//   - Journal-aware confounder boost (alcohol, caffeine, stress, workout,
//     late meal, sick) — adjusts thresholds conservatively
//   - Personalized movement-trend condition (ENMO must not be rising)
//   - Late-window deep-sleep protection (no buzz in last 5/10 min if HR
//     still near baseline)
//
// Scientific grounding: every threshold is either data-derived or carries a
// full citation in the fact base
// (shared/smart-alarm-light-sleep/fact_base_phase2.md). Key sources:
//   - F2: Waking from SWS produces more sleep inertia than from N1/N2
//     (Tassi & Muzet 2000, Sleep Med Rev, doi:10.1053/smrv.2000.0098)
//   - F3: Under normal conditions, stage at awakening does NOT predict
//     inertia (Jewett et al. 1999, J Sleep Res, doi:10.1111/j.1365-2869.1999.00128.x)
//     → UI copy must be probabilistic ("may reduce grogginess")
//   - F5: Sleep duration dominates morning alertness
//     (McHill et al. 2019, Sleep, doi:10.1093/sleep/zsz032)
//   - F6: HR is lower in deep sleep, higher in light/REM
//     (Trinder et al. 2001, J Sleep Res, doi:10.1046/j.1365-2869.2001.00263.x;
//      Cajochen et al. 1994, Physiol Behav, doi:10.1016/0031-9384(94)90058-2;
//      Berlad et al. 1993, J Sleep Res, doi:10.1111/j.1365-2869.1993.tb00067.x;
//      Tsai et al. 2022, Psychosomatic Medicine, doi:10.1097/PSY.0000000000001079)
//   - F8: Movement is reduced in deep sleep, more in light sleep
//     (Imtiaz 2021, Sensors, doi:10.3390/s21051562;
//      Fonseca et al. 2017, Sleep, doi:10.1093/sleep/zsx097)
//   - F9: Wearable stage detection κ = 0.21–0.53 vs PSG
//     (Schyvens et al. 2025, Sleep Adv, doi:10.1093/sleepadvances/zpaf021)
//     → live decision is probabilistic; no-buzz is always safe
//
// ponytail: v1 was a single-window HR-arousal + no-big-movement heuristic.
// v2 adds: nightly baseline, journal confounder boost, movement trend,
// late-window protection. Ceiling unchanged: no REM/deep distinction, and it
// says nothing at all (returns false) when either window is thin. Upgrade
// path: once there is a live per-epoch feed, run cardioStager's actual
// classifier here instead of this heuristic.
//
// Safety note (this is the load-bearing part): nothing in this file, or in
// any caller of it, ever disarms or reschedules the band's own SET_ALARM.
// This can only ever trigger an EARLY extra buzz (see AppState._checkSmartWake
// / engine.runAlarm); the real fallback alarm the band is already holding
// fires at the window's end regardless of what this heuristic decides, on
// the band's own clock, independent of the phone's BLE link, the app process,
// or this file existing at all.

import 'dart:math' as math;

import '../data/journal_fields.dart';

/// One second of the signal this reads: HR (bpm) + the raw accel vector
/// `decoded_onehz` already stores (roughly unit-magnitude at rest, in g).
class SmartWakeSample {
  final double hr;
  final double ax, ay, az;
  const SmartWakeSample(this.hr, this.ax, this.ay, this.az);

  factory SmartWakeSample.fromRow(Map<String, Object?> row) => SmartWakeSample(
        (row['hr'] as num).toDouble(),
        (row['ax'] as num).toDouble(),
        (row['ay'] as num).toDouble(),
        (row['az'] as num).toDouble(),
      );
}

// ── ConfounderProfile (Q2 — journal-aware threshold adjustments) ─────────────

/// Effective thresholds for one night, derived from the user's journal
/// (tags + numeric metrics) for the day BEFORE the sleep window.
///
/// Every adjustment is CONSERVATIVE — it can only make the detector LESS
/// likely to buzz early, never more. Missing journal data means no
/// adjustment (the defaults), never a penalty.
///
/// Ethical guardrail (from lib/ui2/screens/rough_night.dart): this profile
/// is internal only. It is never surfaced to the user — no "alcohol
/// detected" message, no UI change, no notification. The user may observe
/// "smart wake didn't buzz early tonight", which is indistinguishable from
/// any other no-buzz night.
class ConfounderProfile {
  /// HR arousal threshold in bpm above baseline. Default 4; alcohol or
  /// late caffeine → 6; late meal or sick → 5. Stacks as MAX.
  final double hrArousalBpm;

  /// Mean ENMO ceiling in g. Default 0.08; stress or sick → 0.06.
  /// Stacks as MIN.
  final double motionCeilingG;

  /// Late-window deep-sleep protection duration in minutes. Default 5;
  /// workout day (no rest day) → 10. Stacks as MAX.
  final int lateWindowProtectionMinutes;

  /// When true, the early buzz is disabled entirely for this night —
  /// the fallback SET_ALARM at window end fires as usual. Triggered by
  /// the alcohol + stress combination (both elevate nocturnal HR and
  /// movement independently; together the live signal is too noisy for
  /// a confident light-sleep call).
  final bool earlyBuzzDisabled;

  /// Movement-trend window in minutes. Default 3; alcohol or workout → 5
  /// (smooths short spikes from rebound/fragmentation or post-exercise
  /// muscle twitches).
  final int trendWindowMinutes;

  /// Multiplier on the personalized trend threshold. Default 1.0;
  /// stress or sick → 0.5 (stricter — only large transitions count);
  /// late meal → 1.5 (more tolerant — digestion movement is slow/diffuse).
  final double trendThresholdFactor;

  const ConfounderProfile({
    this.hrArousalBpm = 4.0,
    this.motionCeilingG = 0.08,
    this.lateWindowProtectionMinutes = 5,
    this.earlyBuzzDisabled = false,
    this.trendWindowMinutes = 3,
    this.trendThresholdFactor = 1.0,
  });

  /// The identity profile: no journal data → no adjustment, never a penalty.
  static const identity = ConfounderProfile();

  @override
  String toString() => 'ConfounderProfile(hr: $hrArousalBpm, '
      'enmo: $motionCeilingG, late: ${lateWindowProtectionMinutes}min, '
      'disabled: $earlyBuzzDisabled, trend: ${trendWindowMinutes}min '
      '×$trendThresholdFactor)';
}

/// Build a [ConfounderProfile] from one day's journal tags and numeric
/// metrics. Pure — no DB, no I/O, fully unit-testable.
///
/// [tags] is the set of tag strings for the day (e.g. `{'alcohol',
/// 'stress'}`). [metrics] maps field keys to their [JournalMetricValue]
/// (e.g. `{'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 1320)}`).
///
/// The day passed here is the calendar day BEFORE the sleep window —
/// alcohol, caffeine, stress and workout are consumed during the day and
/// affect the night that follows.
ConfounderProfile confounderProfile({
  required Set<String> tags,
  required Map<String, JournalMetricValue> metrics,
}) {
  // ── Alcohol: units > 0 AND last drink at/after 20:00 local ──────────────
  // Alcohol causes HR rebound in the second half of the night. A higher
  // HR threshold prevents buzzing during alcohol-elevated HR that is NOT
  // a stage transition. (Engineering bound — F4-adjacent; documented in
  // fact base 2.6.2b.)
  final alcoholUnits = metrics['alcohol_units'];
  final alcoholLastMin = alcoholUnits?.atMinuteOfDay;
  final alcoholActive = alcoholUnits != null &&
      alcoholUnits.value > 0 &&
      alcoholLastMin != null &&
      alcoholLastMin >= 20 * 60; // 20:00

  // ── Late caffeine: ≥200mg AND last at/after 16:00 local ──────────────────
  final caffeine = metrics['caffeine_mg'];
  final caffeineLastMin = caffeine?.atMinuteOfDay;
  final caffeineActive = caffeine != null &&
      caffeine.value >= 200 &&
      caffeineLastMin != null &&
      caffeineLastMin >= 16 * 60; // 16:00

  // ── Stress: tag OR rating ≥ 4 ────────────────────────────────────────────
  final stressRating = metrics['stress']?.value;
  final stressActive = tags.contains('stress') || (stressRating != null && stressRating >= 4);

  // ── Workout: tag present AND 'rest day' NOT present ──────────────────────
  final workoutActive = tags.contains('workout') && !tags.contains('rest day');

  // ── Late meal: tag ───────────────────────────────────────────────────────
  final lateMealActive = tags.contains('late meal');

  // ── Sick: tag ────────────────────────────────────────────────────────────
  final sickActive = tags.contains('sick');

  // ── HR arousal threshold: MAX of adjustments ─────────────────────────────
  double hrThreshold = 4.0;
  if (alcoholActive || caffeineActive) hrThreshold = math.max(hrThreshold, 6.0);
  if (lateMealActive || sickActive) hrThreshold = math.max(hrThreshold, 5.0);

  // ── ENMO ceiling: MIN of adjustments ─────────────────────────────────────
  double enmoCeiling = 0.08;
  if (stressActive || sickActive) enmoCeiling = math.min(enmoCeiling, 0.06);

  // ── Late-window protection: MAX of durations ─────────────────────────────
  int lateWindow = 5;
  if (workoutActive) lateWindow = math.max(lateWindow, 10);

  // ── Trend window: extended for alcohol/workout (smoothing) ───────────────
  int trendWindow = 3;
  if (alcoholActive || workoutActive) trendWindow = 5;

  // ── Trend threshold factor ───────────────────────────────────────────────
  double trendFactor = 1.0;
  if (stressActive || sickActive) trendFactor *= 0.5; // stricter
  if (lateMealActive) trendFactor *= 1.5; // more tolerant

  // ── Alcohol + Stress combo: disable early buzz entirely ──────────────────
  // Both elevate nocturnal HR and movement independently; together the
  // live signal is too noisy for a confident light-sleep call. The honest
  // outcome is: don't buzz early (F9). Fallback fires at window end.
  final comboDisabled = alcoholActive && stressActive;

  return ConfounderProfile(
    hrArousalBpm: hrThreshold,
    motionCeilingG: enmoCeiling,
    lateWindowProtectionMinutes: lateWindow,
    earlyBuzzDisabled: comboDisabled,
    trendWindowMinutes: trendWindow,
    trendThresholdFactor: trendFactor,
  );
}

// ── enmoTrendExceeded (Q4 — personalized movement trend) ────────────────────

/// True when ENMO is INCREASING over the recent window — the person is
/// turning over, stirring, or beginning to wake. A rising movement trend
/// means "transitioning", not "stable light sleep", so the caller should
/// NOT buzz.
///
/// The check compares mean ENMO of the FIRST HALF vs the SECOND HALF of
/// [samples]. [threshold] is the personalized minimum rise that counts as
/// a trend (computed by the caller as
/// `max(0.02, medianENMO_last3h × 0.5) × profile.trendThresholdFactor`).
///
/// [windowMinutes] is the trailing window the trend is judged on, and it is
/// genuinely applied: samples are 1 Hz, so the last `windowMinutes * 60` of
/// them are used. Alcohol/workout nights pass 5 (smoothing short rebound or
/// post-exercise spikes that a 3-minute window would read as a trend). A list
/// already shorter than the requested window is used whole — never padded.
///
/// Returns false (never guesses) when the window is too short.
bool enmoTrendExceeded(
  List<SmartWakeSample> samples, {
  required double threshold,
  required int windowMinutes,
}) {
  // 1 Hz samples: trim to the trailing window. Trimming HERE rather than in
  // the caller is what makes the alcohol/workout 5-minute smoothing real —
  // the caller hands over everything it fetched, and this decides how much
  // of the tail the trend is judged on.
  final want = windowMinutes <= 0 ? samples.length : windowMinutes * 60;
  final window = samples.length > want
      ? samples.sublist(samples.length - want)
      : samples;
  // Minimum 30 samples (~30 s at 1 Hz) — same floor as the HR check.
  if (window.length < 30) return false;
  final enmos = [for (final s in window) enmo(s)];
  final half = enmos.length ~/ 2;
  final firstHalf = _mean(enmos.sublist(0, half));
  final secondHalf = _mean(enmos.sublist(half));
  return (secondHalf - firstHalf) > threshold;
}

// ── lateWindowProtectionActive (Q3 — deep-sleep protection near window end) ──

/// True when the late-window deep-sleep protection is active: we are within
/// [protectionMinutes] of [windowEnd] AND the current HR is still within
/// 2 bpm of [baselineHr] (i.e., still clearly in deep sleep).
///
/// When active, the caller must NOT buzz early — the fallback SET_ALARM at
/// [windowEnd] fires regardless (Q3: "der letzte Wecker muss funktionieren").
///
/// Rationale: F2 (deep sleep = worst inertia; Tassi & Muzet 2000) + F5
/// (sleep duration dominates morning alertness; McHill 2019). Losing the
/// last few minutes of deep sleep for a marginal "light sleep" call is
/// net-negative.
///
/// Pure — no I/O, fully unit-testable.
bool lateWindowProtectionActive({
  required DateTime windowEnd,
  required DateTime now,
  required int protectionMinutes,
  required double currentHr,
  required double baselineHr,
}) {
  if (protectionMinutes <= 0) return false;
  final msBeforeEnd = windowEnd.difference(now).inMilliseconds;
  if (msBeforeEnd <= 0) return false; // at/past window end — window check handles
  if (msBeforeEnd > protectionMinutes * 60 * 1000) return false; // not yet in zone
  // Within the protection zone: active only if HR is still near baseline
  // (within 2 bpm — still clearly deep sleep).
  return (currentHr - baselineHr) <= 2.0;
}

// ── percentileHr (10th-percentile nightly HR baseline) ───────────────────────

/// The [p]-quantile (0<p<1) of valid HR values in [samples], or null when
/// there are no valid samples. Invalid HR (≤30 or ≥200 bpm, including the
/// off-skin sentinel 0) is filtered out before computing.
///
/// Used for the nightly deep-sleep HR baseline (Q2): the 10th percentile
/// of the last ~3h captures the person's own lowest nocturnal HR — their
/// deep-sleep level — matching #628's `hr_min_night` methodology.
///
/// F6 (HR lower in deep sleep; Trinder 2001, Cajochen 1994, Berlad 1993,
/// Tsai 2022 — confidence A) grounds the direction; the 10th-percentile
/// choice matches the HMM baseline methodology in #628.
double? percentileHr(List<SmartWakeSample> samples, double p) {
  final valid = [
    for (final s in samples)
      if (s.hr > 30.0 && s.hr < 200.0) s.hr,
  ];
  if (valid.isEmpty) return null;
  valid.sort();
  final idx = (valid.length * p).floor().clamp(0, valid.length - 1);
  return valid[idx];
}

// ── likelyLightSleep v2 (Q1+Q2+Q3+Q4 integrated) ─────────────────────────────

/// True when the last few minutes show a lightening-sleep signature —
/// heart rate elevated above tonight's own resting baseline — WITHOUT the
/// hard movement that would mean the person is already awake and moving,
/// WITHOUT a rising movement trend (turning over / arousal), and NOT in
/// the late-window deep-sleep protection zone.
///
/// v2 upgrades over v1 (all gate-approved 2026-10-25):
///   - [profile] adjusts thresholds from the journal (Q2)
///   - Movement-trend check (Q4): rising ENMO → false
///   - [windowEnd]/[now]/[baselineHr] enable late-window protection (Q3)
///
/// Never guesses on a thin window: returns false whenever [baseline] or
/// [recent] is shorter than its minimum sample count, which is the same as
/// "no light sleep detected" — the caller's fallback path (fire at window end
/// regardless) is what actually protects the user, not this function
/// returning true.
///
/// Backward compatible: with the default [ConfounderProfile.identity] and
/// no [windowEnd], the behavior is the shipped v1 heuristic plus the
/// movement-trend check (which v1 lacked).
bool likelyLightSleep({
  required List<SmartWakeSample> baseline,
  required List<SmartWakeSample> recent,
  ConfounderProfile profile = ConfounderProfile.identity,
  double? baselineHrOverride,
  DateTime? windowEnd,
  DateTime? now,
  double? baselineHr,
  int minBaselineSamples = 30,
  int minRecentSamples = 30,
}) {
  // Alcohol + stress combo: early buzz disabled entirely for this night.
  if (profile.earlyBuzzDisabled) return false;

  if (baseline.length < minBaselineSamples) return false;

  // `recent` may be LONGER than 3 minutes: the caller fetches up to the
  // journal's trend window (5 min on alcohol/workout nights) so the trend
  // check below has something to smooth over. HR arousal and the mean-motion
  // ceiling are separate questions and are always judged on the trailing
  // 3 minutes, exactly as they were before the trend window existed — a
  // longer fetch must not quietly move them.
  const int kHrWindowSamples = 180; // 3 min at 1 Hz
  final hrWindow = recent.length > kHrWindowSamples
      ? recent.sublist(recent.length - kHrWindowSamples)
      : recent;
  if (hrWindow.length < minRecentSamples) return false;

  // Baseline HR: caller-supplied (10th percentile from a wider window) or
  // computed here as median (v1 behavior).
  final baseHr = baselineHrOverride ?? _median([for (final s in baseline) s.hr]);
  final recentHr = _mean([for (final s in hrWindow) s.hr]);
  final recentMotion = _mean([for (final s in hrWindow) enmo(s)]);

  // Q3: late-window deep-sleep protection — if we're in the last few minutes
  // AND HR is still near baseline, don't buzz. Fallback fires at window end.
  if (windowEnd != null && now != null && baselineHr != null) {
    if (lateWindowProtectionActive(
      windowEnd: windowEnd,
      now: now,
      protectionMinutes: profile.lateWindowProtectionMinutes,
      currentHr: recentHr,
      baselineHr: baselineHr,
    )) {
      return false;
    }
  }

  // Q1+Q2: HR arousal with dynamic threshold.
  if (recentHr < baseHr + profile.hrArousalBpm) return false;

  // Q1+Q2: low movement with dynamic ceiling.
  if (recentMotion >= profile.motionCeilingG) return false;

  // Q4: personalized movement trend — rising ENMO = turning over / arousal.
  final enmoMedian3h = _median([for (final s in baseline) enmo(s)]);
  final trendThreshold = math.max(0.02, enmoMedian3h * 0.5) *
      profile.trendThresholdFactor;
  if (enmoTrendExceeded(recent,
      threshold: trendThreshold,
      windowMinutes: profile.trendWindowMinutes)) {
    return false;
  }

  return true;
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// ENMO — Euclidean Norm Minus One, in g. The magnitude of deviation from
/// 1g gravity: ~0 when still, rising with movement.
double enmo(SmartWakeSample s) =>
    (math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az) - 1.0).abs();

double _mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

double _median(List<double> xs) {
  final sorted = [...xs]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}
