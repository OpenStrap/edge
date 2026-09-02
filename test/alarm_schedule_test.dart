// The weekly alarm schedule's pure occurrence math:
//   - fillDefaultAlarmSchedule always produces exactly 7 entries,
//   - nextAlarmOccurrence (week wrap, disabled days, same-time-skip), and
//   - seedEntryFromLegacyEpoch's weekday mapping for the 49→50 migration seed.
// No radio, no DB — everything here is deterministic.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/alarm_schedule.dart';

void main() {
  group('fillDefaultAlarmSchedule', () {
    test('an empty stored list becomes 7 disabled default-time entries', () {
      final schedule = fillDefaultAlarmSchedule(const []);
      expect(schedule.length, 7);
      for (var w = 0; w < 7; w++) {
        expect(schedule[w].weekday, w);
        expect(schedule[w].hour, defaultAlarmHour);
        expect(schedule[w].minute, defaultAlarmMinute);
        expect(schedule[w].enabled, isFalse);
      }
    });

    test('a configured weekday is kept, everything else still defaults', () {
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 2, hour: 6, minute: 45, enabled: true),
      ]);
      expect(schedule.length, 7);
      expect(schedule[2], const AlarmScheduleEntry(
          weekday: 2, hour: 6, minute: 45, enabled: true));
      expect(schedule[0].enabled, isFalse);
      expect(schedule[6].enabled, isFalse);
    });
  });

  group('nextAlarmOccurrence', () {
    // Wednesday 2026-08-19.
    final wed = DateTime(2026, 8, 19, 8, 0);

    test('empty schedule → null', () {
      expect(nextAlarmOccurrence(const [], wed), isNull);
    });

    test('every day disabled → null', () {
      final schedule = fillDefaultAlarmSchedule(const []);
      expect(nextAlarmOccurrence(schedule, wed), isNull);
    });

    test('disabled days are skipped — only the enabled one is considered', () {
      // Monday (0) enabled at 07:00; every other day left disabled.
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true),
      ]);
      // From Wednesday, the next Monday is 5 days ahead.
      final next = nextAlarmOccurrence(schedule, wed);
      expect(next, DateTime(2026, 8, 24, 7, 0));
      expect(next!.weekday, DateTime.monday);
    });

    test('a time later today is today, not next week', () {
      // Wednesday (2) enabled at 20:00 — still ahead of the 08:00 "now".
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 2, hour: 20, minute: 0, enabled: true),
      ]);
      expect(nextAlarmOccurrence(schedule, wed), DateTime(2026, 8, 19, 20, 0));
    });

    test('a time already past today wraps to NEXT week, not tomorrow', () {
      // Wednesday (2) enabled at 06:00 — already past the 08:00 "now", and
      // Wednesday is the only enabled day, so the next one is 7 days out.
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 2, hour: 6, minute: 0, enabled: true),
      ]);
      expect(nextAlarmOccurrence(schedule, wed), DateTime(2026, 8, 26, 6, 0));
    });

    test('the exact same minute as "now" is treated as past (same-time-skip)',
        () {
      // Wednesday (2) enabled at exactly 08:00 == "now" — must not arm for
      // right now; the next occurrence is a full week out.
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 2, hour: 8, minute: 0, enabled: true),
      ]);
      expect(nextAlarmOccurrence(schedule, wed), DateTime(2026, 8, 26, 8, 0));
    });

    test('picks the SOONEST occurrence across multiple enabled days', () {
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true), // Mon
        AlarmScheduleEntry(weekday: 4, hour: 6, minute: 30, enabled: true), // Fri
      ]);
      // From Wednesday 08:00, Friday 06:30 (2 days out) beats Monday (5 days).
      expect(
          nextAlarmOccurrence(schedule, wed), DateTime(2026, 8, 21, 6, 30));
    });

    test('week wrap preserves the wall-clock time across a DST boundary', () {
      // 8 March 2026 is a US spring-forward Sunday. A Sunday-only schedule
      // from the Sunday before must land on 06:30 local the following Sunday,
      // not 05:30/07:30 from a naive 7×24h elapsed-hours add.
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 6, hour: 6, minute: 30, enabled: true), // Sun
      ]);
      final now = DateTime(2026, 3, 1, 23, 0); // Sunday 2026-03-01
      final next = nextAlarmOccurrence(schedule, now);
      expect(next, DateTime(2026, 3, 8, 6, 30));
      expect(next!.hour, 6);
      expect(next.minute, 30);
    });
  });

  group('seedEntryFromLegacyEpoch', () {
    test('maps a legacy epoch onto its local weekday/hour/minute, enabled', () {
      // 2026-08-19 06:30 LOCAL is a Wednesday → DateTime.weekday 3 → column 2.
      final at = DateTime(2026, 8, 19, 6, 30);
      final epoch = at.millisecondsSinceEpoch ~/ 1000;
      final seed = seedEntryFromLegacyEpoch(epoch);
      expect(seed.weekday, at.weekday - 1);
      expect(seed.hour, 6);
      expect(seed.minute, 30);
      expect(seed.enabled, isTrue);
    });
  });
}
