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
//   * A single LISTENING mode. Once the link is up we subscribe → SET_CLOCK →
//     INIT (which triggers the historical flood) → then JUST KEEP LISTENING.
//     Historical records and live records arrive on the SAME data stream; we ACK
//     every HISTORY_END marker as it comes and store every record. There is no
//     "syncing → live" flip, no live-edge cutoff, no idle-timeout that ends a
//     phase. The historical offload runs to HISTORY_COMPLETE (which is what
//     durably advances the band's read cursor — cutting it short was the
//     "Groundhog Day" re-flood bug); once complete the same subscription keeps
//     delivering live records with no mode change.
//
// SAFETY: we NEVER send a dangerousCmd (FORCE_TRIM 0x19 / REBOOT 0x1D /
// TOGGLE_PERSISTENT_R21 0x9A). Optical is wrist-gated (0x6B only).
//
// SEQ DISCIPLINE: live commands use the HIGH range (0xA0+); sync ACKs use the LOW
// range (5+, continuing from INIT 0..4). Allocated by `SeqAllocator` so they
// never collide.
//
// PUBLIC SURFACE consumed by AppState / background_sync / edge_tracking. The
// DerivationEngine no longer keys off a discrete "sync done" — instead the engine
// fires a debounced `onDataStored` callback after records are persisted (coalescing
// bursts), so the compute trigger survives the move to continuous listening.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../sync/paired_device.dart' show cleanDeviceLabel;
import '../sync/sync_policy.dart';
import 'ble_state.dart';

// Little-endian u32 reader. The package keeps `u32` private, and the engine only
// needs it to peek the record-counter / ts out of a raw historical frame header.
int u32(Uint8List b, int o) =>
    b.buffer.asByteData(b.offsetInBytes, b.length).getUint32(o, Endian.little);

typedef SampleSink = Future<void> Function(Sample? sample, RawRecord raw);
typedef StateSink = void Function(DeviceState state);
typedef LogSink = void Function(String line);
typedef EventSink = void Function(int eventId, int tsEpoch, String hex);
typedef BatchSink =
    Future<void> Function(List<RawRecord> raws, List<Sample?> samples);

/// Persist a sync chunk's raw records, samples AND the continuation cursor
/// ATOMICALLY (one transaction), returning only once durable. This is the
/// durable half of the safe-trim invariant: it MUST complete before the engine
/// writes the HISTORY_END ACK, so the band never trims flash we haven't banked.
/// [trimTokenHex] is the hex of the HISTORY_END 8-byte continuation token.
typedef CommitSyncBatchSink =
    Future<void> Function(
      List<RawRecord> raws,
      List<Sample?> samples,
      String? trimTokenHex,
    );

/// Fired (debounced) after records are persisted so the caller can schedule a
/// DerivationEngine pass. Replaces the old "runSync() → SyncReport → derive"
/// trigger now that listening is continuous and there's no discrete sync end.
typedef DataStoredSink = void Function();

