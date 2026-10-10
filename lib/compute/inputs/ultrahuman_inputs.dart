// The Ultrahuman Ring Air as the day's wearable: its stored rows mapped onto
// the canonical signals at the resolution the ring actually stores them.
//
// What the ring gives us, and where it lands:
//   * one 32-byte record every 5 minutes. Its HR is in `decoded_onehz`
//     (family 'ultrahuman'); every record, HR, RMSSD, skin temperature,
//     activity and steps alike, is banked verbatim in `raw_archive`
//     ('ultrahuman_record'), and that is where the rest is read from.
//   * HR + skin temperature -> a [Substrate] ([ultrahumanSubstrate]), so the
//     SAME engine computes resting HR, nadir, dip and the nightly skin
//     temperature (centi-°C into the `skin_temp_adc` slot, z against the
//     ring's own nights) off it. Strain/zones/calories come out of the same
//     engine, each reading standing for its 5 minutes: estimated, never
//     ours. Readiness is ours, the partial composite over resting HR and
//     skin temperature (provisional: the ring settle band is synthetic);
//     the resting-HR part alone, estimated, until both have a baseline.
//   * the night -> [ultrahumanNight]: our HR-led window, staged per record by
//     a rule over HR, RMSSD, movement and skin temperature against the
//     night's own levels. It reaches the engine as an unclaimed night, so
//     efficiency and awakenings are ours off it; the stages are estimated.
//   * its daily step count (`observation`) -> [kDeviceValueSlot]; its own
//     RMSSD, SpO2 and skin temperature averaged over the night we staged
//     (`ring_day.device_night`), served beside ours in place of its stored
//     calendar-day means. Device values: none feeds a number of ours.
// No beats, no respiration, no stress: those rows are unavailable, with the
// reason in [kUltrahumanColumn].

import 'dart:math' as math;

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../data/db.dart';
import '../substrate.dart';
import '../vendor_sleep.dart';
import 'canonical.dart';
import 'garmin_inputs.dart';
import 'pebble_inputs.dart' show rhrOnlyReadiness;

const String kUltrahumanFamily = 'ultrahuman';

/// The ring's records for [deviceId] over `[from, to]`, by their HR stamp,
/// oldest first. Records the ring itself marks unusable are kept: their
/// steps and activity are still real.
Future<List<UltrahumanRecord>> ultrahumanRecords(
  String deviceId,
  int from,
  int to,
) async {
  final db = await LocalDb.instance;
  final out = <UltrahumanRecord>[];
  for (final r in await db.rawQuery(
    "SELECT hex FROM raw_archive WHERE device_id = ? "
    "AND reason = 'ultrahuman_record' AND rec_ts >= ? AND rec_ts <= ? "
    'ORDER BY rec_ts',
    [deviceId, from, to],
  )) {
    final hex = r['hex'] as String;
    final rec = parseUltrahumanRecord([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ], 0);
    if (rec != null) out.add(rec);
  }
  return out;
}

/// The skin temperature a record carries, in °C, or null when the ring does
/// not trust it (the adapter's own gate).
double? _skinC(UltrahumanRecord r) {
  final t = r.skinTempC;
  return r.tempQuality > 0 && t >= 20 && t <= 45 ? t : null;
}

/// The ring's HR rows ([sparseHrSubstrate]) with each record's skin
/// temperature beside its HR, in centi-°C.
Future<Substrate> ultrahumanSubstrate(String deviceId, int from, int to) async {
  final sub =
      await sparseHrSubstrate(kUltrahumanFamily, deviceId, from, to);
  if (sub.isEmpty) return sub;
  final temp = {
    for (final r in await ultrahumanRecords(deviceId, from, to))
      if (_skinC(r) case final c?) r.tsA: (c * 100).round(),
  };
  return Substrate(
    tsSec: sub.tsSec,
    hr: sub.hr,
    rrTsMs: sub.rrTsMs,
    rrMs: sub.rrMs,
    ax: sub.ax,
    ay: sub.ay,
    az: sub.az,
    spo2Red: sub.spo2Red,
    spo2Ir: sub.spo2Ir,
    skinTemp: [for (final t in sub.tsSec) temp[t] ?? 0],
    skinContact: sub.skinContact,
    stepCount: sub.stepCount,
    hrValid: sub.hrValid,
    bandSleepState: sub.bandSleepState,
    deviceFamily: kUltrahumanFamily,
    deviceIds: sub.deviceIds,
  );
}

