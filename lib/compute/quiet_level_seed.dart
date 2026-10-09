// ONE-SHOT SEED — `quiet_hrr` history for installs that predate it.
//
// Strain is priced against the median of the trailing days' own quiet-waking
// level (`quiet_hrr`), and abstains below three of them. A derive writes that
// series going forward, but raw 1 Hz substrate is pruned `rawRetentionDays`
// behind the data edge, so a re-derive reaches only the last few days: without
// this every existing user would start at zero prior levels and see strain go
// blank for days.
//
// It does not need raw. Every stored bundle still carries the day's per-minute
// wake HR in two halves: `series.strain_curve` has one point per WAKE minute
// (its `t` values are exactly the wake-minute keys), and `series.hr_curve` is
// the per-minute mean HR for every minute, rounded to whole bpm. Their join is
// the wake series the pipeline scored, to within ±0.5 bpm (≈0.004 HRR), so the
// seeded median is the user's own measurement, not an estimate of it. Days
// whose curve was dropped by the v63 strain rescale yield nothing and are
// skipped; the series then fills naturally.

import 'dart:isolate';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import '../data/series_codec.dart';
import 'hr_max.dart';

/// `compute_freshness` key marking the seed as applied.
const String kQuietHrrSeedKey = 'quiet_hrr_seed_v1';

/// Pure: this stored day's quiet-waking HRR, or null. [payload] is a decoded
/// bundle (`SeriesCodec.decodePayloadJson`, so curves are `[{t, v}]` lists).
/// [manualRestingHr] stands in only for a missing NOCTURNAL resting HR — the
/// same pair, in the same order, the day's own TRIMP is anchored on.
///
/// The ceiling is [estimatedMaxHr] at the CURRENT profile [ageYears], exactly
/// what the live derive prices `quiet_hrr` on — not the bundle's stored
/// `max_hr_used`, which a later birthday or profile edit leaves on another
/// scale. Null without an age, as the live derive is.
double? quietHrrFromStoredBundle(
  Map<String, dynamic> payload, {
  required num? ageYears,
  double? manualRestingHr,
}) {
  final scalars = payload['scalars'] is Map
      ? payload['scalars'] as Map
      : const <String, dynamic>{};
  final series = payload['series'] is Map
      ? payload['series'] as Map
      : const <String, dynamic>{};
  final rhr = (scalars['rhr_nocturnal'] as num?)?.toDouble() ?? manualRestingHr;
  final hrMax = estimatedMaxHr(ageYears, payload['device_family'] as String?);
  final wake = <int>{
    for (final p in (series['strain_curve'] as List? ?? const []))
      if (p is Map && p['t'] is num) (p['t'] as num).toInt(),
  };
  final hr = <double>[
    for (final p in (series['hr_curve'] as List? ?? const []))
      if (p is Map &&
          p['t'] is num &&
          p['v'] is num &&
          wake.contains((p['t'] as num).toInt()))
        (p['v'] as num).toDouble(),
  ];
  return ana.dailyQuietWakingHrr(
    hr,
    restingHr: rhr,
    maxHr: hrMax,
    minMinutes: ana.quietHrrTraitMinMinutes,
  );
}

/// Seed `quiet_hrr` for the trailing window of stored days, once.
///
/// Skips imported days (another vendor's numbers, no 1 Hz wake series),
/// skipped and partial rows (a partial day must not seed the trait, the same
/// reason `putDayResult` skips its series write), and days that already have a
/// value — a derive's own measurement is never overwritten. Decoding and the
/// median run off the UI isolate. Returns the number of days written.
///
/// Without [ageYears] there is no ceiling to price on: nothing is seeded and
/// the seed stays armed for a pass that has one.
Future<int> seedQuietHrrHistoryOnce({
  required num? ageYears,
  double? manualRestingHr,
}) async {
  if (await LocalDb.computeFreshness(kQuietHrrSeedKey) != null) return 0;
  if (ageYears == null) return 0;
  final imported = await LocalDb.importedDates();
  final have = {
    for (final r in await LocalDb.metricSeries('quiet_hrr'))
      r['date'] as String,
  };
  // The window is over MEASURED days, chosen before it is applied: a long
  // import (or a run of skipped/partial rows) newer than them must not fill
  // the window and leave the levels that are recoverable unseeded. Every
  // served day, payload-free (LIMIT -1 is SQLite's "no limit"); bundles are
  // then read one day at a time.
  final measured = [
    for (final r in await LocalDb.recentDayResultsMeta(-1))
      if (r['day_id'] is String &&
          !imported.contains(r['day_id']) &&
          (r['skipped'] as num?)?.toInt() != 1 &&
          (r['partial'] as num?)?.toInt() != 1)
        r['day_id'] as String,
  ].take(ana.quietHrrWindowDays + 3);
  final todo = <(String, String)>[
    for (final day in measured)
      if (!have.contains(day))
        if ((await LocalDb.dayResult(day))?['payload_json'] case final String j)
          (day, j),
  ];
  final levels = todo.isEmpty
      ? const <(String, double)>[]
      : await Isolate.run(() => [
            for (final (date, json) in todo)
              if (SeriesCodec.decodePayloadJson(json) case final p?)
                if (quietHrrFromStoredBundle(p,
                        ageYears: ageYears, manualRestingHr: manualRestingHr)
                    case final q?)
                  (date, q),
          ]);
  for (final (date, q) in levels) {
    await LocalDb.putMetricSeriesValue(date, 'quiet_hrr', q);
  }
  await LocalDb.putComputeFreshness(kQuietHrrSeedKey, '{"done":true}');
  return levels.length;
}
