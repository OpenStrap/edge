// The Home sleep ring's rules as a pure function of fixed inputs: default
// target flagged, stage arcs grouped Deep/REM/Light/Awake, no invented split.
//
// SLEPT   today has a scored night. The ring is that night's stages as
//         contiguous arcs grouped Deep, REM, Light, then Awake; the total
//         sweep of all stages is asleep / target, NOT capped: above a
//         full circle it is a spiral. Stage totals absent => ONE solid arc,
//         never an invented split. Sub-line percentage is asleep / target.
//
// TARGET: the learned need when there is one, otherwise the owner's explicit
// default of 8 h (5 cycles + 30 min), flagged `targetIsDefault`.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/sleep_ring_model.dart';

SleepRingModel _slept({
  num duration = 442,
  SleepStageMin? stages = const SleepStageMin(
    deep: 70,
    rem: 95,
    light: 277,
    awake: 30,
  ),
  num? need,
}) =>
    sleepRingModel(durationMin: duration, stages: stages, needMin: need);

void main() {
  group('target', () {
    test('no learned need => the 8 h default, flagged as a default', () {
      final m = _slept();
      expect(m.targetMin, 480);
      expect(m.targetIsDefault, isTrue);
      expect(kDefaultSleepTargetMin, 480);
    });

    test('a learned need is the target and is NOT flagged', () {
      final m = _slept(need: 462);
      expect(m.targetMin, 462);
      expect(m.targetIsDefault, isFalse);
    });

    test('a zero or negative need is no need at all (default, flagged)', () {
      for (final bad in [0, -30]) {
        final m = _slept(need: bad);
        expect(m.targetMin, 480, reason: 'need $bad');
        expect(m.targetIsDefault, isTrue, reason: 'need $bad');
      }
    });
  });

  group('slept', () {
    test('asleep minutes and whole-percent of the default target', () {
      final m = _slept();
      expect(m.asleepMin, 442);
      // 442 / 480 = 92.08 %
      expect(m.pct, 92);
    });

    test('percent is against the LEARNED need when there is one', () {
      // 442 / 462 = 95.67 %
      expect(_slept(need: 462).pct, 96);
    });

    test('percent above 100 is also drawn above 100: the ring is a spiral', () {
      final m = _slept(
        duration: 540,
        stages: const SleepStageMin(deep: 90, rem: 120, light: 330),
      );
      expect(m.pct, 113);
      expect(m.sweep, closeTo(540 / 480, 1e-9));
    });

    test('arcs are grouped Deep, REM, Light, Awake — in that order', () {
      final m = _slept();
      expect(
        [for (final a in m.arcs) a.kind],
        [
          SleepArcKind.deep,
          SleepArcKind.rem,
          SleepArcKind.light,
          SleepArcKind.awake,
        ],
      );
    });

    test('stage proportions divide the earned sleep sweep, including awake', () {
      final m = _slept();
      expect(m.arcs[0].fraction, closeTo(442 / 480 * 70 / 472, 1e-9));
      expect(m.arcs[1].fraction, closeTo(442 / 480 * 95 / 472, 1e-9));
      expect(m.arcs[2].fraction, closeTo(442 / 480 * 277 / 472, 1e-9));
      expect(m.arcs[3].fraction, closeTo(442 / 480 * 30 / 472, 1e-9));
    });

    test('all arcs together sweep exactly asleep / target', () {
      final m = _slept();
      final asleep = m.arcs.fold<double>(0, (s, a) => s + a.fraction);
      expect(asleep, closeTo(442 / 480, 1e-9));
    });

    test('stage totals that disagree with the duration by rounding are '
        'rescaled so the sweep still equals asleep / target', () {
      // 70 + 95 + 270 = 435, but the night's duration is 442.
      final m = _slept(
        stages: const SleepStageMin(deep: 70, rem: 95, light: 270),
      );
      final asleep = m.arcs.fold<double>(0, (s, a) => s + a.fraction);
      expect(asleep, closeTo(442 / 480, 1e-9));
      // Proportions between stages are untouched.
      expect(m.arcs[0].fraction / m.arcs[1].fraction, closeTo(70 / 95, 1e-9));
      expect(m.arcs[2].fraction / m.arcs[1].fraction, closeTo(270 / 95, 1e-9));
    });

    test('Awake is drawn after Light within the earned sleep sweep', () {
      // The 442 asleep + 60 awake staged minutes divide a 442/480-lap sweep.
      // Awake gets 60/502 of that sweep; it does not fill the remaining track.
      final m = _slept(
        stages: const SleepStageMin(
          deep: 70,
          rem: 95,
          light: 277,
          awake: 60,
        ),
      );
      expect(m.arcs.last.kind, SleepArcKind.awake);
      expect(m.sweep, closeTo(442 / 480, 1e-9));
      expect(m.arcs.last.fraction, closeTo(442 / 480 * 60 / 502, 1e-9));
    });

    test('asleep >= target: Awake still shares the earned spiral sweep',
        () {
      final m = _slept(
        duration: 540,
        stages: const SleepStageMin(
          deep: 90,
          rem: 120,
          light: 330,
          awake: 20,
        ),
      );
      expect(m.arcs.last.kind, SleepArcKind.awake);
      expect(m.arcs.last.fraction, closeTo(540 / 480 * 20 / 560, 1e-9));
      expect(m.sweep, closeTo(540 / 480, 1e-9));
      // Stage proportions divide the same sweep even beyond one lap.
      expect(m.arcs[0].fraction, closeTo(540 / 480 * 90 / 560, 1e-9));
      expect(m.arcs[1].fraction, closeTo(540 / 480 * 120 / 560, 1e-9));
      expect(m.arcs[2].fraction, closeTo(540 / 480 * 330 / 560, 1e-9));
    });

    test('no awake figure => no awake arc (not a zero-length one)', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 70, rem: 95, light: 277),
      );
      expect(
        [for (final a in m.arcs) a.kind],
        [SleepArcKind.deep, SleepArcKind.rem, SleepArcKind.light],
      );
    });

    test('NO stage totals => ONE solid arc, never an invented split', () {
      final m = _slept(stages: null);
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
      expect(m.arcs.single.fraction, closeTo(442 / 480, 1e-9));
    });

    test('a PARTIAL split (a stage missing) is also one solid arc', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 70, light: 277, awake: 30),
      );
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
      expect(m.arcs.single.fraction, closeTo(442 / 480, 1e-9));
    });

    test('stage totals that are all zero are no split either', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 0, rem: 0, light: 0, awake: 0),
      );
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
    });

    test('a solid arc is NOT capped: 600 min against 480 is 125%', () {
      final m = _slept(duration: 600, stages: null);
      expect(m.arcs.single.fraction, closeTo(600 / 480, 1e-9));
      expect(m.sweep, closeTo(600 / 480, 1e-9));
    });
  });
}
