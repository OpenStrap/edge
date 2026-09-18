// Read workouts — and, on Apple, their routes — out of the platform health
// store into a table this app does not derive from.
//
// WHAT THIS IS ALLOWED TO BECOME — the line moved once, deliberately, and this
// is where it now sits.
//
// ALLOWED: a list, a map, and a COUNT. An imported workout appears in Workout ›
// History beside the band's own sessions, in date order, with the app or watch
// that recorded it named on the row, and it counts toward "This week". A
// session you did is a session you did, and a history that silently omits your
// Sunday run is wrong in a way a user can see.
//
// REFUSED: weekly load, CTL/ATL/TSB, the day's strain, the personal records,
// and every personal baseline. Not out of caution — there is nothing to put in
// them. Training load here is TRIMP, which is minutes weighted by heart rate,
// and an imported workout arrives with no heart-rate series at all; the only
// way to give it a load number is to invent one from its duration and call it
// measured. The calories and distance the source app recorded are shown as ITS
// numbers, next to its name, and are never summed into ours: two devices'
// calorie models added together is one number neither of them would agree with.
//
// The refusal is structural, not a filter someone has to remember: these rows
// live in their own table (see db.dart `_createImportedWorkout`), so nothing
// that reads `sessions` can reach them by accident. The screen opts a row IN,
// one surface at a time, and each surface that takes one says whose it was.
//
// PLATFORM ASYMMETRY, and it is load-bearing:
//   workouts — both platforms.
//   routes   — APPLE ONLY, and via our own method channel, because the pinned
//              `health` 11.1.1 has no route API at all (the string "route"
//              does not occur anywhere in its lib/, ios/ or android/ sources).
//              Health Connect gates routes behind READ_EXERCISE_ROUTES, a
//              restricted permission needing a Google declaration or a
//              per-route system consent dialog; neither is wired, so Android
//              imports workouts WITHOUT coordinates and the UI says so. A half
//              path that silently returned no points would be indistinguishable
//              from a user who simply never records outdoors.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:health/health.dart';

import '../data/db.dart';

/// Apple-only bridge to `HKWorkoutRoute`. Implemented in
/// ios/Runner/HealthRoutes.swift; absent on Android by design.
const MethodChannel kHealthRoutesChannel = MethodChannel(
  'openstrap/health_routes',
);

/// How far back an import reaches.
///
/// 90 days on Apple: it is the project's standing ceiling for how much history
/// is worth carrying, and a route-bearing import is the most row-expensive
/// thing this app ingests. Health Connect caps third-party reads at 30 days
/// without `READ_HEALTH_DATA_HISTORY`, which the pinned `health` 11.1.1 cannot
/// request — so Android asks for what it will actually be given rather than
/// asking for 90 and quietly receiving 30.
const int kImportWindowDaysApple = 90;
const int kImportWindowDaysAndroid = 30;

/// A workout that survived filtering, before it becomes a row.
///
/// Every field but the identity ones is nullable on purpose: HealthKit records
/// energy and distance only for the workout types that measured them, and an
/// absent distance is absent — never a zero, which on a map screen reads as a
/// workout that went nowhere.
@immutable
class ImportedWorkoutRow {
  const ImportedWorkoutRow({
    required this.uuid,
    required this.startTs,
    required this.endTs,
    required this.kind,
    required this.source,
    this.energyKcal,
    this.distanceM,
    this.steps,
  });

  final String uuid;
  final int startTs, endTs;
  final String kind, source;
  final double? energyKcal, distanceM;
  final int? steps;

  Map<String, Object?> toRow() => {
        'uuid': uuid,
        'start_ts': startTs,
        'end_ts': endTs,
        'kind': kind,
        'energy_kcal': energyKcal,
        'distance_m': distanceM,
        'steps': steps,
        'source': source,
      };
}

