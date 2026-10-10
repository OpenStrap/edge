// The one vocabulary every device's numbers are mapped onto, and the four
// classes a served number can carry (PLAN_multidevice_analytics §7).
//
// A device adapter (`<device>_inputs.dart`) maps its stored rows onto these
// keys and nothing else: ours land on our own scalar names, the device's own
// values land on the SAME slot name so the two can sit side by side. The
// device's value is never an input to ours — it is read at serve time from
// the display table (`LocalDb.observationsForDay`), never during a derive.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../ble/adapters/_registry.dart'
    show DeviceCategory, categoryOf, kBleHrs, kCoros, kPolarPmd;
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../crossday_pipeline.dart' show buildCrossDayBundle;
import '../derivation_engine.dart' show kAlgoVersion;
import '../substrate.dart';
import '../vendor_sleep.dart';
import 'colmi_inputs.dart';
import 'garmin_inputs.dart';
import 'miband_inputs.dart';
import 'oura_inputs.dart';
import 'pebble_inputs.dart';
import 'ultrahuman_inputs.dart';
import 'validation_bands.dart';

/// The method tag of our readiness on a wearable's day: the composite over
/// resting HR and skin temperature only (no beats, so no HRV), with the
/// ring's provisional temperature settle band behind its temp gate.
const String kPartialReadinessMethod = 'composite_rhr_temp_partial';

/// The method tag of our readiness on a watch's day with no skin
/// temperature: the composite over the watch's resting HR and a flagged-on
/// strap's night beats (resting HR alone is below its weight floor).
const String kStrapReadinessMethod = 'composite_rhr_strap';

/// What a served number is. Ours collapses A and B (the method says which
/// resolution it came from); device is the wearable's own value, labelled;
/// estimated only where the device gives nothing; unavailable says why.
enum MetricClass { ours, device, estimated, unavailable }

/// Why a row is unavailable, as a stable code the UI words (in every locale)
/// with the wearable's name; one code per distinct cause, not per device.
enum Why {
  noNight,
  noStagedNight,
  noMovementData,
  needsThreeNights,
  noNightHr,
  noDeviceHrv,
  noDeviceResp,
  noDeviceSpo2,
  noDeviceStress,
  skinTempNotDecoded,
  readinessRhrOnly,
  needsBeats,
  noDeviceSteps,
  noWakeHr,
  noWakeHrOrProfile,
  needsStrap,
  needsHistory,
  needsThreeDaysHr,
  noWake,
  neverBeats,
  neverResp,
  neverSpo2,
  neverStress,
  neverSkinTemp,
  needsRhrBaseline,
  noMovementRecord,
  noHrDip,
  noNightForNaps,
  needsThreeNightsTemp,
  tooSparseForWorkouts,
  noDeviceNap,
  notDecoded,
  beatsNotSeparated,
  noNightReading,
}

/// Device value names (`observation.vendor_key`, or `key` for the counts a
/// link stores as ours) onto our slot names. One table across devices: a
/// ring's `hrv_avg` and a watch's `hrv_last_night_avg` are both the night's
/// RMSSD as the device computed it (a Colmi's is the mean of its own readings
/// over its own night; an Ultrahuman's stored day mean is swapped for the
/// night's in [dayCells]). `calories` is the device's own daily figure.
const Map<String, String> kDeviceValueSlot = {
  'calories': 'calories',
  'hrv_avg': 'rmssd',
  'hrv_last_night_avg': 'rmssd',
  'resting_hr': 'rhr',
  'respiration_avg': 'resp_rate',
  'spo2_avg': 'spo2',
  'stress_avg': 'stress',
  'skin_temp_avg': 'skin_temp_c',
  'steps': 'steps',
  'sleep_deep_min': 'deep_min',
  'sleep_rem_min': 'rem_min',
  'sleep_light_min': 'light_min',
  'sleep_in_bed_min': 'in_bed_min',
  'sleep_wake_min': 'wake_min',
  'sleep_awake_min': 'wake_min',
  'nap_min': 'nap_min',
};

/// The device chosen as the day's wearable, by `devices.id`, or null.
const String kActiveWearableCursor = 'active_wearable';

/// Per-adapter enable flag (rule R6): absent = off. A developer setting
/// writes '1' until a real-hardware sync earns the adapter its default.
String wearableEnabledCursor(String adapterId) => 'wearable_enabled:$adapterId';

/// [kActiveWearableCursor]'s value when the user chose no wearable at all,
/// so the migration below does not pick one again.
const String kNoActiveWearable = 'none';

/// Whether [adapterId]'s flag is on (rule R6; default off). A Coros watch
/// feeds no number and has no toggle, so a flag left on from before reads
/// off: it would otherwise rank the watch in a signal priority.
Future<bool> wearableEnabled(String adapterId) async =>
    adapterId != kCoros.id &&
    await LocalDb.getCursor(wearableEnabledCursor(adapterId)) == '1';

/// A paired device that can be the day's wearable: a non-primary
/// [DeviceCategory.wearable] (the primary band's days are its own already).
bool isWearableRow(Map<String, Object?> row) =>
    row['id'] != LocalDb.kPrimaryDeviceId &&
    row['role'] != 'primary' &&
    categoryOf(row['adapter_id'] as String?) == DeviceCategory.wearable;

/// The chosen wearable's device id, or null. MIGRATION: an install that never
/// chose one gets the most recently synced wearable, written back so the
/// choice then stays put.
Future<String?> activeWearableId() async {
  final id = await LocalDb.getCursor(kActiveWearableCursor);
  if (id == kNoActiveWearable) return null;
  // A forgotten device leaves its id behind; the next wearable takes over.
  if (id != null && id.isNotEmpty && await LocalDb.deviceRow(id) != null) {
    return id;
  }
  for (final row in await LocalDb.deviceRows()) {
    if (!isWearableRow(row)) continue;
    await LocalDb.setCursor(kActiveWearableCursor, row['id'] as String);
    return row['id'] as String;
  }
  return null;
}

/// The active wearable as (device id, adapter id) when one is chosen AND its
/// adapter's flag is on; null otherwise, which is every WHOOP-only install.
Future<(String, String)?> activeWearable() async {
  final id = await activeWearableId();
  if (id == null) return null;
  final adapter = (await LocalDb.deviceRow(id))?['adapter_id'] as String?;
  if (adapter == null) return null;
  if (!await wearableEnabled(adapter)) return null;
  return (id, adapter);
}

/// Called with the days a wearable change moved, to re-derive them. Set by
/// the app at start-up; null (tests, a headless run) re-derives nothing.
Future<void> Function(Set<String> days)? onWearableDaysChanged;

/// Every day the active wearable has rows for, empty with none.
Future<Set<String>> _wearableDays() async {
  final w = await activeWearable();
  return w == null ? const {} : (await wearableRecTsMaxByDay(w)).keys.toSet();
}

/// Runs [change], then hands every day it moved (each day the old wearable
/// or the new one has rows for) to [onWearableDaysChanged], and returns them.
/// A day the band shares is re-derived too: a night the band never saw may
/// have been staged off the old wearable's hypnogram. A day only the old
/// wearable decided loses its derived rows instead (rule R6: flag off =
/// nothing from it) and is not re-derived, so it stays empty: with no band
/// rows and no active wearable, nothing in the derivation scope covers it.
///
/// ponytail: every shared day is re-derived on a toggle, a full history pass
/// on a long mixed install; narrow it to the days a staged night touched if
/// the toggle gets slow.
Future<Set<String>> _rederiveAround(Future<void> Function() change) async {
  final before = await _wearableDays();
  final beforeShaped = await _wearableShapedDays();
  await refreshSessionSensorSources();
  final sensorsBefore = LocalDb.sessionSensorSources;
  await change();
  // The screens listing paired devices re-read them: a flag decides which
  // of them may be ranked (rule R6).
  LocalDb.deviceRowChanged.add('');
  final after = await _wearableDays();
  final afterShaped = await _wearableShapedDays();
  final band = (await LocalDb.decodedRecTsMaxByDay()).keys.toSet();
  final kept = {...after, ...afterShaped.keys};
  // A day the wearable shaped without HR rows of its own on it (a night
  // staged off its hypnogram alone, or a day whose raw rows were pruned) is
  // cleared only when nothing else contributed to it, and re-derived when
  // the band's rows are still there to re-derive it from.
  final gone = {
    ...before,
    for (final MapEntry(key: d, value: sole) in beforeShaped.entries)
      if (sole) d,
  }.difference(kept).difference(band);
  await LocalDb.clearDerivedDays(gone);
  final days = {
    ...before,
    ...after,
    ...{...beforeShaped.keys, ...afterShaped.keys}.intersection(band),
    // A day whose derive credited a session a now-toggled sensor scored (the
    // workout-gap calories) follows the flag too.
    ...(await _stampedSessionDays(sensorsBefore
            .difference(LocalDb.sessionSensorSources)
            .union(LocalDb.sessionSensorSources.difference(sensorsBefore))))
        .intersection(band),
  }.difference(gone);
  if (days.isNotEmpty) await onWearableDaysChanged?.call(days);
  return {...before, ...after};
}

