// An empty zone set means zones abstained (no HR ceiling, or a cadence
// timeInZone refuses), so movement must abstain too, not serve 0.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart';

void main() {
  test('zoneMinutes abstains on an empty or missing zone set', () {
    expect(zoneMinutes({'zones': {}}), isNull);
    expect(zoneMinutes({}), isNull);
    expect(zoneMinutes({'zones': {'z1': '—'}}), isNull);
  });

  test('zoneMinutes sums a computed zone set, zeros included', () {
    expect(zoneMinutes({'zones': {'z1': 10, 'z2': 5.5}}), 15.5);
    expect(zoneMinutes({'zones': {'z1': 0, 'z2': 0}}), 0);
  });

  test('garmin movement cell is null when zones abstained', () {
    expect(kGarminColumn['movement']!.estimated!({'zones': {}}, {}), isNull);
  });
}
