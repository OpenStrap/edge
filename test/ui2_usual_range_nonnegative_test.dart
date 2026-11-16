// The usual range is centre ± 1.253 × spread. For a skewed minutes metric
// (Daytime sleep: most days no nap, a few long ones) the median is 0 and the
// lower edge came out negative. Minutes can't be negative, and the edge then
// printed through axisHm as a positive duration: "Usual range 47m–25m".

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/trend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 20 days without a nap, then naps of 20–60 min; the last value is "today".
  final naps = <double>[
    for (var i = 0; i < 20; i++) 0,
    20, 45, 0, 30, 60, 0, 25, 0, 40, 0,
    35,
  ];

  test('a metric that is never negative gets a band that starts at 0', () {
    final band = usualRangeFor('nap_min', naps, null)!;
    expect(band.lo, 0);
    expect(band.hi, greaterThan(0));
    // The centre is still the median of the history, not the clamped midpoint.
    expect(band.usual, 0);
    expect(band.side(0), Side.inside);
    // Neither the band's legend nor the axis prints an impossible duration.
    expect(axisHm(band.lo), axisHm(0));
    expect(band.axis(naps, format: axisHm)!.min, greaterThanOrEqualTo(0));
  });

  test('a metric not known to be non-negative keeps its lower edge, even '
      'when its history never went below 0', () {
    final temp = <double>[
      for (var i = 0; i < 20; i++) (i.isEven ? 0.0 : 0.4),
      0.1,
    ];
    expect(usualRangeFor('skin_temp', temp, null)!.lo, lessThan(0));
    expect(usualRangeFor('dip', temp, null)!.lo, lessThan(0));
    expect(usualRangeFor('hrr', temp, null)!.lo, lessThan(0));
    expect(UsualRange.priorTo(temp)!.lo, lessThan(0));
  });

  test('non-negative load, ratio, and score metrics clamp their lower band edge at 0', () {
    final skewed = <double>[
      for (var i = 0; i < 20; i++) 0,
      0.2, 0.5, 1.0,
    ];
    for (final key in [
      'strain',
      'trimp',
      'stress',
      'efficiency',
      'lf_hf',
      'hrv_cv',
      'brv',
      'spo2',
    ]) {
      final band = usualRangeFor(key, skewed, null)!;
      expect(band.lo, 0, reason: '$key cannot be negative');
      expect(band.hi, greaterThan(0), reason: key);
      expect(band.usual, 0, reason: key);
    }
  });
}