/// The days of every session stamped with one of [sensors]
/// (`LocalDb.stampSessionSensor`), by its start and its end.
///
/// ponytail: a day whose raw rows were pruned is not re-derived and keeps
/// the credit; keep the session kcal apart at derive time if that matters.
Future<Set<String>> _stampedSessionDays(Set<String> sensors) async {
  if (sensors.isEmpty) return const {};
  final db = await LocalDb.instance;
  return {
    for (final r in await db.rawQuery(
        'SELECT s.start_ts AS lo, s.end_ts AS hi FROM sessions s '
        'JOIN session_sensor x ON x.session_id = s.id '
        'WHERE x.source IN (${List.filled(sensors.length, '?').join(',')})',
        sensors.toList()))
      for (final k in const ['lo', 'hi'])
        if (r[k] is num)
          dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
              (r[k] as num).toInt() * 1000)),
  };
}

/// `{day -> sole}` for each day the active wearable shaped beyond its HR
/// rows: the days its stored contributor set names it, and the days its own
/// hypnogram may have staged the night of. `sole` is true when it was the
/// only contributor (its id alone in `coverage_devices`, or no contributor
/// set and a device-staged night), so clearing the day takes nothing from
/// the band. Empty with no active wearable.
///
/// ponytail: a pruned day the band ALSO contributed to is not sole and keeps
/// the wearable's share (its raw rows are gone, so it cannot be re-derived
/// without it, and clearing it would delete the band's history). Keep the
/// per-device values apart at derive time if that share must go too.
Future<Map<String, bool>> _wearableShapedDays() async {
  final w = await activeWearable();
  if (w == null) return const {};
  final id = w.$1;
  final db = await LocalDb.instance;
  final out = <String, bool>{};
  for (final r in await db.rawQuery(
      'SELECT date, coverage_devices FROM metric_series_version '
      "WHERE ',' || coverage_devices || ',' LIKE ?",
      ['%,$id,%'])) {
    final ids = (r['coverage_devices'] as String).split(',').toSet();
    out[r['date'] as String] = ids.length == 1;
  }
  for (final r in await db.rawQuery(
      'SELECT night_onset_ts AS lo, MAX(end_ts) AS hi FROM vendor_sleep_epoch '
      'WHERE device_id = ? GROUP BY night_onset_ts',
      [id])) {
    for (final k in const ['lo', 'hi']) {
      final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
          (r[k] as num).toInt() * 1000));
      if (out.containsKey(day)) continue;
      final covered = await db.rawQuery(
          'SELECT 1 FROM metric_series_version '
          'WHERE date = ? AND coverage_devices IS NOT NULL LIMIT 1',
          [day]);
      final staged = await db.rawQuery(
          'SELECT 1 FROM sleep_session_candidates WHERE day_id = ? AND '
          "(payload_json LIKE '%\"sleep_source\":\"vendor_staged\"%' OR "
          "payload_json LIKE '%\"device_night\":true%') LIMIT 1",
          [day]);
      out[day] = covered.isEmpty && staged.isNotEmpty;
    }
  }
  return out;
}

/// Makes [deviceId] the active wearable (null = none) and re-derives the
/// days that moves.
Future<Set<String>> setActiveWearable(String? deviceId) =>
    _rederiveAround(() async {
      await LocalDb.setCursor(
          kActiveWearableCursor, deviceId ?? kNoActiveWearable);
      await refreshSessionSensorSources();
    });

/// Turns [adapterId]'s flag on or off (the developer setting) and re-derives
/// the days that moves. Workout sensors take effect in their sessions.
Future<Set<String>> setWearableEnabled(String adapterId, bool on) =>
    _rederiveAround(() async {
      await LocalDb.setCursor(wearableEnabledCursor(adapterId), on ? '1' : '0');
      await refreshSessionSensorSources();
    });

/// The developer toggle for one paired device: on makes a wearable the
/// active one with its flag on (a workout sensor: flag on, for its sessions);
/// off turns its flag off. One re-derive for the whole change.
Future<Set<String>> useDevice(String deviceId, String adapterId, bool on) =>
    _rederiveAround(() async {
      await LocalDb.setCursor(wearableEnabledCursor(adapterId), on ? '1' : '0');
      if (on && categoryOf(adapterId) == DeviceCategory.wearable) {
        await LocalDb.setCursor(kActiveWearableCursor, deviceId);
      }
      await refreshSessionSensorSources();
    });

/// The workout sensors a workout arms and disarms (`AppState`), so what they
/// record inside a session is that workout's. A Coros watch is a workout
/// sensor too but syncs in short background windows, never per workout: a
/// stray window inside a session would take the session over, so it is no
/// session source.
final Set<String> kWorkoutArmedSensors = {kBleHrs.id, kPolarPmd.id};

/// Reloads [LocalDb.sessionSensorSources] from the flags: every workout-armed
/// sensor ([kWorkoutArmedSensors]) whose flag is on; and with it
/// [LocalDb.sessionWearableSource], the active wearable's adapter.
Future<void> refreshSessionSensorSources() async {
  LocalDb.sessionSensorSources = {
    for (final id in kWorkoutArmedSensors)
      if (await wearableEnabled(id)) id,
  };
  LocalDb.sessionWearableSource = (await activeWearable())?.$2;
}

/// The active wearable's rows over `[from, to]` as a substrate, for a day the
/// primary band left empty, with a strap's session windows laid over them
/// ([withStrapSessions]). Empty for an adapter with no inputs mapping. A day
/// the wearable was off or charging is still its day when a strap recorded a
/// session in it: the strap's seconds alone, under the wearable's family.
Future<Substrate> wearableSubstrate(
  (String, String) wearable,
  int from,
  int to,
) async {
  final own = await switch (wearable.$2) {
    kGarminFamily ||
    kPebbleFamily ||
    kMiBandFamily => sparseHrSubstrate(wearable.$2, wearable.$1, from, to),
    kUltrahumanFamily => ultrahumanSubstrate(wearable.$1, from, to),
    kColmiFamily => colmiSubstrate(wearable.$1, from, to),
    kOuraFamily => ouraSubstrate(wearable.$1, from, to),
    _ => Future.value(Substrate.empty),
  };
  if (!own.isEmpty || columnFor(wearable.$2) == null) {
    return withStrapSessions(own, from, to);
  }
  return withStrapSessions(
      Substrate.fromJson(own.toJson()..['device_family'] = wearable.$2),
      from,
      to);
}

/// Seconds past a session's end a strap's rows still take over: the tail
/// heart-rate recovery and its time constant are read from (the engine's
/// `_hrrForBout` window).
const int kStrapTailSec = 180;

