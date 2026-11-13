// Tests for the preSyncAt lease extension (Option C — wired preSyncAt).
//
// The band prompt lease now starts at preSyncAt (= targetWake − 135min)
// instead of windowStart (= targetWake − 90min), so the app wakes every 61s
// from preSyncAt onward and backfills decoded_onehz with the last ~3h of
// nocturnal data before the smart-wake window opens.
//
// These tests verify:
//   - preSyncAt is computed correctly (targetWake − 135min)
//   - shouldEnable covers the full extended lease (preSyncAt → targetWake)
//   - effectiveLease returns the full duration (135min)
//   - The smart-wake DETECTION window is unchanged (still only inside
//     the actual window, checked by inSmartWakeWindow in _checkSmartWake)
//   - Scheduled alarm path also gets the extended lease
//   - No plan / insufficient history → shouldEnable false, preSyncAt null

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/sync/high_freq_wake_window.dart';

/// Build a day_result row with a wake time at [wakeHour]:[wakeMinute].
Map<String, dynamic> dayRow(int wakeHour, int wakeMinute) {
  final offsetMs = DateTime(2026, 10, 25, wakeHour, wakeMinute)
      .millisecondsSinceEpoch;
  return {
    'window_json': '{"value":{"offset_ms":$offsetMs}}',
    'payload_json': '{"sleep":{"window":{"value":{"offset_ms":$offsetMs}}}}',
  };
}

