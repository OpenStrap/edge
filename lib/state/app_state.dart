// AppState — the single ChangeNotifier the UI listens to. Orchestrates the BLE
// engine, local DB writes (raw-first), live telemetry, and the screen data SEAM.
//
// CLOUD EXCISED: there is no backend, no auth, no upload. Records are captured
// locally (raw_records / samples / events in lib/data/db.dart) and that is the
// system of record. Screens read through `repo` (a LocalRepository — the seam to
// the future on-device analytics re-layer); they no longer talk to a server.
//
// Onboarding gate (see app.dart):
//   not paired → Pairing (LOCAL device pref)
//   else       → main Shell (auto-connect saved band, drain, go live)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/widgets.dart';

import '../ai/ai_prefs.dart';
import '../ai/briefing.dart';
import '../ai/briefing_engine.dart';
import '../ai/nightly_sweep.dart';
import '../coach/coach_config.dart';
import '../models/app_status.dart';
import '../ble/accessory_setup.dart';
import '../ble/adapters/_registry.dart' show kBleHrs, kPolarPmd, kWhoopGen4;
import '../ble/adapters/host.dart' show BandHost;
import '../ble/adapters/whoop_gen4.dart' show WhoopFramedAdapter;
import '../ble/android_background.dart';
import '../ble/ble_engine.dart';
import '../ble/hrs_link.dart';
import '../ble/polar_pmd_link.dart';
import '../ble/live_step_runs.dart';
import '../ble/ble_state.dart'
    show AlarmConfirmation, AlarmEffect, LiveStreamOwners;
import '../ble/ios_ble_restore.dart';
import '../ble/session_link.dart' show SessionLink;
import '../cloud/companion_client.dart';
import '../compute/derivation_engine.dart';
import '../compute/derive_scheduler.dart';
import '../compute/inputs/canonical.dart'
    show flagOnOrPrimary, onWearableDaysChanged, refreshSessionSensorSources;
import '../compute/manual_session.dart' show supersededSuggestionIds;
import '../compute/hr_max.dart';
import '../compute/inputs/measurement_inputs.dart'
    show
        kWeighedAtMs,
        newestWeighing,
        profileWithWeighing,
        profileWithoutStaleWeighing;
import '../compute/profile.dart';
import '../data/day_label.dart';
import '../data/journal_fields.dart'
    show JournalMetricValue, kJournalFieldsByKey;
import '../data/med_store.dart' show MedDb, MedDef;
import '../data/auto_backup.dart'
    show BackupCadence, BackupOutcome, BackupFolder, AndroidBackupStorage, runBackup;
import '../stress/breath_phases.dart';
// `runBackupIfDue` is also the name of the AppState method below, so the pure
// scheduler is imported under an alias rather than shadowed by it.
import '../data/auto_backup.dart' as backup
    show runBackupIfDue, selectedBackupFolder, saveBackupFolder, deleteAutomaticBackups;
import 'alarm_schedule.dart';
import 'derive_coordinator.dart';
import 'gesture_controller.dart';
import 'live_stream_controller.dart';
import 'sync_controller.dart';
import 'workout_controller.dart';
import 'smart_wake.dart';
import 'prefs.dart';
import '../ble/adapters/signals.dart' show InputSignal;
import '../ui2/profile/devices.dart' show liveSources, rankSources;
import '../data/db.dart';
import '../ecg/ble_ecg_transport.dart';
import '../ecg/ecg_controller.dart';
import '../ecg/ecg_guard_store.dart';
import '../ecg/ecg_models.dart';
import '../ecg/ecg_recovery.dart';
import '../data/live_coverage_policy.dart';
import '../data/local_repository.dart';
import '../gps/gps_source.dart';
import '../gps/route_tracker.dart';
import '../gps/screen_wake.dart';
import '../data/local_repository_impl.dart';
import '../data/series_codec.dart';
import '../notify/battery_forecast.dart';
import '../notify/med_buzzer.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../gestures/gesture_settings.dart';
import '../health/auto_workout_import.dart';
import '../health/health_export.dart';
import '../health/phone_pedometer.dart';
import '../import/noop_import.dart';
import '../import/whoop_import.dart';
import '../platform/tasker_bridge.dart';
import '../data/models.dart';
import '../notify/device_alerts.dart';
import '../notify/notification_relay.dart';
import '../notify/notification_service.dart';
import '../notify/tap_router.dart';
import '../notify/water_buzzer.dart';
import '../sync/background_sync.dart' show checkSyncStaleness;
import '../sync/band_ownership.dart';
import '../sync/high_freq_wake_window.dart';
import '../sync/ios_bg_task.dart';
import '../sync/reset_gate.dart';
import '../sync/ios_shortcut_sync.dart';
import '../sync/shortcut_sync_task.dart';
import '../sync/paired_device.dart';
import '../sync/sync_policy.dart'
    show
        BandPromptPolicy,
        BandPromptRequest;
import '../sync/update_service.dart';
import '../telemetry/telemetry_service.dart';
import '../telemetry/health_uploader.dart';
import '../widget/widget_service.dart';
import '../sync/file_log.dart';
import 'breathing_controller.dart';
import 'package:uuid/uuid.dart';

export 'derive_coordinator.dart' show DeriveRunHook;
export 'workout_controller.dart' show LiveWorkoutState;

/// The onboarding/app gate states, in order. See [AppState.route].
/// Flow: loading → pairing → profile (only if incomplete) → shell. The profile
/// step collects age/weight/height/sex so the on-device analytics can
/// personalize (HRmax, calories, TRIMP); it's skipped once those are set.
///
/// [failed] is start-up itself failing — a state the app can BE in, with a name
/// and a retry, rather than the bare untimed spinner [loading] used to sit on
/// forever when anything in `_init` threw.
enum AppRoute { loading, failed, welcome, pairing, profile, shell }

/// The healed pairing to persist when the band reports [reportedSerial], or
/// null when nothing should change.
///
/// HEALS ONLY — it can never CREATE a pairing. The old inline form guarded on
/// `cleanSn != paired?.serial`, which is TRUE when `paired == null`, and then
/// rebuilt a PairedDevice from `paired?.remoteId ?? state.address`. BleEngine's
/// `_teardownSession` never clears `state.serial`/`state.address` (both are set
/// once in `_doConnect`), so a stale engine-state callback arriving AFTER the
/// user unpaired — e.g. the reconnect loop waking from its backoff delay and
/// calling `engine.clearReconnecting()` in its `finally`, which flips the phase
/// to idle and fires `onState` — silently re-created the pairing on disk and
/// bounced the app from Pairing straight back to the Shell. Unpair/sign-out was
/// undone with no user action at all.
PairedDevice? healedPairing(PairedDevice? current, String? reportedSerial) {
  if (current == null) return null; // nothing to heal — do NOT pair
  final clean = cleanDeviceLabel(reportedSerial);
  if (clean == null || clean == current.serial) return null;
  if (current.remoteId.isEmpty) return null;
  return PairedDevice(current.remoteId, clean, generation: current.generation);
}

/// Whether [dayId]'s night is settled enough to announce its recovery: today's
/// row goes through the same [overnightSettled] gate Home uses (#448), older
/// rows are past it.
@visibleForTesting
bool recoveryNightSettled({
  required String dayId,
  required Map<String, dynamic>? payload,
  required int dataEdgeSec,
  required int nowSec,
}) {
  if (dayId != todayLabel()) return true;
  // A no-sleep window's `value` is the string '—', not a Map.
  final sleep = payload?['sleep'];
  final window = sleep is Map ? sleep['window'] : null;
  final value = window is Map ? window['value'] : null;
  final offsetMs = value is Map ? value['offset_ms'] : null;
  return overnightSettled(
    sleepOffsetSec: offsetMs is num ? offsetMs ~/ 1000 : null,
    dataEdgeSec: dataEdgeSec,
    nowSec: nowSec,
  );
}

class AppState extends ChangeNotifier {
  late final BleEngine engine;

  /// The real constructor's [_init] future, so [checkPendingSiriRoute] can
  /// gate itself on it regardless of which call site reaches it first — a
  /// cold launch's very first `resumed` lifecycle callback (app.dart) can
  /// land before [_init] settles just as easily as the constructor's own
  /// unawaited call can, so the guard belongs HERE, once, not duplicated at
  /// every caller. Null under [AppState.forTesting], which never calls
  /// [_init] at all.
  Future<void>? _initDone;

  /// The primary band's route through [BandHost.commitNativeBatch] — see
  /// `WhoopFramedAdapter`'s own header for why `run()` stays unwired this
  /// wave. Constructed right after [engine] since [WhoopFramedAdapter]
  /// delegates to it.
  late final BandHost _bandHost;
  PairedDevice? paired;

  // ── WHOOP MG ECG ──────────────────────────────────────────────────────────
  // The controller owns one reading's lifecycle (lib/ecg/); this object only
  // hosts it, hands it the engine through the transport adapter, and folds
  // its "capturing" into the live-consumer and pause paths.
  final EcgGuardStore _ecgGuard = PrefsEcgGuardStore();
  BleEngineEcgTransport? _ecgTransport;
  EcgController? _ecg;

  /// The ECG owner. Built on first use in the real app; injectable (or
  /// absent) under [AppState.forTesting].
  EcgController get ecg => _ecg ??= _buildEcg();

  /// Whether the paired band was ever positively identified as a WHOOP MG
  /// (a revision-1 HELLO in the MAVERICK interval). Loaded at startup from
  /// the per-serial flag and set the moment an MG identifies itself; the
  /// Health ECG entry is gated on exactly this, so saved readings stay
  /// reachable while the band is away.
  bool pairedIsMaverick = false;

  EcgController _buildEcg() {
    final t = _ecgTransport ??= BleEngineEcgTransport(
      engine: engine,
      serialOf: () => paired?.serial ?? engine.state.serial,
      onRequestSync: () => engine.requestHistorySync(),
    );
    return EcgController(
      transport: t,
      guard: _ecgGuard,
      save: (r, p) => LocalDb.insertEcgReading(
        r.toRow(),
        [for (final x in p) EcgPacketCodec.toRow(x)],
      ),
      busyReason: () => activeWorkout != null
          ? 'workout'
          : (breathingActive || breathingWindowOpen)
              ? 'breathing'
              : null,
      holdScreen: ScreenWake.hold,
      releaseScreen: ScreenWake.releaseOwner,
      log: _log,
    );
  }

  /// READY-time recovery of a retained ECG guard — controller-free, before
  /// the engine publishes READY or claims history (see BleEngine.onReadyEcgRecovery).
  Future<void> _recoverEcgGuardOnReady(BleEngine e) async {
    final t = _ecgTransport ??= BleEngineEcgTransport(
      engine: e,
      serialOf: () => paired?.serial ?? e.state.serial,
      onRequestSync: () => engine.requestHistorySync(),
    );
    await ecgRecoverRetainedGuard(
      guard: _ecgGuard,
      serial: paired?.serial ?? e.state.serial,
      cleanup: t.recoveryCleanup,
      log: _log,
    );
  }

  /// SEAM: the screen data layer. Wired to [LocalRepositoryImpl] in the ctor —
  /// it reads the precomputed day_result / metric_series rows (ZERO heavy
  /// compute on read). Screens still guard on `repo == null` exactly as they did
  /// on `api`.
  LocalRepository? repo;

  /// The on-device compute orchestrator. Kicked (light) after every drain/flush
  /// completion, and (heavy) on foreground finalize + throttled reconnect
  /// backlogs. (The old WorkManager background heavy pass was removed — see the
  /// tombstone in lib/compute/background_derivation.dart.)
  // `background` is final on the engine and picks the concurrency + per-day
  // timeout, so seeding the scheduler alone left a headless first sweep running
  // the foreground budget. Late-initialized, so this reads the value both
  // constructors have already set by the time anything touches `_derive`.
  late final DerivationEngine _derive = DerivationEngine(
    log: _log,
    background: _background,
    offloadActive: () => _deriveScheduler.offloadActive,
  );
  late final DeriveCoordinator _deriveCoordinator = DeriveCoordinator(
    derive: () => _derive,
    profile: () => _profile,
    repo: () => repo,
    background: () => _background,
    disposed: () => _disposed,
    log: _log,
    notify: notifyListeners,
    refreshPhoneStepsToday: _refreshPhoneStepsToday,
    maybeNotifyRecoveryReady: _maybeNotifyRecoveryReady,
    runHealthExport: _runHealthExport,
    healthSyncEnabled: () => healthSyncEnabled,
    telemetryConsent: () => telemetryConsent,
    healthShareConsent: () => healthShareConsent,
    maybeReclaimDiskSpace: _maybeReclaimDiskSpace,
  );
  DeriveScheduler get _deriveScheduler => _deriveCoordinator.scheduler;

  late final LiveStreamController _liveStreamController =
      LiveStreamController(
    background: () => _background,
    activeWorkoutType: () => activeWorkout?.type,
    breathing: () => breathingActive || breathingWindowOpen,
    reconcileLiveStreams: () => engine.reconcileLiveStreams(),
  );

  late final WorkoutController _workoutController = WorkoutController(
    user: () => user,
    linkDeviceFamily: () => engine.linkDeviceFamily,
    clearRadioFallbackAndReconcile: () =>
        engine.clearRadioFallbackAndReconcile(),
    nudgeLive: _liveStreamController.nudge,
    setWorkoutActive: (active) => _deriveScheduler.setWorkoutActive(active),
    notify: notifyListeners,
    log: _log,
    liveHr: () => liveHr,
    liveRaw: () => _liveRaw,
    zoneAlertEnabled: () => zoneAlertEnabled,
    zoneAlertTargetZone: () => zoneAlertTargetZone,
    refreshNightlyRhr: _refreshNightlyRhr,
    restingHr: () => _restingHr,
    liveRestingHr: () => _liveRestingHr,
    observedCeilingBpm: () => _observedCeilingBpm,
    rhr28: () => _rhr28,
    bumpInsights: bumpInsights,
    forceResync: forceResync,
    dismissSupersededSuggestions: _dismissSupersededSuggestions,
    healthSyncEnabled: () => healthSyncEnabled,
    exportToHealth: (row) => _healthExport.exportWorkout(row),
    buzz: () => engine.buzz(),
    repo: () => repo,
    hostDisposed: () => _disposed,
    liveSensor: () {
      final from = liveHrDeviceId;
      if (from == null) return null;
      if (from == _hrsTraceId) return kBleHrs.id;
      if (from == _pmdTraceId) return kPolarPmd.id;
      return null;
    },
    requestHeavyDerive: () => _deriveScheduler.requestHeavy(),
  );

  late final BreathingController _breathingController = BreathingController(
    isConnected: () => isConnected,
    repo: () => repo,
    reconcileLiveStreams: () => engine.reconcileLiveStreams(),
    nudgeLive: _liveStreamController.nudge,
    buzzPattern: (pattern) => engine.buzzPattern(pattern),
    notify: notifyListeners,
  );

  /// Profile fed to the analytics (HRmax/calories/TRIMP personalization).
  Profile get _profile => Profile.fromMap(user);

  DeviceState get device => engine.state;
  final DeviceAlerts _deviceAlerts = DeviceAlerts();

  /// Band-gesture → action mapping (double-tap, etc.). Exposed for the settings UI.
  final GestureSettings gestureSettings = GestureSettings();
  late final GestureController _gestureController;

  /// Relay selected phone-app notifications to the strap as a buzz (Android only).
  /// Exposed for the settings UI; buzzes via the live BLE engine when connected.
  late final NotificationRelay notificationRelay = NotificationRelay(
    buzz: () => engine.buzz(),
    isConnected: () => engine.isConnected,
  );

  /// Fires a strap haptic at each water-reminder slot (best-effort, only when
  /// the band is connected). Armed at launch + whenever the toggle changes.
  late final WaterBuzzer _waterBuzzer = WaterBuzzer(
    buzz: () => engine.buzz(),
    isConnected: () => engine.isConnected,
  );

  /// Fires a strap haptic at each scheduled medication dose (best-effort, only
  /// when the band is connected). Same trade as [_waterBuzzer]: the OS
  /// notification is what actually reminds; the buzz is the bonus half that
  /// only works with a live link. Armed from `_ensureRemindersScheduled`,
  /// which is where the med schedule is already read for the OS slots — one
  /// read feeds both surfaces, so they cannot drift apart.
  late final MedBuzzer _medBuzzer = MedBuzzer(
    buzz: () => engine.buzz(),
    isConnected: () => engine.isConnected,
  );

  /// Tasker integration bridge — listens for Android broadcast intents from
  /// Tasker and buzzes the strap. Wired in the constructor.
  late final TaskerBridge taskerBridge = TaskerBridge(
    buzzPattern: (p) => engine.buzzPattern(p),
  );
  Sample? lastSynced;
  // REAL device time (epoch SECONDS) of the newest record we hold — the band's
  // own clock, NOT when the BLE frame arrived. During a flash backfill, frames
  // land "just now" but carry hours-old records; THIS is the timestamp the
  // "last data: …" indicator must show. Seeded from the DB at init, advanced as
  // records (drained + live) flow in.

  /// "Delete everything" is in progress — refuse every record ingest path.
  ///
  /// Now [ResetGate], not a private field: the headless drain
  /// (`runHeadlessSync`) builds its OWN BleEngine with callbacks wired straight
  /// to LocalDb and no AppState in scope, so a flag living here could never be
  /// consulted by it. Same isolate, so one static covers both — see
  /// reset_gate.dart for why that holds and what would break it.
  bool get _resetting => ResetGate.active;
  final List<String> logLines = [];
  String _prevConn = 'disconnected';
  // Last battery snapshot pushed to the Band Battery widget — so we only reload
  // the widget when pct/charging actually change (the engine-state hook fires
  // ~1 Hz on live HR). -2 = never pushed.
  int _widgetBattPct = -2;
  bool? _widgetBattCharging;
  String? _widgetBattName;
  int? _storedBatteryPct;

  /// Raw strapName last seen from the engine — change-gates the per-tick
  /// cleanDeviceLabel/Prefs work in [_onEngineState].
  String? _lastSeenStrapNameRaw;

  /// Band id last seen from the engine — change-gates the `device.adapter_id`
  /// write in [_onEngineState].
  String? _lastSeenGeneration;

  /// Minute-of-day last checked by [_maybeWarnOvernightBattery]'s clock
  /// pre-gate (it runs off the ~1 Hz engine-state pipeline).
  int? _lastForecastGateMin;

  /// Last time the overnight battery forecast ran. `_onEngineState` fires on
  /// every device-state update, and the forecast reads a few hundred rows, so
  /// it is throttled rather than run per tick. The user-visible fire-once
  /// guarantee comes from the dedupeKey, not from this.
  DateTime? _lastBatteryForecastAt;
  bool? _storedBatteryCharging;
  bool? _storedBatteryWristOn;
  bool initialized = false;

  late final SyncController _sync = SyncController(
    engine: () => engine,
    paired: () => paired,
    log: _log,
    notify: notifyListeners,
    isDisposed: () => _disposed,
    initialized: () => initialized,
    initError: () => initError,
    deriveScheduler: () => _deriveScheduler,
    phoneStepsEnabled: () => phoneStepsEnabled,
    syncPhoneSteps: () => syncPhoneSteps(),
    ecgOnAppPaused: () => _ecg?.onAppPaused(),
    nudgeLive: () => _liveStreamController.nudge(),
    recoverOrphanedLiveSession: _recoverOrphanedLiveSession,
    resetLivePedometer: _resetLivePedometer,
    refreshHighFreqWakeWindow: _refreshHighFreqWakeWindow,
    armNextAlarmOccurrence: _armNextAlarmOccurrence,
    resetActivityReviewAttempts: () =>
        _deriveCoordinator.resetActivityReviewAttempts(),
    refreshActivityReviews: () => refreshActivityReviews(retry: true),
  );

  int? get _lastRecTs => _sync.lastRecTs;
  set _lastRecTs(int? value) => _sync.lastRecTs = value;
  bool get _background => _sync.background;
  set _background(bool value) => _sync.background = value;
  bool get busy => _sync.busy;
  set busy(bool value) => _sync.busy = value;

  bool get isPaired => paired != null;

  /// Sensors paired ALONGSIDE the primary band — a chest strap, a ring.
  ///
  /// Raw `device` rows, minus the primary. Not `PairedDevice`: that type is the
  /// one band the offload engine drives, and it holds a serial, a trim cursor
  /// and a restore identity none of which a notify-class sensor has. These rows
  /// are the whole of what a sensor is (`id`, `adapter_id`, `remote_id`,
  /// `label`, `tier`), and `id` is the `device_id` its measurements carry.
  ///
  /// Read once at startup and after a pair or a forget — a `device` row only
  /// changes when the user changes it, so nothing polls this.
  List<Map<String, Object?>> _sensors = const [];
  List<Map<String, Object?>> get sensors => _sensors;

  /// Paired sensors behind a flag that is off (rule R6): listed, never
  /// ranked for a signal.
  Set<String> _flagOffSensorIds = const {};
  Set<String> get flagOffSensorIds => _flagOffSensorIds;

  StreamSubscription<String>? _deviceRowSub;

  /// Re-read the sensor rows. Call after pairing or forgetting one; also runs
  /// whenever a paired device's row changes (a sync, a battery report).
  Future<void> refreshSensors() async {
    _deviceRowSub ??=
        LocalDb.deviceRowChanged.stream.listen((_) => unawaited(refreshSensors()));
    final rows = await LocalDb.deviceRows();
    _sensors = [
      for (final r in rows)
        if (r['id'] != LocalDb.kPrimaryDeviceId) r,
    ];
    final ids = [for (final r in _sensors) r['id'] as String];
    final kept = (await flagOnOrPrimary(ids)).toSet();
    _flagOffSensorIds = {...ids}.difference(kept);
    // Same reason `_sensors` does not poll: a `signal_priority` row changes
    // only when the user changes it.
    _hrPriority =
        (await LocalDb.signalPriorities())[InputSignal.hr1Hz.name] ?? const [];
    notifyListeners();
  }

  // ── local profile (was server-side; now device-local) ───────────────────────
  // CLOUD EXCISED: the user's name/sex/age/height/weight + prefs (track_cycle,
  // step_goal, resting_hr…) used to live on the backend behind the JWT. They are
  // now a small LOCAL map persisted in shared_preferences. This is the on-device
  // profile the analytics re-layer will read for personalization. `null` until set.
  static const String _kProfile = 'local_profile_json';
  Map<String, dynamic>? user;