/// Turn raw health-store points into workout rows, dropping anything unusable.
/// Pure, so the filtering is testable without a store.
@visibleForTesting
List<ImportedWorkoutRow> workoutsFrom(List<HealthDataPoint> points) {
  final out = <ImportedWorkoutRow>[];
  final seen = <String>{};
  for (final p in points) {
    if (p.type != HealthDataType.WORKOUT) continue;
    final v = p.value;
    if (v is! WorkoutHealthValue) continue;
    // A record with no uuid cannot be deduplicated or matched to its route, and
    // the table's idempotence rests on it. Skipping beats minting a synthetic
    // key that re-inserts the same run on every import.
    if (p.uuid.isEmpty || !seen.add(p.uuid)) continue;
    final start = p.dateFrom.millisecondsSinceEpoch ~/ 1000;
    final end = p.dateTo.millisecondsSinceEpoch ~/ 1000;
    // A workout that ends before it starts, or runs longer than a day, is a bad
    // record. Dropped rather than repaired — we did not measure it and have no
    // standing to decide what it should have said.
    if (end <= start || end - start > 24 * 60 * 60) continue;
    out.add(ImportedWorkoutRow(
      uuid: p.uuid,
      startTs: start,
      endTs: end,
      kind: v.workoutActivityType.name,
      // MANDATORY. A workout whose source we cannot name is one we cannot
      // honestly display, because the entire claim is "we did not measure this".
      source: p.sourceName.trim().isEmpty ? 'Unknown app' : p.sourceName,
      energyKcal: v.totalEnergyBurned?.toDouble(),
      distanceM: v.totalDistance?.toDouble(),
      steps: v.totalSteps,
    ));
  }
  return out;
}

/// Turn one channel route payload into `workout_route` rows.
///
/// Shape from Swift: `{uuid: String, points: [[lat, lng, alt, tsMs], …]}`.
/// Anything malformed is skipped rather than defaulted — a (0, 0) coordinate is
/// a real place in the Gulf of Guinea and would draw a line to it.
///
/// The rows carry `session_id` themselves: `LocalDb.appendRoutePoints` inserts
/// the maps verbatim and does NOT stamp its `sessionId` argument onto them
/// (see `RoutePoint.toRow`, which supplies it the same way).
@visibleForTesting
List<Map<String, Object?>> routeRowsFrom(Object? payload) {
  if (payload is! Map) return const [];
  final uuid = payload['uuid'];
  if (uuid is! String || uuid.isEmpty) return const [];
  final pts = payload['points'];
  if (pts is! List) return const [];
  final out = <Map<String, Object?>>[];
  var seq = 0;
  for (final raw in pts) {
    if (raw is! List || raw.length < 4) continue;
    final lat = (raw[0] as num?)?.toDouble();
    final lng = (raw[1] as num?)?.toDouble();
    final ts = (raw[3] as num?)?.toInt();
    if (lat == null || lng == null || ts == null) continue;
    if (lat.isNaN || lng.isNaN || lat.abs() > 90 || lng.abs() > 180) continue;
    out.add({
      'session_id': uuid,
      'seq': seq++,
      'ts_ms': ts,
      'lat': lat,
      'lng': lng,
      'alt': (raw[2] as num?)?.toDouble(),
      'accuracy': null,
    });
  }
  return out;
}

/// "RUNNING" → "Running". The health store's own enum name, title-cased and
/// de-underscored.
///
/// Not mapped through a lookup table on purpose: a map would need an entry for
/// every one of ~80 activity types and would print a blank for whatever the
/// next OS version adds. Here rather than on a screen because both the Workout
/// history and the receipt list have to say the same word for the same row.
String importedWorkoutTitle(Object? kind) {
  // Checked, not cast. It reads a `Map<String, dynamic>` straight off sqflite,
  // and a cast that throws here would take a whole history screen down over a
  // column that was the wrong type.
  final raw = kind is String ? kind.trim() : '';
  if (raw.isEmpty) return 'Workout';
  return raw
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}

/// What one import did, so the screen can report it rather than guess.
@immutable
class WorkoutImportResult {
  const WorkoutImportResult({
    this.workouts = 0,
    this.withRoutes = 0,
    this.routesSupported = false,
  });

  /// Workouts stored (new or updated).
  final int workouts;

  /// How many of them came with coordinates.
  final int withRoutes;

  /// Whether routes were even askable on this platform. False on Android, so
  /// "no routes" can be reported as "not supported here" rather than as "none
  /// found" — two very different sentences for the user.
  final bool routesSupported;
}

const String _kTombstonesPref = 'health_workout_import_deleted';

/// Health-store workout uuids the user has DELETED here. The source still has
/// them, so without this list the next import would bring each one back.
Future<Set<String>> deletedUuids() async {
  final prefs = await SharedPreferences.getInstance();
  return {...(prefs.getStringList(_kTombstonesPref) ?? const [])};
}

