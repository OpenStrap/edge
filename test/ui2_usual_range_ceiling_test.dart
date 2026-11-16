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

  test('the chart axis never pads a capped band past 100', () {
    // Wide enough that one band-width of headroom would pass 100.
    final rough = <double>[
      for (var i = 0; i < 8; i++) 100,
      95, 90, 85, 80, 75, 98, 92, 88,
      100,
    ];
    final band = usualRangeFor('efficiency', rough, null)!;
    expect(band.hi, 100);
    expect(band.axis(rough)!.max, lessThanOrEqualTo(100));
    // An uncapped band still gets its headroom.
    expect(UsualRange.priorTo(rough)!.axis(rough)!.max, greaterThan(100));
  });

  test('the axis stays under the ceiling after it rounds to whole steps', () {
    // Seven nights at 98 and seven at 100: the band is about 97.7 to 100, and
    // with no floor the rounded axis used to come back as 95 to 105. This case
    // is the one `floor: 0` hides.
    // Fourteen nights of history, then today.
    final steady = <double>[for (var i = 0; i < 7; i++) ...[98, 100], 100];
    final band = usualRangeFor('efficiency', steady, null)!;
    expect(band.hi, 100);
    final axis = band.axis([100])!;
    expect(axis.max, lessThanOrEqualTo(100));
    expect(axis.min, lessThanOrEqualTo(band.lo));
    for (final v in axis.tickValues) {
      expect(v, v.roundToDouble(), reason: 'gridline $v needs a whole label');
    }
    // Data above the ceiling is never cropped.
    expect(band.axis([104])!.max, greaterThanOrEqualTo(104));
  });

  test('a share of a whole never starts below 0', () {
    final spread = <double>[
      for (var i = 0; i < 8; i++) 2,
      90, 5, 80, 1, 70, 3, 60, 4,
      50,
    ];
    expect(UsualRange.priorTo(spread)!.lo, lessThan(0));
    expect(usualRangeFor('efficiency', spread, null)!.lo, 0);
  });

  test('a metric with no ceiling keeps its upper edge', () {
    // Coefficient of variation is a percentage too, but not of a whole.
    expect(usualRangeFor('hrv_cv', efficiency, null)!.hi, greaterThan(100));
    expect(UsualRange.priorTo(efficiency)!.hi, greaterThan(100));
  });
}
