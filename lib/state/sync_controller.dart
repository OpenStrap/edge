// Session and reconnect orchestration extracted from AppState.
//
// The engine owns transport, drain durability, and ACK ordering. This class
// only asks the existing engine to connect and sync. It has no AppState or UI
// dependency; its host supplies the narrow callbacks shared with other areas.
import 'dart:async';
import 'dart:io';

import '../ble/accessory_setup.dart';
import '../ble/ble_engine.dart';
import '../ble/ble_state.dart' show SyncActivityWindow;
import '../ble/ios_ble_restore.dart';
import '../compute/derive_scheduler.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../sync/band_ownership.dart';
import '../sync/edge_tracking.dart';
import '../sync/paired_device.dart';
import '../sync/reset_gate.dart';
import '../sync/shortcut_sync_task.dart';
import '../sync/sync_policy.dart'
    show
        ReconnectSupervisorAction,
        ResumeLinkAction,
        kIosBackgroundPromptIntervalSeconds,
        resumeLinkAction,
        superviseReconnect;

class SyncController {
  SyncController({
    required BleEngine Function() engine,
    required PairedDevice? Function() paired,
    required void Function(String) log,
    required void Function() notify,
    required bool Function() isDisposed,
    required bool Function() initialized,
    required String? Function() initError,
    required DeriveScheduler Function() deriveScheduler,
    required bool Function() phoneStepsEnabled,
    required Future<void> Function() syncPhoneSteps,
    required Future<void>? Function() ecgOnAppPaused,
    required void Function() nudgeLive,
    required Future<void> Function() recoverOrphanedLiveSession,
    required void Function() resetLivePedometer,
    required Future<void> Function() refreshHighFreqWakeWindow,
    required Future<void> Function() armNextAlarmOccurrence,
    required void Function() resetActivityReviewAttempts,
    required Future<void> Function() refreshActivityReviews,
  })  : _engine = engine,
        _paired = paired,
        _log = log,
        _notify = notify,
        _hostDisposed = isDisposed,
        _initialized = initialized,
        _initError = initError,
        _deriveScheduler = deriveScheduler,
        _phoneStepsEnabled = phoneStepsEnabled,
        _syncPhoneSteps = syncPhoneSteps,
        _ecgOnAppPaused = ecgOnAppPaused,
        _nudgeLive = nudgeLive,
        _recoverOrphanedLiveSession = recoverOrphanedLiveSession,
        _resetLivePedometer = resetLivePedometer,
        _refreshHighFreqWakeWindow = refreshHighFreqWakeWindow,
        _armNextAlarmOccurrence = armNextAlarmOccurrence,
        _resetActivityReviewAttempts = resetActivityReviewAttempts,
        _refreshActivityReviews = refreshActivityReviews;

  final BleEngine Function() _engine;
  BleEngine get engine => _engine();
  DeviceState get device => engine.state;
  final PairedDevice? Function() _paired;
  PairedDevice? get paired => _paired();
  final void Function(String) _log;
  final void Function() _notify;
  final bool Function() _hostDisposed;
  bool get _isDisposed => _hostDisposed();
  final bool Function() _initialized;
  final String? Function() _initError;
  final DeriveScheduler Function() _deriveScheduler;
  DeriveScheduler get _scheduler => _deriveScheduler();
  final bool Function() _phoneStepsEnabled;
  final Future<void> Function() _syncPhoneSteps;
  final Future<void>? Function() _ecgOnAppPaused;
  final void Function() _nudgeLive;
  final Future<void> Function() _recoverOrphanedLiveSession;
  final void Function() _resetLivePedometer;
  final Future<void> Function() _refreshHighFreqWakeWindow;
  final Future<void> Function() _armNextAlarmOccurrence;
  final void Function() _resetActivityReviewAttempts;
  final Future<void> Function() _refreshActivityReviews;

  int? lastRecTs;
  bool busy = false;
  bool _keepAlive = false;
  bool _reconnecting = false;
  DateTime? _attemptStartedAt;
  int _reconnectGeneration = 0;
  Timer? _reconnectSupervisor;
  Timer? _backfillTimer;
  BandLease? _foregroundLease;
  DateTime? _lastBackgroundHeavyAt;
  DateTime? _lastWakeWindowRefreshAt;
  bool background = false;

  static const Duration _backfillInterval = Duration(minutes: 10);

  /// Cadence of the reconnect supervisor. Cheap — the tick reads local flags
  /// and does nothing at all unless the app is paired, wants a link, and does
  /// not have one.
  ///
  /// Deliberately 1 min, not lengthened for battery: this supervisor is what
  /// restarts a dead link (#208), and stretching it trades a few free boolean
  /// reads inside an already-doze-exempt, link-holding process for up to 5
  /// minutes of lost sync after exactly the failure it exists to catch.
  static const Duration _reconnectSupervisorInterval = Duration(minutes: 1);

  /// Direct connect attempts before handing the pending connect to the OS
  /// bluetooth stack (Android autoConnect fallback) — see [_reconnect].
  static const int _directAttemptsBeforeOsFallback = 4;

  Future<void> pauseForBackground() async {
    background = true;
    // A WHOOP MG ECG reading stops on pause (the official screen does the
    // same on ON_PAUSE) — BEFORE the live-stream downgrade below, so its
    // cleanup triplet is on the wire first.
    await _ecgOnAppPaused();
    // Step the Android link down to a power-saving connection interval — see
    // `desiredLinkPriority` (issue #200).
    engine.setBackground(true);
    // Defer derivation while backgrounded — running the heavy derive pass on a
    // short background BLE wake gets the app killed (iOS CPU watchdog / jetsam).
    // Capture keeps running; queued derive jobs drain on foreground return.
    _scheduler.setBackground(true);
    // `background` is an owner input (foreground gait IMU, the gen4 bundle,
    // the iOS keepalive): let the engine step the streams to what the
    // remaining owners call for. See [_liveOwners].
    _nudgeLive();
    if (Platform.isAndroid) {
      // Android: ensure the Edge Tracking foreground service is up (idempotent) so the
      // process + live connection survive backgrounding. The service IS the keep-alive.
      EdgeTracking.start();
      return;
    }
    if (!Platform.isIOS) return;
    if (engine.isConnected) {
      IosBleRestore.foregroundActive =
          true; // "app owns the band" — don't let restore compete
      await IosBleRestore.setOwnsBand(true);
      // The live stream is off now (see _liveOwners); ask the band to prompt
      // us instead. Each prompt is one BLE notification → one wake → one
      // flash offload → suspend again. This is what keeps continuous capture
      // going without the 1 Hz stream.
      await _refreshHighFreqWakeWindow();
      _log(
        'Backgrounded — live stream off; band prompts every '
        '${kIosBackgroundPromptIntervalSeconds}s keep the offload going.',
      );
    } else {
      // No live connection to hold — fall back to the restore path so iOS relaunches us
      // when the band reappears.
      await _armRecovery();
      _log('Backgrounded — no live connection; armed iOS restore recovery');
    }
  }

