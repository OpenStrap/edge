import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/ble_service.dart';
import '../config.dart';
import 'api.dart';

/// Drains incoming BLE samples to the backend in 30-second batches.
/// Buffers in-memory; if the network fails, the next flush retries with the
/// accumulated payload. Loses data only on app kill (acceptable for v1; v2
/// can add a Drift cache).
class SyncWorker {
  final WhoopBleService _ble;
  final WhoopsieApi _api;
  Timer? _timer;
  String? _deviceId;

  final List<Map<String, dynamic>> _events = [];
  final List<Map<String, dynamic>> _hr = [];
  final List<Map<String, dynamic>> _ppg = [];
  final List<Map<String, dynamic>> _r24 = [];
  final List<Map<String, dynamic>> _r25 = [];

  final List<StreamSubscription> _subs = [];

  SyncWorker(this._ble, this._api);

  void start({String? deviceId}) {
    _deviceId = deviceId;
    _timer?.cancel();
    _timer = Timer.periodic(Config.syncInterval, (_) => _flush());
    _subs.add(_ble.events.listen((e) => _events.add({
          'ts': e.ts.millisecondsSinceEpoch ~/ 1000,
          'event_id': e.id,
          if (e.detail.isNotEmpty) 'detail': e.detail,
        })));
    _subs.add(_ble.hr.listen((s) => _hr.add({
          'ts': s.ts.millisecondsSinceEpoch ~/ 1000,
          'bpm': s.hr,
          'gsr': s.gsr,
        })));
    _subs.add(_ble.ppg.listen((s) => _ppg.add({
          'ts': s.ts.millisecondsSinceEpoch ~/ 1000,
          'led_drive': s.ledDrive,
          'ir': s.ir,
          'red': s.red,
          if (s.spo2 != null) 'spo2': s.spo2,
        })));
    _subs.add(_ble.r24.listen((r) => _r24.add({
          'ts': r.ts.millisecondsSinceEpoch ~/ 1000,
          'score': r.score,
          'hrv_ms': r.hrvMs,
          'resp_rate_per_min': r.respRatePerMin,
          'skin_temp_delta_c': r.skinTempDeltaC,
        })));
    _subs.add(_ble.rr.listen((r) => _r25.add({
          'ts': r.ts.millisecondsSinceEpoch ~/ 1000,
          'rmssd_ms': r.rmssdMs,
          'count': r.rrDiffsMs.length,
        })));
  }

  Future<void> stop() async {
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _flush();
  }

  Future<void> _flush() async {
    if (_events.isEmpty && _hr.isEmpty && _ppg.isEmpty && _r24.isEmpty && _r25.isEmpty) {
      return;
    }
    final batch = <String, dynamic>{
      if (_deviceId != null) 'device_id': _deviceId,
      if (_events.isNotEmpty) 'events': List<Map<String, dynamic>>.from(_events),
      if (_hr.isNotEmpty) 'hr': List<Map<String, dynamic>>.from(_hr),
      if (_ppg.isNotEmpty) 'ppg': List<Map<String, dynamic>>.from(_ppg),
      if (_r24.isNotEmpty) 'r24': List<Map<String, dynamic>>.from(_r24),
      if (_r25.isNotEmpty) 'r25': List<Map<String, dynamic>>.from(_r25),
    };
    try {
      await _api.ingestBatch(batch);
      _events.clear();
      _hr.clear();
      _ppg.clear();
      _r24.clear();
      _r25.clear();
    } catch (_) {
      // keep buffered, retry next interval
    }
  }
}

final syncWorkerProvider = Provider<SyncWorker>((ref) {
  final w = SyncWorker(ref.read(bleServiceProvider), ref.read(apiProvider));
  ref.onDispose(() => w.stop());
  return w;
});
