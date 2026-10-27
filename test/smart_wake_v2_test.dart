// Tests for the upgraded smart-wake light-sleep detector (Phase 5.1 —
// tests written BEFORE the implementation, per the approved gate).
//
// Covers:
//   - ConfounderProfile (Q2: journal-aware threshold adjustments)
//   - enmoTrendExceeded (Q4: personalized movement trend)
//   - lateWindowProtection (Q3: suppress early buzz near window end)
//   - likelyLightSleep v2 (Q1+Q2+Q3+Q4: 10th-percentile baseline,
//     dynamic thresholds, trend condition, late-window protection)
//   - Backward compat: existing likelyLightSleep tests still pass
//     (default profile = no adjustment = shipped behavior)
//
// Pure functions only — no DB, no BLE, no Flutter widgets.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/state/smart_wake.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

List<SmartWakeSample> still(double hr, int n) =>
    List.generate(n, (_) => SmartWakeSample(hr, 0, 0, 1.0)); // resting, 1g

List<SmartWakeSample> moving(double hr, int n) =>
    List.generate(n, (_) => SmartWakeSample(hr, 0.5, 0.4, 1.0));

SmartWakeSample sample(double hr, double enmo) {
  // ENMO = |‖(ax,ay,az)‖ − 1.0|. For ENMO = e, we need ‖v‖ = 1+e or 1−e.
  // Simplest: ax = e, ay = 0, az = 1 → ‖v‖ = √(e²+1) ≈ 1 + e²/2… not exact.
  // Exact: put all deviation on one axis: ax = e, ay = 0, az = 1.
  // Then ‖v‖ = √(e² + 1), ENMO = |√(e²+1) − 1| ≈ e²/2 for small e.
  // Better: az = 1+e, ax=ay=0 → ‖v‖ = 1+e → ENMO = e. Exact.
  return SmartWakeSample(hr, 0, 0, 1.0 + enmo);
}

List<SmartWakeSample> withEnmo(double hr, double enmo, int n) =>
    List.generate(n, (_) => sample(hr, enmo));

/// Build a list where ENMO changes linearly from [enmoStart] to [enmoEnd].
List<SmartWakeSample> rampEnmo(double hr, double enmoStart, double enmoEnd, int n) {
  return List.generate(n, (i) {
    final t = n <= 1 ? 0.0 : i / (n - 1);
    final enmo = enmoStart + (enmoEnd - enmoStart) * t;
    return sample(hr, enmo);
  });
}

ConfounderProfile emptyProfile() => const ConfounderProfile();

// ── ConfounderProfile (Q2) ───────────────────────────────────────────────────

