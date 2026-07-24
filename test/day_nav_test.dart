// Pure unit tests for the lookback day-navigation maths (issue #112): the
// prev/next/earliest bounds over a set of recorded days. No Flutter, no repo,
// no DB — [DayNav] is intentionally a pure string helper so these rules (never
// past today, stop at the earliest day, skip empty gaps) are exhaustively
// testable.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/journey/day_nav.dart';

void main() {
  group('DayNav.navigableDays', () {
    test('always includes today and drops anything after it', () {
      final nav = DayNav.navigableDays(
        ['2026-07-25', '2026-07-19', '2026-07-30'], // 07-30 is in the future
        '2026-07-24',
      );
      expect(nav, ['2026-07-19', '2026-07-24']);
      // The future 07-30 and 07-25 (also > today) are excluded; today is added.
      expect(nav.contains('2026-07-30'), isFalse);
      expect(nav.contains('2026-07-25'), isFalse);
      expect(nav.contains('2026-07-24'), isTrue);
    });

    test('is sorted ascending and de-duplicated', () {
      final nav = DayNav.navigableDays(
        ['2026-07-20', '2026-07-18', '2026-07-20'],
        '2026-07-22',
      );
      expect(nav, ['2026-07-18', '2026-07-20', '2026-07-22']);
    });

    test('keeps the current day reachable even if not in the recorded set', () {
      // A viewed day that has no data row must still be a valid bound.
      final nav = DayNav.navigableDays(
        const ['2026-07-20'],
        '2026-07-24',
        current: '2026-07-15',
      );
      expect(nav, ['2026-07-15', '2026-07-20', '2026-07-24']);
    });

    test('a future current is NOT admitted (cannot strand into tomorrow)', () {
      final nav = DayNav.navigableDays(
        const [],
        '2026-07-24',
        current: '2026-07-25',
      );
      expect(nav, ['2026-07-24']);
    });

    test('empty available yields today-only', () {
      expect(DayNav.navigableDays(const [], '2026-07-24'), ['2026-07-24']);
    });
  });

  group('DayNav.next / prev', () {
    final days = ['2026-07-10', '2026-07-12', '2026-07-20', '2026-07-24'];

    test('next steps to the immediately later recorded day (skips gaps)', () {
      expect(DayNav.next('2026-07-12', days), '2026-07-20'); // skips 13..19
      expect(DayNav.next('2026-07-10', days), '2026-07-12');
    });

    test('next is null at the latest day (never into the future)', () {
      expect(DayNav.next('2026-07-24', days), isNull);
    });

    test('prev steps to the immediately earlier recorded day (skips gaps)', () {
      expect(DayNav.prev('2026-07-20', days), '2026-07-12');
      expect(DayNav.prev('2026-07-24', days), '2026-07-20');
    });

    test('prev is null at the earliest day', () {
      expect(DayNav.prev('2026-07-10', days), isNull);
    });

    test('next/prev from a day between recorded days lands on neighbours', () {
      // Current 07-15 is not itself in the set (e.g. an empty gap the user
      // reached via the picker): next → 07-20, prev → 07-12.
      expect(DayNav.next('2026-07-15', days), '2026-07-20');
      expect(DayNav.prev('2026-07-15', days), '2026-07-12');
    });

    test('order of the input does not matter', () {
      final shuffled = ['2026-07-24', '2026-07-10', '2026-07-20', '2026-07-12'];
      expect(DayNav.next('2026-07-12', shuffled), '2026-07-20');
      expect(DayNav.prev('2026-07-20', shuffled), '2026-07-12');
    });
  });

  group('DayNav.earliest', () {
    test('returns the minimum day', () {
      expect(
        DayNav.earliest(['2026-07-20', '2026-07-10', '2026-07-24']),
        '2026-07-10',
      );
    });

    test('null on empty', () {
      expect(DayNav.earliest(const []), isNull);
    });
  });

  group('end-to-end stepping walks the whole recorded range without escaping',
      () {
    test('walk back to earliest, forward to today, never past either bound', () {
      final nav = DayNav.navigableDays(
        ['2026-07-18', '2026-07-21'],
        '2026-07-24',
      ); // → [18, 21, 24]
      // Start at today, step back to the earliest.
      var cur = '2026-07-24';
      cur = DayNav.prev(cur, nav)!; // 21
      expect(cur, '2026-07-21');
      cur = DayNav.prev(cur, nav)!; // 18
      expect(cur, '2026-07-18');
      expect(DayNav.prev(cur, nav), isNull); // stop at earliest
      // Step forward back to today.
      cur = DayNav.next(cur, nav)!; // 21
      expect(cur, '2026-07-21');
      cur = DayNav.next(cur, nav)!; // 24
      expect(cur, '2026-07-24');
      expect(DayNav.next(cur, nav), isNull); // stop at today
    });
  });
}
