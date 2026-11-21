import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

Map<String, dynamic> epoch(double hr, double rmssd, {double enmo = 0.0, double skinTemp = 0.0}) =>
    {'hr': hr, 'rmssd': rmssd, 'enmo': enmo, 'skin_temp': skinTemp};

SleepStageAnalyzer baselined() {
  final a = SleepStageAnalyzer();
  // 120 min opening window: calm sleep baseline, HR ~55, RMSSD ~45,
  // low motion (enmo ~0.01), skin temp ~3350 (33.5 °C).
  a.computeBaseline(List.generate(7200, (_) => epoch(55, 45, enmo: 0.01, skinTemp: 3350)));
  return a;
}

void main() {
  test('hybrid: movement-only arousal (HR barely up) is detected as wake', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
      // 60 s of tossing/turning: HR only +3, but ENMO clearly elevated.
      ...List.generate(60, (_) => epoch(58, 40, enmo: 0.25, skinTemp: 3400)),
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    final wakeDuringArousal = states.sublist(30, 90).where((s) => s == SleepState.wake).length;
    expect(wakeDuringArousal, greaterThan(20),
        reason: 'motion-only arousal should yield wake, not light');
  });

  test('hybrid: quiet sleep stays sleep even with normal HR/RMSSD', () {
    final a = baselined();
    final night = List.generate(120, (_) => epoch(56, 44, enmo: 0.008, skinTemp: 3345));
    final states = a.viterbiDecode(night);
    expect(states.where((s) => s == SleepState.wake).length, lessThan(10));
  });

  test('hybrid: high HR arousal is still wake', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
      ...List.generate(60, (_) => epoch(85, 18, enmo: 0.02, skinTemp: 3350)),
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    expect(states.sublist(30, 90).where((s) => s == SleepState.wake).length, greaterThan(20));
  });

  test('hybrid: absent ENMO (0 sentinel) is neutral, never "still"', () {
    final a = baselined();
    // enmo 0 everywhere: baseline has no motion median -> motion factor neutral.
    final night = List.generate(60, (_) => epoch(54, 46, enmo: -1.0, skinTemp: 3350)); // absent sentinel
    final states = a.viterbiDecode(night);
    expect(states.where((s) => s == SleepState.wake).length, lessThan(10),
        reason: 'absent motion must not be read as evidence either way');
  });

  test('hybrid: unusable HR falls back to motion-only evidence', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(0, 0, enmo: -1.0)),
      ...List.generate(60, (_) => epoch(0, 0, enmo: 0.3)), // moving, no HR
      ...List.generate(30, (_) => epoch(0, 0, enmo: -1.0)),
    ];
    final states = a.viterbiDecode(night);
    expect(states.sublist(30, 90).where((s) => s == SleepState.wake).length, greaterThan(20));
  });

  test('neutral: fully missing epoch (no HR/RR, absent ENMO) is uniform, not wake-biased', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
      ...List.generate(60, (_) => epoch(0, 0, enmo: -1.0)), // gap: nothing measured
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.01, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    // The gap must not drag the surrounding sleep into wake.
    expect(states.where((s) => s == SleepState.wake).length, lessThan(10),
        reason: 'a fully unmeasured stretch must stay neutral, never wake');
  });

  test('neutral: absent temp/motion do not add wake evidence (noisy-OR excludes them)', () {
    final a = baselined();
    // same HR/RMSSD, but optional sensors absent -> wake prob must not exceed
    // the case where they are present-and-calm
    final withSensors = a.viterbiDecode(List.generate(60, (_) => epoch(60, 50, enmo: 0.01, skinTemp: 3350)));
    final withoutSensors = a.viterbiDecode(List.generate(60, (_) => epoch(60, 50, enmo: -1.0, skinTemp: 0)));
    final wakeWith = withSensors.where((s) => s == SleepState.wake).length;
    final wakeWithout = withoutSensors.where((s) => s == SleepState.wake).length;
    expect(wakeWithout, lessThanOrEqualTo(wakeWith),
        reason: 'absent optional sensors must be neutral, never extra wake evidence');
  });

  test('hr-only bonus: quiet wakefulness (still, HR +20 bpm over baseline) -> wake', () {
    final a = baselined(); // baseline HR 55
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.005, skinTemp: 3350)),
      // lying still and awake: HR 75 (~1.36x), RMSSD near normal, no motion
      ...List.generate(60, (_) => epoch(75, 44, enmo: 0.002, skinTemp: 3350)),
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.005, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    expect(states.sublist(30, 90).where((s) => s == SleepState.wake).length, greaterThan(20),
        reason: 'still but clearly elevated HR must read as wake (quiet wakefulness)');
  });

  test('hr-only bonus guarded: REM-like (HR 1.22x, still, RMSSD normal) stays non-wake', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.005, skinTemp: 3350)),
      ...List.generate(60, (_) => epoch(67, 45, enmo: 0.004, skinTemp: 3350)), // REM-like HR spike, still
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.005, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    expect(states.sublist(30, 90).where((s) => s == SleepState.wake).length, lessThan(30),
        reason: 'REM-like HR with atonia must not flip to wake (REM guard)');
  });

  test('hybrid: movement still scores when the measured baseline is zero', () {
    final a = SleepStageAnalyzer();
    a.computeBaseline(List.generate(7200, (_) => epoch(55, 45, enmo: 0.0)));
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.0)),
      ...List.generate(60, (_) => epoch(58, 40, enmo: 0.30)),
      ...List.generate(30, (_) => epoch(54, 46, enmo: 0.0)),
    ];
    final states = a.viterbiDecode(night);
    expect(states.sublist(30, 90).where((s) => s == SleepState.wake).length,
        greaterThan(20));
  });

  test('hybrid: a row with no enmo key is absent (neutral), not still', () {
    final a = baselined();
    final withKey = List.generate(120, (_) => epoch(56, 44, enmo: -1.0));
    final noKey = List.generate(
        120, (_) => <String, dynamic>{'hr': 56.0, 'rmssd': 44.0});
    expect(a.viterbiDecode(noKey), a.viterbiDecode(withKey));
  });
}