/// The session override on a wearable's day: inside each saved session a
/// flagged-on workout sensor ([LocalDb.sessionSensorSources]) recorded, the
/// strap's 1 Hz HR replaces the wearable's samples from its first row to its
/// last (up to [kStrapTailSec] past the end), so the same engine reads the
/// session's strain, zones and heart-rate recovery off the strap, as it does
/// on a band's day. [sub] as it is with no sensor on, no such session, or an
/// empty day. The strap's seconds carry HR only (no gravity).
///
/// The strap's beats are laid in wherever it was worn, session or not, so a
/// strap worn at rest (overnight) gives the night the beat-to-beat HRV the
/// wearable cannot ([strapHrvCell]); the engine reads them in the sleep window
/// only, as it does a band's. Only a workout arms a strap today, so in the
/// app that night has no beats until something arms one at bedtime.
///
/// Two sensors worn together are never blended: each session is the sensor's
/// that recorded most of it, and each [kBeatSourceBucketMs] of beats the
/// source's with most beats in it ([ownerBy]).
Future<Substrate> withStrapSessions(Substrate sub, int from, int to) async {
  final ids = LocalDb.sessionSensorSources;
  if (ids.isEmpty) return sub;
  final db = await LocalDb.instance;
  final beats = await db.rawQuery(
    'SELECT source AS src, COALESCE(beat_ts_ms, rr_ts_ms) AS t, rr_ms AS rr '
    'FROM decoded_rr '
    'WHERE source IN (${ids.map((s) => "'$s'").join(', ')}) '
    'AND rec_ts >= ? AND rec_ts <= ? ORDER BY t, beat_index',
    [from, to],
  );
  final all = await db.rawQuery(
    'SELECT s.id AS sid, d.source AS src, d.rec_ts AS t, d.hr AS hr '
    'FROM sessions s '
    'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
    'AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) + $kStrapTailSec '
    'WHERE d.hr > 0 AND d.source IN (${ids.map((s) => "'$s'").join(', ')}) '
    'AND d.rec_ts >= ? AND d.rec_ts <= ? ORDER BY d.rec_ts',
    [from, to],
  );
  final owner = ownerBy([for (final r in all) (r['sid'], r['src'])]);
  final rows = [
    for (final r in all)
      if (r['src'] == owner[r['sid']]) r,
  ];
  // A day the wearable was off with no strap session in it stays empty.
  if (rows.isEmpty) return sub.isEmpty ? sub : _withStrapBeats(sub, beats);
  final strap = <int, int>{};
  final spans = <Object?, (int, int)>{};
  for (final r in rows) {
    final t = (r['t'] as num).toInt();
    strap[t] = (r['hr'] as num).toInt();
    final s = spans[r['sid']];
    spans[r['sid']] = s == null ? (t, t) : (s.$1, t);
  }
  bool covered(int t) => spans.values.any((s) => t >= s.$1 && t <= s.$2);
  // Each per-second channel and its absent value on a strap's second.
  const absent = <String, Object?>{
    'ts_sec': null, 'hr': null, 'ax': 0.0, 'ay': 0.0, 'az': 0.0,
    'spo2_red': 0, 'spo2_ir': 0, 'skin_temp': 0, 'skin_contact': 0,
    'step_count': -1, 'hr_valid': -1, 'band_sleep_state': -1,
  };
  final order = [
    for (var i = 0; i < sub.length; i++)
      if (!covered(sub.tsSec[i])) (sub.tsSec[i], i),
    for (final t in strap.keys) (t, -1),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final j = sub.toJson();
  for (final MapEntry(key: k, value: none) in absent.entries) {
    final src = j[k] as List;
    if (src.length != sub.length) continue;
    j[k] = [
      for (final (t, i) in order)
        i >= 0 ? src[i] : (k == 'ts_sec' ? t : k == 'hr' ? strap[t] : none),
    ];
  }
  return _withStrapBeats(Substrate.fromJson(j), beats);
}

/// The span of beats one source owns on a wearable's day ([ownerBy]): long
/// enough that a splice between sources is rare, short enough that a sensor
/// swapped mid-evening still gives the hours it was worn.
const int kBeatSourceBucketMs = 5 * 60 * 1000;

/// For each group of [tagged] `(group, source)` pairs, the source with most
/// of them, ties to the first by name: one sensor, never two blended.
Map<K, Object?> ownerBy<K>(Iterable<(K, Object?)> tagged) {
  final n = <K, Map<Object?, int>>{};
  for (final (g, s) in tagged) {
    final c = n[g] ??= {};
    c[s] = (c[s] ?? 0) + 1;
  }
  return {
    for (final MapEntry(key: g, value: c) in n.entries)
      g: c.entries.reduce((a, b) => b.value > a.value ||
              (b.value == a.value && '${b.key}'.compareTo('${a.key}') < 0)
          ? b
          : a).key,
  };
}

/// [sub] with the strap's plausible [beats] (`src`, `t` ms, `rr` ms) merged
/// into its own, in time order (ties in arrival order), one source per
/// [kBeatSourceBucketMs]: beats of two sensors interleaved would make every
/// successive difference a cross-device one.
Substrate _withStrapBeats(Substrate sub, List<Map<String, Object?>> beats) {
  final all = [
    for (var i = 0; i < sub.rrMs.length; i++) ('', sub.rrTsMs[i], sub.rrMs[i]),
    for (final b in beats)
      if (plausibleRrOrNull(b['rr'] as num) case final rr?)
        (b['src'], (b['t'] as num).toDouble(), rr),
  ];
  if (all.length == sub.rrMs.length) return sub;
  final owner = ownerBy([for (final b in all) (b.$2 ~/ kBeatSourceBucketMs, b.$1)]);
  final merged = [
    for (final (i, b) in all.indexed)
      if (b.$1 == owner[b.$2 ~/ kBeatSourceBucketMs]) (i, b.$2, b.$3),
  ]..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  return Substrate.fromJson(sub.toJson()
    ..['rr_ts_ms'] = [for (final b in merged) b.$2]
    ..['rr_ms'] = [for (final b in merged) b.$3]);
}

/// Our own night off the active wearable over `[from, to]`, for a day the
/// primary band left empty and the device staged none: staged off a ring
/// whose records carry more than HR ([ultrahumanNight]); unstaged, the window
/// alone, off a Colmi's or an Oura's HR ([colmiNight], [ouraNight]), which
/// comes after the ring's own night and stands only where that one does not. Null otherwise, which is
/// every WHOOP-only install.
Future<VendorNight?> wearableNight(int from, int to) async =>
    switch (await activeWearable()) {
      (final id, kUltrahumanFamily) => ultrahumanNight(id, from, to),
      (final id, kColmiFamily) => colmiNight(id, from, to),
      (final id, kOuraFamily) => ouraNight(id, from, to),
      _ => null,
    };

/// [nights] less every one from a device that is not the active wearable
/// ([activeWearable]: chosen, and its adapter's flag on). Rule R6: flag off =
/// nothing from it, so a watch nobody turned on never stages a night the
/// primary band did not see; and numbers come from one wearable at a time,
/// so a flagged-on device someone switched away from stages none either. The
/// primary's own are kept.
Future<List<VendorNight>> enabledVendorNights(List<VendorNight> nights) async {
  final active = (await activeWearable())?.$1;
  return [
    for (final n in nights)
      if (n.deviceId == LocalDb.kPrimaryDeviceId || n.deviceId == active) n,
  ];
}

/// End of the newest banked vendor sleep epoch of the primary or the active
/// wearable ([enabledVendorNights]), or null when neither has one.
Future<int?> enabledVendorSleepEndTs() async {
  final active = (await activeWearable())?.$1;
  int? last;
  for (final MapEntry(key: id, value: t)
      in (await LocalDb.lastVendorSleepEndTsByDevice()).entries) {
    if ((last == null || t > last) &&
        (id == LocalDb.kPrimaryDeviceId || id == active)) {
      last = t;
    }
  }
  return last;
}

/// Whether paired device [deviceId]'s adapter has its flag on (rule R6).
Future<bool> deviceFlagOn(String? deviceId) async {
  if (deviceId == null) return false;
  final adapter = (await LocalDb.deviceRow(deviceId))?['adapter_id'] as String?;
  return adapter != null && await wearableEnabled(adapter);
}

/// [ids] less every paired device behind a flag whose flag is off, in
/// order. Rule R6 for a signal ranking: a flag-off device ranked (or unioned
/// in by its coverage) owns no window. A band (no flag) and an id with no
/// device row are kept, as before.
///
/// [bandDay]: the order resolves a window of the primary band's day, whose
/// reads load only [derivableSourceSql] rows. A flagged device whose source
/// is not derivable is dropped too, flag on or off: owning a window there
/// would drop the band's rows from it with nothing loaded in their place.
Future<List<String>> flagOnOrPrimary(List<String> ids,
    {bool bandDay = false}) async {
  final out = <String>[];
  for (final id in ids) {
    final adapter = (await LocalDb.deviceRow(id))?['adapter_id'] as String?;
    final flagged = adapter != null &&
        (isWearableFamily(adapter) ||
            categoryOf(adapter) != DeviceCategory.wearable);
    if (flagged && bandDay && !kDerivableSources.contains(adapter)) continue;
    if (!flagged || await wearableEnabled(adapter)) out.add(id);
  }
  return out;
}

/// `{local day -> last second}` the active wearable has rows for, and the
/// days a flagged-on strap recorded a session in while the wearable was off
/// or charging ([wearableSubstrate] lays the session over the empty day).
Future<Map<String, int>> wearableRecTsMaxByDay(
    (String, String) wearable) async {
  final out = {
    ...await switch (wearable.$2) {
      kGarminFamily ||
      kPebbleFamily ||
      kMiBandFamily ||
      kUltrahumanFamily ||
      kColmiFamily => sparseHrRecTsMaxByDay(wearable.$2, wearable.$1),
      kOuraFamily => ouraRecTsMaxByDay(wearable.$1),
      _ => Future.value(const <String, int>{}),
    },
  };
  if (columnFor(wearable.$2) == null) return out;
  for (final MapEntry(key: day, value: t)
      in (await _strapSessionRecTsMaxByDay()).entries) {
    out[day] = math.max(out[day] ?? t, t);
  }
  return out;
}

/// `{local day -> last second}` of the flagged-on workout sensors' rows
/// inside saved sessions (and their [kStrapTailSec] tail), as
/// [withStrapSessions] reads them; empty with no sensor on.
Future<Map<String, int>> _strapSessionRecTsMaxByDay() async {
  final ids = LocalDb.sessionSensorSources;
  if (ids.isEmpty) return const {};
  final db = await LocalDb.instance;
  final out = <String, int>{};
  for (final r in await db.rawQuery(
    'SELECT MIN(d.rec_ts) AS lo, MAX(d.rec_ts) AS hi FROM sessions s '
    'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
    'AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) + $kStrapTailSec '
    'WHERE d.hr > 0 AND d.source IN (${ids.map((s) => "'$s'").join(', ')}) '
    'GROUP BY s.id',
  )) {
    // A session over midnight is both days'.
    for (final k in const ['lo', 'hi']) {
      final t = (r[k] as num?)?.toInt();
      if (t == null) continue;
      final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000));
      out[day] = math.max(out[day] ?? t, t);
    }
  }
  return out;
}

