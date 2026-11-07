// health_nap_export.dart — write a user-confirmed nap to Apple Health
// (HealthKit) on iOS.
//
// HealthKit has NO nap category: the only sleep type is
// HKCategoryTypeIdentifier.sleepAnalysis, and HKCategoryValueSleepAnalysis
// offers exactly inBed / awake / asleepCore / asleepDeep / asleepREM /
// asleepUnspecified (plus the deprecated asleep). There is no value and no
// metadata key the Health app renders as "nap". So a nap is exported as an
// inBed envelope plus one asleepUnspecified sample over the confirmed window
// — it shows up in Apple Health as an ordinary (daytime) sleep segment and
// counts toward Time Asleep there; it is NOT labelled as a nap.
//
// Naps carry no hypnogram (the detector yields a window only), so no stage
// samples are written — fabricating asleepCore/Deep/REM would violate the
// app's never-fabricate rule.
//
// Only rows with source 'confirmed' or 'manual' are ever exported; 'pending'
// detections and 'rejected' windows are not. The window is re-validated at
// export time (bounds, not in the future, and NOT overlapping the derived
// main sleep of the surrounding nights — the same check the confirm path
// enforces, repeated here so a stale row or a shifted night can never push
// night-sleep minutes into Health as a nap).
//
// Idempotency: the native writer deletes THIS APP's own sleepAnalysis samples
// overlapping the nap window before writing, so repeated exports never
// duplicate. Removing/rejecting a nap in Edge deletes the same window.
//
// iOS only for now — Health Connect (Android) has no nap export yet; on
// Android every method returns false and writes nothing. Nothing here throws:
// a missing store, a denied permission or a failed write reads as false.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/nap_edits.dart' show manualNapWindowIsValid;
import '../data/activity_store.dart';
import '../data/db.dart';
import 'health_export.dart' show HealthExporter, kHealthSyncPref;

/// Native side: `HealthKitSleepWriter` on the existing sleep channel.
abstract interface class HealthKitNapWriter {
  /// Delete our own sleepAnalysis samples overlapping [start, end), then write
  /// one inBed + one asleepUnspecified sample over [start, end).
  Future<bool> replaceNap({required DateTime start, required DateTime end});

  /// Delete our own sleepAnalysis samples overlapping [start, end).
  Future<bool> deleteRange({required DateTime start, required DateTime end});
}

class MethodChannelHealthKitNapWriter implements HealthKitNapWriter {
  MethodChannelHealthKitNapWriter({
    this.channel = const MethodChannel('openstrap/healthkit_sleep'),
  });

  final MethodChannel channel;
  Future<void> _pending = Future<void>.value();
  // Monotonic per-call sequence. A native call that outlives its 30 s timeout
  // can still land later; the native side drops nap calls whose seq is not
  // newer than the last one it applied, so a late replaceNap can never
  // overwrite a newer deleteNapRange for the same window.
  int _seq = 0;

  @override
  Future<bool> replaceNap({required DateTime start, required DateTime end}) =>
      _invoke('replaceNap', {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
        'seq': ++_seq,
      });

  @override
  Future<bool> deleteRange({required DateTime start, required DateTime end}) =>
      _invoke('deleteNapRange', {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
        'seq': ++_seq,
      });

