// A day the strap's on-chip step counter ANSWERED is presented from that
// counter, whether or not `live_coverage` also holds phone rows for it.
//
// The counter is a whole-day alternative: the derive only picks it when its
// calibrated total beat every coverage row put together. So the coverage rows
// on such a day are the count the day did NOT publish, and publishing their
// total as the day's figure put a smaller number on this screen than the one
// Home shows for the same day — labelled with the phone, on a day the wrist
// answered.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/day_steps.dart'
    show DayStepsData;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_steps_counter_over_coverage_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a counter day that also has phone hours publishes the counter', () async {
    const day = '2026-03-10';
    final midnight = localDayStartSec(day)!;
    const counterTotal = 12000;

    // The strap's chip answered the day: 12,000 steps in two hourly spans.
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'steps': {
          'value': counterTotal,
          'band_measured': counterTotal,
          'source': 'strap_counter',
          'spans': [
            {
              'start_ts': midnight + 9 * 3600,
              'end_ts': midnight + 10 * 3600 - 1,
              'steps': 4000,
            },
            {
              'start_ts': midnight + 10 * 3600,
              'end_ts': midnight + 11 * 3600 - 1,
              'steps': 8000,
            },
          ],
        },
      }),
      windowJson: '{}',
      finalized: true,
    );

    // …and the phone banked its own, smaller, hours. The ladder lost them to
    // the counter (8,000 < 12,000), which is exactly the state that used to
    // reach the screen as "8,000, counted by your phone".
    await LocalDb.replacePhoneCoverageForDay(day, [
      for (var h = 9; h < 17; h++)
        (
          startTs: midnight + h * 3600,
          endTs: midnight + (h + 1) * 3600 - 1,
          steps: 1000,
        ),
    ]);
    expect(await LocalDb.phoneStepsForDay(day), 8000,
        reason: 'the phone rows are really there, so the old reader saw them');

    final out =
        await LocalRepositoryImpl(getProfileMap: () => null).getDaySteps(day);

    // The day's number is the one it published, and the split sums to it.
    expect(out['day_total'], counterTotal);
    expect(out['day_source'], 'strap_counter');
    expect(out['total'], counterTotal,
        reason: 'the coverage total was the count this day did not publish');
    expect(out['strap'], counterTotal);
    expect(out['phone'], 0);

    // The clock comes from the counter's own spans, never the phone's.
    final spans = (out['spans'] as List).cast<Map>();
    expect(spans.map((s) => s['steps']), [4000, 8000]);
    expect(spans.map((s) => s['start_ts']),
        [midnight + 9 * 3600, midnight + 10 * 3600]);
    expect(spans.every((s) => s['source'] == LocalDb.kStepSourceBand), isTrue);

    // …and the screen passes that one number through untouched: the counter's
    // figure as both the count and what the day published.
    final data = await DayStepsData.load(
        LocalRepositoryImpl(getProfileMap: () => null),
        want: day);
    expect(data.total, counterTotal);
    expect(data.dayTotal, counterTotal);
    expect(data.strap, counterTotal);
    expect(data.phone, 0);
  });

  // An older bundle can carry the counter's count with no hourly spans stored.
  // The day is still a counter day: selecting it by the presence of `spans`
  // dropped it onto the coverage ladder, which returned the phone's smaller
  // total under the counter's name — or zero when the phone had no rows either.
  for (final (label, spans) in [
    ('no spans key at all', const <String, Object?>{}),
    ('spans: null', const {'spans': null}),
  ]) {
    test('a counter day with $label publishes the counter, not the phone',
        () async {
      final day = label == 'spans: null' ? '2026-03-12' : '2026-03-11';
      final midnight = localDayStartSec(day)!;
      const counterTotal = 12500;

      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({
          'steps': {
            'value': counterTotal,
            'band_measured': counterTotal,
            'source': 'strap_counter',
            ...spans,
          },
        }),
        windowJson: '{}',
        finalized: true,
      );
      // The phone banked its own hours for the same day, so falling through to
      // coverage is observable rather than a zero either way.
      await LocalDb.replacePhoneCoverageForDay(day, [
        for (var h = 9; h < 13; h++)
          (
            startTs: midnight + h * 3600,
            endTs: midnight + (h + 1) * 3600 - 1,
            steps: 1000,
          ),
      ]);
      expect(await LocalDb.phoneStepsForDay(day), 4000,
          reason: 'the phone rows are really there');

      final out = await LocalRepositoryImpl(getProfileMap: () => null)
          .getDaySteps(day);

      expect(out['day_source'], 'strap_counter');
      expect(out['day_total'], counterTotal);
      expect(out['total'], counterTotal,
          reason: 'the day published the counter\'s figure');
      expect(out['strap'], counterTotal);
      expect(out['phone'], 0);
      // No stored times: the screen says so instead of drawing the phone's
      // hours under the counter's count.
      expect(out['spans'], isEmpty);
    });
  }

  // The screen half: `DayStepsData.load` must not re-resolve a day's total.
  // It did for one revision — `total = day_total ?? ladder` for EVERY day — and
  // a mixed phone + strap day whose phone rows landed after the last derive
  // then printed "Counted 7,000" over bars summing to 9,000: a header that
  // disagreed with itself. End to end here, through the real repository, so the
  // two halves are checked against one another and not against a fake.
  test('a mixed phone + strap day keeps total == strap + phone when the '
      'bundle is stale', () async {
    const day = '2026-03-13';
    final midnight = localDayStartSec(day)!;

    // The derive published 7,000 off `mixed` — the phone had banked nothing yet.
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'steps': {
          'value': 7000,
          'band_measured': 3000,
          'source': 'mixed',
        },
      }),
      windowJson: '{}',
      finalized: true,
    );
    // The wrist covered 3,000 steps in one half hour…
    await LocalDb.addLiveCoverage(
      midnight + 9 * 3600,
      midnight + 9 * 3600 + 1800,
      3000,
      day,
    );
    // …and the phone banked 6,000 more AFTER that bundle was written, which is
    // the ordinary state of today between drains.
    await LocalDb.replacePhoneCoverageForDay(day, [
      for (var h = 12; h < 18; h++)
        (
          startTs: midnight + h * 3600,
          endTs: midnight + (h + 1) * 3600 - 1,
          steps: 1000,
        ),
    ]);

    final repo = LocalRepositoryImpl(getProfileMap: () => null);
    final out = await repo.getDaySteps(day);
    expect(out['total'], 9000, reason: 'the ladder: 3,000 + 6,000');
    expect(out['strap'], 3000);
    expect(out['phone'], 6000);
    expect(out['day_total'], 7000,
        reason: 'the bundle is stale on purpose, so the two can disagree');

    final data = await DayStepsData.load(repo, want: day);

    expect(data.total, 9000, reason: 'the count says what the bars sum to');
    expect(data.total, data.strap + data.phone);
    expect(data.dayTotal, 7000,
        reason: 'still readable as what the day published');
  });

  group('DayStepsData.load', () {
    // The repository hands the screen one total for a counter day (`total`),
    // and the ladder's own sum for every other day. The screen must not
    // re-resolve either: doing so printed the published figure as the count
    // while `strap`, `phone` and the bars stayed on the ladder, so the header
    // disagreed with itself.
    test('a mixed phone + strap day keeps total == strap + phone, so the '
        'count and the bars agree', () async {
      // The phone banked 6,000 after the last derive, so the bundle still
      // publishes 7,000 off `mixed`. The count is the ladder's 9,000 and the
      // bars under it sum to 9,000 too.
      final data = await DayStepsData.load(_StepsRepo({
        'total': 9000,
        'strap': 3000,
        'phone': 6000,
        'day_total': 7000,
        'day_source': 'mixed',
        'spans': const [],
      }));

      expect(data.mixed, isTrue);
      expect(data.total, 9000, reason: 'the ladder, not the stale bundle');
      expect(data.strap, 3000);
      expect(data.phone, 6000);
      expect(data.total, data.strap + data.phone,
          reason: 'the header count and the bars are the same sum');
      expect(data.dayTotal, 7000,
          reason: 'what the day published is still readable as such');
    });

    test('a counter day keeps the counter total, which the repository returns '
        'as both figures', () async {
      // Even with phone hours on disk, the derive picked the counter, so the
      // repository publishes the counter's figure as `total` and `day_total`
      // alike. The screen passes both through untouched.
      final data = await DayStepsData.load(_StepsRepo({
        'total': 12500,
        'strap': 12500,
        'phone': 0,
        'day_total': 12500,
        'day_source': 'strap_counter',
        'spans': const [],
      }));

      expect(data.total, 12500, reason: 'the counter\'s figure, not 8,000');
      expect(data.dayTotal, 12500);
      expect(data.total, data.dayTotal,
          reason: 'one number for the day, said twice');
      expect(data.strap + data.phone, 12500);
      expect(data.spans, isEmpty, reason: 'the no-times card, not phone hours');
    });

    test('with nothing published, dayTotal stays null and the ladder is the '
        'count', () async {
      final data = await DayStepsData.load(_StepsRepo({
        'total': 6400,
        'strap': 0,
        'phone': 6400,
        'day_total': null,
        'day_source': 'phone',
        'spans': const [],
      }));

      expect(data.total, 6400);
      expect(data.dayTotal, isNull);
    });
  });
}

/// A repository returning one already-resolved `getDaySteps` payload.
class _StepsRepo extends LocalRepository {
  _StepsRepo(this.out);
  final Map<String, dynamic> out;

  @override
  Future<List<String>> availableDays() async => const ['2026-03-10'];

  @override
  Future<Map<String, dynamic>> getDaySteps(String date) async => out;
}
