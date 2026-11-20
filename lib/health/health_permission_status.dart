// Per-type WRITE authorization status of the platform health store, and the
// pure mapping from HealthDataType to the display rows the settings screen
// lists. The status itself is read natively on Apple (HealthKit answers
// `authorizationStatus` for the SHARE side — only READ denial is withheld —
// while the `health` plugin cannot see write auth at all); see
// ios/Runner/HealthAuthBridge.swift.
//
// Honesty rule: anything unreadable maps to [HealthWriteAuth.unknown], never
// to a guessed granted/denied.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

/// What the store says about our WRITE access for one data type.
enum HealthWriteAuth { unknown, notDetermined, denied, authorized }

/// Native status string → enum. Accepts both the raw HealthKit names and the
/// normalized names the channel sends; anything else is `unknown`.
HealthWriteAuth healthWriteAuthFromNative(String? raw) => switch (raw) {
      'authorized' || 'sharingAuthorized' => HealthWriteAuth.authorized,
      'denied' || 'sharingDenied' => HealthWriteAuth.denied,
      'notDetermined' => HealthWriteAuth.notDetermined,
      _ => HealthWriteAuth.unknown,
    };

/// One display row of the permission list. Sleep collapses to a single row:
/// HealthKit has one `sleepAnalysis` object type behind all the stage types.
enum HealthPermType {
  sleep('sleep'),
  restingHr('resting_hr'),
  hrv('hrv'),
  respRate('resp_rate'),
  heartRate('heart_rate'),
  activeEnergy('active_energy'),
  basalEnergy('basal_energy'),
  steps('steps'),
  workout('workout'),
  weight('weight');

  const HealthPermType(this.key);

  /// Stable key sent over the native channel.
  final String key;
}

HealthPermType? healthPermTypeOf(HealthDataType t) => switch (t) {
      HealthDataType.SLEEP_DEEP ||
      HealthDataType.SLEEP_REM ||
      HealthDataType.SLEEP_LIGHT ||
      HealthDataType.SLEEP_AWAKE ||
      HealthDataType.SLEEP_SESSION ||
      HealthDataType.SLEEP_IN_BED =>
        HealthPermType.sleep,
      HealthDataType.RESTING_HEART_RATE => HealthPermType.restingHr,
      HealthDataType.HEART_RATE_VARIABILITY_SDNN ||
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD =>
        HealthPermType.hrv,
      HealthDataType.RESPIRATORY_RATE => HealthPermType.respRate,
      HealthDataType.HEART_RATE => HealthPermType.heartRate,
      HealthDataType.ACTIVE_ENERGY_BURNED => HealthPermType.activeEnergy,
      HealthDataType.BASAL_ENERGY_BURNED => HealthPermType.basalEnergy,
      HealthDataType.STEPS => HealthPermType.steps,
      HealthDataType.WORKOUT => HealthPermType.workout,
      HealthDataType.WEIGHT => HealthPermType.weight,
      _ => null,
    };

/// Unique display rows for [types], in first-seen order.
List<HealthPermType> healthPermTypesFor(Iterable<HealthDataType> types) {
  final out = <HealthPermType>[];
  for (final t in types) {
    final p = healthPermTypeOf(t);
    if (p != null && !out.contains(p)) out.add(p);
  }
  return out;
}

/// Counts over one permission read. Nothing is inferred beyond what the store
/// actually answered.
class HealthPermissionSummary {
  HealthPermissionSummary(Map<String, HealthWriteAuth> statuses)
      : total = statuses.length,
        authorized = _count(statuses, HealthWriteAuth.authorized),
        denied = _count(statuses, HealthWriteAuth.denied),
        notDetermined = _count(statuses, HealthWriteAuth.notDetermined),
        unknown = _count(statuses, HealthWriteAuth.unknown);

  static int _count(Map<String, HealthWriteAuth> m, HealthWriteAuth a) =>
      m.values.where((v) => v == a).length;

  final int total, authorized, denied, notDetermined, unknown;

  bool get anyDenied => denied > 0;

  /// False for an empty read — "nothing denied" must not pass for "all granted".
  bool get allAuthorized => total > 0 && authorized == total;
}

/// Reads per-type write status. Implemented by the native channel bridge;
/// injectable so tests can mock the platform reply.
abstract class HealthAuthReader {
  Future<Map<String, HealthWriteAuth>> read(List<String> keys);
}

/// Reads per-type WRITE status over the native `openstrap/health_auth`
/// channel. Never throws: a missing channel, a plugin-less host or a platform
/// error leaves every key at [HealthWriteAuth.unknown].
class MethodChannelHealthAuthReader implements HealthAuthReader {
  MethodChannelHealthAuthReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('openstrap/health_auth');

  final MethodChannel _channel;

  @override
  Future<Map<String, HealthWriteAuth>> read(List<String> keys) async {
    final out = {for (final k in keys) k: HealthWriteAuth.unknown};
    if (keys.isEmpty) return out;
    try {
      final raw = await _channel
          .invokeMethod<List<Object?>>('writeStatus', {'types': keys});
      if (raw == null) return out;
      for (final e in raw) {
        if (e is! Map) continue;
        final k = e['type'];
        if (k is! String || !out.containsKey(k)) continue;
        final s = e['status'];
        out[k] = healthWriteAuthFromNative(s is String ? s : null);
      }
    } catch (e) {
      debugPrint('[health] writeStatus read: $e');
    }
    return out;
  }
}
