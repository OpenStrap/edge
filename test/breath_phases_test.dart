// The phase engine shared by paced breathing and the interval timer.
//
// A phase is a pure function of elapsed time, so everything interesting can be
// asserted without a clock: boundaries land on the right side, holds stay
// still, and a malformed pattern returns nothing rather than dividing by zero
// in a per-frame call.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/stress/breath_phases.dart';

void main() {
  final box = kBreathPatternsByKey['box']!;
  final resonance = kBreathPatternsByKey['resonance']!;

  group('the pattern table', () {
    test('keys are unique and every pattern has real phases', () {
      final keys = kBreathPatterns.map((p) => p.key).toList();
      expect(keys.toSet().length, keys.length);
      for (final p in kBreathPatterns) {
        expect(p.phases, isNotEmpty, reason: p.key);
        expect(p.cycleSeconds, greaterThan(0), reason: p.key);
        for (final ph in p.phases) {
          expect(ph.seconds, greaterThan(0), reason: '${p.key} has a 0 phase');
        }
      }
    });

    test('only resonance carries a coherence score', () {
      // Coherence measures oscillation AT THE PACED FREQUENCY, which is what
      // resonance work is for. Box breathing and 4-7-8 are trying to do
      // something else, and scoring them against it grades them on someone
      // else's exam.
      final rated = kBreathPatterns.where((p) => p.coherenceRated);
      expect(rated.map((p) => p.key), ['resonance']);
    });

    test('resonance is still the ~5.5 breaths a minute it always was', () {
      expect(resonance.rate, closeTo(5.5, 0.05));
      expect(resonance.pacedHz, closeTo(1 / 10.9, 1e-6));
    });

    test('box is symmetric and a minute long every four breaths', () {
      expect(box.cycleSeconds, 16);
      expect(box.rate, closeTo(3.75, 1e-9));
    });
  });

  group('phaseAt', () {
    test('walks the phases in order', () {
      expect(
        phaseAt(box, const Duration(seconds: 1))!.phase.kind,
        BreathPhaseKind.inhale,
      );
      expect(
        phaseAt(box, const Duration(seconds: 5))!.phase.kind,
        BreathPhaseKind.holdIn,
      );
      expect(
        phaseAt(box, const Duration(seconds: 9))!.phase.kind,
        BreathPhaseKind.exhale,
      );
      expect(
        phaseAt(box, const Duration(seconds: 13))!.phase.kind,
        BreathPhaseKind.holdOut,
      );
    });

    test('a boundary belongs to the phase it starts', () {
      // Off by one here means the strap buzzes a beat late every cycle.
      expect(
        phaseAt(box, const Duration(seconds: 4))!.phase.kind,
        BreathPhaseKind.holdIn,
      );
      expect(
        phaseAt(box, const Duration(milliseconds: 3999))!.phase.kind,
        BreathPhaseKind.inhale,
      );
    });

    test('repeats, and reports which cycle', () {
      final first = phaseAt(box, const Duration(seconds: 1))!;
      final third = phaseAt(box, const Duration(seconds: 33))!;
      expect(third.phase.kind, first.phase.kind);
      expect(first.cycle, 0);
      expect(third.cycle, 2);
    });

    test('progress runs 0 to 1 within a phase', () {
      expect(phaseAt(box, Duration.zero)!.progress, 0);
      expect(
        phaseAt(box, const Duration(seconds: 2))!.progress,
        closeTo(0.5, 1e-9),
      );
      expect(
        phaseAt(box, const Duration(milliseconds: 3999))!.progress,
        closeTo(1.0, 0.001),
      );
    });

    test('a negative elapsed returns nothing rather than a wrong phase', () {
      expect(phaseAt(box, const Duration(seconds: -1)), isNull);
    });

    test('a degenerate pattern returns null instead of dividing by zero', () {
      // This runs every frame, so a malformed pattern must not crash the
      // screen.
      const empty = BreathPattern(
        key: 'empty',
        label: 'Empty',
        description: '',
        phases: [],
      );
      expect(phaseAt(empty, const Duration(seconds: 1)), isNull);
    });
  });

  group('phase presentation', () {
    test('holds are still, so the animation stops asking you to breathe', () {
      expect(BreathPhaseKind.holdIn.isHold, isTrue);
      expect(BreathPhaseKind.holdOut.isHold, isTrue);
      expect(BreathPhaseKind.inhale.isHold, isFalse);
      expect(BreathPhaseKind.holdIn.targetScale,
          BreathPhaseKind.inhale.targetScale);
      expect(BreathPhaseKind.holdOut.targetScale,
          BreathPhaseKind.exhale.targetScale);
    });

    test('both holds read as "Hold" without saying which', () {
      expect(BreathPhaseKind.holdIn.label, 'Hold');
      expect(BreathPhaseKind.holdOut.label, 'Hold');
    });
  });

  group('interval timer on the same engine', () {
    test('work and rest alternate', () {
      final p = intervalPattern(
        work: const Duration(minutes: 3),
        rest: const Duration(minutes: 1),
      );
      expect(p.cycleSeconds, 240);
      expect(
        phaseAt(p, const Duration(minutes: 1))!.phase.kind,
        BreathPhaseKind.work,
      );
      expect(
        phaseAt(p, const Duration(minutes: 3, seconds: 30))!.phase.kind,
        BreathPhaseKind.rest,
      );
      expect(
        phaseAt(p, const Duration(minutes: 4, seconds: 1))!.phase.kind,
        BreathPhaseKind.work,
      );
    });

    test('no rest means continuous work rounds', () {
      final p = intervalPattern(
        work: const Duration(seconds: 30),
        rest: Duration.zero,
      );
      expect(p.phases, hasLength(1));
      expect(
        phaseAt(p, const Duration(seconds: 45))!.phase.kind,
        BreathPhaseKind.work,
      );
      expect(phaseAt(p, const Duration(seconds: 45))!.cycle, 1);
    });
  });

  group('the screen default is the table entry, not a copy', () {
    test('resonance is first, so a default of kBreathPatterns.first is it', () {
      // The calm screen defaults to `kBreathPatterns.first`. It used to carry
      // its own copy of the resonance phases, which could drift on any edit
      // here and shipped an empty description that rendered as a blank line.
      expect(kBreathPatterns.first.key, 'resonance');
      expect(kBreathPatterns.first.description, isNotEmpty);
    });

    test('every pattern has a description to show', () {
      for (final p in kBreathPatterns) {
        expect(p.description, isNotEmpty, reason: p.key);
      }
    });
  });

  group('sessionEnd', () {
    test('is null for an open-ended session', () {
      expect(sessionEnd(box, null), isNull);
      expect(sessionEnd(box, 0), isNull);
    });

    test('is a whole number of cycles', () {
      expect(sessionEnd(box, 4), const Duration(seconds: 64));
      expect(
        sessionEnd(resonance, 5)!.inMilliseconds,
        (resonance.cycleSeconds * 5 * 1000).round(),
      );
    });
  });
}
