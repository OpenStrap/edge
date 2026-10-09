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

  Future<void> seedDay(String dayId, double readiness,
      {bool finalized = false}) async {
    await LocalDb.putDayResult(
      dayId: dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'readiness': readiness}
      }),
      windowJson: '{}',
      finalized: finalized,
      rhr: 55,
      rmssd: 60,
      readiness: readiness,
      series: {
        'readiness': readiness,
        'ln_rmssd': 4.0,
        'rhr': 55.0,
        'resp_rate': 14.0,
        'skin_temp_adc': 3000.0,
        'rmssd': 60.0,
      },
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

  test('trailingSeriesValues(before:) is the window strictly before that day',
      () async {
    await (await LocalDb.instance).delete('metric_series');
    for (var i = 1; i <= 30; i++) {
      await seedDay('2026-05-${i.toString().padLeft(2, '0')}', 40.0 + i);
    }
    // A past day's baseline: days before 05-20 only (01..19), never 05-20
    // itself and never the newer days that came after it.
    final past = await LocalDb.trailingSeriesValues('readiness', 28,
        before: '2026-05-20');
    expect(past.length, 19);
    expect(past.first, 41.0);
    expect(past.last, 59.0);
  });

  // ── The read path never trusts a polluted-but-valid on-disk artifact ───────

  test('load ignores a valid polluted rolling_artifact, even when all finalized',
      () async {
    await (await LocalDb.instance).delete('metric_series');
    // Clean canonical store: 28 distinct, FINALIZED days. All-finalized is the
    // case where a derive sweep does no work and the old self-heal (which only
    // ran inside _refreshBaselines on a working sweep) never fired.
    for (var i = 1; i <= 28; i++) {
      await seedDay('2026-07-${i.toString().padLeft(2, '0')}', 60.0 + i,
          finalized: true);
    }
    // Persist a VALID but polluted artifact — exactly what an affected install
    // carries on disk: 20 identical readiness values (MAD would be 0).
    await LocalDb.putBaseline(
      'rolling_artifact',
      jsonEncode({
        'series': {
          'readiness': [for (var i = 0; i < 20; i++) 60.0],
          'ln_rmssd': [for (var i = 0; i < 20; i++) 4.0],
          'rhr': [for (var i = 0; i < 20; i++) 55.0],
          'resp_rate': [for (var i = 0; i < 20; i++) 14.0],
          'skin_temp_adc': [for (var i = 0; i < 20; i++) 3000.0],
          'rmssd': [for (var i = 0; i < 20; i++) 60.0],
        },
      }),
    );

    // The read path rebuilds from metric_series and IGNORES the artifact.
    final window = await debugBaselineWindow('readiness');
    expect(window.length, 28,
        reason: 'from the 28-day store, not the 20-slot polluted artifact');
    expect(window.toSet().length, greaterThan(1),
        reason: "distinct real days — not the artifact's one repeated value");
    expect(ana.robustZ(72, window), isNotNull,
        reason: 'clean baseline → readiness computes on the FIRST derive, '
            'with no refresh required to self-heal');
  });

  // ── The SWEEP path: the "frozen" snapshot must actually stay frozen ────────
  //
  // The load path above was fixed, but the SWEEP re-introduced the same
  // pollution one level up: `run()`/`rescanRecent()` loaded the snapshot ONCE
  // — already containing the persisted values of the up-to-21 days it was
  // about to re-derive — and then appended each finished day's scalars back
  // into that shared snapshot, evicting a real old day to stay at 28. Days
  // 2..N of the sweep therefore read a window holding duplicate copies of the
  // recent days, in DESCENDING date order (the sweep runs newest-first), and
  // median/MAD collapsed toward the repeated values exactly as before.

  Future<void> seedSweepDays(String month, int n) async {
    await (await LocalDb.instance).delete('metric_series');
    for (var i = 1; i <= n; i++) {
      // Distinct readiness AND distinct rhr per day, so "did this day's own
      // value leak into its own window" is decidable by value.
      await seedDay('2026-$month-${i.toString().padLeft(2, '0')}', 40.0 + i);
    }
  }

  test('a sweep never mutates the frozen snapshot — every day gets the same '
      'window a fresh load would give', () async {
    await seedSweepDays('09', 28);
    // run()/rescanRecent dispatch NEWEST-FIRST over the recent window.
    final orderedDays = [
      for (var i = 28; i >= 8; i--) '2026-09-${i.toString().padLeft(2, '0')}',
    ];

    final first = await debugSweepBaselineWindows('readiness', orderedDays);
    final second = await debugSweepBaselineWindows('readiness', orderedDays);
    expect(first, equals(second),
        reason: 'the sweep snapshot is immutable — deriving days cannot change '
            'what a later day in the same sweep reads');

    for (var i = 0; i < orderedDays.length; i++) {
      final window = first[i];
      expect(window.toSet().length, window.length,
          reason: '${orderedDays[i]}: no value may appear twice — the old '
              'append path stacked each finished day back in');
      final sorted = [...window]..sort();
      expect(window, equals(sorted),
          reason: '${orderedDays[i]}: the window is a real trailing series in '
              'date order, not history with recent days appended out of order');
    }
  });

  test('no day is ever inside its own baseline window', () async {
    await seedSweepDays('10', 28);
    final today = '2026-10-28';
    final ownValue = 40.0 + 28;

    // The unfiltered window (what backs the persisted artifact + the rescan
    // signature) legitimately contains today...
    final unfiltered = await debugBaselineWindow('readiness');
    expect(unfiltered, contains(ownValue));

    // ...but the window the day is DERIVED against must not.
    final own = (await debugSweepBaselineWindows('readiness', [today])).single;
    expect(own, isNot(contains(ownValue)),
        reason: "z-scoring a day against a baseline containing itself pulls "
            'the baseline toward the value under test — the exact '
            'self-inclusion analytics v38 fixed one layer down');
    expect(own.length, 27, reason: 'strictly the 27 prior days');
    expect(own.every((v) => v < ownValue), isTrue,
        reason: 'strictly EARLIER days — a backfill sweep must not leak later '
            "days into an older day's baseline (that would also make the "
            'result depend on sweep order)');
  });

  test('a mid-history backfill day sees only days before it', () async {
    await seedSweepDays('11', 28);
    // Re-derive a day in the MIDDLE of history (what "Re-analyze" does).
    final mid = '2026-11-10';
    final window = (await debugSweepBaselineWindows('readiness', [mid])).single;
    expect(window.length, 9, reason: 'the 9 days 2026-11-01..09');
    expect(window.last, 40.0 + 9);
    expect(window.every((v) => v < 40.0 + 10), isTrue);
  });

  test('quiet_hrr rides the sweep: prior measured days only', () async {
    // Strain is priced on the median of these. The day itself (its own level
    // feeds LATER days, never itself) and an imported day are both out.
    await LocalDb.putMetricSeriesValue('2026-12-01', 'quiet_hrr', 0.11);
    await LocalDb.putMetricSeriesValue('2026-12-02', 'quiet_hrr', 0.12);
    await LocalDb.putDayResult(
      dayId: '2026-12-03',
      algoVersion: 1,
      payloadJson: '{"date":"2026-12-03","imported":true,"source":"whoop_export"}',
      windowJson: '{}',
      finalized: true,
      source: 'whoop_export',
      series: {'quiet_hrr': 0.13},
    );
    await LocalDb.putMetricSeriesValue('2026-12-04', 'quiet_hrr', 0.14);
    final window =
        (await debugSweepBaselineWindows('quiet_hrr', ['2026-12-04'])).single;
    expect(window, [0.11, 0.12]);
    // The non-sweep read (sessions, live gauge) sees the same window.
    expect(
        await LocalDb.trailingSeriesValues('quiet_hrr', 28, before: '2026-12-04'),
        [0.11, 0.12]);
  });

  test('the rescan signature sees a quiet level move under ONE day\'s window',
      () async {
    // Chronological [.10, .10, .20, .20, .20, .15, .30]: changing the sixth
    // day .15 → .25 keeps the count (7) and the overall median (.20) — all a
    // count-and-median signature saw — but the seventh day's strictly-prior
    // window goes from median .175 to .20, so that day's strain moves and the
    // rescan must not skip it.
    final db = await LocalDb.instance;
    await db.delete('metric_series', where: 'key = ?', whereArgs: ['quiet_hrr']);
    const dates = [
      '2027-01-01', '2027-01-02', '2027-01-03', '2027-01-04', //
      '2027-01-05', '2027-01-06', '2027-01-07',
    ];
    const values = [0.10, 0.10, 0.20, 0.20, 0.20, 0.15, 0.30];
    for (var i = 0; i < dates.length; i++) {
      await LocalDb.putMetricSeriesValue(dates[i], 'quiet_hrr', values[i]);
    }
    final before = await debugBaselineSignature();
    expect(await debugBaselineSignature(), before,
        reason: 'stable when nothing moved — a rescan costs nothing then');
    final whole = await debugBaselineWindow('quiet_hrr');
    final todayBefore =
        (await debugSweepBaselineWindows('quiet_hrr', ['2027-01-07'])).single;

    await LocalDb.putMetricSeriesValue('2027-01-06', 'quiet_hrr', 0.25);
    final wholeAfter = await debugBaselineWindow('quiet_hrr');
    final todayAfter =
        (await debugSweepBaselineWindows('quiet_hrr', ['2027-01-07'])).single;
    // What the old signature term read did not move…
    expect(wholeAfter.length, whole.length);
    expect(ana.median(wholeAfter), ana.median(whole));
    expect(ana.median(whole), closeTo(0.20, 1e-9));
    // …while the window the day is actually priced on did.
    expect(ana.median(todayBefore), closeTo(0.175, 1e-9));
    expect(ana.median(todayAfter), closeTo(0.20, 1e-9));
    expect(await debugBaselineSignature(), isNot(before));

    // The NEWEST level (normally today's, rewritten as its wake series grows)
    // sits in no earlier day's window, so moving it must not trigger a rescan.
    final stable = await debugBaselineSignature();
    await LocalDb.putMetricSeriesValue('2027-01-07', 'quiet_hrr', 0.12);
    expect(await debugBaselineSignature(), stable);

    // …until a LATER day exists that wrote no level of its own (too few wake
    // minutes) and may already be finalized: it was priced on the newest
    // level, so moving that level must re-price it.
    await LocalDb.putMetricSeriesValue('2027-01-08', 'rhr', 52);
    final withLater = await debugBaselineSignature();
    await LocalDb.putMetricSeriesValue('2027-01-07', 'quiet_hrr', 0.14);
    expect(await debugBaselineSignature(), isNot(withLater));
  });
}