/// The active wearable's last row second, standing in as "now, in data
/// time" on an install with no band data; null with no wearable chosen.
Future<int?> wearableLastTs() async {
  final wearable = await activeWearable();
  if (wearable == null) return null;
  final byDay = await wearableRecTsMaxByDay(wearable);
  return byDay.isEmpty ? null : byDay.values.reduce(math.max);
}

/// Our own night off a sparse watch's HR, for the day `[dayStart, dayEnd)`
/// [day] holds: the HR-led detector the band's fallback runs
/// ([ana.hrLedSleepWindow]) over the same search window, fed the watch's
/// samples AS its seconds, so its 2 h minimum and 30 min bridge keep their
/// meaning at the watch's cadence. Its smoothing is a 5-minute median, which
/// is 5 samples at 1-min HR but ONE sample at 5-min HR (a Colmi or an
/// Ultrahuman): there it smooths nothing, and a single spike or dropout can
/// split the dip. Kept only when the wake lands in the day, as the band's auto
/// night is. Null on a band's day, or with no sustained dip.
Future<Map<String, Object?>?> sparseHrNight(
  Substrate day,
  int dayStart,
  int dayEnd,
) async {
  final family = day.deviceFamily;
  final c = ana.calibrationFor(kHrCadenceSec, family);
  if (c == null || day.deviceIds.length != 1) return null;
  final sub = await sparseHrSubstrate(family!, day.deviceIds.single,
      dayStart - kNocturnalSearchLookbackSec, dayEnd - 1);
  if (sub.isEmpty) return null;
  final w = hrLedWindow(sub.tsSec, sub.hr, c,
      maxGapSec: family == kPebbleFamily ? kPebbleHrMaxGapSec : 5 * 60);
  if (w == null) return null;
  final (:onsetSec, :offsetSec, :thresholdBpm) = w;
  if (offsetSec < dayStart || offsetSec >= dayEnd) return null;
  return {
    'onset_ts': onsetSec,
    'offset_ts': offsetSec,
    'in_bed_min': (offsetSec - onsetSec) ~/ 60,
    'threshold_bpm': thresholdBpm,
  };
}

/// [ana.hrLedSleepWindow] over samples [c] seconds apart, fed them AS its
/// seconds (see [sparseHrNight]), back in epoch seconds.
///
/// The dip threshold is anchored to the waking level (the detector's
/// baseline rule, 90 % of the median of [hrBaseline]), found in two passes
/// so it never depends on how much of the record is night:
///   1. a rough window, thresholded at 90 % of the upper half's median (the
///      record's 75th percentile). That is a waking HR while the night is
///      under three quarters of the samples, and it is set high on purpose:
///      the rough window may run long, so whatever lies outside it is awake.
///   2. the window again, anchored to the quiet end of the waking HR (the
///      lower half's median, the 25th percentile) of the samples OUTSIDE
///      the rough one, when they cover 4 h or more. The quiet end, not the
///      median: a workout and an afternoon peak lift a waking median until
///      90 % of it sits inside a slow morning's HR.
/// A plain sample-count gate (the median of everything, on 18 h of
/// coverage) fails both ways: a 10 h sleeper whose watch charged for part of
/// the day has a sleeping median, and a partial day under 18 h fell to the
/// 30th percentile, which sits inside a slow morning's HR and runs the
/// window hours past wake. A record that is nearly all night (a ring worn
/// only in bed) keeps the 30th percentile, since it has no waking level.
///
/// [maxGapSec] is the longest hole between samples that still counts as one
/// run, for a device whose HR arrives less often than [c] says.
({int onsetSec, int offsetSec, double thresholdBpm})? hrLedWindow(
  List<int> tsSec,
  List<int> hr,
  int c, {
  int maxGapSec = 5 * 60,
}) {
  if (tsSec.isEmpty) return null;
  final asDouble = [for (final h in hr) h.toDouble()];
  final ts = [for (final t in tsSec) t ~/ c];
  ana.HrLedWindow? run(List<double>? baseline) => ana.hrLedSleepWindow(
    asDouble,
    ts,
    hrBaseline: baseline,
    minDurationSec: 2 * 3600 ~/ c,
    bridgeGapSec: 30 * 60 ~/ c,
    smoothSec: 300 / c,
    maxSampleGapSec: maxGapSec ~/ c,
  );
  final sorted = [for (final h in asDouble) if (h > 0) h]..sort();
  final rough = run(sorted.sublist(sorted.length ~/ 2));
  final awake = rough == null
      ? <double>[]
      : [
          for (var i = 0; i < ts.length; i++)
            if (asDouble[i] > 0 &&
                (ts[i] < rough.onsetSec || ts[i] >= rough.offsetSec))
              asDouble[i],
        ];
  awake.sort();
  // Each sample stands for the record's usual spacing, which is [c] on a
  // one-sample-per-[c] device and longer on one that samples less often.
  final gaps = [for (var i = 1; i < tsSec.length; i++) tsSec[i] - tsSec[i - 1]]
    ..sort();
  final step = gaps.isEmpty ? c : math.max(c, gaps[gaps.length ~/ 2]);
  final w = awake.length * step >= 4 * 3600
      ? run(awake.sublist(0, awake.length ~/ 2))
      : run(null);
  return w == null
      ? null
      : (
          onsetSec: w.onsetSec * c,
          offsetSec: w.offsetSec * c,
          thresholdBpm: w.thresholdBpm,
        );
}

/// One row of a device's column in the metric x device table: where OUR
/// number sits in the stored day (or the cross-day rollup), which device
/// slot holds the device's own, what we estimate where the device gives
/// nothing, and why the row is unavailable when nothing fills it.
class Cell {
  final num? Function(Map day, Map crossDay)? ours;
  final String? ourMethod;
  final String? device;
  final num? Function(Map day, Map crossDay)? estimated;
  final String? estimatedMethod;
  final Why reason;

  /// What the wearable ALONE serves at best (PLAN §3b), where an accessor can
  /// also be filled by something else: HRR is ours only off a strap session.
  final MetricClass? best;

  /// Where the day's payload marks ours as provisional (`provisional: true`
  /// on that envelope): a ring's skin temperature, and the readiness that
  /// takes it in, rest on a settle band set on synthetic nights.
  final List<String>? provisionalAt;
  const Cell({
    this.ours,
    this.ourMethod,
    this.device,
    this.estimated,
    this.estimatedMethod,
    required this.reason,
    this.best,
    this.provisionalAt,
  });
}

/// A stored day's scalar, or null.
num? scalar(Map day, String key) => (day['scalars'] as Map?)?[key] as num?;

/// The stored night's in-bed span (onset to wake, wall clock) in whole
/// minutes, or null with no night. The `sleep_window` row is this quantity
/// for every device, ours and the device's alike. An abstained envelope
/// stores '—' for its value: also null.
num? nightInBedMin(Map day) {
  final s = at(day, ['sleep', 'accounting', 'value', 'in_bed_sec']);
  return s == null ? null : s ~/ 60;
}

/// The session override's row, the same on every wearable: a flagged-on
/// strap's sessions are ours at 1 Hz on the wearable's day
/// ([withStrapSessions]). The wearable alone has none.
final Cell strapWorkoutsCell = Cell(
  ours: (d, _) => d['strap_sessions'] as num?,
  ourMethod: 'hr_1hz',
  best: MetricClass.unavailable,
  reason: Why.needsStrap,
);

/// Heart-rate recovery: no wearable's sparse HR has a recovery curve in it,
/// so it is the strap session's alone, read off its 1 Hz tail.
final Cell strapHrrCell = Cell(
  ours: (d, _) => scalar(d, 'hrr_bpm'),
  ourMethod: 'hr_1hz',
  best: MetricClass.unavailable,
  reason: Why.needsStrap,
);

/// The method of a value read off a strap's beats on a wearable's day.
const String kRrStrapMethod = 'rr_strap';

