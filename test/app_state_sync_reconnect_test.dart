// Sync area: the connected -> disconnected edge, the
// reconnect loop it starts, the level-triggered supervisor behind it, the
// bond-refusal give-up as AppState wires it, and the heavy-derive throttle that
// follows a background reconnect. Through AppState, with a [SyncFakeEngine].
//
// The policies themselves (ReconnectPolicy, BondRefusalGiveUp, StuckStrap
// detection, superviseReconnect) are pure or live in the engine and are tested
// where they are. AppState only reads device.autoReconnectPaused, asks the
// engine for the backoff delay and calls refreshAutoReconnectPause; that wiring
// is what is pinned here.
//
// Not reachable on the Linux host: the Android OS autoConnect fallback
// (Platform.isAndroid), and the supervisor's restartStale branch (it needs an
// attempt that has run for wall-clock minutes; AppState has no clock seam).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_reconnect.db';

bool _logged(SyncRig rig, String text) =>
    rig.app.logLines.any((l) => l.contains(text));

Future<void> _open(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.events.clear();
}

/// Let the reconnect loop that a drop started run to its end.
Future<void> _settledReconnect(SyncRig rig, {int prompts = 2}) async {
  await rig.waitFor(() => rig.engine.count('prompt') >= prompts);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('the disconnect edge, foreground', () {
    test('starts the loop: engine call order of one reconnect and its drain',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      expect(rig.engine.events, [
        'markReconnecting',
        'backoff:1',
        'connect:$kRemoteId:gen4',
        'prompt:false',
        'reconcile',
        'getBattery',
        'getStrapName',
        // The loop breaks right after kicking the burst (unawaited), so its
        // finally runs before the burst's first engine call.
        'clearReconnecting',
        'runSync:180',
        'prompt:false',
      ]);
      expect(rig.app.status, 'connected');
      expect(_logged(rig, 'Connection dropped — reconnecting…'), isTrue);
      expect(_logged(rig, 'Reconnected — live on; draining backlog in background.'), isTrue);
      expect(_logged(rig, 'Reconnect backlog drained: 3 records.'), isTrue);
    }));

    test('the backfill timer is cancelled at the edge and a fresh one armed '
        'when the link is back; the supervisor is not touched',
        syncCase((rig, timers) async {
      await _open(rig);
      final supervisor = timers.activePeriodic(kSuperviseEvery).single;
      final backfill = timers.activePeriodic(kBackfillEvery).single;
      rig.engine.drop();
      expect(backfill.cancelled, isTrue, reason: 'cancelled synchronously, at the edge');
      await _settledReconnect(rig);
      await rig.waitFor(() => timers.activePeriodic(kBackfillEvery).isNotEmpty);
      expect(timers.activePeriodic(kBackfillEvery).single, isNot(same(backfill)));
      expect(timers.activePeriodic(kSuperviseEvery).single, same(supervisor));
    }));

    test('ownership: intent stays on through and after a successful loop; the '
        'lease is the one taken at openSession', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.drop();
      await _settledReconnect(rig);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
    }));

    test('the loop is over afterwards: a supervisor tick starts nothing',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.quiesce();
      rig.engine.events.clear();
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
    }));

    test('notifies once per state it passes through (disconnected, '
        'reconnecting, connected) and 3 more when the drain lands',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncGate = Completer<void>();
      final ticks = TickCounter(rig.app);
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.quiesce();
      final before = ticks.ticks;
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
      await rig.settleDerive();
      await rig.quiesce();
      expect(before, 3);
      expect(ticks.ticks - before, 3);
      ticks.stop();
    }));

    test('a failed attempt backs off with a growing attempt number and the '
        'UI is told it is reconnecting each time', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.connectScript.addAll([false, false, true]);
      rig.engine.drop();
      await _settledReconnect(rig);
      expect(rig.engine.only('backoff'), ['backoff:1', 'backoff:2', 'backoff:3']);
      expect(rig.engine.count('connect'), 3);
      expect(rig.engine.count('markReconnecting'), 3);
      expect(rig.engine.count('requestHistorySync'), 0);
    }));

    test('an attempt that throws is just a failed attempt: the loop goes on '
        'and connects on the next one (issue #208)', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.connectScript.addAll([StateError('gatt 133'), true]);
      rig.engine.drop();
      await _settledReconnect(rig);
      expect(_logged(rig, 'Reconnect attempt 1 failed: Bad state: gatt 133 — retrying.'), isTrue);
      expect(rig.engine.count('connect'), 2);
      expect(rig.app.status, 'connected');
    }));

    test('a poll that throws right after the link is back is logged as a '
        'failed attempt, but the link stays up so the loop ends there: no '
        'teardown, no drain, no backfill timer', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.batteryThrowsOnce = StateError('no reply');
      rig.engine.drop();
      await rig.waitFor(() => _logged(rig, 'Reconnect attempt 1 failed: Bad state: no reply'));
      await rig.waitFor(() => rig.engine.count('clearReconnecting') >= 1);
      await rig.quiesce();
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.only('backoff'), ['backoff:1']);
      expect(rig.engine.isConnected, isTrue);
      expect(rig.engine.count('runSync'), 0);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(await rig.jobTypes(), isEmpty);
      // The loop is over: a supervisor tick starts nothing.
      rig.engine.events.clear();
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
    }));

    test('the drain after a reconnect fails: logged, no derive request, the '
        'link and the backfill timer stay', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(StateError('burst failed'));
      rig.engine.drop();
      await rig.waitFor(() => _logged(rig, 'Reconnect sync burst failed: Bad state: burst failed'));
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
    }));

    test('without a wish for a link the edge does not reconnect, it releases '
        'the lease', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.endSession();
      rig.engine.up();
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.quiesce();
      expect(rig.engine.count('markReconnecting'), 0);
      expect(BandOwnership.owner, isNull);
    }));
  });

  group('the link drops during post-connect setup', () {
    // The edge that the drop produces is ignored (the loop is still marked
    // running), so the loop itself has to notice and go round again.
    Future<void> dropOnce(SyncRig rig) async {
      var fired = false;
      rig.engine.batteryHook = () async {
        if (fired) return;
        fired = true;
        rig.engine.drop();
      };
    }

    test('another attempt follows, and the loop ends fully up',
        syncCase((rig, timers) async {
      await _open(rig);
      await dropOnce(rig);
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.waitFor(() => timers.activePeriodic(kBackfillEvery).isNotEmpty);
      expect(_logged(rig, 'Link dropped during reconnect setup — retrying.'), isTrue);
      expect(rig.engine.count('connect'), 2);
      expect(rig.engine.only('backoff'), ['backoff:1', 'backoff:2']);
      expect(rig.engine.count('markReconnecting'), 2);
      expect(rig.engine.isConnected, isTrue);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      await rig.jobQueued('derive_heavy');
    }));

    test('the retry also happens backgrounded (the iOS recovery re-arm in '
        'front of it is a platform call, not reachable on this host)',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      await dropOnce(rig);
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(_logged(rig, 'Link dropped during reconnect setup — retrying.'), isTrue);
      expect(rig.engine.count('connect'), 2);
      expect(rig.engine.isConnected, isTrue);
    }));
  });

  group('the bond-refusal give-up as AppState wires it', () {
    test('paused at the edge: no loop starts and the lease is released, but '
        'the foreground intent stays on (so a headless wake is still refused)',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.state.autoReconnectPaused = true;
      rig.engine.drop();
      await rig.quiesce();
      expect(rig.engine.count('markReconnecting'), 0);
      expect(rig.engine.count('connect'), 0);
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.tryAcquireHeadless(), isNull);
    }));

    test('the supervisor expires the pause (asks the engine every tick), '
        'does nothing while it stands, and restarts the loop when it is '
        'lifted', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.state.autoReconnectPaused = true;
      rig.engine.drop();
      await rig.quiesce();
      rig.engine.events.clear();
      final tick = timers.activePeriodic(kSuperviseEvery).single;
      tick.fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
      rig.engine.state.autoReconnectPaused = false;
      tick.fire();
      await _settledReconnect(rig);
      expect(_logged(rig, '[RECONNECT] supervisor: disconnected with no loop running — starting one.'), isTrue);
      expect(rig.engine.count('connect'), 1);
      expect(rig.app.status, 'connected');
    }));

    test('a pause that flips mid-loop ends the loop: intent is cleared, the '
        'engine\'s reconnecting phase is cleared, and that clear is itself a '
        'disconnect edge that releases the lease', syncCase((rig, timers) async {
      await _open(rig);
      final gate = rig.holdConnect();
      rig.engine.connectScript.add(false);
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.engine.state.autoReconnectPaused = true;
      gate.complete();
      await rig.waitFor(() => rig.engine.count('clearReconnecting') >= 1);
      await rig.quiesce();
      expect(rig.engine.count('connect'), 1, reason: 'no second attempt');
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.status, 'disconnected');
    }));
  });

  group('the supervisor tick', () {
    FakeTimer sup(SyncTimers t) => t.activePeriodic(kSuperviseEvery).single;

    test('connected: asks the engine about the pause and nothing else',
        syncCase((rig, timers) async {
      await _open(rig);
      sup(timers).fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
    }));

    test('disconnected with no loop: starts one', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.link = false; // dropped without the state edge
      sup(timers).fire();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(_logged(rig, '[RECONNECT] supervisor: disconnected with no loop running — starting one.'), isTrue);
    }));

    test('a loop is already running: no second loop', syncCase((rig, timers) async {
      await _open(rig);
      final gate = rig.holdConnect();
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.engine.events.clear();
      sup(timers).fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
      gate.complete();
      await _settledReconnect(rig);
    }));

    test('a connect in flight (busy): no loop', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.link = false;
      rig.app.busy = true;
      sup(timers).fire();
      await rig.quiesce();
      expect(rig.engine.events, ['refreshPause']);
      rig.app.busy = false;
    }));

    test('after a failed openSession the supervisor is what retries',
        syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      rig.engine.events.clear();
      sup(timers).fire();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await _settledReconnect(rig);
      expect(rig.app.status, 'connected');
    }));
  });

  group('a loop that is retired', () {
    test('endSession while an attempt is parked: the loop exits at its next '
        'check, leaves the flags to whoever owns them, and clears the '
        'reconnecting phase once (by endSession, not by the zombie)',
        syncCase((rig, timers) async {
      await _open(rig);
      final gate = rig.holdConnect();
      rig.engine.connectScript.add(false);
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.app.endSession();
      final clears = rig.engine.count('clearReconnecting');
      gate.complete();
      await rig.waitFor(() => _logged(rig, 'was superseded'));
      await rig.quiesce();
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('clearReconnecting'), clears);
      expect(BandOwnership.foregroundIntent, isFalse);
    }));

    test('a connect that was in flight when endSession retired the loop and '
        'then answers true still runs the post-connect setup and a drain (the '
        'generation is only checked at the loop head and in the finally), but '
        'arms no backfill timer and leaves no intent or lease behind',
        syncCase((rig, timers) async {
      await _open(rig);
      final gate = rig.holdConnect();
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.app.endSession();
      rig.engine.events.clear();
      gate.complete();
      await rig.waitFor(() => _logged(rig, 'was superseded'));
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.quiesce();
      expect(rig.engine.count('getBattery'), 1);
      expect(rig.engine.count('reconcile'), 1);
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.engine.count('disconnect'), 0,
          reason: 'nothing drops the stray link the retired connect won');
    }));

    test('endSession then openSession while the old attempt is parked: the '
        'old loop, if its connect fails, does not clobber the new session\'s '
        'flags', syncCase((rig, timers) async {
      await _open(rig);
      final gate = rig.holdConnect();
      // The new session's connect reads the script first; the parked one
      // reads its answer only after the gate opens.
      rig.engine.connectScript.addAll([true, false]);
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.app.endSession();
      await rig.app.openSession();
      expect(BandOwnership.foregroundIntent, isTrue);
      gate.complete();
      await rig.waitFor(() => _logged(rig, 'was superseded'));
      await rig.quiesce();
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(rig.app.busy, isFalse);
    }));
  });

  group('backgrounded', () {
    test('a drop reconnects too (the iOS restore re-arm in front of it is a '
        'platform branch), and the engine stays in its background tier',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      rig.engine.drop();
      await _settledReconnect(rig);
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('setBackground'), 0, reason: 'a reconnect does not change the tier');
      expect(rig.app.debugLiveOwners.foreground, isFalse);
    }));

    test('heavy derive after a background reconnect is throttled to one per '
        '30 minutes: the second reconnect only gets a light pass',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      await rig.clearJobs();
      rig.engine.events.clear();
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_light');
      expect(await rig.jobTypes(), ['derive_light']);
    }));

    test('in the foreground every reconnect gets the heavy derive',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      await rig.clearJobs();
      rig.engine.events.clear();
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      expect(await rig.jobTypes(), ['derive_heavy']);
    }));

    test('only a BACKGROUND heavy request stamps the throttle clock: after a '
        'foreground reconnect the first background one is still heavy',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      await rig.clearJobs();
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      rig.engine.drop();
      await _settledReconnect(rig);
      await rig.jobQueued('derive_heavy');
      expect(await rig.jobTypes(), ['derive_heavy'],
          reason: 'the first BACKGROUND reconnect is heavy; only a background one stamps the clock');
    }));
  });
}
