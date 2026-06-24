// LocalPipeline — the on-device compute path for LOCAL mode.
//   raw frames (LocalDb) → decode (Rust core via NativeCore) → per-day minutes + RR
//   → analytics (Rust core) → store derived (LocalDb), permanent.
//
// Call OPPORTUNISTICALLY (on sync-complete / app-resume / on-charge), never as heavy
// background work (iOS will kill it). Idempotent: re-running recomputes + replaces.
// This MVP recomputes from all stored raw; dirty-day incrementalism is a refinement.
import 'dart:convert';
import '../data/db.dart';
import '../native/native_core.dart';

class LocalPipeline {
  final NativeCore core;
  LocalPipeline(this.core);

  static const _retentionDays = 14;

  /// Decode all stored raw, group into physiological days (UTC date), compute the
  /// metric set per day, and persist to the derived store. Returns days written.
  Future<int> computeAll() async {
    final raws = await LocalDb.rawHexForCompute();
    // day(YYYY-MM-DD) -> accumulators
    final rrByDay = <String, List<num>>{};
    final minBuckets = <String, Map<int, List<num>>>{}; // day -> (ts//60 -> hr[])
    for (final row in raws) {
      final hex = row['hex'] as String;
      final out = core.decode('decode_r24', hex);
      if (out == null) continue;
      final hr = (out['hr'] ?? 0) as num;
      final ts = (out['ts_epoch'] ?? 0) as num;
      if (ts <= 0) continue;
      final day = _utcDate(ts.toInt());
      final rr = (out['rr_intervals_ms'] ?? const []) as List;
      (rrByDay[day] ??= []).addAll(rr.cast<num>());
      if (hr > 0) ((minBuckets[day] ??= {})[ts ~/ 60] ??= []).add(hr);
    }

    final baseline = {'resting_hr': 50, 'max_hr': 190, 'sleep_need_min': 480};
    var written = 0;
    for (final day in minBuckets.keys) {
      final minutes = _minutes(minBuckets[day]!);
      final rr = rrByDay[day] ?? const [];

      // The aligned metric set (each via the Rust core; same numbers as cloud).
      final daily = <String, dynamic>{
        'strain': core.analytics('calc_strain', {'minutes': minutes, 'baseline': baseline}),
        'resting_hr': core.analytics('calc_resting_hr', {
          'minutes': minutes,
          'sleep_window': {'onset_ts': minutes.first['ts'], 'wake_ts': minutes.last['ts']},
        }),
        'hrv': core.analytics('time_domain_hrv', {'rr': rr}),
        'zones': core.analytics('calc_hr_zones', {'minutes': minutes, 'baseline': baseline}),
      };
      final sleep = core.analytics('calc_sleep', {'minutes': minutes, 'baseline': baseline});

      await LocalDb.upsertDerived(day, 'daily', jsonEncode(daily));
      await LocalDb.upsertDerived(day, 'sleep', jsonEncode(sleep));
      written++;
    }

    // prune-after-derive: drop raw older than retention, but only for derived days.
    final derived = await LocalDb.derivedDates();
    if (derived.isNotEmpty) {
      final cutoff = DateTime.now().subtract(const Duration(days: _retentionDays)).millisecondsSinceEpoch;
      await LocalDb.pruneRawBefore(cutoff);
    }
    return written;
  }

  List<Map<String, dynamic>> _minutes(Map<int, List<num>> buckets) {
    final out = buckets.entries.map((e) {
      final hrs = e.value;
      final avg = hrs.reduce((a, b) => a + b) / hrs.length;
      return {
        'ts': e.key * 60,
        'hr_avg': avg,
        'hr_min': hrs.reduce((a, b) => a < b ? a : b),
        'hr_max': hrs.reduce((a, b) => a > b ? a : b),
        'hr_n': hrs.length,
        'activity': 0,
        'steps': 0,
        'wrist_on': true,
      };
    }).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return out;
  }

  String _utcDate(int tsEpochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(tsEpochSec * 1000, isUtc: true);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
