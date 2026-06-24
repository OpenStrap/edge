// BLE engine — the WHOOP 4.0 (Harvard) BLE transport, on flutter_blue_plus.
//
// REWRITTEN TRANSPORT (feat/ble-rewrite). The protocol/byte layer is unchanged:
// everything still goes through `package:openstrap_protocol` (framing/CRC, INIT,
// buildCommand, buildBatchAck, parseMetadata, decodeRecord/parseR24, constants,
// dangerousCmds). What changed is HOW we manage the link:
//
//   * One explicit connection state machine (`ble_state.dart`); the
//     flutter_blue_plus `connectionState` stream is the SOURCE OF TRUTH for
//     connected/disconnected — we never set "connected" by hand.
//   * A single in-flight guard (`_opLock`) so connect/reconnect/disconnect can
//     NEVER overlap (the classic flaky-connect bug).
//   * A per-connection `_Session` that owns the device, characteristics, the
//     three reassemblers, EVERY stream subscription, and the heartbeat timer —
//     torn down atomically on disconnect so nothing leaks across reconnects.
//   * An event-driven drain controller that completes on HISTORY_COMPLETE,
//     live-edge, idle, timeout, OR link-drop (no busy-poll that ignores drops).
//
// SAFETY: we NEVER send a dangerousCmd (FORCE_TRIM 0x19 / REBOOT 0x1D /
// TOGGLE_PERSISTENT_R21 0x9A). Optical is wrist-gated (0x6B only).
//
// SEQ DISCIPLINE: live commands use the HIGH range (0xA0+); sync ACKs use the LOW
// range (5+, continuing from INIT 0..4). Allocated by `SeqAllocator` so they
// never collide.
//
// PUBLIC SURFACE consumed by AppState / background_sync / edge_tracking. The
// drain-completion signal the DerivationEngine depends on — runSync() returning
// SyncReport after the final flush — is part of that surface.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/models.dart';
import 'ble_state.dart';

// Little-endian u32 reader. The package keeps `u32` private, and the engine only
// needs it to peek the record-counter / ts out of a raw historical frame header.
int u32(Uint8List b, int o) =>
    b.buffer.asByteData(b.offsetInBytes, b.length).getUint32(o, Endian.little);

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

/// All per-connection resources. A fresh one is built on every connect and torn
/// down (every subscription + timer cancelled, characteristics nulled) on every
/// disconnect — so nothing bleeds across reconnects.
class _Session {
  final BluetoothDevice device;
  BluetoothCharacteristic? cmdTo;
  final Map<String, FrameReassembler> asm = {
    'cmd_from': FrameReassembler(),
    'events': FrameReassembler(),
    'data': FrameReassembler(),
  };
  final List<StreamSubscription> subs = [];
  Timer? heartbeat;
  // Starts false: we are NOT connected until connect() resolves / the OS
  // connectionState stream reports `connected`. (It was previously initialised
  // true, which combined with the stream replaying a spurious initial
  // `disconnected` aborted setup before the bond-triggering write.)
  bool connected = false;
  // True once we've actually observed a `connected` state. Used to ignore the
  // initial `disconnected` that flutter_blue_plus replays on listen.
  bool sawConnected = false;
  bool intentionalClose = false;

  _Session(this.device);

  Future<void> teardown() async {
    heartbeat?.cancel();
    heartbeat = null;
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    cmdTo = null;
    connected = false;
  }
}

class BleEngine {
  final SampleSink onRecord;
  final StateSink onState;
  final LogSink? log;
  final EventSink? onEvent;

  /// If provided, historical-drain records are buffered and flushed in batches
  /// (one DB transaction per ACK boundary) instead of one-by-one via [onRecord].
  final BatchSink? onRecordsBatch;

  BleEngine({
    required this.onRecord,
    required this.onState,
    this.log,
    this.onEvent,
    this.onRecordsBatch,
  });

  final DeviceState state = DeviceState();

  // ── transport state machine ─────────────────────────────────────────────────
  BleConnState _phase = BleConnState.idle;
  _Session? _session;

  // Single in-flight guard. Every connect/disconnect/reconnect serialises through
  // this so two attempts can never race on the same peripheral.
  Future<void> _opLock = Future.value();

  final SeqAllocator _seq = SeqAllocator();
  Future<void> _writeChain = Future.value();

