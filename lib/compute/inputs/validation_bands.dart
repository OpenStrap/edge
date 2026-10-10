// How far each low-resolution method lands from the 1 Hz result on the same
// days, as measured by test/lowres_validation_test.dart (PLAN §4). SYNTHETIC
// days only, so a band says how much the resolution costs, not how close
// either number is to a real body.
//
// Only rows whose 1 Hz reference is the same computation at a finer
// resolution carry a band. The sleep rows (window, stages, efficiency) do
// not: on the synthetic nights the 1 Hz reference itself sits 30 min short
// in bed and 71 min short on deep sleep against the truth the nights were
// built with, so an error against it says nothing about the device's method.
// Circadian is served as a clock time and quotes no band. The one sleep
// band is Colmi's window, measured against the synthetic truth instead
// (bed to wake as the nights were built), and its text says so.

/// `'family/row/method'` -> the band the cell's confidence text quotes: the
/// method's mean absolute error against the 1 Hz value on that family's
/// profile, in the row's own unit, rounded up. An average over days, not a
/// per-day bound: the UI words it "on average", and single days can sit
/// further off (5-min strain is outside ±1.5 on 1 day in 24). Readiness is
/// banded only as the rhr-only partial score against the same partial score
/// at 1 Hz, never against the full composite, and its text says so. The
/// validation test fails when a method's error passes its band, when it is
/// measured on fewer days than today, and when a band here has nothing
/// measured behind it. A cell with no entry shows no confidence text.
final Map<String, num> kMethodBand = {
  for (final (family, hr, rest) in const [
    ('garmin', 'hr_1min', 'device_stages'),
    ('pebble', 'hr_1min', 'device_stages'),
    ('miband234', 'hr_1min', 'device_stages'),
    ('ultrahuman', 'hr_5min', 'hr_5min'),
    ('colmi', 'hr_5min', 'device_stages'),
  ]) ...{
    // Measured MAE, 1-min / 5-min: 0.05 / 0.21 bpm.
    '$family/resting_hr/$hr': 1,
    // 0.24 / 0.46 bpm.
    '$family/nadir_dip/$hr': 1,
    // 0.02 / 0.18 bpm.
    '$family/baselines_load_illness/$hr': 1,
    // 0.15 / 0.43.
    '$family/strain/$hr': hr == 'hr_1min' ? 0.3 : 0.6,
    // 4.1 / 2.7 kcal. Not Colmi's: our estimate serves there only on a day
    // the ring stored no calories, and no low-resolution profile has such a
    // day, so its error is unmeasured and shows no band.
    if (family != 'colmi') '$family/calories/$hr': hr == 'hr_1min' ? 10 : 5,
    // 0.42 / 2.27 points.
    '$family/readiness/rhr_only_partial': hr == 'hr_1min' ? 1 : 3,
    // 0.03 / 0.06 h, off the nights the row is served from.
    '$family/sleep_debt_need_sri/$rest': 0.1,
  },
  // 26.25 min against the synthetic truth, over 24 nights: our HR-led
  // window over 5-min HR (1-min profiles 10.35, for scale). The error is in
  // the window's length against the built time in bed, not edge placement.
  'colmi/sleep_window/hr_5min': 30,
};

/// The rows whose band is measured against the synthetic truth, not the
/// 1 Hz value ([kMethodBand]).
const Set<String> kTruthBandRows = {'sleep_window'};

/// [kMethodBand] for a served cell, or null.
num? methodBand(String? family, String row, String? method) =>
    kMethodBand['$family/$row/$method'];
