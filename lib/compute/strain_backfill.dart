// ONE-SHOT BACKFILL — stored strain onto the recalibrated 0–21 scale.
//
// The headline strain map changed: it used to be `min(21, ln(TRIMP+1)/ln(1.5))`
// over whole-waking-day TRIMP, which charged ~180 TRIMP of simply being awake
// as training load and put an INACTIVE full-wear day at ~13/21. It is now the
// load earned ABOVE a quiet-waking baseline that scales with the wake window.
// Every day derived before that change carries a number on the old scale, so
// trends, v_daily/coach SQL and the day-detail screen would show a step change
// at the fix date rather than a real one in the user's training.
//
// WHY NOT JUST RE-DERIVE: raw 1 Hz substrate is pruned `rawRetentionDays` (3)
// behind the DATA EDGE. For anything older there is no substrate — the engine
// logs "no substrate (raw pruned) — kept" and keeps the old row — so a
// kAlgoVersion bump alone can only ever fix the last few days.
//
// It does not need raw. Strain is a pure function of (TRIMP, wake minutes,
// sex); `metric_series` stores `trimp` and the stored bundle carries
// `series.strain_curve`, which is ONE POINT PER WAKE MINUTE — literally the
// series the pipeline handed the scorer.
//
// THE WAKE WINDOW IS READ, NOT RECONSTRUCTED. This used to derive it as
// `worn_min − tst_min`, which is a different quantity in both directions: the
// pipeline's wake series skips minutes with no HR and skips the whole sleep
// span, `worn_min` counts any minute with a record and applies no HR gate, and
// `tst_min` excludes WASO. Measured against `strain_curve` on six real days it
// was off by −15 to +22 minutes on all six, so the header's old claim that the
// two are equal "on a real bundle" was false every time it was checkable. A day
// whose bundle cannot supply the curve now ABSTAINS — the point of this file is
// to remove a step artifact, not to introduce a smaller one.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/day_label.dart';
import '../data/db.dart';
import 'derivation_engine.dart' show kAlgoVersion, rawRetentionDays;

/// `compute_freshness` key marking the rescale as already applied. Bumped with
/// the algo version so a future rescale is a new one-shot rather than a no-op.
const String kStrainRescaleKey = 'strain_rescale_v63';

class StrainBackfillResult {
  /// Days whose `metric_series` strain was rewritten (trends / v_daily).
  final int seriesDays;

  /// Days that got a fresh `day_result` row at the current algo version.
  final int bundleDays;

  /// Days left exactly as they were because they could not be rescaled.
  final int skipped;

  const StrainBackfillResult({
    required this.seriesDays,
    required this.bundleDays,
    required this.skipped,
  });

  bool get didWork => seriesDays > 0 || bundleDays > 0;
}

/// Rebuild one day's headline strain from its stored TRIMP and the wake window
/// the pipeline actually priced it over ([wakeMinutes] = `strain_curve.length`).
///
/// Returns null when the day cannot be rescaled — no TRIMP to rescale from, or
/// no wake window to price the baseline over. A day that cannot be rescaled is
/// LEFT ALONE: an un-rescalable day must not silently become 0, which is a
/// number, not an absence.
double? rescaledStrain({
  required double? trimp,
  required double? wakeMinutes,
  required bool female,
}) {
  if (trimp == null || wakeMinutes == null || wakeMinutes <= 0) return null;
  return ana.strainScore(
    trimp,
    wakeMinutes: wakeMinutes,
    // Reference level, not this user's — see onehz_pipeline's
    // `strainMetric` for why, and edge#226 for the fix.
    quietHrr: ana.quietWakingHrr,
    female: female,
  );
}

