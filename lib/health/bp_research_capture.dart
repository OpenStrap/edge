// BP research capture: a cuff reading typed in next to the band's own
// decoded data from the minutes before it, kept for CSV export. Dev mode
// only. Nothing in compute/, nothing that feeds day_result / metric_series
// and no health-store writer may read these tables
// (bp_research_isolation_test.dart). Missing data stays NULL.

import 'dart:math' show sqrt;

/// Version of the window formulas, exported with every row. Bump when a
/// field's meaning changes.
const int kResearchFeatureVersion = 3;

/// Rest window before the measurement: [at - 5 min, at). Ending at the
/// measurement keeps the cuff's own inflation out.
const int kResearchRestPreMs = 5 * 60 * 1000;

/// No post-measurement window.
const int kResearchWindowPostMs = 0;

/// Two successive beats further apart than this are not paired for RMSSD.
const int kResearchMaxBeatGapMs = 2500;

/// The band window before one measurement. A stat that could not be
/// computed is null, never zero.
class BpResearchWindow {
  const BpResearchWindow({
    required this.windowStartMs,
    required this.windowEndMs,
    this.observedStartMs,
    this.observedEndMs,
    this.onehzRows,
    this.rrBeats,
    this.hrMean,
    this.rrMsMean,
    this.rrMsMin,
    this.rrMsMax,
    this.rmssdMs,
    this.validHrSeconds,
    this.validIntervalCount,
    this.validIntervalPairCount,
    this.coverageFraction,
    this.rejectedIntervalFraction,
    this.qualityStatus,
    required this.featureVersion,
    this.snapshotRevision,
    this.metaJson,
  });

  /// Requested bounds, half-open [start, end).
  final int windowStartMs;
  final int windowEndMs;

  /// First and last valid sample inside the window.
  final int? observedStartMs;
  final int? observedEndMs;

  /// In-window 1 Hz rows, deduplicated by rec_ts.
  final int? onehzRows;

  /// In-window beats, deduplicated by beat identity.
  final int? rrBeats;

  final double? hrMean;
  final double? rrMsMean;
  final double? rrMsMin;
  final double? rrMsMax;
  final double? rmssdMs;

  /// 1 Hz rows with a valid HR.
  final int? validHrSeconds;

  /// Beats with a finite positive interval.
  final int? validIntervalCount;

  /// Successive valid beats within [kResearchMaxBeatGapMs]; RMSSD uses these.
  final int? validIntervalPairCount;

  /// validHrSeconds / window seconds; null without any valid HR.
  final double? coverageFraction;

  /// Share of successive valid pairs dropped for a gap; null without pairs.
  final double? rejectedIntervalFraction;

  /// 'pending' | 'ok' | 'gappy' | 'no_data', see [researchWindowFrom].
  final String? qualityStatus;

  final int featureVersion;

  /// Snapshot revision holding the rows these stats came from.
  final int? snapshotRevision;

  final String? metaJson;
}

/// One cuff reading plus its window, ready to store.
class BpResearchCapture {
  const BpResearchCapture({
    required this.measuredAtMs,
    required this.systolicMmHg,
    required this.diastolicMmHg,
    required this.capturedAtMs,
    required this.device,
    this.measurementStartedAtMs,
    this.measurementFinishedAtMs,
    this.timePrecision,
    this.posture,
    this.conditions,
    this.bandDeviceId,
    this.measurementSessionId,
    this.window,
  });

  /// When the reading was taken (the entry moment when not back-dated).
  /// Idempotency key together with [device].
  final int measuredAtMs;

  /// Cuff inflation start/finish when known; the UI leaves both null.
  final int? measurementStartedAtMs;

  final int? measurementFinishedAtMs;

  /// Precision of the user-reported time ('minute' from the UI).
  final String? timePrecision;

  /// When the pair was typed in.
  final int capturedAtMs;

  final double systolicMmHg;
  final double diastolicMmHg;

  /// The cuff, as the user named it.
  final String? device;

  /// The band the window was read from.
  final String? bandDeviceId;

  /// Free-form label grouping readings of one sitting.
  final String? measurementSessionId;

  final String? posture;
  final String? conditions;

  /// Null when the band had nothing decoded in the window.
  final BpResearchWindow? window;
}

/// Same bounds as `health_measurement_import.dart`; out of range is
/// rejected, never clamped.
const (double, double) kResearchSystolicBounds = (50, 300);
const (double, double) kResearchDiastolicBounds = (20, 200);

