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
import '../coach/coach_config.dart';
import '../models/app_status.dart';
import '../ble/accessory_setup.dart';
import '../ble/android_background.dart';
import '../ble/ble_engine.dart';
import '../ble/ble_state.dart'
    show AlarmConfirmation, AlarmEffect, LiveStepDayWindow, SyncActivityWindow;
import '../ble/ios_ble_restore.dart';
import '../cloud/companion_client.dart';
import '../compute/derivation_engine.dart';
import '../compute/derive_scheduler.dart';
import '../compute/manual_session.dart' show strainFromPerMinuteHr;
import '../compute/hr_max.dart';
import '../compute/profile.dart';
import '../data/day_label.dart';
import '../data/auto_backup.dart'
    show BackupCadence, BackupOutcome, runBackup;
import '../ui/stress/breath_phases.dart';
// `runBackupIfDue` is also the name of the AppState method below, so the pure
// scheduler is imported under an alias rather than shadowed by it.
import '../data/auto_backup.dart' as backup show runBackupIfDue;
import 'prefs.dart';
import '../data/db.dart';
import '../data/live_coverage_policy.dart';
import '../data/local_repository.dart';
import '../gps/gps_source.dart';
import '../gps/route_tracker.dart';
import '../gps/screen_wake.dart';
import '../data/local_repository_impl.dart';
import '../data/series_codec.dart';
import '../notify/battery_forecast.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../gestures/gesture_settings.dart';
import '../health/health_export.dart';
import '../health/phone_pedometer.dart';
import '../import/noop_import.dart';
import '../import/whoop_import.dart';
import '../gestures/gesture_dispatcher.dart';
import '../platform/tasker_bridge.dart';
import '../data/models.dart';
import '../live/live_activity.dart';
import '../live/breathing_live_activity.dart';
import '../notify/device_alerts.dart';
import '../notify/notification_relay.dart';
import '../notify/notification_service.dart';
import '../notify/tap_router.dart';
import '../notify/water_buzzer.dart';
import '../sync/background_sync.dart' show checkSyncStaleness;
import '../sync/edge_tracking.dart';
import '../sync/band_ownership.dart';
import '../sync/high_freq_wake_window.dart';
import '../sync/ios_bg_task.dart';
import '../sync/paired_device.dart';
import '../sync/sync_policy.dart'
    show
        isLinkStale,
        ReconnectSupervisorAction,
        StalenessTier,
        stalenessTierFor,
        superviseReconnect;
import '../sync/update_service.dart';
import '../telemetry/telemetry_service.dart';
import '../telemetry/health_uploader.dart';
import '../widget/widget_service.dart';
import '../sync/file_log.dart';
import 'package:uuid/uuid.dart';

/// The onboarding/app gate states, in order. See [AppState.route].
/// Flow: loading → pairing → profile (only if incomplete) → shell. The profile
/// step collects age/weight/height/sex so the on-device analytics can
/// personalize (HRmax, calories, TRIMP); it's skipped once those are set.
enum AppRoute { loading, welcome, pairing, profile, shell }

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
  return PairedDevice(current.remoteId, clean);
}

class AppState extends ChangeNotifier {
  late final BleEngine engine;
  PairedDevice? paired;
  BandLease? _foregroundLease;

  /// SEAM: the screen data layer. Wired to [LocalRepositoryImpl] in the ctor —
  /// it reads the precomputed day_result / metric_series rows (ZERO heavy
  /// compute on read). Screens still guard on `repo == null` exactly as they did
  /// on `api`.
  LocalRepository? repo;

  /// The on-device compute orchestrator. Kicked (light) after every drain/flush
  /// completion, and (heavy) on foreground finalize. Background heavy passes run
  /// via WorkManager (Android) — see lib/compute/background_derivation.dart.
  // `background` is final on the engine and picks the concurrency + per-day
  // timeout, so seeding the scheduler alone left a headless first sweep running
  // the foreground budget. Late-initialized, so this reads the value both
  // constructors have already set by the time anything touches `_derive`.
  late final DerivationEngine _derive =
      DerivationEngine(log: _log, background: _background);
  late final DeriveScheduler _deriveScheduler = DeriveScheduler(
    run: ({required DeriveJobKind kind}) =>
        _afterDrain(heavy: kind == DeriveJobKind.heavy),
    log: _log,
    onChanged: notifyListeners,
  );

  /// Profile fed to the analytics (HRmax/calories/TRIMP personalization).
  Profile get _profile => Profile.fromMap(user);

  DeviceState get device => engine.state;
  final DeviceAlerts _deviceAlerts = DeviceAlerts();

  /// Band-gesture → action mapping (double-tap, etc.). Exposed for the settings UI.
  final GestureSettings gestureSettings = GestureSettings();
  late final GestureDispatcher _gestureDispatcher;

  /// Relay selected phone-app notifications to the strap as a buzz (Android only).
  /// Exposed for the settings UI; buzzes via the live BLE engine when connected.
  late final NotificationRelay notificationRelay = NotificationRelay(
    buzz: () => engine.buzz(),
    isConnected: () => engine.isConnected,
  );

  /// Fires a strap haptic at each hydration-reminder slot (best-effort, only when
  /// the band is connected). Armed at launch + whenever notification prefs change.
  late final WaterBuzzer _waterBuzzer = WaterBuzzer(
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
  int? _lastRecTs;
  Map<String, int> dbCounts = {'raw': 0, 'pending': 0};
  final List<String> logLines = [];
  String? lastError;
  bool busy = false;

  bool _keepAlive = false;
  bool _reconnecting = false;

  /// When the current reconnect ATTEMPT started, for the supervisor's
  /// staleness check (issue #208). Per-attempt, not per-loop: a loop against a
  /// band left at home legitimately runs for hours, so loop age says nothing
  /// about whether anything is stuck — only an attempt that never returns does.
  DateTime? _attemptStartedAt;

  /// Which reconnect loop is the live one. Bumped whenever a loop starts, so a
  /// loop that was declared wedged and replaced can recognise itself as
  /// superseded if it ever unblocks: without this its `finally` would clear the
  /// REPLACEMENT's `_reconnecting`/`_attemptStartedAt`, and the supervisor
  /// would then start a third loop while two are already connecting.
  int _reconnectGeneration = 0;

  /// Level-triggered reconnect supervision. The loop's only trigger used to be
  /// the `connected → disconnected` edge, so any abandoned loop was permanent.
  /// This ticks regardless of edges and re-arms — see [superviseReconnect].
  Timer? _reconnectSupervisor;
  Timer? _backfillTimer;
  String _prevConn = 'disconnected';
  // Last battery snapshot pushed to the Band Battery widget — so we only reload
  // the widget when pct/charging actually change (the engine-state hook fires
  // ~1 Hz on live HR). -2 = never pushed.
  int _widgetBattPct = -2;
  bool? _widgetBattCharging;
  String? _widgetBattName;
  int? _storedBatteryPct;

  /// Last time the overnight battery forecast ran. `_onEngineState` fires on
  /// every device-state update, and the forecast reads a few hundred rows, so
  /// it is throttled rather than run per tick. The user-visible fire-once
  /// guarantee comes from the dedupeKey, not from this.
  DateTime? _lastBatteryForecastAt;
  bool? _storedBatteryCharging;
  bool? _storedBatteryWristOn;
  bool initialized = false;

  /// True while the app is backgrounded. On iOS we KEEP the BLE connection alive in
  /// this state (see [pauseForBackground]) so the OS keeps resuming us per BLE
  /// notification and the live drain continues.
  bool _background = false;

  bool get isPaired => paired != null;

  static const Duration _backfillInterval = Duration(minutes: 10);

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
  // Reachable from onboarding AND Profile (a returning user is past the welcome
  // gate). Each runs against the engine + local profile, then notifies so every
  // screen re-reads the freshly imported days.

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
    notifyListeners();
    return res.days;
  }

