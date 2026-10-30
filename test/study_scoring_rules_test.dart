// The small scoring rules: a day's strain floored at its sessions, the resting
// HR fallback for a day with no night, the HR-led fallback night gate, and the
// raw-free cleanup of naps that were the next night.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/nap_overlap_cleanup.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/substrate.dart';

void main() {
  test('day strain is never below a finished session in it', () {
    final s = [
      {'status': 'done', 'strain': 8.4},
      {'status': 'live', 'strain': 15.0},
      {'status': 'done', 'strain': 12.0, 'private': 1},
    ];
    expect(DerivationEngine.strainFlooredAtSessions(3.1, s), 8.4);
    expect(DerivationEngine.strainFlooredAtSessions(9.0, s), 9.0);
    expect(DerivationEngine.strainFlooredAtSessions(null, s), isNull);
  });

  test('strain curve is floored at a session from its end, like the headline',
      () {
    // #471: a workout scored 0.6 while the day's HR build-up stayed at 0 —
    // the headline read 0.6 above a line pinned at 0.
    final curve = [
      for (var t = 1000; t <= 1300; t += 60) {'t': t, 'v': 0.0},
    ];
    final s = [
      {'status': 'done', 'strain': 0.6, 'end_ts': 1120},
      {'status': 'live', 'strain': 9.0, 'end_ts': 1000},
      {'status': 'done', 'strain': 9.0, 'end_ts': 1000, 'private': 1},
    ];
    final out = DerivationEngine.strainCurveFlooredAtSessions(curve, s);
    expect([for (final p in out) p['v']], [0.0, 0.0, 0.6, 0.6, 0.6, 0.6]);
    expect(out.last['v'],
        DerivationEngine.strainFlooredAtSessions(0.0, s));
    // The stored curve is not mutated in place.
    expect(curve.every((p) => p['v'] == 0.0), isTrue);

    // HR build-up already above the session keeps its own values.
    final high = [
      {'t': 1000, 'v': 0.2},
      {'t': 1200, 'v': 4.0},
    ];
    expect(
        [
          for (final p in DerivationEngine.strainCurveFlooredAtSessions(
              high, [{'status': 'done', 'strain': 3.0, 'end_ts': 1100}]))
            p['v']
        ],
        [0.2, 4.0]);

    // A session ending after the last point adds a point at its end, capped.
    final late = DerivationEngine.strainCurveFlooredAtSessions(
      [{'t': 1000, 'v': 1.0}],
      [{'status': 'done', 'strain': 5.0, 'end_ts': 9000}],
      capSec: 2000,
    );
    expect(late, [
      {'t': 1000, 'v': 1.0},
      {'t': 2000, 'v': 5.0},
    ]);

    // No HR build-up to draw: no curve is invented from a session.
    expect(
        DerivationEngine.strainCurveFlooredAtSessions(
            const [], [{'status': 'done', 'strain': 5.0, 'end_ts': 900}]),
        isEmpty);
  });

  test('resting HR fallback is the median of three or more prior nights', () {
    expect(rhrFallbackFromHistory([55, 60]), isNull);
    expect(rhrFallbackFromHistory([55, 70, 60]), 60);
    expect(rhrFallbackFromHistory([50, 52, 58, 60, double.nan]), 55);
  });

  test('an HR-led fallback night needs 3 h and a non-daytime start', () {
    // 2026-10-04 local midnight in UTC terms, tz offset 0.
    const mid = 1791072000;
    const h = 3600;
    expect(
        fallbackNightAcceptable(mid - 1 * h, mid + 6 * h, tzOffsetSec: 0), true);
    expect(fallbackNightAcceptable(mid - 1 * h, mid + 1 * h, tzOffsetSec: 0),
        false, reason: 'two hours');
    expect(
        fallbackNightAcceptable(mid + 13 * h, mid + 17 * h, tzOffsetSec: 0),
        false,
        reason: 'starts 13:00');
    // A day sleeper (habitual midsleep 14:00) keeps a daytime window.
    expect(
        fallbackNightAcceptable(mid + 10 * h, mid + 17 * h,
            tzOffsetSec: 0, habitualMidsleepSec: 14 * h),
        true);
  });

  test('naps overlapping the next night are dropped, logged ones kept', () {
    final naps = [
      {'start': 100, 'end': 200, 'duration_min': 2},
      {'start': 900, 'end': 1200, 'duration_min': 5},
      {'start': 950, 'end': 1000, 'duration_min': 1, 'source': 'manual'},
      {'start': 990, 'end': 1100, 'duration_min': 2, 'source': 'legacy'},
    ];
    final kept = napsWithoutNextNight(naps, 1000, 5000)!;
    expect(kept.map((n) => n['start']), [100, 950]);
    expect(napsWithoutNextNight(naps.sublist(0, 1), 1000, 5000), isNull);
  });

  test('WHOOP 4 skin temp that tracks ambient stays out of the illness watch',
      () {
    // Skin temp moving with ambient minute to minute: r near 1.
    final tracking = [
      for (var m = 0; m < 60; m++)
        (m, 800.0 + (m % 7) * 3, 600.0 + (m % 7) * 2),
    ];
    final r = skinTempAmbientR(tracking)!;
    expect(r, greaterThan(0.95));
    expect(skinTempIllnessEligible('gen4', r), isFalse);
    // Too few minutes: no r, and WHOOP 4 fails closed.
    expect(skinTempAmbientR(tracking.sublist(0, 10)), isNull);
    expect(skinTempIllnessEligible('gen4', null), isFalse);
    expect(skinTempIllnessEligible(null, 0.1), isTrue);
    // WHOOP 5 reads real °C and is not checked.
    expect(skinTempIllnessEligible('gen5', null), isTrue);
  });
}
