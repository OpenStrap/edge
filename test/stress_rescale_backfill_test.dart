// One-shot backfill of stored stress scores onto the recalibrated floor (#631).
//
// Raw 1 Hz substrate is pruned `rawRetentionDays` behind the data edge, so the
// stress history CANNOT be re-derived from raw and a kAlgoVersion bump alone
// leaves old low nights flat at 0. It does not need raw: the score is a pure
// function of the stored Baevsky index, which every day_result already carries,
// so the rescale reads `stress.si` and re-maps it with `stressScoreFromSi`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/onehz_pipeline.dart'
    show stressScoreFromSi;
import 'package:openstrap_edge/compute/stress_backfill.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';

/// Seed a derived day the way the engine would have on the OLD (floor-20) scale.
Future<void> seedStressDay(
  String day, {
  required double? si,
  required double? score,
  String level = 'low',
  bool withBlock = true,
  int algoVersion = 120,
}) async {
  await LocalDb.putDayResult(
    dayId: day,
    algoVersion: algoVersion,
    payloadJson: jsonEncode({
      'date': day,
      'scalars': {'rhr': 55, 'stress': ?score},
      if (withBlock)
        'stress': {
          'value': score,
          'score': score,
          'si': si,
          'level': level,
        },
    }),
    windowJson: '{}',
    finalized: true,
    series: {'stress': ?score, 'stress_si': ?si},
  );
}

Future<double?> seriesValue(String key, String day) async {
  for (final r in await LocalDb.metricSeries(key)) {
    if (r['date'] == day) return (r['value'] as num?)?.toDouble();
  }
  return null;
}

Future<double?> bundleScore(String day) async {
  final row = await LocalDb.dayResult(day);
  if (row == null) return null;
  final payload = jsonDecode(row['payload_json'] as String) as Map;
  final blk = payload['stress'];
  return blk is Map ? (blk['score'] as num?)?.toDouble() : null;
}

Future<double?> scalarStress(String day) async {
  final row = await LocalDb.dayResult(day);
  if (row == null) return null;
  final payload = jsonDecode(row['payload_json'] as String) as Map;
  final sc = payload['scalars'];
  return sc is Map ? (sc['stress'] as num?)?.toDouble() : null;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_stress_backfill_test.db';
  });

  // Every test starts from an empty database, so none depends on another's
  // writes or on run order.
  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('backfillStressScale — the stored history', () {
    // Newest row 2026-06-10; a day this far back is comfortably before the
    // rawRetentionDays cutoff, so it is rescaled, while 2026-06-09 is not.
    const oldDay = '2026-05-01';
    final recentDay = dayLabelBefore('2026-06-10', 1)!; // within retention
    const oddDay = '2026-05-02'; // has a trend score, but no SI in the bundle
    const newestDay = '2026-06-10';

    test('a flat-0 low night is rescaled from its own stored index', () async {
      // SI 12 was exactly 0 under the floor of 20.
      await seedStressDay(oldDay, si: 12, score: 0);
      await seedStressDay(newestDay, si: 300, score: 73);

      final result = await backfillStressScale();
      expect(result.didWork, isTrue);

      final raw = stressScoreFromSi(12)!;
      final want = ((raw * 10).round()) / 10;
      expect(want, greaterThan(0)); // the whole point of #631
      // Trend and scalars carry the unrounded score, as the derive writes them.
      expect(await seriesValue('stress', oldDay), closeTo(raw, 1e-9));
      expect(await scalarStress(oldDay), closeTo(raw, 1e-9));
      expect(await bundleScore(oldDay), closeTo(want, 1e-9));
    });

    test('a day still inside the raw window is left for a real re-derive',
        () async {
      await seedStressDay(recentDay, si: 12, score: 0);
      await seedStressDay(newestDay, si: 300, score: 73);

      await backfillStressScale();

      expect(await seriesValue('stress', recentDay), 0);
      expect(await scalarStress(recentDay), 0);
      expect(await seriesValue('stress', newestDay), 73);
    });

    test('a day whose index is missing is left alone, never zeroed', () async {
      await seedStressDay(oddDay, si: null, score: 40); // bundle SI missing
      await seedStressDay(newestDay, si: 300, score: 73);

      final result = await backfillStressScale();

      expect(result.skipped, 1);
      expect(result.didWork, isFalse);
      // Trend, scalars and block are unchanged: abstaining, not rewriting to 0.
      expect(await seriesValue('stress', oddDay), 40);
      expect(await scalarStress(oddDay), 40);
      expect(await bundleScore(oddDay), 40);
    });

    test('it is a one-shot: a second pass rewrites nothing', () async {
      await seedStressDay(oldDay, si: 12, score: 0);
      await seedStressDay(newestDay, si: 300, score: 73);

      expect((await backfillStressScale()).didWork, isTrue);
      expect(await LocalDb.computeFreshness(kStressRescaleKey), isNotNull);
      final again = await backfillStressScale();
      expect(again.didWork, isFalse);
    });
  });
}
