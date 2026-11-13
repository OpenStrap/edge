// The day-strain curve sits under a fixed 00:00–24:00 axis. It used to slot
// each point by minutes ELAPSED since local midnight, so on a fall-back day
// (1500 minutes) everything after the repeated hour landed an hour late and
// 23:00–24:00 fell off the end of the grid, and on a spring-forward day
// (1380 minutes) everything after the gap landed an hour early.
//
// The DST cases only bite when the test machine's local zone observes DST;
// they search the year for such days and skip when there are none.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';

DateTime? _firstDayOfLength(int seconds) {
  for (var d = DateTime(2026, 1, 1);
      d.year == 2026;
      d = DateTime(d.year, d.month, d.day + 1)) {
    if (localDayLengthSec(dayLabelOf(d)) == seconds) return d;
  }
  return null;
}

/// One point per minute of [day], value = the minute's sequence number, so a
/// cumulative curve whose last point is the largest.
List<(int, double)> _everyMinute(DateTime day) {
  final start = day.millisecondsSinceEpoch ~/ 1000;
  final len = localDayLengthSec(dayLabelOf(day))!;
  return [
    for (var s = 0; s < len; s += 60) (start + s, (s ~/ 60).toDouble()),
  ];
}

void main() {
  test('an ordinary day maps every point to its clock minute', () {
    final day = DateTime(2026, 6, 10);
    final (got, grid) = DayStrainData.gridCurve(_everyMinute(day));
    expect(got, day);
    expect(grid.length, 1440);
    expect(grid.every((v) => v != null), isTrue);
    expect(grid[23 * 60 + 30], 1410);
  });

  test('fall-back day keeps the last hour and draws it at its clock time', () {
    final day = _firstDayOfLength(90000);
    if (day == null) {
      markTestSkipped('local zone has no fall-back day');
      return;
    }
    final pts = _everyMinute(day);
    final (_, grid) = DayStrainData.gridCurve(pts);
    expect(grid.length, 1440);
    // The final point is the end of the cumulative curve — the headline.
    expect(grid[1439], pts.last.$2);
    // A late-evening sample lands under its own clock minute.
    final t = DateTime(day.year, day.month, day.day, 23, 10);
    final want = pts
        .firstWhere((p) => p.$1 == t.millisecondsSinceEpoch ~/ 1000)
        .$2;
    expect(grid[23 * 60 + 10], want);
    expect(grid.every((v) => v != null), isTrue);
  });

  test('spring-forward day draws points after the gap at their clock time',
      () {
    final day = _firstDayOfLength(82800);
    if (day == null) {
      markTestSkipped('local zone has no spring-forward day');
      return;
    }
    final pts = _everyMinute(day);
    final (_, grid) = DayStrainData.gridCurve(pts);
    expect(grid[1439], pts.last.$2);
    final t = DateTime(day.year, day.month, day.day, 20, 0);
    final want = pts
        .firstWhere((p) => p.$1 == t.millisecondsSinceEpoch ~/ 1000)
        .$2;
    expect(grid[20 * 60], want);
    // Exactly the skipped hour stays empty.
    expect(grid.where((v) => v == null).length, 60);
  });

  test('points from another local day are ignored', () {
    final day = DateTime(2026, 6, 10);
    final next = DateTime(2026, 6, 11, 0, 5).millisecondsSinceEpoch ~/ 1000;
    final (_, grid) =
        DayStrainData.gridCurve([..._everyMinute(day), (next, 9999)]);
    expect(grid.contains(9999), isFalse);
  });
}