  /// iOS recovery: release the band to the native restore central's no-timeout pending
  /// connect so the OS relaunches us when the band is reachable again.
  ///
  /// Uses [IosBleRestore.armRecoveryNow] — ONE native round trip — rather than a
  /// separately-awaited `setOwnsBand(false)` + `arm(...)` pair. The two-call form
  /// left a real window: if the process got suspended between the two awaits, we
  /// could land with `appOwnsBand == false` (app no longer holding the band) but
  /// nothing armed to replace it — i.e. NOTHING left watching for the band at all,
  /// which is indistinguishable from "never tries to reconnect" from the outside.
  Future<void> _armRecovery() async {
    if (!Platform.isIOS || paired == null) return;
    await IosBleRestore.armRecoveryNow(paired!.remoteId);
  }

  /// Start the level-triggered reconnect supervision (issue #208).
  ///
  /// Deliberately NOT tied to connection state: it must keep ticking precisely
  /// when everything else has given up. It is the backstop for the failure the
  /// issue describes — a reconnect loop abandoned by a throw (or wedged on an
  /// await that never returns), after which the app sits at 'disconnected' with
  /// no edge left to re-trigger it and, on Android, a foreground service making
  /// sure the process never restarts to clear the state.
  void _startReconnectSupervisor() {
    _reconnectSupervisor ??= Timer.periodic(
      _reconnectSupervisorInterval,
      (_) => _superviseReconnect(),
    );
  }

  /// Stop supervising. Called from `dispose` and from every path that stops
  /// wanting a link at all (unpair / endSession) — otherwise the tick outlives
  /// its purpose and keeps poking the engine every few minutes forever.
  void _stopReconnectSupervisor() {
    _reconnectSupervisor?.cancel();
    _reconnectSupervisor = null;
    // Cancelling the timer is not enough: a `_reconnect()` can still be parked
    // inside `waitForOsAutoConnect` for up to 15 minutes. Bumping the
    // generation retires it — it exits at its next loop check and its `finally`
    // leaves the flags alone. Without this, `endSession()` followed by a fresh
    // `openSession()` lets that zombie wake up and become the live loop,
    // reconnecting and re-running the whole post-connect block underneath the
    // new session.
    _reconnectGeneration++;
    _reconnecting = false;
    _attemptStartedAt = null;
    engine.clearReconnecting();
  }

  void _superviseReconnect() {
    if (_isDisposed) return;
    // Expire a bond-refusal pause whose cooldown has run out before deciding —
    // otherwise the supervisor faithfully observes a flag that nothing can ever
    // clear (issue #208).
    engine.refreshAutoReconnectPause();
    final action = superviseReconnect(
      paired: paired != null,
      keepAlive: _keepAlive,
      connected: engine.isConnected,
      loopRunning: _reconnecting,
      autoReconnectPaused: device.autoReconnectPaused,
      connectInFlight: busy,
      attemptRunningFor: _attemptStartedAt == null
          ? null
          : DateTime.now().difference(_attemptStartedAt!),
    );
    switch (action) {
      case ReconnectSupervisorAction.none:
        return;
      case ReconnectSupervisorAction.start:
        _log('[RECONNECT] supervisor: disconnected with no loop running — '
            'starting one.');
        unawaited(_reconnect());
      case ReconnectSupervisorAction.restartStale:
        _log('[RECONNECT] supervisor: the current attempt has been running '
            'since $_attemptStartedAt with no link — treating it as wedged '
            'and starting a fresh loop.');
        _reconnecting = false;
        _attemptStartedAt = null;
        unawaited(_reconnect());
    }
  }

  void _startBackfillTimer() {
    if (!_keepAlive || paired == null || !engine.isConnected) return;
    _backfillTimer ??= Timer.periodic(_backfillInterval, (_) {
      unawaited(_runPeriodicBackfill());
    });
  }

  void _stopBackfillTimer() {
    _backfillTimer?.cancel();
    _backfillTimer = null;
  }

  void debugArmBackfillTimer() {
    _backfillTimer ??= Timer.periodic(_backfillInterval, (_) {});
  }

  Future<void> _runPeriodicBackfill() async {
    if (!_keepAlive || paired == null || busy || _reconnecting) return;
    if (!engine.isConnected) return;
    // BACKGROUND: leave periodic offloads to the engine's own timer, which is
    // floored by `BackfillPolicy` (900 s + an empty-streak backoff). This timer
    // runs every 10 minutes and drives `requestHistorySync()`, whose `manual`
    // trigger is deliberately NEVER floored — so backgrounded, the two together
    // meant a radio-waking offload round roughly every ten minutes all day and
    // all night, bypassing the very rate limit written to prevent that (issue
    // #200). Foreground keeps the faster cadence: the user can see the data.
    if (background) {
      // The OFFLOAD is what we're skipping — the engine's own floored timer
      // owns that. The wake-window re-plan is NOT the engine's: nothing else
      // re-evaluates it on a stable connection, and it only flips on as the
      // 90-minute pre-wake window opens. Skipping it outright meant a band
      // that connected at 22:00 and stayed connected never armed high-frequency
      // sync for that night at all.
      //
      // Throttled to every 25 min while backgrounded (every third 10-min
      // tick): the plan's input (habitual wake median off 14 derived days)
      // changes at most once a day, and the window it arms is 90 min wide —
      // a ~30-min check still opens it with ≥60 min of lead. Re-running the
      // 14-day DB read + JSON decode every 10 min all night bought nothing.
      final lastRefresh = _lastWakeWindowRefreshAt;
      if (lastRefresh == null ||
          DateTime.now().difference(lastRefresh) >=
              const Duration(minutes: 25)) {
        _lastWakeWindowRefreshAt = DateTime.now();
        try {
          await _refreshHighFreqWakeWindow();
        } catch (e) {
          _log('Wake-window refresh failed: $e');
        }
      }
      _log('Periodic history refresh skipped — backgrounded; the engine\'s '
          'floored 15-min backfill owns the offload.');
      return;
    }
    if (_syncBurst != null) {
      _log('Periodic history refresh skipped — a sync burst is already running.');
      return;
    }
    try {
      await _refreshHighFreqWakeWindow();
      _log('Periodic history refresh — requesting another offload.');
      final report = await _kickSyncBurst(kickFirst: true);
      _log(
        'Periodic backlog check: ${report.records} records '
        '(${report.complete ? "complete" : "stopped early"}).',
      );
      if (report.records > 0) {
        _scheduler.markStoredData();
      }
    } catch (e) {
      _log('Periodic history refresh failed: $e');
    }
  }

