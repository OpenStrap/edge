// Gen5 framing — the WHOOP 5.0 / MG ("V5") frame envelope.
//
// THE ONE THING TO UNDERSTAND ABOUT GEN5: it is not a new protocol. Everything
// above the frame envelope is the protocol WHOOP 4.0 already speaks, byte for
// byte — the same packet-type bytes (0x23 COMMAND … 0x34 HISTORICAL_IMU), the
// same command opcodes (0x0A SET_CLOCK, 0x22 GET_DATA_RANGE, 0x17 the batch
// ACK …), the same record layout inside a data packet (k/version at inner[1],
// counter at inner[3:7], unix seconds at inner[7:11], sub-seconds at
// inner[11:13], HR at inner[17] for k9/k12/k24 and inner[14] for k18).
//
// Only two things actually differ between a 4.0 and a 5.0 band:
//
//   1. the GATT UUID prefix — 61080001… becomes fd4b0001…, with the
//      characteristics numbered identically off it (see [WhoopFamily]);
//   2. this file — the outer envelope.
//
//        gen4:  [0xAA][u16 LE size][crc8(size)]        [inner]  [u32 LE crc32]
//        gen5:  [0xAA][0x01][u16 LE size][0x00][0x01]
//               [u16 LE crc16-modbus(header[0..6])]    [inner]  [u32 LE crc32]
//
//      4-byte header vs 8-byte header; crc8 over the length vs crc16-modbus
//      over the whole header prefix. `size` counts the padded inner PLUS the
//      trailing crc32 in both. Inner is zero-padded to 4 bytes in both, and the
//      crc32 is computed over the padded form in both.
//
// So gen5 support is an envelope swap, not a second stack: [Gen5FrameReassembler]
// hands the existing `decodeFrame`/`parseR24` decoders exactly the `Frame` they
// already understand, and [reframeGen4ToGen5] re-wraps the frames the existing
// command builders already produce. That is why the 4.0 path is not touched.
//
// Ported from the two independent public gen5 clients that agree on every field:
// b-nnett/goose (Rust/core/src/protocol.rs — `build_v5_payload_frame`,
// `FrameAccumulator`, `crc16_modbus`) and satayutata/geniemax-core
// (Sources/GenieMax/WhoopFrame.swift).
//
// PURE Dart — no Flutter, no I/O. Kept in the app rather than in
// package:openstrap_protocol so gen5 can be revised against real hardware
// without a protocol-package release; promote it once captures confirm it.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Which WHOOP generation a link is speaking.
///
/// The two families are distinguished ONLY by their 32-bit UUID prefix; the
/// characteristic numbering off that prefix is identical, which is what lets
/// one set of role lookups serve both.
enum WhoopFamily {
  /// WHOOP 4.0 — the "Harvard" service. The long-supported, hardware-tested path.
  gen4('61080001', '61080002', '61080003', '61080004', '61080005', 'WHOOP 4.0'),

  /// WHOOP 5.0 / MG. Same GATT shape, different vendor prefix and frame header.
  gen5('fd4b0001', 'fd4b0002', 'fd4b0003', 'fd4b0004', 'fd4b0005', 'WHOOP 5.0 / MG');

  const WhoopFamily(
    this.servicePrefix,
    this.cmdToPrefix,
    this.cmdFromPrefix,
    this.eventsPrefix,
    this.dataPrefix,
    this.label,
  );

  /// 32-bit prefix of the GATT service this family advertises and exposes.
  final String servicePrefix;

  /// Command WRITE characteristic (…0002).
  final String cmdToPrefix;

  /// Command-response NOTIFY characteristic (…0003).
  final String cmdFromPrefix;

  /// Event NOTIFY characteristic (…0004).
  final String eventsPrefix;

  /// Bulk-data NOTIFY characteristic (…0005).
  final String dataPrefix;

  /// Human-readable name, for logs and pairing UI.
  final String label;

  /// The family a discovered service UUID belongs to, or null if it is neither.
  static WhoopFamily? ofServiceUuid(String uuid) {
    final u = uuid.toLowerCase();
    for (final f in WhoopFamily.values) {
      if (u.startsWith(f.servicePrefix)) return f;
    }
    return null;
  }
}

