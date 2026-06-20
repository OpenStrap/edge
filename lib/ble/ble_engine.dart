// BLE engine — the BLE client for the WHOOP 4.0 band, on flutter_blue_plus.
//
// Responsibilities: service-filtered scan, connect, subscribe to the three notify
// characteristics (each with its OWN length-based reassembler), the 5-packet INIT,
// the historical-sync drain with the correct 3-state ACK, live-stream enable/disable,
// heartbeat + battery poll, and a graceful, SAFE shutdown.
//
// SAFETY (): we NEVER send FORCE_TRIM (0x19), REBOOT (0x1D), or
// TOGGLE_PERSISTENT_R21 (0x9A). Optical is wrist-gated (0x6B only). The drain is
// non-destructive — the cursor advances on ACK and persists across connections.
//
// SEQ DISCIPLINE: live commands use a HIGH counter (0xA0+); sync ACKs use a LOW
// counter (5+, continuing from INIT 0..4). The two never collide.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/commands.dart';
import '../protocol/constants.dart';
import '../protocol/framing.dart';
import '../protocol/records.dart';
import '../data/models.dart';

typedef SampleSink = Future<void> Function(Sample? sample, RawRecord raw);
typedef StateSink = void Function(DeviceState state);
typedef LogSink = void Function(String line);
typedef EventSink = void Function(int eventId, int tsEpoch, String hex);
typedef BatchSink = Future<void> Function(
    List<RawRecord> raws, List<Sample?> samples);

class SyncReport {
  final int records;
  final int batches;
  final bool complete;
  SyncReport(this.records, this.batches, this.complete);
}

class BleEngine {
  final SampleSink onRecord;
  final StateSink onState;
  final LogSink? log;
  final EventSink? onEvent;

  /// If provided, historical-drain records are buffered and flushed in batches
  /// (one DB transaction per ACK boundary) instead of one-by-one via [onRecord].
  /// Much faster on large drains. Live records still go through [onRecord].
  final BatchSink? onRecordsBatch;

  BleEngine(
      {required this.onRecord,
      required this.onState,
      this.log,
      this.onEvent,
      this.onRecordsBatch});

  // Drain buffer (historical 0x2F records), flushed before each sync ACK.
  final List<RawRecord> _drainRaws = [];
  final List<Sample?> _drainSamples = [];

  final DeviceState state = DeviceState();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdTo;
  final _asm = {
    'cmd_from': FrameReassembler(),
    'events': FrameReassembler(),
    'data': FrameReassembler(),
  };
  final List<StreamSubscription> _subs = [];

  int _cmdSeq = 0xA0; // live commands (high range)
  int _syncSeq = 5; // batch ACKs (continue from INIT 0..4)
  Future<void> _writeChain = Future.value();

  bool _syncComplete = false;
  int _syncRecords = 0;
  int _syncBatches = 0;
  int _firstTs = 0; // first historical record ts this session
  int _lastTs = 0; // last historical record ts this session
  bool _liveEnabled = false;
  Timer? _heartbeat;

  void _setConn(String c) {
    state.connection = c;
    onState(state);
  }

  void _log(String s) => log?.call(s);

