import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

void main() {
  test("tonight's sleep begun before midnight is not counted as active", () {
    // Two hours of restless wrist: the z-angle flips every second.
    const n = 7200, t0 = 1_700_000_000;
    final s = Substrate(
      tsSec: [for (var i = 0; i < n; i++) t0 + i],
      hr: List<int>.filled(n, 60),
      rrTsMs: const [],
      rrMs: const [],
      ax: [for (var i = 0; i < n; i++) i.isEven ? 0.0 : 0.5],
      ay: List<double>.filled(n, 0.0),
      az: [for (var i = 0; i < n; i++) i.isEven ? 1.0 : 0.85],
      spo2Red: List<int>.filled(n, 0),
      spo2Ir: List<int>.filled(n, 0),
      skinTemp: List<int>.filled(n, 0),
      skinContact: List<int>.filled(n, 0),
    );
    final all = DerivationEngine.debugActiveMinutes(s, 0, 0)!;
    expect(all, greaterThan(100));
    // Tonight's sleep starts an hour in: only the first hour is waking.
    expect(
        DerivationEngine.debugActiveMinutes(s, 0, 0,
            tonightSleepOnsetSec: t0 + 3600),
        lessThanOrEqualTo(61));
  });
}
