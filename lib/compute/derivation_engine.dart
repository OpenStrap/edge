// DerivationEngine — the on-device compute COORDINATOR (MAIN ISOLATE).
//
// Current flow (per trigger):
//   1. Decide WHICH calendar days need compute (force / pending span / latest
//      day + context).
//   2. For EACH target day, load only that day's bounded overlapping raw window
//      (previous evening through that day) and decode it off-main-isolate.
//   3. Inside that bounded window, segment calendar days and keep ONLY the
//      requested day's prepared payload. Cross-midnight sleep still works
//      because the input window overlaps the prior evening.
//   4. Run the pure day pipeline off-isolate, persist the day row/series, and
//      update in-memory baseline history for the next day in the same run.
//   5. Refresh rolling baselines once, then cross-day rollup / notifications.
//   6. Prune raw only after a force/full-history sweep, never before derived.
//
// Finalized-day rescans are still allowed for baseline-dependent scalars
// (readiness/recovery, illness/anomaly, stress), but they re-use the SAME
// bounded per-day prepare path instead of decoding the whole raw ledger at once.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
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
const int kAlgoVersion = 17;

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
    ]);
    return _BaselineHistoryCache({
      'ln_rmssd': loaded[0],
      'rmssd': loaded[1],
      'rhr': loaded[2],
      'resp_rate': loaded[3],
      'skin_temp_adc': loaded[4],
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
      final todoDays = [
        for (final day in scope.targetDays)
          if (!finalized.contains(day)) day,
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
        await _refreshBaselines();
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
    final range = _targetDayWindow(dayId);
    final port = ReceivePort();
    final isolate = await Isolate.spawn(derivationPrepareWorker, port.sendPort);
    final ready = Completer<SendPort>();
    final result = Completer<PreparedDerivationDay?>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((message) async {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is Map && message['type'] == 'result') {
        final payload = PreparedDerivationPayload.fromJson(
          ((message['payload'] as Map?) ?? const {}).cast<String, dynamic>(),
        );
        await sub.cancel();
        port.close();
        isolate.kill(priority: Isolate.immediate);
        result.complete(payload.days.isEmpty ? null : payload.days.first);
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
    worker.send({'type': 'config', 'target_day': dayId});
    _diag
      ..['day_raw_pages'] = 0
      ..['day_raw_rows'] = 0;
    int? afterRecTs;
    int? afterCursor;
    _diag
      ..['range_from_rec_ts'] = range.$1
      ..['range_to_rec_ts'] = range.$2;
    var usedDecoded = false;
    while (true) {
      final decodedRows = await LocalDb.decodedOneHzBatchByRecTsRange(
        limit: _rawDecodeBatchSize,
        fromRecTs: range.$1,
        toRecTs: range.$2,
        afterRecTs: afterRecTs,
        afterCounter: afterCursor,
      );
      if (decodedRows.isNotEmpty) {
        usedDecoded = true;
        _diag['raw_pages'] = (_diag['raw_pages'] as int) + 1;
        _diag['raw_rows'] = (_diag['raw_rows'] as int) + decodedRows.length;
        _diag['day_raw_pages'] = (_diag['day_raw_pages'] as int) + 1;
        _diag['day_raw_rows'] =
            (_diag['day_raw_rows'] as int) + decodedRows.length;
        if ((_diag['day_raw_pages'] as int) >
            (_diag['max_day_raw_pages'] as int)) {
          _diag['max_day_raw_pages'] = _diag['day_raw_pages'];
        }
        if ((_diag['day_raw_rows'] as int) >
            (_diag['max_day_raw_rows'] as int)) {
          _diag['max_day_raw_rows'] = _diag['day_raw_rows'];
        }
        if ((_diag['day_raw_rows'] as int) > _maxDayRawRows ||
            (_diag['day_raw_pages'] as int) > _maxDayRawPages) {
          await sub.cancel();
          port.close();
          isolate.kill(priority: Isolate.immediate);
          throw Exception(
            'day_prepare_budget_exceeded day=$dayId rows=${_diag['day_raw_rows']} '
            'pages=${_diag['day_raw_pages']} range=${range.$1}-${range.$2}',
          );
        }
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
        fromRecTs: range.$1,
        toRecTs: range.$2,
        afterRecTs: afterRecTs,
        afterRowId: afterCursor,
      );
      if (rows.isEmpty) break;
      _diag['raw_pages'] = (_diag['raw_pages'] as int) + 1;
      _diag['raw_rows'] = (_diag['raw_rows'] as int) + rows.length;
      _diag['day_raw_pages'] = (_diag['day_raw_pages'] as int) + 1;
      _diag['day_raw_rows'] = (_diag['day_raw_rows'] as int) + rows.length;
      if ((_diag['day_raw_pages'] as int) >
          (_diag['max_day_raw_pages'] as int)) {
        _diag['max_day_raw_pages'] = _diag['day_raw_pages'];
      }
      if ((_diag['day_raw_rows'] as int) > (_diag['max_day_raw_rows'] as int)) {
        _diag['max_day_raw_rows'] = _diag['day_raw_rows'];
      }
      if ((_diag['day_raw_rows'] as int) > _maxDayRawRows ||
          (_diag['day_raw_pages'] as int) > _maxDayRawPages) {
        await sub.cancel();
        port.close();
        isolate.kill(priority: Isolate.immediate);
        throw Exception(
          'day_prepare_budget_exceeded day=$dayId rows=${_diag['day_raw_rows']} '
          'pages=${_diag['day_raw_pages']} range=${range.$1}-${range.$2}',
        );
      }

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

    // ── ACTIVITY-MINUTES (1 Hz ENMO over the WAKE span) ───────────────────────
    // Steps can't be counted from 1 Hz (Nyquist) — only from live 100 Hz IMU. So
    // the always-on movement metric is "active minutes": minutes of the waking
    // day whose mean ENMO (van Hees amplitude) clears a light-activity threshold.
    // Computed on THIS isolate (accel lives in `daySub`, not the bundle input).
    final activeMin = _activeMinutes(
      daySub,
      day.sleepOnsetSec,
      day.sleepOffsetSec,
    );
    // NOTE: deriveDayBundle's `scalars` literal is all-double? → Dart infers it
    // as Map<String, double?>. Writing a bare int here throws "int is not a
    // subtype of double?". Store as a double (sc() reads it via toDouble anyway).
    final scMap = (bundle['scalars'] as Map?)?.cast<String, dynamic>();
    scMap?['active_min'] = activeMin.toDouble();
    bundle['activity'] = <String, dynamic>{
      'value': activeMin,
      'active_min': activeMin,
      'confidence': 0.6,
      'tier': 'ESTIMATE',
      'inputs_used': const ['accel_1hz'],
      'note':
          'active minutes (1 Hz ENMO over wake); 1 Hz cannot count steps — '
          'true step counts come from live workout streaming',
    };

    // ── STEPS (24/7 ESTIMATE) + TOTAL DAILY ENERGY (TDEE) ─────────────────────
    // 1 Hz cannot COUNT steps (Nyquist) — but it can detect ambulatory MINUTES
    // and multiply by a cadence (steps/min) for an honest 24/7 ESTIMATE. The
    // live 100 Hz pedometer (app_state) counts real steps AND personalizes the
    // cadence this estimate uses (stepCalib). TDEE = HR-flex (BMR floor + active
    // Keytel surplus). Both need accel/HR from daySub + the profile, so they run
    // here on the main isolate (like activeMin), not in the pure bundle pipeline.
    _stepsAndEnergy(bundle, scMap, daySub, profile);

    // ── More substrate-derived detail blocks (computed here, where the full
    //    sliced substrate lives — same pattern as activeMin; these are fresh
    //    <String,dynamic> blocks so ints are safe, unlike the double? scalars). ─
    bundle['wear'] = _wearBlock(daySub); // on/off-wrist segments
    bundle['daytime_hrv'] = _daytimeHrv(
      daySub,
      day.sleepOnsetSec,
      day.sleepOffsetSec,
    ); // waking RMSSD
    bundle['restlessness'] = _restlessness(sleepSub); // nocturnal movement
    bundle['sleep_periods'] = _sleepPeriods(
      daySub,
      day.sleepOnsetSec,
      day.sleepOffsetSec,
    ); // naps
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
        'active_min': sc('active_min'),
        'calories': sc('calories'),
        // 24/7 step ESTIMATE (ambulatory-min × cadence) + total daily energy.
        'steps': sc('steps'),
        'calories_total': sc('calories_total'),
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
      date ??=
          (illness?['date'] ?? anomaly?['date'] ?? temp?['date']) as String?;
      if (date == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      Future<void> emit(String kind, String title, String body) =>
          LocalDb.putNotification({
            'id': '$date:$kind',
            'kind': kind,
            'title': title,
            'body': body,
            'date': date,
            'created_at': now,
            'read': 0,
          });
      if (illness != null && illness['state'] == 'red') {
        await emit(
          'illness',
          'Possible illness onset',
          'Elevated resting HR + suppressed HRV over recent nights.',
        );
      }
      if (anomaly != null && anomaly['flagged'] == true) {
        await emit(
          'anomaly',
          'Unusual overnight physiology',
          'Your nightly signals deviate from your personal baseline.',
        );
      }
      if (temp != null && temp['flag'] == 'elevated') {
        await emit(
          'temp',
          'Skin temperature elevated',
          'Sustained rise vs your baseline — a possible illness signal.',
        );
      }
      final score = gb?['value'] is Map ? (gb!['value'] as Map)['score'] : null;
      if (score is num && score < 34) {
        await emit(
          'readiness',
          'Low readiness today',
          'Your recovery markers are below your usual range — ease off.',
        );
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
          if (r[col] != null) (r[col] as num).toDouble(),
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

  /// Active minutes over the WAKE span — a COARSE 1 Hz movement proxy. At 1 Hz
  /// the dynamic-acceleration (ENMO) component of movement aliases away (Nyquist,
  /// same limit that bars step counting), so magnitude stays pinned near 1 g.
  /// What 1 Hz DOES resolve is wrist ORIENTATION change (van Hees z-angle) — so
  /// movement = seconds where the arm angle shifts. A minute is "active" if a
  /// meaningful fraction of its seconds show orientation change ≥5°. Transparent,
  /// no ML; honest ESTIMATE (a "minutes you were moving" proxy, not step-grade).
  int _activeMinutes(Substrate s, int sleepOnsetSec, int sleepOffsetSec) {
    final n = s.length;
    if (n < 60) return 0;
    final ang = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      ang[i] = ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
    }
    const moveDeg = 5.0; // per-second orientation change = movement (van Hees)
    const activeFrac = 0.20; // ≥20% of the minute's seconds moving → active
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

  /// 24/7 step ESTIMATE (Tier B) + total daily energy (TDEE), written into the
  /// bundle's `steps` block + `scalars` (steps, calories_total). 1 Hz can't COUNT
  /// steps (Nyquist) — this is ambulatory-minutes × cadence, personalized by the
  /// live pedometer's [stepCalib]. TDEE is the HR-flex method (Mifflin BMR floor +
  /// active Keytel surplus). Best-effort; leaves scalars null on missing data.
  void _stepsAndEnergy(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate daySub,
    Profile profile,
  ) {}

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
