// DerivationEngine — the on-device compute COORDINATOR (MAIN ISOLATE).
//
// Current flow (per trigger):
//   1. Decide WHICH calendar days need compute (force / pending span / latest
//      day + context).
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
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
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
const int kAlgoVersion = 28;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 14;

/// A day stays recomputable for this long after its wake, then FINALIZES (locks)
/// — more flash may still drain within this buffer (ARCHITECTURE_V2: ~48 h).
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;
const int _lightScopeDays = 3;

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

  static Future<_BaselineHistoryCache> load() async {
    final artifact = await LocalDb.baseline('rolling_artifact');
    final raw = artifact?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          List<double> histFromMap(Map<String, dynamic> map, String key) {
            final rows = map[key];
            if (rows is! List) return const [];
            return [
              for (final row in rows)
                if (row is num) row.toDouble(),
            ];
          }

          final map = decoded.cast<String, dynamic>();
          final series = ((map['series'] as Map?) ?? const {})
              .cast<String, dynamic>();
          return _BaselineHistoryCache({
            'ln_rmssd': histFromMap(series, 'ln_rmssd'),
            'rmssd': histFromMap(series, 'rmssd'),
            'rhr': histFromMap(series, 'rhr'),
            'resp_rate': histFromMap(series, 'resp_rate'),
            'skin_temp_adc': histFromMap(series, 'skin_temp_adc'),
            'readiness': histFromMap(series, 'readiness'),
          });
        }
      } catch (_) {
        // Fall back to metric_series rebuild.
      }
    }
    Future<List<double>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key, limit: _baselineWindowDays);
      return [for (final r in rows) (r['value'] as num).toDouble()];
    }

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
    'day_raw_pages': 0,
    'day_raw_rows': 0,
    'max_day_raw_pages': 0,
    'max_day_raw_rows': 0,
    'range_from_rec_ts': null,
    'range_to_rec_ts': null,
    'scope_days': 0,
    'scope_reason': null,
    'prepared_days': 0,
    'todo_days': 0,
    'done_days': 0,
    'skipped_days': 0,
    'active_day': null,
    'last_error': null,
  };

  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_diag);

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
      ..['day_raw_pages'] = 0
      ..['day_raw_rows'] = 0
      ..['max_day_raw_pages'] = 0
      ..['max_day_raw_rows'] = 0
      ..['range_from_rec_ts'] = null
      ..['range_to_rec_ts'] = null
      ..['scope_days'] = 0
      ..['scope_reason'] = null
      ..['prepared_days'] = 0
      ..['todo_days'] = 0
      ..['done_days'] = 0
      ..['skipped_days'] = 0
      ..['active_day'] = null
      ..['last_error'] = null;
    try {
      final scope = await _deriveScope(heavy: heavy, force: force);
      _diag
        ..['scope_days'] = scope.targetDays.length
        ..['scope_reason'] = scope.reason;
      final dataNowSec = await LocalDb.lastRawRecTs() ?? 0;
      if (dataNowSec <= 0) {
        _log('derive: no raw');
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
          await _pruneOldRaw(todoDays, dataNowSec);
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
        '${scope.reason}; v$kAlgoVersion)',
      );

      var done = 0;
      _diag['stage'] = 'per_day';
      for (var i = 0; i < todoDays.length; i++) {
        final dayId = todoDays[i];
        _diag['active_day'] = dayId;
        try {
          _diag['stage'] = 'prepare';
          final prepared = await _prepareTargetDay(dayId);
          // Override day whose raw has been pruned (≥14 d): re-deriving would
          // produce an empty/absent result and clobber the user's manual sleep.
          // Keep the existing locked result instead.
          if (prepared != null &&
              prepared.daySub.isEmpty &&
              overrideDays.contains(dayId)) {
            _log('derive day $dayId skipped: override day, raw pruned — kept');
            onDayDone?.call(dayId, i + 1, todoDays.length);
            continue;
          }
          if (prepared != null) {
            _diag['prepared_days'] = (_diag['prepared_days'] as int) + 1;
            _diag['stage'] = 'per_day';
            await _derivePreparedDay(prepared, profile, dataNowSec, history);
            done++;
            _diag['done_days'] = done;
          } else {
            _log('derive day $dayId skipped: no bounded window payload');
            await _markDaySkipped(
              dayId,
              _localDayLabelToSec(dayId) + 86400,
              dataNowSec,
              reason: 'no_bounded_window_payload',
            );
            _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
            _diag['last_error'] = 'no_bounded_window_payload day=$dayId';
          }
        } catch (e) {
          _log('derive day $dayId FAILED/skipped: $e');
          final dayEndSec = _localDayLabelToSec(dayId) + 86400;
          await _markDaySkipped(
            dayId,
            dayEndSec,
            dataNowSec,
            reason: _skipReasonForError(e),
          );
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
        }
        onDayDone?.call(dayId, i + 1, todoDays.length);
      }

      // 4. Cross-day rollup + notifications (best-effort).
      if (done > 0) {
        _diag['stage'] = 'baselines';
        await _refreshBaselines(history);
        _diag['stage'] = 'cross_day';
        await _runCrossDay(profile);
        _diag['stage'] = 'notifications';
        await _runNotifications();
      }
      // 5. Prune raw — never for a day still inside its raw window / un-derived.
      if (scope.fullHistory) {
        _diag['stage'] = 'prune';
        await _pruneOldRaw(todoDays, dataNowSec);
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
        ..['active_day'] = null
        ..['finished_at'] = finishedAt
        ..['duration_ms'] = finishedAt - startedAt;
    }
  }

  static const int _rawDecodeBatchSize = 2000;
  static const int _maxDayRawRows = 500000;
  static const int _maxDayRawPages = 300;

  Future<PreparedDerivationDay?> _prepareTargetDay(String dayId) async {
    _diag
      ..['day_raw_pages'] = 0
      ..['day_raw_rows'] = 0;
    _diag['stage'] = 'sleep_candidate';
    final candidate = await _sleepCandidateForDay(dayId);
    final dayStart = _localDayLabelToSec(dayId);
    final dayEnd = dayStart + 86400;
    _diag['stage'] = 'day_sub';
    final daySub = await _loadSubstrateRange(
      dayStart,
      dayEnd - 1,
      dayId: dayId,
    );
    Substrate sleepSub = Substrate.empty;
    if (candidate.present &&
        candidate.sleepOffsetSec > candidate.sleepOnsetSec) {
      _diag['stage'] = 'sleep_sub';
      sleepSub = await _loadSubstrateRange(
        candidate.sleepOnsetSec,
        candidate.sleepOffsetSec - 1,
        dayId: dayId,
      );
    }
    return candidate.toPreparedDay(daySub: daySub, sleepSub: sleepSub);
  }

  Future<SleepSessionCandidate> _sleepCandidateForDay(String dayId) async {
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
    );
    final candidate = prepareSleepSessionCandidate(
      searchSub,
      targetDay: dayId,
      override: override,
    );
    if (override == null) {
      await LocalDb.putSleepSessionCandidate(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode(candidate.toJson()),
      );
    }
    return candidate;
  }

  Future<Substrate> _loadSubstrateRange(
    int fromRecTs,
    int toRecTs, {
    required String dayId,
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
      _diag
        ..['range_from_rec_ts'] = fromRecTs
        ..['range_to_rec_ts'] = toRecTs;
      var usedDecoded = false;
      while (true) {
        final decodedRows = await LocalDb.decodedOneHzBatchByRecTsRange(
          limit: _rawDecodeBatchSize,
          fromRecTs: fromRecTs,
          toRecTs: toRecTs,
          afterRecTs: afterRecTs,
          afterCounter: afterCursor,
        );
        if (decodedRows.isNotEmpty) {
          usedDecoded = true;
          _trackPrepareBatch(decodedRows.length);
          rangePages += 1;
          rangeRows += decodedRows.length;
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
        if (usedDecoded) break;
        final rows = await LocalDb.rawHexBatchByRecTsRange(
          limit: _rawDecodeBatchSize,
          fromRecTs: fromRecTs,
          toRecTs: toRecTs,
          afterRecTs: afterRecTs,
          afterRowId: afterCursor,
        );
        if (rows.isEmpty) break;
        _trackPrepareBatch(rows.length);
        rangePages += 1;
        rangeRows += rows.length;
        _enforcePrepareBudget(
          dayId: dayId,
          fromRecTs: fromRecTs,
          toRecTs: toRecTs,
          rangePages: rangePages,
          rangeRows: rangeRows,
        );
        worker.send({
          'type': 'page',
          'hexes': [for (final row in rows) row['hex'] as String],
        });
        final last = rows.last;
        afterRecTs = (last['rec_ts'] as num?)?.toInt() ?? afterRecTs;
        afterCursor = (last['rowid'] as num?)?.toInt() ?? afterCursor;
        if (rows.length < _rawDecodeBatchSize) break;
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

  void _trackPrepareBatch(int rows) {
    _diag['raw_pages'] = (_diag['raw_pages'] as int) + 1;
    _diag['raw_rows'] = (_diag['raw_rows'] as int) + rows;
    _diag['day_raw_pages'] = (_diag['day_raw_pages'] as int) + 1;
    _diag['day_raw_rows'] = (_diag['day_raw_rows'] as int) + rows;
    if ((_diag['day_raw_pages'] as int) > (_diag['max_day_raw_pages'] as int)) {
      _diag['max_day_raw_pages'] = _diag['day_raw_pages'];
    }
    if ((_diag['day_raw_rows'] as int) > (_diag['max_day_raw_rows'] as int)) {
      _diag['max_day_raw_rows'] = _diag['day_raw_rows'];
    }
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
    final rawByDay = await LocalDb.rawRecTsMaxByDay();
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

    final latest = pending.last;
    final latestSec = _localDayLabelToSec(latest);
    final scoped = <String>[];
    for (var i = _lightScopeDays - 1; i >= 0; i--) {
      scoped.add(_localDateLabel(latestSec - i * 86400));
    }
    return _scopeForDays(scoped, reason: 'latest+context');
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

      final rawByDay = await LocalDb.rawRecTsMaxByDay();
      if (rawByDay.isEmpty) {
        _log('rescan: no raw');
        return 0;
      }
      final dataNowSec = await LocalDb.lastRawRecTs() ?? 0;
      if (dataNowSec <= 0) {
        _log('rescan: no data edge');
        return 0;
      }
      final cutoffSec = dataNowSec - _rescanWindowDays * 86400;
      final todoDays = [
        for (final dayId in rawByDay.keys)
          if ((_localDayLabelToSec(dayId) + 86400) >= cutoffSec) dayId,
      ]..sort();
      if (todoDays.isEmpty) {
        _log('rescan: no recent raw-backed days');
        await LocalDb.setCursor('baseline_sig', sig);
        return 0;
      }
      _log(
        'rescan: baseline changed — re-deriving ${todoDays.length} '
        'recent day(s) (incl. finalized; v$kAlgoVersion)',
      );

      final history = await _BaselineHistoryCache.load();
      var done = 0;
      for (var i = 0; i < todoDays.length; i++) {
        final dayId = todoDays[i];
        try {
          final prepared = await _prepareTargetDay(dayId);
          if (prepared == null) continue;
          await _derivePreparedDay(prepared, profile, dataNowSec, history);
          done++;
        } catch (e) {
          _log('rescan day $dayId FAILED/skipped: $e');
          // Do NOT mark-skipped here — a finalized day already has a good row;
          // overwriting it with a skip marker would DISCARD real structure.
        }
        onDayDone?.call(dayId, i + 1, todoDays.length);
      }

      await _refreshBaselines(history);
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
    await _refreshBaselines(await _BaselineHistoryCache.load());
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

    // Where this day's sleep window came from (auto / auto_fallback / manual /
    // confirmed) — drives the Sleep screen's "is this right?" prompt + the
    // manual-edit affordance. Carried verbatim from the segmentation candidate.
    bundle['sleep_source'] = day.sleepSource;

    final scMap = (bundle['scalars'] as Map?)?.cast<String, dynamic>();
    final wake = _buildWakeDayFeatures(
      daySub,
      profile,
      sleepOnsetSec: day.sleepOnsetSec,
      sleepOffsetSec: day.sleepOffsetSec,
      restingHr: (scMap?['rhr'] as num?)?.toDouble(),
    );
    _applyWakeDayFeatures(bundle, scMap, wake);

    // ── STEPS (real 100 Hz + 1 Hz estimate) + TOTAL DAILY ENERGY (TDEE) ───────
    // Pull the day's 100 Hz coverage windows (device-time sec) + their real step
    // count so _stepsAndEnergy can prefer them and estimate only the rest.
    final dayLo = daySub.length == 0 ? 0 : daySub.tsSec.first;
    final dayHi = daySub.length == 0 ? 0 : daySub.tsSec.last + 60;
    final coverageWindows = await LocalDb.coverageWindowsOverlapping(
      dayLo,
      dayHi,
    );
    final liveStepsReal = await LocalDb.liveStepsForDay(day.date);
    final stepCalib = await LocalDb.getStepCalibration();
    _stepsAndEnergy(
      bundle,
      scMap,
      daySub,
      profile,
      coverageWindows,
      liveStepsReal,
      stepCalib,
    );

    // ── More substrate-derived detail blocks (computed here, where the full
    //    sliced substrate lives — same pattern as activeMin; these are fresh
    //    <String,dynamic> blocks so ints are safe, unlike the double? scalars). ─
    bundle['daytime_hrv'] = _daytimeHrv(
      daySub,
      day.sleepOnsetSec,
      day.sleepOffsetSec,
    ); // waking RMSSD
    // ALL-DAY HRV / resp / skin-temp lines for the Timeline graph. Epoch-stamped
    // (rolling RMSSD, rolling RSA, relative skin-temp) over the day-wide 24/7
    // substrate RR/ADC — context lines, movement-confounded, not the recovery
    // values. Computed here where the day substrate lives.
    final sersMap = (bundle['series'] as Map?)?.cast<String, dynamic>();
    sersMap?['hrv_day'] = _dayHrvCurve(daySub);
    sersMap?['resp_day'] = _dayRespCurve(daySub);
    sersMap?['skin_temp_day'] = _daySkinTempCurve(daySub);
    bundle['restlessness'] = _restlessness(sleepSub); // nocturnal movement
    bundle['sleep_periods'] = _sleepPeriods(
      daySub,
      day.sleepOnsetSec,
      day.sleepOffsetSec,
    ); // naps
    // Principled daytime NAPS (van Hees immobility + HR-dip): rich per-nap block
    // + a `nap_min` scalar feeding the Sleep Coach's nap credit + the Timeline.
    _attachNaps(bundle, scMap, daySub, day.sleepOnsetSec, day.sleepOffsetSec);

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
    bundle['detected_workouts'] = await _detectedWorkouts(daySub, day, profile);

    // ── AUTO-WORKOUT SUGGESTIONS + HRR (opt-in detector over day HR+motion) ──
    // One pass of the opt-in detector serves two features: (1) persisted "did you
    // work out?" suggestions + a recent-day notification, and (2) heart-rate
    // recovery (HRR) per bout → `hrr_bpm` scalar. scMap writes through to
    // bundle['scalars'] (CastMap view), so hrr_bpm reaches the series block below.
    await _attachWorkoutSuggestionsAndHrr(bundle, scMap, daySub, day, dataNowSec);

    // ── WRIST ORIENTATION during sleep (low-confidence; NOT body position) ───
    _attachWristOrientation(
        bundle, daySub, day.sleepOnsetSec, day.sleepOffsetSec);

    // ── ADVANCED SLEEP (4-class Cole–Kripke + DoG/percentile stager) ─────────
    // A richer, AASM-style sleep read (SOL / REM-latency / disturbances + a
    // 4-class hypnogram) computed over the day substrate (needs accel, which
    // lives here, not in the bundle input). ADDITIVE: the canonical single-source
    // `sleep` block (from segmentSleep) is the headline; this is a parallel
    // ESTIMATE detail. Best-effort — never throws.
    bundle['advanced_sleep'] = await _advancedSleep(daySub);

    await _persistWakeDayFeatures(dayId: day.date, wake: wake);

    // Finalize once the DATA EDGE has moved >48 h past the day's wake — i.e. we
    // have continuous drained data well beyond it, so no more flash can land for
    // this day. (Anchored on the last record ts, NOT the wall clock.) Imports
    // force-finalize: there is no stored raw to ever recompute them from.
    final finalized =
        forceFinalize || (day.endSec + _finalizationSec) < dataNowSec;

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
      final bundle = await Isolate.run(
        () => buildCrossDayBundle(days, profileMap),
      ).timeout(_crossDayTimeout);
      await LocalDb.putBaseline('crossday', jsonEncode(bundle));
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
    final rows = await LocalDb.recentDayResults(_crossDayWindow);
    final days = <Map<String, dynamic>>[];
    for (final row in rows.reversed) {
      final payload = _decodeBundle(row['payload_json']);
      if (payload == null) continue;
      if (payload['skipped'] == true) continue;
      final rec = _crossDayRecord(row, payload);
      if (rec != null) days.add(rec);
    }
    await LocalDb.putBaseline(
      'crossday_input',
      jsonEncode({'algo_version': kAlgoVersion, 'days': days}),
    );
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
  Future<void> _refreshBaselines(_BaselineHistoryCache history) async {
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
  Future<void> _pruneOldRaw(List<String> dayIds, int dataNowSec) async {
    final derivedIds = await LocalDb.dayResultIds(kAlgoVersion);
    final pending = dayIds.where((d) => !derivedIds.contains(d)).toList();
    if (pending.isNotEmpty) {
      _log('prune skipped — ${pending.length} day(s) not yet derived');
      return;
    }
    final cutoffSec = dataNowSec - rawRetentionDays * 86400;
    if (cutoffSec <= 0) return;
    final deleted = await LocalDb.pruneRawBeforeRecTs(cutoffSec);
    if (deleted > 0) _log('pruned $deleted raw rows with rec_ts < $cutoffSec');
  }

  List<double> _perMinuteMeanWake(
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

  Map<String, int> _wakeZoneMinutes(
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

  double _keytelCaloriesWake(
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

  double? _meanWake(List<double> xs) {
    if (xs.isEmpty) return null;
    var s = 0.0;
    for (final x in xs) {
      s += x;
    }
    return s / xs.length;
  }

  void _applyWakeDayFeatures(
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
      _log('steps/energy skipped: $e');
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

  Map<String, dynamic> _buildWakeDayFeatures(
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
    final age = profile.ageYears?.toDouble();
    final weightKg = profile.weightKg;
    final sex = profile.sex?.toLowerCase();
    final hrMax = age == null ? null : 208 - 0.7 * age;
    final rhrForTrimp = restingHr ?? profile.restingHrManual?.toDouble();
    double? strain;
    double? calories;
    double? steps;
    double? caloriesTotal;
    Map<String, int> zones = const {};
    if (hrMax != null && perMin.isNotEmpty) {
      if (rhrForTrimp != null && sex != null && dayHrValid.isNotEmpty) {
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
      if (age != null && sex != null && weightKg != null) {
        calories = _keytelCaloriesWake(
          perMin,
          age,
          weightKg,
          hrMax,
          sex == 'f',
        );
      }
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
      if (age != null && weightKg != null && profile.heightCm != null) {
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
  int _activeMinutes(Substrate s, int sleepOnsetSec, int sleepOffsetSec) {
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

  List<ana.MotionMinute> _motionMinutes(Substrate s) {
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

  List<double> _hrPerMinuteAligned(List<ana.MotionMinute> motion, Substrate s) {
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

  String _workoutSex(String? sex) {
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

  /// Auto-detected workouts for the day via [ana.WorkoutDetector] over the
  /// day's 1 Hz HR + gravity. Returns a list of per-bout maps (each bout's
  /// avg/peak HR, duration, zone time-%, strain, calories, sport). Manual/live
  /// sessions overlapping the day are passed as saved spans so an overlapping
  /// detected bout is dropped (OVERLAP-DEDUP; manual wins). Empty list when no
  /// bout qualifies. Never throws — best-effort, like the other detail blocks.
  Future<List<Map<String, dynamic>>> _detectedWorkouts(
    Substrate s,
    PreparedDerivationDay day,
    Profile profile,
  ) async => const [];
  // NOTE: sport typing (ana.RuleSportClassifier) lived here, attached to detected
  // workouts. PR#25 relocated workout detection out of _deriveDay, so the per-bout
  // classifier was removed; re-home it where the new flow surfaces bouts.

  /// Advanced 4-class sleep over the day substrate via [ana.AdvancedSleepStager]
  /// (Cole–Kripke sleep/wake spine + DoG HR-variability + percentile-band
  /// classifier + median/physiology smoothing). Returns the MAIN sleep session's
  /// AASM metrics (TST/SOL/REM-latency/WASO/disturbances + per-stage minutes) and
  /// a 4-class hypnogram. ADDITIVE — the canonical `sleep` block stays the
  /// single source; this is a parallel ESTIMATE. `{present:false}` when no
  /// qualifying sleep / insufficient data. Never throws (best-effort detail).
  Future<Map<String, dynamic>> _advancedSleep(Substrate s) async => const {
    'present': false,
  };

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
  void _attachNaps(
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
      _log('naps FAILED/skipped: $e');
    }
  }

  /// Opt-in workout SUGGESTIONS (`autoDetectWorkouts`) + HEART-RATE RECOVERY.
  ///
  /// One detector pass over the day's 1 Hz HR (+ gravity motion) serves both: the
  /// detected bouts become persisted "did you work out?" suggestions (excluding
  /// any already-saved manual/live session), and each bout's HR tail yields an
  /// HRR-60s drop whose daily mean → `hrr_bpm`. Suggestions + the notification are
  /// gated to RECENT days so a re-analyze / import never spams. Best-effort.
  Future<void> _attachWorkoutSuggestionsAndHrr(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    PreparedDerivationDay day,
    int dataNowSec,
  ) async {
    try {
      final n = s.length;
      if (n < 60) return;
      final hrTs = <int>[];
      final hrBpm = <int>[];
      for (var i = 0; i < n; i++) {
        if (s.hr[i] > 0) {
          hrTs.add(s.tsSec[i]);
          hrBpm.add(s.hr[i]);
        }
      }
      if (hrBpm.length < 60) return;
      final motion =
          ana.AutoWorkoutDetector.motionPoints(s.tsSec, s.ax, s.ay, s.az);
      // Exclude windows the user has already logged (manual/live wins).
      final dayLo = s.tsSec.first;
      final dayHi = s.tsSec.last + 60;
      final saved = await LocalDb.sessionsInRange(dayLo, dayHi);
      final savedSpans = <ana.SavedWorkoutSpan>[
        for (final r in saved)
          if (r['start_ts'] is int && r['end_ts'] is int)
            ana.SavedWorkoutSpan(r['start_ts'] as int, r['end_ts'] as int),
      ];
      final rhr = (scMap?['rhr'] as num?)?.round();
      final detected = ana.autoDetectWorkouts(
        hrTs: hrTs,
        hrBpm: hrBpm,
        restingBpm: rhr,
        motion: motion,
        savedSpans: savedSpans,
      );
      final bouts = detected.value ?? const [];

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
      for (final r in saved) {
        final id = r['id'];
        final endTs = r['end_ts'];
        if (id is! String || endTs is! int) continue;
        final m = _hrrForBout(s, endTs);
        if (m != null) {
          drops.add(m);
          await LocalDb.setSessionHrr(id, double.parse(m.toStringAsFixed(1)));
        }
      }
      if (drops.isNotEmpty) {
        final mean = drops.reduce((a, c) => a + c) / drops.length;
        scMap?['hrr_bpm'] = double.parse(mean.toStringAsFixed(1));
      }
      bundle['workout_suggestions'] = boutJson;

      // Persist + notify only for RECENT days (≤ ~36 h old) so imports/re-analyze
      // don't resurface 90 days of prompts.
      final recent = (dataNowSec - day.endSec) < 36 * 3600;
      if (recent && bouts.isNotEmpty) {
        for (final b in bouts) {
          await LocalDb.putWorkoutSuggestion({
            'id': '${day.date}:${b.startSec}',
            'date': day.date,
            'start_ts': b.startSec,
            'end_ts': b.endSec,
            'avg_bpm': b.avgBpm,
            'peak_bpm': b.peakBpm,
            'duration_min': b.durationMin,
            'sport': b.sport,
            'dismissed': 0,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          });
        }
        final first = bouts.first;
        await NotificationCenter.instance.emit(NotificationEvent(
          dedupeKey: '${day.date}:auto_workout',
          category: NotifCategory.recovery,
          priority: NotifPriority.normal,
          title: 'Did you work out?',
          body: 'We spotted ~${first.durationMin} min of elevated activity. '
              'Tap to log it.',
          date: day.date,
          route: '/workouts',
        ));
      }
    } catch (e) {
      _log('auto-workout/HRR FAILED/skipped: $e');
    }
  }

  /// HRR-60s for a bout ending at [endSec]: build the per-second HR tail around
  /// the end index and delegate to [ana.hrRecovery]. Returns the drop (bpm) or null.
  double? _hrrForBout(Substrate s, int endSec) {
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
  void _attachWristOrientation(
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
      _log('wrist-orientation FAILED/skipped: $e');
    }
  }

  int _localDayLabelToSec(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return 0;
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
  }

  String _localDateLabel(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
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
    final endSec = startSec + 86400;
    return (math.max(0, startSec - 6 * 3600), endSec - 1);
  }

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final vs = List<double>.from(xs)..sort();
  final mid = vs.length ~/ 2;
  return vs.length.isOdd ? vs[mid] : (vs[mid - 1] + vs[mid]) / 2;
}
