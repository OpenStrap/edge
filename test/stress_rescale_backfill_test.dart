// One-shot backfill of stored stress scores onto the recalibrated floor (#631).
//
// Raw 1 Hz substrate is pruned `rawRetentionDays` behind the data edge, so the
// stress history CANNOT be re-derived from raw and a kAlgoVersion bump alone
// leaves old low nights flat at 0. It does not need raw: the score is a pure
// function of the stored Baevsky index, which every day_result already carries,
// so the rescale reads `stress.si` and re-maps it with `stressScoreFromSi`,
// in place, at the version each row already has.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/onehz_pipeline.dart'
    show stressScoreFromSi;
import 'package:openstrap_edge/compute/stress_backfill.dart';
import 'package:openstrap_edge/data/db.dart';

/// Seed a derived day the way the engine would have on the OLD (floor-20) scale.
Future<void> seedStressDay(
  String day, {
  required Object? si,
  required double? score,
  bool partial = false,
  bool imported = false,
  int algoVersion = 120,
}) async {
  await LocalDb.putDayResult(
    dayId: day,
    algoVersion: algoVersion,
    payloadJson: jsonEncode({
      'date': day,
      'imported': ?(imported ? true : null),
      'scalars': {'rhr': 55, 'stress': ?score},
      'stress': {'value': score, 'score': score, 'si': si, 'level': 'low'},
    }),
    windowJson: '{}',
    finalized: true,
    partial: partial,
    series: {'stress': ?score},
  );
}

Future<double?> seriesValue(String day) async {
  for (final r in await LocalDb.metricSeries('stress')) {
    if (r['date'] == day) return (r['value'] as num?)?.toDouble();
  }
  return null;
}

Future<Map<String, Object?>> stored(String day, int version) async {
  final db = await LocalDb.instance;
  final row = (await db.query('day_result',
          where: 'day_id = ? AND algo_version = ?', whereArgs: [day, version]))
      .single;
  final payload = jsonDecode(row['payload_json'] as String) as Map;
  return {
    'score': (payload['stress'] as Map)['score'],
    'value': (payload['stress'] as Map)['value'],
    'scalar': (payload['scalars'] as Map)['stress'],
  };
}

void main() {
  setUpAll(() {
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

  final raw = stressScoreFromSi(12)!;
  final rounded = ((raw * 10).round()) / 10;

  test('a flat-0 low night is rescaled in place from its own index', () async {
    // SI 12 was exactly 0 under the floor of 20.
    await seedStressDay('2026-05-01', si: 12, score: 0);

    final result = await backfillStressScale();
    expect(result.bundleDays, 1);
    expect(result.seriesDays, 1);

    expect(rounded, greaterThan(0)); // the whole point of #631
    // Same row, same version: the derive gate, the strain and readiness
    // one-shots and the day's provenance all see what they saw before.
    final s = await stored('2026-05-01', 120);
    expect(s['score'], rounded);
    expect(s['value'], rounded);
    expect(s['scalar'], closeTo(raw, 1e-9)); // unrounded, as the derive writes
    expect(await seriesValue('2026-05-01'), closeTo(raw, 1e-9));
  });

  test('a missing or wrong-typed index is skipped, never zeroed or thrown on',
      () async {
    await seedStressDay('2026-05-01', si: null, score: 40);
    await seedStressDay('2026-05-02', si: '12', score: 41);
    await seedStressDay('2026-05-03', si: 12, score: 0);

    final result = await backfillStressScale();

    expect(result.skipped, 2);
    for (final (day, v) in [('2026-05-01', 40.0), ('2026-05-02', 41.0)]) {
      final s = await stored(day, 120);
      expect(s['score'], v);
      expect(s['scalar'], v);
      expect(await seriesValue(day), v);
    }
    // A bad row does not stop the walk.
    expect(await seriesValue('2026-05-03'), closeTo(raw, 1e-9));
  });

  test('a partial newest row: the trend point follows the complete row',
      () async {
    await seedStressDay('2026-05-01', si: 12, score: 0); // wrote the series
    await seedStressDay('2026-05-01',
        si: 300, score: 73, partial: true, algoVersion: 121);

    await backfillStressScale();

    expect(await seriesValue('2026-05-01'), closeTo(raw, 1e-9));
    expect((await stored('2026-05-01', 121))['score'],
        ((stressScoreFromSi(300)! * 10).round()) / 10);
  });

  test('the trend follows only its writer row, never an older one', () async {
    await seedStressDay('2026-05-01', si: 12, score: 0);
    // Newest complete row has no usable index: the trend stays as it wrote it.
    await seedStressDay('2026-05-01', si: null, score: 40, algoVersion: 121);

    await backfillStressScale();

    expect(await seriesValue('2026-05-01'), 40);
    // The older bundle is still rescaled on its own.
    expect((await stored('2026-05-01', 120))['score'], rounded);
  });

  test('a stamped series writer wins over a newer complete row', () async {
    await seedStressDay('2026-05-01', si: 300, score: 73, algoVersion: 121);
    // A rolled-back build rewrote the series (and its stamp) at v120.
    await seedStressDay('2026-05-01', si: 12, score: 0);

    await backfillStressScale();

    expect(await seriesValue('2026-05-01'), closeTo(raw, 1e-9));
  });

  test('an imported day keeps its score', () async {
    await seedStressDay('2026-05-01', si: 12, score: 0, imported: true);

    final result = await backfillStressScale();

    expect(result.didWork, isFalse);
    expect((await stored('2026-05-01', 120))['score'], 0);
    expect(await seriesValue('2026-05-01'), 0);
  });

  test('an empty store is not marked done', () async {
    expect((await backfillStressScale()).didWork, isFalse);
    expect(await LocalDb.computeFreshness(kStressRescaleKey), isNull);
  });

  test('it is a one-shot: a second pass rewrites nothing', () async {
    await seedStressDay('2026-05-01', si: 12, score: 0);

    expect((await backfillStressScale()).didWork, isTrue);
    expect(await LocalDb.computeFreshness(kStressRescaleKey), isNotNull);
    expect((await backfillStressScale()).didWork, isFalse);
    // Forced, an already-rescaled store is a no-op.
    expect((await backfillStressScale(force: true)).didWork, isFalse);
  });
}