  /// The in-flight historical burst, or null. SINGLE-FLIGHT: openSession and
  /// _reconnect fire the burst unawaited (live streams come up immediately);
  /// this guard makes sure a periodic/forced/manual resync can never start a
  /// SECOND overlapping burst against the same drain controller.
  Future<SyncReport>? _syncBurst;

  /// Start (or join) the historical sync burst. If a burst is already running,
  /// the existing one's future is returned — callers never overlap.
  Future<SyncReport> _kickSyncBurst({required bool kickFirst}) {
    final existing = _syncBurst;
    if (existing != null) return existing;
    final fut = _runSyncBurst(kickFirst: kickFirst).whenComplete(() {
      _syncBurst = null;
    });
    _syncBurst = fut;
    return fut;
  }

  Future<SyncReport> _runSyncBurst({
    required bool kickFirst,
    // A band that hasn't synced for days can hold a HUGE flash backlog (observed:
    // ~2 weeks / hundreds of thousands of records), and an RTC-loss can leave a
    // large frozen-timestamp block the drain must grind THROUGH to reach newer
    // data. 6 sessions wasn't enough to catch up; 20 lets a big backlog drain in
    // one foreground burst. Each session still early-exits on completion / no
    // real progress, so this only runs long when there's genuinely a lot to pull.
    int maxSessions = 20,
  }) async {
    // Totals for the whole burst; `complete` is the final session's.
    var total = SyncReport(0, 0, false);
    for (var i = 0; i < maxSessions && engine.isConnected; i++) {
      // Terminal `Stuck`: a burst failed validation
      // 15 times and the abort went out, so this connection's history is over.
      // The engine refuses every further drain trigger, but stopping here too
      // keeps the loop from spending its remaining sessions waiting out an idle
      // timeout apiece against a link that will never answer.
      if (engine.historyStuckThisSession) {
        _log(
          'Backfill stop — history is terminal (Stuck) for this connection; '
          'the band keeps its checkpoint until the next one.',
        );
        break;
      }
      // rec_ts_hw, not lastDecodedRecTs() — see the boot-time seed above for
      // why: an R10-lite-heavy backlog can genuinely advance without ever
      // touching decoded_onehz, and this "did we make progress" check must
      // not mistake that for a stuck drain (spin-guard/backlogRemains below
      // read frontierAfter too).
      final frontierBefore = await LocalDb.getCursorInt('rec_ts_hw');
      if (kickFirst || i > 0) {
        await engine.requestHistorySync();
      }
      kickFirst = false;
      final report = await engine.runSync(
        timeout: const Duration(seconds: 180),
      );
      final frontierAfter = await LocalDb.getCursorInt('rec_ts_hw');
      // Refresh the freshness signal the "last data" banner reads from EVERY
      // burst session, not just at app boot. `lastRecTs` was previously only
      // ever seeded in `_init()` — during a real historical drain, records go
      // through `_DrainController.onHistoricalRecord` → `onCommitBatch`
      // (bypassing `_onRecord`'s in-memory bump, which only fires on the rare
      // pre-drain-setup fallback path), so a session left open kept showing
      // "more than an hour behind" no matter how much fresh data actually
      // synced, until the app was fully restarted. Bump + notify here so the
      // UI reflects real progress as it happens, mid-burst.
      if (frontierAfter != null && frontierAfter > (lastRecTs ?? 0)) {
        lastRecTs = frontierAfter;
        _notify();
      }
      final strapNewest = engine.strapHistoryNewestTs;
      final frontierAdvanced =
          frontierAfter != null &&
          (frontierBefore == null || frontierAfter > frontierBefore);
      final backlogRemains =
          strapNewest != null &&
          frontierAfter != null &&
          (strapNewest - frontierAfter) > 300;
      total = SyncReport(
        total.records + report.records,
        total.batches + report.batches,
        report.complete,
      );
      await LocalDb.upsertSyncLedgerEntry(
        status: report.complete ? 'complete' : 'session_end',
        metaPatch: {
          'frontier_before_ts': frontierBefore,
          'frontier_after_ts': frontierAfter,
          'frontier_advanced': frontierAdvanced,
          'strap_history_newest_ts': strapNewest,
          'backlog_remains': backlogRemains,
          'session_index': i + 1,
          'max_sessions': maxSessions,
        },
      );
      if (report.batches == 0) {
        _log('Backfill stop — no batch ACKs; trim did not advance.');
        break;
      }
      if (report.complete && !backlogRemains) {
        _log('Backfill stop — history complete acknowledged by strap.');
        break;
      }
      if (!frontierAdvanced && !backlogRemains) {
        // Frontier didn't advance AND the strap reports nothing newer than what
        // we already hold → genuinely nothing more to pull (or a pure re-send).
        _log(
          'Backfill stop — frontier did not advance and no backlog remains '
          '(strap newest=$strapNewest, frontier=$frontierAfter).',
        );
        break;
      }
      if (!frontierAdvanced) {
        // Frontier stuck but the strap says it HAS newer data. This happens when
        // a stretch of flash carries STALE/duplicate timestamps — e.g. the band
        // rebooted, lost its RTC, and recorded for a while with a frozen clock
        // before SET_CLOCK re-latched. The rec_ts frontier can't advance across
        // that block, but the flash read cursor IS walking forward (batches>0),
        // so DON'T stop — drain through the stale block to reach the newer,
        // correctly-stamped records behind it. Bounded by maxSessions.
        _log(
          'Backfill continuation ${i + 1}/$maxSessions — frontier stuck on a '
          'stale-timestamp block but strap reports backlog '
          '(newest=$strapNewest > frontier=$frontierAfter); draining through.',
        );
        continue;
      }
      if (!backlogRemains) break;
      _log(
        'Backfill continuation ${i + 1}/$maxSessions — '
        'frontier still behind strap newest ($strapNewest > $frontierAfter).',
      );
    }
    return total;
  }

