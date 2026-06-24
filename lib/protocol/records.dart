// Decoders — WHOOP 4.0 protocol.
// PURE Dart. Header + HR of R24 are verified; spo2/temp/rhr/accel
// are EMPIRICAL fingerprints (). Full payload preserved in rawTail for re-decode.

import 'dart:typed_data';
import 'constants.dart';
import 'framing.dart';

// ── little-endian helpers over a byte list ──────────────────────────────────
ByteData _bd(Uint8List b) => b.buffer.asByteData(b.offsetInBytes, b.length);
int u16(Uint8List b, int o) => _bd(b).getUint16(o, Endian.little);
int i16(Uint8List b, int o) => _bd(b).getInt16(o, Endian.little);
int u32(Uint8List b, int o) => _bd(b).getUint32(o, Endian.little);
double f32(Uint8List b, int o) => _bd(b).getFloat32(o, Endian.little);

double _round(double v, int decimals) {
  // Non-finite floats appear in opaque/empirical fields (e.g. accel slots that
  // aren't real samples). Python's round() passes them through; Dart's .round()
  // throws on NaN/Infinity. Clamp to 0.0 so storage + JSON upload stay clean.
  if (v.isNaN || v.isInfinite) return 0.0;
  final p = _pow10(decimals);
  return (v * p).roundToDouble() / p;
}

