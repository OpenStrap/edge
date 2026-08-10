// DerivationEngine — the on-device compute COORDINATOR (MAIN ISOLATE).
//
// Current flow (per trigger):
//   1. Decide WHICH calendar days need compute (force / pending span / latest
//      freshness-critical day).
//   2. Build / refresh the first primitive, `sleep_session_candidates`, from a
//      bounded overlap window only when needed.
//   3. Load the exact calendar-day substrate + exact sleep-window substrate for
//      the target day, then build one PreparedDerivationDay from those pieces.
//   4. Run the pure day pipeline off-isolate, then compute the second
//      primitive, `wake_day_features`, directly from the local-day substrate.
//   5. Persist day_result as the materialized UI surface, plus compact baseline
//      artifacts (`rolling_artifact`, `crossday_input`) for downstream reuse.
//   6. Run cross-day / notifications from those compact artifacts and prune raw
//      only after a force/full-history sweep, never before derived.
//
// Finalized-day rescans are still allowed for baseline-dependent scalars
// (readiness/recovery, illness/anomaly, stress), but they now gate off the
// rolling baseline artifact instead of recomputing the signature ad hoc from
// metric_series each time.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'nap_edits.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_performance/firebase_performance.dart';

import '../data/db.dart';
import '../data/day_label.dart';
import '../data/series_codec.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/tap_router.dart' show kRouteWorkoutSuggestion;
import '../telemetry/telemetry_service.dart';
import 'crossday_pipeline.dart';
import 'derive_pacing.dart';
import 'movement_floor_policy.dart' as mfp;
import 'sleep_profile_policy.dart';
import 'derive_prepare.dart';
import 'onehz_pipeline.dart';
import 'profile.dart';
import 'substrate.dart';

/// Analytics/bundle version — bump to force a recompute of non-finalized days.
/// v3: Walch 2019 stager + 4-class stages (light/deep/rem), robust nocturnal HRV,
/// 0–21 strain, skin-temp-z baseline fix, baseline-need signals.
/// v4: finalization + retention anchored on the DATA EDGE (last drained record
/// timestamp), not the wall clock — a buffer-and-sync band's wall-clock time is
/// irrelevant. Bumping resets per-version finalization so any day the old wall-
/// clock logic prematurely LOCKED (before its flash fully drained) re-derives.
/// v5: sleep HR-dip is confidence-only — no longer relocates onset. Validated on
/// real data: the old trim shoved a true 02:15 onset to 02:41, discarding ~26
/// min of real early sleep. Window onset now stands; stager decides wake within.
/// v6: replaced the Walch ML stager with a transparent cardiorespiratory rule
/// stager (motion + HR + RMSSD vs the night's own baseline). Walch over-called
/// wake (solid night read 60% eff) and ignored RR; the rule stager uses RR and,
/// on real data, lifts a true solid night to ~94–99% eff with a plausible
/// light/deep/REM mix. Honest ESTIMATE (conf scales with RR coverage).
/// v7: CALENDAR-day model (local midnight→midnight) replaces wake-to-wake. A
/// day's sleep = the main sleep that ENDED that morning; recovery follows into
/// the day, strain = that day's waking activity. Deletes the wake-scan day
/// boundaries / 36 h horizon / back-extension; recompute = the calendar day(s)
/// new data touches. Day keys are now plain calendar dates.
/// v8: STRESS (Baevsky SI, windowed median → 0–100 score) + relative SpO₂
/// (overnight desaturation index) now computed, persisted to day_result +
/// metric_series, and surfaced (Today tiles, stress screen, day/week/month/3M
/// trends). Stress validated on real data (SI ~47–52, low/normal resting).
/// v9: ACTIVITY-MINUTES — coarse 1 Hz movement proxy (wrist orientation change;
/// 1 Hz can't do ENMO/steps — Nyquist). Persisted + trended. Validated on real
/// data (~477 active min on a full day). True step counts remain live-IMU only.
/// v10: active calories (Keytel), HR zones, nocturnal nadir/waking, sleep-need
/// 8 h default; activeMin stored as double (fixes the int→double? derive crash).
/// v11: SLEEP CYCLES corrected to Rosenblum 2024 "fractal cycles" (HRV-adapted):
/// peak-to-peak of the smoothed per-minute RMSSD series, NOT categorical REM-
/// episode counting. Validated on real data (4 / 2 cycles, ~90–100 min each).
/// v12: nocturnal nadir INSTANT (`sleeping_hr_nadir_ts`) added so the card shows
/// "NADIR @ HH:MM" instead of "@ -"; seam-side, getDayStrain now routes the
/// cross-day EWMA-ACWR `load` to the strain detail. Full seam↔screen audit.
/// v13: computable gaps filled — HRV stability (CV) + Poincaré irregular-beat
/// screen (pipeline), and engine-injected blocks: wear segments, waking
/// daytime-HRV timeline, nocturnal restlessness, and sleep periods (main+naps).
/// v14: trend scalars for sleep-stage minutes (rem/deep/light/tst) + lf_hf +
/// hrv_cv (→ metric_series); per-5-min day `activity_curve` for the "Your day"
/// timeline. (Peak/lowest-HR + their @times are computed seam-side from the HR
/// curve, no derived change.)
/// v15: efficiency + worn_min scalars → metric_series (sleep-efficiency & wear
/// trends); + _trendKey fixes (resting_hr→rhr, skin_temp→skin_temp_z, sleep→tst_min).
/// v16: ADDITIVE analytics surfaced into the bundle — (a) `clinical.strain_effort`
/// + `scalars.strain_effort`: a 0–100 Edwards zone-sum "effort" strain (Karvonen
/// %HRR over the per-second wake HR) beside the 0–21 headline; (b) top-level
/// `baselines` block: Winsorized-EWMA personal baselines (rhr/hrv/resp) with
/// z/delta/ratio + cold-start status; (c) `advanced_sleep` block: a 4-class
/// Cole–Kripke/DoG stager's main-session AASM metrics + hypnogram (parallel
/// ESTIMATE; the single-source `sleep` block stays the headline). Bumping
/// re-derives non-finalized recent days so the new blocks populate.
/// v17: STEPS (24/7 ESTIMATE = ambulatory-minutes × cadence, personalized by the
/// live 100 Hz pedometer's cadence calibration) + TOTAL DAILY ENERGY (TDEE via
/// HR-flex: Mifflin BMR floor + active Keytel surplus). New scalars `steps` +
/// `calories_total` → metric_series; `steps`/`calories_total` bundle blocks. 1 Hz
/// still can't COUNT steps (Nyquist) — real counts come from live streaming, which
/// also tunes this estimate. Bumping re-derives non-finalized days so they fill.
// v20: principled nap detection (van Hees immobility + HR-dip) → `naps` block +
// `nap_min` scalar; cross-day Sleep Coach (need/bedtime/cycle-wake/performance),
// Strain Coach (recovery-gated target), VO₂max + Fitness Age, all in the crossday
// bundle.
// v21: all-day HRV line (`series.hrv_day`, epoch rolling RMSSD over 24/7 RR).
// v22: all-day RESP line (`series.resp_day`, rolling RSA br/min) + relative
// SKIN-TEMP trend (`series.skin_temp_day`) for the Timeline graph.
// v23: all-day HRV (`series.hrv_day`) now rejects ectopic/missed-beat pairs
// (Malik 20% rule) + clips to ≤220 ms, killing the non-physiological 400+ ms
// spikes.
// v24: picks up the analytics sleep-algorithm rewrite (multi-session detection +
// bridging + main-session pick via AdvancedSleepStager). Bumping re-derives
// non-finalized days so past nights restage; "Re-analyze data" restages all.
// v25: 24/7 irregular-rhythm SCREEN (day-span RR → `irregular_rhythm_flag` +
// notification), heart-rate recovery (HRR) per auto-detected bout → `hrr_bpm`,
// breathing-rate variability (`brv_cv`/`brv_slope`), opt-in auto-workout
// SUGGESTIONS (workout_suggestions table + notification), and low-confidence
// WRIST ORIENTATION during sleep (NOT body position). Bumping re-derives
// non-finalized days; "Re-analyze data" restages all.
// v26: integration bump — the oxygen/workout PR externalized active-calorie
// compute to `Calories.activeEnergy` (Keytel + height term) without a version
// bump; combined with the v25 features above, bump so finalized days recompute
// onto the new calorie formula instead of silently carrying the old values.
// v27: WEAR fix — worn-time / coverage / on-off segments were defined as hr>0,
// which misreads daytime PPG drop-out as off-wrist and collapsed a 24 h-worn day
// to ~the sleep window (~7-8 h). Wear is now RECORD presence (gap-detected), in
// both the `worn_min` scalar (onehz_pipeline) and the `_wearBlock` detail. Bump
// so finalized days recompute the corrected wear ("Re-analyze data" restages all).
// v28: SLEEP rescue — manual sleep entry + HR-led fallback. When accel-led
// detection finds nothing, an HR-dip fallback now proposes a window (source
// 'auto_fallback', low confidence); a user can type/confirm a window
// (sleep_override table → source 'manual'/'confirmed') which force-derives even
// a finalized day. Bump so fallback-eligible days restage.
// v29: COUNTER-RESET RECOVERY. The decoded substrate now dedupes by timestamp
// (rec_ts, newest-wins) instead of by the strap counter, which resets on reboot
// and silently quarantined every post-reboot day (empty "today", strain –). The
// DB v17 migration (_rebuildCanonicalDecodedStore) rebuilt decoded_onehz/
// decoded_rr time-keyed, the write path REPLACEs on rec_ts, and the substrate
// loader falls back to decoding raw_records directly for ranges whose decoded
// rows are absent — so previously-quarantined days now have data. Bump so those
// days (and any finalized day derived while data was missing) recompute against
// the recovered substrate.
// v32: SLEEP-STAGE fix — the REM detector depended on a respiration signal
// (`resp`) that no real caller ever supplied (WHOOP 4's R24 record has no
// respiration-ADC channel), so it was unconditionally NaN and the primary
// REM rule could never fire — nights collapsed to almost-all-light. Also
// resolved a three-implementation ambiguity (`cardioStager` vs
// `AdvancedSleepStager` v1/v2 — only v1 was ever actually wired, despite
// `cardioStager` being the one documented as fixing Walch 2019's WAKE-bias)
// via a head-to-head comparison; `cardioStager` (StagingMethod.cardio) is now
// the wired default. ALSO in this same (unshipped) bump: `dailyStepEstimate`'s
// doc had always promised a "run of >= minBoutMin consecutive ambulatory
// minutes" bout gate that was never actually implemented — every minute that
// individually passed the ENMO+HR gate summed directly into steps, so a
// handful of scattered, non-contiguous minutes overnight (a brief HR lift
// during a turn-over) could report several thousand phantom steps the moment
// someone woke up having never walked. `minBoutMin` (default 3) is now a real
// gate. Bumping re-derives non-finalized days so past nights/days restage;
// ALREADY-FINALIZED history needs "Re-analyze data" to pick up BOTH corrected
// staging and corrected steps — this is the one bump so far where that's
// worth actually telling users about, since it affects months of history,
// not just going forward.
// v37: SLEEP-STAGE fix #2 (real-device root cause, not synthetic) — v32 fixed
// the dead REM path but a real overnight capture showed cardioStager still
// massively over-called WAKE (~6h on a night truth was ~3min) and under-
// called REM (~40min vs a ~2h42m truth). Root cause: BOTH the motion
// ("gravity 1 g reference") and HR ("sleeping HR baseline") features were
// single WHOLE-NIGHT scalars. This real device's decoded gravity-vector
// magnitude is NOT perfectly orientation-invariant — different STATIC sleep
// postures read up to ~13% apart in |accel| despite near-zero within-epoch
// variance (i.e. genuinely still), so 389/421 "big move" epochs that night
// were this artifact, not real movement, and produced WAKE blocks too long
// for Webster rescore to bridge back. Separately, the whole-night HR arousal
// threshold misread the sleep-onset HR-decay transient (elevated HR for the
// first ~60-90 min while settling) as sustained arousal. `cardio_stager.dart`
// now computes both references as LOCALLY-ADAPTIVE rolling windows, plus a
// local p25 (not median) floor specifically for the REM gate — REM recurs on
// ~90 min ultradian cycles and is a minority of any local window, so a local
// MEDIAN self-dilutes from REM's own periodic elevation. Verified on the real
// capture: wake 294->1 min, light 173->337 min, deep 26->58 min, rem 41->139
// min, against an Apple Watch Ultra ground truth of wake=3 light=330 deep=38
// rem=162 min for the same night. Bump so this genuinely different (much more
// accurate) staging recomputes; "Re-analyze data" needed for finalized nights.
// v38: audit-fix sweep, two changes actually touch output. (1) analytics'
// `readinessLnRmssd` was including tonight's own value in its own baseline
// window (`historyLnRmssd.sublist(start)` ran to the end of the list instead
// of stopping before it) - pulled the mean/sd toward tonight, understating
// how far off a genuinely suppressed/elevated night reads, worst exactly
// when the window is smallest. Now strictly prior nights only, changing
// `readiness_lnrmssd`'s z/cv/value for every day. (2) day windows here used
// `_localDayLabelToSec(day) + 86400`, assuming every local day is exactly
// 24h - wrong on the two DST-transition days a year (23h/25h), which could
// clip or over-include a day's substrate window right at the boundary. Now
// `_localNextDayLabelToSec` asks DateTime for the actual start of the next
// day. Bump so recent days recompute onto the corrected readiness baseline;
// only matters for history on the rare day that crossed a DST transition.
// v39: night-tail sleep runs shorter than the 60-min standalone floor are no
// longer dropped when they continue the overnight chain (advanced_stager
// detectSleep) — a pre-dawn arousal that split off a <60-min tail was
// truncating the sleep-window offset at the arousal. Bump so affected days
// recompute the corrected (later) offset and downstream sleep/readiness metrics.
// v42: PERSONALIZED, self-improving cardio stager. (1) REM feature upgrades in
// cardioStager — LF/HF from the RR Lomb–Scargle spectrum + R(k)=mean|ΔIHR|,
// OR-combined with the RMSSD drop and gated by atonia + an HR floor (recovers
// under-called REM), plus a 3-epoch median flicker filter. (2) A rolling
// per-user sleep profile (baselines key `sleep_user_profile`) EWMA-folded after
// each finalized night and blended (bounded ≤0.5, growing with nights, 0 at
// cold start) with tonight's per-night-local baselines — so staging gets better
// over time while per-night-local always leads. Deep stays a low-confidence
// NREM sub-split (deep_low_confidence). The profile self-seeds across this
// re-derivation sweep; no explicit migration. Bump so every day re-stages.
// v43: readinessComposite now falls back to a mean/SD z when the robust (median
// +MAD) z is degenerate (MAD==0 on a tightly-clustered quantized baseline —
// whole-bpm RHR / integer skin-temp ADC), which was intermittently blanking the
// whole readiness score to "—" on nights that had valid sleep. Bump so days that
// were previously absent-for-that-reason recompute a real score.
// v44: two consistency fixes; neither changes a scalar that a previously
// FINALIZED day_result already had right, but both affect data availability/
// consistency going forward. (1) A day whose offloaded second-half compute
// (naps/workouts/HRR/wear/curves/wake-features) failed or timed out — but
// whose headline scalars (readiness/RHR/RMSSD) already succeeded — could get
// marked finalized and treated as fully "derived" by the raw-pruning guard,
// permanently losing the raw substrate needed to ever fill in those missing
// fields on retry. Now tracked via a new `partial` day_result column and
// excluded from both age-based finalization and the pruning guard until the
// second half actually completes. (2) The wake_day_features early-read
// artifact (what the Today repo shows before the full day result is ready)
// was copying the pre-hybrid-correction 1Hz-only step/calorie estimate
// instead of the corrected real-100Hz+1Hz hybrid value computed moments
// later in the same pass — the final day_result was always correct, only
// this transient early read was stale. Bump so any day currently sitting
// non-finalized re-derives with both fixes in effect.
// v45: cardioStager REM LF/HF hot-path fix. `_windowRemFeatures` fed ABSOLUTE
// epoch seconds (~1.75e9) into the per-30-s-epoch Lomb–Scargle, forcing every
// sin/cos onto libm's __kernel_rem_pio2 multi-precision slow path. Over a full
// night (~1000 epochs × 240 freqs × ~180 beats × 2 loops) that is tens of
// millions of slow-path trig calls — and because v42 runs staging on the MAIN
// isolate (for the ambient profile blend), it landed on the UI thread and
// produced recurring multi-second freezes → Android ANRs (Crashlytics 0.9.13:
// libm.so __kernel_rem_pio2 / sin / cos, "slow operations in main thread").
// Fix rebases beat times to the window start; L-S is time-shift invariant so
// LF/HF is unchanged in exact arithmetic (only last-ULP float differences, which
// is why a bump is warranted). Bump so non-finalized days re-stage on the fast
// path. Paired with this: `_sleepCandidateForDay` now runs the whole staging +
// profile-fold on a WORKER isolate (the analytics ambient profile globals are
// re-armed inside the `Isolate.run` closure and returned as plain JSON) instead
// of the main/UI thread — so the residual staging CPU no longer blocks the UI
// even before the ~10× trig win.
// v46: readiness-blank-"—" fix — `_seriesMean` trailing-28 window fix +
// analytics re-pin picking up the `robustZ`->`z` fallback (v43 above,
// analytics#26) so quantized baselines with MAD==0 stop intermittently
// blanking a legitimate score.
// v47: readiness's RHR input (`rhrToday` in onehz_pipeline.dart) no longer
// accepts the `rhr` metric's daytime-HR fallback — it now requires an actual
// detected sleep session (`hasSleep && sleepHr.isNotEmpty`), matching how
// HRV/resp/temp were already gated. Previously a no-sleep day could still
// produce a full numeric readiness score off RHR alone (a few minutes of live
// daytime HR masquerading as overnight resting HR), which is how a fresh
// install could show "Readiness 100" ~10 minutes after first wearing the
// strap. Also removed `getDayStress`'s `100 - readiness` fallback in
// local_repository_impl.dart — it fabricated a stress-looking number whenever
// the real Baevsky SI was absent, violating the never-impute rule; the UI
// already correctly renders "—" when `score` is null. Bump so affected days
// re-derive without a same-day, no-sleep readiness/stress score.
// v48: audit sweep across compute + the sibling analytics package.
//
// EDGE-LOCAL changes, which ship the moment this constant lands:
//   - The per-sweep baseline snapshot is genuinely frozen. `appendScalars` is
//     gone; the history is dated and loaded once, and `valuesBefore(key, date)`
//     excludes the target day from its own baseline. A re-derive sweep could
//     previously append each finished day back into the shared window and evict
//     a real old day, collapsing median/MAD toward duplicated recent values —
//     the same pollution shape edge#108 fixed on the load path.
//   - A day is no longer allowed to sit inside its own readiness baseline, and
//     lnRMSSD no longer double-appends today.
//   - `nocturnalRhr` is now fed the positionally-dense day series instead of a
//     compacted one, so its 30-minute window is real wall-clock again.
//   - Profile imputation (age 30 / 70 kg / sex m / RHR 60) no longer persists
//     strain, calories and zones as if they were measured.
//   - SRI no longer drops the one hypnogram segment per night that crosses
//     local midnight; CTL/ATL/TSB now sees a calendar-dense series so fitness
//     and fatigue decay across rest days.
//   - Historical days resolve their timezone offset at their own timestamp
//     rather than through today's offset.
//
// SIBLING-PACKAGE changes ride along with this bump: the analytics sweep from
// the same review (sleep no longer reporting a no-data window as light sleep,
// the Lipponen-Tarvainen threshold on the signed dRR series, abstention on
// degenerate dispersion, the reconciled TRIMP stack, circular social jetlag)
// and the protocol decode fixes. This was NOT true when v48 was first written —
// pubspec.yaml still pointed at the pre-fix SHAs then, and this note said so.
// The pins were moved as part of v49; see the pin-status note above it.
// v49: steps/activity rebuilt on a calibration-invariant feature.
//
// Diagnosed on a real user database: the day reported 39,384 steps against a
// true value of ~2,000. ENMO is `mean(max(0, |a| - gRef))` and gRef is
// auto-calibrated per day from the stillest samples — which are the long sleep
// block, where the wrist sits in a different orientation. gRef came out at
// 0.9797 that day vs ~1.032 on every other, and since ENMO subtracts it from
// every sample, a reference 0.05 g low adds 0.05 g to every minute: exactly the
// 0.05 g walking floor. Sweeping gRef over the identical samples gave 42,155
// steps at 0.97 and 0 at 1.02 — the signal and the calibration error are both
// ~0.05 g, so no threshold could have fixed it.
//
// The analytics package now decides activity from the per-axis high-passed
// dynamic amplitude (gravity is DC in the sensor frame; any per-axis offset or
// gain error cancels exactly), anchored on a PERSONAL floor pooled from
// trailing days rather than an absolute constant or a same-day baseline — both
// of which were measured to fail, in opposite directions.
//
// Edge side of that change:
//   - `dyn_p90` joins the baseline series: each day persists its own high
//     quantile of the dynamic amplitude, and the next day's derive takes the
//     MEDIAN across trailing days (self-excluded, like every other baseline) as
//     its floor. Below the minimum history the estimator ABSTAINS — a day with
//     no personal baseline now reports the real 100 Hz count only, instead of a
//     fabricated 1 Hz number.
//   - `active_min` is persisted as a first-class series. Minutes are what 1 Hz
//     can resolve; steps are derived from them as a range.
//   - The steps bundle carries the range + the floor used, and says plainly
//     when the 1 Hz estimate is absent.
//
// This bump also re-derives days whose stored step figure came from the old
// estimator.
//
// PIN STATUS: as of this bump pubspec.yaml points at the analytics and protocol
// PR-branch commits, so everything described in v48 AND v49 is genuinely in the
// build — the edge code physically cannot compile against the older analytics
// pin, which is how we know. Those pins must move to the merge commits (and
// this must bump again) when the sibling PRs land. Verify any analytics claim
// made here with `git show <pinned-sha>:<file>` before trusting it; a changelog
// citing a change the pinned SHA never contained is how v43 documented a
// readiness fix that stayed broken for three releases.

// v50: the sibling PRs merged; pubspec.yaml now pins the resulting `main`
// commits (analytics f5ccae6, protocol a98cd70) instead of the PR-branch heads
// v49 briefly pointed at.
//
// A version bump is required even though no edge SOURCE line changed with it.
// kAlgoVersion identifies the code that PRODUCED a day_result, and that code
// includes the pinned siblings: a device holding v49 rows built against the
// PR-branch SHAs must re-derive against the merged ones rather than serve them
// as equivalent. Treating "same content, different commit" as not worth a bump
// is the assumption that lets a stale bundle survive a dependency change.
//
// Verified at the merge commits themselves, not inferred from the PRs being
// green: steps.dart carries the new step API, rr_correction.dart has the
// signed-dRR `seg.add(x[k])`, advanced_stager.dart has maxAccelCarryForwardSec,
// live.dart has kKnownRecordVersions.

// v51: edge#170 — autoDetectWorkouts' motion-confirmation gate (tuned for
// arm-swing activities) silently dropped every low-limb-swing cardio window
// (cycling/rowing: the wrist stays still on a handlebar/oar) no matter how
// strong the HR signal was. analytics#32 (PR-branch head, pinned above —
// repin to main once merged) adds an HR-ONSET bypass: the gate is skipped
// only when mean bpm over the candidate's first 3 min rises >=25 bpm versus
// the 3 min immediately before it (Whipp & Wasserman 1972 phase-II kinetics),
// which fires on genuine exercise starts but NOT on slow-drifting elevations
// (fever/heat/anxiety) that have no discernible onset — so this changes which
// suggestions autoDetectWorkouts emits without loosening the false-positive
// gate it exists to protect.
// v52: the rolling per-user sleep profile (`sleep_user_profile`) was folded on
// EVERY staging pass for a day, not once per day — a real 12-day export carried
// `nights: 1348`. Two consequences, both bad: `personalWeight` pinned at its
// 0.5 cap from the first sweep, and an EWMA collapsed onto whichever day was
// re-derived last. Replaying that profile against the same 11 nights moved wake
// 4.3% -> 36.4% and deep 1.9% -> 0.0% on the worst night, i.e. the
// personalization layer was re-creating the wake over-call cardioStager exists
// to avoid. Fixed by (1) folding at most once per day_id (tracked in the
// profile payload), (2) withholding the profile from staging until
// kMinNightsForSleepProfile nights (van der Aar 2025: gains need >=3 nights and
// ~17.5% of subjects get WORSE from personalization), and (3) discarding
// pre-tracking profiles, which cannot be repaired, so they rebuild honestly.
// Bump so every day re-stages without the corrupt blend.
// v53: repin analytics to main @ #34 — the sleep-stager decision layer is
// rewritten. Deep and REM were boolean conjunctions AND-ing one informative
// axis with one null one (rmssd, Cohen's d -0.13 deep / -0.02 REM) and one
// INVERTED one (mean HR, d +0.31 for deep, i.e. deep sleep runs slightly
// FASTER than light on the wrist), so all three could only co-fire by
// coincidence — which is why deep sleep came out as isolated 30-second specks
// that the 3-min minimum-bout rule then deleted. Scored against 99 PSG-labelled
// wrist nights those rules managed kappa 0.036, with deep PPV 5.7% against a
// 4.5% base rate and REM 12.1% against 14.0% — at or below chance for both.
// Now weighted robust-z scores (weights = the measured effect sizes) over
// Rk / hrSd / sdnn / lfhf, with rmssd and mean HR dropped: kappa 0.128, 0.132
// on held-out subjects, deep 53.0/12.9 and REM 52.6/20.7 sens/PPV. Every day's
// hypnogram, stage minutes and sleep-derived scalars change, so every day must
// re-derive. Also picks up the protocol realtimeRr bound (live HRV no longer
// sees implausible sub-100ms "beats" from a misaligned 0x28 frame).
// v54: NOOP CSV imports now bank the export's `step_counter` as REAL steps.
// NOOP's schema gained a `steps` stream (and a `band_sleep_state` column that
// shifted event_kind/event_payload) — the importer read columns by name so it
// never misparsed, but it dropped `steps` into its default branch and every
// imported day reported steps = 0 while the band had actually counted them
// (2,572 over the 3.5 h in the OpenStrap/edge#160 export). The counter is now
// differenced into contiguous runs and written to `live_coverage`, the same
// table the live 100 Hz pedometer uses, so imported and live days count steps
// identically and the 1 Hz estimate still cannot double-count those minutes.
// Only the `steps`/`active_min` block of IMPORTED days changes; no live-sync
// output moves. NOTE this bump does not retro-fix an existing import — imported
// days are force-finalized snapshots with no stored raw to recompute from, so
// an already-imported day needs a re-import to pick its steps up.
// v55: NAPS. Daytime naps were "detected" by the NOCTURNAL detector, which
// rejects them on purpose — `AdvancedSleepStager.minSleepMin = 60` exists so
// "daytime naps and stray still-blocks stay excluded", and anything centred
// 11:00–20:00 local additionally needed ≥90 min plus an HR dip. So the 20–45
// min afternoon nap was STRUCTURALLY undetectable, and `detectNaps` advertised
// a 20-min floor it could never reach, returning an empty list with a
// reassuring (and false) "no qualifying naps (20 min–3 h)" note.
//
// SIBLING (analytics): new `sleep/nap.dart` — the only nap source. Enumerates
// every van Hees z-angle immobility bout on the complement of the main sleep
// window (an ANGLE, so it does not inherit the ~13% |accel| spread across
// static postures), requires an HR dip against the AWAKE-DAYTIME baseline
// rather than a night-dominated whole-day median, and reports TST and in-bed
// separately. No sleep-stage claim: a 30-min nap holds no complete cycle and
// the daytime HR duty cycle will not support a 4-class partition. The shared
// immobility primitive is factored out as `immobilityMask` so night and nap
// run one implementation. Specifics worth knowing:
//   - The awake baseline excludes the main sleep AND every detected bout. It
//     cannot include the candidate's own seconds or the hours of tonight's
//     sleep the nap window borrows, or the dip gate becomes self-suppressing —
//     the quieter the sleep, the lower the bar it must beat.
//   - Under 10 min of awake HR, the day is not judged at all. A median over a
//     handful of samples is not a baseline, and every verdict hangs off it.
//   - Durations are WALL CLOCK, not sample counts. The substrate is a
//     positional array with pruning/sync holes, so a run also breaks at a
//     timestamp discontinuity; otherwise an unobserved hour reads as unbroken
//     stillness and 20 min of evidence reports a 2 h nap.
//   - Deferral is CHAIN-aware. Deferring only the bout that touches the array
//     end is not enough: an ordinary 6-min awakening at 01:50 splits tonight's
//     sleep, and only the trailing half touches the end. Every bout chained to
//     an unfinished one (within napChainGapSec) is unfinished too.
// Verify the analytics pin actually contains this before shipping the bump
// (AGENTS §3.5).
//
// EDGE-LOCAL changes, which ship the moment this constant lands:
//   - `_sleepPeriods` no longer runs its OWN nap detector (20-min stillness
//     runs). That second notion disagreed with `detectNaps` on real days —
//     the committed `payload.json` shows a 21-minute period alongside
//     `naps.count: 0` — and fed a different screen. One source now (§3.8).
//   - Periods speak the contract the Sleep-periods screen actually reads
//     (`onset_ts`/`wake_ts`/`duration_min`/`efficiency`), which it never did:
//     every nap card rendered "0m" with a red confidence dot regardless of
//     what was detected. `duration_min` is minutes ASLEEP for both the main
//     sleep and naps, which were previously different units under one label.
//   - `nap_min` is TST, not the in-bed span. It is subtracted 1:1 from sleep
//     need, so crediting in-bed minutes over-credited every nap by its awake
//     time and always erred toward recommending LESS sleep.
//   - An unfinished bout is DEFERRED, not emitted (see the sibling notes). With
//     a 3 h post-midnight buffer the first hours of TONIGHT'S sleep were being
//     written as a multi-hour "nap" for the day that was ending, then counted
//     again as tomorrow's main sleep.
//   - The main sleep period's TST/efficiency are carried into the day-blocks
//     isolate. That isolate builds its own `scMap` seeded with `rhr` alone, so
//     reading `scMap['tst_min']` there yields null forever — which would have
//     made every main-sleep card read "—". Efficiency is normalized from the
//     stored percent to the 0..1 the card contract uses.
//   - `total_asleep_min` is null when any listed period's minutes are unknown.
//     Summing a null as 0 printed a confident total short by exactly the part
//     we could not measure, and the hero arc divides by it.
//   - `sleep_coach.nap_credit_min` is the credit ACTUALLY applied, not the raw
//     nap minutes: `sleepNeed` clamps to [6 h, 11 h] after subtracting, so a
//     large credit is only partly realized.
//   - Today-scoped reads require an explicit `is_today` stamp on the cross-day
//     record. Taking the last record positionally is yesterday on any day whose
//     row has not been derived yet.
//   - Off-wrist and charging spans are passed to the detector from the strap's
//     own WRIST_OFF/WRIST_ON and CHARGING_ON/OFF events. These were decoded
//     and persisted to `band_events` all along and never used; a band on a
//     table or charger is motionless and is the dominant nap false positive.
//   - Absent ≠ zero: when nap detection cannot judge a day, `nap_min` is left
//     UNWRITTEN, and the sleep-need credit reads TODAY only. It previously
//     fell back through `_lastNum` to YESTERDAY's nap minutes (§3.3).
//   - `sleep_coach.nap_credit_min` exposes the credit that was subtracted, so
//     the coach card can show it instead of silently shrinking the ring.
//
// Days re-derive so naps, nap_min, sleep_periods and sleep need are rebuilt.
// v56: the STRAIN half of the same today-scoping bug. v55 fixed `nap_min` but
// left `sleep_coach.need`'s other today-scoped input reading through
// `_lastNum`, so a day whose strain compute abstained built tonight's strain
// bonus out of an EARLIER day's workout — the identical §3.3 imputation, in the
// identical function, two lines apart. Measured on a 7-day fixture: a carried
// strain of 18 inflated `need_sec` by 2314 s (38.6 min) over a today-abstained
// day. Now `_todayNum`.
//
// Direction note, because it differs from v55 and the difference matters: naps
// are SUBTRACTED and strain is ADDED, so while both inputs floor at 0, that
// floor is an upper bound on need for naps and a LOWER bound for strain.
// Abstaining to 0 strain therefore recommends up to 45 min LESS sleep, not
// more. It is still correct — carrying yesterday forward is not a safety margin
// but noise around the true value (it inflates need only when yesterday
// happened to be harder than today), and strain is a same-day accumulating
// quantity that genuinely starts at 0 — but it is not the cautious direction.
// Because it is not, it is not allowed to be silent either:
//   - `sleep_coach.strain_bonus_min` reports the minutes the bonus ACTUALLY
//     added, measured like `nap_credit_min` (re-run with strain zeroed and
//     diff), so the [6 h, 11 h] clamp cannot make the card claim an increase
//     `need_sec` never took.
//   - It is NULL, never 0, when today produced no strain reading. A confident 0
//     says "you rested"; null says "we could not measure today's strain, so
//     tonight's need is short by up to 45 min". Collapsing those would re-hide
//     exactly what the today-scoping fix exposed.
//   - The Sleep Coach card renders the applied bonus as a "+Xm added for
//     today's strain" line (`strainBonusCaption`), mirroring the nap credit.
//     The card stays SILENT on null, matching the nap precedent — surfacing
//     "today's strain was not measured" to the user is a product decision, and
//     the bundle carries the distinction for whoever takes it.
//
// Days re-derive so sleep need, bedtime, wake and sleep performance are rebuilt.

