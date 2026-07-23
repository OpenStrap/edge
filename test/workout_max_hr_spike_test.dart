// issue #127: the workout summary showed max HR 160 while the HR page (minute-
// mean) peak was the true 143. Root cause was a raw `hr.reduce(math.max)` over
// the 1 Hz samples, so a single 1–2 s PPG motion spike defined the session max.
//
// These tests pin the fix at two levels:
//   • the shared smoother (compute/hr_max.dart) — a 1–2 s spike is excluded, a
//     genuine sustained peak is preserved, and the streaming (live) accumulator
//     agrees with the batch recompute;
//   • the repo seam over the REAL LocalDb (sqflite_ffi) — getWorkout AND
//     getWorkouts both report the smoothed peak, never the raw spike, so the
//     detail screen and the workout list agree.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/hr_max.dart';
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
  // ── The shared smoother: pure, no DB ─────────────────────────────────────
  group('smoothedMaxHr', () {
    test('excludes a 1–2 s transient spike (issue #127)', () {
      // 40 s at 143 with a lone 2 s jump to 200 — the reported failure shape.
      final hr = [
        for (var i = 0; i < 40; i++) (i == 20 || i == 21) ? 200 : 143,
      ];
      expect(smoothedMaxHr(hr, age: 30), 143);
    });

    test('rejects an isolated single-sample spike', () {
      final hr = [for (var i = 0; i < 30; i++) i == 15 ? 205 : 138];
      expect(smoothedMaxHr(hr, age: 30), 138);
    });

    test('preserves a genuine sustained peak above the baseline', () {
      // Baseline 140 with a real 15 s plateau at 158 — a brief peak that a
      // minute-mean would flatten, so it must NOT be suppressed.
      final hr = [
        for (var i = 0; i < 60; i++) (i >= 20 && i < 35) ? 158 : 140,
      ];
      expect(smoothedMaxHr(hr, age: 30), 158);
    });

    test('reports the index at the smoothed peak (time-to-peak)', () {
      final hr = [for (var i = 0; i < 60; i++) (i >= 30 && i < 45) ? 160 : 130];
      final at = smoothedMaxHrAt(hr, age: 30);
      expect(at, isNotNull);
      expect(at!.$1, 160);
      // First window whose median is 160 centres at the plateau's 3rd sample.
      expect(at.$2, inInclusiveRange(30, 44));
    });

    test('physiological reject drops an impossible reading', () {
      // 250 bpm is above the age-30 ceiling; the plausible max is 140.
      final hr = [for (var i = 0; i < 20; i++) i == 10 ? 250 : 140];
      expect(smoothedMaxHr(hr, age: 30), 140);
    });

    test('series shorter than a window falls back to the plausible max', () {
      expect(smoothedMaxHr([150], age: 30), 150);
      expect(smoothedMaxHr(const [], age: 30), isNull);
    });

    test('ceiling has headroom above 220 − age but hard-caps at 220', () {
      expect(hrCeilingForAge(30), 215); // (220-30)+25
      expect(hrCeilingForAge(70), 200); // floored, not (220-70)+25=175
      expect(hrCeilingForAge(10), 220); // capped, not 235
      expect(hrCeilingForAge(null), 220);
    });
  });

  // ── The min counterpart: symmetric spike suppression ─────────────────────
  group('smoothedMinHr', () {
    test('excludes a 1–2 s low dropout', () {
      // 40 s at 138 with a lone 2 s dip to 45 — the low-side of issue #127.
      final hr = [
        for (var i = 0; i < 40; i++) (i == 20 || i == 21) ? 45 : 138,
      ];
      expect(smoothedMinHr(hr, age: 30), 138);
    });

    test('preserves a genuine sustained low below the baseline', () {
      // Baseline 150 with a real 15 s trough at 132 — a brief genuine low that
      // must NOT be smoothed away.
      final hr = [
        for (var i = 0; i < 60; i++) (i >= 20 && i < 35) ? 132 : 150,
      ];
      expect(smoothedMinHr(hr, age: 30), 132);
    });

    test('physiological floor drops sub-30 garbage before the min', () {
      // 15 bpm is below the floor; the plausible min is 140.
      final hr = [for (var i = 0; i < 20; i++) i == 10 ? 15 : 140];
      expect(smoothedMinHr(hr, age: 30), 140);
    });

    test('series shorter than a window falls back to the plausible min', () {
      expect(smoothedMinHr([132], age: 30), 132);
      expect(smoothedMinHr(const [], age: 30), isNull);
    });
  });

  // ── The live accumulator agrees with the batch recompute ─────────────────
  group('RollingMaxHr (live accrual)', () {
    test('streaming max matches smoothedMaxHr over the same series', () {
      final hr = [
        for (var i = 0; i < 60; i++)
          (i == 25 || i == 26) ? 205 : (i >= 40 && i < 55 ? 158 : 141),
      ];
      final live = RollingMaxHr(age: 30);
      for (final v in hr) {
        live.add(v);
      }
      expect(live.max, 158); // spike rejected, genuine plateau kept
      expect(live.max, smoothedMaxHr(hr, age: 30));
    });

    test('LiveWorkoutState.accrueHr suppresses a spike in maxHrSeen', () {
      final w = LiveWorkoutState(
          startTime: DateTime.now(), targetKcal: 300, age: 30);
      for (var i = 0; i < 40; i++) {
        w.accrueHr((i == 18 || i == 19) ? 200 : 142);
      }
      expect(w.maxHrSeen, 142);
    });
  });

  // ── Repo seam over the real DB: detail + list both smoothed and agree ─────
  group('workout max HR over LocalDb', () {
    late LocalRepositoryImpl repo;

    const start = 800000;
    const end = 800600; // 10 min

    // Seed once so each test is self-contained and order-independent: a session
    // with baseline 143, a genuine 20 s plateau at 152, 2 s / 1 s HIGH motion
    // spikes to 200 / 210, and a 2 s LOW dropout to 40 plus a 1 s garbage 20 —
    // plus a spiked max_hr=160 already on the row (as the old live path left it).
    Future<void> seedSpikeSession() async {
      await LocalDb.putSession({
        'id': 'w-spike',
        'start_ts': start,
        'end_ts': end,
        'type': 'run',
        'status': 'done',
        'duration_min': 10,
        // The recompute must OVERRIDE this, not floor against it.
        'max_hr': 160,
        'source': 'manual',
        'created_at': start * 1000,
      });
      await _insertHr(start, end - 1, (ts) {
        final o = ts - start;
        if (o >= 200 && o < 220) return 152; // real brief peak
        if (o == 400 || o == 401) return 200; // 2 s high motion spike
        if (o == 450) return 210; // 1 s high motion spike
        if (o == 300 || o == 301) return 40; // 2 s low dropout
        if (o == 350) return 20; // 1 s sub-physiological garbage
        return 143;
      }, counterBase: 40000);
    }

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_max_hr_spike_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      repo = LocalRepositoryImpl(getProfileMap: () => {'age': 30}); // maxHr 190
      await seedSpikeSession();
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('getWorkout reports the smoothed peak, not a 1–2 s spike', () async {
      final w = await repo.getWorkout('w-spike');
      expect(w['max_hr'], 152); // genuine peak kept, spikes + stored 160 gone
      expect(w['min_hr'], 143); // 40 dropout + 20 garbage excluded, not the min
      // time-to-peak lands on the real plateau (~200 s in → 3 min), not a spike.
      expect(w['time_to_peak_min'], inInclusiveRange(3, 4));
    });

    test('getWorkouts list agrees with the detail screen', () async {
      final res = await repo.getWorkouts(range: 'all');
      final workouts = (res['workouts'] as List).cast<Map>();
      final w = workouts.firstWhere((e) => e['id'] == 'w-spike');
      expect(w['max_hr'], 152); // same smoothed peak as getWorkout
      expect(w['min_hr'], 143); // same smoothed trough as getWorkout
    });
  });
}
