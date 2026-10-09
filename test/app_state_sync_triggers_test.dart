// Sync area: the ways a sync is started over a live link
// (forceResync, foregroundCatchUp, syncNow, the burst loop they share), the
// single-flight rule, and what each leaves behind: the derive trigger, the data
// edge, the log and the notify count. Through AppState with a [SyncFakeEngine].
//
// IosBgTask.foregroundPull is assigned only by the real AppState constructor
// (forTesting does not), so that hook is only checked to be unwired here.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_triggers.db';

bool _logged(SyncRig rig, String text) =>
    rig.app.logLines.any((l) => l.contains(text));

/// A connected, drained foreground session with a clean slate behind it.
Future<void> _open(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.events.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('forTesting leaves the BGTask hook unwired', () {
    expect(IosBgTask.foregroundPull, isNull);
  });

  group('forceResync', () {
    test('with no link it does nothing at all', syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events, isEmpty);
      expect(ticks.ticks, 0);
      expect(await rig.jobTypes(), isEmpty);
      ticks.stop();
    }));

    test('over a live link: a KICKED offload (history request, then the '
        'drain), then a light derive and a notify', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events, ['requestHistorySync', 'runSync:180']);
      await rig.jobQueued('derive_light');
      await rig.settleDerive(const Duration(seconds: 8));
      await rig.quiesce();
      expect(await rig.jobTypes(), ['derive_light']);
      expect(ticks.ticks, 3, reason: 'its own notify and two from the scheduler queueing the job');
      ticks.stop();
    }));

    test('a drain that moved nothing still asks for the light derive',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      await rig.app.forceResync();
      await rig.jobQueued('derive_light');
    }));

    test('it waits out a burst already in flight, then runs its own',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();
      var done = false;
      final resync = rig.app.forceResync().then((_) => done = true);
      await rig.quiesce();
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(done, isFalse);
      rig.engine.syncGate!.complete();
      await resync;
      expect(rig.engine.count('requestHistorySync'), 1);
      expect(rig.engine.count('runSync'), 1, reason: 'its own, after the first one finished');
      await rig.quiesce();
    }));

    test('a failure is logged, never thrown, and the single-flight latch is '
        'clear for the next call', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.requestSyncThrows = StateError('no link');
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(_logged(rig, 'Resync failed: Bad state: no link'), isTrue);
      expect(ticks.ticks, 0);
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      rig.engine.requestSyncThrows = null;
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      ticks.stop();
    }));

    test('if the burst it waits on fails, that failure is its own: logged as '
        'a failed resync, with no offload of its own and no light derive',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      rig.engine.syncScript.add(StateError('first burst failed'));
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      final resync = rig.app.forceResync();
      rig.engine.syncGate!.complete();
      await resync;
      expect(_logged(rig, 'Resync failed: Bad state: first burst failed'), isTrue);
      await rig.waitFor(() => _logged(rig, 'Background sync burst failed: Bad state: first burst failed'));
      await rig.quiesce();
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(rig.engine.count('runSync'), 1);
      expect(await rig.jobTypes(), isEmpty);
    }));
  });

  group('foregroundCatchUp', () {
    test('with no link it does nothing', syncCase((rig, timers) async {
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, isEmpty);
    }));

    test('a granted catch-up JOINS the offload (no history request) and '
        'queues a light derive when records came', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, ['requestForegroundSync', 'runSync:180']);
      expect(_logged(rig, 'Foreground catch-up: 3 records pulled.'), isTrue);
      await rig.jobQueued('derive_light');
      await rig.settleDerive(const Duration(seconds: 8));
      await rig.quiesce();
      expect(ticks.ticks, 3, reason: 'its own notify and two from the scheduler queueing the job');
      ticks.stop();
    }));

    test('a catch-up that brought nothing queues nothing and notifies nobody',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 1, true));
      final ticks = TickCounter(rig.app);
      await rig.app.foregroundCatchUp();
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      expect(ticks.ticks, 0);
      expect(_logged(rig, 'Foreground catch-up: 0 records pulled.'), isTrue);
      ticks.stop();
    }));

    test('floored by the engine (90 s): asked, nothing else', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.foregroundSyncAllowed = false;
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, ['requestForegroundSync']);
    }));

    test('a burst already in flight: it does not even ask the engine',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, isEmpty);
    }));

    test('a stale link is torn down instead (which re-arms the reconnect '
        'through the disconnect edge)', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 31);
      await rig.app.foregroundCatchUp();
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('requestForegroundSync'), 0);
      await rig.waitFor(() => rig.engine.count('markReconnecting') >= 1);
      await rig.quiesce();
    }));

    test('a failing drain is logged', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(StateError('burst failed'));
      await rig.app.foregroundCatchUp();
      expect(_logged(rig, 'Foreground catch-up sync failed: Bad state: burst failed'), isTrue);
      expect(await rig.jobTypes(), isEmpty);
    }));
  });

  group('the burst loop (every trigger shares it)', () {
    test('no batch acknowledged: one session and out', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — no batch ACKs; trim did not advance.'), isTrue);
    }));

    test('complete with no backlog: out after one session',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — history complete acknowledged by strap.'), isTrue);
    }));

    test('a frontier that did not move with nothing behind it ends the loop',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(2, 1, false));
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — frontier did not advance and no backlog remains'), isTrue);
    }));

    test('while the frontier advances and the strap still reports newer data, '
        'it continues: a history request before EVERY session, the data edge '
        'follows the frontier and each advance notifies',
        syncCase((rig, timers) async {
      await _open(rig);
      const newest = 1800000000;
      rig.engine.newestTs = newest;
      var n = 0;
      rig.engine.onRunSync = () async {
        n++;
        await LocalDb.setCursor('rec_ts_hw', '${newest - 1000 + n * 300}');
      };
      rig.engine.syncScript.addAll([
        SyncReport(5, 1, false),
        SyncReport(5, 1, false),
        SyncReport(5, 1, true),
      ]);
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events.where((e) => e.startsWith('request') || e.startsWith('runSync')).toList(), [
        'requestHistorySync', 'runSync:180',
        'requestHistorySync', 'runSync:180',
        'requestHistorySync', 'runSync:180',
      ]);
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch((newest - 1000 + 3 * 300) * 1000));
      expect(_logged(rig, 'Backfill continuation 1/20 — frontier still behind strap newest'), isTrue);
      await rig.quiesce();
      expect(ticks.ticks, greaterThanOrEqualTo(4), reason: 'three advances plus the final notify');
      ticks.stop();
    }));

    test('a frontier stuck on a stale-timestamp block with a backlog behind '
        'it is drained THROUGH, bounded at 20 sessions',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.newestTs = 1800000000;
      await LocalDb.setCursor('rec_ts_hw', '1700000000');
      rig.engine.syncScript.addAll([for (var i = 0; i < 30; i++) SyncReport(1, 1, false)]);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 20);
      expect(_logged(rig, 'Backfill continuation 1/20 — frontier stuck on a stale-timestamp block'), isTrue);
      await rig.quiesce();
    }));

    test('a terminal Stuck connection runs no session at all',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.stuck = true;
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 0);
      expect(_logged(rig, 'Backfill stop — history is terminal (Stuck) for this connection'), isTrue);
    }));

    test('the data edge never moves backwards', syncCase((rig, timers) async {
      await _open(rig);
      await LocalDb.setCursor('rec_ts_hw', '1750000500');
      rig.engine.onRunSync = () async {};
      await rig.app.forceResync();
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000500 * 1000));
      await LocalDb.setCursor('rec_ts_hw', '1750000100');
      await rig.app.forceResync();
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000500 * 1000));
      await rig.quiesce();
    }));

    test('the link dropping mid-loop ends it with the last report',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.newestTs = 1800000000;
      rig.engine.onRunSync = () async => rig.engine.link = false;
      rig.engine.syncScript.addAll([SyncReport(1, 1, false), SyncReport(1, 1, false)]);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));
  });

  group('syncNow', () {
    test('over a live link in the foreground: the engine\'s floored pull, '
        'then a light derive mark and the heavy request on top (one heavy '
        'job queued)', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.syncNow();
      expect(rig.engine.events, ['requestForegroundSync', 'runSync:180']);
      await rig.jobQueued('derive_heavy');
      expect(await rig.jobTypes(), ['derive_heavy']);
    }));

    test('the pull is floored by the engine: asked, no drain, and the heavy '
        'derive is still requested', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.foregroundSyncAllowed = false;
      await rig.app.syncNow();
      expect(rig.engine.events, ['requestForegroundSync']);
      await rig.jobQueued('derive_heavy');
    }));

    test('a burst already in flight is awaited, not joined by a second pull: '
        'the engine is not asked and the heavy derive follows',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();
      var done = false;
      final sync = rig.app.syncNow().then((_) => done = true);
      await rig.quiesce();
      expect(done, isFalse);
      rig.engine.syncGate!.complete();
      await sync;
      expect(rig.engine.events, isEmpty);
      await rig.jobQueued('derive_heavy');
    }));

    test('a failure is logged, never thrown, and the heavy derive is still '
        'requested', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(StateError('burst failed'));
      await rig.app.syncNow();
      expect(_logged(rig, 'Sync failed: Bad state: burst failed'), isTrue);
      await rig.jobQueued('derive_heavy');
    }));

    test('with the link down it is openSession: connect, join the burst it '
        'starts, no pull of its own and no heavy request from syncNow itself',
        syncCase((rig, timers) async {
      await rig.app.syncNow();
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('requestForegroundSync'), 0);
      expect(rig.engine.count('requestHistorySync'), 0);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.quiesce();
    }));

    test('backgrounded it is openSession too, even over a live link: the '
        'foreground reclaim, not a pull', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      await rig.app.syncNow();
      expect(rig.engine.events.first, 'setBackground:false');
      expect(rig.app.debugLiveOwners.foreground, isTrue);
      await rig.quiesce();
    }));
  });
}
