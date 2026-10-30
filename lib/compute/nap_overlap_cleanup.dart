// ONE-SHOT, RAW-FREE — naps that were really the start of the next night.
//
// Before v106 a sleep begun before midnight was also booked as that day's nap
// (`PreparedDerivationDay.tonightSleepOnsetSec` fixed it for new derives). Days
// derived earlier keep the double count in `naps` and `nap_min`, and most of
// them have no raw left to re-derive from. Every stored bundle does carry both
// halves of the answer: its own naps and the next day's main window. So the
// overlap is dropped from the stored bundle, in place, once.

import 'dart:convert';

import '../data/day_label.dart';
import '../data/db.dart';
import 'nap_edits.dart' show napMinutes;

/// `compute_freshness` key marking the cleanup as applied (an import clears it).
const String kNapNextNightCleanupKey = LocalDb.kNapNextNightCleanupKey;

/// [naps] without the detected ones overlapping the next day's main sleep
/// [nextOnsetSec, nextOffsetSec). A nap the user logged or confirmed is kept.
/// A `legacy` one is not: that is an old detection copied aside when its day
/// was rewritten, so it carries the same double count. Null when nothing is
/// dropped.
List<Map<String, dynamic>>? napsWithoutNextNight(
  List<Map<String, dynamic>> naps,
  int nextOnsetSec,
  int nextOffsetSec,
) {
  final kept = [
    for (final n in naps)
      if (n['source'] == 'manual' ||
          n['source'] == 'confirmed' ||
          n['start'] is! num ||
          n['end'] is! num ||
          (n['end'] as num) <= nextOnsetSec ||
          (n['start'] as num) >= nextOffsetSec)
        n,
  ];
  return kept.length == naps.length ? null : kept;
}

/// Runs the cleanup once over every stored day. Returns the days rewritten.
/// Marked done only after it finishes.
///
/// Not gated on the stored algo version: the raw-free readiness and strain
/// backfills restamp an old bundle at the current version while copying its
/// naps through untouched, so a pre-v106 double count can sit under a v112+
/// stamp. A day derived at v106+ has no detected nap inside the next night,
/// so the check is a no-op there.
Future<int> cleanNextNightNapsOnce() async {
  if (await LocalDb.computeFreshness(kNapNextNightCleanupKey) != null) return 0;
  final versions = await LocalDb.dayResultVersions();
  final days = versions.keys.toList()..sort();
  var cleaned = 0;
  for (final day in days) {
    // Calendar arithmetic on the label (noon avoids any DST edge).
    final d = DateTime.parse(day);
    final nextDay = dayLabelOf(DateTime(d.year, d.month, d.day + 1, 12));
    if (!versions.containsKey(nextDay)) continue;
    // '—' on a night with no sleep: a cast would throw and end the pass.
    final win = ((_decode((await LocalDb.dayResult(nextDay))?['payload_json'])
            ?['sleep'] as Map?)?['window'] as Map?)?['value'];
    if (win is! Map) continue;
    final on = win['onset_ms'], off = win['offset_ms'];
    if (on is! num || off is! num) continue;
    // A rewrite of this day may already have copied the phantom aside as a
    // legacy edit, and every later derive would attach it again.
    await LocalDb.deleteLegacyNapsOverlapping(day, on ~/ 1000, off ~/ 1000);
    final row = await LocalDb.dayResult(day);
    final payload = _decode(row?['payload_json']);
    final naps = (payload?['naps'] as Map?)?['value'];
    if (payload == null || naps is! List || naps.isEmpty) continue;
    final kept = napsWithoutNextNight(
      [for (final n in naps) if (n is Map) n.cast<String, dynamic>()],
      on ~/ 1000,
      off ~/ 1000,
    );
    if (kept == null) continue;
    (payload['naps'] as Map)
      ..['value'] = kept
      ..['count'] = kept.length;
    // The stored sleep periods list the same naps: drop them there too, and
    // take their minutes off a known total (an unknown total stays unknown).
    final periods = payload['sleep_periods'];
    if (periods is Map && periods['periods'] is List) {
      bool dropped(Object? p) =>
          p is Map &&
          p['is_main'] != true &&
          !kept.any((n) => n['start'] == p['onset_ts'] && n['end'] == p['wake_ts']);
      final list = periods['periods'] as List;
      final gone = list.where(dropped).toList();
      periods['periods'] = [for (final p in list) if (!dropped(p)) p];
      final total = periods['total_asleep_min'];
      if (total is num) {
        var minus = 0;
        var known = true;
        for (final p in gone) {
          final d = (p as Map)['duration_min'];
          if (d is num) {
            minus += d.round();
          } else {
            known = false;
          }
        }
        periods['total_asleep_min'] = known ? total.round() - minus : null;
      }
    }
    final napMin = napMinutes(kept).toDouble();
    final scalars = payload['scalars'];
    if (scalars is Map) scalars['nap_min'] = napMin;
    // The trend reads `metric_series`; same value, same order as the readiness
    // backfill (series first, bundle second).
    await LocalDb.putMetricSeriesValue(day, 'nap_min', napMin);
    await LocalDb.rewriteDayPayload(
      day,
      (row!['algo_version'] as num).toInt(),
      jsonEncode(payload),
    );
    cleaned++;
  }
  await LocalDb.putComputeFreshness(
      kNapNextNightCleanupKey, jsonEncode({'cleaned': cleaned}));
  return cleaned;
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
