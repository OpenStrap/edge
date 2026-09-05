// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), adapted for a band
// that declares no signals at all: assert the handshake, the acking, the
// device-info/battery round trip, and the clean decline path — never a
// sample, never an offload checkpoint.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/garmin.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

const int _kGfdiHandle = 1;

List<int> _closeAllAck() => const <int>[0x00, 0x06];

List<int> _registerMlResp({
  required int service,
  required int status,
  required int handle,
}) {
  final out = List<int>.filled(14, 0);
  out[1] = 0x01; // REGISTER_ML_RESP
  final svc = ByteData(2)..setInt16(0, service, Endian.little);
  out[10] = svc.getUint8(0);
  out[11] = svc.getUint8(1);
  out[12] = status;
  out[13] = handle;
  return out;
}

/// One MLR-flagged data-frame notification carrying a COBS-encoded GFDI
/// frame, the shape the watch itself sends on an already-registered handle.
List<int> _watchFrame(int handle, Uint8List gfdiFrame) {
  final cobs = garminCobsEncode(gfdiFrame);
  final routing = handle <= 7 ? (0x80 | (handle << 4)) : handle;
  return <int>[routing, ...cobs];
}

Uint8List _deviceInfoFrame({
  String model = 'fenix7',
  String device = 'fenix 7',
  int softwareVersion = 1920,
}) {
  final b = BytesBuilder()
    ..add(_u16(2)) // protocol_version
    ..add(_u16(3122)) // product_number
    ..add(_u32(123456)) // unit_number
    ..add(_u16(softwareVersion))
    ..add(_u16(200)) // max_packet_size
    ..addByte(0) // bluetooth_name: empty
    ..addByte(device.length)
    ..add(device.codeUnits)
    ..addByte(model.length)
    ..add(model.codeUnits);
  return garminBuildGfdiFrame(kGarminMsgDeviceInformation, b.toBytes());
}

Uint8List _batteryResponseFrame(int requestId, {int level = 61, int status = 0}) {
  final inner = <int>[8, status, 16, level]; // fields 1 & 2, varints
  final service = <int>[26, inner.length, ...inner]; // field 3, len-delim
  final smart = <int>[66, service.length, ...service]; // field 8, len-delim
  // Built via the REQUEST builder (identical wire shape to RESPONSE) purely
  // to reuse its `request_id`/`data_offset`/`total_length` header packing,
  // then re-wrapped under the RESPONSE type the watch actually sends.
  final asRequest =
      garminBuildProtobufRequest(requestId: requestId, protoBytes: smart);
  final gfdi = garminParseGfdiFrame(asRequest)!;
  return garminBuildGfdiFrame(kGarminMsgProtobufResponse, gfdi.payload);
}

List<int> _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

/// Drive [GarminAdapter] over a replayed link, collecting whatever it yields
/// until the link closes.
Future<List<BandEvent>> replay(
  GarminAdapter adapter,
  ReplayBandLink link, {
  FutureOr<void> Function(ReplayBandLink link)? whileRunning,
}) async {
  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  // `run()` is `async*`: without a turn here the notify channel this adapter
  // subscribes to may not exist yet when `link.close()` iterates `_channels`.
  await Future<void>.delayed(Duration.zero);
  if (whileRunning != null) await whileRunning(link);
  await link.close();
  await done.future;
  await sub.cancel();
  return events;
}

void main() {
  final adapter = GarminAdapter(
    nowSeconds: () => 1735689600,
    utcOffsetSeconds: () => 0,
    handshakeTimeout: const Duration(milliseconds: 200),
    sessionWindow: const Duration(milliseconds: 200),
  );

  test('declares and emits no signal at all', () {
    expect(adapter.signals, isEmpty);
  });

  test('writes CLOSE_ALL then REGISTER_ML(GFDI), and asks for battery once '
      'the channel opens', () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
            service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
    });

    expect(link.writes, hasLength(3));
    for (final (uuid, _) in link.writes) {
      expect(uuid, kGarminWriteChar);
    }
    expect(link.writes[0].$2[0], 0); // CLOSE_ALL on the control handle
    expect(link.writes[1].$2[0], 0); // REGISTER_ML on the control handle
    // The third write addresses the just-registered GFDI handle directly.
    expect(link.writes[2].$2[0], _kGfdiHandle);
  });

  test('declines cleanly when REGISTER_ML is refused, no GFDI write follows',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(service: kGarminServiceGfdi, status: 1, handle: 0),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
    });
    expect(link.writes, hasLength(2)); // CLOSE_ALL, REGISTER_ML — no third
  });

  test('gives up cleanly when CLOSE_ALL is never acknowledged', () async {
    final quick = GarminAdapter(
      handshakeTimeout: const Duration(milliseconds: 20),
      sessionWindow: const Duration(milliseconds: 20),
    );
    final link = ReplayBandLink();
    final events = await replay(quick, link);
    expect(events, isEmpty);
    expect(link.writes, hasLength(1)); // CLOSE_ALL only
  });

  test('device info push yields model/firmware and is acked', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
            service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
      l.feed(kGarminNotifyChar, _watchFrame(_kGfdiHandle, _deviceInfoFrame()),
          atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
    });

    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'model' && n.value == 'fenix7'), isTrue);
    expect(
        notes.any((n) => n.key == 'firmware' && n.value == '19.20'), isTrue);

    // The device-info push is answered with a plain status ack (type 5024).
    final ackWrite = link.writes.last;
    expect(ackWrite.$1, kGarminWriteChar);
    expect(ackWrite.$2[0], _kGfdiHandle);

    // Banked verbatim regardless of whether it was decoded.
    final raw = [for (final e in events) if (e is SampleBatch) ...?e.raw];
    expect(raw, isNotEmpty);
  });

  test('a complete battery response yields the battery level', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
            service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _watchFrame(_kGfdiHandle, _batteryResponseFrame(1, level: 61)),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
    });
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 61), isTrue);
  });

  test('never yields a sample or an offload checkpoint', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
            service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
      l.feed(kGarminNotifyChar, _watchFrame(_kGfdiHandle, _deviceInfoFrame()),
          atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
    });
    final samples = [
      for (final e in events)
        if (e is SampleBatch) ...e.samples,
    ];
    expect(samples, isEmpty);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
  });

  test('a refused CLOSE_ALL write ends the session without hanging',
      () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    final events = await replay(adapter, link);
    expect(events, isEmpty);
    expect(link.writes, hasLength(1)); // stops at the first refusal
  });
}
