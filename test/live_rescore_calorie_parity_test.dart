// A live session and the substrate re-score of the SAME heart-rate stream must
// report the same calories.
//
// They did not. The live tick billed the raw Keytel active rate for every
// second the band delivered a heart rate, with no activity gate and no resting
// floor, while `Calories.estimateBoutCalories` (which the re-score and every
// manually logged session use) bills the Harris-Benedict RESTING rate for any
// sample below resting + 0.30 x HRR and the Keytel rate only above it. For a
// 34 y 72 kg male the two rates differ by ~2x at 70 bpm, so warm-up, rest
// between sets and cool-down were billed at roughly double, and the number on
// the live gauge did not survive its own re-score.
//
// The live tick now RECOMPUTES from the retained per-minute series through the
// same published rates and the same gate, rather than accruing. That is the
// shape `accrueHr` already uses for strain, and it is what lets a nightly
// resting HR that lands mid-session correct the whole bout instead of only the
// seconds after it arrived.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/app_state.dart';

const _profile = Profile(
  ageYears: 34,
  weightKg: 72,
  heightCm: 178,
  sex: 'm',
);
const _restingHr = 55.0;

// Tanaka HRmax = 208 - 0.7*34 = 184.2
// bout gate    = 55 + 0.30 * (184.2 - 55) = 93.76 bpm
const _hrMax = 184.2;

/// Five minutes hard, five minutes easy. 140 bpm sits above the 93.76 gate and
/// 70 bpm sits below it, so this stream exercises BOTH rates — a stream that
/// stayed above the gate throughout would have passed even before the fix,
/// because above the gate the two implementations already agreed.
final _hr = <int>[
  for (var i = 0; i < 300; i++) 140,
  for (var i = 0; i < 300; i++) 70,
];

final _startedAt = DateTime(2026, 1, 1, 7);

LiveWorkoutState _run(List<int> hr, {double? restingHr = _restingHr}) {
  final s = LiveWorkoutState(
    startTime: _startedAt,
    targetKcal: 300,
    profile: _profile,
    restingHr: restingHr,
  );
  for (var i = 0; i < hr.length; i++) {
    s.elapsed = Duration(seconds: i);
    s.accrueHr(hr[i]);
  }
  return s;
}

/// What the substrate re-score actually says about the same stream.
///
/// Deliberately the REAL entry point rather than a hand-rolled call to
/// `estimateBoutCalories`. A stand-in only proves the live tick matches the
/// test's idea of the re-score; when the fitness term was threaded in, the
/// stand-in kept passing the old model and this test correctly went red. The
/// property under test is agreement with the shipping code, so it has to call
/// the shipping code.
double _rescore(List<int> hr) {
  final base = _startedAt.millisecondsSinceEpoch ~/ 1000;
  final s = computeManualSessionStats(
    hrTs: [for (var i = 0; i < hr.length; i++) base + i],
    hrBpm: hr,
    profile: _profile,
    zoneMaxHr: _hrMax,
    restingHr: _restingHr,
  );
  return s.calories!;
}

void main() {
  test('the live figure matches the re-score of the same stream', () {
    final live = _run(_hr);

    expect(
      live.calories,
      closeTo(_rescore(_hr), 0.25),
      reason: 'the gauge must survive its own re-score',
    );

    // Pinned against the published formulas by hand, so this test fails if the
    // two paths ever agree on a WRONG number. A 55 bpm resting HR gives
    // Uth VO2max = 15.3 * 184.2/55 = 51.24, so the ACTIVE term is Keytel's
    // fitness-adjusted model:
    //   -95.7735 + 0.271*34 + 0.394*72 + 0.404*51.24 + 0.634*140
    //     = 51.270 kJ/min / 251.04                   = 0.2042539 kcal/s
    //   Harris-Benedict resting = 1714.15 kcal/day / 86400 = 0.0198397 kcal/s
    //   300 * 0.2042539 + 300 * 0.0198397            = 67.22 kcal
    expect(live.calories, closeTo(67.22, 0.25));
  });

  test('seconds below the bout gate bill the resting rate, not the Keytel rate',
      () {
    // The defect in isolation. Ten minutes at 70 bpm is below the 93.76 gate
    // throughout, so the whole bout should cost the resting rate.
    final easy = <int>[for (var i = 0; i < 600; i++) 70];

    final live = _run(easy);

    // 600 s * 0.0198397 kcal/s = 11.90 kcal
    expect(live.calories, closeTo(11.90, 0.25));
    // The old tick billed Keytel(70) = 10.2375 kJ/min -> 0.0407803 kcal/s,
    // i.e. 24.47 kcal, more than double.
    expect(
      live.calories,
      lessThan(20.0),
      reason: 'billing the active rate at 70 bpm is the bug this test pins',
    );
  });

  test('a stream that never leaves the active zone agrees too', () {
    // The all-active case, where the gate never fires and the whole bout is
    // priced by the fitness-adjusted term alone.
    final hard = <int>[for (var i = 0; i < 600; i++) 140];

    final live = _run(hard);

    // 600 s * 0.2042539 = 122.55 kcal
    expect(live.calories, closeTo(122.55, 0.25));
    expect(live.calories, closeTo(_rescore(hard), 0.25));
  });

  test('a resting HR that lands mid-session re-scores the whole bout', () {
    // The reason this recomputes instead of accruing. `restingHr` is loaded
    // asynchronously and can arrive after the session starts; an incremental
    // tally could only have corrected the seconds after it landed.
    final s = LiveWorkoutState(
      startTime: _startedAt,
      targetKcal: 300,
      profile: _profile,
      restingHr: null,
    );
    for (var i = 0; i < 300; i++) {
      s.elapsed = Duration(seconds: i);
      s.accrueHr(_hr[i]);
    }
    expect(
      s.caloriesOrNull,
      isNull,
      reason: 'the gate needs a real resting HR — the re-score refuses to '
          'guess one, so the live tick must not either',
    );

    s.restingHr = _restingHr;
    s.elapsed = const Duration(seconds: 300);
    s.accrueHr(_hr[300]);

    expect(
      s.caloriesOrNull,
      isNotNull,
      reason: 'the anchor arriving must score the seconds already banked',
    );
    expect(s.calories, greaterThan(60.0));
  });

  test('abstains for a profile without the Keytel anchors', () {
    final s = _run(_hr.take(60).toList());
    expect(s.caloriesOrNull, isNotNull);

    final unanchored = LiveWorkoutState(
      startTime: _startedAt,
      targetKcal: 300,
      profile: const Profile(weightKg: 72, sex: 'm'), // no age
      restingHr: _restingHr,
    );
    for (var i = 0; i < 60; i++) {
      unanchored.elapsed = Duration(seconds: i);
      unanchored.accrueHr(140);
    }
    expect(unanchored.caloriesOrNull, isNull);
  });
}
