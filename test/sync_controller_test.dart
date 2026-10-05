// SyncController built straight from its constructor, with a hand-written
// engine and every host callback recording into one trace. The AppState-level
// suites (app_state_sync_*_test) pin the same behaviour through the facade;
// this file pins the controller's own contract: what it does before and after
// the busy early return, the order it takes and gives back the band lease
// relative to connect and disconnect, how a burst's reports add up and when its
// single-flight slot frees, which reconnect loop owns the shared flags, the
// retry when the link drops during post-connect setup, and the quiet window.
//
// The iOS and Android branches (Platform.isIOS / Platform.isAndroid) cannot be
// taken on the Linux test host; the engine's own calls are the observable
// surface here.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/sync_controller.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';

import 'support/app_state_derive_harness.dart'
    show deriveDbSetUp, deriveDbTearDown, until;
import 'support/app_state_sync_harness.dart'
    show SyncTimers, kBackfillEvery, kRemoteId, kSerial, kSuperviseEvery;

const _db = 'sync_controller.db';

/// The engine as the controller sees it: every call lands in [trace], in call
/// order, and the answers are scripted. Only the members the controller reads
/// exist; anything else throws.
class _Engine implements BleEngine {
  _Engine(this.trace);
  final List<String> trace;

  @override
  final DeviceState state = DeviceState();

  bool link = false;
  final connectScript = <Object>[];

  /// Holds the NEXT connect until completed (taken at call time, then cleared).
  Completer<void>? nextConnectGate;
  final runSyncScript = <Object>[];
  Completer<void>? syncGate;
  Future<void> Function()? onRunSync;
  Future<void> Function()? batteryHook;
  bool foregroundSyncAllowed = true;
  bool probeAnswer = true;
  int? newestTs;

  int count(String name) =>
      trace.where((e) => e == name || e.startsWith('$name:')).length;

  @override
  bool get isConnected => link;
  @override
  Duration get sinceLastRx => Duration.zero;
  @override
  bool get liveEnabled => false;
  @override
  bool get historyStuckThisSession => false;
  @override
  int? get strapHistoryNewestTs => newestTs;
  @override
  DateTime? get lastRxAt => null;

  @override
  void setBackground(bool value) => trace.add('setBackground:$value');

  @override
  Future<bool> connectToRemoteId(String remoteId,
      {String? generationHint}) async {
    trace.add('connect');
    final gate = nextConnectGate;
    nextConnectGate = null;
    final r = connectScript.isEmpty ? true : connectScript.removeAt(0);
    if (gate != null) await gate.future;
    if (r is bool) {
      link = r;
      return r;
    }
    throw r;
  }

  @override
  Future<void> disconnect() async {
    trace.add('disconnect');
    link = false;
  }

  @override
  Future<void> getBattery() async {
    trace.add('getBattery');
    await batteryHook?.call();
  }

  @override
  Future<void> getStrapName() async => trace.add('getStrapName');

  @override
  Future<void> reconcileLiveStreams() async => trace.add('reconcile');

  @override
  Future<void> requestHistorySync() async => trace.add('requestHistorySync');

  @override
  Future<bool> requestForegroundSync() async {
    trace.add('requestForegroundSync');
    return foregroundSyncAllowed;
  }

