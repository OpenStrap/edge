// Scale weighings → Apple Health / Health Connect WEIGHT samples.
//
// One sample per weighing, at the weighing's own instant, kg. Weight only: no
// body fat, BMI or impedance (those are the scale's, not ours to restate).
//
// WHY THIS IS NOT IN THE PER-DAY PASS. `healthDeleteTypes` drives a day-wide
// delete-then-rewrite from that day's `day_result`. A weighing is not part of
// any day_result, so WEIGHT must NOT be in that list: the pass would delete the
// day's weights and have nothing to write back.
//
// IDEMPOTENCE. Per device, a persisted SET of already-exported ts_ms (newest
// ~2000) decides what is sent: every eligible weighing not in the set goes out
// on each run, so a late-arriving OLDER weighing (history sync, backfill, clock
// correction) is not skipped the way a high-water cursor would skip it. Each
// send is delete-our-own-sample-at-that-instant, then write, so a lost set (or
// `reset`) re-sends without stacking duplicates. A failed weighing is skipped
// (later ones still go out) and retried on later runs, at most
// [kMaxWeightAttempts] times.
//
// HOUSEHOLD SCALES. A scale carries no user, so [exportableWeighings] runs a
// CHAINED band (kWeighingBand, see measurement_inputs.dart) before anything is
// exported: the first weighing seeds, any weighing more than the band away from
// the previous ACCEPTED one is dropped. Health samples cannot be recalled, so
// this is stricter than reading the newest weighing.
//
// NO ECHO LOOP. `health_profile_import.dart` reads WEIGHT from the store into
// the PROFILE (a profile field), never into `observation`. The source here is
// the scale's own stored weighings (`LocalDb.deviceObservationValues`, keyed by
// the scale's device id), so a weight read from the store has no row to export.
// observation_isolation_test keeps raw table access inside db.dart, so the
// source_kind column is not filtered here.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/adapters/_registry.dart' show DeviceCategory, categoryOf;
import '../ble/adapters/miscale.dart' show kWeightMaxKg, kWeightMinKg;
import '../compute/inputs/canonical.dart' show wearableEnabled;
import '../compute/inputs/measurement_inputs.dart' show nearWeight;
import '../data/db.dart';

/// Per-device persisted set (JSON list) of exported weighing ts_ms.
String healthWeightExportedKey(String deviceId) =>
    'health_weight_exported:$deviceId';

/// Per-device persisted failure counts (JSON map ts_ms -> attempts).
String healthWeightAttemptsKey(String deviceId) =>
    'health_weight_attempts:$deviceId';

/// Superseded high-water cursor (LocalDb cursor). Never read any more; only
/// cleared on reset.
String healthWeightCursorName(String deviceId) =>
    'health_weight_through:$deviceId';

/// Set once WEIGHT write permission has been requested on this install.
const String kHealthWeightPermAskedPref = 'health_weight_perm_asked';

/// Bound on the exported set per device (newest kept).
const int kMaxExportedWeighings = 2000;

/// Failed attempts after which a weighing is no longer retried. Mirrors
/// HealthExporter's `_kMaxExportAttempts`.
const int kMaxWeightAttempts = 6;

/// Half-width of the window that identifies "our sample for this weighing".
const Duration kHealthWeightMatchWindow = Duration(milliseconds: 500);

/// A weighing that may be exported, ascending by [atMs] when listed.
typedef Weighing = ({int atMs, double kg});

/// [raw] (ts_ms -> kg) as exportable weighings, ascending, minus [exported].
/// Skips non-finite and out-of-bounds values, then applies the chained
/// household band over ALL plausible weighings (so the chain does not depend
/// on what was exported before). Never substitutes a value.
@visibleForTesting
List<Weighing> exportableWeighings(
  Map<int, num> raw, {
  Set<int> exported = const {},
}) {
  final sorted = <Weighing>[
    for (final e in raw.entries)
      if (e.value.isFinite &&
          e.value >= kWeightMinKg &&
          e.value <= kWeightMaxKg)
        (atMs: e.key, kg: e.value.toDouble()),
  ]..sort((a, b) => a.atMs.compareTo(b.atMs));
  final out = <Weighing>[];
  double? prev;
  for (final w in sorted) {
    if (!nearWeight(w.kg, prev)) continue;
    prev = w.kg;
    if (!exported.contains(w.atMs)) out.add(w);
  }
  return out;
}

Set<int> _decodeSet(String? s) {
  try {
    return {for (final v in jsonDecode(s ?? '[]') as List) (v as num).toInt()};
  } catch (_) {
    return {};
  }
}

Map<int, int> _decodeAttempts(String? s) {
  try {
    return {
      for (final e in (jsonDecode(s ?? '{}') as Map).entries)
        int.parse(e.key as String): (e.value as num).toInt(),
    };
  } catch (_) {
    return {};
  }
}

/// Keeps only the newest [kMaxExportedWeighings] entries.
List<int> _bounded(Set<int> s) {
  final l = s.toList()..sort();
  return l.length > kMaxExportedWeighings
      ? l.sublist(l.length - kMaxExportedWeighings)
      : l;
}

