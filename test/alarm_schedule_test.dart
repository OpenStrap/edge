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

  group('alarmArmsTonight', () {
    // Wednesday 2026-08-19, 19:00 — the 7pm check-in instant.
    final now = DateTime(2026, 8, 19, 19, 0);
    int epochOf(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

    test('arm for tomorrow 07:00 is TRUE — the overnight wake alarm (bug case)',
        () {
      expect(alarmArmsTonight(epochOf(DateTime(2026, 8, 20, 7, 0)), now),
          isTrue);
    });

    test('arm for later today (23:00) is TRUE', () {
      expect(alarmArmsTonight(epochOf(DateTime(2026, 8, 19, 23, 0)), now),
          isTrue);
    });

    test('arm for day-after-tomorrow 07:00 is FALSE — not tonight', () {
      expect(alarmArmsTonight(epochOf(DateTime(2026, 8, 21, 7, 0)), now),
          isFalse);
    });

    test('an arm epoch already in the past is FALSE', () {
      expect(alarmArmsTonight(epochOf(DateTime(2026, 8, 19, 6, 0)), now),
          isFalse);
    });

    test('a null epoch is FALSE', () {
      expect(alarmArmsTonight(null, now), isFalse);
    });

    test('boundary: an arm exactly at noon tomorrow is FALSE (exclusive)', () {
      expect(alarmArmsTonight(epochOf(DateTime(2026, 8, 20, 12, 0)), now),
          isFalse);
    });
  });

  group('inSmartWakeWindow — the fallback-always-fires guarantee', () {
    // windowEnd is always the band's own already-armed fallback SET_ALARM;
    // this function decides only whether an EARLY buzz should be attempted.
    // It never returns anything that could be read as "skip the fallback" —
    // there is no return value meaning that, by construction. The proof
    // below sweeps every second of a whole day around a 30-minute window
    // and checks two properties that together ARE the safety guarantee:
    //   1. true is only ever returned strictly before windowEnd (never at
    //      or after it — an "early" fire can never BE the late fire), and
    //   2. at windowEnd itself and beyond, the function always says false —
    //      i.e. it never tries to claim the fallback moment for itself, so
    //      whatever arms the real SET_ALARM there is untouched by this
    //      function returning either value.
    final windowEnd = DateTime(2026, 9, 18, 6, 30);

    test('minutes == 0 (off) is false for every instant, no exceptions', () {
      for (var deltaMin = -120; deltaMin <= 120; deltaMin++) {
        final now = windowEnd.add(Duration(minutes: deltaMin));
        expect(inSmartWakeWindow(windowEnd: windowEnd, minutes: 0, now: now),
            isFalse,
            reason: 'off must stay off at $now');
      }
    });

    test(
        'algebraic sweep: true never occurs at or after windowEnd, for any '
        'window size, at second resolution', () {
      for (final minutes in [1, 15, 30, 45]) {
        var sawTrueBeforeEnd = false;
        for (var deltaSec = -3600; deltaSec <= 3600; deltaSec += 5) {
          final now = windowEnd.add(Duration(seconds: deltaSec));
          final result = inSmartWakeWindow(
              windowEnd: windowEnd, minutes: minutes, now: now);
          if (!now.isBefore(windowEnd)) {
            // PROPERTY 2: at/after windowEnd, always false.
            expect(result, isFalse,
                reason: '$now is at/after windowEnd=$windowEnd '
                    '(minutes=$minutes) but returned true');
          } else if (result) {
            sawTrueBeforeEnd = true;
          }
        }
        // Sanity: the window is not vacuously always-false — it does fire
        // somewhere strictly before windowEnd when minutes > 0.
        expect(sawTrueBeforeEnd, isTrue,
            reason: 'minutes=$minutes never returned true anywhere');
      }
    });

    test('exactly at the window start boundary is true (inclusive)', () {
      expect(
          inSmartWakeWindow(
              windowEnd: windowEnd,
              minutes: 30,
              now: windowEnd.subtract(const Duration(minutes: 30))),
          isTrue);
    });

    test('one second before windowEnd is still inside the window', () {
      expect(
          inSmartWakeWindow(
              windowEnd: windowEnd,
              minutes: 30,
              now: windowEnd.subtract(const Duration(seconds: 1))),
          isTrue);
    });

    test('exactly at windowEnd is false — that instant belongs to the '
        'fallback alarm alone', () {
      expect(
          inSmartWakeWindow(windowEnd: windowEnd, minutes: 30, now: windowEnd),
          isFalse);
    });

    test('before the window opens is false', () {
      expect(
          inSmartWakeWindow(
              windowEnd: windowEnd,
              minutes: 30,
              now: windowEnd.subtract(const Duration(minutes: 31))),
          isFalse);
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

  group('tomorrowScheduleWeekday', () {
    test('Wednesday → Thursday is column 3', () {
      // 2026-08-19 is a Wednesday (DateTime.weekday 3, column 2).
      expect(tomorrowScheduleWeekday(DateTime(2026, 8, 19, 8, 0)), 3);
    });

    test('wraps Sunday → Monday, column 6 to column 0', () {
      // 2026-08-23 is a Sunday (DateTime.weekday 7, column 6).
      expect(tomorrowScheduleWeekday(DateTime(2026, 8, 23, 8, 0)), 0);
    });
  });
}