double _pow10(int n) {
  double p = 1;
  for (int i = 0; i < n; i++) {
    p *= 10;
  }
  return p;
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ── 5.5 The type-24 record (the historical substrate), 1 Hz ──────────────────
// RECORD DECODING LIVES IN THE RUST CORE (openstrap-protocol, via dart:ffi):
// decode_record / decode_r24 / realtime_rr / frame_accel. The edge does NOT decode
// record bytes in Dart anymore — there is one decoder, shared with the cloud (wasm)
// and the on-device analytics (FFI), so it can't drift. This file keeps only the
// CONTROL-PLANE decode the Rust crate doesn't expose: HELLO, events, command
// responses (battery/alarm/strap-name), and sync markers.

// ── 5.1 HELLO identity ───────────────────────────────────────────────────────
class HelloInfo {
  double? batteryPct;
  bool? charging;
  String? serial;
  String? commit;
  bool? wristOn;
  String rawHex;
  HelloInfo({
    this.batteryPct,
    this.charging,
    this.serial,
    this.commit,
    this.wristOn,
    this.rawHex = '',
  });
}

List<String> _asciiRuns(Uint8List data, int start, int minlen) {
  final runs = <String>[];
  final cur = StringBuffer();
  for (int i = start; i < data.length; i++) {
    final b = data[i];
    if (b >= 0x20 && b < 0x7F) {
      cur.writeCharCode(b);
    } else {
      if (cur.length >= minlen) runs.add(cur.toString());
      cur.clear();
    }
  }
  if (cur.length >= minlen) runs.add(cur.toString());
  return runs;
}

/// Decode the GET_HELLO_HARVARD response *body* (bytes after [0x24,seq,0x23]).
/// Parses by CONTENT (offsets drift across firmware).
HelloInfo parseHello(Uint8List payload) {
  final info = HelloInfo(rawHex: _hex(payload));
  if (payload.length < 10) return info;

  for (int off = 1; off < 10; off++) {
    if (off + 2 <= payload.length) {
      final v = u16(payload, off);
      if (v >= 10 && v <= 1009) {
        info.batteryPct = _round(v / 10.0, 1);
        break;
      }
    }
  }
  if (payload.length > 5) info.charging = payload[5] != 0;
  if (payload.length > 116) info.wristOn = payload[116] != 0;

  const hexset = '0123456789abcdefABCDEF';
  for (final r in _asciiRuns(payload, 6, 6)) {
    if (info.serial == null && r.length >= 6 && r.length <= 13) {
      info.serial = r;
    } else if (info.commit == null &&
        r.length >= 16 &&
        r.split('').every((c) => hexset.contains(c))) {
      info.commit = r;
    }
  }
  return info;
}

// ── 5.2 EVENT (0x30) ─────────────────────────────────────────────────────────
class EventInfo {
  final int eventId;
  final String name;
  final int tsEpoch;
  final Map<String, dynamic> decoded;
  EventInfo(this.eventId, this.name, this.tsEpoch, this.decoded);
}

EventInfo? parseEvent(Uint8List inner) {
  if (inner.length < 4 || inner[0] != PacketType.event) return null;
  final eid = u16(inner, 2);
  final name = EventId.name(eid);
  final ts = inner.length >= 8 ? u32(inner, 4) : 0;
  final dec = <String, dynamic>{};
  switch (eid) {
    case EventId.chargingOn:
    case EventId.chargingOff:
      dec['charging'] = eid == EventId.chargingOn;
      break;
    case EventId.wristOn:
    case EventId.wristOff:
      dec['on_wrist'] = eid == EventId.wristOn;
      break;
    case EventId.batteryPackConnected:
    case EventId.batteryPackRemoved:
      dec['pack_connected'] = eid == EventId.batteryPackConnected;
      break;
    case EventId.doubleTap:
      // Surfaced so the live event path can map it to a user action (see
      // gestures/gesture_dispatcher.dart). Payload beyond the id is unused today.
      dec['double_tap'] = true;
      break;
  }
  return EventInfo(eid, name, ts, dec);
}

// ── 5.3 COMMAND_RESPONSE (0x24) ──────────────────────────────────────────────
class CmdResponse {
  final int opcode;
  final Map<String, dynamic> decoded;
  CmdResponse(this.opcode, this.decoded);
}

CmdResponse? parseCommandResponse(Uint8List inner) {
  if (inner.length < 3 || inner[0] != PacketType.commandResponse) return null;
  final op = inner[2];
  final payload = Uint8List.sublistView(inner, 3);
  final dec = <String, dynamic>{};
  if (op == Cmd.getBatteryLevel && inner.length >= 7) {
    dec['battery_pct'] = _round(u16(inner, 5) / 10.0, 1); // u16 LE @[5:7] / 10
  } else if (op == Cmd.getHelloHarvard) {
    final h = parseHello(payload);
    dec['hello'] = h;
  } else if (op == Cmd.getAlarmTime && payload.length >= 5) {
    // Per app alarm format: [0]=revision, [1:5]=u32 epoch seconds.
    dec['alarm_epoch'] = u32(payload, 1);
  } else if (op == Cmd.getAdvertisingNameHarvard) {
    // Strip leading control bytes (rev/len header), then ASCII up to NUL.
    int s = 0;
    while (s < payload.length && payload[s] < 0x20) {
      s++;
    }
    final end = payload.indexOf(0, s);
    final nameBytes = payload.sublist(s, end < 0 ? payload.length : end);
    dec['strap_name'] = String.fromCharCodes(nameBytes).trim();
  }
  return CmdResponse(op, dec);
}

// ── 5.4 METADATA (0x31) sync markers ─────────────────────────────────────────
class MetaMarker {
  final int sub;
  final String name;
  final Uint8List? token; // 8-byte batch token (HistoryEnd only)
  final int? batchId;
  MetaMarker(this.sub, this.name, this.token, this.batchId);
}

MetaMarker? parseMetadata(Uint8List inner) {
  if (inner.length < 3 || inner[0] != PacketType.metadata) return null;
  final sub = inner[2];
  String name;
  switch (sub) {
    case SyncMeta.historyStart:
      name = 'HISTORY_START';
      break;
    case SyncMeta.historyEnd:
      name = 'HISTORY_END';
      break;
    case SyncMeta.historyComplete:
      name = 'HISTORY_COMPLETE';
      break;
    default:
      name = 'META_$sub';
  }
  Uint8List? token;
  int? batchId;
  if (sub == SyncMeta.historyEnd && inner.length >= 21) {
    token = Uint8List.fromList(inner.sublist(13, 21)); // the 8 bytes the ACK echoes
    batchId = u32(inner, 17);
  }
  return MetaMarker(sub, name, token, batchId);
}

// ── decode_frame dispatch (for live UI / logging) ────────────────────────────
class Decoded {
  final String kind;
  final Map<String, dynamic> fields;
  Decoded(this.kind, this.fields);
}

/// Route a parsed frame to the right decoder. Returns a structured Decoded.
Decoded decodeFrame(Frame frame) {
  final inner = frame.inner;
  final pt = frame.packetType;
  try {
    switch (pt) {
      case PacketType.commandResponse:
        final r = parseCommandResponse(inner);
        if (r != null) return Decoded('cmd_response', {'opcode': r.opcode, ...r.decoded});
        break;
      case PacketType.event:
        final e = parseEvent(inner);
        if (e != null) {
          return Decoded('event', {'event': e.name, 'event_id': e.eventId, 'ts_epoch': e.tsEpoch, ...e.decoded});
        }
        break;
      case PacketType.metadata:
        final m = parseMetadata(inner);
        if (m != null) return Decoded('metadata', {'sub': m.name, 'batch_id': m.batchId});
        break;
      // Data records (0x2F historical, 0x28/0x2B live) are decoded by the Rust core
      // via FFI in BleEngine, not here — decodeFrame only handles the control plane.
    }
  } catch (e) {
    return Decoded('decode_error', {'error': e.toString()});
  }
  return Decoded('other', {'packet_type': pt});
}
