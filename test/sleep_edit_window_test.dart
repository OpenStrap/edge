// Editing a night's bed and wake times. The bedtime is a clock time, and it
// lands on whichever side of midnight is next to the measured onset; pinning
// it to the onset's own date moved the correction a whole night.

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart'
    show correctedSleepWindow;

void main() {
  const seven = TimeOfDay(hour: 7, minute: 0);

  test('a 23:30 bedtime over a 00:30 onset is the evening before', () {
    final (on, off) = correctedSleepWindow(
        DateTime(2026, 8, 19, 0, 30), DateTime(2026, 8, 19, 6, 40),
        const TimeOfDay(hour: 23, minute: 30), seven);
    expect(on, DateTime(2026, 8, 18, 23, 30));
    expect(off, DateTime(2026, 8, 19, 7, 0));
  });

  test('a 00:15 bedtime over a 23:30 onset is just after midnight', () {
    final (on, off) = correctedSleepWindow(
        DateTime(2026, 8, 18, 23, 30), DateTime(2026, 8, 19, 6, 40),
        const TimeOfDay(hour: 0, minute: 15), seven);
    expect(on, DateTime(2026, 8, 19, 0, 15));
    expect(off, DateTime(2026, 8, 19, 7, 0));
  });

  test('a same-side correction keeps the dates', () {
    final (on, off) = correctedSleepWindow(
        DateTime(2026, 8, 18, 22, 40), DateTime(2026, 8, 19, 6, 40),
        const TimeOfDay(hour: 23, minute: 10),
        const TimeOfDay(hour: 6, minute: 30));
    expect(on, DateTime(2026, 8, 18, 23, 10));
    expect(off, DateTime(2026, 8, 19, 6, 30));
  });

  test('a picker left on the measured time keeps the measured instant', () {
    final onset = DateTime(2026, 8, 18, 23, 10, 47);
    final (on, off) = correctedSleepWindow(onset, DateTime(2026, 8, 19, 6, 40),
        const TimeOfDay(hour: 23, minute: 10), seven);
    expect(on, onset);
    expect(off, DateTime(2026, 8, 19, 7, 0));
  });
}
