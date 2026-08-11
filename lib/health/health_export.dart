// health_export.dart — write each day's derived metrics to the platform health
// store: Apple Health (HealthKit) on iOS, Google Health Connect on Android.
//
// Honesty rule (same as the rest of the app): only export what the band/our
// pipeline measures or derives for real — sleep stages, resting HR, HRV
// (SDNN on iOS / RMSSD on Android), respiratory rate, active energy, workouts.
// NOT the proprietary scores (recovery/strain/readiness) or relative-only signals
// (SpO₂ / skin-temp) — no native type, would be fabricated.
//
// Continuous + idempotent: a day is exported AS SOON AS it's derived (no waiting
// for finalization). Because a recent day can re-derive, every export DELETES our
// prior samples for that day's window before writing fresh ones — so re-running
// never duplicates. Days in the contiguous FINALIZED prefix are immutable, so once
// exported they're skipped (tracked by the `health_export_through` cursor); the
// recent tail is re-written each pass until it finalizes.
//
// Nothing here throws — a missing/locked health store yields a HealthLinkState or
// a 0 count, never an exception.

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import '../data/db.dart';
import '../data/series_codec.dart';
import 'health_heart_rate_batch.dart';
import 'health_sleep_session.dart';

/// What we can do with the health store right now.
enum HealthLinkState {
  unknown,
  ready, // permission granted, can write
  needsPermission, // store available, user hasn't granted write access
  notInstalled, // Android: Health Connect not installed
  needsUpdate, // Android: Health Connect needs a Play update
  unsupported, // no health store on this device (iPad / simulator)
}

const _sleepHealthTypes = <HealthDataType>{
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_REM,
  HealthDataType.SLEEP_LIGHT,
  HealthDataType.SLEEP_AWAKE,
  HealthDataType.SLEEP_SESSION,
};

List<HealthDataType> healthDeleteTypes({required bool isApplePlatform}) {
  final types = <HealthDataType>[
    HealthDataType.RESTING_HEART_RATE,
    isApplePlatform
        ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
        : HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.HEART_RATE,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.BASAL_ENERGY_BURNED,
    HealthDataType.STEPS,
    ..._sleepHealthTypes,
    HealthDataType.WORKOUT,
  ];
  return isApplePlatform
      ? types
      : types
            .where(
              (type) =>
                  !_sleepHealthTypes.contains(type) &&
                  type != HealthDataType.HEART_RATE,
            )
            .toList();
}

bool shouldAttemptHealthExport({
  required int attempts,
  required int maxAttempts,
  required DateTime now,
  required DateTime? lastAttempt,
  required Duration backoff,
  bool force = false,
}) {
  if (force) return true;
  if (attempts >= maxAttempts) return false;
  return lastAttempt == null || now.difference(lastAttempt) >= backoff;
}

bool shouldAttemptHealthBulkExport({
  required int attempts,
  required int maxAttempts,
  required DateTime now,
  required DateTime? lastAttempt,
  required Duration backoff,
  required bool prioritySleepAlreadyWritten,
  bool force = false,
}) => shouldAttemptHealthExport(
  attempts: attempts,
  maxAttempts: maxAttempts,
  now: now,
  lastAttempt: lastAttempt,
  backoff: backoff,
  force: force || prioritySleepAlreadyWritten,
);

class PrioritySleepExportResult {
  const PrioritySleepExportResult({
    required this.date,
    required this.succeeded,
  });

  final String? date;
  final bool succeeded;
}

Future<PrioritySleepExportResult> exportNewestPrioritySleep({
  required Iterable<MapEntry<String, Map<String, dynamic>>> newestFirstDays,
  required Future<bool> Function(Map<String, dynamic>) write,
}) async {
  for (final day in newestFirstDays) {
    if (normalizeHealthSleepSession(day.value) == null) continue;
    return PrioritySleepExportResult(
      date: day.key,
      succeeded: await write(day.value),
    );
  }
  return const PrioritySleepExportResult(date: null, succeeded: true);
}

Future<PrioritySleepExportResult> exportPrioritySleepBeforeBulk({
  required Iterable<MapEntry<String, Map<String, dynamic>>> newestFirstDays,
  required Future<bool> Function(Map<String, dynamic>) write,
  required Future<void> Function(String? androidSleepAlreadyWritten) exportBulk,
}) async {
  final priorityResult = await exportNewestPrioritySleep(
    newestFirstDays: newestFirstDays,
    write: write,
  );
  if (!priorityResult.succeeded) return priorityResult;
  await exportBulk(priorityResult.date);
  return priorityResult;
}

class HealthExportSingleFlight {
  Future<int>? _inFlight;

  Future<int> run(Future<int> Function() export) {
    final current = _inFlight;
    if (current != null) return current;

    late final Future<int> operation;
    operation = Future<int>.sync(export).whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }
}

class HealthExporter {
  final _health = Health();
  final _androidSleep = HealthConnectSleepSessionExporter(
    writer: MethodChannelHealthConnectSleepSessionWriter(),
  );
  final HealthConnectHeartRateWriter _androidHeartRate;
  bool _configured = false;

  HealthExporter({HealthConnectHeartRateWriter? androidHeartRate})
    : _androidHeartRate =
          androidHeartRate ?? MethodChannelHealthConnectHeartRateWriter();

  /// True on iOS/macOS (Apple Health); false on Android (Health Connect).
  static bool get isApple => Platform.isIOS || Platform.isMacOS;

  /// Display name of the platform health store.
  static String get storeName => isApple ? 'Apple Health' : 'Health Connect';