/// Fired for every LIVE high-rate frame (0x28/0x2B/0x33). These are EPHEMERAL —
/// they are NOT persisted to raw_records (that bloated storage ~50x and stalled
/// derivation). The caller routes them to an in-memory sink for the live UI /
/// spot-check / workout feature-extraction. `recTs` is the frame's decoded real
/// device time (epoch sec), or null if undecodable.
typedef LiveFrameSink = void Function(int packetType, String hex, int? recTs);
typedef OffloadStateSink = void Function(bool active);

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
  // Session-owned timers; a disconnect cancels them.
  Timer? keepAlive; // 30s: liveness watchdog + battery poll + realtime re-arm
  Timer? periodicBackfill; // 900s: re-trigger the historical offload
  Timer? idleWatchdog; // 60s: strap went silent mid-offload
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
    keepAlive?.cancel();
    keepAlive = null;
    periodicBackfill?.cancel();
    periodicBackfill = null;
    idleWatchdog?.cancel();
    idleWatchdog = null;
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

  /// Debounced "new data stored" trigger. Fired once an inbound burst goes quiet
  /// (see [DeriveDebouncer]) so the caller can schedule a single derive pass per
  /// burst instead of per record. Optional (null in headless contexts that drive
  /// their own derive).
  final DataStoredSink? onDataStored;

  /// If provided, LIVE high-rate frames (0x28/0x2B/0x33) are routed here instead
  /// of being persisted. Ephemeral — for the live UI / spot-check / workout
  /// feature-extraction. NEVER hits raw_records.
  final LiveFrameSink? onLiveFrame;
  final OffloadStateSink? onOffloadState;

  /// If provided, sync chunks are persisted via this ATOMIC commit (raw + samples
  /// + continuation cursor in one transaction) before the HISTORY_END ACK. This is
  /// what makes the offload resumable across restarts (durable cursor).
  /// When null the engine falls back to [onRecordsBatch] (no durable cursor).
  final CommitSyncBatchSink? onCommitBatch;

  /// Tunable debounce window for [onDataStored]. Default coalesces a burst once the
  /// stream goes quiet for ~12s, with a 90s never-quiet floor.
  final DeriveDebouncer deriveDebouncer;

  BleEngine({
    required this.onRecord,
    required this.onState,
    this.log,
    this.onEvent,
    this.onRecordsBatch,
    this.onDataStored,
    this.onLiveFrame,
    this.onOffloadState,
    this.onCommitBatch,
    this.cursorReader,
    this.deriveDebouncer = const DeriveDebouncer(),
  });

  /// Optional reader for a persisted cursor value (e.g. counter_hw) so the engine
  /// can seed its frontier from the durable store on connect — making the stuck/
  /// continuation detectors correct on the very first offload after a restart.
  final Future<int?> Function(String name)? cursorReader;

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

  // Historical-offload bookkeeping. A controller is live for the whole connection
  // (we keep ACKing HISTORY_END markers as they arrive, even after the first
  // HISTORY_COMPLETE — a later strap-triggered offload reuses it).
  _DrainController? _drain;
  bool _liveEnabled = false;
  bool _offloadActive = false;
  final List<Frame> _offloadFrames = [];
  bool _drainingOffloadFrames = false;
  int _historyRequests = 0;
  int _historyCompletions = 0;
  SyncReport? _lastSyncReport;
  int? _strapHistoryOldestTs;
  int? _strapHistoryNewestTs;

  // ── reconnect/offload policy ────────────────────────────────────────────────
  // Marginal-radio + post-bond-loop persist ACROSS reconnects (they count
  // consecutive bad cycles), so they live for the engine's lifetime and self-reset
  // inside connectionEnded() on any non-matching disconnect. Empty-sync + stuck
  // are per-connection and reset on each connect.
  final MarginalRadioDetector _marginalRadio = MarginalRadioDetector();
  final PostBondTimeoutLoopDetector _postBondLoop =
      PostBondTimeoutLoopDetector();
  EmptySyncTracker _emptySync = EmptySyncTracker();
  StuckStrapDetector _stuckStrap = StuckStrapDetector();

  ClockRef? _clockRef; // strap-RTC ↔ wall correlation (set from GET_CLOCK)
  /// Latest strap-RTC ↔ wall correlation, or null until GET_CLOCK is answered.
  ClockRef? get clockRef => _clockRef;
  int? _sessionOldestUnix; // strap's banked-data window (GET_DATA_RANGE)
  int? _sessionNewestUnix;
  DateTime? _bondTime; // when the handshake completed (bond confirmed)
  DateTime? _armTime; // when live (R10/R11) streams were last armed
  int _frontierTs = 0; // highest historical rec_ts we've durably persisted
  int _autoContinueCount = 0; // consecutive auto-continues this connection
  double _lastBackfillAt = 0; // monotonic-ish secs of the last offload trigger
  int _emptyStreak = 0; // consecutive empty offloads (BackfillPolicy backoff)
  int _droppedImplausible = 0; // records rejected by the plausibility gate

  double _wallSecs() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  // Wall-clock of the last BLE notification received on ANY characteristic. iOS
  // can resume the app with the peripheral still flagged "connected" while its
  // GATT notifications silently died during suspension — the UI reads connected
  // but no events arrive. The foreground-reclaim path consults this to tell a
  // genuinely live link (recent data) from a stale one. Also drives the UI's
  // "last data: Xs ago" readout.
  DateTime _lastRx = DateTime.fromMillisecondsSinceEpoch(0);
  Duration get sinceLastRx => DateTime.now().difference(_lastRx);

  /// Wall-clock of the last received BLE notification (any characteristic), for the
  /// UI's "last data: Xs ago". `null` until the first frame this connection.
  DateTime? get lastRxAt =>
      _lastRx.millisecondsSinceEpoch == 0 ? null : _lastRx;

  // ── debounced "new data stored → derive" trigger ─────────────────────────────
  // Continuous listening has no discrete "sync done", so we coalesce stored-record
  // bursts: mark dirty on persist, and fire onDataStored once the stream goes quiet.
  DateTime _lastStored = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _firstPending; // start of the current un-derived run
  Timer? _deriveTimer;

  void _log(String s) => log?.call(s);

  /// Note that records were just persisted; (re)arm the debounced derive trigger.
  /// Called from the record-store paths. No-op when no [onDataStored] is wired.
  void _noteStored() {
    if (onDataStored == null) return;
    final now = DateTime.now();
    _lastStored = now;
    _firstPending ??= now;
    _deriveTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      final fp = _firstPending;
      if (fp == null) return;
      final fire = deriveDebouncer.shouldDerive(
        hasPending: true,
        sinceLastRecord: DateTime.now().difference(_lastStored),
        sinceFirstPending: DateTime.now().difference(fp),
      );
      if (fire) {
        _firstPending = null;
        _deriveTimer?.cancel();
        _deriveTimer = null;
        onDataStored!.call();
      }
    });
  }

  void _setPhase(BleConnState p) {
    _phase = p;
    state.connection = connStringFor(p);
    onState(state);
  }

  bool get isConnected =>
      _session?.connected == true && _phase == BleConnState.listening;

  bool get offloadActive => _offloadActive;

  Map<String, dynamic> get offloadSnapshot => {
    'active': _offloadActive,
    'queued_frames': _offloadFrames.length,
    'queue_draining': _drainingOffloadFrames,
    'records_seen': _drain?.records ?? 0,
    'batches_acked': _drain?.batches ?? 0,
    'buffered_records': _drain?.bufferedRecords ?? 0,
    'history_requests': _historyRequests,
    'history_completions': _historyCompletions,
    'last_progress_ms': _drain?.lastProgressMs,
    'last_report_records': _lastSyncReport?.records,
    'last_report_batches': _lastSyncReport?.batches,
    'last_report_complete': _lastSyncReport?.complete,
    'strap_history_oldest_ts': _strapHistoryOldestTs,
    'strap_history_newest_ts': _strapHistoryNewestTs,
  };

  int? get strapHistoryNewestTs => _strapHistoryNewestTs;

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
  Future<BluetoothDevice?> scan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _setPhase(BleConnState.scanning);
    final svc = Guid(GattUuids.service);
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames = r.advertisementData.serviceUuids.map(
          (g) => g.str.toLowerCase(),
        );
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
        _phase == BleConnState.listening) {
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
    session.subs.add(
      device.connectionState.listen((s) {
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
      }),
    );

    try {
      await device.connect(
        timeout: const Duration(seconds: 20),
        autoConnect: false,
      );
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
    try {
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
            connectionPriorityRequest: ConnectionPriority.high,
          );
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
      // Per-connection policy reset. Marginal-radio + post-bond-loop are NOT reset
      // here — they count consecutive bad cycles across reconnects and self-reset on
      // a healthy disconnect. Empty-sync + stuck are per-connection.
      _emptySync = EmptySyncTracker();
      _stuckStrap = StuckStrapDetector();
      _autoContinueCount = 0;
      _lastBackfillAt = 0;
      _droppedImplausible = 0;
      _sessionOldestUnix = null;
      _sessionNewestUnix = null;
      _bondTime = DateTime.now();
      // Seed the frontier from the durable high-water so the stuck/continuation
      // detectors are correct on the first offload after a restart.
      _frontierTs = (await cursorReader?.call('rec_ts_hw')) ?? 0;

      // Heartbeat: keep the link alive (~10s LINK_VALID). Owned by the session, so a
      // disconnect cancels it — no zombie timer firing into a dead characteristic.
      session.heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
        if (session.connected) _send(Cmd.linkValid, const [0x00]);
      });
      // Keep-alive (30s): liveness watchdog (bounce a silently-dead link), periodic
      // battery poll, and realtime re-arm.
      session.keepAlive = Timer.periodic(
        const Duration(seconds: kKeepAliveIntervalSeconds),
        (_) => _keepAliveFire(session),
      );
      // Periodic backfill (900s): re-trigger the historical offload while connected,
      // floored by BackfillPolicy so a flapping link can't hammer the strap.
      session.periodicBackfill = Timer.periodic(
        const Duration(seconds: kBackfillIntervalSeconds),
        (_) => _triggerBackfill(BackfillTrigger.periodic),
      );

      _lastRx = DateTime.now(); // fresh link — never treat as stale on resume

      // SINGLE LISTENING MODE. Arm the offload controller, enter `listening`, then
      // fire INIT — which triggers the historical flood. Historical + live records
      // then arrive on the same subscription; HISTORY_END markers are committed
      // (raw+samples+cursor, atomically) BEFORE we ACK, so the offload is resumable.
      _drain = _DrainController(
        onRecord: _storeRecord,
        onRecordsBatch: onRecordsBatch == null ? null : _storeRecordsBatch,
        onCommit: onCommitBatch == null ? null : _commitBatch,
        log: _log,
      );
      _setPhase(BleConnState.listening);
      _log('Connected + subscribed — listening (history + live).');
      _setOffloadActive(true);
      _lastBackfillAt = _wallSecs();
      await sendInit(); // triggers the historical offload flood
      return true;
    } catch (e) {
      _log('connect setup failed: $e');
      await _teardownSession(intentional: true);
      _setPhase(BleConnState.idle);
      return false;
    }
  }

  // ── keep-alive + periodic backfill ──────────────────────────────────────────
  void _keepAliveFire(_Session session) {
    if (_session != session || !session.connected) return;
    // Liveness watchdog: iOS can resume us with the peripheral flagged connected
    // while its GATT notifications silently died. If no frame has arrived for
    // longer than the fuse, bounce the link so the caller's reconnect loop runs.
    if (sinceLastRx.inSeconds > kLivenessFuseSeconds) {
      _log('No data for >${kLivenessFuseSeconds}s — bouncing the link.');
      unawaited(
        _teardownSession(intentional: false).then((_) {
          _setPhase(
            BleConnState.idle,
          ); // surfaces 'disconnected' → caller reconnects
        }),
      );
      return;
    }
    if (_liveEnabled) {
      _send(Cmd.sendR10R11Realtime, const [0x01]);
      _send(Cmd.toggleRealtimeHr, const [0x01]);
    }
    _send(Cmd.getBatteryLevel, const []);
  }

  /// Trigger a historical offload, floored by [BackfillPolicy] (manual /
  /// autoContinue are never floored). Re-arms the drain so a fresh HISTORY_COMPLETE
  /// is awaited. Used by the periodic timer, continuation, and the public sync API.
  Future<void> _triggerBackfill(BackfillTrigger trigger) async {
    final d = _drain;
    if (_session?.connected != true || d == null) return;
    if (!BackfillPolicy.shouldRun(
      trigger,
      _wallSecs(),
      _lastBackfillAt,
      _emptyStreak,
    )) {
      return;
    }
    _lastBackfillAt = _wallSecs();
    await _startHistoricalRefresh(
      trigger: trigger,
      reason: trigger.name,
      refreshRange: true,
    );
  }

  /// Canonical historical-refresh entrypoint for the whole app.
  ///
  /// Why this exists:
  /// - A *fresh* connection already runs the 5-packet INIT, whose seq2 polls the
  ///   strap's `GET_DATA_RANGE` and whose seq4 starts the historical drain.
  /// - A *long-lived* connection used to re-kick history with only
  ///   `SEND_HISTORICAL_DATA`. In practice that can stall at the live edge: the
  ///   app knows backlog remains, but a later refresh produces no frontier
  ///   advance and eventually ends as `session_end`.
  ///
  /// So every re-triggered offload now goes through ONE reusable path:
  ///   1. re-arm the drain controller;
  ///   2. refresh the strap's banked-data range (updates newest/oldest);
  ///   3. send `SEND_HISTORICAL_DATA`.
  ///
  /// This keeps periodic sync, manual resync, workout-end backfill, and future
  /// callers on the same protocol path instead of each open-coding their own
  /// "maybe just send 0x16" behavior.
  Future<void> _startHistoricalRefresh({
    required BackfillTrigger trigger,
    required String reason,
    bool refreshRange = true,
  }) async {
    final d = _drain;
    if (_session?.connected != true || d == null) return;
    d.rearm();
    _setOffloadActive(true);
    if (refreshRange) {
      _log('[SYNC] refresh($reason) — polling GET_DATA_RANGE before 0x16.');
      await _send(Cmd.getDataRange, const [0x00]);
      // INIT spaces commands by ~120 ms; keep the same cadence here so the band
      // has time to emit the range response before we request another drain.
      await Future.delayed(const Duration(milliseconds: 120));
    }
    _log('[SYNC] refresh($reason) — sending SEND_HISTORICAL_DATA.');
    await _send(Cmd.sendHistoricalData, const [0x00]);
  }

  Future<void> _subscribe(
    _Session session,
    BluetoothCharacteristic c,
    String role,
  ) async {
    await c.setNotifyValue(true);
    session.subs.add(
      c.onValueReceived.listen((chunk) {
        // Ignore notifications from a session we've already torn down.
        if (_session != session || !session.connected) return;
        _lastRx = DateTime.now();
        for (final frame in session.asm[role]!.feed(chunk)) {
          if (frame.valid) _onFrame(role, frame);
        }
      }),
    );
  }

  // ── link-down handling (drives reconnect via the caller's contract) ─────────────
  void _onLinkDown(_Session session) {
    if (_session != session) return; // a stale session's stream
    final wasIntentional = session.intentionalClose;
    session.connected = false;
    // A drain in flight must complete (with linkDown) immediately, not run out
    // its full budget.
    _drain?.onLinkDown();
    if (!wasIntentional) {
      _feedReconnectDetectors();
      final reason = session.device.disconnectReason;
      _log('Link down (reason=${reason?.description ?? "unknown"}).');
    }
    // The caller (AppState) listens for the 'disconnected' phase to drive its
    // reconnect loop; we surface it here. We do NOT auto-reconnect inside the
    // engine — the caller owns reconnect intent (keepAlive), and routes it back
    // through the same single-flight connect, so there's still exactly one path.
    _setOffloadActive(false);
    _setPhase(BleConnState.idle);
  }

  /// Feed an UNINTENTIONAL disconnect to the cross-reconnect detectors. A timeout
  /// is approximated by "not an intentional close". The detectors self-reset when
  /// a disconnect does not match their quick-timeout pattern.
  void _feedReconnectDetectors() {
    final now = DateTime.now();
    final sinceArm = _armTime == null
        ? null
        : now.difference(_armTime!).inMilliseconds / 1000.0;
    final sinceBond = _bondTime == null
        ? null
        : now.difference(_bondTime!).inMilliseconds / 1000.0;
    if (_marginalRadio.connectionEnded(
      wasArmed: _liveEnabled,
      secondsSinceArm: sinceArm,
      timedOut: true,
    )) {
      state.standardHrFallback = true;
      onState(state);
      _log(
        '[RECONNECT] marginal-radio tripped — standard-HR fallback enabled.',
      );
    }
    if (_postBondLoop.connectionEnded(
      wasBonded: _bondTime != null,
      secondsSinceBond: sinceBond,
      timedOut: true,
    )) {
      state.needsRepairGuide = true;
      onState(state);
      _log('[RECONNECT] post-bond loop tripped — surfacing re-pair guide.');
    }
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

  // ── record store sinks (wrap the caller's sinks + arm the derive debounce) ──────
  // The drain controller persists through these so a stored historical batch (or a
  // single live record) re-arms the debounced onDataStored trigger.
  Future<void> _storeRecord(Sample? sample, RawRecord raw) async {
    await onRecord(sample, raw);
    _noteStored();
  }

  Future<void> _storeRecordsBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
  ) async {
    if (raws.isEmpty) return;
    await onRecordsBatch!(raws, samples);
    _noteStored();
  }

  /// Atomic commit of a sync chunk (raw + samples + cursor) before the ACK.
  Future<void> _commitBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
    String? trimTokenHex,
  ) async {
    if (raws.isEmpty && trimTokenHex == null) return;
    await onCommitBatch!(raws, samples, trimTokenHex);
    if (raws.isNotEmpty) _noteStored();
  }

  // ── frame handling ─────────────────────────────────────────────────────────────
  void _onFrame(String role, Frame frame) {
    final pt = frame.packetType;
    if (role == 'data' &&
        (pt == PacketType.metadata || pt == PacketType.historicalData)) {
      _enqueueOffloadFrame(frame);
      return;
    }
    _processImmediateFrame(frame);
  }

  void _processImmediateFrame(Frame frame) {
    final pt = frame.packetType;
    if (pt == PacketType.metadata) {
      unawaited(_handleSyncMarker(frame));
      return;
    }
    // LIVE streams: realtime HR/RR (0x28), realtime R10 (0x2B), IMU (0x33).
    // EPHEMERAL — these are the high-rate flood (~655 MB/day) and the daily
    // metrics need ONLY the 1 Hz historical substrate (0x2F / R24). We do NOT
    // persist them to raw_records; instead we route them to the in-memory live
    // sink (live UI / spot-check / workout feature-extraction). We also do NOT
    // arm the derive debounce (nothing was stored). Never touch the
    // historical-sync bookkeeping (which keys off 0x2F only).
    if (pt == PacketType.realtimeData ||
        pt == PacketType.realtimeRawData ||
        pt == PacketType.realtimeImuStream) {
      final liveHex = _innerHex(frame.inner);
      // recTs = the frame's REAL device time (epoch sec) — cheap decode, for the
      // ephemeral sink (e.g. spot-check buffering). Null if undecodable.
      final liveTs = decodeRecord(liveHex)?.ts;
      onLiveFrame?.call(
        pt,
        liveHex,
        (liveTs != null && liveTs > 0) ? liveTs : null,
      );
      // Fall through to decodeFrame so the UI gets live telemetry (state.liveHr).
    }
    if (pt == PacketType.historicalData) {
      final recType = frame.inner.length > 1 ? frame.inner[1] : -1;
      final counter = _counterFromInner(frame.inner);
      // Decode the record FIRST so we can stamp its REAL time onto rec_ts. The
      // DerivationEngine buckets/windows days by rec_ts, so a multi-day flash
      // backfill (all received in one sync) splits into correct per-real-day
      // buckets instead of collapsing into one "today".
      Sample? sample;
      if (recType == Record.r24) {
        final r = parseR24(frame.inner);
        if (r != null) {
          sample = Sample(
            tsEpoch: r.tsEpoch,
            counter: r.counter,
            hr: r.hr,
            rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
            ax: r.accelG.isNotEmpty ? r.accelG[0] : 0,
            ay: r.accelG.length > 1 ? r.accelG[1] : 0,
            az: r.accelG.length > 2 ? r.accelG[2] : 0,
            spo2RedRaw: r.spo2RedRaw,
            spo2IrRaw: r.spo2IrRaw,
            skinTempRaw: r.skinTempRaw,
          );
        }
      } else if (recType == Record.r10) {
        final r = parseR10Lite(frame.inner);
        if (r != null) {
          sample = Sample(tsEpoch: r.tsEpoch, counter: r.counter, hr: r.hr);
        }
      }
      // PLAUSIBILITY GATE. When we have a decoded record time, drop records
      // whose unix is implausible vs wall-clock and (when known) the strap's own
      // GET_DATA_RANGE window — a previous owner's wandering-clock pollution.
      // Records with no decodable ts are kept (can't gate them).
      if (sample != null && sample.tsEpoch > 0) {
        if (!isPlausibleUnix(
          sample.tsEpoch,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sessionOldestUnix: _sessionOldestUnix,
          sessionNewestUnix: _sessionNewestUnix,
        )) {
          _droppedImplausible++;
          return; // neither stored nor counted; the ACK still walks the cursor
        }
        if (sample.tsEpoch > _frontierTs) _frontierTs = sample.tsEpoch;
      }
      final raw = RawRecord(
        counter: counter,
        packetType: pt,
        hex: _innerHex(frame.inner),
        capturedAt: DateTime.now().millisecondsSinceEpoch,
        recTs: (sample != null && sample.tsEpoch > 0) ? sample.tsEpoch : null,
      );
      // Hand the record to the offload controller (it buffers per-batch until the
      // HISTORY_END flush, which persists raw-first BEFORE we ACK). The controller
      // is armed for the whole connection, so this is always present; the fallback
      // just stores directly if a frame somehow arrives before setup completed.
      final d = _drain;
      if (d != null) {
        _armIdleWatchdog(); // a record arrived → the strap is still draining
        d.onHistoricalRecord(raw, sample);
      } else {
        unawaited(_storeRecord(sample, raw));
      }
      return;
    }
    if (pt == PacketType.commandResponse) {
      _log(
        '[RESP] op=0x${frame.opcode.toRadixString(16)} '
        'inner=${_innerHex(frame.inner)}',
      );
    } else if (pt == PacketType.event) {
      _log('[EVENT] ${_innerHex(frame.inner)}');
      final e = parseEvent(frame.inner);
      if (e != null) {
        onEvent?.call(e.eventId, e.tsEpoch, _innerHex(frame.inner));
      }
    }
    final decoded = _maybeAugmentDataRange(frame, decodeFrame(frame));
    _absorbState(decoded);
  }

  void _enqueueOffloadFrame(Frame frame) {
    _offloadFrames.add(frame);
    if (_offloadActive || frame.packetType == PacketType.historicalData) {
      _setOffloadActive(true);
    }
    if (_drainingOffloadFrames) return;
    _drainingOffloadFrames = true;
    unawaited(_drainOffloadFrames());
  }

  Future<void> _drainOffloadFrames() async {
    while (_offloadFrames.isNotEmpty) {
      final count = _offloadFrames.length > 64 ? 64 : _offloadFrames.length;
      final batch = _offloadFrames.sublist(0, count);
      _offloadFrames.removeRange(0, count);
      for (final frame in batch) {
        if (frame.packetType == PacketType.metadata) {
          await _handleSyncMarker(frame);
        } else {
          _processHistoricalFrame(frame);
        }
      }
      if (_offloadFrames.isNotEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _drainingOffloadFrames = false;
  }

  void _processHistoricalFrame(Frame frame) {
    final pt = frame.packetType;
    if (pt != PacketType.historicalData) return;
    final recType = frame.inner.length > 1 ? frame.inner[1] : -1;
    final counter = _counterFromInner(frame.inner);
    Sample? sample;
    if (recType == Record.r24) {
      final r = parseR24(frame.inner);
      if (r != null) {
        sample = Sample(
          tsEpoch: r.tsEpoch,
          counter: r.counter,
          hr: r.hr,
          rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
          ax: r.accelG.isNotEmpty ? r.accelG[0] : 0,
          ay: r.accelG.length > 1 ? r.accelG[1] : 0,
          az: r.accelG.length > 2 ? r.accelG[2] : 0,
          spo2RedRaw: r.spo2RedRaw,
          spo2IrRaw: r.spo2IrRaw,
          skinTempRaw: r.skinTempRaw,
        );
      }
    } else if (recType == Record.r10) {
      final r = parseR10Lite(frame.inner);
      if (r != null) {
        sample = Sample(tsEpoch: r.tsEpoch, counter: r.counter, hr: r.hr);
      }
    }
    final raw = RawRecord(
      counter: counter,
      packetType: pt,
      hex: _innerHex(frame.inner),
      capturedAt: DateTime.now().millisecondsSinceEpoch,
      recTs: (sample != null && sample.tsEpoch > 0) ? sample.tsEpoch : null,
    );
    final d = _drain;
    if (d != null) {
      d.onHistoricalRecord(raw, sample);
    } else {
      unawaited(_storeRecord(sample, raw));
    }
  }

  void _absorbState(Decoded d) {
    final f = d.fields;
    if (d.kind == 'cmd_response' && f['opcode'] == Cmd.getDataRange) {
      final oldest = (f['history_oldest'] as num?)?.toInt();
      final newest = (f['history_newest'] as num?)?.toInt();
      if (oldest != null) _strapHistoryOldestTs = oldest;
      if (newest != null) _strapHistoryNewestTs = newest;
      unawaited(
        LocalDb.upsertSyncLedgerEntry(
          status: 'range_seen',
          metaPatch: {
            'strap_history_oldest_ts': _strapHistoryOldestTs,
            'strap_history_newest_ts': _strapHistoryNewestTs,
          },
        ),
      );
    }
    if (f.containsKey('alarm_epoch')) {
      final e = f['alarm_epoch'] as int;
      state.alarmEpoch = e > 1000000000 ? e : null;
      onState(state);
    }
    if (f.containsKey('strap_name')) {
      // Guard with cleanDeviceLabel: a garbled name read never overwrites the
      // last good one (keeps "?*" off the UI).
      final nm = cleanDeviceLabel(f['strap_name'] as String?);
      if (nm != null) {
        state.strapName = nm;
        onState(state);
      }
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
    if (f.containsKey('clock_epoch')) {
      final dev = f['clock_epoch'] as int;
      final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _clockRef = ClockRef(device: dev, wall: wall);
      _log('Clock correlated: device=$dev wall=$wall (drift=${wall - dev}s).');
      // Re-issue SET_CLOCK if the strap RTC has drifted > 1 day or is unset.
      if (ClockPolicy.shouldSetClock(dev, wall)) {
        _log('Clock drift over policy — re-issuing SET_CLOCK.');
        unawaited(setClock());
      }
    }
    if (f.containsKey('range_oldest') && f.containsKey('range_newest')) {
      _sessionOldestUnix = f['range_oldest'] as int;
      _sessionNewestUnix = f['range_newest'] as int;
      state.dataRangeOldest = _sessionOldestUnix;
      state.dataRangeNewest = _sessionNewestUnix;
      onState(state);
    }
    if (d.kind == 'cmd_response' && f['hello'] is HelloInfo) {
      final h = f['hello'] as HelloInfo;
      // Serial now comes from the fixed offset in the HELLO body (see
      // parseHello) — the band's true factory serial, correct even when the user
      // renamed the strap (the advertised name carries no serial then). Guarded
      // by cleanDeviceLabel as a belt-and-braces against any junk ever reaching
      // the UI (the "?*" symptom).
      state.serial = cleanDeviceLabel(h.serial) ?? state.serial;
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

  /// (Re)arm the 60s idle watchdog. Called on every offload frame (records +
  /// markers). If the strap goes silent mid-offload, the open (un-ACKed) chunk is
  /// abandoned so we never ACK a partial — the band re-delivers it next offload.
  void _armIdleWatchdog() {
    final session = _session;
    if (session == null || !session.connected) return;
    session.idleWatchdog?.cancel();
    session.idleWatchdog = Timer(
      const Duration(seconds: kBackfillIdleTimeoutSeconds),
      () {
        _log(
          '[SYNC] idle watchdog: strap silent ${kBackfillIdleTimeoutSeconds}s '
          'mid-offload — abandoning the open chunk (band will re-send).',
        );
        _drain?.discardOpenChunk();
        unawaited(_onOffloadFinished(complete: false));
      },
    );
  }

  Future<void> _handleSyncMarker(Frame frame) async {
    final m = parseMetadata(frame.inner);
    if (m == null) return;
    _armIdleWatchdog();
    _log(
      '[SYNC] META sub=${m.sub} inner='
      '${frame.inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    if (m.sub == SyncMeta.historyStart) {
      _setOffloadActive(true);
      return;
    }
    if (m.sub == SyncMeta.historyEnd && m.token != null) {
      final d = _drain;
      if (d == null) return;
      final tokenHex = m.token!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      _log(
        '[SYNC] HistoryEnd batch=${m.batchId} records=${d.records} '
        'token=$tokenHex',
      );
      // SAFE-TRIM INVARIANT: persist decoded+raw AND the continuation cursor
      // DURABLY (one transaction) BEFORE the ACK. The band trims its flash only
      // once the ACK is link-layer confirmed, so a crash before the ACK
      // re-delivers the chunk. Echo the 8-byte slice the band acks verbatim —
      // a mangled echo is the "Groundhog Day" re-flood bug.
      await d.commit(m.token); // raw + samples + strap_trim cursor, atomic
      final ack = buildBatchAck(_seq.nextSync(), m.token!);
      _log(
        '[SYNC] ACK frame='
        '${ack.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      );
      d.noteBatchAcked();
      await _write(ack); // ACK and KEEP listening
      await LocalDb.upsertSyncLedgerEntry(
        status: 'acknowledged',
        ackedAt: DateTime.now().millisecondsSinceEpoch,
        metaPatch: {
          'last_batch_token': tokenHex,
          'last_batch_id': m.batchId,
          'last_batch_records': d.records,
          'last_ack_batches': d.batches,
          'strap_history_oldest_ts': _strapHistoryOldestTs,
          'strap_history_newest_ts': _strapHistoryNewestTs,
        },
      );
      _noteStored(); // a banked batch → schedule a (debounced) derive
    } else if (m.sub == SyncMeta.historyComplete) {
      final d = _drain;
      if (d == null) return;
      // Backlog fully handed over (cursor is now at the live edge). Commit the tail
      // and KEEP LISTENING — live records continue on the same subscription. We do
      // NOT ACK a HISTORY_COMPLETE and we do NOT switch modes.
      await d.commit(null); // tail (no new token) — persist anything buffered
      d.onComplete();
      _historyCompletions++;
      _session?.idleWatchdog?.cancel();
      await LocalDb.upsertSyncLedgerEntry(
        status: 'complete',
        metaPatch: {
          'history_complete_at': DateTime.now().millisecondsSinceEpoch,
          'records_seen': d.records,
          'batches_acked': d.batches,
          'history_requests': _historyRequests,
          'history_completions': _historyCompletions,
          'strap_history_oldest_ts': _strapHistoryOldestTs,
          'strap_history_newest_ts': _strapHistoryNewestTs,
        },
      );
      _log(
        '[SYNC] HistoryComplete — backlog drained (${d.records} records, '
        '$_droppedImplausible dropped). Still listening for live records.',
      );
      _noteStored();
      await _onOffloadFinished(complete: true);
    }
  }

  // ── post-offload policy: empty-sync, stuck-strap, auto-continue ──────────────
  Future<void> _onOffloadFinished({required bool complete}) async {
    final d = _drain;
    if (d == null) return;
    final banked = d.recordsThisOffload > 0;
    _emptyStreak = banked ? 0 : (_emptyStreak + 1);

    if (complete) {
      // Empty-sync: ≥3 consecutive console-only completed offloads ⇒ RTC lost.
      if (_emptySync.recordCompletedSync(
        bankedSensorRecords: banked,
        consoleOnly: !banked,
      )) {
        state.syncClockLost = true;
        onState(state);
        _log('[SYNC] empty-sync tripped — strap RTC likely lost.');
      }
    }

    // Stuck-strap: frontier frozen ≥10 min while the strap is >5 min ahead.
    if (_stuckStrap.observe(_sessionNewestUnix, _frontierTs, _wallSecs())) {
      state.strapNeedsReboot = true;
      onState(state);
      _log('[SYNC] stuck-strap tripped — defensive SET_CLOCK.');
      await setClock();
    }

    // Auto-continue: re-kick immediately (bypassing the 15-min floor) if the strap
    // still has real backlog and the cursor advanced — but cap per connection.
    final cont = BackfillContinuation.shouldAutoContinue(
      stillConnected: _session?.connected == true,
      strapNewestTs: _sessionNewestUnix,
      ourFrontierTs: _frontierTs,
      rowsPersistedThisSession: d.recordsThisOffload,
      lastTrimAdvanced: d.lastTrimAdvanced,
      consecutiveCount: _autoContinueCount,
    );
    d.resetOffloadCounters();
    if (cont) {
      _autoContinueCount++;
      _log('[SYNC] auto-continue #$_autoContinueCount — more backlog remains.');
      await _triggerBackfill(BackfillTrigger.autoContinue);
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

  /// Re-trigger a historical offload over the CURRENT connection (no reconnect, no
  /// re-subscribe). Re-arms the offload controller's completion flag and re-sends
  /// SEND_HISTORICAL_DATA so the band streams anything banked since the last
  /// HISTORY_COMPLETE. Used when a workout ends so a live-fed session still gets its
  /// window backfilled from flash. Stays in `listening` — no mode change.
  Future<void> requestHistorySync() async {
    _historyRequests++;
    await LocalDb.upsertSyncLedgerEntry(
      status: 'requested',
      metaPatch: {
        'request_reason': 'manual',
        'request_refresh_range': true,
        'request_sent_at': DateTime.now().millisecondsSinceEpoch,
        'history_requests': _historyRequests,
        'history_completions': _historyCompletions,
        'strap_history_oldest_ts': _strapHistoryOldestTs,
        'strap_history_newest_ts': _strapHistoryNewestTs,
      },
    );
    await _triggerBackfill(BackfillTrigger.manual);
  }

  /// Await the CURRENT historical offload reaching HISTORY_COMPLETE (or link-down /
  /// the safety timeout). Does NOT change the connection phase and NEVER aborts —
  /// listening is continuous; this just lets a caller block until the band's
  /// backlog is fully handed over (e.g. so a foreground finalize derive runs over a
  /// complete day). The offload itself was already kicked by [_doConnect]'s INIT.
  ///
  /// If the offload already completed (HISTORY_COMPLETE seen before this is called),
  /// it returns immediately. Kept named `runSync` for the existing call sites.
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) async {
    final session = _session;
    final drain = _drain;
    if (session == null || !session.connected || drain == null) {
      _log('runSync: no live link — nothing to await.');
      return SyncReport(0, 0, false);
    }
    final report = await drain.awaitComplete(
      isLinkUp: () => session.connected,
      timeout: timeout,
    );
    _lastSyncReport = report;
    await LocalDb.upsertSyncLedgerEntry(
      status: report.complete
          ? 'complete'
          : report.records > 0
          ? 'partial'
          : 'idle',
      lastError: report.complete
          ? null
          : report.records == 0
          ? 'no_offload_progress'
          : null,
      metaPatch: {
        'last_report_records': report.records,
        'last_report_batches': report.batches,
        'last_report_complete': report.complete,
        'last_progress_ms': drain.lastProgressMs,
        'history_requests': _historyRequests,
        'history_completions': _historyCompletions,
        'strap_history_oldest_ts': _strapHistoryOldestTs,
        'strap_history_newest_ts': _strapHistoryNewestTs,
      },
    );
    if (!report.complete) _setOffloadActive(false);
    _log(
      '[SYNC] OFFLOAD SUMMARY: records=${report.records} '
      'batches=${report.batches} complete=${report.complete}',
    );
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
      0,
      0,
      0,
      0,
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
      0,
      0,
    ]);
    _log('SET_ALARM_TIME → $epoch');
  }

  Future<void> getAlarm() => _send(Cmd.getAlarmTime, const [revision1]);
  Future<void> disableAlarm() => _send(Cmd.disableAlarm, const [0x00]);

  Future<void> getStrapName() =>
      _send(Cmd.getAdvertisingNameHarvard, const [0x00]);

  /// Rename the strap. Payload: [0x01][name length u8][ASCII name bytes][u32 0].
  Future<void> setStrapName(String name) async {
    // Cap at 20 ASCII chars (matches the reference + the GET decoder's length
    // assumption); the length byte then always stays < 0x20.
    final ascii =
        name.codeUnits.where((c) => c >= 0x20 && c < 0x7f).take(20).toList();
    final payload = <int>[0x01, ascii.length, ...ascii, 0, 0, 0, 0];
    await _send(Cmd.setAdvertisingNameHarvard, payload);
    _log('SET_ADVERTISING_NAME → "$name"');
  }

  Future<void> getBattery() => _send(Cmd.getBatteryLevel, const []);
  Future<void> getHello() => _send(Cmd.getHelloHarvard, const [0x00]);
  Future<void> buzz() =>
      _send(Cmd.runHapticsPattern, const [hapticShortPulse, 0, 0, 0, 0]);

  /// Enable live foreground streams (makes the band emit live R10/R11 + optical).
  /// Optical stays WRIST-GATED (0x6B only). This sends the toggle commands but
  /// DOES NOT change the displayed state — we stay in the single `listening` phase;
  /// live records simply start arriving on the same subscription history uses.
  Future<void> enableLiveStreams() async {
    _liveEnabled = true;
    _armTime =
        DateTime.now(); // marginal-radio detector measures arm→drop latency
    await _send(Cmd.toggleRealtimeHr, const [0x01]);
    // MARGINAL-RADIO FALLBACK: a weak radio can't sustain the high-rate R10/R11 +
    // IMU + optical flood, so once the detector trips we arm HR only.
    if (state.standardHrFallback) {
      _log('Live streams: standard-HR only (marginal-radio fallback).');
      return;
    }
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
      [
        Cmd.toggleOpticalMode,
        [revision1, 0x00],
      ],
      [
        Cmd.enableOpticalData,
        [revision1, 0x00],
      ],
      [
        Cmd.sendR10R11Realtime,
        [0x00],
      ],
      [
        Cmd.toggleImuMode,
        [0x00],
      ],
      [
        Cmd.toggleRealtimeHr,
        [0x00],
      ],
    ];
    for (final op in ops) {
      await _send(op[0] as int, (op[1] as List).cast<int>());
      await Future.delayed(const Duration(milliseconds: 60));
    }
    _liveEnabled = false;
    _armTime = null;
    state.liveHr = null;
    // No phase change — we stay `listening`; only the live R10/R11/optical streams
    // stop. Historical records + the heartbeat keep flowing on the same link.
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
    _drain = null;
    // Fire a final derive for anything stored-but-not-yet-derived, then disarm the
    // debounce timer so it doesn't fire into a dead connection.
    _deriveTimer?.cancel();
    _deriveTimer = null;
    if (_firstPending != null) {
      _firstPending = null;
      onDataStored?.call();
    }
    final device = session.device;
    await session.teardown();
    _session = null;
    _offloadFrames.clear();
    _drainingOffloadFrames = false;
    _setOffloadActive(false);
    if (intentional) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  void _setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    onOffloadState?.call(active);
  }

  Decoded _maybeAugmentDataRange(Frame frame, Decoded decoded) {
    if (decoded.kind != 'cmd_response') return decoded;
    final opcode = decoded.fields['opcode'];
    if (opcode != Cmd.getDataRange) return decoded;
    final payload = frame.inner.length > 3
        ? Uint8List.sublistView(frame.inner, 3)
        : Uint8List(0);
    final ts = <int>[];
    for (var off = 0; off + 4 <= payload.length; off++) {
      final v = u32(payload, off);
      if (v >= 1600000000 && v <= 2100000000) {
        ts.add(v);
      }
    }
    if (ts.isEmpty) return decoded;
    final fields = <String, dynamic>{...decoded.fields};
    fields['history_oldest'] = ts.reduce((a, b) => a < b ? a : b);
    fields['history_newest'] = ts.reduce((a, b) => a > b ? a : b);
    return Decoded(decoded.kind, fields);
  }
}

/// Per-connection historical-offload helper. Buffers records per ACK boundary and
/// flushes them in one transaction (raw-first, BEFORE the HISTORY_END ACK). It is
/// armed for the whole connection (single listening mode) — it never aborts and
/// never switches modes. It just tracks running counts and exposes an
/// [awaitComplete] future that resolves when the band signals HISTORY_COMPLETE (or
/// the link drops / a safety timeout elapses), so a caller can block until the
/// backlog is fully handed over without disturbing the continuous listen.
class _DrainController {
  final SampleSink onRecord;
  final BatchSink? onRecordsBatch;
  final CommitSyncBatchSink? onCommit;
  final void Function(String) log;

  _DrainController({
    required this.onRecord,
    required this.onRecordsBatch,
    required this.onCommit,
    required this.log,
  });

  final List<RawRecord> _raws = [];
  final List<Sample?> _samples = [];

  int records = 0; // total this connection
  int recordsThisOffload = 0; // since the last HISTORY_COMPLETE / rearm
  int batches = 0;
  DateTime _lastProgressAt = DateTime.now();
  bool _complete = false;
  bool _linkDown = false;

  int get bufferedRecords => _raws.length;
  int get lastProgressMs => _lastProgressAt.millisecondsSinceEpoch;
  // Trim-advance tracking for the stuck/continuation detectors: a HISTORY_END
  // whose 8-byte token differs from the last one means the cursor moved.
  String? _lastAckedToken;
  bool lastTrimAdvanced = false;

  bool get _buffering => onCommit != null || onRecordsBatch != null;

  void onHistoricalRecord(RawRecord raw, Sample? sample) {
    records++;
    recordsThisOffload++;
    _lastProgressAt = DateTime.now();
    if (_buffering) {
      _raws.add(raw);
      _samples.add(sample);
    } else {
      unawaited(onRecord(sample, raw));
    }
  }

  void noteBatchAcked() => batches++;

  /// HISTORY_COMPLETE seen — the backlog has been fully handed over. Marks the
  /// current offload complete (for any awaiter) WITHOUT ending the listen.
  void onComplete() {
    _complete = true;
    _lastProgressAt = DateTime.now();
  }

  /// Re-arm for a fresh offload over the same connection (clears the COMPLETE flag
  /// so a new awaitComplete() blocks until the next HISTORY_COMPLETE).
  void rearm() {
    _complete = false;
    _linkDown = false;
    _lastProgressAt = DateTime.now();
  }

  void onLinkDown() => _linkDown = true;

  /// Per-offload counters reset (after the post-offload policy has read them).
  void resetOffloadCounters() => recordsThisOffload = 0;

  /// Abandon the buffered-but-not-yet-committed chunk WITHOUT persisting (idle
  /// watchdog). These records were never ACKed, so the band re-delivers them on the
  /// next offload — dropping them here just avoids ACKing a partial.
  void discardOpenChunk() {
    if (_raws.isEmpty) return;
    log('discarding ${_raws.length} un-ACKed buffered records (idle).');
    _raws.clear();
    _samples.clear();
  }

  /// SAFE-TRIM commit: persist the buffered chunk + the continuation [token]
  /// ATOMICALLY (via onCommit) and return only once durable — the caller writes
  /// the ACK afterwards. Snapshots the buffer so records arriving during the await
  /// land in the next commit. Updates [lastTrimAdvanced].
  Future<void> commit(List<int>? token) async {
    final tokenHex = token
        ?.map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    lastTrimAdvanced = tokenHex != null && tokenHex != _lastAckedToken;
    if (tokenHex != null) _lastAckedToken = tokenHex;
    final raws = List<RawRecord>.from(_raws);
    final samples = List<Sample?>.from(_samples);
    _raws.clear();
    _samples.clear();
    try {
      if (onCommit != null) {
        await onCommit!(raws, samples, tokenHex);
      } else if (onRecordsBatch != null && raws.isNotEmpty) {
        await onRecordsBatch!(raws, samples);
      }
    } catch (e) {
      log('offload commit error: $e');
    }
  }

  Future<void> flush() => commit(null);

  /// Resolve once the current offload reaches HISTORY_COMPLETE, the link drops, or
  /// [timeout] elapses. Pure waiting — NO abort is ever sent (cutting the offload
  /// short is exactly what stalled the cursor). Polls the lightweight stop-evaluator
  /// every second.
  Future<SyncReport> awaitComplete({
    required bool Function() isLinkUp,
    Duration timeout = const Duration(seconds: 600),
  }) async {
    final evaluator = DrainStopEvaluator(timeout: timeout);
    final start = DateTime.now();
    final done = Completer<SyncReport>();
    Timer.periodic(const Duration(seconds: 1), (t) async {
      if (done.isCompleted) {
        t.cancel();
        return;
      }
      if (!isLinkUp()) _linkDown = true;
      final stop = evaluator.evaluate(
        complete: _complete,
        linkDown: _linkDown,
        sinceStart: DateTime.now().difference(start),
      );
      if (stop == DrainStop.keepGoing) {
        if (DateTime.now().difference(_lastProgressAt) <
            const Duration(seconds: 60)) {
          return;
        }
        t.cancel();
        await flush();
        log('[SYNC] idle timeout — no offload progress for 60s.');
        done.complete(SyncReport(records, batches, false));
        return;
      }
      t.cancel();
      await flush();
      log('[SYNC] await stop=$stop.');
      done.complete(SyncReport(records, batches, stop == DrainStop.complete));
    });
    return done.future;
  }
}