  // ── scan ───────────────────────────────────────────────────────────────────
  /// Service-filtered scan (mandatory on iOS/macOS — passive scans hide the UUID).
  /// Canonical flutter_blue_plus pattern: start ONE scan, let the timeout stop it,
  /// stop early when we find a match. NEVER rapid start/stop (Android throttles →
  /// SCANNING_TOO_FREQUENTLY / status=6).
  Future<BluetoothDevice?> scan({Duration timeout = const Duration(seconds: 12)}) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _setConn('scanning');
    final svc = Guid(GattUuids.service);
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames = r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase());
        if (found == null &&
            (name.contains('whoop') ||
                advNames.any((s) => s.startsWith('61080001')))) {
          found = r.device;
          FlutterBluePlus.stopScan(); // end early — the loop below will exit
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: [svc], timeout: timeout);
      // startScan returns once started; wait until scanning actually stops
      // (either our early stopScan above, or the timeout).
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      _log('scan error: $e');
    } finally {
      await sub.cancel();
    }
    if (found == null) {
      _setConn('disconnected');
      _log('No WHOOP found (force-quit the official app; band must be free).');
    }
    return found;
  }

  /// Reconnect to a previously-paired device by its persisted remote id.
  Future<bool> connectToRemoteId(String remoteId) =>
      connect(BluetoothDevice.fromId(remoteId));

  bool get isConnected => state.connection == 'connected' || state.connection == 'syncing';

  // ── connect ──────────────────────────────────────────────────────────────────
  Future<bool> connect(BluetoothDevice device) async {
    _device = device;
    state.address = device.remoteId.str;
    _setConn('connecting');
    for (final a in _asm.values) {
      a.reset();
    }
    try {
      await device.connect(timeout: const Duration(seconds: 20), autoConnect: false);
    } catch (e) {
      _log('connect failed: $e');
      _setConn('disconnected');
      return false;
    }
    // Bond. On Android we must explicitly createBond (the strap gates commands
    // behind encryption — without a bond the ACK/commands are silently dropped).
    // On iOS, bonding happens implicitly on the first write-with-response.
    if (Platform.isAndroid) {
      try {
        await device.createBond();
        _log('Bonded (or already bonded).');
      } catch (e) {
        _log('createBond: $e');
      }
    }

    // Request a larger MTU on Android (no-op on iOS).
    try {
      await device.requestMtu(247);
    } catch (_) {}

    // Ask Android for a fast connection interval during the drain — this is the
    // biggest BLE throughput lever (2–4× on bulk transfer). Android-only; iOS picks
    // a fast interval on its own when there's pending data.
    if (Platform.isAndroid) {
      try {
        await device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high);
      } catch (_) {}
    }

    final services = await device.discoverServices();
    BluetoothService? svc;
    for (final s in services) {
      if (s.uuid.str.toLowerCase().startsWith('61080001')) svc = s;
    }
    if (svc == null) {
      _log('Harvard service not found on device.');
      _setConn('disconnected');
      return false;
    }
    BluetoothCharacteristic? find(String prefix) {
      for (final c in svc!.characteristics) {
        if (c.uuid.str.toLowerCase().startsWith(prefix)) return c;
      }
      return null;
    }

    _cmdTo = find('61080002');
    final cmdFrom = find('61080003');
    final events = find('61080004');
    final data = find('61080005');
    if (_cmdTo == null || cmdFrom == null || events == null || data == null) {
      _log('Missing one or more Harvard characteristics.');
      _setConn('disconnected');
      return false;
    }
    await _subscribe(cmdFrom, 'cmd_from');
    await _subscribe(events, 'events');
    await _subscribe(data, 'data');

    _subs.add(device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _setConn('disconnected');
      }
    }));

    // Set the strap's RTC to real wall-clock time. The band ships with an unset
    // clock (drifts to bogus dates), so every record/event would otherwise carry
    // a garbage timestamp. SET_CLOCK is non-destructive (it's what the official
    // app does each connect); records stamped after this carry real unix time.
    await setClock();

    // Heartbeat: the reference client sends LINK_VALID every ~10s to keep the link alive
    // during the drain. Without it the band can behave oddly mid-sync.
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _send(Cmd.linkValid, const [0x00]);
    });

    _setConn('connected');
    _log('Connected + subscribed.');
    return true;
  }

  Future<void> _subscribe(BluetoothCharacteristic c, String role) async {
    await c.setNotifyValue(true);
    _subs.add(c.onValueReceived.listen((chunk) {
      for (final frame in _asm[role]!.feed(chunk)) {
        if (frame.valid) _onFrame(role, frame);
      }
    }));
  }

  // ── write (serialized) ───────────────────────────────────────────────────────
  // CRITICAL: WHOOP's command characteristic is write-WITHOUT-response (the reference client
  // writes with response=False). A write-with-response on a WoR-only characteristic
  // never lands — which silently breaks the historical ACK and the band re-sends the
  // same batch forever. So we prefer writeWithoutResponse whenever the char supports it.
  Future<void> _write(Uint8List raw) {
    final completer = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        // WRITE-WITH-RESPONSE. Verified on real hardware (5.454.0): with-response
        // is what triggers BLE bonding (the auth challenge) AND gets commands
        // actually delivered + acknowledged. Write-WITHOUT-response can't bond and
        // gets silently dropped — that was the bug that broke the whole sync.
        await _cmdTo!.write(raw, withoutResponse: false);
      } catch (e) {
        _log('write error: $e');
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _send(int opcode, List<int> payload) async {
    // GUARD: never emit a dangerous opcode from the engine.
    if (dangerousCmds.contains(opcode)) {
      _log('REFUSED dangerous opcode 0x${opcode.toRadixString(16)}');
      return;
    }
    final frame = buildCommand(_cmdSeq, opcode, payload);
    _cmdSeq = (_cmdSeq + 1) & 0xFF;
    if (_cmdSeq < 0xA0) _cmdSeq = 0xA0;
    await _write(frame);
  }

  // ── frame handling ─────────────────────────────────────────────────────────
  void _onFrame(String role, Frame frame) {
    final pt = frame.packetType;
    if (pt == PacketType.metadata) {
      unawaited(_handleSyncMarker(frame));
      return;
    }
    // LIVE streams: realtime HR/RR (0x28), realtime R10 (0x2B), IMU (0x33).
    // Raw-first — store + queue for upload; the backend field-decodes. Never
    // touch the historical-sync bookkeeping (_syncRecords/_lastTs) or the
    // live-edge detection, which key off 0x2F only.
    if (pt == PacketType.realtimeData ||
        pt == PacketType.realtimeRawData ||
        pt == PacketType.realtimeImuStream) {
      final raw = RawRecord(
        counter: _counterFromInner(frame.inner),
        packetType: pt,
        hex: _innerHex(frame.inner),
        capturedAt: DateTime.now().millisecondsSinceEpoch,
      );
      onRecord(null, raw); // store raw only; no edge decode (dumb pipe)
      // No early return here — allow fallthrough to decodeFrame and _absorbState
      // so the UI gets live telemetry updates.
    }
    if (pt == PacketType.historicalData) {
      _syncRecords++;
      final recType = frame.inner.length > 1 ? frame.inner[1] : -1;
      final counter = _counterFromInner(frame.inner);
      final raw = RawRecord(
        counter: counter,
        packetType: pt,
        hex: _innerHex(frame.inner),
        capturedAt: DateTime.now().millisecondsSinceEpoch,
      );
      // Track timestamp span of this drain (to see if the cursor persists/advances
      // across syncs). Read ts from the generic header [7:11].
      if (frame.inner.length >= 11) {
        final ts = u32(frame.inner, 7);
        if (ts > 1000000000) {
          if (_firstTs == 0) _firstTs = ts;
          _lastTs = ts;
        }
      }
      Sample? sample;
      if (recType == Record.r24) {
        final r = parseR24(frame.inner);
        if (r != null) {
          sample = Sample(
            tsEpoch: r.tsEpoch,
            counter: r.counter,
            hr: r.hr,
          );
        }
      } else if (recType == Record.r10) {
        // Historical R10: HR + real unix ts (no spo2/temp/rhr in this record).
        final r = parseR10Lite(frame.inner);
        if (r != null) {
          sample = Sample(
            tsEpoch: r.tsEpoch,
            counter: r.counter,
            hr: r.hr,
          );
        }
      }
      // Background sync: store ONLY. Never touch the live display — the screen
      // shows genuine live-stream data (0x2B/0x28), not historical drain values.
      // Buffer for a batched DB flush (flushed before each ACK) when available;
      // otherwise fall back to per-record insert.
      if (onRecordsBatch != null) {
        _drainRaws.add(raw);
        _drainSamples.add(sample);
      } else {
        onRecord(sample, raw);
      }
      return;
    }
    if (pt == PacketType.commandResponse) {
      _log('[RESP] op=0x${frame.opcode.toRadixString(16)} '
          'inner=${_innerHex(frame.inner)}');
    } else if (pt == PacketType.event) {
      _log('[EVENT] ${_innerHex(frame.inner)}');
      // Persist every event (live or from sync) so nothing is lost if upload fails.
      final e = parseEvent(frame.inner);
      if (e != null) onEvent?.call(e.eventId, e.tsEpoch, _innerHex(frame.inner));
    }
    final decoded = decodeFrame(frame);
    _absorbState(decoded);
  }

  void _absorbState(Decoded d) {
    final f = d.fields;
    if (f.containsKey('alarm_epoch')) {
      final e = f['alarm_epoch'] as int;
      // Only trust plausible future-ish epochs (the GET format is best-effort).
      state.alarmEpoch = e > 1000000000 ? e : null;
      onState(state);
    }
    if (f.containsKey('strap_name')) {
      state.strapName = f['strap_name'] as String;
      onState(state);
    }
    if (f.containsKey('battery_pct')) {
      state.batteryPct = (f['battery_pct'] as num).toDouble();
      onState(state);
    }
    if (f.containsKey('charging')) {
      state.charging = f['charging'] as bool;
      onState(state);
    }
    if (f.containsKey('on_wrist')) {
      state.wristOn = f['on_wrist'] as bool;
      onState(state);
    }
    if (d.kind == 'cmd_response' && f['hello'] is HelloInfo) {
      final h = f['hello'] as HelloInfo;
      state.serial = h.serial ?? state.serial;
      state.batteryPct = h.batteryPct ?? state.batteryPct;
      state.wristOn = h.wristOn ?? state.wristOn;
      onState(state);
    }
    if (d.kind == 'realtime_hr') {
      final hr = f['hr'] as int;
      if (hr > 0) {
        state.liveHr = hr;
        state.liveHrAt = DateTime.now().millisecondsSinceEpoch;
        state.wristOn = (f['wearing'] as bool?) ?? state.wristOn;
        onState(state);
      }
    }
  }

  /// Persist buffered drain records in one transaction. Snapshots the buffer so
  /// records arriving during the await land in the next batch, not this one.
  Future<void> _flushDrain() async {
    if (onRecordsBatch == null || _drainRaws.isEmpty) return;
    final raws = List<RawRecord>.from(_drainRaws);
    final samples = List<Sample?>.from(_drainSamples);
    _drainRaws.clear();
    _drainSamples.clear();
    try {
      await onRecordsBatch!(raws, samples);
    } catch (e) {
      _log('drain flush error: $e');
    }
  }

  Future<void> _handleSyncMarker(Frame frame) async {
    final m = parseMetadata(frame.inner);
    if (m == null) return;
    // Dump the FULL raw metadata frame so we can read the real token layout off
    // the device (5.454.0 builds the ACK from parsed ranges, not a flat slice).
    _log('[SYNC] META sub=${m.sub} inner='
        '${frame.inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    if (m.sub == SyncMeta.historyStart) return; // informational
    if (m.sub == SyncMeta.historyEnd && m.token != null) {
      _syncBatches++;
      final tokenHex =
          m.token!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _log('[SYNC] HistoryEnd batch=${m.batchId} records=$_syncRecords '
          '→ ACK seq=$_syncSeq token=$tokenHex');
      // Raw-first: persist this batch's records BEFORE we ACK (the band's cursor
      // advances on ACK, so anything unflushed at ACK time could be lost).
      await _flushDrain();
      // ACK and KEEP listening. THIS is the fragile path ().
      final ack = buildBatchAck(_syncSeq, m.token!);
      _log('[SYNC] ACK frame=${ack.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      _syncSeq = (_syncSeq + 1) & 0xFF;
      _write(ack);
    } else if (m.sub == SyncMeta.historyComplete) {
      await _flushDrain();
      _log('[SYNC] HistoryComplete — drained $_syncRecords records. Done.');
      _syncComplete = true;
    }
  }

  int _counterFromInner(Uint8List inner) =>
      inner.length >= 7 ? u32(inner, 3) : 0;
  String _innerHex(Uint8List inner) =>
      inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ── high-level flows ─────────────────────────────────────────────────────────
  Future<void> sendInit() async {
    _log('Sending 5-packet INIT…');
    for (final pkt in initPackets) {
      await _write(pkt);
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  /// Full drain: INIT → receive records → ACK each batch → stop on COMPLETE,
  /// idle, OR once we've caught up to the live edge (worn band tails 1 Hz forever).
  Future<SyncReport> runSync({Duration timeout = const Duration(seconds: 600)}) async {
    _syncComplete = false;
    _syncRecords = 0;
    _syncBatches = 0;
    _firstTs = 0;
    _lastTs = 0;
    _setConn('syncing');
    await sendInit();

    final start = DateTime.now();
    int last = _syncRecords;
    var idleSince = DateTime.now();
    while (!_syncComplete && DateTime.now().difference(start) < timeout) {
      await Future.delayed(const Duration(seconds: 1));
      // Caught up to the live edge? A worn band keeps feeding 1 Hz forever, so
      // "drained all backlog" = newest record is within ~15s of now. Stop there.
      final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (_lastTs > 0 && (nowS - _lastTs) < 15 && _syncRecords > 0) {
        _log('[SYNC] caught up to live edge (lastTs within 15s of now) — stopping drain.');
        await _send(Cmd.abortHistoricalTransmits, const [0x00]);
        break;
      }
      if (_syncRecords != last) {
        last = _syncRecords;
        idleSince = DateTime.now();
      } else if (DateTime.now().difference(idleSince) > const Duration(seconds: 8)) {
        _log('[SYNC] idle — sending ABORT_HISTORICAL to settle.');
        await _send(Cmd.abortHistoricalTransmits, const [0x00]);
        break;
      }
    }
    // Persist anything still buffered when we exit via live-edge/idle/timeout
    // (those paths don't get a HistoryComplete marker).
    await _flushDrain();
    _setConn('connected');
    _log('[SYNC] DRAIN SUMMARY: records=$_syncRecords batches=$_syncBatches '
        'complete=$_syncComplete firstTs=$_firstTs lastTs=$_lastTs '
        'span=${_lastTs - _firstTs}s');
    return SyncReport(_syncRecords, _syncBatches, _syncComplete);
  }

  /// Set the strap RTC to current unix time: payload = [u32 epoch LE, u32 pad].
  Future<void> setClock() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _send(Cmd.setClock, [
      now & 0xff, (now >> 8) & 0xff, (now >> 16) & 0xff, (now >> 24) & 0xff,
      0, 0, 0, 0,
    ]);
    _log('SET_CLOCK → $now (strap RTC aligned to real time).');
  }

  /// Smart alarm. Payload (7 bytes, LE):
  /// [0]=0x01 revision, [1:5]=u32 epoch seconds, [5:7]=u16 sub-seconds (0).
  Future<void> setAlarm(int epoch) async {
    await _send(Cmd.setAlarmTime, [
      0x01,
      epoch & 0xff, (epoch >> 8) & 0xff, (epoch >> 16) & 0xff, (epoch >> 24) & 0xff,
      0, 0,
    ]);
    _log('SET_ALARM_TIME → $epoch');
  }

  Future<void> getAlarm() => _send(Cmd.getAlarmTime, const [revision1]);
  Future<void> disableAlarm() => _send(Cmd.disableAlarm, const [0x00]);

  Future<void> getStrapName() => _send(Cmd.getAdvertisingNameHarvard, const [0x00]);

  /// Rename the strap (advertising name). Payload:
  /// [0x01][name length u8][ASCII name bytes][u32 0].
  Future<void> setStrapName(String name) async {
    final ascii = name.codeUnits.where((c) => c >= 0x20 && c < 0x7f).toList();
    final payload = <int>[0x01, ascii.length, ...ascii, 0, 0, 0, 0];
    await _send(Cmd.setAdvertisingNameHarvard, payload);
    _log('SET_ADVERTISING_NAME → "$name"');
  }

  Future<void> getBattery() => _send(Cmd.getBatteryLevel, const []);
  Future<void> getHello() => _send(Cmd.getHelloHarvard, const [0x00]);
  Future<void> buzz() => _send(Cmd.runHapticsPattern, const [hapticShortPulse, 0, 0, 0, 0]);

  /// Enable live foreground streams. Optical stays WRIST-GATED (0x6B only).
  Future<void> enableLiveStreams() async {
    _liveEnabled = true;
    await _send(Cmd.toggleRealtimeHr, const [0x01]);
    await Future.delayed(const Duration(milliseconds: 100));
    await _send(Cmd.sendR10R11Realtime, const [0x01]);
    await Future.delayed(const Duration(milliseconds: 100));
    await _send(Cmd.toggleImuMode, const [0x01]);
    await Future.delayed(const Duration(milliseconds: 100));
    await _send(Cmd.enableOpticalData, const [revision1, 0x01]);
    _log('Live streams enabled (optical: wrist-gated).');
  }

  /// Turn everything off. Safe + idempotent. Clears flags back to wrist-gated.
  Future<void> disableLiveStreams() async {
    final ops = <List<dynamic>>[
      [Cmd.toggleOpticalMode, [revision1, 0x00]],
      [Cmd.enableOpticalData, [revision1, 0x00]],
      [Cmd.sendR10R11Realtime, [0x00]],
      [Cmd.toggleImuMode, [0x00]],
      [Cmd.toggleRealtimeHr, [0x00]],
    ];
    for (final op in ops) {
      await _send(op[0] as int, (op[1] as List).cast<int>());
      await Future.delayed(const Duration(milliseconds: 60));
    }
    _liveEnabled = false;
    state.liveHr = null;
    onState(state);
  }

  Future<void> disconnect() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_liveEnabled) {
      try {
        await disableLiveStreams();
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _setConn('disconnected');
    _log('Disconnected.');
  }
}
