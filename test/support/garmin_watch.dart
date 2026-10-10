// Test support: a minimal FIT writer and a scripted Garmin watch that speaks
// the real wire — Multi-Link close-all / register, COBS + GFDI, the download
// request / status / chunked transfer with a running CRC — serving a
// directory plus the FIT files it is given.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Builds a FIT file: definitions + data records, little-endian.
class FitWriter {
  final _recs = <int>[];

  void define(int local, int global, List<(int field, int size, int base)> f) {
    _recs.addAll([0x40 | local, 0, 0, global & 0xff, global >> 8, f.length]);
    for (final (n, s, b) in f) {
      _recs.addAll([n, s, b]);
    }
  }

  void data(int local, List<int> bytes) => _recs.addAll([local, ...bytes]);

  Uint8List build() {
    final n = _recs.length;
    final body = [
      12, 0x20, 0x08, 0x08, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, 0,
      ...'.FIT'.codeUnits, ..._recs,
    ];
    final crc = garminCrc16(body);
    return Uint8List.fromList([...body, crc & 0xff, crc >> 8]);
  }
}

List<int> u16le(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> u32le(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

/// FIT seconds for a Unix instant.
int fitSec(int unix) => unix - kFitEpochOffset;

/// A scripted watch. [files] maps directory index -> (sub-type, timestamp,
/// FIT bytes); index 0 (the directory) is generated from them, behind its
/// 16-byte header record. [notReady] answers a download of that index with
/// NOT_READY that many times before serving it (or always, for a count
/// above the phone's retries).
class GarminWatchScript {
  final Map<int, (int, int, Uint8List)> files;
  static const int handle = 3;
  final int chunk;
  final Map<int, int> notReady;

  /// The capability bits the watch sends in its CONFIGURATION once GFDI
  /// opens; 4 asks for HANDSHAKE_COMPLETE.
  final Set<int> configBits;
  final downloaded = <int>[];

  /// Every SYSTEM_EVENT type the phone sent.
  final systemEvents = <int>[];
  final _rx = GarminCobsReassembler();

  GarminWatchScript(this.files,
      {this.chunk = 200, this.notReady = const {}, this.configBits = const {4}});

  Uint8List get _directory => Uint8List.fromList([
        ...List.filled(16, 0), // header record
        for (final MapEntry(:key, value: (sub, ts, bytes)) in files.entries) ...[
          ...u16le(key), kGarminFileTypeFit, sub, ...u16le(key), 0, 0,
          ...u32le(bytes.length), ...u32le(ts - kGarminEpochOffset),
        ],
      ]);

  /// A handle registered non-reliable is sent on with a bare routing byte.
  List<int> _toPhone(Uint8List gfdi) => [handle, ...garminCobsEncode(gfdi)];

  /// `0 | type | client id 2 | rest`: every control answer names the client.
  static List<int> control(int type, List<int> rest) =>
      [0x00, type, 2, 0, 0, 0, 0, 0, 0, 0, ...rest];

  /// The watch's notifications in answer to one phone write.
  List<List<int>> reply(List<int> written) {
    if (written.isEmpty) return const [];
    if (written[0] == 0 && written.length > 1) {
      if (written[1] == 0x05) return [control(0x06, [0, 0, 0])]; // close-all ack
      if (written[1] == 0x00 && written.length >= 12) {
        // REGISTER_ML -> accepted on [handle], for the service asked for,
        // then the watch's configuration.
        final bits = List.filled(
            configBits.fold(0, (a, b) => b > a ? b : a) ~/ 8 + 1, 0);
        for (final b in configBits) {
          bits[b ~/ 8] |= 1 << (b % 8);
        }
        return [
          control(0x01, [written[10], written[11], 0, handle]),
          _toPhone(garminBuildGfdiFrame(
              kGarminMsgConfiguration, [bits.length, ...bits])),
        ];
      }
      return const [];
    }
    if (written[0] != handle) return const [];
    return [
      for (final raw in _rx.feed(written.sublist(1)))
        if (garminParseGfdiFrame(raw) case final f?) ..._answer(f),
    ];
  }

  List<List<int>> _answer(GarminGfdiFrame f) {
    final type = garminMessageType(f.type);
    if (type == kGarminMsgSystemEvent && f.payload.isNotEmpty) {
      systemEvents.add(f.payload[0]);
    }
    if (type != kGarminMsgDownloadRequest) return const [];
    final index = f.payload[0] | (f.payload[1] << 8);
    List<int> status(int s, int size) => _toPhone(garminBuildGfdiFrame(
        kGarminMsgResponse,
        [...u16le(kGarminMsgDownloadRequest), 0, s, ...u32le(size)]));
    final left = notReady[index] ?? 0;
    if (left > 0) {
      notReady[index] = left - 1;
      return [status(kGarminDownloadNotReady, 0)];
    }
    final bytes = index == 0 ? _directory : files[index]?.$3;
    if (bytes == null) return [status(kGarminDownloadNoSuchIndex, 0)];
    downloaded.add(index);
    final out = <List<int>>[status(0, bytes.length)];
    var crc = 0;
    for (var o = 0; o < bytes.length; o += chunk) {
      final part = bytes.sublist(o, o + chunk > bytes.length ? bytes.length : o + chunk);
      crc = garminCrc16(part, crc);
      out.add(_toPhone(garminBuildGfdiFrame(kGarminMsgFileTransferData,
          [0, ...u16le(crc), ...u32le(o), ...part])));
    }
    return out;
  }
}
