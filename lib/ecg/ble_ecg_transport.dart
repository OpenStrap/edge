// EcgTransport over the real BleEngine — a 1:1 forwarder plus a broadcast
// stream fed by the engine's ECG event sink.

import 'dart:async';

import '../ble/ble_engine.dart';
import 'ecg_models.dart';
import 'ecg_transport.dart';

class BleEngineEcgTransport implements EcgTransport {
  final BleEngine engine;
  final String? Function() serialOf;
  final Future<void> Function() onRequestSync;
  final _events = StreamController<EcgTransportEvent>.broadcast();

  BleEngineEcgTransport({
    required this.engine,
    required this.serialOf,
    required this.onRequestSync,
  });

  /// Wire this to `BleEngine.onEcgEvent`.
  void onEngineEvent(EcgEngineEvent e) {
    _events.add(switch (e) {
      EcgFrameEvent(:final r17, :final linkGeneration) => EcgTransportFrame(
        r17,
        linkGeneration,
      ),
      EcgMalformedR17Event(:final reason, :final linkGeneration) =>
        EcgTransportMalformed(linkGeneration, reason),
      EcgLinkDownEvent(:final linkGeneration) => EcgTransportLinkDown(
        linkGeneration,
      ),
    });
  }

  @override
  bool get isReady => engine.isConnected;

  @override
  bool get isMaverick => engine.isMaverick;

  @override
  int get linkGeneration => engine.linkGeneration;

  @override
  String? get serial => serialOf();

  @override
  Stream<EcgTransportEvent> get events => _events.stream;

  @override
  EcgLeaseHandle? acquire() {
    final l = engine.ecgAcquire();
    return l == null ? null : EcgLeaseHandle(l, l.linkGeneration);
  }

  @override
  bool leaseValid(EcgLeaseHandle lease) =>
      engine.ecgLeaseValid(lease.token as EcgLease);

  @override
  void release(EcgLeaseHandle lease) =>
      engine.ecgRelease(lease.token as EcgLease);

  @override
  Future<void> cancelHistory(EcgLeaseHandle lease) =>
      engine.ecgCancelHistory(lease.token as EcgLease);

  static EcgCommandListResult _wrap(List<EcgCommandOutcome> out) =>
      EcgCommandListResult([
        for (final o in out)
          EcgMemberOutcome(o.label, written: o.written, succeeded: o.succeeded),
      ]);

  @override
  Future<EcgCommandListResult> prepare(
    EcgLeaseHandle lease,
    EcgWrist wrist,
  ) async =>
      _wrap(await engine.ecgPrepare(lease.token as EcgLease, wrist.selection));

  @override
  Future<EcgCommandListResult> start(EcgLeaseHandle lease) async =>
      _wrap(await engine.ecgStart(lease.token as EcgLease));

  @override
  Future<EcgCommandListResult> restart(EcgLeaseHandle lease) async =>
      _wrap(await engine.ecgRestart(lease.token as EcgLease));

  @override
  Future<EcgCommandListResult> cleanup(EcgLeaseHandle lease) async =>
      _wrap(await engine.ecgCleanup(lease.token as EcgLease));

  /// The cleanup triplet under the engine's READY recovery lease — for the
  /// `onReadyEcgRecovery` hook only.
  Future<EcgCommandListResult> recoveryCleanup() async =>
      _wrap(await engine.ecgRecoveryCleanup());

  @override
  Future<void> requestSync() => onRequestSync();

  void dispose() => _events.close();
}
