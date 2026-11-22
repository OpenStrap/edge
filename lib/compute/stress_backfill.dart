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
// the data edge, so a kAlgoVersion bump alone can only fix the last few days.
//
// It does not need raw. The new score is a PURE function of the Baevsky index,
// and each stored day_result already carries its own `stress.si`.
//
// IN PLACE, NOT A NEW VERSION ROW. The rescale rewrites only the stress score
// (`stress.score`/`value`, `scalars.stress`, the `stress` trend point) of the
// rows that exist, at the version they already have. It does not stamp a day
// current, so:
//   * a day that still has raw is still re-derived by the version gate (no
//     guess at where the raw window ends is needed);
//   * the strain and readiness one-shots, which key on the row's version,
//     still see every day they are owed;
//   * provenance (device family, coverage, method stamps, naps) is untouched.
// The rewrite is idempotent (score = f(stored si)), so a row a fresh derive
// already wrote is a no-op.
//
// ONE source for the mapping: `stressScoreFromSi`, the same function the live
// derive calls.

import 'dart:convert';

import '../data/db.dart';
import '../data/series_codec.dart';
import 'onehz_pipeline.dart' show stressScoreFromSi;

/// `compute_freshness` key marking the rescale as applied. Bumped with the algo
/// version so a later recalibration is a new one-shot rather than a no-op.
const String kStressRescaleKey = 'stress_rescale_v125';

class StressBackfillResult {
  /// Days whose `metric_series` stress score was rewritten (trend / v_daily).
  final int seriesDays;

  /// `day_result` rows whose stress score was rewritten in place.
  final int bundleDays;

  /// Rows left exactly as they were: no usable index, imported, or unreadable.
  final int skipped;

  const StressBackfillResult({
    required this.seriesDays,
    required this.bundleDays,
    required this.skipped,
  });

  bool get didWork => seriesDays > 0 || bundleDays > 0;
}

/// Rescale every stored stress score in place. A one-shot once it has walked a
/// non-empty store; an empty store is not marked, so rows a restore merges in
/// later are still rescaled. Set [force] to re-run.
Future<StressBackfillResult> backfillStressScale({bool force = false}) async {
  const none = StressBackfillResult(seriesDays: 0, bundleDays: 0, skipped: 0);
  if (!force && await LocalDb.computeFreshness(kStressRescaleKey) != null) {
    return none;
  }

  final db = await LocalDb.instance;
  final days = [
    for (final r in await db.rawQuery(
        'SELECT DISTINCT day_id FROM day_result WHERE day_id IS NOT NULL '
        'ORDER BY day_id'))
      r['day_id'] as String,
  ];
  if (days.isEmpty) return none;

  var seriesDays = 0;
  var bundleDays = 0;
  var skipped = 0;

  for (final day in days) {
    // One transaction per day: the rows are read and rewritten together, so a
    // derive in another isolate cannot land between the read and the write
    // and be overwritten by an older payload.
    await db.transaction((txn) async {
      final rows = await txn.query('day_result',
          columns: ['algo_version', 'payload_json', 'partial'],
          where: 'day_id = ?',
          whereArgs: [day],
          orderBy: 'algo_version DESC');
      // The build that last wrote this day's series, when stamped.
      final stamp = ((await txn.query('metric_series_version',
                  columns: ['algo_version'],
                  where: 'date = ?',
                  whereArgs: [day]))
              .firstOrNull?['algo_version'] as num?)
          ?.toInt();
      double? seriesScore;
      var seriesPicked = false;
      for (final row in rows) {
        final payload = _decode(row['payload_json']);
        final blk = payload?['stress'];
        final si = blk is Map ? _finite(blk['si']) : null;
        final next = stressScoreFromSi(si);
        // The trend point comes ONLY from the row that wrote it: the stamped
        // writer, else the newest complete row (a partial row never writes the
        // series). If that row has no usable score the trend stays as it is.
        if (!seriesPicked &&
            (row['partial'] as num?)?.toInt() != 1 &&
            (stamp == null || (row['algo_version'] as num?)?.toInt() == stamp)) {
          seriesPicked = true;
          if (payload?['imported'] != true) seriesScore = next;
        }
        // No usable index, or another source's day: a rescaled day must not
        // become 0 (a score, not an absence), and an imported score is not
        // ours to re-price.
        if (payload == null || next == null || payload['imported'] == true) {
          skipped++;
          continue;
        }
        final rounded = _round1(next);
        final scalars = payload['scalars'];
        if ((blk as Map)['score'] == rounded &&
            blk['value'] == rounded &&
            (scalars is! Map || scalars['stress'] == next)) {
          continue; // already on the new scale
        }
        // `value`/`score` are the rounded headline the screens read; the
        // derive also writes the unrounded score into `scalars`.
        blk['score'] = rounded;
        blk['value'] = rounded;
        if (scalars is Map) scalars['stress'] = next;
        await txn.update(
          'day_result',
          {'payload_json': SeriesCodec.encodePayloadJson(jsonEncode(payload))},
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [day, row['algo_version']],
        );
        bundleDays++;
      }
      if (seriesScore == null) return;
      // UPDATE only: never create a trend point the derive did not write, and
      // leave a day whose series another source produced alone.
      final n = await txn.rawUpdate(
        "UPDATE metric_series SET value = ? WHERE date = ? AND key = 'stress' "
        'AND (value IS NULL OR value <> ?) AND NOT EXISTS (SELECT 1 FROM '
        'metric_series_version v WHERE v.date = ? AND COALESCE(v.source, \'band\') '
        "<> 'band')",
        [seriesScore, day, seriesScore, day],
      );
      if (n > 0) seriesDays++;
    });
  }

  await LocalDb.putComputeFreshness(
      kStressRescaleKey, jsonEncode({'done': true}));
  return StressBackfillResult(
    seriesDays: seriesDays,
    bundleDays: bundleDays,
    skipped: skipped,
  );
}

/// A finite number, or null — a wrong-typed index is skipped, not thrown on.
double? _finite(Object? v) {
  if (v is! num) return null;
  final d = v.toDouble();
  return d.isFinite ? d : null;
}

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
