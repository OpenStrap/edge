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
// The live tick now RECOMPUTES from the retained series through the same
// published rates and the same gate, rather than accruing. That is the shape
// `accrueHr` already uses for strain, and it is what lets a nightly resting HR
// that lands mid-session correct the whole bout instead of only the seconds
// after it arrived.
//
// The retained series is per-SAMPLE seconds-at-each-bpm, not per-minute means.
// The first version of this fix used per-minute means and stayed wrong in three
// ways none of the original cases here could see, because they all ran a 1 Hz
// stream whose single transition landed exactly on a minute boundary:
//
//   * the gate is per sample in the re-score and was per minute-MEAN here, so a
//     minute straddling the gate went wholly to one rate;
//   * a completed minute billed a flat 60 s regardless of how many samples
//     backed it, and the minute in progress billed its SAMPLE COUNT as seconds;
//   * a contact-loss gap billed 0 s live while the re-score bills the pre-gap
//     sample for the gap, capped at 150 s.
//
// The last four cases in this file are each one of those.

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

/// Play [hr] into a live session, one sample every [stepSec] seconds.
LiveWorkoutState _run(
  List<int> hr, {
  double? restingHr = _restingHr,
  int stepSec = 1,
}) {
  final s = LiveWorkoutState(
    startTime: _startedAt,
    targetKcal: 300,
    profile: _profile,
    restingHr: restingHr,
  );
  for (var i = 0; i < hr.length; i++) {
    s.elapsed = Duration(seconds: i * stepSec);
    s.accrueHr(hr[i]);
  }
  return s;
}

