// An Oura ring as the day's wearable: its stored rows mapped onto the
// canonical signals at the resolution the ring actually stores them.
//
// What the ring gives us, and where it lands:
//   * its heart rate (`decoded_onehz.hr`, family 'oura': the night's 5-minute
//     pairs and the daytime bursts, one reading about every 5 minutes) -> the
//     substrate's HR, so resting HR, the dip, the HR-led window, readiness and
//     the circadian rhythm are ours at `hr_5min`, as on the other rings.
//   * its beat intervals (`decoded_rr`) -> the substrate's beats, so the
//     night's HRV, respiration and stress are ours off the ring's own beats
//     ([kRrRingMethod]).
//   * its temperature events (`decoded_onehz.skin_temp_c`) -> the
//     substrate's skin temperature (centi-°C), so the nightly skin
//     temperature, its z and its baseline against the ring's own nights are
//     ours.
//   * its own hypnogram (`vendor_sleep_epoch`) -> the night, through the
//     existing `vendor_staged` rung; it reports wake, so efficiency and
//     awakenings are ours off it, and sleep debt, need and regularity follow
//     from its nights.
//   * its stage minutes, RMSSD and SpO2 (`observation`) -> [kDeviceValueSlot],
//     served beside ours, never read here.
// Its steps, motion and raw PPG are banked verbatim in `raw_archive` and not
// decoded, so the rows resting on them are unavailable with [Why.notDecoded].
// None of it has met a real ring (rule R6): the flag stays off by default.

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../substrate.dart';
import 'canonical.dart';
import '../vendor_sleep.dart';
import 'garmin_inputs.dart';
import 'pebble_inputs.dart' show rhrOnlyReadiness;

const String kOuraFamily = 'oura';

/// The method of a value read off the ring's own beat intervals.
const String kRrRingMethod = 'rr_ring';

/// The method tag of our skin temperature off the ring's temperature events.
const String kOuraSkinMethod = 'skin_temp_c_event';

/// [deviceId]'s temperature rows over `[from, to]` (or all of them), oldest
/// first. Readings outside 30-42 °C are not skin on a finger: dropped, as on
/// the other rings.
Future<List<Map<String, Object?>>> _ouraTempRows(
  String deviceId, [
  int? from,
  int? to,
]) async {
  final db = await LocalDb.instance;
  return db.rawQuery(
    'SELECT rec_ts, skin_temp_c FROM decoded_onehz '
    'WHERE device_id = ? AND device_family = ? '
    'AND skin_temp_c >= 30 AND skin_temp_c <= 42 '
    '${from == null ? '' : 'AND rec_ts >= $from AND rec_ts <= $to '}'
    'ORDER BY rec_ts',
    [deviceId, kOuraFamily],
  );
}

/// The ring's day over `[from, to]` as a substrate: its HR readings
/// ([sparseHrSubstrate]) with the skin temperature of the reading nearest
/// each (within [kHrCadenceSec], centi-°C, 0 = none) and its own beats; with
/// no HR, its temperature rows alone ([_ouraTempSubstrate]). Empty when
/// there is neither.
Future<Substrate> ouraSubstrate(String deviceId, int from, int to) async {
  final sub = await sparseHrSubstrate(kOuraFamily, deviceId, from, to);
  if (sub.isEmpty) return _ouraTempSubstrate(deviceId, from, to);
  final c = kHrCadenceSec[kOuraFamily]!;
  final temps = await _ouraTempRows(deviceId, from - c, to + c);
  final skin = <int>[];
  var j = 0;
  for (final t in sub.tsSec) {
    while (j + 1 < temps.length &&
        ((temps[j + 1]['rec_ts'] as num) - t).abs() <=
            ((temps[j]['rec_ts'] as num) - t).abs()) {
      j++;
    }
    final near = j < temps.length &&
        ((temps[j]['rec_ts'] as num) - t).abs() <= c;
    skin.add(near ? ((temps[j]['skin_temp_c'] as num) * 100).round() : 0);
  }
  final db = await LocalDb.instance;
  final beats = await db.rawQuery(
    'SELECT COALESCE(beat_ts_ms, rr_ts_ms) AS t, rr_ms AS rr FROM decoded_rr '
    'WHERE device_id = ? AND device_family = ? AND rec_ts >= ? AND rec_ts <= ? '
    'ORDER BY t, beat_index',
    [deviceId, kOuraFamily, from, to],
  );
  final rr = [
    for (final b in beats)
      if (plausibleRrOrNull(b['rr'] as num) case final ms?)
        ((b['t'] as num).toDouble(), ms),
  ];
  return Substrate.fromJson(sub.toJson()
    ..['skin_temp'] = skin
    ..['rr_ts_ms'] = [for (final b in rr) b.$1]
    ..['rr_ms'] = [for (final b in rr) b.$2]);
}