  /// HealthKit only stores SDNN; Health Connect stores RMSSD — write whichever
  /// the platform supports (both are real, from cleaned RR).
  HealthDataType get _hrvType => isApple
      ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
      : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;

  /// The metric scalar feeding the HRV type (sdnn on iOS, rmssd on Android).
  String get _hrvScalarKey => isApple ? 'sdnn' : 'rmssd';

  List<HealthDataType> get _types => [
        HealthDataType.RESTING_HEART_RATE,
        _hrvType,
        HealthDataType.RESPIRATORY_RATE,
        HealthDataType.HEART_RATE,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.BASAL_ENERGY_BURNED,
        // STEPS is requested for DELETE SCOPE ONLY — nothing writes steps any
        // more (see the block further down for why). We still need the write
        // permission to purge the fabricated step samples earlier versions put
        // into Apple Health / Health Connect, which is why WRITE_STEPS stays in
        // the Android manifest. That purge is a ONE-SHOT migration and does not
        // belong in the per-day rewrite loop — see [_purgeLegacyStepsIfNeeded]
        // and [_rewriteTypes].
        HealthDataType.STEPS,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_SESSION,
        HealthDataType.WORKOUT,
      ];

  /// The types the per-day delete-then-write pass touches.
  ///
  /// STEPS is deliberately excluded. It is in [_types] only so `request()` asks
  /// for the scope the legacy purge needs; including it here would run a delete
  /// for a type nothing writes on every re-export of the recent (not-yet-
  /// finalized) tail, forever, and would let that delete's failure flip a day's
  /// export to unsuccessful.
  /// Composes both intents on this seam:
  ///   * `healthDeleteTypes` (platform-aware) drops the sleep types and
  ///     HEART_RATE on Android, because the native SleepSessionRecord writer
  ///     and the minute-HR batch own their own cleanup there.
  ///   * STEPS is then removed on top, because NOTHING writes steps any more.
  ///     Deleting a type we never write would run on every re-export of the
  ///     not-yet-finalized tail forever, and — since a false `delete()` flips
  ///     `success` — could permanently stall a day's export cursor. The
  ///     historical fabricated samples are handled once by
  ///     [_purgeLegacyStepsIfNeeded] instead, outside the success accounting.
  List<HealthDataType> get _rewriteTypes => [
        for (final t in healthDeleteTypes(isApplePlatform: isApple))
          if (t != HealthDataType.STEPS) t,
      ];

  /// Cursor for the one-shot legacy-STEPS purge: the newest day already purged.
  static const _kStepsPurgeCursor = 'health_steps_purged_through';
  String? _stepsPurgedThrough;

  /// Delete the fabricated STEPS samples earlier versions wrote for [date].
  ///
  /// ONE-SHOT, and deliberately not part of the day's success accounting: this
  /// is a migration cleaning up data we should never have written, not part of
  /// exporting the day. A failure here must not stall the export cursor for a
  /// type nothing writes. Days are walked ascending, so the cursor advances
  /// monotonically and a re-exported tail day is not re-purged.
  Future<void> _purgeLegacyStepsIfNeeded(
    String date,
    DateTime dayStart,
    DateTime dayEnd,
  ) async {
    _stepsPurgedThrough ??= await LocalDb.getCursor(_kStepsPurgeCursor) ?? '';
    final through = _stepsPurgedThrough!;
    if (through.isNotEmpty && date.compareTo(through) <= 0) return;
    try {
      await _health.delete(
        type: HealthDataType.STEPS,
        startTime: dayStart,
        endTime: dayEnd,
      );
      _stepsPurgedThrough = date;
      await LocalDb.setCursor(_kStepsPurgeCursor, date);
    } catch (e) {
      // Leave the cursor where it is so the next pass retries this day.
      debugPrint('[health] purge legacy steps $date: $e');
    }
  }

