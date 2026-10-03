// Regressions for the "app closed mid-ride" class of failure.
//
// The live-workout path had several independent ways to lose a run or ride:
// heavy derivation firing an isolate mid-session, the display sleeping, and
// (platform-side) the foreground-service location type being stripped by an
// unrelated restart. These cover the parts that are testable in pure Dart —
// the two platform-channel behaviours are asserted at the seam.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Wait until [condition] holds, or give up after [timeout].
///
/// Returns as soon as the condition is met, so the generous timeout costs
/// nothing on a fast machine — it only buys headroom on a loaded CI runner.
/// Deliberately does NOT assert; the caller asserts afterwards so the failure
/// message names the real expectation rather than "timed out".
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Releasing the gate re-arms the scheduler, which reads the durable
  // compute_jobs queue — so this needs a real (in-memory-ish) DB.
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_reliability_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // LocalDb.instance caches its open Database keyed only on `db.isOpen`, not
  // on `dbName` — a still-open handle left by an earlier suite is handed back
  // as-is, ignoring the dbName set above. Close ours so whichever suite runs
  // next doesn't inherit it (see phone_pedometer_hour_walk_test.dart, which
  // was the actual source of this file's order-dependent flake: edge#259).
  tearDownAll(() => LocalDb.close());

  group('DeriveScheduler — live-workout gate', () {
    late List<String> logs;
    late int runs;
    late DeriveScheduler s;

    setUp(() {
      logs = [];
      runs = 0;
      s = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async => runs++,
        log: logs.add,
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
      );
    });

    tearDown(() => s.dispose());

    test('holding is idempotent — repeated starts log once', () {
      s.setWorkoutActive(true);
      s.setWorkoutActive(true);
      expect(
        logs.where((l) => l.contains('workout live')).length,
        1,
        reason: 'a re-entrant start must not re-log or re-arm',
      );
    });

    test('releasing after a hold logs the drain exactly once', () {
      s.setWorkoutActive(true);
      s.setWorkoutActive(false);
      s.setWorkoutActive(false);
      expect(logs.where((l) => l.contains('workout ended')).length, 1);
    });

    test('a release without a preceding hold is a no-op', () {
      s.setWorkoutActive(false);
      expect(logs, isEmpty);
    });

    test('the gate is visible in the snapshot', () {
      expect(s.snapshot()['workout_active'], isFalse);
      s.setWorkoutActive(true);
      expect(s.snapshot()['workout_active'], isTrue);
      s.setWorkoutActive(false);
      expect(s.snapshot()['workout_active'], isFalse);
    });

    test(
      'a queued job stays parked for the session, then runs on release',
      () async {
        // This MUST enqueue real work. An earlier version asserted runs == 0
        // without queueing anything, so it passed even with the gate deleted —
        // CodeRabbit caught it on the PR, and it was right.
        s.setWorkoutActive(true);
        s.markStoredData(); // enqueues a durable derive_light job

        // Wait for the PARKED STATE, not for a stopwatch.
        //
        // This was `await Future.delayed(150ms); expect(runs, 0)`, justified as
        // "you cannot poll for something that never happens". You can here, and
        // the sleep was both flaky and weaker than it looked: it failed about
        // one run in four under the full parallel suite, and it passed even
        // before the enqueue had landed, because zero is also what you see when
        // nothing was ever queued.
        //
        // `pending_light` going true is the real precondition — the job is in
        // the durable queue AND the scheduler has seen it. And `_arm()` returns
        // early while a workout is live, so no timer is ever created: once the
        // job is parked, `runs` cannot advance no matter how long anything
        // takes. That makes this deterministic rather than merely patient.
        await _until(() => s.snapshot()['pending_light'] == true);
        expect(runs, 0,
            reason: 'a queued job must not run while a workout is live');

        s.setWorkoutActive(false);
        // But the positive direction MUST poll. The drain does several DB
        // round-trips, and a fixed 120 ms sleep here passed locally and failed
        // on a slower CI runner — a flake I introduced in the previous commit.
        await _until(() => runs == 1);
        expect(runs, 1,
            reason: 'and it must drain once the session ends, not be dropped');
      },
    );

    test(
      'the hold is time-capped — a forgotten workout cannot park work forever',
      () async {
        // The reported bug: start a workout, forget it, and Home spends the
        // rest of the day on "Nothing recorded for today — Sync the band"
        // while the strap is connected and syncing fine. The sync was never
        // the problem: every derive job it queued was parked behind a hold
        // whose design assumed "a workout is minutes long".
        var cappedRuns = 0;
        final capped = DeriveScheduler(
          run: ({required DeriveJobKind kind}) async => cappedRuns++,
          log: logs.add,
          onChanged: () {},
          lightSettle: const Duration(milliseconds: 10),
          heavySettle: const Duration(milliseconds: 10),
          workoutHoldCap: const Duration(milliseconds: 150),
        );
        addTearDown(capped.dispose);

        capped.setWorkoutActive(true);
        capped.markStoredData();
        await _until(() => capped.snapshot()['pending_light'] == true);
        expect(cappedRuns, 0,
            reason: 'inside the cap the hold works exactly as before');

        // The workout is never ended. The cap alone must release the work.
        await _until(() => cappedRuns == 1);
        expect(cappedRuns, 1,
            reason: 'past the cap the queued job must run — the workout is '
                'forgotten, not in progress');

        // And work arriving AFTER expiry runs too: the pipeline is unwedged
        // for the rest of the session, not for one job.
        capped.markStoredData();
        await _until(() => cappedRuns == 2);
        expect(cappedRuns, 2);
      },
    );

    test('ending a workout re-arms the cap for the next session', () async {
      var cappedRuns = 0;
      final capped = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async => cappedRuns++,
        log: logs.add,
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
        workoutHoldCap: const Duration(milliseconds: 150),
      );
      addTearDown(capped.dispose);

      // Let one session expire its cap…
      capped.setWorkoutActive(true);
      capped.markStoredData();
      await _until(() => cappedRuns == 1);
      capped.setWorkoutActive(false);

      // …then a NEW session must hold again from scratch. An expiry that
      // survived the release would make the gate one-shot per launch.
      capped.setWorkoutActive(true);
      capped.markStoredData();
      await _until(() => capped.snapshot()['pending_light'] == true);
      expect(cappedRuns, 1,
          reason: 'a fresh session holds again — the expiry must not stick');
      capped.setWorkoutActive(false);
      await _until(() => cappedRuns == 2);
      expect(cappedRuns, 2);
    });
  });

  group('requeueComputeJob (the post-claim gate race)', () {
    // `_drain()` clears the gate, then awaits takeNextComputeJob(). A workout
    // starting inside that window leaves a job already marked `running` that
    // must be handed back rather than run — otherwise it sits claimed until
    // the next recoverComputeJobs().
    //
    // Deliberately tests the PRIMITIVE rather than simulating the interleaving.
    // Hitting that window means racing a real DB round-trip, which is a coin
    // flip dressed up as a test — the kind that passes locally and fails on a
    // loaded runner (this file already had one of those). What is worth
    // pinning is the guarantee the drain path depends on: a claimed job comes
    // back claimable, and being deferred does not burn an attempt.
    setUp(() async {
      // Leave no jobs behind from an earlier group.
      for (var i = 0; i < 8; i++) {
        final j = await LocalDb.takeNextComputeJob();
        if (j == null) break;
        await LocalDb.completeComputeJob(j['id'].toString());
      }
    });

    test('a claimed job returns to the queue and stays runnable', () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');

      final claimed = await LocalDb.takeNextComputeJob();
      expect(claimed, isNotNull, reason: 'the job should be claimable');
      expect(claimed!['state'], 'running');
      final id = claimed['id'].toString();
      // NOTE: takeNextComputeJob returns the row as it was BEFORE its own
      // update, so `attempts` here is the pre-increment value. That makes the
      // comparison below the meaningful one: if the requeue failed to undo the
      // increment, the second claim would report a higher number than the
      // first.
      final attemptsAtFirstClaim = (claimed['attempts'] as num).toInt();

      // While claimed, nothing else can take it.
      expect(await LocalDb.takeNextComputeJob(), isNull,
          reason: 'a running job must not be handed out twice');

      await LocalDb.requeueComputeJob(id);

      final again = await LocalDb.takeNextComputeJob();
      expect(again, isNotNull,
          reason: 'a requeued job must be claimable again, not stranded');
      expect(again!['id'].toString(), id);
      expect(
        (again['attempts'] as num).toInt(),
        attemptsAtFirstClaim,
        reason: 'the requeue undid the increment, so the second claim starts '
            'from the same count as the first — a deferral is not a retry',
      );

      await LocalDb.completeComputeJob(id);
      expect(await LocalDb.takeNextComputeJob(), isNull);
    });

    test('a request landing during a running pass queues behind it',
        () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      final running = await LocalDb.takeNextComputeJob();
      expect(running, isNotNull);

      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      await LocalDb.completeComputeJob(running!['id'].toString());

      final next = await LocalDb.takeNextComputeJob();
      expect(next, isNotNull,
          reason: 'the batch behind the second request needs its own pass');
      await LocalDb.completeComputeJob(next!['id'].toString());
      expect(await LocalDb.takeNextComputeJob(), isNull,
          reason: 'requests behind a running pass still coalesce');
    });

    test('requeueing an unknown id is harmless', () async {
      await LocalDb.requeueComputeJob('no-such-job');
      expect(await LocalDb.takeNextComputeJob(), isNull);
    });
  });

  group('ScreenWake', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      ScreenWake.resetForTest();
      // Platform.isAndroid/isIOS are BOTH false on the host VM, so without this
      // the dispatch short-circuits and these mocks are never reached — the
      // call-count and failure assertions below asserted nothing at all.
      ScreenWake.platformOverride = 'android';
      for (final ch in const [
        MethodChannel('openstrap/edge_tracking'),
        MethodChannel('openstrap/ios_config'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ch, (c) async {
          calls.add(c);
          return true;
        });
      }
    });

    test('enable then release round-trips the flag and hits the channel',
        () async {
      expect(ScreenWake.isHeld, isFalse);
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isTrue);
      expect(calls.single.method, 'keepAwake');
      expect((calls.single.arguments as Map)['on'], isTrue);
      await ScreenWake.release();
      expect(ScreenWake.isHeld, isFalse);
      expect((calls.last.arguments as Map)['on'], isFalse);
    });

    test('a platform that refuses does NOT latch, so a retry can succeed',
        () async {
      // Android answers false when no activity is attached. Latching the
      // requested value there left Dart believing the screen was held and
      // suppressed every later attempt.
      var refuse = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('openstrap/edge_tracking'),
        (c) async {
          calls.add(c);
          return !refuse;
        },
      );
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isFalse, reason: 'refusal must not latch');

      refuse = false;
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isTrue, reason: 'the retry must go through');
      expect(calls.length, 2);
    });

    test(
      'repeated enables do not spam the platform channel',
      () async {
        await ScreenWake.enable();
        final afterFirst = calls.length;
        await ScreenWake.enable();
        await ScreenWake.enable();
        expect(
          calls.length,
          afterFirst,
          reason: 'the 1 Hz session tick must not hit the channel every second',
        );
      },
    );

    test('a release fired while an enable is in flight still wins', () async {
      // `_on` only updates AFTER the platform await, so a release arriving
      // mid-enable used to read the stale `false`, decide it had nothing to do,
      // and return — then the in-flight enable latched true and the display
      // stayed held for the rest of the app's life. Both call sites in
      // AppState are fire-and-forget, so starting a workout and immediately
      // stopping it was enough to hit this.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('openstrap/edge_tracking'),
        (c) async {
          calls.add(c);
          // A real channel hop is not instantaneous; this is the window the
          // race lived in.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return true;
        },
      );

      await Future.wait([ScreenWake.enable(), ScreenWake.release()]);

      expect(ScreenWake.isHeld, isFalse,
          reason: 'the release must win — the screen cannot stay held');
      expect(
        [for (final c in calls) (c.arguments as Map)['on']],
        [true, false],
        reason: 'both transitions must reach the platform, in order',
      );
    });

    test('a release with nothing held is a no-op', () async {
      await ScreenWake.release();
      expect(calls, isEmpty);
    });

    test('a channel failure never throws into the workout path', () async {
      for (final ch in const [
        MethodChannel('openstrap/edge_tracking'),
        MethodChannel('openstrap/ios_config'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                ch, (c) async => throw PlatformException(code: 'boom'));
      }
      // Losing the wake flag degrades to "the screen sleeps" — it must never
      // propagate and interrupt a session.
      await expectLater(ScreenWake.enable(), completes);
      expect(ScreenWake.isHeld, isFalse,
          reason: 'a throwing channel must not latch either');
    });
  });

  // The 'live milestones' group is gone with `LiveWorkoutState.firedMilestones`.
  // The field had no reader in lib — there is no milestone feature: no banner,
  // no haptic, no confetti, nothing that grepping 'milestone' finds outside the
  // field's own doc. The test only proved that `Set.add` returns false twice.

  group('pace is MOVING pace', () {
    final units = UnitsController.seed(UnitSystem.metric);

    test(
      'standing still after a short walk does not invent an absurd pace',
      () {
        // The reported bug: ~250 m covered, then a long stationary spell.
        // Averaging over ELAPSED time produced "40:32 /km" for someone who had
        // barely moved. Over MOVING time it is a real walking pace.
        const meters = 250.0;
        const movingSec = 200; // ~3.6 km/h — a slow walk
        const elapsedSec = 608; // most of it spent standing

        expect(
          units.pace(meters, elapsedSec),
          '40:32 /km',
          reason: 'this is the wrong number the old code showed',
        );
        expect(units.pace(meters, movingSec), '13:20 /km');
      },
    );

    test('no moving time yet reports nothing rather than dividing by elapsed',
        () {
      // Null, not '—': the formatter says "there is no pace" and the screen
      // drops the stat. A bare dash rendered into a stat slot is a defect.
      expect(units.pace(120.0, 0), isNull);
    });
  });
}