/// The [q] quantile of [v] (nearest rank), NaN when empty.
double _quantile(List<num> v, double q) {
  final s = [...v]..sort();
  return s.isEmpty ? double.nan : s[(q * (s.length - 1)).round()].toDouble();
}

double _median(List<num> v) => _quantile(v, 0.5);

/// Moved in this record: it counted steps. The record's activity field is a
/// vendor value with no stated meaning or scale (a resting baseline above
/// zero would read every record as awake), so it never decides this.
bool _moving(UltrahumanRecord r) => r.steps > 0;

/// One record's stage against the night's own levels: [hrBase] is the
/// night's settled HR (its tenth percentile), [hrvMedian] and [tempMedian] its
/// medians. Awake when it moved, its HR sits 10 bpm or more above the settled
/// level or its skin cooled off the night's; deep when HR sits at the settled
/// level and RMSSD at or above the median; REM when HR sits 5 bpm or more
/// above it and RMSSD at or below the median; light otherwise.
///
/// ponytail: fixed offsets on one value per 5 minutes; a model trained on
/// paired nights replaces it once real paired data exists.
String stageRingEpoch(
  UltrahumanRecord r, {
  required double hrBase,
  required double hrvMedian,
  required double tempMedian,
}) {
  final skin = _skinC(r);
  if (_moving(r) ||
      r.hr >= hrBase + 10 ||
      (skin != null && skin < tempMedian - 1.0)) {
    return 'wake';
  }
  final hrv = r.hrv > 0 ? r.hrv : null;
  if (r.hr <= hrBase + 1 && (hrv == null || hrv >= hrvMedian)) return 'deep';
  if (r.hr >= hrBase + 5 && (hrv == null || hrv <= hrvMedian)) return 'rem';
  return 'light';
}

/// Our night off the ring's records over `[from, to]` (the day's search
/// window): the HR-led window ([hrLedWindow]) at 5 minutes, each record in it
/// staged by [stageRingEpoch], wake trimmed off both ends. Null with no
/// sustained dip or nothing asleep.
Future<VendorNight?> ultrahumanNight(String deviceId, int from, int to) async {
  final c = kHrCadenceSec[kUltrahumanFamily]!;
  final recs = [
    for (final r in await ultrahumanRecords(deviceId, from, to))
      if (ultrahumanHrQualityValid(r.hrQuality) && r.hr >= 25 && r.hr <= 230) r,
  ];
  final w = hrLedWindow([for (final r in recs) r.tsA], [
    for (final r in recs) r.hr,
  ], c);
  if (w == null) return null;
  final night = [
    for (final r in recs)
      if (r.tsA >= w.onsetSec && r.tsA < w.offsetSec) r,
  ];
  if (night.isEmpty) return null;
  final hrv = [for (final r in night) if (r.hrv > 0) r.hrv];
  final temp = [for (final r in night) ?_skinC(r)];
  final hrBase = _quantile([for (final r in night) r.hr], 0.1);
  final hrvMedian = hrv.isEmpty ? 0.0 : _median(hrv);
  final tempMedian = temp.isEmpty ? 0.0 : _median(temp);
  final stages = [
    for (final r in night)
      stageRingEpoch(r,
          hrBase: hrBase, hrvMedian: hrvMedian, tempMedian: tempMedian),
  ];
  final first = stages.indexWhere((s) => s != 'wake');
  final last = stages.lastIndexWhere((s) => s != 'wake');
  if (first < 0) return null;
  return VendorNight(
    deviceId: deviceId,
    source: kOurRingNightSource,
    decodedAtSec: night[last].tsA + c,
    epochs: [
      for (var i = first; i <= last; i++)
        VendorEpoch(night[i].tsA,
            i < last ? night[i + 1].tsA : night[i].tsA + c, stages[i]),
    ],
  );
}

