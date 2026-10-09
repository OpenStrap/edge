// A Colmi ring as the day's wearable: its stored rows mapped onto the
// canonical signals at the resolution the ring actually stores them.
//
// What the ring gives us, and where it lands:
//   * HR history, one value every 5 minutes (`decoded_onehz`, family
//     'colmi') -> an HR substrate ([colmiSubstrate]), so the SAME engine
//     computes resting HR, nadir and dip off it. Strain/zones/calories come
//     out of the same engine, each reading standing for its 5 minutes:
//     estimated, never ours, and calories only where the ring gave none. Our
//     HR-led window ([sparseHrNight]) sits beside the ring's own night, and
//     is the night itself ([colmiNight], unstaged) where the ring staged
//     none. A ring set to measure less often than every 5 minutes abstains.
//   * its temperature replies, banked verbatim in `raw_archive`
//     ('colmi_big_0x25'), one reading per slot (the reply names the slot) ->
//     the substrate's skin temperature (centi-°C, each HR row taking the
//     reading of the slot it falls in), so the nightly skin temperature and
//     its z against the ring's own nights are ours.
//   * its own hypnogram (`vendor_sleep_epoch`) -> the night, through the
//     existing `vendor_staged` rung; it reports wake, so efficiency and
//     awakenings are ours off it.
//   * its own values (`observation`: steps, calories, stress_avg, nap_min,
//     and over its night hrv_avg, spo2_avg, skin_temp_avg and the stage
//     minutes) -> [kDeviceValueSlot], served beside ours, never read here.
// No beats, no respiration, no movement record: those rows are unavailable,
// with the reason in [kColmiColumn].

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../ble/adapters/colmi.dart' show kColmiHistoryDays;
import '../../data/db.dart';
import '../substrate.dart';
import '../vendor_sleep.dart';
import 'canonical.dart';
import 'garmin_inputs.dart';
import 'pebble_inputs.dart' show rhrOnlyReadiness;

const String kColmiFamily = 'colmi';

