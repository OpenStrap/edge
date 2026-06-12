// Framing — WHOOP 4.0 protocol (Gen4 / "Harvard" envelope).
//
// Frame: [0xAA SOF][u16 LE size][crc8(size)][inner, padded /4][u32 LE CRC32]
//   size = len(inner_padded) + 4  (counts the trailing CRC32)
//
// The reassembler MUST be length-based, NOT "reset on 0xAA" — sensor payloads
// contain 0xAA and BLE notification boundaries land on them. See
//
// PURE Dart — no Flutter, no I/O.

import 'dart:typed_data';
import 'crc.dart';
import 'constants.dart';

/// A fully-parsed, validated frame envelope.
class Frame {
  final Uint8List inner; // unpadded? no — padded inner (type, seq, opcode, body…)
  final bool crc8Ok;
  final bool crc32Ok;

  Frame(this.inner, this.crc8Ok, this.crc32Ok);

  bool get valid => crc8Ok && crc32Ok;
  int get packetType => inner.isNotEmpty ? inner[0] : -1;
  int get seq => inner.length > 1 ? inner[1] : -1;
  int get opcode => inner.length > 2 ? inner[2] : -1;
  Uint8List get body =>
      inner.length > 3 ? Uint8List.sublistView(inner, 3) : Uint8List(0);
}

/// Zero-pad to a 4-byte boundary (CRC32 is computed over the padded form).
Uint8List pad4(List<int> data) {
  final padLen = (-data.length) % 4;
  final out = Uint8List(data.length + (padLen < 0 ? padLen + 4 : padLen));
  out.setRange(0, data.length, data);
  return out;
}

/// Wrap inner content in the Gen4 frame envelope.
Uint8List buildFrame(List<int> inner) {
  final innerP = pad4(inner);
  final declared = innerP.length + 4; // +4 = trailing CRC32
  final lenB = Uint8List(2)..buffer.asByteData().setUint16(0, declared, Endian.little);
  final c8 = crc8(lenB);
  final c32 = crc32(innerP);

  final out = BytesBuilder();
  out.addByte(sof);
  out.add(lenB);
  out.addByte(c8);
  out.add(innerP);
  final tail = Uint8List(4)..buffer.asByteData().setUint32(0, c32, Endian.little);
  out.add(tail);
  return out.toBytes();
}

/// Parse a single complete frame. Returns null if too short / bad SOF.
Frame? parseFrame(Uint8List raw) {
  if (raw.length < 8 || raw[0] != sof) return null;
  final bd = raw.buffer.asByteData(raw.offsetInBytes, raw.length);
  final declared = bd.getUint16(1, Endian.little);
  final crc8Ok = raw[3] == crc8(Uint8List.sublistView(raw, 1, 3));
  const innerStart = 4;
  final total = 4 + declared;
  if (raw.length < total) return null;
  // inner = raw[4 : 4 + declared - 4]
  final inner = Uint8List.sublistView(raw, innerStart, innerStart + declared - 4);
  final storedBd = raw.buffer.asByteData(raw.offsetInBytes + innerStart + declared - 4, 4);
  final stored = storedBd.getUint32(0, Endian.little);
  return Frame(Uint8List.fromList(inner), crc8Ok, stored == crc32(inner));
}

/// Length-based reassembler. feed() returns every complete Frame it can carve
/// out of the running buffer. length-based reassembler.
class FrameReassembler {
  final List<int> _buf = [];

  List<Frame> feed(List<int> chunk) {
    final out = <Frame>[];
    _buf.addAll(chunk);

    bool resync() {
      // Find next SOF after index 0.
      int nxt = -1;
      for (int i = 1; i < _buf.length; i++) {
        if (_buf[i] == sof) {
          nxt = i;
          break;
        }
      }
      if (nxt < 0) {
        _buf.clear();
        return false;
      }
      _buf.removeRange(0, nxt);
      return true;
    }

    while (_buf.length >= 8) {
      if (_buf[0] != sof) {
        if (!resync()) break;
        continue;
      }
      final declared = _buf[1] | (_buf[2] << 8); // u16 LE
      final total = 4 + declared;
      if (declared < 4 || total > 4096) {
        // implausible length → spurious SOF
        if (!resync()) break;
        continue;
      }
      if (_buf.length < total) break; // wait for the rest of this frame
      final frame = parseFrame(Uint8List.fromList(_buf.sublist(0, total)));
      if (frame != null) out.add(frame);
      _buf.removeRange(0, total);
      // skip inter-record null padding
      int i = 0;
      while (i < _buf.length && _buf[i] == 0x00) {
        i++;
      }
      if (i > 0) _buf.removeRange(0, i);
    }
    if (_buf.length > 8192) _buf.clear(); // safety: never grow unbounded
    return out;
  }

  void reset() => _buf.clear();
}