/// A row ours off a strap's beats ([withStrapSessions]): the day's [key]
/// scalar, which only beats fill on a wearable's day ([kStrapBeatSeriesKeys]),
/// with the wearable's own [device] value beside it; that value alone (or
/// nothing) on a day the strap gave no beats.
Cell strapBeatCell(String key, {String? device, required Why reason}) => Cell(
  ours: (d, _) => scalar(d, key),
  ourMethod: kRrStrapMethod,
  device: device,
  best: device == null ? MetricClass.unavailable : MetricClass.device,
  reason: reason,
);

/// HRV: ours off a strap's beats on a night it was worn at rest.
Cell strapHrvCell({String? device, required Why reason}) =>
    strapBeatCell('rmssd', device: device, reason: reason);

/// Each row's served cell: the primary value by Ours > Device > Estimated >
/// Unavailable, with the device's own value carried beside ours for the
/// side-by-side presentation. [deviceValues] are already on slot names.
/// Ours and estimates carry the `band` their method measured on [family]'s
/// profile ([methodBand]), where one was.
Map<String, Map<String, Object?>> resolveCells(
  Map<String, Cell> column, {
  required Map day,
  required Map crossDay,
  required Map<String, num> deviceValues,
  required String? method,
  String? family,
}) => {
  for (final MapEntry(key: row, value: c) in column.entries)
    row: () {
      final ours = c.ours?.call(day, crossDay);
      final dev = c.device == null ? null : deviceValues[c.device];
      final est = dev == null ? c.estimated?.call(day, crossDay) : null;
      // Ours off the device's stages only on a night the device staged; on a
      // night our HR-led window found, ours off its HR ([seriesMethodFor]).
      final ourHow =
          c.ourMethod == 'device_stages' &&
              day['sleep_source'] != 'vendor_staged'
          ? method
          : c.ourMethod ?? method;
      final (cls, value, how) = ours != null
          ? (MetricClass.ours, ours, ourHow)
          : dev != null
          ? (MetricClass.device, dev, 'device')
          : est != null
          ? (MetricClass.estimated, est, c.estimatedMethod)
          : (MetricClass.unavailable, null, null);
      return <String, Object?>{
        'class': cls.name,
        'value': value,
        'method': how,
        if (dev != null && cls != MetricClass.device) 'device_value': dev,
        if (cls == MetricClass.unavailable) 'reason': c.reason.name,
        if (cls == MetricClass.ours || cls == MetricClass.estimated)
          'band': ?methodBand(family, row, how),
        if (cls == MetricClass.ours &&
            c.provisionalAt != null &&
            c.provisionalAt!.fold<Object?>(
                  day,
                  (v, k) => v is Map ? v[k] : null,
                ) ==
                true)
          'provisional': true,
      };
    }(),
};

/// Each `metric_series` key's row in the metric x device table. A key not
/// here (a quantity with no row of its own, such as `dyn_p90`) is ours.
const Map<String, String> kSeriesKeyRow = {
  'rhr': 'resting_hr',
  'dip_pct': 'nadir_dip',
  'rmssd': 'hrv',
  'ln_rmssd': 'hrv',
  'sdnn': 'hrv',
  'lf_hf': 'hrv',
  'hrv_cv': 'hrv',
  'resp_rate': 'respiratory_rate',
  'stress': 'stress',
  'skin_temp_z': 'skin_temp',
  'skin_temp_adc': 'skin_temp',
  'readiness': 'readiness',
  'readiness_z': 'readiness',
  'irregular_rhythm_flag': 'irregular_rhythm',
  'tst_min': 'sleep_window',
  'efficiency': 'efficiency_awakenings',
  'awakenings': 'efficiency_awakenings',
  'deep_min': 'sleep_stages',
  'rem_min': 'sleep_stages',
  'light_min': 'sleep_stages',
  'nap_min': 'naps',
  'strain': 'strain',
  'trimp': 'strain',
  'calories': 'calories',
  'calories_total': 'calories',
  'steps': 'steps',
  'active_min': 'movement',
  'hrr_bpm': 'hrr',
  'hrr_tau_s': 'hrr',
};

/// `metric_series` keys a wearable's day has only from a flagged-on strap's
/// beats ([withStrapSessions]): no wearable's own sparse HR carries beats, so
/// each is ours off the strap whatever its row says about the wearable alone.
const Set<String> kStrapBeatSeriesKeys = {
  'resp_rate',
  'stress',
  'irregular_rhythm_flag',
  'prsa_dc',
  'brv_cv',
};

/// A stored value's method, method family and class (`metric_method`).
typedef SeriesMethod = ({String method, String family, String cls});

/// `metric_series` keys that measure the night's window itself. On a night
/// the device staged (`sleep_source` 'vendor_staged') they are read off its
/// own onset, wake and epochs, so they are its values, not ours.
const Set<String> kVendorNightSeriesKeys = {
  'tst_min',
  'longest_sleep_min',
  'sleep_onset_sec',
  'midsleep_sec',
};

/// For a day derived from [family]'s data, the [SeriesMethod] each
/// `metric_series` key is stored under: ours at the family's resolution
/// unless its column says the row is the device's own value or our estimate,
/// or [vendorNight] says the night's window was the device's own.
/// Null for a family with no validated method (nothing is written).
SeriesMethod Function(String key)? seriesMethodFor(
  String? family, {
  bool vendorNight = false,
  bool strapNight = false,
  bool provisionalReadiness = false,
}) {
  final fam = methodFamily(family);
  if (fam == null) return null;
  // A ring night a strap's beats own ([ouraStrapOwnsNight]).
  final strapBeats = strapNight && family == kOuraFamily;
  final column = strapBeats ? kOuraStrapNightColumn : columnFor(family);
  return (key) => switch (column?[kSeriesKeyRow[key]]) {
    // A wearable's provisional readiness is not drawn as a measured point
    // either ([withoutWearableEstimates]); a band's day is left as it is.
    _ when column != null && provisionalReadiness && key == 'readiness' => (
      method: fam,
      family: fam,
      cls: MetricClass.estimated.name,
    ),
    _ when column != null &&
        vendorNight &&
        kVendorNightSeriesKeys.contains(key) => (
      method: 'device',
      family: 'device',
      cls: MetricClass.device.name,
    ),
    _ when family == kUltrahumanFamily && kRingDaySeriesKeys.contains(key) =>
      (method: fam, family: fam, cls: MetricClass.ours.name),
    // A ring that gives its own beats: ours off them where its column serves
    // the row, nothing where it does not ([kOuraColumn]); a strap's on a
    // night its beats own.
    _ when family == kOuraFamily &&
        (key == 'prsa_dc' || key == 'brv_cv') => (
      method: strapBeats ? kRrStrapMethod : kRrRingMethod,
      family: fam,
      cls: MetricClass.ours.name,
    ),
    _ when column != null &&
        family != kOuraFamily &&
        kStrapBeatSeriesKeys.contains(key) => (
      method: kRrStrapMethod,
      family: fam,
      cls: MetricClass.ours.name,
    ),
    // Ours off the device's stages only on a night the device staged; on a
    // night our HR-led window found, the same figure is ours off its HR.
    final Cell c? when c.ours != null => (
      method: c.ourMethod == 'device_stages' && !vendorNight
          ? fam
          : c.ourMethod ?? fam,
      family: fam,
      cls: MetricClass.ours.name,
    ),
    final Cell c? when c.estimated != null => (
      method: c.estimatedMethod ?? fam,
      family: fam,
      cls: MetricClass.estimated.name,
    ),
    Cell(device: _?) => (
      method: 'device',
      family: 'device',
      cls: MetricClass.device.name,
    ),
    // A row the column serves as unavailable: whatever the engine stored for
    // it is not a measurement of this wearable's.
    Cell() => (method: fam, family: fam, cls: MetricClass.unavailable.name),
    _ => (method: fam, family: fam, cls: MetricClass.ours.name),
  };
}

