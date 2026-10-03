// BP research capture (developer mode only): a cuff reading the user typed in,
// paired with the band's decoded data from the minutes around it, for
// analysis outside the app via the CSV export. Nothing derived reads these
// tables (bp_research_isolation_test.dart). No band data = NULL window.

import 'dart:math' as math;

/// Window half-widths around the cuff instant.
const int kBpResearchWindowPreMs = 2 * 60 * 1000;
const int kBpResearchWindowPostMs = 2 * 60 * 1000;

/// The band window around one reference instant. A stat that can't be
/// computed (no valid HR, no beats) is null, not zero.
class BpResearchWindow {
  const BpResearchWindow({
    required this.windowStartMs,
    required this.windowEndMs,
    this.onehzRows,
    this.rrBeats,
    this.hrMean,
    this.rrMsMean,
    this.rrMsMin,
    this.rrMsMax,
    this.rmssdMs,
    this.metaJson,
  });

  final int windowStartMs;
  final int windowEndMs;
  final int? onehzRows;
  final int? rrBeats;
  final double? hrMean;
  final double? rrMsMean;
  final double? rrMsMin;
  final double? rrMsMax;
  final double? rmssdMs;

  /// Optional provenance JSON, stored verbatim.
  final String? metaJson;
}

/// One cuff reference reading plus its window, ready to store.
class BpResearchCapture {
  const BpResearchCapture({
    required this.measuredAtMs,
    required this.systolicMmHg,
    required this.diastolicMmHg,
    required this.capturedAtMs,
    required this.device,
    this.posture,
    this.conditions,
    this.window,
  });

  final int measuredAtMs;
  final double systolicMmHg;
  final double diastolicMmHg;
  final int capturedAtMs;

  /// The cuff's own name ('OMRON', 'Withings BPM', …). NULL when the user
  /// typed a bare pair of numbers with no device named.
  final String? device;
  final String? posture;
  final String? conditions;

  /// Null when the band had nothing decoded in the window.
  final BpResearchWindow? window;
}

/// Same bounds as `health_measurement_import.dart`. Out-of-range input is
/// rejected, never clamped.
const (double, double) kResearchSystolicBounds = (50, 300);
const (double, double) kResearchDiastolicBounds = (20, 200);

/// Window stats around [measuredAtMs] from `decoded_onehz` / `decoded_rr`
/// rows (rr rows ordered by `rr_ts_ms, beat_index`). Null when neither table
/// has a row in the window.
BpResearchWindow? researchWindowFrom({
  required int measuredAtMs,
  required List<Map<String, Object?>> onehzRows,
  required List<Map<String, Object?>> rrRows,
  int? preMs,
  int? postMs,
  String? deviceId,
  String? metaJson,
}) {
  final pre = preMs ?? kBpResearchWindowPreMs;
  final post = postMs ?? kBpResearchWindowPostMs;
  final start = measuredAtMs - pre;
  final end = measuredAtMs + post;

  // decoded_onehz.rec_ts is epoch SECONDS; rr is rr_ts_ms (epoch ms).
  final onehz = onehzRows
      .where((r) {
        final ts = r['rec_ts'];
        return ts is int && ts * 1000 >= start && ts * 1000 <= end;
      })
      .toList(growable: false);
  final rr = rrRows
      .where((r) {
        final ts = r['rr_ts_ms'];
        return ts is int && ts >= start && ts <= end;
      })
      .toList(growable: false);

  if (onehz.isEmpty && rr.isEmpty) return null;

  // hr 0 / null is "no reading", not a heart rate.
  final hrs = onehz
      .map((r) => r['hr'])
      .whereType<int>()
      .where((h) => h > 0)
      .toList(growable: false);
  final hrMean = hrs.isEmpty
      ? null
      : hrs.reduce((a, b) => a + b) / hrs.length;

  final rrs = rr
      .map((r) => r['rr_ms'])
      .whereType<num>()
      .map((v) => v.toDouble())
      .toList(growable: false);
  double? rrMean, rrMin, rrMax, rmssd;
  if (rrs.isNotEmpty) {
    rrMean = rrs.reduce((a, b) => a + b) / rrs.length;
    rrMin = rrs.reduce((a, b) => a < b ? a : b);
    rrMax = rrs.reduce((a, b) => a > b ? a : b);
    // Raw RMSSD over successive beats, no ectopic or gap rejection.
    if (rrs.length >= 2) {
      var sumSq = 0.0;
      for (var i = 1; i < rrs.length; i++) {
        final d = rrs[i] - rrs[i - 1];
        sumSq += d * d;
      }
      rmssd = math.sqrt(sumSq / (rrs.length - 1));
    }
  }

  return BpResearchWindow(
    windowStartMs: start,
    windowEndMs: end,
    onehzRows: onehz.isEmpty ? null : onehz.length,
    rrBeats: rr.isEmpty ? null : rr.length,
    hrMean: hrMean,
    rrMsMean: rrMean,
    rrMsMin: rrMin,
    rrMsMax: rrMax,
    rmssdMs: rmssd,
    metaJson: metaJson,
  );
}
