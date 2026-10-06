// The mandatory adapter test (MULTIBAND_PLAN §3.3.3): assert the handshake,
// exactly one response per watch request, the device-info/battery round
// trip, the file sync's chunk and retry handling, and the clean decline
// path.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/garmin.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../support/garmin_watch.dart';

const int _kGfdiHandle = 1;

List<int> _closeAllAck() => GarminWatchScript.control(0x06, [0, 0, 0]);

List<int> _registerMlResp({
  required int service,
  required int status,
  required int handle,
  int clientId = 2,
}) {
  final out = List<int>.filled(14, 0);
  out[1] = 0x01; // REGISTER_ML_RESP
  out[2] = clientId;
  final svc = ByteData(2)..setInt16(0, service, Endian.little);
  out[10] = svc.getUint8(0);
  out[11] = svc.getUint8(1);
  out[12] = status;
  out[13] = handle;
  return out;
}

/// One data-frame notification carrying a COBS-encoded GFDI frame, the shape
/// the watch sends on a handle registered non-reliable: a bare handle byte.
List<int> _watchFrame(int handle, Uint8List gfdiFrame) =>
    <int>[handle, ...garminCobsEncode(gfdiFrame)];

/// Every GFDI frame the phone wrote on [handle], reassembled from its
/// multi-link packets.
List<GarminGfdiFrame> _sent(ReplayBandLink link,
    {int handle = _kGfdiHandle, String? char}) {
  final rx = GarminCobsReassembler();
  return [
    for (final (uuid, w) in link.writes)
      if (w.isNotEmpty && w[0] == handle && (char == null || uuid == char))
        for (final raw in rx.feed(w.sublist(1))) ?garminParseGfdiFrame(raw),
  ];
}

/// The RESPONSEs among [frames] answering [ref].
List<GarminGfdiFrame> _responsesTo(List<GarminGfdiFrame> frames, int ref) => [
      for (final f in frames)
        if (garminParseStatusAck(f)?.refMsgType == ref) f,
    ];

