// One readiness number on the ring, the push, the chart and the log, even when
// the day has no stored readiness of its own.
//
// The push and the ring read the frozen morning headline when it is pinned to
// the day. The recovery chart, and through it the Observations log, read
// `metric_series`, which drops a null row entirely. A partial derive can pin
// the headline without writing the day's readiness, and a later derive can
// write it as null, so a pin of 22 used to buzz "Low readiness" and fill the
// ring with no chart point and no log entry anywhere to back it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show HealthData;

/// The frozen headline as the engine hands it to the planner: only a pin taken
/// on [day]'s own night (`LocalDb.headlinePinFor`).
Future<({String day, int value})?> _pin(String day) async {
  final v = await LocalDb.headlinePinFor(day);
  return v == null ? null : (day: day, value: v);
}

void main() {
  late LocalRepositoryImpl repo;
  final today = todayLabel();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'low_readiness_agreement_test.db';
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

  // Today's night, scored (so the ring shows today's overnight), with NO
  // readiness of its own; the crossday rollup says today is settled.
  Future<void> seed({required bool nullRow}) async {
    final wakeSec =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - 13 * 3600;
    final db = await LocalDb.instance;
    await db.delete('day_result');
    await db.delete('metric_series');
    await db.delete('baselines');
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': today,
        'scalars': {'rhr': 52.0},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 437 * 60, 'efficiency_pct': 91.0},
          },
        },
      }),
      // The night's wake, which the pin must match to be trusted. Far enough
      // back that the night has settled on the give-up clock.
      windowJson: jsonEncode({'offset_ms': wakeSec * 1000}),
      // `putDayResult` writes the series map as given; with no readiness key
      // the day has no readiness row at all.
      series: nullRow ? {'readiness': null} : const {},
    );
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'algo_version': kAlgoVersion,
        'built_for_day': today,
        'recent': [
          {'date': today, 'unsettled': false},
        ],
      }),
    );
    await LocalDb.setFrozenHeadline(today, 22, wakeSec: wakeSec);
    await LocalDb.refreshComputeFreshness();
  }

  Future<void> expectAgreement() async {
    // Ring.
    final t = TodayData.fromJson(await repo.getToday());
    expect(t.settledReadinessScore, 22, reason: 'ring');

    // Push: the production planner, fed exactly what the engine reads.
    final cd = (await repo.getInsights());
    final notices = planExceptionNotices(
      cd,
      today: today,
      pin: await _pin(today),
      storedReadiness: await LocalDb.metricValueOn(today, 'readiness'),
    );
    final pushed = [
      for (final n in notices)
        for (final f in n.findings)
          if (f.kind == FindingKind.lowReadiness) f,
    ];
    expect(pushed.single.score, 22, reason: 'push');

    // Chart.
    final chart = await repo.getChart('recovery');
    final points = (chart['points'] as List).cast<Map>();
    final todayPoint = points.where((pt) =>
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
            (pt['t'] as num).toInt() * 1000)) ==
        today);
    expect(todayPoint.single['v'], 22, reason: 'chart');

    // Log, through the Health loader the Observations screen uses.
    final log = (await HealthData.load(repo))
        .findings
        .where((f) => f.kind == FindingKind.lowReadiness);
    expect(log.single.date, today, reason: 'log');
    expect(log.single.score, 22, reason: 'log');
  }

  test('with no stored readiness row for the pinned day', () async {
    await seed(nullRow: false);
    expect(await LocalDb.metricValueOn(today, 'readiness'), isNull);
    await expectAgreement();
  });

  test('with a NULL stored readiness for the pinned day', () async {
    await seed(nullRow: true);
    expect(await LocalDb.metricValueOn(today, 'readiness'), isNull);
    await expectAgreement();
  });

  // A deleted day must stay deleted. `deleteDays` removes the day's rows; the
  // pin is a cursor, not a day row, and a pin that outlived its day used to
  // put the deleted day back on the chart, into the log and into a push.
  Future<void> expectNothingFor(String day) async {
    final cd = await repo.getInsights();
    final notices = planExceptionNotices(
      cd,
      today: today,
      pin: await _pin(day),
      storedReadiness: await LocalDb.metricValueOn(day, 'readiness'),
    );
    expect(
        [
          for (final n in notices)
            for (final f in n.findings)
              if (f.kind == FindingKind.lowReadiness) f,
        ],
        isEmpty,
        reason: 'push');

    final points = ((await repo.getChart('recovery'))['points'] as List)
        .cast<Map>()
        .where((pt) =>
            dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
                (pt['t'] as num).toInt() * 1000)) ==
            day);
    expect(points, isEmpty, reason: 'chart');

    final log = (await HealthData.load(repo))
        .findings
        .where((f) => f.kind == FindingKind.lowReadiness);
    expect(log, isEmpty, reason: 'log');
  }

  test('deleting the pinned day takes its pin with it, across a reopen',
      () async {
    await seed(nullRow: false);
    await LocalDb.deleteDays({today});
    await LocalDb.close();
    await LocalDb.instance; // reopen

    expect(await LocalDb.getCursor(LocalDb.kFrozenHeadlineCursor), isNull,
        reason: 'the cursor is cleared inside the delete');
    expect(await LocalDb.frozenHeadline(), isNull);
    // The rollup is not rebuilt by a delete, so it still names the day: the
    // push must stand down on its own, not because the rollup forgot.
    await expectNothingFor(today);
  });

  test('clearing an orphan pin never deletes a pin written meanwhile',
      () async {
    await seed(nullRow: false);
    await (await LocalDb.instance).delete('day_result'); // orphan the pin
    final yesterday = dayLabelBefore(today, 1)!;
    // A derive pins a new headline between the orphan check and its clear.
    LocalDb.debugBeforeOrphanPinClear = () async {
      await LocalDb.putDayResult(
        dayId: yesterday,
        algoVersion: kAlgoVersion,
        payloadJson: '{}',
        windowJson: '{}',
      );
      await LocalDb.setFrozenHeadline(yesterday, 55);
    };
    addTearDown(() => LocalDb.debugBeforeOrphanPinClear = null);
    expect(await LocalDb.frozenHeadline(), isNull, reason: 'the orphan');
    LocalDb.debugBeforeOrphanPinClear = null;
    final pin = await LocalDb.frozenHeadline();
    expect(pin?.day, yesterday, reason: 'the new pin survived');
    expect(pin?.value, 55);
  });

  test('a pin whose day has no result is never read', () async {
    await seed(nullRow: false);
    // An orphan however it arose — not through deleteDays.
    await (await LocalDb.instance).delete('day_result');
    await expectNothingFor(today);
    expect(await LocalDb.frozenHeadline(), isNull);
    // Found, it is removed rather than masked: when the day is derived again
    // the stale value must not come back as that day's pin.
    expect(await LocalDb.getCursor(LocalDb.kFrozenHeadlineCursor), isNull);
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
    );
    expect(await LocalDb.frozenHeadline(), isNull);
  });
}
