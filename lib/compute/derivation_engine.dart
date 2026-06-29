// DerivationEngine — the on-device compute COORDINATOR (MAIN ISOLATE).
//
// V2 flow (per trigger):
//   1. Decode ALL retained raw R24 into ONE continuous Substrate (one decode
//      point — substrate.dart). Raw is the canonical replayable ledger.
//   2. Segment the substrate into WAKE-TO-WAKE physiological days (the V2 day
//      model): each day is anchored on a detected WAKE (sleep offset); the sleep
//      that ends at wake W closes the prior day and its recovery is attributed
//      to the day STARTING at W. Date label = local date of the wake. Fallback:
//      noon-to-noon container flagged LOW_CONFIDENCE_RECOVERY when no sleep in
//      ~36 h, so a day always exists when there's data.
//   3. For each day that is NOT finalized and needs (re)compute: slice the
//      substrate to the day + to the SLEEP window (from segmentSleep), build the
//      serialized DayBundleInput, and run the PURE pipeline OFF-isolate
//      (Isolate.run, per-day timeout). HRV/RHR/recovery run over the sleep
//      window; strain over wake; the sleep section is ENTIRELY the one
//      segmentSleep result.
//   4. Write each bundle → versioned day_result(day_id, algo_version, …) +
//      metric_series + refresh baselines. Finalization: a day locks 48 h after
//      its wake. algo_version bump → recompute non-finalized recent days.
//   5. Prune raw older than rawRetentionDays — never for a day not yet derived.
//
// INVARIANTS:
//   * A finalized day is IMMUTABLE w.r.t. its RAW-derived STRUCTURE — sleep
//     stages, the hypnogram, HR/HRV curves, wear/restlessness, detected workouts
//     are deterministic functions of the (now-pruned) raw and never change once
//     finalized. `run()` never recomputes a finalized day.
//   * The ONE exception is `rescanRecent()` (background re-trigger):
//     baseline-DEPENDENT SCALARS (readiness/recovery, illness/anomaly, stress
//     — anything computed against the trailing 28-day rolling baseline) DO drift
//     after a day finalizes, because later days shift that baseline. rescanRecent
//     re-derives recent days (incl. finalized ones inside the raw-retention
//     window) ONLY when the baseline signature actually changed, overwriting the
//     row at the SAME algo_version (putDayResult is INSERT OR REPLACE). The
//     raw-derived structure recomputes to the SAME values (deterministic); only
//     the baseline-relative scalars refresh. Days older than the raw-retention
//     window aren't in the substrate, so they're naturally excluded — expected.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import 'crossday_pipeline.dart';
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
// Strain Coach (recovery-gated target), VO₂max + WHOOP-Age, all in the crossday
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
const int kAlgoVersion = 24;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 14;

/// A day stays recomputable for this long after its wake, then FINALIZES (locks)
/// — more flash may still drain within this buffer (ARCHITECTURE_V2: ~48 h).
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;

/// Background re-trigger window: how far back from the DATA EDGE a
/// baseline-dirty rescan re-derives days (including finalized ones). Kept ≤ the
/// raw-retention window so every day in scope still has raw to re-derive from;
/// older days simply aren't in the substrate and are naturally excluded.
const int _rescanWindowDays = 21;

class DerivationEngine {
  DerivationEngine({this.log});
  final void Function(String)? log;

  bool _running = false;
  bool get running => _running;