// ── CRC ───────────────────────────────────────────────────────────────────────

/// CRC-16/MODBUS — init 0xFFFF, reflected, poly 0xA001, no final XOR.
///
/// Gen5 uses this over the 6-byte header prefix in place of gen4's crc8 over the
/// 2-byte length field. It is the gate that tells a real frame boundary from a
/// 0xAA that merely happens to occur inside sensor data.
int crc16Modbus(List<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

// ── frame envelope ────────────────────────────────────────────────────────────

/// Length of the gen5 header, in bytes (gen4's is 4).
const int kGen5HeaderLen = 8;

/// Upper bound on a single gen5 frame. The largest packet either reference
/// client decodes is the k21 IMU frame at ~1.2 kB and the k20 optical frame at
/// 2132 B of payload; 4096 leaves headroom without letting a corrupted length
/// field make us buffer unboundedly. Mirrors the gen4 reassembler's own cap.
const int kGen5MaxFrameLen = 4096;

/// Wrap already-built inner content in the gen5 envelope.
///
/// [inner] is the same `[type][seq][opcode][body…]` byte string gen4 uses — this
/// only changes the wrapper around it.
Uint8List buildGen5Frame(List<int> inner) {
  final innerP = pad4(inner);
  final declared = innerP.length + 4; // +4 = trailing crc32, as in gen4

  final header = Uint8List(kGen5HeaderLen);
  header[0] = sof; // 0xAA
  header[1] = 0x01; // frame version
  header[2] = declared & 0xFF;
  header[3] = (declared >> 8) & 0xFF;
  header[4] = 0x00;
  header[5] = 0x01;
  // The header CRC covers bytes 0..5 — i.e. everything above, and nothing else.
  final hc = crc16Modbus(Uint8List.sublistView(header, 0, 6));
  header[6] = hc & 0xFF;
  header[7] = (hc >> 8) & 0xFF;

  final c32 = crc32(innerP);
  final tail = Uint8List(4)
    ..buffer.asByteData().setUint32(0, c32, Endian.little);

  final out = BytesBuilder()
    ..add(header)
    ..add(innerP)
    ..add(tail);
  return out.toBytes();
}

/// Parse one complete gen5 frame. Returns null if it is too short or not a frame.
///
/// Returns the SAME [Frame] type gen4 produces, so every existing decoder
/// (`decodeFrame`, `parseR24`, `parseMetadata`, …) consumes it unchanged. The
/// `crc8Ok` field carries the gen5 HEADER-CRC result: the two families use
/// different header checksums, but both answer the same question — "is this
/// envelope intact?" — and `Frame.valid` already means "both CRCs passed".
Frame? parseGen5Frame(Uint8List raw) {
  if (raw.length < kGen5HeaderLen || raw[0] != sof) return null;
  final declared = raw[2] | (raw[3] << 8); // u16 LE
  // Must at least cover the trailing crc32, or the inner slice below goes
  // negative — same guard as the gen4 parser, same reason.
  if (declared < 4) return null;
  final total = kGen5HeaderLen + declared;
  if (raw.length < total) return null;

  final stored = raw[6] | (raw[7] << 8);
  final headerOk = crc16Modbus(Uint8List.sublistView(raw, 0, 6)) == stored;

  final inner = Uint8List.fromList(
    Uint8List.sublistView(raw, kGen5HeaderLen, kGen5HeaderLen + declared - 4),
  );
  final crcBd = raw.buffer.asByteData(
    raw.offsetInBytes + kGen5HeaderLen + declared - 4,
    4,
  );
  return Frame(inner, headerOk, crcBd.getUint32(0, Endian.little) == crc32(inner));
}

/// Re-wrap a gen4-enveloped frame in the gen5 envelope, preserving inner bytes.
///
/// WHY THIS EXISTS: every command builder in package:openstrap_protocol
/// (`buildCommand`, `buildHistoryResultOk`, `cmdSetAlarm`, `initPackets`, …)
/// emits a complete gen4 frame. Since the inner content is identical across
/// families, translating at the single point where bytes reach the
/// characteristic is both far less code and far less risk than teaching a dozen
/// builders about generations — and it makes it structurally impossible for a
/// gen4 band to receive a gen5-framed command.
///
/// Returns [gen4Frame] unchanged if it does not parse as a gen4 frame, so a
/// malformed input fails the same way it would have without gen5 support.
Uint8List reframeGen4ToGen5(Uint8List gen4Frame) {
  final parsed = parseFrame(gen4Frame);
  if (parsed == null) return gen4Frame;
  return buildGen5Frame(parsed.inner);
}

// ── reassembly ────────────────────────────────────────────────────────────────

/// One reassembler interface over both families, so a session holds the right
/// codec for its band and the notification path stays generation-agnostic.
abstract class WhoopReassembler {
  /// Feed a raw BLE notification chunk; get back every frame now complete.
  List<Frame> feed(List<int> chunk);

  /// Drop all buffered bytes (used when a link drops mid-frame).
  void reset();

  /// How many times the stream had to resynchronise — a degraded-link signal.
  int get resyncs;

  /// Build the reassembler for [family].
  factory WhoopReassembler.of(WhoopFamily family) => family == WhoopFamily.gen4
      ? _Gen4Reassembler()
      : Gen5FrameReassembler();
}

/// Gen4 — delegates to the protocol package's own reassembler so the 4.0 path
/// runs exactly the code it always has, including its crc8 length gate and its
/// inter-record null-padding skip.
class _Gen4Reassembler implements WhoopReassembler {
  final FrameReassembler _inner = FrameReassembler();

  @override
  List<Frame> feed(List<int> chunk) => _inner.feed(chunk);

  @override
  void reset() => _inner.reset();

  @override
  int get resyncs => _inner.resyncs;
}

/// Length-based gen5 reassembler.
///
/// MUST be length-based, not "reset on 0xAA": sensor payloads are full of 0xAA
/// bytes and BLE notification boundaries land on them. The header crc16 is what
/// separates a real frame start from a coincidental one — it is checked BEFORE
/// the declared length is trusted, because acting on a corrupted length byte
/// would swallow up to 4 kB of good stream, which for historical records is data
/// the band trims from flash and never sends again.
class Gen5FrameReassembler implements WhoopReassembler {
  final List<int> _buf = [];
  int _resyncs = 0;

  @override
  int get resyncs => _resyncs;

  @override
  List<Frame> feed(List<int> chunk) {
    final out = <Frame>[];
    _buf.addAll(chunk);

    // Drop to the next plausible frame start after index 0. Returns false when
    // no further 0xAA exists, meaning "stop, wait for more bytes".
    bool resync() {
      _resyncs++;
      var next = -1;
      for (var i = 1; i < _buf.length; i++) {
        if (_buf[i] == sof) {
          next = i;
          break;
        }
      }
      if (next < 0) {
        _buf.clear();
        return false;
      }
      _buf.removeRange(0, next);
      return true;
    }

    while (_buf.length >= kGen5HeaderLen) {
      if (_buf[0] != sof) {
        if (!resync()) break;
        continue;
      }
      final declared = _buf[2] | (_buf[3] << 8);
      final total = kGen5HeaderLen + declared;
      if (declared < 4 || total > kGen5MaxFrameLen) {
        if (!resync()) break; // implausible length ⇒ spurious 0xAA
        continue;
      }
      final storedHeaderCrc = _buf[6] | (_buf[7] << 8);
      if (crc16Modbus(_buf.sublist(0, 6)) != storedHeaderCrc) {
        if (!resync()) break; // header did not hold up ⇒ not a frame boundary
        continue;
      }
      if (_buf.length < total) break; // wait for the rest of this frame

      final frame = parseGen5Frame(Uint8List.fromList(_buf.sublist(0, total)));
      if (frame != null) out.add(frame);
      _buf.removeRange(0, total);

      // Skip inter-record zero padding, as the gen4 reassembler does.
      var i = 0;
      while (i < _buf.length && _buf[i] == 0x00) {
        i++;
      }
      if (i > 0) _buf.removeRange(0, i);
    }

    if (_buf.length > 8192) _buf.clear(); // never grow unbounded
    return out;
  }

  @override
  void reset() {
    _buf.clear();
    _resyncs = 0;
  }
}
