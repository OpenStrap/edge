// Shared helpers for the AppState sync tests (open/resume session, reconnect
// loop and supervisor, sync bursts, Shortcut sync, status). Everything goes
// through AppState's public and @visibleForTesting surface.
//
// What the area talks to, and how the tests see it:
//   - the BLE engine is a [SyncFakeEngine]: a BleEngine subclass that records
//     every call in order, scripts connect / drain / probe results, and feeds
//     its state changes back through AppState.debugFeedEngineState, which is
//     what the production onState callback does. No radio, no plugin.
//   - the periodic timers (10 min backfill, 1 min reconnect supervisor) and
//     every one-shot timer of one second or more (the derive scheduler's settle
//     timers, the alarm grace timer) are
//     replaced, inside [SyncTimers.run], by timers the test fires by hand, so a
//     tick is one explicit call and never a wall-clock race. Shorter one-shots
//     (Future.delayed polls, zero-delay reconnect backoff) run for real.
//   - the derive trigger a drain leaves behind is read from the durable
//     `compute_jobs` rows the scheduler writes (a heavy request supersedes a
//     queued light one; see LocalDb.enqueueDeriveJob), never from a timer.
//   - the process-wide statics the area drives (BandOwnership, ResetGate,
//     IosBleRestore.foregroundActive, the band claim) are reset by [SyncRig].
//
// Platform branches (Platform.isAndroid / Platform.isIOS) cannot be taken on
// the Linux test host, and nothing injects the platform. Those branches are
// named in the files that meet them, not covered.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart' show TestFailure;
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

import 'app_state_derive_harness.dart' show deriveHook, until;

export 'package:openstrap_edge/ble/ble_engine.dart' show SyncReport;
export 'app_state_derive_harness.dart' show deriveDbSetUp, deriveDbTearDown, until;

/// A real wait for fire-and-forget work to land.
Future<void> settleMs([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Counts the notifyListeners ticks of an AppState until [stop].
class TickCounter {
  TickCounter(this.app) {
    app.addListener(_tick);
  }
  final AppState app;
  int ticks = 0;
  void _tick() => ticks++;
  void stop() => app.removeListener(_tick);
}

/// The band the rigs pair.
const String kRemoteId = 'r-sync';
const String kSerial = '4C2248092';

/// A timer the test fires by hand. [period] is null for a one-shot.
class FakeTimer implements Timer {
  FakeTimer(this.duration, this._f, {required this.periodic});
  final Duration duration;
  final bool periodic;
  final Function _f;
  bool cancelled = false;
  int fired = 0;

  /// Run the callback once, as the timer would. A one-shot is spent after.
  void fire() {
    if (cancelled) throw StateError('fired a cancelled timer');
    fired++;
    if (!periodic) cancelled = true;
    if (periodic) {
      (_f as void Function(Timer))(this);
    } else {
      (_f as void Function())();
    }
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => fired;
}

/// Hand-fired timers for everything long. Periodic timers are always replaced;
/// one-shots only from [minOneShot] up (shorter ones are real so polls and the
/// zero-delay reconnect backoff keep running).
class SyncTimers {
  SyncTimers({this.minOneShot = const Duration(seconds: 1)});
  final Duration minOneShot;
  final all = <FakeTimer>[];

  List<FakeTimer> get live => [for (final t in all) if (!t.cancelled) t];
  List<FakeTimer> activePeriodic(Duration d) =>
      [for (final t in live) if (t.periodic && t.duration == d) t];
  List<FakeTimer> activeOneShot(Duration d) =>
      [for (final t in live) if (!t.periodic && t.duration == d) t];

  ZoneSpecification get spec => ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, d, f) {
          final t = FakeTimer(d, f, periodic: true);
          all.add(t);
          return t;
        },
        createTimer: (self, parent, zone, d, f) {
          if (d < minOneShot) return parent.createTimer(zone, d, f);
          final t = FakeTimer(d, f, periodic: false);
          all.add(t);
          return t;
        },
      );

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneSpecification: spec);
}