  /// Run a derivation pass. [heavy]=false runs a bounded light pass (only the
  /// most-recent affected day); [heavy]=true sweeps every recomputable day.
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
    try {
      // 1. ONE decode of all retained raw → one continuous Substrate.
      final hexes = await LocalDb.allRawHexByRecTs();
      if (hexes.isEmpty) {
        _log('derive: no raw');
        return 0;
      }
      final sub = decodeSubstrate(hexes);
      if (sub.isEmpty) {
        _log('derive: substrate empty after decode');
        return 0;
      }

      // 2. Wake-to-wake physiological days.
      final days = calendarDays(sub);
      if (days.isEmpty) {
        _log('derive: no physiological days');
        return 0;
      }

      // 3. Which days to compute. Skip FINALIZED days entirely. Among the rest,
      //    a light pass does only the newest; heavy/force do all recomputable.
      //
      //    "now" for finalization/retention is the DATA EDGE — the timestamp of
      //    the last record we actually drained — NOT the wall clock. The band
      //    buffers in flash and drains on sync, so wall-clock time is irrelevant:
      //    a day only stops accepting more flash once we have CONTINUOUS data
      //    >48 h past its wake. Wall-clock would lock days the instant a long-
      //    offline band syncs (every drained day is already "old"), before we've
      //    confirmed the drain reached past them. Data-edge can never run ahead
      //    of the data, so it can neither prematurely finalize nor over-prune.
      final dataNowSec = sub.lastTs!; // sub non-empty (guarded above)
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      final computable = <PhysioDay>[];
      for (final day in days) {
        if (finalized.contains(day.date)) continue; // locked
        computable.add(day);
      }
      if (computable.isEmpty) {
        _log('derive: all days finalized — nothing to do');
        await _pruneOldRaw(days, dataNowSec);
        return 0;
      }
      final todo = (heavy || force)
          ? computable
          : computable.sublist(computable.length - 1);
      _log('derive: ${todo.length}/${days.length} day(s) '
          '(${force ? "force" : heavy ? "heavy" : "light"}; v$kAlgoVersion)');

      // Personal cadence model (live 100 Hz pedometer) → tunes the 1 Hz daily
      // step ESTIMATE. Read once per pass and threaded into every day.
      final stepCalib = await LocalDb.getStepCalibration();

      var done = 0;
      for (var i = 0; i < todo.length; i++) {
        final day = todo[i];
        try {
          await _deriveDay(sub, day, profile, dataNowSec, stepCalib: stepCalib);
          done++;
        } catch (e) {
          _log('derive day ${day.date} FAILED/skipped: $e');
          await _markDaySkipped(day, dataNowSec);
        }
        onDayDone?.call(day.date, i + 1, todo.length);
      }

      // 4. Cross-day rollup + notifications (best-effort).
      await _runCrossDay(profile);
      await _runNotifications();
      // 5. Prune raw — never for a day still inside its raw window / un-derived.
      await _pruneOldRaw(days, dataNowSec);
      return done;
    } catch (e, st) {
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      _running = false;
    }
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
      // Decode the substrate + calendar days exactly like run().
      final hexes = await LocalDb.allRawHexByRecTs();
      if (hexes.isEmpty) {
        _log('rescan: no raw');
        return 0;
      }
      final sub = decodeSubstrate(hexes);
      if (sub.isEmpty) {
        _log('rescan: substrate empty after decode');
        return 0;
      }
      final days = calendarDays(sub);
      if (days.isEmpty) {
        _log('rescan: no physiological days');
        return 0;
      }

      // Baseline gate: compute the CURRENT signature and compare to the stored
      // one. Unchanged → nothing to refresh; bail cheaply (no redundant writes).
      final sig = await _baselineSignature();
      final prev = await LocalDb.getCursor('baseline_sig');
      if (sig == prev) {
        _log('baseline unchanged — rescan skipped');
        return 0;
      }

      // Baseline moved: re-derive every day whose wake (endSec) is within
      // _rescanWindowDays of the DATA EDGE — including FINALIZED days — so their
      // baseline-dependent scalars refresh. Days older than the raw-retention
      // window aren't in the substrate, so they're naturally excluded (expected:
      // their raw is pruned and they're past the rescan horizon anyway).
      final dataNowSec = sub.lastTs!; // sub non-empty (guarded above)
      final cutoffSec = dataNowSec - _rescanWindowDays * 86400;
      final todo = [for (final d in days) if (d.endSec >= cutoffSec) d];
      _log('rescan: baseline changed — re-deriving ${todo.length}/${days.length} '
          'recent day(s) (incl. finalized; v$kAlgoVersion)');

      final stepCalib = await LocalDb.getStepCalibration();

      var done = 0;
      for (var i = 0; i < todo.length; i++) {
        final day = todo[i];
        try {
          // _deriveDay's write path is putDayResult (INSERT OR REPLACE), so the
          // existing finalized row is OVERWRITTEN at the same algo_version. The
          // recomputed `finalized` flag stays true for a day already past its
          // 48 h horizon, so the day remains locked w.r.t. run() — only its
          // baseline-relative scalars change.
          await _deriveDay(sub, day, profile, dataNowSec, stepCalib: stepCalib);
          done++;
        } catch (e) {
          _log('rescan day ${day.date} FAILED/skipped: $e');
          // Do NOT mark-skipped here — a finalized day already has a good row;
          // overwriting it with a skip marker would DISCARD real structure.
        }
        onDayDone?.call(day.date, i + 1, todo.length);
      }

      // Cross-day rollup + notifications reflect the refreshed scalars.
      await _runCrossDay(profile);
      await _runNotifications();
      // Store the new signature so the next tick is a cheap no-op until it moves.
      await LocalDb.setCursor('baseline_sig', sig);
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
    Future<double?> med(String key) async {
      final rows = await LocalDb.metricSeries(key, limit: _baselineWindowDays);
      final vs = <double>[for (final r in rows) (r['value'] as num).toDouble()]
        ..sort();
      if (vs.isEmpty) return null;
      final mid = vs.length ~/ 2;
      return vs.length.isOdd ? vs[mid] : (vs[mid - 1] + vs[mid]) / 2;
    }