  /// Whether a link that still reports connected may be reused after the
  /// process was not watching it (foreground resume, BG-task wake).
  /// Fresh → yes. Quiet with a live stream armed → no: a stream that stopped
  /// is a dead link. Quiet with NO stream armed → ask the band
  /// (`probeLink`) rather than guess — an iOS process suspended between band
  /// prompts sees minutes of silence on a perfectly healthy link, and
  /// tearing it down on every foreground open would cost a reconnect and a
  /// full re-drain each time. ONE helper for both resume sites so the two
  /// cannot drift (AGENTS §4.7).
  Future<bool> _linkUsableAfterResume(String where) async {
    final quiet = engine.sinceLastRx.inSeconds;
    switch (resumeLinkAction(
      engine.sinceLastRx,
      liveStreamArmed: engine.liveEnabled,
    )) {
      case ResumeLinkAction.trust:
        return true;
      case ResumeLinkAction.reconnect:
        _log('$where: no BLE data for ${quiet}s with a live stream armed — '
            'stale link, reconnecting.');
        return false;
      case ResumeLinkAction.probe:
        final ok = await engine.probeLink();
        _log('$where: quiet link (${quiet}s, no stream armed) — probe '
            '${ok ? 'answered, reusing the link' : 'unanswered, reconnecting'}.');
        return ok;
    }
  }