// NOTE ON NUMBERING: v55 and v56 above are the nap/strain work (PR #204),
// which merged first. The three entries below are this branch's, renumbered
// from 55/56/57 to 57/58/59 so the constant stays STRICTLY MONOTONIC. That is
// load-bearing, not cosmetic: the derive gate matches algo_version EXACTLY
// while the read seam serves MAX(algo_version), so a version that goes
// backwards writes rows nobody reads and re-derives forever.
//
// v57: THE 1 Hz STEP ESTIMATE IS DELETED. Steps are now real-measured only.
//
// Diagnosis on a real user DB (2026-08-03): the app reported 2,645 steps for a
// day the user took under 400. It was 23 "active minutes" x an assumed 115 spm.
// Both halves of that conversion are invalid at 1 Hz, and neither is fixable by
// re-tuning:
//   * Cadence is NOT IDENTIFIABLE. Gait is 1.4-2.3 Hz (Straczkiewicz 2023,
//     doi:10.1038/s41746-022-00745-z); at 1 Hz every fundamental is sub-Nyquist
//     and 80/100/140/160 spm alias to the same 0.333 Hz. No published step
//     detector exists below 10 Hz.
//   * The minutes were never specifically ambulation. At the wrist, arm work
//     out-accelerates walking (stirring ~104 mg, chopping ~139 mg vs walking
//     ~66 mg ENMO), so a movement threshold cannot isolate gait even at full
//     rate: wrist devices emit 22-27 false steps/min during dishes, reaching
//     and driving (O'Connell 2017, doi:10.1371/journal.pone.0169616) while
//     detecting slow walking at sensitivity 0.05. The two errors have OPPOSITE
//     sign, so no gain constant corrects both.
// Confirmed against this DB's own ground truth: the single window where the
// 100 Hz pedometer and 1 Hz overlap had HR 95->108 and dynAmp 0.31-0.40 g, and
// the REAL count was 11 steps in 3.1 min (3.5 spm) where the estimator would
// have assigned ~115 spm.
//
// What changes: `scalars.steps` is now ABSENT unless a gait-capable source
// measured the day (band 100 Hz, phone pedometer, or a NOOP import — all in
// `live_coverage`). Days with no such source lose their step number entirely
// rather than showing an invented one. `active_min` survives as an explicitly
// NON-locomotion movement-volume index (bundle key `movement`) and is no longer
// coverage-excluded, since there is no longer a step total it could double-count
// into. Steps also stopped being written to Apple Health / Health Connect, both
// because the old value was fabricated and because we now READ the phone's own
// pedometer from that store and must not feed our copy back to ourselves.
// Every day's steps/active_min move, so every day must re-derive.
// v58: movement minutes rebuilt on MEASURED evidence. Every change below was
// proven against 4 days of this user's real 1 Hz substrate before being made;
// two proposals were REFUTED by the same tests and deliberately NOT built.
//
//   * HR GATE DELETED. `restingHr + 8 bpm` changed active minutes by exactly
//     ZERO on every day tested. At RHR ~62 it sits at ~6% of heart-rate
//     reserve — below every ACSM band — and 73-100% of covered minutes already
//     cleared it. It also failed in the wrong direction: PPG HR is least
//     reliable during the motion being gated, so a dropout deleted minutes the
//     accelerometer measured fine. `dailyActiveMinutes` no longer accepts HR.
//   * x3 CEILING DELETED. It rejected ZERO minutes on all 4 days with
//     0.42-0.55 g of headroom, and cannot fire on artifacts (a 3 s knock
//     averages ~0.23 g, below the FLOOR). The only thing it could ever exclude
//     was a genuinely hard session.
//   * FLOOR IS NOW FROZEN after a 14-day enrollment, not recomputed daily. A
//     threshold derived from the signal it thresholds cancels the trend it
//     exists to report: scaling a real day's dynAmp gave 37 active minutes at
//     1x, 1.5x, 2x AND 3x activity when recomputed, versus 23 -> 254 frozen.
//     Re-freezes only on device/wrist change, a 30-day wear gap, or 365 days.
//   * NOT BUILT (proven unnecessary): accel autocalibration — offset and
//     uniform gain cancel exactly through the high-pass and the floor
//     normalisation (+5% gain moves the gate decision by 0.0000); only
//     anisotropic gain survives at ~1-3%. And gravity/forearm orientation —
//     it solved the ambulation problem v55 deleted. A sleep-anchored floor was
//     also tested and REFUTED: CV 138.6% across days vs 9.3%, and on one night
//     it landed above the entire day's range (would report zero).
//   * SEMANTICS CORRECTED. The R24 1 Hz accel field is a fused GRAVITY vector,
//     not acceleration: across 269,486 real samples ||a|| is p50 1.027 g with
//     0.030% above 1.3 g, and during the single most vigorous minute of a day
//     it was 1.033 g +- 0.006 (0 of 420 samples above 1.2 g). So `dynAmp`
//     measures how fast the wrist RE-ORIENTS, not how hard it accelerates, and
//     ENMO/MAD over this substrate are ~(1.03 - gRef): a pure calibration
//     artifact with zero signal. That is the true root cause of the original
//     42,155-steps-at-gRef-0.97 / 0-at-1.02 collapse.
// active_min moves on every day; steps are unaffected by this bump.
//
// v59 - review follow-up: the ABSENT `steps` block stops labelling itself. It
//   carried `tier: 'ESTIMATE'` alongside `value: null`, and `Metric.parse` maps
//   that tier to `beta: true`, so a day with no measurement at all rendered the
//   estimate badge. Absent now means absent: `tier: null` (parsing to
//   MetricTier.unknown) and an empty `inputs_used`. No VALUE changes, but the
//   persisted bundle does, so days derived at v58 must be re-derived to pick it
//   up. `ABSENT` was deliberately NOT invented as a fifth tier — `Tier.all` in
//   analytics is a closed set of four published grades.
//
// v60 - the all-day HRV and respiratory curves advance their cadence cursor on
//   every ATTEMPT rather than only on a successful estimate. `_dayRespCurve`
//   left `lastEmit` unset whenever rsaRespRate came back absent — and absent is
//   the EXPECTED daytime case, because daytime RSA is movement-confounded — so a
//   confounded stretch re-ran the triple Lomb-Scargle once per beat instead of
//   once per five minutes. That is what exhausted the 90 s day-blocks budget and
//   left days persisted headline-only. `_dayHrvCurve` had the same shape plus an
//   O(window) sum that ran before its cadence gate was checked. Both curves keep
//   their sampling intent; points that were previously emitted a beat or two
//   after a failed attempt now land on the next cadence tick instead.
// v61 - NAP EDITS. The nap detector's answer is now a PROPOSAL: a nap the user
//   logged is added, and one they rejected is suppressed, replayed over the
//   detector's output on every derivation rather than written into it (so a
//   better detector later still respects "there was no nap here"). Rejection
//   matches by OVERLAP, not by exact bounds, because the detector's boundaries
//   shift between runs and an edit that stopped applying when a boundary moved
//   by a minute would be worse than useless.
//
//   This moves numbers, which is why it is a version bump rather than a read
//   path: `nap_min` is summed over the merged list, so a logged nap credits
//   against sleep need and sleep debt exactly as a detected one does — that
//   was the explicit product decision, not an accident of where the code sat.
//   Days carrying an edit are force-derived alongside sleep-override days, so
//   an edit to an already-finalized day actually takes effect.
const int kAlgoVersion = 61;

// Fold idempotency, the minimum-nights warm-up, and legacy-payload handling
// all live in SleepProfilePolicy (pure, unit-tested) — see
// lib/compute/sleep_profile_policy.dart for the evidence behind each rule.

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 3;

/// A day stays recomputable for this long after its wake, then FINALIZES (locks)
/// — more flash may still drain within this buffer (ARCHITECTURE_V2: ~48 h).
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;

/// Readiness is meant to be a stable MORNING score, but a day stays recomputable
/// for ~48 h (`_finalizationSec`) and every re-derive overwrites the persisted
/// readiness scalar. As the night's flash finishes draining and the trailing
/// 28-day baseline shifts, the surfaced value legitimately drifts through the
/// day (#128: "morning it was 49, now 45"). Once today's overnight is genuinely
/// COMPLETE we PIN the first such readiness as the headline so it stops moving.
///
/// "Complete" must be stronger than `overnight_state == 'ready'` — that flips as
/// soon as the FIRST sleep-bearing row lands (mid-drain), so pinning on it could
/// freeze a partial-night value. We instead require the drained data edge to
/// have moved at least this far PAST the sleep offset (wake): the whole sleep
/// window is then decoded and the segmentation-placed wake is settled, so the
/// overnight inputs are final. Same "edge past the window" model finalisation
/// uses, anchored at wake+margin rather than wake+48 h. Conservative but still
/// reached within the first post-wake sync in practice; raise it to trade a
/// slightly later freeze for more safety margin.
const int _headlineFreezeMarginSec = 60 * 60;

/// The frozen morning readiness headline that should be persisted/surfaced for
/// [today], given the current pin and a fresh look at today's live readiness and
/// whether today's overnight is genuinely COMPLETE. Pure so the freeze semantics
/// are unit-tested without the derive/DB machinery.
///
/// - Not yet a complete overnight → no pin (the headline tracks the live value).
/// - First complete overnight → pin the live value.
/// - Later same-day looks → keep the FIRST pin (the whole point: no daytime
///   drift — a re-derive that would RAISE or LOWER the score is ignored).
/// - A new day → the prior day's pin no longer applies; re-pins once the new
///   day's overnight completes.
@visibleForTesting
({String day, int value})? nextFrozenHeadline({
  required String today,
  required bool overnightComplete,
  required int? liveReadiness,
  required ({String day, int value})? current,
}) {
  if (current != null && current.day == today) return current; // pinned; hold
  if (overnightComplete && liveReadiness != null) {
    return (day: today, value: liveReadiness); // first complete settle → pin
  }
  return null; // nothing to pin yet for today
}

/// Test seam: the rolling baseline window the readiness computation actually
/// runs against, loaded exactly as production does. Exposed to assert the read
/// path ignores a polluted `rolling_artifact` and rebuilds from `metric_series`.
@visibleForTesting
Future<List<double>> debugBaselineWindow(String key) async =>
    (await _BaselineHistoryCache.load()).values(key);

/// Test seam: the EXACT per-day baseline windows one derivation sweep would feed
/// the readiness pass, in dispatch order (`orderedDays` is newest-first).
///
/// Pins the two properties the sweep path must have — the snapshot is loaded
/// ONCE and never mutated as days complete, and each day's window self-excludes
/// that day's own date. Both were violated by the old `appendScalars` sweep.
@visibleForTesting
Future<List<List<double>>> debugSweepBaselineWindows(
  String key,
  List<String> orderedDays,
) async {
  final history = await _BaselineHistoryCache.load();
  return [for (final day in orderedDays) history.valuesBefore(key, day)];
}

@visibleForTesting
({List<String> days, String reason}) selectLightDeriveDays({
  required Set<String> rawDays,
  required List<String> pendingDays,
  required String today,
}) {
  if (rawDays.contains(today) && pendingDays.contains(today)) {
    return (days: [today], reason: 'today-priority');
  }
  return (days: [pendingDays.last], reason: 'latest-pending');
}

class _DeriveScope {
  final bool fullHistory;
  final List<String> targetDays;
  final String reason;

  const _DeriveScope({
    required this.fullHistory,
    required this.targetDays,
    required this.reason,
  });
}

/// One (date, value) sample of a baseline series.
typedef _DatedValue = ({String date, double value});

class _BaselineHistoryCache {
  _BaselineHistoryCache(this._series);

  /// The baseline series this cache carries, keyed by `metric_series.key`.
  static const List<String> keys = [
    'ln_rmssd',
    'rmssd',
    'rhr',
    'resp_rate',
    'skin_temp_adc',
    'readiness',
    // Per-day high quantile of the calibration-invariant dynamic accel
    // amplitude. The 1 Hz activity estimator's floor is anchored on the MEDIAN
    // of this series across trailing days, never on a same-day value: a
    // single-day threshold collapses on a quiet day and passes everything,
    // which is the mirror image of the absolute-constant failure it replaced.
    'dyn_p90',
  ];

  /// DATED baseline samples, ascending by date, one entry per day (metric_series
  /// is keyed `(date, key)` with REPLACE, so it is structurally de-duplicated).
  ///
  /// IMMUTABLE for the lifetime of one derivation sweep. There is deliberately
  /// no mutator: the previous `appendScalars` mutated this shared snapshot as
  /// each day of a sweep finished, which re-introduced exactly the duplicate-day
  /// pollution the load path was rewritten to prevent — `load()` had ALREADY
  /// read the persisted values of the days about to be re-derived, so appending
  /// each finished day again (and evicting a real old day to stay at 28) left
  /// later days in the sweep reading a window with up to 21 duplicated recent
  /// values in descending date order. Median/MAD then collapsed toward the
  /// repeated value and readiness went blank/wrong — the load-path bug, moved
  /// into the sweep path. A sweep now reads ONE frozen snapshot, and each day
  /// derives its own window from it by date.
  final Map<String, List<_DatedValue>> _series;

  /// Load the rolling baseline window that feeds the readiness/illness
  /// computations. This ALWAYS rebuilds from `metric_series` — the canonical
  /// scalar store, keyed `(date, key)` with REPLACE, so it is structurally one
  /// value per day.
  ///
  /// We deliberately do NOT trust the persisted `rolling_artifact` for history.
  /// That artifact was written from an in-memory cache with no day identity, so
  /// repeated same-day re-derives could stack duplicate copies of today into the
  /// window; once enough slots matched, the readiness composite's robust z-score
  /// hit MAD=0 and went absent — the blank readiness ring. A polluted artifact
  /// is still valid JSON, so trusting it on read would let that pollution reach
  /// the computation on the first post-upgrade derive (and, when every day is
  /// finalized and `run()` does no work, forever). Rebuilding from the
  /// de-duplicated store on every load makes the read path immune and self-heals
  /// any already-polluted install.
  ///
  /// NOTE ON THE QUERY: `LocalDb.metricSeries(key)` with NO `limit` is the whole
  /// series, `date ASC` — the dates are what make a per-day `date < target`
  /// window possible at all. It must NOT be given a `limit` (that is `date ASC
  /// LIMIT n`, i.e. the OLDEST n — the opposite of a trailing window); the
  /// trailing window is taken here, in Dart, per target day.
  static Future<_BaselineHistoryCache> load() async {
    Future<List<_DatedValue>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key);
      final out = <_DatedValue>[];
      for (final row in rows) {
        final date = row['date'];
        final value = row['value'];
        if (date is! String || date.isEmpty || value is! num) continue;
        out.add((date: date, value: value.toDouble()));
      }
      return out;
    }

    final loaded = await Future.wait([for (final k in keys) hist(k)]);
    return _BaselineHistoryCache({
      for (var i = 0; i < keys.length; i++) keys[i]: loaded[i],
    });
  }

  /// The trailing [_baselineWindowDays] values for [key], oldest→newest.
  ///
  /// This is the WHOLE window including the newest day; it backs the persisted
  /// rolling artifact + the rescan signature, which describe "the baseline as it
  /// currently stands". Per-day derivation must use [valuesBefore] instead.
  List<double> values(String key) => _trailing(_series[key] ?? const []);

  /// The trailing [_baselineWindowDays] values for [key] STRICTLY BEFORE
  /// [beforeDate] (`date < ?`), oldest→newest — the baseline for deriving the
  /// day labelled [beforeDate].
  ///
  /// SELF-EXCLUSION IS THE POINT. The previous derive of the same day has
  /// already written its own row to `metric_series`, so an unfiltered trailing
  /// window contained TODAY: every light pass after the first z-scored today's
  /// RHR/HRV/temp against a baseline that already contained today (pulling the
  /// baseline toward the value under test and understating a genuinely
  /// off day), and the lnRMSSD stack — which is contractually handed
  /// `[...history, today]` and takes all-but-last as its baseline — counted it
  /// a second time. v38 fixed precisely this self-inclusion inside analytics;
  /// this is the same defect at the edge layer that feeds it. Dates strictly
  /// AFTER the target are excluded too: a baseline is prior days, and a backfill
  /// sweep must not let later days leak into an older day's baseline (which
  /// would also make the result depend on sweep order).
  /// The set of dates that actually have a stored value for [key].
  ///
  /// Used to detect wear GAPS: a date with no `dyn_p90` row means the band
  /// produced no usable motion that day.
  Set<String> datesFor(String key) => {
        for (final s in _series[key] ?? const <_DatedValue>[]) s.date,
      };

  List<double> valuesBefore(String key, String beforeDate) => _trailing([
        for (final s in _series[key] ?? const <_DatedValue>[])
          if (s.date.compareTo(beforeDate) < 0) s,
      ]);

  static List<double> _trailing(List<_DatedValue> samples) {
    final from = samples.length <= _baselineWindowDays
        ? 0
        : samples.length - _baselineWindowDays;
    return [for (var i = from; i < samples.length; i++) samples[i].value];
  }

  Map<String, dynamic> toArtifactJson() {
    double? avg(List<double> xs) {
      if (xs.isEmpty) return null;
      return xs.reduce((a, b) => a + b) / xs.length;
    }

    String fmt(double? v) => v == null ? 'na' : (v * 100).round().toString();
    final rhr = values('rhr');
    final rmssd = values('rmssd');
    final temp = values('skin_temp_adc');
    final resp = values('resp_rate');
    final readiness = values('readiness');
    final signature =
        'v$kAlgoVersion|n${rhr.length}|rhr${fmt(_median(rhr))}|rmssd${fmt(_median(rmssd))}'
        '|temp${fmt(_median(temp))}|resp${fmt(_median(resp))}';
    return {
      'algo_version': kAlgoVersion,
      'signature': signature,
      'series': {
        'ln_rmssd': values('ln_rmssd'),
        'rmssd': rmssd,
        'rhr': rhr,
        'resp_rate': resp,
        'skin_temp_adc': temp,
        'readiness': readiness,
      },
      'rolling': {
        'rhr': avg(rhr),
        'rmssd': avg(rmssd),
        'readiness': avg(readiness),
        'n': rhr.length,
      },
    };
  }
}

/// Background re-trigger window: how far back from the DATA EDGE a
/// baseline-dirty rescan re-derives days (including finalized ones). Kept ≤ the
/// raw-retention window so every day in scope still has raw to re-derive from;
/// older days simply aren't in the substrate and are naturally excluded.
const int _rescanWindowDays = 21;

/// Per-day-local page/row accumulator for the prepare stage (see
/// `_prepareTargetDay`/`_loadSubstrateRange`). Deliberately NOT shared
/// `_diag` state — under concurrent per-day processing, multiple days
/// resetting/incrementing the same shared counters would race and produce
/// garbage diagnostics. Each day gets its own instance; only the final
/// per-day total is merged into the shared running max, once.
class _PrepareStats {
  int pages = 0;
  int rows = 0;
}

/// Run [worker] over [items] with at most [concurrency] running at once. Each
/// of up to [concurrency] "lanes" pulls the next unclaimed item as soon as
/// it's free — a mix of fast (empty/mostly-empty day) and slow (heavy
/// backlog day) items keeps every lane continuously busy, rather than
/// lock-stepping in fixed-size batches where one slow item stalls an entire
/// batch. Pure orchestration: no DB/isolate awareness of its own — every
/// caller in this file catches errors INSIDE [worker] itself (a day that
/// fails is marked skipped and processing continues), so a throwing [worker]
/// is not part of the normal contract here, but note that (per
/// `Future.wait`'s default behavior) an uncaught throw would propagate out
/// and NOT stop already-in-flight sibling lanes from completing their
/// current item first.
///
/// This is the ONE place run()/runDays()/rescanRecent() get their real,
/// multi-core parallelism from — replacing what used to be a fully
/// sequential `for` loop that left every core but one idle during a
/// multi-day backlog sweep.
@visibleForTesting
Future<void> runWithConcurrency<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) worker,
) async {
  if (items.isEmpty) return;
  final poolSize = math.min(concurrency, items.length).clamp(1, items.length);
  var nextIndex = 0;
  Future<void> lane() async {
    while (true) {
      final myIndex = nextIndex;
      if (myIndex >= items.length) return;
      nextIndex++; // no `await` since the read above — atomic claim
      await worker(items[myIndex]);
    }
  }

  await Future.wait(List.generate(poolSize, (_) => lane()));
}

/// Minimal async mutex: serializes read-modify-write sections that concurrent
/// day workers ([runWithConcurrency]) would otherwise interleave.
///
/// Dart's scheduler makes a single statement atomic, but NOT a
/// read → decide → write sequence with `await`s in it: every lane can observe
/// the pre-write state before any of them writes. The shared movement floor is
/// exactly that shape, so it needs one.
class _AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous
        .then((_) => action())
        .whenComplete(completer.complete);
  }
}

class DerivationEngine {
  DerivationEngine({this.log, this.background = false});
  final void Function(String)? log;

  /// True when this engine was constructed inside a headless/background entry
  /// (iOS BGProcessingTask / BGAppRefreshTask, Android WorkManager, the
  /// post-drain background sync pass). The OS throttles CPU hard in those
  /// contexts, which changes two tuning decisions — see [_deriveConcurrency]
  /// and [_perDayTimeout]. Set at construction, not per-run, so a long-lived
  /// foreground engine can never inherit background tuning by accident.
  final bool background;

