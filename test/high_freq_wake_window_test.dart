import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';

void main() {
  Map<String, dynamic> rowForWake(DateTime wake) => {
    'window_json': '{"value":{"offset_ms":${wake.millisecondsSinceEpoch}}}',
  };

  test('enables inside the 90 minute wake window from habitual wake', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 28)),
      rowForWake(DateTime(2026, 6, 26, 7, 31)),
    ];
    final now = DateTime(2026, 6, 29, 6, 45);
    final plan = HighFreqWakeWindow.planFromRows(rows, now);
    expect(plan.shouldEnable, isTrue);
    expect(plan.source, 'habitual_wake');
    expect(plan.targetWake, DateTime(2026, 6, 29, 7, 30));
  });

  test('disables outside the wake window', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 29)),
      rowForWake(DateTime(2026, 6, 26, 7, 31)),
    ];
    final now = DateTime(2026, 6, 29, 4, 0);
    final plan = HighFreqWakeWindow.planFromRows(rows, now);
    expect(plan.shouldEnable, isFalse);
    expect(plan.targetWake, DateTime(2026, 6, 29, 7, 30));
  });

  test('requires enough sleep history', () {
    final rows = [
      rowForWake(DateTime(2026, 6, 28, 7, 30)),
      rowForWake(DateTime(2026, 6, 27, 7, 29)),
    ];
    final plan = HighFreqWakeWindow.planFromRows(
      rows,
      DateTime(2026, 6, 29, 6, 45),
    );
    expect(plan.shouldEnable, isFalse);
    expect(plan.targetWake, isNull);
    expect(plan.source, 'insufficient_sleep_history');
  });

  test(
    'scheduled alarm well before habitual wake gets its own lease window',
    () {
      // Habitual wake 07:30 (median over the history). An alarm armed for
      // 05:30 with a 30 min smart window never falls inside the habitual
      // [06:00, 07:30) lease — this is the bug: without the scheduled-window
      // param, `now`=04:45 would get shouldEnable=false and stay stale.
      final rows = [
        rowForWake(DateTime(2026, 6, 28, 7, 30)),
        rowForWake(DateTime(2026, 6, 27, 7, 29)),
        rowForWake(DateTime(2026, 6, 26, 7, 31)),
      ];
      final now = DateTime(2026, 6, 29, 4, 45);
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        now,
        scheduledWindowEnd: DateTime(2026, 6, 29, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'scheduled_alarm');
      expect(plan.targetWake, DateTime(2026, 6, 29, 5, 30));
    },
  );

  test(
    'scheduled window outside its own lease and outside habitual stays disabled',
    () {
      final rows = [
        rowForWake(DateTime(2026, 6, 28, 7, 30)),
        rowForWake(DateTime(2026, 6, 27, 7, 29)),
        rowForWake(DateTime(2026, 6, 26, 7, 31)),
      ];
      final now = DateTime(2026, 6, 29, 2, 0);
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        now,
        scheduledWindowEnd: DateTime(2026, 6, 29, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isFalse);
      expect(plan.source, 'habitual_wake');
    },
  );

  test(
    'habitual window stays the reported source when it alone already enables',
    () {
      final rows = [
        rowForWake(DateTime(2026, 6, 28, 7, 30)),
        rowForWake(DateTime(2026, 6, 27, 7, 28)),
        rowForWake(DateTime(2026, 6, 26, 7, 31)),
      ];
      final now = DateTime(2026, 6, 29, 6, 45);
      final plan = HighFreqWakeWindow.planFromRows(
        rows,
        now,
        scheduledWindowEnd: DateTime(2026, 6, 30, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'habitual_wake');
      expect(plan.targetWake, DateTime(2026, 6, 29, 7, 30));
    },
  );

  test(
    'scheduled window alone still enables with no sleep history at all',
    () {
      final now = DateTime(2026, 6, 29, 4, 45);
      final plan = HighFreqWakeWindow.planFromRows(
        const [],
        now,
        scheduledWindowEnd: DateTime(2026, 6, 29, 5, 30),
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'scheduled_alarm');
    },
  );

  test(
    'the next-day target keeps the habitual wall-clock hour, not a naive '
    '24-elapsed-hours add (DST regression, month boundary too)',
    () {
      // now is already past today's habitual wake, so targetWake must roll
      // to tomorrow — Duration(days: 1) would still land on the right DAY
      // here (no DST in a pure-arithmetic test), but this pins the fix
      // (DateTime(y, m, d+1, h, min)) against a future regression back to
      // the Duration form, the same way alarm_schedule_test.dart's own DST
      // test pins nextAlarmOccurrence's calendar arithmetic.
      final rows = [
        rowForWake(DateTime(2026, 1, 30, 7, 30)),
        rowForWake(DateTime(2026, 1, 29, 7, 29)),
        rowForWake(DateTime(2026, 1, 28, 7, 31)),
      ];
      final now = DateTime(2026, 1, 31, 20, 0); // past 07:30, month-end too
      final plan = HighFreqWakeWindow.planFromRows(rows, now);
      expect(plan.targetWake, DateTime(2026, 2, 1, 7, 30));
      expect(plan.targetWake!.hour, 7);
      expect(plan.targetWake!.minute, 30);
    },
  );
}
