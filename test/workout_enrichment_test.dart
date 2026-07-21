// Repo-seam tests over the REAL LocalDb (sqflite_ffi):
//   • getWorkout enriches from the decoded_onehz join: hr curve, avg/min/max,
//     zone_bands, recovery_curve, hr_drift_pct, time_to_peak_min, source.
//   • getWorkouts fills per-session avg_hr (the noData heuristic's input).
//   • getChart('hr') returns ONLY today's local-day points (a latest-complete-
//     day fallback curve must not render on today's axis).
//   • getRecords computes local PRs/streaks/counts from metric_series+sessions.
//   • LiveWorkoutState.zoneMinutes → the persisted 5-element zone_min shape.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:convert';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart' show LiveWorkoutState;

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'beef$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

Sample _sample(int ts, int counter, int hr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> _insertHr(int fromTs, int toTs, int Function(int ts) hrOf,
    {required int counterBase}) async {
  final raws = <RawRecord>[];
  final samples = <Sample?>[];
  var c = counterBase;
  for (var ts = fromTs; ts <= toTs; ts++) {
    raws.add(_raw(ts, c));
    samples.add(_sample(ts, c, hrOf(ts)));
    c++;
  }
  await LocalDb.insertRecordsBatch(raws, samples);
}

void main() {
  // Pure fallback for the Today stress tile — mirrors getDayStress so the tile
  // and the stress screen agree (the "stress pill has no number" fix).
  group('stressSummaryForToday', () {
    test('passes through a real SI-derived score', () {
      final out = stressSummaryForToday({
        'stress': {'score': 41.0, 'si': 120.0},
      }, 82);
      expect(out?['score'], 41.0);
    });
    test('does NOT fabricate a score from readiness when SI abstained', () {
      final out = stressSummaryForToday({
        'stress': {'score': null, 'si': null},
      }, 82);
      expect(out?['score'], isNull);
      expect(out?['si'], isNull);
    });
    test('returns null when there is no stress block at all', () {
      expect(stressSummaryForToday(const {}, null), isNull);
      expect(stressSummaryForToday(const {}, 82), isNull);
    });
  });

  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_enrichment_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    repo = LocalRepositoryImpl(getProfileMap: () => {'age': 30}); // maxHr 190
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // Session window: 10 min, first half HR 120, second half HR 150, then a
  // post-end recovery slope for the HRR curve.
  const start = 200000;
  const end = 200600;

  test('getWorkout joins decoded_onehz: curve, stats, zones, drift, HRR',
      () async {
    await LocalDb.putSession({
      'id': 'w-enrich',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'strain': 8.5,
      'duration_min': 10,
      'source': 'manual',
      'created_at': start * 1000,
    });
    // In-session: 120 bpm then 150 bpm.
    await _insertHr(start, start + 299, (_) => 120, counterBase: 10000);
    await _insertHr(start + 300, end - 1, (_) => 150, counterBase: 20000);
    // Post-end recovery: 150 → declining 0.2 bpm/s.
    await _insertHr(end + 1, end + 185,
        (ts) => 150 - ((ts - end) * 0.2).floor(),
        counterBase: 30000);

    final w = await repo.getWorkout('w-enrich');

    expect(w['source'], 'manual');
    expect(w['avg_hr'], 135);
    expect(w['min_hr'], 120);
    expect(w['max_hr'], 150);

    final hr = (w['hr'] as List).cast<Map>();
    expect(hr, isNotEmpty);
    for (final e in hr) {
      expect(e['v'], inInclusiveRange(120, 150));
      expect(e['t'], inInclusiveRange(start - 60, end));
    }

    // Zones at maxHr 190: 120 bpm = 63% → Z2, 150 bpm = 79% → Z3; 5 min each.
    final bands = (w['zone_bands'] as List).cast<Map>();
    expect(bands.length, 5);
    expect(bands[0]['zone'], 1);
    expect((bands[1]['min'] as num).toDouble(), closeTo(5.0, 0.1)); // Z2
    expect((bands[2]['min'] as num).toDouble(), closeTo(5.0, 0.1)); // Z3
    expect(bands[1]['pct'], 50);
    expect(bands[3]['min'], 0);
    // lo/hi bpm edges follow the 50/60/70/80/90% thresholds of maxHr 190.
    expect(bands[0]['lo'], 95);
    expect(bands[4]['hi'], 190);

    // First 150 bpm sample is 300 s in → 5 min to peak.
    expect(w['time_to_peak_min'], 5);
    // 2nd-half mean 150 vs 1st-half 120 → +25% drift.
    expect((w['hr_drift_pct'] as num).toDouble(), closeTo(25.0, 0.2));

    // Recovery curve: drops grow with time (~12/24/36 bpm at 60/120/180 s).
    final curve = (w['recovery_curve'] as List).cast<Map>();
    expect(curve.map((c) => c['sec']).toList(), [60, 120, 180]);
    final drops = [for (final c in curve) (c['drop'] as num).toDouble()];
    expect(drops[0], closeTo(12, 3));
    expect(drops[1], closeTo(24, 3));
    expect(drops[2], closeTo(36, 3));
  });

  test('getWorkout without any joined HR keeps the honest summary shape',
      () async {
    await LocalDb.putSession({
      'id': 'w-empty',
      'start_ts': 500000,
      'end_ts': 500300,
      'type': 'yoga',
      'status': 'done',
      'duration_min': 5,
      'source': 'manual',
      'created_at': 500000000,
    });
    final w = await repo.getWorkout('w-empty');
    expect(w['hr'], isNull); // no fabricated curve
    expect(w['avg_hr'], isNull); // → the screens' noData state
    expect(w['zone_bands'], isNull);
  });

  test('getWorkouts fills avg_hr per session from the 1 Hz join', () async {
    final res = await repo.getWorkouts(range: 'all');
    final workouts = (res['workouts'] as List).cast<Map>();
    final enriched =
        workouts.firstWhere((w) => w['id'] == 'w-enrich');
    final empty = workouts.firstWhere((w) => w['id'] == 'w-empty');
    expect(enriched['avg_hr'], 135);
    expect(enriched['min_hr'], 120);
    expect(((empty['avg_hr'] as num?) ?? 0), 0); // honest: no HR in window
  });

  // ── getChart('hr'): today-window clipping ─────────────────────────────────

  test("getChart('hr') drops a fallback curve from a previous day", () async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final yLabel = _label(yesterday);
    final yNoon =
        DateTime(yesterday.year, yesterday.month, yesterday.day, 12)
                .millisecondsSinceEpoch ~/
            1000;
    await LocalDb.putDayResult(
      dayId: yLabel,
      algoVersion: 1,
      payloadJson: jsonEncode({
        'date': yLabel,
        'scalars': {'rhr': 52.0},
        'series': {
          'hr_curve': [
            {'t': yNoon, 'v': 70},
            {'t': yNoon + 600, 'v': 74},
          ],
        },
        'sleep': {
          'accounting': {'value': {'tst_sec': 27900}},
        },
      }),
      windowJson: '{}',
      finalized: false,
      series: const {
        'rhr': 52.0,
        'strain': 15.4,
        'tst_min': 465.0,
        'efficiency': 0.93,
        'steps': 12000.0,
        'readiness': 91.0,
      },
    );

    // No today bundle exists → the seam falls back to yesterday's — but the
    // Today card must NOT get yesterday's curve on a today axis.
    final chart = await repo.getChart('hr');
    expect(chart['points'], isEmpty);
  });

  test("getChart('hr') returns only today's points from today's bundle",
      () async {
    final today = todayLabel();
    final now = DateTime.now();
    final todayMidnight = DateTime(now.year, now.month, now.day)
            .millisecondsSinceEpoch ~/
        1000;
    final t1 = todayMidnight + 3600;
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: 1,
      payloadJson: jsonEncode({
        'date': today,
        'scalars': {'rhr': 55.0},
        'series': {
          'hr_curve': [
            {'t': todayMidnight - 7200, 'v': 60}, // stale — clipped
            {'t': t1, 'v': 62},
            {'t': t1 + 600, 'v': 66},
          ],
        },
        'sleep': {
          'accounting': {'value': {'tst_sec': 24000}},
        },
      }),
      windowJson: '{}',
      finalized: false,
      series: const {
        'rhr': 55.0,
        'strain': 12.1,
        'tst_min': 400.0,
        'efficiency': 0.88,
        'steps': 8000.0,
        'readiness': 80.0,
      },
    );

    final chart = await repo.getChart('hr');
    final points = (chart['points'] as List).cast<Map>();
    expect(points.length, 2);
    expect(points.first['t'], t1);
  });

  // ── getRecords: local PRs + streaks ───────────────────────────────────────

  test('getRecords computes PRs with dates, workout count, and streaks',
      () async {
    // A third day (2 days ago) to extend the series + streaks.
    final d2 = DateTime.now().subtract(const Duration(days: 2));
    await LocalDb.putDayResult(
      dayId: _label(d2),
      algoVersion: 1,
      payloadJson: jsonEncode({
        'date': _label(d2),
        'scalars': {'rhr': 58.0},
        'sleep': {
          'accounting': {'value': {'tst_sec': 25800}},
        },
      }),
      windowJson: '{}',
      finalized: false,
      series: const {
        'rhr': 58.0,
        'strain': 9.0,
        'tst_min': 430.0,
        'efficiency': 0.85,
        'steps': 9000.0,
        'readiness': 75.0,
      },
    );

    final r = await repo.getRecords();
    expect(r['days_tracked'], greaterThanOrEqualTo(3));
    expect(r['nights_tracked'], greaterThanOrEqualTo(3));
    expect(r['workouts_tracked'], greaterThanOrEqualTo(2));

    final yLabel = _label(DateTime.now().subtract(const Duration(days: 1)));
    final records = (r['records'] as Map).cast<String, dynamic>();
    expect((records['lowest_rhr'] as Map)['value'], 52.0);
    expect((records['lowest_rhr'] as Map)['date'], yLabel);
    expect((records['top_strain'] as Map)['value'], 15.4);
    expect((records['longest_sleep'] as Map)['value'], 465.0);
    expect((records['best_efficiency'] as Map)['value'], 0.93);
    expect((records['most_steps'] as Map)['value'], 12000.0);
    expect((records['top_readiness'] as Map)['value'], 91.0);
    // Top workout strain comes from the sessions table, typed + dated.
    expect((records['top_workout'] as Map)['value'], 8.5);
    expect((records['top_workout'] as Map)['type'], 'run');

    // 3 consecutive derived days (incl. today) → streaks run.
    final streaks = (r['streaks'] as Map).cast<String, dynamic>();
    expect((streaks['wear'] as Map)['current'], greaterThanOrEqualTo(3));
    expect((streaks['sleep'] as Map)['current'], greaterThanOrEqualTo(3));
  });

  // ── zone_min accumulation shape (#15) ─────────────────────────────────────

  test('LiveWorkoutState.zoneMinutes emits the 5-element Z1..Z5 minutes shape',
      () {
    final w = LiveWorkoutState(startTime: DateTime.now(), targetKcal: 300);
    w.zoneSeconds[0] = 120; // rest — excluded from zone_min
    w.zoneSeconds[2] = 300; // Z2: 5 min
    w.zoneSeconds[3] = 90; // Z3: 1.5 min
    w.zoneSeconds[5] = 30; // Z5: 0.5 min
    expect(w.zoneMinutes(), [0.0, 5.0, 1.5, 0.0, 0.5]);
  });
}
