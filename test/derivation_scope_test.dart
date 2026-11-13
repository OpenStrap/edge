import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  group('selectLightDeriveDays', () {
    test(
      'prioritizes today when raw has reached today and today is pending',
      () {
        final light = selectLightDeriveDays(
          rawDays: const {'2026-07-01', '2026-07-02'},
          pendingDays: const ['2026-07-01', '2026-07-02'],
          today: '2026-07-02',
        );

        expect(light.days, ['2026-07-02']);
        expect(light.reason, 'today-priority');
      },
    );

    test('falls back to latest pending day when today has no raw yet', () {
      final light = selectLightDeriveDays(
        rawDays: const {'2026-07-01'},
        pendingDays: const ['2026-06-30', '2026-07-01'],
        today: '2026-07-02',
      );

      expect(light.days, ['2026-07-01']);
      expect(light.reason, 'latest-pending');
    });

    test(
      'falls back to latest pending day when today raw exists but today is finalized',
      () {
        final light = selectLightDeriveDays(
          rawDays: const {'2026-07-01', '2026-07-02'},
          pendingDays: const ['2026-07-01'],
          today: '2026-07-02',
        );

        expect(light.days, ['2026-07-01']);
        expect(light.reason, 'latest-pending');
      },
    );
  });

  group('evaluateTzTravelGuard', () {
    const t0 = 1760000000000;
    const hour = 60 * 60 * 1000;

    test('first call seeds the baseline and does not hold', () {
      final step = evaluateTzTravelGuard(
        stored: null,
        nowOffsetMin: -300,
        nowMs: t0,
      );
      expect(step.held, isFalse);
      expect(step.write, {'offset_min': -300});
    });

    test('a DST-sized shift moves the baseline without holding', () {
      final step = evaluateTzTravelGuard(
        stored: {'offset_min': -300},
        nowOffsetMin: -240,
        nowMs: t0,
      );
      expect(step.held, isFalse);
      expect(step.write, {'offset_min': -240});
    });

    test('a 3h+ jump holds, keeps the old baseline and starts the clock', () {
      final step = evaluateTzTravelGuard(
        stored: {'offset_min': -300},
        nowOffsetMin: 0,
        nowMs: t0,
      );
      expect(step.held, isTrue);
      expect(step.settled, isFalse);
      expect(step.write, {
        'offset_min': -300,
        'away_offset_min': 0,
        'away_since_ms': t0,
      });
    });

    test('the hold settles once the new zone has stood for a day', () {
      final stored = {
        'offset_min': -300,
        'away_offset_min': 0,
        'away_since_ms': t0,
      };
      final early = evaluateTzTravelGuard(
        stored: stored,
        nowOffsetMin: 0,
        nowMs: t0 + 23 * hour,
      );
      expect(early.held, isTrue);
      expect(early.settled, isFalse);
      expect(early.write, isNull);

      final later = evaluateTzTravelGuard(
        stored: stored,
        nowOffsetMin: 0,
        nowMs: t0 + kTzTravelSettleMs,
      );
      expect(later.held, isTrue);
      expect(later.settled, isTrue);
      expect(later.write, isNull);
    });

    test('a second hop restarts the wait', () {
      final step = evaluateTzTravelGuard(
        stored: {
          'offset_min': -300,
          'away_offset_min': 0,
          'away_since_ms': t0,
        },
        nowOffsetMin: 540,
        nowMs: t0 + 30 * hour,
      );
      expect(step.held, isTrue);
      expect(step.settled, isFalse);
      expect(step.write, {
        'offset_min': -300,
        'away_offset_min': 540,
        'away_since_ms': t0 + 30 * hour,
      });
    });

    test('flying home clears the away state', () {
      final step = evaluateTzTravelGuard(
        stored: {
          'offset_min': -300,
          'away_offset_min': 0,
          'away_since_ms': t0,
        },
        nowOffsetMin: -300,
        nowMs: t0 + 5 * hour,
      );
      expect(step.held, isFalse);
      expect(step.write, {'offset_min': -300});
    });

    test('a clock that went backwards restarts the wait', () {
      final step = evaluateTzTravelGuard(
        stored: {
          'offset_min': -300,
          'away_offset_min': 0,
          'away_since_ms': t0,
        },
        nowOffsetMin: 0,
        nowMs: t0 - hour,
      );
      expect(step.settled, isFalse);
      expect(step.write?['away_since_ms'], t0 - hour);
    });
  });
}
