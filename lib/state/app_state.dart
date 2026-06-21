// AppState — the single ChangeNotifier the UI listens to. Orchestrates auth,
// the BLE engine, local DB writes (raw-first), and per-user cloud upload.
//
// Onboarding gate (see app.dart):
//   backend not chosen → BackendChoice
//   not authenticated  → Auth → OTP
//   not paired         → Pairing (LOCAL device pref; re-pair after every sign-in)
//   else               → main Shell (auto-connect saved band, drain, live, upload)

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_status.dart';
import '../ble/ble_engine.dart';
import '../ble/ios_ble_restore.dart';
import '../data/db.dart';
import '../gestures/gesture_settings.dart';
import '../gestures/gesture_dispatcher.dart';
import '../data/models.dart';
import '../net/api_client.dart';
import '../live/live_activity.dart';
import '../notify/device_alerts.dart';
import '../notify/notification_relay.dart';
import '../notify/notification_service.dart';
import '../sync/config.dart';
import '../sync/edge_tracking.dart';
import '../widget/widget_service.dart';
import '../sync/file_log.dart';
import '../sync/uploader.dart';

/// The onboarding/app gate states, in order. See [AppState.route].
enum AppRoute { loading, backend, auth, profile, pairing, shell }

class AppState extends ChangeNotifier {
  late final BleEngine engine;
  BackendConfig? config;
  Session? session;
  ApiClient? api;
  PairedDevice? paired;

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
  /// notification and the live drain + flush continue.
  bool _background = false;

  // THE single upload path. Every record source (live 0x28/R10/IMU, historical drain)
  // only ever STORES locally (raw_records, hex PK, retain-until-200). This one timer is
  // the ONLY thing that POSTs: it kicks once on start, then uploads everything pending
  // every _kFlushInterval, deleting each chunk only on its confirmed 200 (so a non-200/
  // 429 just leaves rows queued for the next tick — no backoff needed; the 60s cadence
  // sits well under the backend rate limit of burst 30 / refill 0.5/s). Uniform
  // behaviour everywhere — no per-event upload() calls to drift out of sync.
  //
  // The 60s cadence collapses the steady-state 1 Hz trickle from ~1 POST/15s (~5,760/
  // day) to ~1 POST/min (~1,440/day) — ~4× fewer R2 puts + D1 writes + Workers requests,
  // with zero data loss (cloud metrics land at the wake-close, so ≤1 min upload latency
  // is invisible). Connection-independent: keeps flushing through background and across
  // reconnects; stopped only on session teardown (logout / signOut / unpair / endSession).
  Timer? _flushTimer;
  static const Duration _kFlushInterval = Duration(seconds: 60);

  bool get backendChosen => config?.chosen ?? false;
  bool get isAuthenticated => session?.isValid ?? false;
  bool get isPaired => paired != null;
  Map<String, dynamic>? get user => session?.user;

  /// True once age/height/weight are set (collected post-OTP via /profile PATCH).
  /// Until then the gate shows ProfileSetupScreen.
  bool get profileComplete {
    final u = session?.user;
    return u != null &&
        u['age'] != null &&
        u['height_cm'] != null &&
        u['weight_kg'] != null;
  }

  /// The single onboarding/route the UI gate is in. `_Gate` selects on THIS so it
  /// rebuilds only on a real route transition — NOT on every ~1 Hz notifyListeners
  /// (live HR, log lines), which used to repaint the whole home stack each second
  /// and starve the background BLE connection.
  AppRoute get route {
    if (!initialized) return AppRoute.loading;
    if (!backendChosen) return AppRoute.backend;
    if (!isAuthenticated) return AppRoute.auth;
    if (!profileComplete) return AppRoute.profile;
    if (!isPaired) return AppRoute.pairing;
    return AppRoute.shell;
  }

  // ── app status: OTA update pointer + admin-pushed alert banner ──────────────
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