  // ── onboarding choice (new vs existing v2 user) ─────────────────────────────
  // 'new' | 'existing' | null (not chosen yet → the welcome screen shows). Once
  // set, the welcome screen never reappears (a returning paired user also skips
  // it). Persisted so a relaunch mid-onboarding doesn't re-prompt.
  static const String _kOnboard = 'onboarding_choice';
  String? _onboardChoice;
  String? get onboardChoice => _onboardChoice;

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfile);
    if (raw != null) {
      try {
        user = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        /* ignore corrupt blob */
      }
    }
    _onboardChoice = prefs.getString(_kOnboard);
    // The companion-URL override is loaded in _initCompanion (single source of
    // truth for every network call — announcements, OTA, telemetry, import).
    healthSyncEnabled = prefs.getBool(_kHealthSync) ?? false;
    phoneStepsEnabled = prefs.getBool(_kPhoneSteps) ?? false;
    // Steps only exist if a real pedometer measured them, so kick the phone
    // pull early. This is BEST-EFFORT and establishes no ordering: it is
    // unawaited, so a derive pass can read `live_coverage` while the sync is
    // still in flight and that day then derives without phone steps. It
    // self-heals on the next light pass.
    //
    // ROUTINE window only (2 days, ~48 platform round trips). Each hourly
    // bucket is one platform call, so the 7-day backfill window is up to 168 of
    // them; only today can still change, and only yesterday if the app did not
    // run then. The full window runs on the explicit gestures instead.
    if (phoneStepsEnabled) {
      unawaited(syncPhoneSteps());
      unawaited(_refreshPhoneStepsToday());
    }
    // Best-effort, no prompt: learn the current health-permission state so the
    // Profile toggle reflects reality on open.
    if (healthSyncEnabled) unawaited(checkHealth());
  }

  // ── companion URL (the ONE backend: announcements, OTA, telemetry, import) ──
  // Resolved by CompanionClient as: this override → build-time COMPANION_URL →
  // empty. Loaded into CompanionClient.overrideUrl in _initCompanion.

  /// The effective companion base URL (override or build-time), '' if unconfigured.
  String get companionUrl => CompanionClient.effectiveBase;

  /// True when a companion URL is configured (override or build-time).
  bool get companionConfigured =>
      CompanionClient.effectiveBase.trim().isNotEmpty;

  /// Set (or clear, with '') the runtime companion-URL override.
  Future<void> setCompanionUrl(String url) async {
    final v = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_kCompanionUrl);
      CompanionClient.overrideUrl = null;
    } else {
      await prefs.setString(_kCompanionUrl, v);
      CompanionClient.overrideUrl = v;
    }
    notifyListeners();
  }

  /// New-user path: record the choice and advance (welcome → pairing → profile).
  Future<void> chooseNewUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOnboard, 'new');
    _onboardChoice = 'new';
    notifyListeners();
  }

  /// Existing-user path: after a successful cloud import, persist the cloud
  /// profile + mark onboarding done so the gate advances to pairing → shell.
  /// [cloudProfile] is the mapped local-profile field set from CloudImporter.
  Future<void> completeCloudOnboard(Map<String, dynamic> cloudProfile) async {
    await updateProfile(cloudProfile); // persists + notifies
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOnboard, 'existing');
    _onboardChoice = 'existing';
    notifyListeners();
  }

  /// Mark onboarding complete after a file import (welcome → import flow). No-op
  /// if a choice was already made (a returning user importing from Profile). The
  /// route then advances past `welcome` to pairing → profile → shell.
  Future<void> completeImportOnboard() async {
    if (_onboardChoice != null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOnboard, 'imported');
    _onboardChoice = 'imported';
    notifyListeners();
  }

  // ── data imports (NOOP raw CSV / Edge backup / WHOOP export) ────────────────
  // Reachable from onboarding (welcome.dart) AND from Settings › Your data
  // (ui2/profile/data.dart) — both go through `runImport`, so there is one
  // router. Each runs against the engine + local profile, then notifies so
  // every screen re-reads the freshly imported days. None of them overwrites a
  // day the band measured (LocalDb.isMeasuredDay).

  /// NOOP raw-sensor CSV → FULL 1 Hz re-derivation (memory-bounded streaming).
  Future<int> importNoopCsv(
    String path, {
    void Function(int days)? onProgress,
  }) async {
    final res = await NoopImporter.importFile(
      path,
      _profile,
      _derive,
      onProgress: onProgress,
    );
    lastNoopImport = res;
    // The rows are durable — tell the screens that read them. Without this an
    // import landed days, sessions and journal rows into a database every live
    // tab had already finished reading, and the only way to see them was to
    // relaunch the app.
    bumpInsights();
    notifyListeners();
    return res.days;
  }

  /// The most recent NOOP import, so the import screen can report what the
  /// source cost us — days it presented out of order were folded in as context
  /// for the following day but never derived, and "imported N days" alone would
  /// hide that.
  NoopImportResult? lastNoopImport;

  /// The most recent vendor-CSV import, for the same reason [lastNoopImport]
  /// exists: the workouts it wrote and the days it refused to overwrite are
  /// not in the day count, and "0 days imported" alone reported an import that
  /// landed sixty sessions as a no-op.
  WhoopImportResult? lastWhoopImport;

  /// WHOOP export CSV(s) → derived-snapshot days (+ workouts). BETA.
  Future<int> importWhoopCsvs(
    List<String> paths, {
    void Function(int days)? onProgress,
  }) async {
    final res = await WhoopImporter.importFiles(
      paths,
      engine: _derive,
      profile: _profile,
      onProgress: onProgress,
    );
    lastWhoopImport = res;
    bumpInsights(); // see importNoopCsv — imported rows have to reach the tabs
    notifyListeners();
    return res.days;
  }

  /// Another device's exported OpenStrap DB (.db) → merge into the local store.
  /// Returns total rows copied across tables.
  /// Set when an import landed its rows but the rollup rebuild after it threw.
  /// The days are in the database and the summaries built from them are not, so
  /// reporting only the row count would claim a success the user does not have.
  String? importRollupError;

  /// Days of stored raw history (substrate archive buckets) the last backup
  /// import could NOT merge, because they are in a format this build does
  /// not read. Reported in the import report, never dropped silently.
  int lastImportArchiveSkipped = 0;

  /// Days of stored raw history the last backup import added or filled in.
  int lastImportArchiveRestored = 0;

  Future<int> importEdgeBackup(String path) async {
    importRollupError = null;
    lastImportArchiveSkipped = 0;
    lastImportArchiveRestored = 0;
    // Gzipped auto-backups (`.db.gz`) are inflated INSIDE importFromDbFile —
    // do not add it back here. Its inflate checks the gzip trailer, so a
    // truncated backup fails loudly; `gzip.decoder` returns partial output
    // without raising and would restore short while reporting success.
    final counts = await LocalDb.importFromDbFile(path);
    lastImportArchiveSkipped = counts['_substrate_archive_skipped'] ?? 0;
    lastImportArchiveRestored = counts['substrate_archive'] ?? 0;
    if (lastImportArchiveSkipped > 0) {
      _log(
        'import: $lastImportArchiveSkipped raw-history archive buckets are in '
        'a format this build cannot read; not imported',
      );
    }
    // Imported rows include derived day_result/metric_series → refresh rollups.
    try {
      await refreshActivityReviews();
      await _derive.finalizeImport(_profile);
      await LocalDb.refreshComputeFreshness();
    } catch (e) {
      importRollupError = '$e';
    }
    bumpInsights(); // see importNoopCsv — imported rows have to reach the tabs
    notifyListeners();
    // DAYS, not rows. `_days` is a distinct day_id count taken from the source
    // file; the caller reports "N days imported" and a row total is not that.
    return counts['_days'] ?? 0;
  }

  // ── platform health export (Apple Health / Health Connect) ──────────────────
  // The shared instance, not a private one: the coach and the log-workout
  // sheet reach the exporter through `HealthExporter.exportWorkoutId` with no
  // AppState in hand, and two exporters would mean two `Health()` handles and
  // two Health-Connect availability probes doing the same work.
  final HealthExporter _healthExport = HealthExporter.shared;
  final HealthExportSingleFlight _healthExportSingleFlight =
      HealthExportSingleFlight();
  HealthLinkState healthState = HealthLinkState.unknown;
  bool healthSyncEnabled = false;
  // Shared with `HealthExporter.exportWorkoutId`, which has to honour this
  // switch from callers that never see this class.
  static const String _kHealthSync = kHealthSyncPref;

  /// "Apple Health" (iOS) or "Health Connect" (Android).
  String get healthStoreName => HealthExporter.storeName;
  bool get healthIsApple => HealthExporter.isApple;

  /// Check current permission state WITHOUT prompting (startup-safe).
  Future<void> checkHealth() async {
    healthState = await _healthExport.check();
    notifyListeners();
  }

  /// Prompt for write access (user gesture). On grant + enabled, kick a sync.
  Future<void> requestHealth() async {
    healthState = await _healthExport.request();
    notifyListeners();
    if (healthState == HealthLinkState.ready && healthSyncEnabled) {
      unawaited(healthSyncNow());
    }
  }

  /// Android: open the Play Store to install/update Health Connect.
  Future<void> installHealthConnect() => _healthExport.install();

  /// Android: open the Health Connect app/settings so the user can enable our
  /// per-app access manually. Re-checks state when they come back.
  Future<void> openHealthConnect() async {
    await _healthExport.openSettings();
  }

  /// Toggle continuous export. Enabling requests permission + does a first sync.
  Future<void> setHealthSync(bool on) async {
    healthSyncEnabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHealthSync, on);
    notifyListeners();
    if (on) {
      await requestHealth();
      if (healthState == HealthLinkState.ready) unawaited(healthSyncNow());
    }
  }

  /// Export all finalized-but-unexported days now. Returns days written.
  Future<int> healthSyncNow() async {
    // Both halves of this seam matter and neither subsumes the other: the
    // export runs through the single-flight guard (main), and the phone-steps
    // sync stays gated on the user's preference (this branch).
    final n = await _runHealthExport(forceRetry: true);
    // Gate on the user's own preference. `disablePhoneSteps` deliberately does
    // NOT revoke the platform permission (that is the user's to do in
    // Settings), so an unconditional sync here would write phone rows straight
    // back after the user turned the feature off — and the ladder ranks a
    // phone span above any band span that does not look like gait, so those
    // rows would go on taking steps off the band. The exact outcome
    // `disablePhoneSteps` exists to prevent.
    // An explicit health sync is a user gesture — take the full window.
    if (phoneStepsEnabled) {
      unawaited(syncPhoneSteps(days: PhonePedometer.fullSyncDays));
    }
    return n;
  }

  Future<int> _runHealthExport({bool forceRetry = false}) =>
      _healthExportSingleFlight.run(
        () => _healthExport.exportAll(forceRetry: forceRetry),
      );

  // ── phone pedometer — the fallback tier, and the only 24/7 one ────────────
  // Not "the only real source": the strap's 100 Hz counter is measured and
  // ranks above it, but only inside a gait workout, and the gen5 on-chip
  // counter only exists on a gen5. Both are windows; this is the one that
  // covers a whole day.
  final PhonePedometer _phonePedometer = PhonePedometer();
  bool phoneStepsEnabled = false;
  static const String _kPhoneSteps = 'phone_steps';

  /// Ask the OS for this phone's own step SENSOR (user gesture).
  ///
  /// `CMPedometer` on iOS, `Sensor.TYPE_STEP_COUNTER` on Android, read straight
  /// off the device — see [PhonePedometer] for why a pocket beats a wrist here.
  /// It is the FALLBACK tier of the step ladder: our 100 Hz strap counter only
  /// runs inside a gait workout and the gen5 on-chip counter only exists on a
  /// gen5, so with a WHOOP 4 and this off a user gets steps for the workout and
  /// nothing for the other twenty-odd hours.
  ///
  /// NOT the health store, and nobody may "restore" that. This used to read
  /// `HealthDataType.STEPS`, which is a multi-writer aggregate any app can
  /// write into (an `HKStatisticsQuery` sum on iOS, a `StepsRecord` aggregate
  /// on Android) — so "real pedometer measurements only" was not enforceable
  /// while we read it. The sensor is the one writer we actually want. Nothing
  /// is uploaded and nothing is written back.
  Future<bool> requestPhoneSteps() async {
    final ok = await _phonePedometer.requestPermission();
    // PERSIST BEFORE mutating in-memory state. Setting the field first and
    // then awaiting the write leaves the two disagreeing if the write throws:
    // the toggle reads ON for this run and OFF on the next launch, and the
    // syncs below would bank phone rows the restored state says the user never
    // enabled — rows that then keep overriding the band, since `disablePhone
    // Steps` is the only thing that clears them and the user never sees the
    // toggle on to turn it off.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPhoneSteps, ok);
    phoneStepsEnabled = ok;
    notifyListeners();
    // The user just asked for this, so pull the full backfill window rather
    // than the cheap routine one — and then RE-DERIVE, symmetric with
    // [disablePhoneSteps]. Banking rows into `live_coverage` changes nothing a
    // screen can see: they all read scalars persisted in `day_result`/
    // `metric_series`, and the only automatic derive is drain-triggered. Grant
    // the permission with the band not connected and, without this, the step
    // tile keeps showing a dash indefinitely — indistinguishable from the
    // feature not working.
    if (ok) {
      unawaited(() async {
        await syncPhoneSteps(days: PhonePedometer.fullSyncDays);
        // Waits out any derive already running (see _reanalyzeForOverride).
        await _reanalyzeForOverride();
      }());
    }
    return ok;
  }

  /// Turn phone steps off and DROP the counts we pulled.
  ///
  /// Leaving the rows behind would keep serving phone-sourced steps from a
  /// source the user just switched off, and the ladder in `resolveDaySteps`
  /// ranks a phone span ABOVE any band span that does not look like gait — so
  /// a stale phone row would go on taking steps off the band indefinitely.
  /// Revoking the OS motion permission is the user's to do in Settings; all we
  /// can do is stop reading and forget what we read.
  ///
  /// Clearing `live_coverage` only changes what FUTURE derives compute — the
  /// screens read scalars persisted in `day_result`/`metric_series`. So this
  /// also re-derives, exactly as `setSleepOverride` does for the equivalent
  /// case; without it the user turns the toggle off and keeps seeing
  /// phone-sourced counts.
  ///
  /// The re-derive is bounded: its scope is days that still hold raw
  /// (`rawRetentionDays`), not the whole history. Older days keep their
  /// phone-sourced value permanently — there is no substrate left to recompute
  /// them from, which is the same limit every other version bump has.
  Future<void> disablePhoneSteps() async {
    // Persist first, for the reason in [requestPhoneSteps].
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPhoneSteps, false);
    phoneStepsEnabled = false;
    phoneStepsLastSyncedDays = null;
    phoneStepsLastTotal = null;
    phoneStepsToday = 0;
    _phoneStepsDay = null;
    // Stop the sensor BEFORE dropping the rows: on Android the counter keeps
    // accumulating into its own on-device store, so clearing `live_coverage`
    // alone would leave this app counting a user who just asked it to stop.
    await _phonePedometer.stop();
    try {
      await LocalDb.clearPhoneCoverage();
    } catch (e) {
      debugPrint('[phone_steps] clear: $e');
    }
    notifyListeners();
    unawaited(_reanalyzeForOverride());
  }

  /// Days successfully read on the last phone-step sync, and the total banked.
  ///
  /// Surfaced in Profile because the failure mode is otherwise INVISIBLE: on
  /// iOS `requestAuthorization` returns true even when the user denies READ
  /// (HealthKit hides read denial by design), so the toggle sits on, every read
  /// comes back empty, and no step count ever appears with nothing to act on.
  int? phoneStepsLastSyncedDays;
  int? phoneStepsLastTotal;

  /// Steps the PHONE has banked for today, mirroring `liveStepsForDay`'s own
  /// source rule (phone wins only when it actually has data).
  ///
  /// No screen reads this today. It fed `todayStepsFromPhone`, the phone-vs-band
  /// precedence gate — deleted with [liveSteps], because no screen ever added a
  /// live band count on top of the day total, so there was never a double-count
  /// for it to arbitrate. The precedence rule that DOES matter is
  /// `LocalDb.liveStepsForDay`'s, which the derivation reads.
  int phoneStepsToday = 0;

  /// Which local day [phoneStepsToday] was read for. The cache is worthless
  /// past midnight, and a process here routinely lives for days (Android
  /// foreground service, iOS suspend/resume), so a day-less cache would hold
  /// yesterday's answer through the whole of today.
  String? _phoneStepsDay;

  Future<void> _refreshPhoneStepsToday() async {
    if (!phoneStepsEnabled) return;
    try {
      final day = todayLabel();
      final n = await LocalDb.phoneStepsForDay(day);
      if (n != phoneStepsToday || day != _phoneStepsDay) {
        phoneStepsToday = n;
        _phoneStepsDay = day;
        notifyListeners();
      }
    } catch (_) {
      /* best-effort — the gate just falls back to showing band live steps */
    }
  }

  /// Pull the last [days] days of phone step counts into `live_coverage`.
  ///
  /// Idempotent (delete-then-insert per day, scoped to the phone source), so
  /// calling it repeatedly — on launch, after a sync, from a background pass —
  /// can never accumulate. Best-effort; never throws.
  Future<int> syncPhoneSteps({
    int days = PhonePedometer.routineSyncDays,
  }) async {
    try {
      final r = await _phonePedometer.syncRecent(days: days);
      phoneStepsLastSyncedDays = r.daysRead;
      phoneStepsLastTotal = r.totalSteps;
      await _refreshPhoneStepsToday();
      notifyListeners();
      return r.daysRead;
    } catch (e) {
      debugPrint('[phone_steps] sync: $e');
      return 0;
    }
  }

  /// Session-triggered Health export for one just-finished workout (issue
  /// #130) — for callers outside this class that write a `sessions` row
  /// directly rather than going through [stopWorkout]. See
  /// [HealthExporter.exportWorkout] for why this can't just wait for the next
  /// day export. Best-effort, never throws.
  ///
  /// This used to take the row, and its only two call sites went out with the
  /// old `lib/ui/workouts` — leaving it callerless while `logManualWorkout`
  /// paths (the coach, the log-workout sheet) exported nothing at all. Those
  /// callers hold the `workout_id` the repo hands back, not the row, and most
  /// of them have no AppState to reach for either, so the seam that matters is
  /// [HealthExporter.exportWorkoutId] and this just forwards to it.
  Future<bool> exportWorkoutToHealth(String? sessionId) =>
      _workoutController.exportWorkoutToHealth(sessionId);

  // ── companion: anonymous telemetry + health-data contribution ────────────────
  // All anchored to a stable anonymous install id (no account). Two SEPARATE
  // consent scopes, BOTH DEFAULTING OFF, both switchable in Settings › Privacy
  // (ui2/profile/settings.dart). There is no consent screen in onboarding: the
  // one the old `lib/ui` had was deleted with that package, and for a while
  // afterwards `setHealthShareConsent` had no caller anywhere — an install
  // carrying `consent_health_data = true` from before the rebuild kept
  // uploading its whole database with no way to stop it. Nothing here may be
  // enabled except by an explicit tap; `consentChosen` records only that the
  // user has answered at least once.
  static const String _kDeviceId = 'install_device_id';
  static const String _kTelemetryConsent = 'consent_telemetry';
  static const String _kHealthShareConsent = 'consent_health_data';
  static const String _kConsentChosen = 'consent_chosen';
  static const String _kCompanionUrl = 'companion_url';

  /// Stable anonymous install id — the device_id every companion call is keyed on.
  String deviceId = '';
  bool telemetryConsent = false;
  bool healthShareConsent = false;

  /// Whether the user has been through the enrollment consent screen. Until then
  /// the toggles default ON there; an install that never saw the screen keeps the
  /// safe OFF default (we do NOT silently enable for someone who never chose).
  bool consentChosen = false;
  int termsVersion = 1; // current Terms version (refreshed from /app/status)

  /// One-time wiring of the companion layer: install id, consent flags, the band
  /// snapshot hook, and the persisted-outbox replay. Runs OFF the startup critical
  /// path (fire-and-forget, after `initialized`) and is fully guarded — it must
  /// NEVER block or break app boot.
  Future<void> _initCompanion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString(_kDeviceId) ?? '';
      if (deviceId.isEmpty) {
        deviceId = const Uuid().v4();
        await prefs.setString(_kDeviceId, deviceId);
      }
      telemetryConsent = prefs.getBool(_kTelemetryConsent) ?? false;
      healthShareConsent = prefs.getBool(_kHealthShareConsent) ?? false;
      consentChosen = prefs.getBool(_kConsentChosen) ?? false;
      CompanionClient.overrideUrl = prefs.getString(_kCompanionUrl);

      final t = TelemetryService.instance;
      t.deviceId = deviceId;
      // The ONE point where Firebase collection may be switched on, and only
      // with the user's AFFIRMATIVELY LOADED consent (the prefs read above).
      // Until this runs, TelemetryService.enforceCollectionOffUntilConsent()
      // (called from main after Firebase.initializeApp) keeps every SDK off.
      t.applyConsent(telemetryConsent);
      t.consentVersion = termsVersion;
      t.bandSnapshot = _bandSnapshot;
      HealthUploader.instance.deviceId = deviceId;
      HealthUploader.instance.consentVersion = termsVersion;
      notifyListeners(); // reflect loaded consent flags in the UI

      await t.load();
      if (telemetryConsent) unawaited(t.flush()); // ship last session's records

      // Learn the live Terms version — best-effort, and ONLY for an install
      // that is actually sending something. The version exists to stamp the
      // consent records we post; someone who has consented to nothing has
      // nothing to stamp, so fetching it was a launch-time call to the
      // operator's server on behalf of a user who had opted out of all of it.
      if (telemetryConsent || healthShareConsent) {
        final status = await CompanionClient.getStatus();
        final v = status?['terms']?['version'];
        if (v is int && v > 0) {
          termsVersion = v;
          t.consentVersion = v;
          HealthUploader.instance.consentVersion = v;
        }
      }
    } catch (e) {
      _log('[companion] init failed (non-fatal): $e');
    }
  }

  /// The live band fields folded into each telemetry batch's device snapshot.
  ///
  /// NOT the band's serial. It used to be, and a hardware serial is a stable
  /// cross-install device identifier — outside what the privacy policy
  /// enumerates as the payload ("crash reports, basic device info, coarse
  /// performance timing"), and not something a crash report has ever needed.
  /// Nothing here distinguishes one band from another.
  Map<String, dynamic> _bandSnapshot() {
    final s = engine.state;
    return {
      if (s.batteryPct != null) 'band_battery_pct': s.batteryPct!.round(),
      'ble_state': s.connection,
    };
  }

  /// Toggle anonymous diagnostics (telemetry). Persists, records the consent on the
  /// server, and flips the transmission gate.
  Future<void> setTelemetryConsent(bool on) async {
    telemetryConsent = on;
    consentChosen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTelemetryConsent, on);
    await prefs.setBool(_kConsentChosen, true);
    TelemetryService.instance.applyConsent(on);
    notifyListeners();
    unawaited(
      CompanionClient.postConsent(
        deviceId: deviceId,
        scope: 'telemetry',
        granted: on,
        termsVersion: termsVersion,
      ),
    );
    if (on) unawaited(TelemetryService.instance.flush());
  }

  /// Toggle full-.db health-data contribution. Persists + records server consent.
  Future<void> setHealthShareConsent(bool on) async {
    healthShareConsent = on;
    consentChosen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHealthShareConsent, on);
    await prefs.setBool(_kConsentChosen, true);
    notifyListeners();
    unawaited(
      CompanionClient.postConsent(
        deviceId: deviceId,
        scope: 'health_data',
        granted: on,
        termsVersion: termsVersion,
      ),
    );
  }

  /// Adopts the newest weighing a paired scale banked as the profile's weight
  /// when it is newer than the last one adopted ([profileWithWeighing]) and
  /// near the current weight (another person's is not ours), then re-derives
  /// the open days from the weighing's day on: calories, BMR and the strain
  /// anchors read the weight at derive time.
  ///
  /// First, a weighing adopted from a scale whose flag is now off is undone
  /// (rule R6, [profileWithoutStaleWeighing]): the weight goes back to the
  /// one it replaced.
  Future<void> adoptWeighing() async {
    final staleAtMs = (user?[kWeighedAtMs] as num?)?.toInt();
    final reverted = await profileWithoutStaleWeighing(user);
    if (reverted != null) await updateProfile(reverted);
    final w = await newestWeighing(near: user?['weight_kg'] as num?);
    final next = w == null ? null : profileWithWeighing(user, w);
    if (next != null) await updateProfile(next);
    final fromMs = [
      if (reverted != null && staleAtMs != null) staleAtMs,
      if (next != null) w!.atMs,
    ];
    if (fromMs.isEmpty) return;
    final from = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(fromMs.reduce(math.min)));
    await rederiveDays({
      for (final r in await LocalDb.recentDayResultsMeta(14))
        if (r['finalized'] != 1 &&
            (r['day_id'] as String).compareTo(from) >= 0)
          r['day_id'] as String,
    });
  }

  /// Merge + persist local profile fields. Returns the updated map. Replaces the
  /// old cloud PATCH /profile (no network).
  Future<Map<String, dynamic>> updateProfile(
    Map<String, dynamic> fields,
  ) async {
    user = {...?user, ...fields};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProfile, jsonEncode(user));
    notifyListeners();
    return user!;
  }

  // ── automatic backup ────────────────────────────────────────────────────────

  BackupCadence get backupCadence =>
      BackupCadence.fromName(Prefs.getString(Prefs.backupCadence, ''));

  BackupFolder? get backupFolder => backup.selectedBackupFolder;

  String? get lastBackupError {
    final error = Prefs.getString(Prefs.backupLastError, '');
    return error.isEmpty ? null : error;
  }

  Future<void> setBackupFolder(BackupFolder? folder) async {
    await backup.saveBackupFolder(folder);
    Prefs.setString(Prefs.backupLastError, '');
    notifyListeners();
  }

  DateTime? get lastBackupAt {
    final ms = Prefs.getInt(Prefs.backupLastRunMs, 0);
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Change the cadence. Switching it ON takes a backup immediately rather
  /// than waiting for the interval — otherwise nothing visible happens and the
  /// setting looks broken.
  Future<void> setBackupCadence(BackupCadence cadence) async {
    Prefs.setString(Prefs.backupCadence, cadence.name);
    notifyListeners();
    if (cadence != BackupCadence.off) await runBackupNow();
  }

  void _markBackupRun(DateTime when) {
    Prefs.setInt(Prefs.backupLastRunMs, when.millisecondsSinceEpoch);
    notifyListeners();
  }

  /// Take one now, whatever the schedule says. Returns what happened so the
  /// caller can say so — a backup that silently did not happen is the failure
  /// this feature exists to prevent.
  Future<BackupOutcome> runBackupNow() async {
    if (ResetGate.active) return const BackupOutcome(skipped: true);
    final outcome = await runBackup();
    _recordBackupOutcome(outcome);
    if (outcome.succeeded) _markBackupRun(DateTime.now());
    return outcome;
  }

  void _recordBackupOutcome(BackupOutcome outcome) {
    if (outcome.skipped) return;
    Prefs.setString(Prefs.backupLastError, outcome.error ?? '');
    notifyListeners();
  }

  /// Foreground hook. Silent unless it actually writes something.
  ///
  /// The timestamp is read and written INSIDE the backup lock, via these
  /// callbacks — reading it here and passing the value in would let a second
  /// resume decide against a stale timestamp while the first backup was still
  /// finishing, and start a duplicate export.
  Future<void> runBackupIfDue() async {
    if (backupCadence == BackupCadence.off) return;
    // Guarded: this is fired with `unawaited` from the resume hook, and
    // `markRun` notifies listeners — which throws if the state was disposed
    // during a long export, surfacing as an unhandled async error.
    try {
      await _runBackupIfDue();
    } catch (e) {
      _log('Backup failed: $e');
    }
  }

  Future<void> _runBackupIfDue() async {
    final outcome = await backup.runBackupIfDue(
      // Re-read inside the lock, not captured here: a call that waits behind a
      // running export would otherwise act on the setting as it was when it
      // queued, and someone who switched backup off in the meantime would
      // still get a copy of their health data written after disabling it.
      cadence: () => ResetGate.active ? BackupCadence.off : backupCadence,
      lastRun: () => lastBackupAt,
      markRun: (when) async => _markBackupRun(when),
    );
    _recordBackupOutcome(outcome);
    if (outcome.error != null) _log('Backup failed: ${outcome.error}');
  }

  /// Clear the local profile + unpair the band (the former "sign out", now purely
  /// local — there is no session to end).
  ///
  /// This is the PROFILE half only. "Reset all data" is [resetAllData], which
  /// calls this last; do not use this one for a destructive user action.
  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProfile);
    await prefs.remove(_kOnboard);
    _onboardChoice = null;
    user = null;
    await unpair();
  }

  /// "Delete everything", and mean it.
  ///
  /// The old reset walked `availableDays()` — the non-skipped DERIVED days —
  /// and deleted those, which left about twenty tables standing: blood panels,
  /// every meal, every medication dose, every breathing session, every logged
  /// set, the rolling baselines, the raw of any day that never derived. It
  /// then removed exactly two preferences, so the install id, the consent
  /// flags, the keychain API key, the home-screen widget's copy of yesterday's
  /// readiness and every scheduled notification all survived a dialog that
  /// said they would not.
  ///
  /// Order matters and is deliberate:
  ///   1. Stop the network paths FIRST. Everything below takes time, and a
  ///      derive or backup finishing mid-reset must not upload or write a
  ///      snapshot of data the user just asked to destroy.
  ///   2. The database, then the preferences, then the keychain — the reads
  ///      that could re-create state are all downstream of the writes.
  ///   3. [signOut] last, because it flips the route and the UI unwinds.
  /// Returns a cleanup error if backup copies or folder access remain.
  Future<String?> resetAllData() async {
    // 0 · nothing further ENTERS the database either. The band is still
    //     connected and still draining — see [_resetting].
    ResetGate.enter();
    try {
      // Wait for a running backup and remove copies while the selected folder
      // grant is still known. Queued scheduled writes see Off inside the lock.
      Prefs.setString(Prefs.backupCadence, BackupCadence.off.name);
      // 1 · nothing further leaves this phone, starting now.
      telemetryConsent = false;
      healthShareConsent = false;
      consentChosen = false;
      TelemetryService.instance.applyConsent(false);
      HealthUploader.instance.deviceId = null; // maybeUpload bails without one
      deviceId = '';

      String? backupCleanupError;
      try {
        await backup.deleteAutomaticBackups();
      } catch (e) {
        // An unavailable backup folder must not prevent deleting app data.
        backupCleanupError = e.toString();
        _log('[reset] backup cleanup failed: $e');
      }
      // Cleanup waits for in-flight folder saves, including on failure.
      final folderToRelease = backupFolder;

      // 2 · every row in every table (see LocalDb.wipeAll for why it is not a
      // hand-written table list, and for the sync_cursor decision).
      await LocalDb.wipeAll();

      // Surfaces outside the database that were still showing it.
      await NotificationService.instance.cancelAll();
      await WidgetService.clear();
      try {
        await coachConfig?.save(apiKey: ''); // deletes the keychain entry
      } catch (e) {
        _log('[reset] keychain clear failed: $e');
      }

      // 3 · the whole preference namespace, not a remembered subset — same
      // reason as wipeAll. A fresh install is the state being restored, and a
      // fresh install has no preferences. The install id regenerates on the next
      // launch, which is the point: the old anonymous id must not follow the
      // user through a "delete everything".
      try {
        final prefs = await SharedPreferences.getInstance();
        final cleared = await prefs.clear();
        if (!cleared) {
          throw const FileSystemException('Preferences were not cleared');
        }
        if (Platform.isAndroid && folderToRelease != null) {
          try {
            await AndroidBackupStorage.release(folderToRelease);
          } catch (e) {
            backupCleanupError ??= e.toString();
            _log('[reset] backup folder access release failed: $e');
          }
        }
      } catch (e) {
        _log('[reset] prefs clear failed: $e');
        // The saved folder and its grant both survive; say so.
        if (Platform.isAndroid && folderToRelease != null) {
          backupCleanupError ??= e.toString();
        }
      }
      appStatus = null;
      _savedAlarm = null;

      // 4 · the in-memory mirrors of what we just deleted. These are plain
      // fields, restored only by the profile load at launch, so leaving them
      // alone kept both features RUNNING against the wiped database for the rest
      // of the session — a re-pair without a relaunch would find phone steps
      // still on and health export still syncing, which is not "a fresh install".
      healthSyncEnabled = false;
      healthState = HealthLinkState.unknown;
      phoneStepsEnabled = false;
      phoneStepsToday = 0;
      _phoneStepsDay = null;
      // The data edge, for the same reason. It only ever moves FORWARD, so a
      // wipe that left it set meant a re-pair without a relaunch showed the
      // deleted install's "Synced through …" — and no amount of syncing the new
      // band could pull the label back to the truth.
      _lastRecTs = null;
      lastSynced = null;

      // signOut() unpairs, so by the time it returns nothing is delivering.
      await signOut();
      return backupCleanupError;
    } finally {
      // Never leave ingest refused if the reset threw part-way: a half-reset
      // install that silently drops every record is worse than the race.
      ResetGate.leave();
    }
  }

  /// The single onboarding/route the UI gate is in. `_Gate` selects on THIS so it
  /// rebuilds only on a real route transition — NOT on every ~1 Hz notifyListeners
  /// (live HR, log lines), which used to repaint the whole home stack each second
  /// and starve the background BLE connection.
  AppRoute get route {
    if (initError != null) return AppRoute.failed;
    if (!initialized) return AppRoute.loading;
    // First run, fresh install: offer "existing v2 user vs new user" before we
    // ask anyone to pair. A returning (already-paired) user skips it even if the
    // choice flag predates this build.
    if (_onboardChoice == null && !isPaired) return AppRoute.welcome;
    if (!isPaired) return AppRoute.pairing;
    if (!profileComplete) return AppRoute.profile;
    return AppRoute.shell;
  }

  /// True once the profile has the fields the analytics personalization needs.
  bool get profileComplete => _profile.isComplete;

  // ── app status: the OTA update pointer ──────────────────────────────────────
  // Fetched directly by UpdateService from a public, unauthenticated pointer
  // URL — independent of any backend / JWT (the authed client was deleted).
  //
  // The operator-pushed alert banner that used to live here is GONE: it was
  // fetched, dismissible and persisted, but no screen ever drew one, so the
  // dismissed-id set could only ever be empty. Deleted rather than wired —
  // nothing in the product asks for an operator broadcast channel.
  AppStatus? appStatus;
  int _currentBuild = 0; // our build number (from package_info); 0 if unknown

  UpdateInfo? get _update => appStatus?.update;

  /// A newer build is published (we're behind latest_build).
  ///
  /// Gated on [UpdateService.supported] (Android + [kSideloadOtaEnabled]):
  /// store builds (Play Store / App Store) and any non-Android build must
  /// never surface a self-update prompt at all, not just fall back to a
  /// browser link — see update_service.dart.
  bool get updateAvailable =>
      UpdateService.supported &&
      _update != null &&
      _currentBuild > 0 &&
      _update!.latestBuild > _currentBuild;

  /// We're below the mandatory floor — the prompt can't be dismissed.
  bool get updateMandatory =>
      UpdateService.supported &&
      _update != null &&
      _currentBuild > 0 &&
      _currentBuild < _update!.minBuild;

  Future<void> _loadAppStatus() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      /* keep 0 → update prompts simply won't fire */
    }
    await refreshAppStatus();
  }

  /// Whether Cycle is shown at all.
  ///
  /// Until it is set, ON for a female profile and off otherwise. It used to be
  /// off for everyone and opt-in only in Settings, which is where nobody found
  /// it. Onboarding now asks, and an explicit choice either way always wins.
  ///
  /// Turning it off hides the tab and stops its query running. It deletes
  /// NOTHING — cycle entries already logged stay on disk and come back intact
  /// if it is switched on again.
  static const String _kCycleTracking = 'cycle_tracking_enabled';
  bool get cycleTrackingEnabled => Prefs.getBool(
      _kCycleTracking, '${user?['sex'] ?? ''}'.toLowerCase() == 'f');

  Future<void> setCycleTrackingEnabled(bool on) async {
    Prefs.setBool(_kCycleTracking, on);
    notifyListeners();
  }

  /// Whether this install checks for updates. Only meaningful on a sideload
  /// build ([kSideloadOtaEnabled]) — that is the only build whose binary can
  /// contact the endpoint at all. Defaults ON there, because a sideloaded app
  /// has no store to tell it a fix exists, but it is refusable and the
  /// Settings row says what the check discloses.
  static const String _kUpdateChecks = 'update_checks_enabled';
  bool get updateChecksEnabled => Prefs.getBool(_kUpdateChecks, true);

  /// Whether the update-check row should appear at all: a build with the
  /// feature compiled out has nothing to switch.
  bool get updateChecksAvailable => kSideloadOtaEnabled;

  Future<void> setUpdateChecksEnabled(bool on) async {
    Prefs.setBool(_kUpdateChecks, on);
    if (!on) {
      appStatus = null; // drop whatever the last check answered
    }
    notifyListeners();
    if (on) await refreshAppStatus();
  }

  /// The live-workout HR-zone-crossing haptic (see [ZoneCrossingAlert]). Off
  /// by default, and read fresh at [startWorkout] rather than watched mid-
  /// session — flipping the switch while a session is already running takes
  /// effect on the next one, same as every other session-start anchor.
  bool get zoneAlertEnabled => Prefs.getBool(Prefs.zoneAlertEnabled, false);

  Future<void> setZoneAlertEnabled(bool on) async {
    Prefs.setBool(Prefs.zoneAlertEnabled, on);
    notifyListeners();
  }

  /// The zone (1..5) the crossing alert watches. Clamped on read so a stray
  /// value can never hand [ZoneCrossingAlert] a target outside the table.
  int get zoneAlertTargetZone =>
      Prefs.getInt(Prefs.zoneAlertTargetZone, 3).clamp(1, 5).toInt();

  Future<void> setZoneAlertTargetZone(int zone) async {
    Prefs.setInt(Prefs.zoneAlertTargetZone, zone.clamp(1, 5).toInt());
    notifyListeners();
  }

  /// Re-poll the update pointer (best-effort; called on launch and on app resume).
  Future<void> refreshAppStatus() async {
    if (!updateChecksEnabled) return;
    final status = await UpdateService.fetchStatus();
    if (status == null) return;
    appStatus = status;
    notifyListeners();
  }


  /// A tapped notification asks the shell to switch to this tab index. The shell
  /// listens; it resets to -1 after consuming. Kept off the ChangeNotifier path so
  /// a deep-link doesn't repaint the whole tree.
  final ValueNotifier<int> navRequest = ValueNotifier<int>(-1);

  /// A tapped notification may also ask for a SUB-SCREEN on top of the tab
  /// (AI briefing breakdown, journal compose). The shell listens, pushes the
  /// screen and resets to null. Same off-ChangeNotifier design as [navRequest].
  final ValueNotifier<String?> screenRequest = ValueNotifier<String?>(null);

  /// Bumped whenever stored insights change so listeners can re-query without a
  /// full ChangeNotifier repaint.
  ValueNotifier<int> get insightsRevision => _deriveCoordinator.insightsRevision;
  StreamSubscription<String>? _tapSub;

  void _handleTapRoute(String route) {
    final t = resolveTapRoute(route); // pure — lib/notify/tap_router.dart
    if (t.screen != null) screenRequest.value = t.screen;
    navRequest.value = t.tab;
  }

  AppState() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final isHeadless = views.isEmpty || 
                       lifecycle == AppLifecycleState.detached || 
                       lifecycle == null || 
                       lifecycle == AppLifecycleState.paused || 
                       lifecycle == AppLifecycleState.hidden;
    _background = isHeadless;

    _gestureController = GestureController(
      settings: gestureSettings,
      log: _log,
      onMarkMoment: _markMomentFromGesture,
      onWorkoutToggle: _toggleWorkoutFromGesture,
      onLogWater: _logWaterFromGesture,
    );
    engine = BleEngine(
      onRecord: _onRecord,
      onState: (s) => _onEngineState(LocalDb.kPrimaryDeviceId, s),
      log: _log,
      // M2: forward the session's real device id once DeviceSession exists;
      // BleEngine's EventSink typedef has no device field, so the id names
      // itself at this construction closure rather than widening the
      // engine's callback shape for a value it does not have.
      onEvent: (id, ts, hex, profile) =>
          _onLiveEvent(id, ts, hex, profile, LocalDb.kPrimaryDeviceId),
      onEcgEvent: (e) => _ecgTransport?.onEngineEvent(e),
      onReadyEcgRecovery: _recoverEcgGuardOnReady,
      // Gated for the same reason as [_onRecord] — this one is wired straight
      // to LocalDb, so it bypasses every check AppState makes.
      onRecordsBatch: (raws, samples) async {
        if (_resetting) return; // see [_resetting]
        await LocalDb.insertRecordsBatch(raws, samples);
      },
      // RESUMABLE SYNC: atomic commit of decoded rows + continuation cursor
      // before the HISTORY_END ACK, and a reader to seed the offload frontier
      // from the durable high-water on (re)connect. Routed through BandHost
      // (M1a) rather than calling LocalDb.commitSyncBatch directly — same
      // durable commit, same arguments, one extra await frame, and the SAME
      // failure contract: `commitNativeBatch` rethrows so
      // `DrainController.commit` still reads durability from a throw.
      onCommitBatch: (raws, samples, trimTokenHex,
          {archives, ecgRawPackets, deviceFamily}) async {
        try {
          // THROWS, never silently succeeds. This is the ACK gate: only
          // `onCommit` can bank raws + archives + trim cursor in one
          // transaction, and DrainController reads durability FROM A THROW
          // (see its safe-trim invariant). Returning quietly here would tell
          // the drain the chunk was banked, it would ACK, and the band would
          // trim flash that this reset refused to store — turning a race into
          // real data loss on a band the user may not be deleting after all if
          // the reset then fails. A throw blocks the ACK and the records stay
          // on the strap.
          if (ResetGate.active) {
            throw StateError('data reset in progress — refusing to commit');
          }
          await _bandHost.commitNativeBatch(raws, samples, trimTokenHex,
              archives: archives,
              ecgRawPackets: ecgRawPackets,
              deviceFamily: deviceFamily);
        } catch (_) {
          IosShortcutSync.foregroundCommitFailed();
          rethrow;
        }
        IosShortcutSync.foregroundCommitted(samples.length);
      },
      // Pre-setup fallback only: the drain path archives inside commitSyncBatch.
      onArchiveRecord: (raw) async {
        if (_resetting) return; // see [_resetting]
        await LocalDb.archiveRawRecord(raw);
      },
      cursorReader: (base) =>
          LocalDb.getCursorInt(LocalDb.cursorKeyFor(base, LocalDb.kPrimaryDeviceId)),
      // Debounced compute trigger: with continuous listening there's no discrete
      // "sync done", so the engine coalesces stored-record bursts and fires this
      // once a burst goes quiet. Light pass = freshness-first (TODAY when data has
      // reached today, else the latest pending day). The foreground heavy finalize
      // still runs in openSession after the backlog fully drains.
      onDataStored: _onDataStored,
      onOffloadState: (active) => _deriveScheduler.setOffloadActive(active),
      // Smart Wake Window: piggyback on the engine's own 30 s keep-alive
      // tick rather than a second timer. See _checkSmartWake's doc for the
      // safety argument (short version: this can only ever ADD an early
      // buzz — the band's already-armed SET_ALARM fallback is never touched
      // here, in any branch).
      onKeepAlive: _checkSmartWake,
      // LIVE high-rate frames (0x28/0x2B/0x33) are ephemeral — routed here for the
      // live UI / breathing session, never persisted.
      onLiveFrame: _onLiveFrame,
      // Live HR/IMU ownership (#287): the engine reads the owner set inside
      // its reconcile loop; this side only mutates owners and nudges.
      liveOwners: _liveOwners,
      deriveDataStaleness: () {
        final ts = _lastRecTs;
        if (ts == null || ts <= 0) return const Duration(days: 3650);
        final at = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        return DateTime.now().difference(at);
      },
      // Foreground-aware debounce tier (see DeriveDebouncer's doc): without
      // this, a catch-up sync's data staleness dropping below the fresh/stale
      // threshold — i.e. records finally reaching "now", exactly what the
      // user is watching for — flips the debounce into its SLOWEST tier
      // (60s quiet / 5min floor) at precisely the worst moment. `_background`
      // already exists for the derive-scheduler's own foreground/background
      // gate (see pauseForBackground/openSession); reusing it here costs
      // nothing new and keeps both signals consistent with each other.
      isForegroundActive: () => !_background,
    );
    _bandHost = BandHost(
      adapter: WhoopFramedAdapter(engine, kWhoopGen4),
      deviceId: LocalDb.kPrimaryDeviceId,
      onLog: (msg) => _log('[COMMIT] $msg'),
    );
    // Seed the engine's link-power state (issue #200). `setBackground` is
    // otherwise only called on TRANSITIONS, and a headless start begins
    // backgrounded — without this the very case that most needs the cheap
    // connection interval would run at the fast one until the user next
    // foregrounded the app.
    engine.setBackground(_background);
    // Same reasoning for the derive pacing budget: it defaults to foreground and
    // otherwise only flips on a transition, so a headless start paced its very
    // first sweep as if the app were on screen.
    _deriveScheduler.setBackground(_background);
    repo = LocalRepositoryImpl(
      getProfileMap: () => user,
      saveProfileFields: updateProfile,
      onActivitiesChanged: refreshActivityReviews,
    );
    // iOS BGProcessing/BGAppRefresh wakes while the FOREGROUND app owns the band
    // skip the headless BLE path (it would fight FBP for the peripheral) — route
    // them to a catch-up pull over the existing live connection instead.
    IosBgTask.foregroundPull = foregroundCatchUp;
    IosShortcutSync.attachForeground(syncForShortcut, () => engine);
    taskerBridge; // force init: register the method channel handler
    // A paired sensor's live beats, into the same trace as the band's. Touches
    // no radio — `HrsLink.reading` is a plain notifier whose identity survives
    // arm/disarm, which is why one listener for the life of this object works.
    HrsLink.instance.reading.addListener(_onHrsReading);
    // Same wiring, second notify-class sensor: PMD readings otherwise never
    // reach liveHr/the live trace at all (arm/disarm alone don't feed it).
    PolarPmdLink.instance.reading.addListener(_onPmdReading);
    _initDone = _init();
    // Notification taps → request a tab switch (the shell listens to navRequest).
    _tapSub = NotificationService.instance.taps.listen(_handleTapRoute);
    unawaited(NotificationService.instance.consumeLaunchRoute());
    unawaited(checkPendingSiriRoute());
  }

  /// Build the object graph WITHOUT running [_init] and without touching a
  /// single platform plugin (no DB read, no prefs load, no BLE session, no
  /// notification/widget channels), so the state machines above can be
  /// unit-tested. Tests only.
  ///
  /// [engine] lets a test substitute a BleEngine subclass (e.g. one whose
  /// stream arming throws). When supplied it is used AS GIVEN — its callbacks
  /// are the test's responsibility, not wired back into this AppState.
  @visibleForTesting
  AppState.forTesting({BleEngine? engine, EcgController? ecg}) {
    _background = false;
    _ecg = ecg;
    _gestureController = GestureController(
      settings: gestureSettings,
      log: _log,
      onMarkMoment: _markMomentFromGesture,
      onWorkoutToggle: _toggleWorkoutFromGesture,
      onLogWater: _logWaterFromGesture,
    );
    this.engine = engine ??
        BleEngine(
          onRecord: _onRecord,
          onState: (s) => _onEngineState(LocalDb.kPrimaryDeviceId, s),
          log: _log,
          // M2: same marker as the constructor above.
          onEvent: (id, ts, hex, profile) =>
              _onLiveEvent(id, ts, hex, profile, LocalDb.kPrimaryDeviceId),
          liveOwners: _liveOwners,
        );
    // Same wiring as the real constructor, and for the same reason it is safe
    // here: a ValueNotifier, no plugin.
    HrsLink.instance.reading.addListener(_onHrsReading);
    PolarPmdLink.instance.reading.addListener(_onPmdReading);
  }

  /// A Siri/Shortcuts App Intent (e.g. "start breathing") may have set a
  /// pending route in the App Group before launching/foregrounding the app —
  /// see WidgetService.consumePendingRoute + StartBreathingIntent in
  /// OpenStrapIntents.swift. Checked on cold launch (constructor, above) AND
  /// on every foreground resume (app.dart's didChangeAppLifecycleState),
  /// since `openAppWhenRun = true` may just foreground an already-running
  /// process rather than trigger a fresh launch.
  ///
  /// Waits for [_initDone] FIRST — a launch's very first `resumed` lifecycle
  /// callback can fire before [_init] has loaded `_schedule` from disk just
  /// as easily as the constructor's own unawaited call can, and
  /// [_maybeEnableTomorrowAlarmFromSiri] must never run
  /// [setScheduleDay] against the still-default placeholder schedule. Both
  /// call sites route through here, so the guard lives once, here, rather
  /// than duplicated at each of them.
  Future<void> checkPendingSiriRoute() async {
    if (_initDone != null) await _initDone;
    await _maybeEnableTomorrowAlarmFromSiri();
    final route = await WidgetService.consumePendingRoute();
    if (route != null) _handleTapRoute(route);
  }

  /// EnableTomorrowAlarmIntent (Siri/Shortcuts) latches the weekday it wants
  /// turned on — computed on the Swift side, at the moment Siri actually ran
  /// it, not here (a request made just before local midnight must still mean
  /// the day the user asked for, even if the app doesn't resume until after
  /// midnight). The widget process has no BLE, so it cannot arm the band
  /// itself; this is the actual write: flip that weekday's slot on at
  /// whatever hour/minute it already has (same as tapping that slot's
  /// toggle on the Alarm screen — never invents a time), then
  /// [setScheduleDay] re-arms the band immediately when connected. On
  /// failure, re-latch the request rather than drop it — a transient
  /// DB/BLE error shouldn't silently eat a Siri command; it just retries on
  /// the next launch/resume.
  Future<void> _maybeEnableTomorrowAlarmFromSiri() async {
    final weekday = await WidgetService.consumeEnableTomorrowAlarmWeekday();
    if (weekday == null) return;
    try {
      await setScheduleDay(weekday: weekday, enabled: true);
    } catch (e) {
      _log('[alarm] siri enable-tomorrow failed, will retry next resume: $e');
      await WidgetService.relatchEnableTomorrowAlarm(weekday);
    }
  }

  /// Set in [dispose]. Async work that resumes AFTER teardown must not touch
  /// state or call notifyListeners() — see dispose()'s own note about
  /// notifying a disposed ChangeNotifier (which throws in release). Timers are
  /// cancelled there, but an already-suspended `await` cannot be, so every
  /// continuation past an await in this class needs to re-check this.
  bool _disposed = false;

  /// Central disposal guard.
  ///
  /// Setting `_disposed` and checking it at each await point only covers the
  /// paths someone remembered to guard. Several notifications reach here from
  /// places that never see that flag — the derive scheduler's `onChanged`
  /// callback, in-flight derive-pass continuations, BLE engine callbacks —
  /// and notifying a disposed ChangeNotifier throws in release. Overriding the
  /// single funnel every one of them goes through makes the guard total instead
  /// of a list of remembered sites.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _deriveCoordinator.cancelActivityReviewRetry();
    if (IosShortcutSync.foregroundSync == syncForShortcut) {
      IosShortcutSync.foregroundSync = null;
      IosShortcutSync.foregroundEngine = null;
    }
    _sync.cancelQuietTimer();
    _disposed = true;
    _ecg?.dispose();
    _ecgTransport?.dispose();
    // EVERY timer this object owns, not just three of them.
    // The breathing recompute timer and _workoutTimer used to survive dispose, and
    // each of their callbacks ends in notifyListeners() on a disposed
    // ChangeNotifier (which throws in release).
    _tapSub?.cancel();
    _deviceRowSub?.cancel();
    _deviceRowSub = null;
    _sync.dispose();
    _alarmGraceTimer?.cancel();
    _alarmGraceTimer = null;
    _breathingController.dispose();
    _workoutController.dispose();
    // The sensor's notifier OUTLIVES this object (HrsLink is a singleton), so
    // a listener left on it is a leak that calls into a disposed
    // ChangeNotifier on the next beat.
    HrsLink.instance.reading.removeListener(_onHrsReading);
    final hrsId = _hrsTraceId;
    _hrsTraceId = null;
    if (hrsId != null) _clearLiveHrTrace(hrsId);
    PolarPmdLink.instance.reading.removeListener(_onPmdReading);
    final pmdId = _pmdTraceId;
    _pmdTraceId = null;
    if (pmdId != null) _clearLiveHrTrace(pmdId);
    BandOwnership.markForegroundIntent(false);
    _sync.releaseForegroundLease();
    _deriveCoordinator.disposeScheduler();
    _waterBuzzer.dispose();
    _medBuzzer.dispose();
    // Owned notifiers/observers. notificationRelay in particular holds a
    // WidgetsBindingObserver, a 120 s Timer.periodic and a StreamSubscription —
    // its observer accumulated on the binding across every hot restart.
    notificationRelay.dispose();
    gestureSettings.dispose();
    navRequest.dispose();
    screenRequest.dispose();
    _deriveCoordinator.disposeInsightsRevision();
    super.dispose();
  }

  /// Arm every periodic/one-shot timer this object owns, so a test can prove
  /// [dispose] actually cancels all of them (an outstanding Timer fails a
  /// `testWidgets` case). Tests only — nothing in the app calls this.
  @visibleForTesting
  void debugArmOwnedTimers() {
    _sync.debugArmBackfillTimer();
    _alarmGraceTimer ??= Timer(const Duration(minutes: 5), () {});
    _breathingController.debugArmTimer();
    _workoutController.debugArmTimer();
  }

  /// Stand-ins for the derive engine's per-pass work, so a test can hold or
  /// fail a pass without a substrate. Null (the default) runs the real engine.
  /// Tests only.
  @visibleForTesting
  DeriveRunHook? get debugDeriveRun => _deriveCoordinator.debugDeriveRun;
  @visibleForTesting
  set debugDeriveRun(DeriveRunHook? value) =>
      _deriveCoordinator.debugDeriveRun = value;
  @visibleForTesting
  Future<int> Function(Profile profile)? get debugRescanRecent =>
      _deriveCoordinator.debugRescanRecent;
  @visibleForTesting
  set debugRescanRecent(Future<int> Function(Profile profile)? value) =>
      _deriveCoordinator.debugRescanRecent = value;
  @visibleForTesting
  Future<bool> Function(Profile profile)? get debugRefreshActivityReviews =>
      _deriveCoordinator.debugRefreshActivityReviews;
  @visibleForTesting
  set debugRefreshActivityReviews(Future<bool> Function(Profile profile)? value) =>
      _deriveCoordinator.debugRefreshActivityReviews = value;

  /// Run one post-drain derive pass directly, as the scheduler's run callback
  /// does. Tests only.
  @visibleForTesting
  Future<void> debugAfterDrain({bool heavy = false}) =>
      _deriveCoordinator.afterDrain(heavy: heavy);

  /// The derive scheduler the engine callbacks and lifecycle transitions drive.
  /// Tests only.
  @visibleForTesting
  DeriveScheduler get debugDeriveScheduler => _deriveScheduler;

  /// The live-stream owner set the engine reads right now. Tests only.
  @visibleForTesting
  LiveStreamOwners get debugLiveOwners => _liveOwners();

  /// Run start-up (guarded, exactly as the constructor fires it) so a test can
  /// drive the failure path. Tests only.
  @visibleForTesting
  Future<void> debugInit() => _init();

  /// Run the orphaned-live-workout reconcile directly. Tests only — in the app
  /// it is kicked unawaited from [_init].
  @visibleForTesting
  Future<void> debugReconcileOrphanedLiveWorkout() =>
      _reconcileOrphanedLiveWorkout();

  /// Run the cross-day anchor read (nightly RHR, quiet-waking level) that
  /// `_initSteps` awaits before the reconcile above. Tests only.
  @visibleForTesting
  Future<void> debugRefreshNightlyRhr() => _refreshNightlyRhr();

  /// Feed one live accel frame through the live-pedometer path exactly as
  /// [_onLiveFrame] does, with the ingest wall-clock supplied by the caller.
  /// Tests only — lets a test replay a session's frames deterministically.
  @visibleForTesting
  void debugFeedLiveAccel(
    List<double> mags, {
    int? recTs,
    required int atMs,
  }) {
    _ingestLiveMagsAt(proto.ImuFrame(recTs ?? 0, 0, mags), atMs);
    _trackCoverage(recTs);
  }

  /// Run one live frame through [_onLiveFrame], the router the engine's
  /// `onLiveFrame` callback feeds (a `forTesting` engine is not wired to it).
  /// Tests only.
  @visibleForTesting
  void debugOnLiveFrame(int pt, String hex, int? recTs) =>
      _onLiveFrame(pt, hex, recTs);

  /// End the live-pedometer session (persist the coverage window) without a
  /// BLE disconnect. Tests only.
  @visibleForTesting
  Future<void> debugFinalizeLivePedometer() => _finalizeLivePedometer();

  /// Run one 1 Hz live-workout tick without the timer. Tests only — the tick is
  /// where a stale heart rate would be billed into zone-seconds and strain.
  @visibleForTesting
  void debugTickWorkout() => _workoutController.debugTickWorkout();

  /// Feed a strap alarm-lifecycle event (56 set / 57–58 fired / 59 cleared)
  /// without going through the BLE event path. Tests only.
  @visibleForTesting
  void debugHandleAlarmEvent(int id, {int? tsSec}) => _handleAlarmEvent(
      id, tsSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);

  /// Feed one `DeviceState` through [_onEngineState] for [deviceId], exactly
  /// as `BleEngine`'s `onState` callback does. Tests only — lets a test drive
  /// the per-device live-HR dedupe (M6 §11) without a real BLE stream.
  @visibleForTesting
  void debugFeedEngineState(String deviceId, DeviceState s) =>
      _onEngineState(deviceId, s);

  /// (Re)arm the strap-buzz timer for the water reminder from the current
  /// notification prefs. Call at launch and whenever the toggle changes (the
  /// Notifications screen passes [prefs] so we skip a reload). Timers don't
  /// persist, so launch is not optional.
  Future<void> armWaterReminder([NotificationPrefs? prefs]) async {
    final p = prefs ?? await NotificationPrefs.load();
    _waterBuzzer.configure(
      enabled: p.waterEnabled,
      slotMinutes: NotificationCenter.waterSlotMinutes(p),
    );
  }

  /// Push a just-saved low-battery threshold into the device-alert pipeline.
  /// DeviceAlerts restores its threshold once per process; without this a
  /// change made in Settings would not apply until the next restart.
  Future<void> refreshBatteryThreshold(NotificationPrefs prefs) async {
    _deviceAlerts.refreshThreshold();
  }

  bool _vacuumedThisLaunch = false;

  /// Give the FILESYSTEM back the pages the retention prune freed.
  ///
  /// Deleting rows only moves pages to SQLite's freelist; the file never
  /// shrinks below its all-time high-water mark, so an install that once let a
  /// substrate backlog build (or that went through v39's two shadow-copy
  /// migrations) keeps that size forever even though the space is unused. See
  /// [LocalDb.vacuumIfBloated] for why this is a one-off VACUUM and not
  /// `auto_vacuum`.
  ///
  /// A VACUUM rewrites the whole file under an exclusive lock and wants ~2× the
  /// file size free on disk, so it runs at exactly one moment: right after a
  /// FOREGROUND heavy derive, with no live session and nothing else in flight.
  /// Never on the sync/ACK path, never backgrounded, and at most once a launch
  /// — steady state has nothing left to reclaim on a second pass.
  Future<void> _maybeReclaimDiskSpace() async {
    if (_vacuumedThisLaunch || _disposed) return;
    if (_background || busy || _liveSessionActive) return;
    _vacuumedThisLaunch = true;
    try {
      final freed = await LocalDb.vacuumIfBloated();
      if (freed > 0) {
        _log('[db] vacuum returned ${freed >> 20} MB to the filesystem');
      }
    } catch (e) {
      // Out of disk, or another connection holds a lock. Storage hygiene —
      // nothing user-facing depends on it, and the next launch tries again.
      _log('[db] vacuum skipped: $e');
    }
  }

  /// Local push when a NEW physiological day's recovery lands (sleep window
  /// closed + recovery computed). Best-effort; fires at most once per day_id —
  /// the last-notified day is persisted so a relaunch/re-derive never re-fires.
  ///
  /// This is the user-need cadence hook from the derive-completion path: you
  /// wake into a new day and your recovery is ready.
  static const String _kLastRecoveryNotifDay = 'last_recovery_notif_day';
  Future<void> _maybeNotifyRecoveryReady() async {
    try {
      final row = await LocalDb.latestDayResult();
      if (row == null) return;
      final dayId = (row['day_id'] ?? row['date'])?.toString();
      if (dayId == null || dayId.isEmpty) return;
      final score = (row['readiness'] as num?)?.round();
      if (score == null) {
        return; // recovery not computed (no nocturnal HRV) → no fire
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_kLastRecoveryNotifDay) == dayId) {
        return; // already fired
      }
      final payload = SeriesCodec.decodePayloadJson(
        (row['payload_json'] ?? '{}').toString(),
      );
      // Home holds a partial night back; announcing it would also spend the
      // day's guard before the real recovery lands.
      if (!recoveryNightSettled(
        dayId: dayId,
        payload: payload,
        dataEdgeSec: await LocalDb.lastDecodedRecTs() ?? 0,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      )) {
        return;
      }

      // Sleep hours from the day's bundle accounting (tst), for the body copy.
      String slept = '';
      try {
        if (payload != null) {
          final acct = ((payload['sleep'] as Map?)?['accounting'] as Map?);
          final tstSec = ((acct?['value'] as Map?)?['tst_sec'] as num?)
              ?.toDouble();
          if (tstSec != null && tstSec > 0) {
            final m = (tstSec / 60).round();
            slept = ', slept ${m ~/ 60}h ${m % 60}m';
          }
        }
      } catch (_) {
        /* body just omits the slept-for clause */
      }

      // GUARD AFTER PRESENT. Writing _kLastRecoveryNotifDay before the emit
      // burned the once-per-day guard on an event that never reached the user:
      // a band syncing at 06:40 lands the new day's recovery inside the DEFAULT
      // 22:00–07:00 quiet window, emit drops it, and the guard then blocked
      // every retry for the rest of the day. emitOncePerDay consumes the guard
      // only on a real present, so the next derive pass after 07:00 fires it.
      final fired = await NotificationCenter.instance.emitOncePerDay(
        prefsKey: _kLastRecoveryNotifDay,
        dayId: dayId,
        e: NotificationEvent(
          dedupeKey: '$dayId:recovery_ready',
          category: NotifCategory.recovery,
          priority: NotifPriority.normal,
          title: 'Your recovery is ready',
          body: 'Recovery $score$slept.',
          date: dayId,
          // kRouteRecovery, NOT the bare /today: this event sat dead for
          // months because the recovery channel was one `classOf` dropped —
          // it is the route that re-sanctions it as a prompt (and
          // recoveryEnabled that mutes it).
          route: kRouteRecovery,
        ),
      );
      if (fired) {
        _log('[notify] recovery-ready fired for $dayId (score=$score)');
      }
    } catch (e) {
      _log('[notify] recovery-ready skipped: $e');
    }
  }

  /// Foreground cadence pass. Wind-down + weekly recap are now REAL OS-scheduled
  /// notifications (see _ensureRemindersScheduled) so they fire even when the app
  /// is closed — we just re-assert that schedule here (cheap, idempotent, picks up
  /// any prefs change), then run the data-driven foreground nudges.
  Future<void> runCadenceChecks() async {
    try {
      if (!isPaired) return;
      await _ensureRemindersScheduled();
      await _maybeNotifyStepGoal();
      await _maybeNotifyInactivity();
      // Opt-in auto-import of Health workouts (off by default; self-gates on
      // permission + a 1 h throttle — see AutoWorkoutImport). Foreground
      // cadence is the trigger: workouts are not live data, and this never
      // prompts.
      unawaited(AutoWorkoutImport.maybeRun());
      await _maybeGenerateBriefing();
      unawaited(_checkSchemaHealth()); // throttled internally to 24h
      // Staleness-escalation meta-layer: the SAME check the headless path
      // runs (shared cooldown via SharedPreferences, so foreground and
      // background never double-fire) — a foreground open is exactly when a
      // background wake-source failure streak should finally surface.
      // allowPermissionPrompt:true is correct HERE (unlike the headless
      // default) — runCadenceChecks only ever runs from an active foreground
      // scene (app.dart's didChangeAppLifecycleState), so this is a genuinely
      // contextual moment to ask, per Apple's/Android's notification docs.
      unawaited(checkSyncStaleness(allowPermissionPrompt: true));
    } catch (e) {
      _log('[notify] cadence checks skipped: $e');
    }
  }

  // ── AI briefings (BYOK — see lib/ai/) ────────────────────────────────────────

  /// The BYOK provider config (owned by main.dart's provider tree). Attached
  /// once by the app widget so briefings/reminders can check `hasKey` and call
  /// the shared plumbing. A key change re-asserts the notification schedule.
  CoachConfig? coachConfig;
  void attachCoachConfig(CoachConfig c) {
    if (identical(coachConfig, c)) return;
    coachConfig = c;
    c.addListener(() => unawaited(_ensureRemindersScheduled()));
    unawaited(_ensureRemindersScheduled());
  }

  /// Re-assert the AI notification schedule (settings screens call this after
  /// a prefs change; also runs on every foreground via runCadenceChecks).
  Future<void> refreshAiReminders() => _ensureRemindersScheduled();

  /// Screens that just wrote a briefing/journal state call this so Today's
  /// AI card (which reads BriefingStore synchronously at build) repaints.
  void briefingUpdated() => notifyListeners();

  int _lastBriefingAttemptMs = 0;

  /// Opportunistic generation on foreground: iOS can't run BYOK network in the
  /// background, so the scheduled notification is only a light prompt — the
  /// real summary is generated (a) when the breakdown screen opens, and (b)
  /// HERE, on the first foreground of the morning/evening window, so the Today
  /// card + breakdown open instantly. Cached per day+period; rate-limited so a
  /// failing provider never gets hammered.
  Future<void> _maybeGenerateBriefing({DateTime? now}) async {
    final cfg = coachConfig;
    final r = repo;
    if (cfg == null || !cfg.configured || r == null) return;
    final at = now ?? DateTime.now();
    if (at.millisecondsSinceEpoch - _lastBriefingAttemptMs < 10 * 60 * 1000) {
      return; // one attempt per 10 min — never a retry storm
    }
    try {
      final ai = await AiPrefs.load();
      final minOfDay = at.hour * 60 + at.minute;
      BriefingPeriod? want;
      // The SAME resolved time the sweep notification is armed for. Reading
      // the raw `eveningMin` here would generate — and permanently cache —
      // tonight's sweep at 20:00 for a user whose slot is 21:45, off a day
      // that was not over yet.
      final eveningMin = ai.resolvedEveningMin(
        bedtimeMinOfDay: (await _readCrossdaySummary()).bedtimeMin,
      );
      if (ai.eveningEnabled && minOfDay >= eveningMin) {
        want = BriefingPeriod.evening;
      } else if (ai.morningEnabled && at.hour >= 5) {
        want = BriefingPeriod.morning;
      }
      if (want == null || BriefingStore.read(want) != null) return;
      if (want == BriefingPeriod.morning) {
        // Don't opportunistically write (and permanently cache) a morning
        // briefing off a still-syncing/truncated overnight — e.g. the band
        // disconnected mid-sleep and the app is only foregrounded at 5am, so
        // "overnight_state" is still 'building'. Wait for it to genuinely
        // settle; the 10-min rate limit above already caps how often we check.
        final today = await r.getToday();
        final status = (today['status'] as Map?)?.cast<String, dynamic>();
        final overnightState = status?['overnight_state']?.toString();
        if (overnightState != 'ready') return;
      }
      _lastBriefingAttemptMs = at.millisecondsSinceEpoch;
      await BriefingEngine(config: cfg, repo: r).generate(want, now: at);
      _log('[ai] ${want.id} briefing generated');
      notifyListeners(); // Today card reads the store synchronously
    } catch (e) {
      _log('[ai] briefing generation skipped: $e');
    }
  }

  /// Fire once per day when the daily step ESTIMATE crosses the user's goal.
  /// Reads the latest derived `steps` series (an estimate — same tier as the
  /// Steps tile), so it never claims a precise count.
  static const String _kLastStepGoalDay = 'last_stepgoal_day';
  Future<void> _maybeNotifyStepGoal() async {
    try {
      // Same default every other step-goal reader uses — a user who never
      // opened the goal editor still sees "100% of goal" on Home.
      final goal =
          (user?['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal;
      if (goal <= 0) return;
      final rows = await LocalDb.metricSeries('steps');
      if (rows.isEmpty) return;
      final last = rows.last;
      final date = last['date'] as String?;
      final steps = (last['value'] as num?)?.toInt();
      if (date == null || steps == null || steps < goal) return;
      // GUARD AFTER PRESENT — same shape as the recovery-ready fix above: the
      // guard used to be written before the emit, so a goal crossed inside
      // quiet hours (or with notifications denied) burned the day's only shot.
      await NotificationCenter.instance.emitOncePerDay(
        prefsKey: _kLastStepGoalDay,
        dayId: date,
        e: NotificationEvent(
          dedupeKey: '$date:step_goal',
          category: NotifCategory.reminders,
          // NORMAL + kRouteSteps, not low + /today: reminders-at-low was one
          // of the dropped pairs, so this achievement never once reached a
          // shade. It is a prompt now (route-keyed), muted via
          // stepGoalEnabled.
          priority: NotifPriority.normal,
          title: 'Step goal reached',
          body: 'You hit about $steps steps — at or above your $goal goal.',
          date: date,
          route: kRouteSteps,
        ),
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// Sedentary desk-job posture check. HONEST LIMIT: movement/posture are only
  /// visible while the band is streaming live IMU, so this only evaluates on
  /// foreground open (issue #123 doesn't cover this branch — "recently prone"
  /// is a short rolling ~15 min window, not a monotonic idle timer, so it
  /// doesn't translate into a single OS-scheduled instant the way the
  /// "time to move" nudge below does; still foreground-only for now).
  ///
  /// WIRED under the Movement-nudge switch: this event used to emit on
  /// reminders/low with a bare `/today` route — exactly the pair `classOf`
  /// drops — so it never once reached a shade (the stillness nudge's own
  /// history, pre-schedulableIds). It now rides [kRouteMovement] at prompt
  /// class, gated by `movementEnabled`, and on a real present it also buzzes
  /// the band — safe because this only ever runs with recent live IMU, i.e. a
  /// link that was alive moments ago.
  static const String _kLastInactivityMs = 'last_inactivity_ms';
  Future<void> _maybeNotifyInactivity() async {
    try {
      if (_lastWalkMs == 0) return; // no live data
      final now = DateTime.now();
      if (now.hour < 9 || now.hour >= 21) return; // daytime only
      final nowMs = now.millisecondsSinceEpoch;

      final walkIdleMs = nowMs - _lastWalkMs;
      final recentlyProne =
          _lastProneMs > 0 && (nowMs - _lastProneMs) < 15 * 60 * 1000;
      if (walkIdleMs < 90 * 60 * 1000 || !recentlyProne) return;

      final prefs = await SharedPreferences.getInstance();
      final lastFired = prefs.getInt(_kLastInactivityMs) ?? 0;
      if (nowMs - lastFired < 2 * 60 * 60 * 1000) return; // rate-limit to /2h

      // CodeRabbit caught this as un-padded (e.g. "2026-7-5" instead of
      // "2026-07-05") — breaks the YYYY-MM-DD convention every other
      // dedupeKey/date field in this file already follows.
      final today = todayLabel();
      // GUARD AFTER PRESENT — same shape as the two above. Stamping the
      // rate-limit before the emit meant a nudge dropped by quiet hours or a
      // muted category silenced the check for the next two hours, so unmuting
      // it at 09:20 bought you nothing until 11:05.
      final fired = await NotificationCenter.instance.emit(
        NotificationEvent(
          dedupeKey: '$today:posture:${nowMs ~/ (2 * 60 * 60 * 1000)}',
          category: NotifCategory.reminders,
          // NORMAL, not low: reminders-at-low is one of the dropped pairs,
          // and prompt class requires normal priority.
          priority: NotifPriority.normal,
          title: 'Time to move',
          body:
              'You’ve been in a typing posture for over 90 minutes without walking.',
          date: today,
          route: kRouteMovement,
        ),
      );
      if (fired) {
        await prefs.setInt(_kLastInactivityMs, nowMs);
        // Strap haptic alongside the shade card — the WaterBuzzer trade in a
        // place that doesn't need its own timer: the live IMU feed this check
        // just read IS the proof of a recent link.
        unawaited(engine.buzz());
      }
    } catch (_) {
      /* best-effort */
    }
  }

  // ── "Time to move" — provisional OS-scheduled nudge (issue #123) ───────────
  // Previously this was ALSO only ever evaluated on foreground open (same
  // in-memory `_lastMovementMs` this function used to read, presented via an
  // immediate NotificationCenter.emit — no wall-clock timer, so it could only
  // ever "fire" the instant the app happened to be opened). Fixed per the
  // issue's own recommended lowest-risk shape: whenever live IMU shows real
  // motion, OS-schedule a ONE-SHOT "time to move" for `now + 2h`
  // (NotificationService.scheduleOnce, same zonedSchedule plumbing wind-down/
  // weekly-recap/hydration already use) and cancel+reschedule it on every
  // subsequent movement — so it only actually fires if the user stays still,
  // uninterrupted, for the full 2h window, and it fires from the OS wall-clock
  // even while the app is closed.
  int _lastStillnessScheduleMs = 0;
  Future<void> _rescheduleStillnessNudge(int nowMs) async {
    // Throttle: _ingestLiveMags can call this many times a second while the
    // user is actively moving — the 2h nudge window doesn't need OS-scheduler
    // churn anywhere near that tight.
    if (nowMs - _lastStillnessScheduleMs < 10 * 60 * 1000) return;
    _lastStillnessScheduleMs = nowMs;
    try {
      // Opt-in, off by default. Read here rather than cached because this runs
      // at most once every ten minutes and SharedPreferences is already in
      // memory — and because the switch has to bite on the next movement, not
      // at the next launch. It is also what makes the slot allow-listed at all
      // (NotificationService.schedulableIds): a nudge with no off switch was
      // refused there, and had never once fired.
      final prefs = await NotificationPrefs.load();
      if (!prefs.movementEnabled) return;
      await NotificationService.instance.cancel(NotificationService.idStillness);
      final at = NotificationCenter.stillnessNudgeAt(
          prefs, DateTime.fromMillisecondsSinceEpoch(nowMs));
      if (at == null) return;
      await NotificationService.instance.scheduleOnce(
        id: NotificationService.idStillness,
        category: NotifCategory.reminders,
        title: 'Time to move',
        body: "You've been still for a couple of hours.",
        at: at,
        route: '/today',
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// True while a user-initiated full re-analysis is running (drives the button's
  /// spinner). Separate from the engine's internal coalescing flag.
  bool reanalyzing = false;

  /// Human-readable progress for the Re-analyze button, e.g. "Analyzing 3/12".
  /// Empty when idle. Updated per-day as the sweep advances.
  String reanalyzeProgress = '';

  /// Force-derive [days] (a wearable was enabled, disabled or switched), then
  /// refresh. Waits out a pass already running rather than dropping the ask.
  Future<void> rederiveDays(Set<String> days) async {
    if (days.isEmpty) return;
    while (_derive.running) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // No `await` between the check above and the call below, and runDays
    // claims the engine before its own first `await`: nothing can start in
    // between, so this call cannot hit runDays' "already running" return.
    try {
      await _derive.runDays(_profile, days, force: true);
      await LocalDb.refreshComputeFreshness();
      bumpInsights();
    } catch (e) {
      _log('[derive] wearable re-derive failed: $e');
    }
  }

  /// User-initiated "Re-analyze data": force-derive EVERY day that has raw,
  /// ignoring the derived cursor, then refresh the UI. Returns the number of days
  /// derived (for a result message). Use when screens are empty despite stored raw.
  Future<int> reanalyzeAll() async {
    if (reanalyzing) return 0;
    reanalyzing = true;
    reanalyzeProgress = 'Analyzing…';
    notifyListeners();
    try {
      final n = await _derive.run(
        _profile,
        heavy: true,
        force: true,
        // Per-day callback: surface progress AND refresh the UI so each real day's
        // metrics appear as soon as it's derived (Today fills in one day at a time).
        onDayDone: (day, index, total) async {
          reanalyzeProgress = 'Analyzing $index/$total';
          if (index == total || index == 1 || index % 3 == 0) {
            notifyListeners();
          }
        },
      );
      await LocalDb.refreshComputeFreshness();
      bumpInsights();
      return n;
    } catch (e) {
      _log('[derive] reanalyze failed: $e');
      return 0;
    } finally {
      reanalyzing = false;
      reanalyzeProgress = '';
      notifyListeners(); // screens re-read the derived store
    }
  }

  // ── SLEEP OVERRIDE (manual entry + fallback confirm) ────────────────────────

  /// Manual sleep entry (Approach 1): the user gives the in-bed window for [date]
  /// (local YYYY-MM-DD). Stored as the source of truth, then a force re-derive
  /// restages that day FROM the window — even if it was finalized/locked.
  Future<void> setSleepOverride(
    String date,
    DateTime onset,
    DateTime offset, {
    String source = 'manual',
  }) async {
    final onsetSec = onset.millisecondsSinceEpoch ~/ 1000;
    final offsetSec = offset.millisecondsSinceEpoch ~/ 1000;
    if (offsetSec <= onsetSec) return;
    await LocalDb.putSleepOverride(
      dayId: date,
      onsetTs: onsetSec,
      offsetTs: offsetSec,
      source: source,
    );
    await _reanalyzeForOverride(date);
  }

  /// Confirm the HR-led fallback's proposal for [date] (Approach 2): accept the
  /// window it already computed, promoting 'auto_fallback' → 'confirmed' so the
  /// prompt stops showing. Reads the current window from the derived day.
  Future<void> confirmSleep(String date) async {
    if (repo == null) return;
    final sleep = await repo!.getDaySleep(date);
    final onset = (sleep['onset_ts'] as num?)?.toInt();
    final offset = (sleep['wake_ts'] as num?)?.toInt();
    if (onset == null || offset == null || offset <= onset) return;
    await LocalDb.putSleepOverride(
      dayId: date,
      onsetTs: onset,
      offsetTs: offset,
      source: 'confirmed',
    );
    await _reanalyzeForOverride(date);
  }

  /// Reject a day's detected main sleep entirely — "this was not sleep at
  /// all", the missing counterpart to [confirmSleep] (naps already have this
  /// via `sleep_nap` source='rejected'; main-sleep sessions didn't — edge#248).
  /// Same table, same force-re-derive; `source: 'rejected'` tells
  /// `calendarDays` (substrate.dart) to skip staging this window rather than
  /// force it, so the day re-derives with no main sleep at all. Reversible
  /// the same way as any other override: [clearSleepOverride].
  Future<void> rejectSleep(String date) async {
    if (repo == null) return;
    final sleep = await repo!.getDaySleep(date);
    final onset = (sleep['onset_ts'] as num?)?.toInt();
    final offset = (sleep['wake_ts'] as num?)?.toInt();
    // The rejected window is stored for the record, same as a rejected nap —
    // it is never read back once source is 'rejected' (staging is skipped
    // outright), so an absent detected window falls back to a harmless
    // same-day placeholder rather than blocking the rejection.
    final fallback = DateTime.parse(date).millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putSleepOverride(
      dayId: date,
      onsetTs: onset ?? fallback,
      offsetTs: offset ?? (fallback + 1),
      source: 'rejected',
    );
    await _reanalyzeForOverride(date);
  }

  /// Remove a manual/confirmed override for [date] — revert to auto/fallback.
  Future<void> clearSleepOverride(String date) async {
    await LocalDb.deleteSleepOverride(date);
    await _reanalyzeForOverride(date);
  }

  /// Force-derive after a sleep-override change so the affected day restages from
  /// the user's window (the engine force-includes override days even if locked).
  Future<void> _reanalyzeForOverride([String? editedDay]) async {
    // run() returns 0 without queueing while ANY pass holds the derive latch
    // (a drain's light pass, the post-drain rescan, another edit), and only a
    // force pass reaches a finalized edited day. Wait our turn rather than
    // drop the edit; the latch is released in a finally, so this ends.
    while (reanalyzing) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    reanalyzing = true;
    notifyListeners();
    try {
      // A pass that was already running prepared the edited day from the old
      // window and re-pins that night's readiness when it lands, after the
      // edit's own release. Release again once it's done, right before the
      // force pass takes the latch (no await between the check and run()).
      do {
        while (_derive.running) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (editedDay != null) await LocalDb.releaseFrozenHeadline(editedDay);
      } while (_derive.running);
      await _derive.run(_profile, force: true);
      if (editedDay != null) {
        // A finalized day behind the export cursor is never re-written, so
        // the corrected (or rejected) night would never reach the health store.
        // Not awaited: the rewind waits out any export already running, and
        // the edit shouldn't spin for that long.
        unawaited(
          HealthExporter.reexportFrom(editedDay).then((_) {
            if (healthSyncEnabled) unawaited(_runHealthExport());
          }),
        );
      }
      await LocalDb.refreshComputeFreshness();
      // The day_result rows just changed — without this no RevisionReload screen
      // re-reads, so an override/nap edit only showed up after a restart.
      bumpInsights();
    } catch (e) {
      _log('[derive] sleep-override re-derive failed: $e');
    } finally {
      reanalyzing = false;
      notifyListeners();
    }
  }

  Future<void> refreshActivityReviews({bool retry = false}) =>
      _deriveCoordinator.refreshActivityReviews(retry: retry);

  Future<void> reanalyzeForNapEdit() => refreshActivityReviews();

  Future<List<Map<String, dynamic>>> dataHistoryDays() =>
      LocalDb.dataHistoryDays();

  Future<int> dataFileBytes() => LocalDb.databaseFileBytes();

  Future<String> exportDaysDb(Set<String> dayIds) =>
      LocalDb.exportDaysDb(dayIds);

  Future<int> deleteDays(Set<String> dayIds) async {
    final deleted = await LocalDb.deleteDays(dayIds);
    await LocalDb.refreshComputeFreshness();
    lastSynced = await LocalDb.latestSample();
    // Deleting days is a durable write like any other, so the screens holding a
    // cached read have to be told. `notifyListeners()` alone leaves a
    // RevisionReload screen showing days that are gone until some unrelated
    // bump or a restart — and this is the one write where the stale copy is of
    // data the user explicitly asked to destroy.
    if (deleted > 0) bumpInsights();
    notifyListeners();
    return deleted;
  }

  /// Debounced "new data stored" callback from the engine (continuous listening has
  /// no discrete sync end). The engine already coalesced the burst; we run a single
  /// LIGHT derive over the affected day(s).
  ///
  /// This is also THE reliable place to refresh `_lastRecTs` (the "last data"
  /// freshness banner reads it). `_runSyncBurst`'s own before/after frontier
  /// check can race the async commit — HISTORY_END's commit+ACK sometimes
  /// lands just after `engine.runSync()` already returned, so that
  /// checkpoint-based refresh can miss a burst entirely. This callback fires
  /// on EVERY successful persist path (foreground burst, background/headless
  /// drain, live-triggered store) after the write is durable, so it can't
  /// race it.
  void _onDataStored() {
    // Synchronously, before the async read below: this is the moment records
    // became durable, and it is the only path that sees every commit.
    _sync.markSyncActivity();
    unawaited(() async {
      final recTsHw = await LocalDb.getCursorInt('rec_ts_hw');
      if (recTsHw != null && recTsHw > (_lastRecTs ?? 0)) {
        _lastRecTs = recTsHw;
      }
      notifyListeners();
      _deriveScheduler.markStoredData();
    }());
  }

  // Live (foreground / kept-alive) event path: persist every event, then let the
  // gesture dispatcher act on it. Headless drain (background_sync) persists only —
  // it must never replay an old tap as a live action.
  void _onLiveEvent(
    int id,
    int ts,
    String hex,
    proto.BandProfile profile,
    String deviceId,
  ) {
    if (_resetting) return; // see [_resetting]
    LocalDb.insertEvent(id, ts, hex, deviceId: deviceId, profile: profile);
    // M3: gesture dispatch and the alarm handler stay unscoped — neither is
    // device-scoped in M3's scope, and a double-tap on either band should
    // still log water.
    _handleAlarmEvent(id, ts);
    _gestureController.onEvent(id, ts, hex);
  }

  /// Why start-up failed, or null if it did not. Drives [AppRoute.failed].
  ///
  /// The message is whatever actually threw, verbatim. It is not translated
  /// into a friendlier guess: if the app does not know why it could not start,
  /// it says what it does know rather than inventing a cause.
  String? initError;

  /// The database had to be rebuilt on this launch — see [LocalDb.lastRebuild].
  /// Non-null means the old file is parked on disk and only what
  /// `salvaged` lists came back. The user has to be TOLD; a rebuild the user
  /// never hears about is indistinguishable from data quietly vanishing.
  DbRebuild? get dbRebuild => LocalDb.lastRebuild;

  bool _retryingInit = false;

  /// Run start-up again after [AppRoute.failed]. Every step in [_initSteps] is
  /// idempotent (prefs/DB reads, and `openSession` is guarded by `busy`), so a
  /// retry that partially succeeded before simply redoes it.
  Future<void> retryInit() async {
    if (initialized || _retryingInit) return;
    _retryingInit = true;
    initError = null;
    notifyListeners(); // back to the spinner while this runs
    try {
      await _init();
    } finally {
      _retryingInit = false;
    }
  }

  /// [_initSteps], with the guard that turns a start-up failure into a state
  /// the app can be in and get out of.
  ///
  /// This is fired UNAWAITED from the constructor, so before the guard any
  /// throw — a corrupt prefs blob, a DB read, the derive scheduler's job
  /// recovery — became an unhandled async error that skipped `initialized =
  /// true` and reached nothing but Crashlytics. The user got `AppRoute.loading`
  /// forever: a bare spinner with no timeout, no message and no retry, on every
  /// single launch. `main.dart` already wraps every OTHER start-up step exactly
  /// like this.
  Future<void> _init() async {
    try {
      await _initSteps();
    } catch (e, st) {
      _log('[init] FAILED: $e');
      TelemetryService.instance.recordNonFatal(e, st, reason: 'app_init_failed');
      // A throw AFTER `initialized` is a late, non-fatal step (the background
      // BLE arm at the tail) — the shell is already usable, so it must not
      // throw the user onto an error screen.
      if (!initialized) {
        initError = '$e';
        notifyListeners();
      }
    }
  }

  Future<void> _initSteps() async {
    paired = await PairedDevice.load();
    final pairedSerial = paired?.serial;
    pairedIsMaverick = pairedSerial != null &&
        await _ecgGuard.isRememberedMaverick(pairedSerial);
    await refreshSensors();
    await _loadProfile();
    await _refreshNightlyRhr();
    // Wearable flags (rule R6): the workout sensors admitted in sessions, and
    // a flag or active-wearable change re-derives the days it moves.
    await refreshSessionSensorSources();
    onWearableDaysChanged = rederiveDays;
    // A wearable's sync queues the derive of every pending day it banked.
    BandHost.onWearableStored = _deriveScheduler.requestHeavy;
    // A scale's newest weighing becomes the profile's weight: after each
    // session, and now for one a background pass took.
    SessionLink.onSessionDone = adoptWeighing;
    // In the background: its re-derive must not hold the shell's launch.
    unawaited(adoptWeighing().catchError(
        (Object e) => debugPrint('[AppState] adoptWeighing failed: $e')));
    await _deriveScheduler.init();
    // Headless wakes don't roll up; openSession picks pending reviews up.
    if (!_background) unawaited(refreshActivityReviews());
    lastSynced = await LocalDb.latestSample();
    // The true data-edge frontier is the `rec_ts_hw` sync cursor, NOT
    // lastDecodedRecTs() (MAX(rec_ts) FROM decoded_onehz). decoded_onehz only
    // gets a row when a record decodes to the FULL 1 Hz shape (R24-family);
    // historical R10 "lite" records (hr-only, no accel/optical) decode fine
    // but land in `samples` instead — so on an R10-lite-heavy backlog,
    // decoded_onehz's max freezes while the strap is genuinely, successfully
    // syncing, and "last data" reads as stuck/stale. `rec_ts_hw` advances for
    // every record commitSyncBatch durably persists, decoded_onehz-eligible
    // or not, so it's the honest frontier (same one RecordGate/backfill
    // policies already trust).
    _lastRecTs =
        await LocalDb.getCursorInt('rec_ts_hw') ?? lastSynced?.tsEpoch;
    await LocalDb.refreshComputeFreshness();
    final alarmPrefs = await SharedPreferences.getInstance();
    _savedAlarm = alarmPrefs.getInt('alarm_epoch');
    final firedSec = alarmPrefs.getInt('alarm_fired_at');
    if (firedSec != null) {
      _alarmFiredAt = DateTime.fromMillisecondsSinceEpoch(firedSec * 1000);
    }
    // Seed the confirmation machine from what the last session (foreground OR
    // headless — background_sync.dart writes the same two keys) actually
    // learned, so a relaunch doesn't forget a confirmed headless arm and
    // wrongly read it as unconfirmed, nor trust an arm that never confirmed.
    if (_savedAlarm != null) {
      _seedAlarmFromPrefs(_savedAlarm!, alarmPrefs);
      // Resume the not-confirmed alert a killed process was still holding.
      final saved = _savedAlarm!;
      final resume = alarmLatchAlertResumeDelay(
          alarmPrefs.getStringList('alarm_latch_alert'),
          savedEpoch: saved,
          confirmed: _alarm.confirmed,
          nowMs: DateTime.now().millisecondsSinceEpoch);
      if (resume != null) {
        _alarmGraceTimer = Timer(resume, () {
          if (!_disposed) unawaited(_notifyAlarmLatchFailed(saved));
        });
      }
    }
    await _loadAlarmSchedule();
    await _seedAlarmScheduleFromLegacyIfNeeded();
    // Band-gesture mapping: load the saved action + query native capabilities so the
    // settings UI knows what this platform supports. Best-effort, non-blocking.
    unawaited(gestureSettings.bootstrap());
    // Notification relay (Android only; inert + invisible elsewhere). Best-effort.
    unawaited(notificationRelay.bootstrap());
    // DB integrity check — see _checkSchemaHealth doc. Best-effort, non-blocking.
    unawaited(_checkSchemaHealth());
    // Rehydrate/finalize any workout left `status='live'` by a killed previous
    // run (issue: "can't stop workout, only delete"). Best-effort, non-blocking.
    unawaited(_reconcileOrphanedLiveWorkout());
    initialized = true;
    notifyListeners();
    // Companion (anonymous telemetry + health-data contribution) — best-effort,
    // OFF the critical path so it can never block/break boot. Guarded internally.
    unawaited(_initCompanion());
    // arm the water-reminder strap buzz (timers don't persist)
    unawaited(armWaterReminder());
    // App status (OTA pointer + admin alert banner) — best-effort, non-blocking.
    unawaited(_loadAppStatus());
    // Register the recurring wall-clock nudges as real OS-scheduled notifications
    // (wind-down, weekly recap) so they fire even when the app is closed.
    if (isPaired) unawaited(_ensureRemindersScheduled());
    // SECOND FRAMED BAND (iOS 18+): the ASK picker must run with NO
    // CBCentralManager alive in the process. This is the only such moment —
    // `main()`'s two flutter_blue_plus calls (setOptions/setLogLevel) return
    // before the plugin's lazy central init, and the block below is the first
    // start-up code that creates one. DO NOT move this later, and do not add a
    // radio call above it.
    if (Prefs.getBool(Prefs.kAskAddPendingKey, false)) {
      await _provisionAdditionalAccessory();
    }
    if (isPaired) {
      if (_background) {
        await _sync.startBackgroundSession();
      } else {
        openSession();
      }
    }
    unawaited(_checkPendingTaskerBuzz());
  }

  // Single-flight guard for _checkPendingTaskerBuzz — it's now invoked both
  // from _init() and from every "became connected" transition
  // (_onEngineState), so an overlapping call (e.g. a connect landing while
  // the _init()-triggered call is still in its bounded wait) must no-op
  // rather than race a second concurrent buzz/clear.
  bool _taskerBuzzCheckInFlight = false;

  Future<void> _checkPendingTaskerBuzz() async {
    if (!Platform.isAndroid) return;
    if (_taskerBuzzCheckInFlight) return;
    _taskerBuzzCheckInFlight = true;
    try {
      final pattern = await TaskerBridge.peekPendingBuzz();
      if (pattern == null) return;
      // A Tasker BUZZ_STRAP can arrive while the app is fully dead; the
      // reconnect this _init() already kicked off may not have landed by the
      // time we get here. Wait (bounded) for a live link rather than firing
      // into a not-yet-connected engine and silently losing the request —
      // and only clear the persisted flag once we actually attempt delivery
      // on a live connection. If this 20s wait still times out, the request
      // is NOT lost: _onEngineState calls back in here on every subsequent
      // "became connected" transition for the rest of this process's life,
      // so a slower reconnect still eventually delivers it instead of
      // requiring a full app restart.
      final connected = await _waitUntil(
        () => engine.isConnected,
        const Duration(seconds: 20),
      );
      if (!connected) {
        _log('[tasker] pending buzz (pattern=$pattern) still queued — '
            'no connection within 20s, will retry on the next reconnect');
        return;
      }
      _log('[tasker] consuming pending buzz (pattern=$pattern) from headless intent');
      await engine.buzzPattern(pattern);
      await TaskerBridge.clearPendingBuzz();
    } finally {
      _taskerBuzzCheckInFlight = false;
    }
  }

  /// One-shot: release the restore central, show the ASK picker for an additional
  /// accessory, re-create the restore central around the new band, and re-arm the
  /// primary. The flag is cleared in `finally` — a cancelled or failed picker must
  /// not re-open the sheet on every launch forever.
  ///
  /// NOT surfaced from any UI in M4 (see devices.dart's addFramedBand) — this is
  /// plumbing + its test only, since no second framed band exists to provision
  /// against yet.
  Future<void> _provisionAdditionalAccessory() async {
    try {
      if (!await AccessorySetup.isSupported()) return;
      // NOT disarm(): that clears the persisted band list too, and a process death
      // between here and `provisioned` below would leave the primary with no
      // restore key and no error anywhere. See ios_ble_restore.releaseCentralForPicker.
      await IosBleRestore.releaseCentralForPicker();
      final remoteId = await AccessorySetup.showPicker(addAnother: true);
      // Recreates the restore central and appends to the band list.
      await IosBleRestore.provisioned(remoteId);
      // Arm policy is unchanged: the PRIMARY is what gets background restore.
      // The new band is provisioned and connectable in the foreground.
      final p = paired;
      if (p != null) await IosBleRestore.arm(p.remoteId);
      // NO FAMILY CLAIM. `AccessorySetup.showPicker` offers both the WHOOP 4.0
      // and the WHOOP 5.0/MG display items and hands back only an
      // `ASAccessory.bluetoothIdentifier` — nothing here knows which one the
      // user chose. Stamping `gen4` filed a WHOOP 5 under gen4's decode
      // constants; a null `adapter_id` is the honest answer until discovery
      // reads the service and says. That also means no `HrsLink.mintDeviceId`
      // call is possible yet (its prefix IS the family), so the row keeps a
      // provisional id.
      await LocalDb.upsertDevice(
        id: 'whoop:$remoteId',
        remoteId: remoteId,
      );
    } catch (e) {
      debugPrint('[ask] additional accessory not provisioned: $e');
      // The restore central is gone at this point if the picker threw after the
      // release. Put it back for the primary, or overnight sync silently stops.
      final p = paired;
      if (p != null) await IosBleRestore.provisioned(p.remoteId);
    } finally {
      Prefs.setBool(Prefs.kAskAddPendingKey, false);
    }
  }

  /// Poll [check] every 500ms until it's true or [timeout] elapses. Small and
  /// generic on purpose — currently only used for the Tasker pending-buzz
  /// handoff, which needs to wait for a real BLE connection rather than a
  /// fixed delay.
  Future<bool> _waitUntil(bool Function() check, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) return check();
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return true;
  }

  /// (Re)register standing scheduled reminders per the user's prefs. Idempotent;
  /// safe to call repeatedly (cancels + re-schedules). Best-effort.
  Future<void> _ensureRemindersScheduled() async {
    try {
      final prefs = await NotificationPrefs.load();
      // ONE crossday read feeds every schedule that hangs off the rollup:
      // the Sleep Coach bedtime (check-in, wind-down, nightly sweep) AND the
      // weekly lookback's finding. Two separate baseline reads were how this
      // used to be written; the second one is also where the weekly finding
      // silently never got computed at all.
      final cd = await _readCrossdaySummary();
      final meds = await _medScheduleToday(prefs);
      await NotificationCenter.instance.scheduleStandingReminders(
        prefs,
        bedtimeMinOfDay: cd.bedtimeMin,
        weeklyFinding: prefs.remindersEnabled
            ? NotificationCenter.weeklyLookbackFinding(cd.recent)
            : null,
        checkInDoneToday: await _checkInDoneToday(),
        medDefs: meds.defs,
        medDosesToday: meds.doses,
        armedTonight: _alarmArmedTonight,
      );
      // The strap-buzz half of the medication reminder, off the SAME schedule
      // read the OS dose slots above were armed from — one read feeds both
      // surfaces. Three answers, matching the scheduler's own rule: the
      // switch OFF is an explicit choice and CLEARS the armed buzzes (a timer
      // left standing would buzz for doses the user has muted); a real
      // (possibly empty) schedule re-arms from it; only a FAILED read while
      // enabled preserves, because cancelling would disarm doses that are
      // still real.
      if (!prefs.medsEnabled) {
        _medBuzzer.configure(slotInstants: const []);
      } else if (meds.defs != null) {
        final instants = <DateTime>[];
        for (final s in NotificationCenter.medPromptSlots(
            prefs, meds.defs!, meds.doses)) {
          final at = NotificationCenter.medSlotInstant(s);
          if (at != null) instants.add(at);
        }
        _medBuzzer.configure(slotInstants: instants);
      }
      // AI slots. The nightly sweep is armed only when today actually produced
      // a finding — see [_sweepHeadlineNow], which is also where the body of
      // that notification comes from.
      final ai = await AiPrefs.load();
      await NotificationCenter.instance.scheduleAiReminders(
        prefs,
        ai,
        aiConfigured: coachConfig?.hasKey ?? false,
        bedtimeMinOfDay: cd.bedtimeMin,
        journalDoneToday: BriefingStore.journalDoneToday(),
        sweepHeadline: await _sweepHeadlineNow(),
      );
    } catch (e) {
      _log('[notify] schedule reminders skipped: $e');
    }
  }

  /// Everything the reminder scheduler needs from the crossday rollup, in ONE
  /// read: the Sleep Coach's recommended bedtime (local minutes past midnight,
  /// or null when not yet learned) and the per-day `recent[]` rows the weekly
  /// lookback's finding summarizes. Read in one place because three schedules
  /// hang off it — check-in, wind-down, nightly sweep, weekly lookback — and
  /// a second copy of this parse is a second thing to get wrong.
  Future<({double? bedtimeMin, List<Map<String, dynamic>> recent})>
      _readCrossdaySummary() async {
    try {
      final cd = await LocalDb.baseline('crossday');
      final m = cd?['payload_json'];
      if (m is! String) {
        return (bedtimeMin: null, recent: const <Map<String, dynamic>>[]);
      }
      final j = jsonDecode(m);
      if (j is! Map) {
        return (bedtimeMin: null, recent: const <Map<String, dynamic>>[]);
      }
      final bt = (j['sleep_coach'] as Map?)?['bedtime'];
      final v = bt is Map ? bt['value'] : null;
      final bedtime =
          (v is Map ? (v['bedtime_min_of_day'] as num?) : null)?.toDouble();
      // Same rows `DerivationEngine._runNotifications` consumes for the daily
      // exception — {date, rhr, unsettled, illness, anomaly, temp}.
      final rawRecent = j['recent'];
      final recent = <Map<String, dynamic>>[
        if (rawRecent is List)
          for (final r in rawRecent)
            if (r is Map) r.cast<String, dynamic>(),
      ];
      return (bedtimeMin: bedtime, recent: recent);
    } catch (_) {
      // No rollup → no learned bedtime and an empty week: every consumer has
      // its own honest silence for that.
      return (bedtimeMin: null, recent: const <Map<String, dynamic>>[]);
    }
  }

  /// Whether today's self-report is already written — the check-in prompt's
  /// "do not ask for something already logged" gate.
  ///
  /// NOT `BriefingStore.journalDoneToday()`, which reads a flag that
  /// `markJournalDone` would set and nothing anywhere calls: it is false for
  /// every user on every day. The journal rows are the truth.
  /// NULL, NOT FALSE, when the journal could not be read. The scheduler reads
  /// `false` as "today is known to be unanswered" and arms the prompt on it —
  /// so a transient read failure asked a user who had already written their
  /// rating how their day was. Null is the answer it already has a branch for:
  /// leave the check-in exactly as it is and let the next pass decide.
  Future<bool?> _checkInDoneToday() async {
    try {
      return NotificationCenter.checkInDone(
          await LocalDb.journalMetricsForDay(todayLabel()));
    } catch (_) {
      return null;
    }
  }

  /// The medication schedule + today's recorded doses. Two indexed reads, only
  /// on the path that will use them.
  ///
  /// NULL `defs` means UNREAD — the switch is off, or the read threw — and is
  /// not the same answer as an empty list, which means "this user has no
  /// medications". The scheduler cancels the armed doses on the second and
  /// preserves them on the first; returning `[]` for a failed read handed it
  /// the wrong one of those.
  Future<({List<MedDef>? defs, Map<String, Map<int, Map<String, Object?>>> doses})>
      _medScheduleToday(NotificationPrefs prefs) async {
    const empty = <String, Map<int, Map<String, Object?>>>{};
    if (!prefs.medsEnabled) return (defs: null, doses: empty);
    try {
      final db = await LocalDb.instance;
      return (
        defs: await MedDb.defs(db),
        doses: await MedDb.dosesForDay(db, todayLabel()),
      );
    } catch (_) {
      return (defs: null, doses: empty);
    }
  }

  String? _sweepHeadline;
  String _sweepDay = '';
  int _lastSweepScanMs = 0;

  /// Today's strongest sweep finding, or null when nothing stands out — which
  /// is most days, and is the answer that keeps tonight's notification silent.
  ///
  /// Pure-Dart and offline: no model is involved in DECIDING there is something
  /// to say, only in phrasing it afterwards. Not run before midday (the day is
  /// not in yet) and at most hourly, because this sits on the foreground
  /// cadence path and it is seven trend queries.
  Future<String?> _sweepHeadlineNow({DateTime? now}) async {
    final r = repo;
    final at = now ?? DateTime.now();
    final day = todayLabel(at);
    if (day != _sweepDay) {
      _sweepDay = day;
      _sweepHeadline = null;
      _lastSweepScanMs = 0;
    }
    if (r == null || at.hour < 12) return null;
    if (_lastSweepScanMs != 0 &&
        at.millisecondsSinceEpoch - _lastSweepScanMs < 60 * 60 * 1000) {
      return _sweepHeadline;
    }
    _lastSweepScanMs = at.millisecondsSinceEpoch;
    try {
      _sweepHeadline =
          sweepHeadline(sweepFindings(await collectSweepSeries(r, at)));
    } catch (e) {
      _log('[ai] sweep scan skipped: $e');
    }
    return _sweepHeadline;
  }

  void _log(String line) {
    debugPrint('[OpenStrap] $line');
    FileLog.write(line);
    logLines.insert(0, line);
    if (logLines.length > 200) logLines.removeLast();
  }

  /// `LocalDb.schemaHealth()` (real `PRAGMA integrity_check` + schema
  /// presence check) was previously fully implemented but never called
  /// anywhere in the app — corruption or schema drift could accumulate
  /// silently forever with nothing to notice it. Wired here: once at
  /// startup, and at most once per [_schemaHealthCheckInterval] thereafter
  /// via the existing foreground cadence (runCadenceChecks) so it doesn't
  /// need its own timer infrastructure. Best-effort, never blocks boot.
  static const Duration _schemaHealthCheckInterval = Duration(hours: 24);
  DateTime? _lastSchemaHealthCheckAt;

  Future<void> _checkSchemaHealth({bool force = false}) async {
    final last = _lastSchemaHealthCheckAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _schemaHealthCheckInterval) {
      return;
    }
    _lastSchemaHealthCheckAt = DateTime.now();
    try {
      // The result is LOGGED, not stored: the field that used to hold it had
      // no reader, and a failing integrity check needs a human looking at the
      // log, not a widget nobody built.
      final health = await LocalDb.schemaHealth();
      if (health['ok'] != true) {
        _log('[db] schemaHealth FAILED: $health');
      }
    } catch (e) {
      _log('[db] schemaHealth check skipped: $e');
    }
  }

  void bumpInsights() => _deriveCoordinator.bumpInsights();

  /// Called when the app goes to the background.
  ///
  /// iOS keeps an app alive in the background ONLY while it holds an active BLE
  /// connection with a subscribed characteristic (UIBackgroundModes: bluetooth-central).
  /// So we DELIBERATELY keep the live CONNECTION up here instead of
  /// disconnecting — but not the live STREAMS. The 1 Hz realtime-HR stream
  /// used to be held purely so iOS would resume us once a second; that was
  /// ~86,400 wakes a day and most of a day's battery. Now the band is asked
  /// to prompt us every [kIosBackgroundPromptIntervalSeconds] (its
  /// HIGH_FREQ_SYNC mode); each prompt event resumes the process, the engine
  /// drains the flash, and the process suspends again.
  ///
  /// We still own the band, so the restore central must NOT arm a competing connect.
  /// `BleRestoreManager` is armed only as a RECOVERY path if the connection actually
  /// drops (band out of range / app jettisoned) — see [_onEngineState] / [_armRecovery].
  ///
  /// On Android the Edge Tracking foreground service keeps the process + connection alive.
  Future<void> pauseForBackground() => _sync.pauseForBackground();

  /// A feature session (workout, breathing, ECG capture) is running — the
  /// "nothing else in flight" bar the one-off VACUUM waits for. ECG matters
  /// here specifically: a VACUUM takes an exclusive DB lock and rewrites the
  /// whole file, and an ECG capture in progress is actively writing captured
  /// packets — the two must never overlap.
  bool get _liveSessionActive =>
      activeWorkout != null ||
      breathingActive ||
      breathingWindowOpen ||
      (_ecg?.isCapturing ?? false);

  /// A screen that displays the live heart rate is on screen: own the HR
  /// stream while it is. Pair with [releaseLiveHrView] in `dispose`.
  void retainLiveHrView() => _liveStreamController.retainLiveHrView();

  void releaseLiveHrView() => _liveStreamController.releaseLiveHrView();

  /// A bounded movement-reminder sampling window is open (IMU-only owner).
  ///
  /// There is NO scheduler yet, and enabling the movement-reminder preference
  /// must not hold the IMU stream: sampling only inside bounded windows cannot
  /// prove that movement did not happen between them, so a standing owner
  /// would let the reminder claim an uninterrupted stillness it never
  /// observed. A separately validated scheduler that can account for the gaps
  /// is the only thing that should call this.
  void setMovementSamplingWindow(bool active) =>
      _liveStreamController.setMovementSamplingWindow(active);

  LiveStreamOwners _liveOwners() => _liveStreamController.owners;

  // Historical singles only now (live frames go through _onLiveFrame and are
  // never persisted). Just write the raw record (+ optional decoded sample).
  Future<void> _onRecord(Sample? sample, RawRecord raw) async {
    if (_resetting) return; // see [_resetting]
    final ts = raw.recTs ?? sample?.tsEpoch;
    // AFTER the write, and gated on the write SAYING it wrote. `_lastRecTs` is
    // the DATA EDGE — what is banked — and it only ever moves forward, so
    // advancing it first meant a failed insert advertised a record the
    // database does not hold, for the rest of the process. Now surfaced on
    // Home ("Synced through …"), where claiming data we do not have is the one
    // thing the line must not do. `insertRecord` returns false rather than
    // throwing if it ever stops committing; today it can only return true or
    // throw, and reading the result costs nothing to keep that honest.
    final inserted = await LocalDb.insertRecord(raw, sample);
    if (inserted && ts != null && ts > 0 && ts > (_lastRecTs ?? 0)) {
      _lastRecTs = ts;
    }
  }

  // Ephemeral live high-rate frame (0x28/0x2B/0x33) — NOT persisted. The
  // breathing session taps the RR-bearing frames (0x28 compact HR, 0x2B R10)
  // into its in-memory buffer. Cheap-bounded; cleared at each session start.
  void _onLiveFrame(int pt, String hex, int? recTs) {
    // NOTE: deliberately do NOT advance _lastRecTs from live frames. Live frames
    // (0x28/0x2B/0x33) are ephemeral and NEVER persisted, and they carry the
    // CURRENT wall-clock time — so bumping _lastRecTs here pinned the "last data"
    // label to "now" while the app was connected, hiding whether the overnight
    // HISTORICAL backlog had actually synced. "Last data" must reflect the newest
    // STORED record (the data edge), which only _onRecord advances.
    // `breathingWindowOpen` is the quiet window either side of the
    // paced block — the same buffer, held open across the pacing's own start
    // and stop so a "before" and an "after" exist at all.
    // A 0x2B envelope also carries gen5 Maverick's rev-21 100 Hz IMU record
    // (byte[1] != 10) — realtimeRr already yields no beats from it, but it
    // should not occupy the breathing R-R buffer at all (edge#286).
    final isRrBearing = pt == 0x28 || (pt == 0x2B && _isR10Record(hex));
    if ((breathingActive || breathingWindowOpen) && isRrBearing) {
      _breathingController.tapFrame(hex);
    }
    // LIVE STEP COUNTER. Gen4: dedicated 0x33 IMU (~10 frames/s × 10 samples)
    // is preferred; full R10 (0x2B) is only a fallback when 0x33 isn't flowing.
    // Gen5 Maverick: live IMU is 0x2B (rec 0x15, 100 Hz planar) — see
    // protocol's frameAccelForBand. Once gen4 0x33 is seen we ignore 0x2B to avoid
    // double-counting the same motion from two stream formats.
    if (pt == 0x33) {
      _imuStreamSeen = true;
      final f = _safeFrameAccel(hex);
      if (f != null) {
        _ingestLiveMags(f);
        _trackCoverage(recTs);
      }
    } else if (pt == 0x2B && !_imuStreamSeen) {
      // Gen5 Maverick live IMU is 0x2B (100 Hz planar), not top-level 0x33.
      final f = _safeFrameAccel(hex);
      if (f != null) {
        _ingestLiveMags(f);
        _trackCoverage(recTs);
      }
    }
  }

  /// True iff a live inner packet's record-type byte ([1]) is 10 (R10, the
  /// only R-R-bearing record a 0x2B envelope carries).
  bool _isR10Record(String hex) {
    if (hex.length < 4) return false;
    try {
      return int.parse(hex.substring(2, 4), radix: 16) == 10;
    } catch (_) {
      return false;
    }
  }

  proto.ImuFrame? _safeFrameAccel(String hex) {
    try {
      // Gen5 Maverick live IMU is 0x2B; gen4 stays on frameAccel (0x33 / R10).
      // protocol's gen5 path abstains unless the record is the IMU buffer.
      return proto.frameAccelForBand(hex);
    } catch (_) {
      return null;
    }
  }

  // ── live pedometer (foreground 100 Hz R10 accel) ────────────────────────────
  // Real step counting via the LOCKED AN-2554 pedometer (analytics `pedometer`),
  // the same algorithm + ×1.11 gain the backend calibrated on a 100-step walk.
  // AN-2554's gain was calibrated on PER-MINUTE contiguous signals, so we count
  // in 60 s chunks: each full minute is committed into `_committedRaw`, and the
  // still-filling partial minute is re-counted each frame for a live readout.
  // AN-2554's CONFIRM=8 regularity gate reads 0 at rest (rejects fidgeting).
  final List<double> _magMin = []; // current minute's magnitude signal
  int _committedRaw = 0; // raw (pre-gain) steps from completed minutes
  bool _imuStreamSeen = false; // prefer the 0x33 IMU stream once it appears
  static const int _minuteSamples = 6000; // 60 s @ 100 Hz — calibration chunk
  int _lastWalkMs = 0; // last time steps were accumulated
  int _lastProneMs = 0; // last time the wrist was in a flat/typing posture
  int _lastLiveUiNotifyMs = 0;
  // The band's record timestamp on the FIRST live frame of this session — the
  // ANCHOR, and only the anchor. It keeps every span this session banks in the
  // same base as `decoded_onehz.rec_ts` (what `coverageWindowsOverlapping`
  // compares against). It is never a duration: in practice every live frame of
  // a session repeats the same `recTs`, so its own extent is 0. Duration comes
  // from what we ingested — see [_bandTsAt].
  //
  // The session-END record timestamp used to be tracked alongside it, for the
  // hull [deriveLiveCoverageWindow] built. Nothing reads a hull any more.
  int? _liveCoverStartTs;
  int? _liveFirstIngestMs; // phone clock at the first ingested live frame
  int? _liveLastIngestMs; // …and at the last one
  void _trackCoverage(int? recTs) {
    if (recTs == null || recTs <= 0) return;
    _liveCoverStartTs ??= recTs;
  }

  /// The spans of THIS session in which the pedometer actually counted — what
  /// gets banked, one `live_coverage` row each. See [GaitRuns]: a session hull
  /// says "a live link was up", which is not a step measurement and is not
  /// something a source ladder can rank.
  final GaitRuns _gaitRuns = GaitRuns();

  /// Map a phone-clock instant onto the BAND's record-time base, the base
  /// `live_coverage` rows live in.
  ///
  /// Same rule [deriveLiveCoverageWindow] uses: the band's first record
  /// timestamp is the ANCHOR (it places the session on the band's timeline),
  /// the phone clock supplies the DURATION (the band repeats one record
  /// timestamp for a whole live session, so it cannot). Null before anything
  /// has been ingested — there is no session to place.
  int? _bandTsAt(int nowMs) {
    final first = _liveFirstIngestMs;
    if (first == null) return null;
    final band = _liveCoverStartTs;
    final anchor = (band != null && band > 0) ? band : first ~/ 1000;
    return anchor + (nowMs - first) ~/ 1000;
  }

  /// Record one completed pedometer chunk — [samples] of signal that finished
  /// arriving at [endMs] (phone clock) and produced [rawSteps].
  void _addGaitChunk(int endMs, int samples, int rawSteps) {
    if (rawSteps <= 0 || samples <= 0) return;
    final endTs = _bandTsAt(endMs);
    final floorTs = _bandTsAt(_liveFirstIngestMs ?? endMs);
    if (endTs == null || floorTs == null) return;
    _gaitRuns.addChunk(
      endTs: endTs,
      // The chunk covers the time it SAMPLED, not the wall time it took to
      // dribble in over a flaky link — see live_step_runs.dart.
      seconds: (samples / kLiveSampleRateHz).round(),
      rawSteps: rawSteps,
      floorTs: floorTs,
    );
  }

  /// Steps counted on the live 100 Hz stream this connected session (real,
  /// gain-applied). Used for cadence calibration. 0 when not streaming.
  ///
  /// The still-filling partial minute is dropped once the stream has been
  /// MEASURED below [kMinLiveSampleRateHz] — a count off a stream that slow is
  /// 60-90% short, so it is absent rather than wrong.
  ///
  /// ponytail: the rate used here is the last COMPLETED chunk's, so the first
  /// minute of a too-slow session can still show a live readout before the
  /// first measurement lands. It is never banked (the commit path measures its
  /// own chunk, below). Measure the partial too only if a rate that low is ever
  /// seen on real hardware.
  int get _liveRaw {
    if (_magMin.isEmpty) return _committedRaw;
    final hz = _liveHz;
    if (hz != null && hz < kMinLiveSampleRateHz) return _committedRaw;
    return _committedRaw + ana.pedometer(_magMin);
  }

  // ── the two safety gates on this tier — see live_step_runs.dart ────────────
  /// Phone-clock instant the current chunk's first sample arrived AFTER, i.e.
  /// the previous frame's arrival. The span from here to the frame that
  /// completes the chunk is exactly the wall time those samples took.
  int? _chunkStartMs;

  /// Measured samples/second of the last completed chunk. Null until one
  /// completes — nothing has been measured yet.
  double? _liveHz;
  bool _liveHzLogged = false;

  /// Set when the last completed chunk was refused for running under the floor.
  bool _liveTooSlow = false;

  /// Why the strap contributed no steps right now, or null when it did.
  ///
  /// Never a number and never a zero: both gates make a window ABSENT, and this
  /// is the sentence that says which one did it. A workout screen or a per-day
  /// source view reads this instead of drawing a bare dash.
  String? get liveStepsAbsentReason {
    final t = activeWorkout?.type;
    if (t != null && !isGaitStepType(t)) {
      return 'Steps are only counted from the strap while you are on foot — '
          'a wrist counts arm rhythm as strides. Your phone covers these '
          'minutes.';
    }
    if (_liveTooSlow) {
      final hz = _liveHz;
      final rate = hz == null
          ? ''
          : ' (${hz.toStringAsFixed(0)} Hz, needs '
              '${kMinLiveSampleRateHz.toStringAsFixed(0)})';
      return 'The strap sent motion too slowly to count steps$rate.';
    }
    return null;
  }

  // The session-total getter that used to feed persistence is gone with the
  // session-hull row it wrote. What persists is per-run now ([_bankGaitRuns]),
  // and the gain is applied there; a second, session-level application was
  // exactly the silent x1.23 this path should not be able to express.

  int? get workoutStepsMeasured => _workoutController.workoutStepsMeasured;

  /// Whether the sensors are still recording a stopped workout's tail.
  @visibleForTesting
  bool get strapTailRunning => _workoutController.strapTailRunning;

  /// How long a stopped workout's sensors stay armed; a test shortens it.
  @visibleForTesting
  Duration get strapTailFor => _workoutController.strapTailFor;
  @visibleForTesting
  set strapTailFor(Duration d) => _workoutController.strapTailFor = d;

  /// Asks for the derive that reads a banked tail.
  @visibleForTesting
  void Function() get onStrapTailBanked =>
      _workoutController.onStrapTailBanked;
  @visibleForTesting
  set onStrapTailBanked(void Function() f) =>
      _workoutController.onStrapTailBanked = f;

  void _ingestLiveMags(proto.ImuFrame f) =>
      _ingestLiveMagsAt(f, DateTime.now().millisecondsSinceEpoch);

  // `nowMs` is passed in (rather than read here) so the coverage bookkeeping
  // this method feeds is drivable from a test without a fake clock.
  void _ingestLiveMagsAt(proto.ImuFrame f, int nowMs) {
    final mags = f.mags;
    if (mags.isEmpty) return;
    // `e` is this frame's 1 Hz-equivalent ENMO (mean |a| − 1 g), read below by
    // the stillness nudge and the posture check. Computed for EVERY frame:
    // those two are about wear and movement, not about steps, so neither gate
    // below may switch them off. It no longer feeds a cadence calibration —
    // that was deleted along with the 1 Hz step estimator that was its only
    // consumer (kAlgoVersion v55).
    var magSum = 0.0;
    for (final m in mags) {
      magSum += m;
    }
    final e = (magSum / mags.length) - 1.0;

    // GATE 1 — gait activities only. See kGaitStepTypeKeys. No active session
    // is countable (passive wear is the case the ladder was built for); a
    // session that is not locomotion on foot is not.
    final w = activeWorkout;
    if (w == null || isGaitStepType(w.type)) {
      // Survives `_resetLivePedometer()` through WorkoutController.
      if (w != null) _workoutController.noteWorkoutSample(nowMs);
      // The chunk's clock starts at the PREVIOUS frame's arrival (this one is
      // when its samples landed), so the span measured at commit is exactly the
      // wall time this chunk's samples took. `_liveLastIngestMs` is still the
      // previous frame here — it is advanced below.
      _chunkStartMs ??= _liveLastIngestMs ?? nowMs;
      // Append this frame's |a|(g) samples (gravity INCLUDED — AN-2554's
      // dynamic threshold rides the ~1 g baseline).
      _magMin.addAll(mags);
    } else if (_magMin.isNotEmpty) {
      // Drop the partial minute rather than splice non-gait signal onto gait
      // signal and count the seam. Up to 60 s of real walking is lost at the
      // moment a non-gait session starts; absent beats a fabricated seam, and
      // the pedometer re-seeds `dynVal` from each chunk's own mean anyway.
      _magMin.clear();
      _chunkStartMs = null;
    }
    // Phone-clock extent of the ingested stream — the only observation that
    // reports how long this session actually ran (the band's record timestamp
    // typically repeats). Used as a DURATION only; see [_bandTsAt].
    _liveFirstIngestMs ??= nowMs;
    if (_liveLastIngestMs == null || nowMs > _liveLastIngestMs!) {
      _liveLastIngestMs = nowMs;
    }
    // Any real movement pushes the "Time to move" nudge back out. 0.02 g over
    // baseline is clearly dynamic movement, not resting jitter. (The posture
    // nudge is the sibling below, and keys off `_lastWalkMs` instead.)
    if (e > 0.02) {
      unawaited(_rescheduleStillnessNudge(nowMs));
    }

    // Feature 3: Live Posture Tracking (detect desk-job pronation)
    // Only trust orientation when not highly dynamic (e < 0.05).
    if (e.abs() < 0.05 && f.ys != null && f.zs != null && f.ys!.isNotEmpty) {
      final my = f.ys!.reduce((a, b) => a + b) / f.ys!.length;
      final mz = f.zs!.reduce((a, b) => a + b) / f.zs!.length;
      final rollDeg = math.atan2(my, mz) * 180.0 / math.pi;
      if (rollDeg.abs() > 135) {
        _lastProneMs = nowMs; // flat wrist / typing posture
      }
    }

    // Commit each completed minute into the raw total (matches the gain's
    // per-minute calibration), then keep counting the next partial minute.
    var committedThisTick = false;
    while (_magMin.length >= _minuteSamples) {
      final minute = _magMin.sublist(0, _minuteSamples);
      _magMin.removeRange(0, _minuteSamples);
      // GATE 2 — the MEASURED rate of the samples in this chunk, not
      // kLiveSampleRateHz. See achievedSampleRateHz / kMinLiveSampleRateHz.
      final hz = achievedSampleRateHz(_minuteSamples, _chunkStartMs, nowMs);
      _chunkStartMs = nowMs;
      if (hz != null) {
        _liveHz = hz;
        if (!_liveHzLogged) {
          _liveHzLogged = true;
          // The number STEPS_ALGO §5 says is documented nowhere. Once per
          // connected session, so it finally gets recorded somewhere.
          _log(
            '[steps] live IMU measured ${hz.toStringAsFixed(1)} Hz '
            '(floor ${kMinLiveSampleRateHz.toStringAsFixed(0)} Hz)',
          );
        }
      }
      _liveTooSlow = hz == null || hz < kMinLiveSampleRateHz;
      if (_liveTooSlow) {
        // ABSENT, never zero: nothing committed, nothing banked, no minute
        // handed to sessionCadenceSpm. `liveStepsAbsentReason` says why.
        continue;
      }
      final before = _committedRaw;
      final minuteSteps = ana.pedometer(minute);
      _committedRaw += minuteSteps;
      if (_committedRaw > before) _lastWalkMs = nowMs;
      // A counting minute is a COVERED minute; a silent one is not, and does
      // not extend the run in progress. This is what keeps a 20-minute walk
      // inside a ten-hour connected session from claiming ten hours.
      _addGaitChunk(nowMs, _minuteSamples, minuteSteps);
      // A completed chunk is exactly 60 s, so its count is a steps-per-minute
      // reading — session cadence is a summary of these, not a second decode.
      // Workout-scoped: gen4's R10 is live-only, so there is no 24/7 cadence.
      _workoutController.addWorkoutMinuteSteps(minuteSteps);
      committedThisTick = true;
    }
    // Checkpoint once a minute (only on an actual commit, not every frame) so
    // a killed process doesn't lose the whole session — only whatever hasn't
    // completed a minute yet. See _recoverOrphanedLiveSession.
    if (committedThisTick) unawaited(_checkpointLiveSession());
    if (nowMs - _lastLiveUiNotifyMs >= 1000) {
      _lastLiveUiNotifyMs = nowMs;
      notifyListeners(); // live readout re-counts the partial minute on read
    }
  }

  /// Reset the live step counter for a fresh connected session.
  ///
  /// This zeroes the connection-lifetime raw counter (`_liveRaw`). If a
  /// workout is active, its raw base was snapshotted from a *previous*
  /// (now-stale) `_liveRaw` value — left untouched, `workoutStepsMeasured` would
  /// compute a negative delta on the next BLE disconnect/reconnect blip,
  /// clamp to 0, and visibly reset the walk's step count instead of counting
  /// monotonically. Rebase it here so the already-accrued workout steps
  /// carry through the reset.
  void _resetLivePedometer() {
    _workoutController.rebaseWorkoutSteps();
    _magMin.clear();
    _committedRaw = 0;
    _lastLiveUiNotifyMs = 0;
    _imuStreamSeen = false;
    // The measured rate is a property of THIS link — a reconnect must re-measure
    // rather than carry a verdict (or a "too slow" note) across the gap.
    _chunkStartMs = null;
    _liveHz = null;
    _liveHzLogged = false;
    _liveTooSlow = false;
    _liveCoverStartTs = null;
    _liveFirstIngestMs = null;
    _liveLastIngestMs = null;
    _gaitRuns.clear();
  }

  /// End-of-session: bank the REAL 100 Hz step spans into `live_coverage`.
  ///
  /// ONE ROW PER GAIT RUN, not one per session. The single row this replaces
  /// spanned the whole connected hull, so it claimed the still hours between
  /// two walks as measured coverage — see live_step_runs.dart for the
  /// measurement off the owner's own export that killed it.
  ///
  /// No cadence calibration any more — its only consumer was the deleted 1 Hz
  /// `dailyStepEstimate` (see kAlgoVersion v55).
  Future<void> _finalizeLivePedometer() async {
    // The still-filling partial minute is real signal that was about to be
    // discarded: count it over the time it actually sampled — but only if that
    // time says it arrived fast enough to count (GATE 2). The tail has its own
    // measurable span, so it is measured on its own rather than inheriting the
    // last chunk's rate.
    final tailHz = achievedSampleRateHz(
      _magMin.length,
      _chunkStartMs,
      _liveLastIngestMs,
    );
    if (_magMin.isNotEmpty &&
        _liveLastIngestMs != null &&
        tailHz != null &&
        tailHz >= kMinLiveSampleRateHz) {
      _addGaitChunk(_liveLastIngestMs!, _magMin.length, ana.pedometer(_magMin));
    }
    final runs = _gaitRuns.runs;
    _resetLivePedometer();
    await _bankGaitRuns(runs);
    // The session ended cleanly and is now durably recorded — the checkpoint
    // that would otherwise let a killed-process session recover is no longer
    // needed.
    await _clearLiveSessionCheckpoint();
  }

  /// Persist [runs] as `live_coverage` rows under the STRAP source.
  ///
  /// `ana.StepParams.gain` is applied HERE and nowhere else on the persistence
  /// path — the runs carry the raw count exactly as `pedometer()` returns it,
  /// and this is the daily-sum layer `calcSteps` documents as the gain's home.
  /// Applying it at both ends shipped a silent x1.23.
  Future<void> _bankGaitRuns(List<LiveStepRun> runs) async {
    for (final run in runs) {
      final steps = (run.rawSteps * ana.StepParams.gain).round();
      if (steps <= 0) continue;
      // Per RUN, so a walk either side of midnight lands on the right days
      // instead of both going to whichever day the session started on.
      final day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(run.startTs * 1000),
      );
      await LocalDb.addLiveCoverage(
        run.startTs,
        run.endTs,
        steps,
        day,
        source: kStepSourceStrap,
      );
    }
  }

  // Whatever accrued via _committedRaw/_magMin between minute-commits is
  // in-memory ONLY — if the OS kills the app (backgrounded walk, phone
  // reboot) mid-session, none of it was ever going to reach
  // _finalizeLivePedometer, so it just vanished with no trace and no
  // fallback (the 1 Hz estimator only backfills minutes a coverage row
  // says are UNCOVERED). Checkpoint the committed total once a minute so
  // the next session start can recover it instead of losing it outright.
  static const String _kLiveSessionCheckpoint = 'live_session_checkpoint';

  Future<void> _checkpointLiveSession() async {
    if (_gaitRuns.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kLiveSessionCheckpoint,
        // Runs are stored gain-applied, i.e. exactly the numbers
        // [_bankGaitRuns] would have written — recovery banks them verbatim, so
        // this path has one gain application too. Rewritten whole each minute
        // (the open run keeps growing), never appended to.
        jsonEncode({
          'runs': [
            for (final r in _gaitRuns.runs)
              [r.startTs, r.endTs, (r.rawSteps * ana.StepParams.gain).round()],
          ],
        }),
      );
    } catch (e) {
      _log('[steps] checkpoint skipped: $e');
    }
  }

  Future<void> _clearLiveSessionCheckpoint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLiveSessionCheckpoint);
    } catch (_) {
      // best-effort
    }
  }

  /// Recover a checkpoint left behind by a session that never reached
  /// [_finalizeLivePedometer] (the process was killed, not a clean
  /// disconnect) — folds the committed steps into `live_coverage` just like
  /// a normal session end, so a killed background walk doesn't just vanish.
  /// Call this BEFORE starting a fresh session ([_resetLivePedometer]).
  /// Single-flight: two entry points can now call this (openSession's full
  /// connect and the background cold-launch branch). Interleaving them would
  /// let both read the checkpoint before either removed it, and
  /// `live_coverage` is an append-only SUM with no window uniqueness — the
  /// duplicate would silently inflate the day's real steps.
  Future<void>? _orphanRecovery;

  Future<void> _recoverOrphanedLiveSession() =>
      _orphanRecovery ??= _recoverOrphanedLiveSessionOnce().whenComplete(() {
        _orphanRecovery = null;
      });

  Future<void> _recoverOrphanedLiveSessionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLiveSessionCheckpoint);
      if (raw == null || raw.isEmpty) return;
      // Durable-FIRST, like everywhere else in this codebase (commit-before-ACK
      // is the same rule): the checkpoint is only dropped once its steps are
      // banked, so a kill anywhere in here re-runs the recovery rather than
      // losing the bout. Replay is safe because of the coverage-window check
      // below and because this method is single-flight. The one exception is a
      // checkpoint that can never be recovered — dropped immediately so it
      // can't be retried on every single connect forever.
      Future<void> drop() => prefs.remove(_kLiveSessionCheckpoint);
      final m = jsonDecode(raw);
      if (m is! Map) return await drop();
      // `runs` is the current shape. A checkpoint written by the PREVIOUS build
      // carries a single session-hull window instead; it is recovered as one
      // run, through the derivation that wrote it, so an in-flight walk is not
      // lost to the upgrade.
      final spans = <List<int>>[];
      final storedRuns = m['runs'];
      if (storedRuns is List) {
        for (final r in storedRuns) {
          if (r is! List || r.length < 3) continue;
          final s = (r[0] as num).toInt();
          final e = (r[1] as num).toInt();
          final n = (r[2] as num).toInt();
          if (n > 0 && e > s) spans.add([s, e, n]);
        }
      } else {
        final steps = (m['steps'] as num?)?.toInt() ?? 0;
        final startTs = (m['cover_start_ts'] as num?)?.toInt();
        final endTs = (m['cover_end_ts'] as num?)?.toInt();
        if (steps > 0 && startTs != null && endTs != null && endTs > startTs) {
          final window = deriveLiveCoverageWindow(
            steps: steps,
            samples100Hz: (m['samples'] as num?)?.toInt() ?? 0,
            bandStartTs: startTs,
            bandEndTs: endTs,
            firstIngestMs: (m['first_ingest_ms'] as num?)?.toInt(),
            lastIngestMs: (m['last_ingest_ms'] as num?)?.toInt(),
          );
          if (window != null) spans.add([window.startTs, window.endTs, steps]);
        }
      }
      if (spans.isEmpty) return await drop();
      var recovered = 0;
      for (final s in spans) {
        // The clean-shutdown path writes coverage BEFORE clearing the
        // checkpoint, so a kill in that gap leaves a checkpoint whose runs are
        // already banked — and `live_coverage` has no uniqueness on the window,
        // so replaying it would silently inflate the day. Skip what is already
        // recorded.
        if (await LocalDb.hasLiveCoverageWindow(s[0], s[1])) continue;
        final day = dayLabelOf(
          DateTime.fromMillisecondsSinceEpoch(s[0] * 1000),
        );
        await LocalDb.addLiveCoverage(
          s[0],
          s[1],
          s[2],
          day,
          source: kStepSourceStrap,
        );
        recovered += s[2];
      }
      await drop();
      if (recovered == 0) {
        _log('[steps] orphan checkpoint already banked — not re-adding');
      } else {
        _log('[steps] recovered $recovered orphaned step(s) '
            'from a killed session');
      }
    } catch (e) {
      _log('[steps] orphan recovery skipped: $e');
    }
  }

  /// "Charge it now or lose tonight" — the one battery warning that is about
  /// DATA rather than about the battery.
  ///
  /// A band that dies at 03:00 costs the whole night: no nocturnal HRV, no
  /// stages, no recovery score in the morning, and a hole in the rolling
  /// baselines that quietly degrades baseline-relative metrics for days. The
  /// band has been reporting battery every few minutes and we have been
  /// persisting it all along, so the drain rate needed to see this coming was
  /// already on disk.
  ///
  /// Deliberately conservative. It fires only in the evening run-up to bedtime
  /// (while there is still time to act), only when the projection actually
  /// lands under the reserve, and never on an abstention — an unknown rate must
  /// stay silent, because the user can always read the battery number
  /// themselves and a false "you're fine" is worse than no message at all.
  Future<void> _maybeWarnOvernightBattery() async {
    try {
      final now = DateTime.now();
      final last = _lastBatteryForecastAt;
      if (last != null && now.difference(last) < const Duration(minutes: 15)) {
        return;
      }
      // Clock-only pre-gate: this runs off _onEngineState, which fires ~1 Hz
      // during live HR — and the 15-min stamp above is (deliberately) written
      // only once the evening-window check passes, so outside the window every
      // tick fell through to the prefs load below. One check per wall-clock
      // minute is plenty; the first tick of a minute still runs the full path,
      // so the first evening forecast is delayed by <1 min at most.
      final gateMin = now.hour * 60 + now.minute;
      if (gateMin == _lastForecastGateMin) return;
      _lastForecastGateMin = gateMin;

      final prefs = await NotificationPrefs.load();
      final nowMin = now.hour * 60 + now.minute;
      if (!BatteryForecaster.inEveningWindow(nowMin, prefs.quietStartMin)) {
        return;
      }
      // Stamped only once the cheap checks have PASSED, so the throttle governs
      // the expensive work (a few hundred rows off `band_battery`) rather than
      // the clock check. Stamping earlier meant a tick that arrived just before
      // the evening window opened would push the first real forecast back by up
      // to another 15 minutes for no reason.
      _lastBatteryForecastAt = now;

      final rows = await LocalDb.recentBandBatterySamples(limit: 400);
      final samples = <BatterySample>[
        for (final r in rows)
          if (r['battery_pct'] != null && r['ts'] != null)
            BatterySample(
              tsSec: (r['ts'] as num).toInt(),
              pct: (r['battery_pct'] as num).toDouble(),
              charging: (r['charging'] as num?)?.toInt() == 1,
            ),
      ];

      const forecaster = BatteryForecaster();
      final wakeAt = BatteryForecaster.nextWakeTime(now, prefs.quietEndMin);
      final f = forecaster.forecast(samples: samples, now: now, wakeAt: wakeAt);
      if (!forecaster.willNotSurvive(f)) return;

      final day = todayLabel(now);
      await NotificationCenter.instance.emit(
        NotificationEvent(
          dedupeKey: '$day:battery_overnight',
          category: NotifCategory.device,
          title: 'Charge your strap before bed',
          body: BatteryForecaster.describe(f, wakeAt: wakeAt),
          date: day,
          route: '/profile',
        ),
        // This runs off the BLE state pipeline, which is headless on both
        // platforms — the same reason DeviceAlerts' sink passes false. An OS
        // authorization prompt with no foreground scene to show it in is a
        // prompt the user never sees and cannot answer.
        allowPermissionPrompt: false,
      );
    } catch (e) {
      // A forecast is a nicety; it must never take down the state update that
      // carries the actual band data.
      _log('[battery-forecast] skipped: $e');
    }
  }

  /// The last readings the live stream delivered, newest last.
  ///
  /// Lives here rather than in the widget that draws it: `lib/ui2` is
  /// presentation, and a `Timer.periodic` inside a card is both a design-system
  /// violation (see the ungated-Duration rule) and a trace that resets every
  /// time the screen is opened. The engine already pushes state at about 1 Hz
  /// while streaming, so appending here is the natural sampling point.
  static const int liveHrTraceMax = 90;

  /// A RECORD PER SAMPLE, not a bare bpm. Two devices streaming at once is two
  /// signals, and a flat `List<int>` drew them as one line with one headline
  /// (final-plan §5.2). The `deviceId` is what lets the card show exactly ONE
  /// device's trace — never a merge, never an average, never two traces on one
  /// card.
  ///
  /// STILL NEVER PERSISTED (invariant 1). RAM, capped at [liveHrTraceMax] PER
  /// DEVICE.
  final List<({int at, int hr, String deviceId})> _liveHrTrace = [];

  /// Last delivered stamp PER DEVICE — what the old scalar was always trying
  /// to be. Two devices reporting in the same second are two samples; one
  /// device reporting the same stamp twice is one.
  final Map<String, int> _liveHrTraceAt = {};

  /// One device's recent readings, newest last, bpm only — the shape
  /// `LiveHrCard` already draws. Null [deviceId] means [liveHrDeviceId], the
  /// device the priority order says wins.
  List<int> liveHrTrace([String? deviceId]) {
    final id = deviceId ?? liveHrDeviceId;
    if (id == null) return const [];
    return [for (final e in _liveHrTrace) if (e.deviceId == id) e.hr];
  }

  /// Bumped on every appended sample. A `select` on the trace's LENGTH stops
  /// firing the moment the buffer is full — length is pinned at
  /// [liveHrTraceMax] from then on — so a card watching length would draw the
  /// first 90 readings and then freeze while the numbers kept arriving. This is
  /// the thing that actually changes.
  int liveHrTraceRev = 0;

  /// The devices' priority order for `hr1Hz`, highest first. Loaded once and
  /// refreshed with the device rows — a `signal_priority` row changes only when
  /// the user changes it, which is the same reason `_sensors` does not poll.
  List<String> _hrPriority = const [];

  bool _isStreaming(String id) {
    final at = _liveHrTraceAt[id];
    return at != null &&
        DateTime.now().millisecondsSinceEpoch - at <= liveHrMaxAge.inMilliseconds;
  }

  /// THE DEVICE WHOSE LIVE TRACE IS SHOWN, or null when nothing is streaming.
  ///
  /// The resolver's rule — exclusive ownership — applied to the live axis. Not
  /// merged, not averaged, not interleaved. Resolved from [_hrPriority] against
  /// the in-memory dedupe map, so it costs no query and works while the app is
  /// mid-stream with no derived day in sight.
  String? get liveHrDeviceId {
    final override = _liveHrDeviceOverride;
    if (override != null && _isLive(override)) return override;
    for (final id in _hrPriority) {
      if (_isLive(id)) return id;
    }
    // No priority row for any streaming device: fall through to the physics
    // ladder, which is precedence rule 3 (final-plan §4.5). `rankSources`
    // already answers it and needs no table.
    for (final s in rankSources(liveSources(this))) {
      final id = s.isBand ? LocalDb.kPrimaryDeviceId : s.deviceId;
      if (id != null && _isLive(id)) return id;
    }
    return null;
  }

  /// Streaming, and not a workout sensor whose flag is off. Rule R6: a
  /// flag-off strap is never the live device, so it scores nothing in a
  /// workout (peak, zones, strain, calories all read [liveHr]).
  bool _isLive(String id) =>
      _isStreaming(id) &&
      !(id == _hrsTraceId &&
          !LocalDb.sessionSensorSources.contains(kBleHrs.id)) &&
      !(id == _pmdTraceId &&
          !LocalDb.sessionSensorSources.contains(kPolarPmd.id));

  /// TWO OR MORE DEVICES HAVE DELIVERED A LIVE READING INSIDE [liveHrMaxAge]
  /// — i.e. are streaming, not merely paired.
  ///
  /// Read off the in-memory dedupe map, which is the only place that knows.
  /// No query, and nothing persisted (invariant 1).
  /// A flag-off strap is not counted ([_isLive]): its pill would set an
  /// override [liveHrDeviceId] refuses, a tap that does nothing.
  bool get liveHrMultiDevice {
    if (_liveHrTraceAt.length < 2) return false;
    var live = 0;
    for (final id in _liveHrTraceAt.keys) {
      if (_isLive(id) && ++live >= 2) return true;
    }
    return false;
  }

  /// Whether the card's pill may switch to [id] ([_isLive]).
  bool liveHrSelectable(String id) => _isLive(id);

  /// The user's tap on the card's pill. Session-only and deliberately NOT
  /// persisted: it is "show me the other one for a moment", not a preference.
  /// A preference is `signal_priority`, and the way to set one is the metric
  /// screen's "Prefer this device" or the priority editor.
  String? _liveHrDeviceOverride;
  void showLiveHrFrom(String? deviceId) {
    _liveHrDeviceOverride = deviceId;
    liveHrTraceRev++; // the card watches this, not the map
    notifyListeners();
  }

  /// ONE SAMPLE PER DELIVERED READING PER DEVICE. Keyed on (device, stamp):
  /// keyed on the stamp alone, a second band reporting in the same second was
  /// dropped and which one survived depended on notification arrival order.
  ///
  /// The ONE way a reading enters the trace, whichever radio delivered it —
  /// the band's engine state or a `HrsLink` sensor's notifier. A second
  /// append path is a second dedupe rule, and the pair of them is what makes
  /// `liveHrMultiDevice` disagree with the chart. Returns true when it took
  /// the sample, i.e. when a listener has something new to draw.
  bool _appendLiveHr(String deviceId, int? hr, int? at) {
    if (hr == null || hr <= 0 || at == null || at == _liveHrTraceAt[deviceId]) {
      return false;
    }
    _liveHrTraceAt[deviceId] = at;
    _liveHrTrace.add((at: at, hr: hr, deviceId: deviceId));
    // The cap is PER DEVICE, so a second band cannot evict the first band's
    // trace by streaming faster.
    // ponytail: reverse scan is O(n) at n <= 90 * devices, once per
    // delivered reading (~1 Hz). A per-device ring buffer is the upgrade if
    // a device count ever makes that matter, which two bands does not.
    var n = 0;
    for (var i = _liveHrTrace.length - 1; i >= 0; i--) {
      if (_liveHrTrace[i].deviceId != deviceId) continue;
      if (++n > liveHrTraceMax) {
        _liveHrTrace.removeAt(i);
        break;
      }
    }
    liveHrTraceRev++;
    return true;
  }

  /// Forget one device's live trace. A dropped link ends a session; the next
  /// one is not a continuation of it, and splicing the two draws a line across
  /// a gap that never happened.
  bool _clearLiveHrTrace(String deviceId) {
    if (!_liveHrTraceAt.containsKey(deviceId)) return false;
    _liveHrTrace.removeWhere((e) => e.deviceId == deviceId);
    _liveHrTraceAt.remove(deviceId);
    liveHrTraceRev++;
    return true;
  }

  /// The HRS sensor whose samples are in the trace right now. Remembered
  /// because [HrsLink.disarm] drops its host BEFORE it clears the reading, so
  /// the disarm tick cannot name the device it is ending.
  String? _hrsTraceId;

  /// Same as [_hrsTraceId], for the second notify-class sensor. Both can be
  /// armed at once (`kMaxConcurrentSecondaryLinks` is 2), each keyed under
  /// its own `device_id` in `_liveHrTrace`, so one trace id each is enough —
  /// no shared state between the two listeners.
  String? _pmdTraceId;

  /// A paired heart-rate sensor's reading, into the SAME trace the band's
  /// engine state feeds.
  ///
  /// Without this the multi-device live axis is structurally dead in
  /// production: `_onEngineState` only ever runs for the primary band, so
  /// `_liveHrTraceAt` never held a second key, `liveHrMultiDevice` was always
  /// false and `liveHrDeviceId` could never name the strap that was actually
  /// measuring. NOT a second persistence path — nothing here writes; the
  /// sensor's own rows are banked by `BandHost` (invariant 1 unchanged).
  ///
  /// Oura is deliberately absent: the ring has no live link and delivers no
  /// live reading at all, so it has nothing to select between.
  void _onHrsReading() {
    if (_disposed) return;
    final r = HrsLink.instance.reading.value;
    final id = HrsLink.instance.deviceId ?? _hrsTraceId;
    if (id == null) return;
    if (r == null) {
      // Disarmed. Same rule as the band's disconnect below.
      _hrsTraceId = null;
      if (_clearLiveHrTrace(id)) notifyListeners();
      return;
    }
    // `HrsReading()` with no bpm is the armed-but-searching state, not a
    // measurement — it is never billed as one.
    _hrsTraceId = id;
    final atSec = r.atSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_appendLiveHr(id, r.bpm, atSec * 1000)) notifyListeners();
  }

  /// Same wiring as [_onHrsReading], for `PolarPmdLink` — a second, parallel
  /// live-reading source, not a widening of the first (see that link's own
  /// doc). Without this a Polar sensor's PPI-derived beats arm/disarm the
  /// link but never reach `liveHr`, workout zones, or the live trace.
  void _onPmdReading() {
    if (_disposed) return;
    final r = PolarPmdLink.instance.reading.value;
    final id = PolarPmdLink.instance.deviceId ?? _pmdTraceId;
    if (id == null) return;
    if (r == null) {
      _pmdTraceId = null;
      if (_clearLiveHrTrace(id)) notifyListeners();
      return;
    }
    _pmdTraceId = id;
    final atSec = r.atSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_appendLiveHr(id, r.bpm, atSec * 1000)) notifyListeners();
  }

  void _onEngineState(String deviceId, DeviceState s) {
    if (_resetting) return; // see [_resetting]
    _appendLiveHr(deviceId, s.liveHr, s.liveHrAt);
    // Bank the name the moment the band says it, so it survives the
    // disconnect. Written through `cleanDeviceLabel` for the same reason the
    // BLE side reads through it: a garbled response must never become the
    // remembered name. Change-gated on the RAW value first (same pattern as
    // _widgetBattName below): this handler fires ~1 Hz during live HR, and
    // cleanDeviceLabel's regex work per tick is pure waste when the name
    // hasn't moved.
    // WHICH band this is, the moment the link says so — service discovery is
    // the only place it is ever known, and `_persistPaired` runs before any
    // session exists. Without this `device.adapter_id` (schema 49) is
    // structurally blank for everyone who paired once, and every per-family
    // metric abstains for a reason that is our bookkeeping, not the band's.
    // Change-gated: this handler fires ~1 Hz during live HR.
    if (s.generation != null && s.generation != _lastSeenGeneration) {
      _lastSeenGeneration = s.generation;
      unawaited(LocalDb.upsertDevice(adapterId: s.generation));
    }
    if (s.strapName != _lastSeenStrapNameRaw) {
      _lastSeenStrapNameRaw = s.strapName;
      final nm = cleanDeviceLabel(s.strapName);
      if (nm != null && nm != Prefs.getString(_kStrapName, '')) {
        Prefs.setString(_kStrapName, nm);
      }
    }
    // Battery-low / charging OS notifications (edge-triggered + de-duped inside).
    _deviceAlerts.onDeviceState(
      batteryPct: s.batteryPct,
      charging: s.charging,
      chargingTs: s.chargingTs,
    );
    final roundedPct = s.batteryPct?.round();
    if (roundedPct != _storedBatteryPct ||
        s.charging != _storedBatteryCharging ||
        s.wristOn != _storedBatteryWristOn) {
      _storedBatteryPct = roundedPct;
      _storedBatteryCharging = s.charging;
      _storedBatteryWristOn = s.wristOn;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      unawaited(
        LocalDb.insertBandBatterySample(
          ts: nowSec,
          // `_onEngineState` drives the PRIMARY band's engine, so this is the
          // real originating device, not a placeholder.
          deviceId: LocalDb.kPrimaryDeviceId,
          batteryPct: roundedPct?.toDouble(),
          charging: s.charging,
          wristOn: s.wristOn,
          source: 'device_state',
        ),
      );
    }
    // A fresh battery reading is exactly when the overnight forecast is worth
    // re-running — and only then, so this costs nothing on idle ticks.
    unawaited(_maybeWarnOvernightBattery());
    // Heal a stale/garbled persisted serial: once the band reports a clean serial
    // (HELLO body, fixed offset), persist it so the disconnected display stops
    // showing any old "?*" junk left by a previous build. HEAL ONLY — see
    // [healedPairing]: this must never CREATE a pairing.
    final healed = healedPairing(paired, s.serial);
    if (healed != null) {
      paired = healed;
      unawaited(PairedDevice.save(healed.remoteId, healed.serial,
          generation: s.generation));
    }
    // Pin the discovered generation onto the pairing record (HEAL ONLY — same
    // rule as the serial above: never CREATE a pairing here). A known-device
    // reconnect skips scanning, and the official gen5 connect order differs
    // before discovery, so the next connect needs this persisted hint.
    final p = paired;
    if (p != null &&
        (s.generation == 'gen4' || s.generation == 'gen5') &&
        s.generation != p.generation) {
      paired =
          PairedDevice(p.remoteId, p.serial, generation: s.generation);
      unawaited(
          PairedDevice.save(p.remoteId, p.serial, generation: s.generation));
    }
    // WHOOP MG identity, remembered per serial so the ECG entry survives a
    // disconnect. Set only from a positive revision-1 MAVERICK hello — never
    // from the family, the name or a command's acceptance.
    final mgSerial = paired?.serial;
    if (!pairedIsMaverick && engine.isMaverick && mgSerial != null) {
      pairedIsMaverick = true;
      unawaited(_ecgGuard.rememberMaverick(mgSerial));
    }
    // Keep the lock-screen Band Battery widget current — only when it changed.
    final battPct = roundedPct ?? -1;
    if (battPct != _widgetBattPct ||
        s.charging != _widgetBattCharging ||
        s.strapName != _widgetBattName) {
      _widgetBattPct = battPct;
      _widgetBattCharging = s.charging;
      _widgetBattName = s.strapName;
      unawaited(
        WidgetService.pushBattery(
          s.batteryPct == null ? null : battPct,
          s.charging,
          s.strapName,
        ),
      );
    }
    if (_prevConn != 'disconnected' && s.connection == 'disconnected') {
      // Live stream ended → bank this bout's step window into `live_coverage`
      // and reset the counter. (No cadence calibration is involved: it was
      // removed with the 1 Hz step estimator at v55/v56.)
      unawaited(_finalizeLivePedometer());
      // A new connection is a new live-HR session: without this the trace
      // buffer spliced readings from before the drop (or from a previously
      // paired band) onto the next session's chart as one continuous line.
      // THIS device only — a second device's trace is a separate session.
      _clearLiveHrTrace(deviceId);
      _sync.onLinkDropped();
    }
    if (_prevConn != 'connected' && s.connection == 'connected') {
      // A Tasker BUZZ_STRAP that arrived while disconnected/dead only gets a
      // bounded wait inside _checkPendingTaskerBuzz (called from _init()) —
      // if that timed out before this connection landed, nothing else was
      // going to retry it before a full process restart (see PR #89 review).
      // Re-check on every fresh "became connected" transition instead; the
      // method no-ops instantly if nothing's pending, and is single-flight
      // guarded against overlapping with its own in-progress wait.
      unawaited(_checkPendingTaskerBuzz());
    }
    _prevConn = s.connection;
    notifyListeners();
  }

  // ── pairing (LOCAL only) ────────────────────────────────────────────────────
  Future<BluetoothDevice?> scanForBand() => engine.scan();

  /// True on iOS 18+, where pairing must go through the AccessorySetupKit picker so
  /// the band is provisioned for iOS-26 background relaunch (TN3115). False on Android
  /// and iOS < 18 — those use the service-filtered scan flow ([scanForBand]/[pairWith]).
  Future<bool> accessorySetupSupported() => AccessorySetup.isSupported();

  /// iOS 18+ pairing: show the ASK picker, persist the provisioned band by its
  /// CoreBluetooth UUID (== flutter_blue_plus remoteId), then open the session. Throws
  /// if the user cancels or no accessory is provisioned. The picker is skipped (returns
  /// the known id) if a WHOOP is already provisioned via ASK.
  Future<void> pairViaAccessorySetup({String? serial}) async {
    final remoteId = await AccessorySetup.showPicker();
    // CRITICAL ORDERING: the ASK picker has now provisioned the accessory. Only NOW is it
    // safe for the native restore central (BleRestoreManager) to exist — it was deferred
    // at launch on a fresh install so showPicker could run with no CBCentralManager alive.
    // Create it here, BEFORE _persistPaired → openSession touches flutter_blue_plus.
    await IosBleRestore.provisioned(remoteId);
    await _persistPaired(remoteId, serial);
  }

  Future<void> pairWith(BluetoothDevice d, {String? serial}) async {
    await _persistPaired(d.remoteId.str, serial);
  }

  Future<void> _persistPaired(String remoteId, String? serial) async {
    // Which band this is, if the link has already said. Passed HERE and not at
    // the two call sites (`pairWith`, `pairViaAccessorySetup`) so neither can
    // forget it — and COALESCE'd inside `upsertDevice`, so a null leaves
    // whatever the row already knows.
    //
    // It is null on a FIRST pair, always: `DeviceState.generation` is only set
    // at service discovery and pairing runs before any session exists. That is
    // why `_onEngineState` stamps it too — this line alone would leave
    // `device.adapter_id` blank on every install that pairs once and never
    // re-pairs.
    await PairedDevice.save(remoteId, serial ?? device.serial,
        generation: device.generation);
    paired = await PairedDevice.load();
    // Now that there's a band to alert about, ask for notification permission
    // (a natural moment; battery/charging alerts depend on it). Best-effort.
    unawaited(NotificationService.instance.ensurePermission());
    // Android: associate the band with CompanionDeviceManager (one-time system
    // dialog) so the OS lets us restart the tracking service from the
    // background and — API 31+ — relaunches us when the band appears.
    // Fire-and-forget: logging happens inside; pairing must never block on it.
    unawaited(AndroidBackground.associateCompanion(remoteId));
    notifyListeners();
    await openSession();
  }

  // ── Android background keep-alive (battery-optimization exemption) ──────────
  /// Whether the app is exempt from battery optimizations (always true on iOS).
  Future<bool> isIgnoringBatteryOptimizations() =>
      AndroidBackground.isIgnoringBatteryOptimizations();

  /// Fire the system "ignore battery optimizations" request dialog (Android).
  Future<void> requestIgnoreBatteryOptimizations() =>
      AndroidBackground.requestIgnoreBatteryOptimizations();

  /// True when this device's OEM (Xiaomi/Huawei/Honor/Oppo/Vivo/OnePlus) is
  /// known to gate background survival behind an extra autostart/protected-
  /// apps allowlist the stock battery-optimization exemption doesn't cover.
  /// Always false on iOS.
  Future<bool> needsOemAutostartSettings() =>
      AndroidBackground.needsOemAutostartSettings();

  /// Open this OEM's autostart allowlist screen (falls back to the app's
  /// standard settings page if none exists on this device).
  Future<void> openOemAutostartSettings() =>
      AndroidBackground.openOemAutostartSettings();

  Future<void> unpair() async {
    await _sync.unpairSession();
    await PairedDevice.clear();
    pairedIsMaverick = false;
    // Everything the old band told us about itself. The engine's DeviceState
    // lives as long as the process and the persisted strap name outlives even
    // that, so without both of these a re-pair — with a DIFFERENT band —
    // inherits the forgotten one's name, serial, generation and bond verdicts.
    device.reset();
    Prefs.setString(_kStrapName, '');
    // AND THE CHANGE GATES THAT GUARD WHAT THOSE TWO LINES JUST CLEARED. Both
    // are per-tick caches in [_onEngineState], and both compare against the
    // OLD band: pair a second band that reports the same generation and the
    // `device.adapter_id` write is skipped, leaving the new pairing's adapter
    // structurally blank (schema 49) and every per-family metric abstaining for
    // a reason that is our bookkeeping. Same for a same-named band and the
    // strap-name pref this method just emptied.
    _lastSeenGeneration = null;
    _lastSeenStrapNameRaw = null;
    paired = null;
    notifyListeners();
  }

  // ── alarm + strap name (require a live connection) ──────────────────────────
  bool get isConnected => device.connection == 'connected';

  /// How old a live HR reading may be and still be a reading of NOW.
  ///
  /// CALIBRATION KNOB. The foreground stream delivers roughly 1 Hz, so this is
  /// about ten missed frames: long enough to ride out a radio hiccup, short
  /// enough that a band which stopped reporting is not still being billed as a
  /// live measurement. Widen it if real straps turn out to gap more than this
  /// under load.
  static const Duration liveHrMaxAge = Duration(seconds: 10);

  /// The band's heart rate RIGHT NOW, or null when there isn't one.
  ///
  /// `DeviceState.liveHr` on its own is only "the last value the engine saw":
  /// nothing clears it on an unintentional drop (only an applied HR OFF does),
  /// so it keeps reading like a measurement long after
  /// the band is gone. Freshness rather than connection alone is the test,
  /// because it also covers the connected-but-stalled stream, which no
  /// disconnect hook can see. Every live consumer must read THIS.
  int? get liveHr {
    final id = liveHrDeviceId;
    if (id != null) {
      // The newest sample from the device that won, which is by construction
      // inside `liveHrMaxAge` (that is what `_isStreaming` tested).
      //
      // THE BAND'S CONNECTION IS NOT THE GATE HERE. `liveHrDeviceId` can name
      // a chest strap or a ring driven by `HrsLink` over its own GATT link,
      // and `isConnected` reads the PRIMARY band's engine state. Gating on it
      // meant that starting a workout with the strap on and the band on its
      // charger returned null from a device that was streaming: `_tickWorkout`
      // then banked no zone seconds, no strain and no calories from a real
      // measurement. `_isStreaming` is already the stricter freshness test.
      for (var i = _liveHrTrace.length - 1; i >= 0; i--) {
        if (_liveHrTrace[i].deviceId == id) return _liveHrTrace[i].hr;
      }
    }
    // The fallback below IS the band's, so it keeps the band's gate.
    if (!isConnected) return null;
    // FALLBACK: nothing in the trace yet — a caller that sets `DeviceState`
    // directly without going through `_onEngineState` (every existing test,
    // and any future path that bypasses the engine callback). The original
    // single-device freshness check on `device.liveHr` itself, so behaviour
    // stays byte-identical for anything that never reaches the trace.
    final at = device.liveHrAt;
    if (at == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    if (age > liveHrMaxAge.inMilliseconds) return null;
    return device.liveHr;
  }
  // The locally-set value is authoritative: the band has no independent alarm
  // source (its alarm is always what the app last wrote, and SET_ALARM is
  // HW-verified), while the GET_ALARM readback format is unconfirmed and was
  // clobbering the display (see the parked block in ble_engine._onDecoded).
  // device.alarmEpoch = this-session optimistic set; _savedAlarm = persisted.
  int? get alarmEpoch => device.alarmEpoch ?? _savedAlarm;
  /// The band's advertising name, LAST KNOWN when the link has not answered.
  ///
  /// `DeviceState.strapName` only exists after a connect and a GET round-trip,
  /// and [PairedDevice] persists the remote id and serial but never this — so
  /// every cold start, and every minute spent disconnected, showed the generic
  /// "WHOOP band" instead of whatever the user named their strap. A name the
  /// band told us once does not stop being true while the radio is off.
  static const String _kStrapName = 'band.strap_name';
  String? get strapName {
    final live = device.strapName;
    if (live != null && live.isNotEmpty) return live;
    final saved = Prefs.getString(_kStrapName, '');
    return saved.isEmpty ? null : saved;
  }
  int? _savedAlarm;

  // ── weekly alarm schedule (replaces a single next-occurrence value) ────────
  // The 7-day schedule lives in `alarm_schedule` (lib/data/db.dart); this cache
  // is always exactly 7 entries (see fillDefaultAlarmSchedule) so the UI can
  // render every weekday row unconditionally, and [_armNextAlarmOccurrence]
  // never has to special-case a weekday nobody has touched.
  List<AlarmScheduleEntry> _schedule = fillDefaultAlarmSchedule(const []);
  List<AlarmScheduleEntry> get alarmSchedule => _schedule;

  Future<void> _loadAlarmSchedule() async {
    try {
      final rows = await LocalDb.alarmScheduleRows();
      _schedule = fillDefaultAlarmSchedule(
          [for (final r in rows) AlarmScheduleEntry.fromRow(r)]);
    } catch (e) {
      _log('[alarm] schedule load failed: $e');
    }
  }

  /// One-time 49→50 seed: a legacy single-alarm value with nothing yet in
  /// `alarm_schedule` becomes that weekday's slot. Safe to call on every
  /// launch — it is a no-op the moment ANY row exists, including a schedule
  /// the user has since cleared via Cancel-all, which must stay cleared
  /// rather than resurrect the old value.
  Future<void> _seedAlarmScheduleFromLegacyIfNeeded() async {
    try {
      if (_savedAlarm == null) return;
      final rows = await LocalDb.alarmScheduleRows();
      if (rows.isNotEmpty) return;
      final seed = seedEntryFromLegacyEpoch(_savedAlarm!);
      await LocalDb.setAlarmScheduleDay(
        weekday: seed.weekday,
        hour: seed.hour,
        minute: seed.minute,
        enabled: seed.enabled,
      );
      await _loadAlarmSchedule();
    } catch (e) {
      _log('[alarm] legacy schedule seed failed: $e');
    }
  }

  /// Change one weekday's slot and re-arm immediately when connected —
  /// waiting for the next connect/sync would leave the band holding the OLD
  /// schedule while the screen already claims the new one.
  Future<void> setScheduleDay({
    required int weekday,
    int? hour,
    int? minute,
    bool? enabled,
    int? smartWindowMinutes,
  }) async {
    final current = _schedule.firstWhere(
      (e) => e.weekday == weekday,
      orElse: () => AlarmScheduleEntry(
          weekday: weekday,
          hour: defaultAlarmHour,
          minute: defaultAlarmMinute,
          enabled: false),
    );
    final next = current.copyWith(
      hour: hour,
      minute: minute,
      enabled: enabled,
      smartWindowMinutes: smartWindowMinutes,
    );
    await LocalDb.setAlarmScheduleDay(
      weekday: next.weekday,
      hour: next.hour,
      minute: next.minute,
      enabled: next.enabled,
      smartWindowMinutes: next.smartWindowMinutes,
    );
    await _loadAlarmSchedule();
    notifyListeners();
    if (isConnected) await _armNextAlarmOccurrence();
  }

  /// Compute + arm the next scheduled occurrence, skipping the write when it
  /// already matches what's armed (don't hammer the strap on every sync).
  /// Called after every successful connect and after each sync completes —
  /// see the `_armNextAlarmOccurrence()` call sites in openSession,
  /// _reconnect, and their `_kickSyncBurst` completion callbacks — so an
  /// edited schedule or a just-fired alarm re-arms with no manual step, and a
  /// fired one-shot (which clears `_savedAlarm`) picks up its next occurrence
  /// on the very next connect.
  /// Restore the confirmation machine for a persisted arm. `setAtMs` is the
  /// REAL arm time (`alarm_set_at_ms`), not now: it is the floor the replay
  /// gate holds a strap event 56 against, and a late genuine 56 delivered
  /// after a relaunch is stamped at the original arm. An arm persisted before
  /// that key existed gets 0, i.e. no floor (the old accept-any behaviour).
  void _seedAlarmFromPrefs(int epoch, SharedPreferences prefs) {
    _alarm.set(epoch, prefs.getInt('alarm_set_at_ms') ?? 0);
    _alarm.confirmed = prefs.getBool('alarm_epoch_confirmed') ?? false;
  }

  Future<void> _armNextAlarmOccurrence({int? firedEpoch}) async {
    if (!isConnected) return;
    try {
      // A headless re-arm (background_sync.dart) can have rewritten
      // `alarm_epoch`/`alarm_epoch_confirmed` under this same live process
      // since init() last read them — refresh from the shared store before
      // comparing, or a stale in-memory `_savedAlarm` makes this issue a
      // needless duplicate setAlarm write on every connect.
      final prefs = await SharedPreferences.getInstance();
      final onDisk = prefs.getInt('alarm_epoch');
      if (onDisk != _savedAlarm) {
        _savedAlarm = onDisk;
        // The optimistic in-session epoch is older than what headless armed,
        // and it wins in [alarmEpoch]; drop it so Home and the alarm screen
        // show the arm that's actually on the strap.
        device.alarmEpoch = null;
        if (onDisk != null) {
          _seedAlarmFromPrefs(onDisk, prefs);
        } else {
          _alarm.disable();
        }
        notifyListeners();
      }
      final result = await armNextScheduledOccurrence(
        engine: engine,
        schedule: _schedule,
        currentArmedEpoch: _savedAlarm ?? device.alarmEpoch,
        now: alarmRearmFrom(DateTime.now(), firedEpoch),
      );
      if (result.disabled) {
        // Every weekday got disabled since the last arm — the strap doesn't
        // give up its old alarm on its own (PR #329 review).
        _clearArmedAlarmState();
        notifyListeners();
        return;
      }
      final epoch = result.epoch;
      if (epoch == null) return;
      await _onArmed(DateTime.fromMillisecondsSinceEpoch(epoch * 1000), epoch);
    } catch (e) {
      _log('[alarm] weekly-schedule arm failed: $e');
    }
  }

  /// The armed epoch (unix sec) a Smart Wake Window early-fire already ran
  /// for, so a re-arm of the SAME occurrence on every 30 s tick does not buzz
  /// the band again on every tick once light sleep is first seen.
  int? _smartWakeFiredForEpoch;

  /// Smart Wake Window's periodic check, run from [BleEngine.onKeepAlive] —
  /// the engine's existing 30 s keep-alive tick, not a new timer.
  ///
  /// SAFETY: this method can only ever cause an EARLY extra buzz
  /// (`engine.runAlarm()`, RUN_ALARM — haptics only, it does not touch
  /// SET_ALARM). It never calls `setAlarm`, `disableAlarm`, or anything else
  /// that could change or clear the armed fallback epoch, in any branch,
  /// including every early `return` below and the catch clause. The band's
  /// own already-armed SET_ALARM is what actually guarantees the wake — it
  /// keeps firing at [alarmEpoch] exactly as scheduled, on the band's own
  /// clock, whether this method ever runs, throws, or finds nothing at all.
  Future<void> _checkSmartWake() async {
    try {
      if (!isConnected) return;
      final epoch = alarmEpoch;
      if (epoch == null || epoch == _smartWakeFiredForEpoch) return;
      final armed = armedSmartWakeWindow(epoch: epoch, schedule: _schedule);
      if (armed == null) return;
      final now = DateTime.now();
      if (!inSmartWakeWindow(
          windowEnd: armed.windowEnd, minutes: armed.minutes, now: now)) {
        return;
      }
      final recentRows = await LocalDb.onehzHrAccelBetween(
        now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch ~/
            1000,
        now.millisecondsSinceEpoch ~/ 1000,
      );
      final baselineRows = await LocalDb.onehzHrAccelBetween(
        now.subtract(const Duration(minutes: 93)).millisecondsSinceEpoch ~/
            1000,
        now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch ~/
            1000,
      );
      final detected = likelyLightSleep(
        baseline: [for (final r in baselineRows) SmartWakeSample.fromRow(r)],
        recent: [for (final r in recentRows) SmartWakeSample.fromRow(r)],
      );
      if (!detected) return;
      _smartWakeFiredForEpoch = epoch; // set BEFORE the write — see below
      // Marked fired before the write goes out on purpose: a write that
      // throws must not retry every 30 s for the rest of the window (that
      // would just be repeated buzzing), and the untouched fallback arm
      // still covers a write that genuinely failed.
      await engine.runAlarm();
      _log('[smart-wake] light sleep detected inside the window — early buzz.');
    } catch (e) {
      _log('[smart-wake] check failed (fallback alarm is unaffected): $e');
    }
  }

  /// Whether the currently-armed alarm — from either source, the schedule
  /// engine or a still-live manual arm — fires during tonight's upcoming
  /// overnight sleep. Feeds the 7pm "no alarm set for tonight" check
  /// (Feature 2.2): the honest, real armed state, not merely that today's
  /// schedule row happens to be enabled — a slot that never latched is not
  /// something this may claim is armed. Delegates to the pure
  /// [alarmArmsTonight], whose window is "after now, before noon tomorrow" —
  /// a wake alarm armed tonight for tomorrow morning still counts, unlike a
  /// same-calendar-date check would (see PR #329).
  bool get _alarmArmedTonight {
    final epoch = alarmEpoch;
    if (!alarmArmsTonight(epoch, DateTime.now())) return false;
    // The window match alone isn't enough — an epoch that was WRITTEN but
    // never actually latched (headless failure, or the write is still inside
    // its grace window with no confirmation yet) must not suppress the 7pm
    // check; that gap is exactly what this check exists to catch (CodeRabbit
    // review, PR #329).
    if (_alarm.targetEpoch != epoch) return false;
    return _alarm.confirmed ||
        _alarm.isPending(DateTime.now().millisecondsSinceEpoch);
  }

  // ── alarm confirmation state machine ────────────────────────────────────────
  // The strap CONFIRMS an alarm actually latched via event 56 (ALARM_SET) and
  // reports firing via 57/58 (+60). This replaces the parked GET_ALARM readback
  // as display truth: we no longer guess from an unconfirmed readback — we know.
  // The transitions live in the pure, unit-testable [AlarmConfirmation]; AppState
  // just wires the strap event stream + persistence + the fired notification.
  final AlarmConfirmation _alarm = AlarmConfirmation();
  Timer? _alarmGraceTimer;
  // Event 56 is a one-shot BLE notification — if that single packet gets
  // dropped by an ordinary momentary disconnect right after the write (the
  // band DID latch the alarm), there is no retry/re-poll for it and the
  // GET_ALARM readback fallback is parked (unconfirmed format), so the app had
  // no way to ever clear the "unconfirmed" warning short of the user
  // re-sending the whole alarm. One silent, automatic re-arm covers that
  // common case; only a still-unconfirmed retry falls through to the warning.
  bool _alarmAutoRetried = false;

  /// The strap emitted ALARM_SET (event 56) — the alarm is confirmed armed.
  bool get alarmConfirmed => _alarm.confirmed;

  /// When the strap last reported firing the alarm (event 57). The
  /// fired alarm is cleared and the next one armed straight away, so without
  /// this the screen just swaps times and a real fire reads like a fault.
  DateTime? get alarmFiredAt => _alarmFiredAt;
  DateTime? _alarmFiredAt;

  /// A SET was written but not yet confirmed, still inside the grace window —
  /// the UI shows a neutral "Setting alarm…" state.
  bool get alarmPending =>
      _alarm.isPending(DateTime.now().millisecondsSinceEpoch);

  Future<void> setAlarm(DateTime when) async {
    if (!isConnected) throw Exception('Connect to your strap first');
    // Pass the DateTime through so the engine computes REAL sub-seconds for the
    // rich 20-byte firing form (a hardcoded 0 subsec would still fire, but the
    // engine owns the exact on-wire layout). Persist the wall instant the
    // engine reports armed (null = write never reached the band).
    final armed = await engine.setAlarm(when);
    if (armed == null) {
      // Do NOT persist or start the confirmation machine, or we'd strand a
      // phantom alarm "waiting for the strap to confirm" that can never fire.
      // Null now covers two cases: the write never left the phone, and the
      // strap answered and REFUSED the alarm. Both mean the band holds no alarm, so both
      // must stay out of persistence; the engine log says which one it was.
      _log('[alarm] the band did not take the alarm — not persisting.');
      // Neutral on purpose: null covers both a write that never left the
      // phone and an explicit refusal — the engine log says which.
      throw Exception('Alarm not set');
    }
    await _onArmed(armed, armed.millisecondsSinceEpoch ~/ 1000);
  }

  /// Shared bookkeeping for anything that just armed the band: optimistic
  /// display, the confirmation machine, the persisted epoch, and the grace
  /// timer. [setAlarm] (an explicit write) and [_armNextAlarmOccurrence] (the
  /// schedule engine) both funnel through here so the two can never drift
  /// apart on what "armed" means.
  Future<void> _onArmed(DateTime when, int epoch) async {
    _savedAlarm = epoch;
    device.alarmEpoch = epoch; // optimistic display
    final setAtMs = DateTime.now().millisecondsSinceEpoch;
    _alarm.set(epoch, setAtMs); // await event 56
    _alarmAutoRetried = false; // a fresh arm gets its one retry
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('alarm_epoch', epoch);
    await prefs.setInt('alarm_set_at_ms', setAtMs);
    // Not confirmed yet — event 56 (below, in _handleAlarmEvent) flips this.
    await prefs.setBool('alarm_epoch_confirmed', false);
    // The alert timers below live in memory only; this lets a relaunch
    // still send the critical alert if the process dies before it goes out.
    await prefs.setStringList('alarm_latch_alert', [
      '$epoch',
      '${alarmLatchAlertAtMs(DateTime.now().millisecondsSinceEpoch, _alarm.graceMs)}',
    ]);
    // Nudge the UI once the grace window elapses so an unconfirmed alarm flips to
    // its soft warning even if no event ever arrives.
    _armAlarmGraceTimer(when);
    notifyListeners();
  }

  /// (Re)arm the "grace window elapsed" timer. One helper so the grace
  /// duration and the retry wiring can't drift between the two call sites.
  void _armAlarmGraceTimer(DateTime when) {
    _alarmGraceTimer?.cancel();
    _alarmGraceTimer = Timer(
      alarmGraceTimerDelay(_alarm.graceMs, retryLeft: !_alarmAutoRetried),
      () => unawaited(_onAlarmGraceElapsed(when)),
    );
  }

  /// Every retry is spent and 56 still hasn't come. While connected a slow
  /// strap can still confirm, so the critical alert waits; [_handleAlarmEvent]
  /// cancels this timer when 56 lands, and the alert re-checks confirmation.
  void _escalateAlarmLatchFailed(int epoch) {
    // A retry that resumes after a newer arm must not cancel that arm's timer.
    if (_savedAlarm != epoch) return;
    _alarmGraceTimer?.cancel();
    _alarmGraceTimer = Timer(alarmLatchAlertDelay(connected: isConnected), () {
      if (!_disposed) unawaited(_notifyAlarmLatchFailed(epoch));
    });
  }

  /// Grace window elapsed with no event 56. Before showing the soft warning,
  /// try ONE silent re-arm — if the strap really did latch it and only the
  /// confirmation notification was dropped, this re-send gives it a second
  /// chance to confirm without the user having to notice or do anything.
  Future<void> _onAlarmGraceElapsed(DateTime when) async {
    if (_disposed || _alarm.confirmed) return;
    final epoch = when.millisecondsSinceEpoch ~/ 1000;
    // A newer alarm was armed while this timer was pending — that set owns the
    // confirmation machine now; retrying the stale time would clobber it.
    if (_savedAlarm != epoch) return;
    if (_alarmAutoRetried || !isConnected) {
      // Offline, the first window is also the last, but its timer fired just
      // before it closes; end it so this rebuild lands on the warning.
      _alarm.setAtMs = null;
      notifyListeners();
      _escalateAlarmLatchFailed(epoch);
      return;
    }
    _alarmAutoRetried = true;
    // Keep showing "waiting" while the re-send is in flight instead of
    // flashing the warning between the two windows.
    _alarm.set(epoch, DateTime.now().millisecondsSinceEpoch);
    var rearmed = false;
    try {
      // gen5 made setAlarm return the armed instant (null = the write never
      // reached the band) where it used to return a bool. Same signal, so the
      // retry bookkeeping below is unchanged.
      rearmed = await engine.setAlarm(when) != null;
    } catch (e) {
      _log('[alarm] auto-retry re-arm failed: $e');
    }
    // The write itself never landed, so the one retry was not actually spent —
    // give it back rather than latching this alarm out of any future retry.
    if (!rearmed) {
      _alarmAutoRetried = false;
      // End the window opened above so the warning shows now.
      if (_savedAlarm == epoch && !_alarm.confirmed) _alarm.setAtMs = null;
    }
    // dispose() ran while the write was in flight — do NOT create a timer it
    // no longer has any chance to cancel (it would keep poking a torn-down
    // engine on every fire).
    if (_disposed) return;
    // Re-check staleness after the await for the same reason as above.
    if (rearmed && _savedAlarm == epoch && !_alarm.confirmed) {
      _alarm.set(epoch, DateTime.now().millisecondsSinceEpoch);
      _armAlarmGraceTimer(when);
      return;
    }
    notifyListeners();
    _escalateAlarmLatchFailed(epoch);
  }

  /// The "alarm not confirmed" safety notification (Feature 2.1): fires once
  /// per armed epoch, only once every retry this grace window can offer is
  /// exhausted and the strap still never confirmed. Respects its own toggle
  /// (default ON). Category device + critical priority rides the same
  /// quiet-hours exemption as the band's other own-failure alerts (flat
  /// battery, gone quiet) — a wake alarm that silently didn't latch is
  /// exactly the kind of thing quiet hours must not swallow.
  Future<void> _notifyAlarmLatchFailed(int epoch) async {
    try {
      final prefs = await NotificationPrefs.load();
      if (!alarmLatchFailed(_alarm, epoch,
          enabled: prefs.alarmLatchFailedEnabled)) {
        return;
      }
      await NotificationCenter.instance.emit(NotificationEvent(
        dedupeKey: 'alarm_latch_failed:$epoch',
        category: NotifCategory.device,
        priority: NotifPriority.critical,
        title: 'Alarm not confirmed',
        body: 'The band did not confirm this alarm — check the strap.',
        date: todayLabel(),
        route: kRouteAlarm,
        osId: NotificationService.idAlarmLatchFailed,
      ));
    } catch (e) {
      _log('[alarm] latch-failure notification skipped: $e');
    }
  }

  /// Fire the strap's alarm haptics immediately — a "test buzz" so the user can
  /// confirm the band actually fires before trusting the scheduled wake.
  Future<void> testAlarmBuzz() async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.runAlarm();
  }

  Future<void> testBuzzPattern(int pattern) async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.buzzPattern(pattern);
  }

  /// Pulse the strap so it can be heard/felt during a find-my-strap hunt.
  /// Unlike [testAlarmBuzz] this NEVER throws — the hunt screen fires it on a
  /// timer and a momentary disconnect must not surface as an error dialog.
  Future<void> buzzBand() async {
    if (!isConnected) return;
    try {
      await engine.buzz();
    } catch (_) {
      // Best-effort by design: the next tick will try again.
    }
  }

  /// The UI's "Cancel-all": DISABLE_ALARM on the band, and clear the whole
  /// weekly schedule — not just the currently-armed instant — so nothing left
  /// in `alarm_schedule` can silently re-arm this on the next connect/sync.
  Future<void> disableAlarm() async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.disableAlarm();
    _savedAlarm = null;
    device.alarmEpoch = null;
    _alarm.disable();
    _alarmGraceTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('alarm_epoch');
    await prefs.remove('alarm_epoch_confirmed');
    await LocalDb.clearAlarmSchedule();
    _schedule = fillDefaultAlarmSchedule(const []);
    notifyListeners();
  }

  /// Retained name for the UI's "clear alarm" affordance — delegates to
  /// [disableAlarm] (the DISABLE_ALARM opcode).
  Future<void> clearAlarm() => disableAlarm();

  /// Strap alarm-lifecycle events (56 set / 57 fired / 58 buzz / 59 disabled). This is
  /// the authoritative confirmation the SET write actually took. The edge DOES see
  /// the protocol EventId names (strapDrivenAlarmSet == 56, …); the pure state
  /// machine matches the raw ids so it stays dependency-free.
  void _handleAlarmEvent(int id, int ts) {
    // The strap stamps events on its own RTC; the alarm was armed at
    // `when - driftSec` in that frame, so map back the same way.
    final effect = _alarm.onEvent(id, DateTime.now().millisecondsSinceEpoch,
        tsSec: ts + (engine.clockRef?.driftSec ?? 0));
    if (effect == null) return;
    switch (effect) {
      case AlarmEffect.confirmed:
        _alarmGraceTimer?.cancel();
        // A re-arm from a sync (tomorrow's schedule slot) never passes through
        // the foreground reminder pass, so the 7pm "no alarm tonight" check
        // armed at this morning's open would still go off. Re-decide it now.
        unawaited(_ensureRemindersScheduled());
        // Diagnostic: ALARM_SET (event 56) means the arm LATCHED on the band.
        // Its absence after a SET is the tell that the write never took.
        _log('[alarm] strap CONFIRMED arm — ALARM_SET (event $id) received.');
        unawaited(() async {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('alarm_epoch_confirmed', true);
          } catch (e) {
            _log('[alarm] persisting confirmation failed: $e');
          }
        }());
        // the 7pm "no alarm set for tonight" one-shot was decided before this
        // alarm latched; re-decide it now or it fires over a real alarm.
        unawaited(_ensureRemindersScheduled());
        break;
      case AlarmEffect.fired:
        _log('[alarm] strap FIRED — EXECUTED (event $id) received.');
        _alarmFiredAt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        unawaited(SharedPreferences.getInstance()
            .then((p) => p.setInt('alarm_fired_at', ts))
            .catchError((Object e) {
          _log('[alarm] persisting the fire time failed: $e');
          return false;
        }));
        unawaited(_notifyAlarmFired());
        // A one-shot alarm is SPENT the moment it fires. This used to only log
        // + notify, so `alarmEpoch` kept returning the past epoch across
        // relaunches (_init reloads `alarm_epoch`) and Profile's "Smart alarm"
        // row went on advertising e.g. "06:30 (7/25)" as the CURRENT alarm
        // indefinitely — with live "Test buzz"/"Clear" affordances for an alarm
        // that is no longer armed. Clear state AND the persisted epoch.
        final firedEpoch = _savedAlarm ?? device.alarmEpoch;
        _clearArmedAlarmState();
        // ...and arm the schedule's next occurrence now. Otherwise nothing
        // re-arms until the next reconnect, so a link that stays up all day
        // leaves tomorrow unarmed and Home saying "Set an alarm". Computed
        // past the slot that just fired (see [alarmRearmFrom]) so a strap
        // running slightly fast doesn't re-arm the spent slot.
        unawaited(_armNextAlarmOccurrence(firedEpoch: firedEpoch));
        break;
      case AlarmEffect.buzzed:
        _log('[alarm] RUN_ALARM buzz (event $id), armed slot unchanged.');
        break;
      case AlarmEffect.cleared:
        // Same persistence gap on the strap-driven clear (event 59): state was
        // nulled but `alarm_epoch` stayed on disk and came back on next launch.
        _clearArmedAlarmState();
        _log('[alarm] cleared (event $id).');
        break;
    }
    notifyListeners();
  }

  /// Drop the armed-alarm state (in-memory + persisted). [AlarmConfirmation]'s
  /// `firedAt` deliberately survives `disable()`, so the fired-notification's
  /// dedupeKey still resolves after this runs.
  void _clearArmedAlarmState() {
    _savedAlarm = null;
    device.alarmEpoch = null;
    _alarm.disable();
    _alarmGraceTimer?.cancel();
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('alarm_epoch');
        await prefs.remove('alarm_epoch_confirmed');
      } catch (e) {
        _log('[alarm] clearing the persisted epoch failed: $e');
      }
    }());
  }

  Future<void> _notifyAlarmFired() async {
    try {
      await NotificationCenter.instance.emit(NotificationEvent(
        dedupeKey: 'alarm_fired:${_alarm.firedAt ?? 0}',
        category: NotifCategory.reminders,
        priority: NotifPriority.critical,
        title: 'Alarm',
        body: 'Your strap alarm just fired.',
        date: todayLabel(),
        route: kRouteAlarm,
      ));
    } catch (e) {
      _log('[alarm] fired-notification skipped: $e');
    }
  }

  Future<void> renameStrap(String name) async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.setStrapName(name);
    device.strapName = name; // optimistic
    await engine.getStrapName();
    notifyListeners();
  }

  // ── session: drain history, go live, stay connected ──────────────────────────
  Future<void> openSession({bool foreground = true}) =>
      _sync.openSession(foreground: foreground);
  Future<void> forceResync() => _sync.forceResync();
  Future<void> foregroundCatchUp() => _sync.foregroundCatchUp();
  Future<void> syncNow() => _sync.syncNow();
  Future<SyncReport> syncForShortcut(ShortcutSyncTask task) =>
      _sync.syncForShortcut(task);

  /// The ONE place the band's HIGH_FREQ_SYNC prompt is programmed. Two
  /// requesters, one decision (`BandPromptPolicy`): the smart-wake window
  /// (61 s, ahead of an alarm) and, on iOS while backgrounded, the 15-min
  /// keep-alive prompt that replaced the 1 Hz HR stream as the thing that
  /// wakes a suspended process. Called on connect, after the backlog drains,
  /// on every background (re)connect, from the 25-min background tick (lease
  /// renewal), on backgrounding and on foreground reclaim.
  ///
  /// SERIALIZED and COALESCING, same shape as the engine's live reconciler:
  /// a call that lands while a pass is running marks it stale and shares its
  /// future; the pass loops until a run sees no newer request. Without this,
  /// a background pass whose ENTER write was still in flight when the user
  /// foregrounded could outlive the foreground pass's EXIT (which, seeing
  /// nothing requested yet, would not even be written), leaving the band
  /// prompting in the foreground with the engine believing it asked for it.
  Future<void> _refreshHighFreqWakeWindow() {
    final running = _bandPromptRun;
    if (running != null) {
      _bandPromptRestale = true;
      return running;
    }
    final run = _bandPromptRun = () async {
      try {
        do {
          _bandPromptRestale = false;
          await _refreshHighFreqWakeWindowOnce();
        } while (_bandPromptRestale);
      } finally {
        _bandPromptRun = null;
      }
    }();
    return run;
  }

  Future<void>? _bandPromptRun;
  bool _bandPromptRestale = false;

  Future<void> _refreshHighFreqWakeWindowOnce() async {
    if (!engine.isConnected) return;
    try {
      final armed = armedSmartWakeWindow(epoch: alarmEpoch, schedule: _schedule);
      final plan = await HighFreqWakeWindow.planNow(
        scheduledWindowEnd: armed?.windowEnd,
        scheduledWindowMinutes: armed?.minutes ?? 0,
      );
      final target = plan.targetWake;
      final iosBackgrounded = _background && Platform.isIOS;
      final req = BandPromptPolicy.plan(
        smartWake: plan.shouldEnable && target != null
            ? BandPromptRequest.smartWake(
                target: target,
                lease: HighFreqWakeWindow.lease,
                source: plan.source,
              )
            : null,
        iosBackgrounded: iosBackgrounded,
        currentReason: engine.highFreqReason,
        currentUntil: engine.highFreqUntil,
        now: DateTime.now(),
      );
      if (req == null) {
        await engine.applyHighFreqWakeWindow(
          enabled: false,
          targetWake: null,
          reason: plan.source,
        );
      } else {
        await engine.applyHighFreqWakeWindow(
          enabled: true,
          targetWake: req.until,
          duration: req.duration,
          intervalSeconds: req.intervalSeconds,
          reason: req.reason,
        );
      }
      _log(
        '[SYNC] Band prompt: smartWake=${plan.shouldEnable} '
        '(source=${plan.source} samples=${plan.sampleCount}) '
        'iosBackground=$iosBackgrounded → ${req ?? 'off'}',
      );
    } catch (e) {
      _log('[SYNC] Band prompt refresh skipped: $e');
    }
  }

  Future<void> endSession() => _sync.endSession();
  String get status => _sync.status;
  DateTime? get lastDataAt => _sync.lastDataAt;
  bool get syncingNow => _sync.syncingNow;
  DateTime? get lastRecordAt => _sync.lastRecordAt;

  /// A derive job is running RIGHT NOW — the backlog just landed and the
  /// pipeline is computing what it means. Surfaced so a screen sitting on
  /// "nothing yet" can say it is being worked on rather than looking dead.
  /// Thin reads of [_deriveScheduler]'s own state; `onChanged: notifyListeners`
  /// already ticks on every transition, so nothing new to wire.
  bool get deriving => _deriveScheduler.running;

  /// A job is queued behind its settle window (the offload/workout just
  /// ended) — about to run, not running yet. Kept distinct from [deriving]
  /// only because a caller may want to say "about to" rather than "is".
  bool get derivePending =>
      _deriveScheduler.pendingLight || _deriveScheduler.pendingHeavy;

  Future<bool> bluetoothReady() async {
    if (!await FlutterBluePlus.isSupported) return false;
    // CoreBluetooth boots in `unknown` before settling — `.first` loses that
    // race and misreads a powered-on adapter as off. Wait for a determinate
    // state (bounded, in case it never settles).
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown)
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
    return state == BluetoothAdapterState.on;
  }

  // The live HRV spot-check that used to live here is GONE. It was fully
  // implemented — 60 s of RR-bearing frames handed to the repository seam —
  // and no screen ever started one, so `spotActive` was a permanently-false
  // term in the old live-consumer gate and a dead branch on every live frame. The
  // LocalRepository seam (`spotCheck`) is still there for whoever builds the
  // screen; the half-wired state machine is not.

  // ── guided breathing ───────────────────────────────────────────────────────
  bool get breathingActive => _breathingController.breathingActive;
  set breathingActive(bool value) => _breathingController.breathingActive = value;

  /// The clock a breathing session is timed by. Tests only — the app never
  /// replaces it.
  @visibleForTesting
  DateTime Function() get breathingNow => _breathingController.breathingNow;
  @visibleForTesting
  set breathingNow(DateTime Function() value) =>
      _breathingController.breathingNow = value;

  BreathPattern get breathingPattern => _breathingController.breathingPattern;
  set breathingPattern(BreathPattern value) =>
      _breathingController.breathingPattern = value;

  DateTime? get breathingStartedAt => _breathingController.breathingStartedAt;
  Duration? get breathingTarget => _breathingController.breathingTarget;

  Map<String, dynamic>? get breathingResult =>
      _breathingController.breathingResult;
  set breathingResult(Map<String, dynamic>? value) =>
      _breathingController.breathingResult = value;

  String? get breathingError => _breathingController.breathingError;
  set breathingError(String? value) => _breathingController.breathingError = value;

  // ── quiet windows either side of the paced block ───────────────────────────
  //
  // The lifecycle, not the statistics, is what blocked this. The live streams
  // were enabled by [startBreathingSession] and torn down by
  // [stopBreathingSession], and the frame buffer was cleared at start — so the
  // two minutes BEFORE the pacing had no streams and the two minutes AFTER it
  // had neither streams nor a buffer. A window therefore brackets the session
  // rather than living inside it: it owns the stream enable, survives the
  // paced block's start and stop, and hands the buffer over at each boundary.
  //
  // Only the two quiet windows are stored. The paced block's own RMSSD is not
  // computed here and has nowhere to go — see `lib/stress/session_effect.dart`.

  /// True while a quiet window is capturing outside the paced block.
  bool get breathingWindowOpen => _breathingController.breathingWindowOpen;
  set breathingWindowOpen(bool value) =>
      _breathingController.breathingWindowOpen = value;

  /// Open the quiet window: HR stream on, frames buffering, no pacing yet.
  /// The window is an HR owner in its own right (see [_liveOwners]), so the
  /// paced block's stop cannot turn off a stream the post window still reads.
  Future<void> openBreathingWindow() =>
      _breathingController.openBreathingWindow();

  /// Close the window, measure both quiet stretches and attach them to the
  /// banked session. Safe to call when no window is open.
  ///
  /// RMSSD comes from the SAME seam the live spot-check uses, so the two
  /// windows are cleaned and estimated identically — a pre window scored one
  /// way and a post window another would produce a difference that is entirely
  /// method.
  Future<void> closeBreathingWindow() =>
      _breathingController.closeBreathingWindow();

  /// Begin a guided-breathing session. Requires a connected band.
  Future<void> startBreathingSession({
    BreathPattern? pattern,
    Duration? target,
  }) =>
      _breathingController.startBreathingSession(pattern: pattern, target: target);

  /// End the guided-breathing session and bank it.
  ///
  /// A session shorter than a minute is NOT recorded. Opening the screen and
  /// closing it again is not a breathing session, and a history full of
  /// 4-second entries would bury the real ones.
  Future<void> stopBreathingSession() =>
      _breathingController.stopBreathingSession();

  /// Past sessions, newest first.
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) =>
      _breathingController.breathingHistory(limit: limit);

  /// Buzz the strap at a breathing or interval phase boundary.
  ///
  /// Distinct patterns per phase so the cue is legible without looking: a
  /// longer buzz to breathe in, a shorter one to breathe out, a double for a
  /// hold. Never throws and never awaits the caller — this fires from a frame
  /// callback, and a momentary disconnect must not interrupt the session or
  /// stall the animation.
  void buzzBreathPhase(BreathPhaseKind kind) =>
      _breathingController.buzzBreathPhase(kind);

  /// The whole session is over, as opposed to one phase of it.
  ///
  /// Its own pattern rather than a repeat of the phase cue: repeated
  /// `runHapticsPattern` frames serialize on the BLE write chain and arrive
  /// milliseconds apart, re-triggering the firmware's haptic engine while it
  /// is still playing — so N of them are felt as one, and the user cannot tell
  /// "round over" from "session over".
  void buzzSessionComplete() => _breathingController.buzzSessionComplete();

  // GUIDED STEP CALIBRATION REMOVED (v56).
  //
  // A short live walk used to teach a personal `refEnmo` + cadence, which was
  // consumed by ONE caller: the 1 Hz `dailyStepEstimate`. That estimator is
  // gone (1 Hz cannot resolve gait — see the kAlgoVersion v55 note), so the
  // calibration had no reader left. It kept a "Calibrate steps" row on the
  // Steps screen that told the user their walk had taught the app something
  // when nothing read the result. The Tier-A 100 Hz AN-2554 pedometer is
  // threshold-based and never needed it.

  // ── live session coach ───────────────────────────────────────────────────────
  LiveWorkoutState? get activeWorkout => _workoutController.activeWorkout;
  set activeWorkout(LiveWorkoutState? value) =>
      _workoutController.activeWorkout = value;

  RouteTracker? get routeTracker => _workoutController.routeTracker;

  GpsPermissionStatus? get routeLocationIssue =>
      _workoutController.routeLocationIssue;
  set routeLocationIssue(GpsPermissionStatus? value) =>
      _workoutController.routeLocationIssue = value;

  int? get liveZone => _workoutController.liveZone;
  double? get liveDistanceKm => _workoutController.liveDistanceKm;
  bool get routeTracking => _workoutController.routeTracking;

  int get _restingHr => (user?['resting_hr'] as num?)?.round() ?? 60;

  /// Latest MEASURED nightly resting HR (`metric_series` key 'rhr'), or null
  /// before the first night has been derived. Refreshed on init and whenever a
  /// workout starts, since RHR moves on the scale of weeks.
  double? _nightlyRhr;

  /// The resting-HR anchor for SCORING a live session: the measured nightly
  /// value, else a user-supplied one, else nothing.
  ///
  /// Deliberately not [_restingHr], which falls back to 60 bpm. That default is
  /// fine for display copy, but as a term inside the Banister formula it would
  /// turn an absent input into a confident-looking strain number — exactly the
  /// fabrication the honesty contract forbids. No anchor, no score.
  double? get _liveRestingHr =>
      _nightlyRhr ?? (user?['resting_hr'] as num?)?.toDouble();

  /// TS-03 — the highest heart rate the band has ever OBSERVED, and the last
  /// 28 nightly resting values. The two anchors [trainingZones] bands on; both
  /// are cross-day reads, so they are cached here rather than queried when a
  /// user taps start. Absent is the ordinary case and yields the age estimate.
  double? _observedCeilingBpm;
  List<double> _rhr28 = const [];

  Future<void> _refreshNightlyRhr() async {
    try {
      _observedCeilingBpm = (await LocalDb.observedHrCeiling())?.bpm;
      // BEFORE the resting-HR early return below: a user with no nightly
      // series still has a quiet level once three days are measured.
      final live = activeWorkout;
      if (live != null) {
        // Its own guard: a failed fill leaves the gauge at "—" but must not
        // skip the resting-HR refresh below.
        try {
          await _workoutController.fillLiveQuietLevel(live);
        } catch (_) {}
      }
      _rhr28 = await LocalDb.trailingSeriesValues('rhr', 28);
      final vals = await LocalDb.trailingSeriesValues('rhr', 7);
      if (vals.isEmpty) return;
      _nightlyRhr = vals.last;
      // Adopt it into a session that started before this read completed, but
      // only to FILL A GAP — overwriting an anchor a running session was
      // already scored against would move its number mid-workout.
      final w = activeWorkout;
      if (w != null && w.restingHr == null) {
        w.restingHr = _liveRestingHr;
        notifyListeners();
      }
    } catch (_) {
      /* best effort — falls back to the user-supplied RHR, or abstains */
    }
  }

  void startWorkout({
    double targetKcal = 300,
    String? workoutId,
    String type = 'other',
  }) =>
      _workoutController.startWorkout(
        targetKcal: targetKcal,
        workoutId: workoutId,
        type: type,
      );

  Future<void> retryRouteTracking() => _workoutController.retryRouteTracking();

  Future<void> maybeFinishFromLiveActivity() =>
      _workoutController.maybeFinishFromLiveActivity();

  /// Same idea as [maybeFinishFromLiveActivity] but for the breathing
  /// session's own Live Activity stop button (EndBreathingIntent sets
  /// `end_breathing_session` — a separate flag so the two Live Activities'
  /// stop buttons never collide). Call on app resume.
  Future<void> maybeStopBreathingFromLiveActivity() =>
      _breathingController.maybeStopBreathingFromLiveActivity();

  Future<void> _reconcileOrphanedLiveWorkout() =>
      _workoutController.reconcileOrphanedLiveWorkout();

  /// Retire the auto-detected suggestion(s) a just-finalized session covers,
  /// mirroring `_writeManualSession`'s cleanup so a live-tracked "Start
  /// Workout" finish (or an orphaned-session reconcile) doesn't leave a
  /// "did you work out?" prompt for something already logged. Best-effort —
  /// a cleanup failure never undoes the already-saved session.
  Future<void> _dismissSupersededSuggestions({
    required int startSec,
    required int endSec,
  }) async {
    try {
      final sug = await LocalDb.activeWorkoutSuggestions();
      for (final id in supersededSuggestionIds(
        sug,
        startSec: startSec,
        endSec: endSec,
      )) {
        await LocalDb.dismissWorkoutSuggestion(id);
      }
    } catch (_) {
      /* suggestion cleanup is best-effort — the session is already saved */
    }
  }

  Future<void> stopWorkout() => _workoutController.stopWorkout();

  Future<void> deleteWorkout(String id) => _workoutController.deleteWorkout(id);

  // ── band-gesture actions (in-app) ─────────────────────────────────────────────
  // Driven by the double-tap dispatcher (lib/gestures).

  /// Double-tap → start a workout if none is live, else end the active one.
  /// CLOUD EXCISED: the workout now lives purely in-app (the local live engine).
  /// The repo seam start/end calls will be re-wired to local persistence later.
  Future<void> _toggleWorkoutFromGesture() async {
    try {
      if (activeWorkout != null) {
        final id = activeWorkout!.workoutId;
        await stopWorkout();
        if (id != null) {
          try {
            await repo?.endWorkout(id);
          } catch (_) {
            /* seam not implemented yet; local already stopped */
          }
        }
      } else {
        String? id;
        try {
          final w = await repo?.startWorkout('other');
          id = w?['workout_id'] as String?;
        } catch (_) {
          /* seam not implemented yet; still start locally */
        }
        startWorkout(workoutId: id, type: 'other');
      }
      await HapticFeedback.mediumImpact();
    } catch (e) {
      _log('[gesture] workout toggle failed: $e');
    }
  }

  /// One water write at a time. `_logWaterFromGesture` reads the day, awaits, then
  /// writes the whole map back, and `postJournalMetrics` REPLACES the day — so two
  /// taps overlapping that await both read the same total and the second write eats
  /// the first glass. Same guard the nutrition screen's `+` already uses. This is not
  /// a second debounce (the dispatcher owns that); it is the read-modify-write lock.
  bool _writingWaterFromGesture = false;

  /// Double-tap → add one glass to today's water. Step and ceiling come from the
  /// journal field spec, so a wrist tap and the on-screen `+` always agree.
  Future<void> _logWaterFromGesture() async {
    final r = repo;
    if (r == null || _writingWaterFromGesture) return;
    _writingWaterFromGesture = true;
    try {
      final spec = kJournalFieldsByKey['water_ml']!;
      final date = todayLabel();
      // Inside the try: the READ can throw too, and a guard set before it would
      // stay set forever. Spread into a fresh map — postJournalMetrics rewrites
      // the whole day from what it is handed.
      final fields = {...await r.getJournalMetrics(date)};
      final now = fields['water_ml']?.value ?? 0;
      fields['water_ml'] =
          JournalMetricValue((now + spec.step).clamp(0, spec.max).toDouble());
      await r.postJournalMetrics(date, fields);
      _log('[gesture] water logged (+${spec.step.round()} ${spec.unit})');
      await HapticFeedback.mediumImpact();
    } catch (e) {
      _log('[gesture] log water failed: $e');
    } finally {
      _writingWaterFromGesture = false;
    }
  }

  /// Double-tap → stamp a timestamped tag onto today's journal (read-modify-write so
  /// existing tags/note survive). "Remember this" for a spike, a set, a feeling.
  Future<void> _markMomentFromGesture() async {
    final r = repo;
    if (r == null) return;
    try {
      final now = DateTime.now();
      final date =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final hhmm =
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      List<String> tags = [];
      String note = '';
      try {
        final journal = await r.getJournal(range: '7d');
        final today = journal.firstWhere(
          (e) => e['date'] == date,
          orElse: () => <String, dynamic>{},
        );
        tags =
            (today['tags'] as List?)?.map((e) => e.toString()).toList() ?? [];
        note = (today['note'] as String?) ?? '';
      } catch (_) {
        /* fresh day / seam not implemented — start clean */
      }
      tags.add('moment $hhmm');
      await r.postJournal(date, tags, note);
      _log('[gesture] moment marked at $hhmm');
      await HapticFeedback.mediumImpact();
    } catch (e) {
      _log('[gesture] mark moment failed: $e');
    }
  }
}
