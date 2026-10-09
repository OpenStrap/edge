// One-shot backfill of stored strain onto the recalibrated 0–21 scale.
//
// Raw 1 Hz substrate is pruned `rawRetentionDays` behind the data edge, so
// history CANNOT be re-derived from raw — the engine logs "no substrate (raw
// pruned) — kept" and keeps the old row. It does not need raw: strain is a pure
// function of (TRIMP, wake minutes, sex). `metric_series` stores `trimp`, and
// the wake window is READ from `series.strain_curve` (one point per wake
// minute) rather than reconstructed as `worn_min − tst_min`, which is a
// different quantity — measured −15..+22 min off on six of six real days.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/strain_backfill.dart';
import 'package:openstrap_edge/data/db.dart';

/// Seed a derived day the way the engine would have before the rescale.
Future<void> seedDay(
  String day, {
  required double? trimp,
  required double? strain,
  required double wornMin,
  required double tstMin,
  required int wakeMin,
  bool finalized = true,
  int algoVersion = 62,
}) async {
  await LocalDb.putDayResult(
    dayId: day,
    algoVersion: algoVersion,
    payloadJson: jsonEncode({
      'date': day,
      'scalars': {
        'trimp': trimp,
        'strain': strain,
        'worn_min': wornMin,
        'tst_min': tstMin,
      },
      'series': {
        'hr_curve': [
          {'t': 1, 'v': 70},
        ],
        // ONE POINT PER WAKE MINUTE, as `_strainCurve` emits. Deliberately
        // NOT `wornMin - tstMin` — that is the quantity the rescale used to
        // guess, and these tests exist to show it no longer does.
        'strain_curve': [
          for (var i = 0; i < wakeMin; i++) {'t': i * 60, 'v': strain},
        ],
      },
    }),
    windowJson: '{}',
    finalized: finalized,
    series: {
      'trimp': trimp,
      'strain': strain,
      'worn_min': wornMin,
      'tst_min': tstMin,
    },
  );
}