/// The ring's day beyond what the engine stores: how much of the night it
/// moved in (share of the night's records with steps), and the
/// minutes of daytime rest after it ([ringNapMin]). Both estimates. Null
/// on any other device's day or a day with no night.
///
/// The rest scan stops an hour before tonight's onset [tonightOnsetSec] when
/// the next night is known (0 = not yet), else 3 h before [dayEnd]: a night
/// that begins before midnight and turns over once (or a still lie in bed
/// the stager left awake) would otherwise count as a nap.
Future<Map<String, Object?>?> ultrahumanDayBlock(
  Substrate day,
  int onsetSec,
  int offsetSec,
  int dayEnd, {
  int tonightOnsetSec = 0,
}) async {
  if (day.deviceFamily != kUltrahumanFamily || day.deviceIds.length != 1) {
    return null;
  }
  if (offsetSec <= onsetSec) return null;
  final recs = await ultrahumanRecords(day.deviceIds.single, onsetSec, dayEnd);
  final night = [for (final r in recs) if (r.tsA < offsetSec) r];
  if (night.isEmpty) return null;
  final napEnd =
      tonightOnsetSec > 0 ? tonightOnsetSec - 3600 : dayEnd - 3 * 3600;
  final hrMedian = _median([
    for (final r in night)
      if (ultrahumanHrQualityValid(r.hrQuality)) r.hr,
  ]);
  // The ring's own per-record values over the night, the quantity its
  // device slots name (the night's RMSSD, SpO2, skin temperature). Its
  // stored daily means run over the whole calendar day, waking hours too.
  final worn = [
    for (final r in night)
      if (ultrahumanHrQualityValid(r.hrQuality)) r,
  ];
  num? mean(Iterable<num> v) =>
      v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  return {
    'device_night': {
      'rmssd': mean([for (final r in worn) if (r.hrv > 0) r.hrv]),
      'spo2': mean([
        for (final r in worn)
          if (r.spo2 > 0 && r.spo2 <= 100) r.spo2,
      ]),
      'skin_temp_c': mean([for (final r in night) ?_skinC(r)]),
    },
    'movement_frac':
        night.where(_moving).length / math.max(1, night.length),
    'nap_min': ringNapMin(
      [
        for (final r in recs)
          if (r.tsA >= offsetSec && r.tsA < napEnd) r,
      ],
      hrMedian,
    ),
  };
}

/// Minutes of daytime rest in [day] (the records after the night, oldest
/// first): runs of 20 min to 3 h with no movement and HR within 5 bpm of the
/// night's median [hrMedian]. Only a run that ENDS inside [day] counts: one
/// still open at its last record is tonight's sleep beginning (or a rest not
/// over yet), and a run over 3 h is a night, not a nap. Nor does a run that
/// starts at [day]'s first record: that is a still lie-in the stager trimmed
/// off the night's end as wake, not a nap.
///
/// ponytail: fixed bounds on one value per 5 minutes; a nap within the hour
/// before bed (3 h before midnight, tonight not yet staged) is not counted,
/// and a lie-in broken by one movement counts its second part.
int ringNapMin(List<UltrahumanRecord> day, double hrMedian) {
  final c = kHrCadenceSec[kUltrahumanFamily]!;
  const minRun = 20 * 60, maxRun = 3 * 3600;
  var napSec = 0, run = 0;
  var lieIn = true;
  for (final r in day) {
    final rest = !_moving(r) &&
        ultrahumanHrQualityValid(r.hrQuality) &&
        r.hr <= hrMedian + 5;
    if (rest) {
      run++;
      continue;
    }
    if (!lieIn && run * c >= minRun && run * c <= maxRun) napSec += run * c;
    run = 0;
    lieIn = false;
  }
  return napSec ~/ 60;
}