/// The 10 minute periodic backfill.
const Duration kBackfillEvery = Duration(minutes: 10);

/// The reconnect supervisor.
const Duration kSuperviseEvery = Duration(minutes: 1);

class _Sink {
  void Function(DeviceState)? fn;
}

/// A BleEngine with no radio. Records what AppState asks of it in [events]
/// (in call order) and answers from the scripts below.
class SyncFakeEngine extends BleEngine {
  factory SyncFakeEngine() => SyncFakeEngine._(_Sink());

  SyncFakeEngine._(_Sink sink)
      : _sink = sink,
        super(onRecord: (_, _) async {}, onState: (s) => sink.fn?.call(s));

  final _Sink _sink;

  /// Route every state change into [app] the way the engine's onState does.
  void wire(AppState app) {
    _sink.fn = (s) => app.debugFeedEngineState(LocalDb.kPrimaryDeviceId, s);
  }

  /// Every engine call AppState made, in order.
  final events = <String>[];
  int count(String prefix) =>
      events.where((e) => e == prefix || e.startsWith('$prefix:')).length;
  List<String> only(String prefix) =>
      [for (final e in events) if (e == prefix || e.startsWith('$prefix:')) e];

  // ── scripts ────────────────────────────────────────────────────────────────
  bool link = false;

  /// connectToRemoteId answers, consumed in order: true / false / an Object to
  /// throw. Empty = true.
  final connectScript = <Object>[];

  /// Holds the NEXT connect until completed (taken once, then cleared).
  Completer<void>? connectGate;

  /// runSync answers: a SyncReport or an Object to throw. Empty = a complete
  /// 3-record report.
  final syncScript = <Object>[];

  /// Holds every runSync until completed.
  Completer<void>? syncGate;

  /// Runs inside runSync before it answers (to move the durable frontier).
  Future<void> Function()? onRunSync;

  /// What requestForegroundSync answers (the engine's 90 s floor).
  bool foregroundSyncAllowed = true;
  bool probeAnswer = true;
  Duration quiet = Duration.zero;
  bool liveArmed = false;
  bool stuck = false;
  int? newestTs;
  DateTime? rxAt;
  Object? batteryThrows;

  /// Like [batteryThrows] but spent after one throw, so a reconnect loop that
  /// tears the link down and retries gets a working poll the second time
  /// (a persistent throw would spin the zero-delay fake backoff).
  Object? batteryThrowsOnce;
  Object? requestSyncThrows;

  /// Runs inside the band-prompt write (to look at the world at that moment);
  /// what it returned each time lands in [promptStamps].
  Future<String> Function()? stamp;
  final promptStamps = <String>[];

  /// Runs inside getBattery, before it answers.
  Future<void> Function()? batteryHook;

  /// Runs inside connectToRemoteId / disconnect, before they answer (to look at
  /// who holds the band at that moment).
  Future<void> Function()? connectHook;
  Future<void> Function()? disconnectHook;

  // ── engine surface AppState reads ──────────────────────────────────────────
  @override
  bool get isConnected => link;
  @override
  Duration get sinceLastRx => quiet;
  @override
  bool get liveEnabled => liveArmed;
  @override
  bool get historyStuckThisSession => stuck;
  @override
  int? get strapHistoryNewestTs => newestTs;
  @override
  DateTime? get lastRxAt => rxAt;

  void _state(String connection) {
    state.connection = connection;
    _sink.fn?.call(state);
  }

  /// The band answers the connect: the link is up and the state says so.
  void up() {
    link = true;
    _state('connected');
  }

  /// The link drops by itself (out of range).
  void drop() {
    link = false;
    _state('disconnected');
  }