  /// Re-poll /app/status (best-effort; called on launch and on app resume).
  Future<void> refreshAppStatus() async {
    if (api == null) return;
    try {
      appStatus = AppStatus.fromJson(await api!.getAppStatus());
      notifyListeners();
    } catch (_) {/* best-effort — never disrupt the UI */}
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
    );
    _init();
  }

  // Live (foreground / kept-alive) event path: persist every event, then let the
  // gesture dispatcher act on it. Headless drain (background_sync) persists only —
  // it must never replay an old tap as a live action.
  void _onLiveEvent(int id, int ts, String hex) {
    LocalDb.insertEvent(id, ts, hex);
    _gestureDispatcher.onEvent(id, ts, hex);
  }

  Future<void> _init() async {
    config = await BackendConfig.load();
    session = await Session.load();
    paired = await PairedDevice.load();
    _rebuildApi();
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
    // The flusher is connection-INDEPENDENT: it just uploads whatever's queued in
    // SQLite (and retries anything a prior tick failed to send). Start it as soon as
    // we're authenticated so a backlog drains even if the live connection comes up via
    // _reconnect rather than openSession.
    if (isAuthenticated) _startFlusher();
    if (isAuthenticated && isPaired) openSession();
  }

  void _rebuildApi() {
    if (config == null || session == null) return;
    api = ApiClient(config!, session!, onLoggedOut: _onLoggedOut);
  }

  void _onLoggedOut() {
    // Refresh failed — session already cleared by ApiClient. Drop to login.
    // The local upload queue persists and retries after re-login.
    _keepAlive = false;
    _stopFlusher();
    engine.disconnect();
    _log('Session expired — please sign in again.');
    notifyListeners();
  }

  void _log(String line) {
    debugPrint('[OpenStrap] $line');
    FileLog.write(line);
    logLines.insert(0, line);
    if (logLines.length > 200) logLines.removeLast();
    notifyListeners();
  }

  // ── onboarding: backend choice ────────────────────────────────────────────────
  Future<void> chooseBackend(String url) async {
    config!
      ..url = url.trim().isEmpty ? BackendConfig.defaultUrl : url.trim()
      ..chosen = true;
    await config!.save();
    _rebuildApi();
    notifyListeners();
  }

  Future<void> updateBackendUrl(String url) async {
    config!.url = url.trim();
    await config!.save();
    _rebuildApi();
    notifyListeners();
  }

  // ── auth ──────────────────────────────────────────────────────────────────────
  Future<void> register({
    required String email,
    String? name,
    int? age,
    double? heightCm,
    double? weightKg,
  }) =>
      api!.register(email: email, name: name, age: age, heightCm: heightCm, weightKg: weightKg);

  Future<void> requestOtp(String email) => api!.requestOtp(email);

  /// Verify OTP → session persisted by ApiClient. Returns true on success.
  Future<void> verifyOtp(String email, String code) async {
    await api!.verifyOtp(email, code);
    _startFlusher();
    notifyListeners();
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) async {
    final u = await api!.patchProfile(fields);
    notifyListeners();
    return u;
  }

  Future<void> signOut() async {
    _keepAlive = false;
    _stopFlusher();
    IosBleRestore.foregroundActive = false;
    await EdgeTracking.stop();
    await IosBleRestore.disarm();
    await engine.disconnect();
    await session!.clear();
    notifyListeners();
  }

  /// Called when the app goes to the background.
  ///
  /// iOS keeps an app alive in the background ONLY while it holds an active BLE
  /// connection with a subscribed characteristic (UIBackgroundModes: bluetooth-central).
  /// So we DELIBERATELY keep the live connection + streams up here instead of
  /// disconnecting — the band keeps pushing notifications, iOS resumes us per
  /// notification, and the drain+upload continue continuously. (The old code called
  /// `engine.disconnect()` here, which made iOS drop the Bluetooth assertion and suspend
  /// us within ~34s, so sync only ever ran when the app was reopened.)
  ///
  /// We still own the band, so the restore central must NOT arm a competing connect.
  /// `BleRestoreManager` is armed only as a RECOVERY path if the connection actually
  /// drops (band out of range / app jettisoned) — see [_onEngineState] / [_armRecovery].
  ///
  /// On Android the Edge Tracking foreground service keeps the process + connection
  /// alive, so the live drain just continues there too.
  Future<void> pauseForBackground() async {
    _background = true;
    if (Platform.isAndroid) {
      // Android: ensure the Edge Tracking foreground service is up (idempotent) so the
      // process + live connection survive backgrounding; the shared flusher keeps
      // uploading. No periodic task, no restore central — the service IS the keep-alive.
      EdgeTracking.start();
      return;
    }
    if (!Platform.isIOS) return;
    if (engine.isConnected) {
      IosBleRestore.foregroundActive = true; // "app owns the band" — don't let restore compete
      await IosBleRestore.setOwnsBand(true);
      _log('Backgrounded — holding live connection for continuous background sync');
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

  /// Start the session-long flusher (idempotent). On a COLD start (no timer yet) it kicks
  /// once immediately so the first session doesn't wait a full interval, then runs every
  /// _kFlushInterval. If the timer is already running — foreground-reclaim or a
  /// mid-session reconnect, since the flusher survives both — this is a no-op and the
  /// already-running timer carries the upload on its next tick (≤_kFlushInterval).
  /// uploadPending() no-ops cheaply when nothing is queued, so the tick is unconditional.
  /// Stopped on session teardown only (logout / signOut / unpair / endSession).
  void _startFlusher() {
    if (_flushTimer != null) return; // already running — timer survives background + reconnect
    if (!uploading) unawaited(upload()); // immediate kick on cold start
    _flushTimer = Timer.periodic(_kFlushInterval, (_) {
      if (!uploading) unawaited(upload());
    });
  }

  void _stopFlusher() {
    _flushTimer?.cancel();
    _flushTimer = null;
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

  Future<void> pairWith(BluetoothDevice d, {String? serial}) async {
    await PairedDevice.save(d.remoteId.str, serial ?? device.serial);
    paired = await PairedDevice.load();
    // Now that there's a band to alert about, ask for notification permission
    // (a natural moment; battery/charging alerts depend on it). Best-effort.
    unawaited(NotificationService.instance.ensurePermission());
    final s = serial ?? device.serial;
    if (config != null &&
        (config!.deviceId.isEmpty || config!.deviceId == 'whoop-unknown') &&
        s != null) {
      config!.deviceId = s;
      await config!.save();
    }
    notifyListeners();
    await openSession();
  }

  Future<void> unpair() async {
    _keepAlive = false;
    _stopFlusher();
    IosBleRestore.foregroundActive = false;
    await EdgeTracking.stop();
    await IosBleRestore.disarm();
    await engine.disconnect();
    await PairedDevice.clear();
    paired = null;
    notifyListeners();
  }

  // ── alarm + strap name (require a live connection) ──────────────────────────
  bool get isConnected => device.connection == 'connected' || device.connection == 'syncing';
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
    if (busy || paired == null || !isAuthenticated) return;
    // Returning to the foreground with the connection still alive (kept during
    // background): don't tear it down and reconnect — just reclaim ownership. The
    // flusher kept running through the background, so uploads are already current;
    // _startFlusher() below is a no-op (timer alive) and no explicit flush is needed.
    final wasBackground = _background;
    _background = false;
    if (wasBackground && engine.isConnected) {
      IosBleRestore.foregroundActive = true;
      await IosBleRestore.setOwnsBand(true);
      EdgeTracking.start(); // Android: keep the foreground service up (idempotent)
      _startFlusher(); // timer was running through background; this is a no-op if so
      return;
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
    _log('===== SESSION START ===== pending=${dbCounts['pending']} raw=${dbCounts['raw']}');
    try {
      if (!await engine.connectToRemoteId(paired!.remoteId)) {
        lastError = 'Could not reach your band. Is it nearby and free '
            '(official WHOOP app force-quit)?';
        return;
      }
      await engine.enableLiveStreams();
      await engine.getBattery();
      await engine.getStrapName(); // populate strap name + alarm for the Profile UI
      await engine.getAlarm();
      _log('Live session active.');

      // Start the session-long flusher (it keeps running after the drain, flushing live
      // records + retrying anything a tick failed to send). Replaces the old
      // drain-scoped timer that stopped once history finished.
      _startFlusher();
      final report = await engine.runSync();
      _log('Drained ${report.records} records in ${report.batches} batches '
          '(${report.complete ? "complete" : "idle-stopped"}).');
      dbCounts = await LocalDb.counts();
      // No explicit upload here — the flusher (kicked on start, then every 60s) is the
      // single upload path; the freshly-drained backlog goes up on its next tick.
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
      // a runner who left their phone behind can be out of range for an hour. The
      // old 5-try (~30s) limit gave up long before they got back, so the band's
      // offline backlog was never pulled until the next manual app open. Capped
      // exponential backoff so we don't hammer the radio.
      int attempt = 0;
      while (_keepAlive && !engine.isConnected) {
        attempt++;
        await Future.delayed(Duration(seconds: (2 * attempt).clamp(2, 30)));
        if (!_keepAlive) break;
        if (await engine.connectToRemoteId(paired!.remoteId)) {
          // Reclaim the band from the iOS restore central so it stops competing.
          if (Platform.isIOS) {
            IosBleRestore.foregroundActive = true;
            await IosBleRestore.setOwnsBand(true);
          }
          _startFlusher();     // ensure live uploads run even on a reconnect-only path
          EdgeTracking.start(); // ensure the Android foreground service is up too
          // FULL drain (no short timeout): pull the ENTIRE offline backlog the band
          // buffered to flash while we were out of range. A 30s cap silently cut a
          // long gap (e.g. a phone-free run) short and lost the rest.
          await engine.runSync();
          await engine.enableLiveStreams();
          dbCounts = await LocalDb.counts();
          // Upload handled by the flusher (single path) — runs within the next tick.
          _log('Reconnected — backlog drained.');
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
      await engine.runSync();
      await engine.enableLiveStreams();
      dbCounts = await LocalDb.counts();
      notifyListeners();
      // Upload handled by the always-running flusher (single path), next tick ≤60s.
    } catch (e) {
      _log('Resync failed: $e');
    }
  }

  Future<void> syncNow() => openSession();

  Future<void> endSession() async {
    _keepAlive = false;
    _stopFlusher();
    await engine.disconnect();
  }

  // ── upload ───────────────────────────────────────────────────────────────────
  bool uploading = false;

  String get status {
    if (uploading) return 'uploading';
    return device.connection;
  }

  Future<void> upload() async {
    if (!isAuthenticated || api == null) {
      _log('Upload skipped — not signed in.');
      return;
    }
    if (uploading) return;
    uploading = true;
    notifyListeners();
    try {
      await _uploadInner();
    } finally {
      uploading = false;
      notifyListeners();
    }
  }

  Future<void> _uploadInner() async {
    final uploader = Uploader(api!);
    final result = await uploader.uploadPending(onChunk: () async {
      dbCounts = await LocalDb.counts();
      notifyListeners();
    });
    if (result.ok) {
      // Suppress the every-tick "0/0" noise — the flusher polls on a steady cadence.
      if (result.attempted > 0) {
        _log('Uploaded ${result.accepted}/${result.attempted} records.');
      }
    } else {
      lastError = 'Upload failed: ${result.error}';
      _log(lastError!);
    }
    final ev = await uploader.uploadEvents();
    if (ev.ok && ev.attempted > 0) {
      _log('Uploaded ${ev.accepted} events.');
    } else if (!ev.ok) {
      _log('Event upload failed: ${ev.error}');
    }
    dbCounts = await LocalDb.counts();
    notifyListeners();
  }

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
  // collect live frames for [spotDuration]s, then POST them to /spotcheck which
  // decodes RR + computes HRV server-side. Ephemeral — nothing is stored.
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
      final res = api == null || frames.isEmpty
          ? null
          : await api!.spotCheck(frames);
      spotResult = res;
      if (res == null) {
        spotError = 'No reading captured — keep the band snug and still.';
      } else if (res['ok'] != true) {
        spotError = 'Not enough clean beats — try again, sitting still.';
      }
    } catch (e) {
      spotError = 'Spot check failed: ${e is ApiException ? e.body : e}';
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
  // Driven by the double-tap dispatcher (lib/gestures). Native actions (media, torch,
  // ring) go over the platform channel; these two act on our own app/backend, so they
  // work on every platform — and a haptic confirms the tap registered.

  /// Double-tap → start a workout if none is live, else end the active one. Mirrors
  /// the UI start/stop flow (api session + local live engine), minus the type picker
  /// (defaults to 'other'; the user can refine it in the app).
  Future<void> _toggleWorkoutFromGesture() async {
    try {
      if (activeWorkout != null) {
        final id = activeWorkout!.workoutId;
        stopWorkout();
        if (id != null) {
          try {
            await api?.endWorkout(id);
          } catch (_) {/* local already stopped; backend trues up on next sync */}
        }
      } else {
        if (api == null) return;
        String? id;
        try {
          final w = await api!.startWorkout('other');
          id = w['workout_id'] as String?;
        } catch (_) {/* still start locally so the user gets the live session */}
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
    final a = api;
    if (a == null) return;
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
        final journal = await a.getJournal(range: '7d');
        final today = journal.firstWhere(
          (r) => r['date'] == date,
          orElse: () => <String, dynamic>{},
        );
        tags = (today['tags'] as List?)?.map((e) => e.toString()).toList() ?? [];
        note = (today['note'] as String?) ?? '';
      } catch (_) {/* fresh day / offline — start clean */}
      tags.add('moment $hhmm');
      await a.postJournal(date, tags, note);
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
      // Calorie burn formula (estimate per second):
      // Male: [(-55.0969 + (0.6309 * HR) + (0.1988 * W) + (0.2017 * A)) / 4.184] / 60
      // Female: [(-20.4022 + (0.4472 * HR) - (0.1263 * W) + (0.074 * A)) / 4.184] / 60
      final u = user ?? {};
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
      
      // Rough strain accumulation (experimental):
      // Simple linear mapping of HRR% (HR Reserve) to strain units per second.
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
  final String? workoutId; // backend session id (for the breakdown on finish)
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
