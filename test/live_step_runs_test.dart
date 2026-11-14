// Tier 1 (strap 100 Hz IMU) — the span it may claim, and the gain it may apply.
//
// Two defects are pinned here, and they are the two that make a step number
// wrong rather than merely imprecise:
//
//   1. A LIVE SESSION IS NOT A COVERAGE SPAN. The old writer banked one row per
//      connected session, spanning the whole wall-clock hull of the link. On the
//      owner's own export that produced a row claiming 9.35 h of band coverage
//      for 216 steps. Once a source ladder picks a source PER SPAN, that hull
//      takes nine hours away from a phone that was counting 11.8 steps/min and
//      the day loses ~7,000 steps. A span may only be time the stream was
//      delivering AND the pedometer was counting.
//
//   2. THE GAIN IS APPLIED EXACTLY ONCE. `pedometer()` returns a RAW count;
//      `StepParams.gain` belongs at the daily-sum layer (as `calcSteps` puts
//      it), which here is the moment a run is banked. Applying it on the
//      session total as well shipped a silent x1.23.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/ble/live_step_runs.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

/// One 100 Hz frame of walking-shaped |a|(g): a ~2 Hz gait oscillation riding
/// the 1 g gravity baseline, which is what the AN-2554 counter expects. Indexed
/// on the ABSOLUTE frame number so the gait stays phase-continuous across a
/// still stretch. Same generator as live_coverage_window_test.dart.
List<double> _walkFrame(int frameIndex, int samples) => [
  for (var i = 0; i < samples; i++)
    1.0 +
        0.45 *
            math.sin(2 * math.pi * 2.0 * ((frameIndex * samples + i) / 100.0)),
];

