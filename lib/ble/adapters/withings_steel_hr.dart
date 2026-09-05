// Withings Steel HR / Activité — pair, authenticate, and bank every reply
// verbatim. No activity/sleep/heart-rate/workout structure is decoded here:
// this band declares zero derivable signals, the same way `oura.dart` and
// `ble_hrs.dart` do for a device nobody has held (ASSUMPTIONS R6).
//
// WIRE SHAPE. One custom GATT service with one characteristic used for BOTH
// directions — commands are written to it, replies arrive as notifications
// on the same UUID. Every message starts with a 5-byte header
// (`[0x01][messageType: u16 BE][structLen: u16 BE]`) followed by zero or more
// TLV structures (`[structType: u16 BE][payloadLen: u16 BE][payload]`,
// `payloadLen` excluding that 4-byte structure header). Message-level types
// and structure-level types are SEPARATE NAMESPACES that happen to share
// some numbers (PROBE the message and PROBE_REPLY the structure are both
// 257) — every constant below is named for which namespace it is.
//
// HANDSHAKE. A first-ever connection needs no proof at all: an empty
// INITIAL_CONNECT message is enough to start a session. Every connection
// after that is gated behind a mutual challenge-response — never payload
// encryption, the bytes on the wire stay plaintext either way, this only
// decides whether the device accepts the session:
//
//   1. host -> PROBE (Probe + ProbeOsVersion)
//   2. device -> CHALLENGE (Challenge: macAddress, 16-byte nonce)
//   3. host -> CHALLENGE (ChallengeResponse answering the device's nonce,
//      plus a fresh Challenge of the host's own — the same macAddress,
//      echoed verbatim, never independently sourced)
//   4. device -> PROBE (ProbeReply, plus its own ChallengeResponse)
//   5. host recomputes and compares; a mismatch means the session is
//      unauthenticated and the connect stops.
//
// The proof is `SHA1(nonce ++ macAddress_ascii ++ secret_ascii)`; `secret` is
// a fixed 32-byte ASCII value shared by every device in this family, not a
// per-device credential — nothing to store, nothing to manage.
//
// WHAT THIS DOES NOT DO. Every activity/sleep/heart-rate/workout structure —
// 30+ classes' worth in the family this belongs to — is out of scope: this
// device supplies no derivable signal regardless of how well its bytes are
// understood, so decoding them would be dead weight against a band nobody
// owns. `run()` archives every reassembled post-handshake message verbatim
// and does nothing else.

import 'dart:async';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

// ---- message-level type ids (one namespace) ----
const int kWithingsMsgInitialConnect = 273;
const int kWithingsMsgProbe = 257;
const int kWithingsMsgChallenge = 296;

// ---- structure-level type ids (a SEPARATE namespace — see header) ----
const int kWithingsStructProbe = 298;
const int kWithingsStructProbeReply = 257;
const int kWithingsStructChallenge = 290;
const int kWithingsStructChallengeResponse = 291;
const int kWithingsStructProbeOsVersion = 2344;

/// Fixed across every device in this family. Not a per-device secret, not
/// something this app generates or stores — a plain constant to embed.
const String kWithingsSteelHrSecret = '2EM5zNP37QzM00hmP6BFTD92nG15XwNd';

/// ponytail: fixed 20-byte write chunks, ceiling = extra round-trips on a
/// device that negotiated a larger MTU; upgrade by exposing MTU on BandLink
/// if this band's connect time actually matters.
const int kWithingsWriteChunkSize = 20;

/// One parsed message: its message-level type and the TLV structures inside.
class WithingsMessage {
  final int type;
  final List<WithingsStruct> structs;
  const WithingsMessage(this.type, this.structs);

  /// The first structure of [structType] in this message, or null.
  WithingsStruct? struct(int structType) {
    for (final s in structs) {
      if (s.type == structType) return s;
    }
    return null;
  }
}

/// One TLV structure's type and payload (header already stripped).
class WithingsStruct {
  final int type;
  final Uint8List payload;
  const WithingsStruct(this.type, this.payload);
}

Uint8List _structBytes(int type, List<int> payload) {
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out).setUint16(0, type, Endian.big);
  ByteData.sublistView(out).setUint16(2, payload.length, Endian.big);
  out.setRange(4, out.length, payload);
  return out;
}

