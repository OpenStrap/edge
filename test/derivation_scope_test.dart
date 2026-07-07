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
}