/// What the substrate re-score actually says about the same stream.
///
/// Deliberately the REAL entry point rather than a hand-rolled call to
/// `estimateBoutCalories`. A stand-in only proves the live tick matches the
/// test's idea of the re-score, and it keeps on proving that after the shipping
/// estimator has moved underneath it. The property under test is agreement with
/// the shipping code, so it has to call the shipping code.
double _rescore(List<int> hr, {int stepSec = 1}) {
  final base = _startedAt.millisecondsSinceEpoch ~/ 1000;
  final s = computeManualSessionStats(
    hrTs: [for (var i = 0; i < hr.length; i++) base + i * stepSec],
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
    // two paths ever agree on a WRONG number. Keytel (male, 72 kg, 34 y) at
    // 140 bpm:
    //   -55.0969 + 0.6309*140 + 0.1988*72 + 0.2017*34
    //     = 54.4005 kJ/min / 251.04                  = 0.2167005 kcal/s
    //   Harris-Benedict resting = 1714.15 kcal/day / 86400 = 0.0198397 kcal/s
    //   300 * 0.2167005 + 300 * 0.0198397            = 70.96 kcal
    expect(live.calories, closeTo(70.96, 0.25));
  });

  test('seconds below the bout gate bill the resting rate, not the Keytel rate',
      () {
    // The defect in isolation. Ten minutes at 70 bpm is below the 93.76 gate
    // throughout, so the whole bout should cost the resting rate.
    final easy = <int>[for (var i = 0; i < 600; i++) 70];

    final live = _run(easy);

    // 600 s * 0.0198397 kcal/s = 11.90 kcal
    expect(live.calories, closeTo(11.90, 0.25));
    // The old tick billed Keytel(70) = 10.2375 kJ/min -> 0.0407804 kcal/s,
    // i.e. 24.47 kcal, more than double.
    expect(
      live.calories,
      lessThan(20.0),
      reason: 'billing the active rate at 70 bpm is the bug this test pins',
    );
  });

  test('a stream that never leaves the active zone agrees too', () {
    // The all-active case, where the gate never fires and the whole bout is
    // priced by the Keytel term alone.
    final hard = <int>[for (var i = 0; i < 600; i++) 140];

    final live = _run(hard);

    // 600 s * 0.2167005 = 130.02 kcal
    expect(live.calories, closeTo(130.02, 0.25));
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

  test('an interval that crosses the gate mid-minute splits the minute', () {
    // 30 s at 130 alternating with 30 s at 60 — the shape of any interval
    // session. Every minute has a mean of 95, which is ABOVE the 93.76 gate, so
    // scoring off minute means bills all six minutes at the active rate for
    // 130 bpm's mean. Per sample, half of every minute is resting.
    final intervals = <int>[
      for (var block = 0; block < 6; block++) ...[
        for (var i = 0; i < 30; i++) 130,
        for (var i = 0; i < 30; i++) 60,
      ],
    ];

    final live = _run(intervals);

    expect(live.calories, closeTo(_rescore(intervals), 0.25));
    // 180 s * activeKcalPerS(130) + 180 s * restingRate
    //   = 180 * 0.1915691 + 180 * 0.0198397 = 38.05 kcal
    expect(live.calories, closeTo(38.05, 0.25));
    // Gating on the minute mean (95 bpm, active, for all 360 s) says 37.30.
    // The two are only 0.75 kcal apart on this shape, because Keytel is nearly
    // linear over 60-130 bpm and the mean lands close to the split. The gap
    // widens with the swing; the sawtooth case below is where it is decisive.
    expect(
      live.calories,
      greaterThan(37.6),
      reason: 'the gate is a per-sample decision, not a per-minute one',
    );
  });

  test('a sawtooth hovering at the gate does not collapse to one side', () {
    // The worst case for minute-mean gating, and an entirely ordinary heart
    // rate: 30 s at 94 and 30 s at 93 against a 93.76 gate. Every minute mean
    // is 93.5, just under, so the whole session reads as rest.
    final sawtooth = <int>[
      for (var block = 0; block < 10; block++) ...[
        for (var i = 0; i < 30; i++) 94,
        for (var i = 0; i < 30; i++) 93,
      ],
    ];

    final live = _run(sawtooth);

    expect(live.calories, closeTo(_rescore(sawtooth), 0.25));
    // 300 s * activeKcalPerS(94) + 300 s * restingRate
    //   = 300 * 0.1010958 + 300 * 0.0198397 = 36.28 kcal
    expect(live.calories, closeTo(36.28, 0.25));
    // Minute-mean gating bills all 600 s at the resting rate: 11.90 kcal, i.e.
    // 1.19 kcal/min where the re-score says 3.63 — about 146 kcal adrift over a
    // zone-2 hour, off a stream that never looks unusual.
    expect(
      live.calories,
      greaterThan(20.0),
      reason: 'billing a 94 bpm half-minute as rest is the bug this pins',
    );
  });

  test('a contact-loss gap is billed the same way on both sides', () {
    // Two minutes of contact, a minute of nothing, two more minutes. The band
    // reports 0 for off-skin, which is not a heart rate, so it is dropped — but
    // the TIME is not. `estimateBoutCalories` sees the filtered stream and bills
    // the pre-gap sample for the gap (capped at 150 s), and the live tick has to
    // do the same or the gauge loses a minute the re-score keeps.
    final withGap = <int>[
      for (var i = 0; i < 120; i++) 140,
      for (var i = 0; i < 60; i++) 0,
      for (var i = 0; i < 120; i++) 140,
    ];

    final live = _run(withGap);

    expect(live.calories, closeTo(_rescore(withGap), 0.25));
    // 300 billed seconds at 140 bpm: 239 one-second steps, the 61 s the pre-gap
    // sample carries across the outage, and one representative second for the
    // final sample. 300 * 0.2167005 = 65.01 kcal.
    expect(live.calories, closeTo(65.01, 0.25));
  });

  test('an outage longer than the cap stops billing at the cap', () {
    // The case above leaves the 150 s cap itself untested: a 61 s gap bills the
    // same whether the bound is there or not, so it pins gap HANDLING and not
    // the bound. A strap off the wrist for three and a half minutes is what
    // separates them — the pre-gap sample is evidence about the next 150 s at
    // most, and past that the athlete may simply have stopped. Both sides have
    // to give up at the same point, or the gauge and its own re-score part
    // company by whatever the outage ran over.
    final longGap = <int>[
      for (var i = 0; i < 120; i++) 140,
      for (var i = 0; i < 200; i++) 0,
      for (var i = 0; i < 120; i++) 140,
    ];

    final live = _run(longGap);

    expect(live.calories, closeTo(_rescore(longGap), 0.25));
    // 389 billed seconds at 140 bpm, NOT the 439 seconds of wall clock: 119
    // one-second steps before the outage, 150 (not 200) carried across it, 119
    // after, and one representative second for the final sample.
    // 389 * 0.2167005 = 84.30 kcal.
    expect(live.calories, closeTo(84.30, 0.25));
  });

  test('a non-1 Hz stream bills real seconds, not sample counts', () {
    // A 5 s notify rate. The per-minute scoring billed a completed minute a flat
    // 60 s however few samples backed it, and billed the minute in progress
    // `_minuteCount` — a SAMPLE count — as if it were seconds, so the trailing
    // minute was worth 12 s.
    final sparse = <int>[
      for (var i = 0; i < 60; i++) 140,
      for (var i = 0; i < 60; i++) 70,
    ];

    final live = _run(sparse, stepSec: 5);

    expect(live.calories, closeTo(_rescore(sparse, stepSec: 5), 0.25));
    // 300 s at 140 (60 samples x 5 s) + 296 s at 70 (59 x 5 s + the final
    // sample's one representative second) = 65.01 + 5.87 = 70.88 kcal. 70 bpm
    // is below the gate, so those 296 s bill the resting rate.
    expect(live.calories, closeTo(70.88, 0.25));
  });

  test('time before the first sample is not billed', () {
    // A session started before the band delivered anything — permissions, a
    // reconnect, a cold strap. Nothing was measured for those seconds and they
    // must cost nothing; the re-score never sees them at all.
    final s = LiveWorkoutState(
      startTime: _startedAt,
      targetKcal: 300,
      profile: _profile,
      restingHr: _restingHr,
    );
    for (var i = 0; i < 60; i++) {
      s.elapsed = Duration(seconds: 45 + i);
      s.accrueHr(140);
    }

    // 60 billed seconds (59 one-second steps + the trailing second), not 105.
    expect(s.calories, closeTo(60 * 0.2167005, 0.25));
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
