// Regression tests for the intermittent BLANK READINESS ring.
//
// Root cause: every BLE drain kicks a light derive pass over TODAY, and the
// persisted rolling-baseline artifact was rebuilt from an in-memory list that
// `_BaselineHistoryCache.appendScalars` only ever APPENDS to — with no day
// identity. Re-deriving the same day stacked duplicate copies of today's value
// into the 28-day window. Once enough slots held the same value the readiness
// composite's robust z-score (median + MAD) hit MAD=0 and `robustZ` returned
// null for every input, so the composite went ABSENT and the ring rendered a
// blank "—" (while the cached AI briefing still showed the earlier score).
//
// The fix rebuilds the persisted artifact from `metric_series` — keyed
// `(date, key)` with REPLACE, so it is structurally one value per day and can
// never carry duplicate-day pollution. `LocalDb.trailingSeriesValues` reads the
// correct TRAILING window (the old `metricSeries(limit:)` returned the OLDEST n,
// a second latent bug). These tests pin both the mechanism and the fix.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_readiness_pollution_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> seedDay(String dayId, double readiness) async {
    await LocalDb.putDayResult(
      dayId: dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'readiness': readiness}
      }),
      windowJson: '{}',
      finalized: false,
      rhr: 55,
      rmssd: 60,
      readiness: readiness,
      series: {'readiness': readiness},
    );
  }

  // ── The mechanism: duplicate-day pollution collapses MAD → absent ──────────

  test('a baseline dominated by one repeated value makes robustZ degenerate',
      () {
    // A healthy trailing window of 28 DISTINCT days: robustZ resolves.
    final distinct = [for (var i = 0; i < 28; i++) 60.0 + i];
    expect(ana.robustZ(72, distinct), isNotNull,
        reason: 'distinct baseline → finite MAD → a real z-score');

    // The polluted window the OLD append path produced: today re-derived ~15×
    // stacked into the 28 slots (evicting real history). >half identical → the
    // median AND its MAD both land on the repeated value → MAD=0 → null.
    final polluted = [
      for (var i = 0; i < 15; i++) 60.0, // 15 copies of "today"
      for (var i = 0; i < 13; i++) 50.0 + i, // 13 surviving real days
    ];
    expect(ana.robustZ(72, polluted), isNull,
        reason: 'MAD=0 on quantized/polluted baseline → readiness goes absent');
  });

  // ── The fix: metric_series is one-row-per-day, so the window stays clean ────

  test('trailingSeriesValues is de-duplicated no matter how often a day rederives',
      () async {
    await (await LocalDb.instance).delete('metric_series');
    // 28 distinct real days.
    for (var i = 1; i <= 28; i++) {
      await seedDay('2026-04-${i.toString().padLeft(2, '0')}', 60.0 + i);
    }
    // Simulate the trigger: re-derive the SAME latest day 15 more times, exactly
    // as every BLE drain did. Under the OLD append path this stacked 15 copies;
    // metric_series REPLACE keeps it at one row.
    for (var k = 0; k < 15; k++) {
      await seedDay('2026-04-28', 88.0);
    }

    final window = await LocalDb.trailingSeriesValues('readiness', 28);
    expect(window.length, 28, reason: 'still 28 days, not 28+15');
    expect(window.where((v) => v == 88.0).length, 1,
        reason: 'the re-derived day appears exactly once — no pollution');
    // A clean window keeps MAD alive, so readiness computes.
    expect(ana.robustZ(72, window), isNotNull,
        reason: 'de-duplicated baseline → readiness ring shows a number');
  });

  test('trailingSeriesValues returns the NEWEST n (oldest→newest), not the oldest n',
      () async {
    await (await LocalDb.instance).delete('metric_series');
    // 30 days with strictly increasing readiness so newest vs oldest is obvious.
    for (var i = 1; i <= 30; i++) {
      await seedDay('2026-05-${i.toString().padLeft(2, '0')}', 40.0 + i);
    }

    final trailing = await LocalDb.trailingSeriesValues('readiness', 28);
    expect(trailing.length, 28);
    // Newest 28 = days 3..30 → values 43..70, returned ascending (oldest→newest).
    expect(trailing.first, 43.0);
    expect(trailing.last, 70.0);

    // The pre-fix path (`metricSeries(limit:)` = `date ASC LIMIT n`) returned the
    // OLDEST 28 instead — days 1..28 → 41..68. Pin the contrast so the trailing
    // semantics can't silently regress back to leading.
    final leading = await LocalDb.metricSeries('readiness', limit: 28);
    final leadingVals = [for (final r in leading) (r['value'] as num).toDouble()];
    expect(leadingVals.first, 41.0);
    expect(leadingVals.last, 68.0);
    expect(trailing, isNot(equals(leadingVals)));
  });
}
