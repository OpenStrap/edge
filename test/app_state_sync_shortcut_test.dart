// Sync area: syncForShortcut through AppState with a [SyncFakeEngine]. The
// cancellation, concurrency and aggregate-report cases that need no scripted
// engine live in app_state_shortcut_sync_test.dart; this file adds the phases
// a Shortcut reports on its way to a burst, the background-mode rules of the
// connect it may start, how a multi-session burst totals up, and what a burst
// that finishes after dispose does.
//
// The iOS restore hand-back after a failed background connect is a platform
// call and is pinned by source in app_state_shortcut_sync_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_shortcut.db';

ShortcutSyncTask _task([String id = 't']) =>
    ShortcutSyncTask(id, const Duration(seconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('readiness', () {
    test('a failed start-up is reported as not ready, not waited on',
        syncCase((rig, timers) async {
      rig.app.initError = 'db corrupt';
      await expectLater(rig.app.syncForShortcut(_task()), throwsStateError);
      expect(rig.engine.events, isEmpty);
    }));

    test('an app disposed while the Shortcut waits for start-up is not ready',
        syncCase((rig, timers) async {
      final work = rig.app.syncForShortcut(_task());
      final failed = expectLater(work, throwsStateError);
      await rig.quiesce();
      rig.app.dispose();
      await failed;
      expect(rig.engine.count('connect'), 0);
      expect(rig.engine.count('runSync'), 0);
    }, dispose: false));

    test('a data reset that begins while the Shortcut waits on a busy app is '
        'refused when the wait ends', syncCase((rig, timers) async {
      rig.app
        ..initialized = true
        ..busy = true;
      final work = rig.app.syncForShortcut(_task());
      final failed = expectLater(work, throwsStateError);
      await rig.quiesce();
      ResetGate.enter();
      rig.app.busy = false;
      await failed;
      expect(rig.engine.events, isEmpty);
    }));
  });

  group('phases', () {
    test('a down link: connecting while the connect is parked, syncing once '
        'the burst starts', syncCase((rig, timers) async {
      rig.app.initialized = true;
      final gate = rig.holdConnect();
      final task = _task();
      final work = rig.app.syncForShortcut(task);
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(task.phase, 'connecting');
      gate.complete();
      final report = await work;
      expect(task.phase, 'syncing');
      expect(report.complete, isTrue);
      expect(report.records, 3);
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));

    test('an up link skips the connect and goes straight to syncing, asking '
        'the engine for a first offload', syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.up();
      final task = _task();
      final report = await rig.app.syncForShortcut(task);
      expect(task.phase, 'syncing');
      expect(report.complete, isTrue);
      expect(rig.engine.count('connect'), 0);
      expect(rig.engine.only('requestHistorySync'), ['requestHistorySync']);
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));

    test('a connect that cannot reach the band ends the Shortcut with an '
        'empty, incomplete report and no burst', syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.connectScript.add(false);
      final task = _task();
      final report = await rig.app.syncForShortcut(task);
      expect(report.complete, isFalse);
      expect(report.records, 0);
      expect(report.batches, 0);
      expect(task.phase, 'connecting');
      expect(rig.engine.count('runSync'), 0);
      await rig.quiesce();
    }));

    test('a link that has been quiet with a stream armed is torn down and '
        'reconnected before the burst', syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.up();
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 45);
      final report = await rig.app.syncForShortcut(_task());
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('connect'), greaterThanOrEqualTo(1));
      expect(report.complete, isTrue);
      await rig.quiesce();
    }));
  });

  group('a background Shortcut', () {
    test('opens the session without foregrounding the app: the engine is never '
        'told it is foreground and the live owners stay background',
        syncCase((rig, timers) async {
      rig.app.initialized = true;
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      final report = await rig.app.syncForShortcut(_task());
      expect(report.complete, isTrue);
      expect(rig.engine.only('setBackground'), isEmpty);
      expect(rig.app.debugLiveOwners.foreground, isFalse);
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));

    test('opening the app while its connect is parked flips to foreground at '
        'once (before the busy bounce), nudges the live streams, and leaves '
        'the Shortcut\'s own session to finish', syncCase((rig, timers) async {
      rig.app.initialized = true;
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      final gate = rig.holdConnect();
      final work = rig.app.syncForShortcut(_task());
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(rig.app.busy, isTrue);
      expect(rig.engine.only('setBackground'), isEmpty);
      await rig.app.openSession();
      expect(rig.engine.only('setBackground'), ['setBackground:false']);
      expect(rig.app.debugLiveOwners.foreground, isTrue);
      expect(rig.engine.count('reconcile'), 1);
      expect(rig.engine.count('connect'), 1, reason: 'the bounced call connects nothing');
      expect(rig.app.busy, isTrue);
      gate.complete();
      final report = await work;
      expect(report.complete, isTrue);
      await rig.quiesce();
    }));
  });

  group('the burst behind a Shortcut', () {
    // Each session moves the frontier 500 s toward the strap's newest record,
    // so the loop keeps going while the strap still reports a backlog.
    const newest = 1800000000;
    void scriptSessions(SyncRig rig, List<SyncReport> reports) {
      rig.engine.newestTs = newest;
      var n = 0;
      rig.engine.onRunSync = () async {
        n++;
        await LocalDb.setCursor('rec_ts_hw', '${newest - 1000 + n * 500}');
      };
      rig.engine.syncScript.addAll(reports);
    }

    test('records and batches are summed across the sessions and the report '
        'is complete when the final session was', syncCase((rig, timers) async {
      rig.app.initialized = true;
      scriptSessions(rig, [SyncReport(5, 1, false), SyncReport(7, 2, true)]);
      final report = await rig.app.syncForShortcut(_task());
      expect(rig.engine.count('runSync'), 2);
      expect(report.records, 12);
      expect(report.batches, 3);
      expect(report.complete, isTrue);
      await rig.quiesce();
    }));

    test('an earlier complete session does not make an incomplete final one '
        'complete', syncCase((rig, timers) async {
      rig.app.initialized = true;
      scriptSessions(rig, [SyncReport(5, 1, true), SyncReport(7, 2, false)]);
      final report = await rig.app.syncForShortcut(_task());
      expect(rig.engine.count('runSync'), 2);
      expect(report.records, 12);
      expect(report.batches, 3);
      expect(report.complete, isFalse);
      await rig.quiesce();
    }));

    test('a burst that brought records queues the light derive and notifies',
        syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.up();
      final ticks = TickCounter(rig.app);
      await rig.app.syncForShortcut(_task());
      await rig.jobQueued('derive_light');
      expect(ticks.ticks, greaterThanOrEqualTo(1));
      ticks.stop();
    }));

    test('a burst that brought nothing queues no derive',
        syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.up();
      rig.engine.syncScript.add(SyncReport(0, 1, true));
      await rig.app.syncForShortcut(_task());
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
    }));
  });

  group('completion after dispose', () {
    test('the report is still returned, but no derive is queued and nobody is '
        'notified', syncCase((rig, timers) async {
      rig.app.initialized = true;
      rig.engine.up();
      rig.engine.syncGate = Completer<void>();
      final work = rig.app.syncForShortcut(_task());
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      var ticks = 0;
      void tick() => ticks++;
      rig.app.addListener(tick);
      rig.app.dispose();
      rig.engine.syncGate!.complete();
      final report = await work;
      expect(report.records, 3);
      expect(report.complete, isTrue);
      await settleMs(300);
      expect(await rig.jobTypes(), isEmpty);
      expect(ticks, 0);
    }, dispose: false));
  });
}