/// Close-all ack, then GFDI accepted on [_kGfdiHandle].
Future<void> _open(ReplayBandLink l) async {
  l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
  await Future<void>.delayed(Duration.zero);
  l.feed(
    kGarminNotifyChar,
    _registerMlResp(service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
    atSec: 1_800_000_000,
  );
  await Future<void>.delayed(Duration.zero);
}

Future<void> _push(ReplayBandLink l, Uint8List gfdi) async {
  l.feed(kGarminNotifyChar, _watchFrame(_kGfdiHandle, gfdi),
      atSec: 1_800_000_000);
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

/// Run [adapter] against [watch] until the session ends, answering each
/// write the way the watch would.
Future<List<BandEvent>> _sync(GarminAdapter adapter, GarminWatchScript watch,
    {ReplayBandLink? link}) async {
  final l = link ?? ReplayBandLink();
  final events = <BandEvent>[];
  final done = Completer<void>();
  adapter.run(l).listen(events.add, onDone: done.complete);
  var served = 0;
  for (var spin = 0; spin < 2000 && !done.isCompleted; spin++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    while (served < l.writes.length) {
      for (final n in watch.reply(l.writes[served++].$2)) {
        l.feed(kGarminNotifyChar, n, atSec: 1_800_000_000);
      }
    }
  }
  await l.close();
  await done.future;
  return events;
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
    registerTimeout: const Duration(milliseconds: 200),
    sessionWindow: const Duration(milliseconds: 200),
  );

  test('declares hrSparse and the registry mirrors it', () {
    expect(adapter.signals.keys, [InputSignal.hrSparse]);
    expect(kAdapterSignals['garmin'], adapter.signals);
  });

  test('writes CLOSE_ALL (12 bytes) then REGISTER_ML(GFDI) on the control '
      'handle', () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: _open);
    for (final (uuid, _) in link.writes) {
      expect(uuid, kGarminWriteChar);
    }
    expect(link.writes[0].$2, hasLength(12));
    expect(link.writes[0].$2.sublist(0, 2), [0, 0x05]);
    expect(link.writes[1].$2.sublist(0, 2), [0, 0x00]);
    expect(_sent(link), isEmpty,
        reason: 'nothing on GFDI before the watch sends its configuration');
  });

  test('the configuration gets an ack, the phone\'s own capabilities, '
      'HANDSHAKE_COMPLETE, then battery and the directory', () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0x10]));
    });
    final sent = _sent(link);
    final types = [for (final f in sent) garminMessageType(f.type)];
    expect(types, [
      kGarminMsgResponse,
      kGarminMsgConfiguration,
      kGarminMsgSystemEvent,
      kGarminMsgProtobufRequest,
      kGarminMsgDownloadRequest,
    ]);
    expect(sent[0].payload, [0xba, 0x13, 0], reason: 'an empty ack');
    expect(garminParseConfiguration(sent[1]), {kGarminCapCurrentTimeRequest});
    expect(sent[2].payload, [kGarminEventHandshakeComplete, 0]);
  });

  test('no HANDSHAKE_COMPLETE for a watch whose configuration does not ask',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0x01]));
    });
    expect([for (final f in _sent(link)) garminMessageType(f.type)],
        isNot(contains(kGarminMsgSystemEvent)));
  });

  test('declines cleanly when REGISTER_ML is refused, no GFDI write follows',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      // 13 bytes: a refusal carries no handle.
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(service: kGarminServiceGfdi, status: 1, handle: 0)
            .sublist(0, 13),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
    });
    expect(link.writes, hasLength(2)); // CLOSE_ALL, REGISTER_ML — no third
    expect(link.logs.any((m) => m.contains('status 1')), isTrue);
  });

  test('a register answer for another client is not ours', () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
            service: kGarminServiceGfdi,
            status: 0,
            handle: _kGfdiHandle,
            clientId: 9),
        atSec: 1_800_000_000,
      );
      await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0]));
    });
    expect(_sent(link), isEmpty);
  });

  test('PENDING_AUTH keeps waiting for the real answer', () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        _registerMlResp(
                service: kGarminServiceGfdi,
                status: kGarminRegisterPendingAuth,
                handle: 0)
            .sublist(0, 13),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await _open(l);
      await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0]));
    });
    expect(_sent(link), isNotEmpty);
  });

  test('ALREADY_IN_USE moves registration to the characteristic it names',
      () async {
    const n11 = '6a4e2811-667b-11e3-949a-0800200c9a66';
    const w21 = '6a4e2821-667b-11e3-949a-0800200c9a66';
    final moved = GarminAdapter(
      handshakeTimeout: const Duration(milliseconds: 200),
      registerTimeout: const Duration(milliseconds: 200),
      sessionWindow: const Duration(milliseconds: 200),
      mlChars: const [kGarminNotifyChar, kGarminWriteChar, n11, w21],
    );
    final link = ReplayBandLink();
    await replay(moved, link, whileRunning: (l) async {
      l.feed(kGarminNotifyChar, _closeAllAck(), atSec: 1_800_000_000);
      await Future<void>.delayed(Duration.zero);
      l.feed(
        kGarminNotifyChar,
        [
          ..._registerMlResp(
                  service: kGarminServiceGfdi,
                  status: kGarminRegisterAlreadyInUse,
                  handle: 0)
              .sublist(0, 13),
          0x11, 0x28,
        ],
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      l.feed(
        n11,
        _registerMlResp(
            service: kGarminServiceGfdi, status: 0, handle: _kGfdiHandle),
        atSec: 1_800_000_000,
      );
      await Future<void>.delayed(Duration.zero);
      l.feed(n11, _watchFrame(_kGfdiHandle,
          garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0])),
          atSec: 1_800_000_000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    expect(link.writes[2].$1, w21, reason: 'REGISTER again, on the twin');
    expect(link.writes[2].$2.sublist(0, 2), [0, 0x00]);
    expect(_sent(link, char: w21), isNotEmpty);
  });

  test('a watch with only 2811 is spoken to on 2811', () async {
    const n11 = '6a4e2811-667b-11e3-949a-0800200c9a66';
    expect(garminMlPair(const [n11]), (notify: n11, write: n11));
    expect(garminMlPair(const [kGarminNotifyChar, kGarminWriteChar]),
        (notify: kGarminNotifyChar, write: kGarminWriteChar));
    expect(garminMlPair(const [kGarminWriteChar]), isNull);
    final only = GarminAdapter(
      handshakeTimeout: const Duration(milliseconds: 20),
      registerTimeout: const Duration(milliseconds: 20),
      sessionWindow: const Duration(milliseconds: 20),
      mlChars: const [n11],
    );
    final link = ReplayBandLink();
    await replay(only, link);
    expect(link.writes, isNotEmpty);
    expect(link.writes.every((w) => w.$1 == n11), isTrue);
  });

  test('gives up a missing CLOSE_ALL ack and registers anyway', () async {
    final quick = GarminAdapter(
      handshakeTimeout: const Duration(milliseconds: 20),
      registerTimeout: const Duration(milliseconds: 20),
      sessionWindow: const Duration(milliseconds: 20),
    );
    final link = ReplayBandLink();
    final events = await replay(quick, link);
    expect(events, isEmpty);
    expect(link.writes, hasLength(2)); // CLOSE_ALL, then REGISTER_ML
    expect(link.writes[1].$2.sublist(0, 2), [0, 0x00]);
  });

  test('device info push yields model/firmware and gets exactly one '
      'response, carrying the phone\'s own', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, _deviceInfoFrame());
    });

    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'model' && n.value == 'fenix7'), isTrue);
    expect(
        notes.any((n) => n.key == 'firmware' && n.value == '19.20'), isTrue);

    final answers = _responsesTo(_sent(link), kGarminMsgDeviceInformation);
    expect(answers, hasLength(1));
    expect(answers.single.payload.length, greaterThan(3));

    // Banked verbatim regardless of whether it was decoded.
    final raw = [for (final e in events) if (e is SampleBatch) ...?e.raw];
    expect(raw, isNotEmpty);
  });

  test('a compact-form time request gets one answer with its transaction id',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(
          l,
          garminBuildGfdiFrame(0x8000 | (6 << 8) | 52, [0x2a, 1, 0, 0]));
    });
    final answers = _responsesTo(_sent(link), kGarminMsgCurrentTimeRequest);
    expect(answers, hasLength(1));
    expect(answers.single.type, 0x8000 | (6 << 8));
    expect(answers.single.payload, hasLength(23));
  });

  test('a message with no handler is answered UNKNOWN_OR_NOT_SUPPORTED',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, garminBuildGfdiFrame(5099, const [1]));
    });
    final answers = _responsesTo(_sent(link), 5099);
    expect(answers, hasLength(1));
    expect(garminParseStatusAck(answers.single)!.status, kGarminStatusUnknown);
  });

  test('a complete battery response yields the battery level and a protobuf '
      'ack', () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, _batteryResponseFrame(1, level: 61));
    });
    final notes = events.whereType<BandNote>().toList();
    expect(notes.any((n) => n.key == 'battery' && n.value == 61), isTrue);
    final answers = _responsesTo(_sent(link), kGarminMsgProtobufResponse);
    expect(answers, hasLength(1));
    expect(answers.single.payload, [0xb4, 0x13, 0, 1, 0, 0, 0, 0, 0, 0, 0]);
  });

  test('never yields a sample or an offload checkpoint without a file',
      () async {
    final link = ReplayBandLink();
    final events = await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, _deviceInfoFrame());
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

  test('the watch closing the GFDI handle ends the session at once',
      () async {
    final long = GarminAdapter(
      handshakeTimeout: const Duration(milliseconds: 200),
      registerTimeout: const Duration(milliseconds: 200),
      sessionWindow: const Duration(seconds: 30),
      configWait: const Duration(seconds: 30),
    );
    final link = ReplayBandLink();
    final done = Completer<void>();
    long.run(link).listen((_) {}, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    await _open(link);
    link.feed(kGarminNotifyChar,
        GarminWatchScript.control(0x04, [0, 0, _kGfdiHandle]),
        atSec: 1_800_000_000);
    await done.future.timeout(const Duration(seconds: 2));
    await link.close();
  });

  test('outbound frames are cut into MTU-sized packets behind the handle',
      () async {
    final link = ReplayBandLink();
    await replay(adapter, link, whileRunning: (l) async {
      await _open(l);
      await _push(l, _deviceInfoFrame());
    });
    final gfdi = [for (final w in link.writes) if (w.$2[0] == _kGfdiHandle) w.$2];
    expect(gfdi.length, greaterThan(1));
    expect(gfdi.every((w) => w.length <= 20), isTrue);
  });

  group('file sync', () {
    final t0 = 1_790_000_000;
    Uint8List fit(int n) => (FitWriter()
          ..define(0, 55, [(253, 4, 0x86), (3, 4, 0x86)])
          ..data(0, [...u32le(fitSec(t0)), ...u32le(n)]))
        .build();
    GarminAdapter syncer({String readFiles = ''}) => GarminAdapter(
          handshakeTimeout: const Duration(milliseconds: 200),
          registerTimeout: const Duration(milliseconds: 200),
          sessionWindow: const Duration(seconds: 3),
          configWait: const Duration(milliseconds: 20),
          notReadyDelay: const Duration(milliseconds: 5),
          readFiles: readFiles,
        );
    String? lastRead(List<BandEvent> events) => events
        .whereType<BandNote>()
        .where((n) => n.key == 'garmin_fit_files')
        .lastOrNull
        ?.value as String?;

    test('a NOT_READY file is asked for again, then served', () async {
      final watch = GarminWatchScript(
          {1: (kGarminFitMonitor, t0, fit(10))}, notReady: {1: 2});
      final events = await _sync(syncer(), watch);
      expect(watch.downloaded, [0, 1]);
      expect(garminDecodeReadFiles(lastRead(events)).keys, [1]);
    });

    test('a file is recorded as read just before its checkpoint, so the '
        'commit that banks its samples is the one that carries it', () async {
      final watch = GarminWatchScript({
        1: (kGarminFitMonitor, t0, fit(10)),
        2: (kGarminFitMonitor, t0 + 60, fit(20)),
      });
      final events = await _sync(syncer(), watch);
      final order = [
        for (final e in events)
          if (e is OffloadCheckpoint)
            'cp'
          else if (e is BandNote && e.key == 'garmin_fit_files')
            garminDecodeReadFiles(e.value as String?).keys.join(',')
      ];
      expect(order, ['1', 'cp', '1,2', 'cp']);
    });

    test('a file the watch keeps refusing is not recorded as read, so the '
        'next session asks again', () async {
      final watch = GarminWatchScript({
        2: (kGarminFitMonitor, t0, fit(10)), // older, never ready
        1: (kGarminFitSleep, t0 + 60, fit(20)),
      }, notReady: {2: 99});
      final events = await _sync(syncer(), watch);
      expect(watch.downloaded, [0, 1]);
      final read = garminDecodeReadFiles(lastRead(events));
      expect(read.keys, [1]);
    });

    test('a file that grew is read again; an unchanged one is not', () async {
      final grown = fit(30);
      final same = fit(40);
      final watch = GarminWatchScript({
        1: (kGarminFitMonitor, t0, grown),
        2: (kGarminFitSleep, t0, same),
      });
      await _sync(
          syncer(
              readFiles: garminEncodeReadFiles(
                  {1: (t0, grown.length - 5), 2: (t0, same.length)})),
          watch);
      expect(watch.downloaded, [0, 1]);
    });

    test('chunk acks: duplicate ok, wrong offset 4, bad CRC 3 and abort',
        () async {
      final link = ReplayBandLink();
      await replay(syncer(), link, whileRunning: (l) async {
        await _open(l);
        await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0]));
        await _push(
            l,
            garminBuildGfdiFrame(kGarminMsgResponse,
                [...u16le(kGarminMsgDownloadRequest), 0, 0, ...u32le(8)]));
        final a = [1, 2, 3, 4];
        final crcA = garminCrc16(a);
        Uint8List chunk(int crc, int off, List<int> d) => garminBuildGfdiFrame(
            kGarminMsgFileTransferData, [0, ...u16le(crc), ...u32le(off), ...d]);
        await _push(l, chunk(crcA, 0, a)); // accepted
        await _push(l, chunk(crcA, 0, a)); // repeat
        await _push(l, chunk(0, 6, a)); // wrong offset
        await _push(l, chunk(crcA ^ 1, 4, a)); // bad CRC
      });
      final acks = [
        for (final f in _responsesTo(_sent(link), kGarminMsgFileTransferData))
          (f.payload[3], f.payload[4]),
      ];
      expect(acks, [
        (kGarminTransferOk, 4),
        (kGarminTransferOk, 4),
        (kGarminTransferOffsetMismatch, 4),
        (kGarminTransferCrcMismatch, 4),
      ]);
    });

    test('three chunks out of step in a row abort the file', () async {
      final link = ReplayBandLink();
      await replay(syncer(), link, whileRunning: (l) async {
        await _open(l);
        await _push(l, garminBuildGfdiFrame(kGarminMsgConfiguration, [1, 0]));
        await _push(
            l,
            garminBuildGfdiFrame(kGarminMsgResponse,
                [...u16le(kGarminMsgDownloadRequest), 0, 0, ...u32le(8)]));
        for (var i = 0; i < 3; i++) {
          await _push(
              l,
              garminBuildGfdiFrame(kGarminMsgFileTransferData,
                  [0, 0, 0, ...u32le(4), 1, 2]));
        }
      });
      expect([
        for (final f in _responsesTo(_sent(link), kGarminMsgFileTransferData))
          f.payload[3],
      ], [
        kGarminTransferOffsetMismatch,
        kGarminTransferOffsetMismatch,
        kGarminTransferAbort,
      ]);
    });
  });
}
