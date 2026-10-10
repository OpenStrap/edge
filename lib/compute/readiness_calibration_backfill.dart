// ONE-SHOT BACKFILL — readiness onto the calibrated mapping (v112).
//
// Readiness changed in two ways: HRV and RHR now form one autonomic input
// (mean of their oriented z's, weight 0.70), and the score is mapped through
// the user's own composite-z spread once 14 prior nights exist
// and re-centred on its capped median (`calibratedReadinessScore`). Both need a history of composite z's that no
// day derived before v112 wrote.
//
// Neither needs raw. Every stored bundle carries the composite's drivers, and
// each driver's detail holds the ORIENTED z that input contributed
// (`oriented robust-z (median+MAD)=…`). The per-input z's are unchanged by
// this release, so the new composite is an exact function of them. This
// file:
//   1. writes `readiness_z` for every stored day whose drivers allow it (the
//      history the calibration needs, going back as far as bundles do);
//   2. re-scores days the derive can no longer reach (no raw substrate left)
//      from that z and the calibration over the days before it. Days that
//      still have substrate are LEFT for the real re-derive the version bump
//      triggers.
// Split in two so the first v112 pass derives today promptly: a bounded seed
// of the recent window runs before the derive ([seedRecentReadinessZ]), the
// history-wide work after it ([backfillReadinessCalibration]).
// A day without a published headline (absent composite, or one the z-cap
// withheld) or without parseable drivers is left exactly as it was.

import 'dart:convert';
import 'dart:isolate';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import 'derivation_engine.dart' show kAlgoVersion, rawRetentionDays;

/// `compute_freshness` key marking the backfill as applied.
const String kReadinessCalibrationKey = 'readiness_calibration_v112';

/// The disclosed weight of each readiness input, read off the analytics
/// constructors so this can never drift from what a derive uses.
final Map<String, double> _weights = {
  for (final i in [
    ana.hrvInput(null, const []),
    ana.rhrInput(null, const []),
    ana.respInput(null, const []),
    ana.tempInput(null, const []),
  ])
    i.label: i.weight,
};

/// The new composite z of a stored bundle, rebuilt from its drivers' oriented
/// z's; null when the bundle published no headline readiness or its drivers
/// cannot be read. Also returns the per-label contributions.
({double z, Map<String, double> contributions})? storedReadinessZ(
    Map<String, dynamic> payload) {
  final scalars = payload['scalars'];
  if (scalars is! Map || scalars['readiness'] is! num) return null;
  final rc = (payload['clinical'] as Map?)?['readiness_composite'];
  final drivers = rc is Map ? rc['drivers'] : null;
  if (drivers is! List || drivers.isEmpty) return null;
  final used = <({String label, double weight, double orientedZ})>[];
  for (final d in drivers) {
    if (d is! Map) return null;
    final label = d['label'], detail = d['detail'];
    final w = _weights[label];
    if (label is! String || w == null || detail is! String) return null;
    final z = double.tryParse(detail.split('=').last);
    if (z == null) return null;
    used.add((label: label, weight: w, orientedZ: z));
  }
  final c = ana.combineReadinessZ(used);
  return (z: c.z, contributions: c.contributions);
}

/// Rewrite [payload]'s readiness to the calibrated score for [z] against
/// [zHistory] (the prior days' composite z's). Returns the new score.
double rescoreStoredReadiness(
  Map<String, dynamic> payload,
  ({double z, Map<String, double> contributions}) stored,
  List<double> zHistory,
) {
  final cal = ana.calibratedReadinessScore(stored.z, zHistory);
  final rc = (payload['clinical'] as Map)['readiness_composite'] as Map;
  rc['value'] = ana.Readiness(cal.score, stored.z,
          calibrationSigma: cal.sigma,
          calibrationNights: cal.nights,
          calibrationCentreRaw: cal.centreRaw,
          calibrationCentre: cal.centre)
      .toJson();
  for (final d in rc['drivers'] as List) {
    final c = stored.contributions[(d as Map)['label']];
    if (c != null) d['contribution'] = double.parse(c.toStringAsFixed(6));
  }
  (payload['scalars'] as Map)
    ..['readiness'] = cal.score
    ..['readiness_z'] = stored.z;
  return cal.score;
}

/// Passes a substrate day may wait for its own derive before the re-score
/// takes it from its stored inputs anyway. A day whose derive keeps failing
/// would otherwise hold the backfill open forever.
/// ponytail: one global limit; per-day counts if a slow, healthy derive
/// ever needs more than this.
const int kReadinessBackfillMaxPasses = 3;

/// `compute_freshness` key for the bounded pre-derive seed.
const String kReadinessZSeedKey = 'readiness_z_seed_v112';

/// Stored days the pre-derive seed covers: the 28-night calibration window
/// behind the oldest day a pass can still re-derive (raw retention), plus a
/// little slack. Older days only matter to the post-derive re-score.
const int kReadinessZSeedDays = 28 + rawRetentionDays + 3;

/// Measured, non-imported, non-skipped, non-partial stored days, oldest first.
Future<List<String>> _storedDays() async {
  final imported = await LocalDb.importedDates();
  return <String>[
    for (final r in await LocalDb.recentDayResultsMeta(-1))
      if (r['day_id'] case final String d)
        if (!imported.contains(d) &&
            (r['skipped'] as num?)?.toInt() != 1 &&
            (r['partial'] as num?)?.toInt() != 1)
          d,
  ]..sort();
}

Future<Set<String>> _haveZ() async => {
      for (final r in await LocalDb.metricSeries('readiness_z'))
        if (r['value'] is num) r['date'] as String,
    };