Future<double?> seriesValue(String key, String day) async {
  final rows = await LocalDb.metricSeries(key);
  for (final r in rows) {
    if (r['date'] == day) return (r['value'] as num?)?.toDouble();
  }
  return null;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_strain_backfill_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('rescaledStrain — pure recompute from stored scalars', () {
    test('rebuilds the headline from TRIMP and the wake window', () {
      // Real bundle 2026-07-09: TRIMP 177.8 over a 611-minute wake window.
      // Old scale put this at 12.79; the rescale reads ~9.0. Unchanged by the
      // wake-window fix — 611 is the same number, now read instead of guessed.
      final s = rescaledStrain(
        trimp: 177.80394321843846,
        wakeMinutes: 611,
        female: false,
        quietHrr: 0.20,
      );
      expect(s, isNotNull);
      expect(s!, closeTo(9.03, 0.05));
    });

    test('a short-wear inactive day rescales to zero', () {
      // Real bundle 2026-07-10: 23 steps, 135 wake minutes.
      expect(
        rescaledStrain(trimp: 23.416868457643158, wakeMinutes: 135,
            female: false, quietHrr: 0.20),
        0.0,
      );
    });

    test('the wake window it is given is the window it prices', () {
      // The measured error of the old `worn_min − tst_min` reconstruction ran
      // −15..+22 min. It is small but it is not nothing: 22 minutes of extra
      // quiet-waking allowance is a real slice of a light day's headline.
      final measured = rescaledStrain(
          trimp: 177.80394321843846, wakeMinutes: 611, female: false, quietHrr: 0.20)!;
      final guessed = rescaledStrain(
          trimp: 177.80394321843846, wakeMinutes: 633, female: false, quietHrr: 0.20)!;
      expect(guessed, lessThan(measured));
    });

    test('abstains rather than guessing when an input is missing', () {
      // No TRIMP → nothing to rescale from. Must leave the day alone, not zero it.
      expect(
        rescaledStrain(trimp: null, wakeMinutes: 611, female: false, quietHrr: 0.20),
        isNull,
      );
      // No curve in the bundle → no window to price the baseline over. The old
      // code reached for `worn_min − tst_min` here; abstaining is the fix.
      expect(
        rescaledStrain(trimp: 177.8, wakeMinutes: null, female: false, quietHrr: 0.20),
        isNull,
      );
      expect(
        rescaledStrain(trimp: 177.8, wakeMinutes: 0, female: false, quietHrr: 0.20),
        isNull,
      );
    });

    test('abstains without this user\'s quiet-waking level', () {
      // The 0.20 population reference used to be passed here. No level, no
      // rescale — the day keeps its old value rather than a stand-in one.
      expect(
        rescaledStrain(
            trimp: 177.8, wakeMinutes: 611, female: false, quietHrr: null),
        isNull,
      );
    });

    test('sex changes the baseline, matching how the TRIMP was scored', () {
      final male = rescaledStrain(
          trimp: 300, wakeMinutes: 900, female: false, quietHrr: 0.20)!;
      final female = rescaledStrain(
          trimp: 300, wakeMinutes: 900, female: true, quietHrr: 0.20)!;
      // The female quiet-waking allowance is larger (0.86·e^0.334 vs
      // 0.64·e^0.384), so the same TRIMP nets less strain.
      expect(female, lessThan(male));
    });
  });

  group('backfillStrainScale — the stored history', () {
    test('waits, UNMARKED, until a quiet-waking level exists', () async {
      await seedDay('2026-07-09',
          trimp: 177.80394321843846, strain: 12.790964777435558,
          wornMin: 827, tstMin: 216, wakeMin: 611);
      final r = await backfillStrainScale(female: false);
      expect(r.didWork, isFalse);
      // Not marked done: the one-shot must run once a level exists.
      expect(await LocalDb.computeFreshness(kStrainRescaleKey), isNull);
      expect(await seriesValue('strain', '2026-07-09'),
          closeTo(12.790964777435558, 1e-9));
      // A settled week at the reference level, so the rescaled values below
      // stay comparable with the pure tests.
      for (var d = 1; d <= 7; d++) {
        await LocalDb.putMetricSeriesValue('2026-05-0$d', 'quiet_hrr', 0.20);
      }
    });

    test('rescales a raw-pruned historical day in series AND bundle', () async {
      // worn − tst would be 611 here too, but the curve is what counts and it
      // is seeded at 611 to keep the pinned 9.03 comparable with the pure test.
      await seedDay('2026-07-09',
          trimp: 177.80394321843846, strain: 12.790964777435558,
          wornMin: 827, tstMin: 216, wakeMin: 611);
      // Data edge, well inside the retention window — must be left for the
      // engine to re-derive from raw rather than patched here.
      await seedDay('2026-07-20',
          trimp: 200, strain: 13.0, wornMin: 900, tstMin: 400, wakeMin: 500,
          finalized: false);

      final r = await backfillStrainScale(female: false);
      expect(r.seriesDays, 1);
      expect(r.bundleDays, 1);

      // The trend series now carries the rescaled value.
      expect(await seriesValue('strain', '2026-07-09'), closeTo(9.03, 0.05));
      // …and so does the bundle the day-detail screen reads.
      final row = await LocalDb.dayResult('2026-07-09');
      expect((row!['algo_version'] as num).toInt(), kAlgoVersion);
      final scalars = (jsonDecode(row['payload_json'] as String)
          as Map)['scalars'] as Map;
      expect((scalars['strain'] as num).toDouble(), closeTo(9.03, 0.05));
      // TRIMP is the input, not the output — it must survive untouched.
      expect((scalars['trimp'] as num).toDouble(),
          closeTo(177.80394321843846, 1e-9));
    });

    test('leaves days inside the raw-retention window for a real re-derive',
        () async {
      // Patching these would write a row AT kAlgoVersion, and the derive gate
      // matches algo_version EXACTLY — the engine would then skip the day and
      // a partial patch would stand in for a full re-derivation.
      expect(await seriesValue('strain', '2026-07-20'), closeTo(13.0, 1e-9));
      final row = await LocalDb.dayResult('2026-07-20');
      expect((row!['algo_version'] as num).toInt(), 62);
    });

    test('drops the stale intraday curve rather than contradicting the headline',
        () async {
      // `series.strain_curve` is cumulative strain, one point per wake minute,
      // and its last point IS the old headline (12.79 for 2026-07-09). It was
      // built from per-sample HR that no longer exists, so it cannot be
      // rescaled — and a curve ending at 12.79 under a headline of 9.03 is
      // worse than no curve. The UI already renders a missing curve honestly.
      final row = await LocalDb.dayResult('2026-07-09');
      final payload = jsonDecode(row!['payload_json'] as String) as Map;
      final series = payload['series'] as Map?;
      expect(series?['strain_curve'], isNull);
      // Everything else in the block survives.
      expect(series?['hr_curve'], isNotNull);
    });

    test('is idempotent — a second run rewrites nothing', () async {
      final again = await backfillStrainScale(female: false);
      expect(again.seriesDays, 0);
      expect(again.bundleDays, 0);
      expect(await seriesValue('strain', '2026-07-09'), closeTo(9.03, 0.05));
    });

    test('a day with no stored TRIMP is skipped, not zeroed', () async {
      await LocalDb.putComputeFreshness(kStrainRescaleKey, '{}');
      await seedDay('2026-06-01',
          trimp: null, strain: 11.5, wornMin: 800, tstMin: 200, wakeMin: 600);

      final r = await backfillStrainScale(female: false, force: true);
      expect(r.skipped, greaterThanOrEqualTo(1));
      // Left exactly as it was — an un-rescalable day must not become 0.
      expect(await seriesValue('strain', '2026-06-01'), closeTo(11.5, 1e-9));
    });

    test('a day with no strain curve is skipped, not guessed at', () async {
      // `worn_min` and `tst_min` are both present and would have produced a
      // number under the old reconstruction. Without the curve there is no
      // record of the window the TRIMP was actually scored over, so the day
      // keeps its old headline rather than getting a differently-wrong one.
      await LocalDb.putComputeFreshness(kStrainRescaleKey, '{}');
      await seedDay('2026-06-02',
          trimp: 177.8, strain: 12.79, wornMin: 827, tstMin: 216, wakeMin: 0);

      final r = await backfillStrainScale(female: false, force: true);
      expect(r.skipped, greaterThanOrEqualTo(1));
      expect(await seriesValue('strain', '2026-06-02'), closeTo(12.79, 1e-9));
    });
  });
}
