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
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
      String? trimTokenHex, {
      List<ArchiveRecord>? archives,
    });

/// Persist an UNDECODABLE historical record (unknown/unsupported version) to the
/// durable archive (never pruned). Used only by the pre-setup fallback path; the
/// drain path archives inside the SAME transaction as the batch commit so the
/// safe-trim invariant holds (see [CommitSyncBatchSink]).
typedef ArchiveSink = Future<void> Function(ArchiveRecord archive);

/// Fired (debounced) after records are persisted so the caller can schedule a
/// DerivationEngine pass. Replaces the old "runSync() → SyncReport → derive"
/// trigger now that listening is continuous and there's no discrete sync end.
typedef DataStoredSink = void Function();

/// Map a decoded gen5 historical record onto the band-agnostic `Sample` type,
/// or null when this record kind has no `Sample` equivalent (yet).
///
/// Only `Gen5HistorySample` (v18, the per-second stream) maps today — the
/// deep buffers (`Gen5OpticalBuffer`/`Gen5ImuBuffer`/`Gen5PpgWaveform`, R22
/// opt-in only) need their own raw-buffer storage, not a 1Hz `Sample`, so
/// they (and a null [g], e.g. an unrecognised version) correctly return null
/// here — the caller archives those, exactly like an undecodable gen4
/// record. Extracted as a top-level pure function (rather than inlined in
/// `_ingestHistoricalFrame`) so the mapping is unit-testable without a live
/// BLE session — see `gen5_sample_mapping_test.dart`.
@visibleForTesting
Sample? sampleFromGen5Historical(Gen5HistoricalRecord? g) {
  if (g is! Gen5HistorySample) return null;
  return Sample(
    tsEpoch: g.unix,
    counter: g.recordIndex,
    hr: g.heartRate,
    rrIntervalsMs: List<int>.from(g.rrIntervalsMs),
    // Gravity vector is float32 g-units on BOTH generations (unlike skin
    // temp / SpO2, which use gen5-specific scales/mechanisms — see
    // Gen5HistorySample's field docs) — safe to feed straight into the
    // shared ax/ay/az fields analytics already reads band-agnostically.
    ax: g.gravityG.isNotEmpty ? g.gravityG[0] : null,
    ay: g.gravityG.length > 1 ? g.gravityG[1] : null,
    az: g.gravityG.length > 2 ? g.gravityG[2] : null,
  );
}

@visibleForTesting
int countHistoricalBurstPackets({
  required Map<int, int> dataPacketCountsByRevision,
  int revision16Count = 0,
  int revision19Count = 0,
  int revision22Count = 0,
  int revision25Count = 0,
  int revision26Count = 0,
}) {
  return dataPacketCountsByRevision.values.fold<int>(
        0,
        (sum, count) => sum + count,
      ) +
      revision16Count +
      revision19Count +
      revision22Count +
      revision25Count +
      revision26Count;
}

@visibleForTesting
int countBurstTrafficPackets({
  required Map<int, int> dataPacketCountsByRevision,
  int revision16Count = 0,
  int revision19Count = 0,
  int revision22Count = 0,
  int revision25Count = 0,
  int revision26Count = 0,
  int eventCount = 0,
  int consoleCount = 0,
  int unknownCount = 0,
}) {
  return countHistoricalBurstPackets(
        dataPacketCountsByRevision: dataPacketCountsByRevision,
        revision16Count: revision16Count,
        revision19Count: revision19Count,
        revision22Count: revision22Count,
        revision25Count: revision25Count,
        revision26Count: revision26Count,
      ) +
      eventCount +
      consoleCount +
      unknownCount;
}

@visibleForTesting
bool shouldPauseMaintenanceTraffic({required bool offloadActive}) =>
    offloadActive;

/// Whether a HISTORY_END burst's packet accounting matches what the band
/// reported sending (`expectedPacketCount`, from the metadata frame).
///
/// [actualBurstPacketCount] only counts packets that reached
/// onHistoricalRecord/onUndecodableRecord — i.e. that PASSED the RecordGate
/// plausibility check. A record the gate rejects (a stale/wandering-clock
/// block — see RecordGate.admit) is, by design, "neither stored nor
/// counted": it never reaches either callback. The band's own count has no
/// such carve-out — it just counts every packet it physically transmitted.
/// [droppedThisBurst] (RecordGate.dropped delta across this burst) must be
/// added back in before comparing, or a burst containing even one
/// gate-rejected record can never validate — which discards its OTHER,
/// perfectly good buffered records and re-requests the same stuck block
/// forever (zero sync progress).
@visibleForTesting
bool burstPacketCountMatches({
  required int expectedPacketCount,
  required int actualBurstPacketCount,
  required int droppedThisBurst,
}) =>
    expectedPacketCount == actualBurstPacketCount + droppedThisBurst;

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

enum _HpsTerminalKind {
  metadataWhileNotSyncing,
  success,
  timeout,
  disconnected,
}

class _HpsTerminal {
  final _HpsTerminalKind kind;
  final String? reason;
  final int successfulBursts;
  final int records;
  final int batches;
  final String? gapSummary;

  const _HpsTerminal({
    required this.kind,
    this.reason,
    required this.successfulBursts,
    required this.records,
    required this.batches,
    this.gapSummary,
  });
}

class _SessionPacketCounts {
  final Map<int, int> dataPacketCountsByRevision;
  final int revision16Count;
  final int consoleLogPacketCount;
  final int unknownRevisionCount;
  final int revision19Count;
  final int revision22Count;
  final int revision25Count;
  final int revision26Count;

  const _SessionPacketCounts({
    required this.dataPacketCountsByRevision,
    required this.revision16Count,
    required this.consoleLogPacketCount,
    required this.unknownRevisionCount,
    required this.revision19Count,
    required this.revision22Count,
    required this.revision25Count,
    required this.revision26Count,
  });

  static const zero = _SessionPacketCounts(
    dataPacketCountsByRevision: <int, int>{},
    revision16Count: 0,
    consoleLogPacketCount: 0,
    unknownRevisionCount: 0,
    revision19Count: 0,
    revision22Count: 0,
    revision25Count: 0,
    revision26Count: 0,
  );
}

class _SessionGapSummary {
  final int intraBurst;
  final int crossBurst;
  final int missing;
  final int backward;

  const _SessionGapSummary({
    required this.intraBurst,
    required this.crossBurst,
    required this.missing,
    required this.backward,
  });

  static const zero = _SessionGapSummary(
    intraBurst: 0,
    crossBurst: 0,
    missing: 0,
    backward: 0,
  );

  bool get isEmpty =>
      intraBurst == 0 && crossBurst == 0 && missing == 0 && backward == 0;

  @override
  String toString() {
    if (isEmpty) return 'none';
    final parts = <String>[];
    if (intraBurst > 0) parts.add('intraBurst=$intraBurst');
    if (crossBurst > 0) parts.add('crossBurst=$crossBurst');
    if (missing > 0) parts.add('missing=$missing');
    if (backward > 0) parts.add('backward=$backward');
    return '{${parts.join(', ')}}';
  }
}

/// All per-connection resources. A fresh one is built on every connect and torn
/// down (every subscription + timer cancelled, characteristics nulled) on every
/// disconnect — so nothing bleeds across reconnects.
class _Session {
  final BluetoothDevice device;
  BluetoothCharacteristic? cmdTo;

  /// Which WHOOP generation this link speaks. Defaults to gen4 (WHOOP 4) and is
  /// pinned once during service discovery via [applyBand] — everything that
  /// differs by generation (frame header/CRC, GATT UUIDs, command envelope,
  /// history ACK, record decode) reads from here.
  BandProfile band = BandProfile.gen4;

  final Map<String, FrameReassembler> asm = {
    'cmd_from': FrameReassembler(),
    'events': FrameReassembler(),
    'data': FrameReassembler(),
  };

  /// Pin this session's generation and rebuild the reassemblers with the
  /// matching header shape. Called once, at discovery, before any frame is fed.
  void applyBand(BandProfile b) {
    band = b;
    asm['cmd_from'] = FrameReassembler(profile: b);
    asm['events'] = FrameReassembler(profile: b);
    asm['data'] = FrameReassembler(profile: b);
  }
  final List<StreamSubscription> subs = [];
  Timer? heartbeat;
  // Session-owned timers; a disconnect cancels them.
  Timer? keepAlive; // 30s: liveness watchdog + battery poll + realtime re-arm
  Timer? periodicBackfill; // 900s: re-trigger the historical offload
  Timer? idleWatchdog; // 60s: strap went silent mid-offload
  Timer? historicalRetry; // explicit abort→retry settle
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
    historicalRetry?.cancel();
    historicalRetry = null;
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

  /// If provided, an undecodable historical record that arrives OUTSIDE an armed
  /// drain (pre-setup fallback only) is archived durably via this sink. The
  /// normal drain path archives inside the batch-commit transaction instead.
  final ArchiveSink? onArchiveRecord;

  /// Tunable debounce window for [onDataStored]. Default coalesces a burst once the
  /// stream goes quiet. The debouncer can run in a fast stale mode or a calmer
  /// fresh mode depending on [deriveDataStaleness] — or a fast foreground mode
  /// depending on [isForegroundActive], which takes priority over both.
  final DeriveDebouncer deriveDebouncer;
  final Duration Function() deriveDataStaleness;
  final bool Function() isForegroundActive;

