// v112 readiness calibration backfill: the composite-z history is rebuilt from
// stored drivers, and days raw no longer reaches are re-scored from it. Days
// inside raw retention are left for the real re-derive.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/readiness_calibration_backfill.dart';
import 'package:openstrap_edge/data/db.dart';

Map<String, dynamic> bundle(double hrv, double rhr, double rr) {
  final z = (0.4 * hrv + 0.3 * rhr + 0.2 * rr) / 0.9;
  final score = 100 / (1 + math.exp(-z));
  String det(double v) => 'oriented robust-z (median+MAD)=$v';
  return {
    'scalars': {'readiness': score},
    'clinical': {
      'readiness_composite': {
        'value': {'score': score, 'composite_z': z},
        'drivers': [
          {'label': 'HRV', 'contribution': 0.4 * hrv / 0.9, 'detail': det(hrv)},
          {'label': 'RHR', 'contribution': 0.3 * rhr / 0.9, 'detail': det(rhr)},
          {'label': 'RR', 'contribution': 0.2 * rr / 0.9, 'detail': det(rr)},
        ],
      },
    },
  };
}

String day(int i) =>
    DateTime.utc(2026, 8, 1).add(Duration(days: i)).toIso8601String().substring(0, 10);

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_readiness_cal_backfill_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('storedReadinessZ rebuilds the autonomic-merged composite', () {
    final s = storedReadinessZ(bundle(-2, 1, 0.5))!;
    expect(s.z, closeTo((0.35 * -2 + 0.35 * 1 + 0.2 * 0.5) / 0.9, 1e-12));
    // No published headline → nothing to rebuild.
    final b = bundle(-2, 1, 0.5)..['scalars'] = {'readiness': null};
    expect(storedReadinessZ(b), isNull);
  });

  test('bounded seed before the derive; re-score picks days by substrate',
      () async {
    // 40 days, a wide (SD ~1.3) alternating spread.
    for (var i = 0; i < 40; i++) {
      final v = (i.isEven ? 1.0 : -1.0) * (1 + (i % 5) * 0.2);
      final b = bundle(v, v, 0);
      await LocalDb.putDayResult(
        dayId: day(i),
        algoVersion: 111,
        payloadJson: jsonEncode(b),
        windowJson: '{}',
        finalized: true,
        readiness: (b['scalars'] as Map)['readiness'] as double,
        series: {'readiness': (b['scalars'] as Map)['readiness'] as double},
      );
    }
    // Before the derive: only the newest window is seeded.
    expect(await seedRecentReadinessZ(), kReadinessZSeedDays);
    final seededDates = {
      for (final r in await LocalDb.metricSeries('readiness_z'))
        r['date'] as String
    };
    expect(seededDates.contains(day(39)), isTrue);
    expect(seededDates.contains(day(40 - kReadinessZSeedDays - 1)), isFalse);
    expect(await seedRecentReadinessZ(), 0); // one-shot

    // Substrate survives only for day 20-21 (a user whose newest stored days
    // are already pruned): every OTHER day below v112 is re-scored, the
    // newest included; the two substrate days are left for the derive.
    final zBy = <String, double>{};
    final r = await backfillReadinessCalibration(
        rawDays: {day(20), day(21)},
        zHistoryLoader: () async {
      for (final row in await LocalDb.metricSeries('readiness_z')) {
        zBy[row['date'] as String] = (row['value'] as num).toDouble();
      }
      return (d, _) => [
            for (final e in (zBy.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              if (e.key.compareTo(d) < 0) e.value
          ].reversed.take(28).toList().reversed.toList();
    });
    expect(r.seeded, 40 - kReadinessZSeedDays);
    expect(r.rescored, 38);

    expect((await LocalDb.dayResult(day(20)))!['algo_version'], 111);
    expect((await LocalDb.dayResult(day(39)))!['algo_version'], kAlgoVersion);

    final row = await LocalDb.dayResult(day(30));
    expect(row!['algo_version'], kAlgoVersion);
    final payload = jsonDecode(row['payload_json'] as String) as Map;
    final v = payload['clinical']['readiness_composite']['value'] as Map;
    final hist = [for (var i = 2; i < 30; i++) zBy[day(i)]!];
    final cal = ana.calibratedReadinessScore(zBy[day(30)]!, hist);
    expect(v['calibration']['status'], 'calibrated');
    expect(v['score'], closeTo(cal.score, 1e-5));
    expect(row['readiness'], closeTo(cal.score, 1e-9));
    // An early day had < 14 prior nights: same logistic, marked calibrating.
    final early = jsonDecode(
        (await LocalDb.dayResult(day(3)))!['payload_json'] as String) as Map;
    expect(early['clinical']['readiness_composite']['value']['calibration']
        ['status'], 'calibrating');

    // One-shot.
    final again =
        await backfillReadinessCalibration(
            rawDays: const {},
            zHistoryLoader: () async => (_, _) => const <double>[]);
    expect(again.seeded + again.rescored, 0);
  });
}