  /// Reconnection backoff schedule (bounded exponential + jitter). Owned by the
  /// transport; the caller's reconnect loop reads `reconnectDelay(attempt)` so the
  /// schedule lives in one place. Exposed so it's testable + tunable.
  final ReconnectPolicy reconnectPolicy = ReconnectPolicy();

  /// The delay to wait before reconnect `attempt` (1-based). Bounded + jittered.
  Duration reconnectDelay(int attempt) => reconnectPolicy.delayFor(attempt);

  // Drain bookkeeping (only valid while syncing).
  _DrainController? _drain;
  bool _liveEnabled = false;

  // Wall-clock of the last BLE notification received on ANY characteristic. iOS
  // can resume the app with the peripheral still flagged "connected" while its
  // GATT notifications silently died during suspension — the UI reads connected
  // but no events arrive. The foreground-reclaim path consults this to tell a
  // genuinely live link (recent data) from a stale one.
  DateTime _lastRx = DateTime.fromMillisecondsSinceEpoch(0);
  Duration get sinceLastRx => DateTime.now().difference(_lastRx);

  void _log(String s) => log?.call(s);

  void _setPhase(BleConnState p) {
    _phase = p;
    state.connection = connStringFor(p);
    onState(state);
  }

  bool get isConnected =>
      _session?.connected == true &&
      (_phase == BleConnState.ready ||
          _phase == BleConnState.live ||
          _phase == BleConnState.syncing);