    String fmt(double? v) => v == null ? 'na' : (v * 100).round().toString();
    // metricSeries returns the OLDEST `limit` rows for the key; we only need a
    // stable function of the baseline window's distribution, so the median over
    // whatever rows exist is sufficient and deterministic.
    final rhr = await med('rhr');
    final rmssd = await med('rmssd');
    final temp = await med('skin_temp_adc');
    final resp = await med('resp_rate');
    final n = (await LocalDb.recentDayResults(_baselineWindowDays)).length;
    return 'v$kAlgoVersion|n$n|rhr${fmt(rhr)}|rmssd${fmt(rmssd)}'
        '|temp${fmt(temp)}|resp${fmt(resp)}';
  }

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress.
  static const Duration _perDayTimeout = Duration(seconds: 90);

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
    final stepCalib = await LocalDb.getStepCalibration();
    var done = 0;
    for (final day in days) {
      if (!dates.contains(day.date)) continue;
      try {
        await _deriveDay(sub, day, profile, dataNowSec,
            forceFinalize: true, stepCalib: stepCalib);
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
    await _runCrossDay(profile);
    await _runNotifications();
  }

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<void> _deriveDay(
      Substrate sub, PhysioDay day, Profile profile, int dataNowSec,
      {bool forceFinalize = false, ana.StepCalibration? stepCalib}) async {
    // Slice the substrate to the day container and to the SLEEP window.
    final daySub = sub.slice(day.startSec, day.endSec);
    final sleepSub = day.hasSleep
        ? sub.sliceIdx(day.sleepLoIdx, day.sleepHiIdx)
        : Substrate.empty;

    // Per-second 4-class stage labels (the single source): 'wake'|'light'|
    // 'deep'|'rem'. analytics' segmentSleep exposes the 4-class stream directly
    // (NREM split into Light/Deep via the LOW-CONFIDENCE HR-depth overlay); we
    // pass it through verbatim so the UI can render Light vs Deep. Fall back to
    // the 3-class enum (light = plain NREM) only if stages4 is unexpectedly empty.
    final hypno = day.sleep.stages4.isNotEmpty
        ? List<String>.from(day.sleep.stages4)
        : <String>[
            for (final s in day.sleep.stages)
              s == ana.SleepStage.wake
                  ? 'wake'
                  : (s == ana.SleepStage.rem ? 'rem' : 'light')
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

    final input = DayBundleInput(
      date: day.date,
      dayTsSec: daySub.tsSec,
      dayHr: daySub.hr,
      sleepTsSec: sleepSub.tsSec,
      sleepHr: sleepSub.hr,
      sleepRrTsMs: sleepSub.rrTsMs,
      sleepRrMs: sleepSub.rrMs,
      sleepSpo2Red: sleepSub.spo2Red,
      sleepSpo2Ir: sleepSub.spo2Ir,
      sleepSkinTemp: sleepSub.skinTemp,
      sleepJson: day.sleep.toJson(),
      hypnoStages: hypno,
      sleepOnsetSec: onsetSec,
      sleepOffsetSec: offsetSec,
      profile: profile.toMap(),
      dayConfidence: day.confidence,
      dayFlags: day.flags,
    );
    final withHistory = await _attachHistory(input);

    final bundle = await Isolate.run(() => deriveDayBundle(withHistory))
        .timeout(_perDayTimeout);

    // NOTE: deriveDayBundle's `scalars` literal is all-double? → Dart infers it
    // as Map<String, double?>. Writing a bare int here throws "int is not a
    // subtype of double?". Store as a double (sc() reads it via toDouble anyway).
    final scMap = (bundle['scalars'] as Map?)?.cast<String, dynamic>();

    // ── STEPS (real 100 Hz + 1 Hz estimate) + TOTAL DAILY ENERGY (TDEE) ───────
    // Pull the day's 100 Hz coverage windows (device-time sec) + their real step
    // count so _stepsAndEnergy can prefer them and estimate only the rest.
    final dayLo = daySub.length == 0 ? 0 : daySub.tsSec.first;
    final dayHi = daySub.length == 0 ? 0 : daySub.tsSec.last + 60;
    final coverageWindows =
        await LocalDb.coverageWindowsOverlapping(dayLo, dayHi);
    final liveStepsReal = await LocalDb.liveStepsForDay(day.date);
    _stepsAndEnergy(bundle, scMap, daySub, profile, coverageWindows,
        liveStepsReal, stepCalib);

    // ── More substrate-derived detail blocks (computed here, where the full
    //    sliced substrate lives — same pattern as activeMin; these are fresh
    //    <String,dynamic> blocks so ints are safe, unlike the double? scalars). ─
    bundle['wear'] = _wearBlock(daySub); // on/off-wrist segments
    bundle['daytime_hrv'] = _daytimeHrv(daySub, onsetSec, offsetSec); // waking RMSSD
    // ALL-DAY HRV line (epoch-stamped rolling RMSSD over the day's 24/7 RR) for
    // the Timeline graph. Distinct from the sleep-only `series.hrv_timeline`
    // (recovery) — daytime HRV reflects autonomic/stress state and IS movement-
    // confounded, so it's a context line, not the recovery RMSSD. Computed here
    // where the day-wide substrate RR lives (the bundle input carries sleep RR
    // only). Epoch timestamps, so the graph needs no rebasing.
    final sersMap = (bundle['series'] as Map?)?.cast<String, dynamic>();
    sersMap?['hrv_day'] = _dayHrvCurve(daySub);
    sersMap?['resp_day'] = _dayRespCurve(daySub); // all-day rolling RSA br/min
    sersMap?['skin_temp_day'] = _daySkinTempCurve(daySub); // relative ADC trend
    bundle['restlessness'] = _restlessness(sleepSub); // nocturnal movement
    bundle['sleep_periods'] = _sleepPeriods(daySub, onsetSec, offsetSec); // naps
    // Principled daytime NAPS (van Hees immobility + HR-dip, analytics module).
    // Richer per-nap {start,end,duration,confidence} than _sleepPeriods, and a
    // `nap_min` scalar that feeds the Sleep Coach's nap credit + the Timeline.
    _attachNaps(bundle, scMap, daySub, onsetSec, offsetSec);
    // Per-5-min movement-level curve for the "Your day" Movement view ([{t,v}],
    // v = fraction of moving seconds 0..1). Fresh top-level list — no typed-map.
    bundle['activity_curve'] = _activityCurve(daySub);

    // ── AUTO-DETECTED WORKOUTS (WorkoutDetector, 1 Hz HR + gravity) ──────────
    // Retroactive bout detection over the day's HR + gravity (lives in daySub,
    // not the bundle input). Per-bout strain/zones/calories via the analytics
    // family. OVERLAP-DEDUP: any manual/live session for this day is passed as a
    // saved span so a detected bout overlapping it is dropped (manual wins). The
    // sport seam stays default ("detected") — OpenStrap's HAR typer can be wired
    // in once high-rate accel features exist.
    bundle['detected_workouts'] =
        await _detectedWorkouts(daySub, day, profile);

    // ── ADVANCED SLEEP (4-class Cole–Kripke + DoG/percentile stager) ─────────
    // A richer, AASM-style sleep read (SOL / REM-latency / disturbances + a
    // 4-class hypnogram) computed over the day substrate (needs accel, which
    // lives here, not in the bundle input). ADDITIVE: the canonical single-source
    // `sleep` block (from segmentSleep) is the headline; this is a parallel
    // ESTIMATE detail. Best-effort — never throws.
    bundle['advanced_sleep'] = await _advancedSleep(daySub);

    // Finalize once the DATA EDGE has moved >48 h past the day's wake — i.e. we
    // have continuous drained data well beyond it, so no more flash can land for
    // this day. (Anchored on the last record ts, NOT the wall clock.) Imports
    // force-finalize: there is no stored raw to ever recompute them from.
    final finalized =
        forceFinalize || (day.endSec + _finalizationSec) < dataNowSec;

    final scalars = (bundle['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    double? sc(String k) => (scalars[k] as num?)?.toDouble();
    await LocalDb.putDayResult(
      dayId: day.date,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(bundle),
      windowJson: jsonEncode(day.sleep.window?.toJson() ?? const {}),
      finalized: finalized,
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
      },
    );
    await _refreshBaselines();
    _log('derived ${day.date} v$kAlgoVersion '
        '(sleep=${day.hasSleep}, final=$finalized)');
  }

  /// Persist a minimal skip marker so a pathological day isn't retried forever.
  Future<void> _markDaySkipped(PhysioDay day, int dataNowSec) async {
    try {
      await LocalDb.putDayResult(
        dayId: day.date,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': 'timeout_or_error'}),
        windowJson: '{}',
        finalized: (day.endSec + _finalizationSec) < dataNowSec,
      );
    } catch (_) {/* best-effort */}
  }

  /// Attach trailing personal history (from metric_series) for the readiness pass.
  Future<Map<String, dynamic>> _attachHistory(DayBundleInput input) async {
    Future<List<double>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key, limit: _baselineWindowDays);
      return [for (final r in rows) (r['value'] as num).toDouble()];
    }

    final m = input.toJson();
    m['ln_rmssd_history'] = await hist('ln_rmssd');
    m['rhr_history'] = await hist('rhr');
    m['resp_history'] = await hist('resp_rate');
    // Robust nocturnal RMSSD history (the `rmssd` series) — feeds the EWMA hrv
    // baseline so its center matches today's headline RMSSD (same metric).
    m['rmssd_history'] = await hist('rmssd');
    // BASELINE for skin_temp_z is the RAW nightly ADC-mean series (`skin_temp_adc`),
    // NOT the z-score series. Feeding z-scores back as the baseline was a unit
    // mismatch that left z permanently null. The raw mean is stored every day so
    // this series fills and z starts computing once ≥3 days exist.
    m['skin_temp_adc_history'] = await hist('skin_temp_adc');
    return m;
  }

  // ── cross-day rollup ─────────────────────────────────────────────────────────

  static const Duration _crossDayTimeout = Duration(seconds: 30);
  static const int _crossDayWindow = 90;

  Future<void> _runCrossDay(Profile profile) async {
    try {
      final rows = await LocalDb.recentDayResults(_crossDayWindow);
      final days = <Map<String, dynamic>>[];
      for (final row in rows.reversed) {
        final payload = _decodeBundle(row['payload_json']);
        if (payload == null) continue;
        if (payload['skipped'] == true) continue;
        final rec = _crossDayRecord(row, payload);
        if (rec != null) days.add(rec);
      }
      if (days.length < 3) {
        _log('crossday: only ${days.length} usable day(s) — skip');
        return;
      }
      final profileMap = profile.toMap();
      final bundle = await Isolate.run(
        () => buildCrossDayBundle(days, profileMap),
      ).timeout(_crossDayTimeout);
      await LocalDb.putBaseline('crossday', jsonEncode(bundle));
      _log('crossday: stored over ${days.length} day(s)');
    } catch (e) {
      _log('crossday FAILED/skipped: $e');
    }
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
      date ??= (illness?['date'] ?? anomaly?['date'] ?? temp?['date']) as String?;
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
      }) =>
          NotificationCenter.instance.emit(NotificationEvent(
            dedupeKey: '$date:$kind',
            category: category,
            priority: priority,
            title: title,
            body: body,
            date: date!,
            route: route,
          ));
      if (illness != null && illness['state'] == 'red') {
        await emit('illness', 'Possible illness onset',
            'Elevated resting HR + suppressed HRV over recent nights.',
            route: '/heart');
      }
      if (anomaly != null && anomaly['flagged'] == true) {
        await emit('anomaly', 'Unusual overnight physiology',
            'Your nightly signals deviate from your personal baseline.',
            route: '/heart');
      }
      if (temp != null && temp['flag'] == 'elevated') {
        await emit('temp', 'Skin temperature elevated',
            'Sustained rise vs your baseline — a possible illness signal.',
            route: '/body');
      }
      final score = gb?['value'] is Map ? (gb!['value'] as Map)['score'] : null;
      if (score is num && score < 34) {
        await emit('readiness', 'Low readiness today',
            'Your recovery markers are below your usual range — ease off.',
            category: NotifCategory.recovery,
            priority: NotifPriority.normal,
            route: '/today');
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
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    final date = row['day_id'] as String?;
    if (date == null || date.isEmpty) return null;
    final scalars = (payload['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
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
      // + VO₂max/WHOOP-Age in the cross-day rollup.
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

  /// Refresh rolling baselines from the latest day_result rows (cheap: columns).
  Future<void> _refreshBaselines() async {
    final recent = await LocalDb.recentDayResults(_baselineWindowDays);
    double? avg(String col) {
      final vs = [
        for (final r in recent)
          if (r[col] != null) (r[col] as num).toDouble()
      ];
      if (vs.isEmpty) return null;
      return vs.reduce((a, b) => a + b) / vs.length;
    }

    await LocalDb.putBaseline(
      'rolling',
      jsonEncode({
        'rhr': avg('rhr'),
        'rmssd': avg('rmssd'),
        'readiness': avg('readiness'),
        'n': recent.length,
      }),
    );
  }

  // ── raw pruning (raw-first invariant) ──────────────────────────────────────

  /// Prune raw older than [rawRetentionDays] BEHIND THE DATA EDGE. Retention is
  /// measured against the last record timestamp we actually drained
  /// ([dataNowSec]), never the wall clock, and rows are deleted by their record
  /// time (`rec_ts`), never receive time (`captured_at`) — a multi-day flash
  /// backfill received in one sync must not be pruned just because it landed
  /// "now". Guard: never prune while any day in [days] is NOT yet derived at the
  /// current algo version (raw-first).
  Future<void> _pruneOldRaw(List<PhysioDay> days, int dataNowSec) async {
    final derivedIds = await LocalDb.dayResultIds(kAlgoVersion);
    final pending = days.where((d) => !derivedIds.contains(d.date)).toList();
    if (pending.isNotEmpty) {
      _log('prune skipped — ${pending.length} day(s) not yet derived');
      return;
    }
    final cutoffSec = dataNowSec - rawRetentionDays * 86400;
    if (cutoffSec <= 0) return;
    final deleted = await LocalDb.pruneRawBeforeRecTs(cutoffSec);
    if (deleted > 0) _log('pruned $deleted raw rows with rec_ts < $cutoffSec');
  }


  /// STEPS (hybrid: real 100 Hz count + bounded 1 Hz estimate) + total daily
  /// energy (TDEE), written into the bundle's `steps` block + `scalars`.
  ///
  /// Steps = [liveStepsReal] (AN-2554 over the band's 100 Hz windows — the real
  /// count, always preferred) + a 1 Hz estimate over the minutes those windows do
  /// NOT cover ([coverageWindows], device-time sec). So a minute is counted by
  /// 100 Hz OR estimated by 1 Hz, never both. TDEE = HR-flex (Mifflin BMR floor +
  /// active Keytel surplus). Best-effort.
  void _stepsAndEnergy(
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
      // Per-minute ENMO over the whole day (van Hees), and per-minute mean HR
      // aligned 1:1 to those minutes (for the walking HR-gate).
      final motion = ana.enmoSeries(daySub.accelSamples()).minutes;
      if (motion.isEmpty) return;
      final hrByMin = <int, List<double>>{};
      final allHrByMin = <int, List<double>>{};
      for (var i = 0; i < daySub.length; i++) {
        final h = daySub.hr[i];
        if (h <= 0) continue;
        final mi = daySub.tsSec[i] ~/ 60;
        (hrByMin[mi] ??= <double>[]).add(h.toDouble());
        (allHrByMin[mi] ??= <double>[]).add(h.toDouble());
      }
      double meanOf(List<double> l) => l.reduce((a, b) => a + b) / l.length;
      final hrPerMin = <double>[
        for (final mm in motion)
          () {
            final l = hrByMin[(mm.tsMinStartMs / 60000).round()];
            return (l == null || l.isEmpty) ? 0.0 : meanOf(l);
          }()
      ];

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
        'estimated_1hz': estSteps, // walking-min × cadence for uncovered minutes
        'ambulatory_min': est.present ? est.value!.ambulatoryMinutes : 0,
        'cadence_used_spm': est.present ? est.value!.cadenceUsed : 0,
        'confidence': liveStepsReal > 0 ? 0.7 : (est.present ? est.confidence : 0.2),
        'tier': liveStepsReal > 0 && estSteps == 0 ? 'HIGH' : 'ESTIMATE',
        'inputs_used': const ['live_100hz_pedometer', 'enmo_1hz', 'hr_1hz'],
        'note': 'real 100 Hz count for streamed time + 1 Hz walking estimate for '
            'the rest (1 Hz cannot count steps directly)',
      };

      // Total daily energy (TDEE) — HR-flex over the day's per-minute HR.
      if (profile.isComplete) {
        final perMinFull = <double>[
          for (final mi in (allHrByMin.keys.toList()..sort()))
            meanOf(allHrByMin[mi]!)
        ];
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
          'note': 'total daily energy: Mifflin BMR floor + active Keytel surplus '
              '(HR-flex)',
        };
      }
    } catch (e) {
      _log('steps/energy skipped: $e');
    }
  }

  /// Auto-detected workouts for the day via [ana.WorkoutDetector] over the
  /// day's 1 Hz HR + gravity. Returns a list of per-bout maps (each bout's
  /// avg/peak HR, duration, zone time-%, strain, calories, sport). Manual/live
  /// sessions overlapping the day are passed as saved spans so an overlapping
  /// detected bout is dropped (OVERLAP-DEDUP; manual wins). Empty list when no
  /// bout qualifies. Never throws — best-effort, like the other detail blocks.
  Future<List<Map<String, dynamic>>> _detectedWorkouts(
      Substrate s, PhysioDay day, Profile profile) async {
    try {
      if (s.length < 60) return const [];
      // Saved/manual spans for this calendar day → overlap-dedup.
      final saved = <ana.SavedWorkoutSpan>[];
      final rows = await LocalDb.sessionsInRange(day.startSec, day.endSec);
      for (final r in rows) {
        final st = (r['start_ts'] as num?)?.toInt();
        final en = (r['end_ts'] as num?)?.toInt() ??
            (r['start_ts'] as num?)?.toInt();
        if (st != null && en != null) {
          saved.add(ana.SavedWorkoutSpan(st, en));
        }
      }
      // Calorie sex string: 'm'→male, 'f'→female, else nonbinary.
      final sexStr = profile.sex == 'm'
          ? 'male'
          : (profile.sex == 'f' ? 'female' : 'nonbinary');
      final prof = profile.isComplete
          ? ana.WorkoutUserProfile(
              weightKg: profile.weightKg!,
              heightCm: profile.heightCm!,
              age: profile.ageYears!.toDouble(),
              sex: sexStr,
            )
          : null;
      final sessions = ana.WorkoutDetector.detect(
        hrTs: s.tsSec,
        hrBpm: [for (final h in s.hr) h.toDouble()],
        gravTs: s.tsSec,
        gx: s.ax,
        gy: s.ay,
        gz: s.az,
        maxHR: profile.hrMaxTanaka,
        restingHR: profile.restingHrManual?.toDouble(),
        age: profile.ageYears?.toDouble(),
        profile: prof,
        savedSpans: saved,
      );
      // Type each bout with the transparent rule classifier (1 Hz: amplitude +
      // HR pattern; honest low-confidence ceiling, label can stay cardio_other).
      return [
        for (final w in sessions)
          () {
            final j = w.toJson();
            final st = (j['start'] as num?)?.toInt();
            final en = (j['end'] as num?)?.toInt();
            if (st != null && en != null && en > st) {
              final pred = _classifyBout(s, st, en,
                  (j['avg_hr'] as num?)?.toDouble() ?? 0,
                  (j['peak_hr'] as num?)?.toDouble() ?? 0);
              j['sport'] = pred.sport;
              j['sport_confidence'] = pred.confidence;
            }
            return j;
          }()
      ];
    } catch (e) {
      _log('detected-workouts ${day.date} skipped: $e');
      return const [];
    }
  }

  /// Transparent sport typing for one bout: mean per-second gravity-delta
  /// (1 Hz amplitude) + within-bout HR variability → ruleSportPrediction. Pure
  /// over the day substrate slice [startSec, endSec).
  ana.SportPrediction _classifyBout(
      Substrate s, int startSec, int endSec, double avgBpm, double peakBpm) {
    var prevMag = 0.0;
    var havesPrev = false;
    var deltaSum = 0.0;
    var nDelta = 0;
    final hrs = <double>[];
    for (var i = 0; i < s.length; i++) {
      final t = s.tsSec[i];
      if (t < startSec || t >= endSec) continue;
      final mag = math.sqrt(s.ax[i] * s.ax[i] + s.ay[i] * s.ay[i] + s.az[i] * s.az[i]);
      if (havesPrev) {
        deltaSum += (mag - prevMag).abs();
        nDelta++;
      }
      prevMag = mag;
      havesPrev = true;
      if (s.hr[i] > 0) hrs.add(s.hr[i].toDouble());
    }
    final meanIntensity = nDelta > 0 ? deltaSum / nDelta : 0.0;
    double? hrCv;
    if (hrs.length >= 3) {
      final m = hrs.reduce((a, b) => a + b) / hrs.length;
      if (m > 0) {
        var v = 0.0;
        for (final h in hrs) {
          v += (h - m) * (h - m);
        }
        hrCv = math.sqrt(v / hrs.length) / m;
      }
    }
    return ana.RuleSportClassifier.classify(
        ana.SportFeatures(meanIntensity: meanIntensity, hrCv: hrCv));
  }

  /// Advanced 4-class sleep over the day substrate via [ana.AdvancedSleepStager]
  /// (Cole–Kripke sleep/wake spine + DoG HR-variability + percentile-band
  /// classifier + median/physiology smoothing). Returns the MAIN sleep session's
  /// AASM metrics (TST/SOL/REM-latency/WASO/disturbances + per-stage minutes) and
  /// a 4-class hypnogram. ADDITIVE — the canonical `sleep` block stays the
  /// single source; this is a parallel ESTIMATE. `{present:false}` when no
  /// qualifying sleep / insufficient data. Never throws (best-effort detail).
  Future<Map<String, dynamic>> _advancedSleep(Substrate s) async {
    try {
      if (s.length < 600) return const {'present': false};
      // Snapshot the primitive arrays (sendable) and run the heavy detect+stage
      // pipeline OFF the main isolate so a heavy/rescan sweep never janks the UI.
      final ts = s.tsSec, hr = s.hr, ax = s.ax, ay = s.ay, az = s.az;
      final rrTs = s.rrTsMs, rrMs = s.rrMs;
      final tz = DateTime.now().timeZoneOffset.inSeconds;
      return await Isolate.run(() {
        final grav = <ana.GravTs>[
          for (var i = 0; i < ts.length; i++) ana.GravTs(ts[i], ax[i], ay[i], az[i])
        ];
        final hrTs = <ana.HrTs>[
          for (var i = 0; i < ts.length; i++)
            if (hr[i] > 0) ana.HrTs(ts[i], hr[i].toDouble())
        ];
        // Sparse RR anchored at each beat's record second.
        final rr = <ana.RrTs>[
          for (var i = 0; i < rrMs.length; i++)
            ana.RrTs((rrTs[i] / 1000).round(), rrMs[i])
        ];
        final m = ana.AdvancedSleepStager.mainSleep(grav, hrTs,
            rr: rr, tzOffsetSec: tz);
        if (!m.present) {
          return <String, dynamic>{'present': false, 'note': m.note};
        }
        final sess = m.value!;
        final hm = ana.AdvancedSleepStager.hypnogramMetrics(sess);
        return <String, dynamic>{
          'present': true,
          'start': sess.start,
          'end': sess.end,
          'efficiency': sess.efficiency,
          'resting_hr': sess.restingHr,
          'avg_hrv': sess.avgHrv,
          'confidence': m.confidence,
          'tier': m.tier,
          'metrics': hm.toJson(),
          'hypnogram': [for (final st in sess.stages) st.toJson()],
        };
      }).timeout(_perDayTimeout);
    } catch (e) {
      _log('advanced-sleep skipped: $e');
      return const {'present': false};
    }
  }

  /// Per-5-min movement-level curve over the whole day ([{t, v}], v = fraction
  /// of seconds in the bucket with a ≥5° wrist-orientation change, 0..1). The
  /// honest 1 Hz movement signal (same basis as active-minutes) for the "Your
  /// day" Movement view. Sleep is NOT excluded — the curve naturally dips there.
  List<Map<String, dynamic>> _activityCurve(Substrate s) {
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

  /// On/off-wrist segments over the day (on = hr>0): the runs, first/last on,
  /// longest off gap, worn minutes + time-coverage. All from the day HR.
  Map<String, dynamic> _wearBlock(Substrate s) {
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
    final segments = <Map<String, dynamic>>[];
    int? firstOn, lastOn;
    var longestOff = 0, wornSec = 0;
    var i = 0;
    while (i < n) {
      final on = s.hr[i] > 0;
      var j = i;
      while (j < n && (s.hr[j] > 0) == on) {
        j++;
      }
      final startTs = s.tsSec[i], endTs = s.tsSec[j - 1] + 1;
      segments.add({
        'on': on,
        'start': startTs,
        'end': endTs,
        'len_min': ((endTs - startTs) / 60).round(),
      });
      if (on) {
        firstOn ??= startTs;
        lastOn = endTs;
        wornSec += endTs - startTs;
      } else if (endTs - startTs > longestOff) {
        longestOff = endTs - startTs;
      }
      i = j;
    }
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
  List<Map<String, num>> _dayHrvCurve(Substrate s) {
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
  List<Map<String, num>> _dayRespCurve(Substrate s) {
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
  List<Map<String, num>> _daySkinTempCurve(Substrate s) {
    final bins = <int, List<double>>{};
    for (var i = 0; i < s.skinTemp.length && i < s.tsSec.length; i++) {
      final v = s.skinTemp[i];
      if (v > 0) (bins[s.tsSec[i] ~/ 300] ??= []).add(v.toDouble());
    }
    if (bins.length < 3) return const [];
    final keys = bins.keys.toList()..sort();
    final means = {
      for (final k in keys) k: bins[k]!.reduce((a, b) => a + b) / bins[k]!.length
    };
    final sorted = means.values.toList()..sort();
    final med = sorted[sorted.length ~/ 2];
    return [
      for (final k in keys)
        {'t': k * 300, 'v': double.parse((means[k]! - med).toStringAsFixed(1))}
    ];
  }

  Map<String, dynamic> _daytimeHrv(Substrate s, int onsetSec, int offsetSec) {
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
    final mean = means.isEmpty ? null : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  /// Nocturnal restlessness from sleep-window orientation change: minutes with
  /// movement, number of distinct movement bouts, longest still stretch (min).
  Map<String, dynamic> _restlessness(Substrate s) {
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
      final d = (ana.zAngle(s.ax[i], s.ay[i], s.az[i]) -
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
  Map<String, dynamic> _sleepPeriods(Substrate s, int onsetSec, int offsetSec) {
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
        final d = (ana.zAngle(s.ax[i], s.ay[i], s.az[i]) -
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
  void _attachNaps(Map<String, dynamic> bundle, Map<String, dynamic>? scMap,
      Substrate s, int onsetSec, int offsetSec) {
    try {
      final n = s.length;
      if (n < 60) return;
      final accel = <ana.AccelSample>[
        for (var i = 0; i < n; i++)
          ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i])
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
            }
        ],
        'count': naps.length,
        'confidence': m.confidence,
        'tier': m.tier,
        'inputs_used': m.inputs_used,
        'note': m.note,
      };
      final napMin =
          naps.fold<int>(0, (a, nap) => a + (nap.durationSec ~/ 60));
      scMap?['nap_min'] = napMin.toDouble();
    } catch (e) {
      _log('naps FAILED/skipped: $e');
    }
  }

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}
