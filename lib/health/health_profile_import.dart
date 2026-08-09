// Read body metrics from the platform health store into the local profile.
//
// Everything else in lib/health writes OUT. This reads IN, for one reason:
// weight changes, and three things the app computes depend on it — calories
// (Keytel), BMR, and the strain anchors. A profile typed in once at onboarding
// and never touched again quietly gets more wrong every month, and most people
// already keep their weight current somewhere else.
//
// PLATFORM ASYMMETRY, and it is not symmetrical by accident:
//   height + weight — both platforms.
//   sex + date of birth — APPLE ONLY. Health Connect has no characteristic
//   record for either, and the plugin's Android type list does not contain
//   them. Requesting them there is the issue #184 shape all over again, so the
//   requested set is built per platform rather than filtered afterwards.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

/// What a read found. Every field is nullable: an empty health store, a denied
/// permission and a never-recorded metric are all "we don't know", and none of
/// them may become a number.
@immutable
class HealthProfileSnapshot {
  const HealthProfileSnapshot({
    this.weightKg,
    this.heightCm,
    this.ageYears,
    this.sex,
  });

  final double? weightKg;
  final double? heightCm;
  final int? ageYears;

  /// 'm' | 'f', matching the local profile map. Null for unset or for a value
  /// HealthKit reports as "other" — the formulas that read this have exactly
  /// two constants, so the honest response is no answer rather than a coin
  /// flip.
  final String? sex;

  bool get isEmpty =>
      weightKg == null && heightCm == null && ageYears == null && sex == null;

  /// Field names that were found, for a "read your weight and height" message
  /// that says what actually happened.
  List<String> get found => [
    if (weightKg != null) 'weight',
    if (heightCm != null) 'height',
    if (ageYears != null) 'age',
    if (sex != null) 'sex',
  ];
}

/// Merge a snapshot into the existing profile map and return the result.
///
/// The rule differs per field, deliberately:
///   weight, height — the health store WINS. They change, and keeping them
///   current is the entire point of the feature.
///   age, sex — only fill a GAP. Neither drifts, so a value already in the
///   profile is a deliberate choice by the user, and overwriting it from
///   another app's record would be presumptuous. Age is also the one the user
///   is most likely to have entered as an approximation on purpose.
///
/// Pure, so the policy is testable without a health store.
Map<String, dynamic> mergeHealthProfile(
  Map<String, dynamic>? existing,
  HealthProfileSnapshot snap,
) {
  final out = Map<String, dynamic>.from(existing ?? const {});
  if (snap.weightKg != null) out['weight_kg'] = snap.weightKg;
  if (snap.heightCm != null) out['height_cm'] = snap.heightCm;
  if (snap.ageYears != null && out['age'] == null) out['age'] = snap.ageYears;
  if (snap.sex != null && out['sex'] == null) out['sex'] = snap.sex;
  return out;
}

/// Which fields [snap] would actually change in [existing], under
/// [mergeHealthProfile]. Used so the confirmation can name them rather than
/// claiming an import that changes nothing.
List<String> healthProfileChanges(
  Map<String, dynamic>? existing,
  HealthProfileSnapshot snap,
) {
  final before = Map<String, dynamic>.from(existing ?? const {});
  final after = mergeHealthProfile(existing, snap);
  const labels = {
    'weight_kg': 'weight',
    'height_cm': 'height',
    'age': 'age',
    'sex': 'sex',
  };
  return [
    for (final e in labels.entries)
      if (after[e.key] != before[e.key]) e.value,
  ];
}

class HealthProfileImporter {
  HealthProfileImporter({Health? health, bool? isApple})
    : _health = health ?? Health(),
      _isApple = isApple ?? (Platform.isIOS || Platform.isMacOS);

  final Health _health;
  final bool _isApple;

  /// Types to request, per platform. Sex and date of birth exist only on
  /// Apple; asking Health Connect for them throws before the platform channel.
  List<HealthDataType> get types => [
    HealthDataType.WEIGHT,
    HealthDataType.HEIGHT,
    if (_isApple) ...[HealthDataType.GENDER, HealthDataType.BIRTH_DATE],
  ];

