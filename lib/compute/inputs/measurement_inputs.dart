// Health measurements (the Mi scales, the thermometer) on our side.
//
// Their readings stay observations, shown attributed on the day they were
// taken: weight, the composition scale's impedance, body temperature. One
// number crosses over, the way a weight read from the health store does
// (`health_profile_import.dart`): the newest weighing becomes the profile's
// weight, which calories, BMR and the strain anchors read. It goes through
// the profile, never straight into a derive.

import '../../ble/adapters/_registry.dart' show DeviceCategory, categoryOf;
import '../../data/db.dart';
import 'canonical.dart' show deviceFlagOn, wearableEnabled;

/// The profile field holding when [newestWeighing]'s weight was taken, so
/// the same weighing is adopted once and a weight typed in after it stays.
const String kWeighedAtMs = 'weight_at_ms';

/// How far a weighing may sit from the profile's weight and still be taken
/// as this user's: a scale weighs whoever steps on it, and its live readings
/// carry no user, so a household member's weighing must not become ours.
// ponytail: a fixed band around the current weight; a user who really
// changed more than this types the new weight in once, and weighings follow
// it from there.
const double kWeighingBand = 0.10;

/// Whether a weighing of [kg] can be this user's, whose weight is [near]
/// (unknown: any).
bool nearWeight(num kg, num? near) =>
    near == null || near <= 0 || (kg - near).abs() <= near * kWeighingBand;

/// The newest weighing any paired health-measurement device with its flag
/// on (rule R6, [wearableEnabled]) banked (kg, epoch ms), or null. With
/// [near] (the profile's weight), only weighings within [kWeighingBand] of
/// it count.
Future<({double kg, int atMs})?> newestWeighing({num? near}) async {
  ({double kg, int atMs})? newest;
  for (final row in await LocalDb.deviceRows()) {
    final adapter = row['adapter_id'] as String?;
    if (adapter == null ||
        categoryOf(adapter) != DeviceCategory.healthMeasurement ||
        !await wearableEnabled(adapter)) {
      continue;
    }
    final w = await LocalDb.deviceObservationValues(
        row['id'] as String, 'weight');
    for (final MapEntry(key: at, value: kg) in w.entries) {
      if (!nearWeight(kg, near)) continue;
      if (newest == null || at > newest.atMs) {
        newest = (kg: kg.toDouble(), atMs: at);
      }
    }
  }
  return newest;
}

/// The devices among [observations] whose weighings get our BMI beside
/// them: a scale whose flag is on (rule R6). A flag-off scale's weight is
/// shown attributed, and nothing of ours is made from it. Only a weighing
/// [nearWeight] the profile's gets one: the height is this user's.
Future<Set<Object?>> bmiScalesOf(
  List<Map<String, Object?>> observations,
) async => {
  for (final r in observations)
    if (r['key'] == 'weight' && await deviceFlagOn(r['device_id'] as String?))
      r['device_id'],
};

/// [profile] with [w] as its weight when [w] is newer than the weighing it
/// last took; null when nothing changes.
// ponytail: a typed-in weight carries no time, so the first weighing ever
// synced replaces it even when that record is older; stamp the form's save
// with [kWeighedAtMs] if that matters.
Map<String, dynamic>? profileWithWeighing(
  Map<String, dynamic>? profile,
  ({double kg, int atMs}) w,
) {
  final at = (profile?[kWeighedAtMs] as num?)?.toInt() ?? 0;
  if (w.atMs <= at) return null;
  final stillWeighed = profile?[kWeighedKg] != null &&
      profile?[kWeighedKg] == profile?['weight_kg'];
  return {
    ...?profile,
    'weight_kg': w.kg,
    kWeighedAtMs: w.atMs,
    kWeighedKg: w.kg,
    kWeightBeforeWeighing: stillWeighed
        ? profile![kWeightBeforeWeighing]
        : profile?['weight_kg'],
  };
}

/// The profile field holding the weight [profileWithWeighing] adopted, so a
/// weight typed in over it is told apart from it.
const String kWeighedKg = 'weight_weighed_kg';

/// The profile field holding the weight from before a scale's weighing
/// replaced it.
const String kWeightBeforeWeighing = 'weight_before_weighing_kg';

/// [profile] with the weight it had before a scale's weighing, when its
/// weight is still that weighing and no paired scale with its flag on holds
/// it any more (rule R6: flag off = nothing from it); null otherwise. The
/// weighing fields are cleared (null, so a merge clears them), so turning
/// the flag back on adopts it again.
Future<Map<String, dynamic>?> profileWithoutStaleWeighing(
  Map<String, dynamic>? profile,
) async {
  final kg = profile?[kWeighedKg] as num?;
  final at = (profile?[kWeighedAtMs] as num?)?.toInt();
  if (profile == null || kg == null || at == null) return null;
  if (kg != profile['weight_kg']) return null; // typed over: the user's now
  for (final row in await LocalDb.deviceRows()) {
    final adapter = row['adapter_id'] as String?;
    if (adapter == null ||
        categoryOf(adapter) != DeviceCategory.healthMeasurement ||
        !await wearableEnabled(adapter)) {
      continue;
    }
    final w = await LocalDb.deviceObservationValues(
        row['id'] as String, 'weight', fromMs: at);
    if (w[at] == kg) return null;
  }
  return {
    ...profile,
    'weight_kg': profile[kWeightBeforeWeighing],
    kWeighedAtMs: null,
    kWeighedKg: null,
    kWeightBeforeWeighing: null,
  };
}