  Future<void> openSession({bool foreground = true}) async {
    if (paired == null) return;
    // Returning to the foreground with the connection still alive (kept during
    // background): don't tear it down and reconnect — just reclaim ownership.
    final wasBackground = background;
    // Applied even when a session is already in flight: a background
    // Shortcut's openSession(foreground: false) can hold busy while the user
    // opens the app, and nothing else clears background. Back in the
    // foreground with an OS CPU/memory budget again — let the scheduler drain
    // any derive jobs that queued (durably) while backgrounded.
    if (foreground) {
      background = false;
      engine.setBackground(false);
      _scheduler.setBackground(false);
    }
    if (busy) {
      if (foreground && wasBackground) {
        _nudgeLive();
        unawaited(_refreshHighFreqWakeWindow());
      }
      return;
    }
    BandOwnership.markForegroundIntent(true);
    _log('[OWNERSHIP] foreground intent on (${BandOwnership.debugState})');
    // Coming back after hours (or days) suspended: re-read the phone's steps
    // for whatever day it is NOW.
    if (foreground && _phoneStepsEnabled()) {
      unawaited(_syncPhoneSteps());
    }
    // Fresh backoff budget per resume, so a chain that gave up earlier retries.
    _resetActivityReviewAttempts();
    unawaited(_refreshActivityReviews());
    if (foreground && wasBackground && engine.isConnected) {
      IosBleRestore.foregroundActive = true;
      await IosBleRestore.setOwnsBand(true);
      EdgeTracking.start(); // Android: keep the foreground service up (idempotent)
      // iOS can resume with the peripheral still flagged "connected" while its GATT
      // notifications died during suspension — UI shows connected but NO events arrive,
      // and only a kill+reopen (full reconnect) recovers. Trust DATA, not the flag: a
      // recent notification proves the link; a quiet link with no stream armed is
      // ASKED (probeLink — quiet is what a suspended process expects); a quiet link
      // that should have been streaming is torn down and falls through to a clean
      // reconnect, which re-subscribes (the only place setNotifyValue runs) and
      // drains the gap.
      if (await _linkUsableAfterResume('Resume')) {
        // Healthy link → fast reclaim. But the fast path skips the band polls the full
        // connect path runs, so the cached battery %/charging/strap-name go stale.
        // Re-poll them in the background so the UI stays current. Non-blocking.
        // (Alarm is NOT re-polled: the readback format is unconfirmed and the local
        // set value is authoritative — see the parked block in ble_engine._onDecoded.)
        unawaited(() async {
          try {
            await engine.getBattery();
            await engine.getStrapName();
          } catch (_) {}
        }());
        // `background` flipped: the foreground owners (gen4 bundle, a gait
        // workout's IMU) apply again.
        _nudgeLive();
        // …and the background band prompt is dropped (the smart-wake window,
        // if open, keeps its own).
        unawaited(_refreshHighFreqWakeWindow());
        // FOREGROUND CATCH-UP: R24 drains on a ~15-min timer while backgrounded,
        // so "last data" can lag up to 15 min behind a healthy link. The user
        // just opened the app — pull the flash backlog now. Floored at 90 s
        // (BackfillTrigger.foreground) so rapid app switching can't hammer the
        // strap. Non-blocking; single-flight via _kickSyncBurst.
        unawaited(foregroundCatchUp());
        _startBackfillTimer();
        return;
      }
      await engine.disconnect();
      // fall through to the full connect → subscribe → drain path below
    }
    _setBusy(true);
    _keepAlive = true;
    // From here on we WANT a link for the life of the process, so the level-
    // triggered supervisor runs from here on too (issue #208).
    _startReconnectSupervisor();
    try {
      // INSIDE the guard, and no `paired!`. This block used to sit BETWEEN
      // _setBusy(true) and the try, force-unwrapping `paired`. The resume path
      // above awaits (setOwnsBand / disconnect), so the user can tap Unpair in
      // that window — `paired!` then threw straight past the finally and `busy`
      // stayed true for the rest of the process, silently no-opping every
      // openSession()/syncNow() ("Sync now" dead until restart).
      final band = paired;
      if (band == null) {
        _log('Session start aborted — band was unpaired mid-resume.');
        return;
      }
      // Android: start the Edge Tracking foreground service so the live connection keeps
      // draining while backgrounded (Android kills background processes otherwise).
      EdgeTracking.start();
      // iOS: arm CoreBluetooth restoration so the band can relaunch us when terminated.
      // The foreground guard stops a wake from fighting this live session for the band.
      IosBleRestore.foregroundActive = true;
      IosBleRestore.arm(band.remoteId);
      _log('===== SESSION START =====');
      await _ensureForegroundLease();
      // connect() now subscribes → SET_CLOCK → INIT, so the historical offload is
      // ALREADY streaming the moment this returns.
      //
      // NOTE on side traffic: info polls (battery/name/high-frequency wake
      // config) and live-stream toggles ride the same link as the historical
      // burst. The per-revision packet accounting counts data-role frames only,
      // so these command exchanges don't perturb the burst packet counts.
      // No message is kept here on purpose: the engine already knows WHY the
      // link is not up (blocker, bond refusal, repair, quarantine…) and says so
      // through `engine.bandStatus`, which every surface renders. A second,
      // staler sentence stored beside it could only disagree with it.
      if (!await engine.connectToRemoteId(band.remoteId,
          generationHint: band.generation)) {
        _log('Session start: could not reach the band.');
        return;
      }
      await engine.getBattery();
      await engine.getStrapName(); // populate strap name for the Profile UI
      // Alarm is displayed from the locally-set/persisted value (authoritative);
      // the GET_ALARM readback is parked (unconfirmed format) — see ble_engine.
      // Arm the strap's high-frequency sync window when a wake alarm is near
      // (denser flushes → fresher overnight data ahead of the alarm).
      await _refreshHighFreqWakeWindow();
      // Compute + arm the next weekly-schedule occurrence on every successful
      // connect (Feature 1's arming engine) — see _armNextAlarmOccurrence.
      await _armNextAlarmOccurrence();
      _log('Listening — live streams per owners, historical burst runs concurrently.');
      // Enable live streams PROMPTLY, then let the historical burst run
      // CONCURRENTLY (unawaited, single-flight via _kickSyncBurst). History and
      // live records already share the one data subscription, so there is no
      // protocol reason to serialize them — and blocking openSession on the
      // burst pinned the UI "busy" for up to 20 sessions × 180 s (during
      // continuous listening, trickled records kept resetting the 60 s
      // no-progress timer, so bursts ran long). The drain's correctness is
      // untouched: commit-before-ACK and the HISTORY_COMPLETE bookkeeping all
      // live inside the engine regardless of who awaits the report.
      // Recover any steps orphaned by a killed process, and zero the counters
      // for this session, BEFORE live delivery starts. Arming live first
      // left a window where frames ingested during the
      // (awaited, I/O-bound) recovery were then wiped by _resetLivePedometer.
      await _recoverOrphanedLiveSession();
      _resetLivePedometer(); // fresh live step count for this connected session
      await engine.reconcileLiveStreams(); // the owners' intent, not full live
      unawaited(
        _kickSyncBurst(kickFirst: false).then((report) async {
          _log(
            'Backlog drained: ${report.records} records in ${report.batches} '
            'batches (${report.complete ? "complete" : "stopped early"}).',
          );
          // Re-evaluate the high-frequency wake window now the backlog landed.
          await _refreshHighFreqWakeWindow();
          // Re-arm the weekly schedule now the sync completed (Feature 1: "on
          // every successful connect AND after each sync").
          await _armNextAlarmOccurrence();
          // The whole backlog landed → heavy foreground finalize (full sleep
          // staging + 24-h spectra over every stale day).
          _scheduler.requestHeavy();
          _notify();
        }).catchError((Object e) {
          _log('Background sync burst failed: $e');
        }),
      );
      _startBackfillTimer();
    } catch (e) {
      _log('Session start failed: $e');
    } finally {
      if (!engine.isConnected || !_keepAlive) {
        _stopBackfillTimer();
        BandOwnership.markForegroundIntent(false);
        _log('[OWNERSHIP] foreground intent off (${BandOwnership.debugState})');
        _releaseForegroundLease();
      }
      // A background connect that failed (a Shortcut while the band is out of
      // range) left foregroundActive true with no link, and no later
      // background transition will clear it: every restore wake and BG-task
      // sync would skip until the user next opens the app. Hand the band back
      // to the restore path, same as the background cold-launch does.
      // Not after unpair/endSession dropped keep-alive mid-connect: that would
      // re-arm a pending connect for a session nobody wants.
      if (_keepAlive && background && !engine.isConnected) {
        await _armRecovery();
      }
      _setBusy(false);
    }
  }