/// Replace-write [weighings] (ascending). A failed weighing is skipped and its
/// attempt counted; later ones still go. Weighings already at
/// [kMaxWeightAttempts] are not tried. Persists via [save] after each change.
/// [stopped] (store hung) ends the run without counting the failure that
/// tripped it. Returns how many were written.
Future<int> writeWeighings({
  required List<Weighing> weighings,
  required Set<int> exported,
  required Map<int, int> attempts,
  required Future<void> Function() save,
  required Future<bool> Function(DateTime start, DateTime end) deleteOwn,
  required Future<bool> Function(double kg, DateTime at) write,
  bool Function()? stopped,
}) async {
  var written = 0;
  for (final w in weighings) {
    if (stopped?.call() ?? false) break;
    if ((attempts[w.atMs] ?? 0) >= kMaxWeightAttempts) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(w.atMs);
    // A delete that cannot clear the instant must not be written on top of.
    var ok = await deleteOwn(
      at.subtract(kHealthWeightMatchWindow),
      at.add(kHealthWeightMatchWindow),
    );
    if (ok) ok = await write(w.kg, at);
    if (ok) {
      written++;
      exported.add(w.atMs);
      attempts.remove(w.atMs);
    } else {
      if (stopped?.call() ?? false) break;
      attempts[w.atMs] = (attempts[w.atMs] ?? 0) + 1;
    }
    await save();
  }
  return written;
}

/// Whether WEIGHT can be written. [check] reads the grant (null = unknown),
/// [request] asks for it. Asks at most once per install ([kHealthWeightPermAskedPref]);
/// after that the write is always attempted (failures are bounded by attempts).
Future<bool> weightWritePermitted({
  required Future<bool> Function() check,
  required Future<void> Function() request,
  required Future<bool> Function() asked,
  required Future<void> Function() markAsked,
}) async {
  try {
    if (await check()) return true;
    if (!await asked()) {
      await request();
      // Only after the request ran: a throw/timeout leaves the ask unspent.
      await markAsked();
    }
    // Health Connect's hasPermissions(WRITE) is unreliable (null/false after a
    // grant), so never block on it once we've asked: attempt the write and let
    // the bounded per-weighing attempts absorb a real denial.
    return true;
  } catch (e) {
    debugPrint('[health] weight permission: $e');
    return false;
  }
}

/// Export every flagged-on scale's pending weighings. Best-effort; never
/// throws. [reset] clears the exported sets (re-sends everything,
/// idempotently). [permitted] is consulted lazily, only when something is
/// pending. The loaders default to [LocalDb]; tests inject their own.
Future<int> exportScaleWeighings({
  required Future<bool> Function(DateTime start, DateTime end) deleteOwn,
  required Future<bool> Function(double kg, DateTime at) write,
  Future<bool> Function()? permitted,
  bool Function()? stopped,
  bool reset = false,
  bool forceRetry = false,
  Future<List<Map<String, Object?>>> Function()? loadDevices,
  Future<bool> Function(String adapterId)? isEnabled,
  Future<Map<int, num>> Function(String deviceId)? loadWeights,
  Future<void> Function(String name)? deleteCursor,
}) async {
  var total = 0;
  try {
    final prefs = await SharedPreferences.getInstance();
    var permChecked = false;
    var permOk = true;
    for (final row in await (loadDevices ?? LocalDb.deviceRows)()) {
      final adapter = row['adapter_id'] as String?;
      final id = row['id'] as String?;
      if (id == null) continue;
      if (reset) {
        await prefs.remove(healthWeightExportedKey(id));
        await prefs.remove(healthWeightAttemptsKey(id));
        await (deleteCursor ?? LocalDb.deleteCursor)(
          healthWeightCursorName(id),
        );
      }
      if (adapter == null ||
          categoryOf(adapter) != DeviceCategory.healthMeasurement ||
          !await (isEnabled ?? wearableEnabled)(adapter)) {
        continue;
      }
      if (forceRetry && !reset) {
        await prefs.remove(healthWeightAttemptsKey(id));
      }
      final exported = _decodeSet(prefs.getString(healthWeightExportedKey(id)));
      final attempts = _decodeAttempts(
        prefs.getString(healthWeightAttemptsKey(id)),
      );
      final raw = await (loadWeights ??
          (d) => LocalDb.deviceObservationValues(d, 'weight'))(id);
      // A full set means older entries were trimmed: do not resurrect them.
      final floor = exported.length >= kMaxExportedWeighings
          ? exported.reduce((a, b) => a < b ? a : b)
          : 0;
      final pending = [
        for (final w in exportableWeighings(raw, exported: exported))
          if (w.atMs >= floor && (attempts[w.atMs] ?? 0) < kMaxWeightAttempts)
            w,
      ];
      if (pending.isEmpty) continue;
      if (!permChecked) {
        permChecked = true;
        permOk = permitted == null || await permitted();
      }
      if (!permOk) continue;
      total += await writeWeighings(
        weighings: pending,
        exported: exported,
        attempts: attempts,
        save: () async {
          await prefs.setString(
            healthWeightExportedKey(id),
            jsonEncode(_bounded(exported)),
          );
          await prefs.setString(
            healthWeightAttemptsKey(id),
            jsonEncode({
              for (final e in attempts.entries) '${e.key}': e.value,
            }),
          );
        },
        deleteOwn: deleteOwn,
        write: write,
        stopped: stopped,
      );
    }
  } catch (e) {
    debugPrint('[health] exportScaleWeighings: $e');
  }
  return total;
}