Future<void> rememberDeletedUuid(String uuid) async {
  final prefs = await SharedPreferences.getInstance();
  final set = await deletedUuids();
  if (set.contains(uuid)) return;
  await prefs.setStringList(_kTombstonesPref, [...set, uuid]);
}


class HealthWorkoutImporter {
  HealthWorkoutImporter({Health? health, bool? isApple})
      : _health = health ?? Health(),
        _isApple = isApple ?? (Platform.isIOS || Platform.isMacOS);

  final Health _health;
  final bool _isApple;

  /// READ only. The export half writes workouts; this never does.
  static const List<HealthDataType> types = [HealthDataType.WORKOUT];

  bool get routesSupported => _isApple;

  /// NON-PROMPTING read-permission probe for the auto path: true only when
  /// the store already granted WORKOUT read. Never shows a dialog — the
  /// manual Import button's tap is the only place that question gets asked.
  Future<bool> hasReadPermission() async {
    try {
      await _health.configure();
      return await _health.hasPermissions(types,
              permissions: [for (final _ in types) HealthDataAccess.READ]) ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermission() async {
    try {
      await _health.configure();
      final perms = [for (final _ in types) HealthDataAccess.READ];
      final already = await _health.hasPermissions(types, permissions: perms);
      if (already == true) return true;
      return await _health.requestAuthorization(types, permissions: perms);
    } catch (e) {
      debugPrint('[imported_workout] permission: $e');
      return false;
    }
  }

  /// Read the window, store the workouts, then fetch each one's route on Apple.
  ///
  /// Never throws: an empty store, a denied permission and a locked device all
  /// come back as a zero result, which the caller reports as "nothing to
  /// import" rather than as a failure.
  Future<WorkoutImportResult> sync({DateTime? now}) async {
    final end = now ?? DateTime.now();
    final start = end.subtract(Duration(
      days: _isApple ? kImportWindowDaysApple : kImportWindowDaysAndroid,
    ));
    List<ImportedWorkoutRow> rows;
    try {
      await _health.configure();
      final points = await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: end,
      );
      rows = workoutsFrom(points);
    } catch (e) {
      debugPrint('[imported_workout] read: $e');
      return WorkoutImportResult(routesSupported: routesSupported);
    }
    if (rows.isEmpty) {
      return WorkoutImportResult(routesSupported: routesSupported);
    }
    // A workout the user DELETED must not resurrect on the next read: the
    // uuid goes onto a tombstone list at delete time, and anything on it is
    // dropped here (workout row AND its route) before it can come back.
    final tombstones = await deletedUuids();
    final alive = [
      for (final r in rows)
        if (!tombstones.contains(r.uuid)) r,
    ];
    await LocalDb.putImportedWorkouts([for (final r in alive) r.toRow()]);
    final withRoutes = await _importRoutes(start, end, skip: tombstones);
    return WorkoutImportResult(
      workouts: rows.length,
      withRoutes: withRoutes,
      routesSupported: routesSupported,
    );
  }

  /// Pull every route in the window in ONE channel call and file each under its
  /// workout's uuid. Returns how many workouts got coordinates.
  ///
  /// One call rather than one per workout: each `HKWorkoutRoute` query is an
  /// async round trip, and 90 days of running is a lot of them to serialise
  /// across the channel one at a time.
  Future<int> _importRoutes(DateTime start, DateTime end,
      {Set<String> skip = const {}}) async {
    if (!routesSupported) return 0;
    List<Object?> payload;
    try {
      final res = await kHealthRoutesChannel.invokeMethod<List<Object?>>(
        'routes',
        {
          'fromMs': start.millisecondsSinceEpoch,
          'toMs': end.millisecondsSinceEpoch,
        },
      );
      payload = res ?? const [];
    } catch (e) {
      // A missing channel (a build without the Swift file) or a refused
      // HealthKit read must not lose the workouts already stored above.
      debugPrint('[imported_workout] routes: $e');
      return 0;
    }
    var n = 0;
    for (final entry in payload) {
      if (entry is! Map) continue;
      final uuid = entry['uuid'];
      if (uuid is! String || uuid.isEmpty) continue;
      if (skip.contains(uuid)) continue;
      final rows = routeRowsFrom(entry);
      if (rows.isEmpty) continue;
      await LocalDb.appendRoutePoints(uuid, rows);
      n++;
    }
    return n;
  }
}
