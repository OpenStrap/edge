// POLICY EXCEPTION PE-1, in one file: the only reader of a wearable's OWN
// RMSSD readings (`decoded_onehz.dev_rmssd_ms`), for a family admitted in
// `kDeviceRmssdFamilies`. It turns the night's raw samples into the one
// number our readiness takes as its HRV input when no strap's beats gave our
// own: ln(mean) over the night our pipeline already chose, or nothing.
//
// What stays OURS: the night window, the plausibility and count gates, the
// aggregate, the log, the personal baseline (per device family, never mixed
// with beat-derived HRV), the z, the weights and the calibration. What is the
// device's: each reading. Its composites (stress, readiness, PAI, ODI) never
// come through here. See docs/internal/sparse_device_analytics_architecture.md.

import 'dart:math' as math;

import '../../ble/adapters/_registry.dart' show kDeviceRmssdFamilies;
import '../../data/db.dart';

/// A reading outside this range is not a resting RMSSD (a dropout, a sensor
/// glitch, or a u8 field pinned near its ceiling).
const double kDeviceRmssdMinMs = 5;
const double kDeviceRmssdMaxMs = 200;

/// The fewest plausible readings a night needs. A count, not a share of the
/// readings the declared cadence implies: that cadence has no capture behind
/// it, and a gate tied to it would abstain every night if the strap samples
/// less often than declared.
/// ponytail: set with no real Helio night behind it (§7 known unknowns);
/// refit on the first ~30 real nights.
const int kDeviceRmssdMinSamples = 6;

/// The night's device RMSSD as ln(mean ms) over `[onsetSec, offsetSec)`, or
/// null with [refusal] saying why.
({double? lnRmssd, int n, String? refusal}) deviceNightLnRmssd(
  List<(int, double)> samples, {
  required int onsetSec,
  required int offsetSec,
}) {
  final inNight = [
    for (final (t, v) in samples)
      if (t >= onsetSec &&
          t < offsetSec &&
          v >= kDeviceRmssdMinMs &&
          v <= kDeviceRmssdMaxMs)
        v,
  ];
  if (inNight.length < kDeviceRmssdMinSamples) {
    return (
      lnRmssd: null,
      n: inNight.length,
      refusal: 'device_rmssd:n=${inNight.length},need=$kDeviceRmssdMinSamples',
    );
  }
  final mean = inNight.reduce((a, b) => a + b) / inNight.length;
  return (lnRmssd: math.log(mean), n: inNight.length, refusal: null);
}

/// [deviceId]'s own RMSSD readings over `[from, to)` as (epoch sec, ms), for
/// an admitted [family] only; empty for every other family.
Future<List<(int, double)>> deviceRmssdSamples(
  String? family,
  String deviceId,
  int from,
  int to,
) async {
  if (!kDeviceRmssdFamilies.contains(family)) return const [];
  final db = await LocalDb.instance;
  return [
    for (final r in await db.rawQuery(
      'SELECT rec_ts, dev_rmssd_ms FROM decoded_onehz '
      'WHERE device_id = ? AND device_family = ? AND rec_ts >= ? '
      'AND rec_ts < ? AND dev_rmssd_ms IS NOT NULL ORDER BY rec_ts',
      [deviceId, family, from, to],
    ))
      ((r['rec_ts'] as num).toInt(), (r['dev_rmssd_ms'] as num).toDouble()),
  ];
}

/// The night's value for a derive: admitted family, one device, a night.
/// Null when any of those is missing (the composite then has no HRV input,
/// exactly as before PE-1).
Future<({double? lnRmssd, String? refusal})?> deviceNightRmssd({
  required String? family,
  required Set<String> deviceIds,
  required int onsetSec,
  required int offsetSec,
}) async {
  if (!kDeviceRmssdFamilies.contains(family) ||
      deviceIds.length != 1 ||
      onsetSec <= 0 ||
      offsetSec <= onsetSec) {
    return null;
  }
  final samples =
      await deviceRmssdSamples(family, deviceIds.single, onsetSec, offsetSec);
  final r =
      deviceNightLnRmssd(samples, onsetSec: onsetSec, offsetSec: offsetSec);
  return (lnRmssd: r.lnRmssd, refusal: r.refusal);
}