/// The ring's temperature rows for [deviceId] over `[from, to]` as a
/// substrate: skin temperature in centi-°C, no HR (0), absent gravity, no
/// beats. Empty when there are none.
Future<Substrate> _ouraTempSubstrate(String deviceId, int from, int to) async {
  final rows = await _ouraTempRows(deviceId, from, to);
  if (rows.isEmpty) return Substrate.empty;
  final n = rows.length;
  final zeros = List<double>.filled(n, 0);
  final none = List<int>.filled(n, -1);
  return Substrate(
    tsSec: [for (final r in rows) (r['rec_ts'] as num).toInt()],
    hr: List<int>.filled(n, 0),
    rrTsMs: const [],
    rrMs: const [],
    ax: zeros,
    ay: zeros,
    az: zeros,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: [
      for (final r in rows) ((r['skin_temp_c'] as num) * 100).round(),
    ],
    skinContact: List<int>.filled(n, 0),
    stepCount: none,
    hrValid: none,
    bandSleepState: none,
    deviceFamily: kOuraFamily,
    deviceIds: {deviceId},
  );
}

/// `{local day -> last HR or temperature second}` over [deviceId]'s rows:
/// the days this ring alone can put up for derivation.
Future<Map<String, int>> ouraRecTsMaxByDay(String deviceId) async {
  final out = await sparseHrRecTsMaxByDay(kOuraFamily, deviceId);
  for (final r in await _ouraTempRows(deviceId)) {
    final t = (r['rec_ts'] as num).toInt();
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000));
    if (t > (out[day] ?? 0)) out[day] = t;
  }
  return out;
}

/// Our night off the ring's HR alone over `[from, to]`, for a night the
/// ring staged none of: the HR-led window ([hrLedWindow]) as one epoch of
/// sleep, unstaged, after the ring's own night and only where that one is
/// not. Null with no sustained dip.
Future<VendorNight?> ouraNight(String deviceId, int from, int to) async {
  final sub = await sparseHrSubstrate(kOuraFamily, deviceId, from, to);
  if (sub.isEmpty) return null;
  final w = hrLedWindow(sub.tsSec, sub.hr, kHrCadenceSec[kOuraFamily]!);
  if (w == null) return null;
  return VendorNight(
    deviceId: deviceId,
    source: kHrWindowNightSource,
    decodedAtSec: w.offsetSec,
    epochs: [VendorEpoch(w.onsetSec, w.offsetSec, 'light')],
  );
}