  Future<void> _reconnect() async {
    if (_reconnecting || paired == null) return;
    // Bond-refusal give-up: a band that keeps refusing the bond will never accept
    // commands, so the auto-reconnect loop is paused (surfaced as needsRepairGuide).
    // A manual user connect / re-pair clears the pause on the next successful bond.
    if (device.autoReconnectPaused) {
      _log('Reconnect paused — repeated bond refusals; re-pair required.');
      return;
    }
    _reconnecting = true;
    _attemptStartedAt = DateTime.now();
    final generation = ++_reconnectGeneration;
    BandOwnership.markForegroundIntent(true);
    _log('[OWNERSHIP] reconnect intent on (${BandOwnership.debugState})');
    try {
      // Keep trying for as long as we still want the link (a session is active) —
      // a runner who left their phone behind can be out of range for an hour.
      // Bounded exponential backoff + jitter, owned by the transport's
      // ReconnectPolicy. The engine's single in-flight guard guarantees this loop
      // can never overlap a foreground connect on the same band.
      int attempt = 0;
      while (_keepAlive &&
          !engine.isConnected &&
          !device.autoReconnectPaused &&
          generation == _reconnectGeneration) {
        attempt++;
        _attemptStartedAt = DateTime.now();
        // Surface `reconnecting` while the loop backs off, so the UI shows a
        // connecting-style state instead of flat 'disconnected'.
        engine.markReconnecting();
        var connected = false;
        // PER-ATTEMPT containment (issue #208). Everything below can throw —
        // `_ensureForegroundLease`, `_claimBand`/teardown inside connect, the
        // post-connect stream setup. This whole loop used to sit inside ONE
        // try/catch, so a single throw abandoned it permanently: the engine
        // settles on 'disconnected', and the `connected → disconnected` edge
        // that is the loop's only trigger can never fire again. On Android the
        // foreground service then keeps the process alive forever, so nothing
        // ever cleared it — the band never reconnected until the user forgot
        // and re-paired it. A failed attempt is now just a failed attempt.
        try {
        // ANDROID OS-MANAGED FALLBACK: once direct attempts keep failing — or
        // while backgrounded, where the process can be frozen between our Dart
        // backoff timers — arm a flutter_blue_plus autoConnect pending connect
        // instead. The OS bluetooth stack then completes the link whenever the
        // band reappears, with no polling from us; the normal setup path runs
        // right after. iOS is excluded: the native restore central
        // (IosBleRestore, armed from _onEngineState) already holds a
        // no-timeout pending connect there, and a second competing pending
        // connect from Dart would fight it for the peripheral.
        final osPending = Platform.isAndroid &&
            (background || attempt > _directAttemptsBeforeOsFallback);
        if (osPending) {
          connected = await engine.waitForOsAutoConnect(
            paired!.remoteId,
            keepWaiting: () => _keepAlive && !engine.isConnected,
          );
          if (connected && _keepAlive) {
            // Mark band ownership before the actual GATT setup so a headless
            // wake can't fight this reconnect for the peripheral.
            await _ensureForegroundLease();
            connected = await engine.connectToRemoteId(paired!.remoteId,
              generationHint: paired!.generation);
          } else {
            connected = false;
          }
        } else {
          await Future.delayed(engine.reconnectDelay(attempt));
          if (!_keepAlive) break;
          await _ensureForegroundLease();
          connected = await engine.connectToRemoteId(paired!.remoteId,
              generationHint: paired!.generation);
        }
        if (connected) {
          // Reclaim the band from the iOS restore central so it stops competing.
          if (Platform.isIOS) {
            IosBleRestore.foregroundActive = true;
            await IosBleRestore.setOwnsBand(true);
          }
          EdgeTracking.start(); // ensure the Android foreground service is up too
          // Arm the strap's high-frequency sync window when a wake alarm is
          // near (denser flushes ahead of the alarm).
          await _refreshHighFreqWakeWindow();
          // Compute + arm the next weekly-schedule occurrence on every
          // successful (re)connect — see _armNextAlarmOccurrence.
          await _armNextAlarmOccurrence();
          // Live streams come up per the current owners (see _liveOwners:
          // backgrounded with no owner is OFF on both platforms);
          // the FULL drain (no short timeout — the ENTIRE offline backlog the
          // band flashed while out of range) runs concurrently, single-flight,
          // exactly as in openSession.
          // Reset BEFORE arming: an IMU ON step waits after the toggle, so
          // frames can land inside the await and would then be wiped.
          _resetLivePedometer();
          await engine.reconcileLiveStreams();
          await engine.getBattery();
          await engine.getStrapName();
          // the link can drop inside the awaits above. _onEngineState ignored
          // that drop because _reconnecting is still set, so nobody else arms
          // recovery or retries: do it here instead of breaking as connected.
          if (!engine.isConnected) {
            _log('Link dropped during reconnect setup — retrying.');
            if (background) await _armRecovery();
            continue;
          }
          // Alarm display comes from the locally-set/persisted value; the
          // GET_ALARM readback is parked (unconfirmed format) — see ble_engine.
          _log('Reconnected — live on; draining backlog in background.');
          unawaited(
            _kickSyncBurst(kickFirst: false).then((report) async {
              _log('Reconnect backlog drained: ${report.records} records.');
              // Re-evaluate the high-frequency wake window now the backlog
              // landed.
              await _refreshHighFreqWakeWindow();
              // Re-arm the weekly schedule now the sync completed (Feature 1:
              // "on every successful connect AND after each sync").
              await _armNextAlarmOccurrence();
              // Backlog (often an overnight gap) just landed → derive it.
              // Backgrounded, a flappy link (routine arm-swing dropouts)
              // reconnects many times an hour; each heavy pass spawns an
              // isolate and re-stages the pending days, so throttle heavy to
              // one per 30 min while backgrounded — the interim reconnects
              // still get a light pass, and the foreground return finalizes
              // with a real heavy anyway.
              final now = DateTime.now();
              final lastHeavy = _lastBackgroundHeavyAt;
              if (background &&
                  lastHeavy != null &&
                  now.difference(lastHeavy) < const Duration(minutes: 30)) {
                _scheduler.markStoredData();
              } else {
                if (background) _lastBackgroundHeavyAt = now;
                _scheduler.requestHeavy();
              }
              _notify();
            }).catchError((Object e) {
              _log('Reconnect sync burst failed: $e');
            }),
          );
          _startBackfillTimer();
            break;
          }
        } catch (e) {
          _log('Reconnect attempt $attempt failed: $e — retrying.');
        }
      }
    } catch (e) {
      _log('Reconnect loop aborted: $e');
    } finally {
      // this used to only check !_keepAlive, but the while loop above can
      // ALSO exit because device.autoReconnectPaused flipped true mid-loop
      // (bond-refusal give-up) while _keepAlive is still true - that path
      // left foreground intent stuck on forever, which blocks every
      // headless background-sync entry point (BandOwnership.tryAcquireHeadless
      // gates on this being off). same bug shape as the foregroundActive fix.
      if (generation != _reconnectGeneration) {
        // Superseded: the supervisor declared this loop wedged and started a
        // replacement, which now owns the flags and the band claim. Clearing
        // them here would clobber the live loop's state and let the supervisor
        // start a third one.
        _log('[RECONNECT] loop #$generation was superseded — leaving the '
            'replacement\'s state alone.');
      } else {
        if (!_keepAlive || device.autoReconnectPaused) {
          BandOwnership.markForegroundIntent(false);
          _log('[OWNERSHIP] reconnect intent off (${BandOwnership.debugState})');
        }
        _reconnecting = false;
        _attemptStartedAt = null;
        // If we gave up (keepAlive dropped / never connected), stop advertising
        // `reconnecting` — fall back to a truthful 'disconnected'. No-op when
        // the loop exited via a successful connect (phase is `listening`).
        engine.clearReconnecting();
      }
    }
  }

