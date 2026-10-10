// Repository-layer P0 regressions, against the REAL LocalRepositoryImpl +
// LocalDb over sqflite_ffi.
//
//  7. getCycle() crashed the whole cycle screen whenever the mean cycle length
//     came out below the 10-day ovulation floor: `(mean - 14).round().clamp(10,
//     mean.round())` THROWS ArgumentError when lowerLimit > upperLimit. Two
//     logged `start` markers 8 days apart is enough (a correction the user
//     made, or a genuinely short cycle).
// 10. getRecords() computes only `workouts_tracked` — the one key its only
//     caller reads. It used to `recentDayResults(3650)` (SELECT r.*, hr_curve
//     + hypnogram + HRV series for TEN YEARS) and jsonDecode every one on the
//     main isolate; then day/night counts from SQL plus a full personal-record
//     sweep; all of it for a screen that wanted an integer.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  late LocalRepositoryImpl repo;
  // Mutable so a test can declare a reproductive state (WH-07). Unset is the
  // conservative default and the cases below that want a phase say so.
  final profile = <String, dynamic>{'track_cycle': true};

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_repo_p0_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => profile);
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() async {
    profile
      ..clear()
      ..addAll({'track_cycle': true});
    final db = await LocalDb.instance;
    await db.delete('journal_metric');
    await db.delete('cycle_log');
    await db.delete('day_result');
    await db.delete('metric_series');
    await db.delete('sessions');
  });

  // ── fix 7 ────────────────────────────────────────────────────────────────
  test(
    'getCycle degrades to phase "unknown" on a sub-10-day mean cycle instead '
    'of throwing ArgumentError out of clamp()',
    () async {
      // Two starts 8 days apart → median 8 → clamp(10, 8) used to throw.
      await LocalDb.putCycleLog('2026-06-01', 'start');
      await LocalDb.putCycleLog('2026-06-09', 'start');

      final cycle = await repo.getCycle();

      expect(cycle['enabled'], isTrue);
      expect(cycle['phase'], 'unknown', reason: 'honest, not invented');
      // Everything that IS knowable still comes back.
      expect(cycle['median_length'], 8);
      expect(cycle['predicted_next'], isNotNull);
      expect(cycle['cycle_day'], isNotNull);
    },
  );

  test(
    'a normal-length cycle gets a real phase once she has declared one',
    () async {
      profile['repro_state'] = 'cycling';
      await LocalDb.putCycleLog('2026-06-01', 'start');
      await LocalDb.putCycleLog('2026-06-29', 'start'); // 28 days

      final cycle = await repo.getCycle();
      expect(cycle['median_length'], 28);
      expect(cycle['phase'], isNot('unknown'));
    },
  );

  test('exactly 10 days — the clamp boundary — does not throw', () async {
    profile['repro_state'] = 'cycling';
    await LocalDb.putCycleLog('2026-06-01', 'start');
    await LocalDb.putCycleLog('2026-06-11', 'start');
    final cycle = await repo.getCycle();
    expect(cycle['median_length'], 10);
    expect(cycle['phase'], isNotNull);
  });

  // ── WH-07 ────────────────────────────────────────────────────────────────
  test(
    'declared state gates what the screen may say, and UNSET is the quiet one',
    () async {
      await LocalDb.putCycleLog('2026-06-01', 'start');
      await LocalDb.putCycleLog('2026-06-29', 'start');

      // Never declared → no phase. Not "assume she cycles".
      var cycle = await repo.getCycle();
      expect(cycle['repro_state'], isNull);
      expect(cycle['phase'], 'unknown');
      expect(cycle['predicted_next'], isNotNull);

      // No ovulation under hormonal contraception, so no phase — but her own
      // logged bleeds still predict the next one.
      profile['repro_state'] = 'contraception';
      cycle = await repo.getCycle();
      expect(cycle['phase'], 'unknown');
      expect(cycle['predicted_next'], isNotNull);

      // Pregnant / postpartum / not cycling: nothing to predict, and the
      // biometric overlay is all that survives.
      profile['repro_state'] = 'none';
      cycle = await repo.getCycle();
      expect(cycle['phase'], 'unknown');
      expect(cycle['predicted_next'], isNull);
      expect(cycle['predicted_from'], isNull);
      expect(cycle['days_until_next'], isNull);
      expect(cycle['cycle_day'], isNotNull);
    },
  );

  // ── WH-09 ────────────────────────────────────────────────────────────────
  test('no fertile window is published, ever', () async {
    await LocalDb.putCycleLog('2026-06-01', 'start');
    await LocalDb.putCycleLog('2026-06-29', 'start');
    await LocalDb.putCycleLog('2026-07-27', 'start');
    final cycle = await repo.getCycle();
    expect(cycle.containsKey('fertile_start'), isFalse);
    expect(cycle.containsKey('fertile_end'), isFalse);
  });

  test(
    'the prediction is a MEDIAN-gap range whose width is her own MAD, and it '
    'has no width at all from a single gap',
    () async {
      // One gap: a point, no band — a single gap has no spread to state.
      await LocalDb.putCycleLog('2026-06-01', 'start');
      await LocalDb.putCycleLog('2026-06-29', 'start');
      var cycle = await repo.getCycle();
      expect(cycle['gap_n'], 1);
      expect(cycle['predicted_from'], isNull);
      expect(cycle['predicted_to'], isNull);

      // Gaps 28, 21, 35 → median 28, MAD 7. The mean would also be 28 here;
      // the width is the point, and ±7 days is what her own log supports.
      await LocalDb.putCycleLog('2026-07-20', 'start'); // +21
      await LocalDb.putCycleLog('2026-08-24', 'start'); // +35
      cycle = await repo.getCycle();
      expect(cycle['gap_n'], 3);
      expect(cycle['median_length'], 28);
      expect(cycle['predicted_next'], '2026-09-21');
      expect(cycle['predicted_from'], '2026-09-14');
      expect(cycle['predicted_to'], '2026-09-28');
    },
  );

  // ── WH-02 ────────────────────────────────────────────────────────────────
  test(
    'the overlay numbers every day against the start that PRECEDED it, not '
    'the last one logged',
    () async {
      await LocalDb.putCycleLog('2026-06-01', 'start');
      await LocalDb.putCycleLog('2026-07-01', 'start');
      for (final d in ['2026-05-30', '2026-06-05', '2026-07-05']) {
        await LocalDb.putDayResult(
          dayId: d,
          algoVersion: 41,
          payloadJson: '{"scalars":{"rhr":52.0}}',
          windowJson: '{}',
        );
      }

      final overlay = (await repo.getCycle())['overlay'] as List;
      final byDate = {
        for (final o in overlay) (o as Map)['date']: o,
      };

      // Day 5 of the FIRST cycle. Counted off the last start it would have
      // been day −25; counted off the last start with the old code it came
      // back as a day past the cycle's own length and the screen could only
      // ever draw one series.
      expect(byDate['2026-06-05']!['cycle_index'], 0);
      expect(byDate['2026-06-05']!['cycle_day'], 5);
      // Day 5 of the SECOND. Same day number, different cycle — which is the
      // comparison the whole feature exists to make.
      expect(byDate['2026-07-05']!['cycle_index'], 1);
      expect(byDate['2026-07-05']!['cycle_day'], 5);
      // Before she ever logged a start there is no cycle to be on day N of.
      // Absent, not day 0 and not a negative day.
      expect(byDate['2026-05-30']!.containsKey('cycle_day'), isFalse);
      expect(byDate['2026-05-30']!.containsKey('cycle_index'), isFalse);
    },
  );

  // ── fix 10 ───────────────────────────────────────────────────────────────
  test(
    'getRecords answers the ONE key its caller reads, touching no day_result '
    'payload at all',
    () async {
      String bundle(int? tstSec) => tstSec == null
          ? '{"scalars":{}}'
          : '{"sleep":{"accounting":{"value":{"tst_sec":$tstSec}}}}';

      await LocalDb.putDayResult(
        dayId: '2026-01-01',
        algoVersion: 41,
        payloadJson: bundle(21600),
        windowJson: '{}',
        series: const {'rhr': 52.0},
      );
      await LocalDb.putDayResult(
        dayId: '2026-01-02',
        algoVersion: 41,
        payloadJson: '<<truncated write>>', // not JSON at all
        windowJson: '{}',
      );

      final records = await repo.getRecords();
      // workout_screen reads ['workouts_tracked'] and nothing else, so nothing
      // else is computed — the day/night counts, the personal records, the
      // streaks and the resting-HR drift all had zero consumers.
      expect(records.keys, ['workouts_tracked']);
      expect(records['workouts_tracked'], 0);
    },
  );

  // ── MT-06 + MIND-04 ──────────────────────────────────────────────────────
  test('the caffeine CLOCK TIME reaches the correlation, and a 0/1 habit comes '
      'back as a group difference instead of being dropped', () async {
    // 30 days. Sleep efficiency falls with a later last cup; the habit is
    // ticked on the days efficiency is high, which is exactly the confound
    // the screen states and exactly what a difference of means measures.
    for (var i = 0; i < 30; i++) {
      final d = DateTime(2026, 6, 1 + i);
      final date = '2026-06-${(1 + i).toString().padLeft(2, '0')}';
      final late = i.isEven; // late coffee on alternate days
      await LocalDb.putJournalMetrics(date, {
        'caffeine_mg': JournalMetricValue(
          200,
          atMinuteOfDay: late ? 19 * 60 : 8 * 60,
        ),
        'walk': JournalMetricValue(late ? 0 : 1),
      });
      await LocalDb.putMetricSeriesValue(
        date,
        'efficiency',
        late ? 80.0 + (i % 3) : 92.0 + (i % 3),
      );
      expect(d.year, 2026);
    }

    final j = await repo.getJournalInsights(range: 'all');
    final rows = (j['numeric_insights'] as List).cast<Map<String, dynamic>>();

    // MT-06: `at_min` used to be dropped three lines before the analysis.
    final caffeine = rows.where((r) => r['field'] == 'caffeine_last_min');
    expect(
      caffeine,
      isNotEmpty,
      reason: 'the last cup never reached the correlation',
    );
    expect(caffeine.first['binary'], isFalse);

    // MIND-04: a tick box has no rho by construction, and the old guard
    // (`rho == null`) threw every one of them away.
    final walk = rows.where((r) => r['field'] == 'walk');
    expect(walk, isNotEmpty, reason: 'the habit half was dropped again');
    expect(walk.first['binary'], isTrue);
    expect(walk.first['delta'], isNotNull);
    expect(walk.first['n_with'], isNotNull);
    expect(walk.first['n_without'], isNotNull);
    expect(walk.first['rho'], isNull);
  });

  test("a wearable's estimated outcome never reaches the journal analysis",
      () async {
    // The caffeine set-up above, but every efficiency value is a wearable's
    // estimate (metric_method class): not a measured outcome to correlate.
    final db = await LocalDb.instance;
    for (var i = 0; i < 30; i++) {
      final date = '2026-06-${(1 + i).toString().padLeft(2, '0')}';
      final late = i.isEven;
      await LocalDb.putJournalMetrics(date, {
        'caffeine_mg': JournalMetricValue(
          200,
          atMinuteOfDay: late ? 19 * 60 : 8 * 60,
        ),
      });
      await LocalDb.putMetricSeriesValue(
          date, 'efficiency', late ? 80.0 + (i % 3) : 92.0 + (i % 3));
      await db.insert('metric_method', {
        'date': date,
        'key': 'efficiency',
        'method': 'hr_5min',
        'family': 'colmi',
        'class': 'estimated',
      });
    }
    final j = await repo.getJournalInsights(range: 'all');
    final rows = (j['numeric_insights'] as List).cast<Map<String, dynamic>>();
    expect(rows.where((r) => r['outcome'] == 'efficiency'), isEmpty);
    expect(rows, isEmpty);
  });

  // ── MIND-12 ──────────────────────────────────────────────────────────────
  test(
    'the weekday test refuses under its history floor, and says why',
    () async {
      for (var i = 0; i < 20; i++) {
        await LocalDb.putMetricSeriesValue(
          '2026-06-${(1 + i).toString().padLeft(2, '0')}',
          'readiness',
          70.0 + i % 5,
        );
      }
      final w = await repo.getWeekdayEffect();
      expect(w['present'], isFalse);
      expect(w['note'], contains('need_history'));
      expect(w['meaningful'], isNull, reason: 'absent is not "no effect"');
    },
  );
}
