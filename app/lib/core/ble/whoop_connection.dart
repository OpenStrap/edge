import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../protocol/whoop_protocol.dart';
import '../services/local_storage.dart';
import '../services/health_analytics.dart';
import '../services/api_client.dart';

// ── Phase ─────────────────────────────────────────────────────────────────────

enum WhoopConnectionPhase {
  idle, scanning, connecting, discoveringServices,
  subscribing, initializing, syncing, realtime,
  disconnected, error,
}

// ── State ─────────────────────────────────────────────────────────────────────

class WhoopConnectionState {
  final WhoopConnectionPhase phase;
  final String? deviceName;
  final int? rssi;
  final int batchCount;
  final int? heartRate;
  final bool? wristOn;
  final double? batteryPct;
  final bool? charging;
  final double? tempC;
  final String? serial;
  final String? advertisingName;
  final List<double> hrHistory;
  final R21Packet? lastR21;
  final R10Packet? lastR10;
  final String? errorMessage;
  final double? hrv;
  final double? spo2;
  final double? recoveryScore;
  final double? accelMagnitude;
  final DateTime? lastDoubleTap;
  // Backend-derived insights
  final Map<String, dynamic>? insights;
  final bool backendOnline;

  const WhoopConnectionState({
    this.phase = WhoopConnectionPhase.idle,
    this.deviceName,
    this.rssi,
    this.batchCount = 0,
    this.heartRate,
    this.wristOn,
    this.batteryPct,
    this.charging,
    this.tempC,
    this.serial,
    this.advertisingName,
    this.hrHistory = const [],
    this.lastR21,
    this.lastR10,
    this.errorMessage,
    this.hrv,
    this.spo2,
    this.recoveryScore,
    this.accelMagnitude,
    this.lastDoubleTap,
    this.insights,
    this.backendOnline = false,
  });

  static const _absent = Object();

  WhoopConnectionState copyWith({
    WhoopConnectionPhase? phase,
    String? deviceName,
    int? rssi,
    int? batchCount,
    int? heartRate,
    Object? wristOn = _absent,
    Object? batteryPct = _absent,
    Object? charging = _absent,
    Object? tempC = _absent,
    Object? serial = _absent,
    Object? advertisingName = _absent,
    List<double>? hrHistory,
    Object? lastR21 = _absent,
    Object? lastR10 = _absent,
    Object? errorMessage = _absent,
    Object? hrv = _absent,
    Object? spo2 = _absent,
    Object? recoveryScore = _absent,
    Object? accelMagnitude = _absent,
    Object? lastDoubleTap = _absent,
    Object? insights = _absent,
    bool? backendOnline,
  }) => WhoopConnectionState(
    phase: phase ?? this.phase,
    deviceName: deviceName ?? this.deviceName,
    rssi: rssi ?? this.rssi,
    batchCount: batchCount ?? this.batchCount,
    heartRate: heartRate ?? this.heartRate,
    wristOn: identical(wristOn, _absent) ? this.wristOn : wristOn as bool?,
    batteryPct: identical(batteryPct, _absent) ? this.batteryPct : batteryPct as double?,
    charging: identical(charging, _absent) ? this.charging : charging as bool?,
    tempC: identical(tempC, _absent) ? this.tempC : tempC as double?,
    serial: identical(serial, _absent) ? this.serial : serial as String?,
    advertisingName: identical(advertisingName, _absent) ? this.advertisingName : advertisingName as String?,
    hrHistory: hrHistory ?? this.hrHistory,
    lastR21: identical(lastR21, _absent) ? this.lastR21 : lastR21 as R21Packet?,
    lastR10: identical(lastR10, _absent) ? this.lastR10 : lastR10 as R10Packet?,
    errorMessage: identical(errorMessage, _absent) ? this.errorMessage : errorMessage as String?,
    hrv: identical(hrv, _absent) ? this.hrv : hrv as double?,
    spo2: identical(spo2, _absent) ? this.spo2 : spo2 as double?,
    recoveryScore: identical(recoveryScore, _absent) ? this.recoveryScore : recoveryScore as double?,
    accelMagnitude: identical(accelMagnitude, _absent) ? this.accelMagnitude : accelMagnitude as double?,
    lastDoubleTap: identical(lastDoubleTap, _absent) ? this.lastDoubleTap : lastDoubleTap as DateTime?,
    insights: identical(insights, _absent) ? this.insights : insights as Map<String, dynamic>?,
    backendOnline: backendOnline ?? this.backendOnline,
  );