  // We do NOT gate on a write-permission check: HealthKit hides write-auth by
  // design, and Health Connect's hasPermissions(WRITE) frequently returns
  // null/false even after the user grants everything — which would leave the UI
  // stuck on "Grant access" forever. Instead we ATTEMPT every write and let the
  // platform enforce (ungranted writes silently no-op). The only hard gate is
  // store AVAILABILITY (Health Connect installed/updated on Android).

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    try {
      await _health.configure();
      _configured = true;
    } catch (e) {
      debugPrint('[health] configure: $e');
    }
  }

  Future<HealthLinkState?> _androidUnavailable() async {
    if (!Platform.isAndroid) return null;
    try {
      final s = await _health.getHealthConnectSdkStatus();
      if (s == HealthConnectSdkStatus.sdkUnavailable) {
        return HealthLinkState.notInstalled;
      }
      if (s == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired) {
        return HealthLinkState.needsUpdate;
      }
    } catch (e) {
      debugPrint('[health] sdkStatus: $e');
    }
    return null;
  }

  /// Store availability (no permission prompt). `ready` = installed/updated &
  /// writable-in-principle; we can't reliably know the per-type grant, so the
  /// app attempts writes regardless. Never throws.
  Future<HealthLinkState> check() async {
    await _ensureConfigured();
    try {
      return await _androidUnavailable() ?? HealthLinkState.ready;
    } catch (e) {
      debugPrint('[health] check: $e');
      return HealthLinkState.unsupported;
    }
  }

  /// Open the system grant flow (HealthKit sheet / Health Connect permission UI).
  /// Call from a user gesture. Returns availability; we never block on the
  /// (unreliable) post-grant permission read.
  Future<HealthLinkState> request() async {
    await _ensureConfigured();
    final un = await _androidUnavailable();
    if (un != null) return un;
    try {
      await _health.requestAuthorization(
        _types,
        permissions: _types.map((_) => HealthDataAccess.WRITE).toList(),
      );
    } catch (e) {
      debugPrint('[health] requestAuthorization: $e');
    }
    return HealthLinkState.ready;
  }

  /// Send the user to the Play Store to install Health Connect (Android only).
  Future<void> install() async {
    if (!Platform.isAndroid) return;
    try {
      await _health.installHealthConnect();
    } catch (e) {
      debugPrint('[health] installHealthConnect: $e');
    }
  }

  /// Open the Health Connect app / settings so the user can enable OpenStrap's
  /// access manually — the reliable path when the in-app request dialog is locked
  /// out. Android-only. API 34+ folds HC into system settings; older uses the HC
  /// app, so try the modern action first then fall back.
  Future<void> openSettings() async {
    if (!Platform.isAndroid) return;
    for (final action in const [
      'android.health.connect.action.HEALTH_HOME_SETTINGS',
      'androidx.health.ACTION_HEALTH_CONNECT_SETTINGS',
    ]) {
      try {
        await AndroidIntent(action: action).launch();
        return;
      } catch (e) {
        debugPrint('[health] open settings ($action): $e');
      }
    }
  }

  // ── export ────────────────────────────────────────────────────────────────

  /// Export every day not in the immutable finalized prefix — including TODAY and
  /// other not-yet-finalized days — DELETING our prior samples for each first so a
  /// re-derive never duplicates. The cursor (`health_export_through`) advances only
  /// over the contiguous finalized-and-exported prefix; the recent tail is
  /// re-written on each call. [reset] re-exports the whole retained window.
  /// Returns the number of days written. Never throws.
  // Per-day export retry state, keyed by date, persisted as JSON in the same
  // sync_cursor key-value table exportAll() already uses for its cursor (no
  // schema migration needed): {date: {attempts, last_ms}}.
  //
  // Design rationale (why bounded retry-with-backoff, not indefinite block):
  // exportAll() runs on EVERY drain/derive pass (light + heavy — see
  // AppState), so a naive "retry every call until it succeeds" would hammer
  // HealthKit/Health Connect many times an hour. And blocking the cursor
  // indefinitely on one bad day would freeze every later day's export too,
  // forever, over one persistently-failing write. This codebase already has
  // precedent against indefinite blocking for exactly this class of problem:
  // derivation_engine.dart marks a pathological day with a skip marker
  // "so it isn't retried forever" and caps per-day compute so "the sweep
  // always makes progress"; the BLE layer's BondRefusalGiveUp does the same
  // (give up after N refusals rather than retry forever). We follow that
  // convention: back off with growing spacing, and after _kMaxExportAttempts
  // give up on that specific day (log it, let the cursor advance past it)
  // rather than wedge the pipeline. Note this only matters for genuine
  // thrown errors or false results from the health-store APIs. A returned
  // false is not success and must keep the day out of the exported prefix.
  static const _kRetryCursor = 'health_export_retry_state';
  static const _kMaxExportAttempts = 6;
  static const _kRetryBackoff = [
    Duration(minutes: 5),
    Duration(minutes: 30),
    Duration(hours: 2),
    Duration(hours: 6),
    Duration(hours: 24),
  ];
  // Entries start at attempts==1 (recorded right after the first failure), so
  // index by attempts-1: the first failure gets the first (shortest) tier.
  Duration _backoffFor(int attempts) =>
      _kRetryBackoff[(attempts - 1).clamp(0, _kRetryBackoff.length - 1)];

  Future<Map<String, dynamic>> _loadRetryState() async {
    final raw = await LocalDb.getCursor(_kRetryCursor);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<int> exportAll({
    bool reset = false,
    bool forceRetry = false,
    void Function(int days)? onProgress,
  }) async {
    await _ensureConfigured();
    if (await _androidUnavailable() != null) return 0; // HC missing/outdated
    try {
      if (reset) {
        await LocalDb.setCursor('health_export_through', '');
        await LocalDb.setCursor(_kRetryCursor, '');
      }
      final cursor = await LocalDb.getCursor('health_export_through') ?? '';
      final retryState = await _loadRetryState();
      var retryStateDirty = false;
      final rows = await LocalDb.recentDayResults(400); // newest-first
      final pendingDays =
          <({String date, bool finalized, Map<String, dynamic>? bundle})>[];
      for (final row in rows) {
        final date = (row['day_id'] ?? row['date'])?.toString();
        if (date == null || date.isEmpty) continue;
        if (cursor.isNotEmpty && date.compareTo(cursor) <= 0) continue;
        pendingDays.add((
          date: date,
          finalized: (row['finalized'] as num?)?.toInt() == 1,
          bundle: _decode(row['payload_json']),
        ));
      }

      late final Future<int> Function(String? androidSleepAlreadyWritten)
      exportBulk;
      Future<int> exportPriorityOrBulk() async {
        if (Platform.isAndroid) {
          final priorityDays = pendingDays
              .where(
                (day) => day.bundle != null && day.bundle!['skipped'] != true,
              )
              .map((day) => MapEntry(day.date, day.bundle!))
              .toList();
          MapEntry<String, Map<String, dynamic>>? priorityDay;
          for (final day in priorityDays) {
            if (normalizeHealthSleepSession(day.value) != null) {
              priorityDay = day;
              break;
            }
          }
          if (priorityDay != null) {
            final pendingPriorityDay = pendingDays.firstWhere(
              (pending) => pending.date == priorityDay!.key,
            );
            final entry = (retryState[priorityDay.key] as Map?)
                ?.cast<String, dynamic>();
            var attempts = (entry?['attempts'] as num?)?.toInt() ?? 0;
            var lastAttemptMs = (entry?['last_ms'] as num?)?.toInt();
            final wasFinalized = entry?['finalized'] as bool? ?? false;
            if (pendingPriorityDay.finalized && !wasFinalized && attempts > 0) {
              attempts = 0;
              lastAttemptMs = null;
            }
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final shouldAttempt = shouldAttemptHealthExport(
              attempts: attempts,
              maxAttempts: _kMaxExportAttempts,
              now: DateTime.fromMillisecondsSinceEpoch(nowMs),
              lastAttempt: lastAttemptMs == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(lastAttemptMs),
              backoff: _backoffFor(attempts),
              force: forceRetry,
            );
            if (!shouldAttempt) {
              if (attempts >= _kMaxExportAttempts) return exportBulk(null);
              return 0;
            }
            Future<void> recordPriorityFailure() async {
              retryState[priorityDay!.key] = {
                'attempts': attempts + 1,
                'last_ms': nowMs,
                'finalized': pendingPriorityDay.finalized,
              };
              await LocalDb.setCursor(_kRetryCursor, jsonEncode(retryState));
            }

            var bulkDone = 0;
            try {
              final priorityResult = await exportPrioritySleepBeforeBulk(
                newestFirstDays: priorityDays,
                write: _androidSleep.replace,
                exportBulk: (androidSleepAlreadyWritten) async {
                  bulkDone = await exportBulk(androidSleepAlreadyWritten);
                },
              );
              if (!priorityResult.succeeded) {
                await recordPriorityFailure();
                return 0;
              }
              return bulkDone;
            } catch (e) {
              debugPrint('[health] write priority Android sleep session: $e');
              await recordPriorityFailure();
              return 0;
            }
          }
        }
        return exportBulk(null);
      }

      exportBulk = (String? androidSleepAlreadyWritten) async {
        var done = 0;
        var newCursor = cursor;
        var prefixContiguous = true; // still extending the finalized prefix?
        for (final day in pendingDays.reversed) {
          final date = day.date;
          final finalized = day.finalized;
          final bundle = day.bundle;
          if (bundle == null || bundle['skipped'] == true) {
            if (!finalized) prefixContiguous = false;
            continue;
          }

          final entry = (retryState[date] as Map?)?.cast<String, dynamic>();
          var attempts = (entry?['attempts'] as num?)?.toInt() ?? 0;
          var lastAttemptMs = (entry?['last_ms'] as num?)?.toInt();
          final wasFinalized = entry?['finalized'] as bool? ?? false;
          if (finalized && !wasFinalized && attempts > 0) {
            // The day just transitioned non-finalized -> finalized: a
            // materially different (complete, now-immutable) payload than
            // whatever was still re-deriving during the "recent tail" attempts
            // that accrued this cap/backoff. Give it a clean attempt budget so
            // a newly-finalized day is never skipped because of a cap earned
            // against the old mutable version.
            attempts = 0;
            lastAttemptMs = null;
          }
          final nowMs = DateTime.now().millisecondsSinceEpoch;

          var ok = false;
          var giveUp = false;
          final shouldAttempt = shouldAttemptHealthBulkExport(
            attempts: attempts,
            maxAttempts: _kMaxExportAttempts,
            now: DateTime.fromMillisecondsSinceEpoch(nowMs),
            lastAttempt: lastAttemptMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(lastAttemptMs),
            backoff: _backoffFor(attempts),
            prioritySleepAlreadyWritten: date == androidSleepAlreadyWritten,
            force: forceRetry,
          );
          if (!shouldAttempt && attempts >= _kMaxExportAttempts) {
            giveUp = true;
          } else if (!shouldAttempt) {
            // Not due for retry yet — don't hammer the health store on every
            // drain/derive pass; counts as "not done" for the cursor below.
          } else {
            ok = await _exportDay(
              date,
              bundle,
              androidSleepAlreadyWritten: date == androidSleepAlreadyWritten,
            ); // delete-then-write (idempotent)
            if (ok) {
              if (entry != null) {
                retryState.remove(date);
                retryStateDirty = true;
              }
            } else {
              final nextAttempts = attempts + 1;
              retryState[date] = {
                'attempts': nextAttempts,
                'last_ms': nowMs,
                'finalized': finalized,
              };
              retryStateDirty = true;
              debugPrint(
                '[health] day $date export incomplete (attempt $nextAttempts/$_kMaxExportAttempts)',
              );
              if (nextAttempts >= _kMaxExportAttempts) {
                debugPrint(
                  '[health] day $date exceeded $_kMaxExportAttempts export attempts — giving up, will stop blocking newer days',
                );
              }
            }
          }

          if (ok) {
            done++;
            onProgress?.call(done);
          }
          // Advance the cursor only while the finalized prefix stays unbroken —
          // a non-finalized day, a still-backing-off retry, or a day still
          // under the attempt cap all stop it (re-checked next pass); a
          // given-up day counts alongside a genuine success so it can't wedge
          // every later day's cursor forever.
          if (prefixContiguous && finalized && (ok || giveUp)) {
            newCursor = date;
          } else {
            prefixContiguous = false;
          }
        }
        if (newCursor != cursor) {
          await LocalDb.setCursor('health_export_through', newCursor);
        }
        if (retryStateDirty) {
          await LocalDb.setCursor(_kRetryCursor, jsonEncode(retryState));
        }
        debugPrint(
          '[health] exported $done day(s); finalized-cursor=$newCursor',
        );
        return done;
      };

      return exportPriorityOrBulk();
    } catch (e) {
      debugPrint('[health] exportAll: $e');
      return 0;
    }
  }

  /// Write one day's metrics. DELETES our prior samples for the day window first
  /// (so a re-derive overwrites instead of duplicating). Best-effort; never throws.
  Future<bool> _exportDay(
    String date,
    Map<String, dynamic> b, {
    bool androidSleepAlreadyWritten = false,
  }) async {
    final dayStart = _localMidnight(date);
    if (dayStart == null) return false;
    // DST-safe next local midnight (calendar-field construction, NOT +24h of
    // absolute Duration — the latter overshoots/undershoots by an hour on the
    // two DST-transition days/year, spilling hourly buckets into the wrong day).
    final dayEnd = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);

    // Aggregate success across every write below: a day is only "exported" if
    // everything we attempted actually landed. Any per-write/per-query failure
    // flips this to false so exportAll()'s cursor won't mark the day done —
    // see the retry/backoff logic there. We still attempt every remaining
    // write on failure (best-effort, idempotent re-export corrects it later).
    var success = true;

    // Sleep is the smallest, highest-value Android write. Do it before the
    // high-volume minute-HR export can consume Health Connect's API quota.
    // The native replace owns SleepSessionRecord cleanup on Android.
    if (Platform.isAndroid && !androidSleepAlreadyWritten) {
      try {
        if (!await _androidSleep.replace(b)) {
          debugPrint('[health] write Android sleep session returned false');
          success = false;
        }
      } catch (e) {
        debugPrint('[health] write Android sleep session: $e');
        success = false;
      }
    }

    // One-shot cleanup of the fabricated step samples earlier versions wrote.
    // Outside the success accounting on purpose — see the method doc.
    await _purgeLegacyStepsIfNeeded(date, dayStart, dayEnd);

    // Idempotency: remove OUR previously-written samples for this day (HealthKit /
    // Health Connect only let an app delete its own data), then re-write fresh.
    for (final t in _rewriteTypes) {
      try {
        final deleted = await _health.delete(
          type: t,
          startTime: dayStart,
          endTime: dayEnd,
        );
        if (!deleted) {
          debugPrint('[health] delete ${t.name} returned false');
          success = false;
        }
      } catch (e) {
        debugPrint('[health] delete ${t.name}: $e');
        success = false;
      }
    }

    final scalars = (b['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    num? sc(String k) => scalars[k] is num ? scalars[k] as num : null;

    // Sleep window → a representative instant for the nightly scalars.
    final win = _sub(b, 'sleep.window.value');
    final onMs = (win?['onset_ms'] as num?)?.toDouble();
    final offMs = (win?['offset_ms'] as num?)?.toDouble();
    final mid = (onMs != null && offMs != null)
        ? DateTime.fromMillisecondsSinceEpoch(((onMs + offMs) / 2).round())
        : dayStart.add(const Duration(hours: 12));

    Future<void> writeAt(
      HealthDataType type,
      num? v,
      HealthDataUnit unit,
      DateTime t,
    ) async {
      if (v == null || v <= 0) return; // absent input, not a failure
      try {
        final wrote = await _health.writeHealthData(
          value: v.toDouble(),
          type: type,
          startTime: t,
          endTime: t,
          unit: unit,
        );
        if (!wrote) {
          debugPrint('[health] write ${type.name} returned false');
          success = false;
        }
      } catch (e) {
        debugPrint('[health] write ${type.name}: $e');
        success = false;
      }
    }

    // Nightly cardiac/respiratory scalars (single sample at the sleep midpoint).
    await writeAt(
      HealthDataType.RESTING_HEART_RATE,
      sc('rhr'),
      HealthDataUnit.BEATS_PER_MINUTE,
      mid,
    );
    await writeAt(_hrvType, sc(_hrvScalarKey), HealthDataUnit.MILLISECOND, mid);
    await writeAt(
      HealthDataType.RESPIRATORY_RATE,
      sc('resp_rate'),
      HealthDataUnit.RESPIRATIONS_PER_MINUTE,
      mid,
    );

    // Hourly buckets spanning [dayStart, dayEnd), shared by the active/basal
    // energy writers below. Each bucket is a real elapsed clock-hour (not
    // 1/24th of the day's span — that would give 57.5min/62.5min "hours" on
    // DST-transition days); the day's actual length (23/24/25 real hours)
    // instead changes bucketCount, with the final bucket clipped to dayEnd so
    // it never spills into the next calendar day.
    final bucketBounds = <DateTime>[dayStart];
    while (bucketBounds.last.isBefore(dayEnd)) {
      final next = bucketBounds.last.add(const Duration(hours: 1));
      bucketBounds.add(next.isAfter(dayEnd) ? dayEnd : next);
    }
    final bucketCount = bucketBounds.length - 1;

    // Active energy: chunked into hourly buckets over the day.
    // We subtract workout calories to prevent double-counting, because workouts
    // are exported separately (their totalEnergyBurned already covers it).
    // Upper bound is exclusive (dayEnd - 1s): sessionsInRange is inclusive on
    // both ends, so a workout starting exactly at midnight would otherwise be
    // double-subtracted from both this day and the next.
    var cal = sc('calories')?.toDouble() ?? 0.0;
    try {
      final rows = await LocalDb.sessionsInRange(
        dayStart.millisecondsSinceEpoch ~/ 1000,
        (dayEnd.millisecondsSinceEpoch ~/ 1000) - 1,
      );
      var workoutCal = 0.0;
      for (final r in rows) {
        if ((r['status']?.toString() ?? '') == 'live') continue;
        workoutCal += (r['calories'] as num?)?.toDouble() ?? 0.0;
      }
      cal = (cal > workoutCal) ? cal - workoutCal : 0.0;
    } catch (e) {
      // Unknown whether cal is workout-adjusted — still write our best guess
      // below (idempotent re-export corrects it once this query succeeds),
      // but flag the day so it isn't marked done on this pass.
      debugPrint('[health] workout-calorie query: $e');
      success = false;
    }

    if (cal > 0) {
      final calPerHour = cal / bucketCount;
      for (int i = 0; i < bucketCount; i++) {
        try {
          final wrote = await _health.writeHealthData(
            value: calPerHour,
            type: HealthDataType.ACTIVE_ENERGY_BURNED,
            startTime: bucketBounds[i],
            endTime: bucketBounds[i + 1],
            unit: HealthDataUnit.KILOCALORIE,
          );
          if (!wrote) {
            debugPrint('[health] write active energy bucket $i returned false');
            success = false;
          }
        } catch (e) {
          debugPrint('[health] write energy bucket $i: $e');
          success = false;
        }
      }
    }

    // Basal energy = total daily energy (TDEE) − active, chunked hourly.
    final calTotal = sc('calories_total');
    final rawCal = sc('calories');
    if (calTotal != null && rawCal != null && calTotal > rawCal) {
      final basal = (calTotal - rawCal).toDouble();
      final basalPerHour = basal / bucketCount;
      for (int i = 0; i < bucketCount; i++) {
        try {
          final wrote = await _health.writeHealthData(
            value: basalPerHour,
            type: HealthDataType.BASAL_ENERGY_BURNED,
            startTime: bucketBounds[i],
            endTime: bucketBounds[i + 1],
            unit: HealthDataUnit.KILOCALORIE,
          );
          if (!wrote) {
            debugPrint('[health] write basal energy bucket $i returned false');
            success = false;
          }
        } catch (e) {
          debugPrint('[health] write basal energy bucket $i: $e');
          success = false;
        }
      }
    }

    // Continuous Heart Rate (minute-by-minute average).
    List<Map<String, Object?>>? hrRows;
    try {
      final db = await LocalDb.instance;
      final startTs = dayStart.millisecondsSinceEpoch ~/ 1000;
      final endTs = dayEnd.millisecondsSinceEpoch ~/ 1000;
      // Group by minute to downsample
      hrRows = await db.rawQuery(
        'SELECT (rec_ts / 60) * 60 AS minute_ts, AVG(hr) as avg_hr '
        'FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts < ? AND hr > 0 '
        'GROUP BY minute_ts',
        [startTs, endTs],
      );
    } catch (e) {
      debugPrint('[health] query continuous hr: $e');
      success = false;
    }
    if (hrRows != null) {
      final wroteHeartRate = await exportContinuousHeartRateDay(
        rows: hrRows,
        start: dayStart,
        end: dayEnd,
        useAndroidBatch: Platform.isAndroid,
        androidWriter: _androidHeartRate,
        writeGeneric: (sample, sampleEnd) => _health.writeHealthData(
          value: sample.beatsPerMinute.toDouble(),
          type: HealthDataType.HEART_RATE,
          startTime: sample.time,
          endTime: sampleEnd,
          unit: HealthDataUnit.BEATS_PER_MINUTE,
        ),
      );
      if (!wroteHeartRate) {
        debugPrint('[health] write continuous heart rate returned false');
        success = false;
      }
    }

    // STEPS ARE DELIBERATELY NOT EXPORTED.
    //
    // We used to write `scalars.steps` here as a plain HealthDataType.STEPS
    // sample. Two reasons that had to stop:
    //
    //   1. The value was a 1 Hz fabrication (active minutes x an assumed
    //      cadence) — measured at 2,645 against a true count under 400.
    //   2. Even now that `steps` is real-pedometer-only, exporting it is
    //      wrong: on iOS the phone ALREADY writes its own pedometer steps to
    //      HealthKit, and we now READ those (see PhonePedometer). Writing our
    //      derived copy back would double-count into the system store and
    //      then feed our own number back to us on the next read.
    //
    // The "estimate" qualifier every in-app surface carries is also lost the
    // moment a sample lands in Apple Health as a bare STEPS count, so a wrong
    // number here contaminates every other app on the device.

    // Health Connect models stages as children of ONE SleepSessionRecord. The
    // health 11.1.1 generic SLEEP_* writer instead creates one parent record
    // per call, fragmenting a night. Android therefore uses our typed native
    // replace API; Apple Health keeps its existing per-stage samples.
    if (isApple) {
      final segs = (_sub(b, 'series')?['hypnogram'] as List?) ?? const [];
      for (final s in segs) {
        if (s is! Map) continue;
        final st = (s['start'] as num?)?.toInt();
        final en = (s['end'] as num?)?.toInt();
        final stage = healthSleepStageOf(s['stage']?.toString());
        if (st == null || en == null || en <= st || stage == null) continue;
        final type = _sleepType(stage);
        try {
          final wrote = await _health.writeHealthData(
            value: 0,
            type: type,
            startTime: DateTime.fromMillisecondsSinceEpoch(st * 1000),
            endTime: DateTime.fromMillisecondsSinceEpoch(en * 1000),
          );
          if (!wrote) success = false;
        } catch (e) {
          debugPrint('[health] write sleep ${type.name}: $e');
          success = false;
        }
      }
    }

    // Workouts (manual/live/detected) finalized in this calendar day. Upper
    // bound is exclusive (dayEnd - 1s) for the same midnight-boundary reason
    // as the active-energy query above — otherwise a workout starting exactly
    // at midnight gets written into both this day and the next.
    {
      List<Map<String, Object?>>? rows;
      try {
        rows = await LocalDb.sessionsInRange(
          dayStart.millisecondsSinceEpoch ~/ 1000,
          (dayEnd.millisecondsSinceEpoch ~/ 1000) - 1,
        );
      } catch (e) {
        debugPrint('[health] query workouts: $e');
        success = false;
      }
      if (rows != null) {
        for (final r in rows) {
          if (await _writeOneWorkout(r) == false) {
            debugPrint('[health] write workout returned false');
            success = false;
          }
        }
      }
    }
    return success;
  }

  /// The actual `writeWorkoutData` call, shared by [_exportDay]'s per-day loop
  /// and [exportWorkout] below — one source of truth for "what counts as a
  /// writable session row". Returns null (no-op, NOT a failure — a still-live
  /// or malformed row) / true (wrote) / false (a genuine write error). CodeRabbit
  /// caught this as a real bug: this used to collapse "skip" and "failed" onto
  /// the same `false`, so an in-progress workout could repeatedly trip
  /// `_exportDay`'s attempts/backoff/give-up machinery (reserved for genuine
  /// thrown errors per the `_kRetryCursor` doc) on every drain/derive pass,
  /// eventually "giving up" on — and silently pausing — that WHOLE day's real
  /// health export (RHR/HRV/steps/sleep), not just the still-live workout.
  Future<bool?> _writeOneWorkout(Map<String, Object?> r) async {
    if ((r['status']?.toString() ?? '') == 'live') {
      return null; // skip, not a failure
    }
    final st = (r['start_ts'] as num?)?.toInt();
    final en = (r['end_ts'] as num?)?.toInt();
    if (st == null || en == null || en <= st) {
      return null; // skip, not a failure
    }
    try {
      return await _health.writeWorkoutData(
        activityType: _activity(r['type']?.toString()),
        start: DateTime.fromMillisecondsSinceEpoch(st * 1000),
        end: DateTime.fromMillisecondsSinceEpoch(en * 1000),
        totalEnergyBurned: (r['calories'] as num?)?.round(),
      );
    } catch (e) {
      debugPrint('[health] write workout @$st: $e');
      return false;
    }
  }

  /// Write ONE just-finished workout to the platform health store immediately,
  /// independent of day_result/derive timing (issue #130: previously a
  /// workout only reached Apple Health/Health Connect as a side effect of
  /// [_exportDay] running for that calendar day via [exportAll], which
  /// requires a `day_result` row to already exist for today AND a BLE-derive
  /// pass to have run afterward — a manual/live workout finished with the
  /// band disconnected, or between derive passes, could sit unexported in
  /// `sessions` for hours, or indefinitely if no further sync happened that
  /// day). Call this directly from wherever a session's final row lands
  /// (stopWorkout, an auto-detected-workout confirm, …) instead of waiting on
  /// the next full-day export.
  ///
  /// Idempotent, but SCOPED: only deletes-then-rewrites WORKOUT-type samples
  /// inside this workout's own [start,end] window, so it can't clobber a
  /// same-day sibling workout or the rest of that day's health data (unlike
  /// [_exportDay], which owns the whole-day delete). Best-effort — never
  /// throws; no-op if the health store isn't configured/available/permitted
  /// (mirrors [_exportDay]'s silent-no-op-on-missing-permission contract).
  Future<bool> exportWorkout(Map<String, Object?> session) async {
    if ((session['status']?.toString() ?? '') == 'live') return false;
    final st = (session['start_ts'] as num?)?.toInt();
    final en = (session['end_ts'] as num?)?.toInt();
    if (st == null || en == null || en <= st) return false;
    try {
      await _ensureConfigured();
      if (await _androidUnavailable() != null) return false;
      final start = DateTime.fromMillisecondsSinceEpoch(st * 1000);
      final end = DateTime.fromMillisecondsSinceEpoch(en * 1000);
      var success = true;
      try {
        final deleted = await _health.delete(
          type: HealthDataType.WORKOUT,
          startTime: start,
          endTime: end,
        );
        if (!deleted) success = false;
      } catch (e) {
        debugPrint('[health] delete workout @$st: $e');
        success = false;
      }
      final wrote = (await _writeOneWorkout(session)) ?? false;
      return success && wrote;
    } catch (e) {
      debugPrint('[health] exportWorkout: $e');
      return false;
    }
  }

  HealthDataType _sleepType(HealthSleepStage stage) {
    switch (stage) {
      case HealthSleepStage.deep:
        return HealthDataType.SLEEP_DEEP;
      case HealthSleepStage.rem:
        return HealthDataType.SLEEP_REM;
      case HealthSleepStage.light:
        return HealthDataType.SLEEP_LIGHT;
      case HealthSleepStage.awake:
        return HealthDataType.SLEEP_AWAKE;
    }
  }

  // `isApple`, not `Platform.isIOS`: every other platform decision in this file
  // (the HRV type, the delete list, the store name) keys off the same getter,
  // and a divergence here would hand macOS the Health Connect spellings.
  HealthWorkoutActivityType _activity(String? type) =>
      healthActivityForType(type, ios: isApple);

  /// Decode a stored day bundle, normalizing the compact curve format back to
  /// plain [{t,v}] lists. Hypnogram segments are never encoded (no `t` key), so
  /// today only the sleep export reads through here — but every day_result
  /// reader goes through the codec so a future one cannot silently miss it.
  static Map<String, dynamic>? _decode(Object? json) =>
      SeriesCodec.decodePayloadJson(json);

  static Map<String, dynamic>? _sub(Map<String, dynamic>? b, String path) {
    var cur = b;
    for (final p in path.split('.')) {
      final n = cur?[p];
      cur = n is Map ? n.cast<String, dynamic>() : null;
      if (cur == null) return null;
    }
    return cur;
  }

  static DateTime? _localMidnight(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]),
        m = int.tryParse(p[1]),
        d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}

