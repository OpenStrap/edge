// Gen5 (WHOOP 5.0 / MG) framing — validated against REAL DEVICE CAPTURES.
//
// No maintainer owns a gen5 strap, so this suite is the only thing standing
// between the gen5 transport and wishful thinking. Every vector below is either
// a hand-derived frame from an independent implementation or bytes a real WHOOP
// 5.0 actually emitted, with the expected decode recorded alongside by whoever
// captured it. Sources:
//
//   • GET_HELLO — b-nnett/goose, Rust/core/tests/protocol_tests.rs. Doubles as a
//     BUILDER PARITY check: goose asserts its own builder reproduces this exact
//     hex, so if buildGen5Frame matches it, three implementations agree.
//   • k2 / k18 / type36 — satayutata/geniemax-core,
//     Tests/GenieMaxTests/Fixtures/decode_golden.json, captured from a real
//     strap with the decoded values verified against the official app.
//
// The k2 and k18 cases matter most: they are fed to the EXISTING gen4 record
// decoders, unchanged. That is the whole architectural claim of gen5 support —
// only the envelope differs — and these tests are what make it falsifiable.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/gen5_framing.dart';
import 'package:openstrap_edge/ble/gen5_records.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// GET_HELLO: COMMAND(0x23) seq=1 opcode=145 data=[1].
const String kGetHelloFrame = 'aa0108000001e67123019101363e5c8d';

/// Realtime HR packet (pt 40 / k2) — the strap reported 83 bpm.
const String kK2Frame =
    'aa011800010022e1280273ca246a852b530000000000000000000100c1e0e8ed';

/// Historical record (pt 47 / k18) — HR 77 bpm at unix 1577582585.
///
/// NOTE ON ITS CRC32: this frame's stored payload CRC does NOT match its bytes,
/// and that is a property of the fixture, not a bug here. geniemax-core states
/// its fixtures are "time-shifted, de-identified" — the capture's timestamp was
/// rewritten after the fact without recomputing the trailing CRC32. The payload
/// is otherwise intact and self-consistent (ts at [7:11], HR at [14] and resp at
/// [35] all still read exactly what the fixture records), so it remains a valid
/// test of the header math and the record decode. [kK18FrameCrcFixed] is the
/// same frame with the CRC recomputed, for the full-validation path.
const String kK18Frame =
    'aa01740001003fb12f12800e79a701f9ff075e3d2a004d000000000000000000'
    '0070310a00000000ce0030123c52b05cbf3de2ef3ed7b3893e780aff00000000'
    '000000000039013e01e60c000c010c020c000000000000000000000000000000'
    '000000000000000001008f888080000000f4c238c0000000686c9868';

/// [kK18Frame] with its payload CRC32 recomputed over the (unchanged) payload.
const String kK18FrameCrcFixed =
    'aa01740001003fb12f12800e79a701f9ff075e3d2a004d000000000000000000'
    '0070310a00000000ce0030123c52b05cbf3de2ef3ed7b3893e780aff00000000'
    '000000000039013e01e60c000c010c020c000000000000000000000000000000'
    '000000000000000001008f888080000000f4c238c0000000dae5fee1';

/// COMMAND_RESPONSE (pt 36) to GET_DATA_RANGE — head 0, watermark 0.
const String kType36Frame =
    'aa01740001003fb1243b91000201000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000'
    '0000000000000000000000000000000000000000000000000000000000000000'
    '00000000000000000000000000000000000000000000000045467b8e';

