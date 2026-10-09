// Sync area: openSession, the connect -> drain -> after-drain
// derive trigger path, through AppState. What it asks the engine and in what
// order, what flags and timers it leaves, how many times it notifies, and what
// each failure path does to the flags (AGENTS 4.3).
//
// The engine is a [SyncFakeEngine]; timers are hand-fired ([SyncTimers]); the
// derive trigger is read from the durable compute_jobs rows.
//
// Platform branches (Android Edge Tracking, the iOS restore central) cannot be
// taken on the Linux host. IosBleRestore.foregroundActive is a plain static,
// set with no platform check, so it is observable and pinned.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_open_session.db';

List<String> _ev(SyncRig rig) => rig.engine.events;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('guards', () {
    test('no paired band: nothing is touched, nothing notifies',
        syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(_ev(rig), isEmpty);
      expect(ticks.ticks, 0);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
      expect(timers.live, isEmpty);
      ticks.stop();
    }, paired: false));

    test('already busy: a second call only flips the engine to foreground '
        '(no connect, no tick, no intent, busy left alone)',
        syncCase((rig, timers) async {
      rig.app.busy = true;
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(_ev(rig), ['setBackground:false']);
      expect(ticks.ticks, 0);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(rig.app.busy, isTrue, reason: 'it must not clear someone else\'s latch');
      ticks.stop();
      rig.app.busy = false;
    }));

    test('two concurrent calls: the second returns at once while the first is '
        'parked in connect', syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final first = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(rig.app.busy, isTrue);
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 1);
      gate.complete();
      await first;
      expect(rig.app.busy, isFalse);
    }));
  });

  group('a successful session', () {
    test('engine call order: foreground, connect with the band id and the '
        'pinned generation, polls, prompt, live reconcile, then the drain',
        syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.jobQueued('derive_heavy');
      expect(_ev(rig).sublist(0, 6), [
        'setBackground:false',
        'connect:$kRemoteId:gen4',
        'getBattery',
        'getStrapName',
        'prompt:false',
        'reconcile',
      ]);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      expect(_ev(rig).sublist(6), ['runSync:180', 'prompt:false']);
      expect(rig.engine.count('requestHistorySync'), 0,
          reason: 'the connect already started the offload (kickFirst: false)');
    }));

    test('busy is true only while connecting, and the burst runs after '
        'openSession has returned', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(rig.app.busy, isTrue);
      gate.complete();
      await open;
      expect(rig.app.busy, isFalse);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.app.busy, isFalse, reason: 'the drain is concurrent, not awaited');
      expect(await rig.jobTypes(), isEmpty, reason: 'no trigger before the drain ends');
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
    }));

    test('ownership: intent on, foreground lease held, iOS restore flag set, '
        'and the supervisor and backfill timers armed', syncCase((rig, timers) async {
      await rig.app.openSession();
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(IosBleRestore.foregroundActive, isTrue,
          reason: 'set with no platform check');
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      // A second headless claim is skipped, not queued.
      expect(BandOwnership.tryAcquireHeadless(), isNull);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('the post-drain step re-reads the band prompt FIRST and only then '
        'requests the heavy derive', syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      // Two prompt writes, neither of which saw a queued job: the connect-time
      // one and the post-drain one, both ahead of the heavy request.
      expect(rig.engine.promptStamps, ['', '']);
      expect(await rig.jobTypes(), ['derive_heavy']);
    }));

    test('the heavy request is a scheduled job, held by a settle timer, and '
        'the pass it runs is the HEAVY, all-days one', syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      await rig.waitFor(() => timers.activeOneShot(const Duration(seconds: 2)).isNotEmpty);
      expect(rig.app.derivePending, isTrue);
      timers.activeOneShot(const Duration(seconds: 2)).single.fire();
      await rig.waitFor(() => rig.passes.isNotEmpty);
      expect(rig.passes.single, isTrue);
    }));

    test('a drain that stopped early still requests the heavy derive (only '
        'the log differs)', syncCase((rig, timers) async {
      rig.engine.syncScript.add(SyncReport(40, 2, false));
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      expect(rig.app.logLines.any((l) => l.contains('Backlog drained: 40 records in 2 batches (stopped early)')), isTrue);
    }));

    test('notifies 3 times to open (busy, connected state, idle) and 3 more '
        'when the drain lands (derive queued, settle armed, completion)',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(ticks.ticks, 3);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      await rig.settleDerive();
      await rig.quiesce();
      expect(ticks.ticks, 6);
      ticks.stop();
    }));

    test('the engine is told it is foreground before anything else',
        syncCase((rig, timers) async {
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      await rig.app.openSession();
      expect(_ev(rig).first, 'setBackground:false');
      expect(rig.app.debugLiveOwners.foreground, isTrue);
    }));
  });

  group('failure paths', () {
    test('the band cannot be reached: busy, intent and lease are released, '
        'the backfill timer never starts, but the supervisor stays and the '
        'iOS restore flag is left as set', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1),
          reason: 'we still WANT a link; the supervisor retries it');
      expect(_ev(rig), ['setBackground:false', 'connect:$kRemoteId:gen4']);
      expect(rig.app.logLines, contains('Session start: could not reach the band.'));
      // The flag is set before the connect and only a BACKGROUND failure hands
      // the band back to iOS recovery (a platform call, not reachable here), so
      // a foreground failure leaves the plain static set.
      expect(IosBleRestore.foregroundActive, isTrue);
      expect(rig.app.status, 'disconnected');
    }));

    test('the connect throws: same cleanup, the throw is logged not rethrown',
        syncCase((rig, timers) async {
      rig.engine.connectScript.add(StateError('gatt 133'));
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(IosBleRestore.foregroundActive, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(rig.app.logLines, contains('Session start failed: Bad state: gatt 133'));
    }));

    test('a poll throws after the link is up: logged, and the half-built '
        'session is left as it is (link up, intent and lease held, no drain, '
        'no backfill timer)', syncCase((rig, timers) async {
      rig.engine.batteryThrowsOnce = StateError('no reply');
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(rig.app.logLines, contains('Session start failed: Bad state: no reply'));
      await rig.quiesce();
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.isConnected, isTrue);
      expect(rig.engine.count('runSync'), 0);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(await rig.jobTypes(), isEmpty);
    }));

    test('the link is gone by the time the session settles: the finally clears '
        'intent and lease even though the connect had answered true',
        syncCase((rig, timers) async {
      rig.engine.batteryHook = () async => rig.engine.link = false;
      await rig.app.openSession();
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
    }));

    test('the drain throws: logged, no derive request, the link and the '
        'intent stay, the backfill timer is armed', syncCase((rig, timers) async {
      rig.engine.syncScript.add(StateError('burst failed'));
      await rig.app.openSession();
      await rig.waitFor(() => rig.app.logLines.any((l) => l.contains('Background sync burst failed')));
      expect(rig.app.logLines, contains('Background sync burst failed: Bad state: burst failed'));
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(rig.app.busy, isFalse);
    }));

    test('the band is unpaired while the connect is parked: the session '
        'carries on with the band it captured and does not wedge busy',
        syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.app.paired = null;
      gate.complete();
      await open;
      expect(rig.app.busy, isFalse);
      expect(rig.engine.count('getBattery'), 1);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('a failed connect and a later openSession: the second attempt runs '
        '(nothing latched)', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 2);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isTrue);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));
  });

  group('resuming from the background with the link still up', () {
    // A real engine never hands back 'connected' without data; the fake's
    // sinceLastRx / liveEnabled / probeAnswer say how quiet the link is.
    Future<void> open(SyncRig rig) async {
      await rig.openAndSettle();
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
    }

    test('a fresh link is reclaimed: no connect, no busy, the foreground '
        'intent is raised again, and a foreground catch-up starts',
        syncCase((rig, timers) async {
      await open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.engine.count('connect'), 0);
      expect(rig.engine.count('disconnect'), 0);
      expect(_ev(rig).first, 'setBackground:false');
      expect(rig.engine.count('requestForegroundSync'), 1);
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(rig.app.debugLiveOwners.foreground, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      ticks.stop();
    }));

    test('a quiet link with a live stream armed is torn down and reconnected',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 45);
      await rig.app.openSession();
      expect(rig.engine.count('probe'), 0);
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('connect'), greaterThanOrEqualTo(1));
      expect(rig.app.logLines.any((l) => l.contains('Resume: no BLE data for 45s with a live stream armed — stale link, reconnecting.')), isTrue);
      await rig.quiesce();
    }));

    test('a quiet link with NO stream armed is asked, and a reply keeps it '
        '(asked TWICE: the catch-up that follows asks again)',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = false;
      rig.engine.quiet = const Duration(seconds: 200);
      rig.engine.probeAnswer = true;
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('probe') >= 2);
      expect(rig.engine.count('probe'), 2);
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.count('connect'), 0);
    }));

    test('no answer to the probe: the link is torn down and reconnected',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = false;
      rig.engine.quiet = const Duration(seconds: 200);
      rig.engine.probeAnswer = false;
      await rig.app.openSession();
      expect(rig.engine.count('probe'), 1);
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('connect'), greaterThanOrEqualTo(1));
      await rig.quiesce();
    }));

    test('COUPLING: tearing a stale link down fires the disconnect edge, which '
        'starts the reconnect loop beside openSession\'s own connect',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 45);
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('markReconnecting') >= 1);
      expect(rig.app.logLines.any((l) => l.contains('Connection dropped — reconnecting…')), isTrue);
      // The fake does not serialise connects the way the real engine's single
      // in-flight guard does, so both callers reach it.
      expect(rig.engine.count('connect'), 2);
      await rig.quiesce();
    }));
  });

  group('who holds the band when the engine is called', () {
    // The foreground intent and the lease are taken before the connect and
    // given back only after the disconnect, so a headless wake cannot slip in
    // between.
    test('openSession: intent and lease are held by the time the connect runs',
        syncCase((rig, timers) async {
      final seen = <String>[];
      rig.engine.connectHook = () async => seen.add(
          '${BandOwnership.foregroundIntent}:${BandOwnership.owner?.name}');
      await rig.app.openSession();
      expect(seen, ['true:foreground']);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('endSession: the intent is dropped first, the lease is still held '
        'while the engine disconnects, and released right after',
        syncCase((rig, timers) async {
      await rig.openAndSettle();
      final seen = <String>[];
      rig.engine.disconnectHook = () async => seen.add(
          '${BandOwnership.foregroundIntent}:${BandOwnership.owner?.name}');
      await rig.app.endSession();
      expect(seen, ['false:foreground']);
      expect(BandOwnership.owner, isNull);
    }));

    test('unpair: same order as endSession', syncCase((rig, timers) async {
      await rig.openAndSettle();
      final seen = <String>[];
      rig.engine.disconnectHook = () async => seen.add(
          '${BandOwnership.foregroundIntent}:${BandOwnership.owner?.name}');
      await rig.app.unpair();
      expect(seen, ['false:foreground']);
      expect(BandOwnership.owner, isNull);
    }));

    test('the reconnect loop re-takes the lease before each connect once a '
        'supervisor tick restarts it', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      expect(BandOwnership.owner, isNull);
      final seen = <String>[];
      rig.engine.connectHook = () async => seen.add(
          '${BandOwnership.foregroundIntent}:${BandOwnership.owner?.name}');
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await rig.waitFor(() => rig.engine.count('prompt') >= 2);
      expect(seen, ['true:foreground']);
    }));
  });

  group('the activity-review rollup openSession launches', () {
    // A failing rollup retries on a 2 s to 30 s backoff and gives up after ten
    // retries; opening the session gives the chain a fresh budget.
    Future<void> failReviews(SyncRig rig) async {
      rig.app.debugRefreshActivityReviews = (_) async {
        rig.reviewCalls++;
        return false;
      };
    }

    List<FakeTimer> retryTimers(SyncTimers t) => [
          for (final x in t.live)
            if (!x.periodic && const [2, 4, 8, 16, 30].contains(x.duration.inSeconds)) x
        ];

    test('a fresh open asks once, as a retry-flagged attempt (no opening '
        'insights bump, one after a rollup that succeeded)',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      final before = rig.app.insightsRevision.value;
      await rig.app.openSession();
      expect(rig.reviewCalls, 1);
      await rig.quiesce();
      expect(rig.app.insightsRevision.value, before + 1);
    }));

    test('a resume on a live link gives a chain that ran out of attempts a '
        'fresh budget', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await failReviews(rig);
      await rig.app.openSession();
      await rig.waitFor(() => retryTimers(timers).length == 1);
      // Fire the whole chain: ten retries after the first attempt.
      for (var i = 0; i < 10; i++) {
        final t = retryTimers(timers);
        expect(t, hasLength(1), reason: 'retry ${i + 1}');
        t.single.fire();
        await rig.waitFor(() => rig.reviewCalls == i + 2);
        await settleMs(10);
      }
      expect(rig.reviewCalls, 11);
      expect(retryTimers(timers), isEmpty, reason: 'ten retries, then it stops');
      await rig.app.pauseForBackground();
      await rig.app.openSession();
      await rig.waitFor(() => rig.reviewCalls == 12);
      await rig.waitFor(() => retryTimers(timers).length == 1);
      expect(timers.live.where((t) => !t.periodic && t.duration == const Duration(seconds: 2)).length,
          1, reason: 'the new chain starts at the first backoff step again');
    }));

    test('a resume that finds a succeeding rollup notifies in the same order '
        'as before: the review is asked first, then the revision bump, with '
        'no extra ticks', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.app.pauseForBackground();
      final order = <String>[];
      rig.app.addListener(() => order.add('t'));
      rig.app.insightsRevision.addListener(() => order.add('r'));
      rig.app.debugRefreshActivityReviews = (_) async {
        order.add('review');
        return true;
      };
      await rig.app.openSession();
      await rig.quiesce();
      expect(order, ['review', 'r']);
    }));
  });
}
