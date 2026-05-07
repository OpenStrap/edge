import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whoopsie_protocol/whoopsie_protocol.dart';

import '../config.dart';

enum LinkState { idle, scanning, connecting, bonding, handshake, live, disconnected, error }

class _Write {
  final Uint8List data;
  final bool fast;
  _Write(this.data, this.fast);
}

class WhoopBleService {
  // ── Public streams ──────────────────────────────────────────────────────
  final _stateC = StreamController<LinkState>.broadcast();
  final _logC = StreamController<String>.broadcast();
  final _idC = StreamController<WhoopIdentity>.broadcast();
  final _evtC = StreamController<WhoopEvent>.broadcast();
  final _hrC = StreamController<HrSample>.broadcast();
  final _ppgC = StreamController<PpgSample>.broadcast();
  final _rrC = StreamController<RrSample>.broadcast();
  final _r24C = StreamController<RecoverySummary>.broadcast();
  final _battC = StreamController<double>.broadcast();
  final _syncC = StreamController<({int acked, int inBatch})>.broadcast();

  Stream<LinkState> get state => _stateC.stream;
  Stream<String> get log => _logC.stream;
  Stream<WhoopIdentity> get identity => _idC.stream;
  Stream<WhoopEvent> get events => _evtC.stream;
  Stream<HrSample> get hr => _hrC.stream;
  Stream<PpgSample> get ppg => _ppgC.stream;
  Stream<RrSample> get rr => _rrC.stream;
  Stream<RecoverySummary> get r24 => _r24C.stream;
  Stream<double> get battery => _battC.stream;
  Stream<({int acked, int inBatch})> get sync => _syncC.stream;

  WhoopIdentity? lastIdentity;

  // ── Internals ───────────────────────────────────────────────────────────
  static const _kSavedDeviceId = 'whoopsie_ble_id';

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdTo;
  StreamSubscription? _connSub;
  final List<StreamSubscription> _subs = [];
  final Map<String, FrameReassembler> _reasm = {};

  int _initIdx = 0;
  bool _haptic = false;
  int _cmdSeq = 0xA0;
  int _batchCounter = 5;
  int _ackedBatches = 0;
  int _inBatch = 0;
  Timer? _heartbeat;
  Timer? _batteryPoll;
  bool _disposed = false;

  final List<_Write> _writeQ = [];
  bool _draining = false;

  void _logMsg(String m) {
    if (!_logC.isClosed) _logC.add(m);
  }

  void _set(LinkState s) {
    _state = s;
    if (!_stateC.isClosed) _stateC.add(s);
  }

  // ── Public API ──────────────────────────────────────────────────────────

  Future<String?> getSavedBleId() async =>
      (await SharedPreferences.getInstance()).getString(_kSavedDeviceId);

  Future<void> _saveBleId(String id) async =>
      (await SharedPreferences.getInstance()).setString(_kSavedDeviceId, id);

