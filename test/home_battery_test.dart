// The Home header's battery reading — same data source devices.dart uses
// (DeviceState.batteryPct/.charging), just the low-battery color threshold
// isolated as a pure function so it doesn't need a widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';

void main() {
  test('draining below the default threshold is low', () {
    expect(lowBattery(10, false), isTrue);
  });

  test('draining right at the threshold is not low (strict <)', () {
    expect(lowBattery(15, false), isFalse);
  });

  test('draining just under the threshold is low', () {
    expect(lowBattery(14, false), isTrue);
  });

  test('charging never reads as low, however drained', () {
    expect(lowBattery(5, true), isFalse);
  });
}