/// A stored day as the native cards (Today, Sleep, Strain) may show it: on a
/// wearable's day, every scalar its column serves as Estimated is taken out,
/// with the strain zones and curves when strain is one and the hypnogram when
/// the stages are. The labelled wearable cards show those, or hide them when
/// the person hides estimates; bare on a native card they would read as a
/// band's measurement. A band's day comes back as it is. The same goes for a
/// provisional readiness (a ring's partial composite on its provisional
/// temperature band), and for the hypnogram of a night that is our HR-led
/// window alone ([colmiNight]): it holds no stages, only "asleep".
///
/// ponytail: removed, not labelled; the native cards grow an Estimated label
/// if a wearable's estimates are wanted there.
Map<String, dynamic> withoutWearableEstimates(Map<String, dynamic> b) {
  final family = b['device_family'] as String?;
  final of = columnFor(family) == null ? null : seriesMethodFor(family);
  final scalars = b['scalars'];
  if (of == null || scalars is! Map) return b;
  // A row the column serves as unavailable is not this wearable's number
  // either (an Oura's strain, which the engine still computes off its HR).
  bool est(String k) =>
      of(k).cls == MetricClass.estimated.name ||
      of(k).cls == MetricClass.unavailable.name;
  final provisional =
      ((b['clinical'] as Map?)?['readiness_composite'] as Map?)?['provisional'] ==
          true;
  final out = {
    ...b,
    'scalars': {...scalars}..removeWhere(
        (k, _) => est('$k') || (k == 'readiness' && provisional)),
  };
  final series = b['series'];
  if (series is Map) {
    out['series'] = {
      ...series,
    }..removeWhere(
        (k, _) =>
            (k == 'hypnogram' &&
                (est('deep_min') || b['sleep_source'] == 'auto_fallback')) ||
            ((k == 'strain_curve' || k == 'zone_timeline') && est('strain')),
      );
  }
  if (est('strain')) out.remove('zones');
  // The night's stage minutes are the same estimate as deep_min: the Sleep
  // screen's stage block reads them off the accounting.
  final sleep = b['sleep'];
  final accounting = sleep is Map ? sleep['accounting'] : null;
  final acct = accounting is Map ? accounting['value'] : null;
  if (est('deep_min') && acct is Map) {
    out['sleep'] = {
      ...sleep as Map,
      'accounting': {
        ...accounting as Map,
        'value': {...acct}..removeWhere((k, _) =>
            const {'light_sec', 'deep_sec', 'rem_sec', 'nrem_sec'}.contains(k)),
      },
    };
  }
  return out;
}

/// Each clinical envelope's `metric_series` key, where its name is not one.
/// An envelope not here shares the day's default method ([seriesMethodFor]).
const Map<String, String> kEnvelopeSeriesKey = {
  'hrv_time': 'rmssd',
  'rmssd_sleep_session': 'rmssd',
  'rmssd_nocturnal': 'rmssd',
  'cv': 'hrv_cv',
  'hrv_freq': 'lf_hf',
  'irregular': 'irregular_rhythm_flag',
  'irregular_24h': 'irregular_rhythm_flag',
  'resting_hr': 'rhr',
  'hr_dip': 'dip_pct',
  'readiness_lnrmssd': 'readiness',
  'readiness_composite': 'readiness',
};

/// Stamps `method`, `family` and `class` on every envelope in [clinical] (it
/// already carries `tier`) for a day derived from [family]'s data, so each
/// stored metric says how it was made (PLAN §2/§7). An absent envelope is
/// `unavailable`; its `note` is the reason. A 1 Hz band's day is left
/// exactly as it is: no stamp there means ours at `hr_1hz`, which its
/// `metric_method` rows also say per key, so no band payload moves.
void tagEnvelopes(Map? clinical, String? family) {
  final of = seriesMethodFor(family);
  if (clinical == null || of == null || columnFor(family) == null) return;
  for (final MapEntry(:key, :value) in clinical.entries) {
    if (value is! Map) continue;
    final m = of(kEnvelopeSeriesKey[key] ?? key);
    value['method'] = m.method;
    value['family'] = m.family;
    value['class'] =
        value['value'] == '—' ? MetricClass.unavailable.name : m.cls;
  }
}

/// [adapterId]'s column of the metric x device table, or null for a device
/// with none (every band, sensor and scale).
Map<String, Cell>? columnFor(String? adapterId) => switch (adapterId) {
  kGarminFamily => kGarminColumn,
  kPebbleFamily => kPebbleColumn,
  kMiBandFamily => kMiBandColumn,
  kUltrahumanFamily => kUltrahumanColumn,
  kColmiFamily => kColmiColumn,
  kOuraFamily => kOuraColumn,
  _ => null,
};

/// What a column can serve at best, row by row, read off its cells rather
/// than written per screen: ours where we compute one, else the device's own
/// value, else an estimate, else unavailable. For "what this unlocks" before
/// pairing; a given day can still fall to a lower class.
Map<String, MetricClass> capabilities(Map<String, Cell> column) => {
  for (final MapEntry(key: row, value: c) in column.entries)
    row: c.best != null
        ? c.best!
        : c.ours != null
        ? MetricClass.ours
        : c.device != null
        ? MetricClass.device
        : c.estimated != null
        ? MetricClass.estimated
        : MetricClass.unavailable,
};

/// The day's served cells for the active wearable, or null when none is
/// chosen, the band saw the day, or the stored day is another device's. SERVE time only: the device's values come from the display read
/// and sit beside ours; nothing here feeds a derive.
Future<Map<String, Map<String, Object?>>?> dayCells(String date) async {
  final wearable = await activeWearable();
  final column = columnFor(wearable?.$2);
  if (wearable == null || column == null) return null;
  final stored = _decode((await LocalDb.dayResult(date))?['payload_json']);
  // A stored day the wearable did not derive (the band covers it and wins)
  // is not this column's: its numbers would read as the wearable's. Nor is a
  // day the band saw and the derive has not reached yet (right after a sync).
  if ((stored.isNotEmpty && stored['device_family'] != wearable.$2) ||
      await _bandSawDay(date)) {
    return null;
  }
  final day = {...stored, 'strap_sessions': await strapSessionCount(date)};
  // A watch with no HR sensor (Pebble 2 SE) never derives a day, so no
  // rollup is its: one as of today is another device's days.
  final noHr = wearable.$2 == kPebbleFamily &&
      stored.isEmpty &&
      !await pebbleHasHr(wearable.$1);
  final crossDay = noHr ? const {} : await crossDayAsOf(date);
  // Minute counts add up across the day's sleep periods (a night the watch
  // split in two is still one night); a device's daily mean kept over
  // several of its files is their mean; any other value is the latest.
  final deviceValues = <String, num>{};
  final means = <String, List<num>>{};
  final obs = [...await LocalDb.observationsForDay(date)]
    ..sort((a, b) => (a['ts_ms'] as int).compareTo(b['ts_ms'] as int));
  for (final o in obs) {
    if (o['device_id'] != wearable.$1) continue;
    final name = (o['vendor_key'] ?? o['key']) as String?;
    final slot = kDeviceValueSlot[name];
    final v = o['value'];
    if (slot == null || v is! num) continue;
    if (name!.endsWith('_avg')) {
      final xs = means[slot] ??= [];
      xs.add(v);
      deviceValues[slot] =
          xs.length == 1 ? v : xs.reduce((a, b) => a + b) / xs.length;
      continue;
    }
    deviceValues[slot] =
        slot.endsWith('_min') ? (deviceValues[slot] ?? 0) + v : v;
  }
  // A ring's night values, over the night itself: its stored means for these
  // run over the calendar day, waking hours included. No night, none.
  // A day value dropped for want of a night is the ring's, just not a night's:
  // its row says no night, not that the ring gave nothing.
  // Keyed on the wearable, not the stored day, so a ring day not derived
  // yet (no stored night) serves no day mean either, as the timeline shows.
  final dayOnly = <String>{};
  if (wearable.$2 == kUltrahumanFamily) {
    final night = (day['ring_day'] as Map?)?['device_night'];
    for (final k in const ['rmssd', 'spo2', 'skin_temp_c']) {
      if (deviceValues.remove(k) != null) dayOnly.add(k);
      if (night is Map && night[k] is num) {
        deviceValues[k] = night[k] as num;
        dayOnly.remove(k);
      }
    }
  }
  // The stored night IS the watch's own when it staged it, so its in-bed span
  // (onset to wake, the quantity our HR-led window measures) is the watch's
  // value, not ours.
  final inBed = nightInBedMin(day);
  if (day['sleep_source'] == 'vendor_staged' && inBed != null) {
    deviceValues['in_bed_min'] = inBed;
  }
  // A ring's stage minutes arrive page by page, each at its own stamp, so a
  // night crossing midnight has rows on two days: the night it staged is the
  // one sum that is all of it, on its wake day. Not staged, none. A watch's
  // rows are per sleep file, so a nap's file on the night's date would add
  // to it: once the day is derived, the night it staged is its sum too (the
  // night sleep_window and efficiency read); before, its rows. A Mi Band
  // banks rows for every sleep block it records, daytime ones included, so
  // the same holds for it.
  if (wearable.$2 == kOuraFamily ||
      ((wearable.$2 == kGarminFamily || wearable.$2 == kMiBandFamily) &&
          stored.isNotEmpty)) {
    for (final s in const ['deep', 'light', 'rem', 'wake']) {
      deviceValues.remove('${s}_min');
      final sec = day['sleep_source'] == 'vendor_staged'
          ? at(day, ['sleep', 'accounting', 'value', '${s}_sec'])
          : null;
      if (sec != null) deviceValues['${s}_min'] = sec / 60;
    }
  }
  // An Oura's RMSSD and SpO2 arrive per event or per batch, so a night
  // crossing midnight has rows on both days: the night's are the rows from
  // 18:00 the evening before to 14:00 (the ring takes neither by day).
  final lo = localDayStartSec(date);
  if (wearable.$2 == kOuraFamily && lo != null) {
    final prev =
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch((lo - 1) * 1000));
    final night = <String, List<num>>{};
    for (final o in [...await LocalDb.observationsForDay(prev), ...obs]) {
      final t = (o['ts_ms'] as int) ~/ 1000;
      final slot = kDeviceValueSlot[o['vendor_key']];
      if (o['device_id'] == wearable.$1 &&
          (slot == 'rmssd' || slot == 'spo2') &&
          o['value'] is num &&
          t >= lo - 6 * 3600 &&
          t < lo + 14 * 3600) {
        (night[slot!] ??= []).add(o['value'] as num);
      }
    }
    for (final k in const ['rmssd', 'spo2']) {
      deviceValues.remove(k);
      final xs = night[k];
      if (xs != null) deviceValues[k] = xs.reduce((a, b) => a + b) / xs.length;
    }
  }
  // A night a strap's beats own: the rows read off its beats are the strap's.
  final served = wearable.$2 == kOuraFamily &&
          await ouraStrapOwnsNight(
              wearable.$1, (stored['sleep'] as Map?)?['window'])
      ? kOuraStrapNightColumn
      : column;
  final cells = resolveCells(
    served,
    day: day,
    crossDay: crossDay,
    deviceValues: deviceValues,
    method: hrMethod(day['device_family'] as String?),
    family: day['device_family'] as String?,
  );
  for (final (row, slot, why) in const [
    ('hrv', 'rmssd', Why.noDeviceHrv),
    ('spo2', 'spo2', Why.noDeviceSpo2),
  ]) {
    final c = cells[row];
    // A Colmi writes these means over its own night only: a ring that
    // staged none gave its readings, just no night to hold them.
    final ringNoNight = wearable.$2 == kColmiFamily &&
        day['sleep_source'] != 'vendor_staged';
    if ((dayOnly.contains(slot) || ringNoNight) && c?['reason'] == why.name) {
      c!['reason'] = Why.noNight.name;
    }
    // An Ultrahuman never stages a night (we do): beside a served window,
    // a day mean with no night value is the ring's night giving no reading,
    // not a night it did not stage.
    if (dayOnly.contains(slot) &&
        c?['reason'] == Why.noNight.name &&
        cells['sleep_window']?['class'] != MetricClass.unavailable.name) {
      c!['reason'] = Why.noNightReading.name;
    }
  }
  // A night is served (our HR-led window), just not one the device staged:
  // "no night stored" would contradict the window beside it.
  if (cells['sleep_window']?['class'] != MetricClass.unavailable.name) {
    for (final c in cells.values) {
      if (c['class'] == MetricClass.unavailable.name &&
          c['reason'] == Why.noNight.name) {
        c['reason'] = Why.noStagedNight.name;
      }
    }
  }
  // A ring that keeps its nights in a form we bank but do not decode did
  // record the night: what its night would have given is not decoded, not
  // missing.
  if (wearable.$2 == kColmiFamily && await colmiSleepUndecoded(wearable.$1)) {
    for (final row in kColmiNightRows) {
      final c = cells[row];
      if (c?['class'] == MetricClass.unavailable.name) {
        c!['reason'] = Why.notDecoded.name;
      }
    }
  }
  // The rows built on derived nights and days never fill on [noHr]: say
  // so, never "needs three nights", which would not clear.
  if (noHr) {
    for (final (row, why) in const [
      ('sleep_debt_need_sri', Why.noNightHr),
      ('circadian', Why.noWakeHr),
    ]) {
      final c = cells[row];
      if (c?['class'] == MetricClass.unavailable.name) c!['reason'] = why.name;
    }
  }
  return cells;
}