  String get phaseLabel {
    switch (phase) {
      case WhoopConnectionPhase.idle:               return 'Ready';
      case WhoopConnectionPhase.scanning:           return 'Scanning';
      case WhoopConnectionPhase.connecting:         return 'Connecting';
      case WhoopConnectionPhase.discoveringServices: return 'Discovering';
      case WhoopConnectionPhase.subscribing:        return 'Subscribing';
      case WhoopConnectionPhase.initializing:       return 'Initializing';
      case WhoopConnectionPhase.syncing:            return 'Syncing';
      case WhoopConnectionPhase.realtime:           return 'Live';
      case WhoopConnectionPhase.disconnected:       return 'Disconnected';
      case WhoopConnectionPhase.error:              return 'Error';
    }
  }

  bool get isConnected =>
      phase == WhoopConnectionPhase.realtime ||
      phase == WhoopConnectionPhase.syncing;

  bool get isLive => phase == WhoopConnectionPhase.realtime;

  bool get isConnecting =>
      phase == WhoopConnectionPhase.connecting ||
      phase == WhoopConnectionPhase.discoveringServices ||
      phase == WhoopConnectionPhase.subscribing ||
      phase == WhoopConnectionPhase.initializing ||
      phase == WhoopConnectionPhase.syncing;
}

// ── Manager ───────────────────────────────────────────────────────────────────

class WhoopConnectionManager {
  static const _svcChannel = MethodChannel('com.whoopconnect.whoop_connect/service');

  final _stateCtrl = StreamController<WhoopConnectionState>.broadcast();
  Stream<WhoopConnectionState> get stateStream => _stateCtrl.stream;

  WhoopConnectionState _state = const WhoopConnectionState();
  WhoopConnectionState get currentState => _state;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription? _scanSub;
  final List<StreamSubscription> _notifSubs = [];
  LocalStorageService? _storage;
  final HealthAnalytics _analytics = HealthAnalytics();

  // Protocol state
  final _reassemblers = <String, FrameReassembler>{};
  int _initIdx = 0;
  int _cmdSeq = 0xA0;
  int _batchCounter = 5;
  bool _realtimeStarted = false;
  bool _hapticSent = false;

  // Backend ingest throttle — send at most once per second
  Timer? _ingestTimer;
  Timer? _insightsTimer;

  WhoopConnectionManager() {
    Future.microtask(() => _emit(_state));
    _checkBackend();
    // Handle haptic trigger from Android NotificationListenerService
    _svcChannel.setMethodCallHandler((call) async {
      if (call.method == 'onHapticNotification') {
        sendHaptic();
      }
    });
  }