/// `beat_ts_ms` when present, else the record second (`rr_ts_ms`).
int _beatTimeMs(Map<String, Object?> r) {
  final beatTs = r['beat_ts_ms'];
  if (beatTs is num && beatTs > 0) return beatTs.toInt();
  final ts = r['rr_ts_ms'];
  return ts is num ? ts.toInt() : 0;
}

/// Beat identity: `beat_ts_ms` when present, else (rr_ts_ms, beat_index).
/// rr_ts_ms alone is shared by every beat of a record.
(String, int, int) _beatKey(Map<String, Object?> r) {
  final beatTs = r['beat_ts_ms'];
  if (beatTs is num && beatTs > 0) return ('b', beatTs.toInt(), 0);
  final ts = r['rr_ts_ms'];
  final idx = r['beat_index'];
  return ('r', ts is num ? ts.toInt() : 0, idx is num ? idx.toInt() : 0);
}

/// Beat time, then record time, then beat index.
int _beatOrder(Map<String, Object?> a, Map<String, Object?> b) {
  final at = _beatTimeMs(a);
  final bt = _beatTimeMs(b);
  if (at != bt) return at < bt ? -1 : 1;
  final ar = (a['rr_ts_ms'] as num?)?.toInt() ?? 0;
  final br = (b['rr_ts_ms'] as num?)?.toInt() ?? 0;
  if (ar != br) return ar < br ? -1 : 1;
  final ai = (a['beat_index'] as num?)?.toInt() ?? 0;
  final bi = (b['beat_index'] as num?)?.toInt() ?? 0;
  if (ai != bi) return ai < bi ? -1 : 1;
  return 0;
}

