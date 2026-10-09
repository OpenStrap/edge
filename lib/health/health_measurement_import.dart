// Import measurements from devices that are CLEARED to take them.
//
// A blood-pressure cuff measures blood pressure. A CGM measures glucose. A
// thermometer measures core temperature. None of those is a thing this app can
// derive from a wrist, and the honest way for those numbers to sit next to your
// sleep is for the device that is allowed to measure them to measure them, and
// for us to show the reading with that device's name on it.
//
// ⚠️ READ-ONLY INPUTS TO DISPLAY. NEVER TRAINING TARGETS. ⚠️
// Read the guard on `_createImportedMeasurement` in db.dart. It is repeated
// there and here deliberately: the moment a cuff series and a wrist PPG series
// live in one database, the obvious next idea is to fit one to the other, and
// that idea is a cuffless-blood-pressure claim from an uncleared device. These
// rows may be shown beside ours. They may never be regressed against ours, and
// nothing derived may take one as an input.
//
// NEVER BLENDED. There is no combined series, no "your blood pressure" without
// the cuff's name on it, and no averaging of an imported reading with anything
// of ours. The source name is a NOT NULL column for that reason.
//
// This is the ONLY honest route to blood pressure or glucose in this app. Both
// are permanently refused as things OpenStrap computes.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/db.dart';
import 'health_rhr_seed.dart' show isOwnHealthSample;

/// Stable `imported_measurement.kind` keys. Written to the database, so they
/// are contract: rename one and every stored row orphans.
const String kKindSystolic = 'bp_systolic';
const String kKindDiastolic = 'bp_diastolic';
const String kKindGlucose = 'glucose';
const String kKindBodyTemp = 'body_temp';

const Map<HealthDataType, String> kImportedKinds = {
  HealthDataType.BLOOD_PRESSURE_SYSTOLIC: kKindSystolic,
  HealthDataType.BLOOD_PRESSURE_DIASTOLIC: kKindDiastolic,
  HealthDataType.BLOOD_GLUCOSE: kKindGlucose,
  HealthDataType.BODY_TEMPERATURE: kKindBodyTemp,
};

/// Plausibility bounds per kind, in the plugin's canonical unit (mmHg, mg/dL,
/// °C). A reading outside these is a bad record — a cuff error code, a stuck
/// sensor, a unit mix-up — and it is DROPPED rather than clamped: a clamped
/// reading is a fabricated one, and this is a table of other people's
/// measurements where we have no standing to invent anything.
const Map<String, (double, double)> kImportedBounds = {
  kKindSystolic: (50, 300),
  kKindDiastolic: (20, 200),
  kKindGlucose: (10, 1000),
  kKindBodyTemp: (25, 45),
};

/// Turn raw health-store points into `imported_measurement` rows, dropping
/// anything unusable. Pure, so the filtering is testable without a store.
///
/// [ownId] is this app's package / bundle id. Our own samples are skipped:
/// the nightly WHOOP 5 skin temperature is written as BODY_TEMPERATURE (see
/// health_export.dart), and reading it back here would file our own wrist
/// reading as a thermometer's.
@visibleForTesting
List<Map<String, Object?>> rowsFrom(
  List<HealthDataPoint> points, {
  String ownId = '',
}) {
  final out = <Map<String, Object?>>[];
  final seen = <String>{};
  // Health Connect reports both halves of one blood-pressure reading under the
  // record's single id; HealthKit gives each half its own. The diastolic half
  // of a shared id gets its own key, or it collides with the systolic row.
  final systolicIds = {
    for (final p in points)
      if (p.type == HealthDataType.BLOOD_PRESSURE_SYSTOLIC) p.uuid,
  };
  for (final p in points) {
    final kind = kImportedKinds[p.type];
    if (kind == null) continue;
    if (isOwnHealthSample(p.sourceId, p.sourceName, ownId)) continue;
    final v = p.value;
    if (v is! NumericHealthValue) continue;
    final value = v.numericValue.toDouble();
    final bounds = kImportedBounds[kind];
    if (bounds != null && (value < bounds.$1 || value > bounds.$2)) continue;
    // A record with no uuid cannot be updated or deduplicated later, and the
    // table's whole idempotence rests on it. Skipping is better than minting a
    // synthetic key that re-inserts the same reading on every read.
    if (p.uuid.isEmpty) continue;
    final key = kind == kKindDiastolic && systolicIds.contains(p.uuid)
        ? '${p.uuid}:$kind'
        : p.uuid;
    if (!seen.add(key)) continue;
    out.add({
      'uuid': key,
      'ts': p.dateTo.millisecondsSinceEpoch ~/ 1000,
      'kind': kind,
      'value': value,
      'unit': p.unit.name,
      // MANDATORY. A reading whose source we cannot name is a reading we
      // cannot honestly display, because the entire claim is "we did not
      // measure this — they did".
      'source': p.sourceName.trim().isEmpty ? 'Unknown app' : p.sourceName,
    });
  }
  return out;
}

class ImportedMeasurementImporter {
  ImportedMeasurementImporter({Health? health, bool? isApple})
      : _health = health ?? Health(),
        _isApple = isApple ?? (Platform.isIOS || Platform.isMacOS);

  final Health _health;
  final bool _isApple;

  static const List<HealthDataType> types = [
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    HealthDataType.BLOOD_GLUCOSE,
    HealthDataType.BODY_TEMPERATURE,
  ];

  /// READ only. The one overlap is BODY_TEMPERATURE, which the health export
  /// writes for WHOOP 5 nights; [rowsFrom] skips our own samples.
  Future<bool> requestPermission() async {
    try {
      await _health.configure();
      final perms = [for (final _ in types) HealthDataAccess.READ];
      final already = await _health.hasPermissions(types, permissions: perms);
      if (already == true) return true;
      return await _health.requestAuthorization(types, permissions: perms);
    } catch (e) {
      debugPrint('[imported_measurement] permission: $e');
      return false;
    }
  }

  /// Read the recent window and store what is there. Returns how many rows
  /// landed; 0 covers an empty store, a denied permission and a locked device
  /// alike, none of which is an error the user needs a dialog for.
  Future<int> sync({DateTime? now}) async {
    final end = now ?? DateTime.now();
    // Health Connect caps third-party reads at 30 days without
    // READ_HEALTH_DATA_HISTORY, which the pinned `health` 11.1.1 cannot
    // request — so ask Android for what it will actually give. A year on Apple
    // is enough for a series that is measured occasionally by hand.
    final start = _isApple
        ? DateTime(end.year - 1, end.month, end.day)
        : end.subtract(const Duration(days: 30));
    try {
      await _health.configure();
      final points = await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: end,
      );
      // Without our own id we cannot tell our skin temperature from a
      // thermometer's, so nothing is stored rather than something mislabelled.
      final ownId = (await PackageInfo.fromPlatform()).packageName;
      return LocalDb.putImportedMeasurements(rowsFrom(points, ownId: ownId));
    } catch (e) {
      debugPrint('[imported_measurement] read: $e');
      return 0;
    }
  }
}