  void _emit(WhoopConnectionState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  void setStorageService(LocalStorageService storage) => _storage = storage;

  ({String key, String name})? getLastConnectedDevice() {
    final key = _storage?.getLastDeviceKey();
    final name = _storage?.getLastDeviceName();
    if (key != null && name != null) return (key: key, name: name);
    return null;
  }

  Future<void> _checkBackend() async {
    final ok = await ApiClient.isReachable();
    _emit(_state.copyWith(backendOnline: ok));
    if (ok) _fetchInsights();
  }

  Future<void> _fetchInsights() async {
    final data = await ApiClient.fetchTodayInsights();
    if (data != null) _emit(_state.copyWith(insights: data));
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> startScan() async {
    await FlutterBluePlus.stopScan();
    _emit(_state.copyWith(phase: WhoopConnectionPhase.scanning));
    _scanSub = FlutterBluePlus.scanResults.listen((_) {});
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (_state.phase == WhoopConnectionPhase.scanning) {
      _emit(_state.copyWith(phase: WhoopConnectionPhase.idle));
    }
  }

  Future<void> connectToDevice(BluetoothDevice device, int rssi) async {
    _connectTo(device, rssi);
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _cleanup();
    _emit(const WhoopConnectionState(phase: WhoopConnectionPhase.disconnected));
    _stopForegroundService();
  }

  Future<void> sendHaptic() async {
    final char = _cmdChar;
    if (char == null) return;
    await _write(char, buildPacket(_cmdSeq++, cmdRunHapticsPatternHarvard, [0x02, 0x00, 0x00, 0x00, 0x00]));
    await _write(char, buildPacket(_cmdSeq++, cmdRunHapticsPatternMaverick,
        [0x01, 0x2F, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]));
  }

  Future<void> refreshInsights() => _fetchInsights();

  // ── Connection flow ───────────────────────────────────────────────────────

  Future<void> _connectTo(BluetoothDevice device, int rssi) async {
    if (_device != null) return;
    await _scanSub?.cancel();
    await FlutterBluePlus.stopScan();

    _device = device;
    _emit(_state.copyWith(
      phase: WhoopConnectionPhase.connecting,
      deviceName: device.platformName,
      rssi: rssi,
    ));

    device.connectionState.listen((cs) {
      if (cs == BluetoothConnectionState.disconnected) _onDisconnected();
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      if (_storage != null) {
        await _storage!.saveLastDevice(device.remoteId.str, device.platformName);
      }
      await device.requestMtu(512);
      _emit(_state.copyWith(phase: WhoopConnectionPhase.discoveringServices));
      await _discoverAndSubscribe(device);
    } catch (e) {
      _emit(_state.copyWith(
          phase: WhoopConnectionPhase.error, errorMessage: e.toString()));
      _cleanup();
    }
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothService? whoopService;

      // Try exact UUID match first
      for (final s in services) {
        if (s.uuid.str128.toLowerCase() == kWhoopServiceUuid.toLowerCase()) {
          whoopService = s;
          break;
        }
      }
      // Fallback: find by CMD_TO_STRAP characteristic
      if (whoopService == null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            if (c.uuid.str128.toLowerCase() == kCmdToStrapUuid.toLowerCase()) {
              whoopService = s;
              break;
            }
          }
          if (whoopService != null) break;
        }
      }
      // Fallback 2: short UUID prefix
      if (whoopService == null) {
        for (final s in services) {
          if (s.uuid.str.toLowerCase().startsWith('61080001')) {
            whoopService = s;
            break;
          }
        }
      }

      if (whoopService == null) {
        _emit(_state.copyWith(
            phase: WhoopConnectionPhase.error,
            errorMessage: 'WHOOP service not found'));
        return;
      }

      _emit(_state.copyWith(phase: WhoopConnectionPhase.subscribing));

      int confirmed = 0;
      for (final char in whoopService.characteristics) {
        final uuid = char.uuid.str128.toLowerCase();
        if (uuid == kCmdToStrapUuid.toLowerCase() ||
            char.uuid.str.toLowerCase().startsWith('61080002')) {
          _cmdChar = char;
        }
        if (char.properties.notify) {
          _reassemblers[uuid] = FrameReassembler();
          try {
            await char.setNotifyValue(true);
            _notifSubs.add(char.onValueReceived.listen((d) => _onData(char, d)));
            confirmed++;
          } catch (_) {}
        }
      }

      if (confirmed > 0) {
        _startInit();
      } else {
        _emit(_state.copyWith(
            phase: WhoopConnectionPhase.error,
            errorMessage: 'No notifications subscribed'));
      }
    } catch (e) {
      _emit(_state.copyWith(
          phase: WhoopConnectionPhase.error,
          errorMessage: 'Discovery failed: $e'));
    }
  }

  void _startInit() {
    if (_initIdx > 0) return;
    _emit(_state.copyWith(phase: WhoopConnectionPhase.initializing));
    _sendInitPacket(0);
  }

  Future<void> _sendInitPacket(int idx) async {
    if (idx >= kInitPackets.length) return;
    final char = _cmdChar;
    if (char == null) return;
    try {
      await _write(char, kInitPackets[idx]);
      _initIdx = idx + 1;
      await Future.delayed(const Duration(milliseconds: 100));
      if (_initIdx < kInitPackets.length) await _sendInitPacket(_initIdx);
    } catch (e) {
      _emit(_state.copyWith(
          phase: WhoopConnectionPhase.error, errorMessage: 'Init failed: $e'));
    }
  }

