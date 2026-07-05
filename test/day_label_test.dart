// Today-label consistency: the UI detail cards, the repository's today
// fallback, the coach prompt, and LocalDb's day filing must all agree on ONE
// local-calendar "today" — even when the LOCAL date differs from the UTC date
// (for a UTC+5:30 user that's every day until ~05:30). The old code computed
// "today" via DateTime.now().toUtc()...substring(0, 10) in the UI/repo/coach
// while the day model keyed days by the LOCAL label, so detail cards looked up
// a day_id that didn't match the summary's. These tests pin the shared helper
// (lib/data/day_label.dart) to local-calendar semantics with an injected clock.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  test('dayLabelOf labels by LOCAL calendar date, zero-padded', () {
    expect(dayLabelOf(DateTime(2026, 7, 3, 0, 30)), '2026-07-03');
    expect(dayLabelOf(DateTime(2026, 1, 9, 23, 59, 59)), '2026-01-09');
    expect(dayLabelOf(DateTime(999, 2, 5)), '0999-02-05');
  });

  test('a UTC instant is labeled by its LOCAL calendar date', () {
    // The same instant expressed in UTC must produce the same LOCAL label —
    // the helper converts before extracting the date.
    final local = DateTime(2026, 7, 3, 0, 30); // just after local midnight
    expect(dayLabelOf(local.toUtc()), dayLabelOf(local));
    expect(dayLabelOf(local.toUtc()), '2026-07-03');
  });

  test(
      'injected-clock todayLabel == the day model label; the old UTC "today" '
      'diverges across a local/UTC date mismatch', () {
    final offset = DateTime(2026, 7, 3).timeZoneOffset;

    // Pick a boundary instant for THIS machine's zone so local date != UTC date
    // (skip the divergence assertion on a UTC machine — no mismatch exists).
    DateTime? boundary;
    if (offset > const Duration(minutes: 30)) {
      boundary = DateTime(2026, 7, 3, 0, 15); // east of UTC: UTC is yesterday
    } else if (offset < -const Duration(minutes: 30)) {
      boundary = DateTime(2026, 7, 3, 23, 45); // west of UTC: UTC is tomorrow
    }
    if (boundary != null) {
      final localLabel = todayLabel(boundary);
      final oldUtcLabel =
          boundary.toUtc().toIso8601String().substring(0, 10);
      expect(localLabel, '2026-07-03');
      // The bug this suite guards against: the UTC computation names a
      // DIFFERENT day than the one the day model files data under.
      expect(oldUtcLabel, isNot(localLabel));
    }

    // What the detail cards pass (todayLabel) is exactly what getToday /
    // LocalDb file the day under (localDayLabelNow delegates to todayLabel).
    expect(LocalDb.localDayLabelNow(), todayLabel());
  });
}
