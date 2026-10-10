// ONE-SHOT BACKFILL — readiness onto the calibrated mapping (v112).
//
// Readiness changed in two ways: HRV and RHR now form one autonomic input
// (mean of their oriented z's, weight 0.70), and the score is mapped through
// the user's own composite-z spread once 14 prior nights exist
// (`calibratedReadinessScore`). Both need a history of composite z's that no
// day derived before v112 wrote.
//
// Neither needs raw. Every stored bundle carries the composite's drivers, and
// each driver's detail holds the ORIENTED z that input contributed
// (`oriented robust-z (median+MAD)=…`). The per-input z's are unchanged by
// this release, so the new composite is an exact function of them. This
// file:
//   1. writes `readiness_z` for every stored day whose drivers allow it (the
//      history the calibration needs, going back as far as bundles do);
//   2. re-scores days the derive can no longer reach (raw pruned) from that
//      z and the calibration over the days before it. Days still inside raw
//      retention are LEFT for the real re-derive the version bump triggers.
// A day without a published headline (absent composite, or one the z-cap
// withheld) or without parseable drivers is left exactly as it was.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/day_label.dart';
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
          calibrationSigma: cal.sigma, calibrationNights: cal.nights)
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

/// Run the backfill once. [zHistoryLoader] returns, after the z rows are
/// written, a lookup of the trailing `readiness_z` window strictly before a
/// day for that day's device family — the same window a derive would use.
Future<({int seeded, int rescored})> backfillReadinessCalibration({
  required Future<List<double> Function(String day, String? deviceFamily)>
      Function()
      zHistoryLoader,
  bool force = false,
}) async {
  if (!force &&
      await LocalDb.computeFreshness(kReadinessCalibrationKey) != null) {
    return (seeded: 0, rescored: 0);
  }
  final imported = await LocalDb.importedDates();
  final have = {
    for (final r in await LocalDb.metricSeries('readiness_z'))
      if (r['value'] is num) r['date'] as String,
  };
  final days = <String>[
    for (final r in await LocalDb.recentDayResultsMeta(-1))
      if (r['day_id'] case final String d)
        if (!imported.contains(d) &&
            (r['skipped'] as num?)?.toInt() != 1 &&
            (r['partial'] as num?)?.toInt() != 1)
          d,
  ]..sort();
  if (days.isEmpty) {
    await _markDone();
    return (seeded: 0, rescored: 0);
  }

  // 1. The z history.
  final rows = <String, Map<String, dynamic>>{};
  final payloads = <String, Map<String, dynamic>>{};
  final zs = <String, ({double z, Map<String, double> contributions})>{};
  var seeded = 0;
  for (final day in days) {
    final row = await LocalDb.dayResult(day);
    final payload = _decode(row?['payload_json']);
    if (row == null || payload == null) continue;
    final stored = storedReadinessZ(payload);
    if (stored == null) continue;
    rows[day] = row;
    payloads[day] = payload;
    zs[day] = stored;
    if (!have.contains(day)) {
      await LocalDb.putMetricSeriesValue(day, 'readiness_z', stored.z);
      seeded++;
    }
  }

  // 2. Re-score what the derive cannot reach. Cutoff = data edge minus raw
  // retention, measured like the pruner (never the wall clock).
  final cutoff = dayLabelOf(DateTime.parse(days.last)
      .add(const Duration(days: -rawRetentionDays)));
  final lookup = await zHistoryLoader();
  var rescored = 0;
  for (final day in days) {
    if (day.compareTo(cutoff) >= 0) continue;
    final row = rows[day], payload = payloads[day], stored = zs[day];
    if (row == null || payload == null || stored == null) continue;
    if (((row['algo_version'] as num?)?.toInt() ?? 0) >= kAlgoVersion) {
      continue;
    }
    final score = rescoreStoredReadiness(payload, stored,
        lookup(day, payload['device_family'] as String?));
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
    await LocalDb.putMetricSeriesValue(day, 'readiness', score);
    rescored++;
  }
  await _markDone();
  return (seeded: seeded, rescored: rescored);
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
