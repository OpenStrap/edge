// Smart Wake Window — the "is right now, inside an already-chosen wake
// window, a reasonable moment to buzz" check.
//
// This is deliberately NOT sleep staging. Real staging
// (analytics/lib/src/onehz/sleep/cardio_stager.dart) needs a whole night to
// build its own baselines and only runs offline, after the fact. This runs
// live, every keep-alive tick, on whatever `decoded_onehz` already has.
//
// ponytail: a single-window HR-arousal + no-big-movement heuristic. Ceiling:
// no REM/deep distinction, no wake rejection beyond the motion cap, and it
// says nothing at all (returns false) when either window is thin. Upgrade
// path: once there is a live per-epoch feed, run cardioStager's actual
// classifier here instead of this heuristic.
//
// Safety note (this is the load-bearing part): nothing in this file, or in
// any caller of it, ever disarms or reschedules the band's own SET_ALARM.
// This can only ever trigger an EARLY extra buzz (see AppState._checkSmartWake
// / engine.runAlarm); the real fallback alarm the band is already holding
// fires at the window's end regardless of what this heuristic decides, on
// the band's own clock, independent of the phone's BLE link, the app process,
// or this file existing at all.

import 'dart:math' as math;

/// One second of the signal this reads: HR (bpm) + the raw accel vector
/// `decoded_onehz` already stores (roughly unit-magnitude at rest, in g).
class SmartWakeSample {
  final double hr;
  final double ax, ay, az;
  const SmartWakeSample(this.hr, this.ax, this.ay, this.az);

  factory SmartWakeSample.fromRow(Map<String, Object?> row) => SmartWakeSample(
        (row['hr'] as num).toDouble(),
        (row['ax'] as num).toDouble(),
        (row['ay'] as num).toDouble(),
        (row['az'] as num).toDouble(),
      );
}

/// True when the last few minutes show a textbook lightening-sleep signature
/// — heart rate elevated above tonight's own resting baseline — WITHOUT the
/// hard movement that would mean the person is already awake and moving.
///
/// Never guesses on a thin window: returns false whenever [baseline] or
/// [recent] is shorter than its minimum sample count, which is the same as
/// "no light sleep detected" — the caller's fallback path (fire at window end
/// regardless) is what actually protects the user, not this function
/// returning true.
bool likelyLightSleep({
  required List<SmartWakeSample> baseline,
  required List<SmartWakeSample> recent,
  double hrArousalBpm = 4,
  double motionCeilingG = 0.08,
  int minBaselineSamples = 30,
  int minRecentSamples = 30,
}) {
  if (baseline.length < minBaselineSamples ||
      recent.length < minRecentSamples) {
    return false;
  }
  final baseHr = _median([for (final s in baseline) s.hr]);
  final recentHr = _mean([for (final s in recent) s.hr]);
  final recentMotion = _mean([for (final s in recent) _enmo(s)]);
  return recentHr >= baseHr + hrArousalBpm && recentMotion < motionCeilingG;
}

double _enmo(SmartWakeSample s) =>
    (math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az) - 1.0).abs();

double _mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

double _median(List<double> xs) {
  final sorted = [...xs]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}