/// The app's workout-type key -> platform health activity type.
///
/// Parameterised by [ios] rather than reading `Platform` directly so a unit
/// test can exercise BOTH platform branches on a host VM (where `Platform.isIOS`
/// and `Platform.isAndroid` are both false) — see
/// `test/workout_health_mapping_test.dart`.
///
/// Why the platform branches exist at all: `health`'s `writeWorkoutData` rejects
/// (throws `HealthException`, before the platform channel) any activity type
/// absent from that platform's own supported set, and the two platforms spell
/// the strength and swim families differently:
///
/// | app key    | iOS                            | Android          |
/// |------------|--------------------------------|------------------|
/// | `strength` | TRADITIONAL_STRENGTH_TRAINING  | STRENGTH_TRAINING|
/// | `swim`     | SWIMMING                       | SWIMMING_POOL    |
///
/// iOS has no bare `STRENGTH_TRAINING`; Android has neither `TRADITIONAL_`/
/// `FUNCTIONAL_STRENGTH_TRAINING` nor bare `SWIMMING`. Using one spelling for
/// both platforms silently drops every workout of that type on the other one —
/// that is issue #184 (no strength workout ever reached Apple Health) and the
/// same latent bug existed for swims on Android.
///
/// Anything unmapped falls back to `OTHER`, which both platforms accept, so an
/// unrecognised or autodetected type still lands in the health store.
@visibleForTesting
HealthWorkoutActivityType healthActivityForType(
  String? type, {
  required bool ios,
}) {
  switch ((type ?? '').toLowerCase()) {
    case 'run':
    case 'running':
      return HealthWorkoutActivityType.RUNNING;
    case 'cycle':
    case 'cycling':
    case 'bike':
    case 'biking':
      return HealthWorkoutActivityType.BIKING;
    case 'walk':
    case 'walking':
      return HealthWorkoutActivityType.WALKING;
    case 'swim':
    case 'swimming':
      return ios
          ? HealthWorkoutActivityType.SWIMMING
          : HealthWorkoutActivityType.SWIMMING_POOL;
    case 'strength':
    case 'weights':
    case 'lifting':
      return ios
          ? HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING
          : HealthWorkoutActivityType.STRENGTH_TRAINING;
    case 'yoga':
      return HealthWorkoutActivityType.YOGA;
    case 'hiit':
      return HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING;
    case 'boxing':
      return HealthWorkoutActivityType.BOXING;
    case 'rowing':
    case 'row':
      return HealthWorkoutActivityType.ROWING;
    case 'hike':
    case 'hiking':
      return HealthWorkoutActivityType.HIKING;
    case 'climb':
    case 'climbing':
      // Bare `CLIMBING` is iOS-only; `ROCK_CLIMBING` is the one spelling both
      // stores accept, which is the #184 lesson applied ahead of the bug.
      return HealthWorkoutActivityType.ROCK_CLIMBING;
    case 'ski':
    case 'skiing':
      // `SKIING` is Android-only; `DOWNHILL_SKIING` exists on both.
      return HealthWorkoutActivityType.DOWNHILL_SKIING;
    case 'snowboard':
    case 'snowboarding':
      return HealthWorkoutActivityType.SNOWBOARDING;
    case 'stairs':
    case 'stair':
      // `STAIRS` is iOS-only; `STAIR_CLIMBING` exists on both.
      return HealthWorkoutActivityType.STAIR_CLIMBING;
    case 'pilates':
      return HealthWorkoutActivityType.PILATES;
    case 'tennis':
    case 'racquet':
    case 'squash':
    case 'padel':
    case 'badminton':
      return HealthWorkoutActivityType.TENNIS;
    case 'basketball':
      return HealthWorkoutActivityType.BASKETBALL;
    case 'soccer':
    case 'football':
      // `SOCCER` passes the plugin's Dart-side guard but is COMMENTED OUT of
      // Health Connect's Kotlin write map (HealthPlugin.kt, "TODO: add
      // soccer"), so the call reaches the channel and comes back
      // `success(false)` rather than throwing. This file treats a false as a
      // genuine write failure and counts it toward the day's give-up budget —
      // so one soccer workout would silently pause that day's ENTIRE export,
      // resting HR and sleep included. Worse than #184, which at least failed
      // only itself. OTHER is accepted on Android, so the workout lands
      // unlabelled instead of taking the day down with it.
      return ios
          ? HealthWorkoutActivityType.SOCCER
          : HealthWorkoutActivityType.OTHER;
    case 'golf':
      return HealthWorkoutActivityType.GOLF;
    default:
      return HealthWorkoutActivityType.OTHER;
  }
}
