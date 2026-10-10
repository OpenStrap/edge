// Mi Band 2/3 as the day's wearable: its stored rows mapped onto the
// canonical signals at the resolution the band actually stores them.
//
// What a Mi Band gives us, and where it lands:
//   * HR in its minute record, one value a minute (`decoded_onehz`, family
//     'miband234') -> the same HR-only substrate a Garmin's makes
//     ([sparseHrSubstrate]), so the SAME engine computes resting HR, nadir,
//     dip, TRIMP/strain/zones and calories off it.
//   * its own sleep kind per minute (`vendor_sleep_epoch`: wake, light and
//     deep; its light holds REM) -> the night, through the existing
//     `vendor_staged` rung. It does report wake inside a night, so
//     efficiency/awakenings are ours off it; our own HR-led window
//     ([sparseHrNight]) sits beside the band's.
//   * its daily steps and per-night stage minutes (`observation`) ->
//     [kDeviceValueSlot], served beside ours, never read here.
// It gives no beats, no respiration, no SpO2, no stress and no skin
// temperature: those rows are unavailable, with the reason in
// [kMiBandColumn]. Readiness and movement are the estimates (PLAN §3b).

import 'canonical.dart';
import 'garmin_inputs.dart' show at;
import 'pebble_inputs.dart' show rhrOnlyReadiness;

/// The adapter id the host stamps on this band's `decoded_onehz` rows.
const String kMiBandFamily = 'miband234';

/// Mi Band 2/3's column of the metric x device table (PLAN §3b), as served.
final Map<String, Cell> kMiBandColumn = {
  // Ours is the HR-led window off its one-a-minute HR (in bed); the band's
  // is the night it staged (`vendor_staged`).
  'sleep_window': Cell(
    ours: (d, _) => at(d, ['hr_sleep_window', 'in_bed_min']),
    device: 'in_bed_min',
    reason: Why.noNight,
  ),
  'efficiency_awakenings': Cell(
    ours: (d, _) => scalar(d, 'efficiency'),
    ourMethod: 'device_stages',
    reason: Why.noNight,
  ),
  // Light and deep only: its light sleep holds REM.
  'sleep_stages': Cell(device: 'deep_min', reason: Why.noStagedNight),
  // The band does record per-minute movement (an intensity byte in each
  // minute record); nothing here decodes it into naps yet.
  'naps': const Cell(reason: Why.notDecoded),
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
  // Our composite needs two inputs we measured; this band gives resting HR
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
  // The band keeps no movement value of its own: minutes in an HR zone
  // stand in, as on a Garmin.
  // ponytail: off HR zones, not the band's per-minute intensity byte; move
  // to that once its scale is checked against a worn band.
  'movement': Cell(
    estimated: (d, _) => d['zones'] is Map
        ? (d['zones'] as Map).values.whereType<num>().fold<num>(0, (a, b) => a + b)
        : null,
    estimatedMethod: 'hr_1min_zone_minutes',
    reason: Why.noWakeHr,
  ),
  'auto_workouts': Cell(
    ours: (d, _) => (d['workout_suggestions'] as List?)?.length,
    reason: Why.noWakeHr,
  ),
  // The session override: a strap's sessions are ours at 1 Hz on this
  // band's day ([withStrapSessions]); its one-a-minute HR has no recovery
  // curve in it, so heart-rate recovery is the strap's alone.
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