  /// Opt-in: send the gen5 "R22" 16-flag SET_CONFIG enable sequence
  /// (`kGen5R22EnableFlags`) before the historical offload on a gen5 link,
  /// unlocking the v20 (optical)/v21 (IMU)/v26 (PPG) deep buffers. Defaults to
  /// OFF — the official WHOOP app never sends this either, the sequence is
  /// UNTESTED on physical hardware, and without it a gen5 strap still serves
  /// its always-on v18 per-second stream perfectly well. Wire a caller-owned
  /// settings read here to make it a real user-facing toggle.
  final bool Function() gen5DeepBuffersEnabled;

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
    this.onArchiveRecord,
    this.cursorReader,
    this.deriveDebouncer = const DeriveDebouncer(),
    this.isBackgroundDrainer = false,
    this.deriveDataStaleness = _defaultDeriveDataStaleness,
    this.isForegroundActive = _defaultIsForegroundActive,
    this.gen5DeepBuffersEnabled = _defaultGen5DeepBuffersDisabled,
  });

  static bool _defaultGen5DeepBuffersDisabled() => false;

  /// True for the headless restore-drain engine (runHeadlessSync). It YIELDS the
  /// band to a foreground engine rather than fighting it — see [_claimBand]. The
  /// foreground app engine leaves this false and always wins.
  final bool isBackgroundDrainer;

  static Duration _defaultDeriveDataStaleness() => const Duration(days: 3650);
  // Callers that never wire this (e.g. the headless background drainer, which
  // has no concept of foreground at all) correctly default to false — the
  // fresh/stale staleness tiers still apply, unaffected.
  static bool _defaultIsForegroundActive() => false;

  /// Optional reader for a persisted cursor value (e.g. counter_hw) so the engine
  /// can seed its frontier from the durable store on connect — making the stuck/
  /// continuation detectors correct on the very first offload after a restart.
  final Future<int?> Function(String name)? cursorReader;

  final DeviceState state = DeviceState();

  // ── PROCESS-WIDE SINGLE-OWNER GUARD ─────────────────────────────────────────
  // The strap streams its historical offload to EVERY subscribed central. If two
  // BleEngine instances in this process are connected at once — the foreground
  // app engine AND the headless restore-drain engine (runHeadlessSync, fired by
  // the iOS CoreBluetooth-restoration wake) — BOTH parse the same HISTORY_END and
  // send CONFLICTING batch-ACKs with different seq numbers. The band's flash trim
  // cursor then races and the offload never advances (observed on-device: batch
  // stuck at 28, duplicate ACKs, sync never completes). Enforce a single owner,
  // FOREGROUND-PRIORITY: a background drainer yields if the band is already owned;
  // a foreground engine preempts a background owner by dropping its link.
  static BleEngine? _bandOwner;

  /// Claim exclusive ownership of the band for this engine. Returns false only for
  /// a background drainer when another engine already owns it (→ it must NOT touch
  /// the band this cycle). A foreground engine always succeeds and preempts any
  /// background owner by disconnecting it.
  ///
  /// SERIALIZED PREEMPTION: the preempted engine's teardown is AWAITED (bounded)
  /// before we proceed — firing our connect while its disconnect is still in
  /// flight gave flutter_blue_plus two overlapping ops on the same peripheral
  /// (connect racing disconnect → spurious connect failures / a half-torn-down
  /// GATT). A hung teardown can't wedge us forever: after the timeout we log and
  /// proceed (the preempted engine's own session guards make its late teardown
  /// harmless once we own the band).
  Future<bool> _claimBand() async {
    final other = _bandOwner;
    final incumbentPresent = other != null && !identical(other, this);
    final decision = BandClaimPolicy.decide(
      incumbentPresent: incumbentPresent,
      // LIVENESS, not just non-nullness: a claim held by an engine that has no
      // session (its connect threw, or its link went down) is a STALE claim,
      // and honouring it wedged every later background drain for the whole
      // process lifetime ("strap not reachable this cycle", forever).
      incumbentLive: incumbentPresent && other.holdsBandLink,
      isBackgroundDrainer: isBackgroundDrainer,
    );
    switch (decision) {
      case BandClaimDecision.yieldToOwner:
        _log(
          'band already owned by a live foreground session — background drain '
          'yielding (avoids duplicate ACKs on the same offload).',
        );
        return false;
      case BandClaimDecision.preemptThenClaim:
        _log('preempting a background drain to take the foreground session.');
        try {
          await other!.disconnect().timeout(const Duration(seconds: 10));
        } on TimeoutException {
          _log('preempted engine teardown timed out after 10s — proceeding '
              'with the foreground connect anyway.');
        } catch (e) {
          _log('preempted engine teardown failed ($e) — proceeding.');
        }
        break;
      case BandClaimDecision.claim:
        if (incumbentPresent) {
          _log('taking over a STALE band claim (the previous owner has no '
              'live link).');
        }
        break;
    }
    _bandOwner = this;
    return true;
  }

  /// Whether this engine actually holds (or is actively bringing up) a BLE
  /// link — the liveness test [BandClaimPolicy] uses on the incumbent owner.
  /// A session object exists from the moment `_doConnect` starts, so a connect
  /// still in flight correctly counts as live; every failure path nulls the
  /// session and drops the phase to idle/error before returning.
  bool get holdsBandLink =>
      _session != null &&
      _phase != BleConnState.idle &&
      _phase != BleConnState.error;

  /// Test-only view of the process-wide single-owner claim.
  @visibleForTesting
  static bool get bandClaimed => _bandOwner != null;

  /// Test-only reset of the process-wide claim (static state otherwise leaks
  /// across test cases).
  @visibleForTesting
  static void resetBandClaimForTest() => _bandOwner = null;

  void _releaseBand() {
    if (identical(_bandOwner, this)) _bandOwner = null;
  }

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

  // ── reconnecting-state surface (owned by the caller's reconnect loop) ────────
  /// The caller (AppState._reconnect) owns reconnect INTENT, so only it knows
  /// when the engine's `idle` actually means "between reconnect attempts" rather
  /// than "genuinely disconnected". It calls this at the top of each retry so
  /// the UI can show a reconnecting/connecting state instead of 'disconnected'
  /// while the loop backs off. Only lifts idle/error — never stomps an
  /// in-flight connect phase or an established listen.
  void markReconnecting() {
    if (_phase == BleConnState.idle || _phase == BleConnState.error) {
      _setPhase(BleConnState.reconnecting);
    }
  }

  /// The reconnect loop gave up (keepAlive dropped / unpaired) — fall back to
  /// a truthful 'disconnected'. No-op unless we're actually in `reconnecting`.
  void clearReconnecting() {
    if (_phase == BleConnState.reconnecting) _setPhase(BleConnState.idle);
  }

  // ── OS-managed pending reconnect (background fallback) ───────────────────────
  /// Arm a flutter_blue_plus `autoConnect` pending connection and wait for the
  /// OS to complete it. Unlike the direct `connect(autoConnect:false)` retry
  /// loop (which needs our Dart timer alive to fire the next attempt), an armed
  /// autoConnect is held by the OS bluetooth stack: whenever the band comes
  /// back into range the link comes up without us polling. Used by the caller's
  /// reconnect loop as a low-churn fallback once direct attempts keep failing
  /// (or while backgrounded on Android, where the foreground service keeps the
  /// process — and therefore the pending connect — alive).
  ///
  /// flutter_blue_plus 1.36.x semantics honoured here:
  ///   - `connect(autoConnect: true)` REQUIRES `mtu: null` (asserted by the
  ///     plugin) and returns immediately — the link is only up once the
  ///     `connectionState` stream reports `connected`. The normal setup path
  ///     already requests the MTU explicitly after connect, so nothing is lost.
  ///   - the pending autoConnect is cancelled by `disconnect()`.
  ///
  /// TRADE-OFF (kept conservative): this method only WAITS for the OS-level
  /// link; it does NOT run service discovery/subscribe/INIT itself. On success
  /// the caller must immediately run the normal [connect] path — FBP treats a
  /// connect() on an already-connected device as a no-op, so the full setup
  /// (discover → subscribe → SET_CLOCK → INIT) runs exactly as for a direct
  /// connect. If we return false (deadline / caller gave up), the pending
  /// autoConnect is cancelled so a surprise OS connect can't come up later
  /// with no subscriptions/heartbeat attached.
  Future<bool> waitForOsAutoConnect(
    String remoteId, {
    Duration wait = const Duration(minutes: 15),
    bool Function()? keepWaiting,
  }) async {
    final device = BluetoothDevice.fromId(remoteId);
    try {
      // Arm under the op lock so it can't overlap a connect/disconnect.
      await _locked(() => device.connect(autoConnect: true, mtu: null));
    } catch (e) {
      _log('autoConnect arm failed: $e');
      return false;
    }
    _log('OS autoConnect armed for $remoteId — waiting (max '
        '${wait.inMinutes} min) for the band to reappear.');
    final done = Completer<bool>();
    final sub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected && !done.isCompleted) {
        done.complete(true);
      }
    });
    final poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (keepWaiting != null && !keepWaiting() && !done.isCompleted) {
        done.complete(false);
      }
    });
    final deadline = Timer(wait, () {
      if (!done.isCompleted) done.complete(false);
    });
    final ok = await done.future;
    await sub.cancel();
    poll.cancel();
    deadline.cancel();
    if (!ok) {
      // Cancel the pending autoConnect — an unsupervised OS connect later
      // (no subscriptions, no heartbeat) would just confuse the band.
      try {
        await _locked(() => device.disconnect());
      } catch (_) {}
      _log('OS autoConnect window ended without a link — cancelled.');
    } else {
      _log('OS autoConnect completed — running the normal setup path.');
    }
    return ok;
  }

  // Historical-offload bookkeeping. A controller is live for the whole connection
  // (we keep ACKing HISTORY_END markers as they arrive, even after the first
  // HISTORY_COMPLETE — a later strap-triggered offload reuses it).
  DrainController? _drain;
  bool _liveEnabled = false;
  // Background live downgrade: only the compact realtime-HR stream is armed
  // (no high-rate R10/R11 + IMU + optical flood). Set by [enableHrOnlyLive].
  bool _liveHrOnly = false;

  /// Whether any live stream is currently armed (full or HR-only). Lets a live
  /// consumer (spot check / step calibration) know if it must arm streams itself
  /// — and therefore whether IT owns turning them back off.
  bool get liveEnabled => _liveEnabled;

  /// True while live is in the background HR-only downgrade.
  bool get liveHrOnly => _liveEnabled && _liveHrOnly;
  bool _offloadActive = false;
  final List<Frame> _offloadFrames = [];
  bool _drainingOffloadFrames = false;
  int _historyRequests = 0;
  int _historyCompletions = 0;
  SyncReport? _lastSyncReport;
  int _successfulBursts = 0;
  _HpsTerminal? _lastHpsTerminal;
  _SessionPacketCounts _sessionPacketCounts = _SessionPacketCounts.zero;
  _SessionGapSummary _sessionGapSummary = _SessionGapSummary.zero;
  DateTime? _highFreqUntil;
  String? _highFreqReason;
  bool _highFreqModeRequested = false;
  final Map<int, int> _lastSequenceByRevision = <int, int>{};
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
  // Counts OUTRIGHT bond refusals across reconnects; after the threshold the
  // caller pauses the auto-reconnect loop instead of pinning the radio forever.
  // A single successful bond clears it (see the createBond block below).
  final BondRefusalGiveUp _bondGiveUp = BondRefusalGiveUp();
  // Real per-chunk failure tracking (see ChunkFailureLedger doc) — persists
  // across reconnects like marginal-radio/post-bond-loop/bond-give-up, since
  // the whole point is catching the SAME token failing across sessions.
  final ChunkFailureLedger _chunkFailures = ChunkFailureLedger();
  EmptySyncTracker _emptySync = EmptySyncTracker();
  StuckStrapDetector _stuckStrap = StuckStrapDetector();
  // Detector 1b: sustained frame corruption (CRC8/CRC32 failures) — an
  // independent failure axis from marginal-radio, which only ever sees
  // timeouts. Per-connection like empty-sync/stuck-strap: a new link starts
  // with fresh radio conditions.
  FrameCorruptionDetector _frameCorruption = FrameCorruptionDetector();
  int _crcFailuresTotal = 0; // across the engine's lifetime (diagnostics)
  int _crcFailuresThisSession = 0; // reset on each connect

  ClockRef? _clockRef; // strap-RTC ↔ wall correlation (set from GET_CLOCK)
  /// Latest strap-RTC ↔ wall correlation, or null until GET_CLOCK is answered.
  ClockRef? get clockRef => _clockRef;

  /// SET_CLOCK re-issue attempts THIS connection. setClock() reads the clock
  /// back, and the GET_CLOCK handler re-issues on drift — so cap the retries or
  /// a firmware that never latches either payload form would loop forever.
  int _clockCorrectTries = 0;
  // Proactive RTC recheck timestamp for long-lived connections — see
  // kRtcReverifyIntervalSeconds. Every other clock recheck is symptom-driven.
  DateTime? _lastClockVerifyAt;
  int? _sessionOldestUnix; // strap's banked-data window (GET_DATA_RANGE)
  int? _sessionNewestUnix;
  // Lifetime count of GET_DATA_RANGE reads rejected by isCorruptFutureRtc —
  // see the range_oldest/range_newest handler below.
  int _corruptDataRangeCount = 0;
  // Lifetime count of GET_CLOCK `clock_epoch` reads rejected by the same gate
  // (ClockPolicy.acceptsClockRead) — see the clock_epoch handler below.
  int _corruptClockReadCount = 0;
  DateTime? _bondTime; // when the handshake completed (bond confirmed)
  DateTime? _armTime; // when live (R10/R11) streams were last armed
  // Run-state for a chain of auto-continued offload rounds: how many
  // consecutive rounds banked nothing, and when the chain started.
  final AutoContinueRun _autoContinue = AutoContinueRun();
  double _lastBackfillAt = 0; // monotonic-ish secs of the last offload trigger
  double? _lastHistoricalSendAt; // last actual SEND_HISTORICAL_DATA wall time
  int _emptyStreak = 0; // consecutive empty offloads (BackfillPolicy backoff)
  // ONE shared per-record gate (plausibility + frontier + drop counter) used by
  // EVERY historical-record path — see RecordGate in ble_state.dart. Re-seeded
  // on each connect from the durable cursor.
  RecordGate _recordGate = RecordGate();
  // Explicit, observable "band reboot" signal (see CounterRegressionDetector
  // doc). Re-seeded from the durable counter_hw cursor on each connect, same
  // pattern as _recordGate's frontierTs seed below.
  CounterRegressionDetector _counterRegression = CounterRegressionDetector();
  // Firmware-aware R24 decoder (see openstrap_protocol's
  // FirmwareAwareR24Decoder doc): tries the original hardware-validated
  // decoder first, falls back to newer-firmware layouts only if that fails,
  // and remembers per-version which one actually worked so a long offload
  // doesn't re-probe every record. Reset alongside _recordGate/
  // _counterRegression on each (re)connect — a re-pair shouldn't carry a
  // stale detection from a different physical band.
  FirmwareAwareR24Decoder _firmwareDecoder = FirmwareAwareR24Decoder();
  // Snapshot of `_recordGate.dropped` at the last HISTORY_START — lets the
  // HISTORY_END validator (below) tell "the band sent fewer packets than it
  // said" apart from "we correctly, silently rejected some as implausible
  // (stale-clock block) and never tallied them." See _handleSyncMarker.
  int _burstDroppedAtStart = 0;
  // Band-truth reconciliation: `expectedPacketCount` mismatches are advisory
  // (see the comment at the validation site — treating a single mismatch as
  // fatal was actively harmful and was reverted), but a mismatch that keeps
  // recurring burst after burst is a real signal worth surfacing over time
  // rather than only as a single overwritten sync_ledger row. Pure
  // observability — does NOT gate or retry anything.
  int _burstMismatchTotal = 0; // across the engine's lifetime
  int _burstMismatchStreak = 0; // consecutive mismatched bursts, reset by connect + by a clean burst
  // Per-revision packet accounting for the historical drain (gap detection +
  // honest per-version counts surfaced to the debug screens).
  final Map<int, int> _historicalVersionCounts = <int, int>{};
  final Set<String> _historicalOpticalDebugKeys = <String>{};

  double _wallSecs() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  // A monotonic clock for measuring ELAPSED durations — never for wall-clock
  // comparisons. DateTime.now() (see _wallSecs above) can jump backward
  // mid-measurement (DST fall-back, a manual or NTP time correction), which
  // would silently disable a duration-based cap built on it (the
  // auto-continue run ceiling in particular). Started once and never reset;
  // callers diff two readings of it, same shape as _wallSecs so they compose
  // with existing double-seconds call sites like AutoContinueRun's.
  final Stopwatch _monotonic = Stopwatch()..start();
  double _monotonicSecs() => _monotonic.elapsedMicroseconds / 1e6;

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

  void _logHistoricalOptics(Uint8List inner, R24 r) {
    final version = r.histVersion;
    final count = (_historicalVersionCounts[version] ?? 0) + 1;
    _historicalVersionCounts[version] = count;

    // Keep the log small but deterministic: first three records of each version,
    // then version milestones that help confirm which path dominates the drain.
    final shouldLogMilestone =
        count <= 3 || count == 10 || count == 50 || count == 100;
    final key = 'v$version#$count';
    if (!shouldLogMilestone || !_historicalOpticalDebugKeys.add(key)) return;

    if (version == Record.r24 || version == Record.r12) {
      _log(
        '[SPO2] hist=v$version count=$count base=inner '
        'whoop4_optical(red@64 ir@66 temp@68 amb@70) '
        'ts=${r.tsEpoch} red=${r.spo2RedRaw} ir=${r.spo2IrRaw} '
        'temp=${r.skinTempRaw} amb=${r.ambientRaw} '
        'ppg_green=${r.ppgGreen} ppg_red_ir=${r.ppgRedIr}',
      );
      return;
    }

    if (version == 25) {
      final view = inner.buffer.asByteData(
        inner.offsetInBytes,
        inner.lengthInBytes,
      );
      final u16s = <int>[];
      for (int off = 23; off + 2 <= inner.length && off < 73; off += 2) {
        u16s.add(view.getUint16(off, Endian.little));
      }
      final first = u16s.take(8).toList();
      final min = u16s.isEmpty ? 0 : u16s.reduce((a, b) => a < b ? a : b);
      final max = u16s.isEmpty ? 0 : u16s.reduce((a, b) => a > b ? a : b);
      _log(
        '[SPO2] hist=v25 count=$count base=inner '
        'known(unix@7 gravity@69/71/73) '
        'unknown_optical_region=23..72 '
        'ts=${r.tsEpoch} g=${r.accelG.map((v) => v.toStringAsFixed(4)).join(",")} '
        'opt_u16_unique=${u16s.toSet().length} opt_u16_min=$min opt_u16_max=$max '
        'opt_u16_first8=$first',
      );
    }
  }

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
        dataStaleness: deriveDataStaleness(),
        isForeground: isForegroundActive(),
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
    // Connection-wide plausibility-gate rejections (RecordGate.dropped) — see
    // burstPacketCountMatches for why these must be added back to the burst
    // packet count before comparing against the band's expectedPacketCount.
    'gate_dropped_total': _recordGate.dropped,
    'gate_dropped_this_burst': _recordGate.dropped - _burstDroppedAtStart,
    // CRC8/CRC32 frame failures — previously silent (see `_subscribe`). A
    // rising count with a healthy `gate_dropped_*` is the signature of a
    // degrading radio corrupting frames rather than a stale/implausible band.
    'crc_failures_total': _crcFailuresTotal,
    'crc_failures_this_session': _crcFailuresThisSession,
    'frame_corruption_tripped': _frameCorruption.tripped,
    // Band-truth reconciliation: expectedPacketCount vs. what we actually
    // committed — advisory only (see the comment at the validation site), but
    // a *streak* of mismatches is a real signal worth watching over time.
    'burst_mismatch_total': _burstMismatchTotal,
    'burst_mismatch_streak': _burstMismatchStreak,
    // Band-reboot signal — see CounterRegressionDetector. Observability only;
    // recovery already happens automatically at the DB layer.
    'counter_regressions_total': _counterRegression.regressions,
    'corrupt_data_ranges_total': _corruptDataRangeCount,
    'corrupt_clock_reads_total': _corruptClockReadCount,
    // Bursts whose open chunk was discarded un-committed and whose HISTORY_END
    // token was therefore refused (see BurstTrimGuard).
    'poisoned_bursts_total': _drain?.poisonedBursts ?? 0,
    'history_requests': _historyRequests,
    'history_completions': _historyCompletions,
    'successful_bursts': _successfulBursts,
    'last_hps_terminal': _lastHpsTerminal?.kind.name,
    'last_hps_reason': _lastHpsTerminal?.reason,
    'last_hps_gap_summary': _lastHpsTerminal?.gapSummary,
    'session_packet_counts_by_revision':
        _sessionPacketCounts.dataPacketCountsByRevision,
    'session_revision16_count': _sessionPacketCounts.revision16Count,
    'session_console_count': _sessionPacketCounts.consoleLogPacketCount,
    'session_unknown_count': _sessionPacketCounts.unknownRevisionCount,
    'session_revision19_count': _sessionPacketCounts.revision19Count,
    'session_revision22_count': _sessionPacketCounts.revision22Count,
    'session_revision25_count': _sessionPacketCounts.revision25Count,
    'session_revision26_count': _sessionPacketCounts.revision26Count,
    'session_gap_summary': _sessionGapSummary.toString(),
    'last_progress_ms': _drain?.lastProgressMs,
    'last_report_records': _lastSyncReport?.records,
    'last_report_batches': _lastSyncReport?.batches,
    'last_report_complete': _lastSyncReport?.complete,
    'strap_history_oldest_ts': _strapHistoryOldestTs,
    'strap_history_newest_ts': _strapHistoryNewestTs,
    'high_freq_requested': _highFreqModeRequested,
    'high_freq_reason': _highFreqReason,
    'high_freq_until_ms': _highFreqUntil?.millisecondsSinceEpoch,
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
    // Advertise-filter on BOTH generations' service UUIDs (gen4 6108xxxx +
    // gen5 fd4bxxxx); the actual generation is pinned later at discovery.
    final gen4Svc = Guid(GattProfile.gen4.service);
    final gen5Svc = Guid(GattProfile.gen5.service);
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames = r.advertisementData.serviceUuids.map(
          (g) => g.str.toLowerCase(),
        );
        if (found == null &&
            (name.contains('whoop') ||
                advNames.any((s) =>
                    s.startsWith('61080001') || s.startsWith('fd4b0001')))) {
          found = r.device;
          FlutterBluePlus.stopScan();
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
          withServices: [gen4Svc, gen5Svc], timeout: timeout);
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
    // SINGLE-OWNER: a background drainer must not open a second drain against a
    // band the foreground session already owns (duplicate ACKs corrupt the trim
    // cursor). Foreground engines preempt instead — awaiting the preempted
    // engine's teardown so two FBP ops never overlap. See [_claimBand].
    if (!await _claimBand()) return false;
    // Any prior session is dead to us now — tear it down before a new one.
    await _teardownSession(intentional: true);
    try {
      return await _doConnect(device);
    } catch (e) {
      // _doConnect guards its own known failure modes, but anything thrown
      // OUTSIDE those guards (e.g. the connectionState subscription setup, which
      // runs before the first try block) used to escape with the band claim
      // still held and a half-built session left in `connecting` — which
      // [BandClaimPolicy] would then read as a LIVE incumbent, permanently
      // starving every later background drain. Route every escape through the
      // one failure exit.
      _log('connect failed (unhandled): $e');
      await _failConnect();
      return false;
    }
  });

  /// Common exit for every failed-connect path: tear the half-built session
  /// down, drop to `idle`, AND RELEASE THE BAND CLAIM.
  ///
  /// [_claimBand] runs BEFORE the link is up, so a connect that threw used to
  /// leave `_bandOwner` pointing at an engine with no link — and only
  /// `disconnect()` ever released it, which nothing calls on this path. Every
  /// later background drain then saw a non-null owner and yielded forever.
  Future<void> _failConnect() async {
    await _teardownSession(intentional: true);
    _releaseBand();
    _setPhase(BleConnState.idle);
  }

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
      await _failConnect();
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
          // A clean bond clears the refusal streak + any give-up latch, so a
          // later run of refusals can trip the pause again, and un-pauses the
          // auto-reconnect loop.
          _bondGiveUp.bondSucceeded();
          state.bondRefusals = 0;
          state.autoReconnectPaused = false;
        } catch (e) {
          // A failed bond is NOT benign: the strap gates every command behind
          // encryption, so downstream GATT ops will fail confusingly (writes
          // silently dropped, no INIT flood, "connected but nothing happens").
          // Log loudly and surface the re-pair diagnostic on engine state so
          // the UI can point the user at the fix instead of a dead session.
          _log('BOND FAILED: $e — encrypted commands will be silently dropped '
              'by the band. Remove the bond in system Bluetooth settings and '
              're-pair.');
          state.needsRepairGuide = true;
          state.bondRefusals++;
          // After a run of consecutive refusals, stop the auto-reconnect loop
          // (it would otherwise pin the radio + drain the battery on a band that
          // will never accept the bond) and surface the re-pair guide. A manual
          // user connect still runs createBond, so a successful re-pair recovers.
          if (_bondGiveUp.bondRefused()) {
            state.autoReconnectPaused = true;
            _log('[RECONNECT] bond-refusal give-up (${_bondGiveUp.consecutive}) '
                '— pausing auto-reconnect; re-pair required.');
          }
          onState(state);
        }
      }

      // Larger MTU + a fast connection interval for the drain (Android-only levers;
      // no-ops on iOS, which picks a fast interval itself when data is pending).
      try {
        final negotiated = await device.requestMtu(247);
        // Log the RESULT: a low MTU here (e.g. 23) is the tell for the 32B alarm
        // write failing, and was previously invisible (the call was swallowed).
        _log('MTU negotiated: $negotiated (requested 247).');
      } catch (e) {
        _log('requestMtu failed: $e — MTU stays at the connection default.');
      }
      if (Platform.isAndroid) {
        try {
          await device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high,
          );
        } catch (_) {}
      }

      if (!session.connected) {
        _log('connect: link dropped during setup.');
        await _failConnect();
        return false;
      }

      _setPhase(BleConnState.discovering);
      final services = await device
          .discoverServices()
          .timeout(_serviceDiscoveryTimeout);
      // Pin the generation from whichever service the peripheral exposes:
      // gen4 "Harvard" 6108xxxx, or gen5 "fd4b" fd4bxxxx. This drives the frame
      // header/CRC, command envelope, ACK, and record decode for the session.
      BluetoothService? svc;
      BandProfile band = BandProfile.gen4;
      for (final s in services) {
        final u = s.uuid.str.toLowerCase();
        if (u.startsWith(GattProfile.gen4.servicePrefix)) {
          svc = s;
          band = BandProfile.gen4;
          break;
        }
        if (u.startsWith(GattProfile.gen5.servicePrefix)) {
          svc = s;
          band = BandProfile.gen5;
          break;
        }
      }
      if (svc == null) {
        _log('No WHOOP service (gen4 6108xxxx / gen5 fd4bxxxx) found on device.');
        await _failConnect();
        return false;
      }
      session.applyBand(band);
      state.generation = band.isGen5 ? 'gen5' : 'gen4';
      _log('Detected ${band.isGen5 ? "WHOOP 5 (gen5)" : "WHOOP 4 (gen4)"} link.');
      final gatt = band.gatt;
      BluetoothCharacteristic? find(String prefix) {
        for (final c in svc!.characteristics) {
          if (c.uuid.str.toLowerCase().startsWith(prefix)) return c;
        }
        return null;
      }

      session.cmdTo = find(gatt.cmdTo.substring(0, 8));
      final cmdFrom = find(gatt.cmdFrom.substring(0, 8));
      final events = find(gatt.events.substring(0, 8));
      final data = find(gatt.data.substring(0, 8));
      if (session.cmdTo == null ||
          cmdFrom == null ||
          events == null ||
          data == null) {
        _log('Missing one or more ${band.isGen5 ? "fd4b" : "Harvard"} characteristics.');
        await _failConnect();
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
      _clockCorrectTries = 0; // fresh retry budget for this connection
      // Drop the previous session's clock correlation so an alarm armed before
      // THIS session's GET_CLOCK reply lands falls back to the raw wall epoch
      // (drift 0) instead of the stale strap-RTC frame. setClock()→getClock()
      // below repopulates it for this connection.
      _clockRef = null;
      await setClock();
      _lastClockVerifyAt = DateTime.now();
      // Per-connection policy reset. Marginal-radio + post-bond-loop are NOT reset
      // here — they count consecutive bad cycles across reconnects and self-reset on
      // a healthy disconnect. Empty-sync + stuck are per-connection.
      _emptySync = EmptySyncTracker();
      _stuckStrap = StuckStrapDetector();
      _frameCorruption = FrameCorruptionDetector();
      _crcFailuresThisSession = 0;
      _burstMismatchStreak = 0;
      _autoContinue.end();
      _lastBackfillAt = 0;
      _successfulBursts = 0;
      _lastHpsTerminal = null;
      _sessionPacketCounts = _SessionPacketCounts.zero;
      _sessionGapSummary = _SessionGapSummary.zero;
      _highFreqModeRequested = false;
      _highFreqReason = null;
      _highFreqUntil = null;
      _lastSequenceByRevision.clear();
      _historicalVersionCounts.clear();
      _historicalOpticalDebugKeys.clear();
      _sessionOldestUnix = null;
      _sessionNewestUnix = null;
      _bondTime = DateTime.now();
      // Fresh record gate, seeded from the durable high-water so the stuck/
      // continuation detectors are correct on the first offload after a restart.
      _recordGate =
          RecordGate(frontierTs: (await cursorReader?.call('rec_ts_hw')) ?? 0);
      // Re-seed the counter-regression watch from the durable counter_hw
      // cursor so a reboot is caught even across the reconnect it usually
      // causes, instead of only within a single unbroken connection.
      _counterRegression = CounterRegressionDetector(
        seedCounter: await cursorReader?.call('counter_hw'),
      );
      _firmwareDecoder = FirmwareAwareR24Decoder();

      // Heartbeat: keep the link alive (~10s LINK_VALID). Owned by the session, so a
      // disconnect cancels it — no zombie timer firing into a dead characteristic.
      session.heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!session.connected ||
            shouldPauseMaintenanceTraffic(offloadActive: _offloadActive)) {
          return;
        }
        _send(Cmd.linkValid, const [0x00]);
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
      _drain = DrainController(
        onRecord: _storeRecord,
        onRecordsBatch: onRecordsBatch == null ? null : _storeRecordsBatch,
        onCommit: onCommitBatch == null ? null : _commitBatch,
        onArchive: onArchiveRecord,
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
      await _failConnect();
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
    if (shouldPauseMaintenanceTraffic(offloadActive: _offloadActive)) {
      return;
    }
    // Proactive RTC recheck: every other clock verification is symptom-driven
    // (see kRtcReverifyIntervalSeconds doc). A long-lived link (e.g. iOS's
    // bluetooth-central background mode, which can stay open indefinitely)
    // gets an independent periodic GET_CLOCK; the existing clock_epoch
    // response handler does the actual drift comparison + bounded re-issue.
    final lastVerify = _lastClockVerifyAt;
    if (lastVerify == null ||
        DateTime.now().difference(lastVerify).inSeconds >=
            kRtcReverifyIntervalSeconds) {
      _lastClockVerifyAt = DateTime.now();
      _log('[SYNC] Periodic RTC re-verify (long-lived connection).');
      unawaited(getClock());
    }
    if (_liveEnabled) {
      // Re-arm ONLY what the current live mode wants: re-sending the high-rate
      // R10/R11 toggle while in HR-only mode (background downgrade) or under the
      // marginal-radio fallback would silently undo the downgrade every 30 s.
      if (!_liveHrOnly && !state.standardHrFallback) {
        _send(Cmd.sendR10R11Realtime, const [0x01]);
      }
      _send(Cmd.toggleRealtimeHr, const [0x01]);
    }
    _send(Cmd.getBatteryLevel, const []);
  }

  /// Trigger a historical offload, floored by [BackfillPolicy] (manual /
  /// autoContinue are never floored). Re-arms the drain so a fresh HISTORY_COMPLETE
  /// is awaited. Used by the periodic timer, continuation, and the public sync API.
  /// Returns true when an offload was actually requested (false → floored or not
  /// connected), so event-driven callers know whether to await a sync report.
  Future<bool> _triggerBackfill(BackfillTrigger trigger) async {
    final d = _drain;
    if (_session?.connected != true || d == null) return false;
    if (!BackfillPolicy.shouldRun(
      trigger,
      _wallSecs(),
      _lastBackfillAt,
      _emptyStreak,
    )) {
      return false;
    }
    _lastBackfillAt = _wallSecs();
    await _startHistoricalRefresh(
      trigger: trigger,
      reason: trigger.name,
      refreshRange: true,
    );
    return true;
  }

  /// Foreground catch-up pull: the app came back to the foreground on a healthy
  /// link and wants the flash backlog NOW instead of waiting out the 15-min
  /// periodic timer. Floored at [BackfillPolicy.eventFloorSeconds] (90 s) so
  /// rapid app switching can't hammer the strap. Returns true when an offload
  /// was actually requested.
  Future<bool> requestForegroundSync() =>
      _triggerBackfill(BackfillTrigger.foreground);

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
    if (_offloadActive && !d._complete) {
      _log(
        '[SYNC] refresh($reason) dropped — strap is already transmitting history.',
      );
      return;
    }
    d.rearm();
    _setOffloadActive(true);
    if (refreshRange) {
      _log('[SYNC] refresh($reason) — polling GET_DATA_RANGE before 0x16.');
      await _sendGetDataRange();
      // INIT spaces commands by ~120 ms; keep the same cadence here so the band
      // has time to emit the range response before we request another drain.
      await Future.delayed(const Duration(milliseconds: 120));
    }
    final wait = HistoricalSyncCommandPolicy.waitSeconds(
      _lastHistoricalSendAt,
      _wallSecs(),
    );
    if (wait > 0) {
      _log(
        '[SYNC] refresh($reason) — waiting ${wait.toStringAsFixed(2)}s '
        'for the 0x16 floor.',
      );
      await Future.delayed(Duration(milliseconds: (wait * 1000).ceil()));
      if (_session?.connected != true) return;
    }
    _log('[SYNC] refresh($reason) — sending SEND_HISTORICAL_DATA.');
    await _sendHistoricalData();
    _lastHistoricalSendAt = _wallSecs();
  }

  Future<void> _subscribe(
    _Session session,
    BluetoothCharacteristic c,
    String role,
  ) async {
    await c.setNotifyValue(true).timeout(_notifySetupTimeout);
    session.subs.add(
      c.onValueReceived.listen((chunk) {
        // Ignore notifications from a session we've already torn down.
        if (_session != session || !session.connected) return;
        _lastRx = DateTime.now();
        for (final frame in session.asm[role]!.feed(chunk)) {
          if (frame.valid) {
            _onFrame(role, frame, session);
          } else {
            // Previously silent: a degrading radio corrupting frames looked
            // identical to a healthy one everywhere. Now counted (surfaced in
            // offloadSnapshot) and fed to an independent corruption-rate
            // detector below, alongside RecordGate.dropped for plausibility
            // rejections.
            _crcFailuresTotal++;
            _crcFailuresThisSession++;
          }
          if (_frameCorruption.feed(frame.valid)) {
            state.standardHrFallback = true;
            onState(state);
            _log(
              '[RECONNECT] frame-corruption tripped '
              '($_crcFailuresThisSession CRC failures this session) — '
              'standard-HR fallback enabled.',
            );
          }
        }
      }),
    );
  }

  // ── link-down handling (drives reconnect via the caller's contract) ─────────────
  void _onLinkDown(_Session session) {
    if (LinkDownPolicy.evaluate(sessionIsCurrent: _session == session) ==
        LinkDownAction.ignoreStaleSession) {
      return; // a stale session's stream
    }
    final wasIntentional = session.intentionalClose;
    session.connected = false;
    // A drain in flight must complete (with linkDown) immediately, not run out
    // its full budget.
    if (_offloadActive) {
      _setHpsTerminal(_HpsTerminalKind.disconnected, drain: _drain);
    }
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
    // TEAR THE SESSION DOWN NOW. This used to happen ONLY on the next
    // connect()/disconnect() — which never comes when BondRefusalGiveUp pauses
    // auto-reconnect (`state.autoReconnectPaused`), so the dead session's five
    // timers (heartbeat 10 s, keep-alive 30 s, periodic backfill 900 s, idle
    // watchdog, historical retry) kept firing into a dead characteristic
    // forever and its four onValueReceived subscriptions stayed registered —
    // one more full set leaked on every drop. Deferred off this notification
    // callback (we are inside one of the very subscriptions being cancelled)
    // and non-intentional, so no redundant device.disconnect() is issued.
    unawaited(
      Future<void>(() async {
        if (_session != session) return; // a connect already replaced us
        await _teardownSession(intentional: false);
        // A claim held with no link is a stale claim (see [BandClaimPolicy]);
        // releasing it here is what stops a failed foreground link from
        // wedging every later background drain. The caller's reconnect loop
        // re-claims through connect(), where foreground still preempts.
        _releaseBand();
      }),
    );
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
  //
  // Returns whether the write actually succeeded (link ready + GATT write
  // confirmed within [_writeTimeout]). Most callers can ignore the result
  // (fire-and-forget telemetry polls), but the batch-ACK path MUST check it —
  // a swallowed ACK failure after the cursor commit means the band never trims
  // and silently re-floods the same chunk forever. The per-write timeout stops
  // a hung write-with-response from stalling the whole write chain / drain.
  static const Duration _writeTimeout = Duration(seconds: 8);
  // Every other step in the connect chain is timed (connect() itself: 20s,
  // ACK writes: 8s). discoverServices()/setNotifyValue() previously had none —
  // a wedged BLE stack here would hang connect() forever and never trip the
  // outer catch-all that tears the session down, silently jamming the whole
  // reconnect ladder above it (OS reconnect / restore-central / BG tasks never
  // get a chance to help because we never reach a failure state). Timing these
  // out lets the existing `catch (e)` in `_doConnect` do its job.
  static const Duration _serviceDiscoveryTimeout = Duration(seconds: 15);
  static const Duration _notifySetupTimeout = Duration(seconds: 15);

  /// [owner] pins the write to ONE session. Without it a write queued by a
  /// long-parked drain (a big commit, then up to ~25 s of ACK retries) lands on
  /// whatever session happens to be current when the write chain reaches it —
  /// i.e. an OLD connection's batch-ACK, with a re-used sync seq, written onto
  /// a BRAND NEW link. Every offload write passes its owning session.
  Future<bool> _write(Uint8List raw, {_Session? owner}) {
    final session = _session;
    final completer = Completer<bool>();
    _writeChain = _writeChain.then((_) async {
      var ok = false;
      try {
        final cmd = session?.cmdTo;
        if (session == null || !session.connected || cmd == null) {
          _log('write skipped: link not ready.');
          return;
        }
        if (owner != null && !identical(owner, session)) {
          _log('write skipped: it belongs to a session that is no longer live.');
          return;
        }
        // allowLongWrite: the rich SET_ALARM_TIME frame is 32B — the only write
        // that exceeds the 20B ATT limit of a default (23B) MTU. Without a long
        // write, flutter_blue_plus throws "value > mtu-3" if the negotiated MTU
        // never rose, and _send would swallow the alarm silently. Long writes are
        // a no-op for the small (<=20B) frames every other command uses.
        await cmd
            .write(raw, withoutResponse: false, allowLongWrite: true)
            .timeout(_writeTimeout);
        ok = true;
      } on TimeoutException {
        _log('write timeout: no GATT response in ${_writeTimeout.inSeconds}s.');
      } catch (e) {
        _log('write error: $e');
      } finally {
        completer.complete(ok);
      }
    });
    return completer.future;
  }

  /// Retry schedule for the HISTORY_END batch ACK (pure; see ble_state.dart).
  final AckRetryPolicy ackRetryPolicy = const AckRetryPolicy();

  /// VERIFIED batch-ACK write: retry a few times with short backoff. Returns
  /// false only after every attempt failed — the caller must then bounce the
  /// link (the chunk is already durably committed; the band re-delivers it next
  /// session and the decoded store dedups by REPLACE).
  Future<bool> _writeAckVerified(Uint8List ack, _Session session) async {
    var failures = 0;
    while (true) {
      if (_sessionIsStale(session)) return false;
      if (await _write(ack, owner: session)) return true;
      failures++;
      if (!ackRetryPolicy.shouldRetry(failures)) return false;
      _log('[SYNC] batch-ACK write failed (attempt $failures/'
          '${ackRetryPolicy.maxAttempts}) — retrying.');
      await Future.delayed(ackRetryPolicy.delayFor(failures));
      if (_sessionIsStale(session)) return false;
    }
  }

  Future<bool> _send(int opcode, List<int> payload) async {
    // `dangerousCmds` is this codebase's own gen4-curated hard-block list
    // (FORCE_TRIM/REBOOT/POWER_CYCLE/TOGGLE_PERSISTENT_R21/firmware-load).
    // `OpcodeSafety.destructive` is whoop-rs's independently-curated list of
    // opcodes with NO legitimate use anywhere in EITHER codebase (142-144
    // have no named meaning at all) — the two don't fully overlap, so both
    // apply. Deliberately NOT `OpcodeSafety.forbidden`: that broader list
    // also flags opcodes this app sends ON PURPOSE via named, reviewed call
    // sites (SET_ADVERTISING_NAME/SELECT_WRIST/SET_CONFIG for the R22
    // sequence/SET_CLOCK_MAVERICK) — see that class's own doc for why a
    // blanket block on `forbidden` would be wrong here.
    if (dangerousCmds.contains(opcode) || OpcodeSafety.isDestructive(opcode)) {
      _log('REFUSED dangerous opcode 0x${opcode.toRadixString(16)}');
      return false;
    }
    final frame = buildCommand(
        _seq.nextLive(), opcode, payload, _session?.band ?? BandProfile.gen4);
    final ok = await _write(frame);
    if (!ok) {
      _log('WRITE FAILED for opcode 0x${opcode.toRadixString(16)} — '
          'command not delivered.');
    }
    return ok;
  }

  // Offload commands whose PAYLOAD (not just the frame envelope) is
  // generation-specific: gen4 sends a single 0x00, gen5 sends an EMPTY payload.
  // Centralised so every offload trigger — the initial handshake, periodic
  // backfill, manual refresh, and retry — emits the correct gen5 format on a
  // gen5 link. (_send already frames with the session's BandProfile.)
  List<int> get _offloadPayload =>
      (_session?.band.isGen5 ?? false) ? const <int>[] : const <int>[0x00];
  Future<void> _sendGetDataRange() =>
      _send(Cmd.getDataRange, _offloadPayload);
  Future<void> _sendHistoricalData() =>
      _send(Cmd.sendHistoricalData, _offloadPayload);

  Future<void> applyHighFreqWakeWindow({
    required bool enabled,
    required DateTime? targetWake,
    Duration duration = const Duration(minutes: 90),
    int intervalSeconds = 60,
    String reason = 'wake_window',
  }) async {
    if (_session?.connected != true) return;
    if (!enabled || targetWake == null) {
      await _disableHighFreqSync(reason: '$reason:outside_window');
      return;
    }
    final unchanged =
        _highFreqModeRequested &&
        _highFreqReason == reason &&
        _highFreqUntil?.millisecondsSinceEpoch ==
            targetWake.millisecondsSinceEpoch;
    if (unchanged) return;
    _log(
      '[SYNC] HighFreq enter ($reason) — interval=${intervalSeconds}s '
      'duration=${duration.inSeconds}s until=${targetWake.toIso8601String()}',
    );
    await _write(
      cmdEnterHighFreqSync(
        _seq.nextLive(),
        intervalSeconds: intervalSeconds,
        durationSeconds: duration.inSeconds,
      ),
    );
    _highFreqModeRequested = true;
    _highFreqReason = reason;
    _highFreqUntil = targetWake;
  }

  Future<void> _disableHighFreqSync({required String reason}) async {
    if (_session?.connected != true || !_highFreqModeRequested) {
      _highFreqModeRequested = false;
      _highFreqReason = null;
      _highFreqUntil = null;
      return;
    }
    _log('[SYNC] HighFreq exit ($reason).');
    await _write(cmdExitHighFreqSync(_seq.nextLive()));
    _highFreqModeRequested = false;
    _highFreqReason = null;
    _highFreqUntil = null;
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

  /// Atomic commit of a sync chunk (raw + samples + undecodable archive + cursor)
  /// before the ACK. Archiving the undecodable records in this SAME transaction is
  /// what keeps the safe-trim invariant intact — nothing the band trims on ACK has
  /// been dropped; unknown-version records are set aside durably first.
  Future<void> _commitBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
    String? trimTokenHex, {
    List<ArchiveRecord>? archives,
  }) async {
    final hasArchives = archives != null && archives.isNotEmpty;
    if (raws.isEmpty && trimTokenHex == null && !hasArchives) return;
    await onCommitBatch!(raws, samples, trimTokenHex, archives: archives);
    if (raws.isNotEmpty || hasArchives) _noteStored();
  }

  // ── frame handling ─────────────────────────────────────────────────────────────
  void _onFrame(String role, Frame frame, _Session session) {
    final pt = frame.packetType;
    // Metadata ALWAYS takes the serialized queue, whatever characteristic it
    // was reassembled on. It used to take the queue only on the `data` role;
    // metadata off `cmd_from`/`events` was fired unawaited on the immediate
    // path — the one route that could run a HISTORY_END handler CONCURRENTLY
    // with the queued drain, i.e. two handlers on the same DrainController,
    // where one snapshots an empty buffer and writes its ACK before the
    // other's commit is durable. See [FrameRoutePolicy].
    final route = FrameRoutePolicy.route(
      isMetadata: pt == PacketType.metadata,
      isHistorical: pt == PacketType.historicalData,
      isDataRole: role == 'data',
    );
    if (route == FrameRoute.serializedQueue) {
      _enqueueOffloadFrame(frame, session);
      return;
    }
    _processImmediateFrame(frame);
  }

  void _processImmediateFrame(Frame frame) {
    final pt = frame.packetType;
    // NOTE: metadata never reaches here — [FrameRoutePolicy] routes every
    // metadata frame to the serialized offload queue regardless of role.
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
      // Historical data flowing while no offload is marked active is a terminal
      // worth recording (an unsolicited drain / lost START marker).
      if (!_offloadActive) {
        _setHpsTerminal(
          _HpsTerminalKind.metadataWhileNotSyncing,
          reason: 'historical_data_while_not_syncing',
        );
      }
      // Same shared path as the queued offload drain — plausibility gate,
      // frontier bump, drop counter and storage enqueue all live in ONE place
      // (see _ingestHistoricalFrame). This branch is only reached by a
      // historicalData frame arriving outside the 'data' role queue.
      _armIdleWatchdog(); // a record arrived → the strap is still draining
      _ingestHistoricalFrame(frame);
      return;
    }
    if (pt == PacketType.commandResponse) {
      _log(
        '[RESP] op=0x${frame.opcode.toRadixString(16)} '
        'inner=${_innerHex(frame.inner)}',
      );
    } else if (pt == PacketType.event) {
      if (_offloadActive) {
        _drain?.onBurstEvent();
      }
      _log('[EVENT] ${_innerHex(frame.inner)}');
      final e = parseEvent(frame.inner);
      if (e != null) {
        _handleEventInfo(e);
        onEvent?.call(e.eventId, e.tsEpoch, _innerHex(frame.inner));
      }
    } else if (pt == PacketType.consoleLogs && _offloadActive) {
      _drain?.onBurstConsole();
    }
    final band = _session?.band ?? BandProfile.gen4;
    final decoded = _maybeAugmentGen5ClockEpoch(
      frame,
      _maybeAugmentDataRange(frame, decodeFrame(frame, profile: band)),
    );
    // gen5-only, debug-visibility ONLY (never persisted, never gated on):
    // log the strap's own console text (now decoded by protocol's
    // `parseConsoleLog`, wired into `decodeFrame` above). Genuinely useful
    // for diagnosing the untested gen5 handshake/offload on real hardware.
    if (band.isGen5 && decoded.kind == 'console_log') {
      _log('[CONSOLE gen5] idx=${decoded.fields['record_index']} '
          'ts=${decoded.fields['ts_epoch']}: ${decoded.fields['text']}');
    }
    _absorbState(decoded);
  }

  void _enqueueOffloadFrame(Frame frame, _Session session) {
    if (_session != session || !session.connected) return; // stale session
    _offloadFrames.add(frame);
    if (_offloadActive || frame.packetType == PacketType.historicalData) {
      _setOffloadActive(true);
    }
    if (_drainingOffloadFrames) return;
    _drainingOffloadFrames = true;
    unawaited(_drainOffloadFrames(session));
  }

  /// The ONE serialized offload-frame processor. [session] is the connection
  /// that started this loop; it is re-checked around every await because a
  /// drain can be parked for a long time (a multi-second large-batch commit,
  /// then up to ~25 s of ACK retries) and `_teardownSession` clears
  /// `_drainingOffloadFrames` underneath it. Without the guard a SECOND
  /// drainer starts on the new session while this one is still alive — two
  /// loops on the same DrainController, so one commit() snapshots an empty
  /// buffer and its ACK can be written before the other's commit is durable —
  /// and this stale loop would go on to write the OLD connection's token onto
  /// the NEW link, tearing down a healthy session when that write failed.
  Future<void> _drainOffloadFrames(_Session session) async {
    // this used to have no try/finally, so if anything inside the loop threw
    // (a couple of the ledger writes in _handleSyncMarker weren't guarded),
    // _drainingOffloadFrames never got reset back to false and every future
    // _enqueueOffloadFrame call would just silently no-op forever - zero
    // sync progress until a full disconnect/reconnect.
    try {
      while (_offloadFrames.isNotEmpty) {
        if (_sessionIsStale(session)) return;
        final count = _offloadFrames.length > 64 ? 64 : _offloadFrames.length;
        final batch = _offloadFrames.sublist(0, count);
        _offloadFrames.removeRange(0, count);
        // Records are flowing → the strap is still draining. Armed per drained
        // batch (bounded rate) instead of per record — same watchdog semantics,
        // no Timer churn at flood rates. Markers re-arm it in _handleSyncMarker.
        _armIdleWatchdog();
        for (final frame in batch) {
          if (_sessionIsStale(session)) return;
          if (frame.packetType == PacketType.metadata) {
            await _handleSyncMarker(frame, session);
          } else {
            _ingestHistoricalFrame(frame);
          }
        }
        if (_offloadFrames.isNotEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      // Only the CURRENT session's loop may clear the flag. A stale loop
      // unwinding after the new session's drainer already started would
      // otherwise re-open the door to a second concurrent drainer.
      if (_session == session) _drainingOffloadFrames = false;
    }
  }

  /// True once [session] is no longer the engine's live session — the guard
  /// every long-parked offload callback shares.
  bool _sessionIsStale(_Session session) =>
      _session != session || !session.connected;

  /// THE single historical-record processing path — used by BOTH the queued
  /// offload drain (real traffic) and the immediate fallback. Decode → gate
  /// (plausibility + frontier via [RecordGate]) → storage enqueue. Keeping one
  /// path is deliberate: the previous duplicate had drifted, silently losing
  /// the plausibility gate and freezing the frontier the stuck-strap /
  /// auto-continue policies read.
  void _ingestHistoricalFrame(Frame frame) {
    final pt = frame.packetType;
    if (pt != PacketType.historicalData) return;
    final recType = frame.inner.length > 1 ? frame.inner[1] : -1;
    final counter = _counterFromInner(frame.inner);
    // Explicit, observable band-reboot signal — see CounterRegressionDetector.
    // 0 is _counterFromInner's fallback for a too-short frame, not a real
    // counter value, so it's excluded to avoid a false regression report.
    if (counter > 0 && _counterRegression.feed(counter)) {
      _log(
        '[SYNC] Record counter regressed (band likely rebooted): '
        'counter=$counter, regressions_total=${_counterRegression.regressions}. '
        'Recovery is automatic (REPLACE-by-rec_ts + orphan cascade) — this is '
        'observability only.',
      );
    }
    // Decode the record FIRST so we can stamp its REAL time onto rec_ts. The
    // DerivationEngine buckets/windows days by rec_ts, so a multi-day flash
    // backfill (all received in one sync) splits into correct per-real-day
    // buckets instead of collapsing into one "today".
    Sample? sample;
    final isGen5 = _session?.band.isGen5 ?? false;
    if (isGen5) {
      // gen5 (WHOOP 5): `parseGen5Historical` dispatches across all four real
      // gen5 historical-record kinds (v18 per-second summary, v20 optical/
      // v21 IMU/v26 PPG deep buffers — R22 opt-in only). Only v18 maps onto
      // the band-agnostic `Sample` type today; the deep buffers need their
      // own raw-buffer storage (a future db table), not a 1Hz Sample, so they
      // fall through to the undecodable archive below — that is honest
      // (correctly-identified-but-not-yet-stored), not a decode failure.
      sample = sampleFromGen5Historical(parseGen5Historical(frame.inner));
    } else if (recType == Record.r24 || recType == Record.r12) {
      // Legacy decoder first, firmware-fallback chain second, undecodable
      // archive last — see FirmwareAwareR24Decoder.
      var decodeTarget = frame.inner;
      if (recType == Record.r12 && decodeTarget.length == 88) {
        // v12 packets are 88 bytes, but parseR24 requires 89. Pad to 89 to hit the native version==12 layout.
        final padded = Uint8List(89);
        padded.setRange(0, 88, decodeTarget);
        decodeTarget = padded;
      }
      final r = _firmwareDecoder.decode(decodeTarget);
      if (r != null) {
        _logHistoricalOptics(frame.inner, r);
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
    // FIRMWARE RESILIENCE: a historical record we could NOT decode (unknown/
    // unsupported version, or a known version whose decode failed) is ARCHIVED
    // durably rather than dropped — it used to fall into raw_records with a null
    // rec_ts and get pruned unseen, losing a future firmware's data forever. The
    // archive rides the SAME commit that runs before the batch-ACK, so nothing the
    // band trims has been discarded (safe-trim invariant intact).
    if (sample == null) {
      final archive = ArchiveRecord(
        counter: counter,
        hex: _innerHex(frame.inner),
        packetType: frame.inner.isNotEmpty ? frame.inner[0] : 0,
        capturedAt: DateTime.now().millisecondsSinceEpoch,
        reason: 'undecodable_rec_v$recType',
      );
      final d = _drain;
      if (d != null) {
        d.onUndecodableRecord(archive);
      } else {
        unawaited(onArchiveRecord?.call(archive) ?? Future<void>.value());
      }
      return;
    }
    // PLAUSIBILITY GATE + FRONTIER (RecordGate, shared with the detectors).
    // Drop records whose unix is implausible vs wall-clock and (when known) the
    // strap's own GET_DATA_RANGE window — a previous owner's wandering-clock
    // pollution. Records with no decodable ts are kept (can't gate them).
    // Rejected records are neither stored nor counted; the ACK still walks the
    // band's cursor.
    // Past this point [sample] is non-null — undecodable records returned above.
    if (!_recordGate.admit(
      sample.tsEpoch,
      wallNow: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      sessionOldestUnix: _sessionOldestUnix,
      sessionNewestUnix: _sessionNewestUnix,
    )) {
      return;
    }
    final raw = RawRecord(
      counter: counter,
      packetType: pt,
      hex: _innerHex(frame.inner),
      capturedAt: DateTime.now().millisecondsSinceEpoch,
      recTs: sample.tsEpoch > 0 ? sample.tsEpoch : null,
    );
    // Hand the record to the offload controller (it buffers per-batch until the
    // HISTORY_END flush, which persists raw-first BEFORE we ACK). The controller
    // is armed for the whole connection, so this is always present; the fallback
    // just stores directly if a frame somehow arrives before setup completed.
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
    // GET_ALARM_TIME readback is PARKED: the response byte layout isn't confirmed
    // (the decode assumed a leading revision byte before the epoch that the band
    // doesn't send → it returned a plausible-but-wrong epoch, e.g. showing 21:49
    // for an alarm set to 11:14). The band has no independent alarm source — its
    // alarm is always exactly what the app last wrote (SET_ALARM is HW-verified) —
    // so the locally-set/persisted value in AppState is authoritative for display.
    // Do NOT clobber it with the unconfirmed readback. If the response format is
    // ever captured, decode it in parseCommandResponse and re-enable here.
    //
    // if (f.containsKey('alarm_epoch')) { ... }
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
      // SANITY GATE, mirroring the one `range_newest` gets below. An
      // implausibly far-future `clock_epoch` yields a large NEGATIVE driftSec,
      // and setAlarm arms at `when - driftSec` — years out, where the alarm
      // silently never fires — while the bounded SET_CLOCK retry budget is
      // spent chasing a value that was never real. Reject the read: with no
      // correlation the alarm falls back to the raw wall epoch. connect()
      // already issues an unconditional SET_CLOCK, and the periodic re-verify
      // re-reads, so a genuinely-wrong RTC still gets corrected.
      if (!ClockPolicy.acceptsClockRead(dev, wall)) {
        _corruptClockReadCount++;
        _log(
          '[SYNC] GET_CLOCK clock_epoch=$dev is implausibly far in the future '
          '— treating as a corrupt strap RTC read; NOT correlating the strap '
          'clock (alarms fall back to the raw wall epoch) '
          '(corrupt_clock_reads_total=$_corruptClockReadCount).',
        );
      } else {
        _clockRef = ClockRef(device: dev, wall: wall);
        _log('Clock correlated: device=$dev wall=$wall (drift=${wall - dev}s).');
        // Re-issue SET_CLOCK if the strap RTC has drifted > 1 day or is unset —
        // but BOUND the retries: setClock() reads the clock back, so an
        // unbounded re-issue on a firmware that never latches either payload
        // form would spin SET_CLOCK/GET_CLOCK forever. Historical records carry
        // their own embedded unix time regardless, so giving up after a few
        // tries is safe.
        if (ClockPolicy.shouldSetClock(dev, wall)) {
          if (_clockCorrectTries < 3) {
            _clockCorrectTries++;
            _log(
              'Clock drift over policy — re-issuing SET_CLOCK '
              '(attempt $_clockCorrectTries/3).',
            );
            unawaited(setClock());
          } else {
            _log(
              'Clock still off after 3 SET_CLOCK attempts — giving up; '
              'firmware may not accept our payload length.',
            );
          }
        } else {
          _clockCorrectTries = 0; // latched — reset for the next drift episode
        }
      }
    }
    if (f.containsKey('range_oldest') && f.containsKey('range_newest')) {
      final oldest = f['range_oldest'] as int;
      final newest = f['range_newest'] as int;
      // GET_DATA_RANGE responses are documented to occasionally carry junk at
      // unstable offsets. Nothing previously sanity-checked `range_newest`
      // before it tightened RecordGate's session window for the whole
      // connection — a corrupt "newest" implausibly far in the future would
      // silently poison that window. Reject and fall back to the broad
      // absolute floor/ceiling instead.
      if (isCorruptFutureRtc(newest, _wallSecs().round())) {
        _corruptDataRangeCount++;
        _log(
          '[SYNC] GET_DATA_RANGE newest=$newest is implausibly far in the '
          'future — treating as a corrupt strap RTC read; NOT tightening '
          'this session\'s plausibility window '
          '(corrupt_ranges_total=$_corruptDataRangeCount).',
        );
      } else {
        _sessionOldestUnix = oldest;
        _sessionNewestUnix = newest;
        state.dataRangeOldest = oldest;
        state.dataRangeNewest = newest;
        onState(state);
      }
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
    // gen5's GET_HELLO (opcode 145) response shape is unrelated to gen4's
    // HelloInfo — it carries a device_name + a gated fw_version instead
    // (parseCommandResponse's gen5 GET_HELLO branch). No confirmed serial/
    // battery/wrist-on offsets for it yet, so — unlike gen4's HELLO above —
    // this is diagnostics-only for now (confirms the untested gen5 handshake
    // actually got a byte-parseable reply) rather than wired into `state`.
    if (d.kind == 'cmd_response' && f.containsKey('device_name')) {
      _log('[HELLO gen5] device_name=${f['device_name']} '
          'fw_version=${f['fw_version']}');
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
          'mid-offload — aborting historical sync and scheduling a retry.',
        );
        _drain?.discardOpenChunk();
        unawaited(_abortAndRetryHistorical(reason: 'idle_watchdog'));
      },
    );
  }

  void _handleEventInfo(EventInfo event) {
    switch (event.eventId) {
      case EventId.highFreqSyncPrompt:
        _log(
          '[SYNC] HighFreq prompt received — scheduling a one-shot historical refresh.',
        );
        unawaited(
          _startHistoricalRefresh(
            trigger: BackfillTrigger.strap,
            reason: 'high_freq_prompt',
            refreshRange: true,
          ),
        );
        return;
      case EventId.highFreqSyncEnabled:
        _log('[SYNC] HighFreq sync enabled event received.');
        _highFreqModeRequested = true;
        return;
      case EventId.highFreqSyncDisabled:
        _log('[SYNC] HighFreq sync disabled event received.');
        _highFreqModeRequested = false;
        _highFreqReason = null;
        _highFreqUntil = null;
        return;
    }
  }

  Future<void> _abortAndRetryHistorical({required String reason}) async {
    final session = _session;
    if (session == null || !session.connected) return;
    session.idleWatchdog?.cancel();
    session.historicalRetry?.cancel();
    _setOffloadActive(false);
    _log('[SYNC] abort($reason) — sending ABORT_HISTORICAL.');
    await _send(Cmd.abortHistoricalTransmits, const [0x00]);
    session.historicalRetry = Timer(
      const Duration(seconds: kHistoricalAbortRetryDelaySeconds),
      () {
        if (_session != session || !session.connected) return;
        _log(
          '[SYNC] abort($reason) — retrying historical refresh after settle.',
        );
        unawaited(
          _startHistoricalRefresh(
            trigger: BackfillTrigger.strap,
            reason: 'abort_retry:$reason',
            refreshRange: true,
          ),
        );
      },
    );
  }

  /// Best-effort write for the sync_ledger diagnostics (sync-diagnostics
  /// screen) — never correctness-critical. These used to be plain unguarded
  /// awaits inside _handleSyncMarker, so a transient sqlite busy/locked
  /// error on one of them could abort mid-marker, skipping whatever
  /// actually-important step (the commit, the ACK, the link-bounce recovery)
  /// was still queued after it. A diagnostic write failing should never take
  /// the real sync logic down with it.
  Future<void> _bestEffortLedgerWrite(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      _log('[SYNC] ledger write failed (non-fatal, continuing): $e');
    }
  }

  /// Refuse to echo a HISTORY_END token, for one of the [TrimAckVerdict]
  /// blocked reasons. The band keeps the chunk and re-delivers it on the next
  /// offload; re-delivery is dedup-safe (decoded rows REPLACE by rec_ts, raw
  /// rows key on the record hex).
  Future<void> _refuseHistoryEndTrim(
    TrimAckVerdict verdict, {
    required DrainController d,
    required _Session session,
    required String tokenHex,
    required int? batchId,
  }) async {
    switch (verdict) {
      case TrimAckVerdict.send:
        return;
      case TrimAckVerdict.blockedStaleSession:
        // Deliberately no ledger write and no teardown: we may be mid-teardown
        // already, and every side effect here would land on a session that is
        // not ours.
        _log(
          '[SYNC] HISTORY_END token=$tokenHex belongs to a session that is no '
          'longer live — NOT ACKing. Writing it would put an old connection\'s '
          'token (with a re-used sync seq) onto the new link. The band '
          're-delivers this chunk next offload.',
        );
        return;
      case TrimAckVerdict.blockedDiscardedBurst:
        // The idle watchdog abandoned this burst's buffered records. Persist
        // anything that arrived since (dedup-safe) but WITHOUT the token, so
        // the trim cursor never claims a chunk we threw away.
        await d.commit(null);
        _log(
          '[SYNC] HISTORY_END token=$tokenHex terminates a DISCARDED burst '
          '(its open chunk was abandoned un-committed) — NOT ACKing, so the '
          'band cannot trim the records we dropped. It re-delivers them next '
          'offload.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'trim_refused',
          lastError: 'discarded_burst',
          metaPatch: {'batch_id': batchId, 'records': d.records},
        ));
        return;
      case TrimAckVerdict.blockedCommitFailed:
        // THE safe-trim invariant. The transaction rolled back, so the cursor
        // did not advance and the rows are not durable — commit() re-buffered
        // them rather than losing them. Never ACK here: that is exactly the
        // path where records existed nowhere, permanently and silently.
        _log(
          '[SYNC] DURABLE COMMIT FAILED for token=$tokenHex — NOT ACKing (the '
          'band must keep this chunk). Records were re-buffered; bouncing the '
          'link so the next session retries the commit from a clean batch.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'commit_failed',
          lastError: 'durable_commit_failed',
          metaPatch: {'batch_id': batchId, 'records': d.records},
        ));
        // Bounce rather than retry in place: a commit that failed on a large
        // batch (the observed production OOM inside commitSyncBatch) only gets
        // bigger if we keep appending to the same buffer. A reconnect drops
        // the buffer, and the band re-delivers from its un-advanced cursor.
        if (!_sessionIsStale(session)) {
          unawaited(
            _teardownSession(intentional: false).then((_) {
              _setPhase(BleConnState.idle); // caller's reconnect loop takes over
            }),
          );
        }
        return;
    }
  }

  Future<void> _handleSyncMarker(Frame frame, _Session session) async {
    if (_sessionIsStale(session)) return;
    final m = parseMetadata(frame.inner);
    if (m == null) return;
    _armIdleWatchdog();
    _log(
      '[SYNC] META sub=${m.sub} inner='
      '${frame.inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    if (m.sub == SyncMeta.historyStart) {
      final d = _drain;
      if (_offloadActive && d != null && d.bufferedRecords > 0) {
        _log(
          '[SYNC] HistoryStart received during active burst — discarding '
          'partial open chunk and restarting burst state.',
        );
        d.discardOpenChunk();
      }
      _session?.historicalRetry?.cancel();
      _burstDroppedAtStart = _recordGate.dropped;
      d?.rearm();
      _setOffloadActive(true);
      return;
    }
    if (m.sub == SyncMeta.historyEnd && m.token != null) {
      final d = _drain;
      if (d == null) return;
      final tokenHex = m.token!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (!_offloadActive) {
        _setHpsTerminal(
          _HpsTerminalKind.metadataWhileNotSyncing,
          reason: 'history_end_while_not_syncing',
          drain: d,
        );
      }
      // PRE-COMMIT GATE. Refuse the trim before anything else touches the link
      // or the durable cursor: a stale session must not be written to at all,
      // and a poisoned burst's records are already gone — there is nothing
      // this token may legitimately trim.
      final preVerdict = TrimAckPolicy.evaluate(
        sessionCurrent: !_sessionIsStale(session),
        burstDiscarded: d.burstDiscarded,
        commitDurable: true,
      );
      if (preVerdict != TrimAckVerdict.send) {
        await _refuseHistoryEndTrim(
          preVerdict,
          d: d,
          session: session,
          tokenHex: tokenHex,
          batchId: m.batchId,
        );
        return;
      }
      final expected = m.expectedPacketCount;
      // Records the plausibility gate silently rejected THIS burst (stale/
      // wandering-clock block — by design, "neither stored nor counted",
      // see RecordGate.admit) never reach onHistoricalRecord/
      // onUndecodableRecord, so they never entered currentBurstPacketCount.
      final droppedThisBurst = _recordGate.dropped - _burstDroppedAtStart;
      final validated = expected == null ||
          d.validateBurst(
            expectedPacketCount: expected,
            droppedThisBurst: droppedThisBurst,
          );
      // ADVISORY ONLY, never a gate: `expectedPacketCount`'s exact semantics
      // (which transport packet types the band itself counts — command
      // responses interleaved with the burst? retried/duplicate frames?) are
      // not fully reverse-engineered, and field data shows the gap between
      // expected and actual varies run to run with no fixed offset. What IS
      // fully verified is frame-level CRC32 (framing.dart) and the RecordGate
      // plausibility check — both already ran on every buffered record before
      // we ever get here. So a count mismatch is NOT evidence of corrupt or
      // missing data; treating it as fatal was actively harmful: on mismatch
      // the OLD behavior discarded the entire buffered chunk (throwing away
      // perfectly good, already-CRC-verified, already-gate-passed records),
      // told the band FAIL, and re-requested the same block — forever, since
      // nothing about a retry changes the count relationship. Zero sync
      // progress, "last data" frozen indefinitely. Log the mismatch (still
      // useful signal — see the sync-diagnostics screen) and commit anyway.
      if (!validated) {
        _burstMismatchTotal++;
        _burstMismatchStreak++;
        _log(
          '[SYNC] Burst packet-count mismatch (advisory, NOT blocking commit) '
          '(attempt ${d.consecutiveValidationFailures}, '
          'streak=$_burstMismatchStreak): expected=$expected, '
          'actual=${d.currentBurstPacketCount}, '
          'dropped_this_burst=$droppedThisBurst, '
          'historical=${d.currentBurstHistoricalPacketCount}, '
          'traffic=${d.currentBurstTrafficCount}, '
          'breakdown=${d.currentBurstBreakdown}',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          status: 'validated_with_mismatch',
          lastError: 'burst_packet_mismatch',
          metaPatch: {
            'expected_burst_packets': expected,
            'actual_burst_packets': d.currentBurstPacketCount,
            'dropped_this_burst': droppedThisBurst,
            'historical_burst_packets': d.currentBurstHistoricalPacketCount,
            'traffic_burst_packets': d.currentBurstTrafficCount,
            'burst_validation_failures': d.consecutiveValidationFailures,
            'burst_breakdown': d.currentBurstBreakdown,
          },
        ));
      } else {
        _burstMismatchStreak = 0;
      }
      _successfulBursts++;
      _mergeValidatedBurst(d);
      final r = d.bufferedRecTsRange;
      _log(
        '[SYNC] HistoryEnd batch=${m.batchId} records=${d.records} '
        'expected=${m.expectedPacketCount} actual=${d.currentBurstPacketCount} '
        'historical=${d.currentBurstHistoricalPacketCount} '
        'traffic=${d.currentBurstTrafficCount} token=$tokenHex '
        'recTs=${r == null ? "none" : "${r.$1}..${r.$2}"}',
      );
      // SAFE-TRIM INVARIANT: persist decoded+raw AND the continuation cursor
      // DURABLY (one transaction) BEFORE the ACK. The band trims its flash only
      // once the ACK is link-layer confirmed, so a crash before the ACK
      // re-delivers the chunk. Echo the 8-byte slice the band acks verbatim —
      // a mangled echo is the "Groundhog Day" re-flood bug.
      final durable = await d.commit(m.token); // raw+samples+cursor, atomic
      // RE-GATE after the await. commit() can take seconds on a large batch —
      // long enough for the link to die under us — and it now reports whether
      // the transaction actually became durable instead of swallowing the
      // exception. Either way the ACK is refused, which is the whole point:
      // the ACK is what makes the band trim its flash.
      final verdict = TrimAckPolicy.evaluate(
        sessionCurrent: !_sessionIsStale(session),
        burstDiscarded: d.burstDiscarded,
        commitDurable: durable,
      );
      if (verdict != TrimAckVerdict.send) {
        await _refuseHistoryEndTrim(
          verdict,
          d: d,
          session: session,
          tokenHex: tokenHex,
          batchId: m.batchId,
        );
        return;
      }
      final ack = buildHistoryResultOk(_seq.nextSync(), m.token!,
          profile: _session?.band ?? BandProfile.gen4);
      _log(
        '[SYNC] ACK frame='
        '${ack.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      );
      // VERIFIED ACK (retried). We only reach here when [TrimAckPolicy]
      // returned `send` — i.e. the commit above REPORTED durable (it no longer
      // swallows its exception) and the session is still ours — so the cursor
      // genuinely is committed. A silently-failed ACK write would leave the
      // band never trimming and re-flooding the same chunk forever. On
      // persistent failure bounce the link — the committed data is safe, and
      // the next session's re-delivery is dedup-safe (rows REPLACE by rec_ts).
      if (!await _writeAckVerified(ack, session)) {
        // Real per-chunk ledger row, keyed by the token itself — previously
        // every ledger write here collapsed onto one shared 'capture' row,
        // so a token that kept failing ACROSS reconnects (the "Groundhog
        // Day" re-flood signature) left no trace distinguishing it from a
        // one-off bounce. This does not change behavior — the bounce below
        // is unconditional either way, and the data is already safe (durably
        // committed above, before the ACK was ever attempted) — it only adds
        // visibility, plus an explicit quarantine escalation once the SAME
        // token has failed enough times to be a real, diagnosable problem.
        final failCount = _chunkFailures.recordFailure(tokenHex);
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'ack_failed',
          lastError: 'ack_write_exhausted',
          metaPatch: {
            'batch_id': m.batchId,
            'records': d.records,
            'ack_failures': failCount,
          },
        ));
        if (_chunkFailures.shouldQuarantine(tokenHex)) {
          await _bestEffortLedgerWrite(() => LocalDb.quarantineSyncChunk(
            kind: 'historical_batch',
            payloadJson: jsonEncode({
              'token': tokenHex,
              'batch_id': m.batchId,
              'ack_failures': failCount,
            }),
            reason: 'persistent_ack_failure',
          ));
          _log(
            '[SYNC] Batch token=$tokenHex has failed ACK $failCount times '
            'across reconnects — quarantined for diagnosis. Data is safe '
            '(already committed); this only means the band has not yet '
            'been told to trim, so it keeps re-sending the same batch.',
          );
        }
        _log('[SYNC] BATCH-ACK FAILED after '
            '${ackRetryPolicy.maxAttempts} attempts (token=$tokenHex, '
            'failures_for_this_token=$failCount) — bouncing the link; data '
            'is committed and the band will re-send.');
        // ONLY bounce a session that is still OURS. _writeAckVerified also
        // returns false when the session died under it, and tearing down then
        // would kill the healthy session that replaced it.
        if (!_sessionIsStale(session)) {
          unawaited(
            _teardownSession(intentional: false).then((_) {
              _setPhase(BleConnState.idle); // caller's reconnect loop takes over
            }),
          );
        }
        return;
      }
      _chunkFailures.recordSuccess(tokenHex);
      d.noteBatchAcked(); // ACKed and KEEP listening
      await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
        status: 'acknowledged',
        ackedAt: DateTime.now().millisecondsSinceEpoch,
        metaPatch: {
          'last_batch_token': tokenHex,
          'last_batch_id': m.batchId,
          'last_batch_records': d.records,
          'last_ack_batches': d.batches,
          'strap_history_oldest_ts': _strapHistoryOldestTs,
          'strap_history_newest_ts': _strapHistoryNewestTs,
          // Which WHOOP generation this batch came from — records/sessions
          // vary hugely in richness by generation (and, for gen5, by whether
          // the R22 deep-buffer opt-in was sent), so downstream diagnostics
          // need this without reaching into the transport layer.
          'band_generation': state.generation,
        },
      ));
      // Same event, but a REAL per-chunk row keyed by the token — closes out
      // whatever ack_failed history this token accumulated above.
      await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
        chunkId: 'batch:$tokenHex',
        kind: 'historical_batch',
        status: 'acked',
        ackedAt: DateTime.now().millisecondsSinceEpoch,
        metaPatch: {
          'batch_id': m.batchId,
          'records': d.records,
        },
      ));
      _noteStored(); // a banked batch → schedule a (debounced) derive
    } else if (m.sub == SyncMeta.historyComplete) {
      final d = _drain;
      if (d == null) return;
      if (!_offloadActive) {
        _setHpsTerminal(
          _HpsTerminalKind.metadataWhileNotSyncing,
          reason: 'history_complete_while_not_syncing',
          drain: d,
        );
      }
      // Backlog fully handed over (cursor is now at the live edge). Commit the tail
      // and KEEP LISTENING — live records continue on the same subscription. We do
      // NOT ACK a HISTORY_COMPLETE and we do NOT switch modes.
      final tailDurable = await d.commit(null); // tail — no new trim token
      if (_sessionIsStale(session)) return; // link died under the tail commit
      if (!tailDurable) {
        // No ACK is written for a HISTORY_COMPLETE, so nothing was trimmed and
        // no data is at risk — but the tail is NOT durable yet. commit() left
        // the records buffered, so the next commit (the next burst's
        // HISTORY_END, or the flush on teardown) re-attempts them.
        _log(
          '[SYNC] HistoryComplete tail commit FAILED — ${d.bufferedRecords} '
          'records stay buffered for the next commit. Nothing was trimmed '
          '(HISTORY_COMPLETE is never ACKed), so no data is at risk.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          status: 'tail_commit_failed',
          lastError: 'durable_commit_failed',
          metaPatch: {'records_seen': d.records},
        ));
      }
      d.onComplete();
      _historyCompletions++;
      _session?.idleWatchdog?.cancel();
      await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
        status: 'complete',
        metaPatch: {
          'history_complete_at': DateTime.now().millisecondsSinceEpoch,
          'records_seen': d.records,
          'batches_acked': d.batches,
          'history_requests': _historyRequests,
          'history_completions': _historyCompletions,
          'strap_history_oldest_ts': _strapHistoryOldestTs,
          'strap_history_newest_ts': _strapHistoryNewestTs,
          'band_generation': state.generation,
        },
      ));
      _log(
        '[SYNC] HistoryComplete — backlog drained (${d.records} records, '
        '${_recordGate.dropped} dropped). Still listening for live records.',
      );
      _setHpsTerminal(_HpsTerminalKind.success, drain: d);
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
    if (_stuckStrap.observe(
        _sessionNewestUnix, _recordGate.frontierTs, _wallSecs())) {
      state.strapNeedsReboot = true;
      onState(state);
      _log('[SYNC] stuck-strap tripped — defensive SET_CLOCK.');
      await setClock();
    }

    // Auto-continue: re-kick immediately (bypassing the 15-min floor) if the strap
    // still has real backlog and the cursor advanced — but cap per connection.
    // Read BEFORE resetOffloadCounters() wipes them.
    final productive = d.recordsThisOffload > 0 && d.lastTrimAdvanced;
    // Clear the streak BEFORE the gate: a capped streak must not block the
    // round that just proved there is more to fetch.
    _autoContinue.observe(productive: productive);
    final cont = BackfillContinuation.shouldAutoContinue(
      stillConnected: _session?.connected == true,
      strapNewestTs: _sessionNewestUnix,
      ourFrontierTs: _recordGate.frontierTs,
      rowsPersistedThisSession: d.recordsThisOffload,
      lastTrimAdvanced: d.lastTrimAdvanced,
      consecutiveUnproductiveCount: _autoContinue.unproductiveStreak,
      // Monotonic, not wall-clock: this ceiling must not un-arm itself if the
      // phone's clock steps backward mid-chain.
      elapsedSeconds: _autoContinue.elapsed(_monotonicSecs()),
    );
    d.resetOffloadCounters();
    if (cont) {
      _autoContinue.continued(productive: productive, now: _monotonicSecs());
      _log('[SYNC] auto-continue — more backlog remains '
          '(unproductive streak ${_autoContinue.unproductiveStreak}).');
      await _triggerBackfill(BackfillTrigger.autoContinue);
    } else {
      _autoContinue.end();
      // nothing left to continue - this offload cycle is genuinely done
      // either way (clean completion or not), so maintenance traffic
      // (heartbeat/keepalive/RTC re-verify/live re-arm/battery poll) can
      // resume. this used to only clear on the !complete sub-case below,
      // so an ordinary clean completion with no more backlog left
      // maintenance traffic silently paused for the rest of the connection.
      _setOffloadActive(false);
      if (!complete && _lastHpsTerminal == null) {
        _setHpsTerminal(_HpsTerminalKind.timeout, drain: d);
      }
    }
  }

  int _counterFromInner(Uint8List inner) =>
      inner.length >= 7 ? u32(inner, 3) : 0;
  String _innerHex(Uint8List inner) =>
      inner.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Send the gen5 "R22" 16-flag SET_CONFIG enable sequence
  /// (protocol's `buildR22EnableSequence`/`kGen5R22EnableFlags`), unlocking
  /// the v20 (optical)/v21 (IMU)/v26 (PPG) deep-buffer historical records.
  /// Sequential, ~40ms apart (same spacing discipline as the gen4 5-packet
  /// INIT) — the official WHOOP app never sends this, and neither does
  /// OpenStrap unless [gen5DeepBuffersEnabled] opts in (see the constructor
  /// doc). UNTESTED on physical hardware. No-op on a gen4 link.
  ///
  /// Written directly via [_write] (not [_send]) because the pre-built
  /// frames already carry their own sequence numbers — going through `_send`
  /// would double-allocate from [_seq] for no benefit. SET_FF_VALUE (120) is
  /// in `OpcodeSafety.forbidden` but NOT `OpcodeSafety.destructive`; per that
  /// class's own doc this deliberate, explicitly-opted-in sequence is exactly
  /// the kind of call site the broader `forbidden` list is not meant to gate
  /// (see `_send`'s doc for the full reasoning) — writing it directly here
  /// keeps that intentional exception in ONE place rather than needing an
  /// allowlist parameter threaded through the shared chokepoint.
  Future<void> enableGen5DeepBuffers() async {
    if (!(_session?.band.isGen5 ?? false)) return;
    final frames = buildR22EnableSequence(startSeq: _seq.nextLive());
    _log('Sending gen5 R22 deep-buffer enable sequence (${frames.length} '
        'flags)…');
    for (final frame in frames) {
      await _write(frame);
      await Future.delayed(const Duration(milliseconds: 40));
    }
    _log('gen5 R22 deep-buffer enable sequence sent.');
  }

  // ── high-level flows ─────────────────────────────────────────────────────────────
  Future<void> sendInit() async {
    final band = _session?.band ?? BandProfile.gen4;
    if (band.isGen5) {
      // gen5 handshake: a single CLIENT_HELLO (GET_HELLO 0x91) written
      // with-response opens the just-works bond, then the offload is driven by
      // GET_DATA_RANGE + SEND_HISTORICAL_DATA with EMPTY payloads (gen4 sends a
      // 0x00). The HISTORY_END ACK is byte-structured identically (handled in
      // the metadata path). NOTE: untested on physical hardware — pending a
      // WHOOP 5 device; the gen4 path above is unchanged.
      _log('Sending gen5 CLIENT_HELLO + offload…');
      await _write(gen5ClientHello());
      await Future.delayed(const Duration(milliseconds: 120));
      // Opt-in deep-buffer sequence, BEFORE the offload trigger (SET_CONFIG
      // flags must land before SEND_HISTORICAL_DATA to take effect for this
      // drain). Default OFF — see [gen5DeepBuffersEnabled].
      if (gen5DeepBuffersEnabled()) {
        await enableGen5DeepBuffers();
      }
      // Same band-aware helpers the refresh/backfill/retry paths use, so the
      // gen5 offload command format is identical everywhere.
      await _sendGetDataRange();
      await Future.delayed(const Duration(milliseconds: 120));
      await _sendHistoricalData();
      return;
    }
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

  /// Set the strap RTC to current time — hardware-verified payload.
  ///
  /// The strap expects an 8-byte payload of TWO little-endian u32s: whole
  /// seconds at [0:4] and SUB-SECONDS at [4:8], where subseconds are in units of
  /// 1/32768 s (a 32768 Hz RTC crystal): `subsec = (millis % 1000) * 32768 / 1000`
  /// (0..32767, a u16 in the low half of the second word). We previously sent
  /// zero subseconds, which the strap firmware rejected; sending the exact
  /// subsecond value is the safe thing. Then read the clock back (GET_CLOCK) so
  /// the response handler can VERIFY it latched and re-issue on drift.
  Future<void> setClock() async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final subsec = ((ms % 1000) * 32768) ~/ 1000; // 0..32767, 1/32768 s units
    final payload = <int>[
      sec & 0xff,
      (sec >> 8) & 0xff,
      (sec >> 16) & 0xff,
      (sec >> 24) & 0xff,
      subsec & 0xff,
      (subsec >> 8) & 0xff,
      0,
      0,
    ];
    // gen5 ("Maverick") uses a DIFFERENT opcode for SET_CLOCK than gen4 — the
    // 8-byte payload shape is unchanged, only the opcode value differs (see
    // Cmd.setClockMaverick's doc in protocol/constants.dart). Sending gen4's
    // opcode 0x0A to a gen5 strap here would silently fail to latch the RTC,
    // which then refuses to serve type-47 history — the exact symptom fixed.
    final isGen5 = _session?.band.isGen5 ?? false;
    final opcode = isGen5 ? Cmd.setClockMaverick : Cmd.setClock;
    await _send(opcode, payload);
    _log('SET_CLOCK${isGen5 ? " (gen5 Maverick)" : ""} → sec=$sec '
        'subsec=$subsec (WHOOP-exact 8B).');
    // Read the RTC back so the GET_CLOCK response handler can confirm it latched
    // (and re-issue SET_CLOCK if the strap clock is still off — see _onDecoded).
    await getClock();
  }

  /// Read the strap RTC. The response carries `clock_epoch`, handled where we
  /// verify drift and re-correlate the strap-RTC ↔ wall clock. gen5 uses its
  /// own GET_CLOCK opcode (147) — see [setClock].
  Future<void> getClock() => _send(
        (_session?.band.isGen5 ?? false) ? Cmd.getClockGen5 : Cmd.getClock,
        const <int>[],
      );

  /// On-device wake alarm (SET_ALARM_TIME = 0x42) — the RICH 20-byte form that
  /// actually FIRES on WHOOP 4.0:
  /// ```
  ///   [0]      0x04              rich-form marker
  ///   [1]      u8  index         alarm slot (default 0)
  ///   [2..6]   u32 epoch-sec LE  the wake time
  ///   [6..8]   u16 subsec  LE    (millis % 1000) * 32768 ~/ 1000 (1/32768 s units)
  ///   [8..20]  12-byte haptic pattern (see [AlarmPayloads.defaultHaptics])
  /// ```
  /// The short 7-byte time-only form ([setAlarmSimple]) is accepted and ACKed by
  /// the band but carries no waveform, so the strap never buzzes it — our earlier
  /// short-form attempts silently failed for exactly this reason. The strap
  /// confirms the alarm latched via event 56 (STRAP_DRIVEN_ALARM_SET) and reports
  /// firing via events 57/58 + 60. Byte layout lives in the pure [AlarmPayloads].
  /// Returns whether the arm write actually reached the band, so the caller can
  /// avoid persisting / confirming a phantom alarm on a failed write.
  Future<bool> setAlarm(
    DateTime when, {
    int index = 0,
    List<int>? haptics,
  }) async {
    // Arm in the STRAP's RTC frame. The strap fires the wake alarm autonomously
    // on its OWN clock, so if that clock is offset from wall time (SET_CLOCK not
    // latched / drift) the raw wall epoch fires at the wrong strap-time — or
    // never (a raw wall epoch is decades ahead of a strap clock still near its
    // factory epoch, which is exactly why an immediate RUN_ALARM buzz works but a
    // scheduled alarm never fires). Shift the target by the GET_CLOCK drift; fall
    // back to the raw epoch when we have no correlation yet (e.g. just after a
    // reconnect, before this session's GET_CLOCK reply). Byte layout + the frame
    // conversion both live in the pure [AlarmPayloads].
    final ref = _clockRef;
    final driftSec = ref?.driftSec ?? 0;
    final armWhen = AlarmPayloads.toStrapFrame(when, driftSec);
    final ok = await _send(
      Cmd.setAlarmTime,
      AlarmPayloads.rich(armWhen, index: index, haptics: haptics),
    );
    _log('SET_ALARM_TIME (rich 20B) → wallSec=${when.millisecondsSinceEpoch ~/ 1000} '
        'strapSec=${armWhen.millisecondsSinceEpoch ~/ 1000} drift=${driftSec}s '
        'correlated=${ref != null} subsec=${AlarmPayloads.subsecOf(armWhen)} '
        'write=${ok ? 'ok' : 'FAILED'}');
    return ok;
  }

  /// Time-only alarm (SET_ALARM_TIME = 0x42), SHORT 7-byte form:
  /// `[0x01][u32 epoch-sec LE][u16 subsec LE]`. Kept for diagnostics/parity —
  /// the band ACKs it but never fires it (no haptic waveform). Use [setAlarm].
  Future<void> setAlarmSimple(DateTime when) async {
    await _send(Cmd.setAlarmTime, AlarmPayloads.simple(when));
    _log('SET_ALARM_TIME (simple 7B) → sec=${when.millisecondsSinceEpoch ~/ 1000} '
        '(ACKs but will not fire)');
  }

  Future<void> getAlarm() => _send(Cmd.getAlarmTime, const [revision1]);

  /// Fire the alarm haptics IMMEDIATELY (RUN_ALARM = 0x44), payload `[0x01]`.
  /// A "test buzz" so the user can confirm the strap actually fires before
  /// trusting the scheduled wake.
  Future<void> runAlarm() => _send(Cmd.runAlarm, AlarmPayloads.runNow);

  /// Cancel the on-device alarm (DISABLE_ALARM = 0x45), payload `[0x01]`.
  /// (The earlier `[0x00]` body was ACKed but did not clear the alarm.)
  Future<void> disableAlarm() => _send(Cmd.disableAlarm, AlarmPayloads.disable);

  Future<void> getStrapName() =>
      _send(Cmd.getAdvertisingNameHarvard, const [0x00]);

  /// Rename the strap. Payload: [0x01][name length u8][ASCII name bytes][u32 0].
  Future<void> setStrapName(String name) async {
    // Cap at 20 ASCII chars (matches the reference + the GET decoder's length
    // assumption); the length byte then always stays < 0x20.
    final ascii = name.codeUnits
        .where((c) => c >= 0x20 && c < 0x7f)
        .take(20)
        .toList();
    final payload = <int>[0x01, ascii.length, ...ascii, 0, 0, 0, 0];
    await _send(Cmd.setAdvertisingNameHarvard, payload);
    _log('SET_ADVERTISING_NAME → "$name"');
  }

  Future<void> getBattery() => _send(Cmd.getBatteryLevel, const []);
  Future<void> getHello() => (_session?.band.isGen5 ?? false)
      ? _send(Cmd.getHello, const [0x01])
      : _send(Cmd.getHelloHarvard, const [0x00]);
  Future<void> buzz() => buzzPattern(hapticShortPulse);

  /// Play a haptic buzz. gen5 ("Maverick") has a DIFFERENT buzz opcode and
  /// payload shape than gen4 (`Cmd.runHapticPatternMaverick`, 12-byte body —
  /// see `cmdBuzzGen5Maverick` in protocol/commands.dart) — [pattern] is
  /// honoured only on gen4; a gen5 link always plays the strap's fixed
  /// `[47, 152]` waveform pair (the only Maverick buzz byte-verified so far).
  Future<void> buzzPattern(int pattern) {
    if (_session?.band.isGen5 ?? false) {
      return _send(
        Cmd.runHapticPatternMaverick,
        const [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 1],
      );
    }
    return _send(Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);
  }

  /// Signal strength of the live link, in dBm (negative; closer to zero is
  /// stronger). Null whenever there is nothing to measure.
  ///
  /// Used by the find-my-band hunt. Note what this does NOT do: it never
  /// scans. A hunt needs to BUZZ the band as well as track it, and buzzing
  /// requires the connection — so a band we cannot reach is one we could not
  /// help find anyway. Read straight off the connected device instead, which
  /// also means the hunt costs nothing beyond one small GATT read per poll:
  /// no radio mode change, no interference with an in-flight offload.
  ///
  /// Returns null rather than throwing on a mid-hunt disconnect; the caller
  /// polls on a timer and a dropped sample must not blow up the screen. The
  /// timeout matters because `readRssi` can hang on a link that is technically
  /// still "connected" but is not passing traffic.
  Future<int?> readRssi() async {
    final s = _session;
    if (s == null || !s.connected) return null;
    try {
      return await s.device.readRssi().timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  /// Enable live foreground streams (makes the band emit live R10/R11 + optical).
  /// Optical stays WRIST-GATED (0x6B only). This sends the toggle commands but
  /// DOES NOT change the displayed state — we stay in the single `listening` phase;
  /// live records simply start arriving on the same subscription history uses.
  Future<void> enableLiveStreams() async {
    _liveEnabled = true;
    _liveHrOnly = false;
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

  /// Clear the sticky standard-HR fallback and give the full live set another
  /// chance. The fallback protects a struggling radio from the high-rate
  /// flood, but it never resets and [enableLiveStreams] honours it silently —
  /// so once tripped, every later step calibration / workout counted 0 steps
  /// for the rest of the process lifetime (the IMU toggles were never sent).
  /// Call this from EXPLICIT foreground user actions whose feature needs the
  /// 100 Hz stream: there the flood is the point, and if the radio genuinely
  /// can't sustain it the detectors re-trip (and re-downgrade) within seconds.
  Future<void> retryFullLiveStreams() async {
    if (state.standardHrFallback) {
      _log('Radio fallback: cleared by explicit user action — retrying the '
          'full live set.');
      state.standardHrFallback = false;
      _marginalRadio.reset();
      _frameCorruption.reset();
      onState(state);
    }
    await enableLiveStreams();
  }

  /// Background live downgrade: keep ONLY the compact realtime-HR stream (0x28)
  /// armed and turn the high-rate R10/R11 + IMU + optical flood OFF. Used while
  /// backgrounded with no live consumer, so the radio isn't saturated by a raw
  /// flood nobody is reading — which can starve the periodic R24 offloads.
  /// [enableLiveStreams] restores the full set on foreground return. Idempotent.
  Future<void> enableHrOnlyLive() async {
    if (_session?.connected != true) return;
    _liveEnabled = true;
    _liveHrOnly = true;
    await _send(Cmd.toggleRealtimeHr, const [0x01]);
    final offOps = <List<dynamic>>[
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
    ];
    for (final op in offOps) {
      await _send(op[0] as int, (op[1] as List).cast<int>());
      await Future.delayed(const Duration(milliseconds: 60));
    }
    _log('Live streams: HR-only (background downgrade — raw flood off).');
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
    _liveHrOnly = false;
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
    if (_session?.connected == true && _highFreqModeRequested) {
      try {
        await _disableHighFreqSync(reason: 'intentional_disconnect');
      } catch (_) {}
    }
    await _teardownSession(intentional: true);
    // Release the single-owner claim ONLY on an intentional disconnect (not on a
    // link-down we intend to reconnect from) so the band is free for a background
    // drain once we've genuinely let go. If we were already preempted by another
    // engine, _releaseBand no-ops (it only clears when we still hold the claim).
    _releaseBand();
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
    // The strap-RTC↔wall correlation belongs to the session that measured it —
    // drop it so it can't leak into the next connection's alarm arming before a
    // fresh GET_CLOCK. (Connection setup also re-nulls it; this covers the gap
    // between teardown and the next connect.)
    _clockRef = null;
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

  void _setHpsTerminal(
    _HpsTerminalKind kind, {
    String? reason,
    DrainController? drain,
  }) {
    final d = drain ?? _drain;
    _lastHpsTerminal = _HpsTerminal(
      kind: kind,
      reason: reason,
      successfulBursts: _successfulBursts,
      records: d?.records ?? 0,
      batches: d?.batches ?? 0,
      gapSummary: d?.currentBurstBreakdown,
    );
  }

  void _mergeValidatedBurst(DrainController d) {
    final burstCounts = d.burstStats.dataPacketCountsByRevision;
    final mergedCounts = <int, int>{
      ..._sessionPacketCounts.dataPacketCountsByRevision,
    };
    for (final entry in burstCounts.entries) {
      mergedCounts[entry.key] = (mergedCounts[entry.key] ?? 0) + entry.value;
    }
    _sessionPacketCounts = _SessionPacketCounts(
      dataPacketCountsByRevision: mergedCounts,
      revision16Count:
          _sessionPacketCounts.revision16Count + d.burstStats.revision16Count,
      consoleLogPacketCount:
          _sessionPacketCounts.consoleLogPacketCount +
          d.burstStats.consoleCount,
      unknownRevisionCount:
          _sessionPacketCounts.unknownRevisionCount + d.burstStats.unknownCount,
      revision19Count:
          _sessionPacketCounts.revision19Count + d.burstStats.revision19Count,
      revision22Count:
          _sessionPacketCounts.revision22Count + d.burstStats.revision22Count,
      revision25Count:
          _sessionPacketCounts.revision25Count + d.burstStats.revision25Count,
      revision26Count:
          _sessionPacketCounts.revision26Count + d.burstStats.revision26Count,
    );

    var crossBurst = _sessionGapSummary.crossBurst;
    var missing = _sessionGapSummary.missing + d.burstStats.intraBurstMissing;
    var backward =
        _sessionGapSummary.backward + d.burstStats.intraBurstBackward;
    for (final entry in d.burstStats.sequenceByRevision.entries) {
      final rev = entry.key;
      final seq = entry.value;
      final last = _lastSequenceByRevision[rev];
      if (last != null) {
        if (seq.firstSequence > last + 1) {
          crossBurst++;
          missing += (seq.firstSequence - last) - 1;
        } else if (seq.firstSequence <= last) {
          backward++;
        }
      }
      final burstLast = seq.lastSequence;
      if (burstLast != null) {
        final prior = _lastSequenceByRevision[rev];
        if (prior == null || burstLast > prior) {
          _lastSequenceByRevision[rev] = burstLast;
        }
      }
    }
    _sessionGapSummary = _SessionGapSummary(
      intraBurst:
          _sessionGapSummary.intraBurst + d.burstStats.intraBurstGapCount,
      crossBurst: crossBurst,
      missing: missing,
      backward: backward,
    );
  }

  Decoded _maybeAugmentDataRange(Frame frame, Decoded decoded) {
    if (decoded.kind != 'cmd_response') return decoded;
    final opcode = decoded.fields['opcode'];
    if (opcode != Cmd.getDataRange) return decoded;
    final payload = frame.inner.length > 3
        ? Uint8List.sublistView(frame.inner, 3)
        : Uint8List(0);
    // We scan every byte offset for a plausible unix u32 (the field layout isn't
    // fully pinned), so the UPPER bound must be tight: a data-range timestamp can
    // never be in the FUTURE. The old ceiling (2100000000 ≈ year 2036) let a
    // spurious cross-field read land as "newest" — observed 2020230636 (year
    // 2034) — which made `history_newest` garbage, so backlogRemains was
    // PERMANENTLY true and the offload never recognized completion (it chased a
    // 2034 target forever). Cap at wall-clock + 1 day (clock skew slack).
    final maxPlausible =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 86400;
    final ts = <int>[];
    for (var off = 0; off + 4 <= payload.length; off++) {
      final v = u32(payload, off);
      if (v >= 1600000000 && v <= maxPlausible) {
        ts.add(v);
      }
    }
    if (ts.isEmpty) return decoded;
    final fields = <String, dynamic>{...decoded.fields};
    fields['history_oldest'] = ts.reduce((a, b) => a < b ? a : b);
    fields['history_newest'] = ts.reduce((a, b) => a > b ? a : b);
    return Decoded(decoded.kind, fields);
  }

  /// Patch up `COMMAND_RESPONSE` decodes for GET_CLOCK_GEN5 (147) — the one
  /// gen5-exclusive opcode `parseCommandResponse` doesn't populate a
  /// `clock_epoch` for yet (its GET_HELLO=145 and GET_BATTERY_LEVEL=26
  /// battery-scale handling are already profile-aware natively, via the
  /// `profile:` param passed into `decodeFrame` above). Without this, gen5's
  /// SET_CLOCK/GET_CLOCK drift-correlation (`ClockRef`, read in
  /// `_absorbState`) would never populate on a gen5 link, since
  /// `parseCommandResponse` only recognises gen4's `Cmd.getClock` (0x0B) for
  /// that field. Same "edge augments a decode protocol hasn't caught up to
  /// yet" pattern as [_maybeAugmentDataRange].
  Decoded _maybeAugmentGen5ClockEpoch(Frame frame, Decoded decoded) {
    if (decoded.kind != 'cmd_response') return decoded;
    if (decoded.fields['opcode'] != Cmd.getClockGen5) return decoded;
    final inner = frame.inner;
    final payload =
        inner.length > 3 ? Uint8List.sublistView(inner, 3) : Uint8List(0);
    final wallNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var o = 0; o + 4 <= payload.length; o++) {
      final v = u32(payload, o);
      if (isPlausibleUnix(v, wallNow)) {
        final fields = <String, dynamic>{...decoded.fields, 'clock_epoch': v};
        return Decoded(decoded.kind, fields);
      }
    }
    return decoded;
  }
}

/// Per-connection historical-offload helper. Buffers records per ACK boundary and
/// flushes them in one transaction (raw-first, BEFORE the HISTORY_END ACK). It is
/// armed for the whole connection (single listening mode). It tracks running counts
/// and exposes an
/// [awaitComplete] future that resolves when the band signals HISTORY_COMPLETE (or
/// the link drops / a safety timeout elapses), so a caller can block until the
/// backlog is fully handed over without disturbing the continuous listen.
///
/// ENGINE-INTERNAL. Public only so the safe-trim invariant it enforces (a
/// commit that fails must re-buffer and must NOT let the caller ACK) can be
/// regression-tested directly without a real band.
@visibleForTesting
class DrainController {
  final SampleSink onRecord;
  final BatchSink? onRecordsBatch;
  final CommitSyncBatchSink? onCommit;
  final ArchiveSink? onArchive;
  final void Function(String) log;

  DrainController({
    required this.onRecord,
    required this.onRecordsBatch,
    required this.onCommit,
    required this.onArchive,
    required this.log,
  });

  final List<RawRecord> _raws = [];
  final List<Sample?> _samples = [];
  // Undecodable historical records buffered for THIS chunk. Committed in the same
  // transaction as [_raws]/[_samples]/the trim cursor (see [commit]) so a future
  // firmware's records are durably set aside BEFORE the band is told to trim.
  final List<ArchiveRecord> _archives = [];
  // Per-burst packet accounting (per-revision counts + sequence gap detection),
  // merged into the session totals when a burst validates.
  final BurstStats burstStats = BurstStats();

  int records = 0; // total this connection
  int recordsThisOffload = 0; // since the last HISTORY_COMPLETE / rearm
  int batches = 0;
  DateTime _lastProgressAt = DateTime.now();
  bool _complete = false;
  bool _linkDown = false;

  int get bufferedRecords => _raws.length;
  int get lastProgressMs => _lastProgressAt.millisecondsSinceEpoch;

  /// Min/max real record time (rec_ts) currently buffered for this batch — lets
  /// us see whether the offload is serving a FROZEN/old timestamp block (the
  /// time-frontier can't advance) vs. genuinely newer records. Diagnostic.
  (int, int)? get bufferedRecTsRange {
    var lo = 0, hi = 0;
    var any = false;
    for (final rec in _raws) {
      final t = rec.recTs;
      if (t == null || t <= 0) continue;
      if (!any) {
        lo = t;
        hi = t;
        any = true;
      } else {
        if (t < lo) lo = t;
        if (t > hi) hi = t;
      }
    }
    return any ? (lo, hi) : null;
  }

  // Trim-advance tracking for the stuck/continuation detectors: a HISTORY_END
  // whose 8-byte token differs from the last one means the cursor moved.
  String? _lastAckedToken;
  bool lastTrimAdvanced = false;
  int consecutiveValidationFailures = 0;

  // Poison latch for the burst currently open (see BurstTrimGuard): once its
  // records have been discarded un-committed, its straggler HISTORY_END must
  // never be echoed.
  final BurstTrimGuard _trimGuard = BurstTrimGuard();

  /// True while the open burst's terminal may NOT be ACKed.
  bool get burstDiscarded => _trimGuard.discarded;

  /// Bursts poisoned this connection (diagnostics).
  int get poisonedBursts => _trimGuard.poisonedBursts;

  bool get _buffering => onCommit != null || onRecordsBatch != null;
  int get currentBurstPacketCount => burstStats.totalTrafficPacketCount;
  int get currentBurstTrafficCount => burstStats.totalTrafficPacketCount;
  int get currentBurstHistoricalPacketCount => burstStats.historicalPacketCount;
  String get currentBurstBreakdown => burstStats.breakdownString;

  void onHistoricalRecord(RawRecord raw, Sample? sample) {
    records++;
    recordsThisOffload++;
    _lastProgressAt = DateTime.now();
    burstStats.onHistoricalData(raw.packetType, raw.counter, sample, raw.hex);
    if (_buffering) {
      _raws.add(raw);
      _samples.add(sample);
    } else {
      unawaited(onRecord(sample, raw));
    }
  }

  /// An undecodable historical record (unknown/unsupported version, or a decode
  /// that failed). Buffered for archival in the next atomic commit — never dropped,
  /// never ACKed away before it is durably set aside.
  void onUndecodableRecord(ArchiveRecord a) {
    records++;
    recordsThisOffload++;
    _lastProgressAt = DateTime.now();
    if (_buffering) {
      _archives.add(a);
    } else {
      unawaited(onArchive?.call(a) ?? Future<void>.value());
    }
  }

  void noteBatchAcked() => batches++;

  void onBurstEvent() => burstStats.onEvent();

  void onBurstConsole() => burstStats.onConsole();

  void onBurstUnknown() => burstStats.onUnknown();

  /// [droppedThisBurst] = records the plausibility gate rejected during this
  /// same burst (stale/wandering-clock block) — never tallied into
  /// [currentBurstPacketCount] (they're never stored), but the band's own
  /// [expectedPacketCount] counts them anyway since it just counts what it
  /// physically transmitted. Add them back in before comparing, or a burst
  /// that legitimately contains even one gate-rejected record can never
  /// validate — discarding otherwise-good buffered records and looping
  /// forever on the same stuck block.
  bool validateBurst({
    required int expectedPacketCount,
    int droppedThisBurst = 0,
  }) {
    if (burstPacketCountMatches(
      expectedPacketCount: expectedPacketCount,
      actualBurstPacketCount: currentBurstPacketCount,
      droppedThisBurst: droppedThisBurst,
    )) {
      consecutiveValidationFailures = 0;
      return true;
    }
    consecutiveValidationFailures++;
    return false;
  }

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
    burstStats.reset();
    // A fresh burst starts un-poisoned: whatever was discarded belonged to the
    // burst that just ended, and the band will re-deliver it.
    _trimGuard.beginBurst();
  }

  void onLinkDown() => _linkDown = true;

  /// Per-offload counters reset (after the post-offload policy has read them).
  void resetOffloadCounters() => recordsThisOffload = 0;

  /// Abandon the buffered-but-not-yet-committed chunk WITHOUT persisting (idle
  /// watchdog). These records were never ACKed, so the band re-delivers them on the
  /// next offload — dropping them here just avoids ACKing a partial.
  ///
  /// POISONS THE OPEN BURST. Discarding alone was not enough: the band had
  /// already put that burst's HISTORY_END on the wire, and the terminal handler
  /// went on to commit the (now empty) buffer and echo the token verbatim —
  /// trimming exactly the records that were just dropped. The poison is
  /// unconditional (even with an empty buffer, this burst was abandoned) and
  /// is cleared only by [rearm] / a fresh HISTORY_START.
  void discardOpenChunk() {
    _trimGuard.discardOpenChunk();
    if (_raws.isEmpty && _archives.isEmpty) return;
    log('discarding ${_raws.length} un-ACKed buffered records + '
        '${_archives.length} archived (idle). This burst\'s HISTORY_END token '
        'is now un-ACKable — the band keeps the chunk.');
    _raws.clear();
    _samples.clear();
    _archives.clear();
  }

  /// SAFE-TRIM commit: persist the buffered chunk + the continuation [token]
  /// ATOMICALLY (via onCommit) and return only once durable — the caller writes
  /// the ACK afterwards. Snapshots the buffer so records arriving during the await
  /// land in the next commit. Updates [lastTrimAdvanced].
  ///
  /// RETURNS WHETHER THE CHUNK IS ACTUALLY DURABLE. This used to be
  /// `Future<void>` with the exception swallowed into a log line, while the
  /// buffer had ALREADY been snapshotted and cleared — so a failed transaction
  /// left the rows nowhere (buffer cleared, transaction rolled back, cursor
  /// unadvanced) and the caller went straight on to echo the HISTORY_END trim
  /// token, telling the band to delete them from its flash. Those records
  /// existed nowhere, permanently and silently. On failure the buffer is now
  /// RESTORED (at the front, so arrival order is preserved) and the trim
  /// bookkeeping rolled back, and the caller MUST NOT ACK — the band keeps the
  /// chunk and re-delivers it, which is dedup-safe (decoded rows REPLACE by
  /// rec_ts).
  Future<bool> commit(List<int>? token) async {
    final tokenHex = token
        ?.map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final previousAckedToken = _lastAckedToken;
    final previousTrimAdvanced = lastTrimAdvanced;
    lastTrimAdvanced = tokenHex != null && tokenHex != _lastAckedToken;
    if (tokenHex != null) _lastAckedToken = tokenHex;
    final raws = List<RawRecord>.from(_raws);
    final samples = List<Sample?>.from(_samples);
    final archives = List<ArchiveRecord>.from(_archives);
    _raws.clear();
    _samples.clear();
    _archives.clear();
    try {
      if (onCommit != null) {
        await onCommit!(raws, samples, tokenHex, archives: archives);
      } else if (onRecordsBatch != null && raws.isNotEmpty) {
        await onRecordsBatch!(raws, samples);
      }
      return true;
    } catch (e) {
      // Put the snapshot back at the FRONT: records that arrived during the
      // await are already appended behind it, so this preserves arrival order.
      _raws.insertAll(0, raws);
      _samples.insertAll(0, samples);
      _archives.insertAll(0, archives);
      // Roll back the trim bookkeeping too — nothing advanced.
      _lastAckedToken = previousAckedToken;
      lastTrimAdvanced = previousTrimAdvanced;
      log('offload commit FAILED ($e) — ${raws.length} records + '
          '${archives.length} archived re-buffered; the caller MUST NOT ACK '
          'this chunk (the band still holds it).');
      return false;
    }
  }

  Future<bool> flush() => commit(null);

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

@visibleForTesting
class BurstStats {
  static const Set<int> _ordinaryHistoricalRevisions = <int>{
    7,
    9,
    10,
    11,
    12,
    18,
    20,
    21,
    24,
  };

  final Map<int, int> _dataPacketCountsByRevision = <int, int>{};
  final Map<int, SequenceState> _sequenceByRevision = <int, SequenceState>{};
  int _eventCount = 0;
  int _consoleCount = 0;
  int _unknownCount = 0;
  int _revision16Count = 0;
  int _revision19Count = 0;
  int _revision22Count = 0;
  int _revision25Count = 0;
  int _revision26Count = 0;

  Map<int, int> get dataPacketCountsByRevision =>
      Map<int, int>.unmodifiable(_dataPacketCountsByRevision);
  Map<int, SequenceState> get sequenceByRevision =>
      Map<int, SequenceState>.unmodifiable(_sequenceByRevision);
  int get eventCount => _eventCount;
  int get consoleCount => _consoleCount;
  int get unknownCount => _unknownCount;
  int get revision16Count => _revision16Count;
  int get revision19Count => _revision19Count;
  int get revision22Count => _revision22Count;
  int get revision25Count => _revision25Count;
  int get revision26Count => _revision26Count;
  int get intraBurstGapCount =>
      _sequenceByRevision.values.fold<int>(0, (sum, s) => sum + s.gapCount);
  int get intraBurstMissing =>
      _sequenceByRevision.values.fold<int>(0, (sum, s) => sum + s.missingCount);
  int get intraBurstBackward => _sequenceByRevision.values.fold<int>(
    0,
    (sum, s) => sum + s.backwardCount,
  );

  int get historicalPacketCount => countHistoricalBurstPackets(
    dataPacketCountsByRevision: _dataPacketCountsByRevision,
    revision16Count: _revision16Count,
    revision19Count: _revision19Count,
    revision22Count: _revision22Count,
    revision25Count: _revision25Count,
    revision26Count: _revision26Count,
  );

  int get totalTrafficPacketCount => countBurstTrafficPackets(
    dataPacketCountsByRevision: _dataPacketCountsByRevision,
    revision16Count: _revision16Count,
    revision19Count: _revision19Count,
    revision22Count: _revision22Count,
    revision25Count: _revision25Count,
    revision26Count: _revision26Count,
    eventCount: _eventCount,
    consoleCount: _consoleCount,
    unknownCount: _unknownCount,
  );

  String get breakdownString {
    final parts = <String>[];
    final revs = _dataPacketCountsByRevision.keys.toList()..sort();
    for (final rev in revs) {
      parts.add('V$rev=${_dataPacketCountsByRevision[rev]}');
    }
    if (_revision16Count > 0) parts.add('V16=$_revision16Count');
    if (_revision19Count > 0) parts.add('V19=$_revision19Count');
    if (_revision22Count > 0) parts.add('V22=$_revision22Count');
    if (_revision25Count > 0) parts.add('V25=$_revision25Count');
    if (_revision26Count > 0) parts.add('V26=$_revision26Count');
    if (_eventCount > 0) parts.add('events=$_eventCount');
    if (_consoleCount > 0) parts.add('console=$_consoleCount');
    if (_unknownCount > 0) parts.add('unknown=$_unknownCount');
    final seq = sequenceSummary;
    if (seq.isNotEmpty) parts.add(seq);
    return '{${parts.join(', ')}}';
  }

  String get sequenceSummary {
    final revs = _sequenceByRevision.keys.toList()..sort();
    final parts = <String>[];
    for (final rev in revs) {
      final s = _sequenceByRevision[rev]!;
      if (s.gapCount > 0 || s.backwardCount > 0 || s.missingCount > 0) {
        parts.add(
          'seqV$rev(gaps=${s.gapCount}, missing=${s.missingCount}, backward=${s.backwardCount})',
        );
      }
    }
    return parts.join(', ');
  }

  void onHistoricalData(
    int packetType,
    int counter,
    Sample? sample,
    String rawHex,
  ) {
    if (packetType != PacketType.historicalData) return;
    final inner = hexToBytes(rawHex);
    if (inner.length < 2) {
      _unknownCount++;
      return;
    }
    final revision = inner[1];
    if (_ordinaryHistoricalRevisions.contains(revision)) {
      _dataPacketCountsByRevision[revision] =
          (_dataPacketCountsByRevision[revision] ?? 0) + 1;
      final seq = _sequenceByRevision.putIfAbsent(
        revision,
        () => SequenceState(firstSequence: counter),
      );
      seq.observe(counter);
      return;
    }
    switch (revision) {
      case 16:
        _revision16Count++;
        return;
      case 19:
        _revision19Count++;
        return;
      case 22:
        _revision22Count++;
        return;
      case 25:
        _revision25Count++;
        return;
      case 26:
        _revision26Count++;
        return;
      default:
        _unknownCount++;
        return;
    }
  }

  void onEvent() => _eventCount++;

  void onConsole() => _consoleCount++;

  void onUnknown() => _unknownCount++;

  void reset() {
    _dataPacketCountsByRevision.clear();
    _sequenceByRevision.clear();
    _eventCount = 0;
    _consoleCount = 0;
    _unknownCount = 0;
    _revision16Count = 0;
    _revision19Count = 0;
    _revision22Count = 0;
    _revision25Count = 0;
    _revision26Count = 0;
  }
}

@visibleForTesting
class SequenceState {
  SequenceState({required this.firstSequence});

  final int firstSequence;
  int? lastSequence;
  int gapCount = 0;
  int missingCount = 0;
  int backwardCount = 0;

  void observe(int seq) {
    final last = lastSequence;
    if (last != null) {
      if (seq > last + 1) {
        gapCount++;
        missingCount += (seq - last) - 1;
      } else if (seq <= last) {
        backwardCount++;
      }
    }
    if (last == null || seq > last) {
      lastSequence = seq;
    }
  }
}
