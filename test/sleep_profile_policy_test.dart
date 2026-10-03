// Regression coverage for the rolling sleep-profile fold rules.
//
// The motivating defect, from a real user export: `sleep_user_profile` held
// `"nights": 1348` against 12 days of data, because the EWMA fold ran on every
// staging pass rather than once per day. That saturated `personalWeight` at its
// 0.5 cap immediately and collapsed the EWMA onto the most recently re-derived
// day. Replaying that profile over the same 11 nights moved wake 4.3% → 36.4%
// and deep 1.9% → 0.0% on the worst night.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_profile_policy.dart';

String _payload({List<String>? foldedDays, int nights = 0}) => jsonEncode({
      'nights': nights,
      'hr_sleep_median': 52.5,
      SleepProfilePolicy.foldedDaysKey: ?foldedDays,
    });

void main() {
  group('fold idempotency (the nights:1348 bug)', () {
    test('a day already folded is never folded again', () {
      final folded = SleepProfilePolicy.foldedDays(
          _payload(foldedDays: ['2026-07-30'], nights: 1));
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: folded, dayId: '2026-07-30', hasOverride: false),
        isFalse,
      );
    });

    test('a day not yet folded is folded once', () {
      final folded = SleepProfilePolicy.foldedDays(
          _payload(foldedDays: ['2026-07-30'], nights: 1));
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: folded, dayId: '2026-07-31', hasOverride: false),
        isTrue,
      );
    });

    test('repeated staging passes over the same days cannot inflate nights',
        () {
      // Simulate what actually happened: 12 real days, re-derived 100x each.
      var folded = <String>{};
      var foldCount = 0;
      final days = [for (var d = 20; d < 32; d++) '2026-07-$d'];
      for (var pass = 0; pass < 100; pass++) {
        for (final day in days) {
          if (SleepProfilePolicy.shouldFold(
              alreadyFolded: folded, dayId: day, hasOverride: false)) {
            foldCount++;
            folded = {...SleepProfilePolicy.appendFoldedDay(folded, day)};
          }
        }
      }
      expect(foldCount, days.length, reason: 'one fold per distinct day');
      expect(folded.length, days.length);
    });

    test('a night still in progress at the data edge does not fold', () {
      final dayEnd = DateTime(2026, 7, 31).millisecondsSinceEpoch ~/ 1000 - 1;
      // 00:15 on the day: an hour of a night that is still going.
      expect(
          SleepProfilePolicy.nightOver(
              dataEdgeSec: dayEnd - 86400 + 900, dayEndSec: dayEnd),
          isFalse);
      expect(SleepProfilePolicy.nightOver(dataEdgeSec: null, dayEndSec: dayEnd),
          isFalse);
      expect(
          SleepProfilePolicy.nightOver(
              dataEdgeSec: dayEnd + 60, dayEndSec: dayEnd),
          isTrue);
    });

    test('an override night never folds — the window is asserted, not measured',
        () {
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: const {}, dayId: '2026-07-31', hasOverride: true),
        isFalse,
      );
    });

    test('skipping an override records nothing, so the POLICY stays eligible',
        () {
      // Scope note, because the obvious reading of this test is wrong:
      // it asserts the POLICY only. Declining to fold an override records
      // nothing in folded_days, so `shouldFold` keeps saying yes afterwards.
      // Worth pinning because the tempting alternative — marking it folded to
      // "remember we skipped it" — would exclude that night permanently.
      //
      // It does NOT assert that the engine actually re-folds after an override
      // is removed. It often will not: `_sleepCandidateForDay` short-circuits
      // on a cached finalized candidate before staging runs, so a day that had
      // a candidate cached before the override was applied never regenerates an
      // observation. See the KNOWN LIMITATION comment at the fold call site.
      const day = '2026-07-31';
      var folded = <String>{};
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: folded, dayId: day, hasOverride: true),
        isFalse,
      );
      expect(folded, isEmpty, reason: 'a skipped override records nothing');
      // user deletes the override, day is re-derived
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: folded, dayId: day, hasOverride: false),
        isTrue,
      );
      folded = {...SleepProfilePolicy.appendFoldedDay(folded, day)};
      // ...and still only once thereafter
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: folded, dayId: day, hasOverride: false),
        isFalse,
      );
    });
  });

  group('minimum-nights warm-up gate', () {
    test('withholds the profile below the floor', () {
      expect(SleepProfilePolicy.shouldBlend(0), isFalse);
      expect(SleepProfilePolicy.shouldBlend(1), isFalse);
      expect(SleepProfilePolicy.shouldBlend(2), isFalse);
    });

    test('applies the profile at and above the floor', () {
      expect(SleepProfilePolicy.shouldBlend(3), isTrue);
      expect(SleepProfilePolicy.shouldBlend(30), isTrue);
    });

    test('a null nights count never blends', () {
      expect(SleepProfilePolicy.shouldBlend(null), isFalse);
    });
  });

  group('legacy payloads are discarded, not trusted', () {
    test('a pre-tracking profile is legacy and yields a cold start', () {
      final legacy = _payload(nights: 1348); // no folded_days key
      expect(SleepProfilePolicy.isLegacy(legacy), isTrue);
      expect(SleepProfilePolicy.usableProfileJson(legacy), isNull);
    });

    test('a tracked profile survives unchanged', () {
      final tracked = _payload(foldedDays: ['2026-07-30'], nights: 1);
      expect(SleepProfilePolicy.isLegacy(tracked), isFalse);
      expect(SleepProfilePolicy.usableProfileJson(tracked), tracked);
    });

    test('null and corrupt payloads are cold starts but not "legacy"', () {
      for (final bad in [null, '', 'not json', '[1,2,3]']) {
        expect(SleepProfilePolicy.usableProfileJson(bad), isNull);
        expect(SleepProfilePolicy.isLegacy(bad), isFalse);
        expect(SleepProfilePolicy.foldedDays(bad), isEmpty);
      }
    });

    test('a tracked-but-empty profile is usable (mid-rebuild, not legacy)', () {
      final rebuilding = _payload(foldedDays: const [], nights: 0);
      expect(SleepProfilePolicy.isLegacy(rebuilding), isFalse);
      expect(SleepProfilePolicy.usableProfileJson(rebuilding), rebuilding);
    });
  });

  group('concurrent-fold semantics (DB transaction contract)', () {
    // The real serialization is an exclusive SQLite transaction in
    // LocalDb.updateBaseline — a Dart lock cannot span isolates. What is
    // testable here without a DB is the PURE contract the transaction body
    // relies on: given the payload as it exists at commit time, decide once.
    //
    // These model the transaction body running serially (which is what the
    // exclusive write lock guarantees) and assert the outcome is correct for
    // any interleaving.

    String? foldInto(String? current, String dayId) {
      final usable = SleepProfilePolicy.usableProfileJson(current);
      final days = SleepProfilePolicy.foldedDays(usable);
      if (!SleepProfilePolicy.shouldFold(
          alreadyFolded: days, dayId: dayId, hasOverride: false)) {
        return null; // leave the row untouched
      }
      final nights = usable == null
          ? 0
          : ((jsonDecode(usable) as Map)['nights'] as num?)?.toInt() ?? 0;
      return jsonEncode(SleepProfilePolicy.withFoldedDays(
          {'nights': nights + 1}, days, dayId));
    }

    test('two lanes folding the SAME day commit exactly one fold', () {
      // The case the old test failed to cover: BOTH lanes see an empty
      // folded_days when they start. Serialized at commit time, the second
      // must observe the first's write and decline.
      var row = jsonEncode({'nights': 0, 'folded_days': <String>[]});
      var writes = 0;
      for (var lane = 0; lane < 2; lane++) {
        final next = foldInto(row, '2026-07-30');
        if (next != null) {
          row = next;
          writes++;
        }
      }
      expect(writes, 1, reason: 'the second lane must see the first write');
      final decoded = jsonDecode(row) as Map;
      expect(decoded['nights'], 1);
      expect(decoded[SleepProfilePolicy.foldedDaysKey], ['2026-07-30']);
    });

    test('distinct days each commit once and none is lost', () {
      var row = jsonEncode({'nights': 0, 'folded_days': <String>[]});
      final days = ['2026-07-28', '2026-07-29', '2026-07-30', '2026-07-31'];
      for (final d in days) {
        final next = foldInto(row, d);
        if (next != null) row = next;
      }
      final decoded = jsonDecode(row) as Map;
      expect(decoded['nights'], days.length);
      expect((decoded[SleepProfilePolicy.foldedDaysKey] as List).cast<String>(),
          days);
    });

    test('a stale pre-staging read cannot resurrect an already-folded day', () {
      // Lane A read an empty profile, went off to stage for 90s, and comes back
      // to find lane B folded the same day. Re-checking against the CURRENT row
      // (what the transaction body does) is what prevents the double count.
      const staleView = '{"nights":0,"folded_days":[]}';
      final committed = jsonEncode({
        'nights': 1,
        'folded_days': const ['2026-07-30'],
      });
      expect(
        SleepProfilePolicy.shouldFold(
          alreadyFolded: SleepProfilePolicy.foldedDays(staleView),
          dayId: '2026-07-30',
          hasOverride: false,
        ),
        isTrue,
        reason: 'the stale view alone would wrongly permit a second fold',
      );
      expect(foldInto(committed, '2026-07-30'), isNull,
          reason: 'deciding against the committed row declines correctly');
    });

    test('a legacy row is discarded, not merged into', () {
      final legacy = jsonEncode({'nights': 1348}); // no folded_days
      final next = foldInto(legacy, '2026-07-30');
      expect(next, isNotNull);
      final decoded = jsonDecode(next!) as Map;
      expect(decoded['nights'], 1,
          reason: 'rebuild from cold start, not from 1348');
      expect(decoded[SleepProfilePolicy.foldedDaysKey], ['2026-07-30']);
    });
  });

  group('folded-day bookkeeping', () {
    test('append is sorted and de-duplicated', () {
      final out = SleepProfilePolicy.appendFoldedDay(
          {'2026-07-31', '2026-07-29'}, '2026-07-30');
      expect(out, ['2026-07-29', '2026-07-30', '2026-07-31']);
      expect(SleepProfilePolicy.appendFoldedDay(out.toSet(), '2026-07-30'),
          hasLength(3));
    });

    test('eviction is chronological for real day labels', () {
      // The cap sorts lexicographically, which only means "age" for zero-padded
      // ISO dates. Pin it across a month and year boundary, where a naive
      // non-padded format would misorder.
      var days = <String>{};
      for (final d in [
        '2025-12-30',
        '2025-12-31',
        '2026-01-01',
        '2026-01-02',
        '2026-01-09',
        '2026-01-10',
      ]) {
        days = {...SleepProfilePolicy.appendFoldedDay(days, d)};
      }
      expect(days.toList(), [
        '2025-12-30',
        '2025-12-31',
        '2026-01-01',
        '2026-01-02',
        '2026-01-09',
        '2026-01-10',
      ]);
    });

    test('a non-date day_id trips the precondition', () {
      // A UUID or epoch string would break the sort, so a RECENT day could be
      // evicted and then re-folded — the exact bug this class prevents.
      expect(
        () => SleepProfilePolicy.appendFoldedDay(const {}, '1785522024'),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => SleepProfilePolicy.appendFoldedDay(const {}, '2026-7-4'),
        throwsA(isA<AssertionError>()),
        reason: 'unpadded dates sort wrong too',
      );
    });

    test('the set is capped, evicting the oldest', () {
      String label(int i) {
        final d = DateTime.utc(2020, 1, 1).add(Duration(days: i));
        return '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
      }

      const overflow = 50;
      const total = SleepProfilePolicy.maxFoldedDays + overflow;
      var days = <String>{};
      for (var i = 0; i < total; i++) {
        days = {...SleepProfilePolicy.appendFoldedDay(days, label(i))};
      }
      expect(days, hasLength(SleepProfilePolicy.maxFoldedDays));
      expect(days.contains(label(0)), isFalse, reason: 'oldest evicted');
      expect(days.contains(label(overflow - 1)), isFalse,
          reason: 'everything past the cap is evicted, oldest first');
      expect(days.contains(label(overflow)), isTrue,
          reason: 'the first surviving day');
      expect(days.contains(label(total - 1)), isTrue, reason: 'newest kept');
    });

    test('withFoldedDays stamps the key without disturbing profile fields', () {
      final stamped = SleepProfilePolicy.withFoldedDays(
        {'nights': 4, 'hr_sleep_median': 52.5},
        {'2026-07-30'},
        '2026-07-31',
      );
      expect(stamped['nights'], 4);
      expect(stamped['hr_sleep_median'], 52.5);
      expect(stamped[SleepProfilePolicy.foldedDaysKey],
          ['2026-07-30', '2026-07-31']);
    });

    test('round-trips through JSON so the next pass reads what we wrote', () {
      final stamped = SleepProfilePolicy.withFoldedDays(
          {'nights': 1}, const {}, '2026-07-31');
      final reread = SleepProfilePolicy.foldedDays(jsonEncode(stamped));
      expect(reread, {'2026-07-31'});
      expect(
        SleepProfilePolicy.shouldFold(
            alreadyFolded: reread, dayId: '2026-07-31', hasOverride: false),
        isFalse,
        reason: 'the day we just folded must not fold again next pass',
      );
    });
  });
}