/// One outbound message: the 5-byte header plus however many structures
/// concatenate to its declared `structLen`.
Uint8List buildWithingsMessage(int messageType, List<Uint8List> structs) {
  final body = BytesBuilder();
  for (final s in structs) {
    body.add(s);
  }
  final structBytes = body.takeBytes();
  final out = Uint8List(5 + structBytes.length);
  out[0] = 0x01;
  final bd = ByteData.sublistView(out);
  bd.setUint16(1, messageType, Endian.big);
  bd.setUint16(3, structBytes.length, Endian.big);
  out.setRange(5, out.length, structBytes);
  return out;
}

Uint8List buildProbeStruct({
  required int os,
  required int app,
  required int version,
}) =>
    _structBytes(kWithingsStructProbe, <int>[
      os & 0xff,
      app & 0xff,
      (version >> 24) & 0xff,
      (version >> 16) & 0xff,
      (version >> 8) & 0xff,
      version & 0xff,
    ]);

Uint8List buildProbeOsVersionStruct(int osVersion) =>
    _structBytes(kWithingsStructProbeOsVersion, <int>[
      (osVersion >> 8) & 0xff,
      osVersion & 0xff,
    ]);

/// The host's OWN outbound challenge — same shape as the one the device
/// sends, built rather than parsed.
Uint8List buildChallengeStruct(String macAddress, List<int> challenge) {
  final macBytes = macAddress.codeUnits;
  return _structBytes(kWithingsStructChallenge, <int>[
    macBytes.length & 0xff,
    ...macBytes,
    challenge.length & 0xff,
    ...challenge,
  ]);
}

Uint8List buildChallengeResponseStruct(List<int> response) => _structBytes(
      kWithingsStructChallengeResponse,
      <int>[response.length & 0xff, ...response],
    );

/// `(macAddress, challenge bytes)` out of a device-sent Challenge structure's
/// payload, or null on a payload too short to hold its own declared fields.
(String, Uint8List)? parseChallengeStruct(Uint8List payload) {
  if (payload.isEmpty) return null;
  var i = 0;
  final macLen = payload[i++];
  if (i + macLen > payload.length) return null;
  final mac = String.fromCharCodes(payload, i, i + macLen);
  i += macLen;
  if (i >= payload.length) return null;
  final challengeLen = payload[i++];
  if (i + challengeLen > payload.length) return null;
  final challenge = Uint8List.sublistView(payload, i, i + challengeLen);
  return (mac, challenge);
}

/// The response bytes out of a device-sent ChallengeResponse structure's
/// payload, or null on one too short to hold its own declared length.
Uint8List? parseChallengeResponseStruct(Uint8List payload) {
  if (payload.isEmpty) return null;
  final len = payload[0];
  if (1 + len > payload.length) return null;
  return Uint8List.sublistView(payload, 1, 1 + len);
}

/// Null on anything malformed — trailing bytes too short to hold another
/// structure header, or a declared payload length that overruns the body —
/// rather than silently returning whatever structures parsed before the
/// break. A message with a well-formed outer header but a broken inner TLV
/// is rejected whole, not accepted with its tail quietly dropped.
List<WithingsStruct>? _parseStructs(Uint8List body) {
  final out = <WithingsStruct>[];
  var i = 0;
  while (i < body.length) {
    if (i + 4 > body.length) return null; // a stray tail, not a header
    final hdr = ByteData.sublistView(body, i, i + 4);
    final type = hdr.getUint16(0, Endian.big);
    final len = hdr.getUint16(2, Endian.big);
    final start = i + 4;
    final end = start + len;
    if (end > body.length) return null; // declared length overruns the body
    out.add(WithingsStruct(type, Uint8List.sublistView(body, start, end)));
    i = end;
  }
  return out;
}

/// A complete, reassembled message (see [WithingsReassembler]) into its
/// message-level type and structures. Null on anything shorter than a
/// header, wrongly tagged, or whose declared `structLen` does not match what
/// actually followed it — a malformed message is dropped, never guessed at.
WithingsMessage? parseWithingsMessage(Uint8List bytes) {
  if (bytes.length < 5 || bytes[0] != 0x01) return null;
  final hdr = ByteData.sublistView(bytes, 0, 5);
  final type = hdr.getUint16(1, Endian.big);
  final structLen = hdr.getUint16(3, Endian.big);
  if (bytes.length - 5 != structLen) return null;
  final structs = _parseStructs(Uint8List.sublistView(bytes, 5));
  if (structs == null) return null;
  return WithingsMessage(type, structs);
}

