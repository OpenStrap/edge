// DerivationEngine — the on-device compute orchestrator (MAIN ISOLATE).
//
// Flow (per trigger):
//   1. Find physiological days with NEW raw since their stored `last_raw_ts`
//      (un-derived OR stale). Battery-sense: a day is recomputed only if it has
//      new raw — no fingerprint gymnastics.
//   2. For each such day (main isolate): read its raw rows from LocalDb, decode
//      via openstrap_protocol → numeric 1 Hz series (HR / RR / accel / ADC).
//   3. Hand the SERIALIZED series + Profile + trailing baselines to a PURE
//      top-level fn (`deriveDayBundle`) via `Isolate.run` — heavy work (24-h
//      spectra, sleep staging) runs OFF the UI isolate. DB I/O stays on main
//      (sqflite isn't isolate-safe). Pass-1 (baseline-independent: RMSSD/RHR)
//      and pass-2 (baseline-dependent: readiness) both happen inside the bundle
//      using the trailing history we pass in.
//   4. Write the bundle → derived_day (+ metric_series + refresh baselines).
//   5. Prune raw older than rawRetentionDays — but NEVER for a day not yet
//      derived (raw-first invariant).

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import '../data/db.dart';
import 'crossday_pipeline.dart';
import 'onehz_pipeline.dart';
import 'profile.dart';

/// Bundle schema version — bump to force a full recompute on a logic change.
const int derivedVersion = 1;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 7;

/// How many trailing derived days feed pass-2 baselines.
const int _baselineWindowDays = 28;

class DerivationEngine {
  DerivationEngine({this.log});
  final void Function(String)? log;

  bool _running = false;

  /// True while a derivation pass is in flight (so triggers don't pile up).
  bool get running => _running;

  /// Run a derivation pass. [heavy]=false runs a bounded light pass (only the
  /// most-recent affected day) suitable for a short background BLE wake;
  /// [heavy]=true sweeps every stale day (the nightly scheduled pass).
  /// [force]=true re-derives EVERY day that has raw, ignoring the derived
  /// cursor — the user-initiated "re-analyze all data" path. Re-entrant calls
  /// are coalesced. Returns the number of days derived.
  /// [onDayDone] fires on the MAIN isolate after each day finishes (or is skipped),
  /// so the caller can refresh the UI incrementally and show progress.
  Future<int> run(
    Profile profile, {
    bool heavy = false,
    bool force = false,
    void Function(String day, int index, int total)? onDayDone,
  }) async {
    if (_running) return 0;
    _running = true;
    try {
      final stale = await _staleDays(force: force);
      if (stale.isEmpty) {
        _log('derive: nothing to do');
        return 0;
      }
      // Light pass: only the newest affected day (capture-window-sized work).
      // Heavy/force: every affected day.
      final days = (heavy || force) ? stale : stale.sublist(stale.length - 1);
      _log('derive: ${days.length} day(s) '
          '(${force ? "force-all" : heavy ? "heavy" : "light"})');
      for (var i = 0; i < days.length; i++) {
        final day = days[i];
        try {
          await _deriveDay(day, profile);
        } catch (e) {
          // A single pathological/timed-out day must never stall the whole sweep.
          // Write a skip marker so it isn't retried forever, then move on.
          _log('derive day $day FAILED/skipped: $e');
          await _markDaySkipped(day);
        }
        onDayDone?.call(day, i + 1, days.length); // incremental UI refresh
      }
      // Cross-day rollup over the recent day series. Best-effort: a failure here
      // must NOT abort the sweep or block pruning — we log and continue.
      await _runCrossDay(profile);
      await _runNotifications();
      await _pruneOldRaw();
      return days.length;
    } catch (e, st) {
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      _running = false;
    }
  }

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress and finishes in finite time.
  static const Duration _perDayTimeout = Duration(seconds: 90);

  /// Defensive caps on a single day's decoded series. With the rec_ts bucketing fix
  /// a day should hold ~1 real day of samples, so these should rarely trigger; they
  /// guard against a clock-glitched/duplicate flood collapsing into one bucket.
  static const int _maxHrSamples = 100000; // ~1 Hz over a day is ~86 400
  static const int _maxRrSamples = 200000;