/// `metric_series` keys whose row this column serves off `ring_day`, not off
/// the stored value: what the engine stores under them on a ring's day is
/// another quantity (z-angle minutes, which need gravity the ring does not
/// give; detected or logged naps), so it keeps the engine's own label, not
/// the row's estimate.
const Set<String> kRingDaySeriesKeys = {'active_min', 'nap_min'};

/// Ultrahuman's column of the metric x device table (PLAN §3b), as served.
final Map<String, Cell> kUltrahumanColumn = {
  // Ours: the in-bed span of the night our 5-minute stager placed (the ring
  // keeps no night), the same quantity every device's row serves.
  'sleep_window': Cell(
    ours: (d, _) => nightInBedMin(d),
    reason: Why.noHrDip,
  ),
  'efficiency_awakenings': Cell(
    ours: (d, _) => scalar(d, 'efficiency'),
    reason: Why.noNight,
  ),
  'sleep_stages': Cell(
    estimated: (d, _) => scalar(d, 'deep_min'),
    estimatedMethod: 'hr_5min_stager',
    reason: Why.noNight,
  ),
  'naps': Cell(
    estimated: (d, _) => at(d, ['ring_day', 'nap_min']),
    estimatedMethod: 'hr_5min_rest',
    reason: Why.noNightForNaps,
  ),
  'sleep_debt_need_sri': Cell(
    ours: (_, x) => at(x, ['sleep_debt', 'value', 'debt_hours']),
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
  'hrv': strapHrvCell(device: 'rmssd', reason: Why.noDeviceHrv),
  'respiratory_rate': strapBeatCell('resp_rate', reason: Why.neverResp),
  'spo2': Cell(device: 'spo2', reason: Why.noDeviceSpo2),
  'stress': strapBeatCell('stress', reason: Why.needsBeats),
  'skin_temp': Cell(
    ours: (d, _) => scalar(d, 'skin_temp_z'),
    ourMethod: 'skin_temp_c_5min',
    provisionalAt: const ['wellness', 'skin_temp', 'provisional'],
    device: 'skin_temp_c',
    reason: Why.needsThreeNightsTemp,
  ),
  // Ours is the composite over the two inputs we measure, resting HR and
  // skin temperature (the ring's HRV is a device value and never feeds it):
  // PARTIAL, and its temperature gate rests on a provisional ring settle
  // band. Until both have 14 nights of baseline, the resting-HR part is
  // estimated.
  'readiness': Cell(
    ours: (d, _) => scalar(d, 'readiness'),
    ourMethod: kPartialReadinessMethod,
    provisionalAt: const ['clinical', 'readiness_composite', 'provisional'],
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
    estimated: (d, _) => scalar(d, 'strain'),
    estimatedMethod: 'hr_5min',
    reason: Why.noWakeHr,
  ),
  'calories': Cell(
    estimated: (d, _) => scalar(d, 'calories'),
    estimatedMethod: 'hr_5min',
    reason: Why.noWakeHrOrProfile,
  ),
  'movement': Cell(
    estimated: (d, _) => at(d, ['ring_day', 'movement_frac']),
    estimatedMethod: 'steps_5min',
    reason: Why.noNight,
  ),
  'auto_workouts': const Cell(
    reason: Why.tooSparseForWorkouts,
  ),
  // The session override: a strap's sessions are ours at 1 Hz on the ring's
  // day ([withStrapSessions]); one HR every 5 minutes has no recovery curve
  // in it, so heart-rate recovery is the strap's alone.
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
