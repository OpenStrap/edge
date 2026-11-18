// ONE-SHOT BACKFILL — stored stress scores onto the recalibrated floor (#631).
//
// The Baevsky SI → 0-100 map used to floor at SI 20, so every genuinely low
// night (Baevsky's own "low" band is SI < 50) read as a flat 0 and high-HRV
// sleepers saw 0 every single night. The floor is now `kStressScoreFloorSi`.
// Every day derived before that change carries a score on the old scale, so the
// stress trend and the day-detail screen would show a step at the release date
// rather than a real change.
//
// WHY NOT JUST RE-DERIVE: raw 1 Hz substrate is pruned `rawRetentionDays` behind
// the data edge, so a kAlgoVersion bump alone can only fix the last few days and
// leaves the rest flat at 0.
//
// It does not need raw. The new score is a PURE function of the Baevsky index,
// and each stored day_result already carries its own `stress.si`. So — unlike
// `backfillStrainScale`, which needs TRIMP, a wake window and a quiet-waking
// level — this rescale has every input in the bundle it is rewriting, needs no
// baseline and no warm-up, and can mark itself done on the first pass.
//
// ONE SOURCE for the mapping: this reads `stress.si` and calls the same
// `stressScoreFromSi` the live derive uses, so a rescaled day and a freshly
// derived one price an identical index identically.

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/day_label.dart';
import '../data/db.dart';
import 'derivation_engine.dart' show kAlgoVersion, rawRetentionDays;
import 'onehz_pipeline.dart' show stressScoreFromSi;

/// `compute_freshness` key marking the rescale as applied. Bumped with the algo
/// version so a later recalibration is a new one-shot rather than a no-op.
const String kStressRescaleKey = 'stress_rescale_v125';

class StressBackfillResult {
  /// Days whose `metric_series` stress score was rewritten (trend / v_daily).
  final int seriesDays;

  /// Days that got a fresh `day_result` row at the current algo version.
  final int bundleDays;

  /// Days left exactly as they were because they could not be rescaled.
  final int skipped;

  const StressBackfillResult({
    required this.seriesDays,
    required this.bundleDays,
    required this.skipped,
  });

  bool get didWork => seriesDays > 0 || bundleDays > 0;
}

/// Rescale every stored day that can no longer be re-derived from raw. Returns
/// without marking done only when there is nothing yet to walk; otherwise it is
/// a one-shot. Set [force] to re-run.
Future<StressBackfillResult> backfillStressScale({bool force = false}) async {
  const none = StressBackfillResult(seriesDays: 0, bundleDays: 0, skipped: 0);
  if (!force && await LocalDb.computeFreshness(kStressRescaleKey) != null) {
    return none;
  }

  final stressRows = await LocalDb.metricSeries('stress');
  if (stressRows.isEmpty) {
    await _markDone();
    return none;
  }

  final days = <String>[
    for (final r in stressRows) ?(r['date'] as String?),
  ]..sort();
  // Days at or after the cutoff still have raw and are LEFT for a real
  // re-derive: writing a patched row at kAlgoVersion here would satisfy the
  // derive gate (which matches algo_version EXACTLY) and stand in for a full
  // re-derivation of the day.
  final cutoff = stressRescaleCutoff(days.last);

  var seriesDays = 0;
  var bundleDays = 0;
  var skipped = 0;

  // Days already complete at the current version were rescaled on a prior pass.
  final alreadyCurrent = await LocalDb.dayResultIds(kAlgoVersion);

  for (final day in days) {
    if (day.compareTo(cutoff) >= 0) continue;
    if (alreadyCurrent.contains(day)) continue;

    final row = await LocalDb.dayResult(day);
    if (row == null) {
      // A series row with no bundle behind it: nothing to rewrite the detail
      // screen from. Leave the trend point alone rather than diverge the two.
      skipped++;
      continue;
    }
    if (((row['algo_version'] as num?)?.toInt() ?? 0) >= kAlgoVersion) {
      continue;
    }

    final payload = _decode(row['payload_json']);
    if (payload == null) {
      skipped++;
      continue;
    }
    final stressBlk = payload['stress'];
    if (stressBlk is! Map) {
      skipped++;
      continue;
    }
    final si = (stressBlk['si'] as num?)?.toDouble();
    final next = stressScoreFromSi(si);
    if (next == null) {
      // No usable index on this day. A rescaled day must not become 0, which is
      // a score, not an absence — leave it exactly as it was.
      skipped++;
      continue;
    }
    final rounded = _round1(next);
    // The block is {value, score, si, level, ...}; `value` and `score` are the
    // rounded headline the screens read, `si`/`level` are unchanged.
    stressBlk['score'] = rounded;
    stressBlk['value'] = rounded;
    // The derive also writes the unrounded score into `scalars`, which the
    // rollup and cross-day reads use, so it moves with the block.
    final scalars = payload['scalars'];
    if (scalars is Map) scalars['stress'] = next;

    final partial = (row['partial'] as num?)?.toInt() == 1;
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: (row['window_json'] as String?) ?? '{}',
      finalized: (row['finalized'] as num?)?.toInt() == 1,
      skipped: (row['skipped'] as num?)?.toInt() == 1,
      partial: partial,
      rhr: (row['rhr'] as num?)?.toDouble(),
      rmssd: (row['rmssd'] as num?)?.toDouble(),
      readiness: (row['readiness'] as num?)?.toDouble(),
      // Rewriting a band-derived day's stress from its own stored index — same
      // provenance it already had.
      source: 'band',
      // `putDayResult` skips the series write for a partial row, so only count
      // the trend as rewritten when it actually was.
      // Unrounded, like the derive's `'stress': sc('stress')` series write.
      series: {'stress': next},
    );
    bundleDays++;
    if (!partial) seriesDays++;
  }

  await _markDone();
  return StressBackfillResult(
    seriesDays: seriesDays,
    bundleDays: bundleDays,
    skipped: skipped,
  );
}

Future<void> _markDone() =>
    LocalDb.putComputeFreshness(kStressRescaleKey, jsonEncode({'done': true}));

double _round1(double v) => (v * 10).round() / 10;

Map<String, dynamic>? _decode(Object? json) {
  if (json is! String) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// The first day still treated as having raw, [rawRetentionDays] CALENDAR days
/// before the data edge [lastDay]. Calendar arithmetic (not an absolute
/// `Duration`), matching the pruner's cut on local day labels, so a DST day does
/// not pull the cutoff a day early. A malformed label falls back to itself,
/// which leaves every day for a re-derive — the safe side.
@visibleForTesting
String stressRescaleCutoff(String lastDay) =>
    dayLabelBefore(lastDay, rawRetentionDays) ?? lastDay;
