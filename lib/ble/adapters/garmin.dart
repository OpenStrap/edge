// A Garmin watch as a [BandAdapter]: open the Multi-Link channel, register
// GFDI, answer what the watch waits for (acks, time, device information,
// configuration), then download its health FIT files and decode them.
//
// THE HANDSHAKE. CLOSE_ALL (a missing answer is logged and registration goes
// on), then REGISTER_ML for GFDI: a PENDING_AUTH answer keeps waiting, an
// ALREADY_IN_USE answer moves to the multi-link characteristic it names.
// When the watch sends its configuration the phone answers with its own and,
// if the watch's bits ask for it (4 or 90), a HANDSHAKE_COMPLETE system
// event; only then does it ask for battery and start the sync.
//
// THE SYNC. Once the watch has sent its configuration (or a few seconds have
// passed without it), the phone downloads file index 0 — the directory — and
// then every health FIT file (monitoring, sleep, HRV status) it has not read
// at its current index, timestamp and size, so a file the watch keeps
// appending to is read again. Each chunk's running CRC is checked and
// acknowledged with the next offset; a chunk at the wrong offset is asked
// for again (three in a row abort the file), a CRC mismatch aborts it. A
// NOT_READY file is asked for again after a second, a few times. A finished
// file is decoded (`protocol`'s `garmin_fit.dart`), committed, and only then
// recorded as read; a file that failed is not, so the next session reads it.
// The session ends when the queue is empty, or at the window.
//
// NOTHING ON THE WATCH CHANGES. The archive flag is never sent; the watch
// keeps every file and this app remembers which ones it read.
//
// WHAT BECOMES WHAT: monitoring HR -> sparse samples (outside derivation,
// ASSUMPTIONS R6); steps -> a daily `steps` observation; the watch's sleep
// stages -> its hypnogram plus stage minutes; HRV status, resting HR, SpO2,
// respiration and stress -> attributed vendor observations.
//
// EXACTLY ONE RESPONSE for every inbound message other than a RESPONSE — an
// unanswered message leaves the watch stalled. A type with its own reply
// (time, device information, file chunks, protobuf) gets only that; a type
// this file does not handle gets status UNKNOWN_OR_NOT_SUPPORTED. A request
// in compact form is answered with its transaction id.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../compute/vendor_sleep.dart' show VendorEpoch;
import '../../data/observation.dart';
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// The request id this pass's one outstanding protobuf ask carries. A single
/// fixed value is enough: this session never has two requests in flight.
const int _kBatteryRequestId = 1;

/// The 128-bit form of multi-link characteristic `6A4E` + [short16].
String garminMlChar(int short16) =>
    '6a4e${short16.toRadixString(16).padLeft(4, '0')}-667b-11e3-949a-0800200c9a66';

/// The multi-link characteristics to use among [chars] (lowercase 128-bit
/// UUIDs present on the watch), or null when there is none.
///
/// The data (notify) characteristic is one of 6A4E2810..6A4E2819: [prefer]
/// when given and present, else the lowest present. Its write twin swaps the
/// `1` for a `2` (2813 -> 2823); a watch without it is written on the data
/// characteristic itself.
({String notify, String write})? garminMlPair(Iterable<String> chars,
    {int? prefer}) {
  final have = {for (final c in chars) c.toLowerCase()};
  final candidates = [
    if (prefer != null) prefer else for (var i = 0x2810; i <= 0x2819; i++) i,
  ];
  for (final n in candidates) {
    if (n < 0x2810 || n > 0x2819 || !have.contains(garminMlChar(n))) continue;
    final write = garminMlChar(n + 0x10);
    return (
      notify: garminMlChar(n),
      write: have.contains(write) ? write : garminMlChar(n),
    );
  }
  return null;
}

/// What a session reads as "already read": index -> (timestamp, size). Kept
/// in `sync_cursor` as `index:timestamp:size` joined by commas.
Map<int, (int, int)> garminDecodeReadFiles(String? s) => {
      for (final part in (s ?? '').split(','))
        if (part.split(':') case [final i, final t, final n]
            when int.tryParse(i) != null &&
                int.tryParse(t) != null &&
                int.tryParse(n) != null)
          int.parse(i): (int.parse(t), int.parse(n)),
    };

String garminEncodeReadFiles(Map<int, (int, int)> m) =>
    [for (final MapEntry(:key, value: (t, n)) in m.entries) '$key:$t:$n']
        .join(',');

