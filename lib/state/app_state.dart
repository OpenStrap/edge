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
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_status.dart';
import '../ble/ble_engine.dart';
import '../ble/ios_ble_restore.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../net/api_client.dart';
import '../live/live_activity.dart';
import '../sync/config.dart';
import '../sync/edge_tracking.dart';
import '../widget/widget_service.dart';
import '../sync/file_log.dart';
import '../sync/uploader.dart';

class AppState extends ChangeNotifier {
  late final BleEngine engine;
  BackendConfig? config;
  Session? session;
  ApiClient? api;
  PairedDevice? paired;

  DeviceState get device => engine.state;
  Sample? lastSynced;
  Map<String, int> dbCounts = {'raw': 0, 'pending': 0};
  final List<String> logLines = [];
  String? lastError;
  bool busy = false;

  bool _keepAlive = false;
  bool _reconnecting = false;
  String _prevConn = 'disconnected';
  bool initialized = false;

  /// True while the app is backgrounded. On iOS we KEEP the BLE connection alive in
  /// this state (see [pauseForBackground]) so the OS keeps resuming us per BLE
  /// notification and the live drain + flush continue.
  bool _background = false;

  /// One session-long flusher. It uploads pending raw records on a steady cadence and,
  /// because the uploader RETAINS rows on any non-200 (a transient rate-limit 429
  /// included), each tick also retries whatever the last tick couldn't send. No
  /// per-record flushing and no backoff/cooldown — a plain ~15s cadence sits well under
  /// the backend rate limit (burst 30, refill 0.5/s) on its own. On iOS the timer simply
  /// fires on the next BLE-notification resume when the app was suspended.
  Timer? _flushTimer;
  static const Duration _kFlushInterval = Duration(seconds: 15);

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
    engine = BleEngine(
      onRecord: _onRecord,
      onState: _onEngineState,
      log: _log,
      onEvent: (id, ts, hex) => LocalDb.insertEvent(id, ts, hex),
      onRecordsBatch: LocalDb.insertRecordsBatch,
    );
    _init();
  }

  Future<void> _init() async {
    config = await BackendConfig.load();
    session = await Session.load();
    paired = await PairedDevice.load();
    _rebuildApi();
    lastSynced = await LocalDb.latestSample();
    dbCounts = await LocalDb.counts();
    _savedAlarm = (await SharedPreferences.getInstance()).getInt('alarm_epoch');
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
    await LocalDb.insertRecord(raw, sample);
  }

  /// Start the session-long flusher (idempotent). Cancelled on disconnect / sign-out.
  void _startFlusher() {
    _flushTimer ??= Timer.periodic(_kFlushInterval, (_) {
      if (!uploading) unawaited(upload());
    });
  }

  void _stopFlusher() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _onEngineState(DeviceState s) {
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
    // background): don't tear it down and reconnect — just reclaim ownership and flush.
    final wasBackground = _background;
    _background = false;
    if (wasBackground && engine.isConnected) {
      IosBleRestore.foregroundActive = true;
      await IosBleRestore.setOwnsBand(true);
      EdgeTracking.start(); // Android: keep the foreground service up (idempotent)
      _startFlusher();
      unawaited(upload());
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
      await upload();
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
      for (int attempt = 1; attempt <= 5 && _keepAlive; attempt++) {
        await Future.delayed(Duration(seconds: 2 * attempt));
        if (!_keepAlive) break;
        if (await engine.connectToRemoteId(paired!.remoteId)) {
          // Reclaim the band from the iOS restore central so it stops competing.
          if (Platform.isIOS) {
            IosBleRestore.foregroundActive = true;
            await IosBleRestore.setOwnsBand(true);
          }
          _startFlusher();     // ensure live uploads run even on a reconnect-only path
          EdgeTracking.start(); // ensure the Android foreground service is up too
          await engine.runSync(timeout: const Duration(seconds: 30));
          await upload();
          await engine.enableLiveStreams();
          _log('Reconnected.');
          break;
        }
      }
    } catch (e) {
      _log('Reconnect failed: $e');
    } finally {
      _reconnecting = false;
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
