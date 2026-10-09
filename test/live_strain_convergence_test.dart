// Live-session strain — pinned to the one shared method.
//
// Until this landed, three things put a number on the same 0–21 dial and
// disagreed with each other:
//   * daily strain   — Banister TRIMP -> min(21, ln(trimp+1)/ln(1.5))
//   * a live session — `strain += %HRR * 0.01` per second: uncited, uncapped,
//                      and measured 25.33 where the canonical method reads
//                      11.62 for the same hour (2.18x, and past the top of its
//                      own scale after ~50 min, which the gauge silently
//                      clamped to full)
//   * an auto-detected session — no strain written at all
//
// The live path is the one with real state, so it gets its own file: the
// per-minute folding has to be right or the gauge and the value written to
// `sessions.strain` on stop will drift apart from everything else.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/app_state.dart';

/// A full profile — every anchor the Banister score needs.
const _profile = Profile(
  ageYears: 30,
  weightKg: 75,
  heightCm: 180,
  sex: 'm',
  restingHrManual: 55,
);

// The live session's own accumulator. It is the piece with real state — the
// per-minute folding has to be right or the live gauge and the number written
// to `sessions.strain` on stop will disagree with everything else.
void main() {
  group('LiveWorkoutState — live strain rides the same method', () {
    // 187 = estimatedMaxHr(30, gen4|gen5) — the ONE ceiling since TS-03a,
    // resolved by AppState from the age and the strap and handed to the session.
    LiveWorkoutState make() => LiveWorkoutState(
          startTime: DateTime(2026, 1, 1, 9),
          targetKcal: 300,
          type: 'run',
          age: 30,
          profile: _profile,
          hrMax: 187.0,
          restingHr: 55,
          quietHrr: 0.20,
        );

    test('starts absent, not zero', () {
      expect(make().strain, isNull);
    });

    test('folds 1 Hz samples into per-minute means', () {
      final w = make();
      // 30 s at 100 then 30 s at 200, all inside minute 0.
      for (var i = 0; i < 60; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(i < 30 ? 100 : 200);
      }
      expect(w.perMinuteHr(), hasLength(1));
      expect(w.perMinuteHr().first, closeTo(150, 0.001));
    });

    test('the in-progress minute counts, so the gauge moves before 60 s', () {
      final w = make();
      for (var i = 0; i < 10; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(150);
      }
      expect(w.perMinuteHr(), hasLength(1));
      expect(w.strain, isNotNull);
      expect(w.strain, greaterThan(0));
    });

    test('an hour at 150 bpm lands on the canonical figure, not 25', () {
      final w = make();
      for (var i = 0; i < 3600; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(150);
      }
      expect(w.perMinuteHr(), hasLength(60));
      expect(w.strain, closeTo(11.62, 0.05));
      expect(w.strain, lessThanOrEqualTo(21.0));
    });

    test('abstains when the profile carries no anchors', () {
      final w = LiveWorkoutState(
        startTime: DateTime(2026, 1, 1, 9),
        targetKcal: 300,
        type: 'run',
      );
      for (var i = 0; i < 600; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(150);
      }
      // No fabricated 30 y / 60 bpm stand-ins — the gauge shows "—".
      expect(w.strain, isNull);
    });

    test('abstains until a quiet level lands, then fills the gap', () {
      final w = LiveWorkoutState(
        startTime: DateTime(2026, 1, 1, 9),
        targetKcal: 300,
        type: 'run',
        age: 30,
        profile: _profile,
        hrMax: 187.0,
        restingHr: 55,
      );
      for (var i = 0; i < 120; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(150);
      }
      // No level read yet — never the 0.20 population reference.
      expect(w.strain, isNull);
      // `_refreshNightlyRhr` fills the gap when the read lands; the next
      // sample re-scores through it.
      w.quietHrr = 0.20;
      w.elapsed = const Duration(seconds: 120);
      w.accrueHr(150);
      expect(w.strain, isNotNull);
      expect(w.strain, greaterThan(0));
    });

    test('off-skin zeros neither pollute a minute nor reset the score', () {
      final w = make();
      for (var i = 0; i < 600; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(150);
      }
      final before = w.strain;
      for (var i = 600; i < 660; i++) {
        w.elapsed = Duration(seconds: i);
        w.accrueHr(0); // dropped contact
      }
      expect(w.strain, before, reason: 'a zero sample must be ignored outright');
    });
  });
}