/// Buffers notification chunks into complete logical messages.
///
/// A byte-0 value of 0x01 marks the START of a message; every chunk after
/// that — whatever its own first byte happens to be — is a continuation.
/// That is what keeps a payload byte that is coincidentally 0x01 from being
/// mistaken for a second message starting mid-stream, and it is needed even
/// though nothing here decodes payloads: a single logical reply routinely
/// spans several notification packets, and archiving a fragment as if it
/// were a complete record banks junk.
class WithingsReassembler {
  final BytesBuilder _buf = BytesBuilder();
  bool _active = false;

  /// Feed one notification's bytes. Returns the complete message once the
  /// accumulated post-header length reaches the declared `structLen`, else
  /// null.
  Uint8List? feed(List<int> chunk) {
    if (!_active) {
      if (chunk.isEmpty || chunk[0] != 0x01) return null; // a stray tail
      _buf.clear();
      _active = true;
    }
    _buf.add(chunk);
    if (_buf.length < 5) return null;
    final bytes = _buf.toBytes();
    final structLen =
        ByteData.sublistView(bytes, 3, 5).getUint16(0, Endian.big);
    if (bytes.length - 5 < structLen) return null;
    _active = false;
    return bytes;
  }
}

/// Slice one message's raw bytes into fixed-size GATT writes. Real devices
/// negotiate a larger MTU than this and would accept bigger chunks — see the
/// `ponytail:` note on [kWithingsWriteChunkSize].
List<Uint8List> chunkWithingsMessage(
  Uint8List message, {
  int chunkSize = kWithingsWriteChunkSize,
}) =>
    <Uint8List>[
      for (var i = 0; i < message.length; i += chunkSize)
        Uint8List.sublistView(
          message,
          i,
          i + chunkSize < message.length ? i + chunkSize : message.length,
        ),
    ];

/// `SHA1(nonce ++ macAddress_ascii ++ secret_ascii)` — the one proof this
/// family's session gate needs in both directions (the host answering the
/// device's nonce, and the host verifying the device's answer to its own).
/// Exposed so a test can pin it against a hand-computed vector without a
/// radio.
Uint8List withingsChallengeResponse(
  List<int> nonce,
  String macAddress, {
  String secret = kWithingsSteelHrSecret,
}) =>
    Uint8List.fromList(
      sha1
          .convert(<int>[...nonce, ...macAddress.codeUnits, ...secret.codeUnits])
          .bytes,
    );

/// One Steel HR / Activité session.
///
/// NOT const: [firstConnect] is a fact the host reads off the `device` row
/// at the start of each connection. There is no key and no cursor to hold
/// alongside it — the SHA1 secret is a shared constant (see the file
/// header), and there is no history to bookmark — which is the whole reason
/// this adapter is simpler than `OuraAdapter`.
class WithingsSteelHrAdapter extends BandAdapter {
  /// Whether this device row has never completed a session. True takes the
  /// no-auth INITIAL_CONNECT path; false takes the challenge-response path.
  final bool firstConnect;

  /// How long to wait for a reply the device owes us.
  final Duration replyTimeout;

  WithingsSteelHrAdapter({
    required this.firstConnect,
    this.replyTimeout = const Duration(seconds: 10),
  });

  @override
  BandEntry get entry => kWithingsSteelHr;