/// The signals this watch supplies: monitoring HR, about once a minute.
/// Mirrored in `kAdapterSignals`.
const Map<InputSignal, Duration> kGarminSignals = {
  InputSignal.hrSparse: Duration(minutes: 1),
};

/// Shown next to every value the watch computed itself.
const String kGarminAttribution = 'Garmin';

int _defaultNowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
int _defaultUtcOffsetSeconds() => DateTime.now().timeZoneOffset.inSeconds;

class GarminAdapter extends BandAdapter {
  /// Wall-clock now, and this phone's current UTC offset — both injected so a
  /// fixture replay is deterministic.
  final int Function() nowSeconds;
  final int Function() utcOffsetSeconds;

  /// How long to wait for CLOSE_ALL_RESP before registering anyway.
  final Duration handshakeTimeout;

  /// How long to wait for REGISTER_ML_RESP, PENDING_AUTH answers included.
  final Duration registerTimeout;

  /// Upper bound on the session once GFDI is registered; it ends earlier
  /// when the file queue drains.
  final Duration sessionWindow;

  /// How long to wait for the watch's configuration before starting the
  /// file sync anyway.
  final Duration configWait;

  /// Pause before asking again for a NOT_READY file, and how many times.
  final Duration notReadyDelay;
  final int notReadyRetries;

  /// The health files already read, as [garminEncodeReadFiles] writes them.
  final String readFiles;

  /// The multi-link characteristics this watch exposes (see [garminMlPair]).
  final List<String> mlChars;

  /// Bytes one GATT write may carry (ATT MTU - 3). An outbound COBS stream
  /// is cut into pieces of one byte less, each behind the handle byte.
  final int maxWrite;

  const GarminAdapter({
    this.nowSeconds = _defaultNowSeconds,
    this.utcOffsetSeconds = _defaultUtcOffsetSeconds,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.registerTimeout = const Duration(seconds: 30),
    this.sessionWindow = const Duration(seconds: 120),
    this.configWait = const Duration(seconds: 3),
    this.notReadyDelay = const Duration(seconds: 1),
    this.notReadyRetries = 3,
    this.readFiles = '',
    this.mlChars = const [kGarminNotifyChar, kGarminWriteChar],
    this.maxWrite = 20,
  });

  @override
  BandEntry get entry => kGarmin;

  @override
  Map<InputSignal, Duration> get signals => kGarminSignals;