  /// Pull anything the band flashed that we don't have yet, over the CURRENT
  /// connection (no reconnect, no teardown). Used when a workout ends so a session
  /// that rode the live feed still gets its window backfilled from flash.
  Future<void> forceResync() async {
    if (!engine.isConnected) return;
    try {
      // Wait out any burst already in flight (it's pulling the same flash), then
      // re-trigger a fresh offload over the live connection (no reconnect) and
      // wait for it to fully hand over. Live streams stay on; no mode change.
      while (_syncBurst != null) {
        await _syncBurst;
      }
      await _kickSyncBurst(kickFirst: true);
      _notify();
      // A just-finished workout window landed from flash → derive it (light).
      _scheduler.markStoredData();
    } catch (e) {
      _log('Resync failed: $e');
    }
  }

  /// Foreground/BG-wake catch-up: pull the flash backlog over the CURRENT
  /// connection, floored at 90 s by [BackfillTrigger.foreground] so rapid app
  /// switching (or repeated OS wakes) can't hammer the strap. No-ops when
  /// disconnected, when a burst is already in flight, or when floored.
  ///
  /// This is the ONE call site an iOS BGAppRefreshTask/BGProcessingTask wake
  /// reaches when it fires while the foreground session still "owns" the band
  /// (`IosBgTask.foregroundPull = foregroundCatchUp`, wired below) — i.e. the
  /// zombie-link scenario `openSession` already guards against (see the
  /// comment there) can ALSO surface here, except this call site never gets a
  /// user-triggered resume to notice it. Apply the same `isLinkStale` bar: if
  /// the flag says connected but nothing has actually arrived recently, don't
  /// trust it — force a real teardown, which flows through `_onEngineState`'s
  /// disconnect branch and re-arms the OS-level (iOS restore central)
  /// recovery + the in-process reconnect loop exactly like a genuine link
  /// drop would. Without this, a zombie link that dies while the foreground
  /// app is backgrounded is invisible to every independent OS wake path —
  /// which is the bug this guards against ("strap disconnects and never
  /// tries to reconnect").
  Future<void> foregroundCatchUp() async {
    if (!engine.isConnected) return;
    if (!await _linkUsableAfterResume('Foreground catch-up')) {
      await engine.disconnect();
      return;
    }
    if (_syncBurst != null) return; // a burst is already pulling the same flash
    try {
      // The engine applies the 90 s foreground floor and (if allowed) re-arms
      // the drain + sends SEND_HISTORICAL_DATA itself — so join the offload
      // WITHOUT re-kicking (kickFirst: false).
      if (!await engine.requestForegroundSync()) return;
      final report = await _kickSyncBurst(kickFirst: false);
      if (report.records > 0) {
        _scheduler.markStoredData();
        _notify();
      }
      _log('Foreground catch-up: ${report.records} records pulled.');
    } catch (e) {
      _log('Foreground catch-up sync failed: $e');
    }
  }

  /// "Sync the band". On a link that is already up in the foreground,
  /// [openSession] just reuses it and joins an offload nobody asked the band
  /// for, so the tap pulled nothing: ask for one over the current link, then
  /// finalize whatever landed. Floored like [foregroundCatchUp]: on a band
  /// that just drained, a few quick taps would each come back empty, and the
  /// empty-sync detector reads three of those as a lost clock and backs the
  /// periodic pull off.
  Future<void> syncNow() async {
    if (background || !engine.isConnected) return openSession();
    try {
      final running = _syncBurst;
      if (running != null) {
        await running;
      } else if (await engine.requestForegroundSync()) {
        await _kickSyncBurst(kickFirst: false);
        _notify();
        _scheduler.markStoredData();
      }
    } catch (e) {
      _log('Sync failed: $e');
    }
    _scheduler.requestHeavy();
  }

  Future<SyncReport> syncForShortcut(ShortcutSyncTask task) async {
    if (ResetGate.active) throw StateError('data reset in progress');
    if (!_initialized()) task.update('starting');
    while (!_initialized() &&
        _initError() == null &&
        !_isDisposed &&
        !task.stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_initError() != null || _isDisposed) throw StateError('Edge is not ready');
    if (busy) task.update('waiting');
    while (busy && !task.stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (task.stopped) return SyncReport(0, 0, false);
    if (ResetGate.active || _isDisposed) throw StateError('Edge is not ready');
    if (engine.isConnected) {
      final usable = await _linkUsableAfterResume('Shortcut');
      if (task.stopped) return SyncReport(0, 0, false);
      if (ResetGate.active || _isDisposed) throw StateError('Edge is not ready');
      if (!usable) await engine.disconnect();
    }
    if (!engine.isConnected) {
      task.update('connecting');
      // A background Shortcut must not enable the UI's high-rate live streams.
      await openSession(foreground: !background);
    }
    if (task.stopped || !engine.isConnected) return SyncReport(0, 0, false);
    // The waits above left 'starting'/'waiting', which a deadline reads as
    // timedOut even though the burst is banking records.
    task.update('syncing');
    final burst = _kickSyncBurst(kickFirst: _syncBurst == null).then((report) {
      if (_isDisposed) return report;
      if (report.records > 0) _scheduler.markStoredData();
      _notify();
      return report;
    });
    // The burst is the app's and can run for many minutes; a stopped Shortcut
    // stops waiting so it releases the headless gate, not the transfer.
    return Future.any([
      burst,
      task.whenStopped.then((_) => SyncReport(0, 0, false)),
    ]);
  }

  Future<void> endSession() async {
    _keepAlive = false;
    BandOwnership.markForegroundIntent(false);
    _log('[OWNERSHIP] endSession intent off (${BandOwnership.debugState})');
    _stopBackfillTimer();
    _stopReconnectSupervisor();
    await engine.disconnect();
    _releaseForegroundLease();
  }

  Future<void> _ensureForegroundLease() async {
    if (_foregroundLease != null) return;
    final lease = await BandOwnership.acquireForeground();
    _foregroundLease = lease;
    _log(
      '[OWNERSHIP] acquired foreground lease=${lease.token} '
      '(${BandOwnership.debugState})',
    );
  }

  void _releaseForegroundLease() {
    final lease = _foregroundLease;
    if (lease == null) return;
    _log(
      '[OWNERSHIP] releasing foreground lease=${lease.token} '
      '(${BandOwnership.debugState})',
    );
    BandOwnership.release(lease);
    _foregroundLease = null;
  }

  void releaseForegroundLease() => _releaseForegroundLease();

  final SyncActivityWindow _syncActivity = SyncActivityWindow();

  /// Fires once when the activity window closes. `syncingNow` decays on
  /// wall-clock time, and nothing else necessarily notifies at that moment — a
  /// band that goes quiet after its last batch would leave the indicator lit
  /// until some unrelated state change happened along.
  Timer? _syncQuietTimer;

  /// Band data is arriving right now. Deliberately narrow: it is not "connected"
  /// and not "we would like to sync" — it is only true while records are
  /// actually landing, so a quiet indicator means a quiet link rather than a
  /// broken one.
  ///
  /// From TestFlight: "don't get to know if syncing is happening or not".
  bool get syncingNow =>
      _syncActivity.isActive(DateTime.now().millisecondsSinceEpoch);

  String get status => device.connection;

  DateTime? get lastDataAt => engine.lastRxAt;

  DateTime? get lastRecordAt => lastRecTs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastRecTs! * 1000);

