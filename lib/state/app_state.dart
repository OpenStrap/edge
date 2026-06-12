// AppState — the single ChangeNotifier the UI listens to. Orchestrates auth,
// the BLE engine, local DB writes (raw-first), and per-user cloud upload.
//
// Onboarding gate (see app.dart):
//   backend not chosen → BackendChoice
//   not authenticated  → Auth → OTP
//   not paired         → Pairing (LOCAL device pref; re-pair after every sign-in)
//   else               → main Shell (auto-connect saved band, drain, live, upload)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_engine.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../net/api_client.dart';
import '../live/live_activity.dart';
import '../sync/background_sync.dart';
import '../sync/config.dart';
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

  AppState() {
    engine = BleEngine(
      onRecord: _onRecord,
      onState: _onEngineState,
      log: _log,
      onEvent: (id, ts, hex) => LocalDb.insertEvent(id, ts, hex),
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
    notifyListeners();
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) async {
    final u = await api!.patchProfile(fields);
    notifyListeners();
    return u;
  }

  Future<void> signOut() async {
    _keepAlive = false;
    await BackgroundSync.disable();
    await engine.disconnect();
    await session!.clear();
    notifyListeners();
  }

  Future<void> _onRecord(Sample? sample, RawRecord raw) async {
    await LocalDb.insertRecord(raw, sample);
  }

  void _onEngineState(DeviceState s) {
    if (_prevConn != 'disconnected' && s.connection == 'disconnected') {
      if (_keepAlive && isPaired && !_reconnecting) {
        _log('Connection dropped — reconnecting…');
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
    await BackgroundSync.disable();
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
    _setBusy(true);
    lastError = null;
    _keepAlive = true;
    // Keep syncing in the background even when the app isn't open (no foreground
    // service / notification). Idempotent — safe to call on every session start.
    BackgroundSync.enable();
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

      final flush = Timer.periodic(const Duration(seconds: 15), (_) => upload());
      late final SyncReport report;
      try {
        report = await engine.runSync();
      } finally {
        flush.cancel();
      }
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
      _log('Uploaded ${result.accepted}/${result.attempted} records.');
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

  void startWorkout({double targetKcal = 300}) {
    if (activeWorkout != null) return;
    final start = DateTime.now();
    activeWorkout = LiveWorkoutState(
      startTime: start,
      targetKcal: targetKcal,
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
  Duration elapsed = Duration.zero;
  double calories = 0.0;
  double strain = 0.0;
  int currentHr = 0;

  LiveWorkoutState({required this.startTime, required this.targetKcal});
}
