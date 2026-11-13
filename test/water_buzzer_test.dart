// Tests for WaterBuzzer's lateness check. Dart timers run on the monotonic
// clock, which stalls while the device sleeps, so a timer armed for a 21:00
// slot can expire hours later in wall-clock terms. A strap buzz at 01:30 for a
// reminder the notification already delivered is worse than no buzz.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/water_buzzer.dart';

class _Harness {
  int buzzes = 0;
  late DateTime wall;
  late WaterBuzzer buzzer;

  _Harness(this.wall) {
    buzzer = WaterBuzzer(
      buzz: () async => buzzes++,
      isConnected: () => true,
      now: () => wall,
    );
  }
}

void main() {
  // 20:59:59 with a 21:00 slot arms a 1 s timer.
  final armedAt = DateTime(2026, 10, 22, 20, 59, 59);
  const slot = 21 * 60;

  test('buzzes when the timer fires at the slot', () async {
    final h = _Harness(armedAt);
    h.buzzer.configure(enabled: true, slotMinutes: [slot]);
    h.wall = DateTime(2026, 10, 22, 21);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(h.buzzes, 1);
    h.buzzer.dispose();
  });

  test('does not buzz when the timer fires hours late', () async {
    final h = _Harness(armedAt);
    h.buzzer.configure(enabled: true, slotMinutes: [slot]);
    // The phone slept: wall-clock reached 01:30 before the timer expired.
    h.wall = DateTime(2026, 10, 23, 1, 30);

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(h.buzzes, 0);
    h.buzzer.dispose();
  });

  // The first slot tomorrow must land at its wall-clock minute even when the
  // night in between is 23 h or 25 h long. Walks every evening of a year so a
  // DST transition is crossed whenever the process timezone has one (in UTC
  // this only pins the ordinary-night behaviour).
  test('first slot tomorrow lands at its wall-clock minute every night', () {
    const first = 7 * 60;
    final h = _Harness(DateTime(2026, 1, 1, 21, 30));
    for (var d = 0; d < 366; d++) {
      final evening = DateTime(2026, 1, 1 + d, 21, 30, 15);
      h.wall = evening;
      h.buzzer.configure(enabled: true, slotMinutes: [first, 20 * 60]);
      final due = h.buzzer.debugDue!;
      expect(due.hour * 60 + due.minute, first, reason: '$evening -> $due');
      expect(due.day, DateTime(evening.year, evening.month, evening.day + 1).day,
          reason: '$evening -> $due');
    }
    h.buzzer.dispose();
  });
}
