// Pebble 2 / 2 SE as the day's wearable: its stored rows mapped onto the
// canonical signals at the resolution the watch actually stores them.
//
// What a Pebble gives us, and where it lands:
//   * HR in its minute record, one value a minute (`decoded_onehz`, family
//     'pebble') -> the same HR-only substrate a Garmin's makes
//     ([sparseHrSubstrate]), so the SAME engine computes resting HR, nadir,
//     dip, TRIMP/strain/zones and calories off it.
//   * its sleep / deep-sleep overlays (`vendor_sleep_epoch`, light and deep
//     only) -> the night, through the existing `vendor_staged` rung; our
//     own HR-led window ([sparseHrNight]) sits beside it. It reports no
//     wake, so efficiency/awakenings are unavailable.
//   * its daily steps, per-night stage minutes and nap minutes
//     (`observation`) -> [kDeviceValueSlot], served beside ours, never read
//     here.
// It gives no beats, no respiration, no SpO2, no stress and no skin
// temperature, and no device value for any of them: those rows are
// unavailable, with the reason in [kPebbleColumn]. Readiness is the one
// estimate (PLAN §3b "C partial").

import 'dart:math' as math;

import '../../data/db.dart';
import 'canonical.dart';
import 'garmin_inputs.dart' show at;

const String kPebbleFamily = 'pebble';

/// Whether Pebble [deviceId] has ever banked a heart rate: false for a
/// 2 SE, which has no HR sensor.
Future<bool> pebbleHasHr(String deviceId) async =>
    (await (await LocalDb.instance).rawQuery(
      'SELECT 1 FROM decoded_onehz WHERE device_id = ? AND hr > 0 LIMIT 1',
      [deviceId],
    )).isNotEmpty;

/// The longest hole in a Pebble's minute HR that still counts as one run of
/// the HR-led night. Its minute record carries HR only for the minutes the
/// sensor sampled, which can be every few minutes rather than every one, so
/// the 5-min hole a one-a-minute watch is held to would end every night.
/// ponytail: set without a real watch's cadence (R6); tighten once one is
/// measured.
const int kPebbleHrMaxGapSec = 15 * 60;

/// Our readiness from resting HR alone: today's resting-HR z against the
/// stored baseline, through the composite's own logistic (lower is better).
/// Partial by construction, so it is only ever served as Estimated.
num? rhrOnlyReadiness(Map day) {
  final z = at(day, ['baselines', 'resting_hr', 'z']);
  return z == null ? null : 100 / (1 + math.exp(z));
}

/// Pebble's column of the metric x device table (PLAN §3b), as served.
final Map<String, Cell> kPebbleColumn = {
  // Ours is the HR-led window off its one-a-minute HR (in bed); the watch's
  // is its own night, which it reports without wake.
  'sleep_window': Cell(
    ours: (d, _) => at(d, ['hr_sleep_window', 'in_bed_min']),
    device: 'in_bed_min',
    reason: Why.noNight,
  ),
  // The watch reports no wake, so its night is all sleep by construction: an
  // efficiency off it would be 100 every night, not a measurement.
  'efficiency_awakenings': const Cell(
    reason: Why.noWake,
  ),
  'sleep_stages': Cell(device: 'deep_min', reason: Why.noStagedNight),
  // The watch's own nap periods (`nap_min`).
  'naps': Cell(device: 'nap_min', reason: Why.noDeviceNap),
  // Off the stored nights, which are the watch's own on its days.
  'sleep_debt_need_sri': Cell(
    ours: (_, x) => at(x, ['sleep_debt', 'value', 'debt_hours']),
    ourMethod: 'device_stages',
    reason: Why.needsThreeNights,
  ),
  'resting_hr': Cell(
    ours: (d, _) => scalar(d, 'rhr'),
    reason: Why.noNightHr,
  ),
  'nadir_dip': Cell(
    ours: (d, _) => scalar(d, 'sleeping_hr_nadir'),
    reason: Why.noNightHr,
  ),
  'hrv': strapHrvCell(reason: Why.neverBeats),
  'respiratory_rate': strapBeatCell('resp_rate', reason: Why.neverResp),
  'spo2': const Cell(reason: Why.neverSpo2),
  'stress': strapBeatCell('stress', reason: Why.neverStress),
  'skin_temp': const Cell(reason: Why.neverSkinTemp),
  // Our composite needs two inputs we measured; this watch gives resting HR
  // only, so the full score abstains and the resting-HR part is estimated.
  // A flagged-on strap's night beats make the composite ours.
  'readiness': Cell(
    ours: (d, _) => scalar(d, 'readiness'),
    ourMethod: kStrapReadinessMethod,
    best: MetricClass.estimated,
    estimated: (d, _) => rhrOnlyReadiness(d),
    estimatedMethod: 'rhr_only_partial',
    reason: Why.needsRhrBaseline,
  ),
  'irregular_rhythm': strapBeatCell(
    'irregular_rhythm_flag',
    reason: Why.needsBeats,
  ),
  'steps': Cell(device: 'steps', reason: Why.noDeviceSteps),
  'strain': Cell(
    ours: (d, _) => scalar(d, 'strain'),
    reason: Why.noWakeHr,
  ),
  'calories': Cell(
    ours: (d, _) => scalar(d, 'calories'),
    reason: Why.noWakeHrOrProfile,
  ),
  'movement': const Cell(
    reason: Why.noMovementRecord,
  ),
  'auto_workouts': Cell(
    ours: (d, _) => (d['workout_suggestions'] as List?)?.length,
    reason: Why.noWakeHr,
  ),
  'workouts_with_strap': strapWorkoutsCell,
  'hrr': strapHrrCell,
  'baselines_load_illness': Cell(
    ours: (d, _) => at(d, ['baselines', 'resting_hr', 'baseline']),
    reason: Why.needsHistory,
  ),
  'circadian': Cell(
    ours: (_, x) => at(x, ['circadian_cosinor', 'value', 'acrophase_hours']),
    reason: Why.needsThreeDaysHr,
  ),
};
