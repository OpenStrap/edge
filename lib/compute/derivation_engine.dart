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
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_performance/firebase_performance.dart';

import '../data/db.dart';
import '../data/day_label.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/tap_router.dart' show kRouteWorkoutSuggestion;
import '../telemetry/telemetry_service.dart';
import 'crossday_pipeline.dart';
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
const int kAlgoVersion = 46;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 3;

/// A day stays recomputable for this long after its wake, then FINALIZES (locks)
/// — more flash may still drain within this buffer (ARCHITECTURE_V2: ~48 h).
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;

/// Test seam: the rolling baseline window the readiness computation actually
/// runs against, loaded exactly as production does. Exposed to assert the read
/// path ignores a polluted `rolling_artifact` and rebuilds from `metric_series`.
@visibleForTesting
Future<List<double>> debugBaselineWindow(String key) async =>
    (await _BaselineHistoryCache.load()).values(key);

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

class _BaselineHistoryCache {
  _BaselineHistoryCache(this._series);

  final Map<String, List<double>> _series;

  /// Load the rolling baseline window that feeds the readiness/illness
  /// computations. This ALWAYS rebuilds from `metric_series` — the canonical
  /// scalar store, keyed `(date, key)` with REPLACE, so it is structurally one
  /// value per day.
  ///
  /// We deliberately do NOT trust the persisted `rolling_artifact` for history.
  /// That artifact is written from an in-memory cache that [appendScalars] only
  /// appends to (no day identity), so repeated same-day re-derives could stack
  /// duplicate copies of today into the window; once enough slots matched, the
  /// readiness composite's robust z-score hit MAD=0 and went absent — the blank
  /// readiness ring. A polluted artifact is still valid JSON, so trusting it on
  /// read would let that pollution reach the computation on the first
  /// post-upgrade derive (and, when every day is finalized and `run()` does no
  /// work, forever). Rebuilding from the de-duplicated store on every load makes
  /// the read path immune and self-heals any already-polluted install.
  static Future<_BaselineHistoryCache> load() async {
    Future<List<double>> hist(String key) =>
        LocalDb.trailingSeriesValues(key, _baselineWindowDays);

    final loaded = await Future.wait([
      hist('ln_rmssd'),
      hist('rmssd'),
      hist('rhr'),
      hist('resp_rate'),
      hist('skin_temp_adc'),
      hist('readiness'),
    ]);
    return _BaselineHistoryCache({
      'ln_rmssd': loaded[0],
      'rmssd': loaded[1],
      'rhr': loaded[2],
      'resp_rate': loaded[3],
      'skin_temp_adc': loaded[4],
      'readiness': loaded[5],
    });
  }

  List<double> values(String key) =>
      List<double>.from(_series[key] ?? const []);

