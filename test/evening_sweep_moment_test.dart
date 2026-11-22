// An evening sweep opened from its notification the next morning (or just
// after midnight) is still about last night: reading or regenerating it for
// the new day reported on a barely-started day and filled tonight's slot,
// which then blocked tonight's real sweep.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/data/day_label.dart';

void main() {
  test('evening window: the sweep is about today', () {
    final now = DateTime(2026, 11, 20, 22, 30);
    expect(eveningSweepMoment(now), now);
  });

  test('next morning: the sweep is about yesterday', () {
    final at = eveningSweepMoment(DateTime(2026, 11, 21, 8));
    expect(todayLabel(at), '2026-11-20');
  });

  test('just after midnight: still yesterday', () {
    final at = eveningSweepMoment(DateTime(2026, 11, 21, 0, 10));
    expect(todayLabel(at), '2026-11-20');
  });

  test('today slot already written (early slot): about today', () {
    final now = DateTime(2026, 11, 21, 10, 5);
    expect(eveningSweepMoment(now, todayCached: true), now);
  });

  test('first of the month: yesterday is the last day of last month', () {
    final at = eveningSweepMoment(DateTime(2026, 12, 1, 8));
    expect(todayLabel(at), '2026-11-30');
  });

  test('early resolved slot passed: about today even before 17:00', () {
    final now = DateTime(2026, 11, 21, 15, 5);
    expect(eveningSweepMoment(now, eveningMin: 15 * 60), now);
    expect(todayLabel(eveningSweepMoment(now)), '2026-11-20');
  });

  test('after 17:00 but before a late slot: still about today', () {
    final now = DateTime(2026, 11, 21, 19);
    expect(eveningSweepMoment(now, eveningMin: 23 * 60), now);
  });
}
