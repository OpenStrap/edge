// GEN5 HARDWARE STEPS — the strap's own pedometer, end to end.
//
// `stepMotionCounter` was decoded, stored in `decoded_onehz.step_count` and read
// back by the loader, but `Substrate` had no field for it, so derivation never
// saw it: a WHOOP 5 user with a genuine wrist pedometer got no steps at all.
//
// The counter is a CUMULATIVE u16 with no midnight reset, so every failure mode
// here is a boundary: it wraps at 65536, a reboot resets it, and the two are
// indistinguishable from the sign of the delta alone. What must never happen is
// a negative total, an absurd total, or a confident 0 on hardware that cannot
// count steps at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

/// A substrate of consecutive 1 Hz seconds carrying [counters] (`-1` = absent).
Substrate _sub(List<int> counters, {int startTs = 1_700_000_000, int step = 1}) {
  final n = counters.length;
  return Substrate(
    tsSec: [for (var i = 0; i < n; i++) startTs + i * step],
    hr: List<int>.filled(n, 60),
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0),
    ay: List<double>.filled(n, 0),
    az: List<double>.filled(n, 1),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    stepCount: counters,
  );
}

void main() {
  group('hardwareStepSpansFromCounter', () {
    test('no counter -> null, same as the total', () {
      expect(hardwareStepSpansFromCounter(_sub([-1, -1]), cumulativeCounterModulus: 65536), isNull);
    });

    test('one span per clock hour, summing to the total, reset dropped', () {
      // 10-minute records from an hour boundary. The delta closing at +3600 is
      // the second hour's; the jump to 39998 and the reset to 0 are dropped.
      // A whole LOCAL hour (spans bucket by local hour), whatever the host zone.
      final t0 = 1_699_999_200 -
          DateTime.fromMillisecondsSinceEpoch(1_699_999_200 * 1000).minute * 60;
      final s = _sub([0, 10, 20, 20, 30, 40, 50, 39998, 40000, 0, 7],
          startTs: t0, step: 600);
      final spans = hardwareStepSpansFromCounter(s, cumulativeCounterModulus: 65536)!;
      // The delta read across the hour line is its own span.
      expect([for (final x in spans) (x.startTs, x.endTs, x.steps)], [
        (t0, t0 + 3000, 40),
        (t0 + 3000, t0 + 3600, 10),
        (t0 + 4200, t0 + 6000, 9),
      ]);
      expect(spans.fold<int>(0, (a, x) => a + x.steps),
          hardwareStepsFromCounter(s, cumulativeCounterModulus: 65536));
    });
  });

  group('hardwareStepSpansFromCounter across a hole', () {
    test('a delta read across a hole does not absorb the next hour', () {
      // Last record before the hole at 08:10 (1000), records resume 09:40
      // (1100), then a 2000-step walk at 1 Hz to 09:59:59. Merged into one
      // [08:10, 09:59] span the chart would put ~960 walk steps in the 8
      // o'clock bar, where at most the 100 across the hole could have happened.
      final t810 = DateTime(2026, 6, 15, 8, 10).millisecondsSinceEpoch ~/ 1000;
      final t940 = DateTime(2026, 6, 15, 9, 40).millisecondsSinceEpoch ~/ 1000;
      const n = 1200;
      final ts = [t810, for (var i = 0; i < n; i++) t940 + i];
      final counters = [1000, for (var i = 0; i < n; i++) 1100 + i * 2000 ~/ (n - 1)];
      final s = Substrate(
        tsSec: ts,
        hr: List<int>.filled(n + 1, 60),
        rrTsMs: const [],
        rrMs: const [],
        ax: List<double>.filled(n + 1, 0),
        ay: List<double>.filled(n + 1, 0),
        az: List<double>.filled(n + 1, 1),
        spo2Red: List<int>.filled(n + 1, 0),
        spo2Ir: List<int>.filled(n + 1, 0),
        skinTemp: List<int>.filled(n + 1, 0),
        skinContact: List<int>.filled(n + 1, 0),
        stepCount: counters,
      );
      final spans = hardwareStepSpansFromCounter(s, cumulativeCounterModulus: 65536)!;
      expect([for (final x in spans) (x.startTs, x.endTs, x.steps)], [
        (t810, t940, 100),
        (t940, t940 + n - 1, 2000),
      ]);
    });
  });

  group('hardwareStepsFromCounter', () {
    test('gen4 (no counter on any record) returns NULL, not zero', () {
      // The distinction the whole feature rests on: "this hardware cannot count
      // steps" must not render as "you took no steps".
      expect(hardwareStepsFromCounter(_sub([-1, -1, -1, -1]), cumulativeCounterModulus: 65536), isNull);
      expect(hardwareStepsFromCounter(Substrate.empty, cumulativeCounterModulus: 65536), isNull);
    });

    test('a counter that never moves is a real, confident ZERO', () {
      expect(hardwareStepsFromCounter(_sub([4000, 4000, 4000]), cumulativeCounterModulus: 65536), 0);
    });

    test('sums positive deltas, not last minus first', () {
      expect(hardwareStepsFromCounter(_sub([100, 102, 105, 105, 109]), cumulativeCounterModulus: 65536), 9);
    });

    test('a u16 WRAP is recovered, not lost and never negative', () {
      // 65530 -> 3 is a 9-step delta through the wrap. Read naively it is
      // -65527, which would drive the total negative.
      final steps = hardwareStepsFromCounter(_sub([65520, 65530, 3, 6]), cumulativeCounterModulus: 65536);
      expect(steps, 10 + 9 + 3);
      expect(steps, isNonNegative);
    });

    test('a RESET contributes nothing rather than an invented jump', () {
      // Reboot mid-day: 40000 -> 0. Modulo 65536 that reads as 25536 steps in
      // one second, which fails the plausibility budget and is dropped whole.
      // The steps after the reset still count.
      expect(hardwareStepsFromCounter(_sub([39998, 40000, 0, 5, 9]), cumulativeCounterModulus: 65536), 2 + 5 + 4);
    });

    test('a reset after a LONG unsynced gap still fails the budget', () {
      // The gap is what buys budget, so it is capped: without the cap a 6-hour
      // hole would license 108000 steps and a reset would look like a wrap.
      final s = _sub([40000, 0, 4], startTs: 1_700_000_000, step: 21600);
      expect(hardwareStepsFromCounter(s, cumulativeCounterModulus: 65536), 4);
    });

    test('an implausible forward jump is dropped, not credited', () {
      // The per-step budget floors at 300 (the counter's update cadence is not
      // verified on hardware, so bursty reporting must survive); 9000 steps
      // between two 1 Hz records is a decode artefact, not a sprint.
      expect(hardwareStepsFromCounter(_sub([100, 9100, 9104]), cumulativeCounterModulus: 65536), 4);
    });

    test('records with no counter are skipped without breaking the chain', () {
      // A mixed page (some records decoded without the field) must not restart
      // the accumulation or double-count across the hole.
      expect(hardwareStepsFromCounter(_sub([10, -1, -1, 16, 18]), cumulativeCounterModulus: 65536), 8);
    });

    test('a total is never negative under any counter behaviour', () {
      final adversarial = [65535, 0, 65535, 0, 12, 3, 60000, 1, 1, 65000];
      final steps = hardwareStepsFromCounter(_sub(adversarial),
          cumulativeCounterModulus: 65536);
      expect(steps, isNotNull);
      expect(steps!, isNonNegative);
    });
  });

  group('Substrate carries the counter through slicing and JSON', () {
    test('slice keeps the counter aligned with tsSec', () {
      final s = _sub([1, 2, 3, 4, 5], startTs: 1000);
      final cut = s.slice(1002, 1004);
      expect(cut.tsSec, [1002, 1003]);
      expect(cut.stepCount, [3, 4]);
      expect(hardwareStepsFromCounter(cut, cumulativeCounterModulus: 65536), 1);
    });

    test('an absent counter round-trips as ABSENT, never as 0', () {
      final back = Substrate.fromJson(_sub([-1, -1, -1]).toJson());
      expect(back.stepCounterAt(0), isNull);
      expect(hardwareStepsFromCounter(back, cumulativeCounterModulus: 65536), isNull);
    });

    test('a present counter round-trips by value', () {
      final back = Substrate.fromJson(_sub([7, 9, 9, 20]).toJson());
      expect(back.stepCount, [7, 9, 9, 20]);
      expect(hardwareStepsFromCounter(back, cumulativeCounterModulus: 65536), 13);
    });

    test('a legacy substrate with no step array reads ABSENT everywhere', () {
      // Rows written before the field existed decode to an empty list; every
      // index must answer "absent", and slicing must not throw.
      // Not `const`: the constructor packs the double arrays into Float64Lists.
      final legacy = Substrate(
        tsSec: const [1, 2, 3],
        hr: const [60, 60, 60],
        rrTsMs: const [],
        rrMs: const [],
        ax: const [0, 0, 0],
        ay: const [0, 0, 0],
        az: const [1, 1, 1],
        spo2Red: [0, 0, 0],
        spo2Ir: [0, 0, 0],
        skinTemp: [0, 0, 0],
        skinContact: [0, 0, 0],
      );
      expect(legacy.stepCounterAt(0), isNull);
      expect(hardwareStepsFromCounter(legacy, cumulativeCounterModulus: 65536), isNull);
      expect(legacy.slice(1, 3).stepCount, isEmpty);
    });
  });

  group('hourlyHrProfile (the circadian substrate)', () {
    // Local midnight, so the hour bins land where the day model puts them.
    final midnight = DateTime(2024, 5, 1);

    List<Map<String, num>> curve(int hours, {int minutesPerHour = 60}) => [
          for (var h = 0; h < hours; h++)
            for (var m = 0; m < minutesPerHour; m++)
              {
                't': midnight
                        .add(Duration(hours: h, minutes: m))
                        .millisecondsSinceEpoch ~/
                    1000,
                'v': 50 + h,
              },
        ];

    test('a fully covered day yields 24 non-null hourly means', () {
      final p = DerivationEngine.hourlyHrProfile(curve(24));
      expect(p.length, 24);
      expect(p.where((v) => v == null), isEmpty);
      expect(p[0], 50);
      expect(p[23], 73);
    });

    test('a thinly covered hour stays NULL rather than averaging one sample', () {
      // 4 minutes is below the 5-minute floor: a single stray reading is not an
      // hourly mean, and letting it through would admit a day that should be
      // excluded from the circadian battery entirely.
      final p = DerivationEngine.hourlyHrProfile(curve(24, minutesPerHour: 4));
      expect(p.every((v) => v == null), isTrue);
    });

    test('off-skin zeros are not readings', () {
      final withZeros = [
        for (final e in curve(24)) {...e, 'v': 0},
      ];
      expect(
        DerivationEngine.hourlyHrProfile(withZeros).every((v) => v == null),
        isTrue,
      );
    });

    test('junk in, nulls out — never a throw', () {
      expect(DerivationEngine.hourlyHrProfile(null).length, 24);
      expect(DerivationEngine.hourlyHrProfile('nope').length, 24);
      expect(
        DerivationEngine.hourlyHrProfile([
          'x',
          {'t': null, 'v': 60},
          {'t': 1, 'v': null},
        ]).every((v) => v == null),
        isTrue,
      );
    });
  });
}
