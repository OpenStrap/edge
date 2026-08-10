// Profile — the on-device personal profile fed to the DerivationEngine.
//
// Sourced from AppState's local profile map (shared_preferences). Algorithms
// that NEED a field (HRmax via Tanaka, Keytel calories, TRIMP sex constant,
// fitness-age) read it from here; algorithms that don't simply ignore it.
//
// HONESTY: a missing field => the DEPENDENT metric must return null+confidence 0
// (never a fabricated default). The engine therefore passes nullable getters and
// only computes profile-gated metrics when the input is present.

import 'package:openstrap_analytics/onehz.dart' as ana;

class Profile {
  final int? ageYears;
  final double? weightKg;
  final double? heightCm;
  final String? sex; // 'm' | 'f' (lowercase; matches the AppState profile map)
  final int? restingHrManual; // optional user-supplied RHR

  const Profile({
    this.ageYears,
    this.weightKg,
    this.heightCm,
    this.sex,
    this.restingHrManual,
  });

  static Profile fromMap(Map<String, dynamic>? m) {
    if (m == null) return const Profile();
    return Profile(
      ageYears: (m['age'] as num?)?.round(),
      weightKg: (m['weight_kg'] as num?)?.toDouble(),
      heightCm: (m['height_cm'] as num?)?.toDouble(),
      sex: (m['sex'] as String?)?.toLowerCase(),
      restingHrManual: (m['resting_hr'] as num?)?.round(),
    );
  }

  Map<String, dynamic> toMap() => {
        if (ageYears != null) 'age': ageYears,
        if (weightKg != null) 'weight_kg': weightKg,
        if (heightCm != null) 'height_cm': heightCm,
        if (sex != null) 'sex': sex,
        if (restingHrManual != null) 'resting_hr': restingHrManual,
      };

  /// Tanaka (2001): HRmax = 208 − 0.7·age. Null when age is unknown — the caller
  /// must NOT substitute 220−age or any default (that would fabricate a ceiling).
  double? get hrMaxTanaka =>
      ageYears == null ? null : 208 - 0.7 * (ageYears!.toDouble());

  bool get isComplete =>
      ageYears != null && weightKg != null && heightCm != null && sex != null;

  /// The anchors Keytel (2005) needs to turn heart rate into kcal: age, body
  /// mass and sex. Height is not one of them, so it is deliberately absent
  /// here — gating calories on [isComplete] would refuse to score a profile
  /// that has everything the formula actually reads.
  ///
  /// The one definition of "can we cost this session in calories", shared by
  /// the live tick and the substrate re-score. They used to disagree: the
  /// re-score refused to guess while the live tick silently substituted a
  /// 30-year-old 70 kg male, so an unfinished profile produced a confident
  /// kcal number that was simply somebody else's.
  bool get hasCalorieAnchors =>
      ageYears != null && weightKg != null && sex != null;
}

/// Normalise every sex spelling the app can persist onto the three names the
/// analytics coefficient tables key on: 'male' | 'female' | 'nonbinary'.
///
/// Two writers disagree. Onboarding (`profile_setup_screen`) stores 'm'/'f';
/// the profile screen offers 'male'/'female'/'other'. Every scored path — day
/// calories, TRIMP, the live tick, a manually logged session — has to land on
/// the same coefficient block for the same stored value, or one field of one
/// profile scores as two different people. It happened: TRIMP tested `== 'f'`
/// while the calorie path accepted 'female' too, so a profile written by the
/// profile screen got female calories and male TRIMP.
///
/// 'other' and anything unrecognised map to `nonbinary`, which the analytics
/// tables define as the mean of the two published sex constants rather than a
/// guess at one of them.
String workoutSex(String? sex) {
  switch ((sex ?? '').toLowerCase()) {
    case 'm':
    case 'male':
      return 'male';
    case 'f':
    case 'female':
      return 'female';
    default:
      return 'nonbinary';
  }
}

/// The ONE definition of the calorie model's fitness anchor (Uth 2004:
/// VO2max ≈ 15.3 × HRmax/RHR), shared by every path that costs heart rate.
///
/// Lives here, on raw values rather than on [Profile], because the pure day
/// pipeline carries the profile as a plain map across an isolate boundary and
/// cannot construct a [Profile]. That pipeline previously kept an inline copy
/// of this closure whose sex mapping accepted only 'f' where the shared
/// helper's accepted 'f' and 'female' — inert only because `vo2maxEstimate`
/// ignores its sex and age arguments today, which is not a property to depend
/// on.
///
/// Returns null whenever Uth's inputs are absent or implausible. A calorie
/// estimate with no fitness anchor falls back to Keytel's published
/// age/mass/sex model; it never invents a fitness level.
double? vo2maxAnchor({
  required double? restingHr,
  required double? maxHr,
  String? sex,
  double? age,
}) {
  if (restingHr == null || maxHr == null) return null;
  final m = ana.vo2maxEstimate(
    restingHr: restingHr,
    maxHr: maxHr,
    sex: workoutSex(sex) == 'female' ? ana.Sex.female : ana.Sex.male,
    age: age,
  );
  return m.present ? m.value : null;
}
