// A Garmin sports watch as a [BandAdapter]: open the Multi-Link control
// channel, register the GFDI handle, answer what the watch needs answered to
// stay connected, ask for battery once, bank every frame verbatim.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Garmin watch,
// so it ships EXPERIMENTAL (ASSUMPTIONS R6): `signals` is `const {}` and
// `garmin` is absent from `kDerivableSources` — this session never turns a
// byte into a heart rate, a step count or a sleep stage.
//
// THIS IS A BOUNDED SESSION, not a drain and not arm/disarm — same shape as
// `dafit.dart`'s own choice and for the same reason: there is no stored
// history this pass decodes, so there is no natural end-of-transfer signal.
// Long enough to open the channel, receive the unprompted device-info push,
// and get one battery answer back; short enough to fit the same background
// wake slot as the primary band's own sync.
//
// WHY REGISTER_ML'S OWN REFUSAL IS THE DECLINE SIGNAL, not a REGISTRATION
// service capability query. Per-firmware variance in which services a watch
// exposes is real, but a query for it needs its own wire format to trust —
// and unlike the messages below, that one is not corroborated cleanly enough
// to build. Refusing to guess it is the honest floor: a watch that has no
// GFDI to give answers REGISTER_ML with a non-zero status, and this file
// declines cleanly on exactly that, never on an assumption that GFDI exists.
//
// ACKING IS UNCONDITIONAL FOR ANY INBOUND MESSAGE OTHER THAN A RESPONSE
// ITSELF, and it is a bring-up requirement, not politeness — an unacked
// data-bearing message is documented to leave the watch stalled. Answering
// CURRENT_TIME_REQUEST is the same kind of requirement, not a nicety.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The request id this pass's one outstanding protobuf ask carries. A single
/// fixed value is enough: this session never has two requests in flight.
const int _kBatteryRequestId = 1;

int _defaultNowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
int _defaultUtcOffsetSeconds() => DateTime.now().timeZoneOffset.inSeconds;

class GarminAdapter extends BandAdapter {
  /// Wall-clock now, and this phone's current UTC offset — both injected so a
  /// fixture replay is deterministic.
  final int Function() nowSeconds;
  final int Function() utcOffsetSeconds;

  /// How long to wait for CLOSE_ALL_RESP or REGISTER_ML_RESP before giving up.
  final Duration handshakeTimeout;

  /// How long the session stays open once the GFDI channel is registered —
  /// see the header note on why this is bounded rather than open-ended.
  final Duration sessionWindow;

  const GarminAdapter({
    this.nowSeconds = _defaultNowSeconds,
    this.utcOffsetSeconds = _defaultUtcOffsetSeconds,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.sessionWindow = const Duration(seconds: 8),
  });

  @override
  BandEntry get entry => kGarmin;

  /// NOTHING. See the header note — this pass decodes device identity and a
  /// battery level, neither of which is a physiological signal, and nothing
  /// else on the wire is touched.
  @override
  Map<InputSignal, Duration> get signals => const {};

  /// COBS-encode and Multi-Link-frame one outbound GFDI frame, then write it.
  /// False for a handle this session never registered, or a refused write —
  /// both non-fatal to the caller, which only logs and moves on.
  Future<bool> _sendGfdi(BandLink link, int? handle, Uint8List frame) async {
    if (handle == null) return false;
    try {
      final framed = garminEncodeTx(handle, garminCobsEncode(frame));
      return await link.write(kGarminWriteChar, framed);
    } on ArgumentError {
      return false; // a handle outside the addressable range; refuse, don't crash
    }
  }

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final cobs = GarminCobsReassembler();
    final events = StreamController<BandEvent>();
    final archived = <Uint8List>[];
    final closeAllDone = Completer<bool>();
    final registerDone = Completer<GarminRegisterMlResponse?>();
    int? gfdiHandle;

