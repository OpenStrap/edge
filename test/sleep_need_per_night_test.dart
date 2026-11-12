// #619: a past night is read against the sleep need the app had computed ON
// that day, not against today's estimate. The crossday artifact only ever holds
// the latest need, so `_runCrossDay` also files it per day under
// `metric_series` `sleep_need_min`; `getDaySleepV2` reads that row for any day
// but today, and reads nothing (no need, no debt) when there is none.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  group('crossDayNeedMin', () {
    test('reads sleep_coach.need in whole minutes', () {
      expect(
        DerivationEngine.crossDayNeedMin({
          'sleep_coach': {
            'need': {
              'value': {'need_sec': 462 * 60 + 29},
              'confidence': 0.7,
            },
          },
        }),
        462.0,
      );
    });

    test('is null when the need abstained or the block is missing', () {
      expect(DerivationEngine.crossDayNeedMin({}), isNull);
      expect(
        DerivationEngine.crossDayNeedMin({
          'sleep_coach': {
            'need': {'value': null, 'reason': 'need_nights'},
          },
        }),
        isNull,
      );
      expect(
        DerivationEngine.crossDayNeedMin({'sleep_coach': 'garbage'}),
        isNull,
      );
    });
  });

  group('getDaySleepV2 sleep need per night', () {
    late LocalRepositoryImpl repo;
    late String today;
    late String pastDay;

    String label(DateTime d) => dayLabelOf(d);

    String bundle(String day) => jsonEncode({
          'date': day,
          'sleep': {
            'accounting': {
              'value': {'tst_sec': 420 * 60, 'efficiency_pct': 90.0},
            },
          },
        });

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_sleep_need_per_night_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      repo = LocalRepositoryImpl(getProfileMap: () => const {});
    });

    tearDownAll(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    setUp(() async {
      // Per test, not once: a run that crosses local midnight would otherwise
      // read a fixture "today" as a past day.
      today = todayLabel();
      final t = DateTime.parse(today);
      pastDay = label(DateTime(t.year, t.month, t.day - 3));
      final db = await LocalDb.instance;
      await db.delete('day_result');
      await db.delete('baselines');
      await db.delete('metric_series');
      for (final day in [pastDay, today]) {
        await LocalDb.putDayResult(
          dayId: day,
          algoVersion: kAlgoVersion,
          payloadJson: bundle(day),
          windowJson: '{}',
        );
      }
      // Today's crossday artifact says 480 min.
      await LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': today,
          'sleep_coach': {
            'need': {
              'value': {'need_sec': 480 * 60},
              'confidence': 0.7,
              'tier': 'ESTIMATE',
            },
          },
        }),
      );
    });

    test('a past night uses the need stored for that day, not today\'s',
        () async {
      await LocalDb.putMetricSeriesValue(pastDay, 'sleep_need_min', 450);

      final night = await repo.getDaySleepV2(pastDay);
      expect(night['need_min'], 450);
      expect(night['debt_min'], 30); // 450 need - 420 asleep
    });

    test('a past night with no stored need has no need and no debt', () async {
      final night = await repo.getDaySleepV2(pastDay);
      expect(night['has_sleep'], isNot(false));
      expect(night.containsKey('need_min'), isFalse);
      expect(night.containsKey('debt_min'), isFalse);
    });

    test('a need that abstained later the same day clears the stored one',
        () async {
      final revision = await LocalDb.activityReviewRevision();
      await LocalDb.putReviewedBaseline('crossday', '{"v":1}', revision,
          series: (date: pastDay, key: 'sleep_need_min', value: 450.0));
      await LocalDb.putReviewedBaseline('crossday', '{"v":2}', revision,
          series: (date: pastDay, key: 'sleep_need_min', value: null));

      // No row at all, not a null one: the freeze goldens pin metric_series,
      // and a row for the build's (wall-clock) day would move with the date.
      final rows = await (await LocalDb.instance).query('metric_series',
          where: 'date = ? AND key = ?',
          whereArgs: [pastDay, 'sleep_need_min']);
      expect(rows, isEmpty);
      expect((await repo.getDaySleepV2(pastDay)).containsKey('need_min'),
          isFalse);
    });

    test('the crossday write stores the artifact and its day\'s need together, '
        'or neither', () async {
      Future<double?> stored() => LocalDb.metricValueOn(today, 'sleep_need_min');
      final revision = await LocalDb.activityReviewRevision();

      expect(
          await LocalDb.putReviewedBaseline('crossday', '{"v":1}', revision,
              series: (date: today, key: 'sleep_need_min', value: 455.0)),
          isTrue);
      expect(await stored(), 455.0);
      expect((await LocalDb.baseline('crossday'))?['payload_json'], '{"v":1}');

      // A stale build (a newer activity review landed) writes nothing.
      expect(
          await LocalDb.putReviewedBaseline('crossday', '{"v":2}', revision + 1,
              series: (date: today, key: 'sleep_need_min', value: 400.0)),
          isFalse);
      expect(await stored(), 455.0);
      expect((await LocalDb.baseline('crossday'))?['payload_json'], '{"v":1}');
    });

    test('today still reads the live crossday need', () async {
      // A stored row for today must not override the live estimate.
      await LocalDb.putMetricSeriesValue(today, 'sleep_need_min', 450);

      final night = await repo.getDaySleepV2(today);
      expect(night['need_min'], 480);
      expect(night['debt_min'], 60);
    });
  });
}
