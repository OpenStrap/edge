// step_calibration.dart — pure policy for calibrating the gen5 on-chip step
// counter per (device family, wearing location) against the phone pedometer.
//
// The model is multiplicative (`corrected = rawTicks * factor`): an additive
// offset would invent steps on a still day. The factor is learned from the
// user's own phone-only days; nothing is hard-coded per placement.

/// Wearing-location codes stored in `device.wearing` (column DEFAULT 1).
/// New codes may only be appended.
abstract final class Wearing {
  static const int wrist = 1;
  static const int bicep = 2;
  static const int other = 3;

  static const Set<int> known = {wrist, bicep, other};

  /// Null for a code this build does not know; never falls back to wrist.
  static int? parse(Object? v) {
    final n = v is num ? v.toInt() : null;
    return (n != null && known.contains(n)) ? n : null;
  }
}

/// A learned factor outside this band means the reference went wrong (phone
/// in a drawer, counter reset storm), not that the counter is that far off.
const double kStepFactorMin = 0.5;
const double kStepFactorMax = 2.0;

/// Pseudo-days of factor 1.0 blended into the fit.
const double kStepFactorPriorWeight = 3.0;

/// Bump when the fit changes so old factors are ignored.
const int kStepCalibrationVersion = 1;

class StepCalibrationProfile {
  const StepCalibrationProfile({
    required this.deviceFamily,
    required this.wearing,
    required this.factor,
    required this.nDays,
    required this.version,
  });

  /// `Substrate.deviceFamily`. Per family, not per band, so a swap keeps it.
  final String deviceFamily;
  final int wearing;

  /// Clamped to [kStepFactorMin, kStepFactorMax]; 1.0 when nothing learned.
  final double factor;

  /// Admitted days behind [factor]; 0 = pure prior.
  final int nDays;
  final int version;

  static StepCalibrationProfile uncalibrated(String deviceFamily, int wearing) =>
      StepCalibrationProfile(
        deviceFamily: deviceFamily,
        wearing: wearing,
        factor: 1.0,
        nDays: 0,
        version: kStepCalibrationVersion,
      );

  /// A fitted 1.0 with days behind it is still calibrated.
  bool get isCalibrated => nDays > 0;
}

/// One day's (phone steps, counter ticks) observation.
class StepCalibrationDay {
  const StepCalibrationDay({
    required this.referenceSteps,
    required this.counterTicks,
  });

  final int referenceSteps;
  final int counterTicks;
}

/// Coarse floors that throw out days the phone or counter barely covered.
const int kStepCalMinReferenceSteps = 1000;
const int kStepCalMinCounterTicks = 300;

bool stepCalibrationDayAdmissible(StepCalibrationDay d) =>
    d.referenceSteps >= kStepCalMinReferenceSteps &&
    d.counterTicks >= kStepCalMinCounterTicks;

/// Ratio of sums over admitted days (weights each day by its evidence),
/// shrunk toward 1.0 and clamped. Uncalibrated below [minDays].
StepCalibrationProfile estimateStepCalibration(
  String deviceFamily,
  int wearing,
  List<StepCalibrationDay> days, {
  int minDays = 3,
}) {
  final admitted =
      days.where(stepCalibrationDayAdmissible).toList(growable: false);
  if (admitted.length < minDays) {
    return StepCalibrationProfile.uncalibrated(deviceFamily, wearing);
  }
  final refSum = admitted.fold<int>(0, (a, d) => a + d.referenceSteps);
  final tickSum = admitted.fold<int>(0, (a, d) => a + d.counterTicks);
  if (tickSum <= 0) {
    return StepCalibrationProfile.uncalibrated(deviceFamily, wearing);
  }
  final ratio = refSum / tickSum;
  final shrunk =
      (admitted.length * ratio + kStepFactorPriorWeight * 1.0) /
          (admitted.length + kStepFactorPriorWeight);
  final clamped = shrunk.clamp(kStepFactorMin, kStepFactorMax);
  return StepCalibrationProfile(
    deviceFamily: deviceFamily,
    wearing: wearing,
    factor: clamped,
    nDays: admitted.length,
    version: kStepCalibrationVersion,
  );
}

int applyStepCalibration(int rawTicks, StepCalibrationProfile? profile) {
  if (rawTicks <= 0 || profile == null || !profile.isCalibrated) return rawTicks;
  final corrected = (rawTicks * profile.factor).round();
  return corrected.clamp(0, (rawTicks * kStepFactorMax).ceil());
}

/// 0.9 uncalibrated (what the counter rung always published), rising with
/// learned days to a 0.98 cap: the reference is a phone, not ground truth.
double stepCounterConfidence(StepCalibrationProfile? profile) {
  if (profile == null || !profile.isCalibrated) return 0.9;
  return (0.9 + 0.08 * (profile.nDays / (profile.nDays + 4.0)))
      .clamp(0.9, 0.98);
}

/// Bundle name for a wearing code. 0 (refused) is gated out by callers.
String wearingName(int w) => switch (w) {
      Wearing.wrist => 'wrist',
      Wearing.bicep => 'bicep',
      Wearing.other => 'other',
      _ => throw ArgumentError.value(w, 'wearing', 'not a wearing code'),
    };