/// Oura's column of the metric x device table (PLAN §3b, §8), as served.
final Map<String, Cell> kOuraColumn = {
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
  // The ring's own stages. Ours beside them needs its motion, whose window
  // and scale are not pinned, so it is not decoded.
  'sleep_stages': Cell(device: 'deep_min', reason: Why.noStagedNight),
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
  // Ours off the ring's own beats (a strap's, where one was worn, owns its
  // minutes: [withStrapSessions]); the ring's own RMSSD beside it.
  'hrv': Cell(
    ours: (d, _) => scalar(d, 'rmssd'),
    ourMethod: kRrRingMethod,
    device: 'rmssd',
    reason: Why.noDeviceHrv,
  ),
  'respiratory_rate': Cell(
    ours: (d, _) => scalar(d, 'resp_rate'),
    ourMethod: kRrRingMethod,
    reason: Why.needsBeats,
  ),
  'spo2': Cell(device: 'spo2', reason: Why.noDeviceSpo2),
  'stress': Cell(
    ours: (d, _) => scalar(d, 'stress'),
    ourMethod: kRrRingMethod,
    reason: Why.needsBeats,
  ),
  'skin_temp': Cell(
    ours: (d, _) => scalar(d, 'skin_temp_z'),
    ourMethod: kOuraSkinMethod,
    provisionalAt: const ['wellness', 'skin_temp', 'provisional'],
    reason: Why.needsThreeNightsTemp,
  ),
  // The composite over what we measure off the ring (resting HR, skin
  // temperature, and its beats' HRV where they cover the night); its
  // temperature gate rests on the provisional ring settle band. Until the
  // inputs have 14 nights of baseline, the resting-HR part is estimated.
  'readiness': Cell(
    ours: (d, _) => scalar(d, 'readiness'),
    provisionalAt: const ['clinical', 'readiness_composite', 'provisional'],
    estimated: (d, _) => rhrOnlyReadiness(d),
    estimatedMethod: 'rhr_only_partial',
    reason: Why.needsRhrBaseline,
  ),
  // PLAN §3b: '-'. Not off the ring's beats; and a strap's beats laid over
  // the ring's night are not told apart from the ring's in the substrate, so
  // not the strap's here either.
  // ponytail: serve a strap's once beats carry their source into the night.
  'irregular_rhythm': const Cell(reason: Why.beatsNotSeparated),
  'steps': const Cell(reason: Why.notDecoded),
  // PLAN §3b: '-'. The ring keeps its own activity record, not decoded.
  'strain': const Cell(reason: Why.notDecoded),
  'calories': const Cell(reason: Why.notDecoded),
  'movement': const Cell(reason: Why.notDecoded),
  'auto_workouts': const Cell(reason: Why.tooSparseForWorkouts),
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

/// [kOuraColumn] for a night a strap's beats own ([ouraStrapOwnsNight]): the
/// rows read off the night's beats are the strap's, not the ring's.
final Map<String, Cell> kOuraStrapNightColumn = {
  ...kOuraColumn,
  for (final row in const ['hrv', 'respiratory_rate', 'stress'])
    row: Cell(
      ours: kOuraColumn[row]!.ours,
      ourMethod: kRrStrapMethod,
      device: kOuraColumn[row]!.device,
      reason: kOuraColumn[row]!.reason,
    ),
};

/// Whether a flagged-on strap's beats own most of ring [deviceId]'s night in
/// [window] (a stored sleep window: its envelope, or its value), by the rule
/// [withStrapSessions] merges them by: one source per [kBeatSourceBucketMs],
/// the one with most beats in it, ties to the ring.
Future<bool> ouraStrapOwnsNight(String deviceId, Object? window) async {
  final ids = LocalDb.sessionSensorSources;
  final v = window is Map && window['value'] is Map ? window['value'] : window;
  if (ids.isEmpty || v is! Map) return false;
  final on = v['onset_ms'], off = v['offset_ms'];
  if (on is! num || off is! num) return false;
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    "SELECT CASE WHEN source IN (${ids.map((s) => "'$s'").join(', ')}) "
    "THEN source ELSE '' END AS src, "
    'COALESCE(beat_ts_ms, rr_ts_ms) AS t, rr_ms AS rr FROM decoded_rr '
    'WHERE ((device_id = ? AND device_family = ?) '
    'OR source IN (${ids.map((s) => "'$s'").join(', ')})) '
    'AND rec_ts >= ? AND rec_ts <= ?',
    [deviceId, kOuraFamily, on ~/ 1000 - 60, off ~/ 1000 + 60],
  );
  final beats = [
    for (final r in rows)
      if (plausibleRrOrNull(r['rr'] as num) != null &&
          (r['t'] as num) >= on &&
          (r['t'] as num) <= off)
        ((r['t'] as num) ~/ kBeatSourceBucketMs, r['src']),
  ];
  final owner = ownerBy(beats);
  var strap = 0;
  for (final (g, src) in beats) {
    if (owner[g] == src) strap += src == '' ? -1 : 1;
  }
  return strap > 0;
}
