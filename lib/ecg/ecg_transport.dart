// The seam between the ECG controller and the BLE engine. The controller
// depends on THIS — a fake implements it in tests — and the adapter in
// ble_ecg_transport.dart forwards to BleEngine 1:1.

import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_models.dart';

/// Exclusive ownership of the command transport for one link. Opaque to the
/// controller; the transport validates it.
class EcgLeaseHandle {
  final Object token;
  final int linkGeneration;
  const EcgLeaseHandle(this.token, this.linkGeneration);
}

/// What the transport reports about the link and the live stream.
sealed class EcgTransportEvent {
  final int linkGeneration;
  const EcgTransportEvent(this.linkGeneration);
}

class EcgTransportFrame extends EcgTransportEvent {
  final LabradorR17 r17;
  const EcgTransportFrame(this.r17, super.linkGeneration);
}

/// A frame that claimed to be R17 but did not parse.
class EcgTransportMalformed extends EcgTransportEvent {
  final String reason;
  const EcgTransportMalformed(super.linkGeneration, this.reason);
}

/// The link of [linkGeneration] is gone.
class EcgTransportLinkDown extends EcgTransportEvent {
  const EcgTransportLinkDown(super.linkGeneration);
}

class EcgMemberOutcome {
  final String label;
  final bool written;
  final bool succeeded;
  const EcgMemberOutcome(
    this.label, {
    required this.written,
    required this.succeeded,
  });

  @override
  String toString() => '$label(written=$written ok=$succeeded)';
}

class EcgCommandListResult {
  final List<EcgMemberOutcome> outcomes;
  const EcgCommandListResult(this.outcomes);

  bool get allSucceeded =>
      outcomes.isNotEmpty && outcomes.every((o) => o.succeeded);
  List<EcgMemberOutcome> get failed => [
    for (final o in outcomes)
      if (!o.succeeded) o,
  ];

  @override
  String toString() => outcomes.join(', ');
}

abstract class EcgTransport {
  /// Connected and READY.
  bool get isReady;

  /// Positively identified WHOOP MG (revision-1 HELLO, MAVERICK interval).
  bool get isMaverick;

  int get linkGeneration;

  /// The connected band's serial, or null before it is known.
  String? get serial;

  Stream<EcgTransportEvent> get events;

  /// Claim the transport. Synchronous. Null when not connected or already
  /// leased (another capture, or READY recovery).
  EcgLeaseHandle? acquire();
  bool leaseValid(EcgLeaseHandle lease);
  void release(EcgLeaseHandle lease);

  /// End the phone-side history owner and wait for it to go quiescent.
  Future<void> cancelHistory(EcgLeaseHandle lease);

  Future<EcgCommandListResult> prepare(EcgLeaseHandle lease, EcgWrist wrist);
  Future<EcgCommandListResult> start(EcgLeaseHandle lease);
  Future<EcgCommandListResult> restart(EcgLeaseHandle lease);

  /// Always attempts all three members.
  Future<EcgCommandListResult> cleanup(EcgLeaseHandle lease);

  /// Ask for an ordinary incremental history sync (after cleanup, so the
  /// saved raw R16 comes back through the normal safe path).
  Future<void> requestSync();
}
