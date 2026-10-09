// Garmin as the day's wearable: its stored rows mapped onto the canonical
// signals at the resolution the watch actually stores them.
//
// What a Garmin gives us, and where it lands:
//   * monitoring HR, one value a minute (`decoded_onehz`, source 'garmin')
//     -> a [Substrate] with that HR only, so the SAME engine computes resting
//     HR, nadir, dip, TRIMP/strain/zones and calories off it. The engine's
//     functions already measure their own cadence (`nocturnalRhr` counts 30
//     samples to a full 30-min window at 60 s).
//   * its own hypnogram (`vendor_sleep_epoch`) -> the night, through the
//     existing `vendor_staged` rung; efficiency/awakenings are ours off it,
//     and our own HR-led window ([sparseHrNight]) sits beside it.
//   * its own numbers (`observation`) -> [kDeviceValueSlot], served beside
//     ours, never read here.
// No accelerometer, no beats, no skin temperature are decoded: every metric
// that needs one is unavailable, with the reason in [kGarminColumn].

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../substrate.dart';
import 'canonical.dart';
import 'colmi_inputs.dart';
import 'miband_inputs.dart';
import 'oura_inputs.dart';
import 'pebble_inputs.dart';
import 'ultrahuman_inputs.dart';

const String kGarminFamily = 'garmin';

/// The widest gap, in seconds, between two readings still taken as one 1 Hz
/// run (a strap's seconds laid over a wearable's day): a dropped second or
/// two. A reading further off is a wearable's own and stands for its minutes.
///
/// ponytail: by timing alone, so a wearable reading landing within this many
/// seconds of a strap's last one is read as the strap's and spreads no
/// minutes; a per-second source channel would tell them apart.
const int kOneHzRunGapSec = 3;

/// Seconds between stored HR values, per family — the method tag ours
/// carries (`hr_1min`) and the cadence the substrate is checked against.
/// A family missing here gets no substrate at all (calibrationFor refuses).
const Map<String, int> kHrCadenceSec = {
  kGarminFamily: 60,
  kPebbleFamily: 60,
  kMiBandFamily: 60,
  kUltrahumanFamily: 300,
  kColmiFamily: 300,
  kOuraFamily: 300,
};

/// The method family behind every number derived from [family]'s data: the
/// resolution of the HR it rests on. One entry per family, read through
/// calibrationFor, so a family missing here (no validated method yet)
/// abstains. Baselines are kept per method family: switching wearable
/// rebuilds them instead of scoring one resolution against another.
const Map<String, String> kMethodFamily = {
  'gen4': 'hr_1hz',
  'gen5': 'hr_1hz',
  kGarminFamily: 'hr_1min',
  kPebbleFamily: 'hr_1min',
  kMiBandFamily: 'hr_1min',
  kUltrahumanFamily: 'hr_5min',
  kColmiFamily: 'hr_5min',
  kOuraFamily: 'hr_5min',
};

/// The wearable families: every one with a column ([kHrCadenceSec]), never
/// a band. A wearable's skin temperature is baselined against its own
/// family's nights only.
final Set<String> kWearableFamilies = {...kHrCadenceSec.keys};

/// Whether [family] is one of [kWearableFamilies].
bool isWearableFamily(String? family) => kWearableFamilies.contains(family);

/// [kMethodFamily] for [family], or null (unstamped or not validated).
String? methodFamily(String? family) =>
    ana.calibrationFor(kMethodFamily, family);

/// The method tag for a number computed from [family]'s HR.
String? hrMethod(String? family) =>
    switch (ana.calibrationFor(kHrCadenceSec, family)) {
      60 => 'hr_1min',
      300 => 'hr_5min',
      _ => null,
    };

