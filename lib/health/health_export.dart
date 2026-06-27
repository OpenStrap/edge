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

/// What we can do with the health store right now.
enum HealthLinkState {
  unknown,
  ready, // permission granted, can write
  needsPermission, // store available, user hasn't granted write access
  notInstalled, // Android: Health Connect not installed
  needsUpdate, // Android: Health Connect needs a Play update
  unsupported, // no health store on this device (iPad / simulator)
}

class HealthExporter {
  final _health = Health();
  bool _configured = false;

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
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.BASAL_ENERGY_BURNED,
        HealthDataType.STEPS,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_SESSION,
        HealthDataType.WORKOUT,
      ];

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
      await _health.requestAuthorization(_types,
          permissions: _types.map((_) => HealthDataAccess.WRITE).toList());
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
  Future<int> exportAll({bool reset = false, void Function(int days)? onProgress}) async {
    await _ensureConfigured();
    if (await _androidUnavailable() != null) return 0; // HC missing/outdated
    try {
      if (reset) await LocalDb.setCursor('health_export_through', '');
      final cursor = await LocalDb.getCursor('health_export_through') ?? '';
      final rows = await LocalDb.recentDayResults(400); // newest-first
      final ascending = rows.reversed.toList();
      var done = 0;
      var newCursor = cursor;
      var prefixContiguous = true; // still extending the finalized prefix?
      for (final row in ascending) {
        final date = (row['day_id'] ?? row['date'])?.toString();
        if (date == null || date.isEmpty) continue;
        if (cursor.isNotEmpty && date.compareTo(cursor) <= 0) {
          continue; // immutable finalized prefix — already exported
        }
        final finalized = (row['finalized'] as num?)?.toInt() == 1;
        final bundle = _decode(row['payload_json']);
        if (bundle == null || bundle['skipped'] == true) {
          if (!finalized) prefixContiguous = false;
          continue;
        }
        final ok = await _exportDay(date, bundle); // delete-then-write (idempotent)
        if (ok) {
          done++;
          onProgress?.call(done);
        }
        // Advance the cursor only while the finalized prefix stays unbroken; the
        // first non-finalized day stops it (that day re-exports next pass).
        if (prefixContiguous && finalized) {
          newCursor = date;
        } else {
          prefixContiguous = false;
        }
      }
      if (newCursor != cursor) {
        await LocalDb.setCursor('health_export_through', newCursor);
      }
      debugPrint('[health] exported $done day(s); finalized-cursor=$newCursor');
      return done;
    } catch (e) {
      debugPrint('[health] exportAll: $e');
      return 0;
    }
  }

  /// Write one day's metrics. DELETES our prior samples for the day window first
  /// (so a re-derive overwrites instead of duplicating). Best-effort; never throws.
  Future<bool> _exportDay(String date, Map<String, dynamic> b) async {
    final dayStart = _localMidnight(date);
    if (dayStart == null) return false;
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Idempotency: remove OUR previously-written samples for this day (HealthKit /
    // Health Connect only let an app delete its own data), then re-write fresh.
    for (final t in _types) {
      try {
        await _health.delete(type: t, startTime: dayStart, endTime: dayEnd);
      } catch (e) {
        debugPrint('[health] delete ${t.name}: $e');
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

    Future<void> writeAt(HealthDataType type, num? v, HealthDataUnit unit,
        DateTime t) async {
      if (v == null || v <= 0) return;
      try {
        await _health.writeHealthData(
            value: v.toDouble(),
            type: type,
            startTime: t,
            endTime: t,
            unit: unit);
      } catch (e) {
        debugPrint('[health] write ${type.name}: $e');
      }
    }

    // Nightly cardiac/respiratory scalars (single sample at the sleep midpoint).
    await writeAt(HealthDataType.RESTING_HEART_RATE, sc('rhr'),
        HealthDataUnit.BEATS_PER_MINUTE, mid);
    await writeAt(_hrvType, sc(_hrvScalarKey), HealthDataUnit.MILLISECOND, mid);
    await writeAt(HealthDataType.RESPIRATORY_RATE, sc('resp_rate'),
        HealthDataUnit.RESPIRATIONS_PER_MINUTE, mid);

    // Active energy over the whole day.
    final cal = sc('calories');
    if (cal != null && cal > 0) {
      try {
        await _health.writeHealthData(
            value: cal.toDouble(),
            type: HealthDataType.ACTIVE_ENERGY_BURNED,
            startTime: dayStart,
            endTime: dayEnd,
            unit: HealthDataUnit.KILOCALORIE);
      } catch (e) {
        debugPrint('[health] write energy: $e');
      }
    }

    // Basal energy = total daily energy (TDEE) − active, over the whole day.
    final calTotal = sc('calories_total');
    if (calTotal != null && cal != null && calTotal > cal) {
      try {
        await _health.writeHealthData(
            value: (calTotal - cal).toDouble(),
            type: HealthDataType.BASAL_ENERGY_BURNED,
            startTime: dayStart,
            endTime: dayEnd,
            unit: HealthDataUnit.KILOCALORIE);
      } catch (e) {
        debugPrint('[health] write basal energy: $e');
      }
    }

    // Steps (24/7 estimate) over the whole day.
    final steps = sc('steps');
    if (steps != null && steps > 0) {
      try {
        await _health.writeHealthData(
            value: steps.toDouble(),
            type: HealthDataType.STEPS,
            startTime: dayStart,
            endTime: dayEnd,
            unit: HealthDataUnit.COUNT);
      } catch (e) {
        debugPrint('[health] write steps: $e');
      }
    }

    // Sleep stages from the per-segment hypnogram (real time ranges).
    final segs = (_sub(b, 'series')?['hypnogram'] as List?) ?? const [];
    for (final s in segs) {
      if (s is! Map) continue;
      final st = (s['start'] as num?)?.toInt();
      final en = (s['end'] as num?)?.toInt();
      final stage = s['stage']?.toString();
      if (st == null || en == null || en <= st || stage == null) continue;
      final type = _sleepType(stage);
      if (type == null) continue;
      try {
        await _health.writeHealthData(
            value: 0,
            type: type,
            startTime: DateTime.fromMillisecondsSinceEpoch(st * 1000),
            endTime: DateTime.fromMillisecondsSinceEpoch(en * 1000));
      } catch (e) {
        debugPrint('[health] write sleep ${type.name}: $e');
      }
    }

    // Workouts (manual/live/detected) finalized in this calendar day.
    {
      try {
        final rows = await LocalDb.sessionsInRange(
            dayStart.millisecondsSinceEpoch ~/ 1000,
            dayEnd.millisecondsSinceEpoch ~/ 1000);
        for (final r in rows) {
          if ((r['status']?.toString() ?? '') == 'live') continue;
          final st = (r['start_ts'] as num?)?.toInt();
          final en = (r['end_ts'] as num?)?.toInt();
          if (st == null || en == null || en <= st) continue;
          await _health.writeWorkoutData(
            activityType: _activity(r['type']?.toString()),
            start: DateTime.fromMillisecondsSinceEpoch(st * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(en * 1000),
            totalEnergyBurned: (r['calories'] as num?)?.round(),
          );
        }
      } catch (e) {
        debugPrint('[health] write workouts: $e');
      }
    }
    return true;
  }

  HealthDataType? _sleepType(String stage) {
    switch (stage) {
      case 'deep':
        return HealthDataType.SLEEP_DEEP;
      case 'rem':
        return HealthDataType.SLEEP_REM;
      case 'light':
      case 'nrem':
        return HealthDataType.SLEEP_LIGHT;
      case 'wake':
      case 'awake':
        return HealthDataType.SLEEP_AWAKE;
      default:
        return null;
    }
  }

  HealthWorkoutActivityType _activity(String? type) {
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
        return HealthWorkoutActivityType.SWIMMING;
      case 'strength':
      case 'weights':
      case 'lifting':
        return HealthWorkoutActivityType.STRENGTH_TRAINING;
      case 'yoga':
        return HealthWorkoutActivityType.YOGA;
      case 'hiit':
        return HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING;
      default:
        return HealthWorkoutActivityType.OTHER;
    }
  }

  static Map<String, dynamic>? _decode(Object? json) {
    if (json is! String) return null;
    try {
      final d = jsonDecode(json);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

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
    final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}
