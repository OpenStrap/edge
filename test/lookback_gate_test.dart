// Gate-logic tests for Today's Lookback card (#140): it should only appear once
// there's a meaningful span of collected data (~a full day), never on first run
// with minutes of data where the "Your day" view is empty and misleading.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui/today/today_screen.dart'
    show kLookbackMinDataHours, shouldShowLookback;

void main() {
  group('shouldShowLookback (Today lookback data-span gate)', () {
    test('hidden when no data has been collected yet', () {
      expect(shouldShowLookback(null), isFalse);
    });

    test('hidden with only minutes of data (first run)', () {
      expect(shouldShowLookback(0), isFalse);
      expect(shouldShowLookback(0.25), isFalse); // 15 minutes
      expect(shouldShowLookback(6), isFalse);
    });

    test('hidden just below the threshold', () {
      expect(shouldShowLookback(kLookbackMinDataHours - 0.1), isFalse);
    });

    test('shown at and above the threshold', () {
      expect(shouldShowLookback(kLookbackMinDataHours), isTrue);
      expect(shouldShowLookback(24), isTrue);
      expect(shouldShowLookback(72), isTrue);
    });

    test('threshold sits in the documented ~18–24h band', () {
      expect(kLookbackMinDataHours, greaterThanOrEqualTo(18));
      expect(kLookbackMinDataHours, lessThanOrEqualTo(24));
    });
  });
}
