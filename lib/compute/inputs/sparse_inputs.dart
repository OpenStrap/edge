// A sparse-HR wearable's column of the metric x device table, BUILT FROM ITS
// DECLARATIONS rather than written per device: what it emits
// (`kAdapterSignals`) and the HR cadence it stores (`kHrCadenceSec`). A new
// wearable of this kind adds those rows and gets this column; nothing in
// compute names it. The hand-written columns (Garmin, Pebble, Mi Band, the
// rings) stay for the devices whose quirks a declaration cannot say (a watch
// that reports no wake, a ring that gives its own beats).
//
// Each row follows the hand-written columns' rules: ours where our method
// reads the HR it stores, the device's value where it declares one, and the
// reason otherwise. See docs/internal/sparse_device_analytics_architecture.md.

import 'dart:math' as math;

import '../../ble/adapters/_registry.dart'
    show kAdapterSignals, kDeviceRmssdFamilies;
import '../../ble/adapters/signals.dart';
import 'canonical.dart';
import 'garmin_inputs.dart';
import 'pebble_inputs.dart' show rhrOnlyReadiness;

final Map<String, Map<String, Cell>> _built = {};

/// [family]'s declaration-built column, or null for a family with no HR
/// cadence ([kHrCadenceSec]): one with no validated method serves nothing.
Map<String, Cell>? sparseColumn(String family) {
  final cadence = kHrCadenceSec[family];
  if (cadence == null) return null;
  return _built[family] ??= _sparseColumn(
    kAdapterSignals[family]?.keys.toSet() ?? const {},
    cadence,
    hrMethod(family),
    admitted: kDeviceRmssdFamilies.contains(family),
  );
}

/// exp of a stored ln value, or null.
num? _exp(num? ln) => ln == null ? null : math.exp(ln);

Map<String, Cell> _sparseColumn(
    Set<InputSignal> has, int cadence, String? method,
    {required bool admitted}) {
  final staged = has.contains(InputSignal.deviceStages);
  // One HR a minute carries a workout's shape and a waking day's load; one
  // every five minutes only an estimate of them (the rings' columns).
  final minute = cadence <= 60;
  Cell load(String key, Why reason) => minute
      ? Cell(ours: (d, _) => scalar(d, key), reason: reason)
      : Cell(
          estimated: (d, _) => scalar(d, key),
          estimatedMethod: method,
          reason: reason,
        );
  return {
    // Ours is the HR-led window off its HR (in bed); the device's, the
    // night it staged.
    'sleep_window': Cell(
      ours: (d, _) => at(d, ['hr_sleep_window', 'in_bed_min']),
      device: staged ? 'in_bed_min' : null,
      reason: Why.noNight,
    ),
    'efficiency_awakenings': staged
        ? Cell(
            ours: (d, _) => scalar(d, 'efficiency'),
            ourMethod: 'device_stages',
            reason: Why.noNight,
          )
        : const Cell(reason: Why.noStagedNight),
    'sleep_stages': Cell(
      device: staged ? 'deep_min' : null,
      reason: Why.noStagedNight,
    ),
    'naps': const Cell(device: 'nap_min', reason: Why.noDeviceNap),
    'sleep_debt_need_sri': Cell(
      ours: (_, x) => at(x, ['sleep_debt', 'value', 'debt_hours']),
      ourMethod: staged ? 'device_stages' : null,
      reason: Why.needsThreeNights,
    ),
    'resting_hr': Cell(
      ours: (d, _) => scalar(d, 'rhr'),
      device: 'rhr',
      reason: Why.noNightHr,
    ),
    'nadir_dip': Cell(
      ours: (d, _) => scalar(d, 'sleeping_hr_nadir'),
      reason: Why.noNightHr,
    ),
    // PE-1 (admitted family): ours is a strap's beats when it was worn,
    // else our night mean of the device's own RMSSD readings; the device's
    // own night figure rides beside it.
    'hrv': admitted
        ? Cell(
            ours: (d, _) =>
                scalar(d, 'rmssd') ?? _exp(scalar(d, 'ln_rmssd_dev')),
            ourMethodOf: (d) => scalar(d, 'rmssd') != null
                ? kRrStrapMethod
                : scalar(d, 'ln_rmssd_dev') != null
                ? kDeviceRmssdMethod
                : null,
            device: 'rmssd',
            reason: Why.noDeviceHrv,
          )
        : strapHrvCell(
            device: has.contains(InputSignal.deviceHrv) ? 'rmssd' : null,
            reason: has.contains(InputSignal.deviceHrv)
                ? Why.noDeviceHrv
                : Why.neverBeats,
          ),
    'respiratory_rate': strapBeatCell(
      'resp_rate',
      device: has.contains(InputSignal.deviceResp) ? 'resp_rate' : null,
      reason: has.contains(InputSignal.deviceResp)
          ? Why.noDeviceResp
          : Why.neverResp,
    ),
    'spo2': has.contains(InputSignal.deviceSpo2)
        ? const Cell(device: 'spo2', reason: Why.noDeviceSpo2)
        : const Cell(reason: Why.neverSpo2),
    'stress': strapBeatCell(
      'stress',
      device: has.contains(InputSignal.deviceStress) ? 'stress' : null,
      reason: has.contains(InputSignal.deviceStress)
          ? Why.noDeviceStress
          : Why.neverStress,
    ),
    // Ours off the Celsius it stores on its HR rows: the night's mean
    // against its own earlier nights.
    'skin_temp': has.contains(InputSignal.skinTempC)
        ? Cell(
            ours: (d, _) => scalar(d, 'skin_temp_z'),
            ourMethod: 'skin_temp_c',
            reason: Why.needsThreeNightsTemp,
          )
        : const Cell(reason: Why.neverSkinTemp),
    // The composite needs two inputs we measured; resting HR alone is
    // estimated until a strap's beats (or the device's own RMSSD samples,
    // once admitted) make it two.
    // On an admitted family the device's own RMSSD readings are the second
    // input (PE-1, owner decision: served as ours, the Today headline).
    'readiness': Cell(
      ours: (d, _) => scalar(d, 'readiness'),
      ourMethod: kStrapReadinessMethod,
      ourMethodOf: admitted
          ? (d) => deviceHrvNight(d) ? kDeviceHrvReadinessMethod : null
          : null,
      best: admitted ? MetricClass.ours : MetricClass.estimated,
      estimated: (d, _) => rhrOnlyReadiness(d),
      estimatedMethod: 'rhr_only_partial',
      reason: Why.needsRhrBaseline,
    ),
    'irregular_rhythm': strapBeatCell(
      'irregular_rhythm_flag',
      reason: Why.needsBeats,
    ),
    'steps': has.contains(InputSignal.steps)
        ? wearableStepsCell
        : const Cell(reason: Why.noDeviceSteps),
    'strain': load('strain', Why.noWakeHr),
    'calories': load('calories', Why.noWakeHrOrProfile),
    // Minutes in an HR zone stand in for movement (no accelerometer): a
    // measure of effort, labelled estimated, as on a Garmin.
    'movement': Cell(
      estimated: (d, _) => d['zones'] is Map
          ? (d['zones'] as Map)
              .values
              .whereType<num>()
              .fold<num>(0, (a, b) => a + b)
          : null,
      estimatedMethod: '${method}_zone_minutes',
      reason: Why.noWakeHr,
    ),
    'auto_workouts': minute
        ? Cell(
            ours: (d, _) => (d['workout_suggestions'] as List?)?.length,
            reason: Why.noWakeHr,
          )
        : const Cell(reason: Why.tooSparseForWorkouts),
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
}