/// Write `readiness_z` for [days] that lack it. The payload decode runs off the
/// calling isolate ([Isolate.run]): it is the expensive part.
Future<int> _seedZ(Iterable<String> days) async {
  final have = await _haveZ();
  final todo = <(String, String)>[
    for (final day in days)
      if (!have.contains(day))
        if ((await LocalDb.dayResult(day))?['payload_json'] case final String j)
          (day, j),
  ];
  if (todo.isEmpty) return 0;
  final zs = await Isolate.run(() => [
        for (final (day, json) in todo)
          if (_decode(json) case final p?)
            if (storedReadinessZ(p) case final s?) (day, s.z),
      ]);
  for (final (day, z) in zs) {
    await LocalDb.putMetricSeriesValue(day, 'readiness_z', z);
  }
  return zs.length;
}

/// BEFORE the derive: the readiness_z history today's (and every re-derived
/// day's) calibration reads — only the newest [kReadinessZSeedDays] stored
/// days, so the first v112 pass is not held up by the whole history. One-shot.
Future<int> seedRecentReadinessZ() async {
  if (await LocalDb.computeFreshness(kReadinessZSeedKey) != null) return 0;
  final days = await _storedDays();
  final n = await _seedZ(
      days.skip(days.length > kReadinessZSeedDays
          ? days.length - kReadinessZSeedDays
          : 0));
  await LocalDb.putComputeFreshness(kReadinessZSeedKey, '{"done":true}');
  return n;
}

/// AFTER the derive: seed `readiness_z` for the rest of history, then re-score
/// every stored day below [kAlgoVersion] that has no raw substrate left
/// ([rawDays] = the days that still have decoded rows; a day with substrate
/// is the derive's to re-derive, and one whose derive failed this pass is
/// retried by the next one). [zHistoryLoader] returns, after the z rows are
/// written, a lookup of the trailing `readiness_z` window strictly before a
/// day for that day's device family — the same window a derive would use.
/// One-shot.
Future<({int seeded, int rescored, int forced})> backfillReadinessCalibration({
  /// Days with substrate: decoded band rows AND the active wearable's rows.
  required Set<String> rawDays,
  required Future<List<double> Function(String day, String? deviceFamily)>
      Function()
      zHistoryLoader,
  bool force = false,
}) async {
  // Absent = first run. {done} = finished. {passes, pending} = an earlier
  // pass left [pending] substrate days to their derive; only those are
  // looked at again, never the whole history.
  final state = force
      ? null
      : _decode((await LocalDb.computeFreshness(
          kReadinessCalibrationKey))?['payload_json']);
  if (state?['done'] == true) return (seeded: 0, rescored: 0, forced: 0);
  final waiting = (state?['pending'] as List?)?.whereType<String>().toList();
  final passes = (state?['passes'] as num?)?.toInt() ?? 0;
  // Last allowed pass: substrate days still below v112 are re-scored from
  // their stored inputs like pruned ones (their derive has failed this long).
  final last = passes + 1 >= kReadinessBackfillMaxPasses;
  final days = waiting ?? await _storedDays();
  final seeded = waiting == null ? await _seedZ(days) : 0;
  final lookup = await zHistoryLoader();
  final versions = await LocalDb.dayResultVersions();
  var rescored = 0;
  // Days below v112 left to the derive because they still have substrate. A
  // light pass need not reach them all, and their raw can be pruned before it
  // does — so while any remain, the backfill is NOT marked done and the next
  // pass looks again (by then each is either re-derived or substrate-less).
  final pending = <String>[];
  var forced = 0;
  for (final day in days) {
    if ((versions[day] ?? 0) >= kAlgoVersion) continue;
    final raw = rawDays.contains(day);
    if (raw && !last) {
      pending.add(day);
      continue;
    }
    final row = await LocalDb.dayResult(day);
    if (row == null ||
        ((row['algo_version'] as num?)?.toInt() ?? 0) >= kAlgoVersion) {
      continue;
    }
    final payload = _decode(row['payload_json']);
    final stored = payload == null ? null : storedReadinessZ(payload);
    if (payload == null || stored == null) continue;
    final score = rescoreStoredReadiness(payload, stored,
        lookup(day, payload['device_family'] as String?));
    // The metric FIRST, the bundle second: the bundle's version is what marks
    // the day done, so a crash between the two leaves the day below v112 and
    // the next pass redoes both (same inputs, same values). The other order
    // left a v112 bundle beside the old trend value, never revisited.
    await LocalDb.putMetricSeriesValue(day, 'readiness', score);
    // `series: {}` + no `source`: the stored payload is rewritten as-is apart
    // from readiness, and the day's metric_series_version / metric_method rows
    // (its family stamp) are left untouched.
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: (row['window_json'] as String?) ?? '{}',
      finalized: (row['finalized'] as num?)?.toInt() == 1,
      rhr: (row['rhr'] as num?)?.toDouble(),
      rmssd: (row['rmssd'] as num?)?.toDouble(),
      readiness: score,
    );
    rescored++;
    if (raw) forced++;
  }
  if (pending.isEmpty) {
    await _markDone();
  } else {
    await LocalDb.putComputeFreshness(kReadinessCalibrationKey,
        jsonEncode({'passes': passes + 1, 'pending': pending}));
  }
  return (seeded: seeded, rescored: rescored, forced: forced);
}

Future<void> _markDone() => LocalDb.putComputeFreshness(
    kReadinessCalibrationKey, jsonEncode({'done': true}));

Map<String, dynamic>? _decode(Object? json) {
  if (json is! String) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
