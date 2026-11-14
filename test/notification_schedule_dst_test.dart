// Regression tests for the scheduled-reminder wall-clock arithmetic.
//
// NotificationService._nextInstanceOf used to advance with absolute Durations:
//   d = d.add(const Duration(days: 1));                       // weekday walk
//   d = d.add(Duration(days: weekday != null ? 7 : 1));        // roll forward
// A Duration is ELAPSED time, not a calendar day. Across a DST transition the
// wall-clock time therefore drifts by an hour: the Sunday-18:00 weekly recap
// computed over a spring-forward landed at 19:00 (and at 17:00 over a
// fall-back), and the bedtime / hydration dailies drifted the same way.
//
// nextInstanceOf now rebuilds the TZDateTime from its calendar fields, so the
// tz database resolves whatever UTC offset that day carries.

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:openstrap_edge/notify/notification_service.dart';

/// The pre-fix implementation, kept verbatim so each test can show the drift
/// it produced.
tz.TZDateTime _legacyNextInstanceOf(tz.TZDateTime now, int hour, int minute,
    {int? weekday}) {
  var d = tz.TZDateTime(
      now.location, now.year, now.month, now.day, hour, minute);
  if (weekday != null) {
    while (d.weekday != weekday) {
      d = d.add(const Duration(days: 1));
    }
  }
  if (!d.isAfter(now)) {
    d = d.add(Duration(days: weekday != null ? 7 : 1));
  }
  return d;
}

void main() {
  late tz.Location ny;

  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  group('weekly recap across a spring-forward', () {
    // US DST 2026 starts Sunday 8 March. From Sunday 1 March 19:00 the next
    // Sunday-18:00 instance is 8 March 18:00 EDT.
    test('keeps the 18:00 wall-clock, not +168h of elapsed time', () {
      final now = tz.TZDateTime(ny, 2026, 3, 1, 19, 0);
      final next =
          nextInstanceOf(now, 18, 0, weekday: DateTime.sunday);
      expect(next.month, 3);
      expect(next.day, 8);
      expect(next.hour, 18);
      expect(next.minute, 0);
      expect(next.weekday, DateTime.sunday);

      // The old arithmetic drifted an hour late.
      final legacy =
          _legacyNextInstanceOf(now, 18, 0, weekday: DateTime.sunday);
      expect(legacy.hour, 19, reason: 'guards the regression being fixed');
    });
  });

  group('weekly recap across a fall-back', () {
    // US DST 2026 ends Sunday 1 November. From Sunday 25 Oct 19:00 the next
    // Sunday-18:00 instance is 1 Nov 18:00 EST.
    test('keeps the 18:00 wall-clock, not −1h', () {
      final now = tz.TZDateTime(ny, 2026, 10, 25, 19, 0);
      final next = nextInstanceOf(now, 18, 0, weekday: DateTime.sunday);
      expect(next.month, 11);
      expect(next.day, 1);
      expect(next.hour, 18);

      final legacy =
          _legacyNextInstanceOf(now, 18, 0, weekday: DateTime.sunday);
      expect(legacy.hour, 17, reason: 'guards the regression being fixed');
    });
  });

  group('daily nudge across a DST boundary', () {
    test('a 22:00 bedtime the evening before spring-forward stays 22:00', () {
      // Saturday 7 March 2026 23:00 → next 22:00 is Sunday 8 March (DST day).
      final now = tz.TZDateTime(ny, 2026, 3, 7, 23, 0);
      final next = nextInstanceOf(now, 22, 0);
      expect(next.day, 8);
      expect(next.hour, 22);
      expect(_legacyNextInstanceOf(now, 22, 0).hour, 23,
          reason: 'guards the regression being fixed');
    });

    test('nextCalendarDay (the skipToday roll) is DST-safe too', () {
      final d = tz.TZDateTime(ny, 2026, 3, 7, 22, 0);
      final rolled = nextCalendarDay(d);
      expect(rolled.day, 8);
      expect(rolled.hour, 22);
      expect(d.add(const Duration(days: 1)).hour, 23,
          reason: 'guards the regression being fixed');
    });
  });

  group('ordinary (non-DST) behaviour is unchanged', () {
    test('a time later today is today', () {
      final now = tz.TZDateTime(ny, 2026, 6, 10, 9, 0);
      final next = nextInstanceOf(now, 21, 30);
      expect(next.day, 10);
      expect(next.hour, 21);
      expect(next.minute, 30);
    });

    test('a time already past rolls to tomorrow', () {
      final now = tz.TZDateTime(ny, 2026, 6, 10, 22, 0);
      final next = nextInstanceOf(now, 21, 30);
      expect(next.day, 11);
      expect(next.hour, 21);
    });

    test('month/year rollover is handled by calendar normalisation', () {
      final now = tz.TZDateTime(ny, 2026, 12, 31, 23, 59);
      final next = nextInstanceOf(now, 8, 0);
      expect(next.year, 2027);
      expect(next.month, 1);
      expect(next.day, 1);
      expect(next.hour, 8);
    });

    test('the weekday walk always lands on the requested weekday', () {
      for (var day = 1; day <= 28; day++) {
        final now = tz.TZDateTime(ny, 2026, 4, day, 12, 0);
        for (var wd = DateTime.monday; wd <= DateTime.sunday; wd++) {
          final next = nextInstanceOf(now, 18, 0, weekday: wd);
          expect(next.weekday, wd);
          expect(next.hour, 18);
          expect(next.isAfter(now), isTrue);
        }
      }
    });
  });

  group('nextDailyInstant resolves against the clock it is given', () {
    setUpAll(() => tz.setLocalLocation(ny));

    test('a pass that read 07:59 still gets today, one that read 08:01 tomorrow',
        () {
      final svc = NotificationService.instance;
      final before = tz.TZDateTime(ny, 2026, 6, 10, 7, 59, 59);
      final after = tz.TZDateTime(ny, 2026, 6, 10, 8, 0, 1);
      expect(svc.nextDailyInstant(8, 0, now: before).day, 10);
      expect(svc.nextDailyInstant(8, 0, now: after).day, 11);
    });
  });
}