  @override
  Future<bool> connectToRemoteId(String remoteId, {String? generationHint}) async {
    events.add('connect:$remoteId:${generationHint ?? '-'}');
    await connectHook?.call();
    final gate = connectGate;
    connectGate = null;
    if (gate != null) await gate.future;
    final r = connectScript.isEmpty ? true : connectScript.removeAt(0);
    if (r is bool) {
      if (r) up();
      return r;
    }
    throw r;
  }

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    await disconnectHook?.call();
    link = false;
    _state('disconnected');
  }

  @override
  Future<void> getBattery() async {
    events.add('getBattery');
    await batteryHook?.call();
    final once = batteryThrowsOnce;
    if (once != null) {
      batteryThrowsOnce = null;
      throw once;
    }
    if (batteryThrows != null) throw batteryThrows!;
  }

  @override
  Future<void> getStrapName() async => events.add('getStrapName');

  @override
  Future<void> reconcileLiveStreams() async => events.add('reconcile');

  @override
  void setBackground(bool value) => events.add('setBackground:$value');

  @override
  Future<void> applyHighFreqWakeWindow({
    required bool enabled,
    required DateTime? targetWake,
    Duration duration = const Duration(seconds: 7200),
    int intervalSeconds = 180,
    String reason = 'wake_window',
  }) async {
    if (stamp != null) promptStamps.add(await stamp!());
    events.add('prompt:$enabled');
  }

  @override
  Future<void> requestHistorySync() async {
    events.add('requestHistorySync');
    if (requestSyncThrows != null) throw requestSyncThrows!;
  }

  @override
  Future<bool> requestForegroundSync() async {
    events.add('requestForegroundSync');
    return foregroundSyncAllowed;
  }

  @override
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) async {
    events.add('runSync:${timeout.inSeconds}');
    if (syncGate != null) await syncGate!.future;
    await onRunSync?.call();
    final r = syncScript.isEmpty ? SyncReport(3, 1, true) : syncScript.removeAt(0);
    if (r is SyncReport) return r;
    throw r;
  }

  @override
  Future<bool> probeLink({Duration timeout = const Duration(seconds: 5)}) async {
    events.add('probe');
    return probeAnswer;
  }

  @override
  Duration reconnectDelay(int attempt) {
    events.add('backoff:$attempt');
    return Duration.zero;
  }

  @override
  void markReconnecting() {
    events.add('markReconnecting');
    if (!link && state.connection == 'disconnected') _state('reconnecting');
  }

  @override
  void clearReconnecting() {
    events.add('clearReconnecting');
    if (state.connection == 'reconnecting') _state('disconnected');
  }

  @override
  bool refreshAutoReconnectPause() {
    events.add('refreshPause');
    return state.autoReconnectPaused;
  }

  @override
  Future<bool> waitForOsAutoConnect(
    String remoteId, {
    Duration wait = const Duration(minutes: 15),
    bool Function()? keepWaiting,
  }) async {
    events.add('osAutoConnect');
    return false;
  }
}

/// A fake engine wired into an AppState, paired to [kRemoteId]. Build inside
/// [SyncTimers.run] so its timers are the hand-fired ones.
class SyncRig {
  SyncRig({bool paired = true, this.timers}) {
    BandOwnership.resetForTest();
    BleEngine.resetBandClaimForTest();
    ResetGate.resetForTest();
    IosBleRestore.foregroundActive = false;
    engine = SyncFakeEngine();
    app = AppState.forTesting(engine: engine);
    engine.wire(app);
    if (paired) {
      app.paired = PairedDevice(kRemoteId, kSerial, generation: 'gen4');
    }
    engine.stamp = () async => (await jobTypes()).join(',');
    // The pass itself is never the subject of a sync-controller test: a run of the
    // scheduler lands here instead of in the derive engine.
    app.debugDeriveRun = deriveHook(calls: passes);
    app.debugRefreshActivityReviews = (_) async {
      reviewCalls++;
      return true;
    };
  }