/// Whether [date] is the band's, not the active wearable's: the band saw
/// it, or the stored day is one no wearable column derived. [dayCells] is
/// null on such a day, and never will be otherwise.
Future<bool> bandHasDay(String date) async {
  final stored = _decode((await LocalDb.dayResult(date))?['payload_json']);
  return (stored.isNotEmpty &&
          columnFor(stored['device_family'] as String?) == null) ||
      await _bandSawDay(date);
}

/// Whether the primary band has a row on the local day [date]: the band's
/// day, the same calendar test the derive's scope uses
/// ([LocalDb.decodedRecTsMaxByDay]).
Future<bool> _bandSawDay(String date) async {
  final lo = localDayStartSec(date);
  final hi = localDayEndSec(date);
  if (lo == null || hi == null) return false;
  final db = await LocalDb.instance;
  return (await db.rawQuery(
    'SELECT 1 FROM decoded_onehz WHERE rec_ts > 0 AND ${derivableSourceSql()} '
    'AND rec_ts >= ? AND rec_ts < ? LIMIT 1',
    [lo, hi],
  )).isNotEmpty;
}

/// The sessions starting on [date] that a flagged-on workout sensor
/// recorded (the session override, [sessionWindowRows]), or null for none.
Future<int?> strapSessionCount(String date) async {
  final ids = LocalDb.sessionSensorSources;
  final lo = localDayStartSec(date);
  final hi = localDayEndSec(date);
  if (ids.isEmpty || lo == null || hi == null) return null;
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS n FROM sessions s WHERE s.start_ts >= ? AND s.start_ts < ? '
    'AND EXISTS (SELECT 1 FROM decoded_onehz d WHERE d.rec_ts >= s.start_ts '
    'AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) AND d.hr > 0 '
    'AND d.source IN (${ids.map((s) => "'$s'").join(', ')}))',
    [lo, hi],
  );
  final n = (rows.first['n'] as num).toInt();
  return n == 0 ? null : n;
}

Map _decode(Object? raw) => raw is String ? jsonDecode(raw) as Map : const {};

/// The cross-day rollup as of [date]: the stored one when [date] is its
/// newest day, else rebuilt over the stored inputs up to [date], so a past
/// day's sleep debt, regularity and circadian rhythm are those nights', not
/// today's. Empty under the rollup's own three-day minimum, and when the
/// stored inputs were written by another algorithm version or before the
/// user's last activity review (the gates the engine's own read applies).
///
/// The rebuild runs off the UI isolate: the inputs hold up to 90 days with
/// hourly HR, and the engine moved this same decode and build into an
/// isolate for the multi-second hangs it caused on the main one. The rows'
/// `is_today` stamps are the build day's, so they are restamped for [date].
Future<Map> crossDayAsOf(String date) async {
  final stored = _decode((await LocalDb.baseline('crossday'))?['payload_json']);
  final recent = stored['recent'];
  if ((stored['algo_version'] as num?)?.toInt() == kAlgoVersion &&
      recent is List && recent.isNotEmpty && recent.last is Map &&
      (recent.last as Map)['date'] == date) {
    return stored;
  }
  final raw = (await LocalDb.baseline('crossday_input'))?['payload_json'];
  if (raw is! String) return const {};
  final reviewRevision = await LocalDb.activityReviewRevision();
  return Isolate.run(() {
    final input = jsonDecode(raw);
    if (input is! Map ||
        (input['algo_version'] as num?)?.toInt() != kAlgoVersion ||
        input['review_revision'] != reviewRevision) {
      return const <String, dynamic>{};
    }
    final days = <Map<String, dynamic>>[
      for (final d in (input['days'] as List?) ?? const [])
        if (d is Map && d['date'] is String &&
            (d['date'] as String).compareTo(date) <= 0)
          {
            ...d.cast<String, dynamic>()..remove('is_today'),
            if (d['date'] == date) 'is_today': true,
          },
    ];
    return days.length < 3
        ? const <String, dynamic>{}
        : buildCrossDayBundle(days, const {});
  });
}

/// [deviceId]'s own values on [date] that have no slot of ours — a vendor's
/// proprietary scores. They belong on that device's page and never in one of
/// our cells, which only read [kDeviceValueSlot] keys. The latest value per key.
Future<Map<String, ({num value, String? unit})>> deviceOwnScores(
  String deviceId,
  String date,
) async => {
  // Latest per key: the read is ordered by attribution, not time.
  for (final o in [...await LocalDb.observationsForDay(date)]
    ..sort((a, b) => (a['ts_ms'] as int).compareTo(b['ts_ms'] as int)))
    if (o['device_id'] == deviceId && _ownScore(o) && o['value'] is num)
      o['vendor_key'] as String: (
        value: o['value'] as num,
        unit: o['unit'] as String?,
      ),
};

/// A device's per-period minutes (one row per walk, run or nap): events
/// for the day timeline, not a daily score; a page showing only the latest
/// would read one walk as the day's.
const Set<String> kDevicePeriodKeys = {'walk_min', 'run_min', 'nap_deep_min'};

