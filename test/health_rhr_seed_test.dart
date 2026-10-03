import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_rhr_seed.dart';

// The seed's two pure decisions: how a day series is built from raw points,
// and whether the seeded centre and the band's own agree. Everything else in
// the file is the health plugin.
void main() {
  group('nightlySeriesFrom', () {
    test('one value per day, newest point wins, gaps stay null', () {
      final s = nightlySeriesFrom(
        const [
          ('2026-01-01', 58),
          ('2026-01-01', 61), // later record for the same day
          ('2026-01-03', 60),
        ],
        firstDay: '2026-01-01',
        lastDay: '2026-01-04',
      );
      // A missing day is a MISSING NIGHT, not a skipped entry: the fold holds
      // on null, which is how the spread stays honest about a watch that is
      // worn intermittently.
      expect(s, [61, null, 60, null]);
    });

    test('out-of-range records never choose a day', () {
      final s = nightlySeriesFrom(
        const [('2026-01-01', 58), ('2026-01-01', 0)],
        firstDay: '2026-01-01',
        lastDay: '2026-01-01',
      );
      expect(s, [58]);
    });
  });

  test('isOwnHealthSample drops what this app wrote, on both platforms', () {
    const own = 'wtf.openstrap.edge';
    expect(isOwnHealthSample(own, 'OpenStrap', own), isTrue); // iOS
    expect(isOwnHealthSample('', own, own), isTrue); // Health Connect
    expect(isOwnHealthSample('com.apple.health.abc', 'Watch', own), isFalse);
    expect(isOwnHealthSample('', '', ''), isFalse);
  });

  group('compareSeedToBand', () {
    List<double?> nights(double v, int n) => [for (var i = 0; i < n; i++) v];

    test('no verdict before the band has 14 nights of its own', () {
      expect(
        compareSeedToBand(seedBaseline: 58, bandNightlyRhr: nights(58, 5)),
        isNull,
      );
      // 30 unworn nights are not 14 measured ones — a missing night must not
      // count toward the gate.
      expect(
        compareSeedToBand(
          seedBaseline: 58,
          bandNightlyRhr: List<double?>.filled(30, null),
        ),
        isNull,
      );
    });

    test('an empty band history is no verdict, not agreement', () {
      expect(
        compareSeedToBand(seedBaseline: 58, bandNightlyRhr: const []),
        isNull,
      );
    });

    test('a seed that matches the band agrees', () {
      final c = compareSeedToBand(
        seedBaseline: 58,
        bandNightlyRhr: nights(58, 30),
      )!;
      expect(c.bandNights, 30);
      expect(c.disagrees, isFalse);
      expect(c.deltaBpm.abs(), lessThan(0.5));
    });

    test('a phone reading systematically higher is a liability, and says so',
        () {
      // A chest-strap-free wrist watch reading 10 bpm above the band is not the
      // same person's resting heart rate on the same scale. The spread floor is
      // 2 bpm, so this is well past 2 sigma.
      final c = compareSeedToBand(
        seedBaseline: 70,
        bandNightlyRhr: nights(58, 30),
      )!;
      expect(c.disagrees, isTrue);
      expect(c.z, greaterThan(kSeedDisagreementZ));
      expect(c.deltaBpm, closeTo(12, 1));
    });
  });
}