  /// Ask for READ access. Safe to call repeatedly.
  Future<bool> requestPermission() async {
    try {
      await _health.configure();
      final already = await _health.hasPermissions(
        types,
        permissions: [for (final _ in types) HealthDataAccess.READ],
      );
      if (already == true) return true;
      return await _health.requestAuthorization(
        types,
        permissions: [for (final _ in types) HealthDataAccess.READ],
      );
    } catch (e) {
      debugPrint('[health_profile] permission: $e');
      return false;
    }
  }

  /// Read the most recent value of each field.
  ///
  /// Never throws: a locked store, a denied permission or a store with nothing
  /// in it all come back as an empty snapshot, which the caller reports as
  /// "nothing to import" rather than as a failure.
  Future<HealthProfileSnapshot> read({DateTime? now}) async {
    try {
      await _health.configure();
      final end = now ?? DateTime.now();
      // One year back on Apple. The point of this is keeping a value CURRENT,
      // and the merge adopts weight and height unconditionally — so a wider
      // window would let an eight-year-old reading silently replace a profile
      // the user has kept up to date, and that stale weight then feeds
      // calories, BMR and the strain anchors. Characteristics (sex, DOB)
      // ignore the window entirely.
      //
      // Health Connect caps third-party reads at the last 30 DAYS unless the
      // user grants `READ_HEALTH_DATA_HISTORY`, and the pinned `health` 11.1.1
      // exposes no API to request it — so asking for ten years on Android
      // returns the same 30 days while implying otherwise. Ask for what we can
      // actually have. Someone who weighs themselves less often than monthly
      // gets nothing, which reports honestly as "nothing to read".
      final start = _isApple
          ? DateTime(end.year - 1, end.month, end.day)
          : end.subtract(const Duration(days: 30));
      final points = await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: end,
      );
      return _snapshotFrom(points, now: end);
    } catch (e) {
      debugPrint('[health_profile] read: $e');
      return const HealthProfileSnapshot();
    }
  }

  /// Fold raw points into a snapshot, newest wins per type.
  @visibleForTesting
  HealthProfileSnapshot snapshotFrom(
    List<HealthDataPoint> points, {
    DateTime? now,
  }) => _snapshotFrom(points, now: now ?? DateTime.now());

  HealthProfileSnapshot _snapshotFrom(
    List<HealthDataPoint> points, {
    required DateTime now,
  }) {
    HealthDataPoint? newest(HealthDataType t) {
      HealthDataPoint? best;
      for (final p in points) {
        if (p.type != t) continue;
        if (best == null || p.dateTo.isAfter(best.dateTo)) best = p;
      }
      return best;
    }

    double? numeric(HealthDataType t) {
      final v = newest(t)?.value;
      return v is NumericHealthValue ? v.numericValue.toDouble() : null;
    }

    final weight = numeric(HealthDataType.WEIGHT);
    // The plugin normalises HEIGHT to METRES; the profile stores centimetres.
    final heightM = numeric(HealthDataType.HEIGHT);

    int? age;
    final dob = newest(HealthDataType.BIRTH_DATE)?.value;
    if (dob is NumericHealthValue) {
      final born = DateTime.fromMillisecondsSinceEpoch(
        dob.numericValue.toInt(),
      );
      var years = now.year - born.year;
      // Not yet had this year's birthday.
      if (now.month < born.month ||
          (now.month == born.month && now.day < born.day)) {
        years--;
      }
      if (years > 0 && years < 120) age = years;
    }

    // HKBiologicalSex raw values: 0 notSet, 1 female, 2 male, 3 other. Only 1
    // and 2 map — "other" and "not set" leave this null, because the formulas
    // downstream carry one constant per sex and nothing sensible for a third.
    String? sex;
    final g = newest(HealthDataType.GENDER)?.value;
    if (g is NumericHealthValue) {
      final raw = g.numericValue.toInt();
      if (raw == 1) sex = 'f';
      if (raw == 2) sex = 'm';
    }

    return HealthProfileSnapshot(
      // Bounds are a sanity floor on a value being adopted without review, not
      // a claim about human bodies: a zero or a wildly out-of-range reading is
      // a bad record, and it would land straight in the calorie formula.
      weightKg: (weight != null && weight > 20 && weight < 400) ? weight : null,
      heightCm: (heightM != null && heightM > 0.5 && heightM < 2.6)
          ? heightM * 100
          : null,
      ageYears: age,
      sex: sex,
    );
  }
}
