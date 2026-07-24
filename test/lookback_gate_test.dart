// Gate-logic tests for Today's Lookback card (#140): it should only appear once
// there's a meaningful span of collected data (~a full day), never on first run
// with minutes of data where the "Your day" view is empty and misleading. The
// span is derived from the earliest record against a live `now`, so the card can
// cross the threshold purely by elapsed wall-clock time (no fresh data needed).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui/today/today_screen.dart'
    show kLookbackMinDataHours, shouldShowLookback;

void main() {
  group('shouldShowLookback (Today lookback data-span gate)', () {
    final now = DateTime(2026, 7, 24, 12, 0, 0);
    int secAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch ~/ 1000;

    test('hidden when no data has been collected yet', () {
      expect(shouldShowLookback(null, now: now), isFalse);
    });

    test('hidden with only minutes of data (first run)', () {
      expect(shouldShowLookback(secAgo(const Duration(minutes: 15)), now: now),
          isFalse);
      expect(shouldShowLookback(secAgo(const Duration(hours: 6)), now: now),
          isFalse);
    });

    test('hidden just below the threshold', () {
      expect(
        shouldShowLookback(
          secAgo(Duration(minutes: (kLookbackMinDataHours * 60).round() - 30)),
          now: now,
        ),
        isFalse,
      );
    });

    test('shown at and above the threshold', () {
      expect(
        shouldShowLookback(
          secAgo(Duration(minutes: (kLookbackMinDataHours * 60).round())),
          now: now,
        ),
        isTrue,
      );
      expect(shouldShowLookback(secAgo(const Duration(hours: 24)), now: now),
          isTrue);
    });

    test('crosses purely by elapsed wall-clock time (same anchor, later now)',
        () {
      // A fixed earliest record — 18h01m before the later `now`, but only 17h59m
      // before the earlier one. No new data; the gate flips solely on the clock.
      final earliest =
          DateTime(2026, 7, 24, 0, 0, 0).millisecondsSinceEpoch ~/ 1000;
      expect(
        shouldShowLookback(earliest, now: DateTime(2026, 7, 24, 17, 59, 0)),
        isFalse,
      );
      expect(
        shouldShowLookback(earliest, now: DateTime(2026, 7, 24, 18, 1, 0)),
        isTrue,
      );
    });

    test('threshold sits in the documented ~18–24h band', () {
      expect(kLookbackMinDataHours, greaterThanOrEqualTo(18));
      expect(kLookbackMinDataHours, lessThanOrEqualTo(24));
    });
  });
}