  /// NOTHING. Pairing, connecting and archiving raw bytes is the whole of
  /// what this file does — see the file header for why.
  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    final reassembler = WithingsReassembler();
    final inbox = _Inbox();
    final sub = link.notify(kWithingsWriteChar).listen(
          (rec) {
            final complete = reassembler.feed(rec.$2);
            if (complete == null) return;
            final msg = parseWithingsMessage(complete);
            if (msg != null) inbox.add(msg, Uint8List.fromList(complete));
          },
          onDone: inbox.close,
          onError: (Object _) => inbox.close(),
        );
    try {
      if (firstConnect) {
        final connectMsg =
            buildWithingsMessage(kWithingsMsgInitialConnect, const []);
        if (!await _sendChunked(link, connectMsg)) {
          link.log('withings_steel_hr: initial connect refused.');
          return;
        }
      } else if (!await _authenticate(link, inbox)) {
        return;
      }
      // The gate passed (first-ever connect, or a verified challenge). The
      // host reads this to know the row's `firstConnect` flag may now flip.
      yield const BandNote('withings_session_ready');

      // Everything from here on is archived verbatim and nothing else — see
      // [signals].
      while (true) {
        final rec = await inbox.next(replyTimeout);
        if (rec == null) return; // the link closed, or fell silent
        final (msg, raw) = rec;
        link.log('withings_steel_hr: archived message 0x'
            '${msg.type.toRadixString(16)} (${raw.length} bytes).');
        yield SampleBatch(const [], raw: [raw]);
      }
    } finally {
      await sub.cancel();
    }
  }

  Future<bool> _authenticate(BandLink link, _Inbox inbox) async {
    final probe = buildWithingsMessage(kWithingsMsgProbe, [
      // os/app/version identify the CLIENT to the device. Nothing in the
      // handshake gates on their values — only the challenge-response
      // proves the session — so these are innocuous placeholders rather
      // than an attempt to present as any particular vendor app.
      buildProbeStruct(os: 0, app: 0, version: 0),
      buildProbeOsVersionStruct(0),
    ]);
    if (!await _sendChunked(link, probe)) {
      link.log('withings_steel_hr: probe write refused.');
      return false;
    }

    final challengeMsg = await inbox.firstWhere(
      (m) => m.type == kWithingsMsgChallenge,
      replyTimeout,
    );
    if (challengeMsg == null) {
      link.log('withings_steel_hr: no challenge from the device.');
      return false;
    }
    final challengeStruct = challengeMsg.struct(kWithingsStructChallenge);
    final parsed =
        challengeStruct == null ? null : parseChallengeStruct(challengeStruct.payload);
    if (parsed == null) {
      link.log('withings_steel_hr: challenge message carried no usable '
          'Challenge structure.');
      return false;
    }
    final (macAddress, deviceNonce) = parsed;

    final ourResponse = withingsChallengeResponse(deviceNonce, macAddress);
    final ourNonce = _random16Bytes();
    final answer = buildWithingsMessage(kWithingsMsgChallenge, [
      buildChallengeResponseStruct(ourResponse),
      buildChallengeStruct(macAddress, ourNonce),
    ]);
    if (!await _sendChunked(link, answer)) {
      link.log('withings_steel_hr: challenge-response write refused.');
      return false;
    }

    final probeReply = await inbox.firstWhere(
      (m) => m.type == kWithingsMsgProbe,
      replyTimeout,
    );
    if (probeReply == null) {
      link.log('withings_steel_hr: no probe reply after the challenge.');
      return false;
    }
    final crStruct = probeReply.struct(kWithingsStructChallengeResponse);
    final deviceResponse =
        crStruct == null ? null : parseChallengeResponseStruct(crStruct.payload);
    final expected = withingsChallengeResponse(ourNonce, macAddress);
    if (deviceResponse == null || !_bytesEqual(deviceResponse, expected)) {
      link.log('withings_steel_hr: challenge response mismatch; treating '
          'the session as unauthenticated.');
      return false;
    }
    return true;
  }

  Future<bool> _sendChunked(BandLink link, Uint8List message) async {
    for (final chunk in chunkWithingsMessage(message)) {
      if (!await link.write(kWithingsWriteChar, chunk)) return false;
    }
    return true;
  }

  Uint8List _random16Bytes() {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Messages off the notify characteristic, buffered so a reply landing
/// before anyone is waiting is not dropped. The same small shape as
/// `oura.dart`'s private `_Inbox`, written fresh here — one buffering class
/// for one file is not worth a cross-adapter import.
class _Inbox {
  final List<(WithingsMessage, Uint8List)> _buf = [];
  Completer<(WithingsMessage, Uint8List)?>? _waiter;
  bool _closed = false;

  void add(WithingsMessage msg, Uint8List raw) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete((msg, raw));
      return;
    }
    _buf.add((msg, raw));
  }

  void close() {
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }

  Future<(WithingsMessage, Uint8List)?> next(Duration timeout) {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    if (_closed) return Future.value(null);
    final w = Completer<(WithingsMessage, Uint8List)?>();
    _waiter = w;
    return w.future.timeout(timeout, onTimeout: () {
      if (identical(_waiter, w)) _waiter = null;
      return null;
    });
  }

  Future<WithingsMessage?> firstWhere(
    bool Function(WithingsMessage) test,
    Duration timeout,
  ) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < timeout) {
      final rec = await next(timeout - deadline.elapsed);
      if (rec == null) return null;
      if (test(rec.$1)) return rec.$1;
    }
    return null;
  }
}