/// A [family] watch's HR rows for [deviceId] over `[from, to]` as a
/// substrate: HR only, absent gravity (0,0,0), no beats. Empty when there are
/// none, or when the rows are not this family's. Shared by every family in
/// [kHrCadenceSec].
Future<Substrate> sparseHrSubstrate(
  String family,
  String deviceId,
  int from,
  int to,
) async {
  if (ana.calibrationFor(kHrCadenceSec, family) == null) {
    return Substrate.empty;
  }
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT rec_ts, hr FROM decoded_onehz '
    'WHERE device_id = ? AND device_family = ? AND rec_ts >= ? '
    'AND rec_ts <= ? AND hr > 0 ORDER BY rec_ts',
    [deviceId, family, from, to],
  );
  if (rows.isEmpty) return Substrate.empty;
  final n = rows.length;
  final zeros = List<double>.filled(n, 0);
  final none = List<int>.filled(n, -1);
  return Substrate(
    tsSec: [for (final r in rows) (r['rec_ts'] as num).toInt()],
    hr: [for (final r in rows) (r['hr'] as num).toInt()],
    rrTsMs: const [],
    rrMs: const [],
    ax: zeros,
    ay: zeros,
    az: zeros,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    stepCount: none,
    hrValid: none,
    bandSleepState: none,
    deviceFamily: family,
    deviceIds: {deviceId},
  );
}

/// `{local day -> last HR second}` over [deviceId]'s rows: the days this
/// watch alone can put up for derivation.
Future<Map<String, int>> sparseHrRecTsMaxByDay(
  String family,
  String deviceId,
) async {
  final db = await LocalDb.instance;
  final out = <String, int>{};
  for (final r in await db.rawQuery(
    'SELECT rec_ts FROM decoded_onehz WHERE device_id = ? '
    'AND device_family = ? AND hr > 0 ORDER BY rec_ts',
    [deviceId, family],
  )) {
    final t = (r['rec_ts'] as num).toInt();
    out[dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000))] = t;
  }
  return out;
}

/// A number at [path] inside a stored block, or null — '—' and absent
/// blocks are both null, never 0.
num? at(Map m, List<String> path) {
  Object? v = m;
  for (final k in path) {
    v = v is Map ? v[k] : null;
  }
  return v is num ? v : null;
}

/// Garmin's column of the metric x device table (PLAN §3b), as served.
final Map<String, Cell> kGarminColumn = {
  // Ours is the HR-led window off its one-a-minute HR (in bed); the watch's
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
  'sleep_stages': Cell(device: 'deep_min', reason: Why.noStagedNight),
  'naps': const Cell(reason: Why.noMovementData),
  // Off the nights the watch staged, as efficiency is.
  'sleep_debt_need_sri': Cell(
    ours: (_, x) => at(x, ['sleep_debt', 'value', 'debt_hours']),
    ourMethod: 'device_stages',
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
  // Ours needs beat intervals: a strap's, on a night it was worn; the
  // watch's own are not decoded yet, so otherwise the HRV is the watch's.
  'hrv': strapHrvCell(device: 'rmssd', reason: Why.noDeviceHrv),
  'respiratory_rate': strapBeatCell(
    'resp_rate',
    device: 'resp_rate',
    reason: Why.noDeviceResp,
  ),
  'spo2': Cell(device: 'spo2', reason: Why.noDeviceSpo2),
  'stress': strapBeatCell(
    'stress',
    device: 'stress',
    reason: Why.noDeviceStress,
  ),
  'skin_temp': const Cell(reason: Why.skinTempNotDecoded),
  // Ours is the composite, which needs two inputs we measured; from this
  // watch we have resting HR only (its HRV is a device value and never feeds
  // it) until its beat intervals or skin temperature are decoded, so on a
  // watch-only night the composite abstains and the resting-HR part is
  // estimated. On a night a flag-on chest strap supplied beats, the
  // composite is ours.
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
  // No accelerometer is decoded from this watch, so minutes in an HR zone
  // stand in: a measure of effort, not of movement (a slow walk below zone 1
  // reads as none, a racing heart at rest as some). Labelled estimated.
  // ponytail: off HR zones, not the watch's activity records; move to those
  // once its FIT activity fields are decoded and checked against a real watch.
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
  // watch's day ([withStrapSessions]), and its one-a-minute HR has no
  // recovery curve in it, so heart-rate recovery is the strap's alone.
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
