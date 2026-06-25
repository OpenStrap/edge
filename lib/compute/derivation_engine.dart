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

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import 'crossday_pipeline.dart';
import 'onehz_pipeline.dart';
import 'profile.dart';
import 'substrate.dart';

/// Analytics/bundle version — bump to force a recompute of non-finalized days.
const int kAlgoVersion = 2;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 14;

/// A day stays recomputable for this long after its wake, then FINALIZES (locks)
/// — more flash may still drain within this buffer (ARCHITECTURE_V2: ~48 h).
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;

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
      final days = physiologicalDays(sub);
      if (days.isEmpty) {
        _log('derive: no physiological days');
        return 0;
      }

      // 3. Which days to compute. Skip FINALIZED days entirely. Among the rest,
      //    a light pass does only the newest; heavy/force do all recomputable.
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      final computable = <PhysioDay>[];
      for (final day in days) {
        if (finalized.contains(day.date)) continue; // locked
        computable.add(day);
      }
      if (computable.isEmpty) {
        _log('derive: all days finalized — nothing to do');
        await _pruneOldRaw(days);
        return 0;
      }
      final todo = (heavy || force)
          ? computable
          : computable.sublist(computable.length - 1);
      _log('derive: ${todo.length}/${days.length} day(s) '
          '(${force ? "force" : heavy ? "heavy" : "light"}; v$kAlgoVersion)');

      var done = 0;
      for (var i = 0; i < todo.length; i++) {
        final day = todo[i];
        try {
          await _deriveDay(sub, day, profile, nowSec);
          done++;
        } catch (e) {
          _log('derive day ${day.date} FAILED/skipped: $e');
          await _markDaySkipped(day, nowSec);
        }
        onDayDone?.call(day.date, i + 1, todo.length);
      }

      // 4. Cross-day rollup + notifications (best-effort).
      await _runCrossDay(profile);
      await _runNotifications();
      // 5. Prune raw — never for a day still inside its raw window / un-derived.
      await _pruneOldRaw(days);
      return done;
    } catch (e, st) {
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      _running = false;
    }
  }

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress.
  static const Duration _perDayTimeout = Duration(seconds: 90);

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<void> _deriveDay(
      Substrate sub, PhysioDay day, Profile profile, int nowSec) async {
    // Slice the substrate to the day container and to the SLEEP window.
    final daySub = sub.slice(day.startSec, day.endSec);
    final sleepSub = day.hasSleep
        ? sub.sliceIdx(day.sleepLoIdx, day.sleepHiIdx)
        : Substrate.empty;

    // Per-second stage labels (the single source) → 'wake'|'nrem'|'rem' strings.
    final hypno = <String>[
      for (final s in day.sleep.stages)
        s == ana.SleepStage.wake
            ? 'wake'
            : (s == ana.SleepStage.rem ? 'rem' : 'nrem')
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

    // Finalize if the day's wake is >48 h in the past (no more flash will land).
    final finalized = (day.endSec + _finalizationSec) < nowSec;

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
        'odi_per_hour': sc('odi_per_hour'),
        'cpc_ratio': sc('cpc_ratio'),
      },
    );
    await _refreshBaselines();
    _log('derived ${day.date} v$kAlgoVersion '
        '(sleep=${day.hasSleep}, final=$finalized)');
  }

  /// Persist a minimal skip marker so a pathological day isn't retried forever.
  Future<void> _markDaySkipped(PhysioDay day, int nowSec) async {
    try {
      await LocalDb.putDayResult(
        dayId: day.date,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': 'timeout_or_error'}),
        windowJson: '{}',
        finalized: (day.endSec + _finalizationSec) < nowSec,
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
        await emit('illness', 'Possible illness onset',
            'Elevated resting HR + suppressed HRV over recent nights.');
      }
      if (anomaly != null && anomaly['flagged'] == true) {
        await emit('anomaly', 'Unusual overnight physiology',
            'Your nightly signals deviate from your personal baseline.');
      }
      if (temp != null && temp['flag'] == 'elevated') {
        await emit('temp', 'Skin temperature elevated',
            'Sustained rise vs your baseline — a possible illness signal.');
      }
      final score = gb?['value'] is Map ? (gb!['value'] as Map)['score'] : null;
      if (score is num && score < 34) {
        await emit('readiness', 'Low readiness today',
            'Your recovery markers are below your usual range — ease off.');
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

    final sleep = (payload['sleep'] as Map?)?.cast<String, dynamic>();
    final win = (sleep?['window'] as Map?)?.cast<String, dynamic>();
    final winVal = (win?['value'] as Map?)?.cast<String, dynamic>();
    final acct = (sleep?['accounting'] as Map?)?.cast<String, dynamic>();
    final acctVal = (acct?['value'] as Map?)?.cast<String, dynamic>();
    final series = (payload['series'] as Map?)?.cast<String, dynamic>();

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

  /// Prune raw older than [rawRetentionDays]. Guard: never prune while any day
  /// in [days] is NOT yet derived at the current algo version (raw-first).
  Future<void> _pruneOldRaw(List<PhysioDay> days) async {
    final derivedIds = await LocalDb.dayResultIds(kAlgoVersion);
    final pending = days.where((d) => !derivedIds.contains(d.date)).toList();
    if (pending.isNotEmpty) {
      _log('prune skipped — ${pending.length} day(s) not yet derived');
      return;
    }
    final cutoff = DateTime.now()
        .subtract(const Duration(days: rawRetentionDays))
        .millisecondsSinceEpoch;
    if (cutoff <= 0) return;
    final deleted = await LocalDb.pruneRawBefore(cutoff);
    if (deleted > 0) _log('pruned $deleted raw rows captured < ${cutoff ~/ 1000}');
  }

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}