void main() {
  group('gen5 frame envelope', () {
    test('builder reproduces the goose GET_HELLO vector byte-for-byte', () {
      // inner = [COMMAND, seq=1, GET_HELLO=145, 0x01]
      final built = buildGen5Frame(const [0x23, 0x01, 0x91, 0x01]);
      expect(_hex(built), kGetHelloFrame);
    });

    test('parses the GET_HELLO vector with both CRCs valid', () {
      final f = parseGen5Frame(hexToBytes(kGetHelloFrame))!;
      expect(f.crc8Ok, isTrue, reason: 'header crc16-modbus');
      expect(f.crc32Ok, isTrue, reason: 'payload crc32');
      expect(f.valid, isTrue);
      expect(_hex(f.inner), '23019101');
      expect(f.packetType, PacketType.command);
      expect(f.seq, 1);
      expect(f.opcode, 145);
    });

    test('round-trips arbitrary inner content through build → parse', () {
      // Deliberately not a multiple of 4, to exercise the padding path.
      const inner = [0x23, 0x07, 0x22, 0xDE, 0xAD, 0xBE];
      final f = parseGen5Frame(buildGen5Frame(inner))!;
      expect(f.valid, isTrue);
      expect(f.inner.take(inner.length), inner);
      expect(f.inner.length % 4, 0, reason: 'inner is zero-padded to 4 bytes');
    });

    test('a corrupted payload fails crc32 but leaves the header readable', () {
      // Mirrors goose's payload_crc_mismatch_preserves_parseable_header test:
      // we must still be able to see WHAT the frame was, to log it usefully.
      final raw = hexToBytes(kGetHelloFrame);
      raw[raw.length - 1] ^= 0xFF;
      final f = parseGen5Frame(raw)!;
      expect(f.crc8Ok, isTrue);
      expect(f.crc32Ok, isFalse);
      expect(f.valid, isFalse);
      expect(f.packetType, PacketType.command);
    });

    test('a corrupted header is reported, not silently trusted', () {
      final raw = hexToBytes(kGetHelloFrame);
      raw[6] ^= 0xFF; // header crc16 low byte
      expect(parseGen5Frame(raw)!.crc8Ok, isFalse);
    });

    test('rejects a short buffer and a declared length below the crc32', () {
      expect(parseGen5Frame(hexToBytes('aa010800')), isNull);
      // declared = 2, which cannot even cover the trailing crc32.
      expect(parseGen5Frame(hexToBytes('aa010200000100000000')), isNull);
    });

    test('crc16-modbus matches the reference implementation', () {
      // The header prefix of GET_HELLO: aa 01 08 00 00 01 → 0x71e6.
      expect(crc16Modbus(const [0xAA, 0x01, 0x08, 0x00, 0x00, 0x01]), 0x71E6);
      expect(crc16Modbus(const []), 0xFFFF);
    });
  });

  group('gen5 reassembly', () {
    test('reassembles a frame split across BLE notifications', () {
      final frame = hexToBytes(kGetHelloFrame);
      final asm = Gen5FrameReassembler();
      expect(asm.feed(frame.sublist(0, 5)), isEmpty);
      expect(asm.feed(frame.sublist(5, 11)), isEmpty);
      final out = asm.feed(frame.sublist(11));
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
      expect(_hex(out.single.inner), '23019101');
    });

    test('drops leading noise before the frame start', () {
      // goose's deframer test feeds exactly this shape.
      final frame = hexToBytes(kGetHelloFrame);
      final asm = Gen5FrameReassembler();
      final out = asm.feed([0x00, 0x01, ...frame]);
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
    });

    test('carves several frames out of one chunk', () {
      final asm = Gen5FrameReassembler();
      final out = asm.feed([
        ...hexToBytes(kGetHelloFrame),
        ...hexToBytes(kK2Frame),
        ...hexToBytes(kGetHelloFrame),
      ]);
      expect(out, hasLength(3));
      expect(out.every((f) => f.valid), isTrue);
    });

    test('a 0xAA inside sensor data does not desynchronise the stream', () {
      // THE regression this design exists to prevent. Sensor payloads are full
      // of 0xAA and notification boundaries land on them; a "reset on 0xAA"
      // reassembler would lose every record after the first such byte.
      final payload = List<int>.filled(32, 0xAA);
      final frame = buildGen5Frame([0x2F, 0x18, ...payload]);
      final asm = Gen5FrameReassembler();
      final out = asm.feed(frame);
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
      expect(out.single.inner[1], 0x18);
    });

    test('resynchronises past a bad header instead of stalling', () {
      final good = hexToBytes(kGetHelloFrame);
      final asm = Gen5FrameReassembler();
      // A 0xAA with a header CRC that cannot hold up, then a real frame.
      final out = asm.feed([0xAA, 0x01, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, ...good]);
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
      expect(asm.resyncs, greaterThan(0));
    });

    test('an implausible declared length does not buffer unboundedly', () {
      final asm = Gen5FrameReassembler();
      expect(asm.feed([0xAA, 0x01, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x00]), isEmpty);
      expect(asm.feed(hexToBytes(kGetHelloFrame)), hasLength(1));
    });

    test('reset clears buffered bytes and the resync counter', () {
      final asm = Gen5FrameReassembler();
      final frame = hexToBytes(kGetHelloFrame);
      asm.feed(frame.sublist(0, 6));
      asm.reset();
      expect(asm.resyncs, 0);
      // The tail of the old frame alone must not produce anything.
      expect(asm.feed(frame.sublist(6)), isEmpty);
    });
  });

  // The claim under test: gen5 differs ONLY in the envelope, so real gen5
  // payloads decode through the existing, hardware-tested gen4 decoders.
  group('real gen5 captures decode through the gen4 decoders', () {
    test('k2 realtime packet yields the captured heart rate', () {
      final f = parseGen5Frame(hexToBytes(kK2Frame))!;
      expect(f.valid, isTrue, reason: 'real device frame must validate');
      expect(f.packetType, PacketType.realtimeData);
      expect(f.inner[1], 2, reason: 'k-domain 2');

      final hr = parseRealtimeHr(f.inner)!;
      expect(hr.hrBpm, 83, reason: 'geniemax recorded hr8 = 83');
    });

    test('k18 historical record yields the captured HR and timestamp', () {
      final f = parseGen5Frame(hexToBytes(kK18Frame))!;
      // Header math must hold on the real capture. The payload CRC does not,
      // for the de-identification reason documented on the constant.
      expect(f.crc8Ok, isTrue, reason: 'real device header must validate');
      expect(f.packetType, PacketType.historicalData);
      expect(f.inner[1], 18, reason: 'k-domain 18');

      // The HEADER decodes through the shared layout both generations agree on.
      // The full gen4 v24 field map does NOT apply to a k18 body — see
      // gen5_records_test.dart for that boundary and decodeGen5History for the
      // fields we can actually justify reading.
      final r = decodeGen5History(f.inner)!;
      expect(r.hr, 77, reason: 'geniemax recorded hr14 = 77');
      expect(r.tsEpoch, 1577582585, reason: 'geniemax recorded ts7');
    });

    test('the same k18 frame fully validates once its CRC32 is recomputed', () {
      // Proves the CRC mismatch above is the fixture's, not the parser's: the
      // payload bytes are untouched, only the trailing CRC differs.
      final f = parseGen5Frame(hexToBytes(kK18FrameCrcFixed))!;
      expect(f.valid, isTrue);
      expect(f.inner, parseGen5Frame(hexToBytes(kK18Frame))!.inner);
      expect(decodeGen5History(f.inner)!.hr, 77);
    });

    test('a real k18 frame survives chunked reassembly', () {
      // The path that actually runs on-device: bytes arrive split across BLE
      // notifications, not as one buffer.
      final frame = hexToBytes(kK18FrameCrcFixed);
      final asm = Gen5FrameReassembler();
      final out = <Frame>[];
      for (var i = 0; i < frame.length; i += 20) {
        out.addAll(asm.feed(
          frame.sublist(i, i + 20 > frame.length ? frame.length : i + 20),
        ));
      }
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
      expect(decodeGen5History(out.single.inner)!.hr, 77);
    });

    test('type36 command response frames validate and route', () {
      final f = parseGen5Frame(hexToBytes(kType36Frame))!;
      expect(f.valid, isTrue);
      expect(f.packetType, PacketType.commandResponse);
    });

    test('decodeFrame routes a real gen5 realtime frame without changes', () {
      final f = parseGen5Frame(hexToBytes(kK2Frame))!;
      final d = decodeFrame(f);
      expect(d.kind, 'realtime_hr');
      expect(d.fields['hr'], 83);
    });
  });

  group('envelope translation', () {
    test('reframing a built gen4 command preserves inner bytes exactly', () {
      final gen4 = buildCommand(7, Cmd.getClock, const [0x00]);
      final gen5 = reframeGen4ToGen5(gen4);

      final a = parseFrame(gen4)!;
      final b = parseGen5Frame(gen5)!;
      expect(b.inner, a.inner);
      expect(b.valid, isTrue);
      expect(b.packetType, PacketType.command);
      expect(b.opcode, Cmd.getClock);
    });

    test('reframing produces exactly what buildGen5Frame would', () {
      final inner = parseFrame(buildCommand(1, 0x91, const [0x01]))!.inner;
      expect(reframeGen4ToGen5(buildCommand(1, 0x91, const [0x01])),
          buildGen5Frame(inner));
    });

    test('the batch ACK survives the envelope swap', () {
      // The HISTORY_END ACK is the one write where a mistake costs data: the
      // band trims flash once it lands.
      final token = [1, 2, 3, 4, 5, 6, 7, 8];
      final gen5 = reframeGen4ToGen5(buildHistoryResultOk(3, token));
      final f = parseGen5Frame(gen5)!;
      expect(f.valid, isTrue);
      expect(f.opcode, Cmd.historicalDataResult);
      expect(f.inner.sublist(4, 12), token);
    });

    test('a non-frame input is returned untouched rather than mangled', () {
      final junk = hexToBytes('0badc0de');
      expect(reframeGen4ToGen5(junk), junk);
    });
  });

  group('WhoopFamily', () {
    test('identifies each family from its service UUID', () {
      expect(WhoopFamily.ofServiceUuid(GattUuids.service), WhoopFamily.gen4);
      expect(WhoopFamily.ofServiceUuid('fd4b0001-cce1-4033-93ce-002d5875f58a'),
          WhoopFamily.gen5);
      expect(WhoopFamily.ofServiceUuid('FD4B0001-CCE1-4033-93CE-002D5875F58A'),
          WhoopFamily.gen5);
      expect(WhoopFamily.ofServiceUuid('0000180d-0000-1000-8000-00805f9b34fb'),
          isNull);
    });

    test('characteristic roles are numbered identically off each prefix', () {
      // This parallelism is what lets one set of role lookups serve both
      // families; if it ever stops holding, the connect path must change.
      for (final f in WhoopFamily.values) {
        expect(f.cmdToPrefix, '${f.servicePrefix.substring(0, 4)}0002');
        expect(f.cmdFromPrefix, '${f.servicePrefix.substring(0, 4)}0003');
        expect(f.eventsPrefix, '${f.servicePrefix.substring(0, 4)}0004');
        expect(f.dataPrefix, '${f.servicePrefix.substring(0, 4)}0005');
      }
    });

    test('gen4 prefixes still match the protocol package constants', () {
      expect(GattUuids.service, startsWith(WhoopFamily.gen4.servicePrefix));
      expect(GattUuids.cmdTo, startsWith(WhoopFamily.gen4.cmdToPrefix));
      expect(GattUuids.cmdFrom, startsWith(WhoopFamily.gen4.cmdFromPrefix));
      expect(GattUuids.events, startsWith(WhoopFamily.gen4.eventsPrefix));
      expect(GattUuids.data, startsWith(WhoopFamily.gen4.dataPrefix));
    });

    test('WhoopReassembler.of returns the right codec per family', () {
      expect(WhoopReassembler.of(WhoopFamily.gen5), isA<Gen5FrameReassembler>());
      // Gen4 must keep running the protocol package's own reassembler.
      final gen4 = WhoopReassembler.of(WhoopFamily.gen4);
      expect(gen4, isNot(isA<Gen5FrameReassembler>()));
      final out = gen4.feed(buildCommand(1, Cmd.getClock, const [0x00]));
      expect(out, hasLength(1));
      expect(out.single.valid, isTrue);
    });
  });
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