  Future<bool> _invoke(String method, Map<String, Object?> args) {
    final result = Completer<bool>();
    _pending = _pending.then((_) async {
      try {
        // FINITE timeout, same as the sleep-session writer: a native handler
        // that never calls back must not leave this future pending forever.
        result.complete(
          await channel
                  .invokeMethod<bool>(method, args)
                  .timeout(const Duration(seconds: 30)) ==
              true,
        );
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// Whether a `sleep_nap` row may be exported: only a confirmed or manually
/// logged nap inside the 5 min – 6 h window that has already ended.
@visibleForTesting
bool napWindowExportable({
  required String? source,
  required int startTs,
  required int endTs,
  required int nowSec,
}) {
  if (source != 'confirmed' && source != 'manual') return false;
  if (!manualNapWindowIsValid(startTs, endTs)) return false;
  return endTs <= nowSec;
}

/// Whether [startTs, endTs) overlaps a main-sleep window given in epoch ms.
@visibleForTesting
bool napOverlapsWindowMs(int startTs, int endTs, num? onsetMs, num? offsetMs) {
  if (onsetMs == null || offsetMs == null) return false;
  return startTs * 1000 < offsetMs && endTs * 1000 > onsetMs;
}

/// Zone key marking "inside [HealthNapExporter.synchronized]" — makes the
/// nap lock reentrant so a call site can wrap a DB edit and a health call in
/// one critical section without deadlocking on the inner health call.
const _napHealthLockKey = #healthNapHealthLock;

class HealthNapExporter {
  HealthNapExporter({
    HealthKitNapWriter? writer,
    bool? isApple,
    Future<bool> Function()? healthSyncEnabled,
    Future<Map<String, dynamic>?> Function(String dayId, int startTs)? napRow,
    Future<List<Map<String, dynamic>>> Function(String dayId)? dayNapRows,
    Future<bool> Function(int startTs, int endTs)? overlapsMainSleep,
  }) : _writer = writer ?? MethodChannelHealthKitNapWriter(),
       isApple = isApple ?? HealthExporter.isApple,
       _healthSyncEnabled =
           healthSyncEnabled ?? _defaultHealthSyncEnabled,
       _napRow = napRow ?? _defaultNapRow,
       _dayNapRows = dayNapRows ?? LocalDb.napEdits,
       _overlapsMainSleep =
           overlapsMainSleep ?? _defaultOverlapsMainSleep;

  final HealthKitNapWriter _writer;
  final bool isApple;
  final Future<bool> Function() _healthSyncEnabled;
  final Future<Map<String, dynamic>?> Function(String dayId, int startTs)
      _napRow;
  final Future<List<Map<String, dynamic>>> Function(String dayId) _dayNapRows;
  final Future<bool> Function(int startTs, int endTs) _overlapsMainSleep;

  /// Process-wide exporter; call sites use the static wrappers below.
  static final HealthNapExporter shared = HealthNapExporter();

  Future<void> _lockTail = Future<void>.value();

  /// Serializes nap DB edits + Health writes against [exportDayNaps]'s
  /// read-and-write pass. Without this, a remove/reject that lands while a
  /// daily export has already read the row (but not yet written) lets the
  /// export write the just-removed nap back into HealthKit after the
  /// delete. With the lock, either order is safe: the export re-reads the
  /// rows inside the critical section, so a row deleted first is skipped.
  /// Reentrant via [_napHealthLockKey]; leaf lock — never acquires another
  /// lock while held, so it cannot deadlock against exportAll's workout lock.
  Future<T> synchronized<T>(Future<T> Function() op) {
    if (Zone.current[_napHealthLockKey] == true) return op();
    final prev = _lockTail;
    final release = Completer<void>();
    _lockTail = release.future;
    return prev
        .then((_) => runZoned(op, zoneValues: {_napHealthLockKey: true}))
        .whenComplete(release.complete);
  }

  /// Export the nap stored at ([dayId], [startTs]) — its [endTs] is read from
  /// the row. Used after "put back" restores a rejected nap to 'confirmed'.
  /// Never throws; false when nothing was written.
  static Future<bool> exportNapRow({
    required String dayId,
    required int startTs,
  }) async {
    final row = await shared._napRow(dayId, startTs);
    final endTs = row?['end_ts'];
    if (endTs is! num) return false;
    return shared.exportNap(
      dayId: dayId,
      startTs: startTs,
      endTs: endTs.toInt(),
    );
  }

  /// Export a confirmed/manual nap window to Apple Health. Re-reads the row
  /// and re-checks the main-sleep overlap at export time. Never throws;
  /// false when nothing was written (switch off, Android, not confirmed,
  /// overlap, store error).
  static Future<bool> exportConfirmedNap({
    required String dayId,
    required int startTs,
    required int endTs,
  }) => shared.exportNap(dayId: dayId, startTs: startTs, endTs: endTs);

  /// Remove a previously exported nap window from Apple Health (the nap was
  /// deleted or rejected in Edge). Never throws; false when nothing was
  /// deleted.
  static Future<bool> deleteExportedNap({
    required int startTs,
    required int endTs,
  }) => shared.deleteNapWindow(startTs: startTs, endTs: endTs);

  Future<bool> exportNap({
    required String dayId,
    required int startTs,
    required int endTs,
  }) => synchronized(() async {
    try {
      // Health Connect has no nap export yet; never claim one happened.
      if (!isApple) return false;
      if (!await _healthSyncEnabled()) return false;
      final row = await _napRow(dayId, startTs);
      final source = row?['source'];
      // The stored row is the source of truth: a caller passing a stale
      // endTs (e.g. before an edit landed) must not export a window the row
      // no longer holds.
      final storedEnd = row?['end_ts'];
      if (storedEnd is! num || storedEnd.toInt() != endTs) return false;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (!napWindowExportable(
        source: source is String ? source : null,
        startTs: startTs,
        endTs: endTs,
        nowSec: nowSec,
      )) {
        return false;
      }
      // Defense in depth: the confirm/log paths already refuse windows that
      // overlap the main sleep, but re-check here so a stale row or a night
      // that moved since can never be written as a nap.
      if (await _overlapsMainSleep(startTs, endTs)) return false;
      return await _writer.replaceNap(
        start: DateTime.fromMillisecondsSinceEpoch(startTs * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(endTs * 1000),
      );
    } catch (e) {
      debugPrint('[health] exportNap $dayId $startTs-$endTs: $e');
      return false;
    }
  });

  /// Export every exportable nap of [dayId]. Called from the per-day health
  /// export AFTER the main-sleep replace: that replace's noon-to-noon
  /// cleanup window also covers the wake day's afternoon, so it deletes OUR
  /// nap samples there — re-writing them on every pass keeps them in the
  /// store. Rows that are not exportable (pending/rejected/legacy, overlap
  /// with main sleep) are skipped silently; false means an attempted write
  /// failed. On Android or with the sync switch off this is a no-op `true`.
  Future<bool> exportDayNaps(String dayId) => synchronized(() async {
    try {
      if (!isApple) return true;
      if (!await _healthSyncEnabled()) return true;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var ok = true;
      for (final row in await _dayNapRows(dayId)) {
        final startTs = row['start_ts'];
        final endTs = row['end_ts'];
        final source = row['source'];
        if (startTs is! num || endTs is! num) continue;
        final s = startTs.toInt(), e = endTs.toInt();
        if (!napWindowExportable(
          source: source is String ? source : null,
          startTs: s,
          endTs: e,
          nowSec: nowSec,
        )) {
          continue;
        }
        // Per-row isolation: one throwing row (overlap lookup, store error)
        // must not skip the remaining naps — the main-sleep replace above
        // may already have deleted their Health samples, and a day that
        // gives up retries would leave them missing.
        try {
          if (await _overlapsMainSleep(s, e)) continue;
          final written = await _writer.replaceNap(
            start: DateTime.fromMillisecondsSinceEpoch(s * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(e * 1000),
          );
          if (!written) ok = false;
        } catch (rowError) {
          debugPrint('[health] exportDayNaps $dayId row $s-$e: $rowError');
          ok = false;
        }
      }
      return ok;
    } catch (e) {
      debugPrint('[health] exportDayNaps $dayId: $e');
      return false;
    }
  });

  Future<bool> deleteNapWindow({
    required int startTs,
    required int endTs,
  }) => synchronized(() async {
    try {
      if (!isApple) return false;
      if (!await _healthSyncEnabled()) return false;
      if (endTs <= startTs) return false;
      return await _writer.deleteRange(
        start: DateTime.fromMillisecondsSinceEpoch(startTs * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(endTs * 1000),
      );
    } catch (e) {
      debugPrint('[health] deleteNapWindow $startTs-$endTs: $e');
      return false;
    }
  });

  static Future<bool> _defaultHealthSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kHealthSyncPref) == true;
  }

  static Future<Map<String, dynamic>?> _defaultNapRow(
    String dayId,
    int startTs,
  ) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'sleep_nap',
      where: 'day_id = ? AND start_ts = ?',
      whereArgs: [dayId, startTs],
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<bool> _defaultOverlapsMainSleep(int startTs, int endTs) async =>
      ActivityStore.overlapsMainSleep(await LocalDb.instance, startTs, endTs);
}