/// A wrist doing nothing: flat 1 g, well inside the detector's dead zone.
List<double> _stillFrame(int samples) => List<double>.filled(samples, 1.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_live_step_runs_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await LocalDb.instance;
    await db.delete('live_coverage');
  });

  // ── the pure fold ──────────────────────────────────────────────────────────
  group('GaitRuns', () {
    test('back-to-back counting minutes are ONE run', () {
      final g = GaitRuns();
      for (var i = 1; i <= 4; i++) {
        g.addChunk(
          endTs: 1000 + i * 60,
          seconds: 60,
          rawSteps: 100,
          floorTs: 1000,
        );
      }
      expect(g.runs, hasLength(1));
      expect(g.runs.single.startTs, 1000);
      expect(g.runs.single.endTs, 1240);
      expect(g.runs.single.rawSteps, 400);
    });

    test('a silent minute SPLITS the runs and is not claimed', () {
      final g = GaitRuns();
      // walk, walk, [10 still minutes recorded as nothing], walk
      g.addChunk(endTs: 1060, seconds: 60, rawSteps: 110, floorTs: 1000);
      g.addChunk(endTs: 1120, seconds: 60, rawSteps: 110, floorTs: 1000);
      g.addChunk(endTs: 1780, seconds: 60, rawSteps: 110, floorTs: 1000);

      expect(g.runs, hasLength(2));
      expect(g.runs.first.seconds, 120);
      expect(g.runs.last.seconds, 60);
      // The still stretch is simply absent — the whole point.
      final claimed = g.runs.fold<int>(0, (a, r) => a + r.seconds);
      expect(claimed, 180);
      expect(claimed, lessThan(1780 - 1000));
    });

    test('a chunk covers the time it SAMPLED, not the wall time it took', () {
      // 60 s of signal that dribbled in over an hour of a flaky link: the run
      // is 60 s wide, not 3600. This is the 9.35 h / 216 steps failure in the
      // small.
      final g = GaitRuns()
        ..addChunk(endTs: 4600, seconds: 60, rawSteps: 90, floorTs: 1000);
      expect(g.runs.single.seconds, 60);
    });

    test('zero-step and zero-length chunks are dropped', () {
      final g = GaitRuns()
        ..addChunk(endTs: 1060, seconds: 60, rawSteps: 0, floorTs: 1000)
        ..addChunk(endTs: 1060, seconds: 0, rawSteps: 50, floorTs: 1000);
      expect(g.isEmpty, isTrue);
    });

    test('a run never starts before the session did', () {
      // The first chunk of a session finishes slightly under 60 s after the
      // first frame, because its samples took wall time to arrive.
      final g = GaitRuns()
        ..addChunk(endTs: 1059, seconds: 60, rawSteps: 90, floorTs: 1000);
      expect(g.runs.single.startTs, 1000);
    });

    test('the run cap merges rather than losing steps', () {
      final g = GaitRuns(maxRuns: 3);
      for (var i = 0; i < 10; i++) {
        g.addChunk(
          endTs: 1000 + i * 600, // each one isolated by a 9-minute gap
          seconds: 60,
          rawSteps: 10,
          floorTs: 500,
        );
      }
      expect(g.runs, hasLength(3));
      expect(g.runs.fold<int>(0, (a, r) => a + r.rawSteps), 100);
    });
  });

  // ── the real session, end to end ───────────────────────────────────────────
  test('a walk, ten still minutes, another walk — two spans, not fourteen '
      'minutes of coverage, and the gain applied once', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);

    const recTs = 1786400000; // band record time; never advances (real hw)
    const samplesPerFrame = 10; // 0x33 IMU shape
    const framesPerMinute = 600;
    const startMs = recTs * 1000;

    // Rebuild the exact per-minute signal the app will see, so the expected
    // step counts come from the SHIPPING pedometer rather than a guess.
    final minutes = <List<double>>[];
    var frame = 0;
    void phase(int mins, List<double> Function(int f) gen) {
      for (var m = 0; m < mins; m++) {
        final sig = <double>[];
        for (var f = 0; f < framesPerMinute; f++, frame++) {
          final mags = gen(frame);
          sig.addAll(mags);
          app.debugFeedLiveAccel(
            mags,
            recTs: recTs,
            atMs: startMs + frame * 100,
          );
        }
        minutes.add(sig);
      }
    }

    phase(2, (f) => _walkFrame(f, samplesPerFrame));
    phase(10, (_) => _stillFrame(samplesPerFrame));
    phase(2, (f) => _walkFrame(f, samplesPerFrame));
    await app.debugFinalizeLivePedometer();

    final db = await LocalDb.instance;
    final rows = await db.query('live_coverage', orderBy: 'start_ts');

    // 1. TWO spans, one per walk.
    expect(rows, hasLength(2), reason: 'one row per walk, not one per session');
    for (final r in rows) {
      expect(
        r['source'],
        kStepSourceStrap,
        reason:
            'tier 1 must be distinguishable from the phone and from an '
            'imported band count',
      );
    }

    // 2. The still stretch is not claimed. 14 minutes streamed, ~4 covered.
    final covered = rows.fold<int>(
      0,
      (a, r) => a + (r['end_ts'] as int) - (r['start_ts'] as int),
    );
    expect(covered, closeTo(240, 8));
    expect(
      covered,
      lessThan(600),
      reason: 'the ten still minutes are not steps',
    );
    // …and the gap between the two spans really is the still stretch.
    expect(
      (rows[1]['start_ts'] as int) - (rows[0]['end_ts'] as int),
      closeTo(600, 8),
    );
    expect(
      rows.first['start_ts'],
      recTs,
      reason: 'spans stay in the band record-time base',
    );

    // 3. THE GAIN, EXACTLY ONCE. Raw per run, gained once at banking.
    final rawWalk1 = ana.pedometer(minutes[0]) + ana.pedometer(minutes[1]);
    final rawWalk2 = ana.pedometer(minutes[12]) + ana.pedometer(minutes[13]);
    expect(rawWalk1, greaterThan(0), reason: 'the walk must count at all');
    expect(rows[0]['steps'], (rawWalk1 * ana.StepParams.gain).round());
    expect(rows[1]['steps'], (rawWalk2 * ana.StepParams.gain).round());
    // The shape of the bug this replaces: gain on the run AND on the session.
    // The default gain is 1.00 since the 2026-08-16 steps audit, so a second
    // application is numerically invisible and `lessThan(doubled)` no longer
    // bites — it holds against any non-unit gain, and separately against the
    // exact value the old 1.11 double-application used to write.
    final doubled = (rawWalk1 * ana.StepParams.gain * ana.StepParams.gain)
        .round();
    expect(rows[0]['steps'], lessThanOrEqualTo(doubled));
    expect(rows[0]['steps'], isNot((rawWalk1 * 1.11 * 1.11).round()));

    // 4. The still minutes contributed nothing at all.
    expect(ana.pedometer(minutes[5]), 0);
  });

  // ── GATE 1: gait activities only ───────────────────────────────────────────
  group('the gait gate', () {
    test('the pure predicate accepts foot locomotion and nothing else', () {
      expect(isGaitStepType('walking'), isTrue);
      expect(
        isGaitStepType('Trail running'.toLowerCase()),
        isFalse,
        reason: 'the stored key is trail_running, not "trail running"',
      );
      expect(isGaitStepType('trail_running'), isTrue);
      expect(isGaitStepType('Running'), isTrue, reason: 'case-insensitive');
      // The unbounded-over-count cases: rhythmic arm work with no strides.
      expect(isGaitStepType('rowing'), isFalse);
      expect(isGaitStepType('boxing'), isFalse);
      expect(isGaitStepType('elliptical'), isFalse);
      expect(isGaitStepType('weight_training'), isFalse);
      // "No session" is not a gait type — the caller decides that separately.
      expect(isGaitStepType(null), isFalse);
    });

    test(
      'a ROWING session banks no steps from a walking-shaped signal',
      () async {
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        // The signal is a textbook walk. The only thing refusing it is the
        // session type — which is the whole point: on a wrist, rowing LOOKS like
        // this (OxWalk P18: 217 true steps read as 650).
        app.activeWorkout = LiveWorkoutState(
          startTime: DateTime.now(),
          targetKcal: 0,
          type: 'rowing',
        );
        const recTs = 1786600000;
        for (var f = 0; f < 1200; f++) {
          app.debugFeedLiveAccel(
            _walkFrame(f, 10),
            recTs: recTs,
            atMs: recTs * 1000 + f * 100,
          );
        }
        expect(
          app.liveStepsAbsentReason,
          isNotNull,
          reason: 'absent must carry a reason, never a bare dash or a 0',
        );
        await app.debugFinalizeLivePedometer();
        final db = await LocalDb.instance;
        expect(await db.query('live_coverage'), isEmpty);
      },
    );

    test('the SAME signal under a WALKING session banks normally', () async {
      // The control: without this, the test above passes if the gate is wired
      // to reject everything.
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(),
        targetKcal: 0,
        type: 'walking',
      );
      const recTs = 1786700000;
      for (var f = 0; f < 1200; f++) {
        app.debugFeedLiveAccel(
          _walkFrame(f, 10),
          recTs: recTs,
          atMs: recTs * 1000 + f * 100,
        );
      }
      expect(app.liveStepsAbsentReason, isNull);
      await app.debugFinalizeLivePedometer();
      final db = await LocalDb.instance;
      final rows = await db.query('live_coverage');
      expect(rows, isNotEmpty);
      expect((rows.first['steps'] as num).toInt(), greaterThan(0));
    });
  });

  // ── GATE 2: the measured sample rate ───────────────────────────────────────
  group('the sample-rate floor', () {
    test('achievedSampleRateHz measures, and refuses to guess', () {
      expect(achievedSampleRateHz(6000, 0, 60000), 100.0);
      expect(achievedSampleRateHz(6000, 0, 240000), 25.0);
      // A 30 s stall inside a chunk halves the achieved rate — which is how the
      // gap `_magMin` cannot see gets caught.
      expect(achievedSampleRateHz(6000, 0, 120000), 50.0);
      // Unmeasurable is not "fine": no span, no samples, inverted.
      expect(achievedSampleRateHz(6000, 0, 0), isNull);
      expect(achievedSampleRateHz(0, 0, 60000), isNull);
      expect(achievedSampleRateHz(6000, null, 60000), isNull);
      expect(achievedSampleRateHz(6000, 100, 50), isNull);
    });

    test('a 25 Hz stream banks NOTHING even though the signal counts', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      const recTs = 1786800000;
      // Identical frames to the walk above, delivered at 400 ms instead of
      // 100 ms: 6000 samples over 240 s = 25 Hz. OxWalk §4 measures MAPE 90.8%
      // there, with nine of 39 participants reading exactly zero.
      for (var f = 0; f < 600; f++) {
        app.debugFeedLiveAccel(
          _walkFrame(f, 10),
          recTs: recTs,
          atMs: recTs * 1000 + f * 400,
        );
      }
      expect(app.liveStepsAbsentReason, contains('too slowly'));
      await app.debugFinalizeLivePedometer();
      final db = await LocalDb.instance;
      expect(
        await db.query('live_coverage'),
        isEmpty,
        reason: 'a refused window is ABSENT, never a count and never a 0',
      );
    });
  });

  // A gait workout backgrounded mid-walk loses its IMU stream (the owner is
  // foreground-only) while HR and GPS keep recording. The minutes counted
  // before the lock are not the walk's total.
  group('a gap in the workout\'s accel stream', () {
    Future<Map<String, Object?>?> walk({required int gapMs}) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(workoutId: 'gap$gapMs', type: 'walking');
      final base = DateTime.now().millisecondsSinceEpoch - 130000 - gapMs;
      for (var f = 0; f < 1200; f++) {
        app.debugFeedLiveAccel(
          _walkFrame(f, 10),
          atMs: base + f * 100 + (f >= 600 ? gapMs : 0),
        );
      }
      if (gapMs == 0) {
        expect(app.workoutStepsMeasured, greaterThan(0));
      } else {
        expect(app.workoutStepsMeasured, isNull);
      }
      await app.stopWorkout();
      return LocalDb.session('gap$gapMs');
    }

    test('a stream that only came up minutes in banks no steps', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(workoutId: 'late', type: 'walking');
      final base = DateTime.now().millisecondsSinceEpoch + 60000;
      for (var f = 0; f < 1200; f++) {
        app.debugFeedLiveAccel(_walkFrame(f, 10), atMs: base + f * 100);
      }
      expect(app.workoutStepsMeasured, isNull);
      await app.stopWorkout();
      expect((await LocalDb.session('late'))!['steps'], isNull);
    });

    test('a covered walk banks its steps', () async {
      final row = await walk(gapMs: 0);
      expect((row!['steps'] as num).toInt(), greaterThan(0));
    });

    test('a walk with a locked-screen gap banks no step total', () async {
      final row = await walk(gapMs: 10 * 60 * 1000);
      expect(row, isNotNull);
      expect(row!['steps'], isNull);
    });
  });

  test('a session that never counted writes nothing', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    const recTs = 1786500000;
    for (var f = 0; f < 600; f++) {
      app.debugFeedLiveAccel(
        _stillFrame(10),
        recTs: recTs,
        atMs: recTs * 1000 + f * 100,
      );
    }
    await app.debugFinalizeLivePedometer();
    final db = await LocalDb.instance;
    expect(await db.query('live_coverage'), isEmpty);
  });

  // A reset between collecting steps and finalizing them must not let the
  // finalizer re-bank the deleted session: it judges the runs by the
  // generation they were COLLECTED under, not the one current when it runs.
  group('a reset between collection and finalization', () {
    Future<AppState> walked() async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      const recTs = 1786900000;
      for (var f = 0; f < 1200; f++) {
        app.debugFeedLiveAccel(
          _walkFrame(f, 10),
          recTs: recTs,
          atMs: recTs * 1000 + f * 100,
        );
      }
      return app;
    }

    test('control: with no reset the walk is banked', () async {
      final app = await walked();
      await app.debugFinalizeLivePedometer();
      final db = await LocalDb.instance;
      expect(await db.query('live_coverage'), isNotEmpty);
    });

    test('control: without a reset the walk is checkpointed', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      const recTs = 1787100000;
      for (var f = 0; f < 700; f++) {
        app.debugFeedLiveAccel(_walkFrame(f, 10),
            recTs: recTs, atMs: recTs * 1000 + f * 100);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('live_session_checkpoint'), isTrue);
    });

    test('a reset after the steps were collected is not checkpointed back',
        () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      const recTs = 1787000000;
      // One full walking minute: runs are buffered and a first checkpoint lands.
      for (var f = 0; f < 700; f++) {
        app.debugFeedLiveAccel(_walkFrame(f, 10),
            recTs: recTs, atMs: recTs * 1000 + f * 100);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('live_session_checkpoint');
      ResetGate.enter();
      ResetGate.leave();
      // The next minute completes AFTER the reset; the buffered runs predate it.
      for (var f = 700; f < 1400; f++) {
        app.debugFeedLiveAccel(_walkFrame(f, 10),
            recTs: recTs, atMs: recTs * 1000 + f * 100);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(prefs.containsKey('live_session_checkpoint'), isFalse,
          reason: 'runs from before the reset must not be written back');
    });

    test('a reset after the steps were collected keeps them out of storage',
        () async {
      final app = await walked();
      ResetGate.enter();
      ResetGate.leave();
      // The reset is over (nothing is active); only the generation moved.
      expect(ResetGate.active, isFalse);
      await app.debugFinalizeLivePedometer();
      final db = await LocalDb.instance;
      expect(await db.query('live_coverage'), isEmpty,
          reason: 'steps collected before the reset must not come back');
    });
  });
}