  /// The most recent NOOP import, so the import screen can report what the
  /// source cost us — days it presented out of order were folded in as context
  /// for the following day but never derived, and "imported N days" alone would
  /// hide that.
  NoopImportResult? lastNoopImport;

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
    notifyListeners();
    return res.days;
  }

  /// Another device's exported OpenStrap DB (.db) → merge into the local store.
  /// Returns total rows copied across tables.
  Future<int> importEdgeBackup(String path) async {
    final counts = await LocalDb.importFromDbFile(path);
    // Imported rows include derived day_result/metric_series → refresh rollups.
    try {
      await _derive.finalizeImport(_profile);
    } catch (_) {
      /* best-effort */
    }
    notifyListeners();
    return counts.values.fold<int>(0, (a, b) => a + b);
  }

  // ── platform health export (Apple Health / Health Connect) ──────────────────
  final HealthExporter _healthExport = HealthExporter();
  final HealthExportSingleFlight _healthExportSingleFlight =
      HealthExportSingleFlight();
  HealthLinkState healthState = HealthLinkState.unknown;
  bool healthSyncEnabled = false;
  static const String _kHealthSync = 'health_sync';

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
    // back after the user turned the feature off — and since `liveStepsForDay`
    // prefers phone rows outright, it would re-suppress the band count, the
    // exact outcome `disablePhoneSteps` exists to prevent.
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

  // ── phone pedometer (the ONLY source of real 24/7 step counts) ─────────────
  final PhonePedometer _phonePedometer = PhonePedometer();
  bool phoneStepsEnabled = false;
  static const String _kPhoneSteps = 'phone_steps';

  /// Ask for READ access to the phone's own step counts (user gesture).
  ///
  /// The band cannot count steps: it is on the wrist, and its 24/7 stream is
  /// 1 Hz, where gait is sub-Nyquist. The phone rides in a pocket and already
  /// counts steps continuously into the on-device health store — this reads
  /// them. Nothing is uploaded and nothing is written back.
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
        // `_reanalyzeForOverride` no-ops while another derive is running, and
        // the full sync above takes long enough (7 days of hourly platform
        // reads) that a drain-triggered pass can easily have started. Dropping
        // it silently leaves the freshly-banked rows out of `day_result` and
        // the tile on a dash — the exact "looks broken" symptom this call was
        // added to prevent. Wait for the other pass, bounded, then run.
        for (var i = 0; i < 60 && reanalyzing; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await _reanalyzeForOverride();
      }());
    }
    return ok;
  }

  /// Turn phone steps off and DROP the counts we pulled.
  ///
  /// Leaving the rows behind would keep serving phone-sourced steps from a
  /// source the user just switched off, and `liveStepsForDay` prefers phone
  /// rows over band rows — so a stale row would keep overriding the band
  /// indefinitely. Revoking the platform permission is the user's to do in
  /// Settings; all we can do is stop reading and forget what we read.
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
  /// source rule (phone wins only when it actually has data). Screens add the
  /// band's live count on top of the day total, and must not do that once the
  /// phone owns the day — both count the same walk. Gating on
  /// [phoneStepsEnabled] alone was wrong: with the toggle on and no phone data
  /// (iOS read denied, nothing writing to Health Connect) the band still owns
  /// the day and its live steps were being thrown away.
  int phoneStepsToday = 0;

  /// Which local day [phoneStepsToday] was read for. The cache is worthless
  /// past midnight, and a process here routinely lives for days (Android
  /// foreground service, iOS suspend/resume), so a day-less cache would hold
  /// yesterday's answer through the whole of today — suppressing the band's
  /// live count on a day the phone has not contributed a single step to.
  String? _phoneStepsDay;

  /// True when today's step total comes from the phone, so band live steps are
  /// already accounted for and must not be added again. Unknown-or-stale reads
  /// as false: showing the band's live count is the safe direction (a lost
  /// count is invisible, a doubled one is a wrong number).
  bool get todayStepsFromPhone =>
      phoneStepsEnabled &&
      _phoneStepsDay == todayLabel() &&
      phoneStepsToday > 0;

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
  /// #130) — used by callers outside this class (e.g. confirming an
  /// auto-detected workout in workouts_screen.dart) that write a `sessions`
  /// row directly rather than going through [stopWorkout]. See
  /// [HealthExporter.exportWorkout] for why this can't just wait for the next
  /// day export. Best-effort, never throws.
  Future<bool> exportWorkoutToHealth(Map<String, Object?> session) =>
      _healthExport.exportWorkout(session);

  // ── companion: anonymous telemetry + health-data contribution ────────────────
  // All anchored to a stable anonymous install id (no account). Two SEPARATE
  // consent scopes, both PRE-ENABLED at enrollment (shown on the onboarding
  // name/age screen, where the user can switch either off before continuing).
  // `consentChosen` records that the user has passed that screen at least once,
  // so we never retroactively flip a returning install that predates the screen.
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

      // Learn the live Terms version (and OTA/banner) — best-effort.
      final status = await CompanionClient.getStatus();
      final v = status?['terms']?['version'];
      if (v is int && v > 0) {
        termsVersion = v;
        t.consentVersion = v;
        HealthUploader.instance.consentVersion = v;
      }
    } catch (e) {
      _log('[companion] init failed (non-fatal): $e');
    }
  }

  /// The live band fields folded into each telemetry batch's device snapshot.
  Map<String, dynamic> _bandSnapshot() {
    final s = engine.state;
    return {
      if (s.serial != null) 'band_serial': s.serial,
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
    final outcome = await runBackup();
    if (outcome.succeeded) _markBackupRun(DateTime.now());
    return outcome;
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
      cadence: () => backupCadence,
      lastRun: () => lastBackupAt,
      markRun: (when) async => _markBackupRun(when),
    );
    if (outcome.error != null) _log('Backup failed: ${outcome.error}');
  }

  /// Clear the local profile + unpair the band (the former "sign out", now purely
  /// local — there is no session to end).
  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProfile);
    await prefs.remove(_kOnboard);
    _onboardChoice = null;
    user = null;
    await unpair();
  }

  /// The single onboarding/route the UI gate is in. `_Gate` selects on THIS so it
  /// rebuilds only on a real route transition — NOT on every ~1 Hz notifyListeners
  /// (live HR, log lines), which used to repaint the whole home stack each second
  /// and starve the background BLE connection.
  AppRoute get route {
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

  // ── app status: OTA update pointer + admin-pushed alert banner ──────────────
  // Now fetched directly by UpdateService from a public, unauthenticated pointer
  // URL — independent of any backend / JWT (the authed client was deleted).
  AppStatus? appStatus;
  int _currentBuild = 0; // our build number (from package_info); 0 if unknown
  final Set<String> _dismissedBanners = {};

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

  UpdateInfo? get update => _update;

  /// The admin banner to show right now (null if none, or dismissed + dismissible).
  BannerInfo? get activeBanner {
    final b = appStatus?.banner;
    if (b == null) return null;
    if (b.dismissible && _dismissedBanners.contains(b.id)) return null;
    return b;
  }

  Future<void> _loadAppStatus() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      /* keep 0 → update prompts simply won't fire */
    }
    final prefs = await SharedPreferences.getInstance();
    _dismissedBanners.addAll(
      prefs.getStringList('dismissed_banners') ?? const [],
    );
    await refreshAppStatus();
  }

  /// Re-poll the update pointer (best-effort; called on launch and on app resume).
  Future<void> refreshAppStatus() async {
    final status = await UpdateService.fetchStatus();
    if (status == null) return;
    appStatus = status;
    notifyListeners();
  }

  Future<void> dismissBanner(String id) async {
    _dismissedBanners.add(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('dismissed_banners', _dismissedBanners.toList());
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
  final ValueNotifier<int> insightsRevision = ValueNotifier<int>(0);
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

    _gestureDispatcher = GestureDispatcher(
      settings: gestureSettings,
      log: _log,
      onMarkMoment: _markMomentFromGesture,
      onWorkoutToggle: _toggleWorkoutFromGesture,
    );
    engine = BleEngine(
      onRecord: _onRecord,
      onState: _onEngineState,
      log: _log,
      onEvent: _onLiveEvent,
      onRecordsBatch: LocalDb.insertRecordsBatch,
      // RESUMABLE SYNC: atomic commit of decoded rows + continuation cursor
      // before the HISTORY_END ACK, and a reader to seed the offload frontier
      // from the durable high-water on (re)connect.
      onCommitBatch: (raws, samples, trimTokenHex, {archives}) =>
          LocalDb.commitSyncBatch(raws, samples,
              trimToken: trimTokenHex,
              archives: archives,
              onCheckpoint: (msg) => _log('[COMMIT] $msg')),
      // Pre-setup fallback only: the drain path archives inside commitSyncBatch.
      onArchiveRecord: LocalDb.archiveRawRecord,
      cursorReader: LocalDb.getCursorInt,
      // Debounced compute trigger: with continuous listening there's no discrete
      // "sync done", so the engine coalesces stored-record bursts and fires this
      // once a burst goes quiet. Light pass = freshness-first (TODAY when data has
      // reached today, else the latest pending day). The foreground heavy finalize
      // still runs in openSession after the backlog fully drains.
      onDataStored: _onDataStored,
      onOffloadState: (active) => _deriveScheduler.setOffloadActive(active),
      // LIVE high-rate frames (0x28/0x2B/0x33) are ephemeral — routed here for the
      // live UI / spot-check, never persisted.
      onLiveFrame: _onLiveFrame,
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
    repo = LocalRepositoryImpl(getProfileMap: () => user);
    // iOS BGProcessing/BGAppRefresh wakes while the FOREGROUND app owns the band
    // skip the headless BLE path (it would fight FBP for the peripheral) — route
    // them to a catch-up pull over the existing live connection instead.
    IosBgTask.foregroundPull = foregroundCatchUp;
    taskerBridge; // force init: register the method channel handler
    _init();
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
  AppState.forTesting({BleEngine? engine}) {
    _background = false;
    _gestureDispatcher = GestureDispatcher(
      settings: gestureSettings,
      log: _log,
      onMarkMoment: _markMomentFromGesture,
      onWorkoutToggle: _toggleWorkoutFromGesture,
    );
    this.engine = engine ??
        BleEngine(
          onRecord: _onRecord,
          onState: _onEngineState,
          log: _log,
          onEvent: _onLiveEvent,
        );
  }

  /// A Siri/Shortcuts App Intent (e.g. "start breathing") may have set a
  /// pending route in the App Group before launching/foregrounding the app —
  /// see WidgetService.consumePendingRoute + StartBreathingIntent in
  /// OpenStrapIntents.swift. Checked on cold launch (constructor, above) AND
  /// on every foreground resume (app.dart's didChangeAppLifecycleState),
  /// since `openAppWhenRun = true` may just foreground an already-running
  /// process rather than trigger a fresh launch.
  Future<void> checkPendingSiriRoute() async {
    final route = await WidgetService.consumePendingRoute();
    if (route != null) _handleTapRoute(route);
  }

  /// Central disposal guard.
  ///
  /// Setting `_disposed` and checking it at each await point only covers the
  /// paths someone remembered to guard. Several notifications reach here from
  /// places that never see that flag — the derive scheduler's `onChanged`
  /// callback, in-flight `_afterDrain()` continuations, BLE engine callbacks —
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
    _syncQuietTimer?.cancel();
    _syncQuietTimer = null;
    _disposed = true;
    // EVERY timer this object owns, not just three of them. _spotTimer,
    // _breathingRecomputeTimer and _workoutTimer used to survive dispose, and
    // each of their callbacks ends in notifyListeners() on a disposed
    // ChangeNotifier (which throws in release).
    _tapSub?.cancel();
    _stopBackfillTimer();
    _stopReconnectSupervisor();
    _alarmGraceTimer?.cancel();
    _alarmGraceTimer = null;
    _spotTimer?.cancel();
    _spotTimer = null;
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    BandOwnership.markForegroundIntent(false);
    _releaseForegroundLease();
    _deriveScheduler.dispose();
    _waterBuzzer.dispose();
    // Owned notifiers/observers. notificationRelay in particular holds a
    // WidgetsBindingObserver, a 120 s Timer.periodic and a StreamSubscription —
    // its observer accumulated on the binding across every hot restart.
    notificationRelay.dispose();
    gestureSettings.dispose();
    navRequest.dispose();
    screenRequest.dispose();
    insightsRevision.dispose();
    super.dispose();
  }

  /// Arm every periodic/one-shot timer this object owns, so a test can prove
  /// [dispose] actually cancels all of them (an outstanding Timer fails a
  /// `testWidgets` case). Tests only — nothing in the app calls this.
  @visibleForTesting
  void debugArmOwnedTimers() {
    _backfillTimer ??= Timer.periodic(_backfillInterval, (_) {});
    _alarmGraceTimer ??= Timer(const Duration(minutes: 5), () {});
    _spotTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {});
    _breathingRecomputeTimer ??=
        Timer.periodic(_breathingRecomputeInterval, (_) {});
    _workoutTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {});
  }

  /// True while some foreground feature is holding the live streams open —
  /// the gate [_maybeDowngradeLiveForBackground] consults. Tests only.
  @visibleForTesting
  bool get debugHasLiveConsumer => _hasLiveConsumer;

  /// Run the orphaned-live-workout reconcile directly. Tests only — in the app
  /// it is kicked unawaited from [_init].
  @visibleForTesting
  Future<void> debugReconcileOrphanedLiveWorkout() =>
      _reconcileOrphanedLiveWorkout();

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

  /// End the live-pedometer session (persist the coverage window, fold the bout
  /// into the cadence calibration) without a BLE disconnect. Tests only.
  @visibleForTesting
  Future<void> debugFinalizeLivePedometer() => _finalizeLivePedometer();

  /// Feed a strap alarm-lifecycle event (56 set / 57–58 fired / 59 cleared)
  /// without going through the BLE event path. Tests only.
  @visibleForTesting
  void debugHandleAlarmEvent(int id) =>
      _handleAlarmEvent(id, DateTime.now().millisecondsSinceEpoch ~/ 1000);

  /// (Re)arm the strap-buzz timer for the hydration reminder from the current
  /// notification prefs. Call at launch and whenever the prefs change (the
  /// Notifications screen passes [prefs] so we skip a reload). Slot times come
  /// from the same NotificationCenter helper the OS scheduler uses.
  Future<void> armWaterReminder([NotificationPrefs? prefs]) async {
    final p = prefs ?? await NotificationPrefs.load();
    _waterBuzzer.configure(
      enabled: p.waterEnabled && p.remindersEnabled,
      slotMinutes: NotificationCenter.waterSlotMinutes(p),
    );
  }

  /// Compute trigger: kick the DerivationEngine after data is persisted.
  /// [heavy]=false is the bounded light pass (TODAY when raw has reached today,
  /// else the latest pending day); [heavy]=true is the foreground finalize
  /// sweep. Best-effort + non-blocking — never throws into the BLE path.
  /// Refreshes the UI when results land so screens re-read the fresh derived rows.
  Future<void> _afterDrain({bool heavy = false}) async {
    final mode = heavy ? 'heavy' : 'light';
    try {
      // Context for whatever crash/ANR report comes next — the derivation
      // engine's heavy per-day compute is isolate-offloaded, but the
      // assembly/UI-refresh wiring around it still runs on the main isolate,
      // so this is real signal if a freeze/ANR correlates with a derive pass.
      TelemetryService.instance.setContext('derive_mode', mode);
      TelemetryService.instance.setContext('derive_active', true);
      TelemetryService.instance.breadcrumb('derive: $mode start');
      // Refresh the UI after EACH day so Today/trends fill in as the sweep runs,
      // not only at the end (a multi-day backfill can be many days of work).
      await TelemetryService.instance.traced('derive_$mode', () => _derive.run(
        _profile,
        heavy: heavy,
        onDayDone: (day, index, total) async {
          if (index == total || index == 1 || index % 3 == 0) {
            dbCounts = await LocalDb.counts();
            notifyListeners();
          }
        },
      ));
      TelemetryService.instance.breadcrumb('derive: $mode done');
      // A drain can bank band coverage and a day can have rolled over since the
      // last read — both change which source owns today's steps.
      unawaited(_refreshPhoneStepsToday());
      // The drain that triggered this pass may have landed the 1 Hz window of a
      // workout the app slept through, whose strain/calories were scored from
      // whatever few minutes the foreground tally saw (issue #206). Re-score
      // recent sessions against the substrate now that it is here, so the
      // workout LIST is corrected too and not just a detail screen someone
      // happens to open. Monotone and idempotent — see reconcileSessionScore.
      try {
        final fixed = await repo?.rescoreRecentSessions() ?? 0;
        if (fixed > 0) {
          _log('[derive] rescored $fixed session(s) from substrate');
        }
      } catch (e) {
        _log('[derive] session rescore failed: $e');
      }
      await LocalDb.refreshComputeFreshness();
      _bumpInsightsRevision();
      notifyListeners(); // screens re-fetch from the derived store
      // A heavy finalize is where a freshly-closed sleep window + recovery for a
      // new physiological day lands — fire the "recovery ready" push off it.
      if (heavy) {
        unawaited(_maybeNotifyRecoveryReady());
        // Baseline-dirty rescan: new data may have shifted the rolling baseline,
        // so refresh baseline-dependent scalars (readiness/illness/stress) on
        // recent FINALIZED days. Cheap when the baseline is unchanged (a single
        // signature read). Best-effort — never throws into the BLE path.
        unawaited(() async {
          try {
            final n = await _derive.rescanRecent(_profile);
            if (n > 0) {
              notifyListeners(); // screens re-read the refreshed scalars
            }
          } catch (e) {
            _log('[derive] rescan failed: $e');
          }
        }());
      }
      // Continuous health export: push freshly-derived days (incl. TODAY) to Apple
      // Health / Health Connect AS SOON as they're computed — runs on BOTH the
      // light (every drain) and heavy passes, not only on finalize. Idempotent
      // (delete-then-write), best-effort, never throws into the BLE/derive path.
      if (healthSyncEnabled) {
        unawaited(() async {
          try {
            final n = await _runHealthExport();
            if (n > 0) _log('[health] exported $n day(s)');
          } catch (e) {
            _log('[health] export failed: $e');
          }
        }());
      }
      // Companion (opt-in): flush any queued telemetry now that we're doing network
      // work anyway, and — on a heavy (finalize) pass — consider the once/day full
      // .db upload (itself gated on Wi-Fi + charging + >24h). Both best-effort.
      if (telemetryConsent) unawaited(TelemetryService.instance.flush());
      if (heavy && healthShareConsent) {
        unawaited(HealthUploader.instance.maybeUpload(consented: true));
      }
    } catch (e, st) {
      _log('[derive] post-drain failed: $e');
      // Was silently swallowed before — this is a real pipeline failure
      // (derive/health-export/etc.) that Firebase never saw. Non-fatal, not
      // fatal: the app keeps running, but this is worth knowing about.
      TelemetryService.instance.recordNonFatal(e, st, reason: 'post_drain_failed');
    } finally {
      TelemetryService.instance.setContext('derive_active', false);
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

      // Sleep hours from the day's bundle accounting (tst), for the body copy.
      String slept = '';
      try {
        final payload = SeriesCodec.decodePayloadJson(
          (row['payload_json'] ?? '{}').toString(),
        );
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
          body: 'Recovery $score$slept. Tap to see today.',
          date: dayId,
          route: '/today',
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
      if (ai.eveningEnabled && minOfDay >= ai.eveningMin) {
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
      final goal = (user?['step_goal'] as num?)?.toInt();
      if (goal == null || goal <= 0) return;
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
          priority: NotifPriority.low,
          title: 'Step goal reached',
          body:
              'You hit about $steps steps — at or above your $goal goal. Nice work.',
          date: date,
          route: '/today',
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
      await prefs.setInt(_kLastInactivityMs, nowMs);

      // CodeRabbit caught this as un-padded (e.g. "2026-7-5" instead of
      // "2026-07-05") — breaks the YYYY-MM-DD convention every other
      // dedupeKey/date field in this file already follows.
      final today = todayLabel();
      await NotificationCenter.instance.emit(
        NotificationEvent(
          dedupeKey: '$today:posture:${nowMs ~/ (2 * 60 * 60 * 1000)}',
          category: NotifCategory.reminders,
          priority: NotifPriority.low,
          title: 'Posture Check & Stretch',
          body:
              'You’ve been in a typing posture for over 90 minutes without walking. Time to stretch your legs and reset your posture!',
          date: today,
          route: '/today',
        ),
      );
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
      await NotificationService.instance.cancel(NotificationService.idStillness);
      final at =
          DateTime.fromMillisecondsSinceEpoch(nowMs).add(const Duration(hours: 2));
      if (at.hour < 9 || at.hour >= 21) return; // would land outside daytime
      await NotificationService.instance.scheduleOnce(
        id: NotificationService.idStillness,
        category: NotifCategory.reminders,
        title: 'Time to move',
        body:
            "You've been still for a couple of hours — a short walk keeps your energy and circulation up.",
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
            dbCounts = await LocalDb.counts();
            notifyListeners();
          }
        },
      );
      await LocalDb.refreshComputeFreshness();
      _bumpInsightsRevision();
      dbCounts = await LocalDb.counts();
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
    await _reanalyzeForOverride();
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
    await _reanalyzeForOverride();
  }

  /// Remove a manual/confirmed override for [date] — revert to auto/fallback.
  Future<void> clearSleepOverride(String date) async {
    await LocalDb.deleteSleepOverride(date);
    await _reanalyzeForOverride();
  }

  /// Force-derive after a sleep-override change so the affected day restages from
  /// the user's window (the engine force-includes override days even if locked).
  Future<void> _reanalyzeForOverride() async {
    if (reanalyzing) return;
    reanalyzing = true;
    notifyListeners();
    try {
      await _derive.run(_profile, force: true);
      await LocalDb.refreshComputeFreshness();
      dbCounts = await LocalDb.counts();
    } catch (e) {
      _log('[derive] sleep-override re-derive failed: $e');
    } finally {
      reanalyzing = false;
      notifyListeners();
    }
  }

  /// Re-derive after a nap edit. Same machinery as a sleep-override change —
  /// nap minutes feed sleep need and sleep debt, so an edit is a recompute
  /// rather than a redraw, and the engine force-includes nap-edit days even
  /// when they are finalized.
  Future<void> reanalyzeForNapEdit() => _reanalyzeForOverride();

  Future<int> reanalyzeDays(Set<String> days) async {
    if (days.isEmpty || reanalyzing) return 0;
    reanalyzing = true;
    final ordered = days.toList()..sort();
    reanalyzeProgress =
        'Analyzing ${ordered.length} day${ordered.length == 1 ? '' : 's'}…';
    notifyListeners();
    try {
      final n = await _derive.runDays(
        _profile,
        days,
        force: true,
        onDayDone: (day, index, total) async {
          reanalyzeProgress = 'Analyzing $index/$total';
          if (index == total || index == 1 || index % 3 == 0) {
            dbCounts = await LocalDb.counts();
            notifyListeners();
          }
        },
      );
      await LocalDb.refreshComputeFreshness();
      _bumpInsightsRevision();
      dbCounts = await LocalDb.counts();
      return n;
    } catch (e) {
      _log('[derive] reanalyze selected failed: $e');
      return 0;
    } finally {
      reanalyzing = false;
      reanalyzeProgress = '';
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> dataHistoryDays() =>
      LocalDb.dataHistoryDays();

  Future<int> dataFileBytes() => LocalDb.databaseFileBytes();

  Future<String> exportDaysDb(Set<String> dayIds) =>
      LocalDb.exportDaysDb(dayIds);

  Future<int> deleteDays(Set<String> dayIds) async {
    final deleted = await LocalDb.deleteDays(dayIds);
    await LocalDb.refreshComputeFreshness();
    dbCounts = await LocalDb.counts();
    lastSynced = await LocalDb.latestSample();
    notifyListeners();
    return deleted;
  }

  /// Debounced "new data stored" callback from the engine (continuous listening has
  /// no discrete sync end). The engine already coalesced the burst; we run a single
  /// LIGHT derive over the affected day(s) and refresh DB counts for the UI.
  ///
  /// This is also THE reliable place to refresh `_lastRecTs` (the "last data"
  /// freshness banner reads it). `_runSyncBurst`'s own before/after frontier
  /// check can race the async commit — HISTORY_END's commit+ACK sometimes
  /// lands just after `engine.runSync()` already returned, so that
  /// checkpoint-based refresh can miss a burst entirely. This callback fires
  /// on EVERY successful persist path (foreground burst, background/headless
  /// drain, live-triggered store) after the write is durable, so it can't
  /// race it — same guarantee dbCounts already relies on above.
  void _onDataStored() {
    // Synchronously, before the async read below: this is the moment records
    // became durable, and it is the only path that sees every commit.
    _markSyncActivity();
    unawaited(() async {
      dbCounts = await LocalDb.counts();
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
  void _onLiveEvent(int id, int ts, String hex) {
    LocalDb.insertEvent(id, ts, hex);
    _handleAlarmEvent(id, ts);
    _gestureDispatcher.onEvent(id, ts, hex);
  }

  Future<void> _init() async {
    paired = await PairedDevice.load();
    await _loadProfile();
    await _refreshNightlyRhr();
    await _deriveScheduler.init();
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
    dbCounts = await LocalDb.counts();
    await LocalDb.refreshComputeFreshness();
    _savedAlarm = (await SharedPreferences.getInstance()).getInt('alarm_epoch');
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
    unawaited(
      armWaterReminder(),
    ); // arm the hydration strap-buzz (timers don't persist)
    // App status (OTA pointer + admin alert banner) — best-effort, non-blocking.
    unawaited(_loadAppStatus());
    // Register the recurring wall-clock nudges as real OS-scheduled notifications
    // (wind-down, weekly recap) so they fire even when the app is closed.
    if (isPaired) unawaited(_ensureRemindersScheduled());
    if (isPaired) {
      if (_background) {
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
          if (await engine.connectToRemoteId(paired!.remoteId)) {
            // A process kill followed by an iOS BLE-restore relaunch lands
            // HERE, not in openSession() — this is the primary case the live
            // step checkpoint exists for, so recovery has to run on this path
            // too or those steps sit in prefs forever. Counters are fresh on a
            // cold launch, so there is nothing to double-count.
            await _recoverOrphanedLiveSession();
            _resetLivePedometer();
            _maybeDowngradeLiveForBackground();
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
      // Fire the "time to sleep" nudge at the Sleep Coach's recommended bedtime
      // when we have one (from the crossday rollup), else the fixed default.
      double? bedtimeMin;
      try {
        final cd = await LocalDb.baseline('crossday');
        final m = cd?['payload_json'];
        if (m is String) {
          final j = jsonDecode(m);
          final bt = j is Map ? ((j['sleep_coach'] as Map?)?['bedtime']) : null;
          final v = bt is Map ? bt['value'] : null;
          final b = v is Map ? (v['bedtime_min_of_day'] as num?) : null;
          bedtimeMin = b?.toDouble();
        }
      } catch (_) {
        /* fall back to default bedtime */
      }
      await NotificationCenter.instance.scheduleStandingReminders(
        prefs,
        bedtimeMinOfDay: bedtimeMin,
      );
      // AI nudges (morning/evening briefing prompts + pre-sleep journal).
      final ai = await AiPrefs.load();
      await NotificationCenter.instance.scheduleAiReminders(
        prefs,
        ai,
        aiConfigured: coachConfig?.hasKey ?? false,
        bedtimeMinOfDay: bedtimeMin,
        journalDoneToday: BriefingStore.journalDoneToday(),
      );
    } catch (e) {
      _log('[notify] schedule reminders skipped: $e');
    }
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
  Map<String, dynamic>? schemaHealth;
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
      final health = await LocalDb.schemaHealth();
      schemaHealth = health;
      if (health['ok'] != true) {
        _log('[db] schemaHealth FAILED: $health');
      }
      notifyListeners();
    } catch (e) {
      _log('[db] schemaHealth check skipped: $e');
    }
  }

  void _bumpInsightsRevision() {
    insightsRevision.value = insightsRevision.value + 1;
  }

  /// Called when the app goes to the background.
  ///
  /// iOS keeps an app alive in the background ONLY while it holds an active BLE
  /// connection with a subscribed characteristic (UIBackgroundModes: bluetooth-central).
  /// So we DELIBERATELY keep the live connection + streams up here instead of
  /// disconnecting — the band keeps pushing notifications, iOS resumes us per
  /// notification, and the local drain continues continuously.
  ///
  /// We still own the band, so the restore central must NOT arm a competing connect.
  /// `BleRestoreManager` is armed only as a RECOVERY path if the connection actually
  /// drops (band out of range / app jettisoned) — see [_onEngineState] / [_armRecovery].
  ///
  /// On Android the Edge Tracking foreground service keeps the process + connection alive.
  Future<void> pauseForBackground() async {
    _background = true;
    // Step the Android link down to a power-saving connection interval — see
    // `desiredLinkPriority` (issue #200).
    engine.setBackground(true);
    // Defer derivation while backgrounded — running the heavy derive pass on a
    // short background BLE wake gets the app killed (iOS CPU watchdog / jetsam).
    // Capture keeps running; queued derive jobs drain on foreground return.
    _deriveScheduler.setBackground(true);
    // LIVE-FLOOD SUPPRESSION GUARD: with no foreground consumer of the live
    // streams (no workout / spot check / step calibration), downgrade live to
    // HR-only so the high-rate raw flood can't starve the periodic R24 offloads
    // while backgrounded. Full live is restored on foreground reclaim.
    _maybeDowngradeLiveForBackground();
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
      _log(
        'Backgrounded — holding live connection for continuous background capture',
      );
    } else {
      // No live connection to hold — fall back to the restore path so iOS relaunches us
      // when the band reappears.
      await _armRecovery();
      _log('Backgrounded — no live connection; armed iOS restore recovery');
    }
  }

  /// True while some foreground feature is actively consuming the live streams
  /// (workout coach, HRV spot check, breathing session).
  bool get _hasLiveConsumer =>
      activeWorkout != null || spotActive || breathingActive;

  /// Downgrade live to HR-only when backgrounded with no live consumer. The
  /// keep-alive re-arm respects the HR-only mode, so the downgrade sticks until
  /// [openSession]'s fast reclaim (or a reconnect in the foreground) restores
  /// the full set.
  void _maybeDowngradeLiveForBackground() {
    if (!engine.isConnected || !engine.liveEnabled) return;
    if (_hasLiveConsumer) return;
    unawaited(engine.enableHrOnlyLive());
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

  // Historical singles only now (live frames go through _onLiveFrame and are
  // never persisted). Just write the raw record (+ optional decoded sample).
  Future<void> _onRecord(Sample? sample, RawRecord raw) async {
    final ts = raw.recTs ?? sample?.tsEpoch;
    if (ts != null && ts > 0 && ts > (_lastRecTs ?? 0)) _lastRecTs = ts;
    await LocalDb.insertRecord(raw, sample);
  }

  // Ephemeral live high-rate frame (0x28/0x2B/0x33) — NOT persisted. Spot-check
  // taps the RR-bearing frames (0x28 compact HR, 0x2B R10) into the in-memory
  // scan buffer. Cheap-bounded; cleared at each scan start.
  void _onLiveFrame(int pt, String hex, int? recTs) {
    // NOTE: deliberately do NOT advance _lastRecTs from live frames. Live frames
    // (0x28/0x2B/0x33) are ephemeral and NEVER persisted, and they carry the
    // CURRENT wall-clock time — so bumping _lastRecTs here pinned the "last data"
    // label to "now" while the app was connected, hiding whether the overnight
    // HISTORICAL backlog had actually synced. "Last data" must reflect the newest
    // STORED record (the data edge), which only _onRecord advances.
    if (spotActive && (pt == 0x28 || pt == 0x2B)) {
      if (_spotFrames.length < 8000) _spotFrames.add(hex);
    }
    if (breathingActive && (pt == 0x28 || pt == 0x2B)) {
      if (_breathingFrames.length < 8000) _breathingFrames.add(hex);
    }
    // LIVE STEP COUNTER. The dedicated 0x33 IMU stream is the high-rate live
    // accel — it arrives ~10 frames/s (10 samples each), so it drives a smooth,
    // responsive count. Full R10 (0x2B) is only a fallback when the IMU stream
    // isn't flowing (and live 0x2B is often R10-LITE, which carries no accel).
    // `frameAccel` returns |a|(g) samples for both; once 0x33 is seen we ignore
    // 0x2B to avoid double-counting the same motion from two stream formats.
    if (pt == 0x33) {
      _imuStreamSeen = true;
      final f = _safeFrameAccel(hex);
      if (f != null) {
        _ingestLiveMags(f);
        _trackCoverage(recTs);
      }
    } else if (pt == 0x2B && !_imuStreamSeen) {
      final f = _safeFrameAccel(hex);
      if (f != null) {
        _ingestLiveMags(f);
        _trackCoverage(recTs);
      }
    }
  }

  proto.ImuFrame? _safeFrameAccel(String hex) {
    try {
      return proto.frameAccel(hex);
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
  int _liveSamples = 0; // total 100 Hz samples streamed this session
  bool _imuStreamSeen = false; // prefer the 0x33 IMU stream once it appears
  static const int _minuteSamples = 6000; // 60 s @ 100 Hz — calibration chunk
  int _lastWalkMs = 0; // last time steps were accumulated
  int _lastProneMs = 0; // last time the wrist was in a flat/typing posture
  int _lastLiveUiNotifyMs = 0;
  // DEVICE-time window (epoch sec) the live pedometer covered this session — so
  // the 1 Hz estimate can EXCLUDE these minutes (100 Hz real count wins).
  //
  // The band's record timestamp is the ANCHOR only: it keeps the window in the
  // same base as `decoded_onehz.rec_ts` (what `coverageWindowsOverlapping`
  // compares against). It is NOT the duration — in practice every live frame of
  // a session repeats the same `recTs`, so start==end and the window covered
  // nothing. The duration comes from what we actually ingested (100 Hz sample
  // count + the phone-clock hull of the ingest times), combined by
  // [deriveLiveCoverageWindow]. See that function for the base reconciliation.
  int? _liveCoverStartTs;
  int _liveCoverEndTs = 0;
  int? _liveFirstIngestMs; // phone clock at the first ingested live frame
  int? _liveLastIngestMs; // …and at the last one
  void _trackCoverage(int? recTs) {
    if (recTs == null || recTs <= 0) return;
    _liveCoverStartTs ??= recTs;
    if (recTs > _liveCoverEndTs) _liveCoverEndTs = recTs;
  }

  /// The window this session covered, or null when there is nothing defensible
  /// to record. Pure decision lives in [deriveLiveCoverageWindow]; this only
  /// feeds it the observations.
  LiveCoverageWindow? _liveCoverageWindow(int steps) => deriveLiveCoverageWindow(
        steps: steps,
        samples100Hz: _liveSamples,
        bandStartTs: _liveCoverStartTs,
        bandEndTs: _liveCoverEndTs,
        firstIngestMs: _liveFirstIngestMs,
        lastIngestMs: _liveLastIngestMs,
      );

  /// Steps counted on the live 100 Hz stream this connected session (real,
  /// gain-applied). Used for cadence calibration. 0 when not streaming.
  int get _liveRaw =>
      _committedRaw + (_magMin.isEmpty ? 0 : ana.pedometer(_magMin));

  // A routine BLE disconnect zeroes the live counter for a fresh session
  // (`_resetLivePedometer`) before the derived day_result has had a chance to
  // fold the just-ended session's steps in — the Today tile would otherwise
  // visibly drop then jump back once derivation catches up. Hold the ended
  // session's total on display for a short grace window so the number never
  // regresses; the derived total supersedes it well within that window.
  int _sessionStepsCushion = 0;
  int _sessionCushionSetAtMs = 0;
  static const int _sessionCushionGraceMs = 20 * 1000;

  /// The TRUE gain-applied step count for THIS connected session, with no
  /// display cushion. Everything that PERSISTS or CALIBRATES must read this —
  /// [liveSteps] is display-only and can deliberately report a just-ended
  /// PRIOR session's larger total during its grace window, which would
  /// double-count into `live_coverage` and poison the cadence model.
  int get _rawSessionSteps => (_liveRaw * ana.StepParams.gain).round();

  /// Rebases the connection-lifetime counter at local midnight — see
  /// [LiveStepDayWindow] for why a permanently-connected band made the Today
  /// tile carry yesterday's steps into today.
  final LiveStepDayWindow _liveStepDay = LiveStepDayWindow();

  int get liveSteps {
    final today = todayLabel();
    final dayChanged = _liveStepDay.day != null && _liveStepDay.day != today;
    final raw = _liveStepDay.stepsToday(_rawSessionSteps, today);
    // The cushion holds a PRE-midnight session total for a few seconds so the
    // tile doesn't visibly dip on a reconnect. Carried across the boundary it
    // would re-introduce exactly the number we just rebased away.
    if (dayChanged) _sessionStepsCushion = 0;
    if (_sessionStepsCushion <= 0) return raw;
    if (DateTime.now().millisecondsSinceEpoch - _sessionCushionSetAtMs >=
        _sessionCushionGraceMs) {
      _sessionStepsCushion = 0;
      return raw;
    }
    return math.max(raw, _sessionStepsCushion);
  }

  // Snapshot of the RAW session total at the moment a manual workout started, so
  // the live-session screen shows steps FOR THIS WORKOUT (not since connection).
  int? _workoutRawBase;

  /// Whether ANY gait-capable accel sample has reached us since the active
  /// workout began, so [workoutStepsMeasured] can tell "did not move" apart
  /// from "the band never sent anything to count".
  ///
  /// Deliberately a latch and NOT a comparison against `_liveSamples`:
  /// `_resetLivePedometer()` zeroes that counter on every (re)connect, and it
  /// runs mid-workout. A counter comparison therefore went permanently
  /// "unmeasured" after the first reconnect — steps stuck on a dash for the
  /// rest of the workout and `stopWorkout` banking none — which is the same
  /// trap `_resetLivePedometer` already sidesteps for `_workoutRawBase` by
  /// rebasing it negative rather than dropping it.
  bool _workoutSawSamples = false;

  /// Steps taken since the active workout started (real, live, gain-applied).
  /// 0 when no workout is running.
  ///
  /// Prefer [workoutStepsMeasured] in anything user-facing: this coerces an
  /// unmeasured workout to 0, which is only safe because the two remaining
  /// callers treat 0 as "omit" (the finish card hides the stat, `stopWorkout`
  /// leaves the column unset).
  int get workoutSteps => workoutStepsMeasured ?? 0;

  /// Steps for the active workout, or NULL when nothing gait-capable was ever
  /// measured for it (issue #183).
  ///
  /// The live count needs the band's 100 Hz accel stream. That stream is
  /// routinely absent even during a perfectly good workout: the sticky
  /// standard-HR fallback suppresses it, the background downgrade turns it off,
  /// and a pocketed phone can drop it entirely — while GPS distance and the
  /// 1 Hz HR keep flowing. Reporting `0` in that state is a fabricated
  /// measurement, and it is what the issue screenshotted: a mile walked, HR and
  /// distance both right, "0 STEPS" beside them.
  int? get workoutStepsMeasured {
    if (activeWorkout == null || _workoutRawBase == null) return null;
    // Nothing gait-capable has arrived for this workout — unmeasured, as
    // opposed to zero steps having been measured.
    if (!_workoutSawSamples) return null;
    final raw = _liveRaw - _workoutRawBase!;
    return raw > 0 ? (raw * ana.StepParams.gain).round() : 0;
  }

  void _ingestLiveMags(proto.ImuFrame f) =>
      _ingestLiveMagsAt(f, DateTime.now().millisecondsSinceEpoch);

  // `nowMs` is passed in (rather than read here) so the coverage bookkeeping
  // this method feeds is drivable from a test without a fake clock.
  void _ingestLiveMagsAt(proto.ImuFrame f, int nowMs) {
    final mags = f.mags;
    if (mags.isEmpty) return;
    // Survives `_resetLivePedometer()` — see [_workoutSawSamples].
    if (activeWorkout != null) _workoutSawSamples = true;
    // Append this frame's |a|(g) samples (gravity INCLUDED — AN-2554's dynamic
    // threshold rides the ~1 g baseline). `e` is this frame's 1 Hz-equivalent
    // ENMO (mean |a| − 1 g), read below by the stillness nudge and the posture
    // check. It no longer feeds a cadence calibration — that was deleted along
    // with the 1 Hz step estimator that was its only consumer (kAlgoVersion
    // v55).
    var magSum = 0.0;
    for (final m in mags) {
      _magMin.add(m);
      magSum += m;
    }
    _liveSamples += mags.length;
    final e = (magSum / mags.length) - 1.0;
    // Phone-clock extent of the ingested stream — the only observation that
    // reports how long this session actually ran (the band's record timestamp
    // typically repeats). Used as a DURATION only; see [_liveCoverageWindow].
    _liveFirstIngestMs ??= nowMs;
    if (_liveLastIngestMs == null || nowMs > _liveLastIngestMs!) {
      _liveLastIngestMs = nowMs;
    }
    // Stamp last real motion (for the inactivity nudge). 0.02 g over baseline is
    // clearly dynamic movement, not resting jitter.
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
      final before = _committedRaw;
      _committedRaw += ana.pedometer(minute);
      if (_committedRaw > before) _lastWalkMs = nowMs;
      committedThisTick = true;
    }
    // Checkpoint once a minute (only on an actual commit, not every frame) so
    // a killed process doesn't lose the whole session — only whatever hasn't
    // completed a minute yet. See _recoverOrphanedLiveSession.
    if (committedThisTick) unawaited(_checkpointLiveSession());
    // Keep the day window current from the SAMPLE path. Reading it only when
    // the Today tile is built would make the first read after midnight the
    // window's first observation of any day — and a first observation counts
    // in full, so a phone parked on another tab across midnight would carry
    // the whole of yesterday's session into today.
    if (committedThisTick) _liveStepDay.stepsToday(_rawSessionSteps, todayLabel());
    if (nowMs - _lastLiveUiNotifyMs >= 1000) {
      _lastLiveUiNotifyMs = nowMs;
      notifyListeners(); // live readout re-counts the partial minute on read
    }
  }

  /// Reset the live step counter for a fresh connected session.
  ///
  /// This zeroes the connection-lifetime raw counter (`_liveRaw`). If a
  /// workout is active, `_workoutRawBase` was snapshotted from a *previous*
  /// (now-stale) `_liveRaw` value — left untouched, `workoutSteps` would
  /// compute a negative delta on the next BLE disconnect/reconnect blip,
  /// clamp to 0, and visibly reset the walk's step count instead of counting
  /// monotonically. Rebase it here so the already-accrued workout steps
  /// carry through the reset.
  void _resetLivePedometer() {
    if (activeWorkout != null && _workoutRawBase != null) {
      final accruedRaw = _liveRaw - _workoutRawBase!;
      _workoutRawBase = accruedRaw > 0 ? -accruedRaw : 0;
    }
    _magMin.clear();
    _committedRaw = 0;
    _liveSamples = 0;
    _lastLiveUiNotifyMs = 0;
    _imuStreamSeen = false;
    _liveCoverStartTs = null;
    _liveCoverEndTs = 0;
    _liveFirstIngestMs = null;
    _liveLastIngestMs = null;
  }

  /// End-of-session: bank the REAL 100 Hz step window into `live_coverage`.
  ///
  /// No cadence calibration any more — its only consumer was the deleted 1 Hz
  /// `dailyStepEstimate` (see kAlgoVersion v55).
  Future<void> _finalizeLivePedometer() async {
    // RAW, never the cushioned display value: a second short session ending
    // inside the first one's grace window would otherwise persist the FIRST
    // session's total again (double-counted coverage + a nonsense cadence).
    final steps = _rawSessionSteps; // gain-applied
    // Derive the coverage window BEFORE resetting (it reads session counters).
    final window = _liveCoverageWindow(steps);
    if (steps > 0) {
      // Never LOWER a still-active cushion — a small follow-up session ending
      // inside the grace window must not reintroduce the visible regression
      // the cushion exists to prevent.
      final active = liveSteps; // expires the cushion if it is already stale
      _sessionStepsCushion = math.max(
        steps,
        math.max(active, _sessionStepsCushion),
      );
      _sessionCushionSetAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    _resetLivePedometer();
    // Record the REAL 100 Hz step window (device time). This is BAND-sourced
    // coverage; the derivation reads it via `liveStepsForDay`, which prefers a
    // phone count for the day when one exists and never sums the two.
    if (window != null) {
      final day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(window.startTs * 1000),
      );
      await LocalDb.addLiveCoverage(window.startTs, window.endTs, steps, day);
    }
    // The session ended cleanly and is now durably recorded — the checkpoint
    // that would otherwise let a killed-process session recover is no longer
    // needed.
    await _clearLiveSessionCheckpoint();
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
    if (_committedRaw <= 0 || _liveCoverStartTs == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kLiveSessionCheckpoint,
        jsonEncode({
          'steps': (_committedRaw * ana.StepParams.gain).round(),
          'samples': _liveSamples,
          'cover_start_ts': _liveCoverStartTs,
          'cover_end_ts': _liveCoverEndTs,
          'first_ingest_ms': _liveFirstIngestMs,
          'last_ingest_ms': _liveLastIngestMs,
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
      final steps = (m['steps'] as num?)?.toInt() ?? 0;
      final startTs = (m['cover_start_ts'] as num?)?.toInt();
      final endTs = (m['cover_end_ts'] as num?)?.toInt();
      if (steps <= 0 || startTs == null || endTs == null || endTs <= startTs) {
        return await drop();
      }
      final window = deriveLiveCoverageWindow(
        steps: steps,
        samples100Hz: (m['samples'] as num?)?.toInt() ?? 0,
        bandStartTs: startTs,
        bandEndTs: endTs,
        firstIngestMs: (m['first_ingest_ms'] as num?)?.toInt(),
        lastIngestMs: (m['last_ingest_ms'] as num?)?.toInt(),
      );
      if (window == null) return await drop();
      // The clean-shutdown path writes coverage BEFORE clearing the checkpoint,
      // so a kill in that gap leaves a checkpoint whose bout is already banked —
      // and `live_coverage` has no uniqueness on the window, so replaying it
      // would silently inflate the day. Skip anything already recorded.
      if (await LocalDb.hasLiveCoverageWindow(window.startTs, window.endTs)) {
        _log('[steps] orphan checkpoint already banked — not re-adding');
        return await drop();
      }
      final day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(window.startTs * 1000),
      );
      await LocalDb.addLiveCoverage(window.startTs, window.endTs, steps, day);
      await drop();
      _log('[steps] recovered $steps orphaned step(s) from a killed session');
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
      );
    } catch (e) {
      // A forecast is a nicety; it must never take down the state update that
      // carries the actual band data.
      _log('[battery-forecast] skipped: $e');
    }
  }

  void _onEngineState(DeviceState s) {
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
      unawaited(PairedDevice.save(healed.remoteId, healed.serial));
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
      // Live stream ended → fold this bout into the personal cadence calibration
      // (best-effort; only credible walking updates it) and reset the counter.
      unawaited(_finalizeLivePedometer());
      if (_keepAlive && isPaired && !_reconnecting && !device.autoReconnectPaused) {
        _log('Connection dropped — reconnecting…');
        _stopBackfillTimer();
        if (_background) {
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

  /// Cadence of the reconnect supervisor. Cheap — the tick reads local flags
  /// and does nothing at all unless the app is paired, wants a link, and does
  /// not have one.
  static const Duration _reconnectSupervisorInterval = Duration(minutes: 1);

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
  /// its purpose and keeps poking the engine once a minute forever.
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
    if (_disposed) return;
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
    if (_background) {
      // The OFFLOAD is what we're skipping — the engine's own floored timer
      // owns that. The wake-window re-plan is NOT the engine's: nothing else
      // re-evaluates it on a stable connection, and it only flips on as the
      // 90-minute pre-wake window opens. Skipping it outright meant a band
      // that connected at 22:00 and stayed connected never armed high-frequency
      // sync for that night at all.
      try {
        await _refreshHighFreqWakeWindow();
      } catch (e) {
        _log('Wake-window refresh failed: $e');
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
        dbCounts = await LocalDb.counts();
        _deriveScheduler.markStoredData();
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
    var last = SyncReport(0, 0, false);
    for (var i = 0; i < maxSessions && engine.isConnected; i++) {
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
      // burst session, not just at app boot. `_lastRecTs` was previously only
      // ever seeded in `_init()` — during a real historical drain, records go
      // through `_DrainController.onHistoricalRecord` → `onCommitBatch`
      // (bypassing `_onRecord`'s in-memory bump, which only fires on the rare
      // pre-drain-setup fallback path), so a session left open kept showing
      // "more than an hour behind" no matter how much fresh data actually
      // synced, until the app was fully restarted. Bump + notify here so the
      // UI reflects real progress as it happens, mid-burst.
      if (frontierAfter != null && frontierAfter > (_lastRecTs ?? 0)) {
        _lastRecTs = frontierAfter;
        notifyListeners();
      }
      final strapNewest = engine.strapHistoryNewestTs;
      final frontierAdvanced =
          frontierAfter != null &&
          (frontierBefore == null || frontierAfter > frontierBefore);
      final backlogRemains =
          strapNewest != null &&
          frontierAfter != null &&
          (strapNewest - frontierAfter) > 300;
      last = report;
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
    return last;
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
    await PairedDevice.save(remoteId, serial ?? device.serial);
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
    await PairedDevice.clear();
    paired = null;
    notifyListeners();
  }

  // ── alarm + strap name (require a live connection) ──────────────────────────
  bool get isConnected => device.connection == 'connected';
  // The locally-set value is authoritative: the band has no independent alarm
  // source (its alarm is always what the app last wrote, and SET_ALARM is
  // HW-verified), while the GET_ALARM readback format is unconfirmed and was
  // clobbering the display (see the parked block in ble_engine._onDecoded).
  // device.alarmEpoch = this-session optimistic set; _savedAlarm = persisted.
  int? get alarmEpoch => device.alarmEpoch ?? _savedAlarm;
  String? get strapName => device.strapName;
  int? _savedAlarm;

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

  /// A SET was written but not yet confirmed, still inside the grace window —
  /// the UI shows a neutral "Setting alarm…" state.
  bool get alarmPending =>
      _alarm.isPending(DateTime.now().millisecondsSinceEpoch);

  /// Set but neither confirmed nor still pending — show a soft warning (the band
  /// took the write but never confirmed it latched).
  bool get alarmUnconfirmed =>
      _alarm.isUnconfirmed(DateTime.now().millisecondsSinceEpoch);

  int? get alarmLastEventId => _alarm.lastEventId;
  int? get alarmFiredAt => _alarm.firedAt;

  Future<void> setAlarm(DateTime when) async {
    if (!isConnected) throw Exception('Connect to your strap first');
    final epoch =
        when.millisecondsSinceEpoch ~/ 1000; // local wall-clock → unix
    // Pass the DateTime through so the engine computes REAL sub-seconds for the
    // rich 20-byte firing form (a hardcoded 0 subsec would still fire, but the
    // engine owns the exact on-wire layout).
    final ok = await engine.setAlarm(when);
    if (!ok) {
      // The arm write never reached the band — do NOT persist or start the
      // confirmation machine, or we'd strand a phantom alarm "waiting for the
      // strap to confirm" that can never fire. Surface it so the UI reflects
      // "couldn't send" (the coach/profile callers snackbar on a throw).
      _log('[alarm] arm write FAILED — not persisting; alarm not set.');
      throw Exception('Alarm not sent — the strap did not accept the write');
    }
    _savedAlarm = epoch;
    device.alarmEpoch = epoch; // optimistic display
    _alarm.set(epoch, DateTime.now().millisecondsSinceEpoch); // await event 56
    _alarmAutoRetried = false; // fresh user-initiated set gets its one retry
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('alarm_epoch', epoch);
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
      Duration(milliseconds: _alarm.graceMs + 250),
      () => unawaited(_onAlarmGraceElapsed(when)),
    );
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
      notifyListeners();
      return;
    }
    _alarmAutoRetried = true;
    var rearmed = false;
    try {
      rearmed = await engine.setAlarm(when);
    } catch (e) {
      _log('[alarm] auto-retry re-arm failed: $e');
    }
    // The write itself never landed, so the one retry was not actually spent —
    // give it back rather than latching this alarm out of any future retry.
    if (!rearmed) _alarmAutoRetried = false;
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

  /// Live signal strength of the band in dBm, or null when unmeasurable.
  /// Deliberately raw — all smoothing and labelling belongs to
  /// ProximityTracker, which is testable without a radio.
  Future<int?> readBandRssi() => engine.readRssi();

  Future<void> disableAlarm() async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.disableAlarm();
    _savedAlarm = null;
    device.alarmEpoch = null;
    _alarm.disable();
    _alarmGraceTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('alarm_epoch');
    notifyListeners();
  }

  /// Retained name for the UI's "clear alarm" affordance — delegates to
  /// [disableAlarm] (the DISABLE_ALARM opcode).
  Future<void> clearAlarm() => disableAlarm();

  /// Strap alarm-lifecycle events (56 set / 57–58 fired / 59 disabled). This is
  /// the authoritative confirmation the SET write actually took. The edge DOES see
  /// the protocol EventId names (strapDrivenAlarmSet == 56, …); the pure state
  /// machine matches the raw ids so it stays dependency-free.
  void _handleAlarmEvent(int id, int ts) {
    final effect = _alarm.onEvent(id, DateTime.now().millisecondsSinceEpoch);
    if (effect == null) return;
    switch (effect) {
      case AlarmEffect.confirmed:
        _alarmGraceTimer?.cancel();
        // Diagnostic: ALARM_SET (event 56) means the arm LATCHED on the band.
        // Its absence after a SET is the tell that the write never took.
        _log('[alarm] strap CONFIRMED arm — ALARM_SET (event $id) received.');
        break;
      case AlarmEffect.fired:
        _log('[alarm] strap FIRED — EXECUTED (event $id) received.');
        unawaited(_notifyAlarmFired());
        // A one-shot alarm is SPENT the moment it fires. This used to only log
        // + notify, so `alarmEpoch` kept returning the past epoch across
        // relaunches (_init reloads `alarm_epoch`) and Profile's "Smart alarm"
        // row went on advertising e.g. "06:30 (7/25)" as the CURRENT alarm
        // indefinitely — with live "Test buzz"/"Clear" affordances for an alarm
        // that is no longer armed. Clear state AND the persisted epoch.
        _clearArmedAlarmState();
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
        route: '/today',
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
  Future<void> openSession() async {
    if (busy || paired == null) return;
    BandOwnership.markForegroundIntent(true);
    _log('[OWNERSHIP] foreground intent on (${BandOwnership.debugState})');
    // Returning to the foreground with the connection still alive (kept during
    // background): don't tear it down and reconnect — just reclaim ownership.
    final wasBackground = _background;
    _background = false;
    engine.setBackground(false);
    // Coming back after hours (or days) suspended: re-read the phone's steps
    // for whatever day it is NOW.
    if (phoneStepsEnabled) {
      unawaited(syncPhoneSteps());
    }
    // Back in the foreground with an OS CPU/memory budget again — let the
    // scheduler drain any derive jobs that queued (durably) while backgrounded.
    _deriveScheduler.setBackground(false);
    if (wasBackground && engine.isConnected) {
      IosBleRestore.foregroundActive = true;
      await IosBleRestore.setOwnsBand(true);
      EdgeTracking.start(); // Android: keep the foreground service up (idempotent)
      // iOS can resume with the peripheral still flagged "connected" while its GATT
      // notifications died during suspension — UI shows connected but NO events arrive,
      // and only a kill+reopen (full reconnect) recovers. Trust DATA, not the flag: if a
      // notification arrived recently the link is genuinely live → keep the fast reclaim.
      // Otherwise it's stale → tear it down and fall through to a clean reconnect, which
      // re-subscribes (the only place setNotifyValue runs) and drains the gap.
      if (!isLinkStale(engine.sinceLastRx)) {
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
        // Backgrounding downgraded live to HR-only (no raw flood) — restore the
        // full live set now that the foreground UI is consuming it again.
        if (engine.liveHrOnly) unawaited(engine.enableLiveStreams());
        // FOREGROUND CATCH-UP: R24 drains on a ~15-min timer while backgrounded,
        // so "last data" can lag up to 15 min behind a healthy link. The user
        // just opened the app — pull the flash backlog now. Floored at 90 s
        // (BackfillTrigger.foreground) so rapid app switching can't hammer the
        // strap. Non-blocking; single-flight via _kickSyncBurst.
        unawaited(foregroundCatchUp());
        _startBackfillTimer();
        return;
      }
      _log(
        'Resume: no BLE data for ${engine.sinceLastRx.inSeconds}s — stale link, reconnecting.',
      );
      await engine.disconnect();
      // fall through to the full connect → subscribe → drain path below
    }
    _setBusy(true);
    lastError = null;
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
      _log('===== SESSION START ===== raw=${dbCounts['raw']}');
      await _ensureForegroundLease();
      // connect() now subscribes → SET_CLOCK → INIT, so the historical offload is
      // ALREADY streaming the moment this returns.
      //
      // NOTE on side traffic: info polls (battery/name/high-frequency wake
      // config) and live-stream toggles ride the same link as the historical
      // burst. The per-revision packet accounting counts data-role frames only,
      // so these command exchanges don't perturb the burst packet counts.
      if (!await engine.connectToRemoteId(band.remoteId)) {
        lastError =
            'Could not reach your band. Is it nearby and free '
            '(official WHOOP app force-quit)?';
        return;
      }
      await engine.getBattery();
      await engine.getStrapName(); // populate strap name for the Profile UI
      // Alarm is displayed from the locally-set/persisted value (authoritative);
      // the GET_ALARM readback is parked (unconfirmed format) — see ble_engine.
      // Arm the strap's high-frequency sync window when a wake alarm is near
      // (denser flushes → fresher overnight data ahead of the alarm).
      await _refreshHighFreqWakeWindow();
      _log('Listening — live streams on, historical burst runs concurrently.');
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
      // for this session, BEFORE live delivery starts. Doing it after
      // enableLiveStreams() left a window where frames ingested during the
      // (awaited, I/O-bound) recovery were then wiped by _resetLivePedometer.
      await _recoverOrphanedLiveSession();
      _resetLivePedometer(); // fresh live step count for this connected session
      await engine.enableLiveStreams();
      dbCounts = await LocalDb.counts();
      unawaited(
        _kickSyncBurst(kickFirst: false).then((report) async {
          _log(
            'Backlog drained: ${report.records} records in ${report.batches} '
            'batches (${report.complete ? "complete" : "stopped early"}).',
          );
          dbCounts = await LocalDb.counts();
          // Re-evaluate the high-frequency wake window now the backlog landed.
          await _refreshHighFreqWakeWindow();
          // The whole backlog landed → heavy foreground finalize (full sleep
          // staging + 24-h spectra over every stale day).
          _deriveScheduler.requestHeavy();
          notifyListeners();
        }).catchError((Object e) {
          _log('Background sync burst failed: $e');
        }),
      );
      _startBackfillTimer();
    } catch (e) {
      lastError = e.toString();
    } finally {
      if (!engine.isConnected || !_keepAlive) {
        _stopBackfillTimer();
        BandOwnership.markForegroundIntent(false);
        _log('[OWNERSHIP] foreground intent off (${BandOwnership.debugState})');
        _releaseForegroundLease();
      }
      _setBusy(false);
    }
  }

  /// Direct connect attempts before handing the pending connect to the OS
  /// bluetooth stack (Android autoConnect fallback) — see [_reconnect].
  static const int _directAttemptsBeforeOsFallback = 4;

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
            (_background || attempt > _directAttemptsBeforeOsFallback);
        if (osPending) {
          connected = await engine.waitForOsAutoConnect(
            paired!.remoteId,
            keepWaiting: () => _keepAlive && !engine.isConnected,
          );
          if (connected && _keepAlive) {
            // Mark band ownership before the actual GATT setup so a headless
            // wake can't fight this reconnect for the peripheral.
            await _ensureForegroundLease();
            connected = await engine.connectToRemoteId(paired!.remoteId);
          } else {
            connected = false;
          }
        } else {
          await Future.delayed(engine.reconnectDelay(attempt));
          if (!_keepAlive) break;
          await _ensureForegroundLease();
          connected = await engine.connectToRemoteId(paired!.remoteId);
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
          // Live streams come up promptly; the FULL drain (no short timeout —
          // the ENTIRE offline backlog the band flashed while out of range)
          // runs concurrently, single-flight, exactly as in openSession.
          // Background reconnect with no live consumer → HR-only live, so the
          // raw flood can't starve the backlog drain we're about to run.
          if (_background && !_hasLiveConsumer) {
            await engine.enableHrOnlyLive();
          } else {
            await engine.enableLiveStreams();
          }
          _resetLivePedometer();
          await engine.getBattery();
          await engine.getStrapName();
          // Alarm display comes from the locally-set/persisted value; the
          // GET_ALARM readback is parked (unconfirmed format) — see ble_engine.
          _log('Reconnected — live on; draining backlog in background.');
          unawaited(
            _kickSyncBurst(kickFirst: false).then((report) async {
              dbCounts = await LocalDb.counts();
              _log('Reconnect backlog drained: ${report.records} records.');
              // Re-evaluate the high-frequency wake window now the backlog
              // landed.
              await _refreshHighFreqWakeWindow();
              // Backlog (often an overnight gap) just landed → derive it.
              _deriveScheduler.requestHeavy();
              notifyListeners();
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
      dbCounts = await LocalDb.counts();
      notifyListeners();
      // A just-finished workout window landed from flash → derive it (light).
      _deriveScheduler.markStoredData();
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
    if (isLinkStale(engine.sinceLastRx)) {
      _log(
        'Foreground catch-up: no BLE data for ${engine.sinceLastRx.inSeconds}s '
        '— zombie link, forcing reconnect instead of a stale-link pull.',
      );
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
        dbCounts = await LocalDb.counts();
        _deriveScheduler.markStoredData();
        notifyListeners();
      }
      _log('Foreground catch-up: ${report.records} records pulled.');
    } catch (e) {
      _log('Foreground catch-up sync failed: $e');
    }
  }

  Future<void> syncNow() => openSession();

  Future<void> _refreshHighFreqWakeWindow() async {
    if (!engine.isConnected) return;
    try {
      final plan = await HighFreqWakeWindow.planNow();
      await engine.applyHighFreqWakeWindow(
        enabled: plan.shouldEnable,
        targetWake: plan.targetWake,
        duration: HighFreqWakeWindow.lease,
        intervalSeconds: 60,
        reason: plan.source,
      );
      _log(
        '[SYNC] HighFreq wake window: source=${plan.source} '
        'samples=${plan.sampleCount} enabled=${plan.shouldEnable} '
        'target=${plan.targetWake?.toIso8601String()}',
      );
    } catch (e) {
      _log('[SYNC] HighFreq wake window skipped: $e');
    }
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

  String get status => device.connection;

  /// Wall-clock of the last BLE notification received (any characteristic). Used
  /// only to PULSE the indicator (link is alive / frames flowing). `null` until
  /// the first frame this connection.
  DateTime? get lastDataAt => engine.lastRxAt;

  Map<String, dynamic> get pipelineStatus => {
    'capture': engine.offloadSnapshot,
    'derive': {..._deriveScheduler.snapshot(), 'engine': _derive.snapshot()},
    'db_counts': dbCounts,
    'reanalyzing': reanalyzing,
    'reanalyze_progress': reanalyzeProgress,
  };

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

  /// Records reached durable storage. Called from the durable-write callback —
  /// NOT inferred from a sync burst finishing, because `_onDataStored` has
  /// already advanced the frontier by then, so the burst's own "did the
  /// frontier move" test is false exactly when data has just landed.
  void _markSyncActivity() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _syncActivity.mark(now);
    _syncQuietTimer?.cancel();
    _syncQuietTimer = Timer(
      Duration(milliseconds: _syncActivity.windowMs),
      () {
        _syncQuietTimer = null;
        notifyListeners();
      },
    );
  }

  /// REAL device timestamp of the newest record we hold (the band's own clock),
  /// NOT when the BLE frame arrived. This is what "last data: …" displays — a
  /// flash backfill arrives "now" but carries hours-old records. `null` until any
  /// record exists.
  DateTime? get lastRecordAt => _lastRecTs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_lastRecTs! * 1000);

  /// The quiet in-app half of the staleness-escalation meta-layer (see
  /// sync_policy.dart's stalenessTierFor doc + checkSyncStaleness, which
  /// drives the louder OS-notification half). A never-synced band reads as
  /// [StalenessTier.fresh] — that's a distinct, already-visible onboarding
  /// state, not silent staleness. Always computed fresh against wall-clock
  /// now, so any screen can read it without needing its own refresh timer.
  StalenessTier get syncStalenessTier {
    final last = lastRecordAt;
    if (last == null) return StalenessTier.fresh;
    return stalenessTierFor(DateTime.now().difference(last).inSeconds);
  }

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

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

  // ── live HRV spot-check ──────────────────────────────────────────────────────
  // User taps "spot check": we enable wrist-gated optical + realtime records,
  // collect live frames for [spotDuration]s, then hand them to the repo seam which
  // (in the re-layer) decodes RR + computes HRV on-device. Ephemeral — nothing stored.
  static const int spotDuration = 60;
  bool spotActive = false;
  int spotRemaining = 0; // seconds left in the current scan
  Map<String, dynamic>?
  spotResult; // last result {rmssd, sdnn, mean_hr, n_beats, ok}
  String? spotError;
  final List<String> _spotFrames = [];
  Timer? _spotTimer;
  bool _spotEnabledStreams =
      false; // did WE turn streams on (so we turn them off)

  /// Begin a 60s live HRV reading. Requires a connected band.
  Future<void> startSpotCheck() async {
    if (spotActive) return;
    if (!isConnected) {
      spotError = 'Connect your band first.';
      notifyListeners();
      return;
    }
    spotActive = true;
    spotError = null;
    spotResult = null;
    spotRemaining = spotDuration;
    _spotFrames.clear();
    notifyListeners();
    try {
      // OWNERSHIP: only claim "we enabled it" when live was actually OFF. The
      // open session keeps live streams armed for its whole lifetime — claiming
      // ownership then would make _stopSpotStreams turn OFF streams the session
      // still expects on (iOS then suspends the app → ingestion stalls).
      if (!engine.liveEnabled) {
        await engine.enableLiveStreams();
        _spotEnabledStreams = true;
      } else if (engine.liveHrOnly) {
        // Background downgrade active — the spot check needs the RR-bearing
        // R10 frames, so upgrade to full live WITHOUT taking ownership (the
        // session owns the streams; it restores/apportions them itself).
        await engine.enableLiveStreams();
      }
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
    _spotTimer?.cancel();
    _spotTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      spotRemaining -= 1;
      if (spotRemaining <= 0) {
        unawaited(_finishSpotCheck());
      } else {
        notifyListeners();
      }
    });
  }

  /// Abort an in-progress scan without computing.
  void cancelSpotCheck() {
    if (!spotActive) return;
    _spotTimer?.cancel();
    _spotTimer = null;
    spotActive = false;
    spotRemaining = 0;
    _stopSpotStreams();
    notifyListeners();
  }

  Future<void> _finishSpotCheck() async {
    _spotTimer?.cancel();
    _spotTimer = null;
    spotRemaining = 0;
    _stopSpotStreams();
    final frames = List<String>.from(_spotFrames);
    notifyListeners();
    try {
      final res = repo == null || frames.isEmpty
          ? null
          : await repo!.spotCheck(frames);
      spotResult = res;
      if (res == null) {
        spotError = 'No reading captured — keep the band snug and still.';
      } else if (res['ok'] != true) {
        spotError = 'Not enough clean beats — try again, sitting still.';
      }
    } catch (e) {
      spotError = 'Spot check failed: ${e is RepositoryException ? e.body : e}';
    } finally {
      spotActive = false;
      notifyListeners();
    }
  }

  void _stopSpotStreams() {
    if (_spotEnabledStreams && activeWorkout == null) {
      unawaited(engine.disableLiveStreams());
    }
    _spotEnabledStreams = false;
  }

  // ── guided-breathing cardiac coherence ──────────────────────────────────────
  // User taps "begin breathing session": enable live RR-bearing streams,
  // collect frames continuously in _breathingFrames (tapped from _onLiveFrame,
  // same seam spot-check uses), and periodically recompute McCraty & Zayas
  // 2014 coherence over the FULL accumulated series so far — not a sliding
  // window, so the score stabilizes as more clean data comes in rather than
  // jittering on a short recent slice. Replaces the screen's old
  // Random()-fabricated score. Ephemeral — nothing persisted.
  //
  // 5.5 breaths/min == CalmBreathingScreen's 5450ms inhale/exhale half-cycle
  // (10900ms per full breath).
  static const double breathingPacedHz = 1000.0 / 10900.0;
  static const Duration _breathingRecomputeInterval = Duration(seconds: 20);
  bool breathingActive = false;

  /// The pattern the running session is pacing to. Coherence is only computed
  /// for a pattern that claims a resonance frequency — see
  /// [BreathPattern.coherenceRated].
  BreathPattern breathingPattern = kBreathPatterns.first;

  /// When the running session started, for the persisted history row.
  DateTime? _breathingStartedAt;

  /// When the running session began, for a view that mounts mid-session.
  DateTime? get breathingStartedAt => _breathingStartedAt;

  /// What the running session was asked to run for, or null for an open one.
  Duration? get breathingTarget => _breathingTarget;

  /// What the session was SUPPOSED to run for, or null for an open one.
  ///
  /// Held because the banked duration is otherwise wall-clock: the screen's
  /// ticker is muted while the app is suspended, so a two-minute session
  /// backgrounded at 0:30 and resumed forty minutes later stopped on resume
  /// and banked a forty-minute session, with a coherence score drawn mostly
  /// from unpaced breathing. One backgrounded session would poison the trend
  /// this history exists to build.
  Duration? _breathingTarget;
  Map<String, dynamic>?
  breathingResult; // last {ok, ratio, score, peak_hz, n_beats, confidence, tier, note}
  String? breathingError;
  final List<String> _breathingFrames = [];
  Timer? _breathingRecomputeTimer;
  bool _breathingEnabledStreams = false;

  /// Begin a guided-breathing session. Requires a connected band.
  Future<void> startBreathingSession({
    BreathPattern? pattern,
    Duration? target,
  }) async {
    if (breathingActive) return;
    if (!isConnected) {
      breathingError = 'Connect your band first.';
      notifyListeners();
      return;
    }
    breathingPattern = pattern ?? breathingPattern;
    _breathingTarget = target;
    breathingActive = true;
    breathingResult = null;
    breathingError = null;
    _breathingFrames.clear();
    _breathingStartedAt = DateTime.now();
    notifyListeners();
    unawaited(BreathingLiveActivity.start(startedAt: DateTime.now()));
    try {
      // OWNERSHIP: same rule as spot-check — only claim "we enabled it" when
      // live was actually OFF, so ending the session can never turn off
      // streams the open session still expects on.
      if (!engine.liveEnabled) {
        await engine.enableLiveStreams();
        _breathingEnabledStreams = true;
      } else if (engine.liveHrOnly) {
        await engine.enableLiveStreams();
      }
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = Timer.periodic(_breathingRecomputeInterval, (_) {
      unawaited(_recomputeBreathingCoherence());
    });
  }

  /// End the guided-breathing session and bank it.
  ///
  /// A session shorter than a minute is NOT recorded. Opening the screen and
  /// closing it again is not a breathing session, and a history full of
  /// 4-second entries would bury the real ones.
  Future<void> stopBreathingSession() async {
    if (!breathingActive) return;
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
    breathingActive = false;
    _stopBreathingStreams();
    unawaited(BreathingLiveActivity.end());

    final started = _breathingStartedAt;
    final target = _breathingTarget;
    _breathingStartedAt = null;
    _breathingTarget = null;
    if (started != null) {
      final ended = DateTime.now();
      var seconds = ended.difference(started).inSeconds;
      // Clamped to what was asked for. Overshoot is always suspension, never
      // extra breathing — the pacer stops the moment the app leaves the
      // foreground, so any second past the target was spent doing something
      // else.
      if (target != null && seconds > target.inSeconds) {
        seconds = target.inSeconds;
      }
      if (seconds >= 60) {
        final res = breathingResult;
        final scored = res != null && res['ok'] == true;
        // Null unless the pattern is one a coherence score means something
        // for AND the estimator actually produced one.
        final rated = breathingPattern.coherenceRated && scored;
        unawaited(
          LocalDb.putBreathingSession(
            startedAt: started.millisecondsSinceEpoch,
            endedAt: ended.millisecondsSinceEpoch,
            pattern: breathingPattern.key,
            seconds: seconds,
            coherence: rated ? (res['score'] as num?)?.toDouble() : null,
            confidence: rated ? (res['confidence'] as num?)?.toDouble() : null,
          ),
        );
      }
    }
    notifyListeners();
  }

  /// Past sessions, newest first.
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) =>
      LocalDb.breathingSessions(limit: limit);

  /// Buzz the strap at a breathing or interval phase boundary.
  ///
  /// Distinct patterns per phase so the cue is legible without looking: a
  /// longer buzz to breathe in, a shorter one to breathe out, a double for a
  /// hold. Never throws and never awaits the caller — this fires from a frame
  /// callback, and a momentary disconnect must not interrupt the session or
  /// stall the animation.
  void buzzBreathPhase(BreathPhaseKind kind) {
    if (!isConnected) return;
    final pattern = switch (kind) {
      BreathPhaseKind.inhale || BreathPhaseKind.work => 1,
      BreathPhaseKind.exhale || BreathPhaseKind.rest => 0,
      BreathPhaseKind.holdIn || BreathPhaseKind.holdOut => 2,
    };
    unawaited(engine.buzzPattern(pattern).catchError((_) {}));
  }

  /// The whole session is over, as opposed to one phase of it.
  ///
  /// Its own pattern rather than a repeat of the phase cue: repeated
  /// `runHapticsPattern` frames serialize on the BLE write chain and arrive
  /// milliseconds apart, re-triggering the firmware's haptic engine while it
  /// is still playing — so N of them are felt as one, and the user cannot tell
  /// "round over" from "session over".
  void buzzSessionComplete() {
    if (!isConnected) return;
    unawaited(engine.buzzPattern(4).catchError((_) {}));
  }

  Future<void> _recomputeBreathingCoherence() async {
    if (!breathingActive || repo == null) return;
    final frames = List<String>.from(_breathingFrames);
    if (frames.isEmpty) return;
    try {
      final res = await repo!.breathingCoherence(
        frames,
        // The pattern's own paced frequency, not a constant — box breathing at
        // 3.75 breaths/min scored against a 5.5 breaths/min target would read
        // as incoherent no matter how well it was done.
        pacedHz: breathingPattern.pacedHz,
      );
      if (!breathingActive) return; // session ended while we awaited
      breathingResult = res;
      notifyListeners();
      final score = res['ok'] == true ? (res['score'] as num?)?.toDouble() : null;
      unawaited(BreathingLiveActivity.update(coherenceScore: score));
    } catch (_) {
      /* best-effort; keep the last good result on screen rather than erroring */
    }
  }

  void _stopBreathingStreams() {
    if (_breathingEnabledStreams && activeWorkout == null) {
      unawaited(engine.disableLiveStreams());
    }
    _breathingEnabledStreams = false;
  }

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
  LiveWorkoutState? activeWorkout;
  Timer? _workoutTimer;

  // GPS route tracking for the active run/ride/walk (on-device only). Null when
  // no session is live or the type isn't route-eligible / permission denied.
  RouteTracker? _routeTracker;
  RouteTracker? get routeTracker => _routeTracker;
  // A hike is a walk that goes somewhere, so it records a route like one.
  // Ski and snowboard are deliberately NOT here despite being outdoors: the
  // route screen's hero numbers are distance and pace, and pace down a
  // lift-served descent is not the same claim as pace on a walk — it would
  // read as a performance figure while measuring gravity.
  static const Set<String> _routeTypes = {'run', 'cycle', 'walk', 'hike'};

  DateTime _lastLaPush = DateTime.fromMillisecondsSinceEpoch(0);

  // Sourced from the LOCAL profile (no server). Fall back to representative
  // defaults when a field isn't set yet. maxHr = 220 - age.
  int get _maxHr {
    final age = (user?['age'] as num?)?.toDouble() ?? 30.0;
    return (220 - age).round();
  }

  /// Estimated max HR (220 − age) — used by the route map / splits to colour by
  /// HR zone, matching the live zone bands.
  int get maxHr => _maxHr;

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

  Future<void> _refreshNightlyRhr() async {
    try {
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

  /// HR → zone 0..5 (% of max HR), matching the app's zone bands.
  int _zoneFor(int hr) {
    if (hr <= 0 || _maxHr <= 0) return 0;
    final pct = hr / _maxHr * 100;
    if (pct >= 90) return 5;
    if (pct >= 80) return 4;
    if (pct >= 70) return 3;
    if (pct >= 60) return 2;
    if (pct >= 50) return 1;
    return 0;
  }

  void startWorkout({
    double targetKcal = 300,
    String? workoutId,
    String type = 'other',
  }) {
    if (activeWorkout != null) return;
    final start = DateTime.now();
    final id = workoutId ?? 'w${start.millisecondsSinceEpoch}';
    // The workout screen's live step count rides the 100 Hz IMU stream, which
    // the sticky standard-HR fallback silently suppresses (same starvation as
    // the calibration walk) — and which may simply be off (spot-check cleanup
    // restores streams to OFF when they were off before) or still in the
    // background HR-only downgrade. A deliberate workout start is an explicit
    // user action — retry the full live set; detectors re-trip if it can't
    // hold. No ownership flag: the background downgrade / session close
    // manage the stream lifecycle exactly as for openSession's arming.
    if (isConnected &&
        (!engine.liveEnabled ||
            engine.liveHrOnly ||
            device.standardHrFallback)) {
      unawaited(engine.retryFullLiveStreams());
    }
    _workoutRawBase = _liveRaw;
    _workoutSawSamples = false;
    // A first night may have been derived since init. This read finishes
    // after the session below is constructed, so it back-fills the anchor on
    // `activeWorkout` when it lands rather than blocking the start.
    unawaited(_refreshNightlyRhr());
    // Hold heavy derivation for the session — an isolate spawn mid-ride
    // competes with GPS, the live map and the BLE drain (see
    // DeriveScheduler.setWorkoutActive).
    _deriveScheduler.setWorkoutActive(true);
    // Hold the display for EVERY live session, not just route-eligible ones.
    // Arming this from _maybeStartRouteTracking meant an indoor workout, a
    // location-denied run, and a resumed non-route session all watched the
    // screen sleep mid-set. Released unconditionally on both teardown paths.
    ScreenWake.enable();
    activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: targetKcal,
      workoutId: id,
      type: type,
      age: (user?['age'] as num?)?.round(),
      // Score against the profile the session is performed under.
      profile: Profile.fromMap(user),
      restingHr: _liveRestingHr,
    );
    // Persist the live session (INSERT OR REPLACE — idempotent if repo already
    // inserted this id). Final stats are written on stop.
    unawaited(
      LocalDb.putSession({
        'id': id,
        'start_ts': start.millisecondsSinceEpoch ~/ 1000,
        'end_ts': null,
        'type': type,
        'status': 'live',
        'source': 'manual',
        'created_at': start.millisecondsSinceEpoch,
      }),
    );
    // Never leak a previous periodic tick by overwriting the reference.
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickWorkout(),
    );
    notifyListeners();
    _log('Live session started. Goal: ${targetKcal.round()} kcal');
    // Light up the lock screen / Dynamic Island (iOS).
    LiveActivity.start(
      startedAt: start,
      targetKcal: targetKcal.round(),
      maxHr: _maxHr,
      rhr: _restingHr,
    );
    _lastLaPush = DateTime.fromMillisecondsSinceEpoch(0);
    // GPS route: only for run/ride/walk, and only if the user grants location.
    unawaited(_maybeStartRouteTracking(id, type));
  }

  /// Why route tracking is NOT running for the current route-eligible workout
  /// (null = no issue / tracking active). Drives the live screen's "Location
  /// off" affordance instead of silently skipping the map.
  GpsPermissionStatus? routeLocationIssue;

  /// Set in [dispose]. Async work that resumes AFTER teardown must not touch
  /// state or call notifyListeners() — see dispose()'s own note about
  /// notifying a disposed ChangeNotifier (which throws in release). Timers are
  /// cancelled there, but an already-suspended `await` cannot be, so every
  /// continuation past an await in this class needs to re-check this.
  bool _disposed = false;

  /// Start recording the route if the type is eligible and location permission
  /// is granted. Denial is surfaced (routeLocationIssue) — the workout still
  /// runs without a map, but the user is told why and how to fix it.
  Future<void> _maybeStartRouteTracking(String id, String type) async {
    // Lowercased for the same reason every other type lookup is: the stored
    // `type` column is free-form text and older rows carry mixed case.
    if (!_routeTypes.contains(type.toLowerCase())) return;
    if (_routeTracker != null) return;
    routeLocationIssue = null;
    var perm = GpsPermissionStatus.error;
    try {
      perm = await GpsSource.ensurePermission();
    } catch (_) {
      perm = GpsPermissionStatus.error;
    }
    // The permission round-trip can outlive the whole AppState (a resumed
    // workout kicks this off unawaited during startup), so re-check both.
    if (_disposed) return;
    // The session may have ended while we awaited the permission dialog.
    if (activeWorkout?.workoutId != id) return;
    if (perm != GpsPermissionStatus.granted) {
      routeLocationIssue = perm;
      _log('Route tracking unavailable: ${perm.name}.');
      notifyListeners();
      return;
    }
    final tracker = RouteTracker(
      sink: (batch) => LocalDb.appendRoutePoints(
        id,
        [for (final p in batch) p.toRow(id)],
      ),
      zoneNow: () => _zoneFor(activeWorkout?.currentHr ?? 0),
    );
    _routeTracker = tracker;
    try {
      tracker.start(GpsSource.stream());
    } catch (_) {
      _routeTracker = null;
      routeLocationIssue = GpsPermissionStatus.error;
      notifyListeners();
      return;
    }
    // Android: retype the already-running FGS to connectedDevice|location so
    // the OS keeps delivering fixes while a route session is live.
    EdgeTracking.start(location: true);
    notifyListeners();
    _log('Route tracking started for $type.');
  }

  /// Re-attempt route tracking after the user fixed permissions (returns from
  /// Settings). No-op unless a route-eligible session is live without a tracker.
  Future<void> retryRouteTracking() async {
    final w = activeWorkout;
    if (w == null || w.workoutId == null || _routeTracker != null) return;
    await _maybeStartRouteTracking(w.workoutId!, w.type);
  }

  /// If the Live Activity's Finish button was tapped (App Intent set the flag),
  /// stop the workout here too. Call on app resume.
  Future<void> maybeFinishFromLiveActivity() async {
    if (activeWorkout != null && await WidgetService.consumeEndSessionFlag()) {
      await stopWorkout();
    }
  }

  /// Same idea as [maybeFinishFromLiveActivity] but for the breathing
  /// session's own Live Activity stop button (EndBreathingIntent sets
  /// `end_breathing_session` — a separate flag so the two Live Activities'
  /// stop buttons never collide). Call on app resume.
  Future<void> maybeStopBreathingFromLiveActivity() async {
    if (breathingActive && await WidgetService.consumeEndBreathingFlag()) {
      await stopBreathingSession();
    }
  }

  /// Reconcile any session row still `status='live'` left over from a
  /// previous run — `stopWorkout()`'s finalize write never happened, almost
  /// certainly because the app was killed/crashed mid-workout. `activeWorkout`
  /// was PURELY in-memory and nothing ever restored it from this row, so after
  /// a restart the mini-player banner / live session screen (and their only
  /// "finish" control) became unreachable — the workout's sole remaining
  /// action was the detail screen's unconditional delete button ("can't stop
  /// workout, only delete"). Called once from [_init].
  ///
  /// - Recent (<= [_kMaxLiveWorkoutAgeMs] old): genuinely resumable —
  ///   rehydrate `activeWorkout` so the normal "hold to finish" flow works
  ///   again. Live per-second tallies (calories, strain, zone minutes) can't
  ///   be reconstructed from a single DB row, so they restart from zero going
  ///   forward rather than being fabricated — honest, not perfect, but no
  ///   worse than the row being permanently un-finishable otherwise.
  /// - Stale (older than the ceiling), or a malformed/second stray row:
  ///   almost certainly not something the user is still "in" — silently
  ///   finalize it (status: 'done') instead of resurfacing a days-old "still
  ///   live" banner. duration_min/calories are left unset rather than guessed
  ///   (we don't know the real end time or effort).
  static const int _kMaxLiveWorkoutAgeMs = 6 * 60 * 60 * 1000; // 6h
  Future<void> _reconcileOrphanedLiveWorkout() async {
    try {
      // Called unawaited from _init(); a concurrent startWorkout() could in
      // principle already be running by the time this DB round-trip resolves
      // (CodeRabbit flagged the race). Bail rather than clobber a real,
      // just-started activeWorkout and leak its timer.
      if (activeWorkout != null) return;
      final rows = await LocalDb.liveSessions();
      // RE-CHECK AFTER THE AWAIT. This is kicked unawaited from _init(), one
      // line before `initialized = true` makes the shell interactive — so the
      // user can tap "Start workout" INSIDE this DB round-trip. The pre-await
      // guard alone let us then overwrite a genuinely live `activeWorkout` with
      // the stale row AND assign a second `_workoutTimer` over the live one:
      // the first timer became unreachable, was never cancelled, and kept
      // running _tickWorkout at 2 Hz for the rest of the session — double
      // counting calories/strain/zone-seconds against a workout the user never
      // started.
      if (activeWorkout != null) return;
      if (rows.isEmpty) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      var resumed = false;
      for (final row in rows) {
        final startSec = (row['start_ts'] as num?)?.toInt();
        final ageMs = startSec == null ? null : nowMs - startSec * 1000;
        if (!resumed && ageMs != null && ageMs >= 0 && ageMs <= _kMaxLiveWorkoutAgeMs) {
          resumed = true;
          final startMs = startSec! * 1000;
          final id = row['id'] as String? ?? 'w$startMs';
          activeWorkout = LiveWorkoutState(
            startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
            targetKcal: 300,
            workoutId: id,
            type: (row['type'] as String?) ?? 'other',
            age: (user?['age'] as num?)?.round(),
            profile: Profile.fromMap(user),
            restingHr: _liveRestingHr,
          );
          // Without this, `workoutSteps` (gated on _workoutRawBase != null)
          // stays 0 for the rest of this resumed session, and stopWorkout()
          // would persist 0 steps even once real pedometer data resumes
          // flowing — CodeRabbit caught this. Mirrors startWorkout()'s own
          // snapshot: steps count from zero going forward, same as
          // calories/strain/zone-minutes already (honestly) do here.
          _workoutRawBase = _liveRaw;
          _workoutSawSamples = false;
    // A first night may have been derived since init. This read finishes
    // after the session below is constructed, so it back-fills the anchor on
    // `activeWorkout` when it lands rather than blocking the start.
    unawaited(_refreshNightlyRhr());
          // Never overwrite a live timer reference without cancelling it.
          _workoutTimer?.cancel();
          _workoutTimer = Timer.periodic(
            const Duration(seconds: 1),
            (_) => _tickWorkout(),
          );
          _log('[workout] resumed a live session still running after restart (id=$id).');
          // Re-arm GPS for the REST of the session. Without this a resumed
          // workout recorded no further route at all: the timer/calories/strain
          // all came back, the map silently never did, and the athlete only
          // found out at the finish screen. `_maybeStartRouteTracking` is a
          // no-op for non-route types and re-appends to the SAME workout_route
          // rows (`id` is unchanged), so the pre-restart part of the route is
          // kept and the gap shows honestly as a segment break.
          unawaited(_maybeStartRouteTracking(id, activeWorkout!.type));
          _deriveScheduler.setWorkoutActive(true);
          ScreenWake.enable();
        } else {
          await LocalDb.putSession({...row, 'status': 'done'});
          _log('[workout] finalized a stale live-session row from a previous run (id=${row['id']}).');
        }
      }
      if (resumed) notifyListeners();
    } catch (e) {
      _log('[workout] reconcile orphaned live session failed: $e');
    }
  }

  Future<void> stopWorkout() async {
    if (activeWorkout == null) return;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    // Stop GPS route recording and AWAIT the buffered-tail flush before the
    // finish screen loads the route — an unawaited stop raced the navigation
    // and the finish/detail map missed the last batch of fixes.
    final rt = _routeTracker;
    _routeTracker = null;
    routeLocationIssue = null;
    if (rt != null) {
      try {
        await rt.stop();
      } catch (_) {}
      // Android: drop the FGS back to connectedDevice-only now the route ended.
      EdgeTracking.start(location: false);
    }
    // Release the display unconditionally — not inside the `rt != null` branch.
    // A session that never got a tracker (permission denied) still armed
    // nothing, but a session whose tracker was already cleared by another path
    // would otherwise leave the screen pinned awake until the app is killed.
    ScreenWake.release();
    _deriveScheduler.setWorkoutActive(false);
    final w = activeWorkout!;
    // Nullable for the same reason `steps` below is: an unanchored profile
    // means this session was never costed, and a 0 in the column reads as
    // "burned nothing" rather than "not measured".
    final finalKcal = w.caloriesOrNull;
    // Nullable: an unmeasured workout must leave the column unset rather than
    // bank a zero that reads as "you took no steps".
    final wSteps = workoutStepsMeasured;
    // Persist the finalized session before clearing the live state. zone_min =
    // the per-zone seconds the 1 Hz tick accumulated (Z1..Z5, minutes).
    final id = w.workoutId ?? 'w${w.startTime.millisecondsSinceEpoch}';
    final zoneMin = w.zoneMinutes();
    final endTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sessionRow = {
      'id': id,
      'start_ts': w.startTime.millisecondsSinceEpoch ~/ 1000,
      'end_ts': endTs,
      'type': w.type,
      'status': 'done',
      'calories': finalKcal,
      'strain': w.strain,
      'max_hr': w.maxHrSeen > 0 ? w.maxHrSeen : null,
      'duration_min': w.elapsed.inMinutes,
      'zone_min_json': jsonEncode(
        zoneMin.any((v) => v > 0) ? zoneMin : const <num>[],
      ),
      if (wSteps != null && wSteps > 0) 'steps': wSteps,
      'source': 'manual',
      'created_at': w.startTime.millisecondsSinceEpoch,
    };
    unawaited(LocalDb.putSession(sessionRow));
    // Session-triggered Health export (issue #130) — don't wait for the next
    // day_result/derive pass (which may not run at all if the band isn't
    // connected right now); write this workout to Apple Health/Health Connect
    // immediately. Best-effort, never throws, no-ops if sync is off.
    if (healthSyncEnabled) {
      unawaited(_healthExport.exportWorkout(sessionRow));
    }
    activeWorkout = null;
    _workoutRawBase = null;
    _workoutSawSamples = false;
    notifyListeners();
    _log(
      finalKcal == null
          ? 'Live session ended. No calorie anchors in the profile.'
          : 'Live session ended. Burned $finalKcal kcal.',
    );
    LiveActivity.end();
    // A workout often rides the live feed; if the connection blipped during it, the
    // band may hold that window in flash. Pull it now over the live connection so the
    // just-finished session isn't left with a gap.
    unawaited(forceResync());
  }

  /// Tears down the in-memory live-workout state (timer, GPS route tracker,
  /// Live Activity) WITHOUT persisting anything — unlike [stopWorkout], which
  /// finalizes and writes a completed session. Used by [deleteWorkout] below
  /// when the row being deleted happens to be the one currently live: just
  /// nulling `activeWorkout` left the timer still ticking, the route tracker
  /// still appending GPS points, and the Live Activity still showing, all
  /// against a workout id that no longer has a backing DB row.
  Future<void> _cancelActiveWorkoutTeardown() async {
    _workoutTimer?.cancel();
    _workoutTimer = null;
    final rt = _routeTracker;
    _routeTracker = null;
    routeLocationIssue = null;
    if (rt != null) {
      try {
        await rt.stop();
      } catch (_) {}
      EdgeTracking.start(location: false);
    }
    ScreenWake.release();
    _deriveScheduler.setWorkoutActive(false);
    activeWorkout = null;
    _workoutRawBase = null;
    _workoutSawSamples = false;
    LiveActivity.end();
  }

  /// Delete a stored workout session and, if it happens to be the one
  /// currently tracked as "live", fully tear down that live state too (see
  /// [_cancelActiveWorkoutTeardown]). Previously the UI called
  /// `repo.deleteWorkout(id)` directly — that only removed the DB row, so
  /// deleting a session right after finishing it (before this in-memory
  /// state was independently cleared) could leave the app still showing
  /// "Run live" until a manual refresh/restart; and deleting a workout that
  /// was GENUINELY still live would have left its timer/route tracker/Live
  /// Activity running against a deleted id.
  Future<void> deleteWorkout(String id) async {
    await repo?.deleteWorkout(id);
    if (activeWorkout?.workoutId == id) {
      await _cancelActiveWorkoutTeardown();
      notifyListeners();
    }
  }

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

  void _tickWorkout() {
    final w = activeWorkout;
    if (w == null) return;

    w.elapsed = DateTime.now().difference(w.startTime);
    w.currentHr = device.liveHr ?? 0;
    // Smooth at accrual (issue #127): a raw `> maxHrSeen` would let a 1–2 s PPG
    // spike define the session max. accrueHr feeds the rolling-median peak.
    w.accrueHr(w.currentHr);
    // Per-zone time: one tick ≈ one second in the current zone (persisted as
    // zone_min at stop — this is what feeds the Time-in-Zones bar).
    if (w.currentHr > 0) w.zoneSeconds[_zoneFor(w.currentHr)] += 1;

    // Neither strain NOR calories is accrued here. `accrueHr` (called above)
    // recomputes both from the session's per-minute HR through the one shared
    // path each has — Banister -> log-squash for strain, and the published
    // Keytel/Harris-Benedict rates behind `Calories.estimateBoutCalories` for
    // kcal. So the live gauge, a manually logged session and the day's own
    // figures all mean the same thing.
    //
    // Calories used to be billed HERE, per second, from an inline copy of
    // Keytel with no activity gate and no resting floor. That copy charged the
    // full active rate at any heart rate the band reported, so the number on
    // the gauge did not survive the re-score of its own stream.
    // Push to the Live Activity at most ~every 4s (ActivityKit throttles; saves battery).
    if (DateTime.now().difference(_lastLaPush).inSeconds >= 4) {
      _lastLaPush = DateTime.now();
      LiveActivity.update(
        hr: w.currentHr,
        zone: _zoneFor(w.currentHr),
        // Absent stays absent. These used to be coerced to 0, so a new user
        // with no profile anchors — the case where both correctly abstain and
        // the in-app gauge shows "—" — got a confident "0 kcal" pushed to the
        // lock screen for the whole session. Unmeasured is not zero.
        strain: w.strain,
        calories: w.caloriesOrNull,
        maxHr: _maxHr,
        rhr: _restingHr,
      );
    }
    notifyListeners();
  }
}

/// Active workout tracking (in-memory only).
class LiveWorkoutState {
  final DateTime startTime;
  final double targetKcal;
  final String? workoutId; // local session id (for the breakdown on finish)
  final String type; // exercise type label
  Duration elapsed = Duration.zero;

  /// Live kcal for the bout so far. Zero here is ambiguous on its own — read
  /// [caloriesOrNull] anywhere a user can see it.
  ///
  /// RECOMPUTED from the retained per-minute series on every sample, not
  /// accrued. Same reason [strain] is: [restingHr] is loaded asynchronously and
  /// can land after the session starts, and it sets the gate that decides
  /// whether a minute is billed at the active or the resting rate. An
  /// incremental tally could only ever have corrected the seconds after the
  /// anchor arrived, leaving the earlier ones scored against a guess.
  double calories = 0.0;

  /// Whether the calorie estimate has run even once this session.
  ///
  /// Separate from [Profile.hasCalorieAnchors] because "can we score this" and
  /// "did we score this" are different questions and both have a zero-shaped
  /// answer. A complete profile whose band never delivered a heart rate — the
  /// link dropped, the strap was off — accrues nothing, and reporting that as
  /// 0 kcal claims a measurement that was never taken. Strain already reports
  /// that case as absent; this makes calories agree.
  bool _caloriesScored = false;

  /// Live kcal, or null when this session cannot be costed at all — the
  /// profile lacks the anchors Keytel needs, no resting HR has arrived to set
  /// the bout gate, or no heart rate ever landed. Absent beats fabricated, and
  /// absent also beats a confident zero.
  int? get caloriesOrNull => _caloriesScored ? calories.round() : null;

  /// Re-cost the bout so far. The only writer of [calories].
  ///
  /// Uses the SAME published rates, coefficients and activity gate as
  /// `Calories.estimateBoutCalories`, which is what the substrate re-score and
  /// every manually logged session run on — so the figure on the live gauge
  /// survives its own re-score. It used to bill the raw Keytel active rate for
  /// every second the band reported a heart rate, with no gate and no resting
  /// floor, which roughly doubled the cost of warm-up, rest between sets and
  /// cool-down against what the re-score would later say about the same stream.
  ///
  /// PER SAMPLE, not per minute. [_secondsByBpm] holds how many seconds the
  /// bout spent at each whole-bpm value, so this reproduces
  /// `estimateBoutCalories`'s sample-by-sample billing exactly while staying
  /// O(distinct bpm) in memory instead of retaining every raw sample.
  ///
  /// It scored per MINUTE, off the mean of each minute, and that lost the two
  /// things the re-score gets right:
  ///
  ///   * The gate is per sample there and was per minute-mean here. A minute
  ///     that straddles the gate — 30 s at 93 and 30 s at 94 against a 93.76
  ///     gate — billed as a whole resting minute (1.19 kcal) where the
  ///     re-score bills half of it active (3.63). About 146 kcal adrift over a
  ///     zone-2 hour, in a stream that never looks unusual.
  ///   * The seconds were wrong. A completed minute billed a flat 60 s no
  ///     matter how few samples backed it, and the minute in progress billed
  ///     `_minuteCount`, a SAMPLE count used as a second count — 12 s instead
  ///     of 60 at a 5 s notify rate.
  void _scoreCalories() {
    final rhr = restingHr;
    final hrMax = profile.hrMaxTanaka;
    // The re-score refuses to invent a 220/60 anchor pair, so neither does
    // this. A resting HR landing later re-scores the whole bout.
    if (!profile.hasCalorieAnchors || rhr == null || hrMax == null) {
      _caloriesScored = false;
      calories = 0.0;
      return;
    }
    if (_secondsByBpm.isEmpty && _lastSampleHr == null) {
      _caloriesScored = false;
      calories = 0.0;
      return;
    }

    final age = profile.ageYears!.toDouble();
    final weightKg = profile.weightKg!;
    final coeffs = ana.Calories.resolveCoeffs(workoutSex(profile.sex));
    // Height is not a Keytel term; it only moves the Harris-Benedict resting
    // floor. Defaulted to match `computeManualSessionStats`, so the two paths
    // cannot disagree for a profile that carries no height.
    final heightCm = profile.heightCm ?? 170.0;
    final gate = rhr + ana.Calories.activeHRRFraction * (hrMax - rhr);
    final restingRate =
        ana.Calories.restingKcalPerS(coeffs, weightKg, heightCm, age);

    var kcal = 0.0;
    void bill(int bpm, double seconds) {
      final rate = bpm < gate
          ? restingRate
          : ana.Calories.activeKcalPerS(
              coeffs,
              bpm.toDouble(),
              hrMax,
              weightKg,
              age,
            );
      kcal += rate * seconds;
    }

    _secondsByBpm.forEach(bill);
    // The newest sample has no successor yet, so its own duration is unknown.
    // `estimateBoutCalories` gives the final sample one representative second;
    // matching that is what keeps the gauge and the re-score equal at every
    // instant rather than only at the end.
    final trailing = _lastSampleHr;
    if (trailing != null) bill(trailing, 1.0);

    calories = kcal;
    _caloriesScored = true;
  }

  /// Headline 0–21 strain, or null when the profile lacks an anchor the
  /// Banister formula needs. Recomputed on every HR sample by [accrueHr] — it
  /// is NOT accrued incrementally any more. The old `strain += %HRR * 0.01`
  /// per second was uncited and uncapped: it read 25.33 where the canonical
  /// method reads 11.62 for the same hour, and passed the top of its own 0–21
  /// scale after ~50 minutes of hard work, which the gauge silently clamped.
  double? strain;
  int currentHr = 0;
  int maxHrSeen = 0; // spike-suppressed peak live HR this session (issue #127)

  /// Milestone keys already announced this SESSION ("t5", "k200", "mhr178"…).
  ///
  /// Lives here, not on the live-session screen's State, because the screen is
  /// disposed and rebuilt every time the athlete navigates away and back — so
  /// a screen-local set forgot everything and re-fired the same milestone
  /// (banner, haptic and confetti) on every return. The workout is the thing
  /// a milestone belongs to, so the workout remembers it.
  final Set<String> firedMilestones = {};

  /// Rolling-median accumulator behind [maxHrSeen] — smooths the live 1 Hz HR
  /// at accrual so a transient PPG motion spike can't set the session max (or
  /// fire a spurious "new max!"). Same window + reject as the on-read recompute.
  final RollingMaxHr _hrPeak;

  /// Seconds spent in each HR zone (index 0..5 = Z0 rest .. Z5 max), tallied at
  /// 1 Hz by _tickWorkout. Z1..Z5 are persisted as `zone_min` on stop.
  final List<double> zoneSeconds = List<double>.filled(6, 0);

  /// The persisted `zone_min` payload: minutes in Z1..Z5 (index 0 = Z1 — the
  /// 5-element shape the Time-in-Zones bar parses). Z0 (rest) is excluded.
  List<double> zoneMinutes() => [
        for (var z = 1; z <= 5; z++)
          double.parse((zoneSeconds[z] / 60.0).toStringAsFixed(2)),
      ];

  /// Anchors for the live strain score. Held on the session because a workout
  /// must be scored against the profile it was performed under, not whatever
  /// the profile happens to say when the session ends.
  final Profile profile;

  /// Resting-HR anchor for the strain score. NOT final: the measured nightly
  /// value is loaded asynchronously, so a session can begin before it lands.
  /// [AppState._refreshNightlyRhr] back-fills it here when it arrives, and the
  /// next HR sample re-scores through it — otherwise the session would be
  /// stuck unscored for its whole duration over a read that finished a
  /// fraction of a second after it started.
  double? restingHr;

  /// Per-minute mean HR, the unit Banister TRIMP weights. Live HR arrives at
  /// 1 Hz, so it is folded into the current minute here rather than kept as
  /// thousands of raw samples.
  final List<double> _perMinuteHr = [];
  int _minuteBucket = -1;
  double _minuteSum = 0;
  int _minuteCount = 0;

  /// Per-minute means INCLUDING the minute still in progress, so the live
  /// gauge moves within the first minute instead of sitting at zero for 60 s.
  List<double> perMinuteHr() => [
        ..._perMinuteHr,
        if (_minuteCount > 0) _minuteSum / _minuteCount,
      ];

  /// Seconds the bout has spent at each whole-bpm value — the calorie series.
  ///
  /// Deliberately NOT the per-minute means above. `estimateBoutCalories`, which
  /// the substrate re-score and every manually logged session run on, decides
  /// active-vs-resting per SAMPLE and weights each sample by the elapsed time to
  /// the next one. A per-minute mean cannot express either: it collapses a
  /// minute that straddles the activity gate onto one side of it, and it has no
  /// idea how many seconds actually backed the samples in it.
  ///
  /// A histogram rather than a sample list because heart rate is a small
  /// integer — this is bounded at a couple of hundred entries for a bout of any
  /// length, while retaining raw 1 Hz samples is not.
  final Map<int, double> _secondsByBpm = {};

  /// The most recent accepted sample, still unbilled: its duration is the time
  /// until the NEXT sample, which has not arrived. Also what makes a gap in the
  /// stream bill correctly — the sample before a contact-loss gap is charged
  /// for the gap, capped, exactly as the re-score charges it.
  int? _lastSampleHr;
  double? _lastSampleSec;

  /// A stream that stops for longer than this stopped being one bout; billing
  /// the pre-gap heart rate across an hour of no data would invent the hour.
  ///
  /// Taken from the analytics constant rather than restated, because the whole
  /// point of this scoring path is that it gives up at the same instant the
  /// re-score of the same stream does. A second literal 150.0 here would agree
  /// today and diverge silently the day the published cap moved.
  static const double _gapCapS = ana.Calories.defaultMergeGapCapS;

  LiveWorkoutState({
    required this.startTime,
    required this.targetKcal,
    this.workoutId,
    this.type = 'other',
    int? age,
    this.profile = const Profile(),
    this.restingHr,
  }) : _hrPeak = RollingMaxHr(age: age);

  /// Feed a live HR sample; updates the spike-suppressed [maxHrSeen], the
  /// per-minute accumulator behind strain, the per-bpm second counts behind
  /// calories, and both derived figures.
  ///
  /// A non-positive reading is off-skin, not a heart rate, so it is dropped —
  /// but the time it covers is NOT thrown away. It is billed to the last real
  /// sample when the next one arrives, capped at [_gapCapS], which is what
  /// `estimateBoutCalories` does with the same gap once the zeros have been
  /// filtered out of the stream it re-scores.
  void accrueHr(int hr) {
    if (hr <= 0) return;
    _hrPeak.add(hr);
    if (_hrPeak.max > maxHrSeen) maxHrSeen = _hrPeak.max;

    // Close out the previous sample: its duration is the time until this one.
    // Sub-second and out-of-order arrivals fall back to one second, matching
    // `estimateBoutCalories`'s handling of a non-positive gap.
    final nowSec = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final prevHr = _lastSampleHr;
    final prevSec = _lastSampleSec;
    if (prevHr != null && prevSec != null) {
      final gap = nowSec - prevSec;
      final dur = gap > 0 ? math.min(gap, _gapCapS) : 1.0;
      _secondsByBpm[prevHr] = (_secondsByBpm[prevHr] ?? 0) + dur;
    }
    _lastSampleHr = hr;
    _lastSampleSec = nowSec;

    // Fold into the current minute, measured from the session start so the
    // buckets are the session's own minutes rather than wall-clock ones.
    final minute = elapsed.inMinutes;
    if (minute != _minuteBucket) {
      if (_minuteCount > 0) _perMinuteHr.add(_minuteSum / _minuteCount);
      _minuteBucket = minute;
      _minuteSum = 0;
      _minuteCount = 0;
    }
    _minuteSum += hr;
    _minuteCount++;

    // ONE strain method across the app (see strainFromPerMinuteHr). Null when
    // an anchor is missing — the gauge shows "—" rather than a number built on
    // an invented HRmax or resting HR.
    strain = strainFromPerMinuteHr(
      perMinuteHr(),
      profile: profile,
      restingHr: restingHr,
    );

    // Calories re-score off the same series, through the same estimator the
    // substrate re-score uses, so both live figures on the gauge mean the same
    // thing the finished session will.
    _scoreCalories();
  }
}