void main() {
  group('ConfounderProfile (Q2 — journal-aware boost)', () {
    test('empty journal → default thresholds (no penalty)', () {
      final p = confounderProfile(tags: {}, metrics: {});
      expect(p.hrArousalBpm, 4.0);
      expect(p.motionCeilingG, 0.08);
      expect(p.lateWindowProtectionMinutes, 5);
      expect(p.earlyBuzzDisabled, isFalse);
      expect(p.trendWindowMinutes, 3);
      expect(p.trendThresholdFactor, 1.0);
    });

    test('alcohol (units>0, last drink ≥20:00) → HR threshold 4→6', () {
      final p = confounderProfile(
        tags: {'alcohol'},
        metrics: {
          'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 22 * 60), // 22:00
        },
      );
      expect(p.hrArousalBpm, 6.0);
      expect(p.motionCeilingG, 0.08); // unchanged
      expect(p.trendWindowMinutes, 5); // alcohol extends trend window
    });

    test('alcohol but last drink before 20:00 → no boost', () {
      final p = confounderProfile(
        tags: {'alcohol'},
        metrics: {
          'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 18 * 60), // 18:00
        },
      );
      expect(p.hrArousalBpm, 4.0); // no boost — drank early
    });

    test('late caffeine (≥200mg, last ≥16:00) → HR threshold 4→6', () {
      final p = confounderProfile(
        tags: {'caffeine'},
        metrics: {
          'caffeine_mg': JournalMetricValue(250, atMinuteOfDay: 17 * 60), // 17:00
        },
      );
      expect(p.hrArousalBpm, 6.0);
    });

    test('caffeine <200mg → no boost', () {
      final p = confounderProfile(
        tags: {'caffeine'},
        metrics: {
          'caffeine_mg': JournalMetricValue(100, atMinuteOfDay: 17 * 60),
        },
      );
      expect(p.hrArousalBpm, 4.0);
    });

    test('stress tag → ENMO ceiling 0.08→0.06', () {
      final p = confounderProfile(tags: {'stress'}, metrics: {});
      expect(p.motionCeilingG, 0.06);
      expect(p.trendThresholdFactor, 0.5); // stricter trend
    });

    test('stress rating ≥4 → ENMO ceiling 0.08→0.06', () {
      final p = confounderProfile(
        tags: {},
        metrics: {'stress': JournalMetricValue(4)},
      );
      expect(p.motionCeilingG, 0.06);
      expect(p.trendThresholdFactor, 0.5);
    });

    test('stress rating 3 → no boost', () {
      final p = confounderProfile(
        tags: {},
        metrics: {'stress': JournalMetricValue(3)},
      );
      expect(p.motionCeilingG, 0.08);
      expect(p.trendThresholdFactor, 1.0);
    });

    test('workout tag (no rest day) → late-window 5→10 min', () {
      final p = confounderProfile(tags: {'workout'}, metrics: {});
      expect(p.lateWindowProtectionMinutes, 10);
      expect(p.trendWindowMinutes, 5); // workout extends trend window
    });

    test('workout + rest day → no workout boost', () {
      final p = confounderProfile(tags: {'workout', 'rest day'}, metrics: {});
      expect(p.lateWindowProtectionMinutes, 5); // default
    });

    test('late meal tag → HR threshold 4→5', () {
      final p = confounderProfile(tags: {'late meal'}, metrics: {});
      expect(p.hrArousalBpm, 5.0);
      expect(p.trendThresholdFactor, 1.5); // more tolerant trend
    });

    test('sick tag → ENMO 0.06 + HR 5 bpm', () {
      final p = confounderProfile(tags: {'sick'}, metrics: {});
      expect(p.motionCeilingG, 0.06);
      expect(p.hrArousalBpm, 5.0);
      expect(p.trendThresholdFactor, 0.5);
    });

    test('alcohol + stress combo → early buzz DISABLED entirely', () {
      final p = confounderProfile(
        tags: {'alcohol', 'stress'},
        metrics: {
          'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 22 * 60),
        },
      );
      expect(p.earlyBuzzDisabled, isTrue);
    });

    test('alcohol (early) + stress → no combo disable (alcohol too early)', () {
      final p = confounderProfile(
        tags: {'alcohol', 'stress'},
        metrics: {
          'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 15 * 60), // 15:00
        },
      );
      expect(p.earlyBuzzDisabled, isFalse);
      expect(p.motionCeilingG, 0.06); // stress still applies
    });

    test('stacking: alcohol + late meal → HR = MAX(6,5) = 6', () {
      final p = confounderProfile(
        tags: {'alcohol', 'late meal'},
        metrics: {
          'alcohol_units': JournalMetricValue(1, atMinuteOfDay: 21 * 60),
        },
      );
      expect(p.hrArousalBpm, 6.0);
    });

    test('stacking: stress + sick → ENMO = MIN(0.06, 0.06) = 0.06', () {
      final p = confounderProfile(tags: {'stress', 'sick'}, metrics: {});
      expect(p.motionCeilingG, 0.06);
      expect(p.hrArousalBpm, 5.0); // sick boost
    });
  });

  // ── enmoTrendExceeded (Q4 — personalized movement trend) ───────────────────

  group('enmoTrendExceeded (Q4 — personalized movement trend)', () {
    test('flat ENMO → no trend exceeded', () {
      final samples = withEnmo(55, 0.03, 60);
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isFalse,
      );
    });

    test('rising ENMO above threshold → trend exceeded (no buzz)', () {
      // First half ~0.02, second half ~0.08 → rise of ~0.06 > 0.02 threshold.
      // (0.03→0.06 gives a rise of only ~0.015 — below the 0.02 threshold.)
      final samples = rampEnmo(55, 0.02, 0.08, 60);
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isTrue,
      );
    });

    test('rising ENMO below threshold → no trend exceeded (buzz ok)', () {
      // Rise of 0.01 < 0.02 threshold
      final samples = rampEnmo(55, 0.03, 0.04, 60);
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isFalse,
      );
    });

    test('falling ENMO → no trend exceeded (settling = good)', () {
      final samples = rampEnmo(55, 0.06, 0.03, 60);
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isFalse,
      );
    });

    test('too few samples → false (never guesses)', () {
      final samples = rampEnmo(55, 0.03, 0.10, 10);
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isFalse,
      );
    });

    test('longer window (5 min, alcohol/workout) smooths short spikes', () {
      // A 30-second spike in a 3-min window looks like a trend.
      // In a 5-min window, the same spike is diluted.
      final spike3min = [
        ...withEnmo(55, 0.03, 90),  // 90s flat
        ...withEnmo(55, 0.12, 30),  // 30s spike
        ...withEnmo(55, 0.03, 60),  // 60s flat
      ];
      // 3-min window: first half mean ~0.03, second half mean ~0.06 → exceeded
      expect(
        enmoTrendExceeded(spike3min, threshold: 0.02, windowMinutes: 3),
        isTrue,
      );
      // 5-min window: spike is 30s of 300s → diluted below threshold
      final spike5min = [
        ...withEnmo(55, 0.03, 135), // 135s flat
        ...withEnmo(55, 0.12, 30),  // 30s spike
        ...withEnmo(55, 0.03, 135), // 135s flat
      ];
      expect(
        enmoTrendExceeded(spike5min, threshold: 0.02, windowMinutes: 5),
        isFalse,
      );
    });

    // REGRESSION (review finding, mikenrafter on PR #630): windowMinutes used
    // to be accepted and never read — the alcohol/workout 5-minute smoothing
    // was documentation only. The symmetric spike test above could not catch
    // that (it passes either way), so this one is deliberately ASYMMETRIC:
    // 2 min of high noise followed by a 3-min ramp. Judged over the whole
    // 5 minutes the ramp is invisible (the noisy prefix dominates the first
    // half and the rise goes negative); judged over the trailing 3 minutes it
    // is a clear trend. Only a genuinely applied window can tell them apart.
    test('windowMinutes is actually applied (regression: dead parameter)', () {
      final samples = [
        ...withEnmo(55, 0.10, 120), // 2 min flat, high
        for (var i = 0; i < 180; i++) // 3 min ramp 0.02 → 0.08
          sample(55, 0.02 + (0.08 - 0.02) * i / 179),
      ];
      expect(samples.length, 300); // 5 minutes at 1 Hz
      // Trailing 3 minutes: a clear rise → exceeded.
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 3),
        isTrue,
      );
      // Full 5 minutes: the noisy prefix flattens it out → not exceeded.
      expect(
        enmoTrendExceeded(samples, threshold: 0.02, windowMinutes: 5),
        isFalse,
      );
    });

    test('a list shorter than the requested window is used whole', () {
      // 2 minutes of samples, 5-minute window requested → use all 120.
      final short = withEnmo(55, 0.03, 60) + withEnmo(55, 0.09, 60);
      // Judged whole: first half 0.03, second half 0.09 → rise 0.06.
      expect(
        enmoTrendExceeded(short, threshold: 0.02, windowMinutes: 5),
        isTrue,
      );
    });
  });

  // ── lateWindowProtection (Q3 — deep-sleep protection near window end) ──────

  group('lateWindowProtection (Q3)', () {
    final windowEnd = DateTime(2026, 10, 26, 6, 30);

    test('not in last 5 min → protection inactive', () {
      final now = DateTime(2026, 10, 26, 6, 20); // 10 min before end
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd,
          now: now,
          protectionMinutes: 5,
          currentHr: 48,
          baselineHr: 48,
        ),
        isFalse,
      );
    });

    test('in last 5 min AND HR near baseline → protection ACTIVE (no buzz)', () {
      final now = DateTime(2026, 10, 26, 6, 28); // 2 min before end
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd,
          now: now,
          protectionMinutes: 5,
          currentHr: 49, // +1 bpm from baseline
          baselineHr: 48,
        ),
        isTrue,
      );
    });

    test('in last 5 min but HR clearly elevated → protection inactive (buzz ok)', () {
      final now = DateTime(2026, 10, 26, 6, 28);
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd,
          now: now,
          protectionMinutes: 5,
          currentHr: 56, // +8 bpm — clearly light sleep
          baselineHr: 48,
        ),
        isFalse,
      );
    });

    test('HR within 2 bpm of baseline → protected; above 2 bpm → not', () {
      final now = DateTime(2026, 10, 26, 6, 27);
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd, now: now, protectionMinutes: 5,
          currentHr: 50, baselineHr: 48, // +2 bpm — boundary
        ),
        isTrue, // ≤2 bpm → protected
      );
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd, now: now, protectionMinutes: 5,
          currentHr: 51, baselineHr: 48, // +3 bpm
        ),
        isFalse,
      );
    });

    test('workout day (10-min protection) extends the zone', () {
      final now = DateTime(2026, 10, 26, 6, 23); // 7 min before end
      // 5-min protection: inactive (7 > 5)
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd, now: now, protectionMinutes: 5,
          currentHr: 48, baselineHr: 48,
        ),
        isFalse,
      );
      // 10-min protection: active (7 < 10)
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd, now: now, protectionMinutes: 10,
          currentHr: 48, baselineHr: 48,
        ),
        isTrue,
      );
    });

    test('exactly at window end → inactive (window check handles this)', () {
      expect(
        lateWindowProtectionActive(
          windowEnd: windowEnd,
          now: windowEnd,
          protectionMinutes: 5,
          currentHr: 48,
          baselineHr: 48,
        ),
        isFalse,
      );
    });
  });

  // ── likelyLightSleep v2 (Q1+Q2+Q3+Q4 integrated) ──────────────────────────

  group('likelyLightSleep v2 (upgraded, with ConfounderProfile)', () {
    test('backward compat: default profile = shipped behavior (HR+4, ENMO<0.08)', () {
      final baseline = still(52, 90);
      final recent = still(58, 60); // +6 bpm, no movement
      expect(
        likelyLightSleep(baseline: baseline, recent: recent),
        isTrue,
      );
    });

    test('backward compat: thin windows still → false', () {
      expect(
        likelyLightSleep(baseline: still(55, 5), recent: still(65, 60)),
        isFalse,
      );
      expect(
        likelyLightSleep(baseline: still(55, 90), recent: still(65, 5)),
        isFalse,
      );
    });

    test('v2: rising ENMO trend → false even if HR elevated and mean ENMO low', () {
      final baseline = still(52, 90);
      // Mean ENMO is low (~0.045) but rising sharply — person is turning over
      final recent = rampEnmo(58, 0.02, 0.07, 60);
      expect(
        likelyLightSleep(baseline: baseline, recent: recent),
        isFalse, // trend exceeded → no buzz
      );
    });

    test('v2: with alcohol profile, +4 bpm is NOT enough (needs +6)', () {
      final baseline = still(52, 90);
      final recent = still(57, 60); // +5 bpm
      final alcoholProfile = confounderProfile(
        tags: {'alcohol'},
        metrics: {'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 22 * 60)},
      );
      // Default: +5 ≥ 4 → would be true
      expect(likelyLightSleep(baseline: baseline, recent: recent), isTrue);
      // Alcohol profile: +5 < 6 → false
      expect(
        likelyLightSleep(baseline: baseline, recent: recent, profile: alcoholProfile),
        isFalse,
      );
    });

    test('v2: alcohol+stress combo → always false (early buzz disabled)', () {
      final baseline = still(52, 90);
      final recent = still(65, 60); // +13 bpm, very elevated
      final comboProfile = confounderProfile(
        tags: {'alcohol', 'stress'},
        metrics: {'alcohol_units': JournalMetricValue(2, atMinuteOfDay: 22 * 60)},
      );
      expect(
        likelyLightSleep(baseline: baseline, recent: recent, profile: comboProfile),
        isFalse, // combo → no buzz regardless
      );
    });

    test('v2: late-window protection suppresses buzz when HR near baseline', () {
      final baseline = still(48, 90);
      final recent = still(50, 60); // +2 bpm — would normally pass +4? No, +2 < 4.
      // Use a case that WOULD pass without protection: +5 bpm but in last 5 min
      final recentElevated = still(53, 60); // +5 bpm
      final windowEnd = DateTime(2026, 10, 26, 6, 30);
      final nowLate = DateTime(2026, 10, 26, 6, 28); // 2 min before end

      // Without late-window context: would be true (+5 ≥ 4, no movement)
      expect(
        likelyLightSleep(baseline: baseline, recent: recentElevated),
        isTrue,
      );
      // With late-window protection active (HR 53 vs baseline 48 = +5, but
      // protection checks if HR is "near baseline" — within 2 bpm):
      // 53 is NOT within 2 bpm of 48 → protection inactive → still true
      expect(
        likelyLightSleep(
          baseline: baseline,
          recent: recentElevated,
          windowEnd: windowEnd,
          now: nowLate,
          baselineHr: 48,
        ),
        isTrue, // HR too elevated for protection to apply
      );
      // But if HR is truly near baseline (49 = +1 bpm):
      final recentNearBaseline = still(49, 60);
      expect(
        likelyLightSleep(
          baseline: baseline,
          recent: recentNearBaseline,
          windowEnd: windowEnd,
          now: nowLate,
          baselineHr: 48,
        ),
        isFalse, // +1 < 4 anyway, but also protection would catch it
      );
    });

    test('v2: a 5-min recent fetch does not move the 3-min HR judgment', () {
      // The caller now fetches up to the trend window (5 min on alcohol or
      // workout nights). HR arousal must still be judged on the trailing 3
      // minutes — otherwise a longer fetch would silently make the detector
      // more eager.
      final baseline = still(52, 90);
      final recent = [
        ...withEnmo(70, 0.03, 120), // first 2 min: elevated (would inflate a 5-min mean)
        ...withEnmo(54, 0.03, 180), // last 3 min: only +2 bpm — below the 4 bpm bar
      ];
      expect(recent.length, 300);
      // Judged on the trailing 3 minutes → +2 bpm → no buzz.
      expect(
        likelyLightSleep(baseline: baseline, recent: recent),
        isFalse,
      );
      // Sanity: the same data judged as a 3-minute list is unchanged.
      expect(
        likelyLightSleep(baseline: baseline, recent: withEnmo(54, 0.03, 180)),
        isFalse,
      );
      // And the trailing 3 minutes WOULD buzz if they were elevated.
      final recentHot = [
        ...withEnmo(50, 0.03, 120),
        ...withEnmo(58, 0.03, 180), // +6 bpm in the trailing 3 min
      ];
      expect(
        likelyLightSleep(baseline: baseline, recent: recentHot),
        isTrue,
      );
    });

    test('v2: stress profile tightens ENMO ceiling (0.07 passes default, fails stress)', () {
      final baseline = still(52, 90);
      // Mean ENMO 0.07 — passes default 0.08, fails stress 0.06
      final recent = withEnmo(58, 0.07, 60);
      final stressProfile = confounderProfile(tags: {'stress'}, metrics: {});

      expect(likelyLightSleep(baseline: baseline, recent: recent), isTrue);
      expect(
        likelyLightSleep(baseline: baseline, recent: recent, profile: stressProfile),
        isFalse,
      );
    });
  });

  // ── 10th-percentile baseline helper ────────────────────────────────────────

  group('percentileHr (baseline computation)', () {
    test('10th percentile of flat HR = that HR', () {
      final samples = still(52, 100);
      expect(percentileHr(samples, 0.10), 52.0);
    });

    test('10th percentile picks the low end (deep-sleep HR)', () {
      // 80 samples at 48 (deep), 20 samples at 60 (light) → 10th pct = 48
      final samples = [...still(48, 80), ...still(60, 20)];
      expect(percentileHr(samples, 0.10), 48.0);
    });

    test('empty list → null (caller falls back)', () {
      expect(percentileHr([], 0.10), isNull);
    });

    test('filters invalid HR (≤30 or ≥200)', () {
      final samples = [
        ...still(48, 90),
        SmartWakeSample(0, 0, 0, 1.0),   // off-skin sentinel
        SmartWakeSample(250, 0, 0, 1.0), // impossible
      ];
      expect(percentileHr(samples, 0.10), 48.0);
    });
  });
}