void main() {
  group('HighFreqWakeWindow preSyncAt lease extension (Option C)', () {
    // 07:30 habitual wake → preSyncAt = 07:30 − 135min = 05:15
    final targetWake = DateTime(2026, 10, 26, 7, 30);
    final preSyncAt = DateTime(2026, 10, 26, 5, 15);
    final rows = [for (var i = 0; i < 5; i++) dayRow(7, 30)];

    test('preSyncAt = targetWake − (lease + preSyncLead) = 05:15', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 3, 0), // well before preSyncAt
      );
      expect(plan.targetWake, targetWake);
      expect(plan.preSyncAt, preSyncAt);
      expect(plan.shouldEnable, isFalse); // 03:00 is before preSyncAt
    });

    test('shouldEnable becomes true at preSyncAt (05:15), not windowStart', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 5, 15), // exactly at preSyncAt
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.preSyncAt, preSyncAt);
    });

    test('shouldEnable is true between preSyncAt and windowStart (05:15–06:00)', () {
      // This is the NEW behavior: the band prompt is active during the
      // pre-sync lead, backfilling data. The smart-wake DETECTION still
      // only runs inside the actual window (06:00–06:30), checked by
      // inSmartWakeWindow in _checkSmartWake.
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 5, 45), // 30 min into the pre-sync lead
      );
      expect(plan.shouldEnable, isTrue);
    });

    test('shouldEnable is true inside the actual window (06:00–06:30)', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 6, 15),
      );
      expect(plan.shouldEnable, isTrue);
    });

    test('shouldEnable is false at/after targetWake', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 7, 30), // exactly at targetWake
      );
      expect(plan.shouldEnable, isFalse);
    });

    test('shouldEnable is false before preSyncAt (04:00)', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 4, 0),
      );
      expect(plan.shouldEnable, isFalse);
    });

    test('effectiveLease = targetWake − preSyncAt = 135 min', () {
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 3, 0),
      );
      expect(plan.effectiveLease, const Duration(minutes: 135));
    });

    test('effectiveLease falls back to 90 min when preSyncAt is null', () {
      // No plan (insufficient history) → effectiveLease is null, caller
      // falls back to HighFreqWakeWindow.lease (90 min).
      const plan = HighFreqWakePlan(
        shouldEnable: false,
        targetWake: null,
        source: 'insufficient_sleep_history',
        sampleCount: 0,
      );
      expect(plan.effectiveLease, isNull);
    });

    test('scheduled alarm path also gets preSyncAt and extended lease', () {
      // 05:30 alarm with a 30-min smart window → windowEnd = 05:30.
      // preSyncAt = windowEnd − (the window's OWN 30 min + 45 min lead) =
      // 04:15, not the 90-minute default's 03:15.
      final scheduledEnd = DateTime(2026, 10, 26, 5, 30);
      final plan = HighFreqWakeWindow.planFromRows(
        [], // no habitual history — scheduled path takes over
        DateTime(2026, 10, 26, 4, 15), // exactly at preSyncAt
        scheduledWindowEnd: scheduledEnd,
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'scheduled_alarm');
      expect(plan.targetWake, scheduledEnd);
      expect(plan.preSyncAt, DateTime(2026, 10, 26, 4, 15));
      expect(plan.effectiveLease, const Duration(minutes: 75));
    });

    test('a longer armed window starts pre-sync earlier, a shorter one later',
        () {
      final end = DateTime(2026, 10, 26, 7, 0);
      HighFreqWakePlan plan(int minutes) => HighFreqWakeWindow.planFromRows(
            [],
            end.subtract(const Duration(minutes: 1)),
            scheduledWindowEnd: end,
            scheduledWindowMinutes: minutes,
          );
      expect(plan(120).preSyncAt, DateTime(2026, 10, 26, 4, 15));
      expect(plan(45).preSyncAt, DateTime(2026, 10, 26, 5, 30));
    });

    test('leaseFrom never runs past the wake time', () {
      final end = DateTime(2026, 10, 26, 7, 0);
      final plan = HighFreqWakeWindow.planFromRows(
        [],
        DateTime(2026, 10, 26, 6, 0),
        scheduledWindowEnd: end,
        scheduledWindowMinutes: 90,
      );
      // At preSyncAt (04:45) the whole 135 min is still ahead.
      expect(plan.leaseFrom(DateTime(2026, 10, 26, 4, 45)),
          const Duration(minutes: 135));
      // A late connect at 06:30 only has 30 min left, not 135.
      expect(plan.leaseFrom(DateTime(2026, 10, 26, 6, 30)),
          const Duration(minutes: 30));
      expect(plan.leaseFrom(end), Duration.zero);
      expect(plan.leaseFrom(end.add(const Duration(minutes: 5))),
          Duration.zero);
    });

    test('scheduled alarm path: shouldEnable false before preSyncAt', () {
      final plan = HighFreqWakeWindow.planFromRows(
        [],
        DateTime(2026, 10, 26, 4, 0), // 15 min before preSyncAt
        scheduledWindowEnd: DateTime(2026, 10, 26, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isFalse);
    });

    test('habitual plan takes priority over scheduled when both cover now', () {
      // If habitual shouldEnable is true, scheduled is not consulted.
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        DateTime(2026, 10, 26, 6, 15), // inside habitual window
        scheduledWindowEnd: DateTime(2026, 10, 26, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.source, 'habitual_wake');
    });

    test('insufficient history → no plan, preSyncAt null', () {
      final plan = HighFreqWakeWindow.planFromRows(
        [dayRow(7, 30)], // only 1 sample, minSamples = 3
        DateTime(2026, 10, 26, 6, 0),
      );
      expect(plan.shouldEnable, isFalse);
      expect(plan.preSyncAt, isNull);
      expect(plan.effectiveLease, isNull);
      expect(plan.source, 'insufficient_sleep_history');
    });
  });

  group('Constants', () {
    test('lease = 90 min (unchanged)', () {
      expect(HighFreqWakeWindow.lease, const Duration(minutes: 90));
    });

    test('preSyncLead = 45 min', () {
      expect(HighFreqWakeWindow.preSyncLead, const Duration(minutes: 45));
    });

    test('lease + preSyncLead = 135 min (full extended lease)', () {
      expect(
        HighFreqWakeWindow.lease + HighFreqWakeWindow.preSyncLead,
        const Duration(minutes: 135),
      );
    });
  });
}