  bool _running = false;
  bool get running => _running;
  final Map<String, dynamic> _diag = {
    'running': false,
    'stage': 'idle',
    'mode': null,
    'force': false,
    'started_at': null,
    'finished_at': null,
    'duration_ms': null,
    'raw_pages': 0,
    'raw_rows': 0,
    'max_day_raw_pages': 0,
    'max_day_raw_rows': 0,
    'scope_days': 0,
    'scope_reason': null,
    'prepared_days': 0,
    'todo_days': 0,
    'done_days': 0,
    'skipped_days': 0,
    // List, not a single day — several days can be in flight concurrently
    // (see run()'s bounded worker pool).
    'active_days': <String>[],
    'concurrency': 1,
    'last_error': null,
  };

  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_diag);

  /// Run a derivation pass. [heavy]=false runs a bounded light pass over the
  /// freshness-critical day: TODAY when raw has reached today, else the latest
  /// pending day. [heavy]=true sweeps every recomputable day.
  /// [force]=true recomputes EVERY non-finalized day regardless of the cursor.
  /// Re-entrant calls are coalesced. Returns the number of days computed.
  Future<int> run(
    Profile profile, {
    bool heavy = false,
    bool force = false,
    void Function(String day, int index, int total)? onDayDone,
  }) async {
    if (_running) return 0;
    _running = true;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    _diag
      ..['running'] = true
      ..['stage'] = 'scope'
      ..['mode'] = force ? 'force' : (heavy ? 'heavy' : 'light')
      ..['force'] = force
      ..['started_at'] = startedAt
      ..['finished_at'] = null
      ..['duration_ms'] = null
      ..['raw_pages'] = 0
      ..['raw_rows'] = 0
      ..['max_day_raw_pages'] = 0
      ..['max_day_raw_rows'] = 0
      ..['scope_days'] = 0
      ..['scope_reason'] = null
      ..['prepared_days'] = 0
      ..['todo_days'] = 0
      ..['done_days'] = 0
      ..['skipped_days'] = 0
      ..['active_days'] = <String>[]
      ..['concurrency'] = _deriveConcurrency
      ..['last_error'] = null;
      
    Trace? runTrace;
    try {
      if (Firebase.apps.isNotEmpty) {
        runTrace = FirebasePerformance.instance.newTrace('derivation_engine_run');
        await runTrace.start();
        runTrace.putAttribute('mode', force ? 'force' : (heavy ? 'heavy' : 'light'));
      }
    } catch (_) {}

    try {
      final scope = await _deriveScope(heavy: heavy, force: force);
      _diag
        ..['scope_days'] = scope.targetDays.length
        ..['scope_reason'] = scope.reason;
      final dataNowSec = await LocalDb.lastDecodedRecTs() ?? 0;
      if (dataNowSec <= 0) {
        _log('derive: no decoded data');
        return 0;
      }
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      // A user sleep override (manual / confirmed) must take effect even on a
      // FINALIZED (locked) day — it's the user's word. Force those back into the
      // todo set. (No-raw days are guarded in the per-day loop so we never
      // clobber a good manual result with an empty re-derive once raw is pruned.)
      final overrideDays = {
        ...await LocalDb.sleepOverrideDays(),
        // A nap edit on a finalized day has to take effect too — same reason.
        ...await LocalDb.napEditDays(),
      };
      final todoDays = [
        for (final day in scope.targetDays)
          if (!finalized.contains(day) || overrideDays.contains(day)) day,
      ];
      if (todoDays.isEmpty) {
        _log('derive: all days finalized — nothing to do');
        if (scope.fullHistory) {
          await _pruneOldDecoded(todoDays, dataNowSec);
        }
        return 0;
      }
      _diag['todo_days'] = todoDays.length;
      _diag['stage'] = 'history';
      final history = await _BaselineHistoryCache.load();
      _log(
        'derive: ${todoDays.length} day(s) '
        '(${force
            ? "force"
            : heavy
            ? "heavy"
            : "light"}; '
        '${scope.reason}; v$kAlgoVersion; '
        'concurrency=$_deriveConcurrency)',
      );

      // Newest-first: `scope.targetDays` sorts ascending (oldest first), which
      // is exactly backwards from what the user actually wants when they open
      // the app after a backlog — today/most-recent should be among the very
      // FIRST days dispatched, not the last one a long sweep gets to. A no-op
      // for the light path (0-1 days), so always safe to apply.
      final orderedDays = todoDays.reversed.toList();

      var done = 0;
      var completed = 0;
      var failures = 0;
      final activeDays = <String>{};
      _diag['stage'] = 'per_day';
      _diag['active_days'] = const <String>[];

      // One day's full prepare→compute→persist body (identical to the old
      // sequential loop's per-iteration work) — extracted so it can run as a
      // unit inside the worker pool below. Concurrency-safe: everything it
      // touches is either (a) day_id-keyed DB rows (independent across days),
      // (b) the read-only `history` snapshot (frozen before this loop starts,
      // refreshed only after it ends — see `_BaselineHistoryCache`), or (c)
      // shared counters mutated via single, non-`await`-split statements,
      // which Dart's cooperative single-threaded scheduler makes atomic
      // relative to the other concurrent workers even though the actual
      // isolate CPU work they await genuinely runs in parallel across cores.
      Future<void> processDay(String dayId) async {
        activeDays.add(dayId);
        _diag['active_days'] = activeDays.toList();
        try {
          final prepared = await _prepareTargetDay(dayId);
          // Override day whose raw has been pruned (≥14 d): re-deriving would
          // produce an empty/absent result and clobber the user's manual sleep.
          // Keep the existing locked result instead.
          if (prepared != null &&
              prepared.daySub.isEmpty &&
              overrideDays.contains(dayId)) {
            _log('derive day $dayId skipped: override day, raw pruned — kept');
          } else if (prepared != null) {
            _diag['prepared_days'] = (_diag['prepared_days'] as int) + 1;
            await _derivePreparedDay(prepared, profile, dataNowSec, history);
            done++;
            _diag['done_days'] = done;
          } else {
            _log('derive day $dayId skipped: no bounded window payload');
            await _markDaySkipped(
              dayId,
              _localNextDayLabelToSec(dayId),
              dataNowSec,
              reason: 'no_bounded_window_payload',
            );
            _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
            _diag['last_error'] = 'no_bounded_window_payload day=$dayId';
            failures++;
          }
        } catch (e) {
          _log('derive day $dayId FAILED/skipped: $e');
          final dayEndSec = _localNextDayLabelToSec(dayId);
          await _markDaySkipped(
            dayId,
            dayEndSec,
            dataNowSec,
            reason: _skipReasonForError(e),
          );
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
          failures++;
        }
        activeDays.remove(dayId);
        _diag['active_days'] = activeDays.toList();
        completed++;
        onDayDone?.call(dayId, completed, orderedDays.length);
      }

      await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);

      // 4. Cross-day rollup + notifications (best-effort).
      if (done > 0) {
        _diag['stage'] = 'baselines';
        await _refreshBaselines();
        _diag['stage'] = 'cross_day';
        await _runCrossDay(profile);
        _diag['stage'] = 'notifications';
        await _runNotifications();
      }
      // 5. Prune raw — never for a day still inside its raw window / un-derived.
      if (scope.fullHistory) {
        _diag['stage'] = 'prune';
        await _pruneOldDecoded(todoDays, dataNowSec);
        // Re-baseline the travel guard — but ONLY if every targeted day
        // actually got re-derived under the current timezone. processDay
        // swallows per-day errors and marks the day skipped, so a restage can
        // "finish" with days still unresolved; clearing the hold then would
        // drop it without the adjacency ever having been fixed. (A day kept
        // deliberately — a pruned override day — is not a failure.)
        if (failures == 0) {
          await LocalDb.putBaseline(
            'tz_travel_guard',
            jsonEncode({'offset_min': DateTime.now().timeZoneOffset.inMinutes}),
          );
        } else {
          _log(
            'derive: $failures day(s) unresolved — keeping the timezone hold',
          );
        }
      }
      return done;
    } catch (e, st) {
      _diag['last_error'] = '$e';
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      // Storage housekeeping runs here, after everything, still holding
      // `_running`. See _runStorageHousekeeping — this is the only place every
      // entry path and every early return actually reaches.
      _diag['stage'] = 'housekeeping';
      await _runStorageHousekeeping();
      _running = false;
      final finishedAt = DateTime.now().millisecondsSinceEpoch;
      _diag
        ..['running'] = false
        ..['stage'] = 'idle'
        ..['active_days'] = const <String>[]
        ..['finished_at'] = finishedAt
        ..['duration_ms'] = finishedAt - startedAt;
      
      try { await runTrace?.stop(); } catch (_) {}
    }
  }

  Future<int> runDays(
    Profile profile,
    Set<String> days, {
    bool force = true,
    void Function(String day, int index, int total)? onDayDone,
  }) async {
    if (days.isEmpty) return 0;
    if (_running) return 0;
    _running = true;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    _diag
      ..['running'] = true
      ..['stage'] = 'scope'
      ..['mode'] = 'selected'
      ..['force'] = force
      ..['started_at'] = startedAt
      ..['finished_at'] = null
      ..['duration_ms'] = null
      ..['raw_pages'] = 0
      ..['raw_rows'] = 0
      ..['max_day_raw_pages'] = 0
      ..['max_day_raw_rows'] = 0
      ..['scope_days'] = days.length
      ..['scope_reason'] = 'selected-days'
      ..['prepared_days'] = 0
      ..['todo_days'] = 0
      ..['done_days'] = 0
      ..['skipped_days'] = 0
      ..['active_days'] = <String>[]
      ..['concurrency'] = _deriveConcurrency
      ..['last_error'] = null;
    try {
      final scope = _scopeForDays(days.toList(), reason: 'selected-days');
      final dataNowSec = await LocalDb.lastDecodedRecTs() ?? 0;
      if (dataNowSec <= 0) {
        _log('derive selected: no decoded data');
        return 0;
      }
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      final todoDays = [
        for (final day in scope.targetDays)
          if (force || !finalized.contains(day)) day,
      ];
      if (todoDays.isEmpty) {
        _log('derive selected: all days finalized — nothing to do');
        return 0;
      }
      _diag['todo_days'] = todoDays.length;
      final history = await _BaselineHistoryCache.load();
      // Same bounded worker-pool pattern as run() — see its doc for why this
      // is safe (independent day_id-keyed writes + a frozen baseline shared
      // read-only across the whole batch).
      final orderedDays = todoDays.reversed.toList();
      var done = 0;
      var completed = 0;
      var failures = 0;
      final activeDays = <String>{};

      Future<void> processDay(String dayId) async {
        activeDays.add(dayId);
        _diag['active_days'] = activeDays.toList();
        try {
          final prepared = await _prepareTargetDay(dayId);
          if (prepared != null) {
            _diag['prepared_days'] = (_diag['prepared_days'] as int) + 1;
            await _derivePreparedDay(prepared, profile, dataNowSec, history);
            done++;
            _diag['done_days'] = done;
          } else {
            _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
            _diag['last_error'] = 'no_bounded_window_payload day=$dayId';
            failures++;
          }
        } catch (e) {
          _log('derive selected day $dayId FAILED/skipped: $e');
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
          failures++;
        }
        activeDays.remove(dayId);
        _diag['active_days'] = activeDays.toList();
        completed++;
        onDayDone?.call(dayId, completed, orderedDays.length);
      }

      await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);
      // A SELECTED re-analyze that happens to cover the whole raw history, with
      // every day resolved, is a full restage by any other name — it re-derived
      // every day under the current timezone, so it clears the travel hold too.
      // A partial selection deliberately does not: those days say nothing about
      // the ones still held.
      if (force && failures == 0) {
        final rawDays = (await LocalDb.decodedRecTsMaxByDay()).keys.toSet();
        if (rawDays.isNotEmpty && rawDays.difference(days).isEmpty) {
          await LocalDb.putBaseline(
            'tz_travel_guard',
            jsonEncode({
              'offset_min': DateTime.now().timeZoneOffset.inMinutes,
            }),
          );
          _log('derive selected: full-coverage restage — timezone hold cleared');
        }
      }
      if (done > 0) {
        await _refreshBaselines();
        await _runCrossDay(profile);
        await _runNotifications();
      }
      return done;
    } catch (e, st) {
      _log('derive selected ERROR: $e\n$st');
      return 0;
    } finally {
      await _runStorageHousekeeping();
      final finishedAt = DateTime.now().millisecondsSinceEpoch;
      _diag
        ..['running'] = false
        ..['stage'] = 'idle'
        ..['finished_at'] = finishedAt
        ..['duration_ms'] = finishedAt - startedAt;
      _running = false;
    }
  }

  static const int _rawDecodeBatchSize = 2000;
  static const int _maxDayRawRows = 500000;
  static const int _maxDayRawPages = 300;

  Future<PreparedDerivationDay?> _prepareTargetDay(String dayId) async {
    // Per-day page/row totals used to live in the shared `_diag` map (reset
    // then accumulated across this day's 2-3 substrate loads). Under
    // concurrent per-day processing (see `run()`), multiple days resetting/
    // incrementing the SAME shared fields would race and produce garbage
    // diagnostics (never a correctness issue for the derived VALUES — this
    // is telemetry-only). Each day now gets its own local accumulator,
    // merged into the shared running max exactly once, below.
    final stats = _PrepareStats();
    final candidate = await _sleepCandidateForDay(dayId, stats: stats);
    final dayStart = _localDayLabelToSec(dayId);
    final dayEnd = _localNextDayLabelToSec(dayId);
    // Load the day PLUS the nap boundary buffer in ONE pass (each
    // _loadSubstrateRange spawns its own isolate, so a second load would
    // double that cost) and slice the calendar day back out of it. Without
    // this, the live decoded path — run()/runDays()/rescanRecent(), i.e. every
    // non-import day — fell back to napSub == daySub and went on bisecting
    // naps at midnight.
    final napSub = await _loadSubstrateRange(
      dayStart,
      dayEnd - 1 + napBoundaryBufferSec,
      dayId: dayId,
      stats: stats,
    );
    final daySub = napSub.slice(dayStart, dayEnd);
    Substrate sleepSub = Substrate.empty;
    if (candidate.present &&
        candidate.sleepOffsetSec > candidate.sleepOnsetSec) {
      sleepSub = await _loadSubstrateRange(
        candidate.sleepOnsetSec,
        candidate.sleepOffsetSec - 1,
        dayId: dayId,
        stats: stats,
      );
    }
    // Single safe merge into the shared max-tracking diagnostics — one
    // statement, no `await` in between, so it's atomic relative to any other
    // concurrently-running day's identical merge.
    if (stats.pages > (_diag['max_day_raw_pages'] as int)) {
      _diag['max_day_raw_pages'] = stats.pages;
    }
    if (stats.rows > (_diag['max_day_raw_rows'] as int)) {
      _diag['max_day_raw_rows'] = stats.rows;
    }
    return candidate.toPreparedDay(
      daySub: daySub,
      napSub: napSub,
      sleepSub: sleepSub,
    );
  }

  Future<SleepSessionCandidate> _sleepCandidateForDay(
    String dayId, {
    _PrepareStats? stats,
  }) async {
    // A user sleep override is the source of truth — never serve the cached auto
    // candidate, and don't cache the override result (so a later edit / clear is
    // not shadowed by a stale artifact). The auto path keeps its finalized cache.
    final overrideRow = await LocalDb.getSleepOverride(dayId);
    final override = overrideRow == null
        ? null
        : SleepWindowOverride(
            dayId: dayId,
            onsetSec: (overrideRow['onset_ts'] as num).toInt(),
            offsetSec: (overrideRow['offset_ts'] as num).toInt(),
            source: overrideRow['source'] as String? ?? 'manual',
          );

    if (override == null) {
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      if (finalized.contains(dayId)) {
        final cached = await LocalDb.sleepSessionCandidate(dayId, kAlgoVersion);
        final raw = cached?['payload_json'];
        if (raw is String && raw.isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              return SleepSessionCandidate.fromJson(
                decoded.cast<String, dynamic>(),
              );
            }
          } catch (_) {
            // Fall through to rebuild the artifact.
          }
        }
      }
    }
    final range = _targetDayWindow(dayId);
    final searchSub = await _loadSubstrateRange(
      range.$1,
      range.$2,
      dayId: dayId,
      stats: stats,
    );
    // PERSONALIZED STAGER (v42): stage on a WORKER isolate, NOT the main/UI
    // thread. cardioStager reads analytics "ambient" globals — the rolling sleep
    // profile (`cardioUserProfile`) it blends in (bounded ≤0.5) and the
    // observation-recording flag it folds back afterwards. Those globals are
    // ISOLATE-LOCAL (they don't cross `Isolate.run`), which is why v42 originally
    // ran staging on the main isolate — and, per-30-s-epoch over a full night,
    // that landed the trig/Lomb–Scargle load on the UI thread and produced the
    // recurring multi-second freezes → Android ANRs (Crashlytics 0.9.13). We now
    //   (1) read the profile from the DB HERE (the main isolate owns the DB) as
    //       plain JSON,
    //   (2) re-arm the ambient globals and run the staging + EWMA profile fold
    //       INSIDE the worker, and
    //   (3) return the staged candidate + folded profile as plain JSON to persist
    //       back on main.
    // The worker isolate dies after `Isolate.run`, so the recording flag can't
    // leak into the next day's derivation — no try/finally reset needed.
    final profileJson = await _loadSleepUserProfileJson();
    // Which day_ids have ALREADY been folded into that profile. See
    // [_kFoldedDaysKey] for why this exists and why a legacy profile that
    // lacks it is discarded rather than trusted.
    final foldedDays = SleepProfilePolicy.foldedDays(profileJson);
    final mayFold = SleepProfilePolicy.shouldFold(
      alreadyFolded: foldedDays,
      dayId: dayId,
      hasOverride: override != null,
    );
    // Cancellable + TIMED OUT. This site previously used a bare `Isolate.run`
    // with no timeout at all, so a hung staging pass never completed its future
    // — `_running` stayed true and `DeriveScheduler._drain` never returned, i.e.
    // all derivation was dead until app restart.
    final (candidateJson, observationJson) =
        await _runIsolateCancellable(() {
      try {
        final p = profileJson == null
            ? null
            : ana.SleepUserProfile.fromJson(
                (jsonDecode(profileJson) as Map).cast<String, dynamic>());
        // Warm-up gate — see SleepProfilePolicy.shouldBlend. Note the profile
        // is only WITHHELD FROM STAGING here; accumulation into it happens on
        // the main isolate in _foldObservationIntoProfile, which re-reads the
        // current profile, so a withheld night still counts toward `nights`.
        ana.cardioUserProfile =
            SleepProfilePolicy.shouldBlend(p?.nights) ? p : null;
      } catch (_) {
        // Defense in depth: an incompatible/outdated persisted profile must
        // fall back to a cold start, never throw inside the worker (an uncaught
        // throw here bubbles to processDay's per-day catch → the day gets stuck
        // marked 'error' every pass until the row is fixed).
        ana.cardioUserProfile = null;
      }
      ana.cardioRecordObservations = true;
      ana.resetCardioObservations();
      final candidate = prepareSleepSessionCandidate(
        searchSub,
        targetDay: dayId,
        override: override,
      );
      // Fold the MAIN sleep (most epochs) of a freshly-staged night into the
      // rolling profile — done here in the worker because the observations live
      // in THIS isolate's globals. Skipped for overrides. EWMA self-seeds.
      String? observationJson;
      // IDEMPOTENT PER DAY. `fold()` is an EWMA step that also increments
      // `nights`, and this path runs on EVERY staging pass for a day — an
      // algo-version bump, a BLE-drain re-derive, a backfill sweep. Without a
      // guard the same handful of real nights fold hundreds of times: a real
      // user export showed `nights: 1348` against 12 days of data, which pins
      // `personalWeight` at its 0.5 cap from day one and collapses the EWMA
      // onto whichever day was re-derived last. Measured effect of that
      // corrupt profile on the same nights: wake 4.3% -> 36.4%, deep 1.9% ->
      // 0.0%. One fold per day_id, ever.
      if (mayFold) {
        final obs = ana.takeCardioObservations();
        if (obs.isNotEmpty) {
          obs.sort((a, b) => b.epochs.compareTo(a.epochs));
          final main = obs.first;
          if (main.epochs >= 120) {
            // require ≥60 min — not a nap.
            // Return the raw OBSERVATION, not a folded profile. Folding here
            // would bake in the profile this worker read before staging began,
            // and a concurrent day may have written a newer one since. The
            // fold happens on the main isolate under the profile lock.
            observationJson = jsonEncode({
              'epochs': main.epochs,
              'hr_floor_p5': main.hrFloorP5,
              'hr_floor_p25': main.hrFloorP25,
              'hr_sleep_median': main.hrSleepMedian,
              'hr_arousal': main.hrArousal,
              'rmssd_med': main.rmssdMed,
              'rmssd_mad': main.rmssdMad,
              'enmo_still_cut': main.enmoStillCut,
              'enmo_move_cut': main.enmoMoveCut,
              'lfhf_med': main.lfhfMed,
              'rk_med': main.rkMed,
            });
          }
        }
      }
      return (jsonEncode(candidate.toJson()), observationJson);
    }, _perDayTimeout, label: 'sleep-staging $dayId');
    final candidate = SleepSessionCandidate.fromJson(
        (jsonDecode(candidateJson) as Map).cast<String, dynamic>());
    if (override == null) {
      await LocalDb.putSleepSessionCandidate(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: candidateJson,
      );
      if (observationJson != null) {
        // BEST-EFFORT, and deliberately isolated from the day's success path.
        // The fold is bookkeeping; the day's real result is already persisted
        // above. `updateBaseline` takes an exclusive SQLite write lock, and the
        // whole point of this change is that two derivation isolates contend
        // for it — so SQLITE_BUSY here is an EXPECTED outcome, not an
        // exceptional one. Letting it escape would hit processDay's broad
        // catch, which calls `_markDaySkipped` and increments `failures`,
        // throwing away a fully computed day (and holding the timezone) over a
        // bookkeeping write.
        //
        // KNOWN LIMITATION — a swallowed failure here is PERMANENT for this
        // day, not retried. Once the day finalizes, the cached-candidate
        // short-circuit at the top of this method returns before staging runs,
        // so `observationJson` is never regenerated and the fold never happens.
        // Same for a day whose override is later removed if it already has a
        // cached candidate from before the override.
        //
        // Accepted deliberately rather than fixed: the profile is an EWMA with
        // a ~14-night horizon and a hard 0.5 blend cap, so one missing night is
        // a small perturbation, whereas a retry path needs durable pending
        // state and a way to distinguish "failed, retry" from "declined
        // permanently" (a <120-epoch nap never folds, and would otherwise
        // bypass the candidate cache and re-stage on every sweep forever).
        // If the fold ever stops being best-effort, that state machine is the
        // thing to build — do not simply bypass the cache.
        try {
          await _foldObservationIntoProfile(dayId, observationJson);
        } catch (e) {
          _log('sleep profile fold skipped for $dayId (day result kept, '
              'this night will not contribute to the profile): $e');
        }
      }
    }
    return candidate;
  }

  /// Fold one night's observation into the shared profile, serialised against
  /// every other day in the sweep.
  ///
  /// The profile is RE-READ inside the lock and [SleepProfilePolicy.shouldFold]
  /// re-checked, because the value this day read before staging is stale by
  /// definition — a concurrently-derived day may have folded since. Skipping
  /// that re-check is what turns a read-modify-write race into a lost fold plus
  /// a lost day_id, and the day then re-folds forever.
  Future<void> _foldObservationIntoProfile(
      String dayId, String observationJson) async {
    final Map<String, dynamic> o;
    try {
      o = (jsonDecode(observationJson) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    double? d(String k) => (o[k] as num?)?.toDouble();
    final observed = ana.SleepNightObservation(
      epochs: (o['epochs'] as num?)?.toInt() ?? 0,
      hrFloorP5: d('hr_floor_p5'),
      hrFloorP25: d('hr_floor_p25'),
      hrSleepMedian: d('hr_sleep_median'),
      hrArousal: d('hr_arousal'),
      rmssdMed: d('rmssd_med'),
      rmssdMad: d('rmssd_mad'),
      enmoStillCut: d('enmo_still_cut'),
      enmoMoveCut: d('enmo_move_cut'),
      lfhfMed: d('lfhf_med'),
      rkMed: d('rk_med'),
    );
    // The whole read-modify-write happens inside ONE exclusive DB transaction.
    // A Dart mutex cannot do this job: `derivationDispatcher` is a
    // vm:entry-point WorkManager entry that builds its own DerivationEngine in
    // a SEPARATE background isolate, and a `static` lock has one copy per
    // isolate — so a background heavy pass and a foreground sweep would each
    // read the same profile, fold, and clobber the other, losing both the fold
    // and its day_id from folded_days. SQLite's write lock is cross-connection
    // and therefore cross-isolate.
    await LocalDb.updateBaseline('sleep_user_profile', (current) {
      // Re-derive freshness INSIDE the transaction: the value this day read
      // before staging is stale by definition, another lane may have folded
      // since. Returning null leaves the row untouched.
      final usable = SleepProfilePolicy.usableProfileJson(current);
      final freshDays = SleepProfilePolicy.foldedDays(usable);
      if (!SleepProfilePolicy.shouldFold(
          alreadyFolded: freshDays, dayId: dayId, hasOverride: false)) {
        return null;
      }
      final ana.SleepUserProfile base;
      try {
        base = usable == null
            ? const ana.SleepUserProfile()
            : ana.SleepUserProfile.fromJson(
                (jsonDecode(usable) as Map).cast<String, dynamic>());
      } catch (_) {
        return null; // unreadable — leave it for the cold-start path
      }
      return jsonEncode(SleepProfilePolicy.withFoldedDays(
          base.fold(observed).toJson(), freshDays, dayId));
    });
  }

  /// Read the persisted per-user sleep profile (`baselines` key
  /// `sleep_user_profile`) as raw JSON, for passing into the staging worker
  /// isolate. Absent/corrupt ⇒ null (cold start). DB read stays on the main
  /// isolate (the DB owner); the worker reconstructs the profile from this JSON.
  ///
  /// A profile written before per-day fold tracking existed carries no
  /// [_kFoldedDaysKey] and therefore an untrustworthy `nights` count and an
  /// EWMA skewed by repeated re-folds of the same nights. We cannot repair it
  /// (there is no record of which days went in), so we DISCARD it and rebuild.
  /// That degrades to pure per-night-local baselines — the cold-start path
  /// cardio_stager.dart was validated on — and the profile re-earns its weight
  /// over the next few nights under the corrected accounting.
  Future<String?> _loadSleepUserProfileJson() async {
    final row = await LocalDb.baseline('sleep_user_profile');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    // Validate here (mirrors the cached-candidate guard above) so a corrupt
    // payload becomes a cold start, per this method's contract — rather than
    // throwing later inside the staging worker's `jsonDecode(...) as Map`.
    return SleepProfilePolicy.usableProfileJson(raw);
  }

  Future<Substrate> _loadSubstrateRange(
    int fromRecTs,
    int toRecTs, {
    required String dayId,
    _PrepareStats? stats,
  }) async {
    if (toRecTs < fromRecTs) return Substrate.empty;
    final port = ReceivePort();
    // onError/onExit are LOAD-BEARING. Without them, an uncaught throw inside
    // the worker (a malformed SQLite row reaching one of the numeric reads in
    // its 'page' handler — the worker only ever reported errors from its
    // 'finish' branch) killed the isolate silently, and this side awaited
    // `result.future` FOREVER with `_running == true`: DeriveScheduler._drain
    // never returned and ALL derivation was dead until app restart. Now a
    // worker death fails the future, and the timeout below bounds the wait
    // even if no signal arrives at all.
    final isolate = await Isolate.spawn(
      derivationPrepareWorker,
      port.sendPort,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final ready = Completer<SendPort>();
    final result = Completer<Substrate>();
    // A failure completes BOTH completers, but we may bail out via `ready` and
    // never await `result` — register a listener so that error is never an
    // unobserved async error. (The real error still propagates via `ready`.)
    unawaited(result.future.catchError((_) => Substrate.empty));
    late final StreamSubscription<dynamic> sub;
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      if (!result.isCompleted) result.completeError(error);
    }

    sub = port.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is Map && message['type'] == 'result') {
        final kind = message['kind']?.toString();
        if (kind == 'substrate') {
          final payload = ((message['payload'] as Map?) ?? const {})
              .cast<String, dynamic>();
          if (!result.isCompleted) result.complete(Substrate.fromJson(payload));
        }
        return;
      }
      if (message is Map && message['type'] == 'error') {
        fail(Exception('prepare worker error: ${message['error']}'));
        return;
      }
      if (message is List) {
        // `onError` wire format ([error, stackTrace]) — an uncaught throw.
        fail(Exception('prepare worker crashed: '
            '${message.isNotEmpty ? message.first : "no detail"}'));
        return;
      }
      if (message == null) {
        // `onExit` — the isolate ended without ever sending a result.
        fail(StateError('prepare worker exited without a result'));
      }
    });
    try {
      final worker = await ready.future;
      worker.send(const {'type': 'config', 'mode': 'substrate'});
      int? afterRecTs;
      int? afterCursor;
      var rangePages = 0;
      var rangeRows = 0;
      while (true) {
        final decodedRows = await LocalDb.decodedOneHzBatchByRecTsRange(
          limit: _rawDecodeBatchSize,
          fromRecTs: fromRecTs,
          toRecTs: toRecTs,
          afterRecTs: afterRecTs,
          afterCounter: afterCursor,
        );
        if (decodedRows.isNotEmpty) {
          _trackPrepareBatch(decodedRows.length);
          rangePages += 1;
          rangeRows += decodedRows.length;
          if (stats != null) {
            stats.pages += 1;
            stats.rows += decodedRows.length;
          }
          _enforcePrepareBudget(
            dayId: dayId,
            fromRecTs: fromRecTs,
            toRecTs: toRecTs,
            rangePages: rangePages,
            rangeRows: rangeRows,
          );
          final firstCounter = (decodedRows.first['counter'] as num?)?.toInt();
          final lastCounter = (decodedRows.last['counter'] as num?)?.toInt();
          final rrRows = firstCounter == null || lastCounter == null
              ? const <Map<String, dynamic>>[]
              : await LocalDb.decodedRrByCounterRange(
                  fromCounter: firstCounter,
                  toCounter: lastCounter,
                );
          worker.send({'type': 'page', 'frames': decodedRows, 'rr': rrRows});
          final last = decodedRows.last;
          afterRecTs = (last['rec_ts'] as num?)?.toInt() ?? afterRecTs;
          afterCursor = (last['counter'] as num?)?.toInt() ?? afterCursor;
          if (decodedRows.length < _rawDecodeBatchSize) break;
          continue;
        }
        break;
      }
      worker.send(const {'type': 'finish'});
      // BOUNDED. `result.future` had no timeout at all, so any path that left
      // the worker unable to answer hung this call — and with it the whole
      // engine — permanently.
      return await result.future.timeout(
        _perDayTimeout,
        onTimeout: () => throw TimeoutException(
          'substrate prepare for $dayId timed out after $_perDayTimeout',
        ),
      );
    } finally {
      // ALWAYS tear down: on success, on error, and on timeout. The isolate is
      // killed rather than abandoned so a wedged worker can never outlive the
      // call that spawned it.
      await sub.cancel();
      port.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  // Cumulative across the WHOLE run — safe under concurrent per-day
  // processing since each field is a simple, non-`await`-split increment
  // (order across days doesn't matter for a total). Per-day max tracking
  // moved to `_PrepareStats` + the single merge at the end of
  // `_prepareTargetDay`, since that DOES need per-day isolation.
  void _trackPrepareBatch(int rows) {
    _diag['raw_pages'] = (_diag['raw_pages'] as int) + 1;
    _diag['raw_rows'] = (_diag['raw_rows'] as int) + rows;
  }

  void _enforcePrepareBudget({
    required String dayId,
    required int fromRecTs,
    required int toRecTs,
    required int rangePages,
    required int rangeRows,
  }) {
    if (rangeRows > _maxDayRawRows || rangePages > _maxDayRawPages) {
      throw Exception(
        'day_prepare_budget_exceeded day=$dayId rows=$rangeRows '
        'pages=$rangePages range=$fromRecTs-$toRecTs',
      );
    }
  }

  Future<_DeriveScope> _deriveScope({
    required bool heavy,
    required bool force,
  }) async {
    final rawByDay = await LocalDb.decodedRecTsMaxByDay();
    if (rawByDay.isEmpty) {
      return const _DeriveScope(
        fullHistory: true,
        targetDays: [],
        reason: 'empty',
      );
    }
    final rawDays = rawByDay.keys.toList()..sort();
    if (force) {
      // A full restage resolves any held-back timezone-adjacent days on its
      // own, so it clears the guard — but only once it has actually RUN. See
      // the reset at the end of run(): clearing it here, at scope-selection
      // time, meant an interrupted restage still dropped the hold.
      return _scopeForDays(rawDays, reason: 'full-history', fullHistory: true);
    }

    final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
    var pending = [
      for (final day in rawDays)
        if (!finalized.contains(day)) day,
    ];

    // decodedRecTsMaxByDay() buckets by the CURRENT device timezone, but
    // `finalized` was frozen under whatever timezone was active when each day
    // was derived. A real cross-timezone trip (not an ~1h DST shift) can make
    // the SAME rec_ts rows relabel to a day adjacent to one already finalized
    // — looking like a brand-new "pending" night that's really a duplicate, or
    // silently landing on an already-finalized day_id and looking lost. Once
    // that's detected, hold off auto-deriving anything adjacent to finalized
    // data until "Re-analyze data" (full restage) resolves it properly.
    if (await _timezoneTravelSuspected()) {
      final adjacent = <String>{
        for (final day in finalized) ..._adjacentDayIds(day),
      };
      final held = pending.where(adjacent.contains).toList();
      if (held.isNotEmpty) {
        _log(
          'derive: possible timezone change — holding ${held.length} day(s) '
          'adjacent to finalized data until Re-analyze data runs: $held',
        );
        pending = pending.where((d) => !adjacent.contains(d)).toList();
        if (pending.isEmpty) {
          // Everything pending was held. Falling through to the
          // 'latest-finalized-check' below would re-derive rawDays.last —
          // one of the very days just held — defeating the hold entirely.
          return const _DeriveScope(
            fullHistory: false,
            targetDays: [],
            reason: 'tz-travel-hold',
          );
        }
      }
    }
    if (pending.isEmpty) {
      return _scopeForDays([rawDays.last], reason: 'latest-finalized-check');
    }

    if (heavy) {
      return _scopeForDays(pending, reason: 'pending-span');
    }

    final light = selectLightDeriveDays(
      rawDays: rawByDay.keys.toSet(),
      pendingDays: pending,
      today: LocalDb.localDayLabelNow(),
    );
    return _scopeForDays(light.days, reason: light.reason);
  }

  /// The day before and after [dayId] ('YYYY-MM-DD'), DST-safe (goes through
  /// real DateTime arithmetic, not a raw ±86400s offset).
  static List<String> _adjacentDayIds(String dayId) {
    final d = DateTime.tryParse(dayId);
    if (d == null) return const [];
    String label(DateTime x) =>
        '${x.year.toString().padLeft(4, '0')}-'
        '${x.month.toString().padLeft(2, '0')}-'
        '${x.day.toString().padLeft(2, '0')}';
    return [
      label(DateTime(d.year, d.month, d.day - 1)),
      label(DateTime(d.year, d.month, d.day + 1)),
    ];
  }

  /// True right after the device timezone jumps by more than a real DST shift
  /// ever would (>=3h) — a strong signal of actual cross-timezone travel
  /// rather than a seasonal clock change. Stays true across repeated calls
  /// (derive runs many times a day) by only ever updating the persisted
  /// baseline offset when NO jump is detected — updating it unconditionally
  /// would make the very next call see lastOffset == nowOffset and silently
  /// drop the guard after a single pass. `force` (full restage) is what
  /// resets it, per _deriveScope.
  static const int _tzJumpThresholdMin = 180;
  Future<bool> _timezoneTravelSuspected() async {
    final nowOffsetMin = DateTime.now().timeZoneOffset.inMinutes;
    final row = await LocalDb.baseline('tz_travel_guard');
    final raw = row?['payload_json'];
    int? lastOffsetMin;
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) lastOffsetMin = (d['offset_min'] as num?)?.toInt();
      } catch (_) {
        // fall through — treat as unknown
      }
    }
    if (lastOffsetMin == null) {
      await LocalDb.putBaseline(
        'tz_travel_guard',
        jsonEncode({'offset_min': nowOffsetMin}),
      );
      return false;
    }
    final jumped = (nowOffsetMin - lastOffsetMin).abs() >= _tzJumpThresholdMin;
    if (!jumped) {
      await LocalDb.putBaseline(
        'tz_travel_guard',
        jsonEncode({'offset_min': nowOffsetMin}),
      );
    }
    return jumped;
  }

  _DeriveScope _scopeForDays(
    List<String> days, {
    required String reason,
    bool fullHistory = false,
  }) {
    final sorted = days.toSet().toList()..sort();
    if (sorted.isEmpty || fullHistory) {
      return _DeriveScope(
        fullHistory: true,
        targetDays: sorted,
        reason: reason,
      );
    }
    return _DeriveScope(fullHistory: false, targetDays: sorted, reason: reason);
  }

  // ── baseline-dirty recent rescan ─────────────────────────────────────────────

  /// Re-derive the recent (≤ raw-retention) window — INCLUDING finalized days —
  /// when the rolling baseline has actually shifted, so baseline-DEPENDENT
  /// scalars (readiness/recovery, illness/anomaly, stress) on already-finalized
  /// days refresh as later data moves their baseline.
  ///
  /// CHEAP BY DEFAULT: we gate on a baseline SIGNATURE — a stable hash of the
  /// current rolling baseline compared to the stored `baseline_sig` cursor. If unchanged
  /// we do ~one read and return 0 (no redundant writes). Only a real baseline
  /// change re-derives, and only the recent window (older raw is already pruned).
  ///
  /// Re-entrant calls are coalesced (shares the `_running` guard with run()).
  /// Best-effort: returns the number of days re-derived (0 on skip/empty/error).
  Future<int> rescanRecent(
    Profile profile, {
    void Function(String day, int index, int total)? onDayDone,
  }) async {
    if (_running) return 0;
    _running = true;
    try {
      // Baseline gate: compute the CURRENT signature and compare to the stored
      // one. Unchanged → nothing to refresh; bail cheaply (no redundant writes).
      final sig = await _baselineSignature();
      final prev = await LocalDb.getCursor('baseline_sig');
      if (sig == prev) {
        _log('baseline unchanged — rescan skipped');
        return 0;
      }

      final rawByDay = await LocalDb.decodedRecTsMaxByDay();
      if (rawByDay.isEmpty) {
        _log('rescan: no decoded data');
        return 0;
      }
      final dataNowSec = await LocalDb.lastDecodedRecTs() ?? 0;
      if (dataNowSec <= 0) {
        _log('rescan: no data edge');
        return 0;
      }
      final cutoffSec = dataNowSec - _rescanWindowDays * 86400;
      final todoDays = [
        for (final dayId in rawByDay.keys)
          if (_localNextDayLabelToSec(dayId) >= cutoffSec) dayId,
      ]..sort();
      if (todoDays.isEmpty) {
        _log('rescan: no recent decoded-backed days');
        await LocalDb.setCursor('baseline_sig', sig);
        return 0;
      }
      _log(
        'rescan: baseline changed — re-deriving ${todoDays.length} '
        'recent day(s) (incl. finalized; v$kAlgoVersion)',
      );

      final history = await _BaselineHistoryCache.load();
      // Same bounded worker-pool pattern as run()/runDays — up to
      // _rescanWindowDays (21) days is exactly the kind of sweep that used
      // to run fully sequentially for no reason (independent day_id-keyed
      // writes + one frozen baseline snapshot shared read-only here).
      final orderedDays = todoDays.reversed.toList();
      var done = 0;
      var completed = 0;

      Future<void> processDay(String dayId) async {
        try {
          final prepared = await _prepareTargetDay(dayId);
          if (prepared != null) {
            await _derivePreparedDay(prepared, profile, dataNowSec, history);
            done++;
          }
        } catch (e) {
          _log('rescan day $dayId FAILED/skipped: $e');
          // Do NOT mark-skipped here — a finalized day already has a good row;
          // overwriting it with a skip marker would DISCARD real structure.
        }
        completed++;
        onDayDone?.call(dayId, completed, orderedDays.length);
      }

      await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);

      await _refreshBaselines();
      // Cross-day rollup + notifications reflect the refreshed scalars.
      await _runCrossDay(profile);
      await _runNotifications();
      // Store the new signature so the next tick is a cheap no-op until it moves.
      await LocalDb.setCursor('baseline_sig', await _baselineSignature());
      return done;
    } catch (e, st) {
      _log('rescan ERROR: $e\n$st');
      return 0;
    } finally {
      await _runStorageHousekeeping();
      _running = false;
    }
  }

  /// A stable, cheap signature of the CURRENT rolling baseline — the same inputs
  /// the readiness/illness baselines fold over. We take the trailing
  /// _baselineWindowDays derived rows and the median of each baseline series
  /// (RHR, RMSSD, skin-temp ADC mean, respiration), rounded to a stable
  /// precision, joined into a string. When new days land (or a recent day is
  /// re-derived) these medians shift and the signature changes → a rescan fires;
  /// when nothing moved the signature is byte-identical → the rescan is skipped.
  Future<String> _baselineSignature() async {
    final artifact = await LocalDb.baseline('rolling_artifact');
    final raw = artifact?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final sig = decoded['signature']?.toString();
          if (sig != null && sig.isNotEmpty) return sig;
        }
      } catch (_) {
        // Fall back to rebuilding the signature.
      }
    }
    final history = await _BaselineHistoryCache.load();
    return history.toArtifactJson()['signature']?.toString() ??
        'v$kAlgoVersion|na';
  }

  /// Foreground vs background pacing — lane count and per-day wall-clock
  /// budget. See [DerivePacing] for why the background numbers differ.
  DerivePacing get _pacing => DerivePacing(background: background);

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress.
  Duration get _perDayTimeout => _pacing.perDayTimeout;

  /// Throttle for the readiness-absent diagnostic log — one per calendar day
  /// so repeated light-pass re-derives of today don't spam the outbox.
  String? _loggedReadinessAbsentFor;

  /// Bounded worker-pool size for concurrent per-day derivation. Days within
  /// a single run share ONE frozen baseline snapshot (`_BaselineHistoryCache`
  /// is loaded once before the loop, refreshed once after — see `run()`) and
  /// each writes to an independent, day_id-keyed `day_result` row — there is
  /// no cross-day ordering dependency within a run. A multi-day backlog sweep
  /// was previously fully sequential (one day's prepare-isolate + prepare
  /// substrate loads + compute-isolate all finishing before the next day even
  /// started), which wastes every core beyond the one doing the current day's
  /// work. Running several days' isolate work genuinely concurrently gets
  /// real wall-clock speedup from the device's other cores — in the FOREGROUND.
  /// A headless background slot has no spare cores to soak up, so it takes one
  /// lane; [DerivePacing] owns that decision and explains it.
  int get _deriveConcurrency {
    try {
      return _pacing.concurrency(Platform.numberOfProcessors);
    } catch (_) {
      return 1; // Platform unavailable on this target — sequential fallback
    }
  }

  // ── imports (derive from a pre-built substrate, not from stored raw) ─────────

  /// Derive the named [dates] from a caller-supplied [sub] (e.g. a CSV import
  /// rebuilt into a Substrate), reusing the FULL per-day pipeline (sleep / HRV /
  /// strain / workouts / advanced_sleep) — so imported raw 1 Hz gets the exact
  /// same analytics as a live band sync. [sub] should span the requested dates
  /// PLUS the prior evening (a night's sleep starts before midnight, and the day
  /// model searches `prev 18:00 → noon`); the caller windows the stream so memory
  /// stays bounded. Each derived day is FORCE-FINALIZED (imports are immutable
  /// snapshots — there is no stored raw to recompute them from). Returns the
  /// number of days written. Does NOT prune raw or run the cross-day rollup —
  /// call [finalizeImport] once after all windows.
  Future<int> deriveImportedDays(
    Substrate sub,
    Profile profile,
    Set<String> dates, {
    void Function(String day)? onDayDone,
  }) async {
    if (sub.isEmpty || dates.isEmpty) return 0;
    final days = calendarDays(sub);
    final dataNowSec = sub.lastTs ?? 0;
    var done = 0;
    for (final day in days) {
      if (!dates.contains(day.date)) continue;
      try {
        await _deriveDay(sub, day, profile, dataNowSec, forceFinalize: true);
        done++;
        onDayDone?.call(day.date);
      } catch (e) {
        _log('import day ${day.date} FAILED/skipped: $e');
      }
    }
    return done;
  }

  /// Run the cross-day rollup + notifications + baseline refresh once after an
  /// import completes (reflects the freshly imported day history).
  Future<void> finalizeImport(Profile profile) async {
    await _refreshBaselines();
    await _runCrossDay(profile);
    await _runNotifications();
  }

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<void> _deriveDay(
    Substrate sub,
    PhysioDay day,
    Profile profile,
    int dataNowSec, {
    bool forceFinalize = false,
  }) async {
    final daySub = sub.slice(day.startSec, day.endSec);
    // Same buffered slice prepareDerivationPayload uses — without it, imported
    // days fall back to daySub and a nap straddling midnight is bisected again
    // on exactly the path this PR set out to fix.
    final napSub = sub.slice(day.startSec, day.endSec + napBoundaryBufferSec);
    final sleepSub = day.hasSleep
        ? sub.sliceIdx(day.sleepLoIdx, day.sleepHiIdx)
        : Substrate.empty;
    final hypno = day.sleep.stages4.isNotEmpty
        ? List<String>.from(day.sleep.stages4)
        : <String>[
            for (final s in day.sleep.stages)
              s == ana.SleepStage.wake
                  ? 'wake'
                  : (s == ana.SleepStage.rem ? 'rem' : 'light'),
          ];
    final win = day.sleep.window;
    final onsetSec = win == null
        ? 0
        : (win.onsetMs != null
              ? (win.onsetMs! / 1000).round()
              : (sleepSub.firstTs ?? 0));
    final offsetSec = win == null
        ? 0
        : (win.offsetMs != null
              ? (win.offsetMs! / 1000).round() + 1
              : ((sleepSub.lastTs ?? -1) + 1));
    await _derivePreparedDay(
      PreparedDerivationDay(
        date: day.date,
        endSec: day.endSec,
        confidence: day.confidence,
        flags: List<String>.from(day.flags),
        sleepJson: day.sleep.toJson(),
        hypnoStages: hypno,
        sleepOnsetSec: onsetSec,
        sleepOffsetSec: offsetSec,
        daySub: daySub,
        napSub: napSub,
        sleepSub: sleepSub,
      ),
      profile,
      dataNowSec,
      await _BaselineHistoryCache.load(),
      forceFinalize: forceFinalize,
    );
  }

  Future<void> _derivePreparedDay(
    PreparedDerivationDay day,
    Profile profile,
    int dataNowSec,
    _BaselineHistoryCache history, {
    bool forceFinalize = false,
  }) async {
    final daySub = day.daySub;
    final sleepSub = day.sleepSub;
    // Per-second 4-class stage labels (the single source): 'wake'|'light'|
    // 'deep'|'rem'. analytics' segmentSleep exposes the 4-class stream directly
    // (NREM split into Light/Deep via the LOW-CONFIDENCE HR-depth overlay); we
    // pass it through verbatim so the UI can render Light vs Deep. Fall back to
    // the 3-class enum (light = plain NREM) only if stages4 is unexpectedly empty.
    final input = DayBundleInput(
      date: day.date,
      dayTsSec: daySub.tsSec,
      dayHr: daySub.hr,
      dayRrTsMs: daySub.rrTsMs,
      dayRrMs: daySub.rrMs,
      sleepTsSec: sleepSub.tsSec,
      sleepHr: sleepSub.hr,
      sleepRrTsMs: sleepSub.rrTsMs,
      sleepRrMs: sleepSub.rrMs,
      sleepSpo2Red: sleepSub.spo2Red,
      sleepSpo2Ir: sleepSub.spo2Ir,
      sleepSkinTemp: sleepSub.skinTemp,
      sleepJson: day.sleepJson,
      hypnoStages: day.hypnoStages,
      sleepOnsetSec: day.sleepOnsetSec,
      sleepOffsetSec: day.sleepOffsetSec,
      profile: profile.toMap(),
      dayConfidence: day.confidence,
      dayFlags: day.flags,
    );
    final withHistory = _attachHistory(input, history);

    // Cancellable: on timeout the isolate is KILLED, not merely abandoned to
    // keep burning a core behind the worker pool's back.
    final bundle = await _runIsolateCancellable(
      () => deriveDayBundle(withHistory),
      _perDayTimeout,
      label: 'day-bundle ${day.date}',
    );
    _logSpo2Diagnostics(day, input, bundle);
    // Readiness came back absent for TODAY specifically (not a historical
    // backfill day, which would just be noise) — log why. This ran inside
    // Isolate.run so it couldn't call Firebase itself; it just returned the
    // per-input diagnostic (see onehz_pipeline.dart's readinessAbsentDiag).
    // Throttled to once/day so repeated light-pass re-derives of today don't
    // spam the outbox with the same finding.
    final absentDiag = bundle['readiness_absent_diag'];
    if (absentDiag != null &&
        day.date == todayLabel() &&
        _loggedReadinessAbsentFor != day.date) {
      _loggedReadinessAbsentFor = day.date;
      TelemetryService.instance.breadcrumb('readiness absent: $absentDiag');
      // Flattened, not the raw nested map: record()'s Analytics forwarding
      // only keeps num/String values as-is and stringifies everything else,
      // so passing {'hrv': {'value': ..., 'baseline_n': ...}, ...} directly
      // would turn each input into one unqueryable "{value: true, ...}"
      // string instead of separately filterable fields.
      final diag = (absentDiag as Map).cast<String, dynamic>();
      final flat = <String, dynamic>{};
      for (final key in ['hrv', 'rhr', 'resp', 'temp']) {
        final v = (diag[key] as Map?)?.cast<String, dynamic>();
        if (v == null) continue;
        flat['${key}_value'] = v['value'];
        flat['${key}_baseline_n'] = v['baseline_n'];
        flat['${key}_baseline_sd'] = v['baseline_sd'];
      }
      flat['note'] = diag['note'];
      TelemetryService.instance.record(
        kind: 'event',
        level: 'warn',
        message: 'readiness_absent',
        context: flat,
      );
      // Also surface the SURPRISING case — readiness absent when it should NOT
      // be (adequate inputs, not the honest cold-start `need_baseline` note) —
      // as a queryable Crashlytics non-fatal, so a residual "readiness '—' even
      // with sleep present" is diagnosable from the per-input flags WITHOUT GA4
      // access. Cold-start (need_baseline) absences stay Analytics-only so this
      // stays low-noise (and, post the MAD/SD-z fallback, rare).
      //
      // GATE: only fire the Crashlytics non-fatal when at least one input
      // actually HAD a value with an adequate baseline (`value == true` — the
      // "should have computed" case) — a day with literally no sleep session
      // and no day-HR (every input false) is an honest, unremarkable miss, not
      // a surprise, and was previously alarming here just as loudly as a real
      // regression (analytics-only note above still records it either way).
      final note = (diag['note'] as String?) ?? '';
      final anyValuePresent = ['hrv', 'rhr', 'resp', 'temp'].any((key) {
        final v = (diag[key] as Map?)?.cast<String, dynamic>();
        return v != null && v['value'] == true;
      });
      if (!note.startsWith('need_baseline') && anyValuePresent) {
        final summary = StringBuffer('readiness_absent');
        for (final key in ['hrv', 'rhr', 'resp', 'temp']) {
          final v = (diag[key] as Map?)?.cast<String, dynamic>();
          if (v == null) continue;
          summary.write(
              ' $key=${v['value'] == true ? 'Y' : 'n'}/${v['baseline_n']}'
              '(sd=${v['baseline_sd']})');
        }
        summary.write(' | $note');
        TelemetryService.instance.recordNonFatal(
          StateError(summary.toString()),
          StackTrace.current,
          reason: 'readiness_absent',
        );
      }
    }

    // Where this day's sleep window came from (auto / auto_fallback / manual /
    // confirmed) — drives the Sleep screen's "is this right?" prompt + the
    // manual-edit affordance. Carried verbatim from the segmentation candidate.
    bundle['sleep_source'] = day.sleepSource;

    final scMap = (bundle['scalars'] as Map?)?.cast<String, dynamic>();

    // ── NEVER WRITE NOTHING OVER SOMETHING ───────────────────────────────────
    // Raw retention is 3 days, but derived history is forever — so a day older
    // than retention has a good `day_result` and NO raw. Re-deriving it (which
    // "Advanced data → Select all → Re-analyze" does for EVERY listed day, via
    // runDays(force: true) → _prepareTargetDay, whose empty substrate yields an
    // all-absent bundle) used to overwrite that good row: `putDayResult` is
    // ConflictAlgorithm.replace on BOTH `day_result` and `metric_series`, so
    // every scalar for the date was NULLed — and, because an empty bundle's
    // endSec was 0, the blank was written FINALIZED and could never re-derive.
    // Only `run()` had a pruned-raw guard, and only for user-override days.
    //
    // Detect it BEFORE the offloaded second half so its own writes
    // (wake_day_features) can't clobber the early-read path either. With no day
    // substrate and no sleep substrate the second half has nothing to add — its
    // scalars are all derived from those two.
    final producedNothing = daySub.isEmpty &&
        sleepSub.isEmpty &&
        (scMap == null || !scMap.values.any((v) => v != null));
    if (producedNothing) {
      final existing = await LocalDb.dayResult(day.date);
      if (_isRealDayResult(existing)) {
        _log('derive ${day.date}: no substrate (raw pruned) — kept the '
            'existing result rather than blanking it');
        return;
      }
    }

    // ── SECOND HALF — OFFLOADED to a background isolate ──────────────────────
    // Everything that turns the isolate-1 bundle into the full day result (wake
    // features, hybrid steps + TDEE, all-day HRV/RSA/skin-temp Timeline lines,
    // naps, workout detection + HRR, wrist orientation, restlessness map, fit
    // quality) used to run on the CALLING isolate — the UI isolate for the
    // foreground light pass that fires on every sync — hanging the main thread
    // for seconds (the rolling-RSA Lomb-Scargle over the 24 h day + nap
    // re-staging + workout detection are the trig/CPU hogs). It is all PURE
    // compute over the two substrates + a few scalars, so it now runs in
    // Isolate.run. DB reads that it needs are done HERE (this is the DB-owning
    // isolate); the DB writes + notification it produces are returned as
    // descriptors and applied below. Same _perDayTimeout guard as isolate 1.
    // NON-FATAL: a failure OR timeout anywhere in the offloaded second half must
    // never skip the whole day. Isolate 1 already computed the headline scalars
    // (readiness / RHR / RMSSD) into bundle['scalars']; we persist those and just
    // drop the optional detail blocks. (Previously an exception here threw out of
    // _derivePreparedDay → the day was marked skipped → readiness rendered "-"
    // even though it had been computed fine — the "readiness randomly goes -" bug.)
    // `secondHalfOk` tracks whether this actually completed: a headline-only
    // row must be marked `partial` below so it never locks as finalized and
    // never counts as "derived" for the raw-pruning guard (see
    // LocalDb.dayResultIds) — otherwise a transient failure here permanently
    // loses the ability to ever back-fill naps/workouts/HRR/wear/curves for
    // this day once its raw substrate is pruned.
    var secondHalfOk = true;
    try {
      final dayLo = daySub.length == 0 ? 0 : daySub.tsSec.first;
      final dayHi = daySub.length == 0 ? 0 : daySub.tsSec.last + 60;
      final liveStepsReal = await LocalDb.liveStepsForDay(day.date);
      final savedSessions = await LocalDb.sessionsInRange(dayLo, dayHi);

      // Off-wrist / charging spans over the NAP window (which runs past this
      // day's end), read here because the isolate has no DB handle. These are
      // the strap's own reports: a band on a table or a charger is perfectly
      // still and otherwise reads as deep rest to a motion-based detector.
      final napLo =
          day.napSub.length == 0 ? dayLo : day.napSub.tsSec.first;
      final napHi =
          day.napSub.length == 0 ? dayHi : day.napSub.tsSec.last + 60;
      final wristOffSpans = await LocalDb.wristOffSpans(napLo, napHi);
      final chargingSpans = await LocalDb.chargingSpans(napLo, napHi);

      // PERSONAL movement floor — ESTIMATED ONCE, THEN FROZEN.
      //
      // Freezing is the whole point and it is not an optimisation. This
      // threshold is derived from the same signal it thresholds, so a floor
      // that keeps tracking the user cancels the trend it exists to report.
      // Measured by scaling a real day's dynAmp and recomputing both ways:
      //
      //     activity x     FROZEN     recomputed
      //          1.00          23             37
      //          1.50          66             37
      //          2.00         128             37
      //          3.00         254             37
      //
      // A recomputed floor reports the SAME number whether the user tripled
      // their activity or did nothing at all. So: accumulate `dyn_p90` for an
      // enrollment window, commit the median, and keep using it. It re-freezes
      // only on events that genuinely change the signal's scale (see
      // `ana.shouldRefreezeFloor`) — never merely because time passed.
      //
      // Self-exclusion (days STRICTLY BEFORE this one) is retained for the
      // enrollment estimate: a day must not help set the threshold it is then
      // scored against. Below the minimum history the floor is null and the
      // estimator abstains rather than substituting a constant.
      final dynFloorG = await _frozenMovementFloor(history, day.date);
      final dynHistory = history.valuesBefore('dyn_p90', day.date);

      // Built on THIS isolate so the Isolate.run closure captures only this plain
      // sendable object (never `this`, `day`, or `bundle`).
      // Read HERE, on the main isolate — the worker has no database.
      final napEdits = [
        for (final row in await LocalDb.napEdits(day.date))
          NapEdit(
            kind: row['source'] == 'rejected'
                ? NapEditKind.rejected
                : NapEditKind.added,
            startSec: (row['start_ts'] as num).toInt(),
            endSec: (row['end_ts'] as num).toInt(),
          ),
      ];

      final blocksInput = _DayBlocksInput(
        daySub: daySub,
        napSub: day.napSub,
        napEdits: napEdits,
        sleepSub: sleepSub,
        profile: profile,
        onsetSec: day.sleepOnsetSec,
        offsetSec: day.sleepOffsetSec,
        rhr: (scMap?['rhr'] as num?)?.toDouble(),
        maxHrUsed: (bundle['max_hr_used'] as num?)?.round(),
        liveStepsReal: liveStepsReal,
        dynFloorG: dynFloorG,
        dynHistoryDays: dynHistory.length,
        savedSessions: savedSessions,
        wristOffSpans: wristOffSpans,
        chargingSpans: chargingSpans,
        mainTstMin: (scMap?['tst_min'] as num?)?.round(),
        // The scalar is a PERCENT (onehz_pipeline.dart:914); the period
        // contract and the card both want 0..1, the same normalization
        // `_daySleep` does on read.
        mainEfficiency: (scMap?['efficiency'] as num?) == null
            ? null
            : (scMap!['efficiency'] as num).toDouble() / 100.0,
        date: day.date,
        // Local midnight from the day LABEL, not from the substrate — this has
        // to be where `napSub`'s slice window opens (`_localDayLabelToSec`),
        // not where its first surviving sample happens to land, or the
        // contiguity test compares a timestamp against itself and is
        // vacuously true on every day with a gap at the boundary.
        dayStartSec: _localDayLabelToSec(day.date),
        dayEndSec: day.endSec,
        dataNowSec: dataNowSec,
      );
      final blocks =
          await _runDayBlocksCancellable(blocksInput, _perDayTimeout);

      // Merge the computed blocks back into the isolate-1 bundle. scMap is the
      // CastMap view over bundle['scalars'], so addAll writes through — nap_min /
      // hrr_bpm reach the persisted series map below.
      bundle.addAll(blocks.bundlePatch);
      (bundle['series'] as Map?)?.cast<String, dynamic>().addAll(
            blocks.seriesPatch,
          );
      scMap?.addAll(blocks.scalarPatch);

      // DB writes + notification the pure compute deferred to us (DB-owning isolate).
      for (final w in blocks.sessionHrrWrites) {
        await LocalDb.setSessionHrr(w.$1, w.$2);
      }
      for (final sug in blocks.suggestionsToPersist) {
        await LocalDb.putWorkoutSuggestion({
          ...sug,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
      final nb = blocks.notifBout;
      if (nb != null) {
        await NotificationCenter.instance.emit(
          NotificationEvent(
            // Per-bout, not per-day — a per-day key silently swallowed the
            // notification for a second real workout later the same day
            // (fire-once-per-key by design). endSec is stable across re-derive
            // passes re-detecting the SAME bout, so that case still dedupes.
            dedupeKey: '${day.date}:auto_workout:${nb.endSec}',
            category: NotifCategory.recovery,
            priority: NotifPriority.normal,
            title: 'Did you work out?',
            body: 'We spotted ~${nb.durationMin} min of elevated activity. '
                'Tap to log it.',
            date: day.date,
            route: kRouteWorkoutSuggestion,
          ),
          // This runs from headless background derivation too — never prompt
          // for permission from a background context (violates the OS
          // background contract and can incorrectly cache permission=denied).
          allowPermissionPrompt: false,
        );
      }

      await _persistWakeDayFeatures(dayId: day.date, wake: blocks.wake);
    } catch (e, st) {
      secondHalfOk = false;
      _log('day-blocks (offloaded second half) failed for ${day.date} — '
          'persisting headline day (partial): $e');
      TelemetryService.instance.recordNonFatal(e, st, reason: 'day_blocks_failed');
    }

    // Finalize once the DATA EDGE has moved >48 h past the day's wake — i.e. we
    // have continuous drained data well beyond it, so no more flash can land for
    // this day. (Anchored on the last record ts, NOT the wall clock.) Imports
    // force-finalize: there is no stored raw to ever recompute them from, so
    // forceFinalize wins even for a partial (headline-only) result — there's
    // nothing left to retry regardless. Outside of that, never let a partial
    // result lock in as finalized purely by age, or its missing naps/
    // workouts/HRR/wear/curves would never get a chance to be filled in by a
    // later retry.
    final ageFinalized = (day.endSec + _finalizationSec) < dataNowSec;
    // A result with NOTHING in it is never finalized — not even by
    // forceFinalize. Locking an all-absent row is what made the destructive
    // re-analyze permanent; leaving it unlocked means a later pass (or a
    // restored/backfilled substrate) can still fill the day in.
    final finalized =
        !producedNothing && (forceFinalize || (ageFinalized && secondHalfOk));

    // A failed/timed-out second half yields a headline-only bundle, and
    // putDayResult replaces the row wholesale — so re-deriving an already
    // complete day (rescanRecent deliberately revisits finalized days) destroyed
    // its naps, sleep periods, workouts, HRR, wear and curves. Carry the
    // previous result's detail forward instead of blanking it. Same principle as
    // the producedNothing guard above and the skip-marker guard in
    // _markDaySkipped: never let a thinner result overwrite a richer one.
    var effectiveFinalized = finalized;
    var effectivePartial = !secondHalfOk;
    if (!secondHalfOk) {
      final existing = await LocalDb.dayResult(day.date);
      if (_isRealDayResult(existing)) {
        final prev = _decodeBundle(existing!['payload_json']);
        if (prev != null) {
          final recovered = carryForwardDetail(prev, bundle);
          final prevVersion = (existing['algo_version'] as num?)?.toInt();
          final outcome = recoveryOutcome(
            recovered: recovered,
            prevPartial: (existing['partial'] as num?)?.toInt() == 1,
            prevVersion: prevVersion,
            prevFinalized: (existing['finalized'] as num?)?.toInt() == 1,
            finalizedByAge: finalized,
          );
          effectivePartial = outcome.partial;
          effectiveFinalized = outcome.finalized;
          _log('derive ${day.date}: second half failed — carried the previous '
              "result's detail blocks forward (v$prevVersion -> v$kAlgoVersion, "
              'partial=$effectivePartial)');
        }
      }
    }

    final scalars =
        (bundle['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    double? sc(String k) => (scalars[k] as num?)?.toDouble();
    await LocalDb.putDayResult(
      dayId: day.date,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(bundle),
      windowJson: jsonEncode(
        ((day.sleepJson['window'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      finalized: effectiveFinalized,
      partial: effectivePartial,
      rhr: sc('rhr'),
      rmssd: sc('rmssd'),
      readiness: sc('readiness'),
      series: {
        'rhr': sc('rhr'),
        'rmssd': sc('rmssd'),
        'sdnn': sc('sdnn'),
        'readiness': sc('readiness'),
        'ln_rmssd': sc('ln_rmssd'),
        'resp_rate': sc('resp_rate'),
        'skin_temp_z': sc('skin_temp_z'),
        // RAW nightly ADC mean — the baseline series for skin_temp_z. Written
        // EVERY day (even during the bootstrap window where skin_temp_z is null)
        // so the baseline fills and z begins computing from ~day 4.
        'skin_temp_adc': sc('skin_temp_adc'),
        'dip_pct': sc('dip_pct'),
        // Headline 0–21 strain (for trend/sparkline); raw TRIMP kept too.
        'strain': sc('strain'),
        'trimp': sc('trimp'),
        // Secondary 0–100 Edwards "effort" strain → its own trend series.
        'strain_effort': sc('strain_effort'),
        'odi_per_hour': sc('odi_per_hour'),
        'cpc_ratio': sc('cpc_ratio'),
        // New metrics → trends (day/week/month/3M).
        'stress': sc('stress'),
        'spo2': sc('spo2'),
        'calories': sc('calories'),
        // Steps = REAL pedometer counts only (band 100 Hz / phone / NOOP
        // import, all via `live_coverage`). Absent — written as a NULL row, so
        // a previously fabricated value is overwritten rather than left
        // standing — on any day nothing gait-capable measured.
        'steps': sc('steps'),
        // Movement minutes: activity VOLUME, not locomotion. Steps are NOT
        // derived from this and never will be again (see the v55/v56 note).
        'active_min': sc('active_min'),
        // This day's high quantile of the calibration-invariant dynamic accel
        // amplitude. Not a user-facing metric: it is the per-day summary the
        // NEXT day's derive pools to anchor its personal ambulatory floor, so
        // the threshold never depends on a single day (see _BaselineHistoryCache).
        'dyn_p90': sc('dyn_p90'),
        'calories_total': sc('calories_total'),
        // Daytime nap minutes (principled van Hees + HR-dip) → trend + Sleep Coach.
        'nap_min': sc('nap_min'),
        // Sleep-stage minutes + HRV freq/stability trends.
        'rem_min': sc('rem_min'),
        'deep_min': sc('deep_min'),
        'light_min': sc('light_min'),
        'tst_min': sc('tst_min'),
        'lf_hf': sc('lf_hf'),
        'hrv_cv': sc('hrv_cv'),
        'efficiency': sc('efficiency'),
        'worn_min': sc('worn_min'),
        // v25: 24/7 irregular-rhythm screen flag, breathing-rate variability,
        // and mean heart-rate recovery across the day's detected bouts.
        'irregular_rhythm_flag': sc('irregular_rhythm_flag'),
        'brv_cv': sc('brv_cv'),
        'hrr_bpm': sc('hrr_bpm'),
      },
    );
    // NOTE: the sweep's `history` snapshot is deliberately NOT updated here.
    // See _BaselineHistoryCache — mutating the shared snapshot mid-sweep is the
    // duplicate-day pollution bug, and each day already derives its own
    // date-bounded window from the frozen snapshot.
    _log(
      'derived ${day.date} v$kAlgoVersion '
      '(sleep=${day.sleepOffsetSec > day.sleepOnsetSec}, final=$finalized)',
    );
    await _maybeFreezeHeadlineReadiness(day, dataNowSec, sc('readiness'));
  }

  /// Pin today's morning readiness headline once its overnight is genuinely
  /// COMPLETE, so the Today hero + recovery story stop drifting through the day
  /// (#128). Only the headline is pinned — this row's `day_result`, the
  /// baselines, trends and finalisation all keep updating on later re-derives.
  Future<void> _maybeFreezeHeadlineReadiness(
    PreparedDerivationDay day,
    int dataNowSec,
    double? readiness,
  ) async {
    // Only today's headline is pinned. Historical/backfill + imported days never
    // reach the Today hero, and imports are immutable snapshots anyway.
    if (day.date != todayLabel()) return;
    final hasSleep = day.sleepOffsetSec > day.sleepOnsetSec;
    if (!hasSleep) return;
    final overnightComplete =
        dataNowSec >= day.sleepOffsetSec + _headlineFreezeMarginSec;
    final current = await LocalDb.frozenHeadline();
    final next = nextFrozenHeadline(
      today: day.date,
      overnightComplete: overnightComplete,
      liveReadiness: readiness?.round(),
      current: current,
    );
    if (next == null) return;
    // Already pinned to this exact value → skip the redundant write.
    if (current != null &&
        current.day == next.day &&
        current.value == next.value) {
      return;
    }
    await LocalDb.setFrozenHeadline(next.day, next.value);
    _log('froze headline readiness ${next.value} for ${next.day}');
  }

  void _logSpo2Diagnostics(
    PreparedDerivationDay day,
    DayBundleInput input,
    Map<String, dynamic> bundle,
  ) {
    final red = input.sleepSpo2Red;
    final ir = input.sleepSpo2Ir;
    final ts = input.sleepTsSec;
    if (red.isEmpty || ir.isEmpty || ts.isEmpty) {
      _log('[spo2-detect] {"day":"${day.date}","status":"no_sleep_spo2"}');
      return;
    }

    int minInt(List<int> xs) => xs.reduce((a, b) => a < b ? a : b);
    int maxInt(List<int> xs) => xs.reduce((a, b) => a > b ? a : b);
    double meanInt(List<int> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

    final redNonZero = red.where((v) => v > 0).length;
    final irNonZero = ir.where((v) => v > 0).length;
    final spo2 = (bundle['spo2'] as Map?)?.cast<String, dynamic>();
    final ratios = <double>[
      for (var i = 0; i < red.length && i < ir.length; i++)
        if (red[i] > 0 && ir[i] > 0) red[i] / ir[i],
    ];
    double? meanDouble(List<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
    double? minDouble(List<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a < b ? a : b);
    double? maxDouble(List<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a > b ? a : b);

    final payload = <String, dynamic>{
      'day': day.date,
      'sleep_samples': ts.length,
      'sleep_span_sec': ts.last - ts.first,
      'feature_disabled': spo2?['disabled'] == true,
      'red': <String, dynamic>{
        'non_zero': redNonZero,
        'zero': red.length - redNonZero,
        'coverage': redNonZero / red.length,
        'unique': red.toSet().length,
        'min': minInt(red),
        'max': maxInt(red),
        'mean': meanInt(red).toStringAsFixed(2),
        'first10': red.take(10).toList(),
      },
      'ir': <String, dynamic>{
        'non_zero': irNonZero,
        'zero': ir.length - irNonZero,
        'coverage': irNonZero / ir.length,
        'unique': ir.toSet().length,
        'min': minInt(ir),
        'max': maxInt(ir),
        'mean': meanInt(ir).toStringAsFixed(2),
        'first10': ir.take(10).toList(),
      },
      'ratio': <String, dynamic>{
        'samples': ratios.length,
        'min': minDouble(ratios)?.toStringAsFixed(6),
        'max': maxDouble(ratios)?.toStringAsFixed(6),
        'mean': meanDouble(ratios)?.toStringAsFixed(6),
        'first10': ratios.take(10).map((v) => v.toStringAsFixed(6)).toList(),
      },
      'odi': <String, dynamic>{
        'disabled': spo2?['disabled'],
        'note': spo2?['note'],
        'value': spo2?['odi_per_hour'],
        'dip_count': spo2?['dip_count'],
        'signal_coverage': spo2?['signal_coverage'],
        'trusted_coverage': spo2?['trusted_coverage'],
        'confidence': spo2?['confidence'],
        'reject_counts': spo2?['reject_counts'],
        'severity_counts': spo2?['severity_counts'],
        'debug': spo2?['debug'],
      },
    };
    _log('[spo2-detect] ${jsonEncode(payload)}');
  }

  /// Skip reasons that describe a TRANSIENT failure of this particular pass
  /// rather than a permanently pathological day. These must never finalize:
  /// finalizing locks the day out of every future pass at this algo version.
  static const Set<String> _transientSkipReasons = {'timeout', 'error'};

  /// Whether [row] is a REAL derived day result worth protecting — i.e. not a
  /// skip marker and not an all-absent shell.
  static bool _isRealDayResult(Map<String, dynamic>? row) {
    if (row == null) return false;
    if ((row['skipped'] as num?)?.toInt() == 1) return false;
    final payload = _decodeBundle(row['payload_json']);
    if (payload == null) return false;
    if (payload['skipped'] == true) return false;
    final scalars = payload['scalars'];
    if (scalars is Map && scalars.values.any((v) => v != null)) return true;
    return row['rhr'] != null || row['rmssd'] != null || row['readiness'] != null;
  }

  /// Fill [next]'s missing detail from [prev] when the second-half compute
  /// failed, so a headline-only pass never blanks a day that already had naps,
  /// workouts, HRR, wear and curves. Returns true if anything was carried over.
  ///
  /// Keyed on ABSENCE, not on null: isolate 1 writes its headline scalars
  /// explicitly and a null there is a real "we could not measure this today"
  /// that must survive. Only keys the failed second half never got to add are
  /// restored — a freshly computed value always wins.
  @visibleForTesting
  static bool carryForwardDetail(
    Map<String, dynamic> prev,
    Map<String, dynamic> next,
  ) {
    var carried = false;
    for (final e in prev.entries) {
      if (e.key == 'scalars' || e.key == 'series') continue;
      if (next.containsKey(e.key) || e.value == null) continue;
      next[e.key] = e.value;
      carried = true;
    }
    // `scalars` and `series` are flat maps the second half patches INTO rather
    // than owning, so they merge per key instead of wholesale.
    for (final sub in const ['scalars', 'series']) {
      final p = prev[sub];
      if (p is! Map) continue;
      final n = next[sub];
      if (n is! Map) {
        next[sub] = Map<String, dynamic>.from(p.cast<String, dynamic>());
        carried = true;
        continue;
      }
      for (final e in p.entries) {
        if (n.containsKey(e.key) || e.value == null) continue;
        n[e.key] = e.value;
        carried = true;
      }
    }
    return carried;
  }

  /// How a day should be filed after its second half failed and the previous
  /// result's detail was carried forward.
  ///
  /// The version check is the subtle part. `LocalDb.dayResult` returns the
  /// HIGHEST algo_version stored for the day, so immediately after a bump the
  /// row it hands back belongs to the previous version. Carrying that detail
  /// forward still beats blanking the day — but it must not be filed as a
  /// finished CURRENT-version result, because the reason a bump exists is that
  /// those blocks are computed differently now. A cross-version carry therefore
  /// stays partial and unfinalized, so a later pass recomputes it for real
  /// instead of locking last version's curves in under this version's number.
  @visibleForTesting
  static ({bool partial, bool finalized}) recoveryOutcome({
    required bool recovered,
    required bool prevPartial,
    required int? prevVersion,
    required bool prevFinalized,
    required bool finalizedByAge,
  }) {
    final sameVersion = prevVersion == kAlgoVersion;
    if (!recovered || prevPartial || !sameVersion) {
      // Stays partial, but keep whatever the caller had already decided about
      // finalizing: an IMPORT force-finalizes even a partial day, because there
      // is no stored raw to ever recompute it from.
      return (partial: true, finalized: finalizedByAge);
    }
    // As complete as it was before this pass, so it keeps what it had earned.
    return (partial: false, finalized: finalizedByAge || prevFinalized);
  }

  /// Test seam for [_markDaySkipped] — the "a skip marker must never destroy a
  /// real result" guarantee is the whole point of the method, so it is pinned
  /// directly rather than through a full derive pass.
  @visibleForTesting
  Future<void> debugMarkDaySkipped(
    String dayId,
    int dayEndSec,
    int dataNowSec, {
    required String reason,
  }) =>
      _markDaySkipped(dayId, dayEndSec, dataNowSec, reason: reason);

  /// Persist a minimal skip marker so a pathological day isn't retried forever.
  ///
  /// A SKIP MARKER MUST NEVER OVERWRITE A REAL RESULT. `putDayResult` is
  /// ConflictAlgorithm.replace on both `day_result` AND `metric_series`, so this
  /// used to blank a good day's every scalar on a single [_perDayTimeout]
  /// overrun — and, once the day sat >48 h behind the data edge, wrote the blank
  /// FINALIZED, making it permanent (raw is pruned 3 days later, so there is
  /// nothing left to re-derive from). It hit TODAY too: a good 08:00 result
  /// replaced by a skip marker after one transient 09:00 timeout on a loaded
  /// phone. `rescanRecent` explicitly refuses to do this for exactly this
  /// reason; `run()` did it anyway. Now: write the marker only when there is no
  /// good row to lose, and never lock a transient failure.
  Future<void> _markDaySkipped(
    String dayId,
    int dayEndSec,
    int dataNowSec, {
    required String reason,
  }) async {
    try {
      final existing = await LocalDb.dayResult(dayId);
      if (_isRealDayResult(existing)) {
        _log('derive $dayId $reason — existing result kept (not overwritten '
            'with a skip marker)');
        return;
      }
      await LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': reason}),
        windowJson: '{}',
        // Structural failures (a day that can never be prepared / blows the
        // prepare budget) still finalize once aged out, so they aren't retried
        // forever. A timeout or a one-off error does not — that day gets
        // another chance while it still has raw.
        finalized: !_transientSkipReasons.contains(reason) &&
            (dayEndSec + _finalizationSec) < dataNowSec,
        skipped: true,
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Attach trailing personal history (from metric_series) for the readiness
  /// pass — the trailing window of days STRICTLY BEFORE the day being derived.
  ///
  /// The self-exclusion (`date < input.date`) is load-bearing, not cosmetic: see
  /// [_BaselineHistoryCache.valuesBefore]. Every one of these series is a
  /// BASELINE the day's own value is scored against, so the day's own row (which
  /// a previous derive of the same day already persisted) must not be in it.
  Map<String, dynamic> _attachHistory(
    DayBundleInput input,
    _BaselineHistoryCache history,
  ) {
    final m = input.toJson();
    final date = input.date;
    m['ln_rmssd_history'] = history.valuesBefore('ln_rmssd', date);
    m['rhr_history'] = history.valuesBefore('rhr', date);
    m['resp_history'] = history.valuesBefore('resp_rate', date);
    // Robust nocturnal RMSSD history (the `rmssd` series) — feeds the EWMA hrv
    // baseline so its center matches today's headline RMSSD (same metric).
    m['rmssd_history'] = history.valuesBefore('rmssd', date);
    // BASELINE for skin_temp_z is the RAW nightly ADC-mean series (`skin_temp_adc`),
    // NOT the z-score series. Feeding z-scores back as the baseline was a unit
    // mismatch that left z permanently null. The raw mean is stored every day so
    // this series fills and z starts computing once ≥3 days exist.
    m['skin_temp_adc_history'] = history.valuesBefore('skin_temp_adc', date);
    return m;
  }

  // ── cross-day rollup ─────────────────────────────────────────────────────────

  static const Duration _crossDayTimeout = Duration(seconds: 30);
  static const int _crossDayWindow = 90;

  /// Whether a persisted `crossday_input` artifact may be reused AS-IS today.
  ///
  /// Pure, so it is unit-testable without a database — the seam that consumes it
  /// ([_crossDayInputDays]) cannot be.
  ///
  /// The artifact stamps `is_today: true` on the row that was today WHEN IT WAS
  /// BUILT. That is a fact about a day stored as a bare boolean, in a DURABLE
  /// row, so a cached artifact served on a later day hands `_todayNum` a record
  /// that still claims to be today — and yesterday's strain and nap minutes land
  /// inside tonight's `need_sec`. That is the exact imputation the stamp exists
  /// to prevent (§3.3), arriving through the cache instead of through `_lastNum`.
  ///
  /// Every current `_runCrossDay` call site refreshes the artifact immediately
  /// beforehand, so the stale read is not reachable today. That is an unenforced
  /// ordering coincidence and not something to rely on: one new caller, or one
  /// early return inside `_refreshBaselines`, makes it live and silent.
  ///
  /// An artifact with no `built_for_day` (written before this field existed)
  /// cannot be SHOWN to be fresh, so it is rebuilt rather than assumed fresh.
  static bool crossDayArtifactUsableToday(Object? decoded, String today) {
    if (decoded is! Map) return false;
    if (decoded['days'] is! List) return false;
    final builtFor = decoded['built_for_day'];
    return builtFor is String && builtFor.isNotEmpty && builtFor == today;
  }

  Future<void> _runCrossDay(Profile profile) async {
    try {
      final days = await _crossDayInputDays();
      if (days.length < 3) {
        _log('crossday: only ${days.length} usable day(s) — skip');
        return;
      }
      final profileMap = profile.toMap();
      // Encode INSIDE the isolate too — a real ~3.5-4.7s main-isolate hang was
      // caught in production (Crashlytics jank_watchdog, correlated with a
      // heavy derive pass) coming from jsonEncode-ing this bundle back on the
      // main isolate after Isolate.run returned it. Returning the already-
      // encoded string avoids both the main-isolate encode cost AND transfers
      // a flat string across the isolate boundary instead of a large nested Map.
      final bundleJson = await _runIsolateCancellable(
        () => jsonEncode(buildCrossDayBundle(days, profileMap)),
        _crossDayTimeout,
        label: 'crossday',
      );
      await LocalDb.putBaseline('crossday', bundleJson);
      _log('crossday: stored over ${days.length} day(s)');
    } catch (e) {
      _log('crossday FAILED/skipped: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _crossDayInputDays() async {
    final artifact = await LocalDb.baseline('crossday_input');
    final raw = artifact?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        // Day-gated, NOT just well-formed. The rows carry `is_today`, which is a
        // fact about the day the artifact was BUILT on; serving them on a later
        // day makes `_todayNum` read yesterday's strain and nap minutes as
        // today's (§3.3). See [crossDayArtifactUsableToday].
        if (crossDayArtifactUsableToday(decoded, LocalDb.localDayLabelNow())) {
          final rows = (decoded as Map)['days'] as List;
          return [
            for (final row in rows)
              if (row is Map) row.cast<String, dynamic>(),
          ];
        }
      } catch (_) {
        // Fall through to rebuild from day_result.
      }
    }
    return _refreshCrossDayInputArtifact();
  }

  Future<List<Map<String, dynamic>>> _refreshCrossDayInputArtifact() async {
    // The DB read itself must stay on the main isolate (sqflite), but
    // decoding up to _crossDayWindow (90) full day payloads + re-encoding
    // them was previously ALL synchronous main-isolate work with zero
    // offloading — this is the confirmed source of the ~3.5-4.7s production
    // hang (Crashlytics jank_watchdog), since _refreshBaselines calls this
    // unconditionally on every heavy pass. _decodeBundle/_crossDayRecord are
    // both static, so this whole transform+encode step is isolate-safe.
    final rows = await LocalDb.recentDayResults(_crossDayWindow);
    final today = LocalDb.localDayLabelNow();
    final (days, json) = await _runIsolateCancellable(() {
      final days = <Map<String, dynamic>>[];
      for (final row in rows.reversed) {
        final payload = _decodeBundle(row['payload_json']);
        if (payload == null) continue;
        if (payload['skipped'] == true) continue;
        final rec = _crossDayRecord(row, payload);
        if (rec == null) continue;
        // Today's own row updates on every derive pass while the night is
        // still syncing/settling — feeding that partial reading into the
        // illness/anomaly CUSUM can fire a false "possible illness onset" on
        // data that's really just a truncated/mid-drain night. Only exclude
        // TODAY specifically; older days already had their 48h to settle.
        //
        // FLAG it rather than DROP it: `days` is the single input list for the
        // whole cross-day bundle, so dropping today also silently removed it
        // from readiness/glass-box, the resting-HR trend-shift CUSUM, load,
        // sleep debt and `recent` (whose last row dates every notification).
        // buildCrossDayBundle nulls only the alert inputs for a flagged day.
        if (row['day_id'] == today && (row['finalized'] as num?) != 1) {
          rec['unsettled'] = true;
        }
        // Explicit identity for TODAY-scoped reads. `unsettled` cannot serve
        // this purpose — it is only set while today is unfinalized. Without a
        // flag, a today-scoped consumer can only take the LAST record
        // positionally, which on a day with no derived row is YESTERDAY's.
        if (row['day_id'] == today) rec['is_today'] = true;
        days.add(rec);
      }
      // `built_for_day` is what makes the `is_today` stamps inside `days`
      // interpretable later. Without it the envelope carries day-relative facts
      // with no day attached, and any reader has to assume freshness.
      return (
        days,
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': today,
          'days': days,
        })
      );
    }, _crossDayTimeout, label: 'crossday-input');
    await LocalDb.putBaseline('crossday_input', json);
    return days;
  }

  // ── notifications generator ─────────────────────────────────────────────────

  Future<void> _runNotifications() async {
    try {
      final cdRow = await LocalDb.baseline('crossday');
      final cd = _decodeBundle(cdRow?['payload_json']);
      if (cd == null) return;
      String? date;
      final recent = cd['recent'];
      if (recent is List && recent.isNotEmpty) {
        final last = recent.last;
        if (last is Map) date = last['date'] as String?;
      }
      final illness = cd['illness'] is Map ? cd['illness'] as Map : null;
      final anomaly = cd['anomaly'] is Map ? cd['anomaly'] as Map : null;
      final temp = cd['temp_illness'] is Map ? cd['temp_illness'] as Map : null;
      final gb = cd['readiness_glassbox'] is Map
          ? cd['readiness_glassbox'] as Map
          : null;
      date ??=
          (illness?['date'] ?? anomaly?['date'] ?? temp?['date']) as String?;
      if (date == null) return;
      // Single emitter: writes the in-app feed AND (per user prefs) fires the OS
      // notification. Health signals are critical (may override quiet hours);
      // recovery/insight signals are normal (respect quiet hours).
      Future<void> emit(
        String kind,
        String title,
        String body, {
        NotifCategory category = NotifCategory.health,
        NotifPriority priority = NotifPriority.critical,
        String route = '/today',
      }) => NotificationCenter.instance.emit(
        NotificationEvent(
          dedupeKey: '$date:$kind',
          category: category,
          priority: priority,
          title: title,
          body: body,
          date: date!,
          route: route,
        ),
      );
      if (illness != null && illness['state'] == 'red') {
        await emit(
          'illness',
          'Possible illness onset',
          'Elevated resting HR + suppressed HRV over recent nights.',
          route: '/heart',
        );
      }
      if (anomaly != null && anomaly['flagged'] == true) {
        await emit(
          'anomaly',
          'Unusual overnight physiology',
          'Your nightly signals deviate from your personal baseline.',
          route: '/heart',
        );
      }
      if (temp != null && temp['flag'] == 'elevated') {
        await emit(
          'temp',
          'Skin temperature elevated',
          'Sustained rise vs your baseline — a possible illness signal.',
          route: '/body',
        );
      }
      // 24/7 irregular-rhythm SCREEN (not a diagnosis). Fires at most once/day.
      final irregFlag = await LocalDb.metricValueOn(date, 'irregular_rhythm_flag');
      if (irregFlag == 1.0) {
        await emit('irregular', 'Irregular heart rhythm — screen',
            'Your beat-to-beat pattern looked irregular today. This is a screen, '
            'not a diagnosis — see a clinician if you have symptoms.',
            route: '/heart');
      }
      final score = gb?['value'] is Map ? (gb!['value'] as Map)['score'] : null;
      if (score is num && score < 34) {
        await emit(
          'readiness',
          'Low readiness today',
          'Your recovery markers are below your usual range — ease off.',
          category: NotifCategory.recovery,
          priority: NotifPriority.normal,
          route: '/today',
        );
      }

      // "Something changed" — online CUSUM on the recent resting-HR series. Fire
      // only when the shift lands on the LATEST day (a fresh change, not old
      // history we'd re-announce every pass). Dedupe key includes the date so it
      // surfaces at most once per day.
      final rhrSeries = <double>[];
      if (recent is List) {
        for (final r in recent) {
          if (r is Map && r['rhr'] is num) {
            rhrSeries.add((r['rhr'] as num).toDouble());
          }
        }
      }
      if (rhrSeries.length >= 10) {
        final dets = ana.cusumChangePoints(rhrSeries, h: 5.0);
        if (dets.isNotEmpty && dets.last.index == rhrSeries.length - 1) {
          final dir = dets.last.direction > 0 ? 'risen' : 'fallen';
          await emit(
            'changed',
            'Your resting heart-rate trend shifted',
            'Your resting HR has $dir noticeably versus your recent baseline.',
            category: NotifCategory.recovery,
            priority: NotifPriority.normal,
            route: '/heart',
          );
        }
      }
    } catch (e) {
      _log('notifications FAILED/skipped: $e');
    }
  }

  /// Decode a stored day bundle, normalizing the compact curve format back to
  /// plain [{t,v}] lists.
  ///
  /// The normalization is LOAD-BEARING on the re-derive path, not just hygiene:
  /// `_deriveOneDay` reads the previous row through here and merges its series
  /// into the fresh bundle. Without normalizing, an encoded `prev` would be
  /// merged beside newly-computed legacy lists and the day would carry two
  /// different shapes for the same curve.
  static Map<String, dynamic>? _decodeBundle(Object? json) =>
      SeriesCodec.decodePayloadJson(json);

  /// Build the cross-day record from a day_result row + its payload bundle.
  static Map<String, dynamic>? _crossDayRecord(
    Map<String, dynamic> row,
    Map<String, dynamic> payload,
  ) {
    final date = row['day_id'] as String?;
    if (date == null || date.isEmpty) return null;
    final scalars =
        (payload['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    num? sc(String k) => scalars[k] is num ? scalars[k] as num : null;
    num? col(String k) => row[k] is num ? row[k] as num : null;

    // Safe map cast: a metric envelope's `value` is the string '—' when the
    // metric is ABSENT (e.g. a no-sleep day), so a blind `as Map?` throws. Only
    // treat it as a map when it really is one.
    Map<String, dynamic>? asMap(Object? v) =>
        v is Map ? v.cast<String, dynamic>() : null;

    final sleep = asMap(payload['sleep']);
    final win = asMap(sleep?['window']);
    final winVal = asMap(win?['value']);
    final acct = asMap(sleep?['accounting']);
    final acctVal = asMap(acct?['value']);
    final series = asMap(payload['series']);

    final onsetMs = (winVal?['onset_ms'] as num?)?.toDouble();
    final offsetMs = (winVal?['offset_ms'] as num?)?.toDouble();
    final tstSec = (acctVal?['tst_sec'] as num?)?.toDouble();

    return {
      'date': date,
      'rhr': col('rhr') ?? sc('rhr'),
      'rmssd': col('rmssd') ?? sc('rmssd'),
      'readiness': col('readiness') ?? sc('readiness'),
      'resp_rate': sc('resp_rate'),
      'skin_temp_z': sc('skin_temp_z'),
      'trimp': sc('trimp'),
      // Headline 0–21 strain, daily steps, nap minutes — feed Sleep/Strain Coach
      // + VO₂max/Fitness Age in the cross-day rollup.
      'strain': sc('strain'),
      'steps': sc('steps'),
      'nap_min': sc('nap_min'),
      'efficiency': sc('efficiency'),
      'onset_sec': onsetMs == null ? null : (onsetMs / 1000).round(),
      'wake_sec': offsetMs == null ? null : (offsetMs / 1000).round(),
      'tst_min': tstSec == null ? null : (tstSec / 60).round(),
      'hypnogram': series?['hypnogram'],
    };
  }

  /// Refresh the persisted rolling-baseline artifact + signature caches.
  ///
  /// Rebuilds from the de-duplicated `metric_series` store (see
  /// [_BaselineHistoryCache.load]) rather than persisting the in-memory cache
  /// the sweep mutated via [_BaselineHistoryCache.appendScalars] — that list is
  /// correct for intra-sweep freshness but is append-only with no day identity,
  /// so persisting it let repeated same-day re-derives stack duplicate copies of
  /// today into the window (the blank-readiness root cause). The read path
  /// ([_BaselineHistoryCache.load]) no longer trusts this artifact for history,
  /// but it still backs the cheap `signature` rescan gate, so keep it fresh.
  Future<void> _refreshBaselines() async {
    final history = await _BaselineHistoryCache.load();
    final artifact = history.toArtifactJson();
    final rolling = ((artifact['rolling'] as Map?) ?? const {})
        .cast<String, dynamic>();
    await LocalDb.putBaseline('rolling_artifact', jsonEncode(artifact));
    await LocalDb.putBaseline('rolling', jsonEncode(rolling));
    await _refreshCrossDayInputArtifact();
  }

  // ── raw pruning (raw-first invariant) ──────────────────────────────────────

  /// Prune raw older than [rawRetentionDays] BEHIND THE DATA EDGE. Retention is
  /// measured against the last record timestamp we actually drained
  /// ([dataNowSec]), never the wall clock, and rows are deleted by their record
  /// time (`rec_ts`), never receive time (`captured_at`) — a multi-day flash
  /// backfill received in one sync must not be pruned just because it landed
  /// "now". Guard: never prune while any day in [days] is NOT yet derived at the
  /// current algo version (raw-first).
  Future<void> _pruneOldDecoded(List<String> dayIds, int dataNowSec) async {
    final derivedIds = await LocalDb.dayResultIds(kAlgoVersion);
    final pending = dayIds.where((d) => !derivedIds.contains(d)).toList();
    if (pending.isNotEmpty) {
      _log('prune skipped — ${pending.length} day(s) not yet derived');
      return;
    }
    final cutoffSec = dataNowSec - rawRetentionDays * 86400;
    if (cutoffSec <= 0) return;
    final deleted = await LocalDb.pruneDecodedBeforeRecTs(cutoffSec);
    if (deleted > 0) {
      _log('pruned $deleted decoded rows with rec_ts < $cutoffSec');
    }
    // Superseded generations of the recomputable per-day intermediates. Runs
    // here rather than inside the decoded prune so it stays off the path to a
    // durable commit.
    final stale = await LocalDb.pruneSupersededIntermediates();
    if (stale > 0) {
      _log('pruned $stale superseded intermediate rows');
    }
  }

  /// Storage housekeeping that must run on EVERY derive.
  ///
  /// Deliberately NOT inside [_pruneOldDecoded]: both of that method's call
  /// sites sit behind `if (scope.fullHistory)`, and ordinary light/heavy
  /// derives run with `fullHistory: false`. Putting the back-catalogue rewrite
  /// there made it resumable but effectively unreachable — a normal install
  /// would have converted nothing.
  ///
  /// CALLED FROM THE `finally` OF EVERY ENTRY PATH, and it swallows its own
  /// errors, for two reasons that were both live:
  ///
  ///   • Reach. Called from the body, it sat below `if (dataNowSec <= 0)
  ///     return 0` and below two other early returns — so the install that most
  ///     needs it, one restored from a backup with years of derived history and
  ///     no decoded rows at all (they are capped at `rawRetentionDays`, so a
  ///     backup carries almost none), converted nothing, ever. runDays and
  ///     rescanRecent never reached it at all.
  ///   • Blast radius. Called unguarded from the body, a throw — SQLITE_BUSY
  ///     from the other derivation isolate, a full disk — skipped the raw prune
  ///     that enforces `rawRetentionDays`, skipped the timezone re-baseline, and
  ///     landed in the run-wide catch, so a derive that had actually completed
  ///     every day reported 0 back to `reanalyzeAll`. This work is a storage
  ///     optimization; nothing it does may change what the derive returns.
  ///
  /// Bounded and resumable, so running it on every pass costs one small batch.
  /// Off the path to a durable commit, and never inside a migration: `onUpgrade`
  /// runs under iOS's CPU watchdog (invariant 11).
  Future<void> _runStorageHousekeeping() async {
    try {
      final reencoded = await LocalDb.reencodeLegacyDayResults();
      if (reencoded > 0) {
        _log('re-encoded $reencoded legacy day bundles');
      }
    } catch (e) {
      _log('storage housekeeping skipped: $e');
    }
  }

  static List<double> _perMinuteMeanWake(
    Substrate s,
    int sleepOnsetSec,
    int sleepOffsetSec,
  ) {
    final buckets = <int, List<double>>{};
    for (var i = 0; i < s.hr.length && i < s.tsSec.length; i++) {
      if (s.hr[i] <= 0) continue;
      final t = s.tsSec[i];
      if (sleepOffsetSec > sleepOnsetSec &&
          t >= sleepOnsetSec &&
          t < sleepOffsetSec) {
        continue;
      }
      (buckets[t ~/ 60] ??= []).add(s.hr[i].toDouble());
    }
    final keys = buckets.keys.toList()..sort();
    return [for (final k in keys) _meanWake(buckets[k]!)!];
  }

  static Map<String, int> _wakeZoneMinutes(
    Substrate s,
    int sleepOnsetSec,
    int sleepOffsetSec,
    double hrMax,
  ) {
    final samples = <ana.HrSample>[];
    final n = math.min(s.tsSec.length, s.hr.length);
    for (var i = 0; i < n; i++) {
      final ts = s.tsSec[i];
      if (sleepOnsetSec > 0 &&
          sleepOffsetSec > sleepOnsetSec &&
          ts >= sleepOnsetSec &&
          ts < sleepOffsetSec) {
        continue;
      }
      samples.add(ana.HrSample(ts * 1000.0, s.hr[i].toDouble()));
    }
    final zoneSet = ana.HeartRateZones.zonesFromMaxHr(hrMax);
    return ana.HeartRateZones.timeInZone(samples, zoneSet).toRoundedMinuteMap();
  }

  static double _keytelCaloriesWake(
    List<double> perMin,
    double age,
    double weight,
    double hrMax,
    bool female,
  ) {
    var kcal = 0.0;
    for (final hr in perMin) {
      if (hr < 0.50 * hrMax) continue;
      final kjMin = female
          ? (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.074 * age) / 4.184
          : (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184;
      if (kjMin > 0) kcal += kjMin;
    }
    return kcal;
  }

  static double? _meanWake(List<double> xs) {
    if (xs.isEmpty) return null;
    var s = 0.0;
    for (final x in xs) {
      s += x;
    }
    return s / xs.length;
  }

  static void _applyWakeDayFeatures(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Map<String, dynamic> wake,
  ) {
    final activeMin = (wake['active_min'] as num?)?.toDouble();
    if (activeMin != null) scMap?['active_min'] = activeMin;
    final strain = (wake['strain'] as num?)?.toDouble();
    if (strain != null) scMap?['strain'] = strain;
    final calories = (wake['calories'] as num?)?.toDouble();
    if (calories != null) scMap?['calories'] = calories;
    final steps = (wake['steps'] as num?)?.toDouble();
    if (steps != null) scMap?['steps'] = steps;
    final caloriesTotal = (wake['calories_total'] as num?)?.toDouble();
    if (caloriesTotal != null) scMap?['calories_total'] = caloriesTotal;
    bundle['activity'] = wake['activity'];
    bundle['activity_curve'] = wake['activity_curve'];
    bundle['zones'] = wake['zones'];
    bundle['hr_stats'] = wake['hr_stats'];
    bundle['wear'] = wake['wear'];
  }

  /// The personal movement floor, estimated ONCE and then frozen.
  ///
  /// Returns the persisted value if one exists. Otherwise, once enough trailing
  /// `dyn_p90` days have accumulated, commits the median and returns it. Below
  /// that it returns null and the estimator abstains — deliberately, since a
  /// constant fallback is the exact failure this design removes.
  ///
  /// Why frozen: the floor is derived from the same signal it thresholds, so a
  /// continuously-recomputed floor tracks the user and reports a near-constant
  /// number regardless of behaviour (measured: 37 active minutes at 1x, 1.5x,
  /// 2x AND 3x activity, versus 23 -> 254 with a frozen floor).
  ///
  /// ORDER-INDEPENDENCE. The floor is ONE persisted scalar shared by every day,
  /// but `run()` dispatches days NEWEST-FIRST through a concurrent worker pool,
  /// so this read-modify-write is reached by several days at once. Three things
  /// keep the outcome from depending on which worker finishes last:
  ///
  ///   1. `_floorLock` serializes the whole read/decide/write, so two days can
  ///      never both observe "nothing stored" and both commit.
  ///   2. `daysSinceFrozen` is clamped at 0 (see [mfp.daysSinceFrozen]), so a
  ///      backfill day never reads as a stale floor and never triggers a
  ///      re-freeze just for being old.
  ///   3. `mayCommitFloorOn` stops an older day overwriting a newer freeze.
  ///
  /// Without these, a `kAlgoVersion` bump — which this very change forces —
  /// would re-derive the whole retained window and let sweep order decide every
  /// day's `active_min`. That is precisely what `_BaselineHistoryCache`'s own
  /// contract forbids for baselines.
  static Future<double?> _frozenMovementFloor(
    _BaselineHistoryCache history,
    String dayId,
  ) =>
      _floorLock.run(() => _resolveMovementFloor(history, dayId));

  /// Serializes the shared-floor read-modify-write across concurrent day
  /// workers. See [_frozenMovementFloor].
  static final _AsyncLock _floorLock = _AsyncLock();

  static Future<double?> _resolveMovementFloor(
    _BaselineHistoryCache history,
    String dayId,
  ) async {
    final stored = await LocalDb.getMovementFloor();
    final hist = history.valuesBefore('dyn_p90', dayId);

    if (stored != null) {
      // Re-freeze only on a real change of scale, never on elapsed time alone.
      //
      // NOTE on the unwired signals: `shouldRefreezeFloor` also accepts
      // `deviceChanged` and `wristChanged`, and edge has no reliable source for
      // either yet (no persisted device identity, no wrist-selection history),
      // so they are deliberately NOT passed rather than passed as a fabricated
      // `false` that reads like a checked condition. `wearGapDays` IS
      // derivable — a run of days with no `dyn_p90` row means the band was not
      // worn — so it is computed and passed.
      final refreeze = ana.shouldRefreezeFloor(
        daysSinceFrozen: mfp.daysSinceFrozen(
          frozenOn: stored.frozenOn,
          dayId: dayId,
        ),
        wearGapDays: mfp.wearGapDays(
          have: history.datesFor('dyn_p90'),
          dayId: dayId,
        ),
      );
      if (!refreeze) return stored.floorG;

      // A re-freeze that CANNOT be satisfied must not destroy what we have.
      // Falling through to enrollment with thin history would return null and
      // make `active_min` vanish for the day — and that is reachable exactly
      // when re-freezing matters most (an old floor on a user whose recent
      // `dyn_p90` history was pruned or is sparse). Keep serving the existing
      // floor until a replacement can actually be computed.
      if (hist.length < ana.enrollmentDaysForFrozenFloor) return stored.floorG;

      // REACHABLE, and this is the case it exists for: an OLD backfill day that
      // trips the re-freeze rule (a 30-day wear gap before it is the common
      // one) and has enough prior history to recompute. Without this it would
      // overwrite the freeze a NEWER day just established, and since the sweep
      // runs newest-first and concurrently, sweep order would decide the floor.
      // A backfill day may CONSUME the shared floor; it may never move it.
      if (!mfp.mayCommitFloorOn(frozenOn: stored.frozenOn, dayId: dayId)) {
        return stored.floorG;
      }
    } else if (hist.length < ana.enrollmentDaysForFrozenFloor) {
      // Still enrolling, and nothing stored to fall back on. Return null so the
      // metric abstains and says so, rather than shipping a threshold we have
      // already proven will be re-derived.
      return null;
    }

    final floor = ana.personalDynFloorFromDailySummaries(hist);
    if (floor == null) return stored?.floorG;
    await LocalDb.putMovementFloor(
      floorG: floor,
      frozenOn: dayId,
      days: hist.length,
    );
    if (kDebugMode) {
      debugPrint('[derive] movement floor FROZEN at '
          '${floor.toStringAsFixed(4)} g from ${hist.length} days ($dayId)');
    }
    return floor;
  }

  /// Write the day's step count. REAL PEDOMETER MEASUREMENTS ONLY.
  ///
  /// The 1 Hz substrate contributes NOTHING here and must never do so again.
  /// The removed estimate multiplied 1 Hz "active minutes" by a walking cadence
  /// band; on a real user day it reported 2,645 steps against a true count
  /// under 400. Both halves of that conversion are invalid at 1 Hz:
  ///   * cadence is not identifiable (gait 1.4-2.3 Hz is sub-Nyquist; 80/100/
  ///     140/160 spm all alias to the same 0.333 Hz), and
  ///   * the minutes counted were never specifically ambulation — at the wrist,
  ///     arm work out-accelerates walking (stirring ~104 mg, chopping ~139 mg
  ///     vs walking ~66 mg ENMO), which is why wrist devices are documented
  ///     emitting 22-27 false steps/min during dishes and driving (O'Connell
  ///     2017) while missing slow walking at sensitivity 0.05.
  /// Two errors of OPPOSITE sign: no gain constant fixes both.
  ///
  /// So `steps` is absent unless something that can actually see gait measured
  /// it: the Tier A 100 Hz pedometer, or the phone's own pedometer (both land
  /// in `live_coverage`). No real source -> no number.
  ///
  /// Called BEFORE the movement-substrate guards, because it depends on none of
  /// them — see the call site.
  static void _writeSteps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    int liveStepsReal,
  ) {
    final haveRealSteps = liveStepsReal > 0;
    if (haveRealSteps) {
      scMap?['steps'] = liveStepsReal.toDouble();
    } else {
      scMap?.remove('steps');
    }
    bundle['steps'] = <String, dynamic>{
      'value': haveRealSteps ? liveStepsReal : null,
      'real_measured': liveStepsReal,
      'source': haveRealSteps ? 'pedometer_100hz_or_phone' : null,
      'confidence': haveRealSteps ? 0.9 : 0.0,
      // NO TIER ON AN ABSENT METRIC. `ESTIMATE` here was actively wrong in two
      // ways: this code path never estimates anything (that is the whole point
      // of the change), and `Metric.parse` turns tier == ESTIMATE into
      // `beta: true`, which paints the estimate/beta badge onto a card that has
      // no number on it at all. `null` parses to `MetricTier.unknown`, which is
      // what "we did not measure this" actually is. `ABSENT` is deliberately
      // NOT invented: `Tier.all` in analytics is a closed set of four published
      // grades and the edge must not widen it from here.
      'tier': haveRealSteps ? 'HIGH' : null,
      // Likewise, nothing was used when nothing was measured.
      'inputs_used':
          haveRealSteps ? const ['live_coverage_pedometer'] : const <String>[],
      'note': haveRealSteps
          ? 'real pedometer count over measured windows only; time outside '
              'those windows is not counted rather than estimated'
          : 'no step count: nothing that can resolve gait measured this day. '
              'A 1 Hz wrist stream cannot count steps, so no number is shown '
              'instead of an invented one',
    };
  }

  /// STEPS (real pedometer counts ONLY) + movement minutes + total daily energy
  /// (TDEE), written into the bundle's `steps`/`movement` blocks + `scalars`.
  ///
  /// Steps = [liveStepsReal] and nothing else — the pedometer counts banked in
  /// `live_coverage` by a source that can actually resolve gait (the band's
  /// 100 Hz AN-2554 stream, or the phone's own pedometer). Time outside those
  /// windows is NOT counted and NOT estimated: with no real count the day has
  /// no step number at all. See the long note at the call site for why the old
  /// 1 Hz estimate was removed rather than recalibrated.
  ///
  /// Movement minutes are a separate, explicitly non-locomotion activity index
  /// computed over the whole day. TDEE = HR-flex (Mifflin BMR floor + active
  /// Keytel surplus). Best-effort.
  static void _stepsAndEnergy(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate daySub,
    Profile profile,
    int liveStepsReal,
    double? dynFloorG,
    int dynHistoryDays,
  ) {
    try {
      // STEPS FIRST — they depend on NOTHING from the band substrate.
      //
      // `liveStepsReal` comes from `live_coverage`, i.e. the phone pedometer or
      // a live 100 Hz session. Both of the guards below protect the 1 Hz
      // MOVEMENT computation, and if the step assignment sat after them a day
      // with real measured phone steps but a thin band substrate (a day the
      // band barely synced, or a fresh install) would silently report no steps
      // at all — discarding a real measurement because an unrelated signal was
      // missing. Assign steps before anything can return early.
      _writeSteps(bundle, scMap, liveStepsReal);

      if (daySub.length < 60) return;
      final motion = _motionMinutes(daySub);
      if (motion.isEmpty) return;
      final hrPerMin = _hrPerMinuteAligned(motion, daySub);

      // This day's own contribution to the personal floor, persisted to
      // metric_series so tomorrow's derive can anchor on it. Null for a day too
      // thin to summarise — we store nothing rather than a fabricated level.
      final dynSummary = ana.dailyDynSummary(motion);
      if (dynSummary != null) scMap?['dyn_p90'] = dynSummary;

      // MOVEMENT MINUTES run over the WHOLE day — no coverage exclusion.
      //
      // Minutes covered by a pedometer window used to be dropped here, because
      // steps were "real count over covered time + 1 Hz estimate over the rest"
      // and including both would double-count. That hybrid is gone: steps are
      // real-measured only and movement minutes are a separate quantity in a
      // different unit, so there is nothing to double-count. Excluding covered
      // minutes now would just silently under-report movement for exactly the
      // periods we know the user was active.
      final est = ana.dailyActiveMinutes(
        motion,
        personalDynFloorG: dynFloorG,
        pooledMinutesAvailable: dynHistoryDays,
      );
      final v = est.present ? est.value : null;

      // Movement minutes stay, as an explicitly non-locomotion activity index.
      //
      // ONLY OVERWRITE ON SUCCESS — never remove. `_applyWakeDayFeatures` has
      // already written `active_min` from `_activeMinutes` (ENMO over wake), a
      // SEPARATE quantity that was never part of the fabricated step
      // conversion. Removing it on abstention deleted a number the user
      // previously had, for the whole enrollment window (every day a new user
      // has before the floor freezes), and nulled its trend series with it.
      // Abstaining from the new index is right; destroying the old independent
      // measurement to do it is not.
      if (v != null) scMap?['active_min'] = v.activeMinutes.toDouble();
      bundle['movement'] = <String, dynamic>{
        'active_min': v?.activeMinutes,
        'bout_count': v?.boutCount,
        'dyn_floor_g': v?.dynFloorG,
        'coverage': v?.coverage,
        'confidence': est.present ? est.confidence : 0.0,
        'tier': 'ESTIMATE',
        // HR is NOT an input any more — the resting-HR gate was deleted in v56
        // after it changed active minutes by exactly zero on every day tested.
        'inputs_used': const ['dyn_amp_1hz', 'personal_dyn_floor'],
        'note': v == null
            ? (est.note ?? 'need_baseline')
            : 'minutes of sustained wrist movement — activity volume, NOT '
                'walking, and deliberately not converted to steps',
      };
      if (profile.isComplete) {
        final perMinFull = <double>[
          for (final h in hrPerMin)
            if (h > 0) h,
        ];
        if (perMinFull.isNotEmpty) {
          final sexStr = profile.sex == 'm'
              ? 'male'
              : (profile.sex == 'f' ? 'female' : 'nonbinary');
          final e = ana.Calories.dailyEnergy(
            perMinFull,
            profile: ana.WorkoutUserProfile(
              weightKg: profile.weightKg!,
              heightCm: profile.heightCm!,
              age: profile.ageYears!.toDouble(),
              sex: sexStr,
            ),
            hrmax: profile.hrMaxTanaka,
          );
          scMap?['calories_total'] = e.total.roundToDouble();
          bundle['calories_total'] = <String, dynamic>{
            'value': e.total.round(),
            'active': e.active.round(),
            'basal': e.basal.round(),
            'confidence': 0.5,
            'tier': 'ESTIMATE',
            'inputs_used': const ['hr_1hz', 'profile'],
            'note':
                'total daily energy: Mifflin BMR floor + active Keytel surplus '
                '(HR-flex)',
          };
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] steps/energy skipped: $e');
    }
  }

  Future<void> _persistWakeDayFeatures({
    required String dayId,
    required Map<String, dynamic> wake,
  }) async {
    final payload = <String, dynamic>{'day_id': dayId, ...wake};
    await LocalDb.putWakeDayFeatures(
      dayId: dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
    );
  }

  static Map<String, dynamic> _buildWakeDayFeatures(
    Substrate daySub,
    Profile profile, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    double? restingHr,
    double? dynFloorG,
  }) {
    final activeMin = _activeMinutes(daySub, sleepOnsetSec, sleepOffsetSec);
    final wear = _wearBlock(daySub);
    final perMin = _perMinuteMeanWake(daySub, sleepOnsetSec, sleepOffsetSec);
    final motion = _motionMinutes(daySub);
    final hrPerMinAll = _hrPerMinuteAligned(motion, daySub);
    final dayHrValid = <double>[
      for (final h in daySub.hr)
        if (h > 0) h.toDouble(),
    ];
    // NEVER IMPUTE A PROFILE. These used to default to age 30 / 70 kg / sex 'm'
    // / RHR 60 "so new users still get Strain" — and the results were then
    // persisted as REAL scalars (strain, calories, calories_total, steps) into
    // day_result AND metric_series for someone who never entered a profile.
    // That is a fabricated number wearing a real number's clothes, and it
    // contradicts the never-impute contract the rest of this layer (and
    // `Profile`'s own doc, and the pure `onehz_pipeline` which already gates on
    // exactly these fields) enforces. A missing input now makes the DEPENDENT
    // metric absent — the UI already renders "—" correctly.
    final age = profile.ageYears?.toDouble();
    final weightKg = profile.weightKg;
    final sex = profile.sex?.toLowerCase();
    final hrMax = profile.hrMaxTanaka; // null when age is unknown
    final rhrForTrimp = restingHr ?? profile.restingHrManual?.toDouble();
    double? strain;
    double? calories;
    double? steps; // stays null here — real counts only, see below
    double? movementMin;
    double? caloriesTotal;
    Map<String, int> zones = const {};
    if (perMin.isNotEmpty && hrMax != null) {
      // TRIMP needs a real resting HR (nightly or user-supplied) and a real sex
      // constant — both are in the Banister formula itself.
      if (dayHrValid.isNotEmpty && rhrForTrimp != null && sex != null) {
        final trimp = ana.banisterTrimp(
          perMin,
          restingHr: rhrForTrimp,
          maxHr: hrMax,
          sex: sex == 'f' ? ana.Sex.female : ana.Sex.male,
        );
        if (trimp.present && trimp.value != null) {
          final score = ana.strainScoreMetric(trimp.value);
          if (score.present) strain = score.value;
        }
      }
      // Zones are pure %HRmax bands — real as soon as HRmax is real.
      zones = _wakeZoneMinutes(daySub, sleepOnsetSec, sleepOffsetSec, hrMax);
      // Keytel takes age, weight and sex directly.
      if (age != null && weightKg != null && sex != null) {
        calories = _keytelCaloriesWake(perMin, age, weightKg, hrMax, sex == 'f');
      }
    }
    if (motion.isNotEmpty) {
      // STEPS ARE NOT COMPUTED HERE. This is the EARLY-READ path (what Today
      // shows before the full day result exists), and there is no gait-capable
      // source available to it — the real pedometer counts live in
      // `live_coverage` and are summed by `_stepsAndEnergy`, which overwrites
      // this artifact moments later via the copy-back below.
      //
      // It used to seed `steps` from the 1 Hz estimate so Today had something
      // to show immediately. That is exactly the fabrication being removed:
      // "something to show" is not a reason to invent a measurement. `steps`
      // stays null here and Today renders no step figure until a real count
      // exists.
      //
      // Movement minutes ARE computable from 1 Hz and are emitted below.
      final movementMetric = ana.dailyActiveMinutes(
        motion,
        personalDynFloorG: dynFloorG,
      );
      if (movementMetric.present && movementMetric.value != null) {
        movementMin = movementMetric.value!.activeMinutes.toDouble();
      }
      // TDEE needs the full anthropometric set (Mifflin BMR + Keytel surplus).
      if (age != null &&
          weightKg != null &&
          sex != null &&
          profile.heightCm != null) {
        final energy = ana.Calories.dailyEnergy(
          hrPerMinAll,
          profile: ana.WorkoutUserProfile(
            weightKg: weightKg,
            heightCm: profile.heightCm!,
            age: age,
            sex: _workoutSex(profile.sex),
          ),
          hrmax: hrMax,
          dayMinutes: motion.length,
        );
        caloriesTotal = energy.total;
        calories ??= energy.active;
      }
    }
    final hrStats = dayHrValid.isEmpty
        ? null
        : {
            'max': dayHrValid.reduce(math.max).round(),
            'min': dayHrValid.reduce(math.min).round(),
            'avg': _meanWake(dayHrValid)?.round(),
          };
    return {
      'active_min': activeMin,
      'movement_min': movementMin,
      'strain': strain,
      'calories': calories,
      'steps': steps,
      'calories_total': caloriesTotal,
      'wear_min': (wear['worn_min'] as num?)?.toDouble(),
      'activity': {
        'value': activeMin,
        'active_min': activeMin,
        'movement_min': movementMin,
        'confidence': 0.6,
        'tier': 'ESTIMATE',
        'inputs_used': const ['accel_1hz'],
        'note': 'minutes of wrist movement over wake (1 Hz). This is activity '
            'volume, NOT walking, and is never converted to steps: at the '
            'wrist, arm work registers as strongly as ambulation. Real step '
            'counts come only from the 100 Hz or phone pedometer',
      },
      'activity_curve': _activityCurve(daySub),
      'zones': zones,
      'hr_stats': hrStats,
      'wear': wear,
    };
  }

  /// Active minutes over the WAKE span — a coarse 1 Hz movement proxy.
  static int _activeMinutes(Substrate s, int sleepOnsetSec, int sleepOffsetSec) {
    final n = s.length;
    if (n < 60) return 0;
    final ang = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      ang[i] = ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
    }
    const moveDeg = 5.0;
    const activeFrac = 0.20;
    final moveSec = <int, int>{};
    final totSec = <int, int>{};
    for (var i = 1; i < n; i++) {
      final t = s.tsSec[i];
      if (sleepOffsetSec > sleepOnsetSec &&
          t >= sleepOnsetSec &&
          t < sleepOffsetSec) {
        continue;
      }
      final m = t ~/ 60;
      totSec[m] = (totSec[m] ?? 0) + 1;
      if ((ang[i] - ang[i - 1]).abs() > moveDeg) {
        moveSec[m] = (moveSec[m] ?? 0) + 1;
      }
    }
    var active = 0;
    totSec.forEach((m, tot) {
      if (tot > 0 && (moveSec[m] ?? 0) / tot >= activeFrac) active++;
    });
    return active;
  }

  static List<ana.MotionMinute> _motionMinutes(Substrate s) {
    final samples = <ana.AccelSample>[
      for (var i = 0; i < s.length; i++)
        ana.AccelSample(
          s.tsSec[i] * 1000.0,
          s.ax[i],
          s.ay[i],
          s.az[i],
          valid: s.hr[i] > 0,
        ),
    ];
    return ana.enmoSeries(samples).minutes;
  }

  static List<double> _hrPerMinuteAligned(List<ana.MotionMinute> motion, Substrate s) {
    final buckets = <int, List<double>>{};
    for (var i = 0; i < s.hr.length && i < s.tsSec.length; i++) {
      if (s.hr[i] <= 0) continue;
      final minuteStartMs = (s.tsSec[i] ~/ 60) * 60000.0;
      (buckets[minuteStartMs.toInt()] ??= <double>[]).add(s.hr[i].toDouble());
    }
    return [
      for (final mm in motion)
        _meanWake(buckets[mm.tsMinStartMs.toInt()] ?? const <double>[]) ?? 0.0,
    ];
  }

  static String _workoutSex(String? sex) {
    switch ((sex ?? '').toLowerCase()) {
      case 'm':
      case 'male':
        return 'male';
      case 'f':
      case 'female':
        return 'female';
      default:
        return 'nonbinary';
    }
  }

  // NOTE: `detected_workouts` (`const []`) and `advanced_sleep`
  // (`{present:false}`) are currently constant stubs — they are now emitted
  // directly inside [_computeDayBlocks] (the offloaded second half). When the
  // real WorkoutDetector / AdvancedSleepStager passes are re-homed, put them
  // back there so they stay OFF the calling isolate.

  /// Per-5-min movement-level curve over the whole day ([{t, v}], v = fraction
  /// of seconds in the bucket with a ≥5° wrist-orientation change, 0..1). The
  /// honest 1 Hz movement signal (same basis as active-minutes) for the "Your
  /// day" Movement view. Sleep is NOT excluded — the curve naturally dips there.
  static List<Map<String, dynamic>> _activityCurve(Substrate s) {
    final n = s.length;
    if (n < 60) return const [];
    final ang = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      ang[i] = ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
    }
    const bucketSec = 300; // 5 min
    final move = <int, int>{}, tot = <int, int>{};
    for (var i = 1; i < n; i++) {
      final b = s.tsSec[i] ~/ bucketSec;
      tot[b] = (tot[b] ?? 0) + 1;
      if ((ang[i] - ang[i - 1]).abs() > 5.0) move[b] = (move[b] ?? 0) + 1;
    }
    final out = <Map<String, dynamic>>[];
    final keys = tot.keys.toList()..sort();
    for (final b in keys) {
      out.add({
        't': b * bucketSec,
        'v': double.parse(((move[b] ?? 0) / tot[b]!).toStringAsFixed(3)),
      });
    }
    return out;
  }

  /// On/off-wrist segments over the day from RECORD PRESENCE — the runs,
  /// first/last on, longest off gap, worn minutes + time-coverage.
  ///
  /// Wear is whether a 1 Hz record EXISTS, not whether HR locked. The band logs
  /// to flash only while on-wrist (off-wrist it stops and emits WRIST_OFF), so a
  /// record means worn. The old `hr>0` rule misread normal daytime PPG drop-out
  /// (HR only locks on a still wrist with good optical contact — mostly SLEEP)
  /// as off-wrist, collapsing a 24 h-worn day to ~the sleep window (~7-8 h). Off
  /// periods are now GAPS in the record stream longer than [offGapSec].
  ///
  /// CAVEAT: this assumes the band does NOT keep logging while off-wrist. If a
  /// future firmware streams off-wrist records, add a skin-temp/motion on-body
  /// gate here (the substrate carries accel + skinTemp).
  static Map<String, dynamic> _wearBlock(Substrate s) {
    final n = s.length;
    if (n == 0) {
      return {
        'segments': const [],
        'first_on': null,
        'last_on': null,
        'longest_off_min': 0,
        'worn_min': 0,
        'coverage_pct': 0,
      };
    }
    const offGapSec = 120; // a >2-min hole in the 1 Hz stream = off / not worn
    final segments = <Map<String, dynamic>>[];
    final firstOn = s.tsSec.first;
    final lastOn = s.tsSec.last + 1;
    var longestOff = 0, wornSec = 0;
    var runStart = s.tsSec.first;
    var prev = s.tsSec.first;

    void closeOnRun(int endTs) {
      segments.add({
        'on': true,
        'start': runStart,
        'end': endTs,
        'len_min': ((endTs - runStart) / 60).round(),
      });
      wornSec += endTs - runStart;
    }

    for (var i = 1; i < n; i++) {
      final ts = s.tsSec[i];
      final gap = ts - prev;
      if (gap > offGapSec) {
        closeOnRun(prev + 1);
        segments.add({
          'on': false,
          'start': prev + 1,
          'end': ts,
          'len_min': (gap / 60).round(),
        });
        if (gap > longestOff) longestOff = gap;
        runStart = ts;
      }
      prev = ts;
    }
    closeOnRun(prev + 1);

    final totalSec = s.tsSec.last - s.tsSec.first + 1;
    return {
      'segments': segments,
      'first_on': firstOn,
      'last_on': lastOn,
      'longest_off_min': (longestOff / 60).round(),
      'worn_min': (wornSec / 60).round(),
      'coverage_pct': totalSec > 0 ? (100 * wornSec / totalSec).round() : 0,
    };
  }

  /// Waking ultradian HRV: RMSSD over 5-min buckets of the DAY's RR that falls
  /// OUTSIDE the sleep window (the daytime autonomic rhythm). Timeline + mean.
  /// All-day rolling-RMSSD curve over the 24/7 RR (epoch-stamped {t,v}), for the
  /// Timeline graph. 5-min sliding window, emitted ~each minute. Inline artifact
  /// gate (plausible RR 300–2000 ms) — daytime RR is noisier/motion-confounded,
  /// so this is a context line, not the nocturnal recovery RMSSD.
  /// Test seam: counts window evaluations, for the same reason as
  /// [debugRespAttempts] — the fix is about how often the O(window) sum runs.
  @visibleForTesting
  static int debugHrvAttempts = 0;

  @visibleForTesting
  static List<Map<String, num>> dayHrvCurve(Substrate s) {
    final ts = <double>[], rr = <double>[];
    for (var i = 0; i < s.rrMs.length; i++) {
      final v = s.rrMs[i];
      if (v >= 300 && v <= 2000) {
        ts.add(s.rrTsMs[i]);
        rr.add(v);
      }
    }
    if (rr.length < 10) return const [];
    const winMs = 300000.0; // 5 min
    final out = <Map<String, num>>[];
    var lo = 0;
    var lastEmit = -1e18;
    for (var i = 0; i < rr.length; i++) {
      while (ts[i] - ts[lo] > winMs) {
        lo++;
      }
      // Cadence gate FIRST: the sum-of-squared-differences below is O(window),
      // and running it for every beat only to discard the result on the 60 s
      // check was the whole window's work wasted per sample.
      if (i - lo >= 10 && ts[i] - lastEmit > 60000) {
        debugHrvAttempts++;
        var ssd = 0.0;
        var nd = 0;
        for (var k = lo + 1; k <= i; k++) {
          final d = rr[k] - rr[k - 1];
          // Malik 20% rule: a real beat-to-beat change is small; a successive
          // jump >20% (or >200 ms) is an ectopic/missed beat — skip that pair so
          // one artifact doesn't blow RMSSD up to non-physiological 400+ ms.
          if (d.abs() > 0.20 * rr[k - 1] || d.abs() > 200) continue;
          ssd += d * d;
          nd++;
        }
        // Advance on the ATTEMPT, before either quality check. The window holds
        // ~300-600 beats, and leaving the cursor behind when a stretch is too
        // artifact-heavy to yield 8 usable pairs re-runs that whole sum on every
        // subsequent beat until one finally does.
        lastEmit = ts[i];
        if (nd >= 8) {
          final rmssd = math.sqrt(ssd / nd);
          if (rmssd <= 220) {
            out.add({
              't': (ts[i] / 1000).round(),
              'v': double.parse(rmssd.toStringAsFixed(1)),
            });
          }
        }
      }
    }
    return out;
  }

  /// All-day respiratory-rate curve (epoch {t,v} br/min) via rolling RSA on the
  /// 24/7 RR. 3-min window emitted ~every 5 min; absent windows (too few/too
  /// noisy beats) are skipped — never fabricated. Daytime RSA is movement-
  /// confounded, so it's a context line.
  ///
  /// Test seam: replaces the RSA estimator, so the ABSENT branch — the one that
  /// used to strand the cadence cursor and re-run a triple Lomb-Scargle per beat
  /// — can be exercised deterministically. It needs a seam because no synthetic
  /// RR reliably makes the real estimator abstain: the behaviour comes from real
  /// movement-confounded daytime data, which is exactly what is hard to fake.
  @visibleForTesting
  static double? Function(List<double> nn, List<double> nnt)?
      debugRespEstimator;

  /// Test seam: counts estimator ATTEMPTS. The cost fix is about how often the
  /// estimator runs, not about what it returns, so the attempt count is the only
  /// thing that actually distinguishes the fixed code from the broken code.
  @visibleForTesting
  static int debugRespAttempts = 0;

  @visibleForTesting
  static List<Map<String, num>> dayRespCurve(Substrate s) {
    final ts = <double>[], rr = <double>[];
    for (var i = 0; i < s.rrMs.length; i++) {
      final v = s.rrMs[i];
      if (v >= 300 && v <= 2000) {
        ts.add(s.rrTsMs[i]);
        rr.add(v);
      }
    }
    if (rr.length < 60) return const [];
    const winMs = 180000.0; // 3 min
    final out = <Map<String, num>>[];
    var lo = 0;
    var lastEmit = -1e18;
    for (var i = 0; i < rr.length; i++) {
      while (ts[i] - ts[lo] > winMs) {
        lo++;
      }
      if (i - lo >= 30 && ts[i] - lastEmit > 300000) {
        // 5-min cadence
        final nn = rr.sublist(lo, i + 1);
        final t0 = ts[lo];
        final nnt = [for (var k = lo; k <= i; k++) ts[k] - t0];
        debugRespAttempts++;
        final seam = debugRespEstimator;
        final double? brpm;
        if (seam != null) {
          brpm = seam(nn, nnt);
        } else {
          final est = ana.rsaRespRate(nn, nnt, artifactFraction: 0.15);
          brpm = est.present ? est.value!.brpm : null;
        }
        // Advance the cadence cursor on every ATTEMPT, not just on a successful
        // estimate. Daytime RSA is movement-confounded (see above), so absent is
        // the common case — and while lastEmit sat inside the success branch a
        // confounded stretch re-ran the triple Lomb-Scargle once per BEAT
        // instead of once per 5 min. That is what blew the day-blocks budget.
        lastEmit = ts[i];
        if (brpm != null) {
          out.add({
            't': (ts[i] / 1000).round(),
            'v': double.parse(brpm.toStringAsFixed(1)),
          });
        }
      }
    }
    return out;
  }

  /// All-day RELATIVE skin-temperature trend (epoch {t,v}). Per-5-min mean ADC
  /// expressed as a delta from the day's median — RELATIVE only, no absolute °C
  /// (the band has no calibrated temperature). A slow context line.
  static List<Map<String, num>> _daySkinTempCurve(Substrate s) {
    final bins = <int, List<double>>{};
    for (var i = 0; i < s.skinTemp.length && i < s.tsSec.length; i++) {
      final v = s.skinTemp[i];
      if (v > 0) (bins[s.tsSec[i] ~/ 300] ??= []).add(v.toDouble());
    }
    if (bins.length < 3) return const [];
    final keys = bins.keys.toList()..sort();
    final means = {
      for (final k in keys)
        k: bins[k]!.reduce((a, b) => a + b) / bins[k]!.length,
    };
    final sorted = means.values.toList()..sort();
    final med = sorted[sorted.length ~/ 2];
    return [
      for (final k in keys)
        {'t': k * 300, 'v': double.parse((means[k]! - med).toStringAsFixed(1))},
    ];
  }

  static Map<String, dynamic> _daytimeHrv(Substrate s, int onsetSec, int offsetSec) {
    const binSec = 300;
    final bins = <int, List<double>>{};
    double? prev;
    for (var k = 0; k < s.rrMs.length; k++) {
      final tSec = s.rrTsMs[k] ~/ 1000;
      if (offsetSec > onsetSec && tSec >= onsetSec && tSec < offsetSec) {
        prev = null;
        continue; // skip the sleep window
      }
      final v = s.rrMs[k];
      if (v < 300 || v > 2000) {
        prev = null;
        continue;
      }
      if (prev != null) {
        final d = v - prev;
        if (d.abs() <= 200) (bins[tSec ~/ binSec] ??= <double>[]).add(d * d);
      }
      prev = v;
    }
    final timeline = <Map<String, dynamic>>[];
    final means = <double>[];
    final keys = bins.keys.toList()..sort();
    for (final b in keys) {
      final sq = bins[b]!;
      if (sq.length < 5) continue;
      final rmssd = math.sqrt(sq.reduce((a, c) => a + c) / sq.length);
      timeline.add({'t': b * binSec, 'rmssd': (rmssd * 10).round() / 10.0});
      means.add(rmssd);
    }
    final mean = means.isEmpty
        ? null
        : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  /// Nocturnal restlessness from sleep-window orientation change: minutes with
  /// movement, number of distinct movement bouts, longest still stretch (min).
  static Map<String, dynamic> _restlessness(Substrate s) {
    final n = s.length;
    if (n < 60) {
      return {
        'restless_min': null,
        'movement_bouts': null,
        'longest_still_min': null,
      };
    }
    const moveDeg = 5.0;
    final byMinMove = <int, int>{}, byMinTot = <int, int>{};
    for (var i = 1; i < n; i++) {
      final m = s.tsSec[i] ~/ 60;
      byMinTot[m] = (byMinTot[m] ?? 0) + 1;
      final d =
          (ana.zAngle(s.ax[i], s.ay[i], s.az[i]) -
                  ana.zAngle(s.ax[i - 1], s.ay[i - 1], s.az[i - 1]))
              .abs();
      if (d > moveDeg) byMinMove[m] = (byMinMove[m] ?? 0) + 1;
    }
    final keys = byMinTot.keys.toList()..sort();
    var restless = 0, bouts = 0, longestStill = 0, curStill = 0;
    var prevMoved = false;
    for (final m in keys) {
      final moved = (byMinMove[m] ?? 0) / (byMinTot[m] ?? 1) >= 0.20;
      if (moved) {
        restless++;
        if (!prevMoved) bouts++;
        curStill = 0;
      } else {
        curStill++;
        if (curStill > longestStill) longestStill = curStill;
      }
      prevMoved = moved;
    }
    return {
      'restless_min': restless,
      'movement_bouts': bouts,
      'longest_still_min': longestStill,
    };
  }

  /// Sleep periods: the main sleep plus the naps [_attachNaps] already found.
  ///
  /// This used to run its OWN nap detector — 20-min runs of still, on-wrist
  /// minutes — in parallel with `detectNaps`. Two detectors, two answers, two
  /// screens: `payload.json` shipped a 21-minute period here on the very day
  /// `naps` reported `count: 0`. One source per concern (AGENTS §3.8), so the
  /// naps are now passed in rather than re-derived.
  ///
  /// Every period speaks the SAME contract the Sleep-periods screen reads
  /// (`onset_ts`/`wake_ts`/`duration_min`/`efficiency`/`confidence`), and
  /// `duration_min` is minutes ASLEEP for both the main sleep and naps — they
  /// were previously different units under one label, then summed.
  ///
  /// [naps] is NULL when the nap detector could not judge the day at all (as
  /// opposed to an empty list, which means "judged, and there were none"). An
  /// unjudged day has an unknown NUMBER of periods, not just unknown durations,
  /// so the total is unknown for exactly the same reason a null `duration_min`
  /// makes it unknown — and `nap_min` is already left unwritten in that case.
  /// Publishing `total_asleep_min = mainTstMin` there would state a complete
  /// day total while `naps.value` is null, which is internally inconsistent.
  static Map<String, dynamic> _sleepPeriods(
    int onsetSec,
    int offsetSec,
    List<Map<String, dynamic>>? naps, {
    int? mainTstMin,
    double? mainEfficiency,
  }) {
    final periods = <Map<String, dynamic>>[];
    // Null-if-any-component-unknown. Summing a null duration as 0 would print a
    // confident total that is short by exactly the part we could not measure —
    // and the hero tile divides it by need, so the "% of need" arc understates
    // too. An unknown component makes the SUM unknown.
    var totalAsleep = 0;
    var totalKnown = true;
    if (offsetSec > onsetSec) {
      periods.add({
        'is_main': true,
        'onset_ts': onsetSec,
        'wake_ts': offsetSec,
        // Null when staging did not produce a TST. The screen renders "—";
        // substituting the in-bed span would silently relabel time in bed as
        // time asleep, which is the same conflation this change removes.
        'duration_min': mainTstMin,
        'in_bed_min': (offsetSec - onsetSec) ~/ 60,
        'efficiency': ?mainEfficiency,
        // No hypnogram here on purpose: it lives in the isolate-1 bundle's
        // `series.hypnogram`, which this isolate does not receive. The read
        // seam attaches it (see `_daySleep`), where the whole bundle is in
        // hand. Passing it from here would only ever have written null.
      });
      if (mainTstMin != null) {
        totalAsleep += mainTstMin;
      } else {
        totalKnown = false;
      }
    }
    if (naps == null) {
      // Not judged. The day may hold any number of unmeasured naps, so no
      // total can be stated — the screen renders "—" rather than a confident
      // figure that silently omits them.
      totalKnown = false;
    } else {
      for (final nap in naps) {
        periods.add(nap);
        final d = (nap['duration_min'] as num?)?.toInt();
        if (d != null) {
          totalAsleep += d;
        } else {
          totalKnown = false;
        }
      }
    }
    return {
      'periods': periods,
      'total_asleep_min': totalKnown ? totalAsleep : null,
    };
  }

  /// Daytime naps via the analytics `detectNaps` — the ONLY nap source.
  ///
  /// Writes the `naps` block (per-nap epoch bounds + TST/TIB + confidence) and
  /// the `nap_min` scalar (total minutes ASLEEP) used by the Sleep Coach and
  /// Timeline, and returns period maps for [_sleepPeriods] so the Sleep-periods
  /// screen lists exactly the same naps the Timeline draws. There used to be a
  /// second, coarser nap notion in `_sleepPeriods` built from 20-min stillness
  /// runs; the two disagreed on real days (`payload.json` shipped a 21-min
  /// period alongside `naps.count: 0`) and fed two different screens.
  ///
  /// ABSENT is not ZERO. When the detector cannot judge the day, `nap_min` is
  /// left UNWRITTEN rather than set to 0 — a written 0 is a claim that there
  /// were no naps, and it would also be picked up as a real value downstream.
  /// Returns NULL for that unjudged case and a (possibly empty) list when the
  /// day really was judged, so [_sleepPeriods] can make the same distinction
  /// instead of reading "no naps returned" as "no naps happened".
  /// The explicit "nap assessment unknown" envelope.
  ///
  /// Every abstention path must publish this, not just the detector's own
  /// `!m.present` branch. `_computeDayBlocks` starts from an EMPTY bundlePatch
  /// and `_attachNaps` is the only writer of `naps`, so a path that returns
  /// without writing leaves the key missing entirely — and "key absent" and
  /// "judged, value null" are then two different encodings of the same fact,
  /// distinguishable only by HOW the abstention happened. A reader that checks
  /// `bundle['naps']?['value'] == null` and one that checks
  /// `bundle.containsKey('naps')` would disagree.
  /// Abstention path that still honours what the USER logged.
  ///
  /// The detector abstains on exactly the days this feature exists for — strap
  /// off for part of the afternoon, a short record, a failure. Returning early
  /// there dropped every logged nap on the floor: no card to see, no minutes
  /// credited, and no way to delete the row the user had just created, while
  /// the edit kept force-re-deriving that day forever.
  ///
  /// A logged nap needs nothing from the detector — it carries its own absolute
  /// bounds — so it is published on its own. The day is still reported as
  /// unjudged when the user logged nothing, because that is what it is.
  static List<Map<String, dynamic>>? _napsWhenUnjudged(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    List<NapEdit> napEdits,
    String note,
  ) {
    final merged = applyNapEdits(const [], napEdits);
    if (merged.isEmpty) {
      _writeUnknownNaps(bundle, note);
      return null;
    }
    bundle['naps'] = <String, dynamic>{
      'value': merged,
      'count': merged.length,
      // No detection confidence, because there was no detection.
      'confidence': null,
      // AUTH is the closed vocabulary's "directly measured / definitional",
      // which is what a self-report is: the user is not estimating that they
      // napped, they are stating it. An invented fifth tier would be a string
      // no reader knows how to rank.
      'tier': ana.Tier.auth,
      'inputs_used': const ['user'],
      'note': '$note — showing what you logged',
    };
    scMap?['nap_min'] = napMinutes(merged).toDouble();
    return [
      for (final nap in merged)
        {
          'is_main': false,
          'onset_ts': nap['start'],
          'wake_ts': nap['end'],
          'duration_min': nap['duration_min'],
          'in_bed_min': nap['in_bed_min'],
          'efficiency': null,
          'confidence': null,
          if (nap['source'] != null) 'source': nap['source'],
        },
    ];
  }

  static void _writeUnknownNaps(
    Map<String, dynamic> bundle,
    String note,
  ) {
    bundle['naps'] = <String, dynamic>{
      'value': null,
      'count': null,
      'confidence': 0,
      'tier': 'ESTIMATE',
      'inputs_used': const <String>[],
      'note': note,
    };
  }

  static List<Map<String, dynamic>>? _attachNaps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    int onsetSec,
    int offsetSec, {
    int? attributionStartSec,
    int? attributionEndSec,
    List<List<int>> wristOff = const [],
    List<List<int>> charging = const [],
    // Read on the main isolate and carried in, like every other DB-sourced
    // input here — this runs inside the compute worker, which has no database.
    List<NapEdit> napEdits = const [],
  }) {
    try {
      final n = s.length;
      if (n < 60) {
        return _napsWhenUnjudged(
          bundle,
          scMap,
          napEdits,
          'too little 1 Hz data to assess naps',
        );
      }
      final accel = <ana.AccelSample>[
        for (var i = 0; i < n; i++)
          ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i]),
      ];
      final hr = [for (final h in s.hr) h.toDouble()];
      // Map the main-sleep epoch-second window to indices into the day arrays.
      ana.SleepWindowSpan? main;
      if (offsetSec > onsetSec) {
        var lo = -1, hi = -1;
        for (var i = 0; i < n; i++) {
          if (lo < 0 && s.tsSec[i] >= onsetSec) lo = i;
          if (s.tsSec[i] < offsetSec) hi = i + 1;
        }
        if (lo >= 0 && hi > lo) main = ana.SleepWindowSpan(lo, hi);
      }
      final m = ana.detectNaps(
        accel,
        hr,
        mainSleep: main,
        wristOff: wristOff,
        exclude: charging,
      );

      if (!m.present) {
        return _napsWhenUnjudged(
          bundle,
          scMap,
          napEdits,
          m.note ?? 'naps could not be assessed for this day',
        );
      }

      final t0 = s.tsSec.first;
      // The window opens AT local midnight and is contiguous into it, so a bout
      // that begins at the very first sample was already in progress when we
      // started looking — it is the tail of something that started YESTERDAY,
      // and yesterday's buffered window (which runs `napBoundaryBufferSec` past
      // its own midnight) saw it whole and emitted it whole.
      //
      // Analytics guards the trailing edge only: `unfinished` walks BACKWARD
      // from the array end (nap.dart), while `stillAt(0)` short-circuits its
      // discontinuity check at `k == 0` — so a bout at index 0 is always
      // emitted, with no way for the detector to know what preceded it. Before
      // `minNapSec` dropped to 15 min this was unreachable (the old nocturnal
      // detector needed 60+ min and an HR dip); it is reachable now.
      //
      // Gated on contiguity, NOT on index alone: if the record only STARTS
      // hours into the day (band off overnight), yesterday's detector broke on
      // that same discontinuity and dropped the bout too, so dropping it here
      // as well would lose a real nap rather than de-duplicate one.
      final leadingEdgeOwnedByYesterday = attributionStartSec != null &&
          t0 <= attributionStartSec + napLeadingEdgeContiguitySec;
      // A nap STARTING at/after the real day boundary is tomorrow's — its own
      // (unbuffered) window finds it independently, so keeping it here too
      // would double-count it.
      final naps = m.value!.where((nap) {
        if (leadingEdgeOwnedByYesterday && nap.startSec == 0) return false;
        if (attributionEndSec == null) return true;
        return t0 + nap.startSec < attributionEndSec;
      }).toList();

      // The detector's answer is a PROPOSAL. The user's edits — a nap it
      // missed, or one it invented — are stored separately and replayed over
      // it here on every derivation, so a better detector later still respects
      // "there was no nap here" instead of the edit being baked into a stale
      // detection.
      final detected = <Map<String, dynamic>>[
        for (final nap in naps)
          {
            'start': t0 + nap.startSec,
            'end': t0 + nap.endSec,
            // Minutes ASLEEP. `duration_min` kept as the asleep figure so
            // existing readers do not silently switch to in-bed minutes.
            'duration_min': (nap.tstSec / 60).round(),
            'in_bed_min': (nap.tibSec / 60).round(),
            'efficiency': nap.efficiency,
            'confidence': nap.confidence,
          },
      ];
      final merged = applyNapEdits(detected, napEdits);

      bundle['naps'] = <String, dynamic>{
        'value': merged,
        'count': merged.length,
        'confidence': m.confidence,
        'tier': m.tier,
        'inputs_used': m.inputs_used,
        'note': napEdits.isEmpty ? m.note : '${m.note} (edited)',
      };

      // TST, never TIB. Crediting in-bed minutes against sleep need
      // over-credits every nap by its awake time and always errs toward
      // recommending LESS sleep than the user needs.
      // Rounded, matching the two display paths exactly. Truncating here while
      // the cards round made the credit disagree with the sum of the minutes
      // shown — up to a minute per nap, in a number the user can add up.
      // Summed over the MERGED list, so a logged nap counts toward sleep need
      // and sleep debt exactly as a detected one does.
      scMap?['nap_min'] = napMinutes(merged).toDouble();

      return [
        for (final nap in merged)
          {
            'is_main': false,
            'onset_ts': nap['start'],
            'wake_ts': nap['end'],
            'duration_min': nap['duration_min'],
            'in_bed_min': nap['in_bed_min'],
            'efficiency': nap['efficiency'],
            'confidence': nap['confidence'],
            if (nap['source'] != null) 'source': nap['source'],
          },
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] naps FAILED/skipped: $e');
      return _napsWhenUnjudged(
        bundle,
        scMap,
        napEdits,
        'nap detection failed for this day',
      );
    }
  }

  /// Runs [_computeDayBlocks] in an explicitly spawned, killable isolate and
  /// enforces [timeout] on the isolate itself — not just on the caller's wait.
  ///
  /// `Isolate.run(...).timeout(...)` (the previous approach) only stops the
  /// CALLER from awaiting the result; the spawned isolate keeps executing to
  /// completion in the background regardless. Under a multi-day backlog with
  /// a bounded worker pool ([_deriveConcurrency]), a slow/hung day's abandoned
  /// isolate can keep burning CPU well after its caller moved on to the next
  /// day — silently exceeding the intended concurrency budget. Spawning the
  /// isolate ourselves gives us a handle to actually `kill()` it on timeout.
  static Future<_DayBlocksOutput> _runDayBlocksCancellable(
    _DayBlocksInput input,
    Duration timeout,
  ) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(
      _dayBlocksIsolateEntry,
      (port.sendPort, input),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final completer = Completer<_DayBlocksOutput>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((message) {
      if (completer.isCompleted) return;
      if (message is _DayBlocksOutput) {
        completer.complete(message);
      } else if (message is List) {
        // Either our own caught-exception report (`[error, stack]`) or the
        // `onError` port's uncaught-error format — both are 2-element lists
        // of strings. `onExit` fires with `null`, which we treat as "the
        // isolate ended without ever sending a result" below.
        completer.completeError(
          StateError(
            message.isNotEmpty
                ? 'day-blocks isolate failed: ${message.first}'
                : 'day-blocks isolate failed with no error detail',
          ),
        );
      } else if (message == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('day-blocks isolate exited without a result'),
          );
        }
      }
    });
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          isolate.kill(priority: Isolate.immediate);
          throw TimeoutException(
            'day-blocks computation timed out after $timeout',
          );
        },
      );
    } finally {
      await sub.cancel();
      port.close();
      // No-op if the isolate already exited normally; guarantees a hung or
      // still-running isolate never outlives this call.
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Run [compute] in an explicitly spawned isolate and enforce [timeout] ON THE
  /// ISOLATE — the general-purpose form of [_runDayBlocksCancellable].
  ///
  /// `Isolate.run(...).timeout(...)` only stops the CALLER awaiting; the spawned
  /// isolate keeps burning CPU to completion in the background. With a bounded
  /// per-day worker pool that silently blows the concurrency budget during a
  /// backlog sweep — which is exactly why [_runDayBlocksCancellable] exists, and
  /// it had been applied to only one of the file's isolate sites. Worse, some
  /// sites (the sleep-staging pass) had NO timeout at all, so a hung isolate
  /// wedged the engine with `_running == true` forever.
  ///
  /// Also wires `onError`/`onExit` so an uncaught throw or a silent death
  /// FAILS the future instead of hanging it.
  static Future<R> _runIsolateCancellable<R>(
    FutureOr<R> Function() compute,
    Duration timeout, {
    required String label,
  }) async {
    final port = ReceivePort();
    final (SendPort, FutureOr<Object?> Function()) message =
        (port.sendPort, compute);
    final isolate = await Isolate.spawn(
      _cancellableIsolateEntry,
      message,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final completer = Completer<R>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((msg) {
      if (completer.isCompleted) return;
      if (msg is _IsolateValue) {
        completer.complete(msg.value as R);
      } else if (msg is List) {
        // Our caught-exception report or the `onError` port's uncaught-error
        // format — both 2-element lists of strings.
        completer.completeError(
          StateError(
            msg.isNotEmpty
                ? '$label isolate failed: ${msg.first}'
                : '$label isolate failed with no error detail',
          ),
        );
      } else if (msg == null) {
        // `onExit` — the isolate ended without ever sending a result.
        completer.completeError(
          StateError('$label isolate exited without a result'),
        );
      }
    });
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          isolate.kill(priority: Isolate.immediate);
          throw TimeoutException('$label timed out after $timeout');
        },
      );
    } finally {
      await sub.cancel();
      port.close();
      // No-op if it already exited; guarantees a hung isolate never outlives
      // this call.
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// `Isolate.spawn` entry point for [_runIsolateCancellable].
  static Future<void> _cancellableIsolateEntry(
    (SendPort, FutureOr<Object?> Function()) args,
  ) async {
    final (sendPort, compute) = args;
    try {
      sendPort.send(_IsolateValue(await compute()));
    } catch (e, st) {
      sendPort.send([e.toString(), st.toString()]);
    }
  }

  /// `Isolate.spawn` entry point for [_runDayBlocksCancellable]. Must be a
  /// static/top-level function taking exactly one (sendable) argument.
  static void _dayBlocksIsolateEntry((SendPort, _DayBlocksInput) args) {
    final (sendPort, input) = args;
    try {
      sendPort.send(_computeDayBlocks(input));
    } catch (e, st) {
      sendPort.send([e.toString(), st.toString()]);
    }
  }

  /// The full PURE second half of per-day derivation, run OFF the calling
  /// isolate via a cancellable spawned isolate (see [_runDayBlocksCancellable],
  /// [_derivePreparedDay]). Previously ALL of this ran on whatever isolate
  /// drove the engine — the UI isolate for the foreground light pass fired on
  /// every sync — producing multi-second main-thread hangs (rolling RSA
  /// Lomb-Scargle over the 24 h day, nap re-staging, workout detection, wake
  /// features, steps/energy). DB reads are performed by the caller and passed
  /// in; DB writes + notifications are returned as descriptors for the caller
  /// to apply.
  static _DayBlocksOutput _computeDayBlocks(_DayBlocksInput inp) {
    final daySub = inp.daySub;
    final sleepSub = inp.sleepSub;
    final onset = inp.onsetSec;
    final offset = inp.offsetSec;
    final bundlePatch = <String, dynamic>{};
    final seriesPatch = <String, dynamic>{};
    // Working scalars — seeded with the nightly RHR the pure helpers read
    // (steps/energy + wake features gate on it). The seed is removed from the
    // returned patch so we only write back the NEWLY computed scalars.
    final scMap = <String, dynamic>{'rhr': inp.rhr};

    // Wake-day features (active min / strain / calories / steps / zones / wear),
    // then the hybrid 100 Hz + 1 Hz steps + TDEE override (order preserved).
    final wake = _buildWakeDayFeatures(
      daySub,
      inp.profile,
      sleepOnsetSec: onset,
      sleepOffsetSec: offset,
      restingHr: inp.rhr,
      dynFloorG: inp.dynFloorG,
    );
    _applyWakeDayFeatures(bundlePatch, scMap, wake);
    _stepsAndEnergy(
      bundlePatch,
      scMap,
      daySub,
      inp.profile,
      inp.liveStepsReal,
      inp.dynFloorG,
      inp.dynHistoryDays,
    );
    // _stepsAndEnergy just wrote `steps` (REAL pedometer counts from
    // `live_coverage` — band 100 Hz or phone, never an estimate) and
    // `calories_total` into bundlePatch + scMap. `wake` was built above by
    // _buildWakeDayFeatures BEFORE that ran, and deliberately leaves `steps`
    // null: the early-read path has no gait-capable source of its own and must
    // not invent one. `wake` is what _persistWakeDayFeatures stores and what
    // the Today repository reads until the full day result exists, so copy the
    // measured values back in — otherwise Today shows no step count on a day
    // that really was measured.
    for (final key in const ['steps', 'calories_total']) {
      final value = scMap[key];
      if (value != null) wake[key] = value;
    }

    bundlePatch['daytime_hrv'] = _daytimeHrv(daySub, onset, offset);
    seriesPatch['hrv_day'] = dayHrvCurve(daySub);
    seriesPatch['resp_day'] = dayRespCurve(daySub);
    seriesPatch['skin_temp_day'] = _daySkinTempCurve(daySub);
    bundlePatch['restlessness'] = _restlessness(sleepSub);
    // napSub extends a few hours past this day's calendar end so a nap/
    // secondary-sleep block spanning midnight isn't bisected — but a run that
    // actually STARTS in that borrowed buffer belongs to tomorrow (which sees
    // it in its own regular window), so both helpers drop anything starting
    // at/after dayEndSec to avoid double-counting.
    // Naps FIRST — `_sleepPeriods` lists exactly these, so the Timeline bands
    // and the Sleep-periods cards can never disagree again.
    final napPeriods = _attachNaps(
      bundlePatch,
      scMap,
      inp.napSub,
      onset,
      offset,
      attributionStartSec: inp.dayStartSec,
      attributionEndSec: inp.dayEndSec,
      wristOff: inp.wristOffSpans,
      charging: inp.chargingSpans,
      napEdits: inp.napEdits,
    );
    bundlePatch['sleep_periods'] = _sleepPeriods(
      onset,
      offset,
      napPeriods,
      mainTstMin: inp.mainTstMin,
      mainEfficiency: inp.mainEfficiency,
    );
    // Overrides wake's activity_curve (same value, computed once here).
    bundlePatch['activity_curve'] = _activityCurve(daySub);
    bundlePatch['detected_workouts'] = const <Map<String, dynamic>>[];

    final wc = _computeWorkouts(
      s: daySub,
      maxHr: inp.maxHrUsed,
      rhrScalar: inp.rhr,
      saved: inp.savedSessions,
      date: inp.date,
      dayEndSec: inp.dayEndSec,
      dataNowSec: inp.dataNowSec,
    );
    bundlePatch['workout_suggestions'] = wc.boutJson;
    if (wc.hrrBpm != null) scMap['hrr_bpm'] = wc.hrrBpm;

    _attachWristOrientation(bundlePatch, daySub, onset, offset);
    bundlePatch['advanced_sleep'] = const {'present': false};

    // Feature 6: Restlessness Map (5-min ENMO heatmap of the sleep window).
    if (sleepSub.length > 0) {
      const bucketSec = 300; // 5 min
      final moveSum = <int, double>{};
      final moveCount = <int, int>{};
      for (var i = 0; i < sleepSub.length; i++) {
        final b = sleepSub.tsSec[i] ~/ bucketSec;
        final ax = sleepSub.ax[i];
        final ay = sleepSub.ay[i];
        final az = sleepSub.az[i];
        final mag = math.sqrt(ax * ax + ay * ay + az * az);
        final enmo = (mag - 1.0).abs();
        moveSum[b] = (moveSum[b] ?? 0.0) + enmo;
        moveCount[b] = (moveCount[b] ?? 0) + 1;
      }
      final out = <Map<String, dynamic>>[];
      final keys = moveSum.keys.toList()..sort();
      for (final b in keys) {
        final avgEnmo = moveSum[b]! / moveCount[b]!;
        final density = math.min(1.0, avgEnmo * 10.0);
        out.add({
          't': b * bucketSec,
          'density': double.parse(density.toStringAsFixed(3)),
        });
      }
      bundlePatch['restlessness_map'] = out;
    }

    // Feature 2: Fit-quality diagnostic (band too loose during high activity).
    var activeContactSum = 0;
    var activeContactN = 0;
    for (var i = 0; i < daySub.length; i++) {
      if (daySub.hr[i] > 100 && daySub.skinContact[i] > 0) {
        activeContactSum += daySub.skinContact[i];
        activeContactN++;
      }
    }
    if (activeContactN > 60) {
      final avgContact = activeContactSum / activeContactN;
      if (avgContact < 100) {
        bundlePatch['fit_quality'] = 'poor';
        bundlePatch['fit_warning'] =
            'Band is worn too loosely during high activity. Tighten for accurate HR.';
      }
    }

    scMap.remove('rhr'); // seed only; the real rhr scalar already lives in the bundle
    return _DayBlocksOutput(
      bundlePatch: bundlePatch,
      seriesPatch: seriesPatch,
      scalarPatch: scMap,
      wake: wake,
      suggestionsToPersist: wc.suggestionsToPersist,
      sessionHrrWrites: wc.sessionHrrWrites,
      notifBout: wc.notifBout,
    );
  }

  /// PURE compute half of workout SUGGESTIONS (`autoDetectWorkouts`) + HRR.
  ///
  /// Runs inside the day-blocks isolate: one detector pass over the day's 1 Hz HR
  /// (+ gravity motion) yields the detected bouts (excluding any already-saved
  /// manual/live session, passed in via [saved] which the caller read from the DB
  /// on the DB-owning isolate) and each bout's HR-tail HRR-60s drop. Returns the
  /// bout JSON, the mean `hrr_bpm`, the retrospective per-session HRR writes, the
  /// recent-day suggestions to persist, and the freshly-ended notif candidate —
  /// the DB writes + notification are performed by the caller on the main isolate.
  static _WorkoutCompute _computeWorkouts({
    required Substrate s,
    required int? maxHr,
    required double? rhrScalar,
    required List<Map<String, dynamic>> saved,
    required String date,
    required int dayEndSec,
    required int dataNowSec,
  }) {
    try {
      final n = s.length;
      if (n < 60) return const _WorkoutCompute.empty();
      final hrTs = <int>[];
      final hrBpm = <int>[];
      for (var i = 0; i < n; i++) {
        if (s.hr[i] > 0) {
          hrTs.add(s.tsSec[i]);
          hrBpm.add(s.hr[i]);
        }
      }
      if (hrBpm.length < 60) return const _WorkoutCompute.empty();
      final motion =
          ana.AutoWorkoutDetector.motionPoints(s.tsSec, s.ax, s.ay, s.az);
      // Exclude windows the user has already logged (manual/live wins).
      final savedSpans = <ana.SavedWorkoutSpan>[
        for (final r in saved)
          if (r['start_ts'] is int && r['end_ts'] is int)
            ana.SavedWorkoutSpan(r['start_ts'] as int, r['end_ts'] as int),
      ];
      final rhr = rhrScalar?.round();
      // Auto-detection needs a real resting-HR baseline. Without one the detector
      // can't compute a trustworthy %HRR floor and ordinary daytime HR reads as a
      // workout. If we don't have a nightly RHR for this day yet, skip detection
      // entirely (HRR for already-saved sessions below still runs).
      final bouts = rhr == null
          ? const <ana.DetectedWorkout>[]
          : (ana.autoDetectWorkouts(
                hrTs: hrTs,
                hrBpm: hrBpm,
                restingBpm: rhr,
                maxBpm: maxHr,
                motion: motion,
                savedSpans: savedSpans,
              ).value ??
              const <ana.DetectedWorkout>[]);

      // HRR per bout from the per-second HR tail bracketing each bout end.
      final drops = <double>[];
      final boutJson = <Map<String, dynamic>>[];
      for (final b in bouts) {
        final m = _hrrForBout(s, b.endSec);
        if (m != null) drops.add(m);
        boutJson.add({
          'start': b.startSec,
          'end': b.endSec,
          'avg_bpm': b.avgBpm,
          'peak_bpm': b.peakBpm,
          'duration_min': b.durationMin,
          'sport': b.sport,
          if (m != null) 'hrr_bpm': double.parse(m.toStringAsFixed(1)),
        });
      }
      // Also fill HRR for already-saved sessions (manual/live) retrospectively
      // from the substrate around each session's end — so the workout detail
      // screen shows HRR without buffering 60 s after a live stop.
      final sessionHrr = <(String, double)>[];
      for (final r in saved) {
        final id = r['id'];
        final endTs = r['end_ts'];
        if (id is! String || endTs is! int) continue;
        final m = _hrrForBout(s, endTs);
        if (m != null) {
          drops.add(m);
          sessionHrr.add((id, double.parse(m.toStringAsFixed(1))));
        }
      }
      final hrrBpm = drops.isEmpty
          ? null
          : double.parse(
              (drops.reduce((a, c) => a + c) / drops.length).toStringAsFixed(1));

      // Persist + notify only for RECENT days (≤ ~36 h old) so imports/re-analyze
      // don't resurface 90 days of prompts.
      final recent = (dataNowSec - dayEndSec) < 36 * 3600;
      final toPersist = <Map<String, dynamic>>[];
      ({int endSec, int durationMin})? notif;
      if (recent && bouts.isNotEmpty) {
        for (final b in bouts) {
          toPersist.add({
            'id': '$date:${b.startSec}',
            'date': date,
            'start_ts': b.startSec,
            'end_ts': b.endSec,
            'avg_bpm': b.avgBpm,
            'peak_bpm': b.peakBpm,
            'duration_min': b.durationMin,
            'sport': b.sport,
            'dismissed': 0,
          });
        }
        // Notify ONLY for a bout that ended in the last ~2 h (a near-real-time
        // detection). Draining a backlog (e.g. an overnight gap) re-derives a whole
        // day at once; without this every hours-old bout would fire a "did you work
        // out?" prompt → a wall of notifications. Suggestions are still persisted
        // above so they surface in the Workouts screen; we just don't ping for them.
        final newest = bouts.reduce((a, b) => a.endSec >= b.endSec ? a : b);
        if ((dataNowSec - newest.endSec) < 2 * 3600) {
          notif = (endSec: newest.endSec, durationMin: newest.durationMin);
        }
      }
      return _WorkoutCompute(
        boutJson: boutJson,
        hrrBpm: hrrBpm,
        sessionHrrWrites: sessionHrr,
        suggestionsToPersist: toPersist,
        notifBout: notif,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] auto-workout/HRR FAILED/skipped: $e');
      return const _WorkoutCompute.empty();
    }
  }

  /// HRR-60s for a bout ending at [endSec]: build the per-second HR tail around
  /// the end index and delegate to [ana.hrRecovery]. Returns the drop (bpm) or null.
  static double? _hrrForBout(Substrate s, int endSec) {
    final n = s.length;
    if (n == 0) return null;
    // Find the index nearest the bout end.
    var endIdx = -1;
    for (var i = 0; i < n; i++) {
      if (s.tsSec[i] >= endSec) {
        endIdx = i;
        break;
      }
    }
    if (endIdx < 0) endIdx = n - 1;
    const pre = 30, post = 75;
    final lo = (endIdx - pre).clamp(0, n - 1);
    final hi = (endIdx + post).clamp(0, n - 1);
    final tail = <int>[for (var i = lo; i <= hi; i++) s.hr[i]];
    final m = ana.hrRecovery(tail, endIndex: endIdx - lo, recoverySec: 60);
    return m.present ? m.value!.dropBpm : null;
  }

  /// Low-confidence WRIST ORIENTATION during the sleep window (`positionSeries`).
  /// Explicitly a WRIST measure (body-position PROXY), never claimed as the
  /// sleeper's supine/side/prone body position. Emits a dominant-orientation
  /// summary + per-position minutes + an orientation-change count. Best-effort.
  static void _attachWristOrientation(
    Map<String, dynamic> bundle,
    Substrate s,
    int onsetSec,
    int offsetSec,
  ) {
    try {
      if (offsetSec <= onsetSec) return;
      final epoch = <ana.AccelSample>[
        for (var i = 0; i < s.length; i++)
          if (s.tsSec[i] >= onsetSec && s.tsSec[i] < offsetSec)
            ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i])
      ];
      if (epoch.length < 60) return;
      final tilts = ana.positionSeries(epoch, epochSec: 30);
      if (tilts.isEmpty) return;
      // Per-position minutes (each epoch ≈ 30 s) + orientation-change count.
      final mins = <String, double>{};
      var changes = 0;
      String? prev;
      for (final t in tilts) {
        mins[t.position] = (mins[t.position] ?? 0) + 0.5; // 30 s
        if (prev != null && prev != t.position) changes++;
        prev = t.position;
      }
      String dominant = 'unknown';
      var best = -1.0;
      mins.forEach((k, v) {
        if (v > best) {
          best = v;
          dominant = k;
        }
      });
      bundle['wrist_orientation'] = <String, dynamic>{
        'dominant': dominant,
        'minutes': mins,
        'changes': changes,
        'epochs': tilts.length,
        'confidence': 'low',
        'tier': ana.Tier.relative,
        'note': 'WRIST orientation during sleep (gravity-tilt). A body-position '
            'PROXY, NOT supine/side/prone body position — the wrist moves '
            'independently of the torso.',
      };
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] wrist-orientation FAILED/skipped: $e');
    }
  }

  int _localDayLabelToSec(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return 0;
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
  }

  // was `_localDayLabelToSec(day) + 86400` at every call site - assumes every
  // local day is exactly 24h, which is wrong on the two DST-transition days a
  // year (23h/25h). DateTime normalizes the day+1 overflow itself and
  // .millisecondsSinceEpoch already respects local DST rules, so just asking
  // for the START of the NEXT day gets this right without hardcoding a
  // day length.
  int _localNextDayLabelToSec(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return 0;
    return DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch ~/ 1000;
  }

  String _skipReasonForError(Object error) {
    final msg = error.toString();
    if (msg.contains('day_prepare_budget_exceeded')) {
      return 'day_prepare_budget_exceeded';
    }
    if (msg.contains('TimeoutException')) {
      return 'timeout';
    }
    return 'error';
  }

  /// The substrate range to LOAD so [calendarDays] can actually run its
  /// documented nocturnal search for [dayId].
  ///
  /// `calendarDays` searches from the previous local NOON
  /// (`dayStart − kNocturnalSearchLookbackSec`), and its comment records that
  /// widening from the old prev-18:00 window as deliberate — "the old
  /// prev-18:00 → noon window missed late wakes and forced the detector to act
  /// like there was only one candidate sleep". But this loader only fetched
  /// `dayStart − 6 h` (= 18:00), and `searchStart = math.max(dataStart, …)`
  /// clipped the search right back to the slice start, so the widening was a
  /// no-op and any sleep onset before 18:00 was truncated. Load the whole
  /// window the day model asks for, from the one shared constant.
  (int, int) _targetDayWindow(String dayId) {
    final startSec = _localDayLabelToSec(dayId);
    final endSec = _localNextDayLabelToSec(dayId);
    return (math.max(0, startSec - kNocturnalSearchLookbackSec), endSec - 1);
  }

  /// Test seam for [_targetDayWindow] — the bug was that this loader and
  /// [calendarDays]' search window silently disagreed, so the agreement is
  /// pinned directly.
  @visibleForTesting
  (int, int) debugTargetDayWindow(String dayId) => _targetDayWindow(dayId);

  /// Test seam for [_sleepPeriods] — "an unjudged day publishes no total" is a
  /// one-line invariant guarding a user-visible number, so it is pinned
  /// directly rather than through a full derive pass.
  @visibleForTesting
  static Map<String, dynamic> debugSleepPeriods(
    int onsetSec,
    int offsetSec,
    List<Map<String, dynamic>>? naps, {
    int? mainTstMin,
    double? mainEfficiency,
  }) =>
      _sleepPeriods(
        onsetSec,
        offsetSec,
        naps,
        mainTstMin: mainTstMin,
        mainEfficiency: mainEfficiency,
      );

  /// Test seam for [_attachNaps] — the day-boundary attribution rules (drop
  /// tomorrow's leading nap, drop yesterday's trailing one) decide which day a
  /// nap's minutes are credited to, and are cheap to state directly.
  @visibleForTesting
  static List<Map<String, dynamic>>? debugAttachNaps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    int onsetSec,
    int offsetSec, {
    int? attributionStartSec,
    int? attributionEndSec,
    List<List<int>> wristOff = const [],
    List<List<int>> charging = const [],
    List<NapEdit> napEdits = const [],
  }) =>
      _attachNaps(
        bundle,
        scMap,
        s,
        onsetSec,
        offsetSec,
        attributionStartSec: attributionStartSec,
        attributionEndSec: attributionEndSec,
        wristOff: wristOff,
        charging: charging,
        napEdits: napEdits,
      );

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}

/// Wrapper for a cancellable-isolate result, so a computation whose OWN result
/// happens to be a `List` (the uncaught-error wire format) or `null` (the
/// `onExit` signal) can never be misread as a failure.
class _IsolateValue {
  final Object? value;
  const _IsolateValue(this.value);
}

/// Test seam for [DerivationEngine._runIsolateCancellable] — the isolate
/// lifecycle guarantees (value / error / killed-on-timeout) are what the engine
/// depends on to never hang, so they're pinned directly.
@visibleForTesting
Future<R> runCancellableIsolate<R>(
  FutureOr<R> Function() compute,
  Duration timeout, {
  String label = 'test',
}) =>
    DerivationEngine._runIsolateCancellable(compute, timeout, label: label);

/// Sendable input for [DerivationEngine._computeDayBlocks] — crosses the
/// `Isolate.run` boundary, so every field is plain data (Substrate is int/double
/// lists; Profile is a primitive data class). DB reads that the
/// pure compute needs are performed by the caller and passed in here.
class _DayBlocksInput {
  final Substrate daySub;
  final Substrate napSub;
  final Substrate sleepSub;
  final Profile profile;
  final int onsetSec;
  final int offsetSec;
  final double? rhr;
  final int? maxHrUsed;
  final int liveStepsReal;

  /// PERSONAL ambulatory floor (g, dynAmp units) from trailing days, or null
  /// when there isn't enough history yet — in which case the 1 Hz estimator
  /// abstains rather than falling back to a constant. Computed on the main
  /// isolate (it needs metric_series) and carried in, like the other history.
  final double? dynFloorG;

  /// How many trailing days backed [dynFloorG] — only for the cold-start note.
  final int dynHistoryDays;
  final List<Map<String, dynamic>> savedSessions;

  /// The user's nap edits for this day, replayed over the detector's output.
  final List<NapEdit> napEdits;

  /// Strap-reported off-wrist spans ([startSec, endSec]) over the nap window.
  /// A band on a table is motionless and reads as deep rest — this is the
  /// dominant nap false positive, and the strap already tells us about it.
  final List<List<int>> wristOffSpans;

  /// Strap-reported charging spans — off-wrist by definition, and motionless.
  final List<List<int>> chargingSpans;

  /// Main-sleep TST (minutes) and efficiency (0..1) from ISOLATE 1.
  ///
  /// Carried explicitly because `_computeDayBlocks` builds its own fresh
  /// `scMap` seeded with `rhr` alone — reading `scMap['tst_min']` in there
  /// silently yields null forever, which is how the main sleep period came to
  /// report "—" for its duration.
  final int? mainTstMin;
  final double? mainEfficiency;

  final String date;

  /// Local midnight opening this calendar day — where `napSub` starts. Nap
  /// attribution needs BOTH boundaries: [dayEndSec] pushes a nap starting in
  /// the borrowed buffer onto tomorrow, and this one drops the tail of a nap
  /// yesterday already owns. See `_attachNaps`.
  final int dayStartSec;
  final int dayEndSec;
  final int dataNowSec;
  const _DayBlocksInput({
    required this.daySub,
    required this.napSub,
    required this.sleepSub,
    required this.profile,
    required this.onsetSec,
    required this.offsetSec,
    required this.rhr,
    required this.maxHrUsed,
    required this.liveStepsReal,
    required this.dynFloorG,
    required this.dynHistoryDays,
    required this.savedSessions,
    this.napEdits = const [],
    required this.wristOffSpans,
    required this.chargingSpans,
    required this.mainTstMin,
    required this.mainEfficiency,
    required this.date,
    required this.dayStartSec,
    required this.dayEndSec,
    required this.dataNowSec,
  });
}

/// Sendable output of [DerivationEngine._computeDayBlocks]. [bundlePatch] /
/// [seriesPatch] / [scalarPatch] are merged into the isolate-1 bundle on the main
/// isolate; [wake] is persisted; [suggestionsToPersist] / [sessionHrrWrites] /
/// [notifBout] are the DB writes + notification the caller applies.
class _DayBlocksOutput {
  final Map<String, dynamic> bundlePatch;
  final Map<String, dynamic> seriesPatch;
  final Map<String, dynamic> scalarPatch;
  final Map<String, dynamic> wake;
  final List<Map<String, dynamic>> suggestionsToPersist;
  final List<(String, double)> sessionHrrWrites;
  final ({int endSec, int durationMin})? notifBout;
  const _DayBlocksOutput({
    required this.bundlePatch,
    required this.seriesPatch,
    required this.scalarPatch,
    required this.wake,
    required this.suggestionsToPersist,
    required this.sessionHrrWrites,
    required this.notifBout,
  });
}

/// Result of the pure workout compute ([DerivationEngine._computeWorkouts]).
class _WorkoutCompute {
  final List<Map<String, dynamic>> boutJson;
  final double? hrrBpm;
  final List<(String, double)> sessionHrrWrites;
  final List<Map<String, dynamic>> suggestionsToPersist;
  final ({int endSec, int durationMin})? notifBout;
  const _WorkoutCompute({
    required this.boutJson,
    required this.hrrBpm,
    required this.sessionHrrWrites,
    required this.suggestionsToPersist,
    required this.notifBout,
  });
  const _WorkoutCompute.empty()
      : boutJson = const [],
        hrrBpm = null,
        sessionHrrWrites = const [],
        suggestionsToPersist = const [],
        notifBout = null;
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final vs = List<double>.from(xs)..sort();
  final mid = vs.length ~/ 2;
  return vs.length.isOdd ? vs[mid] : (vs[mid - 1] + vs[mid]) / 2;
}
