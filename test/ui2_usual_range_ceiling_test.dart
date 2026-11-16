// The usual range is centre ± 1.253 × spread. For a percentage that sits near
// its top (sleep efficiency, SpO2) the upper edge came out above 100 and
// printed as "Usual range 97–103%": a share of a whole cannot exceed it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/trend.dart';

void main() {
  // Mostly 97–100 %, a few rougher nights; the last value is "today".
  final efficiency = <double>[
    for (var i = 0; i < 10; i++) 100,
    99, 98, 97, 96, 95, 90, 88, 85, 100, 99,
    100,
  ];

  test('a percentage of a whole gets a band that ends at 100', () {
    for (final key in ['efficiency', 'spo2']) {
      final band = usualRangeFor(key, efficiency, null)!;
      expect(band.hi, 100, reason: '$key cannot exceed 100 %');
      expect(band.lo, lessThan(100), reason: key);
      // The centre is still the median of the history.
      expect(band.usual, 100, reason: key);
      expect(band.side(100), Side.inside, reason: key);
    }
  });

  test('a metric with no ceiling keeps its upper edge', () {
    // Coefficient of variation is a percentage too, but not of a whole.
    expect(usualRangeFor('hrv_cv', efficiency, null)!.hi, greaterThan(100));
    expect(UsualRange.priorTo(efficiency)!.hi, greaterThan(100));
  });
}
