// Sync area: "Delete everything" (ResetGate / AppState's
// _resetting) quiescing the ingest paths, and what the foreground side of the
// headless exclusion (BandOwnership, AGENTS 3.12) does. Through AppState.
//
// resetAllData itself needs the whole plugin stack (preferences, notifications,
// widget, telemetry, keychain), so its ordering stays source-pinned in
// test/reset_quiesces_ingest_test.dart. What is behavioural here is the gate's
// effect on the stored-record callback and on the connection edge handler that
// lives in _onEngineState.
//
// AppState does not use HeadlessSyncGate at all: the headless wake paths
// (lib/sync, lib/ble/ios_ble_restore.dart) take it, and the foreground app
// stays out of their way through BandOwnership only. That is pinned below.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_reset.db';

RawRecord _raw(int ts) =>
    RawRecord(counter: 1, hex: '00', capturedAt: 1750000000000, recTs: ts);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() async {
    ResetGate.resetForTest();
    await deriveDbTearDown(_db);
  });

  group('the engine callbacks refuse while a reset is running', () {
    test('a stored record neither writes nor moves the data edge, and is '
        'accepted again when the gate lifts', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      ResetGate.enter();
      await app.engine.onRecord(null, _raw(1750000100));
      expect(app.lastRecordAt, isNull);
      ResetGate.leave();
      await app.engine.onRecord(null, _raw(1750000200));
      expect(app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000200 * 1000));
    });

    test('the data edge only moves forward', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.engine.onRecord(null, _raw(1750000200));
      await app.engine.onRecord(null, _raw(1750000100));
      expect(app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000200 * 1000));
    });

    test('a device-state callback is ignored whole: no notify, no live-HR '
        'sample', syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      ResetGate.enter();
      rig.engine.state.connection = 'connected';
      rig.engine.state.liveHr = 66;
      rig.engine.state.liveHrAt = 1750000000000;
      rig.app.debugFeedEngineState('', rig.engine.state);
      expect(ticks.ticks, 0);
      expect(rig.app.liveHrTrace(''), isEmpty);
      ResetGate.leave();
      rig.app.debugFeedEngineState('', rig.engine.state);
      expect(ticks.ticks, 1);
      expect(rig.app.liveHrTrace(''), [66]);
      ticks.stop();
    }, paired: false));
  });

  group('the connection edge during a reset', () {
    test('a drop that happens while the gate is up starts no reconnect',
        syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      await rig.jobQueued('derive_heavy');
      rig.engine.events.clear();
      ResetGate.enter();
      rig.engine.drop();
      await rig.quiesce();
      expect(rig.engine.count('markReconnecting'), 0);
      expect(rig.engine.count('connect'), 0);
      expect(rig.app.status, 'disconnected');
    }));

    test('and nothing re-triggers it when the gate lifts, until the next '
        'state callback finds the previous state still "connected"',
        syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      await rig.jobQueued('derive_heavy');
      rig.engine.events.clear();
      ResetGate.enter();
      rig.engine.drop();
      ResetGate.leave();
      await rig.quiesce();
      expect(rig.engine.count('connect'), 0, reason: 'the edge was swallowed');
      // The next callback, whatever it carries, sees connected -> disconnected.
      rig.app.debugFeedEngineState('', rig.engine.state);
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.waitFor(() => rig.engine.count('prompt') >= 1);
    }));
  });

  group('the foreground side of the headless exclusion', () {
    test('while a foreground session is held a headless claim is refused '
        '(skip, never queue); once it is released, it is granted',
        syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      expect(BandOwnership.tryAcquireHeadless(), isNull);
      await rig.app.endSession();
      final lease = BandOwnership.tryAcquireHeadless();
      expect(lease, isNotNull);
      BandOwnership.release(lease!);
    }));

    test('a failed first connect releases the claim too',
        syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      final lease = BandOwnership.tryAcquireHeadless();
      expect(lease, isNotNull);
      BandOwnership.release(lease!);
    }));

    test('AppState neither takes nor consults HeadlessSyncGate: a held gate '
        'does not stop a foreground session', syncCase((rig, timers) async {
      final hold = Completer<void>();
      final running = HeadlessSyncGate.tryRun<void>('reset_probe', () => hold.future);
      expect(HeadlessSyncGate.busy, isTrue);
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 1);
      expect(HeadlessSyncGate.busy, isTrue, reason: 'the app did not take or release it');
      hold.complete();
      await running;
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));
  });
}
