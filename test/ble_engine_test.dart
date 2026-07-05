import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';

void main() {
  group('historical burst packet accounting', () {
    test('counts ordinary historical revisions and extended revisions', () {
      final count = countHistoricalBurstPackets(
        dataPacketCountsByRevision: const {24: 30, 10: 5},
        revision16Count: 2,
        revision19Count: 3,
        revision22Count: 4,
        revision25Count: 6,
        revision26Count: 7,
      );
      expect(count, 57);
    });

    test('traffic count includes historical packets plus side traffic', () {
      final historical = countHistoricalBurstPackets(
        dataPacketCountsByRevision: const {24: 30},
      );
      final traffic = countBurstTrafficPackets(
        dataPacketCountsByRevision: const {24: 30},
        consoleCount: 17,
        eventCount: 5,
        unknownCount: 2,
      );

      expect(historical, 30);
      expect(traffic, 54);
      expect(historical, isNot(traffic));
    });

    test(
      'whoop history-end expected count matches transport-envelope traffic, not just stored historical records',
      () {
        final historical = countHistoricalBurstPackets(
          dataPacketCountsByRevision: const {24: 30},
        );
        final traffic = countBurstTrafficPackets(
          dataPacketCountsByRevision: const {24: 30},
          consoleCount: 17,
          eventCount: 2,
        );

        expect(historical, 30);
        expect(traffic, 49);
        expect(traffic, isNot(historical));
      },
    );

    test(
      'log-shaped burst from device validates on traffic count even when only a subset are persisted historical rows',
      () {
        final historical = countHistoricalBurstPackets(
          dataPacketCountsByRevision: const {24: 15},
        );
        final traffic = countBurstTrafficPackets(
          dataPacketCountsByRevision: const {24: 15},
          eventCount: 2,
          consoleCount: 37,
        );

        expect(historical, 15);
        expect(traffic, 54);
      },
    );
  });

  group('burst packet count validation (dropped-record carve-out)', () {
    test('matches when nothing was gate-rejected', () {
      expect(
        burstPacketCountMatches(
          expectedPacketCount: 26,
          actualBurstPacketCount: 26,
          droppedThisBurst: 0,
        ),
        isTrue,
      );
    });

    test(
      'a real mismatch (band reports more than we saw at all) still fails',
      () {
        expect(
          burstPacketCountMatches(
            expectedPacketCount: 50,
            actualBurstPacketCount: 26,
            droppedThisBurst: 0,
          ),
          isFalse,
        );
      },
    );

    test(
      'matches once gate-rejected (stale-clock block) records are added '
      'back in — the exact shape of the real bug: expected=50, only 26 '
      'passed the plausibility gate, 24 were legitimately dropped',
      () {
        expect(
          burstPacketCountMatches(
            expectedPacketCount: 50,
            actualBurstPacketCount: 26,
            droppedThisBurst: 24,
          ),
          isTrue,
        );
      },
    );

    test('does not over-forgive — dropped count must exactly close the gap',
        () {
      expect(
        burstPacketCountMatches(
          expectedPacketCount: 50,
          actualBurstPacketCount: 26,
          droppedThisBurst: 10, // leaves a real 14-packet gap unexplained
        ),
        isFalse,
      );
    });
  });

  group('history-end settle streak', () {
    test('resets while queue is not empty', () {
      final streak = nextBurstStablePollStreak(
        queueEmpty: false,
        currentCount: 79,
        previousCount: 79,
        stableStreak: 2,
      );

      expect(streak, 0);
    });

    test('increments only when queue is empty and count is unchanged', () {
      final streak = nextBurstStablePollStreak(
        queueEmpty: true,
        currentCount: 79,
        previousCount: 79,
        stableStreak: 1,
      );

      expect(streak, 2);
    });

    test('resets when traffic count changes between polls', () {
      final streak = nextBurstStablePollStreak(
        queueEmpty: true,
        currentCount: 80,
        previousCount: 79,
        stableStreak: 2,
      );

      expect(streak, 0);
    });
  });

  group('maintenance traffic gating', () {
    test('maintenance traffic is paused while offload is active', () {
      expect(shouldPauseMaintenanceTraffic(offloadActive: true), isTrue);
    });

    test('maintenance traffic runs when offload is inactive', () {
      expect(shouldPauseMaintenanceTraffic(offloadActive: false), isFalse);
    });
  });
}