  /// COBS-encode one outbound GFDI frame and write it on [handle] to [char],
  /// cut into [maxWrite]-byte multi-link packets, in order. False for a
  /// handle this session never registered, or a refused write — both
  /// non-fatal to the caller, which only logs and moves on.
  Future<bool> _sendGfdi(
      BandLink link, String char, int? handle, Uint8List frame) async {
    if (handle == null) return false;
    final cobs = garminCobsEncode(frame);
    final piece = maxWrite - 1 < 1 ? 1 : maxWrite - 1;
    try {
      for (var o = 0; o < cobs.length; o += piece) {
        final end = o + piece < cobs.length ? o + piece : cobs.length;
        if (!await link.write(char, garminEncodeTx(handle, cobs.sublist(o, end)))) {
          return false;
        }
      }
      return true;
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
    var registerDone = Completer<GarminRegisterMlResponse?>();
    final pair = garminMlPair(mlChars);
    if (pair == null) {
      link.log('garmin: no multi-link data characteristic; ending the session.');
      return;
    }
    var notifyChar = pair.notify;
    var writeChar = pair.write;
    int? gfdiHandle;
    var dispatch = Future<void>.value();

    Future<bool> send(Uint8List frame) =>
        _sendGfdi(link, writeChar, gfdiHandle, frame);

    // ── file sync state ──
    var syncStarted = false;
    final read = garminDecodeReadFiles(readFiles);
    final queue = <GarminFileEntry>[];
    GarminFileEntry? entry; // null while the directory is being read
    int? fileSize;
    var fileCrc = 0;
    var lastOffset = -1; // offset of the last accepted chunk
    var badChunks = 0;
    var notReady = 0;
    final file = BytesBuilder(copy: false);

    void finish() {
      if (!events.isClosed) events.close();
    }

    /// Record [e] as read and tell the host, which persists it with its next
    /// commit.
    void markRead(GarminFileEntry e) {
      read[e.index] = (e.timestamp, e.size);
      if (!events.isClosed) {
        events.add(BandNote('garmin_fit_files', garminEncodeReadFiles(read)));
      }
    }

    Future<void> request(GarminFileEntry? e, {bool retry = false}) async {
      entry = e;
      fileSize = null;
      fileCrc = 0;
      lastOffset = -1;
      badChunks = 0;
      if (!retry) notReady = 0;
      file.clear();
      await send(garminBuildDownloadRequest(e?.index ?? 0));
    }

    Future<void> next() async {
      if (queue.isEmpty) {
        finish();
      } else {
        await request(queue.removeAt(0));
      }
    }

    /// Battery, then the directory. Once, on the watch's configuration or
    /// the [configWait] fallback.
    Future<void> startSync() async {
      if (syncStarted) return;
      syncStarted = true;
      await send(garminBuildProtobufRequest(
        requestId: _kBatteryRequestId,
        protoBytes: garminBatteryRequestProto(),
      ));
      await request(null);
    }

    Future<void> fileDone(Uint8List bytes) async {
      final e = entry;
      if (e == null) {
        final health =
            garminParseDirectory(bytes).where((x) => x.isHealthFit).toList();
        // A file gone from the watch is forgotten; its index may come back
        // as another file.
        read.removeWhere((i, _) => !health.any((x) => x.index == i));
        queue
          ..addAll(health.where((x) => read[x.index] != (x.timestamp, x.size)))
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        link.log('garmin: ${queue.length} health file(s) to read.');
      } else if (!events.isClosed) {
        for (final ev in _decodeFit(link, bytes)) {
          events.add(ev);
        }
        // The read-file note rides the checkpoint's commit: the host writes
        // it in the same transaction as this file's samples, never before.
        markRead(e);
        events.add(OffloadCheckpoint(() async => true));
      }
      await next();
    }

    Future<void> onDownloadStatus(
        ({bool ok, int downloadStatus, int size}) status) async {
      final e = entry;
      if (status.ok && status.size > 0) {
        fileSize = status.size;
        return;
      }
      final idx = e?.index ?? 0;
      if (status.downloadStatus == kGarminDownloadNotReady &&
          notReady < notReadyRetries) {
        notReady++;
        link.log('garmin: file $idx not ready; asking again.');
        await Future<void>.delayed(notReadyDelay);
        if (!events.isClosed) await request(e, retry: true);
        return;
      }
      link.log('garmin: download of file $idx refused '
          '(status ${status.downloadStatus}).');
      // No such file, or never readable: asking again next time is pointless.
      if (e != null &&
          (status.downloadStatus == kGarminDownloadNoSuchIndex ||
              status.downloadStatus == kGarminDownloadNotReadable)) {
        markRead(e);
      }
      await next();
    }

    Future<void> onChunk(GarminGfdiFrame f) async {
      final chunk = garminParseFileChunk(f);
      final size = fileSize;
      if (chunk == null || size == null) return;
      Future<void> ack(int status) => send(garminBuildChunkAck(file.length,
          status: status, responseType: garminResponseType(f.type)));
      if (chunk.offset == lastOffset && chunk.offset != file.length) {
        await ack(kGarminTransferOk); // a repeat of the last accepted chunk
        return;
      }
      if (chunk.offset != file.length) {
        if (++badChunks >= 3) {
          link.log('garmin: file ${entry?.index ?? 0} out of step; aborted.');
          await ack(kGarminTransferAbort);
          await next();
        } else {
          await ack(kGarminTransferOffsetMismatch);
        }
        return;
      }
      final crc = garminCrc16(chunk.data, fileCrc);
      if (crc != chunk.crc) {
        link.log('garmin: file ${entry?.index ?? 0} failed its CRC; aborted.');
        await ack(kGarminTransferCrcMismatch);
        await next();
        return;
      }
      badChunks = 0;
      lastOffset = chunk.offset;
      file.add(chunk.data);
      fileCrc = crc;
      await ack(kGarminTransferOk);
      if (file.length >= size) await fileDone(file.toBytes());
    }

    Future<void> ackAndDispatch(GarminGfdiFrame f) async {
      final type = garminMessageType(f.type);
      final rt = garminResponseType(f.type);
      Future<void> ack([int status = kGarminStatusAck]) => send(
          garminBuildStatusAck(type, status: status, responseType: rt));
      switch (type) {
        case kGarminMsgResponse:
          final status = garminParseDownloadStatus(f);
          if (status != null) await onDownloadStatus(status);
        case kGarminMsgConfiguration:
          await ack();
          await send(garminBuildConfigurationReply());
          final bits = garminParseConfiguration(f) ?? const <int>{};
          if (bits.contains(kGarminCapDeviceInitiatesSync) ||
              bits.contains(kGarminCapSync2)) {
            await send(garminBuildSystemEvent(kGarminEventHandshakeComplete));
          }
          await startSync();
        case kGarminMsgFileTransferData:
          await onChunk(f);
        case kGarminMsgCurrentTimeRequest:
          final reply = garminBuildTimeResponse(
            f,
            nowUnixSeconds: nowSeconds(),
            utcOffsetSeconds: utcOffsetSeconds(),
          );
          if (reply != null) {
            await send(reply);
          } else {
            await ack();
          }
        case kGarminMsgDeviceInformation:
          await send(garminBuildDeviceInfoReply(responseType: rt));
          final info = garminParseDeviceInformation(f);
          if (info != null && !events.isClosed) {
            final model =
                info.deviceModel.isNotEmpty ? info.deviceModel : info.deviceName;
            if (model.isNotEmpty) events.add(BandNote('model', model));
            events.add(BandNote('firmware', info.firmware));
          }
        case kGarminMsgProtobufRequest || kGarminMsgProtobufResponse:
          final pf = garminParseProtobufFrame(f);
          if (pf == null) {
            await ack();
            break;
          }
          await send(garminBuildProtobufAck(f, pf));
          if (type != kGarminMsgProtobufResponse) break;
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
          await ack();
          final ev = garminParseSystemEvent(f);
          if (ev != null) {
            link.log('garmin: system event ${ev.$1} (value ${ev.$2}).');
          }
        default:
          await ack(kGarminStatusUnknown);
      }
    }

    void onDisconnected() {
      if (!closeAllDone.isCompleted) closeAllDone.complete(false);
      if (!registerDone.isCompleted) registerDone.complete(null);
      if (!events.isClosed) events.close();
    }

    void onNotify((int, List<int>) rec) {
      final bytes = Uint8List.fromList(rec.$2);
      final decoded = garminDecodeMlr(bytes);
      if (decoded is GarminCloseAllAck) {
        if (!closeAllDone.isCompleted) closeAllDone.complete(true);
        return;
      }
      if (decoded is GarminRegisterMlResponse &&
          decoded.service == kGarminServiceGfdi) {
        if (decoded.status == kGarminRegisterPendingAuth) {
          link.log('garmin: the watch is asking to allow this phone; waiting.');
          return;
        }
        if (!registerDone.isCompleted) registerDone.complete(decoded);
        return;
      }
      final handle = gfdiHandle;
      if (decoded is GarminHandleClosed && decoded.handle == handle) {
        link.log('garmin: watch closed GFDI handle $handle; ending the session.');
        gfdiHandle = null; // any queued write is refused
        archived.add(bytes);
        finish();
        return;
      }
      if (decoded is GarminMlrData && handle != null && decoded.handle == handle) {
        // protocol's garminDecodeMlr already strips the routing byte
        // (protocol#70) — decoded.payload IS the COBS/GFDI stream.
        for (final frame in cobs.feed(decoded.payload)) {
          archived.add(frame);
          final gfdi = garminParseGfdiFrame(frame);
          // In arrival order: chunks must append in sequence.
          if (gfdi != null) {
            dispatch = dispatch.then((_) => ackAndDispatch(gfdi));
          }
        }
        return;
      }
      // Control-channel noise this file has no decode for, another client's
      // answer, or data on a handle this session never registered — banked,
      // never acted on.
      archived.add(bytes);
    }

    StreamSubscription<(int, List<int>)> listen(String char) =>
        link.notify(char).listen(
              onNotify,
              onDone: onDisconnected,
              onError: (Object _) => onDisconnected(),
            );
    var sub = listen(notifyChar);

    try {
      if (!await link.write(
          writeChar, garminEncodeTx(0, garminCloseAllRequest()))) {
        link.log('garmin: close-all write refused; ending the session.');
        return;
      }
      final closed =
          await closeAllDone.future.timeout(handshakeTimeout, onTimeout: () => false);
      if (!closed) {
        link.log('garmin: failed to close existing handles; continuing '
            'registration.');
      }

      GarminRegisterMlResponse? reg;
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!await link.write(writeChar,
            garminEncodeTx(0, garminRegisterMlRequest(kGarminServiceGfdi)))) {
          link.log('garmin: register-ml write refused; ending the session.');
          return;
        }
        reg = await registerDone.future
            .timeout(registerTimeout, onTimeout: () => null);
        final alt = reg?.alternateChar;
        if (attempt > 0 ||
            reg?.status != kGarminRegisterAlreadyInUse ||
            alt == null) {
          break;
        }
        final moved = garminMlPair(mlChars, prefer: alt);
        if (moved == null) {
          link.log('garmin: the watch named multi-link characteristic '
              '${alt.toRadixString(16)}, which it does not expose.');
          return;
        }
        link.log('garmin: GFDI in use; registering on '
            '${alt.toRadixString(16)} instead.');
        await sub.cancel();
        notifyChar = moved.notify;
        writeChar = moved.write;
        registerDone = Completer<GarminRegisterMlResponse?>();
        sub = listen(notifyChar);
      }
      if (reg == null || !reg.accepted) {
        link.log('garmin: the watch declined the GFDI channel (status '
            '${reg?.status ?? "none"}).');
        return;
      }
      gfdiHandle = reg.handle;

      // A watch that never sends its configuration still gets synced.
      final kick = Timer(configWait, () => unawaited(startSync()));
      final timer = Timer(sessionWindow, () {
        if (!events.isClosed) events.close();
      });
      try {
        yield* events.stream;
      } finally {
        timer.cancel();
        kick.cancel();
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

/// One downloaded FIT file into events: HR samples (banked with the file's
/// bytes), and the watch's own numbers as attributed observations. A file
/// that is not valid FIT is banked raw and decoded no further.
List<BandEvent> _decodeFit(BandLink link, Uint8List bytes) {
  final List<FitMessage> m;
  try {
    m = parseFit(bytes);
  } on FormatException catch (e) {
    link.log('garmin: a downloaded file is not valid FIT (${e.message}).');
    return [SampleBatch(const [], raw: [bytes])];
  }
  DateTime at(int sec) => DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  DateTime dayOf(int sec) {
    final t = at(sec);
    return DateTime(t.year, t.month, t.day);
  }

  Observation obs(DateTime t, String name, num value, String unit,
          {bool ours = false}) =>
      Observation(
        at: t,
        sourceKind: ObservationSource.vendor,
        key: ours ? name : null,
        vendorKey: ours ? null : name,
        value: value,
        unit: unit,
        attribution: kGarminAttribution,
      );

  List<Observation> dailyMeans(
      List<(int, num)> xs, String name, String unit) {
    final byDay = <DateTime, List<num>>{};
    for (final (t, v) in xs) {
      (byDay[dayOf(t)] ??= []).add(v);
    }
    return [
      for (final MapEntry(:key, :value) in byDay.entries)
        obs(key, name, value.fold<double>(0, (a, b) => a + b) / value.length,
            unit),
    ];
  }

  final samples = [
    for (final (t, hr) in fitMonitoringHr(m))
      if (hr >= 25 && hr <= 230)
        NeutralSample(anchor: TimeAnchor.measured, tsEpoch: t, hr: hr),
  ];
  final stages = fitSleepStages(m);
  final rows = <Observation>[
    for (final MapEntry(:key, :value) in fitDailySteps(m).entries)
      obs(key, 'steps', value, 'steps', ours: true),
    for (final (t, v) in fitHrvLastNight(m)) obs(at(t), 'hrv_last_night_avg', v, 'ms'),
    for (final (t, v) in fitRestingHr(m)) obs(dayOf(t), 'resting_hr', v, 'bpm'),
    ...dailyMeans(fitSpo2(m), 'spo2_avg', '%'),
    ...dailyMeans(fitRespiration(m), 'respiration_avg', 'br/min'),
    ...dailyMeans(fitStress(m), 'stress_avg', ''),
  ];
  if (stages.isNotEmpty) {
    final minutes = <String, int>{};
    for (final (a, b, st) in stages) {
      minutes[st] = (minutes[st] ?? 0) + (b - a) ~/ 60;
    }
    final wake = at(stages.last.$2);
    for (final MapEntry(:key, :value) in minutes.entries) {
      rows.add(obs(wake, 'sleep_${key}_min', value, 'min'));
    }
  }
  return [
    SampleBatch(samples, raw: [bytes]),
    if (stages.isNotEmpty)
      VendorHypnogram('garmin', [
        for (final (a, b, st) in stages) VendorEpoch(a, b, st),
      ]),
    if (rows.isNotEmpty) VendorScalars(rows),
  ];
}
