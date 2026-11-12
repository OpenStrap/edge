// DEMO FIXTURES (review tooling): the data the review renders (GuideStepView,
// test/support/guide_view.dart) give the REAL screens. Test-only: the shipped
// app never renders a guide on demo data; live guides (lib/ui2/guides) walk the
// user's own screens. Handed to the screens' `data:` parameter and never
// written to the DB.
//
// One fictional user, one believable day: a scored night, a moderate-to-hard
// day (strain 9.4 of 21) with the heart-rate zones filled, WHOOP-style numbers.

import 'package:openstrap_edge/data/day_label.dart' show todayLabel;
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart' show DayStrainData;
import 'package:openstrap_edge/ui2/activity/zones.dart' show ZonesData;
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show HomeData;

/// A measured value the screens treat as a real reading (non-empty: a value
/// and a confidence above zero).
Metric _reading(num value, {String? unit}) =>
    Metric(value: value, unit: unit, confidence: .9, tier: MetricTier.high);

/// Today's local date at midnight.
DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

abstract final class GuideDemo {
  /// Today, all three rings scored (strain visible): recovery 72, strain 9.4,
  /// sleep 7 h of an 8 h need.
  static HomeData get home => HomeData(
        dayId: todayLabel(),
        readiness: _reading(72),
        sleepMin: _reading(420),
        sleepNeedMin: _reading(480),
        strain: _reading(9.4),
        rhr: _reading(52),
        steps: _reading(6842),
        calories: _reading(1180),
        caloriesTotal: _reading(2310),
      );

  /// A curve, zone minutes with a non-zero total, a computed (not manual) set.
  static DayStrainData get dayStrain => DayStrainData(
        // Today's local date, like the Home fixture: a fixed date would make
        // the strain screen's subtitle read a date instead of "today".
        day: _today(),
        // Cumulative strain over the waking minutes 07:00-19:00, ending at the
        // day's 9.4 (a gentle ease-out, like the real curve).
        curve: [
          for (var minute = 0; minute < 1440; minute++)
            if (minute >= 420 && minute <= 1140)
              9.4 * (1 - (1 - (minute - 420) / 720) * (1 - (minute - 420) / 720))
            else
              null,
        ],
        strain: 9.4,
        zoneMin: const [212, 168, 71, 26, 6],
        maxHrUsed: 187,
        zoneSource: 'karvonen',
        zoneMaxHr: 187,
        zoneLowerBpm: const [120, 134, 147, 160, 174],
        peakHr: 171,
        wornMin: 1210,
        coveragePct: 94,
      );

  /// Five zone rows, source not 'manual' (so the link reads "Set your own").
  static ZonesData get zones => _zones('karvonen');

  /// The same zones with the user's own set saved (`source == 'manual'`): the
  /// real screen then labels the link "Edit your own zones".
  static ZonesData get zonesManual => _zones('manual');

  // Zone edges for a ceiling of 187 and a resting rate of 54 (reserve 133):
  // 54 + 133 * {.50, .60, .70, .80, .90} = 120.5, 133.8, 147.1, 160.4, 173.7,
  // rounded; the top zone ends at the ceiling.
  static ZonesData _zones(String source) => ZonesData(
        ceilingBpm: 187,
        ceilingDate: '2026-10-18',
        ceilingSession: 'Running',
        source: source,
        maxHr: 187,
        restingHr: 54,
        restingDays: 28,
        zones: const [
          (zone: 1, name: 'Warm-up', lo: 120, hi: 134),
          (zone: 2, name: 'Easy', lo: 134, hi: 147),
          (zone: 3, name: 'Aerobic', lo: 147, hi: 160),
          (zone: 4, name: 'Threshold', lo: 160, hi: 174),
          (zone: 5, name: 'Max effort', lo: 174, hi: 187),
        ],
      );
}