    Future<void> ackAndDispatch(GarminGfdiFrame f) async {
      if (f.type != kGarminMsgResponse) {
        await _sendGfdi(link, gfdiHandle, garminBuildStatusAck(f.type));
      }
      switch (f.type) {
        case kGarminMsgCurrentTimeRequest:
          await _sendGfdi(
            link,
            gfdiHandle,
            garminBuildTimeResponse(
              nowUnixSeconds: nowSeconds(),
              utcOffsetSeconds: utcOffsetSeconds(),
            ),
          );
        case kGarminMsgDeviceInformation:
          final info = garminParseDeviceInformation(f);
          if (info != null && !events.isClosed) {
            final model =
                info.deviceModel.isNotEmpty ? info.deviceModel : info.deviceName;
            if (model.isNotEmpty) events.add(BandNote('model', model));
            events.add(BandNote('firmware', info.firmware));
          }
        case kGarminMsgProtobufResponse:
          final pf = garminParseProtobufFrame(f);
          if (pf == null) break;
          if (!pf.isComplete) {
            link.log('garmin: ignoring a chunked protobuf reply (offset '
                '${pf.dataOffset} of ${pf.totalLength} bytes).');
            break;
          }
          if (pf.requestId != _kBatteryRequestId) break;
          final battery = garminParseBatteryResponseProto(pf.protoBytes);
          if (battery != null && !events.isClosed) {
            events.add(BandNote('battery', battery.level));
          }
        case kGarminMsgSystemEvent:
          final ev = garminParseSystemEvent(f);
          if (ev != null) {
            link.log('garmin: system event ${ev.$1} (value ${ev.$2}).');
          }
      }
    }

    void onDisconnected() {
      if (!closeAllDone.isCompleted) closeAllDone.complete(false);
      if (!registerDone.isCompleted) registerDone.complete(null);
      if (!events.isClosed) events.close();
    }

    final sub = link.notify(kGarminNotifyChar).listen(
      (rec) {
        final bytes = Uint8List.fromList(rec.$2);
        final decoded = garminDecodeMlr(bytes);
        if (decoded is GarminCloseAllAck) {
          if (!closeAllDone.isCompleted) closeAllDone.complete(true);
          return;
        }
        if (decoded is GarminRegisterMlResponse) {
          if (!registerDone.isCompleted) registerDone.complete(decoded);
          return;
        }
        final handle = gfdiHandle;
        if (decoded is GarminMlrData && handle != null && decoded.handle == handle) {
          // Byte 0 is the routing byte; the COBS/GFDI stream starts after it.
          for (final frame in cobs.feed(decoded.payload.sublist(1))) {
            archived.add(frame);
            final gfdi = garminParseGfdiFrame(frame);
            if (gfdi != null) unawaited(ackAndDispatch(gfdi));
          }
          return;
        }
        // Control-channel noise this file has no decode for, or data on a
        // handle this session never registered — banked, never acted on.
        archived.add(bytes);
      },
      onDone: onDisconnected,
      onError: (Object _) => onDisconnected(),
    );

    try {
      if (!await link.write(
          kGarminWriteChar, garminEncodeTx(0, garminCloseAllRequest()))) {
        link.log('garmin: close-all write refused; ending the session.');
        return;
      }
      final closed =
          await closeAllDone.future.timeout(handshakeTimeout, onTimeout: () => false);
      if (!closed) {
        link.log('garmin: no CLOSE_ALL acknowledgement — the watch is '
            'probably still connected to a phone.');
        return;
      }

      if (!await link.write(kGarminWriteChar,
          garminEncodeTx(0, garminRegisterMlRequest(kGarminServiceGfdi)))) {
        link.log('garmin: register-ml write refused; ending the session.');
        return;
      }
      final reg = await registerDone.future
          .timeout(handshakeTimeout, onTimeout: () => null);
      if (reg == null || !reg.accepted) {
        link.log('garmin: the watch declined the GFDI channel (status '
            '${reg?.status ?? "none"}).');
        return;
      }
      gfdiHandle = reg.handle;

      await _sendGfdi(
        link,
        gfdiHandle,
        garminBuildProtobufRequest(
          requestId: _kBatteryRequestId,
          protoBytes: garminBatteryRequestProto(),
        ),
      );

      final timer = Timer(sessionWindow, () {
        if (!events.isClosed) events.close();
      });
      try {
        yield* events.stream;
      } finally {
        timer.cancel();
      }
    } finally {
      await sub.cancel();
      if (!events.isClosed) events.close();
    }
    if (archived.isNotEmpty) {
      yield SampleBatch(const [], raw: List.of(archived));
    }
  }
}

/// The single instance. Const, so it costs nothing to reference.
const GarminAdapter kGarminAdapter = GarminAdapter();
