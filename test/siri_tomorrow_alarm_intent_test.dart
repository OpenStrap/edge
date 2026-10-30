import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';

// Siri's "Enable tomorrow's alarm" latches the instant it ran and the app
// resolves the weekday against the schedule. Taking the next calendar date
// missed the morning still ahead when asked after midnight; a fixed noon
// cut-off missed the next day when asked in the morning after the alarm had
// already gone off.
List<AlarmScheduleEntry> _weekAt(int hour, int minute) => [
      for (var w = 0; w < 7; w++)
        AlarmScheduleEntry(
            weekday: w, hour: hour, minute: minute, enabled: false),
    ];

void main() {
  // 2026-10-20 is a Tuesday (column 1); Wednesday is column 2.
  const tue = 1, wed = 2;

  test('after midnight, before today\'s slot: today\'s morning', () {
    expect(
        siriTomorrowAlarmWeekday(
            _weekAt(7, 0), DateTime(2026, 10, 20, 0, 40)),
        tue);
  });

  test('in the morning after today\'s slot has passed: the next day', () {
    expect(
        siriTomorrowAlarmWeekday(_weekAt(7, 0), DateTime(2026, 10, 20, 9)),
        wed);
  });

  test('exactly at today\'s slot counts as passed', () {
    expect(
        siriTomorrowAlarmWeekday(_weekAt(7, 0), DateTime(2026, 10, 20, 7)),
        wed);
  });

  test('the slot time is per weekday, not a fixed hour', () {
    final s = _weekAt(7, 0);
    s[tue] = const AlarmScheduleEntry(
        weekday: 1, hour: 10, minute: 30, enabled: false);
    expect(siriTomorrowAlarmWeekday(s, DateTime(2026, 10, 20, 9)), tue);
    expect(siriTomorrowAlarmWeekday(s, DateTime(2026, 10, 20, 10, 31)), wed);
  });

  test('an evening slot still ahead in the afternoon is not "tomorrow"', () {
    expect(
        siriTomorrowAlarmWeekday(_weekAt(22, 0), DateTime(2026, 10, 20, 15)),
        wed);
  });

  test('evening request: the next calendar day, wrapping Sunday to Monday',
      () {
    expect(
        siriTomorrowAlarmWeekday(_weekAt(7, 0), DateTime(2026, 10, 20, 23)),
        wed);
    // 2026-10-25 is a Sunday.
    expect(
        siriTomorrowAlarmWeekday(_weekAt(7, 0), DateTime(2026, 10, 25, 22)),
        0);
  });

  test('a weekday with no row uses the default slot time', () {
    expect(
        siriTomorrowAlarmWeekday(const [], DateTime(2026, 10, 20, 0, 40)),
        tue);
    expect(siriTomorrowAlarmWeekday(const [], DateTime(2026, 10, 20, 9)),
        wed);
  });

  test('the intent latches the request time, not a weekday', () {
    final swift = File('ios/OpenStrapIntents.swift').readAsStringSync();
    final start = swift.indexOf('struct EnableTomorrowAlarmIntent');
    expect(start, isNonNegative);
    final end = swift.indexOf('// MARK:', start);
    final body = swift.substring(start, end < 0 ? swift.length : end);
    expect(body, contains('"enable_tomorrow_alarm_requested_at"'));
    expect(body, isNot(contains('"enable_tomorrow_alarm_weekday"')));
  });
}