  Future<void> forgetSavedDevice() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSavedDeviceId);
    await disconnect();
  }

  /// Scan for nearby WHOOP straps. Filters by service UUID + name.
  Future<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 12)}) async {
    _set(LinkState.scanning);
    _logMsg('Scanning…');
    final found = <ScanResult>[];
    final sub = FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        final svcMatch = r.advertisementData.serviceUuids
            .any((u) => WhoopsieUuids.isWhoopService(u.toString()));
        final nameMatch = r.device.platformName.toLowerCase().contains('whoop');
        if ((svcMatch || nameMatch) &&
            !found.any((e) => e.device.remoteId == r.device.remoteId)) {
          found.add(r);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await Future.delayed(timeout);
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    if (_state == LinkState.scanning) _set(LinkState.idle);
    return found;
  }

  LinkState _state = LinkState.idle;

  /// Connect to a specific BLE device (by remoteId). On Android also calls
  /// `createBond()` which triggers the system pair dialog. On iOS pairing is
  /// implicit on the first encrypted write.
  Future<bool> connect(BluetoothDevice device) async {
    _disposed = false;
    _device = device;
    _set(LinkState.connecting);
    _logMsg('Connecting ${device.platformName}…');
    try {
      await device.connect(timeout: const Duration(seconds: 20), autoConnect: false);
    } catch (e) {
      _logMsg('Connect failed: $e');
      _set(LinkState.error);
      return false;
    }

    _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && !_disposed) {
        _logMsg('Disconnected. Reconnecting in 2s.');
        _set(LinkState.disconnected);
        _resetSession();
        Future.delayed(const Duration(seconds: 2), () {
          if (!_disposed && _device != null) connect(_device!);
        });
      }
    });

    if (Platform.isAndroid) {
      _set(LinkState.bonding);
      _logMsg('Requesting bond — accept the system pair dialog if prompted.');
      try {
        await device.createBond();
      } catch (e) {
        _logMsg('createBond: $e');
      }
      try {
        await device.requestMtu(247);
      } catch (_) {}
    }

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.serviceUuid.toString().toLowerCase().contains('61080001'),
      orElse: () => throw Exception('WHOOP service not found'),
    );
    _cmdTo = null;
    for (final c in svc.characteristics) {
      final u = c.characteristicUuid.toString().toLowerCase();
      if (u.contains('0002')) {
        _cmdTo = c;
      } else if (RegExp('0003|0004|0005|0007').hasMatch(u)) {
        try {
          await c.setNotifyValue(true);
          _reasm[u] = FrameReassembler();
          _subs.add(c.onValueReceived.listen((d) => _onData(u, Uint8List.fromList(d))));
        } catch (e) {
          _logMsg('notify($u) failed: $e');
        }
      }
    }
    if (_cmdTo == null) {
      _logMsg('cmdToStrap missing — abort');
      _set(LinkState.error);
      return false;
    }

    await _saveBleId(device.remoteId.str);
    _set(LinkState.handshake);
    _logMsg('Handshaking…');
    _initIdx = 0;
    _stepInit();
    _startHeartbeat();
    return true;
  }

  Future<void> disconnect() async {
    _disposed = true;
    _heartbeat?.cancel();
    _batteryPoll?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _resetSession();
    _set(LinkState.idle);
  }

  void _resetSession() {
    _initIdx = 0;
    _haptic = false;
    _cmdSeq = 0xA0;
    _batchCounter = 5;
    _ackedBatches = 0;
    _inBatch = 0;
    _writeQ.clear();
    _reasm.clear();
    _cmdTo = null;
  }

  // ── Heartbeat + battery poll ────────────────────────────────────────────
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(Config.linkHeartbeatInterval, (_) {
      if (_cmdTo != null) {
        _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.linkValid, [0x00]));
      }
    });
  }

  void _startBatteryPoll() {
    _batteryPoll?.cancel();
    _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.getBatteryLevel));
    _batteryPoll = Timer.periodic(Config.batteryPollInterval, (_) {
      if (_cmdTo != null) {
        _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.getBatteryLevel));
      }
    });
  }

  // ── INIT sequence ───────────────────────────────────────────────────────
  void _stepInit() {
    if (_initIdx >= kInitPackets.length) {
      _logMsg('INIT complete — awaiting end-of-sync metadata.');
      return;
    }
    final pkt = kInitPackets[_initIdx];
    _logMsg('init [${_initIdx + 1}/5]');
    _initIdx++;
    _enqueue(pkt, then: _stepInit);
  }

  void _enableLive() {
    _enqueue(WhoopFrame.buildCommand(
        _cmdSeq++ & 0xFF, WhoopCmd.runHapticsPattern, [0x02, 0x00, 0x00, 0x00, 0x00]));
    _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.toggleHr, [0x01]));
    _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.sendR10R11Realtime, [0x01]));
    _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.togglePersistentR21, [0x01]));
    _enqueue(WhoopFrame.buildCommand(_cmdSeq++ & 0xFF, WhoopCmd.toggleOpticalMode, [0x01]));
    _logMsg('Live streams enabled.');
    _set(LinkState.live);
    _startBatteryPoll();
  }

  // ── Write queue ─────────────────────────────────────────────────────────
  void _enqueue(Uint8List data, {bool fast = false, void Function()? then}) {
    _writeQ.add(_Write(data, fast));
    _drain(then);
  }

  Future<void> _drain([void Function()? thenLast]) async {
    if (_draining || _writeQ.isEmpty || _cmdTo == null) return;
    _draining = true;
    while (_writeQ.isNotEmpty) {
      final w = _writeQ.removeAt(0);
      try {
        await _cmdTo!.write(w.data, withoutResponse: w.fast);
      } catch (e) {
        _logMsg('write err: $e');
      }
      await Future.delayed(Duration(milliseconds: w.fast ? 20 : 80));
    }
    _draining = false;
    if (thenLast != null) thenLast();
  }

  // ── Inbound data ────────────────────────────────────────────────────────
  void _onData(String charUuid, Uint8List bytes) {
    final reasm = _reasm[charUuid] ?? FrameReassembler();
    _reasm[charUuid] = reasm;
    for (final frame in reasm.feed(bytes)) {
      _decode(frame);
    }
  }

  void _decode(Uint8List frame) {
    final marker = parseBatchMarker(frame);
    if (marker != null) {
      _enqueue(WhoopFrame.buildBatchAck(_batchCounter, marker.bytes), fast: true);
      _ackedBatches++;
      _batchCounter = (_batchCounter + 1) & 0xFF;
      _inBatch = 0;
      _syncC.add((acked: _ackedBatches, inBatch: _inBatch));
      _logMsg('ACK batch #$_ackedBatches');
      return;
    }
    final p = WhoopFrame.unwrap(frame);
    if (p == null || p.isEmpty) return;
    final t = p[0];

    if (t == PktType.event) {
      final e = parseEvent(p);
      if (e != null) _evtC.add(e);
    } else if (t == PktType.metadata) {
      // End-of-sync — kick off live streams if not already.
      if (!_haptic) {
        _haptic = true;
        _enableLive();
      }
    } else if (t == PktType.response) {
      if (p.length >= 3) {
        final cmd = p[2];
        if (cmd == WhoopCmd.getHelloHarvard && p.length >= 4) {
          final id = parseHello(Uint8List.sublistView(p, 3));
          if (id != null) {
            lastIdentity = id;
            _idC.add(id);
          }
        } else if (cmd == WhoopCmd.getBatteryLevel) {
          final pct = parseBatteryResponse(p);
          if (pct != null) _battC.add(pct);
        }
      }
    } else if (t == PktType.realtime || t == PktType.realtimeRaw || t == PktType.historical) {
      if (p.length < 2) return;
      final rec = p[1];
      if (rec == 10) {
        final s = parseR10(p);
        if (s != null) _hrC.add(s);
      } else if (rec == 21) {
        final s = parseR21(p);
        if (s != null) _ppgC.add(s);
      } else if (rec == 2) {
        final s = parseR2(p);
        if (s != null) _ppgC.add(s);
      } else if (rec == 24) {
        final s = parseR24(p);
        if (s != null) _r24C.add(s);
      } else if (rec == 25) {
        final s = parseR25(p);
        if (s != null) _rrC.add(s);
      }
      if (t == PktType.historical) {
        _inBatch++;
        _syncC.add((acked: _ackedBatches, inBatch: _inBatch));
      }
    }
  }
}

final bleServiceProvider = Provider<WhoopBleService>((ref) {
  final s = WhoopBleService();
  ref.onDispose(() => s.disconnect());
  return s;
});
