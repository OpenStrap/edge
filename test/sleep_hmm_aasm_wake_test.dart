import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';

Map<String, dynamic> epoch(double hr, double rmssd, {double enmo = 0.0, double skinTemp = 0.0}) =>
    {'hr': hr, 'rmssd': rmssd, 'enmo': enmo, 'skin_temp': skinTemp};

SleepStageAnalyzer baselined() {
  final a = SleepStageAnalyzer();
  a.computeBaseline(List.generate(7200, (_) => epoch(55, 45, enmo: 0.01, skinTemp: 3350)));
  return a;
}

/// Mirror of the AASM 15 s minimum-wake-run rule applied in _hmmRestage.
List<String> applyAasmWakeRule(List<String> labels, {int minWakeRunSec = 15}) {
  final merged = [...labels];
  var i = 0;
  while (i < merged.length) {
    if (merged[i] != 'wake') {
      i++;
      continue;
    }
    var j = i;
    while (j < merged.length && merged[j] == 'wake') {
      j++;
    }
    if (j - i < minWakeRunSec) {
      final surrounding = i > 0 ? merged[i - 1] : 'light';
      for (var k = i; k < j; k++) {
        merged[k] = surrounding == 'unobserved' ? 'light' : surrounding;
      }
    }
    i = j;
  }
  return merged;
}

void main() {
  test('AASM: short wake run (<15 s) is an arousal, reverts to sleep stage', () {
    // 10 s of wake between deep phases must NOT stay wake (AASM: arousal
    // >=3 s but < half a 30 s epoch is not stage W).
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)), // deep
      ...List.generate(10, (_) => epoch(70, 25, enmo: 0.3, skinTemp: 3450)),  // brief arousal
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)), // deep
    ];
    final states = a.viterbiDecode(night);
    final labels = states.map((s) => switch (s) {
      SleepState.wake => 'wake',
      SleepState.nremLight => 'light',
      SleepState.nremDeep => 'deep',
      SleepState.rem => 'rem',
    }).toList();
    final cleaned = applyAasmWakeRule(labels);
    expect(cleaned.sublist(30, 40).where((l) => l == 'wake').length, lessThan(10),
        reason: 'a 10 s wake burst is an arousal, not wake');
  });

  test('AASM: long wake run (>=15 s) stays wake', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)),
      ...List.generate(60, (_) => epoch(85, 15, enmo: 0.4, skinTemp: 3500)),  // real awakening
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    final labels = states.map((s) => switch (s) {
      SleepState.wake => 'wake',
      SleepState.nremLight => 'light',
      SleepState.nremDeep => 'deep',
      SleepState.rem => 'rem',
    }).toList();
    final cleaned = applyAasmWakeRule(labels);
    expect(cleaned.sublist(30, 90).where((l) => l == 'wake').length, greaterThan(30),
        reason: 'a sustained awakening must remain wake (counts to WASO)');
  });

  test('AASM: staging continues after wake — no restart (sleep resumes)', () {
    final a = baselined();
    final night = <Map<String, dynamic>>[
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)),
      ...List.generate(30, (_) => epoch(85, 15, enmo: 0.4, skinTemp: 3500)),
      ...List.generate(30, (_) => epoch(53, 50, enmo: 0.005, skinTemp: 3350)),
    ];
    final states = a.viterbiDecode(night);
    // After the wake block the decoder resumes sleep (via light, wake->deep is
    // a 0.5% transition) instead of staying latched in wake.
    expect(states[75], isNot(SleepState.wake));
  });
}
