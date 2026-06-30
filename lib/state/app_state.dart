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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_status.dart';
import '../ble/accessory_setup.dart';
import '../ble/ble_engine.dart';
import '../ble/ios_ble_restore.dart';
import '../cloud/companion_client.dart';
import '../compute/derivation_engine.dart';
import '../compute/derive_scheduler.dart';
import '../compute/profile.dart';
import '../data/db.dart';
import '../data/local_repository.dart';
import '../data/local_repository_impl.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../gestures/gesture_settings.dart';
import '../health/health_export.dart';
import '../import/noop_import.dart';
import '../import/whoop_import.dart';
import '../gestures/gesture_dispatcher.dart';
import '../data/models.dart';
import '../live/live_activity.dart';
import '../notify/device_alerts.dart';
import '../notify/notification_relay.dart';
import '../notify/notification_service.dart';
import '../notify/water_buzzer.dart';
import '../sync/edge_tracking.dart';
import '../sync/paired_device.dart';
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

class AppState extends ChangeNotifier {
  late final BleEngine engine;
  PairedDevice? paired;

  /// SEAM: the screen data layer. Wired to [LocalRepositoryImpl] in the ctor —
  /// it reads the precomputed derived_day / metric_series rows (ZERO heavy
  /// compute on read). Screens still guard on `repo == null` exactly as they did
  /// on `api`.
  LocalRepository? repo;

  /// The on-device compute orchestrator. Kicked (light) after every drain/flush
  /// completion, and (heavy) on foreground finalize. Background heavy passes run
  /// via WorkManager (Android) — see lib/compute/background_derivation.dart.
  late final DerivationEngine _derive = DerivationEngine(log: _log);
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
  Timer? _backfillTimer;
  String _prevConn = 'disconnected';
  // Last battery snapshot pushed to the Band Battery widget — so we only reload
  // the widget when pct/charging actually change (the engine-state hook fires
  // ~1 Hz on live HR). -2 = never pushed.
  int _widgetBattPct = -2;
  bool? _widgetBattCharging;
  String? _widgetBattName;
  int? _storedBatteryPct;
  bool? _storedBatteryCharging;
  bool? _storedBatteryWristOn;
  bool initialized = false;

  /// True while the app is backgrounded. On iOS we KEEP the BLE connection alive in
  /// this state (see [pauseForBackground]) so the OS keeps resuming us per BLE
  /// notification and the live drain continues.
  bool _background = false;

  bool get isPaired => paired != null;