/// A device value with no slot of ours: the device's own score.
bool _ownScore(Map<String, Object?> o) =>
    o['vendor_key'] is String &&
    !kDeviceValueSlot.containsKey(o['vendor_key']) &&
    !kDevicePeriodKeys.contains(o['vendor_key']) &&
    !(o['vendor_key'] as String).startsWith('sleep_');

/// A day's [rows] (`LocalDb.observationsForDay`) as the day timeline lists
/// them. A wearable's own scores, and its stress index (a vendor's own
/// scale), live on its device page, not here. A daily mean kept over several
/// of a device's files is one row, their mean, the value its column serves.
/// A ring's calendar-day means its column serves over the night instead are
/// that night's value, or no row with no night. An Oura's stage pages,
/// RMSSD and SpO2 on [date] are one row each over the night that ends on it
/// ([_ouraNightRows]), as its column serves them. A Garmin's or Mi Band's
/// stage rows, one per sleep file (a nap's beside the night's), are one row
/// per stage, the value its column serves. A paired device whose flag
/// is off lists nothing (rule R6).
Future<List<Map<String, Object?>>> timelineObservations(
  List<Map<String, Object?>> rows, {
  String? date,
}) async {
  final wearable = <Object?, bool>{};
  final flagOn = <Object?, bool>{};
  final ring = <Object?, bool>{};
  final oura = <Object?, bool>{};
  final ouraRow = <String, Map<String, Object?>>{};
  final means = <String, (Map<String, Object?>, List<num>)>{};
  final watch = <Object?, String?>{};
  final stageRows =
      <String, (Map<String, Object?>, List<Map<String, Object?>>)>{};
  final out = <Map<String, Object?>>[];
  for (final o in rows) {
    final id = o['device_id'];
    final key = o['vendor_key'];
    if (id is String &&
        id != LocalDb.kPrimaryDeviceId &&
        !(flagOn[id] ??= await deviceFlagOn(id))) {
      continue;
    }
    if (key is String &&
        (key.startsWith('sleep_') || key == 'hrv_avg' || key == 'spo2_avg') &&
        (oura[id] ??= id is String &&
            (await LocalDb.deviceRow(id))?['adapter_id'] == kOuraFamily)) {
      ouraRow[id as String] ??= o;
      continue;
    }
    final stage = kDeviceValueSlot[key];
    if (key is String &&
        key.startsWith('sleep_') &&
        const {'deep_min', 'light_min', 'rem_min', 'wake_min'}
            .contains(stage) &&
        o['value'] is num &&
        (watch.containsKey(id)
                ? watch[id]
                : watch[id] = await _stagesPerFile(id)) !=
            null) {
      final seen = stageRows['$id|${o['date']}|$stage'];
      if (seen != null) {
        seen.$1['value'] = (seen.$1['value'] as num) + (o['value'] as num);
        seen.$2.add(o);
        continue;
      }
      final row = {...o};
      stageRows['$id|${o['date']}|$stage'] = (row, [o]);
      out.add(row);
      continue;
    }
    if ((_ownScore(o) || key == 'stress_avg') &&
        (wearable[id] ??= id is String &&
            categoryOf((await LocalDb.deviceRow(id))?['adapter_id']
                    as String?) ==
                DeviceCategory.wearable)) {
      continue;
    }
    final v = o['value'];
    if (const {'hrv_avg', 'spo2_avg', 'skin_temp_avg'}.contains(key) &&
        (ring[id] ??= id is String &&
            (await LocalDb.deviceRow(id))?['adapter_id'] ==
                kUltrahumanFamily)) {
      final day = _decode((await LocalDb.dayResult(dayLabelOf(
              DateTime.fromMillisecondsSinceEpoch(o['ts_ms'] as int))))?[
          'payload_json']);
      final ringDay = day['ring_day'];
      final night = day['device_family'] == kUltrahumanFamily && ringDay is Map
          ? ringDay['device_night']
          : null;
      final n = night is Map ? night[kDeviceValueSlot[key]] : null;
      if (n is num) out.add({...o, 'value': n});
      continue;
    }
    if (key is String && key.endsWith('_avg') && v is num) {
      final seen = means['$id|$key'];
      if (seen != null) {
        seen.$2.add(v);
        seen.$1['value'] = seen.$2.reduce((a, b) => a + b) / seen.$2.length;
        continue;
      }
      final row = {...o};
      means['$id|$key'] = (row, [v]);
      out.add(row);
      continue;
    }
    out.add(o);
  }
  // The active watch's: before the day is derived, the files' sum (as
  // [dayCells] has it); once derived, the night the watch staged, or no row
  // when it staged none. Another watch's, or a day another device derived
  // (no cell serves either): the per-file rows, unsummed.
  final active = stageRows.isEmpty ? null : await activeWearableId();
  for (final (r, files) in stageRows.values) {
    final day = date ??
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(r['ts_ms'] as int));
    final stored = _decode((await LocalDb.dayResult(day))?['payload_json']);
    if (r['device_id'] != active ||
        (stored.isNotEmpty &&
            stored['device_family'] != watch[r['device_id']])) {
      final i = out.indexOf(r);
      out.replaceRange(i, i + 1, files);
      continue;
    }
    if (stored.isEmpty) continue;
    final slot = kDeviceValueSlot[r['vendor_key']]!;
    final sec = stored['sleep_source'] == 'vendor_staged'
        ? at(stored, [
            'sleep',
            'accounting',
            'value',
            '${slot.substring(0, slot.length - 4)}_sec'
          ])
        : null;
    if (sec == null) {
      out.remove(r);
    } else {
      r['value'] = sec / 60;
    }
  }
  for (final MapEntry(key: id, value: o) in ouraRow.entries) {
    out.addAll(await _ouraNightRows(id, o,
        date ?? dayLabelOf(DateTime.fromMillisecondsSinceEpoch(o['ts_ms'] as int))));
  }
  return out;
}

/// [id]'s family when it banks stage minutes per sleep file (a Garmin, a
/// Mi Band), else null.
Future<String?> _stagesPerFile(Object? id) async {
  if (id is! String) return null;
  final family = (await LocalDb.deviceRow(id))?['adapter_id'];
  return family == kGarminFamily || family == kMiBandFamily
      ? family as String
      : null;
}

/// Ring [id]'s night ending on [date] as timeline rows, shaped like
/// [template] (one of its rows): each stage's minutes over the night the
/// derive staged off it, and its RMSSD and SpO2 means over 18:00 the evening
/// before to 14:00, the values [dayCells] serves. Another period waking on
/// [date] (a nap, or a night split at a gap) adds nothing; no staged night,
/// no stage rows.
Future<List<Map<String, Object?>>> _ouraNightRows(
  String id,
  Map<String, Object?> template,
  String date,
) async {
  final lo = localDayStartSec(date);
  if (lo == null) return const [];
  final stored = _decode((await LocalDb.dayResult(date))?['payload_json']);
  final w = (stored['sleep'] as Map?)?['window'];
  final v = w is Map && w['value'] is Map ? w['value'] : w;
  final wake = v is Map ? v['offset_ms'] : null;
  final minutes = <String, num>{};
  if (stored['sleep_source'] == 'vendor_staged' &&
      stored['device_family'] == kOuraFamily &&
      wake is num &&
      await activeWearableId() == id) {
    for (final s in const ['deep', 'light', 'rem', 'wake']) {
      final sec = at(stored, ['sleep', 'accounting', 'value', '${s}_sec']);
      if (sec != null) minutes[s] = sec / 60;
    }
  }
  final prev = dayLabelOf(DateTime.fromMillisecondsSinceEpoch((lo - 1) * 1000));
  final night = <String, List<num>>{};
  for (final o in [
    ...await LocalDb.observationsForDay(prev),
    ...await LocalDb.observationsForDay(date),
  ]) {
    final t = (o['ts_ms'] as int) ~/ 1000;
    final key = o['vendor_key'];
    if (o['device_id'] == id &&
        (key == 'hrv_avg' || key == 'spo2_avg') &&
        o['value'] is num &&
        t >= lo - 6 * 3600 &&
        t < lo + 14 * 3600) {
      (night[key as String] ??= []).add(o['value'] as num);
    }
  }
  Map<String, Object?> row(String key, num v, String unit, int atSec) => {
    ...template,
    'key': key,
    'vendor_key': key,
    'value': v,
    'unit': unit,
    'ts_ms': atSec * 1000,
  };
  return [
    for (final MapEntry(key: stage, value: m) in minutes.entries)
      row('sleep_${stage}_min', m, 'min', (wake as num) ~/ 1000),
    for (final MapEntry(key: k, value: xs) in night.entries)
      row(k, xs.reduce((a, b) => a + b) / xs.length,
          k == 'spo2_avg' ? '%' : 'ms', lo),
  ];
}
