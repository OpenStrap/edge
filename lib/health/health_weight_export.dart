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
// correction) is not skipped the way a high-water cursor would skip it. A
// normal send is a plain write: a weighing not in the set has no sample of ours
// to replace, and a failed replacement must never cost a sample that was
// exported earlier. Only a `reset` re-send deletes our own sample at that
// instant first (so it does not stack duplicates), and never when another
// weighing (any scale) sits inside the match window, since the delete is by
// type + time range and would take that sample too. A failed weighing is
// skipped (later ones still go out) and retried on later runs, at most
// [kMaxWeightAttempts] times. At most [kMaxWeighingsPerRun] per call.
//
// HOUSEHOLD SCALES. A scale carries no user, so [exportableWeighings] runs a
// CHAINED band (kWeighingBand, see measurement_inputs.dart) before anything is
// exported: the first weighing seeds, any weighing more than the band away from
// the previous ACCEPTED one is dropped, unless 3 consecutive rejects are near
// each other (then the run is accepted and re-seeds the chain). Health samples cannot be recalled, so
// this is stricter than reading the newest weighing.
//
// NO ECHO LOOP. `health_profile_import.dart` reads WEIGHT from the store into
// the PROFILE (a profile field), never into `observation`. The source here is
// the scale's own stored weighings (`LocalDb.deviceObservationValues`, keyed by
// the scale's device id), so a weight read from the store has no row to export.
// observation_isolation_test keeps raw table access inside db.dart, so the
// source_kind column is not filtered here.
import 'dart:async' show TimeoutException;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/adapters/_registry.dart' show DeviceCategory, categoryOf;
import '../ble/adapters/miscale.dart' show kWeightMaxKg, kWeightMinKg;
import '../compute/inputs/canonical.dart' show wearableEnabled;
import '../compute/inputs/measurement_inputs.dart' show weighingChain;
import '../data/db.dart';

/// Per-device persisted set (JSON list) of exported weighing ts_ms.
String healthWeightExportedKey(String deviceId) =>
    'health_weight_exported:$deviceId';

/// Per-device persisted failure counts (JSON map ts_ms -> attempts).
String healthWeightAttemptsKey(String deviceId) =>
    'health_weight_attempts:$deviceId';

/// Per-device persisted set (JSON list) of weighing instants whose native
/// write timed out and may still have landed. Kept across restarts so a retry
/// clears our sample there first instead of stacking a duplicate.
String healthWeightMaybeLandedKey(String deviceId) =>
    'health_weight_maybe_landed:$deviceId';

/// Per-device persisted set (JSON list) of weighing instants that were
/// exported and then aged out of the bounded exported set. Kept apart from the
/// never-exported instants so a late older weighing (backfill) is still sent
/// while an old exported one is not sent again.
String healthWeightTrimmedKey(String deviceId) =>
    'health_weight_trimmed:$deviceId';

/// Superseded high-water cursor (LocalDb cursor). Never read any more; only
/// cleared on reset.
String healthWeightCursorName(String deviceId) =>
    'health_weight_through:$deviceId';

/// Set once WEIGHT write permission has been requested on this install.
const String kHealthWeightPermAskedPref = 'health_weight_perm_asked';

/// Last observed WEIGHT grant (true/false) so a not-granted -> granted
/// transition can clear the per-weighing attempt caps.
const String kHealthWeightGrantSeenPref = 'health_weight_grant_seen';

/// Most weighings processed per [exportScaleWeighings] call; the rest stay
/// pending for the next drain so a big replay cannot hold the export lock long.
const int kMaxWeighingsPerRun = 200;

/// Bound on the exported set per device (newest kept).
const int kMaxExportedWeighings = 2000;