/// The ring's skin temperature readings for [deviceId] over `[from, to]`, as
/// (slot start, slot end, centi-°C), oldest first. A reply says "N days ago",
/// counted from the session's clock (`rec_ts`, stamped once per sync), the
/// same day the adapter resolved it to, so a sync running past midnight
/// places it right. A row banked before that stamp existed falls back to its
/// capture time.
/// Readings outside 30-42 °C are not skin on a finger: dropped. The band is
/// tight on purpose, since the value bytes' encoding depends on firmware and
/// a reply read in the wrong one mostly lands outside it.
Future<List<(int, int, int)>> colmiSkinTemps(
  String deviceId,
  int from,
  int to,
) async {
  final db = await LocalDb.instance;
  final out = <int, (int, int, int)>{};
  // A reply is banked on or after the day it describes and at most the
  // ring's history (kColmiHistoryDays) later: scan only those captures.
  for (final r in await db.rawQuery(
    'SELECT hex, COALESCE(rec_ts * 1000, captured_at) AS anchor_ms '
    'FROM raw_archive WHERE device_id = ? '
    "AND reason = 'colmi_big_0x${kColmiBigTemperature.toRadixString(16)}' "
    'AND captured_at >= ? AND captured_at <= ?',
    [
      deviceId,
      (from - 86400) * 1000,
      (to + (kColmiHistoryDays + 1) * 86400) * 1000,
    ],
  )) {
    final hex = r['hex'] as String;
    final bytes = [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    if (bytes.length < kColmiBigHeaderLength + 2) continue;
    final span = bytes[kColmiBigHeaderLength + 1] * 60;
    final banked = DateTime.fromMillisecondsSinceEpoch(r['anchor_ms'] as int);
    for (final t in colmiTemperatures(bytes)) {
      if (t.celsius < 30 || t.celsius > 42) continue;
      final at = DateTime(banked.year, banked.month, banked.day - t.daysAgo,
                  0, t.minuteOfDay)
              .millisecondsSinceEpoch ~/
          1000;
      if (at + span <= from || at > to) continue;
      out[at] = (at, at + span, (t.celsius * 100).round());
    }
  }
  return out.values.toList()..sort((a, b) => a.$1.compareTo(b.$1));
}

/// The ring's HR rows ([sparseHrSubstrate]) over `[from, to]`, or empty when
/// they sit further apart than [kHrCadenceSec] says. The interval is the
/// ring's own setting (5 minutes by default, slower on request), and every
/// duration read off the rows assumes 5: each reading stands for 5 minutes
/// of waking HR (resting HR, strain, calories), and the HR-led window counts
/// any wider step as a hole. A ring set slower abstains rather than serve
/// numbers scaled by the wrong interval.
///
/// ponytail: abstains; keep the interval the walk's page 0 announces per
/// sync and scale by it if rings set slower turn up.
Future<Substrate> colmiHr(String deviceId, int from, int to) async {
  final sub = await sparseHrSubstrate(kColmiFamily, deviceId, from, to);
  if (sub.length < 2) return sub;
  final gaps = [
    for (var i = 1; i < sub.length; i++) sub.tsSec[i] - sub.tsSec[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2] > kHrCadenceSec[kColmiFamily]!
      ? Substrate.empty
      : sub;
}

/// Our night off the ring's HR alone over `[from, to]` (the day's search
/// window), for a night the ring staged none of: the HR-led window
/// ([hrLedWindow]) as one epoch of sleep. It holds no stages (its source
/// reports none, [kVendorStagesReported]), so stage minutes, wake and
/// efficiency stay off it; what it gives the day is the window, which
/// resting HR, the dip and everything anchored on the night are read in.
/// Null with no sustained dip.
Future<VendorNight?> colmiNight(String deviceId, int from, int to) async {
  final sub = await colmiHr(deviceId, from, to);
  if (sub.isEmpty) return null;
  final w = hrLedWindow(sub.tsSec, sub.hr, kHrCadenceSec[kColmiFamily]!);
  if (w == null) return null;
  return VendorNight(
    deviceId: deviceId,
    source: kHrWindowNightSource,
    decodedAtSec: w.offsetSec,
    epochs: [VendorEpoch(w.onsetSec, w.offsetSec, 'light')],
  );
}

/// The rows whose figures come off the ring's own night: on a ring whose
/// nights we bank but do not decode ([colmiSleepUndecoded]) they are
/// unavailable for that reason.
const Set<String> kColmiNightRows = {
  'sleep_stages',
  'efficiency_awakenings',
  'hrv',
  'spo2',
};

/// Whether [deviceId]'s latest clock reply said it keeps its nights in the
/// per-day form asked for on Service A, not the big-data one: those replies
/// are banked verbatim and not decoded into stages.
Future<bool> colmiSleepUndecoded(String deviceId) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT hex FROM raw_archive WHERE device_id = ? AND reason = ? '
    'ORDER BY captured_at DESC LIMIT 1',
    [deviceId, 'colmi_cmd_0x${kColmiCmdSetTime.toRadixString(16).padLeft(2, '0')}'],
  );
  if (rows.isEmpty) return false;
  final hex = rows.single['hex'] as String;
  return colmiNewSleepProtocol([
        for (var i = 0; i + 1 < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]) ==
      false;
}

/// The ring's HR rows ([colmiHr]) with the skin temperature of the slot each
/// falls in beside its HR, in centi-°C (0 = none).
Future<Substrate> colmiSubstrate(String deviceId, int from, int to) async {
  final sub = await colmiHr(deviceId, from, to);
  if (sub.isEmpty) return sub;
  final temps = await colmiSkinTemps(deviceId, from, to);
  final skin = <int>[];
  var j = 0;
  for (final t in sub.tsSec) {
    while (j < temps.length && temps[j].$2 <= t) {
      j++;
    }
    skin.add(j < temps.length && temps[j].$1 <= t ? temps[j].$3 : 0);
  }
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
    skinTemp: skin,
    skinContact: sub.skinContact,
    stepCount: sub.stepCount,
    hrValid: sub.hrValid,
    bandSleepState: sub.bandSleepState,
    deviceFamily: kColmiFamily,
    deviceIds: sub.deviceIds,
  );
}

/// Colmi's column of the metric x device table (PLAN §3b), as served.
final Map<String, Cell> kColmiColumn = {
  // Ours is the HR-led window off its 5-minute HR (in bed); the ring's is
  // the night it staged.
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
  // PLAN §3b marks this '-' (nothing of ours). Kept as V on purpose: a ring
  // that records naps sends them as their own reply and the adapter stores
  // it as `nap_min`, so the ring's figure is served, labelled as the
  // device's; we place no nap of our own off one HR every 5 minutes. A ring
  // that sends none reads unavailable with that reason.
  'naps': Cell(device: 'nap_min', reason: Why.noDeviceNap),
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
  'hrv': strapHrvCell(device: 'rmssd', reason: Why.noDeviceHrv),
  'respiratory_rate': strapBeatCell('resp_rate', reason: Why.neverResp),
  'spo2': Cell(device: 'spo2', reason: Why.noDeviceSpo2),
  'stress': strapBeatCell(
    'stress',
    device: 'stress',
    reason: Why.noDeviceStress,
  ),
  'skin_temp': Cell(
    ours: (d, _) => scalar(d, 'skin_temp_z'),
    ourMethod: 'skin_temp_c_slot',
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
  // The ring's own daily figure where it gave one (PLAN §3b: never C when
  // V exists); our estimate off its 5-minute HR only where it gave none.
  'calories': Cell(
    device: 'calories',
    estimated: (d, _) => scalar(d, 'calories'),
    estimatedMethod: 'hr_5min',
    reason: Why.noWakeHrOrProfile,
  ),
  'movement': const Cell(
    reason: Why.noMovementRecord,
  ),
  'auto_workouts': const Cell(
    reason: Why.tooSparseForWorkouts,
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