  /// Persist a minimal derived row for a skipped day so it's not re-derived every
  /// pass (its last_raw_ts is advanced to the day's end).
  Future<void> _markDaySkipped(String date) async {
    final toSec =
        (DateTime.parse('$date 23:59:59').millisecondsSinceEpoch + 999) ~/ 1000;
    try {
      await LocalDb.putDerivedDay(
        date: date,
        payloadJson: jsonEncode({'skipped': true, 'reason': 'timeout_or_error'}),
        version: derivedVersion,
        lastRawTs: toSec,
      );
    } catch (_) {/* best-effort */}
  }

  // ── find days needing (re)derivation ───────────────────────────────────────

  /// Physiological-day labels (sorted ascending) that have raw newer than their
  /// derived `last_raw_ts` (or were never derived / are an old bundle version).
  /// [force]=true returns EVERY day that has raw, ignoring the derived cursor.
  Future<List<String>> _staleDays({bool force = false}) async {
    // Group raw by the LOCAL calendar date of each record's REAL time (rec_ts),
    // NOT its receive time (captured_at). This is the core of the backfill fix: a
    // whole multi-day flash offload arrives in one sync (one captured_at≈now) but
    // carries many real days of rec_ts — so it splits into correct per-day buckets
    // instead of collapsing into a single "today" that would run 24-h spectra over
    // many days at once. The day label is refined by the sleep window in the bundle.
    final dayMax = await LocalDb.rawRecTsMaxByDay();
    if (dayMax.isEmpty) return const [];

    // `last_raw_ts` keeps its semantics (the cursor of raw already reflected for a
    // day) but is now keyed on rec_ts seconds instead of captured_at ms.
    final lastRawByDay = await LocalDb.derivedLastRawTs();

    final stale = <String>[];
    for (final e in dayMax.entries) {
      if (force) {
        stale.add(e.key);
        continue;
      }
      final derivedTs = lastRawByDay[e.key];
      if (derivedTs == null || e.value > derivedTs) {
        stale.add(e.key);
      }
    }
    stale.sort();
    return stale;
  }

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<void> _deriveDay(String date, Profile profile) async {
    // Day window in epoch SECONDS (local-calendar day of the record's REAL time).
    // last_raw_ts is captured here on the MAIN isolate, before the heavy work, so a
    // concurrent live insert mid-pass is simply picked up next pass (its rec_ts is
    // re-bucketed and compared against this cursor next run).
    final fromSec = DateTime.parse('$date 00:00:00').millisecondsSinceEpoch ~/ 1000;
    final toSec =
        (DateTime.parse('$date 23:59:59').millisecondsSinceEpoch + 999) ~/ 1000;

    final hexes = await LocalDb.rawHexInRecTsRange(fromSec, toSec);
    if (hexes.isEmpty) return;
    final lastRawTs = toSec; // everything in-window (by rec_ts) is now reflected.

    // (main isolate) DECODE the raw hex → 1 Hz numeric series.
    final input = _buildDayInput(date, hexes, profile);

    // Defensive cap: if a single day's series is pathologically large (e.g. a clock
    // glitch fused multiple days into one rec_ts bucket), downsample the spectral
    // input so Lomb-Scargle stays bounded. With the rec_ts fix this rarely fires.
    final hrLen = (input['hr'] as List?)?.length ?? 0;
    final rrLen = (input['rr_ms'] as List?)?.length ?? 0;
    if (hrLen > _maxHrSamples || rrLen > _maxRrSamples) {
      _log('WARN $date oversized series (hr=$hrLen rr=$rrLen) — downsampling');
      _downsampleInPlace(input, 'hr_ts', _maxHrSamples);
      _downsampleInPlace(input, 'hr', _maxHrSamples);
      _downsampleInPlace(input, 'rr_ts_ms', _maxRrSamples);
      _downsampleInPlace(input, 'rr_ms', _maxRrSamples);
    }

    // Attach trailing baselines for pass-2.
    final withHistory = await _attachHistory(input);

    // (off-isolate) run the pure pipeline. Isolate.run copies the map in/out.
    // A per-day timeout guarantees one bad day can't hang the whole sweep — on
    // timeout the future throws and run()'s catch marks the day skipped.
    final bundle = await Isolate.run(() => deriveDayBundle(withHistory))
        .timeout(_perDayTimeout);

    // (main isolate) persist.
    final scalars = (bundle['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    double? sc(String k) => (scalars[k] as num?)?.toDouble();
    await LocalDb.putDerivedDay(
      date: date,
      payloadJson: jsonEncode(bundle),
      version: derivedVersion,
      lastRawTs: lastRawTs,
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
        'dip_pct': sc('dip_pct'),
        'trimp': sc('trimp'),
        'odi_per_hour': sc('odi_per_hour'),
        'cpc_ratio': sc('cpc_ratio'),
      },
    );
    await _refreshBaselines();
    _log('derived $date — ${hexes.length} raw → bundle v$derivedVersion');
  }

  /// Uniformly decimate a serialized series list (in place) down to at most [max]
  /// elements, preserving time order. Only used by the oversized-day guard.
  void _downsampleInPlace(Map<String, dynamic> input, String key, int max) {
    final list = input[key] as List?;
    if (list == null || list.length <= max) return;
    final stride = (list.length / max).ceil();
    final out = [for (var i = 0; i < list.length; i += stride) list[i]];
    input[key] = out;
  }

  /// Decode raw frames into a serialized [DayInput] map (the isolate input).
  Map<String, dynamic> _buildDayInput(
      String date, List<String> hexes, Profile profile) {
    final hrTs = <int>[], hrBpm = <int>[];
    final rrTsMs = <double>[], rrMs = <double>[];
    final aTs = <double>[], ax = <double>[], ay = <double>[], az = <double>[];
    final skinTemp = <int>[], spo2Red = <int>[], spo2Ir = <int>[];

    for (final hex in hexes) {
      // Type-24 historical (1 Hz biometric) records carry the full substrate.
      proto.R24? r;
      try {
        r = proto.parseR24(proto.hexToBytes(hex));
      } catch (_) {
        r = null;
      }
      if (r != null && r.tsEpoch > 0) {
        hrTs.add(r.tsEpoch);
        hrBpm.add(r.hr);
        // RR beats: distribute across the 1-s record, anchored at record end.
        var t = r.tsEpoch * 1000.0;
        for (final rr in r.rrIntervalsMs) {
          if (rr > 0) {
            rrMs.add(rr.toDouble());
            rrTsMs.add(t);
            t += 0; // beats share the record second; time order preserved
          }
        }
        if (r.accelG.length == 3) {
          aTs.add(r.tsEpoch.toDouble());
          ax.add(r.accelG[0]);
          ay.add(r.accelG[1]);
          az.add(r.accelG[2]);
        }
        skinTemp.add(r.skinTempRaw);
        spo2Red.add(r.spo2RedRaw);
        spo2Ir.add(r.spo2IrRaw);
        continue;
      }
      // Live RR-bearing frames (0x28 / R10) — fold their beats in too.
      final live = proto.realtimeRr(hex);
      if (live != null && live.ts > 0) {
        for (final rr in live.rrMs) {
          if (rr > 0) {
            rrMs.add(rr.toDouble());
            rrTsMs.add(live.ts * 1000.0);
          }
        }
      }
    }

    // Order all series by time (decode order ~= capture order, but be safe for RR).
    return DayInput(
      date: date,
      hrTsSec: hrTs,
      hrBpm: hrBpm,
      rrTsMs: rrTsMs,
      rrMs: rrMs,
      accelTsSec: aTs,
      ax: ax,
      ay: ay,
      az: az,
      skinTempRaw: skinTemp,
      spo2RedRaw: spo2Red,
      spo2IrRaw: spo2Ir,
      profile: profile.toMap(),
    ).toJson();
  }

  /// Attach trailing personal history (from metric_series) for pass-2 baselines.
  Future<Map<String, dynamic>> _attachHistory(Map<String, dynamic> input) async {
    Future<List<double>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key, limit: _baselineWindowDays);
      return [for (final r in rows) (r['value'] as num).toDouble()];
    }