  Future<void> _enableRealtime() async {
    final char = _cmdChar;
    if (char == null || _realtimeStarted) return;
    _realtimeStarted = true;

    await _write(char, buildPacket(_cmdSeq++, cmdToggleRealtimeHr, [0x01]));
    await Future.delayed(const Duration(milliseconds: 50));
    await _write(char, buildPacket(_cmdSeq++, cmdSendR10R11Realtime, [0x01]));
    await Future.delayed(const Duration(milliseconds: 50));
    await _write(char, buildPacket(_cmdSeq++, cmdTogglePersistentR21, [0x01]));
    await Future.delayed(const Duration(milliseconds: 100));
    await _write(char, buildPacket(_cmdSeq++, cmdToggleOpticalMode, [0x01]));

    _emit(_state.copyWith(phase: WhoopConnectionPhase.realtime));
    _startForegroundService();

    // Fetch backend insights when we go live
    _fetchInsights();

    // Periodic insights refresh every 5 minutes
    _insightsTimer?.cancel();
    _insightsTimer = Timer.periodic(const Duration(minutes: 5), (_) => _fetchInsights());

    // Start backend ingest timer
    _ingestTimer?.cancel();
    _ingestTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendToBackend());
  }

  void _sendToBackend() {
    final s = _state;
    if (!s.isLive) return;
    ApiClient.ingest(
      hr: s.heartRate,
      hrv: s.hrv,
      spo2: s.spo2,
      tempC: s.tempC,
      batteryPct: s.batteryPct,
      charging: s.charging,
      accelMag: s.accelMagnitude,
      wristOn: s.wristOn,
    );
  }

  // ── Incoming data ─────────────────────────────────────────────────────────

  void _onData(BluetoothCharacteristic char, List<int> data) {
    final uuid = char.uuid.str128.toLowerCase();
    final reassembler = _reassemblers.putIfAbsent(uuid, FrameReassembler.new);
    final frame = reassembler.feed(data);
    if (frame == null) return;
    final packet = decodeFrame(frame);
    if (packet != null) _handlePacket(packet);
  }

  void _handlePacket(WhoopPacket packet) {
    switch (packet) {
      case BatchMarkerPacket(:final batchN):
        final char = _cmdChar;
        if (char != null) _write(char, buildBatchAck(_batchCounter++, batchN));
        _emit(_state.copyWith(
          phase: WhoopConnectionPhase.syncing,
          batchCount: _batchCounter - 5,
        ));

      case EndOfSyncPacket():
        if (!_hapticSent) {
          _hapticSent = true;
          sendHaptic();
        }
        _enableRealtime();

      case HelloHarvardPacket(
          :final batteryPct, :final charging, :final serial, :final wristStatus):
        _emit(_state.copyWith(
          batteryPct: batteryPct,
          charging: charging,
          serial: serial,
          wristOn: wristStatus == WristStatus.onWrist ? true
              : wristStatus == WristStatus.offWrist ? false : null,
        ));

      case CmdResponsePacket(:final extra, cmd: 0x4C):
        if (extra != null) _emit(_state.copyWith(advertisingName: extra));

      case EventPacket(:final eventType, :final batteryPct, :final tempC):
        var next = _state;
        if (eventType == 3 && batteryPct != null) next = next.copyWith(batteryPct: batteryPct);
        if (eventType == 7) next = next.copyWith(charging: true);
        if (eventType == 8) next = next.copyWith(charging: false);
        if (eventType == 9) next = next.copyWith(wristOn: true);
        if (eventType == 10) next = next.copyWith(wristOn: false);
        if (eventType == 17 && tempC != null) next = next.copyWith(tempC: tempC);
        if (eventType == 14) {
          next = next.copyWith(lastDoubleTap: DateTime.now());
          _handleDoubleTap();
        }
        if (next != _state) _emit(next);

      case R10Packet(:final heartRate, :final isRealtime, :final accelX, :final accelY, :final accelZ):
        if (isRealtime && heartRate > 0) {
          _analytics.addHeartRate(heartRate);
          final hrv = _analytics.computeHrv();
          final history = [..._state.hrHistory, heartRate.toDouble()];
          final trimmed = history.length > 120 ? history.sublist(history.length - 120) : history;
          final accel = HealthAnalytics.computeAccelMagnitude(
              accelX?.toList(), accelY?.toList(), accelZ?.toList());
          _emit(_state.copyWith(
            heartRate: heartRate,
            lastR10: packet,
            hrHistory: trimmed,
            hrv: hrv,
            accelMagnitude: accel,
          ));
          _updateForegroundNotification(heartRate);
        }

      case R21Packet(:final channelC, :final channelF):
        final spo2 = HealthAnalytics.computeSpo2(channelC, channelF);
        _emit(_state.copyWith(lastR21: packet, spo2: spo2));

      default:
        break;
    }
  }

  void _handleDoubleTap() {
    _svcChannel.invokeMethod('onDoubleTap').catchError((_) {});
  }

  // ── Android service bridge ────────────────────────────────────────────────

  void _startForegroundService() {
    _svcChannel.invokeMethod('startForegroundService').catchError((_) {});
  }

  void _stopForegroundService() {
    _svcChannel.invokeMethod('stopForegroundService').catchError((_) {});
  }

  void _updateForegroundNotification(int hr) {
    _svcChannel.invokeMethod('updateNotification', {'heartRate': hr}).catchError((_) {});
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _write(BluetoothCharacteristic char, List<int> data) async {
    try {
      await char.write(data, withoutResponse: false);
    } catch (_) {}
  }

  void _onDisconnected() {
    _cleanup();
    _emit(const WhoopConnectionState(phase: WhoopConnectionPhase.disconnected));
    _stopForegroundService();
  }

  void _cleanup() {
    for (final sub in _notifSubs) sub.cancel();
    _notifSubs.clear();
    _scanSub?.cancel();
    _scanSub = null;
    _device = null;
    _cmdChar = null;
    _reassemblers.clear();
    _initIdx = 0;
    _cmdSeq = 0xA0;
    _batchCounter = 5;
    _realtimeStarted = false;
    _hapticSent = false;
    _ingestTimer?.cancel();
    _insightsTimer?.cancel();
    _analytics.reset();
  }

  void dispose() {
    _cleanup();
    _stateCtrl.close();
  }
}