/// The window [measuredAtMs - preMs, measuredAtMs + postMs) from decoded
/// rows. Null when no row falls inside and the data is final.
///
/// Status: 'pending' while the window end is in the future ([nowMs]) or the
/// band's decoded data does not reach it yet ([dataThroughMs]); otherwise
/// 'no_data', 'gappy' (under half covered, or over half the pairs dropped
/// for gaps) or 'ok'. The thresholds are research defaults, not validated.
BpResearchWindow? researchWindowFrom({
  required int measuredAtMs,
  required List<Map<String, Object?>> onehzRows,
  required List<Map<String, Object?>> rrRows,
  int? preMs,
  int? postMs,
  int? maxGapMs,
  int? nowMs,
  int? dataThroughMs,
  String? deviceId,
  String? metaJson,
}) {
  final pre = preMs ?? kResearchRestPreMs;
  final post = postMs ?? kResearchWindowPostMs;
  final gap = maxGapMs ?? kResearchMaxBeatGapMs;
  final start = measuredAtMs - pre;
  final end = measuredAtMs + post;

  // decoded_onehz.rec_ts is epoch seconds.
  final onehz =
      onehzRows.where((r) {
        final ts = r['rec_ts'];
        return ts is num && ts * 1000 >= start && ts * 1000 < end;
      }).toList()..sort(
        (a, b) => ((a['rec_ts'] as num).toDouble()).compareTo(
          (b['rec_ts'] as num).toDouble(),
        ),
      );
  final onehzDedup = <Map<String, Object?>>[];
  {
    int? lastTs;
    for (final r in onehz) {
      final ts = (r['rec_ts'] as num).toInt();
      if (lastTs == ts) continue;
      lastTs = ts;
      onehzDedup.add(r);
    }
  }

  final rrAll = rrRows.where((r) {
    final t = _beatTimeMs(r);
    return t >= start && t < end;
  }).toList()..sort(_beatOrder);
  final rrDedup = <Map<String, Object?>>[];
  {
    (String, int, int)? lastKey;
    for (final r in rrAll) {
      final key = _beatKey(r);
      if (lastKey == key) continue;
      lastKey = key;
      rrDedup.add(r);
    }
  }

  // Data not final yet: the window end is in the future, or this band's
  // decoded data stops short of it. rec_ts is whole seconds, so the last
  // second inside [start, end) is end - 1000.
  final notFinal =
      (nowMs != null && end > nowMs) ||
      (dataThroughMs != null && dataThroughMs < end - 1000);
  if (onehzDedup.isEmpty && rrDedup.isEmpty) {
    // Keep a pending window row so a refresh can fill it later.
    if (notFinal) {
      return BpResearchWindow(
        windowStartMs: start,
        windowEndMs: end,
        qualityStatus: 'pending',
        featureVersion: kResearchFeatureVersion,
        metaJson: metaJson,
      );
    }
    return null;
  }

  final validHrRows = onehzDedup
      .where((r) {
        final h = r['hr'];
        return h is num && h.isFinite && h > 0;
      })
      .toList(growable: false);
  final hrMean = validHrRows.isEmpty
      ? null
      : validHrRows
                .map((r) => (r['hr'] as num).toDouble())
                .reduce((a, b) => a + b) /
            validHrRows.length;
  final validHrSeconds = validHrRows.isEmpty ? null : validHrRows.length;

  // RMSSD pairs only beats that are adjacent in the series AND within
  // [gap] of each other; an invalid beat breaks the chain.
  final validIntervals = <(int, double)>[]; // (beat_time_ms, rr_ms)
  var pairTotal = 0;
  var validPairs = 0;
  var sumSq = 0.0;
  (int, double)? prev;
  for (final r in rrDedup) {
    final v = r['rr_ms'];
    if (v is! num || !v.isFinite || v <= 0) {
      prev = null;
      continue;
    }
    final cur = (_beatTimeMs(r), v.toDouble());
    validIntervals.add(cur);
    if (prev != null) {
      pairTotal++;
      if (cur.$1 - prev.$1 <= gap) {
        final d = cur.$2 - prev.$2;
        sumSq += d * d;
        validPairs++;
      }
    }
    prev = cur;
  }

  double? rrMean, rrMin, rrMax;
  if (validIntervals.isNotEmpty) {
    final values = validIntervals.map((p) => p.$2).toList(growable: false);
    rrMean = values.reduce((a, b) => a + b) / values.length;
    rrMin = values.reduce((a, b) => a < b ? a : b);
    rrMax = values.reduce((a, b) => a > b ? a : b);
  }
  final rmssd = validPairs > 0 ? sqrt(sumSq / validPairs) : null;
  final rejectedPairFraction = pairTotal == 0
      ? null
      : 1.0 - (validPairs / pairTotal);

  final windowSeconds = (end - start) / 1000.0;
  final coverage = validHrSeconds == null || windowSeconds <= 0
      ? null
      : validHrSeconds / windowSeconds;

  final String status;
  if (notFinal) {
    status = 'pending';
  } else if (validHrRows.isEmpty && validIntervals.isEmpty) {
    status = 'no_data';
  } else if ((rejectedPairFraction != null && rejectedPairFraction > 0.5) ||
      (coverage != null && coverage < 0.5)) {
    status = 'gappy';
  } else {
    status = 'ok';
  }

  int? observedStart;
  int? observedEnd;
  final o1 = validHrRows.isNotEmpty
      ? (validHrRows.first['rec_ts'] as num).toInt() * 1000
      : null;
  final o2 = validIntervals.isNotEmpty ? validIntervals.first.$1 : null;
  final e1 = validHrRows.isNotEmpty
      ? (validHrRows.last['rec_ts'] as num).toInt() * 1000
      : null;
  final e2 = validIntervals.isNotEmpty ? validIntervals.last.$1 : null;
  if (o1 != null && o2 != null) {
    observedStart = o1 < o2 ? o1 : o2;
    observedEnd = (e1 ?? o1) > (e2 ?? o2) ? (e1 ?? o1) : (e2 ?? o2);
  } else {
    observedStart = o1 ?? o2;
    observedEnd = e1 ?? e2;
  }

  return BpResearchWindow(
    windowStartMs: start,
    windowEndMs: end,
    observedStartMs: observedStart,
    observedEndMs: observedEnd,
    onehzRows: onehzDedup.isEmpty ? null : onehzDedup.length,
    rrBeats: rrDedup.isEmpty ? null : rrDedup.length,
    hrMean: hrMean,
    rrMsMean: rrMean,
    rrMsMin: rrMin,
    rrMsMax: rrMax,
    rmssdMs: rmssd,
    validHrSeconds: validHrSeconds,
    validIntervalCount: validIntervals.isEmpty ? null : validIntervals.length,
    validIntervalPairCount: validPairs == 0 ? null : validPairs,
    coverageFraction: coverage,
    rejectedIntervalFraction: rejectedPairFraction,
    qualityStatus: status,
    featureVersion: kResearchFeatureVersion,
    metaJson: metaJson,
  );
}