    input['ln_rmssd_history'] = await hist('ln_rmssd');
    input['rhr_history'] = await hist('rhr');
    input['resp_history'] = await hist('resp_rate');
    input['skin_temp_z_history'] = await hist('skin_temp_z');
    return input;
  }

  /// Max wall-clock for the off-isolate cross-day rollup.
  static const Duration _crossDayTimeout = Duration(seconds: 30);

  /// How many trailing derived days feed the cross-day families.
  static const int _crossDayWindow = 90;

  // ── cross-day rollup ─────────────────────────────────────────────────────────

  /// Gather the recent derived-day series and run the cross-day analytics
  /// families (illness/anomaly/load/temp/SRI/jetlag/chronotype/sleep-debt/
  /// percentile/glass-box/BRV) ONCE, storing the result in the `crossday`
  /// baseline. Best-effort: every failure path logs and returns without storing.
  Future<void> _runCrossDay(Profile profile) async {
    try {
      final rows = await LocalDb.recentDerivedDays(_crossDayWindow);
      // recentDerivedDays is newest-first; the families want oldest-first.
      final days = <Map<String, dynamic>>[];
      for (final row in rows.reversed) {
        final payload = _decodeBundle(row['payload_json']);
        if (payload == null) continue;
        if (payload['skipped'] == true) continue; // skip marker rows
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
      // A cross-day failure must never abort the sweep or block pruning.
      _log('crossday FAILED/skipped: $e');
    }
  }

  // ── notifications generator ─────────────────────────────────────────────────

  /// Emit idempotent notifications for the LATEST day's flags from the cross-day
  /// rollup (illness / anomaly / elevated temp / low readiness). id =
  /// `date:kind` + INSERT OR IGNORE, so re-running a pass never duplicates.
  /// Best-effort: any failure is swallowed (never aborts the sweep).
  Future<void> _runNotifications() async {
    try {
      final cdRow = await LocalDb.baseline('crossday');
      final cd = _decodeBundle(cdRow?['payload_json']);
      if (cd == null) return;

      // Latest day's date: prefer the recent[] tail, else the flag payloads.
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

  /// Decode a derived_day payload_json into a map (null on any failure).
  static Map<String, dynamic>? _decodeBundle(Object? json) {
    if (json is! String) return null;
    try {
      final d = jsonDecode(json);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Build the cross-day day-record from a derived_day row + its payload bundle.
  /// Scalars prefer the row columns (rhr/rmssd/readiness) and fall back to the
  /// payload `scalars`; resp_rate/skin_temp_z/trimp come from the payload.
  /// Returns null when the row carries no usable date.
  static Map<String, dynamic>? _crossDayRecord(
      Map<String, dynamic> row, Map<String, dynamic> payload) {
    final date = row['date'] as String?;
    if (date == null || date.isEmpty) return null;
    final scalars = (payload['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    num? sc(String k) => scalars[k] is num ? scalars[k] as num : null;
    num? col(String k) => row[k] is num ? row[k] as num : null;

    final sleep = (payload['sleep'] as Map?)?.cast<String, dynamic>();
    final window = (sleep?['window'] as Map?)?.cast<String, dynamic>();
    final acct = (sleep?['accounting'] as Map?)?.cast<String, dynamic>();
    final series = (payload['series'] as Map?)?.cast<String, dynamic>();

    final onsetMs = (window?['onset_ms'] as num?)?.toDouble();
    final offsetMs = (window?['offset_ms'] as num?)?.toDouble();
    final tstSec = (acct?['tst_sec'] as num?)?.toDouble();

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

  /// Refresh rolling baselines from the recent derived rows (cheap: from columns).
  Future<void> _refreshBaselines() async {
    final recent = await LocalDb.recentDerivedDays(_baselineWindowDays);
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

  /// Prune raw older than [rawRetentionDays] — but only days that ARE derived.
  /// Age is measured by `captured_at` (STORAGE age, ms) — pruning by how long we've
  /// held a row is correct and independent of rec_ts. The raw-first guard: if ANY
  /// day still needs derivation we skip pruning this pass, so an un-derived day's
  /// raw is never deleted (it survives until its bundle is written). Un-derived
  /// days are rare here because the sweep derives them before pruning.
  Future<void> _pruneOldRaw() async {
    // Never prune while there are un-derived days — protects the raw-first invariant
    // regardless of whether the stale day's raw is old or new by storage age.
    final stale = await _staleDays();
    if (stale.isNotEmpty) {
      _log('prune skipped — ${stale.length} day(s) not yet derived');
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
