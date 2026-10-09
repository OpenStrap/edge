import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/movement_floor_policy.dart';
import 'package:openstrap_edge/data/day_label.dart' show dayLabelBefore;

/// The frozen movement floor is ONE shared scalar that every day of a derive
/// sweep reads and can write. `DerivationEngine.run()` dispatches days
/// NEWEST-FIRST through a concurrent worker pool, and the v56 bump forces the
/// whole retained window to re-derive at once — so these decisions must be
/// order-independent, or sweep order silently decides every day's `active_min`.
void main() {
  group('dayLabelBefore — calendar, never Duration', () {
    test('does not skip the spring-forward day', () {
      // 2026-03-08 is 23 h long in a US timezone. `subtract(Duration(days: 2))`
      // from local midnight on 03-10 lands at 23:00 on 03-07, so the walk-back
      // NEVER GENERATES 2026-03-08 and the gap is counted against the wrong
      // days. Calendar-field construction cannot do this.
      expect(dayLabelBefore('2026-03-10', 1), '2026-03-09');
      expect(dayLabelBefore('2026-03-10', 2), '2026-03-08');
      expect(dayLabelBefore('2026-03-10', 3), '2026-03-07');
    });

    test('crosses month and year boundaries', () {
      expect(dayLabelBefore('2026-03-01', 1), '2026-02-28');
      expect(dayLabelBefore('2026-01-01', 1), '2025-12-31');
      expect(dayLabelBefore('2024-03-01', 1), '2024-02-29'); // leap year
    });

    test('an unparseable label yields null rather than a wrong date', () {
      expect(dayLabelBefore('not-a-date', 1), isNull);
    });
  });

  group('wearGapDays', () {
    test('no gap when yesterday has data', () {
      expect(
        wearGapDays(have: {'2026-03-09', '2026-03-08'}, dayId: '2026-03-10'),
        0,
      );
    });

    test('counts the consecutive run of missing days', () {
      expect(
        wearGapDays(have: {'2026-03-05'}, dayId: '2026-03-10'),
        4, // 03-09, 03-08, 03-07, 03-06 missing; 03-05 present -> stop
      );
    });

    test('spans a DST transition without miscounting', () {
      // 03-08 is present, so the gap is exactly one day (03-09). The Duration
      // walk-back skipped 03-08 entirely and reported a longer gap here.
      expect(
        wearGapDays(have: {'2026-03-08'}, dayId: '2026-03-10'),
        1,
      );
    });

    test('walks bare day labels across month and year boundaries', () {
      // `dayLabelBefore` now lives in day_label.dart with its strict
      // `YYYY-MM-DD` parse; the engine's only caller passes bare labels, and
      // this pins that its answer is unchanged.
      expect(
        wearGapDays(have: {'2025-12-30'}, dayId: '2026-01-02'),
        2, // 01-01, 12-31 missing; 12-30 present -> stop
      );
      expect(
        wearGapDays(have: {'2024-02-28'}, dayId: '2024-03-01'),
        1, // 02-29 (leap day) missing
      );
    });

    test('an EMPTY history is no information, not a 60-day gap', () {
      // A brand-new install must not trip the >=30-day re-freeze rule purely
      // because it has no history yet.
      expect(wearGapDays(have: const {}, dayId: '2026-03-10'), 0);
    });

    test('is bounded by maxScan', () {
      expect(
        wearGapDays(have: {'2020-01-01'}, dayId: '2026-03-10', maxScan: 12),
        12,
      );
    });
  });

  group('daysSinceFrozen — never negative', () {
    test('a later day reports real age', () {
      expect(daysSinceFrozen(frozenOn: '2026-03-01', dayId: '2026-03-11'), 10);
    });

    test('a BACKFILL day is age 0, not its absolute distance', () {
      // This is the bug the clamp fixes. With `.abs()`, re-deriving a day from
      // more than `maxAgeDays` before the freeze read as maximally stale and
      // re-froze the shared floor onto an OLDER frozenOn — during a
      // newest-first sweep, i.e. on every kAlgoVersion bump.
      expect(daysSinceFrozen(frozenOn: '2026-03-01', dayId: '2024-01-01'), 0);
      expect(daysSinceFrozen(frozenOn: '2026-03-01', dayId: '2026-02-28'), 0);
    });

    test('same day is 0', () {
      expect(daysSinceFrozen(frozenOn: '2026-03-01', dayId: '2026-03-01'), 0);
    });
  });

  group('mayCommitFloorOn — the floor only moves forward', () {
    test('nothing frozen yet: any day may establish it', () {
      expect(mayCommitFloorOn(frozenOn: null, dayId: '2026-03-01'), isTrue);
    });

    test('a newer day may re-freeze', () {
      expect(
        mayCommitFloorOn(frozenOn: '2026-03-01', dayId: '2026-03-02'),
        isTrue,
      );
    });

    test('an OLDER day may consume but never move the floor', () {
      // Otherwise the oldest day of a newest-first concurrent sweep could
      // clobber the freeze the newest day just established, making every day's
      // active_min depend on which worker finished last.
      expect(
        mayCommitFloorOn(frozenOn: '2026-03-10', dayId: '2026-03-01'),
        isFalse,
      );
    });

    test('re-freezing on the same day is allowed', () {
      expect(
        mayCommitFloorOn(frozenOn: '2026-03-10', dayId: '2026-03-10'),
        isTrue,
      );
    });
  });
}
