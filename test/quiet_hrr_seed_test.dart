// One-shot `quiet_hrr` seed for installs that predate the series.
//
// A re-derive only reaches the last few days (raw is pruned), so without a
// seed every existing user would start with zero prior quiet levels and see
// strain go blank. Every stored bundle still carries the per-minute wake HR as
// `strain_curve` (one point per wake minute) joined to `hr_curve`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/quiet_level.dart';
import 'package:openstrap_edge/compute/quiet_level_seed.dart';
import 'package:openstrap_edge/compute/strain_backfill.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

/// 400 wake minutes at 62 bpm, then 400 sleep minutes at 50 that are in
/// `hr_curve` but not in `strain_curve` — so they must not enter the median.
Map<String, dynamic> _payload({
  bool withCurve = true,
  double? rhrNocturnal = 55,
}) =>
    {
      'scalars': {'rhr_nocturnal': ?rhrNocturnal},
      'max_hr_used': 183.5,
      'series': {
        'hr_curve': [
          for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 62},
          for (var i = 400; i < 800; i++) {'t': i * 60, 'v': 50},
        ],
        if (withCurve)
          'strain_curve': [
            for (var i = 0; i < 400; i++) {'t': i * 60, 'v': 0.0},
          ],
      },
    };

void main() {
  group('quietHrrFromStoredBundle — pure', () {
    test('the wake minutes\' median HRR', () {
      // 62 bpm against RHR 55 / HRmax 183.5 (age 35) = 7/128.5.
      expect(quietHrrFromStoredBundle(_payload(), ageYears: 35), closeTo(0.0545, 0.0005));
    });

    test('the ceiling comes from the CURRENT age, as the live derive\'s does',
        () {
      // The stored bundle was scored on another ceiling (a later birthday, an
      // edited profile). Seeded and live levels must share one scale: age 40
      // is HRmax 180, so 7/125 — not 7/95 off the stored 150.
      final stale = {..._payload(), 'max_hr_used': 150.0};
      expect(quietHrrFromStoredBundle(stale, ageYears: 40),
          closeTo(0.056, 0.0005));
      expect(quietHrrFromStoredBundle(stale, ageYears: null), isNull,
          reason: 'no age, no ceiling — the live derive abstains too');
    });

    test('no strain curve, no wake series — null', () {
      expect(quietHrrFromStoredBundle(_payload(withCurve: false), ageYears: 35), isNull);
    });

    test('no nocturnal RHR — the user-entered one anchors it', () {
      final noRhr = _payload(rhrNocturnal: null);
      expect(quietHrrFromStoredBundle(noRhr, ageYears: 35), isNull);
      expect(
          quietHrrFromStoredBundle(noRhr, ageYears: 35, manualRestingHr: 55),
          closeTo(0.0545, 0.0005));
    });

    test('columnar curves decode to the same value', () {
      final stored =
          SeriesCodec.encodePayloadJson(jsonEncode(_payload()));
      expect(stored, isNot(contains('"strain_curve":[{')),
          reason: 'the codec actually stored a columnar curve');
      final decoded = SeriesCodec.decodePayloadJson(stored)!;
      expect(quietHrrFromStoredBundle(decoded, ageYears: 35),
          closeTo(0.0545, 0.0005));
    });
  });

  group('seedQuietHrrHistoryOnce — an existing install', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_quiet_hrr_seed_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    Future<void> day(
      String date, {
      bool partial = false,
      bool skipped = false,
      bool imported = false,
    }) =>
        LocalDb.putDayResult(
          dayId: date,
          algoVersion: 97,
          payloadJson: SeriesCodec.encodePayloadJson(jsonEncode({
            'date': date,
            if (imported) 'imported': true,
            ..._payload(),
          })),
          windowJson: '{}',
          finalized: true,
          partial: partial,
          skipped: skipped,
          source: imported ? 'whoop_export' : 'band',
          series: {'strain': 5.0},
        );

    Future<Map<String, double>> quietRows() async => {
          for (final r in await LocalDb.metricSeries('quiet_hrr'))
            r['date'] as String: (r['value'] as num).toDouble(),
        };

    test('without an age it seeds nothing and stays armed', () async {
      await day('2026-08-20');
      expect(await seedQuietHrrHistoryOnce(ageYears: null), 0);
      expect(await LocalDb.computeFreshness(kQuietHrrSeedKey), isNull,
          reason: 'it runs once an age is set');
      await (await LocalDb.instance).delete('day_result');
    });

    test('seeds once, even with the strain rescale long since done', () async {
      // The population this exists for: an install whose v63 strain rescale
      // already ran, so `backfillStrainScale` returns at its freshness check.
      await LocalDb.putComputeFreshness(kStrainRescaleKey, '{"done":true}');
      for (final d in ['2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04']) {
        await day(d);
      }
      await day('2026-09-05', partial: true);
      await day('2026-09-06', skipped: true);
      await day('2026-09-07', imported: true);
      // A derive already measured this one — the seed must not overwrite it.
      await day('2026-09-08');
      await LocalDb.putMetricSeriesValue('2026-09-08', 'quiet_hrr', 0.3);

      expect((await backfillStrainScale(female: false)).didWork, isFalse);
      expect(await seedQuietHrrHistoryOnce(ageYears: 35), 4);

      final rows = await quietRows();
      expect(rows.keys.toSet(),
          {'2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04', '2026-09-08'});
      for (final d in ['2026-09-01', '2026-09-02', '2026-09-03', '2026-09-04']) {
        expect(rows[d], closeTo(0.0545, 0.0005), reason: d);
      }
      expect(rows['2026-09-08'], 0.3);
      expect(await LocalDb.computeFreshness(kQuietHrrSeedKey), isNotNull);

      // …so the next day's strain has a level to be priced on.
      final level = await personalQuietLevelBefore('2026-09-09');
      expect(level.present, isTrue);
      expect(level.value!.days, 5);
    });

    test('a second run is a no-op', () async {
      final before = await quietRows();
      // Even a newly stored day is left for its own derive to measure.
      await day('2026-09-09');
      expect(await seedQuietHrrHistoryOnce(ageYears: 35), 0);
      expect(await quietRows(), before);
    });

    test('imports filling the recent rows do not crowd out older measured days',
        () async {
      final db = await LocalDb.instance;
      for (final t in ['day_result', 'metric_series', 'compute_freshness']) {
        await db.delete(t);
      }
      const measured = ['2026-06-01', '2026-06-02', '2026-06-03', '2026-06-04'];
      for (final d in measured) {
        await day(d);
      }
      // A vendor import newer than all of them, longer than the whole window.
      for (var i = 0; i < 40; i++) {
        await day(
            '2026-07-${(i % 30 + 1).toString().padLeft(2, '0')}'
                .replaceFirst('07', i < 30 ? '07' : '08'),
            imported: true);
      }
      expect(await seedQuietHrrHistoryOnce(ageYears: 35), 4);
      expect((await quietRows()).keys.toSet(), measured.toSet());
    });
  });
}