  static const Duration _backfillInterval = Duration(minutes: 15);

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
  bool get companionConfigured => CompanionClient.effectiveBase.trim().isNotEmpty;

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
    notifyListeners();
    return res.days;
  }

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
    final n = await _healthExport.exportAll();
    return n;
  }

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
      t.enabled = telemetryConsent;
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
    TelemetryService.instance.enabled = on;
    notifyListeners();
    unawaited(CompanionClient.postConsent(
      deviceId: deviceId, scope: 'telemetry', granted: on,
      termsVersion: termsVersion,
    ));
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
    unawaited(CompanionClient.postConsent(
      deviceId: deviceId, scope: 'health_data', granted: on,
      termsVersion: termsVersion,
    ));
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
  bool get updateAvailable =>
      _update != null &&
      _currentBuild > 0 &&
      _update!.latestBuild > _currentBuild;

  /// We're below the mandatory floor — the prompt can't be dismissed.
  bool get updateMandatory =>
      _update != null && _currentBuild > 0 && _currentBuild < _update!.minBuild;

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
  StreamSubscription<String>? _tapSub;

  static const Map<String, int> _routeToTab = {
    '/today': 0,
    '/sleep': 1,
    '/heart': 2,
    '/body': 3,
    '/workouts': 4,
  };
  void _handleTapRoute(String route) {
    navRequest.value = _routeToTab[route] ?? 0; // unknown (e.g. /recap) → Today
  }

  AppState() {
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
      // RESUMABLE SYNC: atomic commit of raw + samples + continuation cursor
      // before the HISTORY_END ACK, and a reader to seed the offload frontier
      // from the durable high-water on (re)connect.
      onCommitBatch: (raws, samples, trimTokenHex) =>
          LocalDb.commitSyncBatch(raws, samples, trimToken: trimTokenHex),
      cursorReader: LocalDb.getCursorInt,
      // Debounced compute trigger: with continuous listening there's no discrete
      // "sync done", so the engine coalesces stored-record bursts and fires this
      // once a burst goes quiet. Light pass (newest affected day) — the foreground
      // heavy finalize still runs in openSession after the backlog fully drains.
      onDataStored: _onDataStored,
      onOffloadState: (active) => _deriveScheduler.setOffloadActive(active),
      // LIVE high-rate frames (0x28/0x2B/0x33) are ephemeral — routed here for the
      // live UI / spot-check, NEVER persisted to raw_records.
      onLiveFrame: _onLiveFrame,
    );
    repo = LocalRepositoryImpl(getProfileMap: () => user);
    _init();
    // Notification taps → request a tab switch (the shell listens to navRequest).
    _tapSub = NotificationService.instance.taps.listen(_handleTapRoute);
    unawaited(NotificationService.instance.consumeLaunchRoute());
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    _stopBackfillTimer();
    _deriveScheduler.dispose();
    _waterBuzzer.dispose();
    super.dispose();
  }

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
  /// [heavy]=false is the bounded light pass (newest affected day); [heavy]=true is
  /// the foreground finalize sweep. Best-effort + non-blocking — never throws into
  /// the BLE path. Refreshes the UI when results land so screens re-read the fresh
  /// derived rows.
  Future<void> _afterDrain({bool heavy = false}) async {
    try {
      // Refresh the UI after EACH day so Today/trends fill in as the sweep runs,
      // not only at the end (a multi-day backfill can be many days of work).
      await _derive.run(
        _profile,
        heavy: heavy,
        onDayDone: (day, index, total) async {
          if (index == total || index == 1 || index % 3 == 0) {
            dbCounts = await LocalDb.counts();
            notifyListeners();
          }
        },
      );
      await LocalDb.refreshComputeFreshness();
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
            final n = await _healthExport.exportAll();
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
    } catch (e) {
      _log('[derive] post-drain failed: $e');
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
        final payload = jsonDecode((row['payload_json'] ?? '{}').toString());
        if (payload is Map) {
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

      await prefs.setString(_kLastRecoveryNotifDay, dayId);
      await NotificationCenter.instance.emit(NotificationEvent(
        dedupeKey: '$dayId:recovery_ready',
        category: NotifCategory.recovery,
        priority: NotifPriority.normal,
        title: 'Your recovery is ready',
        body: 'Recovery $score$slept. Tap to see today.',
        date: dayId,
        route: '/today',
      ));
      _log('[notify] recovery-ready fired for $dayId (score=$score)');
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
    } catch (e) {
      _log('[notify] cadence checks skipped: $e');
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
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_kLastStepGoalDay) == date) return; // already fired
      await prefs.setString(_kLastStepGoalDay, date);
      await NotificationCenter.instance.emit(NotificationEvent(
        dedupeKey: '$date:step_goal',
        category: NotifCategory.reminders,
        priority: NotifPriority.low,
        title: 'Step goal reached',
        body: 'You hit about $steps steps — at or above your $goal goal. Nice work.',
        date: date,
        route: '/today',
      ));
    } catch (_) {/* best-effort */}
  }

  /// Opportunistic "time to move" nudge. HONEST LIMIT: movement is only visible
  /// while the band is streaming live IMU, so this can only fire when we've seen
  /// recent live data and then a daytime gap with no ambulatory movement. Silent
  /// when we have no movement data at all (never nudges on missing data).
  static const String _kLastInactivityMs = 'last_inactivity_ms';
  Future<void> _maybeNotifyInactivity() async {
    try {
      if (_lastMovementMs == 0) return; // no live movement data → stay silent
      final now = DateTime.now();
      if (now.hour < 9 || now.hour >= 21) return; // daytime only
      final nowMs = now.millisecondsSinceEpoch;
      final idleMs = nowMs - _lastMovementMs;
      if (idleMs < 2 * 60 * 60 * 1000) return; // < 2h idle → no nudge
      final prefs = await SharedPreferences.getInstance();
      final lastFired = prefs.getInt(_kLastInactivityMs) ?? 0;
      if (nowMs - lastFired < 2 * 60 * 60 * 1000) return; // rate-limit to /2h
      await prefs.setInt(_kLastInactivityMs, nowMs);
      final today = '${now.year}-${now.month}-${now.day}';
      await NotificationCenter.instance.emit(NotificationEvent(
        dedupeKey: '$today:move:${nowMs ~/ (2 * 60 * 60 * 1000)}',
        category: NotifCategory.reminders,
        priority: NotifPriority.low,
        title: 'Time to move',
        body: "You've been still for a couple of hours — a short walk keeps your "
            'energy and circulation up.',
        date: today,
        route: '/today',
      ));
    } catch (_) {/* best-effort */}
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

  /// Debounced "new data stored" callback from the engine (continuous listening has
  /// no discrete sync end). The engine already coalesced the burst; we run a single
  /// LIGHT derive over the affected day(s) and refresh DB counts for the UI.
  void _onDataStored() {
    unawaited(() async {
      dbCounts = await LocalDb.counts();
      notifyListeners();
      _deriveScheduler.markStoredData();
    }());
  }

  // Live (foreground / kept-alive) event path: persist every event, then let the
  // gesture dispatcher act on it. Headless drain (background_sync) persists only —
  // it must never replay an old tap as a live action.
  void _onLiveEvent(int id, int ts, String hex) {
    LocalDb.insertEvent(id, ts, hex);
    _gestureDispatcher.onEvent(id, ts, hex);
  }

  Future<void> _init() async {
    paired = await PairedDevice.load();
    await _loadProfile();
    await _deriveScheduler.init();
    lastSynced = await LocalDb.latestSample();
    _lastRecTs = await LocalDb.lastRawRecTs() ?? lastSynced?.tsEpoch;
    dbCounts = await LocalDb.counts();
    await LocalDb.refreshComputeFreshness();
    _savedAlarm = (await SharedPreferences.getInstance()).getInt('alarm_epoch');
    // Band-gesture mapping: load the saved action + query native capabilities so the
    // settings UI knows what this platform supports. Best-effort, non-blocking.
    unawaited(gestureSettings.bootstrap());
    // Notification relay (Android only; inert + invisible elsewhere). Best-effort.
    unawaited(notificationRelay.bootstrap());
    initialized = true;
    notifyListeners();
    // Companion (anonymous telemetry + health-data contribution) — best-effort,
    // OFF the critical path so it can never block/break boot. Guarded internally.
    unawaited(_initCompanion());
    unawaited(armWaterReminder()); // arm the hydration strap-buzz (timers don't persist)
    // App status (OTA pointer + admin alert banner) — best-effort, non-blocking.
    unawaited(_loadAppStatus());
    // Register the recurring wall-clock nudges as real OS-scheduled notifications
    // (wind-down, weekly recap) so they fire even when the app is closed.
    if (isPaired) unawaited(_ensureRemindersScheduled());
    if (isPaired) openSession();
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
      } catch (_) {/* fall back to default bedtime */}
      await NotificationCenter.instance
          .scheduleStandingReminders(prefs, bedtimeMinOfDay: bedtimeMin);
    } catch (e) {
      _log('[notify] schedule reminders skipped: $e');
    }
  }

  void _log(String line) {
    debugPrint('[OpenStrap] $line');
    FileLog.write(line);
    logLines.insert(0, line);
    if (logLines.length > 200) logLines.removeLast();
    notifyListeners();
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

  /// iOS recovery: release the band to the native restore central's no-timeout pending
  /// connect so the OS relaunches us when the band is reachable again.
  Future<void> _armRecovery() async {
    if (!Platform.isIOS || paired == null) return;
    IosBleRestore.foregroundActive = false;
    await IosBleRestore.setOwnsBand(false);
    await IosBleRestore.arm(paired!.remoteId);
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
    if (recTs != null && recTs > 0 && recTs > (_lastRecTs ?? 0)) {
      _lastRecTs = recTs;
    }
    if (spotActive && (pt == 0x28 || pt == 0x2B)) {
      if (_spotFrames.length < 8000) _spotFrames.add(hex);
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
        _ingestLiveMags(f.mags);
        _trackCoverage(recTs);
      }
    } else if (pt == 0x2B && !_imuStreamSeen) {
      final f = _safeFrameAccel(hex);
      if (f != null) {
        _ingestLiveMags(f.mags);
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
  double _liveEnmoSum = 0; // 1 Hz-equivalent ENMO accumulator (for calibration)
  int _liveEnmoN = 0;
  bool _imuStreamSeen = false; // prefer the 0x33 IMU stream once it appears
  static const int _minuteSamples = 6000; // 60 s @ 100 Hz — calibration chunk
  int _lastMovementMs = 0; // wall-clock of the last live frame showing real motion
  // DEVICE-time window (epoch sec) the live pedometer covered this session — so
  // the 1 Hz estimate can EXCLUDE these minutes (100 Hz real count wins).
  int? _liveCoverStartTs;
  int _liveCoverEndTs = 0;
  void _trackCoverage(int? recTs) {
    if (recTs == null || recTs <= 0) return;
    _liveCoverStartTs ??= recTs;
    if (recTs > _liveCoverEndTs) _liveCoverEndTs = recTs;
  }

  /// Steps counted on the live 100 Hz stream this connected session (real,
  /// gain-applied). Used for cadence calibration. 0 when not streaming.
  int get _liveRaw =>
      _committedRaw + (_magMin.isEmpty ? 0 : ana.pedometer(_magMin));
  int get liveSteps => (_liveRaw * ana.StepParams.gain).round();

  // Snapshot of the RAW session total at the moment a manual workout started, so
  // the live-session screen shows steps FOR THIS WORKOUT (not since connection).
  int? _workoutRawBase;

  /// Steps taken since the active workout started (real, live, gain-applied).
  /// 0 when no workout is running. This is what the workout screen shows.
  int get workoutSteps {
    if (activeWorkout == null || _workoutRawBase == null) return 0;
    final raw = _liveRaw - _workoutRawBase!;
    return raw > 0 ? (raw * ana.StepParams.gain).round() : 0;
  }

  void _ingestLiveMags(List<double> mags) {
    if (mags.isEmpty) return;
    // Append this frame's |a|(g) samples (gravity INCLUDED — AN-2554's dynamic
    // threshold rides the ~1 g baseline). Also accumulate a 1 Hz-equivalent ENMO
    // sample (mean |a| − 1 g) for cadence calibration.
    var magSum = 0.0;
    for (final m in mags) {
      _magMin.add(m);
      magSum += m;
    }
    _liveSamples += mags.length;
    final e = (magSum / mags.length) - 1.0;
    _liveEnmoSum += e > 0 ? e : 0.0;
    _liveEnmoN++;
    // Stamp last real motion (for the inactivity nudge). 0.02 g over baseline is
    // clearly dynamic movement, not resting jitter.
    if (e > 0.02) _lastMovementMs = DateTime.now().millisecondsSinceEpoch;

    // Commit each completed minute into the raw total (matches the gain's
    // per-minute calibration), then keep counting the next partial minute.
    while (_magMin.length >= _minuteSamples) {
      final minute = _magMin.sublist(0, _minuteSamples);
      _magMin.removeRange(0, _minuteSamples);
      _committedRaw += ana.pedometer(minute);
    }
    notifyListeners(); // live readout re-counts the partial minute on read
  }

  /// Reset the live step counter for a fresh connected session.
  void _resetLivePedometer() {
    _magMin.clear();
    _committedRaw = 0;
    _liveSamples = 0;
    _liveEnmoSum = 0;
    _liveEnmoN = 0;
    _imuStreamSeen = false;
    _liveCoverStartTs = null;
    _liveCoverEndTs = 0;
  }

  /// End-of-session: if the bout is credible walking, fold it into the personal
  /// cadence calibration (persisted) so the 24/7 estimate gets more accurate.
  Future<void> _finalizeLivePedometer() async {
    final steps = liveSteps; // gain-applied
    final durS = _liveSamples / 100.0;
    final enmo = _liveEnmoN > 0 ? _liveEnmoSum / _liveEnmoN : 0.0;
    // Capture the device-time coverage window BEFORE resetting.
    final coverStart = _liveCoverStartTs;
    final coverEnd = _liveCoverEndTs;
    _resetLivePedometer();
    // Record the REAL 100 Hz step window (device time). The derivation pass adds
    // it to the day's steps AND excludes those minutes from the 1 Hz estimate, so
    // 100 Hz always wins and a minute is never counted twice.
    if (steps > 0 && coverStart != null && coverEnd >= coverStart) {
      final d = DateTime.fromMillisecondsSinceEpoch(coverStart * 1000);
      final day = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      unawaited(LocalDb.addLiveCoverage(coverStart, coverEnd, steps, day));
    }
    if (steps <= 0 || durS < 20) return;
    final cadence = steps / (durS / 60.0);
    // Any nonzero AN-2554 count is CONFIRM-gated gait; confidence is high when
    // the cadence lands in a walking band (else let calibrateCadence reject it).
    final conf = (cadence >= 60 && cadence <= 200) ? 0.85 : 0.4;
    final result = ana.PedometerResult(steps, durS, cadence, 0.0, conf);
    try {
      final prior = await LocalDb.getStepCalibration();
      final next = ana.calibrateCadence(prior, result, enmo);
      if (next != null && !identical(next, prior)) {
        await LocalDb.putStepCalibration(next);
        _log('[steps] cadence calibrated → '
            '${next.cadenceSpm.toStringAsFixed(0)} spm (n=${next.n})');
      }
    } catch (e) {
      _log('[steps] calibration skipped: $e');
    }
  }

  void _onEngineState(DeviceState s) {
    // Battery-low / charging OS notifications (edge-triggered + de-duped inside).
    _deviceAlerts.onDeviceState(batteryPct: s.batteryPct, charging: s.charging);
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
    // Heal a stale/garbled persisted serial: once the band reports a clean serial
    // (HELLO body, fixed offset), persist it so the disconnected display stops
    // showing any old "?*" junk left by a previous build.
    final cleanSn = cleanDeviceLabel(s.serial);
    if (cleanSn != null && cleanSn != paired?.serial) {
      final rid = paired?.remoteId ?? s.address;
      if (rid != null && rid.isNotEmpty) {
        paired = PairedDevice(rid, cleanSn);
        unawaited(PairedDevice.save(rid, cleanSn));
      }
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
      if (_keepAlive && isPaired && !_reconnecting) {
        _log('Connection dropped — reconnecting…');
        _stopBackfillTimer();
        // If we're backgrounded, also arm the iOS restore path: if the in-process
        // reconnect can't reach the band (out of range / about to be jettisoned), the
        // OS will relaunch us when it returns.
        if (_background) unawaited(_armRecovery());
        _reconnect();
      }
    }
    _prevConn = s.connection;
    notifyListeners();
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
    try {
      _log('Periodic history refresh — requesting another offload.');
      final report = await _runSyncBurst(kickFirst: true);
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

  Future<SyncReport> _runSyncBurst({
    required bool kickFirst,
    int maxSessions = 6,
  }) async {
    var last = SyncReport(0, 0, false);
    for (var i = 0; i < maxSessions && engine.isConnected; i++) {
      final frontierBefore = await LocalDb.lastRawRecTs();
      if (kickFirst || i > 0) {
        await engine.requestHistorySync();
      }
      kickFirst = false;
      final report = await engine.runSync(
        timeout: const Duration(seconds: 180),
      );
      final frontierAfter = await LocalDb.lastRawRecTs();
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
      if (!frontierAdvanced) {
        _log(
          'Backfill stop — batch ACKed but persisted frontier did not advance.',
        );
        break;
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
    notifyListeners();
    await openSession();
  }

  Future<void> unpair() async {
    _keepAlive = false;
    _stopBackfillTimer();
    IosBleRestore.foregroundActive = false;
    await EdgeTracking.stop();
    await IosBleRestore.disarm();
    // Deprovision the ASK accessory (iOS 18+) so a future pair re-shows the picker and
    // re-establishes iOS-26 relaunch eligibility. No-op on Android / iOS < 18.
    await AccessorySetup.removeAll();
    await engine.disconnect();
    await PairedDevice.clear();
    paired = null;
    notifyListeners();
  }

  // ── alarm + strap name (require a live connection) ──────────────────────────
  bool get isConnected => device.connection == 'connected';
  // Prefer a value read back from the band; else the one we last set (persisted),
  // since the band's GET_ALARM echo format isn't fully confirmed.
  int? get alarmEpoch => device.alarmEpoch ?? _savedAlarm;
  String? get strapName => device.strapName;
  int? _savedAlarm;

  Future<void> setAlarm(DateTime when) async {
    if (!isConnected) throw Exception('Connect to your strap first');
    final epoch =
        when.millisecondsSinceEpoch ~/ 1000; // local wall-clock → unix
    await engine.setAlarm(epoch);
    _savedAlarm = epoch;
    device.alarmEpoch = epoch; // optimistic display
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('alarm_epoch', epoch);
    await engine.getAlarm();
    notifyListeners();
  }

  Future<void> clearAlarm() async {
    if (!isConnected) throw Exception('Connect to your strap first');
    await engine.disableAlarm();
    _savedAlarm = null;
    device.alarmEpoch = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('alarm_epoch');
    notifyListeners();
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
    // Returning to the foreground with the connection still alive (kept during
    // background): don't tear it down and reconnect — just reclaim ownership.
    final wasBackground = _background;
    _background = false;
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
      if (engine.sinceLastRx < const Duration(seconds: 30)) {
        // Healthy link → fast reclaim. But the fast path skips the band polls the full
        // connect path runs, so the cached battery %/charging/strap-name/alarm go stale.
        // Re-poll them in the background so the UI stays current. Non-blocking.
        unawaited(() async {
          try {
            await engine.getBattery();
            await engine.getStrapName();
            await engine.getAlarm();
          } catch (_) {}
        }());
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
    // Android: start the Edge Tracking foreground service so the live connection keeps
    // draining while backgrounded (Android kills background processes otherwise).
    EdgeTracking.start();
    // iOS: arm CoreBluetooth restoration so the band can relaunch us when terminated.
    // The foreground guard stops a wake from fighting this live session for the band.
    IosBleRestore.foregroundActive = true;
    IosBleRestore.arm(paired!.remoteId);
    _log('===== SESSION START ===== raw=${dbCounts['raw']}');
    try {
      // connect() now subscribes → SET_CLOCK → INIT, so the historical offload is
      // ALREADY streaming the moment this returns. We just enable live streams (so
      // the band also emits live R10/R11) and poll device info; the offload keeps
      // running on the same subscription with no mode flip.
      if (!await engine.connectToRemoteId(paired!.remoteId)) {
        lastError =
            'Could not reach your band. Is it nearby and free '
            '(official WHOOP app force-quit)?';
        return;
      }
      await engine.enableLiveStreams();
      _resetLivePedometer(); // fresh live step count for this connected session
      await engine.getBattery();
      await engine
          .getStrapName(); // populate strap name + alarm for the Profile UI
      await engine.getAlarm();
      _log('Listening (history + live).');
      // Block until the band's backlog is fully handed over (HISTORY_COMPLETE) —
      // does NOT abort or end the listen. Per-batch derives already fired via the
      // debounced onDataStored; once the WHOLE backlog has landed we run the heavy
      // foreground finalize (full sleep staging + 24-h spectra over every stale day).
      final report = await _runSyncBurst(kickFirst: false);
      _log(
        'Backlog drained: ${report.records} records in ${report.batches} '
        'batches (${report.complete ? "complete" : "stopped early"}).',
      );
      dbCounts = await LocalDb.counts();
      _deriveScheduler.requestHeavy();
      _startBackfillTimer();
    } catch (e) {
      lastError = e.toString();
    } finally {
      if (!engine.isConnected || !_keepAlive) {
        _stopBackfillTimer();
      }
      _setBusy(false);
    }
  }

  Future<void> _reconnect() async {
    if (_reconnecting || paired == null) return;
    _reconnecting = true;
    try {
      // Keep trying for as long as we still want the link (a session is active) —
      // a runner who left their phone behind can be out of range for an hour.
      // Bounded exponential backoff + jitter, owned by the transport's
      // ReconnectPolicy. The engine's single in-flight guard guarantees this loop
      // can never overlap a foreground connect on the same band.
      int attempt = 0;
      while (_keepAlive && !engine.isConnected) {
        attempt++;
        await Future.delayed(engine.reconnectDelay(attempt));
        if (!_keepAlive) break;
        if (await engine.connectToRemoteId(paired!.remoteId)) {
          // Reclaim the band from the iOS restore central so it stops competing.
          if (Platform.isIOS) {
            IosBleRestore.foregroundActive = true;
            await IosBleRestore.setOwnsBand(true);
          }
          EdgeTracking.start(); // ensure the Android foreground service is up too
          // FULL drain (no short timeout): pull the ENTIRE offline backlog the band
          // buffered to flash while we were out of range.
          await _runSyncBurst(kickFirst: false);
          await engine.enableLiveStreams();
          dbCounts = await LocalDb.counts();
          _log('Reconnected — backlog drained.');
          // Backlog (often an overnight gap) just landed → derive it.
          _deriveScheduler.requestHeavy();
          _startBackfillTimer();
          break;
        }
      }
    } catch (e) {
      _log('Reconnect failed: $e');
    } finally {
      _reconnecting = false;
    }
  }

  /// Pull anything the band flashed that we don't have yet, over the CURRENT
  /// connection (no reconnect, no teardown). Used when a workout ends so a session
  /// that rode the live feed still gets its window backfilled from flash.
  Future<void> forceResync() async {
    if (!engine.isConnected) return;
    try {
      // Re-trigger a fresh offload over the live connection (no reconnect), then
      // wait for it to fully hand over. Live streams stay on; no mode change.
      await _runSyncBurst(kickFirst: true);
      dbCounts = await LocalDb.counts();
      notifyListeners();
      // A just-finished workout window landed from flash → derive it (light).
      _deriveScheduler.markStoredData();
    } catch (e) {
      _log('Resync failed: $e');
    }
  }

  Future<void> syncNow() => openSession();

  Future<void> endSession() async {
    _keepAlive = false;
    _stopBackfillTimer();
    await engine.disconnect();
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

  /// REAL device timestamp of the newest record we hold (the band's own clock),
  /// NOT when the BLE frame arrived. This is what "last data: …" displays — a
  /// flash backfill arrives "now" but carries hours-old records. `null` until any
  /// record exists.
  DateTime? get lastRecordAt => _lastRecTs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_lastRecTs! * 1000);

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

  Future<bool> bluetoothReady() async {
    if (!await FlutterBluePlus.isSupported) return false;
    final state = await FlutterBluePlus.adapterState.first;
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
      // If a workout is already streaming, reuse it; else turn streams on ourselves.
      if (activeWorkout == null) {
        await engine.enableLiveStreams();
        _spotEnabledStreams = true;
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

  // ── guided step calibration (open-road walk) ────────────────────────────────
  // A short live 100 Hz walk teaches the user's real walking signature (refEnmo)
  // + cadence, which anchors the 1 Hz daily estimate. Target a step count with a
  // buffer so the AN-2554 confirm-gate has settled.
  static const int stepCalTargetSteps = 200; // steps to learn a stable cadence
  static const int stepCalBuffer = 50; // ask the user to walk a bit more
  bool _stepCalEnabledStreams = false;

  /// Begin a calibration walk: turn on the live IMU stream and count from zero.
  Future<void> startStepCalibration() async {
    if (!isConnected) throw Exception('Connect to your strap first');
    if (activeWorkout == null) {
      await engine.enableLiveStreams();
      _stepCalEnabledStreams = true;
    }
    _resetLivePedometer(); // count this walk from 0
    notifyListeners();
  }

  /// Finish the calibration walk: fold the live bout into the personal cadence
  /// model (refEnmo + cadence). Returns the learned cadence (spm), or null if the
  /// walk wasn't credible. Stops the stream we turned on.
  Future<double?> finishStepCalibration() async {
    final steps = liveSteps;
    final durS = _liveSamples / 100.0;
    final enmo = _liveEnmoN > 0 ? _liveEnmoSum / _liveEnmoN : 0.0;
    double? learned;
    if (steps > 0 && durS >= 20) {
      final cadence = steps / (durS / 60.0);
      final conf = (cadence >= 60 && cadence <= 200) ? 0.9 : 0.4;
      final result = ana.PedometerResult(steps, durS, cadence, 0.0, conf);
      try {
        final prior = await LocalDb.getStepCalibration();
        final next = ana.calibrateCadence(prior, result, enmo);
        if (next != null) {
          await LocalDb.putStepCalibration(next);
          learned = next.cadenceSpm;
          _log('[steps] CALIBRATED → ${next.cadenceSpm.toStringAsFixed(0)} spm '
              '(refEnmo=${next.refEnmo.toStringAsFixed(3)}, n=${next.n})');
        }
      } catch (e) {
        _log('[steps] calibration failed: $e');
      }
    }
    if (_stepCalEnabledStreams && activeWorkout == null) {
      unawaited(engine.disableLiveStreams());
    }
    _stepCalEnabledStreams = false;
    _resetLivePedometer();
    notifyListeners();
    return learned;
  }

  /// Cancel a calibration walk without saving.
  void cancelStepCalibration() {
    if (_stepCalEnabledStreams && activeWorkout == null) {
      unawaited(engine.disableLiveStreams());
    }
    _stepCalEnabledStreams = false;
    _resetLivePedometer();
    notifyListeners();
  }

  // ── live session coach ───────────────────────────────────────────────────────
  LiveWorkoutState? activeWorkout;
  Timer? _workoutTimer;

  DateTime _lastLaPush = DateTime.fromMillisecondsSinceEpoch(0);

  // Sourced from the LOCAL profile (no server). Fall back to representative
  // defaults when a field isn't set yet. maxHr = 220 - age.
  int get _maxHr {
    final age = (user?['age'] as num?)?.toDouble() ?? 30.0;
    return (220 - age).round();
  }

  int get _restingHr => (user?['resting_hr'] as num?)?.round() ?? 60;

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
    _workoutRawBase = _liveRaw;
    activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: targetKcal,
      workoutId: id,
      type: type,
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
  }

  /// If the Live Activity's Finish button was tapped (App Intent set the flag),
  /// stop the workout here too. Call on app resume.
  Future<void> maybeFinishFromLiveActivity() async {
    if (activeWorkout != null && await WidgetService.consumeEndSessionFlag()) {
      stopWorkout();
    }
  }

  void stopWorkout() {
    if (activeWorkout == null) return;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    final w = activeWorkout!;
    final finalKcal = w.calories.round();
    final wSteps = workoutSteps; // real steps taken during this workout
    // Persist the finalized session before clearing the live state. No per-zone
    // minute tallies are tracked live, so zone_min is honestly empty.
    final id = w.workoutId ?? 'w${w.startTime.millisecondsSinceEpoch}';
    unawaited(
      LocalDb.putSession({
        'id': id,
        'start_ts': w.startTime.millisecondsSinceEpoch ~/ 1000,
        'end_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'type': w.type,
        'status': 'done',
        'calories': w.calories,
        'strain': w.strain,
        'max_hr': w.maxHrSeen > 0 ? w.maxHrSeen : null,
        'duration_min': w.elapsed.inMinutes,
        'zone_min_json': jsonEncode(const <num>[]),
        if (wSteps > 0) 'steps': wSteps,
        'source': 'manual',
        'created_at': w.startTime.millisecondsSinceEpoch,
      }),
    );
    activeWorkout = null;
    _workoutRawBase = null;
    notifyListeners();
    _log('Live session ended. Burned $finalKcal kcal.');
    LiveActivity.end();
    // A workout often rides the live feed; if the connection blipped during it, the
    // band may hold that window in flash. Pull it now over the live connection so the
    // just-finished session isn't left with a gap.
    unawaited(forceResync());
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
        stopWorkout();
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
    if (w.currentHr > w.maxHrSeen) w.maxHrSeen = w.currentHr;

    if (w.currentHr > 0) {
      // Calorie burn formula (estimate per second). Personalized from the LOCAL
      // profile, with representative fallbacks (30y, 70kg, male) when unset.
      final u = user ?? const {};
      final age = (u['age'] as num?)?.toDouble() ?? 30.0;
      final weight = (u['weight_kg'] as num?)?.toDouble() ?? 70.0;
      final female = u['sex'] == 'f';

      double kcalMin;
      if (female) {
        kcalMin =
            (-20.4022 +
                (0.4472 * w.currentHr) -
                (0.1263 * weight) +
                (0.074 * age)) /
            4.184;
      } else {
        kcalMin =
            (-55.0969 +
                (0.6309 * w.currentHr) +
                (0.1988 * weight) +
                (0.2017 * age)) /
            4.184;
      }
      // Add per-second slice (kcal/min / 60). Clamp to 0 in case of low HR.
      w.calories += (kcalMin.clamp(0.0, 30.0) / 60.0);

      // Rough strain accumulation (experimental): HRR% (HR Reserve) → strain/sec.
      final maxHr = 220.0 - age;
      final rhr = (u['resting_hr'] as num?)?.toDouble() ?? 60.0;
      final hrr = (w.currentHr - rhr) / (maxHr - rhr).clamp(1.0, 200.0);
      if (hrr > 0) {
        w.strain +=
            (hrr * 0.01); // scales to ~15-20 strain over an hour of hard work
      }
    }
    // Push to the Live Activity at most ~every 4s (ActivityKit throttles; saves battery).
    if (DateTime.now().difference(_lastLaPush).inSeconds >= 4) {
      _lastLaPush = DateTime.now();
      LiveActivity.update(
        hr: w.currentHr,
        zone: _zoneFor(w.currentHr),
        strain: w.strain,
        calories: w.calories.round(),
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
  double calories = 0.0;
  double strain = 0.0;
  int currentHr = 0;
  int maxHrSeen = 0; // peak live HR this session (for the "new max!" moment)

  LiveWorkoutState({
    required this.startTime,
    required this.targetKcal,
    this.workoutId,
    this.type = 'other',
  });
}