  /// Run [body] under the single in-flight guard. Chains onto the existing op so
  /// callers can never start two transport operations concurrently.
  Future<T> _locked<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _opLock = _opLock.then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ── scan ─────────────────────────────────────────────────────────────────────
  /// Service-filtered scan (mandatory on iOS/macOS — passive scans hide the UUID).
  /// Start ONE scan, stop early on a match, otherwise let the timeout stop it.
  /// NEVER rapid start/stop (Android throttles → SCANNING_TOO_FREQUENTLY).
  Future<BluetoothDevice?> scan(
      {Duration timeout = const Duration(seconds: 12)}) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _setPhase(BleConnState.scanning);
    final svc = Guid(GattUuids.service);
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames =
            r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase());
        if (found == null &&
            (name.contains('whoop') ||
                advNames.any((s) => s.startsWith('61080001')))) {
          found = r.device;
          FlutterBluePlus.stopScan();
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: [svc], timeout: timeout);
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      _log('scan error: $e');
    } finally {
      await sub.cancel();
    }
    if (found == null) {
      _setPhase(BleConnState.idle);
      _log('No WHOOP found (force-quit the official app; band must be free).');
    }
    return found;
  }

  /// Reconnect to a previously-paired device by its persisted remote id.
  Future<bool> connectToRemoteId(String remoteId) =>
      connect(BluetoothDevice.fromId(remoteId));

  // ── connect ────────────────────────────────────────────────────────────────────
  /// Idempotent connect. Serialised through [_opLock] so it can never overlap
  /// another connect/disconnect. Returns true on a fully-ready link.
  Future<bool> connect(BluetoothDevice device) => _locked(() async {
        // Already connected to this exact peripheral and ready → no-op success.
        if (_session != null &&
            _session!.connected &&
            _session!.device.remoteId == device.remoteId &&
            (_phase == BleConnState.ready ||
                _phase == BleConnState.live ||
                _phase == BleConnState.syncing)) {
          _log('connect: already connected to ${device.remoteId.str} — reusing.');
          return true;
        }
        // Any prior session is dead to us now — tear it down before a new one.
        await _teardownSession(intentional: true);
        return _doConnect(device);
      });

  Future<bool> _doConnect(BluetoothDevice device) async {
    state.address = device.remoteId.str;
    _setPhase(BleConnState.connecting);
    final session = _Session(device);
    _session = session;
    _seq.reset();

    // SOURCE OF TRUTH: listen to the OS connection-state stream FIRST so we never
    // miss the disconnect that can fire during discovery/subscribe.
    session.subs.add(device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) {
        session.connected = true;
        session.sawConnected = true;
      } else if (s == BluetoothConnectionState.disconnected) {
        // flutter_blue_plus REPLAYS the current state on listen — for a
        // not-yet-connected device that's a spurious `disconnected`. Only treat
        // it as a real link-down once we've actually observed `connected`.
        if (session.sawConnected) {
          session.connected = false;
          _onLinkDown(session);
        }
      }
    }));

    try {
      await device.connect(
          timeout: const Duration(seconds: 20), autoConnect: false);
    } catch (e) {
      _log('connect failed: $e');
      await _teardownSession(intentional: true);
      _setPhase(BleConnState.idle);
      return false;
    }

    // connect() resolved without throwing => the link is up. Set this explicitly
    // rather than racing the connectionState stream's `connected` emission, so
    // the setup below (discover/subscribe/SET_CLOCK → bond) is never skipped.
    session.connected = true;
    session.sawConnected = true;

    // Bond. On Android we explicitly createBond (the strap gates commands behind
    // encryption — without a bond the ACK/commands are silently dropped). On iOS
    // bonding happens implicitly on the first write-with-response.
    if (Platform.isAndroid) {
      try {
        await device.createBond();
        _log('Bonded (or already bonded).');
      } catch (e) {
        _log('createBond: $e');
      }
    }

    // Larger MTU + a fast connection interval for the drain (Android-only levers;
    // no-ops on iOS, which picks a fast interval itself when data is pending).
    try {
      await device.requestMtu(247);
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high);
      } catch (_) {}
    }

    if (!session.connected) {
      _log('connect: link dropped during setup.');
      return false;
    }

    _setPhase(BleConnState.discovering);
    final services = await device.discoverServices();
    BluetoothService? svc;
    for (final s in services) {
      if (s.uuid.str.toLowerCase().startsWith('61080001')) svc = s;
    }
    if (svc == null) {
      _log('Harvard service not found on device.');
      await _teardownSession(intentional: true);
      _setPhase(BleConnState.idle);
      return false;
    }
    BluetoothCharacteristic? find(String prefix) {
      for (final c in svc!.characteristics) {
        if (c.uuid.str.toLowerCase().startsWith(prefix)) return c;
      }
      return null;
    }

    session.cmdTo = find('61080002');
    final cmdFrom = find('61080003');
    final events = find('61080004');
    final data = find('61080005');
    if (session.cmdTo == null ||
        cmdFrom == null ||
        events == null ||
        data == null) {
      _log('Missing one or more Harvard characteristics.');
      await _teardownSession(intentional: true);
      _setPhase(BleConnState.idle);
      return false;
    }

    _setPhase(BleConnState.subscribing);
    await _subscribe(session, cmdFrom, 'cmd_from');
    await _subscribe(session, events, 'events');
    await _subscribe(session, data, 'data');

    _setPhase(BleConnState.settingUp);
    // Set the strap RTC to real wall-clock time. The band ships with an unset
    // clock; SET_CLOCK is non-destructive (it's what the official app does each
    // connect). Records stamped after this carry real unix time.
    await setClock();

    // Heartbeat: keep the link alive (~10s LINK_VALID). Owned by the session, so a
    // disconnect cancels it — no zombie timer firing into a dead characteristic.
    session.heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (session.connected) _send(Cmd.linkValid, const [0x00]);
    });

    _lastRx = DateTime.now(); // fresh link — never treat as stale on resume
    _setPhase(BleConnState.ready);
    _log('Connected + subscribed.');
    return true;
  }

  Future<void> _subscribe(
      _Session session, BluetoothCharacteristic c, String role) async {
    await c.setNotifyValue(true);
    session.subs.add(c.onValueReceived.listen((chunk) {
      // Ignore notifications from a session we've already torn down.
      if (_session != session || !session.connected) return;
      _lastRx = DateTime.now();
      for (final frame in session.asm[role]!.feed(chunk)) {
        if (frame.valid) _onFrame(role, frame);
      }
    }));
  }

  // ── link-down handling (drives reconnect via the caller's contract) ─────────────
  void _onLinkDown(_Session session) {
    if (_session != session) return; // a stale session's stream
    final wasIntentional = session.intentionalClose;
    session.connected = false;
    // A drain in flight must complete (with linkDown) immediately, not run out
    // its full budget.
    _drain?.onLinkDown();
    // The caller (AppState) listens for the 'disconnected' phase to drive its
    // reconnect loop; we surface it here. We do NOT auto-reconnect inside the
    // engine — the caller owns reconnect intent (keepAlive), and routes it back
    // through the same single-flight connect, so there's still exactly one path.
    if (!wasIntentional) {
      final reason = session.device.disconnectReason;
      _log('Link down (reason=${reason?.description ?? "unknown"}).');
    }
    _setPhase(BleConnState.idle);
  }

  // ── write (serialised through a single chain) ───────────────────────────────────
  // The cmd characteristic write is WITH-RESPONSE: that's what triggers BLE bonding
  // (the auth challenge) AND gets commands delivered + acknowledged. Write-WITHOUT-
  // response is silently dropped by the band and never establishes the bond.
  Future<void> _write(Uint8List raw) {
    final session = _session;
    final completer = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        final cmd = session?.cmdTo;
        if (session == null || !session.connected || cmd == null) {
          _log('write skipped: link not ready.');
          return;
        }
        await cmd.write(raw, withoutResponse: false);
      } catch (e) {
        _log('write error: $e');
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _send(int opcode, List<int> payload) async {
    if (dangerousCmds.contains(opcode)) {
      _log('REFUSED dangerous opcode 0x${opcode.toRadixString(16)}');
      return;
    }
    final frame = buildCommand(_seq.nextLive(), opcode, payload);
    await _write(frame);
  }

  // ── frame handling ─────────────────────────────────────────────────────────────
  void _onFrame(String role, Frame frame) {
    final pt = frame.packetType;
    if (pt == PacketType.metadata) {
      unawaited(_handleSyncMarker(frame));
      return;
    }
    // LIVE streams: realtime HR/RR (0x28), realtime R10 (0x2B), IMU (0x33).
    // Raw-first — store; the backend/on-device layer field-decodes. Never touch
    // the historical-sync bookkeeping (which keys off 0x2F only).
    if (pt == PacketType.realtimeData ||
        pt == PacketType.realtimeRawData ||
        pt == PacketType.realtimeImuStream) {
      final raw = RawRecord(
        counter: _counterFromInner(frame.inner),
        packetType: pt,
        hex: _innerHex(frame.inner),
        capturedAt: DateTime.now().millisecondsSinceEpoch,
      );
      onRecord(null, raw);
      // Fall through to decodeFrame so the UI gets live telemetry.
    }
    if (pt == PacketType.historicalData) {
      final recType = frame.inner.length > 1 ? frame.inner[1] : -1;
      final counter = _counterFromInner(frame.inner);
      final raw = RawRecord(
        counter: counter,
        packetType: pt,
        hex: _innerHex(frame.inner),
        capturedAt: DateTime.now().millisecondsSinceEpoch,
      );
      int ts = 0;
      if (frame.inner.length >= 11) {
        final t = u32(frame.inner, 7);
        if (t > 1000000000) ts = t;
      }
      Sample? sample;
      if (recType == Record.r24) {
        final r = parseR24(frame.inner);
        if (r != null) {
          sample = Sample(tsEpoch: r.tsEpoch, counter: r.counter, hr: r.hr);
        }
      } else if (recType == Record.r10) {
        final r = parseR10Lite(frame.inner);
        if (r != null) {
          sample = Sample(tsEpoch: r.tsEpoch, counter: r.counter, hr: r.hr);
        }
      }
      // Hand the record to the drain controller (it buffers + tracks ts/counts),
      // or store directly if no drain is active (shouldn't happen for 0x2F, but
      // safe).
      final d = _drain;
      if (d != null) {
        d.onHistoricalRecord(raw, sample, ts);
      } else if (onRecordsBatch != null) {
        unawaited(onRecordsBatch!([raw], [sample]));
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

  Future<void> _handleSyncMarker(Frame frame) async {
    final m = parseMetadata(frame.inner);
    if (m == null) return;
    _log('[SYNC] META sub=${m.sub} inner='
        '${frame.inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    if (m.sub == SyncMeta.historyStart) return;
    if (m.sub == SyncMeta.historyEnd && m.token != null) {
      final d = _drain;
      if (d == null) return;
      final tokenHex =
          m.token!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _log('[SYNC] HistoryEnd batch=${m.batchId} records=${d.records} '
          'token=$tokenHex');
      // RAW-FIRST: persist this batch BEFORE we ACK (the band's cursor advances
      // on ACK, so anything unflushed at ACK time could be lost).
      await d.flush();
      final ack = buildBatchAck(_seq.nextSync(), m.token!);
      _log('[SYNC] ACK frame='
          '${ack.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      d.noteBatchAcked();
      await _write(ack); // ACK and KEEP listening
    } else if (m.sub == SyncMeta.historyComplete) {
      final d = _drain;
      if (d == null) return;
      await d.flush();
      _log('[SYNC] HistoryComplete — drained ${d.records} records. Done.');
      d.onComplete();
    }
  }

  int _counterFromInner(Uint8List inner) =>
      inner.length >= 7 ? u32(inner, 3) : 0;
  String _innerHex(Uint8List inner) =>
      inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ── high-level flows ─────────────────────────────────────────────────────────────
  Future<void> sendInit() async {
    _log('Sending 5-packet INIT…');
    for (final pkt in initPackets) {
      await _write(pkt);
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  /// Full drain: INIT → receive records → ACK each batch → stop on COMPLETE,
  /// live-edge, idle, link-down, or timeout. Returns AFTER the final flush, so the
  /// DerivationEngine's post-drain hook fires only once everything is persisted.
  Future<SyncReport> runSync(
      {Duration timeout = const Duration(seconds: 600)}) async {
    final session = _session;
    if (session == null || !session.connected) {
      _log('runSync: no live link — nothing to drain.');
      return SyncReport(0, 0, false);
    }
    final drain = _DrainController(
      onRecord: onRecord,
      onRecordsBatch: onRecordsBatch,
      log: _log,
      evaluator: DrainStopEvaluator(timeout: timeout),
    );
    _drain = drain;
    _setPhase(BleConnState.syncing);
    await sendInit();

    final report = await drain.run(
      isLinkUp: () => session.connected,
      sendAbort: () => _send(Cmd.abortHistoricalTransmits, const [0x00]),
    );

    _drain = null;
    // Restore phase based on what's still true (link may have dropped mid-drain).
    if (session.connected) {
      _setPhase(_liveEnabled ? BleConnState.live : BleConnState.ready);
    }
    _log('[SYNC] DRAIN SUMMARY: records=${report.records} '
        'batches=${report.batches} complete=${report.complete}');
    return report;
  }

  /// Set the strap RTC to current unix time: payload = [u32 epoch LE, u32 pad].
  Future<void> setClock() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _send(Cmd.setClock, [
      now & 0xff,
      (now >> 8) & 0xff,
      (now >> 16) & 0xff,
      (now >> 24) & 0xff,
      0, 0, 0, 0,
    ]);
    _log('SET_CLOCK → $now (strap RTC aligned to real time).');
  }

  /// Smart alarm. Payload (7 bytes, LE):
  /// [0]=0x01 revision, [1:5]=u32 epoch seconds, [5:7]=u16 sub-seconds (0).
  Future<void> setAlarm(int epoch) async {
    await _send(Cmd.setAlarmTime, [
      0x01,
      epoch & 0xff,
      (epoch >> 8) & 0xff,
      (epoch >> 16) & 0xff,
      (epoch >> 24) & 0xff,
      0, 0,
    ]);
    _log('SET_ALARM_TIME → $epoch');
  }

  Future<void> getAlarm() => _send(Cmd.getAlarmTime, const [revision1]);
  Future<void> disableAlarm() => _send(Cmd.disableAlarm, const [0x00]);

  Future<void> getStrapName() =>
      _send(Cmd.getAdvertisingNameHarvard, const [0x00]);

  /// Rename the strap. Payload: [0x01][name length u8][ASCII name bytes][u32 0].
  Future<void> setStrapName(String name) async {
    final ascii = name.codeUnits.where((c) => c >= 0x20 && c < 0x7f).toList();
    final payload = <int>[0x01, ascii.length, ...ascii, 0, 0, 0, 0];
    await _send(Cmd.setAdvertisingNameHarvard, payload);
    _log('SET_ADVERTISING_NAME → "$name"');
  }

  Future<void> getBattery() => _send(Cmd.getBatteryLevel, const []);
  Future<void> getHello() => _send(Cmd.getHelloHarvard, const [0x00]);
  Future<void> buzz() =>
      _send(Cmd.runHapticsPattern, const [hapticShortPulse, 0, 0, 0, 0]);

  /// Enable live foreground streams. Optical stays WRIST-GATED (0x6B only).
  Future<void> enableLiveStreams() async {
    _liveEnabled = true;
    if (_phase == BleConnState.ready) _setPhase(BleConnState.live);
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
    if (_phase == BleConnState.live) _setPhase(BleConnState.ready);
    onState(state);
  }

  /// Idempotent, intentional teardown. Safe to call repeatedly.
  Future<void> disconnect() => _locked(() async {
        if (_liveEnabled && _session?.connected == true) {
          try {
            await disableLiveStreams();
          } catch (_) {}
        }
        await _teardownSession(intentional: true);
        _setPhase(BleConnState.idle);
        _log('Disconnected.');
      });

  /// Tear down the current session: cancel every subscription + timer, drop the
  /// BLE link, null all per-connection state. Called for BOTH intentional
  /// disconnect and (via [_onLinkDown]) an OS-driven drop.
  Future<void> _teardownSession({required bool intentional}) async {
    final session = _session;
    if (session == null) return;
    session.intentionalClose = intentional;
    _drain?.onLinkDown();
    final device = session.device;
    await session.teardown();
    _session = null;
    if (intentional) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }
}

/// Event-driven historical-drain controller. Owns the buffered records, the
/// ts/counter tracking, the idle watchdog, and the completion Future. It is fed
/// by the engine's frame handler (records + markers) and by link-down events; it
/// completes its [run] Future on the first stop condition.
class _DrainController {
  final SampleSink onRecord;
  final BatchSink? onRecordsBatch;
  final void Function(String) log;
  final DrainStopEvaluator evaluator;

  _DrainController({
    required this.onRecord,
    required this.onRecordsBatch,
    required this.log,
    required this.evaluator,
  });

  final List<RawRecord> _raws = [];
  final List<Sample?> _samples = [];

  int records = 0;
  int batches = 0;
  bool _complete = false;
  bool _linkDown = false;
  int _lastTsSec = 0;
  DateTime _lastNewRecordAt = DateTime.now();
  final DateTime _start = DateTime.now();

  final Completer<SyncReport> _done = Completer<SyncReport>();
  Timer? _poll;

  void onHistoricalRecord(RawRecord raw, Sample? sample, int tsSec) {
    records++;
    _lastNewRecordAt = DateTime.now();
    if (tsSec > 0) _lastTsSec = tsSec;
    if (onRecordsBatch != null) {
      _raws.add(raw);
      _samples.add(sample);
    } else {
      onRecord(sample, raw);
    }
  }

  void noteBatchAcked() => batches++;

  void onComplete() {
    _complete = true;
    // HISTORY_COMPLETE already flushed in the marker handler — finish now.
    if (!_done.isCompleted) unawaited(_finish(DrainStop.complete));
  }

  void onLinkDown() {
    // Flag it; run()'s 1s loop observes it and finishes WITHOUT sending an abort
    // on a dead link. Safe to call before run() starts or after it finishes.
    _linkDown = true;
  }

  /// Persist buffered records in one transaction. Snapshots the buffer so records
  /// arriving during the await land in the next flush.
  Future<void> flush() async {
    if (onRecordsBatch == null || _raws.isEmpty) return;
    final raws = List<RawRecord>.from(_raws);
    final samples = List<Sample?>.from(_samples);
    _raws.clear();
    _samples.clear();
    try {
      await onRecordsBatch!(raws, samples);
    } catch (e) {
      log('drain flush error: $e');
    }
  }

  /// Drive the drain to completion. Polls the pure stop-evaluator every second
  /// (the protocol is push, but the live-edge / idle / timeout conditions are
  /// time-based). Sends ABORT_HISTORICAL on live-edge / idle exits.
  Future<SyncReport> run({
    required bool Function() isLinkUp,
    required Future<void> Function() sendAbort,
  }) async {
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_done.isCompleted) return;
      if (!isLinkUp()) _linkDown = true;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final stop = evaluator.evaluate(
        complete: _complete,
        linkDown: _linkDown,
        records: records,
        lastRecordTsSec: _lastTsSec,
        nowSec: nowSec,
        sinceStart: DateTime.now().difference(_start),
        sinceLastNewRecord: DateTime.now().difference(_lastNewRecordAt),
      );
      if (stop == DrainStop.keepGoing) return;
      // Live-edge / idle exits politely tell the band to stop transmitting.
      if ((stop == DrainStop.liveEdge || stop == DrainStop.idle) && isLinkUp()) {
        log('[SYNC] stop=$stop — sending ABORT_HISTORICAL.');
        try {
          await sendAbort();
        } catch (_) {}
      } else {
        log('[SYNC] stop=$stop.');
      }
      await _finish(stop);
    });
    return _done.future;
  }

  Future<void> _finish(DrainStop stop) async {
    if (_done.isCompleted) return;
    _poll?.cancel();
    _poll = null;
    // Persist anything still buffered on a non-COMPLETE exit (those paths don't
    // get a HistoryComplete marker; COMPLETE/END already flushed).
    await flush();
    _done.complete(SyncReport(records, batches, stop == DrainStop.complete));
  }
}