  void markSyncActivity() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _syncActivity.mark(now);
    _syncQuietTimer?.cancel();
    _syncQuietTimer = Timer(
      Duration(milliseconds: _syncActivity.windowMs),
      () {
        _syncQuietTimer = null;
        _notify();
      },
    );
  }

  void _setBusy(bool b) {
    busy = b;
    _notify();
  }

  /// The background cold-launch connect that `_initSteps` runs when the process
  /// starts backgrounded (an iOS BLE-restore relaunch lands here, not in
  /// [openSession]).
  Future<void> startBackgroundSession() async {
    _keepAlive = true;
    _startReconnectSupervisor();
    if (Platform.isAndroid) EdgeTracking.start();
    if (Platform.isIOS) {
      IosBleRestore.foregroundActive = true;
      IosBleRestore.arm(paired!.remoteId);
    }
    _log('===== BACKGROUND SESSION START =====');
    try {
      await _ensureForegroundLease();
      if (await engine.connectToRemoteId(paired!.remoteId,
          generationHint: paired!.generation)) {
        // A process kill followed by an iOS BLE-restore relaunch lands
        // HERE, not in openSession() — this is the primary case the live
        // step checkpoint exists for, so recovery has to run on this path
        // too or those steps sit in prefs forever. Counters are fresh on a
        // cold launch, so there is nothing to double-count.
        await _recoverOrphanedLiveSession();
        _resetLivePedometer();
        // Apply the owners' intent to the fresh link: backgrounded owns
        // no live stream on either platform (see [_liveOwners]). On iOS
        // the band's HIGH_FREQ_SYNC prompt is what wakes the suspended
        // process, so it must be armed HERE too — this path is the
        // relaunch after a process kill, and with no stream and no
        // prompt nothing would ever schedule this process again.
        await engine.reconcileLiveStreams();
        await _refreshHighFreqWakeWindow();
        _startBackfillTimer();
      } else {
        // Connect attempt didn't succeed on this background cold-launch —
        // fall back to the recovery arm so `foregroundActive` resets and
        // native re-arms a fresh pending connect. Without this, a single
        // failed connect here permanently wedges every future
        // restore-wake for this process's lifetime: foregroundActive was
        // already set true above, and it's the master gate on the native
        // wake handler (ios_ble_restore.dart) — stuck true with no live
        // connection means every subsequent wake silently no-ops forever,
        // and the only way back is the user manually opening the app.
        _log('[init] bg connect returned false — arming recovery');
        await _armRecovery();
      }
    } catch (e) {
      _log('[init] bg connect failed: $e — arming recovery');
      await _armRecovery();
    }
  }

  /// The `connected -> disconnected` branch of `_onEngineState`: reconnect while
  /// a session is wanted, otherwise hand the foreground lease back.
  void onLinkDropped() {
    if (_keepAlive && paired != null && !_reconnecting && !device.autoReconnectPaused) {
      _log('Connection dropped — reconnecting…');
      _stopBackfillTimer();
      if (background) {
        // Backgrounded: arm the OS-durable restore path FIRST and wait for it to
        // confirm-armed before spending any Dart cycles on the in-process retry —
        // the restore central's no-timeout pending connect is the only piece of
        // this that survives a full process suspension, so it must land before we
        // risk `_reconnect()`'s own delay/backoff getting cut off mid-flight (that
        // loop needs the Dart run loop to keep being scheduled; the armed native
        // connect does not). Still fire-and-forget from the caller's perspective —
        // `_onEngineState` itself stays synchronous.
        unawaited(_armRecovery().then((_) => _reconnect()));
      } else {
        _reconnect();
      }
    } else {
      _releaseForegroundLease();
    }
  }

  Future<void> unpairSession() async {
    _keepAlive = false;
    BandOwnership.markForegroundIntent(false);
    _stopBackfillTimer();
    _stopReconnectSupervisor();
    IosBleRestore.foregroundActive = false;
    await EdgeTracking.stop();
    await IosBleRestore.disarm();
    // Deprovision the ASK accessory (iOS 18+) so a future pair re-shows the picker and
    // re-establishes iOS-26 relaunch eligibility. No-op on Android / iOS < 18.
    await AccessorySetup.removeAll();
    await engine.disconnect();
    _releaseForegroundLease();
  }

  /// AppState cancels this first in its dispose, before anything that can
  /// throw, as it did when it owned the timer.
  void cancelQuietTimer() {
    _syncQuietTimer?.cancel();
    _syncQuietTimer = null;
  }

  void dispose() {
    _stopBackfillTimer();
    _stopReconnectSupervisor();
  }
}
