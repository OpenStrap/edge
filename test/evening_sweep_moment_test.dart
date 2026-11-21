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
}
