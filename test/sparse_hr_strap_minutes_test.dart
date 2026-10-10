// A strap's 1 Hz session on a 5-minute wearable's day: each strap second is
// its own minute's, not spread over the next four as a ring reading is.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test("a strap's 20-minute session on a ring's day is 20 minutes, not 24",
      () {
    const t0 = 1780000000;
    const s0 = t0 + 3 * 3600, s1 = s0 + 20 * 60;
    final ts = <int>[
      for (var t = t0; t < s0; t += 300) t,
      for (var t = s0; t < s1; t++) t,
      for (var t = s1 + 600; t < t0 + 6 * 3600; t += 300) t,
    ];
    final b = deriveDayBundle(
      DayBundleInput(
        date: '2026-06-01',
        dayTsSec: ts,
        dayHr: [for (final t in ts) t >= s0 && t < s1 ? 165 : 60],
        sleepTsSec: const [],
        sleepHr: const [],
        sleepRrTsMs: const [],
        sleepRrMs: const [],
        sleepSkinTemp: const [],
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        profile: const {
          'age': 30,
          'sex': 'm',
          'weight_kg': 75,
          'height_cm': 178,
          'resting_hr': 50,
        },
        deviceFamily: 'colmi',
      ).toJson(),
    );
    final zones = (b['zones'] as Map).cast<String, int>();
    final hard = (zones['z4'] ?? 0) + (zones['z5'] ?? 0);
    expect(hard, inInclusiveRange(19, 21), reason: '$zones');
  });

  test("a ring reading just after a strap's session stands for its minutes",
      () {
    const t0 = 1780000000;
    const s0 = t0 + 3 * 3600, s1 = s0 + 20 * 60;
    // [gap] seconds after the strap's last second the ring reads 120 once,
    // then 60 every 5 minutes.
    Map<String, int> zones(int gap) {
      final ts = <int>[
        for (var t = t0; t < s0; t += 300) t,
        for (var t = s0; t < s1; t++) t,
        for (var t = s1 - 1 + gap; t < t0 + 6 * 3600; t += 300) t,
      ];
      final b = deriveDayBundle(
        DayBundleInput(
          date: '2026-06-01',
          dayTsSec: ts,
          dayHr: [
            for (final t in ts)
              t >= s0 && t < s1 ? 165 : t == s1 - 1 + gap ? 120 : 60,
          ],
          sleepTsSec: const [],
          sleepHr: const [],
          sleepRrTsMs: const [],
          sleepRrMs: const [],
          sleepSkinTemp: const [],
          sleepJson: const {},
          hypnoStages: const [],
          sleepOnsetSec: 0,
          sleepOffsetSec: 0,
          profile: const {
            'age': 30,
            'sex': 'm',
            'weight_kg': 75,
            'height_cm': 178,
            'resting_hr': 50,
          },
          deviceFamily: 'colmi',
        ).toJson(),
      );
      return (b['zones'] as Map).cast<String, int>();
    }

    final far = zones(600), near = zones(30);
    expect(near, far,
        reason: '30 s after the strap, as 10 minutes after: its 5 minutes');
  });
}
