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
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_status.dart';
import '../ble/accessory_setup.dart';
import '../ble/ble_engine.dart';
import '../ble/ios_ble_restore.dart';
import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../data/db.dart';
import '../data/local_repository.dart';
import '../data/local_repository_impl.dart';
import '../gestures/gesture_settings.dart';
import '../gestures/gesture_dispatcher.dart';
import '../data/models.dart';
import '../live/live_activity.dart';
import '../notify/device_alerts.dart';
import '../notify/notification_relay.dart';
import '../notify/notification_service.dart';
import '../sync/edge_tracking.dart';
import '../sync/paired_device.dart';
import '../sync/update_service.dart';
import '../widget/widget_service.dart';
import '../sync/file_log.dart';

/// The onboarding/app gate states, in order. See [AppState.route].
/// Flow: loading → pairing → profile (only if incomplete) → shell. The profile
/// step collects age/weight/height/sex so the on-device analytics can
/// personalize (HRmax, calories, TRIMP); it's skipped once those are set.
enum AppRoute { loading, pairing, profile, shell }

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
  Sample? lastSynced;
  Map<String, int> dbCounts = {'raw': 0, 'pending': 0};
  final List<String> logLines = [];
  String? lastError;
  bool busy = false;

  bool _keepAlive = false;
  bool _reconnecting = false;
  String _prevConn = 'disconnected';
  // Last battery snapshot pushed to the Band Battery widget — so we only reload
  // the widget when pct/charging actually change (the engine-state hook fires
  // ~1 Hz on live HR). -2 = never pushed.
  int _widgetBattPct = -2;
  bool? _widgetBattCharging;
  String? _widgetBattName;
  bool initialized = false;

  /// True while the app is backgrounded. On iOS we KEEP the BLE connection alive in
  /// this state (see [pauseForBackground]) so the OS keeps resuming us per BLE
  /// notification and the live drain continues.
  bool _background = false;

  bool get isPaired => paired != null;

  // ── local profile (was server-side; now device-local) ───────────────────────
  // CLOUD EXCISED: the user's name/sex/age/height/weight + prefs (track_cycle,
  // step_goal, resting_hr…) used to live on the backend behind the JWT. They are
  // now a small LOCAL map persisted in shared_preferences. This is the on-device
  // profile the analytics re-layer will read for personalization. `null` until set.
  static const String _kProfile = 'local_profile_json';
  Map<String, dynamic>? user;

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfile);
    if (raw != null) {
      try {
        user = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {/* ignore corrupt blob */}
    }
  }

  /// Merge + persist local profile fields. Returns the updated map. Replaces the
  /// old cloud PATCH /profile (no network).
  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) async {
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
    user = null;
    await unpair();
  }

  /// The single onboarding/route the UI gate is in. `_Gate` selects on THIS so it
  /// rebuilds only on a real route transition — NOT on every ~1 Hz notifyListeners
  /// (live HR, log lines), which used to repaint the whole home stack each second
  /// and starve the background BLE connection.
  AppRoute get route {
    if (!initialized) return AppRoute.loading;
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
      _update != null && _currentBuild > 0 && _update!.latestBuild > _currentBuild;

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
    } catch (_) {/* keep 0 → update prompts simply won't fire */}
    final prefs = await SharedPreferences.getInstance();
    _dismissedBanners.addAll(prefs.getStringList('dismissed_banners') ?? const []);
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
      // Debounced compute trigger: with continuous listening there's no discrete
      // "sync done", so the engine coalesces stored-record bursts and fires this
      // once a burst goes quiet. Light pass (newest affected day) — the foreground
      // heavy finalize still runs in openSession after the backlog fully drains.
      onDataStored: _onDataStored,
    );
    repo = LocalRepositoryImpl(getProfileMap: () => user);
    _init();
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
          dbCounts = await LocalDb.counts();
          notifyListeners();
        },
      );
      notifyListeners(); // screens re-fetch from the derived store
    } catch (e) {
      _log('[derive] post-drain failed: $e');
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
          dbCounts = await LocalDb.counts();
          notifyListeners();
        },
      );
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

  /// Debounced "new data stored" callback from the engine (continuous listening has
  /// no discrete sync end). The engine already coalesced the burst; we run a single
  /// LIGHT derive over the affected day(s) and refresh DB counts for the UI.
  void _onDataStored() {
    unawaited(() async {
      dbCounts = await LocalDb.counts();
      await _afterDrain(); // light pass
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
    lastSynced = await LocalDb.latestSample();
    dbCounts = await LocalDb.counts();
    _savedAlarm = (await SharedPreferences.getInstance()).getInt('alarm_epoch');
    // Band-gesture mapping: load the saved action + query native capabilities so the
    // settings UI knows what this platform supports. Best-effort, non-blocking.
    unawaited(gestureSettings.bootstrap());
    // Notification relay (Android only; inert + invisible elsewhere). Best-effort.
    unawaited(notificationRelay.bootstrap());
    initialized = true;
    notifyListeners();
    // App status (OTA pointer + admin alert banner) — best-effort, non-blocking.
    unawaited(_loadAppStatus());
    if (isPaired) openSession();
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
      IosBleRestore.foregroundActive = true; // "app owns the band" — don't let restore compete
      await IosBleRestore.setOwnsBand(true);
      _log('Backgrounded — holding live connection for continuous background capture');
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

  Future<void> _onRecord(Sample? sample, RawRecord raw) async {
    // Spot-check: tap the live RR-bearing frames (0x28 compact HR, 0x2B R10) into
    // the in-memory scan buffer. Cheap-bounded; cleared at each scan start.
    if (spotActive && (raw.packetType == 0x28 || raw.packetType == 0x2B)) {
      if (_spotFrames.length < 8000) _spotFrames.add(raw.hex);
    }
    await LocalDb.insertRecord(raw, sample);
  }

  void _onEngineState(DeviceState s) {
    // Battery-low / charging OS notifications (edge-triggered + de-duped inside).
    _deviceAlerts.onDeviceState(batteryPct: s.batteryPct, charging: s.charging);
    // Keep the lock-screen Band Battery widget current — only when it changed.
    final battPct = s.batteryPct?.round() ?? -1;
    if (battPct != _widgetBattPct ||
        s.charging != _widgetBattCharging ||
        s.strapName != _widgetBattName) {
      _widgetBattPct = battPct;
      _widgetBattCharging = s.charging;
      _widgetBattName = s.strapName;
      unawaited(WidgetService.pushBattery(
          s.batteryPct == null ? null : battPct, s.charging, s.strapName));
    }
    if (_prevConn != 'disconnected' && s.connection == 'disconnected') {
      if (_keepAlive && isPaired && !_reconnecting) {
        _log('Connection dropped — reconnecting…');
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
    final epoch = when.millisecondsSinceEpoch ~/ 1000; // local wall-clock → unix
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
        return;
      }
      _log('Resume: no BLE data for ${engine.sinceLastRx.inSeconds}s — stale link, reconnecting.');
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
        lastError = 'Could not reach your band. Is it nearby and free '
            '(official WHOOP app force-quit)?';
        return;
      }
      await engine.enableLiveStreams();
      await engine.getBattery();
      await engine.getStrapName(); // populate strap name + alarm for the Profile UI
      await engine.getAlarm();
      _log('Listening (history + live).');
      // Block until the band's backlog is fully handed over (HISTORY_COMPLETE) —
      // does NOT abort or end the listen. Per-batch derives already fired via the
      // debounced onDataStored; once the WHOLE backlog has landed we run the heavy
      // foreground finalize (full sleep staging + 24-h spectra over every stale day).
      final report = await engine.runSync();
      _log('Backlog drained: ${report.records} records in ${report.batches} '
          'batches (${report.complete ? "complete" : "stopped early"}).');
      dbCounts = await LocalDb.counts();
      unawaited(_afterDrain(heavy: true));
    } catch (e) {
      lastError = e.toString();
    } finally {
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
          await engine.runSync();
          await engine.enableLiveStreams();
          dbCounts = await LocalDb.counts();
          _log('Reconnected — backlog drained.');
          // Backlog (often an overnight gap) just landed → derive it.
          unawaited(_afterDrain(heavy: true));
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
      await engine.requestHistorySync();
      await engine.runSync();
      dbCounts = await LocalDb.counts();
      notifyListeners();
      // A just-finished workout window landed from flash → derive it (light).
      unawaited(_afterDrain());
    } catch (e) {
      _log('Resync failed: $e');
    }
  }

  Future<void> syncNow() => openSession();

  Future<void> endSession() async {
    _keepAlive = false;
    await engine.disconnect();
  }

  String get status => device.connection;

  /// Wall-clock of the last BLE notification received (any characteristic), for the
  /// "last data: Xs ago" UI. `null` until the first frame this connection.
  DateTime? get lastDataAt => engine.lastRxAt;

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
  int spotRemaining = 0;             // seconds left in the current scan
  Map<String, dynamic>? spotResult;  // last result {rmssd, sdnn, mean_hr, n_beats, ok}
  String? spotError;
  final List<String> _spotFrames = [];
  Timer? _spotTimer;
  bool _spotEnabledStreams = false;  // did WE turn streams on (so we turn them off)

  /// Begin a 60s live HRV reading. Requires a connected band.
  Future<void> startSpotCheck() async {
    if (spotActive) return;
    if (!isConnected) { spotError = 'Connect your band first.'; notifyListeners(); return; }
    spotActive = true;
    spotError = null;
    spotResult = null;
    spotRemaining = spotDuration;
    _spotFrames.clear();
    notifyListeners();
    try {
      // If a workout is already streaming, reuse it; else turn streams on ourselves.
      if (activeWorkout == null) { await engine.enableLiveStreams(); _spotEnabledStreams = true; }
    } catch (_) {/* best-effort; we still collect whatever arrives */}
    _spotTimer?.cancel();
    _spotTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      spotRemaining -= 1;
      if (spotRemaining <= 0) { unawaited(_finishSpotCheck()); } else { notifyListeners(); }
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

  void startWorkout({double targetKcal = 300, String? workoutId, String type = 'other'}) {
    if (activeWorkout != null) return;
    final start = DateTime.now();
    activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: targetKcal,
      workoutId: workoutId,
      type: type,
    );
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickWorkout());
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
    final finalKcal = activeWorkout!.calories.round();
    activeWorkout = null;
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
          } catch (_) {/* seam not implemented yet; local already stopped */}
        }
      } else {
        String? id;
        try {
          final w = await repo?.startWorkout('other');
          id = w?['workout_id'] as String?;
        } catch (_) {/* seam not implemented yet; still start locally */}
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
      final date = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      List<String> tags = [];
      String note = '';
      try {
        final journal = await r.getJournal(range: '7d');
        final today = journal.firstWhere(
          (e) => e['date'] == date,
          orElse: () => <String, dynamic>{},
        );
        tags = (today['tags'] as List?)?.map((e) => e.toString()).toList() ?? [];
        note = (today['note'] as String?) ?? '';
      } catch (_) {/* fresh day / seam not implemented — start clean */}
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
        kcalMin = (-20.4022 + (0.4472 * w.currentHr) - (0.1263 * weight) + (0.074 * age)) / 4.184;
      } else {
        kcalMin = (-55.0969 + (0.6309 * w.currentHr) + (0.1988 * weight) + (0.2017 * age)) / 4.184;
      }
      // Add per-second slice (kcal/min / 60). Clamp to 0 in case of low HR.
      w.calories += (kcalMin.clamp(0.0, 30.0) / 60.0);

      // Rough strain accumulation (experimental): HRR% (HR Reserve) → strain/sec.
      final maxHr = 220.0 - age;
      final rhr = (u['resting_hr'] as num?)?.toDouble() ?? 60.0;
      final hrr = (w.currentHr - rhr) / (maxHr - rhr).clamp(1.0, 200.0);
      if (hrr > 0) {
        w.strain += (hrr * 0.01); // scales to ~15-20 strain over an hour of hard work
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
  final String type;       // exercise type label
  Duration elapsed = Duration.zero;
  double calories = 0.0;
  double strain = 0.0;
  int currentHr = 0;
  int maxHrSeen = 0;       // peak live HR this session (for the "new max!" moment)

  LiveWorkoutState({
    required this.startTime,
    required this.targetKcal,
    this.workoutId,
    this.type = 'other',
  });
}
