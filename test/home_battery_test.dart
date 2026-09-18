// The Home header's battery reading — same data source devices.dart uses
// (DeviceState.batteryPct/.charging), just the low-battery color threshold
// isolated as a pure function so it doesn't need a widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';

void main() {
  test('draining below the default threshold is low', () {
    expect(lowBattery(10, false), isTrue);
  });

  test('draining right at the threshold is low', () {
    expect(lowBattery(15, false), isTrue);
  });

  test('draining above the threshold is not low', () {
    expect(lowBattery(16, false), isFalse);
  });

  test('charging never reads as low, however drained', () {
    expect(lowBattery(5, true), isFalse);
  });
}
