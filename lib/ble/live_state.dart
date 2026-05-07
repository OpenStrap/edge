import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:whoopsie_protocol/whoopsie_protocol.dart';

import 'ble_service.dart';

/// Aggregated live snapshot for the UI. Subscribes to all BLE streams,
/// keeps the latest sample of each plus a small HR sparkline buffer.
class LiveSnapshot {
  final LinkState state;
  final WhoopIdentity? identity;
  final HrSample? hr;
  final PpgSample? ppg;
  final WhoopEvent? lastEvent;
  final RrSample? rr;
  final RecoverySummary? r24;
  final double? batteryPct;
  final int evtCount;
  final int r10Count;
  final int ppgCount;
  final int ackedBatches;
  final int inBatch;
  final List<int> hrTrace;
  final List<int> spo2Window;
  final int spo2Avg;
  final List<String> logs;

  const LiveSnapshot({
    this.state = LinkState.idle,
    this.identity,
    this.hr,
    this.ppg,
    this.lastEvent,
    this.rr,
    this.r24,
    this.batteryPct,
    this.evtCount = 0,
    this.r10Count = 0,
    this.ppgCount = 0,
    this.ackedBatches = 0,
    this.inBatch = 0,
    this.hrTrace = const [],
    this.spo2Window = const [],
    this.spo2Avg = 0,
    this.logs = const [],
  });

  LiveSnapshot copyWith({
    LinkState? state,
    WhoopIdentity? identity,
    HrSample? hr,
    PpgSample? ppg,
    WhoopEvent? lastEvent,
    RrSample? rr,
    RecoverySummary? r24,
    double? batteryPct,
    int? evtCount,
    int? r10Count,
    int? ppgCount,
    int? ackedBatches,
    int? inBatch,
    List<int>? hrTrace,
    List<int>? spo2Window,
    int? spo2Avg,
    List<String>? logs,
  }) =>
      LiveSnapshot(
        state: state ?? this.state,
        identity: identity ?? this.identity,
        hr: hr ?? this.hr,
        ppg: ppg ?? this.ppg,
        lastEvent: lastEvent ?? this.lastEvent,
        rr: rr ?? this.rr,
        r24: r24 ?? this.r24,
        batteryPct: batteryPct ?? this.batteryPct,
        evtCount: evtCount ?? this.evtCount,
        r10Count: r10Count ?? this.r10Count,
        ppgCount: ppgCount ?? this.ppgCount,
        ackedBatches: ackedBatches ?? this.ackedBatches,
        inBatch: inBatch ?? this.inBatch,
        hrTrace: hrTrace ?? this.hrTrace,
        spo2Window: spo2Window ?? this.spo2Window,
        spo2Avg: spo2Avg ?? this.spo2Avg,
        logs: logs ?? this.logs,
      );
}

class LiveController extends StateNotifier<LiveSnapshot> {
  final WhoopBleService _ble;
  final List<StreamSubscription> _subs = [];
  final ListQueue<int> _spo2 = ListQueue();
  final List<int> _hrTrace = [];
  final ListQueue<String> _logs = ListQueue();

  LiveController(this._ble) : super(const LiveSnapshot()) {
    _subs.add(_ble.state.listen((s) => state = state.copyWith(state: s)));
    _subs.add(_ble.log.listen((m) {
      _logs.add(m);
      while (_logs.length > 12) {
        _logs.removeFirst();
      }
      state = state.copyWith(logs: List.unmodifiable(_logs));
    }));
    _subs.add(_ble.identity.listen((i) => state = state.copyWith(identity: i)));
    _subs.add(_ble.hr.listen((s) {
      if (s.hr > 0 && s.hr < 220) {
        _hrTrace.add(s.hr);
        if (_hrTrace.length > 60) _hrTrace.removeAt(0);
      }
      state = state.copyWith(
        hr: s,
        r10Count: state.r10Count + 1,
        hrTrace: List.unmodifiable(_hrTrace),
      );
    }));
    _subs.add(_ble.ppg.listen((s) {
      if (s.spo2 != null) {
        _spo2.add(s.spo2!);
        while (_spo2.length > 10) {
          _spo2.removeFirst();
        }
      }
      final avg =
          _spo2.isEmpty ? 0 : (_spo2.reduce((a, b) => a + b) / _spo2.length).round();
      state = state.copyWith(
        ppg: s,
        ppgCount: state.ppgCount + 1,
        spo2Window: List.unmodifiable(_spo2),
        spo2Avg: avg,
      );
    }));
    _subs.add(_ble.events.listen((e) =>
        state = state.copyWith(lastEvent: e, evtCount: state.evtCount + 1)));
    _subs.add(_ble.rr.listen((r) => state = state.copyWith(rr: r)));
    _subs.add(_ble.r24.listen((r) => state = state.copyWith(r24: r)));
    _subs.add(_ble.battery.listen((p) => state = state.copyWith(batteryPct: p)));
    _subs.add(_ble.sync.listen((m) =>
        state = state.copyWith(ackedBatches: m.acked, inBatch: m.inBatch)));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

final liveProvider =
    StateNotifierProvider<LiveController, LiveSnapshot>((ref) => LiveController(ref.read(bleServiceProvider)));
