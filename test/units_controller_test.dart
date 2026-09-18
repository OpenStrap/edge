// UnitsController pace formatting — regression coverage for a real user
// report: a near-zero GPS distance divided into real elapsed time produced
// an absurd "189:xx" style pace.
//
// The honest answer is NULL, not '—'. A formatter cannot know why a value is
// missing, and a bare dash rendered into a stat slot is a defect on its own —
// the callers now drop the stat instead of drawing a placeholder.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/units_controller.dart';

void main() {
  group('UnitsController pace sanity ceiling', () {
    test('formatPace answers null for an absurdly slow pace, not the raw '
        'number', () {
      // 1000 min/km — the exact class of number the bug produced.
      expect(UnitsController.formatPace(1000 * 60), isNull);
    });

    test('formatPace still shows a real, plausible pace normally', () {
      expect(UnitsController.formatPace(5 * 60 + 30), '5:30');
    });

    test('pace() returns null (never "— /km") for a near-zero distance '
        'over real elapsed time — the exact bed-jitter scenario', () {
      final u = UnitsController.seed(UnitSystem.metric);
      // 1 metre over 60 seconds — GPS noise, not a real 60 min/km pace.
      expect(u.pace(1, 60), isNull);
    });

    test('pace() returns a normal formatted pace for real distance/time', () {
      final u = UnitsController.seed(UnitSystem.metric);
      // 1 km in 5:30 → "5:30 /km".
      expect(u.pace(1000, 5 * 60 + 30), '5:30 /km');
    });

    test('paceFromSpeed() returns null consistently, never "— /km"', () {
      final u = UnitsController.seed(UnitSystem.metric);
      expect(u.paceFromSpeed(null), isNull);
      expect(u.paceFromSpeed(0), isNull);
    });
  });

  group('imperial', () {
    final u = UnitsController.seed(UnitSystem.imperial);

    test('distance converts and labels in miles', () {
      // 5 km = 3.107 mi.
      expect(u.distance(5000), '3.11 mi');
      expect(u.distanceUnit, 'mi');
    });

    test('pace is per mile, not per km', () {
      // 5:00/km over 5 km is 8:03/mi (5 min × 1.609344).
      expect(u.pace(5000, 25 * 60), '8:03 /mi');
    });

    test('speed reads mph', () {
      // 10 m/s = 22.4 mph.
      expect(u.speed(10), '22.4 mph');
    });

    test('metric is unchanged', () {
      final m = UnitsController.seed(UnitSystem.metric);
      expect(m.distance(5000), '5.00 km');
      expect(m.pace(5000, 25 * 60), '5:00 /km');
      expect(m.speed(10), '36.0 km/h');
    });
  });

  group('strength load — storage stays kg, only display/step change', () {
    test('weightUnit is kg/lb', () {
      expect(UnitsController.seed(UnitSystem.metric).weightUnit, 'kg');
      expect(UnitsController.seed(UnitSystem.imperial).weightUnit, 'lb');
    });

    test('weightValue converts a kg amount for display, metric untouched',
        () {
      final m = UnitsController.seed(UnitSystem.metric);
      final i = UnitsController.seed(UnitSystem.imperial);
      expect(m.weightValue(100), 100);
      // 100 kg = 220.46 lb.
      expect(i.weightValue(100), closeTo(220.46, 0.01));
    });

    test('loadStepKg keeps the exercise step in metric', () {
      final m = UnitsController.seed(UnitSystem.metric);
      expect(m.loadStepKg(2.5), 2.5);
      expect(m.loadStepKg(0), 0);
    });

    test('loadStepKg snaps to a clean 5 lb plate step in imperial, not a '
        'raw 2.5 kg → ~5.5 lb conversion', () {
      final i = UnitsController.seed(UnitSystem.imperial);
      final step = i.loadStepKg(2.5);
      // 5 lb in kg.
      expect(step, closeTo(2.2679618, 1e-6));
      expect(i.weightValue(step), closeTo(5.0, 1e-6));
    });

    test('loadStepKg stays 0 for bodyweight-only lifts in imperial too', () {
      expect(UnitsController.seed(UnitSystem.imperial).loadStepKg(0), 0);
    });
  });
}