  final SyncTimers? timers;
  late final SyncFakeEngine engine;
  late final AppState app;
  final passes = <bool>[];

  /// Every `refreshActivityReviews` attempt openSession and the resume paths
  /// launch, answered as done so no retry timer is armed.
  int reviewCalls = 0;
  bool _closed = false;
  final _openGates = <Completer<void>>[];

  /// Hold the next connect; [close] releases it if the test did not.
  Completer<void> holdConnect() {
    final g = Completer<void>();
    _openGates.add(g);
    engine.connectGate = g;
    return g;
  }


  /// The derive job types waiting in `compute_jobs` ('derive_light',
  /// 'derive_heavy'), as a sorted list.
  Future<List<String>> jobTypes() async {
    final rows = await LocalDb.computeJobs(state: 'queued');
    return [for (final r in rows) r['type'].toString()]..sort();
  }

  /// Forget every queued derive job, so the next trigger reads on its own.
  Future<void> clearJobs() async {
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
  }

  /// Wait (polling) until a derive job of [type] is queued; fails the test,
  /// listing the jobs that were queued, if it never is.
  Future<void> jobQueued(String type) async {
    final end = DateTime.now().add(const Duration(seconds: 6));
    while (true) {
      final queued = await jobTypes();
      if (queued.contains(type)) return;
      if (!DateTime.now().isBefore(end)) {
        throw TestFailure('derive job "$type" was never queued '
            '(queued: $queued)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// The derive scheduler has armed its settle timer (2 s after a heavy
  /// request, 8 s after a light one) and its change notifications have landed,
  /// so a tick count taken after this has no scheduler work still in flight.
  Future<void> settleDerive([Duration settle = const Duration(seconds: 2)]) async {
    await waitFor(() => timers!.activeOneShot(settle).isNotEmpty);
    await settleMs(40);
  }

  /// A connected, drained foreground session with the derive trigger it left
  /// fully settled.
  Future<void> openAndSettle() async {
    await app.openSession();
    await waitFor(() => engine.count('prompt') == 2);
    await jobQueued('derive_heavy');
    await settleDerive();
  }

  /// Wait (polling) until [ok].
  Future<void> waitFor(bool Function() ok,
      {Duration within = const Duration(seconds: 6)}) =>
      until(ok, within: within);

  /// True when every in-flight piece of work AppState started has finished:
  /// no connect / sync burst is parked and the app is not busy.
  Future<void> quiesce() async {
    await settleMs(60);
  }

  /// Let the fire-and-forget work land, then dispose (unless already).
  Future<void> close({bool dispose = true}) async {
    if (_closed) return;
    _closed = true;
    final sg = engine.syncGate;
    if (sg != null && !sg.isCompleted) sg.complete();
    final cg = _openGates;
    for (final g in cg) {
      if (!g.isCompleted) g.complete();
    }
    final held = engine.connectGate;
    if (held != null && !held.isCompleted) held.complete();
    await settleMs(250);
    if (dispose) app.dispose();
    await settleMs(60);
    BandOwnership.resetForTest();
    ResetGate.resetForTest();
    IosBleRestore.foregroundActive = false;
  }
}

/// A test body that runs inside a [SyncTimers] zone with a fresh rig.
void Function() syncCase(
  Future<void> Function(SyncRig rig, SyncTimers timers) body, {
  bool paired = true,
  bool dispose = true,
}) =>
    () async {
      final timers = SyncTimers();
      await timers.run(() async {
        final rig = SyncRig(paired: paired, timers: timers);
        try {
          await body(rig, timers);
        } finally {
          await rig.close(dispose: dispose);
        }
      });
    };

/// How many ticks (notifyListeners) [app] made across [body].
Future<int> ticksDuring(AppState app, Future<void> Function() body) async {
  final t = TickCounter(app);
  await body();
  t.stop();
  return t.ticks;
}