/// Bound on the aged-out exported history per device (newest kept). Past
/// kMaxExportedWeighings + kMaxTrimmedWeighings weighings on one scale the
/// oldest aged-out instant is forgotten, and a reset would send it again.
const int kMaxTrimmedWeighings = 10000;

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
/// on what was exported before), re-seeding after 3 consecutive mutually-near
/// rejects so a guest seed or a lasting weight change recovers (the same
/// [weighingChain] the trend uses). Never substitutes a value.
@visibleForTesting
List<Weighing> exportableWeighings(
  Map<int, num> raw, {
  Set<int> exported = const {},
}) {
  final chain = weighingChain([
    for (final e in raw.entries)
      if (e.value.isFinite && e.value >= kWeightMinKg && e.value <= kWeightMaxKg)
        (atMs: e.key, kg: e.value.toDouble()),
  ]);
  return [
    for (final w in chain)
      if (!exported.contains(w.atMs)) w,
  ];
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
List<int> _bounded(Set<int> s, [int max = kMaxExportedWeighings]) {
  final l = s.toList()..sort();
  return l.length > max ? l.sublist(l.length - max) : l;
}

/// Write [weighings] (ascending). A failed weighing is skipped and its
/// attempt counted; later ones still go. Weighings already at
/// [kMaxWeightAttempts] are not tried. Persists via [save] after each change.
/// [stopped] (store hung) ends the run without counting the failure that
/// tripped it. [mayContinue] is asked before EACH weighing; false ends the run
/// (opt-out mid-drain). With [resend] our own sample at the instant is deleted
/// first, unless [deleteSafe] says another sample shares the window. A delete
/// that succeeds but whose write then fails takes the instant out of
/// [exported], so it is pending again rather than recorded as in Health.
/// A [write] that throws [TimeoutException] may have landed: the instant goes
/// into [maybeLanded] and the next attempt clears our sample there first, but
/// only when [deleteSafe] allows it (otherwise it is left and retried, bounded
/// by the attempt cap, never deleting a neighbour's sample).
/// Returns how many were written.
Future<int> writeWeighings({
  required List<Weighing> weighings,
  required Set<int> exported,
  required Map<int, int> attempts,
  required Future<void> Function() save,
  required Future<bool> Function(DateTime start, DateTime end) deleteOwn,
  required Future<bool> Function(double kg, DateTime at) write,
  bool Function()? stopped,
  Future<bool> Function()? mayContinue,
  bool resend = false,
  bool Function(int atMs)? deleteSafe,
  Set<int>? maybeLanded,
  Set<int>? trimmed,
}) async {
  var written = 0;
  final landed = maybeLanded ?? <int>{};
  for (final w in weighings) {
    if (stopped?.call() ?? false) break;
    if (mayContinue != null && !await mayContinue()) break;
    if ((attempts[w.atMs] ?? 0) >= kMaxWeightAttempts) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(w.atMs);
    // Already in Health and the delete would take a neighbour's sample too:
    // keep what is there rather than stack a duplicate.
    if (resend &&
        (exported.contains(w.atMs) || (trimmed?.contains(w.atMs) ?? false)) &&
        !(deleteSafe?.call(w.atMs) ?? true)) {
      continue;
    }
    var ok = true;
    var deleted = false;
    final safe = deleteSafe?.call(w.atMs) ?? true;
    if ((resend || landed.contains(w.atMs)) && safe) {
      // A delete that cannot clear the instant must not be written on top of.
      ok = await deleteOwn(
        at.subtract(kHealthWeightMatchWindow),
        at.add(kHealthWeightMatchWindow),
      );
      deleted = ok;
      if (ok) landed.remove(w.atMs);
    } else if (landed.contains(w.atMs)) {
      // A possible survivor of a timed-out write, and the delete would take a
      // neighbour's sample too: leave it and retry later.
      ok = false;
    }
    if (ok) {
      try {
        ok = await write(w.kg, at);
      } on TimeoutException {
        ok = false;
        landed.add(w.atMs);
      }
    }
    if (ok) {
      written++;
      exported.add(w.atMs);
      trimmed?.remove(w.atMs);
      attempts.remove(w.atMs);
    } else {
      // Our sample was deleted and the replacement did not go in: it is no
      // longer in Health, so it must not stay marked as exported.
      if (deleted) {
        exported.remove(w.atMs);
        trimmed?.remove(w.atMs);
      }
      if (stopped?.call() ?? false) {
        await save();
        break;
      }
      attempts[w.atMs] = (attempts[w.atMs] ?? 0) + 1;
    }
    await save();
  }
  return written;
}

/// Whether WEIGHT can be written. [check] reads the grant (a throw or timeout
/// means UNKNOWN, and the write is still attempted), [request] asks for it.
/// Asks at most once per install ([kHealthWeightPermAskedPref]); after that the
/// write is always attempted (failures are bounded by attempts).
Future<bool> weightWritePermitted({
  required Future<bool> Function() check,
  required Future<void> Function() request,
  required Future<bool> Function() asked,
  required Future<void> Function() markAsked,
}) async {
  try {
    var granted = false;
    try {
      granted = await check();
    } catch (e) {
      debugPrint('[health] weight permission check (unknown): $e');
    }
    if (granted) return true;
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

class _ScaleDevice {
  _ScaleDevice(this.id, this.adapter, this.raw);
  final String id;
  final String adapter;
  final Map<int, num> raw;
}

/// Export every flagged-on scale's pending weighings. Best-effort; never
/// throws. [reset] clears the exported sets (re-sends everything,
/// idempotently). [permitted] is consulted lazily, only when something is
/// pending. [syncEnabled] / [isEnabled] are re-checked before every weighing
/// (opt-out mid-drain). [weightGranted] (null = unknown) feeds the grant
/// transition that clears the attempt caps. The loaders default to [LocalDb];
/// tests inject their own.
Future<int> exportScaleWeighings({
  required Future<bool> Function(DateTime start, DateTime end) deleteOwn,
  required Future<bool> Function(double kg, DateTime at) write,
  Future<bool> Function()? permitted,
  Future<bool?> Function()? weightGranted,
  Future<bool> Function()? syncEnabled,
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
    final enabledFn = isEnabled ?? wearableEnabled;
    final devices = <_ScaleDevice>[];
    // Scales switched off still have samples in Health: their instants take
    // part in the collision check only, never in an export.
    final disabledScales = <_ScaleDevice>[];
    for (final row in await (loadDevices ?? LocalDb.deviceRows)()) {
      final adapter = row['adapter_id'] as String?;
      final id = row['id'] as String?;
      if (id == null) continue;
      try {
        if (adapter == null ||
            categoryOf(adapter) != DeviceCategory.healthMeasurement) {
          continue;
        }
        if (!await enabledFn(adapter)) {
          disabledScales.add(
            _ScaleDevice(
              id,
              adapter,
              await (loadWeights ??
                  (d) => LocalDb.deviceObservationValues(d, 'weight'))(id),
            ),
          );
          continue;
        }
        // The exported set is kept on reset (a disabled scale keeps its state,
        // and an unsafe resend keeps its mark); only attempts and the old
        // cursor are cleared.
        if (reset) {
          await prefs.remove(healthWeightAttemptsKey(id));
          await (deleteCursor ?? LocalDb.deleteCursor)(
            healthWeightCursorName(id),
          );
        }
        if (forceRetry && !reset) {
          await prefs.remove(healthWeightAttemptsKey(id));
        }
        final raw =
            await (loadWeights ??
                (d) => LocalDb.deviceObservationValues(d, 'weight'))(id);
        devices.add(_ScaleDevice(id, adapter, raw));
      } catch (e) {
        debugPrint('[health] weighings load $id: $e');
      }
    }

    // Every scale's instants: a delete by time range must not take another
    // weighing's sample with it.
    bool deleteSafeFor(String id, int atMs) {
      for (final d in [...devices, ...disabledScales]) {
        for (final ts in d.raw.keys) {
          if (d.id == id && ts == atMs) continue;
          if ((ts - atMs).abs() <= kHealthWeightMatchWindow.inMilliseconds) {
            return false;
          }
        }
      }
      return true;
    }

    var permChecked = false;
    var permOk = true;
    var grantEvaluated = false;
    var grantTransitioned = false;
    // A reset re-sends with delete-then-write; a cap would leave the rest to
    // later plain writes that stack duplicates on the samples still in Health.
    var budget = reset ? 1 << 30 : kMaxWeighingsPerRun;
    var syncOff = false;
    for (final d in devices) {
      if (syncOff || budget <= 0) break;
      try {
        final id = d.id;
        final exported = _decodeSet(
          prefs.getString(healthWeightExportedKey(id)),
        );
        final attempts = _decodeAttempts(
          prefs.getString(healthWeightAttemptsKey(id)),
        );
        final maybeLanded = _decodeSet(
          prefs.getString(healthWeightMaybeLandedKey(id)),
        );
        final trimmed = _decodeSet(
          prefs.getString(healthWeightTrimmedKey(id)),
        );
        var persistedTrimmed = {...trimmed};
        Future<void> save() async {
          // What the bound drops from the exported set is remembered, so an
          // old exported weighing is not sent again as if it were new.
          final keep = _bounded(exported).toSet();
          final evicted = exported.difference(keep);
          if (evicted.isNotEmpty) {
            trimmed.addAll(evicted);
            exported.removeAll(evicted);
          }
          // Also when a removal changed it (a reset deleted a trimmed sample
          // and its replacement failed): a stale mark would read as exported.
          if (trimmed.length != persistedTrimmed.length ||
              !trimmed.containsAll(persistedTrimmed)) {
            persistedTrimmed = {...trimmed};
            await prefs.setString(
              healthWeightTrimmedKey(id),
              jsonEncode(_bounded(trimmed, kMaxTrimmedWeighings)),
            );
          }
          await prefs.setString(
            healthWeightMaybeLandedKey(id),
            jsonEncode(_bounded(maybeLanded)),
          );
          await prefs.setString(
            healthWeightExportedKey(id),
            jsonEncode(_bounded(exported)),
          );
          await prefs.setString(
            healthWeightAttemptsKey(id),
            jsonEncode({for (final e in attempts.entries) '${e.key}': e.value}),
          );
        }

        // Attempt entries for weighings that no longer exist are dead weight.
        final before = attempts.length;
        attempts.removeWhere((ts, _) => !d.raw.containsKey(ts));
        var attemptsDirty = attempts.length != before;
        // Not-granted/unknown -> granted: capped weighings get a fresh chance.
        if (attempts.isNotEmpty && weightGranted != null) {
          if (!grantEvaluated) {
            grantEvaluated = true;
            final now = await weightGranted() == true;
            final seen = prefs.getBool(kHealthWeightGrantSeenPref) == true;
            grantTransitioned = now && !seen;
            if (now != seen) {
              await prefs.setBool(kHealthWeightGrantSeenPref, now);
            }
          }
          if (grantTransitioned) {
            attempts.clear();
            attemptsDirty = true;
          }
        }
        if (attemptsDirty) await save();

        // Exported history that aged out of the bounded set is in [trimmed],
        // so a never-exported older weighing (backfill) is still pending.
        final pending = [
          for (final w in exportableWeighings(
            d.raw,
            exported: reset ? const {} : {...exported, ...trimmed},
          ))
            if ((attempts[w.atMs] ?? 0) < kMaxWeightAttempts) w,
        ].take(budget).toList();
        if (pending.isEmpty) continue;
        budget -= pending.length;
        if (!permChecked) {
          permChecked = true;
          permOk = permitted == null || await permitted();
        }
        if (!permOk) continue;
        total += await writeWeighings(
          weighings: pending,
          exported: exported,
          attempts: attempts,
          save: save,
          deleteOwn: deleteOwn,
          write: write,
          stopped: stopped,
          resend: reset,
          deleteSafe: (ts) => deleteSafeFor(id, ts),
          maybeLanded: maybeLanded,
          trimmed: trimmed,
          mayContinue: () async {
            if (syncEnabled != null && !await syncEnabled()) {
              syncOff = true;
              return false;
            }
            return await enabledFn(d.adapter);
          },
        );
      } catch (e) {
        debugPrint('[health] weighings export ${d.id}: $e');
      }
    }
  } catch (e) {
    debugPrint('[health] exportScaleWeighings: $e');
  }
  return total;
}
