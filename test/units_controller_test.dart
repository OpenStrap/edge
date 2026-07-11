// UnitsController pace formatting — regression coverage for a real user
// report: a near-zero GPS distance divided into real elapsed time produced
// an absurd "189:xx" style pace instead of an honest "—".

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/units_controller.dart';

void main() {
  group('UnitsController pace sanity ceiling', () {
    test('formatPace shows an honest — for an absurdly slow pace, not the '
        'raw number', () {
      final u = UnitsController.seed(UnitSystem.metric);
      // 1000 min/km — the exact class of number the bug produced.
      expect(u.formatPace(1000 * 60), '—');
    });

    test('formatPace still shows a real, plausible pace normally', () {
      final u = UnitsController.seed(UnitSystem.metric);
      expect(u.formatPace(5 * 60 + 30), '5:30');
    });

    test('pace() returns bare "—" (no unit suffix) for a near-zero distance '
        'over real elapsed time — the exact bed-jitter scenario', () {
      final u = UnitsController.seed(UnitSystem.metric);
      // 1 metre over 60 seconds — GPS noise, not a real 60 min/km pace.
      expect(u.pace(1, 60), '—');
    });

    test('pace() returns a normal formatted pace for real distance/time', () {
      final u = UnitsController.seed(UnitSystem.metric);
      // 1 km in 5:30 → "5:30 /km".
      expect(u.pace(1000, 5 * 60 + 30), '5:30 /km');
    });

    test('paceFromSpeed() returns bare "—" consistently, not "— /km"', () {
      final u = UnitsController.seed(UnitSystem.metric);
      expect(u.paceFromSpeed(null), '—');
      expect(u.paceFromSpeed(0), '—');
    });
  });
}
