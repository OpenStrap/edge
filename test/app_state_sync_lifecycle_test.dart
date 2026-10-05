// Sync area: the foreground / background transitions
// (pauseForBackground, the foreground reclaim), what each starts and stops, the
// cold-start session (foreground and the headless background one), endSession,
// unpair, and the 10 minute backfill timer's tick. Through AppState.
//
// Platform branches (Android Edge Tracking, the iOS restore central, the
// scheduler's iOS-only background hold, the OS autoConnect fallback) cannot be
// taken on the Linux host; pauseForBackground on Linux is the engine step-down,
// the live-owner re-evaluation and nothing else.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_lifecycle.db';

bool _logged(SyncRig rig, String text) =>
    rig.app.logLines.any((l) => l.contains(text));

/// A connected, drained foreground session.
Future<void> _open(SyncRig rig) => rig.openAndSettle();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('pauseForBackground', () {
    test('steps the engine down and re-evaluates the live owners; it does '
        'not disconnect, release ownership or stop a timer',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.events.clear();
      final live = timers.live.where((t) => t.periodic).length;
      await rig.app.pauseForBackground();
      expect(rig.engine.events, ['setBackground:true', 'reconcile']);
      expect(rig.app.debugLiveOwners.foreground, isFalse);
      expect(rig.engine.isConnected, isTrue);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(timers.live.where((t) => t.periodic).length, live);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
    }));

    test('does not notify', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.pauseForBackground();
      expect(ticks.ticks, 0);
      ticks.stop();
    }));

    test('with no link it still only steps down (the iOS restore re-arm is a '
        'platform branch)', syncCase((rig, timers) async {
      await rig.app.pauseForBackground();
      expect(rig.engine.events, ['setBackground:true', 'reconcile']);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(IosBleRestore.foregroundActive, isFalse,
          reason: 'only the iOS branch sets it on pause');
    }));

    test('twice: the engine is told twice (it dedupes) and nothing else moves',
        syncCase((rig, timers) async {
      await rig.app.pauseForBackground();
      await rig.app.pauseForBackground();
      expect(rig.engine.only('setBackground'),
          ['setBackground:true', 'setBackground:true']);
    }));

    test('the foreground return is openSession; the owners flip back',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      expect(rig.app.debugLiveOwners.foreground, isFalse);
      await rig.app.openSession();
      expect(rig.app.debugLiveOwners.foreground, isTrue);
      expect(rig.engine.only('setBackground').last, 'setBackground:false');
      await rig.quiesce();
    }));
  });

  group('the periodic backfill tick', () {
    FakeTimer tick(SyncTimers t) => t.activePeriodic(kBackfillEvery).single;

    test('foreground: wake-window refresh, then an offload that is KICKED '
        '(history request before the drain), and a light derive for the '
        'records it brought', syncCase((rig, timers) async {
      await _open(rig);
      await rig.clearJobs();
      rig.engine.events.clear();
      tick(timers).fire();
      await rig.jobQueued('derive_light');
      expect(rig.engine.events, ['prompt:false', 'requestHistorySync', 'runSync:180']);
      expect(_logged(rig, 'Periodic backlog check: 3 records (complete).'), isTrue);
      expect(await rig.jobTypes(), ['derive_light']);
    }));

    test('a tick that brought no records requests no derive',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.clearJobs();
      rig.engine.syncScript.add(SyncReport(0, 1, true));
      tick(timers).fire();
      await rig.waitFor(() => _logged(rig, 'Periodic backlog check: 0 records'));
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
    }));

    test('a tick while a burst is already running joins nothing and asks '
        'nothing', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await _openNoDrain(rig);
      rig.engine.events.clear();
      tick(timers).fire();
      await rig.waitFor(() => _logged(rig, 'Periodic history refresh skipped — a sync burst is already running.'));
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(rig.engine.count('runSync'), 0);
    }));

    test('a failing offload is logged, the single-flight latch clears, and '
        'the next tick runs again', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.requestSyncThrows = StateError('no link');
      tick(timers).fire();
      await rig.waitFor(() => _logged(rig, 'Periodic history refresh failed: Bad state: no link'));
      rig.engine.requestSyncThrows = null;
      rig.engine.events.clear();
      tick(timers).fire();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
    }));

    test('backgrounded: no offload (the engine\'s floored timer owns it); '
        'the wake-window refresh runs on the first tick and is throttled to '
        'one per 25 minutes', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      tick(timers).fire();
      await rig.waitFor(() => _logged(rig, 'Periodic history refresh skipped — backgrounded'));
      expect(rig.engine.events, ['prompt:false']);
      rig.engine.events.clear();
      tick(timers).fire();
      await rig.quiesce();
      expect(rig.engine.events, isEmpty, reason: 'throttled: under 25 min since the last');
    }));

    for (final c in <(String, Future<void> Function(SyncRig))>[
      ('the link is down', (rig) async => rig.engine.link = false),
      ('busy', (rig) async => rig.app.busy = true),
      ('the band is unpaired', (rig) async => rig.app.paired = null),
    ]) {
      test('guard: nothing happens when ${c.$1}', syncCase((rig, timers) async {
        await _open(rig);
        final t = tick(timers);
        await c.$2(rig);
        rig.engine.events.clear();
        t.fire();
        await rig.quiesce();
        expect(rig.engine.events, isEmpty);
        rig.app.busy = false;
      }));
    }
  });

  group('cold start (debugInit with a paired band)', () {
    Future<void> pairedCase(SyncRig rig) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
    }

    test('foreground: the data edge is seeded from the rec_ts_hw cursor and '
        'the session opens like openSession (not awaited by init)',
        syncCase((rig, timers) async {
      await pairedCase(rig);
      await LocalDb.setCursor('rec_ts_hw', '1750000000');
      expect(rig.app.lastRecordAt, isNull);
      await rig.app.debugInit();
      expect(rig.app.initialized, isTrue);
      expect(rig.app.paired?.remoteId, kRemoteId);
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000));
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      expect(rig.engine.events.first, 'setBackground:false');
      expect(rig.engine.only('connect'), ['connect:$kRemoteId:gen4']);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(BandOwnership.owner, BandOwnerKind.foreground);
    }, paired: false));

    test('headless background: wants a link, supervises, takes the lease, '
        'connects, recovers live streams and arms the backfill timer, but '
        'polls nothing and starts no drain', syncCase((rig, timers) async {
      await pairedCase(rig);
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      await rig.app.debugInit();
      expect(rig.engine.only('connect'), ['connect:$kRemoteId:gen4']);
      expect(rig.engine.count('getBattery'), 0);
      expect(rig.engine.count('getStrapName'), 0);
      expect(rig.engine.count('runSync'), 0);
      expect(rig.engine.count('reconcile'), greaterThanOrEqualTo(1));
      expect(rig.engine.count('prompt'), 1);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(_logged(rig, '===== BACKGROUND SESSION START ====='), isTrue);
      expect(await rig.jobTypes(), isEmpty);
    }, paired: false));

    test('headless background, connect refused: logged, no backfill timer, '
        'the supervisor stays, and the lease and intent are still held (only '
        'the iOS recovery arm runs, and that is a platform call)',
        syncCase((rig, timers) async {
      await pairedCase(rig);
      await rig.app.pauseForBackground();
      rig.engine.connectScript.add(false);
      await rig.app.debugInit();
      expect(_logged(rig, '[init] bg connect returned false — arming recovery'), isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.tryAcquireHeadless(), isNull);
    }, paired: false));

    test('headless background, connect throws: same outcome, logged as a '
        'failure', syncCase((rig, timers) async {
      await pairedCase(rig);
      await rig.app.pauseForBackground();
      rig.engine.connectScript.add(StateError('radio off'));
      await rig.app.debugInit();
      expect(_logged(rig, '[init] bg connect failed: Bad state: radio off — arming recovery'), isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
    }, paired: false));
  });

  group('endSession', () {
    test('stops wanting a link: disconnects, releases intent and lease, '
        'cancels the supervisor and the backfill timer, starts no reconnect, '
        'notifies once (the disconnected state)', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      rig.engine.events.clear();
      await rig.app.endSession();
      expect(rig.engine.events, ['clearReconnecting', 'disconnect']);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(rig.app.status, 'disconnected');
      expect(rig.engine.count('markReconnecting'), 0);
      // The iOS restore flag is NOT cleared here (unpair clears it).
      expect(IosBleRestore.foregroundActive, isTrue);
      expect(ticks.ticks, 1);
      expect(_logged(rig, '[OWNERSHIP] endSession intent off'), isTrue);
      ticks.stop();
    }));

    test('with nothing open it is harmless', syncCase((rig, timers) async {
      await rig.app.endSession();
      expect(rig.engine.events, ['clearReconnecting', 'disconnect']);
      expect(BandOwnership.owner, isNull);
    }));

    test('a session can be opened again afterwards', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.endSession();
      rig.engine.events.clear();
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 1);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      await rig.quiesce();
    }));
  });

  group('unpair', () {
    test('ends the session, clears the pairing and everything the old band '
        'said about itself, and drops the iOS restore flag; notifies twice',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.state.serial = 'OLD';
      rig.engine.state.strapName = 'Old strap';
      final ticks = TickCounter(rig.app);
      await rig.app.unpair();
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.app.paired, isNull);
      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
      expect(rig.app.device.serial, isNull);
      expect(rig.app.device.strapName, isNull);
      expect(rig.app.status, 'disconnected');
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(rig.engine.count('markReconnecting'), 0);
      expect(ticks.ticks, 2, reason: 'the disconnected state, then the final notify');
      ticks.stop();
    }));

    test('a drop that arrives after the unpair does not reconnect (no longer '
        'wanting a link, no longer paired)', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.unpair();
      rig.engine.up();
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.quiesce();
      expect(rig.engine.events, isNot(contains('markReconnecting')));
      expect(rig.engine.count('connect'), 0);
    }));
  });
}

/// openSession without waiting for the drain bookkeeping (the burst is parked
/// on the engine's gate).
Future<void> _openNoDrain(SyncRig rig) async {
  await rig.app.openSession();
  await rig.waitFor(() => rig.engine.count('runSync') == 1);
}
