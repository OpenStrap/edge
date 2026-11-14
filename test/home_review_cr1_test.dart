// Review regressions for the Home sleep ring.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/sleep_ring_model.dart';

void main() {
  test('4510399136: a need that rounds to zero uses the labelled default', () {
    for (final need in [.001, .49, double.nan, double.infinity]) {
      expect(() => sleepRingModel(durationMin: 360, needMin: need),
          returnsNormally, reason: 'invalid need $need must not crash Home');
      final m = sleepRingModel(durationMin: 360, needMin: need);
      expect(m.targetMin, 480);
      expect(m.targetIsDefault, isTrue);
      expect(m.pct, 75);
    }
    final boundary = sleepRingModel(durationMin: 1, needMin: .5);
    expect(boundary.targetMin, 1);
    expect(boundary.targetIsDefault, isFalse);
    expect(boundary.pct, 100);
  });

  test('4510399166: awake stays inside the 75 percent sleep sweep', () {
    final m = sleepRingModel(durationMin: 360, needMin: 480,
      stages: const SleepStageMin(deep: 60, rem: 90, light: 210, awake: 120));
    expect(m.pct, 75);
    expect(m.sweep, closeTo(.75, 1e-12));
    // 480 total staged minutes divide a 0.75-lap sweep: awake gets 120/480
    // of that sweep, and deep gets 60/480 of it.
    expect(m.arcs.last.kind, SleepArcKind.awake);
    expect(m.arcs.last.fraction, closeTo(.1875, 1e-12));
    expect(m.arcs.first.fraction, closeTo(.09375, 1e-12));
  });
}