/// Rescale every stored day that can no longer be re-derived from raw.
///
/// [female] selects the Banister constant for the quiet-waking baseline; it has
/// to match the constant the stored TRIMP was scored with or the subtraction is
/// off by the male/female coefficient. Runs once — set [force] to re-run.
Future<StrainBackfillResult> backfillStrainScale({
  required bool female,
  bool force = false,
}) async {
  const none = StrainBackfillResult(seriesDays: 0, bundleDays: 0, skipped: 0);
  if (!force && await LocalDb.computeFreshness(kStrainRescaleKey) != null) {
    return none;
  }

  final strainRows = await LocalDb.metricSeries('strain');
  if (strainRows.isEmpty) {
    await _markDone();
    return none;
  }

  final trimpBy = await _byDate('trimp');

  // The DATA EDGE is the newest day on disk, matching how the pruner measures
  // retention (never the wall clock — a multi-day flash backfill received in
  // one sync must not be treated as old). Days at or after the cutoff still
  // have raw and are LEFT for a real re-derive: writing a patched row at
  // kAlgoVersion here would satisfy the derive gate, which matches
  // algo_version EXACTLY, and a partial patch would stand in for a full
  // re-derivation of the day.
  final days = <String>[
    for (final r in strainRows) ?(r['date'] as String?),
  ]..sort();
  final cutoff = _shiftDays(days.last, -rawRetentionDays);

  var seriesDays = 0;
  var bundleDays = 0;
  var skipped = 0;

  // Days already complete at the current version were rescaled on a prior
  // pass. Read as ONE query so the loop below does not open a `day_result` row
  // just to close it again: this runs once per install-history, and the day
  // this fires is the launch right after an update.
  final alreadyCurrent = await LocalDb.dayResultIds(kAlgoVersion);

  for (final day in days) {
    if (day.compareTo(cutoff) >= 0) continue;
    if (alreadyCurrent.contains(day)) continue;

    // Cheapest gate first: a day with no stored TRIMP cannot be rescaled at
    // all, and finding that out by opening its bundle was a round trip plus a
    // payload materialisation per unrescalable day. The wake window itself has
    // to come out of the bundle (`strain_curve`), so everything else waits for
    // the row.
    if (trimpBy[day] == null) {
      skipped++;
      continue;
    }

    final row = await LocalDb.dayResult(day);
    // A partial/skipped row at the current version is not in `alreadyCurrent`
    // but is still rescaled — same check as before, just reached less often.
    if (row != null &&
        ((row['algo_version'] as num?)?.toInt() ?? 0) >= kAlgoVersion) {
      continue;
    }

    if (row == null) {
      // A series row with no bundle behind it. The wake window lives in the
      // bundle, so there is nothing to price the baseline over — leave the old
      // value alone rather than rescale it against a window we guessed.
      skipped++;
      continue;
    }

    final payload = _decode(row['payload_json']);
    if (payload == null) {
      skipped++;
      continue;
    }
    final scalars = payload['scalars'];
    if (scalars is! Map) {
      skipped++;
      continue;
    }
    final series = payload['series'];
    final next = rescaledStrain(
      trimp: trimpBy[day],
      // THE window the pipeline scored over: `strain_curve` emits exactly one
      // point per wake minute (`_strainCurve` in onehz_pipeline.dart). Stored
      // either as a legacy list or as SeriesCodec's columnar form, hence
      // `_curveLength`.
      wakeMinutes: _curveLength(
        series is Map ? series['strain_curve'] : null,
      )?.toDouble(),
      female: female,
    );
    if (next == null) {
      skipped++;
      continue;
    }
    scalars['strain'] = next;

    // The intraday curve is cumulative strain, one point per wake minute, built
    // from per-sample HR that no longer exists — it cannot be rescaled, and its
    // last point IS the old headline. A curve ending at 12.79 under a headline
    // of 9.03 contradicts itself, so it is DROPPED rather than left to disagree.
    // (Its LENGTH was read above, before this removes it.)
    if (series is Map) series.remove('strain_curve');

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
      // Rewriting a band-derived day's strain from its own stored payload —
      // same provenance it already had (see export-provenance).
      source: 'band',
      // `putDayResult` skips the series write for a partial row, so only count
      // the trend as rewritten when it actually was.
      series: {'strain': next},
    );
    bundleDays++;
    if (!partial) seriesDays++;
  }

  await _markDone();
  return StrainBackfillResult(
    seriesDays: seriesDays,
    bundleDays: bundleDays,
    skipped: skipped,
  );
}

Future<void> _markDone() =>
    LocalDb.putComputeFreshness(kStrainRescaleKey, jsonEncode({'done': true}));

Future<Map<String, double>> _byDate(String key) async {
  final out = <String, double>{};
  for (final r in await LocalDb.metricSeries(key)) {
    final d = r['date'] as String?;
    final v = (r['value'] as num?)?.toDouble();
    if (d != null && v != null) out[d] = v;
  }
  return out;
}

/// Number of samples in a stored curve, in either shape SeriesCodec can write:
/// the legacy `[{t,v}, …]` list or the columnar `{t0, dt|to, v:[…]}` map.
/// Null when there is no curve to count.
int? _curveLength(Object? curve) {
  if (curve is List) return curve.isEmpty ? null : curve.length;
  if (curve is Map) {
    final v = curve['v'];
    if (v is List && v.isNotEmpty) return v.length;
  }
  return null;
}

Map<String, dynamic>? _decode(Object? json) {
  if (json is! String) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Shift a 'YYYY-MM-DD' label by [days] calendar days.
String _shiftDays(String day, int days) =>
    dayLabelOf(DateTime.parse(day).add(Duration(days: days)));
