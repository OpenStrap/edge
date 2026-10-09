// What a band physically EMITS. Never what OpenStrap can compute from it.
//
// This is the whole reason the seam is shaped the way it is. A capability
// boolean (`supportsSpo2()`) names an OUTPUT: metric N+1 widens the interface
// and every implementation becomes a breaking change, so the blast radius of a
// new feature is the device count. That is how Gadgetbridge's
// `DeviceCoordinator` reached 1,092 lines, 168 methods and ~61 `supportsXxx()`
// booleans while its device count went 270 -> 511.
//
// A signal names an INPUT — a physical fact that was true before anyone
// conceived the metric. A Polar H10 emits RR intervals whether or not we have
// written a respiratory-rate function. Blast radius of a new metric: one
// analytics function and one card. ZERO adapters, forever.
//
// The consequence is free and it is the reason there are no UI conditionals:
// an undeclared signal produces no substrate column, so the metric returns
// absent and the card deletes itself through the absence contract that already
// exists.
//
// DO NOT add a member for something we compute. `readiness`, `sleepScore` and
// `hrv` are outputs. If you are about to add one, you want a metric, not a
// signal.
library;

/// The eight raw-signal input classes (I1-I8 in `ADDING_A_DEVICE.md`), the
/// canonical device-reported inputs, and the one non-raw class a band can
/// offer.
enum InputSignal {
  /// I1 — beat-to-beat intervals. The single most valuable thing a band can
  /// emit: nine analytics files take interval lists directly, so HRV, stress
  /// and respiration light up with no further work.
  rrIntervals,

  /// I2 — dense heart rate, roughly one reading per second.
  hr1Hz,

  /// I3 — heart rate at a coarser or irregular cadence. Declare the real
  /// cadence; `sampleCadenceSeconds()` measures it and metrics that cannot be
  /// supported at that rate ABSTAIN rather than stretch a window.
  hrSparse,

  /// I4 — tri-axial acceleration at ~1 Hz. Sleep staging and wear detection.
  accel1Hz,

  /// I5 — high-rate acceleration (~100 Hz). The only path to a real step
  /// count. NOTE: the sustained-magnitude accel bound is derived for 1 Hz
  /// vectors and is INVALID here — re-derive it before persisting one.
  accelHighRate,

  /// I6 — raw green PPG ADC counts.
  ppgGreen,

  /// I7 — raw red + infrared PPG ADC counts. Relative SpO2 only; an absolute
  /// saturation is a calibration claim no adapter may make.
  ppgRedIr,

  /// I8 — relative skin-temperature ADC counts.
  skinTempRaw,

  // ── Canonical device-reported inputs ─────────────────────────────────────
  // What a wearable without raw channels hands us, each a physical fact about
  // the data it stores, never a metric of ours. The declared Duration is how
  // finely the device stores it; Duration.zero means variable-length periods
  // (a hypnogram) or a cadence the device does not state.

  /// Pedometer counts the device itself made.
  steps,

  /// Skin temperature in absolute degrees Celsius (not an ADC count; that is
  /// [skinTempRaw]).
  skinTempC,

  /// The device's own movement/activity value per record.
  activityLevel,

  /// The device's own HRV figure (its RMSSD or equivalent). Shown as the
  /// device's value; never an input to our HRV.
  deviceHrv,

  /// The device's own sleep stages.
  deviceStages,

  /// The device's own respiratory rate.
  deviceResp,

  /// The device's own SpO2 figure. Shown as the device's value.
  deviceSpo2,

  /// The device's own stress figure. Shown as the device's value.
  deviceStress,

  /// NOT raw. Numbers the band computed itself — its RMSSD, its sleep score.
  /// These land in `observation`, are attributed to the vendor, and are never
  /// an input to one of our derivations and never enter a baseline.
  vendorScalars,

  // There is deliberately NO `ecg` / `ppgWaveform` member. `decoded_onehz` is
  // one row per second and raw prunes at `rawRetentionDays`, so a waveform has
  // nowhere to live. Adding the member before the store exists would let an
  // adapter declare a capability with nothing behind it — see
  // ADDING_A_DEVICE.md §5.
}

/// The signals a derive resolves by priority (`_resolveOwnership`), so the
/// only ones a user can rank. Every other member is served beside ours or
/// summed (steps), never arbitrated.
const Set<InputSignal> kRankedSignals = {
  InputSignal.hr1Hz,
  InputSignal.rrIntervals,
  InputSignal.accel1Hz,
  InputSignal.ppgRedIr,
  InputSignal.skinTempRaw,
  InputSignal.hrSparse,
};