  void appendScalars(Map<String, dynamic> scalars) {
    void add(String seriesKey, String scalarKey) {
      final v = (scalars[scalarKey] as num?)?.toDouble();
      if (v == null) return;
      final list = _series.putIfAbsent(seriesKey, () => <double>[]);
      list.add(v);
      while (list.length > _baselineWindowDays) {
        list.removeAt(0);
      }
    }

    add('ln_rmssd', 'ln_rmssd');
    add('rmssd', 'rmssd');
    add('rhr', 'rhr');
    add('resp_rate', 'resp_rate');
    add('skin_temp_adc', 'skin_temp_adc');
    add('readiness', 'readiness');
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

class DerivationEngine {
  DerivationEngine({this.log});
  final void Function(String)? log;

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
      final overrideDays = await LocalDb.sleepOverrideDays();
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
      }
      return done;
    } catch (e, st) {
      _diag['last_error'] = '$e';
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
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
          }
        } catch (e) {
          _log('derive selected day $dayId FAILED/skipped: $e');
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
        }
        activeDays.remove(dayId);
        _diag['active_days'] = activeDays.toList();
        completed++;
        onDayDone?.call(dayId, completed, orderedDays.length);
      }

      await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);
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
    final daySub = await _loadSubstrateRange(
      dayStart,
      dayEnd - 1,
      dayId: dayId,
      stats: stats,
    );
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
    return candidate.toPreparedDay(daySub: daySub, sleepSub: sleepSub);
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
    final (candidateJson, updatedProfileJson) = await Isolate.run(() {
      try {
        ana.cardioUserProfile = profileJson == null
            ? null
            : ana.SleepUserProfile.fromJson(
                (jsonDecode(profileJson) as Map).cast<String, dynamic>());
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
      String? foldedJson;
      if (override == null) {
        final obs = ana.takeCardioObservations();
        if (obs.isNotEmpty) {
          obs.sort((a, b) => b.epochs.compareTo(a.epochs));
          final main = obs.first;
          if (main.epochs >= 120) {
            // require ≥60 min — not a nap
            final base = ana.cardioUserProfile ?? const ana.SleepUserProfile();
            foldedJson = jsonEncode(base.fold(main).toJson());
          }
        }
      }
      return (jsonEncode(candidate.toJson()), foldedJson);
    });
    final candidate = SleepSessionCandidate.fromJson(
        (jsonDecode(candidateJson) as Map).cast<String, dynamic>());
    if (override == null) {
      await LocalDb.putSleepSessionCandidate(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: candidateJson,
      );
      if (updatedProfileJson != null) {
        await LocalDb.putBaseline('sleep_user_profile', updatedProfileJson);
      }
    }
    return candidate;
  }

  /// Read the persisted per-user sleep profile (`baselines` key
  /// `sleep_user_profile`) as raw JSON, for passing into the staging worker
  /// isolate. Absent/corrupt ⇒ null (cold start). DB read stays on the main
  /// isolate (the DB owner); the worker reconstructs the profile from this JSON.
  Future<String?> _loadSleepUserProfileJson() async {
    final row = await LocalDb.baseline('sleep_user_profile');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    // Validate here (mirrors the cached-candidate guard above) so a corrupt
    // payload becomes a cold start, per this method's contract — rather than
    // throwing later inside the staging worker's `jsonDecode(...) as Map`.
    try {
      if (jsonDecode(raw) is Map) return raw;
    } catch (_) {
      // corrupt payload → null (cold start)
    }
    return null;
  }

  Future<Substrate> _loadSubstrateRange(
    int fromRecTs,
    int toRecTs, {
    required String dayId,
    _PrepareStats? stats,
  }) async {
    if (toRecTs < fromRecTs) return Substrate.empty;
    final port = ReceivePort();
    final isolate = await Isolate.spawn(derivationPrepareWorker, port.sendPort);
    final ready = Completer<SendPort>();
    final result = Completer<Substrate>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((message) async {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is Map && message['type'] == 'result') {
        final kind = message['kind']?.toString();
        if (kind == 'substrate') {
          final payload = ((message['payload'] as Map?) ?? const {})
              .cast<String, dynamic>();
          await sub.cancel();
          port.close();
          isolate.kill(priority: Isolate.immediate);
          result.complete(Substrate.fromJson(payload));
        }
        return;
      }
      if (message is Map && message['type'] == 'error') {
        await sub.cancel();
        port.close();
        isolate.kill(priority: Isolate.immediate);
        result.completeError(Exception(message['error']));
      }
    });
    final worker = await ready.future;
    worker.send(const {'type': 'config', 'mode': 'substrate'});
    try {
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
      return result.future;
    } catch (_) {
      await sub.cancel();
      port.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
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
      return _scopeForDays(rawDays, reason: 'full-history', fullHistory: true);
    }

    final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
    final pending = [
      for (final day in rawDays)
        if (!finalized.contains(day)) day,
    ];
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

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress.
  static const Duration _perDayTimeout = Duration(seconds: 90);

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
  /// real wall-clock speedup from the device's other cores. Capped
  /// conservatively — this is a phone doing background/foreground compute,
  /// not a server batch job — rather than using every available core.
  static const int _maxDeriveConcurrency = 3;

  int get _deriveConcurrency {
    try {
      return math.max(
        1,
        math.min(_maxDeriveConcurrency, Platform.numberOfProcessors),
      );
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

    final bundle = await Isolate.run(
      () => deriveDayBundle(withHistory),
    ).timeout(_perDayTimeout);
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
      final note = (diag['note'] as String?) ?? '';
      if (!note.startsWith('need_baseline')) {
        final summary = StringBuffer('readiness_absent');
        for (final key in ['hrv', 'rhr', 'resp', 'temp']) {
          final v = (diag[key] as Map?)?.cast<String, dynamic>();
          if (v == null) continue;
          summary.write(
              ' $key=${v['value'] == true ? 'Y' : 'n'}/${v['baseline_n']}');
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
      final coverageWindows =
          await LocalDb.coverageWindowsOverlapping(dayLo, dayHi);
      final liveStepsReal = await LocalDb.liveStepsForDay(day.date);
      final stepCalib = await LocalDb.getStepCalibration();
      final savedSessions = await LocalDb.sessionsInRange(dayLo, dayHi);

      // Built on THIS isolate so the Isolate.run closure captures only this plain
      // sendable object (never `this`, `day`, or `bundle`).
      final blocksInput = _DayBlocksInput(
        daySub: daySub,
        sleepSub: sleepSub,
        profile: profile,
        onsetSec: day.sleepOnsetSec,
        offsetSec: day.sleepOffsetSec,
        rhr: (scMap?['rhr'] as num?)?.toDouble(),
        maxHrUsed: (bundle['max_hr_used'] as num?)?.round(),
        coverageWindows: coverageWindows,
        liveStepsReal: liveStepsReal,
        stepCalib: stepCalib,
        savedSessions: savedSessions,
        date: day.date,
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
            dedupeKey: '${day.date}:auto_workout',
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
    final finalized = forceFinalize || (ageFinalized && secondHalfOk);

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
      finalized: finalized,
      partial: !secondHalfOk,
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
        // Steps = real 100 Hz count + 1 Hz estimate over uncovered minutes
        // (computed in _stepsAndEnergy; never double-counted).
        'steps': sc('steps'),
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
    history.appendScalars(scalars);
    _log(
      'derived ${day.date} v$kAlgoVersion '
      '(sleep=${day.sleepOffsetSec > day.sleepOnsetSec}, final=$finalized)',
    );
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

  /// Persist a minimal skip marker so a pathological day isn't retried forever.
  Future<void> _markDaySkipped(
    String dayId,
    int dayEndSec,
    int dataNowSec, {
    required String reason,
  }) async {
    try {
      await LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': reason}),
        windowJson: '{}',
        finalized: (dayEndSec + _finalizationSec) < dataNowSec,
        skipped: true,
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Attach trailing personal history (from metric_series) for the readiness pass.
  Map<String, dynamic> _attachHistory(
    DayBundleInput input,
    _BaselineHistoryCache history,
  ) {
    final m = input.toJson();
    m['ln_rmssd_history'] = history.values('ln_rmssd');
    m['rhr_history'] = history.values('rhr');
    m['resp_history'] = history.values('resp_rate');
    // Robust nocturnal RMSSD history (the `rmssd` series) — feeds the EWMA hrv
    // baseline so its center matches today's headline RMSSD (same metric).
    m['rmssd_history'] = history.values('rmssd');
    // BASELINE for skin_temp_z is the RAW nightly ADC-mean series (`skin_temp_adc`),
    // NOT the z-score series. Feeding z-scores back as the baseline was a unit
    // mismatch that left z permanently null. The raw mean is stored every day so
    // this series fills and z starts computing once ≥3 days exist.
    m['skin_temp_adc_history'] = history.values('skin_temp_adc');
    return m;
  }

  // ── cross-day rollup ─────────────────────────────────────────────────────────

  static const Duration _crossDayTimeout = Duration(seconds: 30);
  static const int _crossDayWindow = 90;

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
      final bundleJson = await Isolate.run(
        () => jsonEncode(buildCrossDayBundle(days, profileMap)),
      ).timeout(_crossDayTimeout);
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
        if (decoded is Map) {
          final rows = decoded['days'];
          if (rows is List) {
            return [
              for (final row in rows)
                if (row is Map) row.cast<String, dynamic>(),
            ];
          }
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
    final (days, json) = await Isolate.run(() {
      final days = <Map<String, dynamic>>[];
      for (final row in rows.reversed) {
        final payload = _decodeBundle(row['payload_json']);
        if (payload == null) continue;
        if (payload['skipped'] == true) continue;
        final rec = _crossDayRecord(row, payload);
        if (rec != null) days.add(rec);
      }
      return (days, jsonEncode({'algo_version': kAlgoVersion, 'days': days}));
    });
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

  static Map<String, dynamic>? _decodeBundle(Object? json) {
    if (json is! String) return null;
    try {
      final d = jsonDecode(json);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

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

  /// STEPS (hybrid: real 100 Hz count + bounded 1 Hz estimate) + total daily
  /// energy (TDEE), written into the bundle's `steps` block + `scalars`.
  ///
  /// Steps = [liveStepsReal] (AN-2554 over the band's 100 Hz windows — the real
  /// count, always preferred) + a 1 Hz estimate over the minutes those windows do
  /// NOT cover ([coverageWindows], device-time sec). So a minute is counted by
  /// 100 Hz OR estimated by 1 Hz, never both. TDEE = HR-flex (Mifflin BMR floor +
  /// active Keytel surplus). Best-effort.
  static void _stepsAndEnergy(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate daySub,
    Profile profile,
    List<List<int>> coverageWindows,
    int liveStepsReal,
    ana.StepCalibration? stepCalib,
  ) {
    try {
      if (daySub.length < 60) return;
      final motion = _motionMinutes(daySub);
      if (motion.isEmpty) return;
      final hrPerMin = _hrPerMinuteAligned(motion, daySub);

      // STEPS — hybrid, no double-count. Drop any minute already covered by a
      // 100 Hz window (real count wins), estimate steps for the rest from 1 Hz.
      bool covered(double tsMinStartMs) {
        final s = (tsMinStartMs / 1000).round();
        for (final w in coverageWindows) {
          if (s + 60 > w[0] && s < w[1]) return true;
        }
        return false;
      }

      final motionUn = <ana.MotionMinute>[];
      final hrUn = <double>[];
      for (var i = 0; i < motion.length; i++) {
        if (covered(motion[i].tsMinStartMs)) continue;
        motionUn.add(motion[i]);
        hrUn.add(hrPerMin[i]);
      }

      final rhr = (scMap?['rhr'] as num?)?.toDouble();
      final est = ana.dailyStepEstimate(
        motionUn,
        hrPerMin: hrUn,
        restingHr: rhr,
        calib: stepCalib,
      );
      final estSteps = est.present ? est.value!.steps : 0;
      final daySteps = liveStepsReal + estSteps;
      scMap?['steps'] = daySteps.toDouble();
      bundle['steps'] = <String, dynamic>{
        'value': daySteps,
        'real_100hz': liveStepsReal, // AN-2554 over live windows (real count)
        'estimated_1hz':
            estSteps, // walking-min × cadence for uncovered minutes
        'ambulatory_min': est.present ? est.value!.ambulatoryMinutes : 0,
        'cadence_used_spm': est.present ? est.value!.cadenceUsed : 0,
        'confidence': liveStepsReal > 0
            ? 0.7
            : (est.present ? est.confidence : 0.2),
        'tier': liveStepsReal > 0 && estSteps == 0 ? 'HIGH' : 'ESTIMATE',
        'inputs_used': const ['live_100hz_pedometer', 'enmo_1hz', 'hr_1hz'],
        'note':
            'real 100 Hz count for streamed time + 1 Hz walking estimate for '
            'the rest (1 Hz cannot count steps directly)',
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
    final age = profile.ageYears?.toDouble() ?? 30.0; // fallback age
    final weightKg = profile.weightKg ?? 70.0; // fallback weight
    final sex = profile.sex?.toLowerCase() ?? 'm'; // fallback sex
    final hrMax = 208 - 0.7 * age;
    // Fallback to 60.0 so new users (no baseline yet, no manual RHR) still get Strain
    final rhrForTrimp = restingHr ?? profile.restingHrManual?.toDouble() ?? 60.0;
    double? strain;
    double? calories;
    double? steps;
    double? caloriesTotal;
    Map<String, int> zones = const {};
    if (perMin.isNotEmpty) {
      if (dayHrValid.isNotEmpty) {
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
      zones = _wakeZoneMinutes(daySub, sleepOnsetSec, sleepOffsetSec, hrMax);
      // age/weightKg always have a value by this point (defaulted above), so
      // this used to be a dead "if (age != null && weightKg != null && ...)"
      // that flutter analyze flagged - there was never actually a gate here.
      calories = _keytelCaloriesWake(
        perMin,
        age,
        weightKg,
        hrMax,
        sex == 'f',
      );
    }
    if (motion.isNotEmpty) {
      final stepMetric = ana.dailyStepEstimate(
        motion,
        hrPerMin: hrPerMinAll,
        restingHr: rhrForTrimp,
      );
      if (stepMetric.present && stepMetric.value != null) {
        steps = stepMetric.value!.steps.toDouble();
      }
      // same story - age/weightKg can't be null here, heightCm is the only
      // field that actually still needs a null check.
      if (profile.heightCm != null) {
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
      'strain': strain,
      'calories': calories,
      'steps': steps,
      'calories_total': caloriesTotal,
      'wear_min': (wear['worn_min'] as num?)?.toDouble(),
      'activity': {
        'value': activeMin,
        'active_min': activeMin,
        'confidence': 0.6,
        'tier': 'ESTIMATE',
        'inputs_used': const ['accel_1hz'],
        'note':
            'active minutes (1 Hz ENMO over wake); 1 Hz cannot count steps — '
            'true step counts come from live workout streaming',
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
  static List<Map<String, num>> _dayHrvCurve(Substrate s) {
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
      if (i - lo >= 10) {
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
        if (nd >= 8 && ts[i] - lastEmit > 60000) {
          final rmssd = math.sqrt(ssd / nd);
          if (rmssd <= 220) {
            out.add({
              't': (ts[i] / 1000).round(),
              'v': double.parse(rmssd.toStringAsFixed(1)),
            });
            lastEmit = ts[i];
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
  static List<Map<String, num>> _dayRespCurve(Substrate s) {
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
        final est = ana.rsaRespRate(nn, nnt, artifactFraction: 0.15);
        final brpm = est.present ? est.value!.brpm : null;
        if (brpm != null) {
          out.add({
            't': (ts[i] / 1000).round(),
            'v': double.parse(brpm.toStringAsFixed(1)),
          });
          lastEmit = ts[i];
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

  /// Sleep periods: the main sleep + any NAPS (still, on-wrist minute-runs ≥20
  /// min OUTSIDE the main window). Conservative — naps need sustained stillness.
  static Map<String, dynamic> _sleepPeriods(Substrate s, int onsetSec, int offsetSec) {
    final periods = <Map<String, dynamic>>[];
    var totalAsleep = 0;
    if (offsetSec > onsetSec) {
      final mainMin = (offsetSec - onsetSec) ~/ 60;
      periods.add({
        'is_main': true,
        'start': onsetSec,
        'end': offsetSec,
        'asleep_min': mainMin,
      });
      totalAsleep += mainMin;
    }
    final n = s.length;
    if (n >= 60) {
      const moveDeg = 5.0;
      // Per-minute "still + on-wrist", excluding the main window.
      final still = <int, bool>{}; // minute → still
      final mTot = <int, int>{}, mMove = <int, int>{}, mOn = <int, int>{};
      for (var i = 1; i < n; i++) {
        final t = s.tsSec[i];
        if (offsetSec > onsetSec && t >= onsetSec && t < offsetSec) continue;
        final m = t ~/ 60;
        mTot[m] = (mTot[m] ?? 0) + 1;
        if (s.hr[i] > 0) mOn[m] = (mOn[m] ?? 0) + 1;
        final d =
            (ana.zAngle(s.ax[i], s.ay[i], s.az[i]) -
                    ana.zAngle(s.ax[i - 1], s.ay[i - 1], s.az[i - 1]))
                .abs();
        if (d > moveDeg) mMove[m] = (mMove[m] ?? 0) + 1;
      }
      final keys = mTot.keys.toList()..sort();
      for (final m in keys) {
        final tot = mTot[m] ?? 1;
        still[m] = (mMove[m] ?? 0) / tot < 0.10 && (mOn[m] ?? 0) / tot > 0.5;
      }
      // Runs of ≥20 contiguous still minutes → a nap.
      var i = 0;
      while (i < keys.length) {
        if (still[keys[i]] != true) {
          i++;
          continue;
        }
        var j = i;
        while (j < keys.length &&
            still[keys[j]] == true &&
            keys[j] - keys[i] == j - i) {
          j++;
        }
        final lenMin = j - i;
        if (lenMin >= 20) {
          final start = keys[i] * 60, end = keys[j - 1] * 60 + 60;
          periods.add({
            'is_main': false,
            'start': start,
            'end': end,
            'asleep_min': lenMin,
          });
          totalAsleep += lenMin;
        }
        i = j;
      }
    }
    return {'periods': periods, 'total_asleep_min': totalAsleep};
  }

  /// Principled daytime naps via the analytics `detectNaps` (van Hees immobility
  /// + HR-dip over the WAKE span, the main nocturnal window carved out). Writes a
  /// rich `naps` block (per-nap start/end epoch-sec + duration + confidence) and a
  /// `nap_min` scalar (total nap minutes) used by the Sleep Coach + Timeline.
  static void _attachNaps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    int onsetSec,
    int offsetSec,
  ) {
    try {
      final n = s.length;
      if (n < 60) return;
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
      final m = ana.detectNaps(accel, hr, mainSleep: main);
      final naps = m.value ?? const [];
      final t0 = s.tsSec.first;
      bundle['naps'] = <String, dynamic>{
        'value': [
          for (final nap in naps)
            {
              'start': t0 + nap.startSec,
              'end': t0 + nap.endSec,
              'duration_min': (nap.durationSec / 60).round(),
              'confidence': nap.confidence,
            },
        ],
        'count': naps.length,
        'confidence': m.confidence,
        'tier': m.tier,
        'inputs_used': m.inputs_used,
        'note': m.note,
      };
      final napMin = naps.fold<int>(0, (a, nap) => a + (nap.durationSec ~/ 60));
      scMap?['nap_min'] = napMin.toDouble();
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] naps FAILED/skipped: $e');
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
    );
    _applyWakeDayFeatures(bundlePatch, scMap, wake);
    _stepsAndEnergy(
      bundlePatch,
      scMap,
      daySub,
      inp.profile,
      inp.coverageWindows,
      inp.liveStepsReal,
      inp.stepCalib,
    );
    // _stepsAndEnergy just corrected `steps`/`calories_total` in bundlePatch +
    // scMap using the hybrid real-100Hz + 1Hz-estimate count, but `wake` (built
    // above by _buildWakeDayFeatures, before this correction ran) still holds
    // the earlier 1Hz-only estimate. `wake` is what _persistWakeDayFeatures
    // stores and what the Today repository reads while the full day result
    // isn't ready yet, so copy the corrected values back in to avoid serving
    // stale steps/calories from that early-read path.
    for (final key in const ['steps', 'calories_total']) {
      final value = scMap[key];
      if (value != null) wake[key] = value;
    }

    bundlePatch['daytime_hrv'] = _daytimeHrv(daySub, onset, offset);
    seriesPatch['hrv_day'] = _dayHrvCurve(daySub);
    seriesPatch['resp_day'] = _dayRespCurve(daySub);
    seriesPatch['skin_temp_day'] = _daySkinTempCurve(daySub);
    bundlePatch['restlessness'] = _restlessness(sleepSub);
    bundlePatch['sleep_periods'] = _sleepPeriods(daySub, onset, offset);
    _attachNaps(bundlePatch, scMap, daySub, onset, offset);
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

  (int, int) _targetDayWindow(String dayId) {
    final startSec = _localDayLabelToSec(dayId);
    final endSec = _localNextDayLabelToSec(dayId);
    return (math.max(0, startSec - 6 * 3600), endSec - 1);
  }

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}

/// Sendable input for [DerivationEngine._computeDayBlocks] — crosses the
/// `Isolate.run` boundary, so every field is plain data (Substrate is int/double
/// lists; Profile/StepCalibration are primitive data classes). DB reads that the
/// pure compute needs are performed by the caller and passed in here.
class _DayBlocksInput {
  final Substrate daySub;
  final Substrate sleepSub;
  final Profile profile;
  final int onsetSec;
  final int offsetSec;
  final double? rhr;
  final int? maxHrUsed;
  final List<List<int>> coverageWindows;
  final int liveStepsReal;
  final ana.StepCalibration? stepCalib;
  final List<Map<String, dynamic>> savedSessions;
  final String date;
  final int dayEndSec;
  final int dataNowSec;
  const _DayBlocksInput({
    required this.daySub,
    required this.sleepSub,
    required this.profile,
    required this.onsetSec,
    required this.offsetSec,
    required this.rhr,
    required this.maxHrUsed,
    required this.coverageWindows,
    required this.liveStepsReal,
    required this.stepCalib,
    required this.savedSessions,
    required this.date,
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