  @override
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) async {
    trace.add('runSync:${timeout.inSeconds}');
    if (syncGate != null) await syncGate!.future;
    await onRunSync?.call();
    final r =
        runSyncScript.isEmpty ? SyncReport(3, 1, true) : runSyncScript.removeAt(0);
    if (r is SyncReport) return r;
    throw r;
  }

  @override
  Future<bool> probeLink({Duration timeout = const Duration(seconds: 5)}) async {
    trace.add('probe');
    return probeAnswer;
  }

  @override
  Duration reconnectDelay(int attempt) {
    trace.add('backoff:$attempt');
    return Duration.zero;
  }

  @override
  void markReconnecting() => trace.add('markReconnecting');

  @override
  void clearReconnecting() => trace.add('clearReconnecting');

  @override
  bool refreshAutoReconnectPause() {
    trace.add('refreshPause');
    return state.autoReconnectPaused;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what the controller asks of the scheduler; none of the real
/// scheduler's timers or queue run.
class _Scheduler extends DeriveScheduler {
  _Scheduler(this.trace)
      : super(
          run: ({required kind}) async {},
          log: (_) {},
          onChanged: () {},
        );
  final List<String> trace;

  @override
  void setBackground(bool background) => trace.add('sched.background:$background');
  @override
  void markStoredData() => trace.add('sched.stored');
  @override
  void requestHeavy() => trace.add('sched.heavy');
}

/// A controller plus the host it is wired to. Engine calls, host callbacks and
/// the band lease all append to the one [trace], in call order.
class _Rig {
  _Rig({bool paired = true}) {
    BandOwnership.resetForTest();
    ResetGate.resetForTest();
    engine = _Engine(trace);
    scheduler = _Scheduler(trace);
    pairedDevice =
        paired ? PairedDevice(kRemoteId, kSerial, generation: 'gen4') : null;
    c = SyncController(
      engine: () => engine,
      paired: () => pairedDevice,
      log: (l) {
        logs.add(l);
        if (l.contains('acquired foreground lease')) trace.add('lease+');
        if (l.contains('releasing foreground lease')) trace.add('lease-');
      },
      notify: () => notifies++,
      isDisposed: () => hostDisposed,
      initialized: () => initialized,
      initError: () => initError,
      deriveScheduler: () => scheduler,
      phoneStepsEnabled: () => phoneSteps,
      syncPhoneSteps: () async => trace.add('steps'),
      ecgOnAppPaused: () async => trace.add('ecg.pause'),
      nudgeLive: () => trace.add('nudge'),
      recoverOrphanedLiveSession: () async => trace.add('recover'),
      resetLivePedometer: () => trace.add('resetPedometer'),
      refreshHighFreqWakeWindow: () async => trace.add('wake'),
      armNextAlarmOccurrence: () async => trace.add('alarm'),
      resetActivityReviewAttempts: () => trace.add('reviews.reset'),
      refreshActivityReviews: () async => trace.add('reviews.refresh'),
    );
  }

  final trace = <String>[];
  final logs = <String>[];
  late final _Engine engine;
  late final _Scheduler scheduler;
  late final SyncController c;
  PairedDevice? pairedDevice;
  int notifies = 0;
  bool hostDisposed = false;
  bool initialized = true;
  String? initError;
  bool phoneSteps = false;

  bool logged(String text) => logs.any((l) => l.contains(text));

  /// A connected foreground session whose backlog burst has landed.
  Future<void> openAndSettle() async {
    await c.openSession();
    await until(() => trace.contains('sched.heavy'));
    trace.clear();
    logs.clear();
    notifies = 0;
  }

  /// Wait (polling) until [text] has been logged.
  Future<void> loggedWithin(String text) =>
      until(() => logged(text), what: 'log "$text"');
}

/// A test body in a [SyncTimers] zone (the 10 min backfill, the 1 min
/// supervisor and the 6 s quiet timer are fired by hand) with a fresh rig.
void Function() _rigCase(
  Future<void> Function(_Rig r, SyncTimers timers) body, {
  bool paired = true,
}) =>
    () async {
      final timers = SyncTimers();
      await timers.run(() async {
        final r = _Rig(paired: paired);
        try {
          await body(r, timers);
        } finally {
          r.c.dispose();
          BandOwnership.resetForTest();
          ResetGate.resetForTest();
        }
      });
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('openSession and the busy early return', () {
    test('the foreground flip lands before the busy return, with the nudge',
        _rigCase((r, timers) async {
      r.c.background = true;
      r.c.busy = true;
      await r.c.openSession();
      expect(r.c.background, isFalse);
      expect(r.c.busy, isTrue, reason: 'the in-flight session keeps its flag');
      expect(r.trace, [
        'setBackground:false',
        'sched.background:false',
        'nudge',
        'wake',
      ]);
      expect(BandOwnership.foregroundIntent, isFalse,
          reason: 'returned before claiming intent');
    }));

    test('already foreground and busy: flips nothing new and nudges nothing',
        _rigCase((r, timers) async {
      r.c.busy = true;
      await r.c.openSession();
      expect(r.trace, ['setBackground:false', 'sched.background:false']);
    }));

    test('a background open while busy touches nothing', _rigCase((r, timers) async {
      r.c.background = true;
      r.c.busy = true;
      await r.c.openSession(foreground: false);
      expect(r.c.background, isTrue);
      expect(r.trace, isEmpty);
    }));

    test('the activity-review reset follows the busy return and precedes the lease',
        _rigCase((r, timers) async {
      r.phoneSteps = true;
      r.engine.connectScript.add(false);
      await r.c.openSession();
      expect(r.trace, [
        'setBackground:false',
        'sched.background:false',
        'steps',
        'reviews.reset',
        'reviews.refresh',
        'lease+',
        'connect',
        'lease-',
      ]);
    }));

    test('unpaired: nothing happens, not even the foreground flip',
        _rigCase((r, timers) async {
      r.c.background = true;
      await r.c.openSession();
      expect(r.c.background, isTrue);
      expect(r.trace, isEmpty);
    }, paired: false));
  });

  group('the band lease against connect and disconnect', () {
    test('a failed connect releases the lease and intent, and frees busy',
        _rigCase((r, timers) async {
      r.engine.connectScript.add(false);
      await r.c.openSession();
      expect(r.trace.where((e) => e.startsWith('lease') || e == 'connect'),
          ['lease+', 'connect', 'lease-']);
      expect(r.c.busy, isFalse);
      expect(r.notifies, 2, reason: 'busy on, busy off');
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(r.logged('Session start: could not reach the band.'), isTrue);
    }));

    test('a connect that throws is swallowed and cleaned up the same way',
        _rigCase((r, timers) async {
      r.engine.connectScript.add(StateError('radio'));
      await r.c.openSession();
      expect(r.logged('Session start failed: Bad state: radio'), isTrue);
      expect(r.trace.last, 'lease-');
      expect(r.c.busy, isFalse);
    }));

    test('a good session takes the lease before connect and keeps it',
        _rigCase((r, timers) async {
      await r.c.openSession();
      await until(() => r.trace.contains('sched.heavy'));
      expect(r.trace, [
        'setBackground:false',
        'sched.background:false',
        'reviews.reset',
        'reviews.refresh',
        'lease+',
        'connect',
        'getBattery',
        'getStrapName',
        'wake',
        'alarm',
        'recover',
        'resetPedometer',
        'reconcile',
        'runSync:180',
        'wake',
        'alarm',
        'sched.heavy',
      ]);
      expect(r.c.busy, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(BandOwnership.foregroundIntent, isTrue);
    }));

    test('endSession disconnects, then gives the lease back',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      await r.c.endSession();
      expect(r.trace, ['clearReconnecting', 'disconnect', 'lease-']);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(BandOwnership.foregroundIntent, isFalse);
    }));

    test('unpairSession tears the link down in order, lease last',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      await r.c.unpairSession();
      expect(r.trace, ['clearReconnecting', 'disconnect', 'lease-']);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
    }));

    test('dispose cancels the timers and leaves the lease and the link to the host',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      r.c.markSyncActivity();
      // AppState cancels the quiet timer first, then disposes the rest.
      r.c.cancelQuietTimer();
      expect(timers.live, isNotEmpty, reason: 'backfill still armed');
      r.c.dispose();
      expect(timers.live, isEmpty);
      expect(r.trace, ['clearReconnecting']);
      expect(r.engine.link, isTrue);
    }));

    test('a link drop with no session wanted only hands the lease back',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      r.engine.state.autoReconnectPaused = true;
      r.engine.link = false;
      r.c.onLinkDropped();
      expect(r.trace, ['lease-']);
    }));

    test('the background cold-launch connect: success, refusal and a throw',
        _rigCase((r, timers) async {
      r.engine.connectScript.add(true);
      r.engine.connectScript.add(false);
      r.engine.connectScript.add(StateError('radio'));
      await r.c.startBackgroundSession();
      expect(r.trace, [
        'lease+',
        'connect',
        'recover',
        'resetPedometer',
        'reconcile',
        'wake',
      ]);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      r.trace.clear();
      await r.c.startBackgroundSession();
      expect(r.trace, ['connect']);
      expect(r.logged('[init] bg connect returned false — arming recovery'),
          isTrue);
      await r.c.startBackgroundSession();
      expect(r.logged('[init] bg connect failed: Bad state: radio'), isTrue);
    }));

    test('going to the background: flag first, ECG cleanup before the stream step-down',
        _rigCase((r, timers) async {
      final f = r.c.pauseForBackground();
      expect(r.c.background, isTrue, reason: 'set before the first await');
      await f;
      expect(r.trace, [
        'ecg.pause',
        'setBackground:true',
        'sched.background:true',
        'nudge',
      ]);
    }));
  });

  group('sync bursts', () {
    test('a burst reports the sum of its sessions with the last one\'s completion',
        _rigCase((r, timers) async {
      r.engine.link = true;
      r.engine.newestTs = 1000000;
      var session = 0;
      r.engine.runSyncScript
        ..add(SyncReport(2, 1, false))
        ..add(SyncReport(3, 2, true));
      r.engine.onRunSync = () async {
        session++;
        await LocalDb.setCursor(
            'rec_ts_hw', session == 1 ? '1000' : '999900');
      };
      final task = ShortcutSyncTask('t', const Duration(minutes: 1));
      final report = await r.c.syncForShortcut(task);
      expect(report.records, 5);
      expect(report.batches, 3);
      expect(report.complete, isTrue);
      expect(r.trace.where((e) => e.startsWith('runSync') ||
          e == 'requestHistorySync'), [
        'requestHistorySync',
        'runSync:180',
        'requestHistorySync',
        'runSync:180',
      ]);
      expect(r.c.lastRecTs, 999900, reason: 'advanced from every session');
      expect(task.phase, 'syncing');
      expect(r.trace.last, 'sched.stored');
    }));

    test('the single-flight slot frees whenComplete, success or failure',
        _rigCase((r, timers) async {
      r.engine.link = true;
      r.engine.runSyncScript.add(StateError('stuck'));
      await r.c.foregroundCatchUp();
      expect(r.logged('Foreground catch-up sync failed: Bad state: stuck'),
          isTrue);
      expect(r.engine.count('runSync'), 1);
      // A fresh burst starts, so the failed one released the slot.
      await r.c.forceResync();
      expect(r.engine.count('runSync'), 2);
      expect(r.logged('Resync failed'), isFalse);
      await r.c.forceResync();
      expect(r.engine.count('runSync'), 3);
    }));

    test('a second trigger joins the burst in flight instead of starting one',
        _rigCase((r, timers) async {
      r.engine.link = true;
      final gate = r.engine.syncGate = Completer<void>();
      final first = r.c.foregroundCatchUp();
      await until(() => r.engine.count('runSync') == 1);
      await r.c.foregroundCatchUp();
      expect(r.engine.count('runSync'), 1, reason: 'the second one joined');
      var resyncDone = false;
      final resync = r.c.forceResync().then((_) => resyncDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(resyncDone, isFalse, reason: 'forceResync waits the burst out');
      r.engine.syncGate = null;
      gate.complete();
      await first;
      await resync;
      expect(r.engine.count('runSync'), 2);
      expect(r.engine.count('requestHistorySync'), 1,
          reason: 'forceResync re-kicks the offload itself');
    }));

    test('syncNow asks for a floored pull, then requests the heavy finalize',
        _rigCase((r, timers) async {
      r.engine.link = true;
      r.engine.foregroundSyncAllowed = false;
      await r.c.syncNow();
      expect(r.trace, ['requestForegroundSync', 'sched.heavy']);
      r.trace.clear();
      r.engine.foregroundSyncAllowed = true;
      await r.c.syncNow();
      expect(r.trace, [
        'requestForegroundSync',
        'runSync:180',
        'sched.stored',
        'sched.heavy',
      ]);
    }));

    test('syncNow while backgrounded or unlinked opens a session instead',
        _rigCase((r, timers) async {
      r.c.background = true;
      r.c.busy = true;
      r.engine.link = true;
      await r.c.syncNow();
      expect(r.c.background, isFalse);
      expect(r.engine.count('requestForegroundSync'), 0);
      expect(r.trace, contains('setBackground:false'));
    }));

    test('the periodic tick: foreground pulls, background only re-plans the wake window',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      final tick = timers.activePeriodic(kBackfillEvery).single;
      tick.fire();
      await until(() => r.trace.contains('sched.stored'));
      expect(r.trace, [
        'wake',
        'requestHistorySync',
        'runSync:180',
        'sched.stored',
      ]);
      expect(r.logged('Periodic backlog check: 3 records (complete).'), isTrue);

      r.trace.clear();
      r.c.background = true;
      tick.fire();
      await until(() => r.logged('Periodic history refresh skipped — backgrounded'));
      expect(r.trace, ['wake']);
      r.trace.clear();
      tick.fire();
      await until(() => r.logs.where((l) =>
          l.contains('Periodic history refresh skipped — backgrounded')).length == 2);
      expect(r.trace, isEmpty, reason: 'the re-plan is throttled to 25 minutes');
    }));
  });

  group('reconnect', () {
    test('a link that drops during post-connect setup is retried',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      var dropped = false;
      r.engine.batteryHook = () async {
        if (dropped) return;
        dropped = true;
        r.engine.link = false;
      };
      r.engine.link = false;
      r.c.onLinkDropped();
      await r.loggedWithin('Reconnected — live on; draining backlog in background.');
      expect(r.logged('Link dropped during reconnect setup — retrying.'), isTrue);
      expect(r.engine.count('connect'), 2, reason: 'one attempt per pass');
      expect(r.engine.count('backoff'), 2);
      expect(r.engine.link, isTrue);
      await until(() => r.trace.contains('sched.heavy'));
    }));

    test('a superseded loop leaves the replacement\'s flags alone',
        _rigCase((r, timers) async {
      r.engine.connectScript
        ..add(true) // the first session
        ..add(false) // loop A, parked until released
        ..add(false) // the second session's own connect
        ..add(true); // loop B, parked until released
      await r.openAndSettle();

      final gateA = r.engine.nextConnectGate = Completer<void>();
      r.engine.link = false;
      r.c.onLinkDropped();
      await until(() => r.engine.count('connect') == 1);

      // Ending the session retires loop A; a fresh session then drops again and
      // starts loop B.
      await r.c.endSession();
      await r.c.openSession();
      expect(r.engine.count('connect'), 2);
      final gateB = r.engine.nextConnectGate = Completer<void>();
      r.engine.link = false;
      r.c.onLinkDropped();
      await until(() => r.engine.count('connect') == 3);
      expect(BandOwnership.foregroundIntent, isTrue);

      final mark = r.trace.length;
      gateA.complete();
      await r.loggedWithin('[RECONNECT] loop #1 was superseded');
      expect(r.trace.sublist(mark), isNot(contains('clearReconnecting')),
          reason: 'the stale loop must not clear the live loop\'s state');
      expect(BandOwnership.foregroundIntent, isTrue);

      gateB.complete();
      await until(() => r.trace.sublist(mark).contains('clearReconnecting'));
      expect(r.engine.link, isTrue, reason: 'loop B owned the reconnect');
      expect(r.logs.where((l) => l.contains('superseded')), hasLength(1));
    }));

    test('the supervisor starts a loop when none runs, and does nothing once disposed',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      final tick = timers.activePeriodic(kSuperviseEvery).single;
      r.engine.link = false;
      tick.fire();
      await r.loggedWithin('[RECONNECT] supervisor: disconnected with no loop running');
      await until(() => r.engine.count('connect') == 1);

      r.trace.clear();
      r.hostDisposed = true;
      tick.fire();
      expect(r.trace, isEmpty, reason: 'not even refreshAutoReconnectPause');
    }));

    test('a drop while a session is wanted cancels the backfill timer and reconnects',
        _rigCase((r, timers) async {
      await r.openAndSettle();
      final backfill = timers.activePeriodic(kBackfillEvery).single;
      r.engine.link = false;
      r.c.onLinkDropped();
      expect(backfill.cancelled, isTrue, reason: 'cancelled at the edge');
      await r.loggedWithin('Reconnected');
      expect(r.logged('Connection dropped — reconnecting…'), isTrue);
    }));
  });

  group('the quiet window', () {
    test('marking activity lights the indicator and arms one timer that notifies once',
        _rigCase((r, timers) async {
      expect(r.c.syncingNow, isFalse);
      r.c.markSyncActivity();
      expect(r.c.syncingNow, isTrue);
      expect(r.notifies, 0, reason: 'marking itself does not notify');
      final first = timers.activeOneShot(const Duration(milliseconds: 6000));
      expect(first, hasLength(1));

      r.c.markSyncActivity();
      expect(first.single.cancelled, isTrue, reason: 'a new batch restarts it');
      final second = timers.activeOneShot(const Duration(milliseconds: 6000));
      expect(second, hasLength(1));

      second.single.fire();
      expect(r.notifies, 1);
      expect(timers.activeOneShot(const Duration(milliseconds: 6000)), isEmpty);
    }));

    test('last-record time follows the stored seconds', _rigCase((r, timers) async {
      expect(r.c.lastRecordAt, isNull);
      r.c.lastRecTs = 1700000000;
      expect(r.c.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    }));
  });

  group('syncForShortcut', () {
    test('waits for init, then for a busy session, reporting each phase',
        _rigCase((r, timers) async {
      r.initialized = false;
      r.c.busy = true;
      r.engine.link = true;
      final phases = <String>[];
      final task = ShortcutSyncTask('t', const Duration(minutes: 1),
          onProgress: (m) => phases.add(m['phase']! as String));
      final done = r.c.syncForShortcut(task);
      await until(() => phases.contains('starting'));
      r.initialized = true;
      await until(() => phases.contains('waiting'));
      r.c.busy = false;
      final report = await done;
      expect(phases, ['starting', 'waiting', 'syncing']);
      expect(report.records, 3);
    }));

    test('an init failure or a disposed host is "not ready"',
        _rigCase((r, timers) async {
      r.initialized = false;
      r.initError = 'boom';
      await expectLater(
          r.c.syncForShortcut(ShortcutSyncTask('t', const Duration(minutes: 1))),
          throwsA(isA<StateError>()));
      r.initError = null;
      r.initialized = true;
      r.hostDisposed = true;
      await expectLater(
          r.c.syncForShortcut(ShortcutSyncTask('t', const Duration(minutes: 1))),
          throwsA(isA<StateError>()));
    }));

    test('a reset in progress refuses before anything else', _rigCase((r, timers) async {
      ResetGate.enter();
      await expectLater(
          r.c.syncForShortcut(ShortcutSyncTask('t', const Duration(minutes: 1))),
          throwsA(isA<StateError>()));
      expect(r.trace, isEmpty);
    }));

    test('a stopped task stops waiting without touching the band',
        _rigCase((r, timers) async {
      r.c.busy = true;
      final task = ShortcutSyncTask('t', const Duration(minutes: 1));
      final done = r.c.syncForShortcut(task);
      await until(() => task.phase == 'waiting');
      task.stop();
      final report = await done;
      expect([report.records, report.batches, report.complete], [0, 0, false]);
      expect(r.trace, isEmpty);
    }));

    test('a stopped task ceases waiting on a running burst; the burst carries on',
        _rigCase((r, timers) async {
      r.engine.link = true;
      final gate = r.engine.syncGate = Completer<void>();
      final task = ShortcutSyncTask('t', const Duration(minutes: 1));
      final done = r.c.syncForShortcut(task);
      await until(() => r.engine.count('runSync') == 1);
      task.stop();
      final report = await done;
      expect([report.records, report.batches, report.complete], [0, 0, false]);
      expect(r.trace, isNot(contains('sched.stored')));
      r.engine.syncGate = null;
      gate.complete();
      await until(() => r.trace.contains('sched.stored'),
          what: 'the burst finishing on its own');
    }));

    test('after the host is disposed the report comes back with no derive and no notify',
        _rigCase((r, timers) async {
      r.engine.link = true;
      var gate = r.engine.syncGate = Completer<void>();
      var task = ShortcutSyncTask('t', const Duration(minutes: 1));
      var done = r.c.syncForShortcut(task);
      await until(() => r.engine.count('runSync') == 1);
      gate.complete();
      var report = await done;
      expect(report.records, 3);
      expect(r.trace.last, 'sched.stored', reason: 'control: alive host derives');
      final notified = r.notifies;
      expect(notified, greaterThan(0));

      r.trace.clear();
      gate = r.engine.syncGate = Completer<void>();
      task = ShortcutSyncTask('t', const Duration(minutes: 1));
      done = r.c.syncForShortcut(task);
      await until(() => r.engine.count('runSync') == 1);
      r.hostDisposed = true;
      gate.complete();
      report = await done;
      expect(report.records, 3);
      expect(r.trace, isNot(contains('sched.stored')));
      expect(r.notifies, notified, reason: 'no notify after disposal');
    }));

    test('a background Shortcut connects without the foreground flip',
        _rigCase((r, timers) async {
      r.c.background = true;
      final task = ShortcutSyncTask('t', const Duration(minutes: 1));
      final report = await r.c.syncForShortcut(task);
      expect(r.c.background, isTrue);
      expect(r.trace, isNot(contains('setBackground:false')));
      expect(r.trace, contains('connect'));
      expect(report.records, 3);
      expect(task.phase, 'syncing');
    }));
  });
}
