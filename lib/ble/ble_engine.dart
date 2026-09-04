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
import '../platform/tasker_bridge.dart';
import '../sync/paired_device.dart' show cleanDeviceLabel;
import '../sync/sync_policy.dart';
import 'adapters/_registry.dart';
import 'android_native_name.dart';
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
/// [deviceFamily] is which strap produced these rows (`'gen4'`/`'gen5'`, pinned
/// at service discovery) — stamped into the ledger at ingest, because this is
/// the only moment anyone knows it. Null when no link has identified itself.
typedef CommitSyncBatchSink =
    Future<void> Function(
      List<RawRecord> raws,
      List<Sample?> samples,
      String? trimTokenHex, {
      List<ArchiveRecord>? archives,
      String? deviceFamily,
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

// ── WHOOP 5.0 / MG discovery (not wire-format) ──────────────────────────────
// Transport/framing lives in package:openstrap_protocol (BandProfile / GattProfile).
// Edge only decides what to *look for*. The 128-bit vendor service is already
// on main; what is still unsettled on hardware is whether a real band puts it
// in the primary advertisement or only the scan response (#238 close note).
//
// A 128-bit UUID often does not fit the 31-byte AD. iOS hashes anything that
// spills into the scan-response overflow area, so AccessorySetupKit never sees
// it. The SIG member UUID 0xFD4B (2 bytes) and the advertised name
// (`WHOOP MGB…` / `WHOOP 5A…`) still fit. That 16-bit form is NOT the
// Bluetooth-base expansion `0000FD4B-0000-1000-8000-00805F9B34FB` — no band
// advertises that 128-bit value.

/// 16-bit Bluetooth SIG member UUID assigned to WHOOP. Distinct from
/// [GattProfile.gen5.service]. Platforms disagree on spelling: iOS reports
/// `"fd4b"`; Android reports the Base-UUID expansion.
const String kWhoopMemberUuid16 = 'fd4b';

/// Service UUIDs used as the BLE `withServices` scan filter.
///
/// `withServices` is OR-combined on both platforms. The 16-bit member UUID
/// must be its own entry: filtering only on the 128-bit vendor UUID misses a
/// band that advertised the 2-byte form.
List<Guid> whoopScanServiceUuids() => [
      Guid(GattProfile.gen4.service),
      Guid(GattProfile.gen5.service),
      Guid(kWhoopMemberUuid16),
    ];

/// True when a scan result is a WHOOP strap of either generation.
///
/// Matching is broad on purpose: a band whose 128-bit service UUID is hidden
/// in the scan-response overflow must still be caught by the 16-bit member
/// UUID or by its advertised name, or pairing never starts.
bool advertisementLooksLikeWhoop({
  required String platformName,
  required Iterable<String> serviceUuids,
}) {
  if (platformName.toLowerCase().contains('whoop')) return true;
  for (final raw in serviceUuids) {
    final u = raw.toLowerCase();
    if (u.startsWith(GattProfile.gen4.servicePrefix.toLowerCase())) return true;
    if (u.startsWith(GattProfile.gen5.servicePrefix.toLowerCase())) return true;
    if (u == kWhoopMemberUuid16 || u.startsWith('0000fd4b')) return true;
  }
  return false;
}


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
    // The band computes these itself, every second, whether or not a phone is
    // listening — unlike our own step estimate, which only runs during a live
    // session. gen4 carries none of them, so they stay null there rather than
    // being stored as a zero that reads like a real measurement.
    stepCount: g.stepMotionCounter,
    stepCadence: g.stepCadence,
    activityClass: g.activityClassKnown, // null for the unclassified code
    // -50.00 °C is the AS6221 unavailable/error SENTINEL, not a reading, so the
    // honest accessor abstains on it and the column stores NULL. Persisting the
    // sentinel verbatim would put a number 70 °C below any wrist into a
    // temperature column, where nothing downstream could tell it from data.
    skinTempC: g.skinTempCOrNull,
    // `onWrist` and `hrValid` are DELIBERATELY LEFT UNSET. v18 carries no
    // honest source for either, and both readings we once used are disproven
    // (see Gen5HistorySample's deprecation notices in protocol):
    //   • body 60 bits 0-1 (`onWristRaw`) are the primary-flags bit-8 snapshot,
    //     not wear. Wear truth comes from the HELLO body, the wrist on/off
    //     events, and the streams being wear-gated — none of it per-second.
    //   • body 15 bit7 (`hrRrValidThisSecond`) is not HR/RR validity: across
    //     1,587,671 retained records it toggles ~50/50 independently of HR
    //     presence, and 752,820 records carried a valid HR with the bit CLEAR.
    //     HR presence is `heartRate` in 25..230 — which the decoder already
    //     enforces on `hr`, and which every reader derives from `hr` itself;
    //     per-second signal quality is `signalQualityLogVariance`.
    // NULL here means "the band never told us", which is the truth. Setting
    // them from those bits is what turned a coin-flip into a confident wear /
    // validity answer downstream.
    hrAlt: g.heartRateAlt,
    // MT-12 — the record's second and third temperature channels, and the
    // band's own per-second signal-quality figure. Carried by CHANNEL INDEX,
    // never by a body part: protocol calls their semantics loose, and naming
    // one of them is exactly how gen4's `skinTempRaw` came to feed readiness
    // as a skin temperature. Measured on real records (docs/internal/GATES.md):
    // populated on 1,035/1,035, 27.0-33.2 °C, systematically 2-3 °C below
    // `skinTempC`. That is a measurement; no claim is made about what they are.
    // Nothing reads these — persisting claims nothing, which is the point.
    tempCh2C: g.tempAux1C,
    tempCh3C: g.tempAux2C,
    signalQualityLogVar: g.signalQualityLogVariance,
    // The band's own gravity-removed motion magnitude for this second (g).
    // Present on 1,035/1,035 real MG records and 3/3 WHOOP 5 (GATES.md §4b).
    // NOT our ENMO and never a substitute for it: the band's window, filter
    // and statistic are all unknown, so the two are on different scales.
    // Stored, unread — the point is to make the comparison possible later.
    dynAccelG: g.dynamicAccelerationG,
    // The record's own sub-second (1/32768 s), decoded on both generations
    // since forever and dropped here — see Sample.tsSubsec.
    tsSubsec: g.tsSubsec,
    // The band's OWN wake/sleep envelope, bits 4-5 of the same byte
    // `onWristRaw` above already comes out of — decoded, modelled, and the
    // only field in this mapper that was never carried. Raw code, not the
    // enum: a stored name freezes a meaning, a stored 2-bit code does not.
    // Corroboration only, never a stage — see Sample.bandSleepState.
    bandSleepState: g.sleepStateRawNibble,
  );
}

/// Decode a gen5 historical inner frame to a band-agnostic [Sample], or null.
@visibleForTesting
Sample? decodeGen5HistoricalSample(Uint8List inner) =>
    sampleFromGen5Historical(parseGen5Historical(inner));

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

/// Whether a NON-data frame is a burst count member: each complete type-48 event, type-50 console log and the
/// three battery-pack ("puffin") wrappers 53/54/55 counts exactly once toward
/// `HISTORY_END.expected_count`. Type 47 is counted on the data path instead
/// (it is what `dataPacketCountsByRevision` tallies); type 49 metadata NEVER
/// counts — it defines the burst boundaries; the 51/52 IMU streams are not
/// members of this count path at all.
@visibleForTesting
bool isBurstCountMemberType(int packetType) =>
    packetType == PacketType.event ||
    packetType == PacketType.consoleLogs ||
    packetType == PacketType.relativePuffinEvents ||
    packetType == PacketType.puffinEventsFromStrap ||
    packetType == PacketType.relativeBatteryPackConsoleLogs;

@visibleForTesting
bool shouldPauseMaintenanceTraffic({required bool offloadActive}) =>
    offloadActive;

/// Whether a HISTORY_END burst's packet accounting matches what the band
/// reported sending (`expectedPacketCount`, from the metadata frame).
///
/// [receivedTrafficCount] is every frame we received this burst, ALL types
/// ([BurstStats.totalTrafficPacketCount]) — the same all-types total
/// [burstPacketShortfall] compares against, and the exact same measurement:
/// this predicate is `shortfall <= 0`. Negative is NOT a mismatch: it just
/// means we tallied MORE frames than the band said it sent (retried/duplicate
/// frames), which [burstPacketShortfall]'s own doc calls "not loss" — it used
/// to trip the advisory mismatch counter and write the burst to the sync ledger
/// as `validated_with_mismatch` anyway. The doc here used to describe a
/// historical-only, post-RecordGate count that this function is never handed,
/// and that no longer exists as an input anywhere (the historical-only figure
/// survives separately as `currentBurstHistoricalPacketCount`, logged but not
/// compared).
///
/// [droppedThisBurst] (RecordGate.dropped delta across this burst) must be
/// added back in before comparing, or a burst containing even one
/// gate-rejected record can never validate — which discards its OTHER,
/// perfectly good buffered records and re-requests the same stuck block
/// forever (zero sync progress).
/// The pinned rule is ONE-SIDED with a failure-dependent slack, not equality
///:
///
/// ```text
///   slack = consecutiveFailedValidations >= 3 ? 2 : 0
///   pass  = expected - slack <= actual
/// ```
///
/// Two consequences worth stating, because equality got both wrong:
///   * SURPLUS PASSES. There is no upper bound. The strap re-offers an
///     unacknowledged burst and can re-deliver frames, so tallying MORE than
///     expected is normal and must not fail — under equality it did.
///   * The first three attempts demand every frame; from the fourth, up to two
///     missing are tolerated so a burst with a persistently unreadable frame
///     can still make progress instead of looping to the 15-attempt abort.
/// The pinned Sensor-HPS boundary: attempts 1..14 send a failure result and
/// wait for the strap to re-offer; the 15th is terminal and aborts instead of
/// sending a fifteenth failure. Bounding it is what stops a permanently-short burst becoming an
/// infinite re-request loop.
const int kBurstValidationAttemptLimit = 15;

/// How long a terminal `Stuck` keeps refusing drain work within one connection.
///
/// The latch exists to survive the band's re-offer storm: after an abort it
/// keeps re-offering the same HISTORY_END about every 2.5 s, and every re-offer
/// used to re-enter validation and abort again (14+ times in 12 s on a real
/// strap). This window has to outlast that storm AND the 60 s idle watchdog
/// that ends the offload.
///
/// It is deliberately NOT "the rest of the connection". Continuation after
/// `Stuck` comes from a later connection, a scheduler tick or an explicit
/// trigger; a session-scoped latch refuses the last two outright, which is
/// stricter than the behaviour it models. Three CRC-corrupt frames on a
/// marginal link must not cost every later drain on a connection that may stay
/// up for hours. Once the window passes a genuinely new trigger gets a fresh
/// validation cycle; the band still holds its checkpoint, so nothing already
/// committed is re-fetched.
const Duration kHistoryStuckCooldown = Duration(minutes: 2);

@visibleForTesting
int burstCountSlack(int consecutiveFailedValidations) =>
    consecutiveFailedValidations >= 3 ? 2 : 0;

@visibleForTesting
bool burstPacketCountMatches({
  required int expectedPacketCount,
  required int receivedTrafficCount,
  required int droppedThisBurst,
  int consecutiveFailedValidations = 0,
}) =>
    expectedPacketCount - burstCountSlack(consecutiveFailedValidations) <=
    receivedTrafficCount + droppedThisBurst;

/// Honest burst-completeness signal for TELEMETRY ONLY — this NEVER gates the
/// commit/ACK decision (see the log-only call site).
///
/// [receivedTrafficCount] is every frame we actually received this burst, ALL
/// types (historical R24 data + interleaved console/event/unknown) — i.e.
/// [BurstStats.totalTrafficPacketCount], NOT the banked historical subset. The
/// band's [expectedPacketCount] (num_packets) likewise counts every frame it
/// transmitted, so comparing the two all-types totals is type-agnostic and
/// interleaving-immune: benign console/event frames riding along cannot fake a
/// shortfall the way comparing against the R24-only subset did.
///
/// [droppedThisBurst] (RecordGate plausibility rejections this burst) is added
/// back because the band counted those frames but they never entered
/// [receivedTrafficCount]. A POSITIVE result is frames the band counted that we
/// did NOT count as valid received traffic — i.e. missing OR corrupted traffic
/// (would-flag / potential loss): CRC-failed frames also never enter
/// [receivedTrafficCount], so a positive shortfall cannot by itself prove a
/// frame never arrived. Zero is complete; negative just means we tallied more
/// than expected (retried/duplicate frames), which is not loss.
@visibleForTesting
int burstPacketShortfall({
  required int expectedPacketCount,
  required int receivedTrafficCount,
  int droppedThisBurst = 0,
}) =>
    expectedPacketCount - (receivedTrafficCount + droppedThisBurst);

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

  /// The 15th consecutive failed validation — doc 05's terminal `Stuck`.
  /// One abort, no fifteenth failure result, no same-session retry.
  stuck,

  /// A HISTORICAL_DATA_RESULT (positive or negative) could not be delivered.
  /// The burst window is already closed on the band side, so with no result on
  /// the wire the task cannot make progress — it ends through the one abort
  /// boundary ([BleEngine._endHistoryTaskWithAbort]).
  resultWriteFailed,
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
/// How one live-stream transition ended on the wire.
enum _LiveWrite { ok, failed, stale }

class _Session {
  final BluetoothDevice device;
  BluetoothCharacteristic? cmdTo;

  /// Set synchronously at the top of `_teardownSession`, before any await.
  /// The generation bump happens there too, but `_session` is nulled only
  /// after the subscription cancels have been awaited — so for that window
  /// the dying session is still the current one and still `connected`, and a
  /// live-stream pass that just discarded a stale completion would otherwise
  /// capture the NEW generation and write to the link being closed.
  bool closing = false;

  /// Which registered band this link speaks. Defaults to gen4 (WHOOP 4) and is
  /// pinned once during service discovery via [applyBand] — everything that
  /// differs by band (frame header/CRC, GATT UUIDs, command envelope, history
  /// ACK, record field offsets) reads from here.
  BandEntry entry = kWhoopGen4;

  /// This link's frame envelope profile. Owned by [entry]; kept as a getter
  /// because the wire format is `protocol`'s to define, not edge's.
  ///
  /// Non-null by construction: this engine only ever drives framed bands
  /// ([kFramedBands] is what the scan and the discovery match filter on), and
  /// [applyBand] asserts it at the one place an entry gets pinned.
  BandProfile get band => entry.wire!;

  final Map<String, FrameReassembler> asm = {
    'cmd_from': FrameReassembler(),
    'events': FrameReassembler(),
    'data': FrameReassembler(),
  };

  /// Pin this session's band and rebuild the reassemblers with the matching
  /// header shape. Called once, at discovery, before any frame is fed.
  void applyBand(BandEntry e) {
    final w = e.wire;
    // A notify-only sensor has no envelope to reassemble and no command
    // characteristic to write. It reaches the phone through `hrs_link.dart`,
    // never through this engine — see the registry header.
    assert(w != null, 'the offload engine only drives framed bands, not ${e.id}');
    entry = e;
    asm['cmd_from'] = FrameReassembler(profile: w!);
    asm['events'] = FrameReassembler(profile: w);
    asm['data'] = FrameReassembler(profile: w);
  }
  final List<StreamSubscription> subs = [];
  Timer? heartbeat;
  // Session-owned timers; a disconnect cancels them.
  Timer? keepAlive; // 30s: liveness watchdog + battery poll + realtime re-arm
  Timer? periodicBackfill; // 900s: re-trigger the historical offload
  Timer? idleWatchdog; // 60s: strap went silent mid-offload
  Timer? historicalRetry; // explicit abort→retry settle
  /// Abort→retry attempts THIS session. The cycle re-arms the 60 s idle
  /// watchdog, which can re-fire the abort, so without a cap a band that
  /// connects but never drains cycles at a fixed period for the life of the
  /// session — every other retry in this engine is bounded, this one was not.
  int historicalRetries = 0;
  // Starts false: we are NOT connected until connect() resolves / the OS
  // connectionState stream reports `connected`. (It was previously initialised
  // true, which combined with the stream replaying a spurious initial
  // `disconnected` aborted setup before the bond-triggering write.)
  bool connected = false;
  // True once we've actually observed a `connected` state. Used to ignore the
  // initial `disconnected` that flutter_blue_plus replays on listen.
  bool sawConnected = false;
  bool intentionalClose = false;
  /// Whether the doc-01 charging follow-up (GET_BATTERY_PACK_INFO) has already
  /// been launched for THIS session. Session-scoped so a second bootstrap on
  /// the same link cannot start a second retry loop against the same band.
  bool batteryPackFollowUpStarted = false;

  /// Terminal `Stuck` latch: set when a burst has
  /// failed validation [kBurstValidationAttemptLimit] times and the abort went
  /// out. From then on this session's history is OVER — no further drain
  /// trigger, and no re-validating a burst the band keeps re-offering.
  /// "Failed validation 15 → terminal Stuck, no same-session retry;
  /// continuation comes from a later connection or scheduler event." Being
  /// session-scoped is the whole mechanism: a reconnect builds a new [_Session]
  /// and the next connection drains normally from the band's checkpoint.
  bool historyStuck = false;

  /// When [historyStuck] latched. Drives [historyStuckActive].
  DateTime? historyStuckAt;

  /// Whether the latch is still refusing work.
  ///
  /// Read this, never [historyStuck] directly, on any path that decides whether
  /// to refuse a drain, drop a marker or suppress a terminal. [historyStuck]
  /// stays true as a session diagnostic ("this connection hit Stuck at least
  /// once") after the window has passed.
  bool get historyStuckActive {
    final at = historyStuckAt;
    if (!historyStuck || at == null) return false;
    return DateTime.now().difference(at) < kHistoryStuckCooldown;
  }

  /// Markers dropped, and drain triggers refused, by [historyStuck]
  /// (diagnostics). Each kind logs its FIRST occurrence and then stays silent:
  /// the band re-offers roughly every 2.5 s, and the whole point of the latch
  /// is to stop that from generating traffic and log noise.
  int stuckMarkersDropped = 0;
  int stuckRefreshesRefused = 0;

  /// The CURRENT history task ended through the abort boundary
  /// ([BleEngine._endHistoryTaskWithAbort]). While set, straggler markers and
  /// frames from that task are inert: they must not re-arm the idle watchdog,
  /// re-raise `_offloadActive` or trigger another abort — a duplicate
  /// HISTORY_END used to keep a wedged task alive indefinitely. Cleared when
  /// the next task is explicitly claimed ([BleEngine._startHistoricalRefresh]);
  /// unlike [historyStuck] it does NOT refuse that claim, so a later
  /// explicit/scheduled task starts cleanly.
  bool historyTaskEnded = false;

  /// Markers dropped by [historyTaskEnded] (diagnostics; first one logs).
  int endedMarkersDropped = 0;

  /// HISTORY_END markers dropped as doc-05 duplicates because they arrived
  /// before the current task's first HISTORY_START (diagnostics; first logs).
  int preStartHistoryEndsDropped = 0;

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

/// How [BleEngine._connectGen5Official] ended.
enum _Gen5ConnectOutcome {
  /// Bootstrap completed; the session is listening (READY).
  ready,

  /// Setup failed and the session was torn down.
  failed,

  /// Discovery contradicted the gen5 hint — the caller falls back to the
  /// legacy connect order for whatever the device actually is.
  notGen5,
}

/// One discovered band link: the registry entry the peripheral turned out to
/// be, plus the characteristics resolved off its service.
///
/// [BleEngine._discoverBand] returns null rather than a record whose entry is
/// missing a characteristic it declares required, so no caller re-checks that.
class _DiscoveredBand {
  final BandEntry entry;

  /// The four command/notify characteristics, resolved by 32-bit prefix.
  ///
  /// NULLABLE, and deliberately: WHICH of them a link must expose is registry
  /// data ([BandEntry.requiredCharacteristics]), and
  /// [BleEngine._discoverBand] has already refused any entry missing one it
  /// declares. A null here therefore means "this entry does not require it",
  /// which is the case the legacy route skips a subscription for — not an
  /// unchecked absence.
  final BluetoothCharacteristic? cmdTo;
  final BluetoothCharacteristic? cmdFrom;
  final BluetoothCharacteristic? events;
  final BluetoothCharacteristic? data;

  /// Memfault (0007). OPTIONAL in both directions: absent is normal, and it is
  /// a diagnostic/liveness input, never a readiness one. It is resolved HERE
  /// rather than only on the gen5 route because this is the one validation
  /// path — the two copies this replaced had already drifted over exactly
  /// this field.
  final BluetoothCharacteristic? memfault;

  const _DiscoveredBand({
    required this.entry,
    required this.cmdTo,
    required this.cmdFrom,
    required this.events,
    required this.data,
    required this.memfault,
  });
}

/// The platform seam for the official gen5 connect order: PHY preference,
/// discovery/validation, MTU intent, bond, notification registration.
///
/// One production implementation ([_FbpGattOps]) wraps flutter_blue_plus; the
/// sequence itself lives in [BleEngine._connectGen5Official], so injecting a
/// recorder here tests the REAL order rather than a parallel one.
abstract class GattBootstrapOps {
  /// Whether the explicit bond step applies. Android bonds explicitly; iOS
  /// bonds implicitly on the first encrypted operation, as in the legacy flow.
  bool get bondingApplies;

  /// Ask for LE 2M PHY. Throws when the request fails — logged, non-fatal.
  Future<void> preferLe2mPhy();

  /// Discover services, pin the session's band and stash the band's
  /// characteristics. Returns the discovered registry entry, or null when no
  /// known framed service — or a required characteristic — is present.
  Future<BandEntry?> discoverAndValidate();

  /// Request the ATT MTU; returns the negotiated value, throws on failure.
  Future<int> requestMtu(int mtu);

  /// Whether an OS bond already exists (skip creating another).
  Future<bool> isBonded();

  /// Create the OS bond and wait for it to complete; throws on refusal or
  /// failure.
  Future<void> createBond();

  /// Register one required notification ('cmd_from' | 'events' | 'data');
  /// throws when registration fails.
  Future<void> subscribe(String role);

  /// Register the OPTIONAL Memfault characteristic (0007) when present.
  /// Returns whether it was registered; absence or failure NEVER throws —
  /// Memfault is not a required characteristic and must not block READY.
  Future<bool> subscribeOptionalMemfault();
}

/// The flutter_blue_plus implementation of [GattBootstrapOps].
class _FbpGattOps implements GattBootstrapOps {
  final BleEngine _engine;
  final BluetoothDevice _device;
  final _Session _session;
  BluetoothCharacteristic? _cmdFrom, _events, _data, _memfault;

  _FbpGattOps(this._engine, this._device, this._session);

  @override
  bool get bondingApplies => Platform.isAndroid;

  @override
  Future<void> preferLe2mPhy() async {
    // "when Android supports it" — the request is Android-only
    // (flutter_blue_plus throws androidOnly elsewhere); iOS never asks.
    if (!Platform.isAndroid) return;
    await _device.setPreferredPhy(
      txPhy: Phy.le2m.mask,
      rxPhy: Phy.le2m.mask,
      option: PhyCoding.noPreferred,
    );
  }

  @override
  Future<BandEntry?> discoverAndValidate() async {
    final found = await _engine._discoverBand(_device);
    if (found == null) return null;
    _session.applyBand(found.entry);
    _session.cmdTo = found.cmdTo;
    _cmdFrom = found.cmdFrom;
    _events = found.events;
    _data = found.data;
    _memfault = found.memfault;
    return found.entry;
  }

  @override
  Future<int> requestMtu(int mtu) => _device.requestMtu(mtu);

  @override
  Future<bool> isBonded() async =>
      // `bondState` emits an initial value, but that first emission awaits the
      // platform's `getBondState` when nothing is cached, so this await can
      // hang. The BOUND lives at the call site in `_connectGen5Official` —
      // the seam, where a test can drive a read that never answers.
      await _device.bondState.first == BluetoothBondState.bonded;

  @override
  Future<void> createBond() => _device.createBond();

  @override
  Future<void> subscribe(String role) {
    final c = switch (role) {
      'cmd_from' => _cmdFrom,
      'events' => _events,
      _ => _data,
    };
    return _engine._subscribe(_session, c!, role);
  }

  @override
  Future<bool> subscribeOptionalMemfault() async {
    final c = _memfault;
    if (c == null) return false;
    try {
      await _engine._subscribeMemfault(_session, c);
      return true;
    } catch (e) {
      // Optional means optional: a CCC write failing on 0007 is logged by
      // the caller and never faults setup.
      return false;
    }
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

  /// The current live-stream owner set (#287). Read INSIDE the reconcile loop,
  /// never cached, so a nudge that was missed is healed by the next keep-alive
  /// tick rather than persisting until the next owner change. Null means no
  /// owners (a headless drainer).
  final LiveStreamOwners Function()? liveOwners;

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
  /// OFF — the sequence is
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
    this.liveOwners,
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

  /// The device family every row this link produces is stamped with — `'gen4'`
  /// or `'gen5'`, pinned once at service discovery. NULL until a link has
  /// actually identified itself, and NULL is not gen4: it means we do not know
  /// which sensor package measured the row, so a per-family metric must refuse
  /// rather than assume. Deliberately reads `state.generation` (set only after
  /// the service UUID matched) rather than `_session.band`, which DEFAULTS to
  /// gen4 before discovery has run.
  String? get linkDeviceFamily => state.generation;

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
  //
  // KEYED BY `remoteId`, because the hazard above is about ONE peripheral: two
  // engines connected to two DIFFERENT devices never share a trim cursor, and
  // a process-wide single owner made a second device's connect preempt the
  // primary's link on every connect.
  static final Map<String, BleEngine> _bandOwners = {};

  /// The peripheral this engine currently holds a claim on, if any. Kept
  /// because [_releaseBand] is called from paths with no device in scope, and
  /// it must release exactly the key it took.
  String? _claimedBandId;

  /// Claim exclusive ownership of the peripheral [remoteId] for this engine.
  /// Returns false only for a background drainer when another engine already
  /// owns THAT peripheral (→ it must NOT touch it this cycle); a claim on a
  /// different device does not block it. A foreground engine always succeeds
  /// and preempts any background owner of the same device by disconnecting it.
  ///
  /// SERIALIZED PREEMPTION: the preempted engine's teardown is AWAITED (bounded)
  /// before we proceed — firing our connect while its disconnect is still in
  /// flight gave flutter_blue_plus two overlapping ops on the same peripheral
  /// (connect racing disconnect → spurious connect failures / a half-torn-down
  /// GATT). A hung teardown can't wedge us forever: after the timeout we log and
  /// proceed (the preempted engine's own session guards make its late teardown
  /// harmless once we own the band).
  Future<bool> _claimBand(String remoteId) async {
    final other = _bandOwners[remoteId];
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
    // Moving to a different peripheral: let the old one go, or this engine
    // holds two keys and the stale one starves a later drain. ONLY NOW that the
    // new claim is granted — `connect()` calls this BEFORE `_teardownSession`,
    // so a `yieldToOwner` returns false with the previous session still live.
    // Releasing above the switch dropped that peripheral's key while this
    // engine still held its link, and the next engine to claim it opened a
    // second drain against a band we were still ACKing.
    if (_claimedBandId != null && _claimedBandId != remoteId) _releaseBand();
    _bandOwners[remoteId] = this;
    _claimedBandId = remoteId;
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

  /// Test-only view of the per-peripheral single-owner claim.
  @visibleForTesting
  static bool get bandClaimed => _bandOwners.isNotEmpty;

  /// Test-only reset of the claims (static state otherwise leaks across test
  /// cases).
  @visibleForTesting
  static void resetBandClaimForTest() => _bandOwners.clear();

  void _releaseBand() {
    final id = _claimedBandId;
    if (id == null) return;
    if (identical(_bandOwners[id], this)) _bandOwners.remove(id);
    _claimedBandId = null;
  }

  // ── transport state machine ─────────────────────────────────────────────────
  BleConnState _phase = BleConnState.idle;
  _Session? _session;

  // Single in-flight guard. Every connect/disconnect/reconnect serialises through
  // this so two attempts can never race on the same peripheral.
  Future<void> _opLock = Future.value();

  final SeqAllocator _seq = SeqAllocator();

  /// This engine's link is ONE peripheral's command characteristic, so one
  /// write is in flight at a time. Shared type with `GattBandLink`, which needs
  /// the identical guarantee for the identical reason (ASSUMPTIONS G5) — one
  /// chain each, never one between them.
  final WriteChain _writeChain = WriteChain();

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
  // Cancellation-poll cadence while parked in the OS-autoConnect wait. The
  // actual connect is fully OS-driven (the connectionState listener completes
  // the wait); this timer exists ONLY to notice `keepWaiting` flipping false,
  // so 60 s of latency on unpair/give-up is fine — at 5 s it was 12 needless
  // CPU wakes/min, around the clock, whenever the band was out of range.
  static const Duration _osAutoConnectPoll = Duration(seconds: 60);

  /// Consecutive autoConnect ARM failures (not connect timeouts — the arm
  /// itself throwing, e.g. adapter wedged). Drives the bounded backoff below;
  /// reset by a successful arm.
  int _autoConnectArmFailures = 0;

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
    // Adapter not on (Bluetooth toggled off, permission revoked): arming would
    // just throw, once per pass, all night. Park on the adapterState stream —
    // a native event — until it reports `on`, the caller stops wanting the
    // link, or the window ends, then hand back false so the caller's loop
    // re-enters and arms against a live adapter.
    try {
      final adapter = await FlutterBluePlus.adapterState.first
          .timeout(const Duration(seconds: 5));
      if (adapter != BluetoothAdapterState.on) {
        _log('OS autoConnect: adapter is ${adapter.name} — waiting for it to '
            'come back (event-driven, max ${wait.inMinutes} min) instead of '
            'arming a connect that cannot succeed.');
        await _waitForAdapterOn(wait: wait, keepWaiting: keepWaiting);
        return false;
      }
    } catch (_) {/* adapter state unavailable — fall through to the arm */}
    try {
      // Arm under the op lock so it can't overlap a connect/disconnect.
      await _locked(() => device.connect(autoConnect: true, mtu: null));
      _autoConnectArmFailures = 0;
    } catch (e) {
      // Bounded backoff before handing back the failure. The reconnect loop's
      // OS-pending branch has no backoff of its own (only the direct-connect
      // branch delays), so this delay is the only thing between the loop and
      // an all-night retry spin when the arm keeps failing for a reason the
      // adapter-state gate above didn't catch.
      _autoConnectArmFailures++;
      final delay = reconnectPolicy.delayFor(_autoConnectArmFailures);
      _log('autoConnect arm failed (attempt $_autoConnectArmFailures): $e — '
          'backing off ${delay.inSeconds}s.');
      await Future.delayed(delay);
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
    final poll = Timer.periodic(_osAutoConnectPoll, (_) {
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

  /// Park until the Bluetooth adapter reports `on`, the caller stops wanting
  /// the link ([keepWaiting] false, checked on the cancellation poll), or
  /// [wait] elapses. Event-driven off the native adapterState stream — zero
  /// per-attempt platform calls while the adapter stays off.
  Future<void> _waitForAdapterOn({
    required Duration wait,
    bool Function()? keepWaiting,
  }) async {
    final done = Completer<void>();
    final sub = FlutterBluePlus.adapterState.listen((s) {
      if (s == BluetoothAdapterState.on && !done.isCompleted) done.complete();
    });
    final poll = Timer.periodic(_osAutoConnectPoll, (_) {
      if (keepWaiting != null && !keepWaiting() && !done.isCompleted) {
        done.complete();
      }
    });
    final deadline = Timer(wait, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      await sub.cancel();
      poll.cancel();
      deadline.cancel();
    }
  }

  // Historical-offload bookkeeping. A controller is live for the whole connection
  // (we keep ACKing HISTORY_END markers as they arrive, even after the first
  // HISTORY_COMPLETE — a later strap-triggered offload reuses it).
  DrainController? _drain;

  // ── live HR / IMU ownership (#287) ──────────────────────────────────────────
  // Desired state comes from the app's owner set through [liveOwners] and is
  // recomputed inside the reconcile loop; applied state is what this LINK has
  // been told and acknowledged. They are deliberately separate: the old flags
  // flipped before the writes went out and doubled as both, which is how a
  // stale OFF could defeat a new owner. See `desiredLiveStreams` /
  // `nextLiveStreamStep` in ble_state.dart for the policy.
  LiveStreamIntent _liveApplied = LiveStreamIntent.off;

  /// The strap's high-rate bundle state is unknown on a fresh link. Consulted
  /// on gen4 only (R10/R11 OFF persists across reconnects there); reset by
  /// teardown.
  bool _imuFresh = true;

  /// A write for that bit failed or went stale, so the strap may be in either
  /// state; the policy replays the newest desired direction before it declares
  /// convergence. Reset by teardown.
  bool _imuDirty = false;
  bool _hrDirty = false;

  /// The in-flight reconcile pass. Shared so that `await reconcileLiveStreams()`
  /// is a real barrier for a caller that coalesced behind a running pass —
  /// `disconnect()` relies on that to know its OFF intent has been processed.
  Completer<void>? _liveRun;

  /// Owners changed (or a disconnect arrived) while a pass was in flight:
  /// recompute once more before the pass ends.
  bool _liveRestale = false;

  /// The keep-alive asked for the applied streams to be re-asserted on the
  /// next converged pass (the band's live toggles can silently die).
  bool _liveReassert = false;

  /// The link has finished its INIT sequence and may carry live toggles.
  /// `listening` is set BEFORE `_startInitDrain` sends the INIT packets (with
  /// delays, possibly behind a history-lifecycle wait), so the phase alone
  /// would let an owner nudge slip a live toggle in between them. Set at the
  /// end of `_finishConnect`; cleared on a new session and at teardown.
  bool _liveReady = false;

  /// `disconnect()` in progress: desired is forced to OFF for the whole of the
  /// shutdown reconcile AND the teardown, so nothing can re-arm the closing
  /// link. Cleared in a `finally`.
  bool _liveShutdown = false;

  /// Whether any live stream is currently applied on this link. Read by the
  /// resume-time staleness bar, the keep-alive's liveness poll and the
  /// marginal-radio detector.
  bool get liveEnabled => _liveApplied.any;

  /// What this link has been told and acknowledged. Tests only.
  @visibleForTesting
  LiveStreamIntent get debugLiveApplied => _liveApplied;

  /// What the current owners call for on this link. Tests only.
  @visibleForTesting
  LiveStreamIntent get debugLiveDesired => _desiredLive();

  // ── link power (issue #200) ─────────────────────────────────────────────────
  // Android's connection priority was requested ONCE at connect setup and never
  // stepped back down, so an ~11.25 ms interval was held for the entire life of
  // a deliberately-permanent connection. [desiredLinkPriority] decides what the
  // link should be running at; [_applyLinkPriority] is the one place that talks
  // to the radio, and it is a no-op when nothing changed.
  bool _backgrounded = false;
  LinkPriority? _appliedPriority;
  bool _priorityInFlight = false;
  bool _priorityRestale = false;

  /// Bumped by every teardown. Captured before a priority request and re-checked
  /// after it: `_teardownSession` clears `_appliedPriority` at its top but nulls
  /// `_session` only after awaiting subscription cancels, so an identity check
  /// on the session alone still passes inside that window — and the reply then
  /// restores the value teardown had just cleared, leaving the NEXT connection
  /// convinced it had already asked.
  int _linkGeneration = 0;

  /// True from the start of connect setup until INIT has been sent. Setup is
  /// discovery + subscribes + SET_CLOCK + INIT and is immediately followed by
  /// the first flash drain, so it wants the fast interval for the same reason
  /// an offload does — but it must ask for it through [_applyLinkPriority] like
  /// everything else, or the direct request races the serialized ones and
  /// leaves `_appliedPriority` describing a target the radio never got.
  bool _connectSetup = false;

  /// What the link should be running at given the engine's CURRENT state. The
  /// wiring under test: that `_connectSetup` counts as offload-grade traffic,
  /// and that `sendInit` clears it again.
  @visibleForTesting
  LinkPriority linkPriorityForCurrentState() => desiredLinkPriority(
        offloadActive: _offloadActive || _connectSetup,
        background: _backgrounded,
        hasLiveConsumer: _liveApplied.imu || _desiredLive().imu,
      );

  /// The last hop: the policy's [LinkPriority] as the radio's own enum.
  ///
  /// Lifted out of [_applyLinkPriority] because inline it was the one step
  /// nothing covered. `desiredLinkPriority` could keep returning exactly the
  /// right answer while every arm here mapped to `ConnectionPriority.high` —
  /// which IS issue #200, the link pinned at ~11.25 ms overnight — and the
  /// whole suite stayed green. Arm-by-arm coverage is in
  /// `link_priority_policy_test.dart`.
  @visibleForTesting
  static ConnectionPriority connectionPriorityFor(LinkPriority want) =>
      switch (want) {
        LinkPriority.high => ConnectionPriority.high,
        LinkPriority.balanced => ConnectionPriority.balanced,
        LinkPriority.lowPower => ConnectionPriority.lowPower,
      };

  @visibleForTesting
  void debugBeginConnectSetup() => _connectSetup = true;

  /// Feed a decoded control frame straight into the state absorber.
  ///
  /// The response-driven clock policy (trust verdict, bounded SET_CLOCK
  /// re-issue) lives on the far side of a real radio, so without this the only
  /// coverage possible was of the pure [ClockPolicy] predicates — never of the
  /// engine wiring that decides whether to act on them.
  @visibleForTesting
  void debugAbsorbDecoded(Decoded d) => _absorbState(d);

  /// Test seam: replaces the GATT write with [debugInstallFakeLink]'s callback.
  /// Null in production, where [_write] takes the real characteristic path.
  @visibleForTesting
  Future<bool> Function(Uint8List frame)? debugWriteHook;

  /// Stand up a connected-looking link with no radio behind it, so the flows
  /// that decide WHETHER to ask the strap for history — the clock gate, the
  /// backfill floor, the offload-active guard — can be driven end to end.
  ///
  /// Injecting `Decoded` values alone cannot cover these: it exercises the
  /// response handler while leaving `_readClock`, `_startHistoricalRefresh` and
  /// the INIT path unrun, which is exactly where the ordering bugs live.
  ///
  /// [onWrite] receives every outgoing frame and returns whether the write
  /// "succeeded", so a test can also assert the failed-write paths.
  ///
  /// [onCommit] wires the atomic safe-trim sink, which is what production
  /// always has — without it the HISTORY_END path refuses every ACK as
  /// non-trimmable, so the commit-before-ACK ordering and the result-write
  /// failure paths are unreachable.
  @visibleForTesting
  ///
  /// [listening] marks the link READY (the post-bootstrap `listening` phase);
  /// [liveReady] (defaults to [listening]) marks its INIT sequence finished,
  /// which is what the live-stream reconciler requires before it writes. The
  /// defaults leave both alone so bootstrap tests can drive them themselves.
  void debugInstallFakeLink({
    required Future<bool> Function(Uint8List frame) onWrite,
    BandProfile band = BandProfile.gen4,
    ArchiveSink? onArchive,
    CommitSyncBatchSink? onCommit,
    bool listening = false,
    bool? liveReady,
  }) {
    final session = _Session(
      BluetoothDevice(remoteId: const DeviceIdentifier('AA:BB:CC:DD:EE:FF')),
    );
    session.connected = true;
    session.sawConnected = true;
    session.applyBand(bandEntryFor(band));
    _session = session;
    if (listening) _phase = BleConnState.listening;
    _liveReady = liveReady ?? listening;
    debugWriteHook = onWrite;
    _drain = DrainController(
      onRecord: _storeRecord,
      onRecordsBatch: null,
      onCommit: onCommit,
      onArchive: onArchive,
      log: _log,
    );
  }

  /// Test seam onto the LOWEST-level write, so the dangerous-opcode block that
  /// lives there can be exercised on a pre-framed frame — which is exactly the
  /// shape the nine `_send`-bypassing call sites hand it.
  @visibleForTesting
  Future<bool> debugWriteRaw(Uint8List raw) => _write(raw);

  /// Commands currently waiting for a correlated response. Zero at
  /// rest; a wrong-opcode reply must leave the count unchanged.
  @visibleForTesting
  int get pendingCommandCount => _awaiter.pendingCount;

  /// Hello failures counted across reconnect attempts.
  @visibleForTesting
  int get helloFailureCount => _helloFailures;

  /// The identity verdict from the last successful hello.
  @visibleForTesting
  HelloIdentity? get helloIdentity => _helloIdentity;

  /// Drive the real gen5 hello exchange (write → correlated await → identity
  /// gate / failure counter). Everything it decides sits behind a radio
  /// otherwise, and it is the one path where a mis-correlated reply would be
  /// acted on as a real identity.
  @visibleForTesting
  Future<bool> debugReadGen5Hello() => _readGen5Hello();

  /// Drive the real doc-01 bootstrap that follows notification registration:
  /// the observed 500 ms delay, HELLO, the clock decision, the final
  /// advertising-name read and the charging follow-up.
  ///
  /// The ORDER of those steps, and which of them make a BLE write at all, is
  /// the whole contract of — and it lives behind a
  /// radio otherwise, because the only caller is the connect path.
  @visibleForTesting
  Future<bool> debugBootstrapAfterRegistration() {
    final session = _session;
    if (session == null) return Future.value(false);
    return _bootstrapAfterRegistration(session);
  }

  /// Observability seam onto [_applyLinkPriority]: called on EVERY entry,
  /// before the platform guard, so a test tracing the official gen5 sequence
  /// can prove no connection-priority request happens pre-READY.
  @visibleForTesting
  void Function()? debugOnPriorityRequest;

  /// Injectable Android native-name getter — the post-HELLO gate reads the
  /// platform `BluetoothDevice.getName()`, which only exists behind a radio;
  /// tests inject a fake so the gate itself is exercisable anywhere.
  /// Production leaves it null: the gate then applies exactly on Android and
  /// reads through the [AndroidNativeName] channel.
  @visibleForTesting
  Future<String?> Function(String remoteId)? debugNativeNameReader;

  bool get _nameGateApplies =>
      debugNativeNameReader != null || Platform.isAndroid;

  Future<String?> _nativeName(String remoteId) =>
      (debugNativeNameReader ?? AndroidNativeName.of)(remoteId);

  /// Drive the REAL official gen5 connect order (PHY → discovery → MTU →
  /// bond → 600 ms → registrations → post-registration bootstrap → READY +
  /// INIT) over an injected [GattBootstrapOps] on the fake link installed by
  /// [debugInstallFakeLink]. This is the production sequence, not a copy —
  /// the seam only replaces the radio.
  @visibleForTesting
  Future<bool> debugConnectGen5Official(GattBootstrapOps ops) async {
    final session = _session;
    if (session == null) return false;
    return await _connectGen5Official(session.device, session, ops: ops) ==
        _Gen5ConnectOutcome.ready;
  }

  /// Feed one inbound historical frame through the real ingest path (decode →
  /// plausibility gate → store or archive).
  ///
  /// The routing decisions this covers — which record versions decode, and
  /// what happens to a record the gate rejects — are the difference between
  /// banking a user's data and letting the band trim it away, and they sit
  /// behind a radio otherwise.
  @visibleForTesting
  void debugIngestHistoricalFrame(Frame frame) => _ingestHistoricalFrame(frame);

  /// Feed one inbound control frame through the real immediate-receive path
  /// (decode → event handling → state absorb).
  ///
  /// Type-48 events are telemetry the band volunteers — nothing here is ever
  /// requested — so this path is otherwise only reachable behind a radio.
  @visibleForTesting
  void debugProcessImmediateFrame(Frame frame) => _processImmediateFrame(frame);

  /// Feed one inbound frame through the REAL receive path, including
  /// [FrameRoutePolicy] and the serialized offload queue — i.e. the thing that
  /// decides which burst window a frame's count lands in.
  ///
  /// [debugProcessImmediateFrame] and [debugIngestHistoricalFrame] both start
  /// past that decision, so neither can express the one property that matters
  /// here: that a burst's data frames, its event/console members and its
  /// HISTORY_END are all handled in the order the band put them on the wire.
  /// [role] is the characteristic the frame was reassembled on ('data',
  /// 'events', 'cmd_from'), which is exactly what the ordering hazard is about.
  @visibleForTesting
  void debugReceiveFrame(Frame frame, {String role = 'data'}) {
    final session = _session;
    if (session == null) return;
    _onFrame(role, frame, session);
  }

  /// Drive the canonical historical-refresh path. Returns whether
  /// SEND_HISTORICAL_DATA actually went out.
  @visibleForTesting
  Future<bool> debugStartHistoricalRefresh({bool refreshRange = false}) =>
      _startHistoricalRefresh(
        trigger: BackfillTrigger.foreground,
        reason: 'test',
        refreshRange: refreshRange,
      );

  /// Age the clock-suspicion start past [ClockPolicy.suspectGraceSeconds].
  ///
  /// The grace window is 12 real hours off a monotonic stopwatch, so the only
  /// alternative to a seam here is not covering post-grace behaviour at all —
  /// and post-grace is precisely where history un-defers onto a strap RTC we
  /// have just concluded is the fast one.
  @visibleForTesting
  void debugExpireClockSuspicion() {
    if (_phoneClockSuspectSince == null) return;
    _phoneClockSuspectSince =
        _monotonicSecs() - ClockPolicy.suspectGraceSeconds - 1;
  }

  /// Told by AppState on every foreground/background transition. Drives the
  /// connection interval — see [desiredLinkPriority].
  void setBackground(bool value) {
    if (_backgrounded == value) return;
    _backgrounded = value;
    unawaited(_applyLinkPriority());
    // The debounced derive trigger's one-shot deadline was computed for the
    // OLD tier — a foreground flip must re-evaluate promptly (the user is
    // looking at the screen; the foreground tier fires within 15 s), not at a
    // background-tier deadline minutes away.
    if (_deriveTimer != null) {
      _deriveTimer!.cancel();
      _deriveTimer = null;
      _armDeriveTimer(const Duration(seconds: 1));
    }
  }

  /// Bring the link to the priority the current state calls for.
  ///
  /// SERIALIZED, and the target is recomputed inside the loop rather than at
  /// call time. Every caller fires this unawaited from a state transition
  /// (background, live mode, offload), so two can overlap; if they did, the
  /// slower one's completion would write ITS target into `_appliedPriority`
  /// last. The radio would then sit at one interval while the field claimed
  /// another, and the `want == _appliedPriority` check below — the thing that
  /// keeps this from spamming the radio — would skip the next legitimate
  /// step-down, leaving the link fast exactly when it should go quiet.
  Future<void> _applyLinkPriority() async {
    // Fires BEFORE the platform guard so a test can prove where priority
    // requests do and do not happen — the official gen5 sequence carries none
    // before READY (no requestConnectionPriority was
    // found in the official data path).
    debugOnPriorityRequest?.call();
    if (!Platform.isAndroid) return; // iOS picks its own interval
    if (_priorityInFlight) {
      // Someone is mid-request; make them re-evaluate when they land rather
      // than issuing a competing one.
      _priorityRestale = true;
      return;
    }
    _priorityInFlight = true;
    try {
      do {
        _priorityRestale = false;
        final session = _session;
        if (session == null || !session.connected) return;
        final want = desiredLinkPriority(
          offloadActive: _offloadActive || _connectSetup,
          background: _backgrounded,
          // Desired OR applied: the fast interval is requested before the
          // flood starts and held until the OFF has landed.
          hasLiveConsumer: _liveApplied.imu || _desiredLive().imu,
        );
        if (want == _appliedPriority) continue;
        final generation = _linkGeneration;
        try {
          await session.device.requestConnectionPriority(
            connectionPriorityRequest: connectionPriorityFor(want),
          );
          // Only remember it if the link we asked is still the live one. A
          // teardown during the await clears `_appliedPriority` precisely so
          // the next session re-requests from scratch (Android resets the
          // interval per GATT connection); writing this session's target in
          // afterwards would make the new link skip its own request.
          if (generation != _linkGeneration ||
              !identical(_session, session) ||
              !session.connected) {
            // Do not record it against the dead link, and do not swallow a
            // transition that arrived while we were waiting: loop once more so
            // the replacement session (if there is one) gets its own target.
            _log('Link priority reply arrived after teardown — discarded.');
            _priorityRestale = true;
            continue;
          }
          _appliedPriority = want;
          _log('Link priority → ${want.name}.');
        } catch (e) {
          // Leave `_appliedPriority` alone so this is retried. The retry is the
          // keep-alive tick calling back in, NOT this loop — spinning here
          // against a radio that just refused would hammer it. Without a
          // retry at all, a failed step-DOWN would hold the fast interval
          // until the next state change, which overnight means until morning.
          _log('requestConnectionPriority(${want.name}) failed: $e');
        }
      } while (_priorityRestale);
    } finally {
      _priorityInFlight = false;
    }
  }

  bool _offloadActive = false;
  // Each queued frame carries the history-task generation it arrived under, so
  // the serialized drainer can refuse to process an OLD task's leftovers as
  // part of its replacement (see [_drainOffloadFrames]).
  final List<({Frame frame, int taskGen})> _offloadFrames = [];
  bool _drainingOffloadFrames = false;

  /// The history-task generation: bumped when a task is claimed
  /// ([_startHistoricalRefresh], the INIT drain) and when one ends through the
  /// abort boundary ([_endHistoryTaskWithAbort]). Every asynchronous
  /// continuation that can mutate task state or write to the band captures it
  /// before its first await and re-checks after — a continuation whose
  /// generation is no longer current belongs to a task that is over, and it
  /// must neither ACK, abort, clear state nor consume the new task's frames.
  int _historyTaskGen = 0;

  /// The awaited opcode-20 write of the most recent task-ending abort, while
  /// it is still in flight. Every task start waits this out (see
  /// [_startHistoricalRefresh]) so a replacement task cannot put
  /// GET_DATA_RANGE/opcode 22 on the wire under a band that is still being
  /// told to abandon the previous one. Deliberately NOT a broad lock: only the
  /// lifecycle transition serializes on it, never packet ingestion.
  Future<void>? _historyAbortInFlight;

  /// The currently executing sync-marker handler, while the serialized
  /// drainer awaits it. Task starts wait for this too (a handler can park for
  /// seconds inside a large durable commit, and a commit that FAILS after a
  /// replacement task started would re-buffer the old task's rows under the
  /// new one). See [_awaitHistoryLifecycleQuiescence].
  Future<void>? _historyMarkerInFlight;

  /// True from a task claim until that task's first HISTORY_START. Doc 05: a
  /// task is Running-with-no-active-burst until the strap declares a burst,
  /// and in that state a HISTORY_END is a DUPLICATE — drop, no ACK. Without
  /// this, a late END straggling in from the previous (aborted) task during
  /// the claim's range/clock window would carry the new generation and be
  /// validated as part of the new task. Enforced on gen5 only, where doc 05
  /// pins the START-first flow; the gen4 marker sequence is unpinned and its
  /// behavior unchanged.
  bool _historyAwaitingFirstStart = false;

  bool get _dropPreStartHistory =>
      _historyAwaitingFirstStart && (_session?.band.isGen5 ?? false);
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

  /// Last GET_ALARM_TIME readback: what the STRAP says it holds, as opposed to
  /// what the app believes it set. Diagnostics only — a disagreement means the
  /// user's alarm may not actually be armed. Never used for display.
  int? _strapAlarmEpoch;
  bool? _strapAlarmActive;

  /// Why the last running haptics pattern stopped (HAPTICS_TERMINATED(100),
  /// `expired`, `error` or `user_double_tap`. The double tap is the
  /// only way to learn the WEARER dismissed an alarm rather than letting it
  /// time out. Recorded and logged; the alarm flow is unchanged.
  String? _lastHapticsTermination;
  int? _lastHapticsTerminationTs;

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

  /// Clear a bond-refusal auto-reconnect pause whose cooldown has expired, and
  /// report whether the pause is still in force (issue #208).
  ///
  /// The pause was previously cleared in exactly ONE place: the `createBond()`
  /// success branch. That branch is inside the connect path, which the pause
  /// itself stops from ever running — so the flag latched for the life of the
  /// process, and the Android foreground service made sure the process outlived
  /// any reason for it. [BondRefusalGiveUp.stillPaused] expires it after a
  /// cooldown; a band that genuinely will not bond simply re-trips.
  bool refreshAutoReconnectPause() {
    if (!state.autoReconnectPaused) return false;
    if (_bondGiveUp.stillPaused(DateTime.now())) return true;
    state.autoReconnectPaused = false;
    // Clear what the pause put on screen, too. Leaving `needsRepairGuide` set
    // tells the user to re-pair while auto-reconnect has quietly re-armed
    // behind the message, and a `bondRefusals` count that keeps climbing while
    // the give-up streak restarts at 1 no longer means anything.
    state.needsRepairGuide = false;
    state.bondRefusals = 0;
    _log('[RECONNECT] bond-refusal pause expired — auto-reconnect re-armed.');
    onState(state);
    return false;
  }
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
  // Frames whose CRCs both pass but whose revision byte this decoder does not
  // understand (gen5 only — gen4 has no revision byte). NOT corruption: a
  // non-zero count means the strap's firmware moved the header layout.
  int _frameRevRejectsTotal = 0;
  /// Bounded "ask the band to re-send a short burst" budget (see P-03 / the
  /// class doc — an unconditional FAIL here wedged sync forever).

  ClockRef? _clockRef; // strap-RTC ↔ wall correlation (set from GET_CLOCK)
  /// Latest strap-RTC ↔ wall correlation, or null until GET_CLOCK is answered.
  ClockRef? get clockRef => _clockRef;

  /// SET_CLOCK re-issue attempts THIS connection. setClock() reads the clock
  /// back, and the GET_CLOCK handler re-issues on drift — so cap the retries or
  /// a firmware that never latches either payload form would loop forever.
  int _clockCorrectTries = 0;

  /// True while the bootstrap's clock step owns the SET_CLOCK decision.
  ///
  /// The bootstrap sends **one** `SET_CLOCK(10)`. Without this window,
  /// an unset/far-off RTC got TWO: [_absorbClockEpoch]'s own bounded
  /// re-correction fired on the hello/GET_CLOCK reply, and
  /// [_bootstrapSetClock] then wrote again because no correlation existed.
  /// a duplicate persistent-state write is a real hazard. While
  /// this is set, the absorb handler leaves the write to the bootstrap step;
  /// outside it (RTC-lost events, the periodic re-verify) it corrects itself
  /// exactly as before.
  bool _bootstrapClockWrite = false;
  // Proactive RTC recheck timestamp for long-lived connections — see
  // kRtcReverifyIntervalSeconds. Every other clock recheck is symptom-driven.
  DateTime? _lastClockVerifyAt;
  int? _sessionOldestUnix; // strap's banked-data window (GET_DATA_RANGE)
  int? _sessionNewestUnix;
  Map<String, dynamic>? _lastPagesBehind;

  /// The strap's own ring-buffer bookkeeping from the last GET_DATA_RANGE reply
  /// — `{written, used, capacity, trim_page, wrap_count, free_records}`, exactly
  /// as protocol parsed it (SD-08). Null until a reply carried it.
  ///
  /// DEVICE STATE, not physiology: it can claim what it says and nothing more.
  /// `wrap_count` is a ring wrap counter, NOT a unique batch id — never build
  /// dedupe on it.
  Map<String, dynamic>? get lastPagesBehind => _lastPagesBehind;
  // Lifetime count of GET_DATA_RANGE reads rejected by isCorruptFutureRtc —
  // see the range_oldest/range_newest handler below.
  int _corruptDataRangeCount = 0;
  // Lifetime count of GET_CLOCK `clock_epoch` reads rejected by the same gate
  // (ClockPolicy.acceptsClockRead) — see the clock_epoch handler below.
  int _corruptClockReadCount = 0;
  // True when the last GET_CLOCK showed a plausible strap RTC reading > 1 day in
  // the FUTURE relative to the phone — the phone clock is likely wrong (slow), so
  // history offload is DEFERRED (not drained-and-trimmed) until the clocks agree.
  // See ClockPolicy.phoneClockSuspect and _startHistoricalRefresh.
  bool _phoneClockSuspect = false;
  /// MONOTONIC seconds ([_monotonicSecs]) at which the suspicion started — not a
  /// wall `DateTime`. The whole point of this state is that the wall clock is
  /// not trusted: timing the grace window off `DateTime.now()` lets the very
  /// jump we are waiting for (the phone stepping forward over NTP, possibly
  /// still >1 day behind the strap) expire the window instantly and hand back
  /// permission to drain-and-trim under a clock we still don't trust.
  double? _phoneClockSuspectSince;
  bool get historyPausedForClock => _deferForClock;
  /// Defer history only while the disagreement is still young. A slow phone
  /// re-syncs over NTP in minutes; one that persists past the grace window is a
  /// strap RTC running fast, and deferring forever would stall sync for good.
  bool get _deferForClock =>
      _phoneClockSuspect &&
      !ClockPolicy.suspectGraceExpired(
          _phoneClockSuspectSince, _monotonicSecs());
  int _clockPausedOffloads = 0; // diagnostics: offloads deferred for this reason
  /// Request/response correlation for every command this engine awaits
  ///. Replaces the two ad-hoc one-shot completers this file used to
  /// carry for HELLO and GET_CLOCK, which keyed off "a reply of roughly the
  /// right shape arrived" and could therefore be satisfied by an unrelated
  /// command's answer. Emptied on teardown so a dropped link never leaves a
  /// caller waiting out a full timeout on a connection that is gone.
  final CommandAwaiter _awaiter = CommandAwaiter();

  /// The most recent gen5 HELLO. Its timestamp is the primary input to the
  /// clock decision.
  Gen5HelloInfo? _gen5Hello;

  /// Consecutive HELLO-EXCHANGE failures, counted ACROSS reconnect
  /// attempts (like `_marginalRadio`/`_postBondLoop`, and deliberately NOT
  /// reset in the per-connection block in `_doConnect`); at
  /// [kHelloFailuresBeforeBondReset] the counter resets and the platform bond
  /// is removed exactly once before starting over — through the existing
  /// reconnect owner, never a nested reconnect. Cleared ONLY when a complete
  /// bootstrap reaches READY ([_finishConnect]); a hello object arriving is
  /// not success. Identity/clock/name failures are connection failures but
  /// are deliberately NOT counted here — the evidence scopes this counter to
  /// the exchange itself.
  int _helloFailures = 0;
  static const int kHelloFailuresBeforeBondReset = 5;

  // The two bootstrap delays moved to `adapters/_registry.dart`
  // ([kGen5PreRegistrationDelay] / [kGen5PostRegistrationDelay]) and are read
  // per band off [BandEntry.preRegistrationDelay] — a band-specific duration is
  // data, and keeping a second copy here would be the one thing an assumption's
  // named constant exists to prevent.

  /// while the band reports charging, ask it what
  /// battery pack it is on — "five attempts, 5,000 ms between attempts", and
  /// "every unusable attempt is followed by the 5-second delay, including the
  /// fifth". Purely advisory: a missing or invalid result "must not move the
  /// band out of READY".
  static const int kBatteryPackInfoAttempts = 5;
  static const Duration kBatteryPackInfoRetryDelay = Duration(seconds: 5);

  /// The identity verdict from the last successful hello — ENFORCED by
  /// [_gen5PostHelloGates] (a failed verdict fails the connection). Null
  /// until a hello lands.
  HelloIdentity? _helloIdentity;

  /// The last USABLE `GET_BATTERY_PACK_INFO(151)` reply and when it landed. Diagnostics only — surfaced in
  /// [offloadSnapshot], never gating READY or anything else.
  BatteryPackInfoResponse? _batteryPack;
  int? _batteryPackTs;
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
  // Consecutive HISTORY_END refuses where the burst banked nothing durable
  // but the RecordGate dropped samples. After a short streak we re-issue
  // SET_CLOCK and bounce — the usual cause is a bad post-reconnect window
  // that would otherwise loop empty drop-ACKs (or, after the refuse guard,
  // re-deliver forever without ever correcting the clock).
  //
  // NOT reset per connection (unlike _emptySync / _stuckStrap). The remedy IS
  // a reconnect, so a per-connection reset made the escalation unreachable:
  // the idle watchdog tears the session down after a refuse-only burst, the
  // next connect zeroed the count, and the loop ran forever at streak 1.
  // See NoDurableProgressEscalation for the full derivation.
  final NoDurableProgressEscalation _noDurableProgress =
      NoDurableProgressEscalation();
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

  void _logHistoricalOptics(R24 r) {
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
        // deprecated names, but this is a raw-bytes debug line — logging them
        // under the label we've always used is the point.
        // ignore: deprecated_member_use
        'temp=${r.skinTempRaw} amb=${r.ambientRaw} '
        // ignore: deprecated_member_use
        'ppg_green=${r.ppgGreen} ppg_red_ir=${r.ppgRedIr}',
      );
      return;
    }

    // No v25 arm: the only caller branches on `recType != Record.r25`, and
    // `recType` is frame.inner[1] — the same byte `r.histVersion` reads — so a
    // v25 record can never reach here. v25 is archived whole instead (it is a
    // 24 Hz PPG waveform, not a 1 Hz record), and its byte survey lived here
    // unreachable.
  }

  /// Note that records were just persisted; (re)arm the debounced derive trigger.
  /// Called from the record-store paths. No-op when no [onDataStored] is wired.
  void _noteStored() {
    if (onDataStored == null) return;
    final now = DateTime.now();
    _lastStored = now;
    _firstPending ??= now;
    _armDeriveTimer();
  }

  /// One-shot timer armed at the debouncer's computed next boundary — replaces
  /// the old 2 s Timer.periodic poll, which during continuous background
  /// listening ran for the whole pending window (a permanent 0.5 Hz CPU wake,
  /// 24/7 with a healthy link). Fires, re-evaluates, and either delivers
  /// [onDataStored] or re-arms at the next boundary. Only armed when none is
  /// pending, so record floods don't churn timers; tier flips are handled by
  /// the [setBackground] poke below.
  void _armDeriveTimer([Duration? delay]) {
    if (_deriveTimer != null) return;
    final fp = _firstPending;
    if (fp == null) return;
    final d = delay ??
        deriveDebouncer.nextCheckDelay(
          sinceLastRecord: DateTime.now().difference(_lastStored),
          sinceFirstPending: DateTime.now().difference(fp),
          dataStaleness: deriveDataStaleness(),
          isForeground: isForegroundActive(),
          isBackgrounded: _backgrounded,
        );
    _deriveTimer = Timer(d, () {
      _deriveTimer = null;
      final pending = _firstPending;
      if (pending == null) return;
      final fire = deriveDebouncer.shouldDerive(
        hasPending: true,
        sinceLastRecord: DateTime.now().difference(_lastStored),
        sinceFirstPending: DateTime.now().difference(pending),
        dataStaleness: deriveDataStaleness(),
        isForeground: isForegroundActive(),
        isBackgrounded: _backgrounded,
      );
      if (fire) {
        _firstPending = null;
        onDataStored!.call();
        return;
      }
      _armDeriveTimer();
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

  /// True once this connection's history hit the terminal `Stuck` boundary
  ///: a burst failed validation
  /// [kBurstValidationAttemptLimit] times and the abort went out. Nothing may
  /// start another drain on this link; continuation belongs to a later
  /// connection. Callers that loop over sync sessions must stop on it.
  /// Whether a terminal `Stuck` is currently refusing drain work.
  ///
  /// Windowed, not the raw latch -- callers use this to mirror the engine's own
  /// refusal, so it has to go false when the engine starts accepting triggers
  /// again. The raw latch stays visible in diagnostics as `history_stuck`.
  bool get historyStuckThisSession => _session?.historyStuckActive ?? false;

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
    // EVERY gate rejection was "below the 2023-11 epoch floor" — the signature
    // of a source whose time base is uptime, a sequence number or milliseconds
    // rather than wall clock (ASSUMPTIONS F1). Nothing is lost when it fires
    // (TrimAckPolicy refuses the trim on a drop-only burst) but nothing is
    // stored either and the chunk is re-delivered forever, so it needs a
    // reader. This is it.
    'gate_time_base_not_wallclock': _recordGate.timeBaseNotWallClock,
    // CRC8/CRC32 frame failures — previously silent (see `_subscribe`). A
    // rising count with a healthy `gate_dropped_*` is the signature of a
    // degrading radio corrupting frames rather than a stale/implausible band.
    'crc_failures_total': _crcFailuresTotal,
    'crc_failures_this_session': _crcFailuresThisSession,
    'frame_rev_rejects_total': _frameRevRejectsTotal,
    'frame_corruption_tripped': _frameCorruption.tripped,
    // Band-truth reconciliation: expectedPacketCount vs. what we actually
    // committed — advisory only (see the comment at the validation site), but
    // a *streak* of mismatches is a real signal worth watching over time.
    'burst_mismatch_total': _burstMismatchTotal,
    'burst_mismatch_streak': _burstMismatchStreak,
    // Terminal `Stuck` for this connection and how
    // much re-offer/re-trigger traffic the latch has since absorbed.
    'history_stuck': _session?.historyStuck ?? false,
    'stuck_markers_dropped': _session?.stuckMarkersDropped ?? 0,
    'stuck_refreshes_refused': _session?.stuckRefreshesRefused ?? 0,
    // Terminal-task latch (abort boundary) and the straggler traffic it has
    // absorbed since — the ended-task counterpart of the stuck counters.
    'history_task_ended': _session?.historyTaskEnded ?? false,
    'ended_markers_dropped': _session?.endedMarkersDropped ?? 0,
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
    // What the STRAP reports it holds (GET_ALARM_TIME), not what we set.
    'strap_alarm_epoch': _strapAlarmEpoch,
    'strap_alarm_active': _strapAlarmActive,
    // Unsolicited strap telemetry (haptics termination). Observability only —
    // it drives neither a sync nor the alarm flow.
    'last_haptics_termination': _lastHapticsTermination,
    'last_haptics_termination_ts': _lastHapticsTerminationTs,
    // hello health and the identity verdict (the gate itself is enforced in
    // the bootstrap). `hello_failures` counts ACROSS reconnects, resets at
    // the bond-reset threshold and clears when a bootstrap reaches READY.
    'hello_failures': _helloFailures,
    'hello_identity_ok': _helloIdentity?.ok,
    'hello_serial_eeprom_failure': _helloIdentity?.eepromFailureSignal,
    // what the band answered about the puck it
    // was sitting on. Absent until a USABLE reply lands (see
    // [BatteryPackInfoGate]); never a readiness input.
    'battery_pack_attached': _batteryPack?.attached,
    'battery_pack_address': _batteryPack?.identifier,
    'battery_pack_name': _batteryPack?.name,
    'battery_pack_type': _batteryPack?.batteryPackType?.name,
    'battery_pack_type_raw': _batteryPack?.batteryPackTypeRaw,
    'battery_pack_status': _batteryPack?.statusRaw,
    'battery_pack_ts': _batteryPackTs,
    // Optional Memfault (0007) traffic — collected, never parsed or required.
    'memfault_chunks': _memfaultChunks,
    'memfault_bytes': _memfaultBytesTotal,
    'pending_commands': _awaiter.pendingKeys,
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
  ///
  /// Serialised process-wide through [withScanLock]: the HR-sensor scan shares
  /// this one radio scanner, and the `isScanning == false` await below is
  /// satisfied by ITS `stopScan` too — an unserialised scan silently ends
  /// having seen nothing and reports "No band found".
  Future<BluetoothDevice?> scan({
    Duration timeout = const Duration(seconds: 12),
  }) =>
      withScanLock(() => _scanLocked(timeout));

  Future<BluetoothDevice?> _scanLocked(Duration timeout) async {
    // A phone-level blocker is NOT "nothing answered". Returning null for a
    // revoked Bluetooth permission classified it as `notFound` upstream, which
    // told the user to walk closer to a band that was never the problem — the
    // one fix that cannot work. Check the adapter BEFORE scanning and throw,
    // so the reason reaches the caller instead of being flattened into a null.
    final pre = await _detectBlocker();
    if (pre != null) {
      _noteBlocker(pre);
      _setPhase(BleConnState.idle);
      throw BleUnavailableException(pre);
    }
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _setPhase(BleConnState.scanning);
    // Advertise-filter on every FRAMED band's service UUID plus the 16-bit
    // WHOOP member UUID fallback. This is an OS-LEVEL filter: a device whose
    // service is not in this list is invisible to the callback below, so the
    // registry — not a literal here — is what decides which bands can be seen
    // at all. The actual band is pinned later at discovery.
    //
    // [kFramedBands], not the whole registry: this is the "find my band" scan,
    // and a notify-only sensor that matched here would be handed to
    // `_doConnect`, which would then talk WHOOP at it.
    //
    // The 16-bit member UUID (kWhoopMemberUuid16) is a WHOOP-only fallback for
    // a 128-bit vendor UUID hidden in the scan-response overflow area — see
    // [whoopScanServiceUuids] / [advertisementLooksLikeWhoop]'s doc comment.
    final wanted = [
      for (final e in kFramedBands) Guid(e.service),
      Guid(kWhoopMemberUuid16),
    ];
    // ACCEPTANCE stays broad (#255) — the match below. The GENERATION HINT is
    // narrower: only an advertised 128-bit service names a generation
    // ([ScanAcceptPolicy]); a name-only or 16-bit-only match records no hint,
    // and the connect path then probes the official gen5 order first and lets
    // GATT discovery pin the truth.
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames = r.advertisementData.serviceUuids.map(
          (g) => g.str.toLowerCase(),
        );
        // ponytail: `whoop` name-match is a WHOOP-only fallback for a band that
        // advertises its name but not its service UUID. A per-entry name
        // matcher is D9's `BandDiscovery`; until then this one literal stays.
        if (found == null &&
            (name.contains('whoop') ||
                advNames.any((s) =>
                    s == kWhoopMemberUuid16 ||
                    s.startsWith('0000fd4b') ||
                    kFramedBands.any((e) => s.startsWith(e.servicePrefix))))) {
          found = r.device;
          final adv = ScanAcceptPolicy.accepts(
            r.advertisementData.serviceUuids.map((g) => g.str),
          );
          if (adv != null) {
            _advertisedGeneration[r.device.remoteId.str] = adv;
          }
          unawaited(
            FlutterBluePlus.stopScan().catchError(
              (Object e) => _log('stopScan after match failed: $e'),
            ),
          );
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: wanted, timeout: timeout);
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      // Android reports a missing runtime permission by throwing here rather
      // than through the adapter state, so the pre-check above cannot catch it.
      final blocker = classifyBleBlocker(error: e);
      if (blocker != null) {
        _noteBlocker(blocker);
        await sub.cancel();
        _setPhase(BleConnState.idle);
        throw BleUnavailableException(blocker);
      }
      _log('scan error: $e');
    } finally {
      await sub.cancel();
    }
    if (found == null) {
      _setPhase(BleConnState.idle);
      // The remedy in this line is still WHOOP-specific ("the official app").
      // Per-band copy needs the per-entry discovery/label of D9; the registry
      // does not make it fixable on its own.
      _log('No band found (force-quit the official app; band must be free).');
    } else {
      _clearBlocker();
    }
    return found;
  }

  // ── phone-level Bluetooth blockers ──────────────────────────────────────────
  /// The last reason the phone's own stack refused us, or null when the stack is
  /// usable. Latched (a blocker does not clear itself) and cleared only by a
  /// scan or connect that actually got through.
  BleBlocker? _blocker;

  BleBlocker? get bluetoothBlocker => _blocker;

  /// The ONE connection state a screen renders — the phone-level blocker and the
  /// band's own diagnostic flags folded into a named state with its reason and
  /// its fix. See [bandStatusFor]; every flag it reads is set by a detector in
  /// this file.
  BandStatus get bandStatus => bandStatusFor(
        connection: state.connection,
        blocker: _blocker,
        autoReconnectPaused: state.autoReconnectPaused,
        needsRepairGuide: state.needsRepairGuide,
        syncChunkQuarantined: state.syncChunkQuarantined,
        strapNeedsReboot: state.strapNeedsReboot,
        syncClockLost: state.syncClockLost,
        bondRefusals: state.bondRefusals,
      );

  /// Read the adapter state without hanging: `unknown` is the pre-init value and
  /// never a verdict, so wait past it, but never longer than [_blockerProbe].
  static const Duration _blockerProbe = Duration(seconds: 2);

  Future<BleBlocker?> _detectBlocker() async {
    try {
      final s = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(_blockerProbe,
              onTimeout: () => BluetoothAdapterState.unknown);
      return classifyBleBlocker(adapterState: s.name);
    } catch (e) {
      return classifyBleBlocker(error: e);
    }
  }

  void _noteBlocker(BleBlocker b) {
    if (_blocker == b) return;
    _blocker = b;
    _log('[BLE] blocked by the phone, not the band: ${b.name}.');
    onState(state);
  }

  /// Anything that actually reached the radio proves the stack is usable again.
  void _clearBlocker() {
    if (_blocker == null) return;
    _blocker = null;
    _log('[BLE] phone-level Bluetooth block cleared.');
    onState(state);
  }

  /// Reconnect to a previously-paired device by its persisted remote id.
  ///
  /// [generationHint] is the persisted 'gen4'/'gen5' from the pairing record:
  /// a known-device reconnect skips scanning, and the official gen5 connect
  /// order differs before discovery, so the generation has to arrive from
  /// outside the link. Anything but an explicit 'gen4' probes the official
  /// gen5 sequence first ([connectRouteFor]); a discovered gen4 falls back to
  /// the unchanged legacy flow.
  Future<bool> connectToRemoteId(String remoteId, {String? generationHint}) =>
      connect(BluetoothDevice.fromId(remoteId), generationHint: generationHint);

  /// What the last accepting scan ADVERTISED per remote id ('gen4'/'gen5'), so
  /// a first-ever connect right after a scan takes the generation-correct
  /// bootstrap order without waiting for a persisted hint.
  final Map<String, String> _advertisedGeneration = {};

  // ── connect ────────────────────────────────────────────────────────────────────
  /// Idempotent connect. Serialised through [_opLock] so it can never overlap
  /// another connect/disconnect. Returns true on a fully-ready link.
  Future<bool> connect(BluetoothDevice device, {String? generationHint}) =>
      _locked(() async {
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
    if (!await _claimBand(device.remoteId.str)) return false;
    // Any prior session is dead to us now — tear it down before a new one.
    await _teardownSession(intentional: true);
    try {
      return await _doConnect(device, generationHint: generationHint);
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
  /// leave the claim pointing at an engine with no link — and only
  /// `disconnect()` ever released it, which nothing calls on this path. Every
  /// later background drain then saw a non-null owner and yielded forever.
  Future<void> _failConnect() async {
    await _teardownSession(intentional: true);
    _releaseBand();
    _setPhase(BleConnState.idle);
  }

  Future<bool> _doConnect(BluetoothDevice device, {String? generationHint}) async {
    state.address = device.remoteId.str;
    _setPhase(BleConnState.connecting);
    final session = _Session(device);
    _session = session;
    _liveReady = false;
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
      // Bluetooth revoked mid-life shows up here, on a reconnect, and used to
      // vanish into the reconnect loop as an ordinary failed attempt — retrying
      // silently forever against a stack that will never answer.
      final blocker = classifyBleBlocker(error: e);
      if (blocker != null) _noteBlocker(blocker);
      _log('connect failed: $e');
      await _failConnect();
      return false;
    }
    _clearBlocker();

    // connect() resolved without throwing => the link is up. Set this explicitly
    // rather than racing the connectionState stream's `connected` emission, so
    // the setup below (discover/subscribe/SET_CLOCK → bond) is never skipped.
    session.connected = true;
    session.sawConnected = true;

    // The official gen5 order differs BEFORE discovery (LE 2M PHY
    // preference) and puts the bond after discovery + the MTU intent, so the
    // route must be chosen ahead of discovery: a scan supplies the generation
    // from the advertisement, a known-device reconnect from the persisted
    // pairing. [connectRouteFor] sends everything that is not EXPLICITLY gen4
    // — including an unknown/null hint, e.g. a pairing upgraded from an older
    // build or a headless engine that never persisted one — through the
    // official gen5 sequence first; its discovery identifies the band, and a
    // discovered gen4 falls back to the unchanged legacy flow below.
    final hint = generationHint ?? _advertisedGeneration[device.remoteId.str];
    if (connectRouteFor(hint) == ConnectRoute.gen5Official) {
      switch (await _connectGen5Official(device, session)) {
        case _Gen5ConnectOutcome.ready:
          return true;
        case _Gen5ConnectOutcome.failed:
          return false;
        case _Gen5ConnectOutcome.notGen5:
          // Discovery found a gen4 service — take the proven legacy path
          // (one extra discovery, paid only until the generation persists).
          break;
      }
    }
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
      // Setup is immediately followed by INIT + the first flash drain, which is
      // exactly when throughput matters, so `_connectSetup` asks for the fast
      // interval — through the SAME serialized helper as every other
      // transition. `_applyLinkPriority` steps it back down once the offload
      // ends (issue #200); before that, `high` was requested here and then held
      // for the entire life of a deliberately-permanent connection.
      _connectSetup = true;
      await _applyLinkPriority();

      if (!session.connected) {
        _log('connect: link dropped during setup.');
        await _failConnect();
        return false;
      }

      _setPhase(BleConnState.discovering);
      // The SAME discovery+validation the official gen5 route runs — see
      // [_discoverBand]; it logs which half failed.
      final found = await _discoverBand(device);
      if (found == null) {
        await _failConnect();
        return false;
      }
      final entry = found.entry;
      session.applyBand(entry);
      state.generation = entry.id;
      _log('Detected ${entry.label} (${entry.id}) link.');
      session.cmdTo = found.cmdTo;
      final cmdFrom = found.cmdFrom;
      final events = found.events;
      final data = found.data;

      // The bond is complete by here, so this is the pause that precedes
      // notification registration — [BandEntry.preRegistrationDelay], zero on
      // a band with no evidence for one.
      final preDelay = entry.preRegistrationDelay;
      if (preDelay > Duration.zero &&
          !await _bootstrapPause(
            session,
            preDelay,
            'the pre-registration delay',
          )) {
        return false;
      }
      _setPhase(BleConnState.subscribing);
      // Null only for a band whose entry does not require the characteristic —
      // the `missing` gate above has already aborted for one that does.
      if (cmdFrom != null) await _subscribe(session, cmdFrom, 'cmd_from');
      if (events != null) await _subscribe(session, events, 'events');
      if (data != null) await _subscribe(session, data, 'data');

      if (!await _bootstrapAfterRegistration(session)) return false;
      return await _finishConnect(session);
    } catch (e) {
      _log('connect setup failed: $e');
      await _failConnect();
      return false;
    }
  }

  /// Everything between a completed bootstrap and a live listening link:
  /// per-connection policy resets, session timers, the drain controller, the
  /// READY transition (with its follow-ups) and INIT. Shared verbatim by the
  /// legacy path and the official gen5 path so there is exactly one way a
  /// session becomes ready.
  Future<bool> _finishConnect(_Session session) async {
    try {
      // Fresh clock verification stamp — see kRtcReverifyIntervalSeconds.
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
      // _noDurableProgress is deliberately NOT reset here — like _marginalRadio
      // and _postBondLoop above, it counts consecutive bad cycles ACROSS
      // reconnects. Resetting per connection made the escalation unreachable,
      // because the escalation's own remedy is a reconnect. It clears on a
      // successful trim ACK, the only thing that proves the condition is over.
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
      // The gate's drop counter restarts at 0, so its burst baseline must too.
      // Left behind, a HISTORY_END arriving on connection N>1 before that
      // connection's first HISTORY_START computed a NEGATIVE droppedThisBurst
      // against the previous connection's baseline — which fabricates a
      // positive burstPacketShortfall and makes TrimAckVerdict.blockedNoDurableProgress
      // unfireable (`!hadDurableRows && droppedThisBurst > 0`), i.e. a
      // gate-drop-only burst could authorise the band to trim flash we never
      // banked. The startless HISTORY_END is expected, not hypothetical: the
      // historyEnd branch has its own `history_end_while_not_syncing` terminal.
      _burstDroppedAtStart = 0;
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
        // Backgrounded: 60 s cadence. LINK_VALID is an app-level write, not
        // link-layer maintenance — the controller keeps the connection alive on
        // its own, and offloads already pause this write for minutes at a time
        // with no link loss, so a 60 s gap is proven safe on real hardware.
        // 10 s stays for foreground (cheap there, and the responsive case is
        // where a firmware-side idle policy would first show).
        if (_backgrounded) {
          final last = _lastLinkValidAt;
          if (last != null &&
              DateTime.now().difference(last) < const Duration(seconds: 60)) {
            return;
          }
        }
        _lastLinkValidAt = DateTime.now();
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
      // READY ordering: record connection success, clear the
      // successful-bootstrap failure state, transition, and only then launch
      // the charging follow-up. The hello-failure count clears HERE and
      // nowhere earlier — a hello object arriving is not a completed
      // bootstrap, and clearing on it would let a link that repeatedly dies
      // between hello and READY reset its own counter and never reach the
      // five-failure bond reset.
      _log('Connected + subscribed — listening (history + live).');
      if (_helloFailures > 0) {
        _log('[HELLO gen5] bootstrap completed — clearing '
            '$_helloFailures accumulated hello failure(s) at READY.');
        _helloFailures = 0;
      }
      _setPhase(BleConnState.listening);
      // The charging-only battery-pack lookup launches strictly AFTER
      // READY, asynchronously; it never blocks or gates anything.
      _maybeStartBatteryPackFollowUp(session);
      // The INIT drain claim rides the same task-lifecycle rules as every
      // other history task ([_startInitDrain]) — quiescence barrier, task
      // generation, staleness re-checks, arm/rollback.
      final ok = await _startInitDrain(session);
      // Live toggles only AFTER the INIT sequence: the caller reconciles the
      // owners' intent once this returns (see `_liveReady`).
      if (ok && identical(_session, session)) _liveReady = true;
      return ok;
    } catch (e) {
      _log('connect setup failed: $e');
      await _failConnect();
      return false;
    }
  }

  /// The INIT drain claim — the tail of [_doConnect], lifted out so its
  /// lifecycle rules are testable: wait for the previous task's quiescence,
  /// re-check the session, arm the task state, fire INIT, and roll back if
  /// INIT never went out. Returns whether connect setup may report success —
  /// false only when [session] died along the way (no INIT traffic goes out
  /// then; the disconnect path owns the cleanup).
  Future<bool> _startInitDrain(_Session session) async {
    // INIT seq4 IS SEND_HISTORICAL_DATA, so it needs the SAME data-safety gate
    // as _startHistoricalRefresh — without it every fresh connection drains
    // and trims under exactly the untrustworthy phone clock we refuse to drain
    // under there, which is the common case (a dead-battery reboot lands a bad
    // clock and a reconnect together).
    final drainOnInit = !_deferForClock;
    if (!drainOnInit) {
      _clockPausedOffloads++;
      _log(
        '[SYNC] INIT drain DEFERRED — phone clock appears wrong relative to '
        'the strap RTC; not draining history until they agree '
        '(deferred_total=$_clockPausedOffloads).',
      );
    }
    // The INIT drain is a new task like any other claim, so it goes behind
    // the same lifecycle barrier: a previous session's task-ending abort or
    // a marker handler still parked in a commit must finish unwinding
    // before this task arms. (Both resolve fast once their session is
    // stale — the owner-bound write refuses immediately, and the handler
    // re-checks staleness at every await.)
    await _awaitHistoryLifecycleQuiescence();
    // The wait can park for as long as an old commit takes — re-check that
    // THIS link survived it. A stale connect continuation must not mutate
    // the task state a replacement session now owns, run INIT against a dead
    // link, or report the connect as successful.
    if (_sessionIsStale(session)) {
      _log('[SYNC] INIT drain abandoned — the link died while waiting for '
          'the previous history task to unwind.');
      return false;
    }
    // Leftovers of a previous session's task (queued frames, parked
    // continuations) are stale from here — session binding already refuses
    // most of them, the generation closes the rest. Doc 05: no burst is
    // active until this task's first HISTORY_START.
    _historyTaskGen++;
    // Same claim as _startHistoricalRefresh's task boundary: the failure
    // tally and the waiter generation belong to the TASK, not to the
    // controller's lifetime. On a fresh connect the controller is already
    // new and this is a no-op; it matters once a caller reuses an existing
    // controller (debugStartInitDrain(), or a future one).
    _drain?.startFreshTask();
    _historyAwaitingFirstStart = drainOnInit;
    _setOffloadActive(drainOnInit);
    // Only a real drain spends the backfill floor; a deferred one leaves it
    // open so a foreground trigger can retry as soon as the phone corrects.
    final floorBeforeInit = _lastBackfillAt;
    if (drainOnInit) _lastBackfillAt = _wallSecs();
    // Both are pre-armed above because seq4 IS the drain trigger and the
    // flood can start before the write even returns. If INIT did not go out
    // there is no flood: hand the state back, or `_offloadActive` stays set
    // on a strap that was never asked for history and every later refresh
    // stops at the already-transmitting guard.
    final initOk = await sendInit(drain: drainOnInit);
    // UNCONDITIONAL staleness re-check — not only on a failed INIT. The last
    // write can succeed and the link die before this continuation resumes;
    // reporting success then hands the caller a READY verdict for a dead
    // session. And whichever way INIT went, a stale continuation must not
    // touch the rollback state its replacement now owns.
    if (_sessionIsStale(session)) {
      _log('[SYNC] INIT drain abandoned — the link died under the INIT '
          'writes; not reporting connect success for a dead session.');
      return false;
    }
    if (!initOk) {
      _historyAwaitingFirstStart = false;
      _setOffloadActive(false);
      _lastBackfillAt = floorBeforeInit;
      _log(
        '[SYNC] INIT did not fully write — no history was requested; '
        'clearing offload state so a later refresh can retry.',
      );
    }
    return true;
  }

  /// Drive the real INIT-drain claim ([_startInitDrain]) for the CURRENT
  /// session — the lifecycle barrier, the post-wait staleness re-check and
  /// the arm/rollback rules sit behind a real connect otherwise.
  @visibleForTesting
  Future<bool> debugStartInitDrain() {
    final session = _session;
    if (session == null) return Future.value(false);
    return _startInitDrain(session);
  }

  /// The official WHOOP 5 connect order, from an established link through
  /// READY:
  ///
  ///   prefer LE 2M PHY → discover + validate the fd4b service → request
  ///   MTU 247 → establish/await the Android bond → 600 ms → register the
  ///   required notifications serially → [_bootstrapAfterRegistration]
  ///   (500 ms → HELLO → name/identity gates → clock → advertising name) →
  ///   [_finishConnect] (READY + the charging follow-up).
  ///
  /// The PHY request is a preference, not proof the physical link changed PHY
  /// (the official HCI fixture shows no 2M update on a link whose source asked
  /// for one) — its failure is logged and non-fatal. MTU 247 is source intent;
  /// the band may originate the ATT exchange itself, and a failed request
  /// keeps the connection default. A missing service/characteristic, a failed
  /// required registration, or a refused bond each prevent READY.
  ///
  /// All platform work goes through [ops] — one production implementation
  /// ([_FbpGattOps]); tests inject a recorder so this exact order is
  /// assertable without a radio.
  Future<_Gen5ConnectOutcome> _connectGen5Official(
    BluetoothDevice device,
    _Session session, {
    GattBootstrapOps? ops,
  }) async {
    final gatt = ops ?? _FbpGattOps(this, device, session);
    try {
      try {
        await gatt.preferLe2mPhy();
        _log('[BOOT gen5] LE 2M PHY preference requested (a preference — not '
            'proof the physical link changed PHY).');
      } catch (e) {
        _log('[BOOT gen5] LE 2M PHY preference failed: $e — non-fatal; the '
            'link stays on its current PHY.');
      }
      if (!session.connected || _session != session) {
        _log('connect: link dropped before discovery.');
        if (identical(_session, session)) await _failConnect();
        return _Gen5ConnectOutcome.failed;
      }
      _setPhase(BleConnState.discovering);
      final entry = await gatt.discoverAndValidate();
      if (entry == null) {
        _log('[BOOT gen5] required band service or characteristic missing — '
            'connection failed.');
        await _failConnect();
        return _Gen5ConnectOutcome.failed;
      }
      // Discovery is the truth; the generation hint that routed us here was
      // only a hint. Anything else goes back to the legacy order unchanged.
      if (entry.id != kWhoopGen5.id) return _Gen5ConnectOutcome.notGen5;
      state.generation = entry.id;
      _log('Detected ${entry.label} (${entry.id}) link.');
      try {
        final negotiated = await gatt.requestMtu(247);
        _log('MTU negotiated: $negotiated (requested 247).');
      } catch (e) {
        _log('requestMtu failed: $e — MTU stays at the connection default.');
      }
      // Deliberately NO requestConnectionPriority here: no such call was
      // found in the official data path, so the official sequence must not
      // carry one before READY. The offload transition
      // ([_setOffloadActive], post-READY, separately owned) still raises the
      // interval for the drain, and gen4 keeps its legacy setup request.
      // Bond — in its official position, after discovery and the MTU intent.
      // Already bonded → no second bond. A refused/failed bond is FATAL here:
      // the strap gates every command behind encryption, so continuing would
      // run subscriptions and HELLO against writes the band silently drops.
      if (gatt.bondingApplies) {
        // BOUNDED, AND OUTSIDE THE REFUSAL ACCOUNTING. The initial bond-state
        // read is the one platform await in this bootstrap that could hang:
        // `bondState`'s first emission falls through to the platform's
        // `getBondState` when nothing is cached. Unbounded, a request that
        // never answers parks the bootstrap right here with `_session`
        // non-null and the phase still `discovering`, so `holdsBandLink` keeps
        // the claim live and every later headless drain yields to a connect
        // that will never finish — no recovery short of a process restart.
        //
        // A stalled read is a PHONE-STACK condition, not a band that refuses
        // to bond, so it fails the connect WITHOUT touching `bondRefusals` /
        // `needsRepairGuide`: counted as a refusal it would walk the give-up
        // threshold and then tell the user to remove a bond that is fine. The
        // legacy path counted `createBond()` failures only, and so does this.
        // `createBond()` needs no bound of ours: the plugin gives it a
        // 90-second response timeout.
        final bool alreadyBonded;
        try {
          alreadyBonded = await gatt.isBonded().timeout(_bondStateTimeout);
        } catch (e) {
          _log('[BOOT gen5] bond-state read failed or timed out ($e) — '
              'bootstrap stops here; NOT counted as a bond refusal.');
          await _failConnect();
          return _Gen5ConnectOutcome.failed;
        }
        try {
          if (alreadyBonded) {
            _log('[BOOT gen5] already bonded — not creating another bond.');
          } else {
            await gatt.createBond();
            _log('Bonded.');
          }
          // A clean bond clears the refusal streak + any give-up latch, so a
          // later run of refusals can trip the pause again, and un-pauses the
          // auto-reconnect loop.
          _bondGiveUp.bondSucceeded();
          state.bondRefusals = 0;
          state.autoReconnectPaused = false;
        } catch (e) {
          _log('BOND FAILED: $e — bootstrap stops here (no subscriptions, no '
              'HELLO, no READY). Remove the bond in system Bluetooth settings '
              'and re-pair.');
          state.needsRepairGuide = true;
          state.bondRefusals++;
          // After a run of consecutive refusals, stop the auto-reconnect loop
          // (it would otherwise pin the radio + drain the battery on a band
          // that will never accept the bond) and surface the re-pair guide. A
          // manual user connect still runs the bond, so a successful re-pair
          // recovers.
          if (_bondGiveUp.bondRefused()) {
            state.autoReconnectPaused = true;
            _log('[RECONNECT] bond-refusal give-up (${_bondGiveUp.consecutive}) '
                '— pausing auto-reconnect; re-pair required.');
          }
          onState(state);
          await _failConnect();
          return _Gen5ConnectOutcome.failed;
        }
      }
      if (!session.connected || _session != session) {
        _log('connect: link dropped during the bond.');
        if (identical(_session, session)) await _failConnect();
        return _Gen5ConnectOutcome.failed;
      }
      // The pause before notification registration —
      // [BandEntry.preRegistrationDelay] (600 ms on gen5), read off the ENTRY
      // exactly like `_bootstrapAfterRegistration` reads its post-registration
      // twin. A band-specific duration is data, and a second copy here is the
      // one thing the named constant exists to prevent.
      final preDelay = session.entry.preRegistrationDelay;
      if (preDelay > Duration.zero &&
          !await _bootstrapPause(
            session,
            preDelay,
            'the pre-registration delay',
          )) {
        return _Gen5ConnectOutcome.failed;
      }
      _setPhase(BleConnState.subscribing);
      // Serial registration in the retained official fixture order: command
      // response → optional Memfault → data → events (that order is one
      // client fixture, not a protocol requirement — but matching it costs
      // nothing). A failed REQUIRED registration faults setup; Memfault
      // (0007) stays optional in both directions: absent or failing, setup
      // continues, and when present its bytes are collected as diagnostics
      // without ever becoming a requirement.
      Future<bool> requiredRegistration(String role) async {
        try {
          await gatt.subscribe(role);
          return true;
        } catch (e) {
          _log('[BOOT gen5] required notification registration failed '
              '($role): $e — connection failed.');
          await _failConnect();
          return false;
        }
      }

      if (!await requiredRegistration('cmd_from')) {
        return _Gen5ConnectOutcome.failed;
      }
      if (await gatt.subscribeOptionalMemfault()) {
        _log('[BOOT gen5] optional Memfault (0007) registered — collected as '
            'diagnostics only.');
      } else {
        _log('[BOOT gen5] optional Memfault (0007) absent or not registered — '
            'not required; setup continues.');
      }
      if (!await requiredRegistration('data')) {
        return _Gen5ConnectOutcome.failed;
      }
      if (!await requiredRegistration('events')) {
        return _Gen5ConnectOutcome.failed;
      }
      if (!await _bootstrapAfterRegistration(session)) {
        return _Gen5ConnectOutcome.failed;
      }
      return await _finishConnect(session)
          ? _Gen5ConnectOutcome.ready
          : _Gen5ConnectOutcome.failed;
    } catch (e) {
      _log('connect setup failed: $e');
      await _failConnect();
      return _Gen5ConnectOutcome.failed;
    }
  }

  // ── bootstrap ────────────────────────────────────

  /// One of the two observed bootstrap delays, with the same stale-session
  /// check every neighbouring step carries: a link that drops during the sleep
  /// aborts setup instead of letting it run on against a dead connection.
  ///
  /// Returns false when the session is gone (the caller must return false too;
  /// teardown has already happened here).
  Future<bool> _bootstrapPause(
    _Session session,
    Duration delay,
    String what,
  ) async {
    await Future.delayed(delay);
    if (_session != session || !session.connected) {
      _log('link dropped during $what — abandoning setup.');
      // Tear down ONLY if we are still the live session — a newer _doConnect
      // that already took over must not have its link killed by this one.
      if (identical(_session, session)) await _failConnect();
      return false;
    }
    return true;
  }

  /// Everything the phase sequence puts between the last CCC write and
  /// READY: the 500 ms post-registration delay, the MANDATORY gen5 GET_HELLO,
  /// the Android native-name gate, the identity gates, the clock contract and
  /// the awaited advertising-name read. [_finishConnect] then owns the READY
  /// transition and the charging follow-up.
  ///
  /// Lifted out of [_doConnect] because this ORDER is the contract the
  /// specifies — and as inline statements inside a 400-line connect the only
  /// way to check it was against a radio.
  ///
  /// Returns false when a step failed or the link died under one; the session
  /// has already been torn down in that case.
  Future<bool> _bootstrapAfterRegistration(_Session session) async {
    // The pause after the last registration, before the higher-level state
    // machine runs — [BandEntry.postRegistrationDelay], zero on a band with no
    // evidence for one.
    final postDelay = session.entry.postRegistrationDelay;
    if (postDelay > Duration.zero &&
        !await _bootstrapPause(
          session,
          postDelay,
          'the post-registration delay',
        )) {
      return false;
    }
    _setPhase(BleConnState.settingUp);
    _clockCorrectTries = 0; // fresh retry budget for this connection
    // Drop the previous session's clock correlation so an alarm armed before
    // THIS session's clock work lands falls back to the raw wall epoch
    // (drift 0) instead of the stale strap-RTC frame. The steps below
    // repopulate it for this connection.
    _clockRef = null;
    _gen5Hello = null;
    if (session.band.isGen5) {
      // HELLO FIRST on gen5, and MANDATORY. Hello carries the strap's own
      // timestamp (the clock decision's input), plus the identity, battery,
      // charge and on-body state everything after this wants. A missing or
      // failed exchange — write failure, timeout, terminal FAILURE,
      // UNSUPPORTED, or a success whose body never parsed — fails the
      // CONNECTION: no GET_CLOCK fallback, no identity work, no READY.
      // The failure was already counted by _noteHelloFailure (the fifth also
      // removes the platform bond); recovery belongs to the reconnect owner,
      // never to a nested reconnect from inside this coroutine.
      final helloOk = await _readGen5Hello();
      if (_session != session || !session.connected) {
        _log('link dropped during gen5 HELLO — abandoning setup.');
        if (identical(_session, session)) await _failConnect();
        return false;
      }
      if (!helloOk) {
        _log('[HELLO gen5] hello exchange failed — hello is mandatory; '
            'connection failed.');
        await _failConnect();
        return false;
      }
      if (!await _gen5PostHelloGates(session)) return false;
      if (!await _gen5ClockContract(session)) return false;
      // The awaited advertising-name read is the last command before READY.
      // Its await completes before READY; its result is not a gate.
      await _readAdvertisingNameGen5(session);
      if (_session != session || !session.connected) {
        _log('link dropped during the advertising-name read — abandoning '
            'setup.');
        if (identical(_session, session)) await _failConnect();
        return false;
      }
      return true;
    }
    // ── gen4: the proven legacy clock flow, unchanged ──
    // READ BEFORE WRITE. This used to be an unconditional SET_CLOCK, which is
    // precisely the write [ClockPolicy.phoneClockSuspect] says we must never
    // make: on a phone running >1 day slow it stamps that slow time onto a
    // CORRECT strap RTC — and worse, it destroys the evidence, because the
    // read-back then "agrees" and every later suspect-clock gate sees a
    // healthy pair. Read first; skip the write while the PHONE is the suspect
    // one. Unset/behind/garbage-low RTCs are unaffected (not suspect) and are
    // still corrected here and by the clock_epoch handler's bounded re-issue.
    // _readClock waits on a real reply now — up to _clockReadTimeout, where
    // this used to be a 120 ms sleep. That is a much wider window for the
    // link to drop underneath us, and setClock() absorbs failed writes, so
    // without these checks setup would carry on past a teardown, rebuild the
    // drain state and hand back `true` for a dead connection.
    // One SET_CLOCK per bootstrap: the read runs inside the window so the
    // absorb handler's own re-correction stands down and _bootstrapSetClock
    // is the single writer.
    _bootstrapClockWrite = true;
    try {
      await _readClock();
      if (_session != session || !session.connected) {
        _log('link dropped during the clock read — abandoning setup.');
        // Tear down ONLY if we are still the live session. `_failConnect`
        // teardown+band-release act on whatever `_session` currently points
        // at, so a newer `_doConnect` that already took over would have its
        // link killed and its band claim dropped by this stale invocation.
        if (identical(_session, session)) await _failConnect();
        return false;
      }
      await _bootstrapSetClock(session);
    } finally {
      _bootstrapClockWrite = false;
    }
    if (_session != session || !session.connected) {
      _log('link dropped during SET_CLOCK — abandoning setup.');
      // Tear down ONLY if we are still the live session (see above).
      if (identical(_session, session)) await _failConnect();
      return false;
    }
    return true;
  }

  /// The post-HELLO readiness gates: the Android native-name
  /// requirement and the serial/CPU identity rules. A failed gate is a
  /// CONNECTION failure — deliberately not a hello-exchange failure, because
  /// the failure counter is scoped to the exchange
  /// itself and the evidence never counts these against it.
  Future<bool> _gen5PostHelloGates(_Session session) async {
    final hello = _gen5Hello!;
    // Android `BluetoothDevice.getName()` must be non-null. Read from the
    // PLATFORM — flutter_blue_plus's `platformName` is an in-memory cache
    // that is empty for a device rebuilt with `BluetoothDevice.fromId()` on a
    // cold process start, so gating on it would fail every known-device
    // reconnect that skipped scanning. The exact gate is non-null (an
    // empty-but-present name passes — do not strengthen without evidence).
    // Android-only; iOS exposes no equivalent and the source gate is
    // Android's.
    if (_nameGateApplies) {
      final name = await _nativeName(session.device.remoteId.str);
      if (_session != session || !session.connected) {
        _log('link dropped during the native-name read — abandoning setup.');
        if (identical(_session, session)) await _failConnect();
        return false;
      }
      if (name == null) {
        _log('[BOOT gen5] Android reports no name for this device — '
            'readiness requires a non-null native name; connection failed.');
        await _failConnect();
        return false;
      }
      _log('[BOOT gen5] Android native name present ("$name").');
    }
    // Family refinement: a recognized discriminator refines the stored type;
    // an unrecognized/null mapping is NOT by itself a rejection.
    if (hello.isWhoop5) {
      _log('[BOOT gen5] family discriminator ${hello.opticalDiscriminator} '
          'confirms WHOOP 5.0.');
    } else {
      _log('[BOOT gen5] family discriminator ${hello.opticalDiscriminator} '
          'maps to no known family — type stays gen5 (not a rejection).');
    }
    // Identity — ENFORCED: serial and CPU must each FULLY match
    // [A-Za-z0-9]+; empty and partial matches fail. Evaluated by
    // _noteHelloSuccess, judged here. Battery, charging, on-body, firmware,
    // hardware, signal-processor, HR-broadcast and error fields are state or
    // diagnostics, never gates.
    final id = _helloIdentity;
    if (id == null || !id.ok) {
      _log('[BOOT gen5] identity gate FAILED ($id) — connection failed.');
      await _failConnect();
      return false;
    }
    if (id.eepromFailureSignal) {
      // Passes the alphanumeric gate — a diagnostic, never a rejection.
      _log('[HELLO gen5] serial is all zeros — the strap is reporting an '
          'EEPROM failure. Not a reject; the band stays usable.');
    }
    return true;
  }

  /// The gen5 bootstrap clock contract:
  /// the timestamp hello ALREADY carries (subseconds included) is the strap's
  /// clock reading — zero is a present timestamp, not a missing one, so the
  /// parsed-hello path never sends GET_CLOCK (opcode 11 exists only as the
  /// generic null-timestamp fallback). Compare against a newly sampled phone
  /// time: below two whole seconds of absolute delta, succeed with no BLE
  /// write; at two or more, send exactly one awaited SET_CLOCK(10). A null
  /// SET_CLOCK response fails readiness and disconnects.
  Future<bool> _gen5ClockContract(_Session session) async {
    final hello = _gen5Hello!;
    // The absorb handler's own re-correction stands down inside this window
    // (_bootstrapClockWrite), leaving this method the single SET_CLOCK writer
    // for the bootstrap — including against the clock_epoch retry path.
    _bootstrapClockWrite = true;
    try {
      // Feed the suspect-phone verdict and the strap↔wall correlation the
      // same way a GET_CLOCK reply would, so both clock sources share one
      // brain. An implausible (unset-RTC) reading is deliberately never
      // correlated there; the delta below still forces the correction.
      // THE TIMESTAMP IS READ AT REVISION-1 OFFSETS. The pinned parser records
      // `helloRevision` and no longer refuses an unknown one (protocol#35 —
      // hello is MANDATORY on this path, so a firmware that bumps the byte has
      // to still connect), which leaves the timestamp as the one field this
      // method acts on that a moved layout could make plausible-but-wrong. An
      // unknown revision therefore neither fails the connection nor becomes a
      // correlation: it forfeits the "already in sync" shortcut and takes the
      // unconditional SET_CLOCK below, which writes a freshly sampled PHONE
      // time and is right under any layout.
      if (hello.helloRevision == 1) {
        _absorbClockEpoch(hello.tsSeconds);
        final helloMs =
            hello.tsSeconds * 1000 + (hello.tsSubseconds * 1000) ~/ 32768;
        final deltaMs =
            (DateTime.now().millisecondsSinceEpoch - helloMs).abs();
        if (!BootstrapClockGate.needsCorrectionMs(deltaMs)) {
          _log('[CLOCK] in sync (delta ${deltaMs}ms, tolerance '
              '${BootstrapClockGate.toleranceSeconds}s) — no correction '
              'needed; no SET_CLOCK written.');
          return true;
        }
      } else {
        _log('[CLOCK] hello revision ${hello.helloRevision} is not the '
            'revision-1 layout these offsets read — its timestamp is neither '
            'trusted nor correlated; correcting unconditionally.');
      }
      // The contract is UNCONDITIONAL at ≥2 s: one awaited SET_CLOCK with a
      // newly sampled phone time — even for a strap reading days ahead of the
      // phone. Edge's phone-suspect policy is a HISTORY-safety rule, not a
      // bootstrap rule; it must not turn the official clock step into a
      // refusal, and a successful correction clears it below (see
      // [_bootstrapSetClockGen5]) so the initial drain is not suppressed by a
      // verdict the write just made stale.
      final ok = await _bootstrapSetClockGen5();
      if (_session != session || !session.connected) {
        _log('link dropped during SET_CLOCK — abandoning setup.');
        if (identical(_session, session)) await _failConnect();
        return false;
      }
      if (!ok) {
        _log('[CLOCK] SET_CLOCK failed to write or went unanswered — clock '
            'synchronization is a readiness requirement; connection failed.');
        await _failConnect();
        return false;
      }
      return true;
    } finally {
      _bootstrapClockWrite = false;
    }
  }

  /// The one bootstrap SET_CLOCK(10): phone timestamp sampled when BUILDING
  /// the request, the confirmed 8-byte gen5 body (u32 LE seconds + u32 LE
  /// subseconds in 1/32768 s), one correlated await — and deliberately NO
  /// GET_CLOCK read-back (the official bootstrap sends none; the periodic
  /// re-verify still audits the RTC later). Returns whether a non-null
  /// response arrived; per the contract a non-null response object is
  /// success regardless of its result byte.
  Future<bool> _bootstrapSetClockGen5() async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final subsec = ((ms % 1000) * 32768) ~/ 1000; // 0..32767, 1/32768 s units
    final out = await _sendAwaited(Cmd.setClock, <int>[
      sec & 0xff,
      (sec >> 8) & 0xff,
      (sec >> 16) & 0xff,
      (sec >> 24) & 0xff,
      subsec & 0xff,
      (subsec >> 8) & 0xff,
      0,
      0,
    ]);
    if (!out.written) return false;
    _log('SET_CLOCK (gen5 bootstrap) → sec=$sec subsec=$subsec — awaiting '
        'the correlated response.');
    final resp = await out.response;
    if (resp != null && resp.success) {
      // The strap just took our wall time, so correlate at drift 0 without a
      // read-back — an alarm armed before the next periodic re-verify must not
      // be shifted by the drift this write just corrected.
      //
      // BOTH HALVES COME FROM THE ONE SAMPLE THE STRAP WAS GIVEN. Reading the
      // wall clock again here samples it after `out.response` resolved — up to
      // the awaiter's timeout later — so `driftSec` would be the round-trip
      // latency, and `setAlarm` arms at `when - driftSec`.
      _clockRef = ClockRef(device: sec, wall: sec);
      // And the phone-suspect verdict — computed off the PRE-correction hello
      // timestamp — is now stale by construction: strap and phone agree
      // because this write made them agree. Left set, it would defer the
      // initial history drain (and let record-gate age checks judge against a
      // reading that no longer exists). The suspect detector still re-trips
      // on the next reading if the phone genuinely is wrong.
      if (_phoneClockSuspect) {
        _phoneClockSuspect = false;
        _phoneClockSuspectSince = null;
        _log('[CLOCK] SET_CLOCK accepted — clearing the phone-clock-suspect '
            'verdict from the pre-correction reading; history may drain.');
      }
    }
    return resp != null;
  }

  /// The ONE service-discovery and characteristic-validation path.
  ///
  /// BOTH connect routes come here — `_FbpGattOps.discoverAndValidate` on the
  /// official gen5 order, and `_doConnect`'s legacy order, which a discovered
  /// gen4 falls back to. They used to be two transcriptions of this, and they
  /// had already drifted: only the gen5 copy resolved Memfault, and only the
  /// legacy copy matched on `str128` and on [BandEntry.requiredCharacteristics].
  /// Which service pins the band and which characteristics are required is one
  /// decision, so it is one function.
  ///
  /// Returns null — having logged which half failed — when the peripheral
  /// exposes no known framed service, or is missing a required characteristic.
  /// Both callers treat that as a failed connect.
  ///
  /// It does NOT touch the session itself — pinning stays at the caller. Note
  /// that `_FbpGattOps.discoverAndValidate` pins IMMEDIATELY, before
  /// `_connectGen5Official` reads the outcome, so a `notGen5` device is briefly
  /// pinned to what discovery actually found. That is harmless and deliberate:
  /// what it pins is the TRUE band, and the legacy route it falls back to
  /// re-discovers and re-pins the same entry before using it.
  Future<_DiscoveredBand?> _discoverBand(BluetoothDevice device) async {
    final services =
        await device.discoverServices().timeout(_serviceDiscoveryTimeout);
    // Pin the band from whichever registered service the peripheral exposes.
    // This drives the frame header/CRC, command envelope, ACK, and record
    // decode for the session.
    BluetoothService? svc;
    BandEntry? entry;
    for (final s in services) {
      // `str128`, not `str`: `str` is the SHORTEST form, so a SIG-assigned
      // service comes back as `180d` and never starts with a `0000180d`
      // prefix. WHOOP's uuids are 128-bit either way — see
      // `GattBandLink._find`, which had the live version of this bug.
      final u = s.uuid.str128;
      // [kFramedBands], for the same reason the scan filters on it: this
      // engine speaks a framed envelope and nothing else.
      for (final e in kFramedBands) {
        if (u.startsWith(e.servicePrefix)) {
          svc = s;
          entry = e;
          break;
        }
      }
      if (svc != null) break;
    }
    if (svc == null || entry == null) {
      _log('No known band service found on device (looked for: '
          '${kFramedBands.map((e) => "${e.servicePrefix}xxxx").join(", ")}).');
      return null;
    }
    BluetoothCharacteristic? find(String uuid) {
      final prefix = uuid.substring(0, 8);
      for (final c in svc!.characteristics) {
        // `str128` — see the service match above.
        if (c.uuid.str128.startsWith(prefix)) return c;
      }
      return null;
    }

    // WHICH characteristics a link must expose is registry data. Demanding
    // all four unconditionally is why `hr_sensor.dart` exists as a second
    // parallel BLE stack — a generic HRS device has ONE notify
    // characteristic and would abort here.
    final missing = [
      for (final u in entry.requiredCharacteristics)
        if (find(u) == null) u.substring(0, 8),
    ];
    if (missing.isNotEmpty) {
      _log('${entry.label}: missing required characteristic(s) '
          '${missing.join(", ")}.');
      return null;
    }
    // Non-null: `entry` came out of [kFramedBands].
    final gatt = entry.gatt!;
    return _DiscoveredBand(
      entry: entry,
      cmdTo: find(gatt.cmdTo),
      cmdFrom: find(gatt.cmdFrom),
      events: find(gatt.events),
      data: find(gatt.data),
      memfault: find(gatt.memfault),
    );
  }

  /// The gen4 bootstrap SET_CLOCK decision.
  ///
  /// NO GEN5 BAND REACHES THIS, by either connect route — and that is a
  /// property of `_bootstrapAfterRegistration`, not of how the connect was
  /// routed: it branches on `session.band.isGen5` and the gen5 arm returns
  /// after [_gen5ClockContract]. So a gen5 band that fell into `_doConnect`
  /// on a stale `gen4` hint still gets the gen5 contract, because discovery
  /// has pinned the true band before the branch is read.
  ///
  /// That is also where [BandEntry.setClockDriftGated] is honoured now:
  /// [_gen5ClockContract] gates on the hello timestamp at MILLISECOND
  /// resolution against a freshly sampled phone time, which is strictly
  /// better evidence than the whole-second `_clockRef` drift a flag test here
  /// could read. Re-testing the flag on this path would be dead code — it is
  /// false for every band that gets here.
  ///
  /// gen4 keeps the unconditional write it has always had: its flow is proven,
  /// and the WHOOP 5 bootstrap is where the evidence for gating lives. The
  /// phone-clock deferral still wins — while THIS phone is the suspect party,
  /// writing its wall clock onto a possibly-correct strap RTC corrupts the RTC
  /// and destroys the evidence.
  Future<void> _bootstrapSetClock(_Session session) async {
    if (_deferForClock) return;
    await setClock();
  }

  /// `GET_ADVERTISING_NAME(141)` with
  /// body `01` and the correlated 5 s await, sent after the clock step and
  /// before READY. (Never the gen4 advertising-name opcode on a gen5 link.)
  ///
  /// The command must OCCUR — and its await must COMPLETE — before READY, but
  /// the returned object/status/content is not a readiness gate: a null,
  /// failed or unsupported reply is logged and bootstrap continues. The name
  /// itself lands the way it always has, through the `strap_name` branch of
  /// the state absorber.
  Future<void> _readAdvertisingNameGen5(_Session session) async {
    if (!session.band.isGen5) return;
    final out = await _sendAwaited(
      Cmd.getCustomAdvertisingName,
      const <int>[revision1],
    );
    if (!out.written) {
      _log('[NAME] GET_ADVERTISING_NAME was never written — not a readiness '
          'gate; setup continues.');
      return;
    }
    final r = await out.response;
    if (r == null) {
      _log('[NAME] GET_ADVERTISING_NAME went unanswered — not a readiness '
          'gate.');
    } else if (!r.success) {
      _log('[NAME] GET_ADVERTISING_NAME status=${r.status} — not a readiness '
          'gate.');
    }
  }

  /// when hello says the band is charging, look
  /// up the battery pack it is sitting on, asynchronously, after setup.
  ///
  /// Never runs off-charger, never runs twice for one session, and is not
  /// awaited by anything: "a missing or invalid response must be logged and
  /// must **not** move the band out of READY".
  void _maybeStartBatteryPackFollowUp(_Session session) {
    if (!session.band.isGen5) return;
    // Same quarantine as the state publication: `charging` is body[5] of the
    // revision-1 map, so an unknown revision is no evidence the band is on a
    // charger and must not start the opcode-151 follow-up.
    if (_gen5Hello?.helloRevision != 1) return;
    if (_gen5Hello?.charging != true) return;
    if (session.batteryPackFollowUpStarted) return;
    session.batteryPackFollowUpStarted = true;
    unawaited(_runBatteryPackFollowUp(session));
  }

  /// The follow-up task itself: up to [kBatteryPackInfoAttempts] correlated
  /// `GET_BATTERY_PACK_INFO(151)` reads, [kBatteryPackInfoRetryDelay] apart.
  ///
  /// Session-owned like every other background task here — it checks
  /// [_sessionIsStale] before each attempt and after each wait, so a link that
  /// drops halfway through stops the loop rather than writing into a dead
  /// characteristic for another twenty seconds.
  Future<void> _runBatteryPackFollowUp(_Session session) async {
    for (var attempt = 1; attempt <= kBatteryPackInfoAttempts; attempt++) {
      if (_sessionIsStale(session)) return;
      final out = await _sendAwaited(
        Cmd.getBatteryPackInfo,
        const <int>[],
        frameBuilder: (seq) =>
            cmdGetBatteryPackInfo(seq, profile: session.band),
      );
      final info = out.written
          ? (await out.response)?.fields['battery_pack_info']
              as BatteryPackInfoResponse?
          : null;
      if (info != null &&
          BatteryPackInfoGate.usable(
            identifier: info.identifier,
            name: info.name,
          )) {
        _batteryPack = info;
        _batteryPackTs = _wallSecs().round();
        _log('[PACK] battery pack identified on attempt $attempt/'
            '$kBatteryPackInfoAttempts: address=${info.identifier} '
            'name="${info.name}" attached=${info.attached} '
            'type=${info.batteryPackType?.name ?? info.batteryPackTypeRaw}.');
        return;
      }
      // "every unusable attempt is followed by the 5-second delay,
      // including the fifth". The band answers before it knows what it is
      // sitting on, so an early all-zero address is the expected reply.
      await Future.delayed(kBatteryPackInfoRetryDelay);
    }
    _log('[PACK] no usable GET_BATTERY_PACK_INFO reply after '
        '$kBatteryPackInfoAttempts attempts — nothing changes; the band stays '
        'READY.');
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
    // Re-arm what is APPLIED (the band's live toggles can silently die) and,
    // as a side effect, retry any transition that failed earlier — a no-op
    // when applied already equals desired. Serialised through the same pass as
    // every other live write; see [_reassertLive] for what is re-sent.
    // Only START a pass; never restale one in flight. A coalesced call marks
    // the running pass restale, and a failed transition retries while that
    // flag is set — a gen4 OFF bundle whose four writes each time out (8 s)
    // outlasts this 30 s tick, so a tick that restaled it would retry it
    // forever. The reassert flag alone is picked up by the next converged
    // pass, whoever starts it.
    _liveReassert = true;
    if (_liveRun == null) unawaited(_reconcileLive());
    // Battery is a DISPLAY value that moves over hours. Polling it on every
    // 30 s keep-alive tick was 2,880 radio round-trips a day for a handful of
    // real changes (issue #200).
    //
    // BUT it is also load-bearing for liveness: `_lastRx` only advances on an
    // inbound notification, and with no live stream armed the battery REPLY is
    // the only inbound traffic this link generates (LINK_VALID is a write; the
    // band is not known to answer it). Left purely on a 5-minute cadence, a
    // quiet link would sail past the 120 s fuse and get bounced — trading a
    // power win for a reconnect storm. So: poll on the slow cadence normally,
    // and force one as soon as silence approaches the fuse.
    unawaited(
      _pollBatteryIfDue(
        // With no live stream armed (Android background keeps live fully OFF)
        // the battery REPLY is the only inbound traffic this link generates,
        // and resume-time staleness is judged against
        // kLinkFreshnessNoStreamSeconds — so force the poll well under that
        // bar (~every other 30 s tick ⇒ sinceLastRx stays ≤ ~65 s). With a
        // stream armed, the original fuse/2 threshold stands.
        force: sinceLastRx.inSeconds >
            (liveEnabled
                ? kLivenessFuseSeconds ~/ 2
                : kNoStreamPollSilenceSeconds),
      ),
    );
    // Cheap retry hook for a priority request that failed earlier: a no-op
    // whenever the link already sits at the wanted interval.
    unawaited(_applyLinkPriority());
  }

  DateTime? _lastBatteryPollAt;

  /// Last LINK_VALID heartbeat actually sent — drives the backgrounded 60 s
  /// stretch in the 10 s heartbeat timer above.
  DateTime? _lastLinkValidAt;

  /// Ask the band for its battery level, at most once per
  /// [kBatteryPollIntervalSeconds].
  ///
  /// The stamp moves only after the write actually goes out, so a failed write
  /// does not buy five minutes of silence — and [getBattery] shares this path
  /// so the read AppState does right after connecting isn't immediately
  /// followed by a duplicate from the first keep-alive tick.
  Future<void> _pollBatteryIfDue({bool force = false}) async {
    final last = _lastBatteryPollAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last).inSeconds <
            kBatteryPollIntervalSeconds) {
      return;
    }
    // KNOWN DEVIATION from the pinned idle contract (no idle polling loop —
    // battery updates
    // come from band events): this poll and the 6 h clock re-verify are kept
    // deliberately, as LIVENESS probes on stacks that silently drop
    // notifications, not as data sources — hello + BATTERY_LEVEL events are
    // the data path. Revisiting both is tracked as an open conformance task;
    // removing them changes dead-link detection, so it is not done as a
    // drive-by here.
    // Correlated but deliberately NOT awaited by this caller: the
    // battery level is a display value, and both call sites — the keep-alive
    // tick and `getBattery()` on the session-open path — only ever needed the
    // write to have gone out. Blocking either for up to five seconds on a
    // strap that ignores the poll would trade a cosmetic value for a slower
    // connect. What the correlation buys is the log line below: an unanswered
    // poll on the link whose ONLY inbound traffic is this reply is exactly the
    // liveness signal the keep-alive cares about.
    //
    // Write failures are swallowed and reported as false. Stamping regardless
    // would buy five minutes of silence off a write that never left the phone.
    final out = await _sendAwaited(Cmd.getBatteryLevel, const []);
    if (!out.written) return;
    // The stamp belongs to the WRITE, so a strap that never answers does not
    // turn the poll into a five-second-per-tick retry loop.
    _lastBatteryPollAt = DateTime.now();
    unawaited(out.response.then((r) {
      if (r == null) {
        _log('[BATTERY] GET_BATTERY_LEVEL went unanswered — the link produced '
            'no inbound traffic for this poll.');
      }
    }));
  }

  /// Trigger a historical offload, floored by [BackfillPolicy] (manual /
  /// autoContinue are never floored). Re-arms the drain so a fresh HISTORY_COMPLETE
  /// is awaited. Used by the periodic timer, continuation, and the public sync API.
  /// Returns true when an offload was actually requested (false → floored or not
  /// connected), so event-driven callers know whether to await a sync report.
  Future<bool> _triggerBackfill(
    BackfillTrigger trigger, {
    bool fromMarkerHandler = false,
  }) async {
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
    // Spend the floor OPTIMISTICALLY so two triggers racing into the await
    // below can't both slip past `shouldRun`, then hand it back if the refresh
    // asked the strap for nothing. Without the hand-back, a refresh deferred
    // for a suspect clock bought the next attempt a full backfill interval of
    // silence — so a phone that corrected itself seconds later still sat
    // blocked, which is exactly the window the deferral is short enough to
    // ride out.
    final floorBefore = _lastBackfillAt;
    _lastBackfillAt = _wallSecs();
    final sent = await _startHistoricalRefresh(
      trigger: trigger,
      reason: trigger.name,
      refreshRange: true,
      fromMarkerHandler: fromMarkerHandler,
    );
    if (!sent) _lastBackfillAt = floorBefore;
    return sent;
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
  ///
  /// Returns whether `SEND_HISTORICAL_DATA` actually went out. Callers use it to
  /// decide whether the attempt was worth spending a rate-limit floor on — a
  /// refresh that dropped out at one of the gates below asked the strap for
  /// nothing, so it must not buy the next real attempt fifteen minutes of
  /// silence.
  /// [fromMarkerHandler] marks the one caller that runs INSIDE the serialized
  /// marker handler (the auto-continue decision at HISTORY_COMPLETE): it must
  /// not wait for [_historyMarkerInFlight] — that is its own future — but its
  /// position already guarantees the handler is past every controller-mutating
  /// await.
  Future<bool> _startHistoricalRefresh({
    required BackfillTrigger trigger,
    required String reason,
    bool refreshRange = true,
    bool fromMarkerHandler = false,
  }) async {
    // SERIALIZED LIFECYCLE: the previous task must be QUIESCENT before any
    // trigger may start the next one — its task-ending abort delivered (or
    // given up), and its marker handler out of any parked commit. Otherwise
    // range/opcode 22 goes out while the band is still being told to abandon
    // the previous task, or an old commit failure re-buffers the old task's
    // rows under the new one. Every waiter resumes on the same turn and the
    // claim below is synchronous, so the first one through takes the task and
    // the rest fall out at the already-transmitting guard: at most ONE next
    // task.
    if (_historyAbortInFlight != null || _historyMarkerInFlight != null) {
      _log('[SYNC] refresh($reason) — waiting for the previous history '
          'task\'s abort/handler to finish before starting a new one.');
    }
    await _awaitHistoryLifecycleQuiescence(
      includeMarkerHandler: !fromMarkerHandler,
    );
    final d = _drain;
    final session = _session;
    if (session?.connected != true || d == null) return false;
    // Terminal `Stuck`: no same-session retry —
    // continuation comes from a later connection, scheduler tick or explicit
    // trigger. Every in-session trigger routes through here — periodic
    // backfill, foreground/manual resync, auto-continue and the backfill
    // continuation loop — so refusing here closes all of them at once. The
    // FIRST drain of a fresh session is untouched: the latch lives on the
    // session object, so a reconnect clears it.
    if (session!.historyStuckActive) {
      session.stuckRefreshesRefused++;
      if (session.stuckRefreshesRefused == 1) {
        _log(
          '[SYNC] refresh($reason) refused — history is terminal (Stuck) for '
          'this connection; the band keeps its checkpoint until the next one.',
        );
      }
      return false;
    }
    if (_offloadActive && !d._complete) {
      _log(
        '[SYNC] refresh($reason) dropped — strap is already transmitting history.',
      );
      return false;
    }
    // A commit that FAILED after its task was ENDED BY ABORT re-buffered that
    // task's rows into this shared controller (the quiescence wait above
    // guarantees the restore has happened by now, not mid-claim). They were
    // never ACKed, so the band re-delivers them under this task's own
    // bursts — discard them rather than let them ride into this task's first
    // commit as data it never received. The discard poisons the (empty) open
    // burst; this task's first HISTORY_START clears that latch.
    //
    // Deliberately scoped to an abort-ended task: a NORMALLY completed task
    // whose tail commit failed keeps its buffer on purpose (see the
    // HistoryComplete tail-commit handling) — those rows re-attempt on the
    // next commit, exactly as documented there.
    if (session.historyTaskEnded &&
        (d.bufferedRecords > 0 || d.bufferedArchives > 0)) {
      _log(
        '[SYNC] refresh($reason) — discarding the aborted previous task\'s '
        '${d.bufferedRecords} record(s) + ${d.bufferedArchives} archive(s) '
        'of leftover un-ACKed buffer before starting a new task; the band '
        're-delivers them.',
      );
      d.discardOpenChunk();
    }
    // TASK BOUNDARY: this claim is the start of a genuinely new history task
    // (the guards above have refused every same-task re-entry), so the burst
    // validation-failure counter starts fresh HERE — before opcode 22 — and
    // nowhere else, the previous task's waiters are superseded with their
    // recorded outcome, and the controller re-arms — one call, so the
    // outcome snapshot can never be ordered after the reset. Doc 05: a later
    // task must never inherit the previous task's failure slack. The
    // previous task's terminal latch lifts for the same reason: ITS
    // stragglers had to stay inert, but this task's markers are live traffic.
    d.startFreshTask();
    // The previous task's terminal latch, in case this claim never becomes a
    // task (deferred for clock, or the SEND_HISTORICAL_DATA write fails) —
    // then it must go back so that task's stragglers stay inert instead of
    // re-arming the idle watchdog under the current generation.
    final endedBeforeClaim = session.historyTaskEnded;
    session.historyTaskEnded = false;
    // Doc 05: the new task has no active burst until the strap's first
    // HISTORY_START — until then a HISTORY_END is a duplicate and data
    // packets are dropped (gen5).
    _historyAwaitingFirstStart = true;
    // Claiming IS the generation bump: from here, leftovers of any previous
    // task (queued frames, parked continuations) are provably stale.
    _historyTaskGen++;
    final taskGen = _historyTaskGen;
    // True once this claim is no longer the engine's live task — either the
    // link was replaced or a terminal (idle watchdog above all) ended the task
    // while this method was parked on an await. A stale claim must simply
    // stop: the state it would "clean up" belongs to someone else now.
    bool claimStale() => _sessionIsStale(session) || _historyTaskGen != taskGen;
    _setOffloadActive(true);
    if (refreshRange) {
      _log('[SYNC] refresh($reason) — polling GET_DATA_RANGE before 0x16.');
      await _sendGetDataRange(owner: session);
      // INIT spaces commands by ~120 ms; keep the same cadence here so the band
      // has time to emit the range response before we request another drain.
      await Future.delayed(const Duration(milliseconds: 120));
      if (claimStale()) return false;
    }
    // Data-safety gate: never drain-and-trim history under an untrustworthy phone
    // clock. Poll the strap RTC and compare; if the phone clock looks slow (strap
    // plausible but > 1 day ahead), DEFER — draining now would drop the strap's
    // real records as "future" and the ACK would trim them off the band forever.
    // The strap retains everything; we drain on a later refresh once the clocks
    // agree (the phone's clock almost always self-corrects via NTP). SET_CLOCK is
    // deliberately NOT issued here — pushing the strap back to the slow phone
    // would corrupt a correct RTC (see ClockPolicy.phoneClockSuspect).
    await _readClock();
    if (claimStale()) return false;
    if (_deferForClock) {
      _clockPausedOffloads++;
      _log(
        '[SYNC] refresh($reason) DEFERRED — phone clock appears wrong relative '
        'to the strap RTC; not draining history until they agree '
        '(deferred_total=$_clockPausedOffloads).',
      );
      // The claim never became a task (no opcode 22): restore the idle
      // marker/data handling — nothing is awaiting a HISTORY_START — and
      // hand the previous task's terminal latch back.
      session.historyTaskEnded = endedBeforeClaim;
      _historyAwaitingFirstStart = false;
      _setOffloadActive(false);
      return false;
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
      if (claimStale()) return false;
    }
    _log('[SYNC] refresh($reason) — sending SEND_HISTORICAL_DATA.');
    // `_send` swallows write failures and reports them as false. Claiming
    // success anyway leaves the strap with no request, `_offloadActive` stuck
    // true — so later refreshes bounce off the "already transmitting" guard —
    // and both rate-limit floors spent on a command that never left the phone.
    if (!await _sendHistoricalData(owner: session)) {
      // A claim that went stale UNDER the write must not clear the state the
      // replacement task now owns.
      if (!claimStale()) {
        session.historyTaskEnded = endedBeforeClaim;
        _historyAwaitingFirstStart = false;
        _setOffloadActive(false);
      }
      return false;
    }
    _lastHistoricalSendAt = _wallSecs();
    return true;
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
          if (frame.decodable) {
            _onFrame(role, frame, session);
          } else if (frame.valid) {
            // Both CRCs pass but the frame revision is one this decoder does
            // not understand, so packetType/seq/opcode sit at unknown offsets:
            // routing it would read a BODY byte as the opcode and dispatch on
            // it, silently, with no CRC failure to point at. Counted apart
            // from CRC corruption so a firmware revision bump is loud.
            _frameRevRejectsTotal++;
            // ARCHIVE, don't drop. These are intact bytes from a firmware we
            // don't speak yet — exactly what raw_archive is for. Dropping them
            // while still ACKing the burst let the band trim records that
            // existed nowhere. The counter is forensic only (its offset is a
            // guess under an unknown revision); raw_archive keys on the hex.
            //
            // Only while an offload is running: that is the only window where
            // an ACK can make the band delete these bytes, and we cannot tell a
            // record from a 100 Hz live frame under an unknown revision —
            // archiving those (raw_archive is never pruned) would bloat the DB
            // exactly the way live frames are kept out of raw_records for.
            if (_offloadActive) {
              _archiveHistoricalFrame(
                frame,
                _counterFromInner(frame.inner),
                reason: 'undecodable_frame_rev',
              );
            }
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
            // The fallback is an input to the desired live state: drop an
            // applied IMU bundle now rather than on a keep-alive tick that
            // returns early for the whole of an offload.
            unawaited(_reconcileLive());
          }
        }
      }),
    );
  }

  /// Collect the OPTIONAL Memfault characteristic's bytes as diagnostics.
  /// The official client persists/uploads whatever the strap volunteers here
  /// and sends nothing to solicit it; this app only counts
  /// what arrived (surfaced in [offloadSnapshot]) — the channel is never
  /// parsed, never required, and never a readiness input.
  Future<void> _subscribeMemfault(
    _Session session,
    BluetoothCharacteristic c,
  ) async {
    await c.setNotifyValue(true).timeout(_notifySetupTimeout);
    session.subs.add(
      c.onValueReceived.listen((chunk) {
        if (_session != session || !session.connected) return;
        _onMemfaultChunk(chunk);
      }),
    );
  }

  /// The ONE Memfault accounting path — the notification listener above and
  /// the test seam both land here, so the liveness stamp and the counters
  /// cannot drift apart. A chunk is real inbound traffic on this link: it
  /// proves liveness the same as any other notification, so the
  /// staleness/watchdog clock advances.
  void _onMemfaultChunk(List<int> chunk) {
    _lastRx = DateTime.now();
    _memfaultChunks++;
    _memfaultBytesTotal += chunk.length;
    if (_memfaultChunks == 1) {
      _log('[MEMFAULT] strap volunteered its first crash/diagnostic '
          'chunk (${chunk.length} B) — collected only.');
    }
  }

  /// Feed one Memfault chunk through the real accounting path — the liveness
  /// stamp and counters live behind a radio otherwise.
  @visibleForTesting
  void debugIngestMemfaultChunk(List<int> chunk) => _onMemfaultChunk(chunk);

  /// Memfault (0007) traffic counters — diagnostics only.
  int _memfaultChunks = 0;
  int _memfaultBytesTotal = 0;

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
      final reason = session.device.disconnectReason;
      _feedReconnectDetectors(
        timedOut: isTimeoutDisconnect(reason?.description),
      );
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
    // callback (we are inside one of the very subscriptions being cancelled);
    // the disconnect() teardown issues is a no-op on an already-dead link.
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

  /// Feed an UNINTENTIONAL disconnect to the cross-reconnect detectors. The
  /// detectors self-reset when a disconnect does not match their quick-timeout
  /// pattern.
  ///
  /// [timedOut] is the platform's own verdict (see [isTimeoutDisconnect]) and
  /// used to be hardcoded `true` — which made every ordinary drop look like a
  /// timeout to both detectors. `_bondTime` is set unconditionally in the
  /// connect setup, not just on Android, so that hardcoding let two unremarkable
  /// disconnects inside 8 s of setup latch the re-pair guide on any platform.
  void _feedReconnectDetectors({required bool timedOut}) {
    final now = DateTime.now();
    final sinceArm = _armTime == null
        ? null
        : now.difference(_armTime!).inMilliseconds / 1000.0;
    final sinceBond = _bondTime == null
        ? null
        : now.difference(_bondTime!).inMilliseconds / 1000.0;
    if (_marginalRadio.connectionEnded(
      wasArmed: liveEnabled,
      secondsSinceArm: sinceArm,
      timedOut: timedOut,
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
      timedOut: timedOut,
    )) {
      state.needsRepairGuide = true;
      onState(state);
      _log('[RECONNECT] post-bond loop tripped — surfacing re-pair guide.');
    }
  }

  /// Test seam: the disconnect path's detector feed, with the bond timestamp the
  /// connect setup would have stamped. Both detectors live behind a real radio,
  /// so without this the only coverage possible was of the pure detectors —
  /// never of the engine wiring that decides what counts as a timeout.
  @visibleForTesting
  void debugFeedDisconnect({required bool timedOut, DateTime? bondedAt}) {
    _bondTime = bondedAt ?? DateTime.now();
    _feedReconnectDetectors(timedOut: timedOut);
  }

  /// A command reply is the direct contradiction of the re-pair guide: the band
  /// decrypted one of our commands and answered it, so encryption is not
  /// blocking traffic and there is nothing to re-pair.
  ///
  /// `needsRepairGuide` was set-only in practice. Its one clear sat inside
  /// [refreshAutoReconnectPause], behind `if (!state.autoReconnectPaused)
  /// return false` — and a single refused bond, or a post-bond loop trip, never
  /// pauses auto-reconnect. `state` is one long-lived [DeviceState], so a
  /// working, syncing band kept telling the user to forget the bond and re-pair
  /// for the rest of the process.
  ///
  /// Keyed on the round-trip rather than on `createBond()` succeeding, because
  /// the bond succeeding does not prove the band accepts commands while a reply
  /// does — and the connect setup issues GET_CLOCK immediately after the bond,
  /// so on Android the evidence lands in the same setup either way.
  /// [PostBondTimeoutLoopDetector] trips once and latches, so it is reset here
  /// too: otherwise the guide could be cleared but never legitimately re-raised.
  void _clearRepairGuideOnCommandReply() {
    if (!state.needsRepairGuide) return;
    state.needsRepairGuide = false;
    _postBondLoop.reset();
    onState(state);
    _log('[RECONNECT] band answered a command — clearing the re-pair guide.');
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

  /// The initial bond-state read, applied at the [GattBootstrapOps] seam in
  /// `_connectGen5Official` — the same reason as the two above, at the one
  /// platform stream await the gen5 bootstrap adds. Short because it is a
  /// CACHED OS lookup, not a radio round trip: the bond itself is
  /// `createBond()`, which the plugin bounds at 90 s.
  static const Duration _bondStateTimeout = Duration(seconds: 5);

  /// [owner] pins the write to ONE session. Without it a write queued by a
  /// long-parked drain (a big commit, then up to ~25 s of ACK retries) lands on
  /// whatever session happens to be current when the write chain reaches it —
  /// i.e. an OLD connection's batch-ACK, with a re-used sync seq, written onto
  /// a BRAND NEW link. Every offload write passes its owning session.
  /// [allowDangerous] is the ONE audited opt-out of the block below. It exists
  /// for `enableGen5DeepBuffers`, whose SET_FF_VALUE frames are in
  /// `dangerousCmds` on purpose (persistent config writes) and are sent only
  /// behind an explicit user opt-in with a restore-defaults companion. Pass it
  /// nowhere else without the same justification.
  Future<bool> _write(
    Uint8List raw, {
    _Session? owner,
    bool allowDangerous = false,
  }) {
    final session = _session;
    // The dangerous-opcode block lives HERE, at the one write every command
    // funnels through, not only in `_send`: nine call sites build their own
    // frame and hand it straight to `_write`, so a `_send`-only guard was
    // bypassable BY CONSTRUCTION rather than by an audited opt-out. Now the
    // bypasses are one named parameter at one reviewed call site, and
    // FORCE_TRIM (whose full-erase form is two 0xFEFEFEFE args), REBOOT and
    // POWER_CYCLE cannot leave this engine by any path.
    final opcode =
        allowDangerous ? null : _opcodeOfFrame(raw, session?.entry ?? kWhoopGen4);
    if (opcode != null &&
        (dangerousCmds.contains(opcode) || OpcodeSafety.isDestructive(opcode))) {
      _log('REFUSED dangerous opcode 0x${opcode.toRadixString(16)} at _write');
      return Future.value(false);
    }
    return _writeChain.add<bool>(() async {
      try {
        // Readiness and ownership are checked BEFORE the test seam, not after,
        // so a hooked write rejects a stale-session ACK exactly like the real
        // one. A seam that skips the guards it is meant to be standing in for
        // makes every test that relies on it prove the wrong thing.
        if (session == null || !session.connected || session.closing) {
          _log('write skipped: link not ready.');
          return false;
        }
        if (owner != null && !identical(owner, session)) {
          _log('write skipped: it belongs to a session that is no longer live.');
          return false;
        }
        final hook = debugWriteHook;
        if (hook != null) return await hook(raw);
        final cmd = session.cmdTo;
        if (cmd == null) {
          _log('write skipped: link not ready.');
          return false;
        }
        // allowLongWrite: the rich SET_ALARM_TIME frame is 32B — the only write
        // that exceeds the 20B ATT limit of a default (23B) MTU. Without a long
        // write, flutter_blue_plus throws "value > mtu-3" if the negotiated MTU
        // never rose, and _send would swallow the alarm silently. Long writes are
        // a no-op for the small (<=20B) frames every other command uses.
        await cmd
            .write(raw, withoutResponse: false, allowLongWrite: true)
            .timeout(_writeTimeout);
        return true;
      } on TimeoutException {
        _log('write timeout: no GATT response in ${_writeTimeout.inSeconds}s.');
        return false;
      } catch (e) {
        _log('write error: $e');
        return false;
      }
    });
  }

  /// The command opcode carried by an already-framed outbound write, or null
  /// when [raw] is too short to carry one. Where the opcode sits is registry
  /// data ([BandEntry.frameOpcodeIndex] = the band's header length plus its
  /// inner-payload opcode offset), not a WHOOP literal.
  ///
  /// This feeds the dangerous-opcode block, so a band whose entry gets this
  /// wrong reads the wrong byte and the block stops protecting it — see the
  /// guard's own test.
  static int? _opcodeOfFrame(Uint8List raw, BandEntry entry) {
    final i = entry.frameOpcodeIndex;
    return i < raw.length ? raw[i] : null;
  }

  /// Retry schedule for the HISTORY_END batch ACK (pure; see ble_state.dart).
  final AckRetryPolicy ackRetryPolicy = const AckRetryPolicy();

  /// VERIFIED batch-ACK write: retry a few times with short backoff. Returns
  /// false only after every attempt failed — the caller must then bounce the
  /// link (the chunk is already durably committed; the band re-delivers it next
  /// session and the decoded store dedups by REPLACE).
  /// [taskGen] is the history-task generation the ACK belongs to — a retry
  /// must stop the moment that task ends (abort boundary), or a parked loop
  /// would go on writing an ended task's token between the abort and the next
  /// task's frames.
  Future<bool> _writeAckVerified(
    Uint8List ack,
    _Session session, {
    required int taskGen,
  }) async {
    var failures = 0;
    bool stale() => _sessionIsStale(session) || _historyTaskGen != taskGen;
    while (true) {
      if (stale()) return false;
      if (await _write(ack, owner: session)) return true;
      failures++;
      if (!ackRetryPolicy.shouldRetry(failures)) return false;
      _log('[SYNC] batch-ACK write failed (attempt $failures/'
          '${ackRetryPolicy.maxAttempts}) — retrying.');
      await Future.delayed(ackRetryPolicy.delayFor(failures));
      if (stale()) return false;
    }
  }

  /// The dangerous-opcode hard block, shared by [_send] and [_sendAwaited] so
  /// an awaited command can never take a route around it.
  bool _refuseDangerousOpcode(int opcode) {
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
      return true;
    }
    return false;
  }

  /// [owner] pins the write to one session (see [_write]) — offload commands
  /// issued from a long-parked task start pass theirs so a claim that went
  /// stale mid-await cannot put its command onto a replacement link.
  Future<bool> _send(int opcode, List<int> payload, {_Session? owner}) async {
    if (_refuseDangerousOpcode(opcode)) return false;
    final frame = buildCommand(
        _seq.nextLive(), opcode, payload, _session?.band ?? BandProfile.gen4);
    final ok = await _write(frame, owner: owner);
    if (!ok) {
      _log('WRITE FAILED for opcode 0x${opcode.toRadixString(16)} — '
          'command not delivered.');
    }
    return ok;
  }

  /// Send a command and wait for ITS reply.
  ///
  /// The observer is installed BEFORE the write ("Ordering"), so a response
  /// that beats the write's own completion still finds a waiter. Correlation is
  /// strict: only a reply echoing this exact sequence AND opcode satisfies the
  /// await; anything else leaves it to expire. The timeout is applied exactly
  /// once and NOTHING is resent — retry belongs to the calling state machine
  /// ("Timeouts and retries"), because several commands mutate persistent state
  /// and a duplicate write after a slow-but-successful response is a real
  /// hazard.
  ///
  /// Awaits the WRITE and hands back whether it went out plus the still-pending
  /// response, so a caller can distinguish "we never asked" from "we asked and
  /// heard nothing" — different failures with different remedies — and so a
  /// caller that only needs the request to have left the phone (the battery
  /// poll) does not have to block on the reply. `response` completes null on a
  /// failed write and on timeout.
  ///
  /// [frameBuilder] is for commands whose frame comes from a protocol helper
  /// rather than a bare opcode+payload (the gen5 hello); it receives the
  /// allocated sequence so the correlation still holds.
  Future<({bool written, Future<CorrelatedResponse?> response})> _sendAwaited(
    int opcode,
    List<int> payload, {
    Duration timeout = CommandAwaiter.defaultTimeout,
    Uint8List Function(int seq)? frameBuilder,
  }) async {
    if (_refuseDangerousOpcode(opcode)) {
      return (written: false, response: Future<CorrelatedResponse?>.value());
    }
    final seq = _seq.nextLive();
    final pending = _awaiter.register(seq, opcode, timeout: timeout);
    final frame = frameBuilder?.call(seq) ??
        buildCommand(seq, opcode, payload, _session?.band ?? BandProfile.gen4);
    if (!await _write(frame)) {
      pending.cancel();
      _log('WRITE FAILED for opcode 0x${opcode.toRadixString(16)} — '
          'command not delivered.');
      return (written: false, response: pending.response);
    }
    return (written: true, response: pending.response);
  }

  // Offload commands whose PAYLOAD (not just the frame envelope) is
  // band-specific: gen4 sends a single 0x00, gen5 sends an EMPTY payload.
  // Read from [BandWireCommands.offloadBody] so every offload trigger — the
  // initial handshake, periodic backfill, manual refresh, and retry — emits the
  // right one. (_send already frames with the session's BandProfile.)
  List<int> get _offloadPayload =>
      (_session?.entry ?? kWhoopGen4).commands.offloadBody;
  /// IMU_SET_DATA_STREAM for the session's band. gen5 wants a leading revision
  /// byte where gen4 sends a bare on/off byte; protocol's `cmdToggleImu` owns
  /// that split. Sent the gen4 body, a gen5 strap reads the state from past the
  /// end of the body, the stream never arms, and step calibration stays at 0.
  ///
  /// [owner] pins the write to one session exactly as [_send] does: the live
  /// reconciler issues this from a multi-write bundle that can straddle a
  /// teardown, and the gen4 tail must not land on a replacement gen5 link.
  Future<bool> _sendToggleImu(bool on, {_Session? owner}) => _write(
        cmdToggleImu(_seq.nextLive(), on,
            profile: (owner ?? _session)?.band ?? BandProfile.gen4),
        owner: owner,
      );

  Future<bool> _sendGetDataRange({_Session? owner}) =>
      _send(Cmd.getDataRange, _offloadPayload, owner: owner);
  Future<bool> _sendHistoricalData({_Session? owner}) =>
      _send(Cmd.sendHistoricalData, _offloadPayload, owner: owner);

  /// Ask the strap to prompt more frequent history syncs around a wake time.
  ///
  /// Defaults are the pinned Smart Alarm values: interval **180 s**, duration
  /// **7200 s** (2 h), i.e. the wire body `02 b4 00 20 1c`. The wake window
  /// opens at `latest wake time - 2 hours`, which is why the duration
  /// matches it.
  ///
  /// The previous default was 61 s / 90 min — chosen only because gen5 refuses
  /// an interval of 60 or less, not because anything established it. A shorter
  /// interval means more wake/connect cycles for the same result; the pinned
  /// cadence is the one with evidence behind it.
  Future<void> applyHighFreqWakeWindow({
    required bool enabled,
    required DateTime? targetWake,
    Duration duration = const Duration(seconds: 7200),
    int intervalSeconds = 180,
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
    // Frame for the SESSION'S band. Built gen4-only, a gen5 strap got a header
    // length and checksum it cannot parse, so high-frequency sync never
    // engaged — while the flags below claimed it had. Only claim the mode when
    // the write actually landed.
    final ok = await _write(
      cmdEnterHighFreqSync(
        _seq.nextLive(),
        intervalSeconds: intervalSeconds,
        durationSeconds: duration.inSeconds,
        profile: _session?.band ?? BandProfile.gen4,
      ),
    );
    if (!ok) {
      _log('[SYNC] HighFreq enter ($reason) write FAILED — mode NOT claimed.');
      return;
    }
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
    await _write(cmdExitHighFreqSync(_seq.nextLive(),
        profile: _session?.band ?? BandProfile.gen4));
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
    String? deviceFamily,
  }) async {
    final hasArchives = archives != null && archives.isNotEmpty;
    if (raws.isEmpty && trimTokenHex == null && !hasArchives) return;
    // Stamp the family HERE, from the link that produced the chunk: this is the
    // last point that knows it. Callers may override (tests / a replay that
    // knows better); null falls back to the live link, which is itself null
    // before discovery has pinned one.
    await onCommitBatch!(raws, samples, trimTokenHex,
        archives: archives, deviceFamily: deviceFamily ?? linkDeviceFamily);
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
      isBurstCountMember: isBurstCountMemberType(pt),
      offloadActive: _offloadActive,
    );
    switch (route) {
      case FrameRoute.serializedQueue:
        _enqueueOffloadFrame(frame, session);
      case FrameRoute.immediateAndCount:
        // Process inline first (unchanged behaviour: wrist/battery/alarm and
        // console text must not wait behind an offload commit), then enqueue
        // the SAME frame so only its burst COUNT is applied in arrival order,
        // in the burst window the band sent it in. See [FrameRoute].
        _processImmediateFrame(frame);
        _enqueueOffloadFrame(frame, session);
      case FrameRoute.immediate:
        _processImmediateFrame(frame);
    }
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
      // Same doc-05 rule as the queued path: data packets before the task's
      // first HISTORY_START are the previous task's stragglers — drop them
      // (un-ACKed, the band re-delivers) instead of ingesting them into a
      // burst window that has not opened.
      if (_dropPreStartHistory) return;
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
      // NOTE: the burst COUNT for this frame is NOT applied here. Events,
      // console logs and puffin wrappers are count members but they arrive on a different characteristic than the
      // data frames, so counting them at notification time put them in
      // whichever burst window happened to be open rather than the one the
      // band sent them in. The count now rides the serialized queue at this
      // frame's arrival position — see [FrameRoute.immediateAndCount] and
      // [_countQueuedBurstMember]. Event PROCESSING stays right here: nothing
      // about wrist/battery/alarm handling may wait on an offload commit.
      _log('[EVENT] ${_innerHex(frame.inner)}');
      // The profile matters: protocol keeps the gen5-scoped event bodies
      // (29/100/109/123) numeric and un-decoded on a gen4 link.
      final e = parseEvent(
        frame.inner,
        profile: _session?.band ?? BandProfile.gen4,
      );
      if (e != null) {
        _handleEventInfo(e);
        onEvent?.call(e.eventId, e.tsEpoch, _innerHex(frame.inner));
      }
    }
    final entry = _session?.entry ?? kWhoopGen4;
    final band = entry.wire!;
    final decoded = _maybeAugmentClockEpoch(
      frame,
      decodeFrame(frame, profile: band),
    );
    // Debug-visibility ONLY (never persisted, never gated on): log the strap's
    // own console text (decoded by protocol's `parseConsoleLog`, wired into
    // `decodeFrame` above). Per-band because the value of the noise is — see
    // [BandEntry.logsConsoleOutput].
    if (entry.logsConsoleOutput && decoded.kind == 'console_log') {
      _log('[CONSOLE gen5] idx=${decoded.fields['record_index']} '
          'ts=${decoded.fields['ts_epoch']}: ${decoded.fields['text']}');
    }
    _absorbState(decoded);
  }

  void _enqueueOffloadFrame(Frame frame, _Session session) {
    if (_session != session || !session.connected) return; // stale session
    _offloadFrames.add((frame: frame, taskGen: _historyTaskGen));
    // A straggler historical frame from a task that ended through the abort
    // boundary must not re-raise the offload — that is exactly the "duplicate
    // terminals hold the offload open" wedge.
    if ((_offloadActive || frame.packetType == PacketType.historicalData) &&
        !session.historyTaskEnded) {
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
        //
        // Only REAL drain progress counts: event/console count members ride
        // this queue too, and gen5's console chatter alone could otherwise
        // keep a genuinely stalled offload alive past the timeout forever.
        // Stale-generation leftovers count for nothing here either.
        if (batch.any((e) =>
            e.taskGen == _historyTaskGen &&
            e.frame.packetType == PacketType.historicalData)) {
          _armIdleWatchdog();
        }
        for (final entry in batch) {
          if (_sessionIsStale(session)) return;
          final frame = entry.frame;
          // An OLD task's queued frames must never be processed as part of a
          // new one: they were counted/collected for a burst window that is
          // over, and the band re-delivers anything un-ACKed anyway.
          // HISTORY_COMPLETE is no exception — a stale COMPLETE reaching the
          // handler would record a SUCCESS terminal and run the post-offload
          // policy for a task that ended in an abort (or worse, complete a
          // replacement task it never belonged to). The awaitComplete()
          // waiter it used to release is resolved at the abort boundary
          // instead (DrainController.onTaskTerminal).
          if (entry.taskGen != _historyTaskGen) continue;
          if (frame.packetType == PacketType.metadata) {
            // Published while awaited so a task start can wait out a handler
            // parked mid-commit — see _awaitHistoryLifecycleQuiescence.
            final handling = _handleSyncMarker(frame, session);
            _historyMarkerInFlight = handling;
            try {
              await handling;
            } finally {
              if (identical(_historyMarkerInFlight, handling)) {
                _historyMarkerInFlight = null;
              }
            }
          } else if (frame.packetType == PacketType.historicalData) {
            // Doc 05: the processor drops data packets until the task's first
            // HISTORY_START — a straggler record from the previous task must
            // not be ingested (or tallied) into the new one. Un-ACKed, so the
            // band re-delivers it under a real burst.
            if (_dropPreStartHistory) continue;
            _ingestHistoricalFrame(frame);
          } else {
            // A count member that was already processed inline
            // ([FrameRoute.immediateAndCount]) and is here only to have its
            // burst count applied in arrival order.
            _countQueuedBurstMember(frame);
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

  /// Apply the burst count for one non-data count member (type 48/50/53/54/55)
  /// that has already been processed inline, now that the serialized queue has
  /// reached its arrival position.
  ///
  /// This is the ONLY place these families increment the burst count. The band
  /// reports `expected_count = data_pkt_cnt + event_pkt_cnt` for the frames it
  /// transmitted between HISTORY_START and HISTORY_END; counting here — behind
  /// the same queue that carries the data frames and both markers — is what
  /// makes our tally cover the same window. A member counted at notification
  /// time instead could land before its burst's HISTORY_START (where `rearm()`
  /// wipes it) or after its HISTORY_END had already validated, which is how a
  /// burst carrying several of them went permanently short by ~4 frames
  /// against `expected=16, actual=12, breakdown={V18=12}` on a real strap.
  void _countQueuedBurstMember(Frame frame) {
    final d = _drain;
    if (d == null) return;
    final pt = frame.packetType;
    if (pt == PacketType.consoleLogs) {
      d.onBurstConsole();
      return;
    }
    // Type 48 events and the battery-pack ("puffin") wrappers 53/54/55 all
    // count once each, on the band's event counter. The wrappers were counted
    // nowhere at all before the count gate landed: a retained capture has a
    // checkpoint of 24 ordinary packets plus three type-54 wrappers reported as
    // `expected = 27`, which fails 27/24 forever until they are counted.
    d.onBurstEvent();
    if (pt != PacketType.event) {
      _log('[SYNC] puffin wrapper type=$pt counted as a burst member');
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
  /// Set a historical frame aside in `raw_archive` — the never-pruned store for
  /// bytes this build could not fully turn into a [Sample].
  ///
  /// Routed through the drain when one is active so the write lands inside the
  /// SAME transaction as the batch commit (safe-trim invariant: nothing the
  /// band is told it may trim has been discarded).
  void _archiveHistoricalFrame(
    Frame frame,
    int counter, {
    required String reason,
  }) {
    final archive = ArchiveRecord(
      counter: counter,
      hex: _innerHex(frame.inner),
      packetType: frame.inner.isNotEmpty ? frame.inner[0] : 0,
      capturedAt: DateTime.now().millisecondsSinceEpoch,
      reason: reason,
    );
    final d = _drain;
    if (d != null) {
      d.onUndecodableRecord(archive);
    } else {
      unawaited(onArchiveRecord?.call(archive) ?? Future<void>.value());
    }
  }

  void _ingestHistoricalFrame(Frame frame) {
    final pt = frame.packetType;
    if (pt != PacketType.historicalData) return;
    // Where the record-version byte sits is registry data, not a literal.
    final vAt = (_session?.entry ?? kWhoopGen4).innerVersionOffset;
    final recType = frame.inner.length > vAt ? frame.inner[vAt] : -1;
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
    final wallNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final isGen5 = _session?.band.isGen5 ?? false;
    if (isGen5) {
      // gen5 (WHOOP 5): `parseGen5Historical` dispatches across all four real
      // gen5 historical-record kinds (v18 per-second summary, v20 optical/
      // v21 IMU/v26 PPG deep buffers — R22 opt-in only). Only v18 maps onto
      // the band-agnostic `Sample` type today; the deep buffers need their
      // own raw-buffer storage (a future db table), not a 1Hz Sample, so they
      // fall through to the undecodable archive below — that is honest
      // (correctly-identified-but-not-yet-stored), not a decode failure.
      //
      // WHAT THE v26 PPG BUFFER MAY NOT BECOME: vascular age, arterial
      // stiffness, a "PPG aging clock", or any pulse-morphology claim about a
      // blood vessel. this is not the v25 scar being reapplied — that one
      // killed rate/ratio derivations and morphology is a per-pulse shape, so
      // it gets its own refusal, and it fails for four independent reasons:
      //   1. sample rate. 24-50 Hz is ~12-25 samples per cardiac cycle,
      //      nowhere near enough to locate a dicrotic notch, and gen4's v25 is
      //      13-27 s bursts every ~20 min.
      //   2. multiplexing. v26's subChannel means one burst is several
      //      interleaved optical channels, not one signal, and 0.2% of records
      //      report a channel we don't know (protocol's `subChannelKnown` is
      //      the gate, and it returning null is the common failure).
      //   3. amplitude. the band re-tunes gain per record, and morphology IS
      //      amplitude-shape, so pulse shape is not comparable across records
      //      without a normalisation nobody has validated.
      //   4. physiology. the diastolic peak is frequently absent in older
      //      subjects — the exact population such a feature targets — and
      //      green-light wrist reflectance is the worst site and wavelength
      //      for morphology, with no explainable transfer to arterial stiffness.
      // the defensible uses of this waveform are internal and claim nothing
      // about a vessel: beat-detection quality, motion-artifact rejection,
      // corroborating the band's own RR intervals. build those, not a number.
      sample = decodeGen5HistoricalSample(frame.inner);
    } else if (recType != Record.r25 &&
        kKnownRecordVersions.contains(recType)) {
      // Every gen4 layout version protocol has a field map for — not just
      // v24/v12. v7/v9/v18 decode fine through the same chain and used to fall
      // through to `undecodable_rec_v*` purely because this branch never routed
      // them. gen5 also ships a v18 with a completely different layout; the
      // `isGen5` branch above claims it first, so this is gen4 only.
      //
      // v25 is EXCLUDED on purpose and keeps going to the archive.
      //
      // THE TIMESTAMP IS RIGHT AND THE GRAVITY VECTOR IS NOT. inner[7] is
      // monotonic and steps by exactly 1 s. But `_parseV25`'s accel — i16s at
      // inner[69/71/73], the only "validation" behind which is a mean |g| of
      // 0.97 sitting inside a 0.5-1.5 g window — is NOT an accelerometer.
      // MEASURED on all 28,395 v25 records in `whoop-4.db`:
      //
      //   * inner[73] (the "z" axis) takes THREE distinct values across 28,395
      //     records: 0, 1 and 256. inner[71] ("y") takes 17, one of which
      //     (2896) is 68% of them. No axis of a worn IMU does that.
      //   * inner[69] ("x") is the upper half of a little-endian f32 that
      //     starts at inner[67], which is why it is pinned near 0.94 g. |g|
      //     ≈ 0.97 is that constant, not a wrist.
      //   * 13,394 v25 seconds also have a v24 record for the SAME second.
      //     Against that real gravity vector: per-axis correlation 0.16 /
      //     0.22 / 0.06, and the median ANGLE between the two vectors is 83°
      //     — orthogonal, i.e. unrelated.
      //
      // A near-constant vector is exactly the "perfectly still wrist" this
      // file's `ax/ay/az` note refuses to fabricate, and van Hees immobility
      // is precisely what would consume it. So SLP-05's routing half is
      // REFUSED on the data, not deferred. Consistent with GATES.md §4a: the
      // 76-byte v25 inner is the same record as gen5's v26 — 24 × i16 of
      // waveform — so there is no room in it for a gravity vector, and what
      // lives at 69/71/73 is the waveform's tail and a constant.
      //
      // AND THERE IS NOTHING TO GAIN EITHER WAY. Of the 13,395 v25 seconds
      // that fall inside `decoded_onehz`'s retained range on that export,
      // 13,394 are ALREADY covered by a v24 record; exactly one is new in
      // 8.5 days. Recomputed over all 24 stored sleep windows, the observed
      // fraction (`sampled && hrNear`) moves +0.00 pp. The "1-5 pp lift"
      // SLP-05 sizes does not exist on real data.
      //
      // Worse, routing it here would be a REGRESSION: `_queueDecodedOneHz`
      // writes REPLACE on the rec_ts key, so a v25 record arriving for a
      // second a v24 record already holds would evict it — deleting that
      // second's HR, R-R, optical and thermal readings and leaving an
      // HR-less row behind. That is 49% of v25 records.
      //
      // The record genuinely has NO heart rate. Every byte and u16 offset was
      // scanned for anything in a bpm range with physiological drift across
      // 18k consecutive one-second pairs; the only matches are the packet type,
      // the timestamp's high bytes and a gravity high byte. What sits between
      // is a 24-slot raw waveform buffer spanning the full i16 range — the band
      // ships samples here and computes HR into the v24 records instead.
      //
      // So `_parseV25` reporting `hr: 0` is an honest absence, and the nullable
      // `hr` column (schema v43) that used to be the blocker is in place — the
      // blocker now is the accel, above. `undecodable_rec_v25` is therefore NOT
      // in `LocalDb.redrivableArchiveReasons` and must not be added: the bytes
      // stay archived, unpruned, whole, for a build that can actually read the
      // waveform (RESP-15/SD-15). Nothing is lost by leaving them there.
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
        _logHistoricalOptics(r);
        sample = Sample(
          tsEpoch: r.tsEpoch,
          counter: r.counter,
          hr: r.hr,
          rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
          // NULL, not 0: a decoder that emitted no gravity vector said the
          // accel is ABSENT, and 0 g is a reading no wrist can produce (which
          // is exactly why a run of them reads as a perfectly still one).
          ax: r.accelG.isNotEmpty ? r.accelG[0] : null,
          ay: r.accelG.length > 1 ? r.accelG[1] : null,
          az: r.accelG.length > 2 ? r.accelG[2] : null,
          spo2RedRaw: r.spo2RedRaw,
          spo2IrRaw: r.spo2IrRaw,
          // stored raw under the column it's always had. nothing reads it as a
          // temperature — that's what the deprecation is warning about.
          // ignore: deprecated_member_use
          skinTempRaw: r.skinTempRaw,
          // gen4 ambient-light ADC (u16 @inner[70]). Decoded on every
          // historical record since forever and thrown away here — this was
          // the ONLY hole left in SD-04: the column, the Sample field and the
          // write all exist, but the live drain never handed the value over,
          // so `ambient_raw` was NULL on every row the band ever delivered.
          // 0 is the ADC-ABSENT sentinel (records.dart emits `optical ? u16@70
          // : 0` for unconfirmed versions) and is mapped to NULL at the write
          // in `_queueDecodedOneHz` — do not "fix" it by zero-filling here.
          ambientRaw: r.ambientRaw,
          // Same field, same offset, same omission on this side: the record's
          // sub-second was decoded and thrown away here too.
          tsSubsec: r.tsSubsec,
        );
      }
    } else if (recType == Record.r10) {
      final r = parseR10Lite(frame.inner);
      if (r != null) {
        // R10 carries an R-R block, and this path used to drop it. The record
        // then committed as decoded — so it never reached raw_archive — and
        // the band was acked to trim it, which made those beats unrecoverable
        // rather than merely degraded. R10 carries no accel we map, so
        // ax/ay/az stay ABSENT (null) rather than becoming a still wrist.
        sample = Sample(
          tsEpoch: r.tsEpoch,
          counter: r.counter,
          hr: r.hr,
          rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
        );
      }
    }
    // FIRMWARE RESILIENCE: a historical record we could NOT decode (unknown/
    // unsupported version, or a known version whose decode failed) is ARCHIVED
    // durably rather than dropped — it used to fall into raw_records with a null
    // rec_ts and get pruned unseen, losing a future firmware's data forever. The
    // archive rides the SAME commit that runs before the batch-ACK, so nothing the
    // band trims has been discarded (safe-trim invariant intact).
    if (sample == null) {
      _archiveHistoricalFrame(
        frame,
        counter,
        reason: 'undecodable_rec_v$recType',
      );
      return;
    }
    // PLAUSIBILITY GATE + FRONTIER (RecordGate, shared with the detectors).
    // Drop records whose unix is implausible vs wall-clock and (when known) the
    // strap's own GET_DATA_RANGE window — a previous owner's wandering-clock
    // pollution. Records with no decodable ts are kept (can't gate them).
    // A rejected record is not BANKED and not counted — but its bytes are
    // archived (see below). Mixed bursts (some rows banked) may still ACK; a
    // drop-only burst must not — see TrimAckVerdict.blockedNoDurableProgress.
    // Past this point [sample] is non-null — undecodable records returned above.
    if (!_recordGate.admit(
      sample.tsEpoch,
      wallNow: wallNow,
      sessionOldestUnix: _sessionOldestUnix,
      sessionNewestUnix: _sessionNewestUnix,
    )) {
      // ARCHIVE, don't drop. A record we merely MISTRUST used to be written
      // nowhere at all, i.e. treated strictly worse than one we cannot parse —
      // and the batch-ACK then let the band trim those bytes away for good.
      // The archive rides the same pre-ACK transaction, so the bytes survive.
      // They are NOT re-timed later: the offset-and-snap salvage that used to
      // promise it would collapse 300 one-second records onto one rec_ts (see
      // sync_policy.dart), so it is gone. The day keeps an honest hole.
      _archiveHistoricalFrame(frame, counter, reason: kGateDroppedReason);
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
      d.onHistoricalRecord(raw, sample, recType);
    } else {
      unawaited(_storeRecord(sample, raw));
    }
  }

  void _absorbState(Decoded d) {
    final f = d.fields;
    if (d.kind == 'cmd_response') _clearRepairGuideOnCommandReply();
    // GET_ALARM_TIME readback, re-enabled as a VERIFICATION signal. It was
    // parked upstream because the decode returned a plausible-but-wrong epoch —
    // that was the protocol-side bug (the rev-4 reply's epoch sits at body[2:6]
    // after the revision and active-flag bytes, which the old parse misread);
    // parseCommandResponse now decodes the confirmed layout including the
    // active flag. The readback stays NON-authoritative for display: the
    // locally-set value is what the user sees, and this only verifies it.
    //
    // It was parked because the response layout was unconfirmed and the decode
    // returned a plausible-but-wrong epoch (21:49 for an alarm set to 11:14).
    // The revision-4 response is now pinned:
    //   body[0] revision 04 · body[1] active flag (exactly 1) ·
    //   body[2:6] epoch u32 LE · body[6:8] subsec u16
    // and protocol reads the epoch at that offset, so the old wrong-offset
    // failure mode is gone.
    //
    // Deliberately still NOT authoritative for display: AppState's persisted
    // value is what the user set, and this reply is only meaningful when it
    // DISAGREES — which is exactly the case worth surfacing, because it means
    // the alarm the user believes is armed is not armed on the band. Log the
    // disagreement and expose it for diagnostics; never silently overwrite the
    // user's alarm with a value read off the wire.
    if (f.containsKey('alarm_epoch')) {
      final strapEpoch = (f['alarm_epoch'] as num).toInt();
      final active = f['alarm_active'] as bool?;
      _strapAlarmEpoch = strapEpoch;
      _strapAlarmActive = active;
      _log('[ALARM] strap readback: epoch=$strapEpoch active=$active');
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
      // Gate on the EVENT's own strap timestamp, for the same reason the
      // `charging` flag below carries one: the band re-serves its buffered
      // event log on connect, so a BATTERY_LEVEL event is not evidence of the
      // current charge. Applied blind, a first pair with a long backlog walked
      // the live indicator through weeks of battery history before settling.
      // A GET_BATTERY_LEVEL poll response has no `ts_epoch` and is always
      // live — see [BatteryPolicy].
      final batteryTs = (f['ts_epoch'] as num?)?.toInt();
      final wallNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (BatteryPolicy.acceptsEventReading(batteryTs, wallNow)) {
        state.batteryPct = (f['battery_pct'] as num).toDouble();
        onState(state);
      }
    }
    if (f.containsKey('charging')) {
      state.charging = f['charging'] as bool;
      // Carry the EVENT's own strap timestamp alongside the flag. The strap
      // dumps its buffered event log on connect and re-sends events it has
      // already delivered, so a chargingOn frame is not evidence that the puck
      // went on just now — only its timestamp is. Consumers that treat the
      // transition as live (DeviceAlerts) gate on this; see #179.
      state.chargingTs = (f['ts_epoch'] as num?)?.toInt();
      onState(state);
    }
    if (f.containsKey('on_wrist')) {
      state.wristOn = f['on_wrist'] as bool;
      onState(state);
    }
    if (f.containsKey('clock_epoch')) {
      _absorbClockEpoch(f['clock_epoch'] as int);
    }
    // THE ONE GET_DATA_RANGE consumer. `range_oldest`/`range_newest` come from
    // the reply's real field map (protocol emits them together or not at all).
    // They used to come from a local byte-scan that took the min/max of every
    // 4-byte window that looked like a unix time — which is how a cross-field
    // read once landed as "newest" in 2034 and left `backlogRemains` true
    // forever, chasing a target the band could never reach. The scanner was
    // then given a tighter ceiling instead of being replaced, and it kept
    // running alongside the correct value, feeding a different decision.
    //
    // The same field map was then absorbed TWICE — once here behind
    // isCorruptFutureRtc, and once in a sibling block that assigned
    // `range_newest` straight into `_strapHistoryNewestTs` with no check at
    // all. Protocol only screens to `_maxPlausibleUnix` (year 2100), so every
    // junk value between now+1 day and 2100 reached the ungated path, pinned
    // `backlogRemains` true in AppState._runSyncBurst and burned all 20
    // backfill sessions on every foreground catch-up. One field map, one gate.
    if (f.containsKey('range_oldest') && f.containsKey('range_newest')) {
      final oldest = (f['range_oldest'] as num).toInt();
      final newest = (f['range_newest'] as num).toInt();
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
          'this session\'s plausibility window, and NOT adopting it as the '
          'backlog target '
          '(corrupt_ranges_total=$_corruptDataRangeCount).',
        );
      } else {
        _sessionOldestUnix = oldest;
        _sessionNewestUnix = newest;
        _strapHistoryOldestTs = oldest;
        _strapHistoryNewestTs = newest;
        state.dataRangeOldest = oldest;
        state.dataRangeNewest = newest;
        onState(state);
        // A rejected read is not a range seen: the ledger row is written only
        // for the value we actually adopted. Through the same best-effort
        // wrapper as every other ledger write in this file — un-awaited and
        // un-caught, a failed write surfaced as an unhandled async error
        // instead of a log line.
        unawaited(
          _bestEffortLedgerWrite(
            () => LocalDb.upsertSyncLedgerEntry(
              status: 'range_seen',
              metaPatch: {
                'strap_history_oldest_ts': _strapHistoryOldestTs,
                'strap_history_newest_ts': _strapHistoryNewestTs,
              },
            ),
          ),
        );
      }
    }
    // The OTHER half of the same GET_DATA_RANGE reply: the strap's own ring
    // bookkeeping, parsed since forever and read by nobody. Deliberately NOT
    // inside the block above — `pages_behind` is emitted independently of the
    // epochs, and pages are pages whatever the RTC says, so a corrupt-clock
    // reply still carries a usable backlog. The clock gate stays exactly as it
    // is; this reads a different field.
    final pb = f['pages_behind'];
    if (pb is Map) {
      _lastPagesBehind =
          Map<String, dynamic>.unmodifiable(pb.cast<String, dynamic>());
      unawaited(_recordPagesBehind(_lastPagesBehind!));
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
    // gen5's GET_HELLO (opcode 145) has its own layout, now decoded in full
    // against the revision-1 body map — battery, charge state, the
    // strap's own timestamp, serial, firmware and on-body state all come from
    // here. It used to be diagnostics-only
    // because those offsets were unconfirmed, which left gen5 with no serial,
    // no battery-at-connect and no wrist state.
    if (d.kind == 'cmd_response' && f['gen5_hello'] is Gen5HelloInfo) {
      final h = f['gen5_hello'] as Gen5HelloInfo;
      _gen5Hello = h;
      // PUBLISH ONLY WHAT THE REVISION-1 MAP IS KNOWN TO DESCRIBE. An unknown
      // revision still connects — the parser records the byte instead of
      // gating on it (protocol#35) and hello is mandatory here — but every
      // field below is read at revision-1 offsets, and `onState` is DURABLE,
      // not a repaint: it writes a `band_battery` sample, can fire the
      // battery-low/charging OS notification, heals this serial onto the
      // PAIRING RECORD, and pushes the lock-screen widget. A moved layout
      // would make all four fabricated and persistent.
      //
      // The identity gate below cannot be leaned on to catch that: `cpuHex` is
      // lowercase hex by construction, so it only fails when EMPTY, and any
      // printable bytes landing at the serial offset pass the alphanumeric
      // match. It is a filter, not a fail-closed check — and it runs AFTER
      // this publication either way.
      if (h.helloRevision == 1) {
        state.serial = cleanDeviceLabel(h.serial) ?? state.serial;
        if (h.batteryPct != null) state.batteryPct = h.batteryPct!.toDouble();
        state.charging = h.charging;
        state.wristOn = h.wristOn;
        onState(state);
        _log('[HELLO gen5] serial=${h.serial} fw=${h.firmwareVersion} '
            'battery=${h.batteryPct}% charging=${h.charging} '
            'wrist=${h.wristOn} whoop5=${h.isWhoop5}');
      } else {
        // REVISION-NEUTRAL, deliberately. The line above names six fields read
        // at revision-1 offsets, and the foreground logger PERSISTS what it is
        // handed — so under an unknown layout it would bank a serial and a
        // battery figure as if they were read, which is the same imputation
        // the quarantine above exists to stop. The revision and the body
        // length are the two things true at any layout.
        _log('[HELLO gen5] revision ${h.helloRevision} is not the revision-1 '
            'layout these offsets read (body ${h.rawHex.length ~/ 2}B) — '
            'serial, battery, charge and wrist state are NOT published or '
            'logged; the connection continues.');
      }
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
    // Correlation LAST, so everything a reply carries is already applied to
    // the engine's state by the time whoever awaited it resumes.
    //
    // A reply satisfies its await whether or not the body made sense — "the
    // read completed" and "the read produced a usable value" are different
    // questions, and conflating them cost a full timeout on every clock read
    // whose revision byte we did not recognise.
    if (d.kind == 'cmd_response') {
      final opcode = (f['opcode'] as num?)?.toInt();
      final reqSeq = (f['req_seq'] as num?)?.toInt();
      final outcome = _awaiter.deliver(
        opcode: opcode,
        reqSeq: reqSeq,
        status: (f['cmd_status'] as num?)?.toInt(),
        fields: f,
      );
      // A near-miss — right opcode but a sequence we never sent, or the right
      // sequence carrying a different opcode — is the one symptom worth
      // shouting about. It is what a strap that does not echo the originating
      // sequence would look like, and it is the correlation contract's
      // own "a sequence match with the wrong opcode is not a success" case.
      // Either way the await it belongs to just expires, silently, without it.
      final nearMiss = (opcode != null && _awaiter.hasPendingOpcode(opcode)) ||
          (reqSeq != null && _awaiter.hasPendingSeq(reqSeq));
      if (outcome == CommandDelivery.unmatched && nearMiss) {
        _log('[CMD] response opcode=$opcode req_seq=$reqSeq matched no pending '
            'command (waiting on ${_awaiter.pendingKeys}) — ignored.');
      }
    }
  }

  /// (Re)arm the 60s idle watchdog. Called on every offload frame (records +
  /// markers). If the strap goes silent mid-offload, the open (un-ACKed) chunk is
  /// abandoned so we never ACK a partial — the band re-delivers it next offload.
  void _armIdleWatchdog() {
    final session = _session;
    if (session == null || !session.connected) return;
    // A terminal task has nothing left to wait for: stragglers from it (the
    // re-offered HISTORY_END above all) must not re-arm the watchdog and keep
    // the ended task's retry machinery alive.
    if (session.historyTaskEnded) return;
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
    final f = event.decoded;
    switch (event.eventId) {
      case EventId.strapConditionReport:
        // Free sync-progress telemetry, sent unasked. Logged ONLY —
        // deliberately no offload trigger and no stored state, so the
        // backfill policy stays the single place that decides when to sync.
        _log(
          '[SYNC] strap condition report: '
          'pages_behind=${f['condition_pages_behind']} '
          'backlog=${f['condition_backlog']} soc=${f['condition_soc_pct']} '
          'charging=${f['condition_charging']} '
          'wrist=${f['condition_wrist_state']} ts=${event.tsEpoch}',
        );
        return;
      case EventId.hapticsTerminated:
        // . `user_double_tap` is the wearer
        // dismissing a running alarm — a different fact from an alarm that ran
        // its course. Observed, not acted on: the alarm flow is unchanged.
        _lastHapticsTermination =
            f['haptics_termination'] as String? ?? 'unknown';
        _lastHapticsTerminationTs = event.tsEpoch;
        _log('[ALARM] haptics terminated: cause=$_lastHapticsTermination '
            'code=${f['haptics_termination_code']} ts=${event.tsEpoch}');
        return;
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

  /// THE task-ending abort boundary. Every terminal that must tell the band to
  /// exit history mode funnels through here, so the invariants live in one
  /// place:
  ///
  ///  * AT MOST ONE abort per terminal — [_Session.historyTaskEnded] latches
  ///    first, so a duplicate HISTORY_END (the band re-offers every ~2.5 s
  ///    until it hears something) cannot fire a second one.
  ///  * The abort is BEST-EFFORT and session-bound: `_write(owner:)` refuses
  ///    it once [session] is no longer live, so an old task's abort can never
  ///    land on a replacement link. A failed write is logged and swallowed —
  ///    the task is terminating either way.
  ///  * The task is RELEASED ONLY AFTER the abort boundary completes:
  ///    `_offloadActive` stays up (refusing every refresh trigger) until the
  ///    awaited write resolves, so a new task cannot send GET_DATA_RANGE or
  ///    opcode 22 into the band while the abort is still in flight.
  ///  * NO reconnect is started here. Doc 05: an ordinary terminal does not
  ///    reconnect or resubmit; continuation comes from a later connection,
  ///    scheduler tick or explicit trigger — which
  ///    [_startHistoricalRefresh] permits again by clearing the latch when it
  ///    claims the next task.
  Future<void> _endHistoryTaskWithAbort({
    required _Session session,
    required _HpsTerminalKind kind,
    required String reason,
  }) async {
    // A stale session's task died with its link — nothing to abort, and
    // writing would target the replacement session.
    if (_sessionIsStale(session)) return;
    if (session.historyTaskEnded) return; // one abort per terminal
    session.historyTaskEnded = true;
    // Nothing further is coming that may keep this task alive.
    session.idleWatchdog?.cancel();
    // The ended task's parked continuations (a commit mid-await, queued
    // frames, ACK retries) are stale from this moment.
    _historyTaskGen++;
    _setHpsTerminal(kind, reason: reason);
    // Release any awaitComplete()/runSync() waiter promptly with an
    // incomplete report — the latch above drops every post-terminal marker
    // (HISTORY_COMPLETE included), so nothing else would ever resolve it
    // short of the 60 s idle window.
    _drain?.onTaskTerminal();
    _log('[SYNC] history task terminal ($reason) — sending one best-effort '
        'abort; the band keeps its checkpoint and a later task resumes from '
        'it.');
    final boundary = _writeHistoryAbort(session, reason: reason);
    _historyAbortInFlight = boundary;
    try {
      await boundary;
    } finally {
      if (identical(_historyAbortInFlight, boundary)) {
        _historyAbortInFlight = null;
      }
      // Release the task only now — the abort boundary is complete. But only
      // when the ending session still owns the engine's offload state: a
      // replacement session's INIT pre-arms `_offloadActive` for ITS drain,
      // and an old abort unwinding after the swap must not clear that claim.
      if (!_sessionIsStale(session)) _setOffloadActive(false);
    }
  }

  /// Wait until the previous history task's lifecycle is quiescent: no
  /// task-ending abort in flight and (unless the caller IS the marker
  /// handler) no sync-marker handler still running. Loops because a new
  /// pending future can appear while an old one is being awaited.
  Future<void> _awaitHistoryLifecycleQuiescence({
    bool includeMarkerHandler = true,
  }) async {
    while (true) {
      final pending = _historyAbortInFlight ??
          (includeMarkerHandler ? _historyMarkerInFlight : null);
      if (pending == null) return;
      await pending;
    }
  }

  Future<void> _writeHistoryAbort(
    _Session session, {
    required String reason,
  }) async {
    // Not `_send`: the frame must be pinned to the session whose task is
    // ending (`owner:`), exactly like the batch ACK.
    final frame = buildCommand(
      _seq.nextLive(),
      Cmd.abortHistoricalTransmits,
      const [0x00],
      session.band,
    );
    if (!await _write(frame, owner: session)) {
      _log('[SYNC] best-effort history abort ($reason) was not delivered — '
          'continuing the terminal anyway.');
    }
  }

  /// Attempts allowed per session before the abort→retry cycle gives up and
  /// leaves the link to the ordinary reconnect path.
  static const int _maxHistoricalRetriesPerSession = 3;

  Future<void> _abortAndRetryHistorical({required String reason}) async {
    final session = _session;
    if (session == null || !session.connected) return;
    session.idleWatchdog?.cancel();
    session.historicalRetry?.cancel();
    // The drain ended on the clock, not on a HISTORY_COMPLETE — the boundary
    // records the `timeout` terminal, which used to be attempted in
    // `_onOffloadFinished` behind a `!complete` flag no call site ever passed,
    // so a timed-out drain reported whatever terminal the previous burst had
    // left behind (usually `success`).
    //
    // The boundary also fixes the ordering this path used to get wrong: it
    // clears `_offloadActive` only AFTER the awaited abort write resolves, so
    // a refresh trigger racing this abort cannot start a new task under a
    // band that is still being told to abandon the old one.
    final retriesExhausted =
        session.historicalRetries >= _maxHistoricalRetriesPerSession;
    if (!retriesExhausted) {
      session.historicalRetries++;
      _log('[SYNC] abort($reason) — sending ABORT_HISTORICAL.');
    }
    await _endHistoryTaskWithAbort(
      session: session,
      kind: _HpsTerminalKind.timeout,
      reason: reason,
    );
    if (retriesExhausted) {
      _log('[SYNC] abort($reason) — already retried '
          '${session.historicalRetries} times this session; NOT re-arming. '
          'The strap is not draining; the reconnect path takes it from here.');
      return;
    }
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

  /// SD-08. Persist the strap's ring-buffer bookkeeping and log how it moved
  /// since the last connect.
  ///
  /// Device state, not physiology, so it can claim exactly what it says: how
  /// many records the ring holds, how much room is left, and how many times it
  /// has wrapped. `wrap_count` moving between two connects means the ring
  /// overwrote records — possibly ones we never drained. We only LOG that for
  /// now (ring-buffer-loss-warning): the "you lost N days" wording needs a real
  /// records-per-day divisor, and a week of these lines is how we get one. No
  /// notification, no copy, no user-facing claim.
  ///
  /// Sink is `band_backlog`, one row per connect, keyed on the connect second
  /// and never pruned — the same shape and the same reason as `band_battery`.
  /// It replaces the single `sync_ledger` row this used to overwrite: that row
  /// only ever held the LAST reading, which is enough for the wrap check and
  /// nothing else, and the records-per-day divisor the loss wording needs can
  /// only come from a series. `device_family` rides along because `free_records`
  /// on gen4 and on gen5 do not belong on one axis.
  ///
  /// The previous `wrap_count` now comes from the newest stored row, so the
  /// check survives on the table it writes to rather than on ledger JSON.
  Future<void> _recordPagesBehind(Map<String, dynamic> pb) async {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    final used = asInt(pb['used']);
    final free = asInt(pb['free_records']);
    final wrap = asInt(pb['wrap_count']);
    final written = asInt(pb['written']);
    final capacity = asInt(pb['capacity']);
    final trimPage = asInt(pb['trim_page']);

    int? prevWrap;
    try {
      final prev = await LocalDb.bandBacklog(limit: 1);
      if (prev.isNotEmpty) prevWrap = asInt(prev.first['wrap_count']);
    } catch (_) {/* no prior snapshot — first connect since install */}

    final wrapped = (prevWrap != null && wrap != null && wrap > prevWrap)
        ? wrap - prevWrap
        : 0;
    _log('[BACKLOG] used=$used free=$free wrap=$wrap (prev=$prevWrap, '
        '+$wrapped) written=$written/$capacity trim_page=$trimPage');

    await _bestEffortLedgerWrite(
      () => LocalDb.putBandBacklog(
        ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        written: written,
        used: used,
        capacity: capacity,
        trimPage: trimPage,
        wrapCount: wrap,
        freeRecords: free,
        // Unknown link ⇒ NULL, never a guessed gen4.
        deviceFamily: linkDeviceFamily,
      ),
    );
  }

  /// Refuse to echo a HISTORY_END token, for one of the [TrimAckVerdict]
  /// blocked reasons. The band keeps the chunk and re-delivers it on the next
  /// offload; re-delivery is dedup-safe (decoded rows REPLACE by rec_ts, raw
  /// rows key on the record hex).
  /// The count gate refused this burst: persist what arrived, tell the strap
  /// the burst FAILED, and let it re-offer the same checkpoint unchanged.
  ///
  /// Three properties, all load-bearing:
  ///  1. `commit(null)` — the records and raws are stored durably, but WITHOUT
  ///     the trim token, so the cursor does not advance and nothing is deleted
  ///     from the band. Re-delivery is dedup-safe (`decoded_onehz` REPLACEs by
  ///     `rec_ts`), so storing now costs nothing and means a burst we keep
  ///     failing still yields its readable records.
  ///  2. The 2-byte `00 00` failure result, which is what makes the strap
  ///     re-offer rather than sit waiting for a result that never comes.
  ///  3. A bounded end: the 15th consecutive failure sends ONE abort and
  ///     terminates the session — and deliberately does NOT send a 15th failure
  ///     result, matching the pinned retry boundary.
  Future<void> _refuseHistoryEndOnShortCount({
    required DrainController d,
    required _Session session,
    required int taskGen,
    required String tokenHex,
    required int? batchId,
    required int? expected,
    required int droppedThisBurst,
  }) async {
    // Store what did arrive, without the token.
    final durable = await d.commit(null);
    if (!durable) {
      _log('[SYNC] short-count burst ALSO failed to commit — bouncing the '
          'link so the next session retries from a clean batch.');
      if (!_sessionIsStale(session)) {
        unawaited(
          _teardownSession(intentional: false).then((_) {
            _setPhase(BleConnState.idle);
          }),
        );
      }
      return;
    }
    if (_sessionIsStale(session)) return;
    // The task ended while the commit was parked — this continuation may not
    // send a result or an abort on behalf of a task that is over.
    if (_historyTaskGen != taskGen) return;

    if (d.consecutiveValidationFailures >= kBurstValidationAttemptLimit) {
      // Terminal. One abort, no 15th failure result, and NO same-session
      // auto-retry: the strap keeps the uncommitted checkpoint and a later
      // connection resumes from it.
      //
      // LATCH IT. Sending the abort is not by itself terminal: the band goes on
      // re-offering the same HISTORY_END about every 2.5 s until it gets a
      // result, and every re-offer used to re-enter validation — which was
      // already past the limit, so it aborted again. A real strap showed that
      // loop running 14+ times in 12 s, and the 60 s idle timeout then handing
      // the whole 15-failure cycle to the backfill continuation. Terminal has
      // to mean terminal for the session.
      session.historyStuck = true;
      session.historyStuckAt = DateTime.now();
      _log(
        '[SYNC] burst still short after '
        '${d.consecutiveValidationFailures} attempts — aborting history for '
        'this session (records are stored; the band keeps the checkpoint).',
      );
      await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
            chunkId: 'batch:$tokenHex',
            kind: 'historical_batch',
            status: 'stuck',
            lastError: 'burst_short_count_attempts_exhausted',
            metaPatch: {
              'batch_id': batchId,
              'expected_burst_packets': expected,
              'actual_burst_packets': d.currentBurstTrafficCount,
              'dropped_this_burst': droppedThisBurst,
              'attempts': d.consecutiveValidationFailures,
            },
          ));
      await _endHistoryTaskWithAbort(
        session: session,
        kind: _HpsTerminalKind.stuck,
        reason: 'burst_validation_attempts_exhausted',
      );
      return;
    }

    // `owner:` for the same reason the batch ACK carries it — this is an
    // offload write, and a session that died mid-await must not have its
    // failure result land on the replacement link.
    final ok = await _write(
      buildHistoryResultFail(_seq.nextSync(), profile: session.band),
      owner: session,
    );
    if (!ok) {
      // The burst window is closed and the band never heard a result: it will
      // re-offer this HISTORY_END every ~2.5 s, and each re-offer used to do
      // nothing but log `write_ok=false` and re-arm the watchdog — a task
      // wedged open indefinitely. A result we cannot deliver is TERMINAL for
      // the task: the rows above are already committed (without the token, so
      // nothing was trimmed), and the band keeps the checkpoint for the next
      // task. One best-effort abort, no reconnect, and the task is released
      // only after that abort boundary completes.
      _log(
        '[SYNC] FAILURE result for token=$tokenHex could not be written '
        '(attempt ${d.consecutiveValidationFailures}/'
        '$kBurstValidationAttemptLimit) — ending the history task.',
      );
      await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
            chunkId: 'batch:$tokenHex',
            kind: 'historical_batch',
            status: 'aborted',
            lastError: 'failure_result_write_failed',
            metaPatch: {
              'batch_id': batchId,
              'expected_burst_packets': expected,
              'actual_burst_packets': d.currentBurstTrafficCount,
              'dropped_this_burst': droppedThisBurst,
              'attempts': d.consecutiveValidationFailures,
            },
          ));
      await _endHistoryTaskWithAbort(
        session: session,
        kind: _HpsTerminalKind.resultWriteFailed,
        reason: 'failure_result_write_failed',
      );
      return;
    }
    _log(
      '[SYNC] sent FAILURE result for token=$tokenHex '
      '(attempt ${d.consecutiveValidationFailures}/'
      '$kBurstValidationAttemptLimit) — the band re-offers this '
      'burst; nothing was trimmed.',
    );
    await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'trim_refused',
          lastError: 'burst_short_count',
          metaPatch: {
            'batch_id': batchId,
            'expected_burst_packets': expected,
            'actual_burst_packets': d.currentBurstTrafficCount,
            'dropped_this_burst': droppedThisBurst,
            'attempts': d.consecutiveValidationFailures,
          },
        ));
  }

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
      case TrimAckVerdict.blockedBurstShortfall:
        // The rows we DID receive are already durable (this verdict is only
        // reachable post-commit). Withholding the token asks the band to
        // re-deliver the chunk, which is the only way the frames we lost can
        // still be recovered — after the trim they are gone from flash. The
        // re-delivery is dedup-safe (decoded rows REPLACE by rec_ts), and
        // this token's one refusal has already been spent, so
        // the redelivery is ACKed whatever it contains. No link bounce: the
        // link is fine, we just want the chunk again.
        _log(
          '[SYNC] HISTORY_END token=$tokenHex NOT ACKed — the burst was short '
          '(frames counted by the band that we never received intact). The '
          'committed rows stay; the band re-delivers this chunk once and the '
          'next delivery is ACKed regardless.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'trim_refused',
          lastError: 'burst_shortfall_retry',
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
      case TrimAckVerdict.blockedNoDurableProgress:
        // Gate rejected every historical sample this burst and nothing was
        // banked (no raws, no archives). Echoing the token would trim flash
        // we never stored — the HR-gap / frozen-cursor failure mode after a
        // reconnect with a bad plausibility window. Keep the chunk on the
        // band; after a short streak, re-correlate the clock and bounce.
        final runRemedy = _noDurableProgress.trimRefused();
        _log(
          '[SYNC] HISTORY_END token=$tokenHex has no durable rows but the '
          'plausibility gate dropped samples this burst — NOT ACKing '
          '(refusals=${_noDurableProgress.refusals} '
          'remedies=${_noDurableProgress.remedies}). The band keeps the chunk; '
          'a SET_CLOCK/reconnect may clear a poisoned gate window.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
          chunkId: 'batch:$tokenHex',
          kind: 'historical_batch',
          status: 'trim_refused',
          lastError: 'no_durable_progress',
          metaPatch: {
            'batch_id': batchId,
            'records': d.records,
            'no_durable_refuse_streak': _noDurableProgress.refusals,
            'no_durable_remedy_cycles': _noDurableProgress.remedies,
          },
        ));
        if (runRemedy && !_sessionIsStale(session)) {
          _log(
            '[SYNC] no-durable trim refuses hit the remedy threshold — '
            'defensive SET_CLOCK + bounce so the next session can re-admit '
            'the re-delivered chunk.',
          );
          if (_noDurableProgress.shouldSurfaceGiveUp()) {
            // The remedy has now failed repeatedly. We still do NOT ACK —
            // trimming flash we never banked is unrecoverable, so "keep the
            // data" stays the right answer. What changes is that this stops
            // being INVISIBLE: previously it refused, bounced and retried
            // forever behind a debug log, because the two detectors that would
            // otherwise catch it (`EmptySyncTracker` -> `syncClockLost`,
            // `StuckStrapDetector`) are only evaluated in
            // `_onOffloadFinished`, and HISTORY_COMPLETE never arrives here.
            state.syncClockLost = true;
            onState(state);
            _log(
              '[SYNC] ${_noDurableProgress.remedies} SET_CLOCK+bounce remedies '
              'have not cleared the no-durable-progress loop — surfacing '
              'syncClockLost. The chunk is still SAFE on the band; we are '
              'refusing the trim, not losing data.',
            );
          }
          try {
            await setClock();
          } catch (e) {
            _log('[SYNC] defensive SET_CLOCK after no-durable refuse failed: $e');
          }
          if (!_sessionIsStale(session)) {
            unawaited(
              _teardownSession(intentional: false).then((_) {
                _setPhase(BleConnState.idle);
              }),
            );
          }
        }
        return;
    }
  }

  Future<void> _handleSyncMarker(Frame frame, _Session session) async {
    if (_sessionIsStale(session)) return;
    // The task this marker belongs to. Re-checked after every await below: a
    // terminal (idle watchdog, failed result write) that fires while this
    // handler is parked ends the task, and the resumed continuation must not
    // ACK, send or mutate on behalf of a task that is over.
    final taskGen = _historyTaskGen;
    final m = parseMetadata(frame.inner);
    if (m == null) return;
    // Terminal `Stuck`: this session's history ended
    // with the abort. The band does not know that yet and re-offers the burst
    // every ~2.5 s; each re-offer must be dropped, NOT re-validated and
    // re-aborted. The idle watchdog is deliberately not re-armed either — there
    // is nothing left to wait for on this link.
    //
    // HISTORY_COMPLETE is dropped like everything else. It used to be let
    // through so a parked `awaitComplete()` waiter could still resolve, but a
    // post-terminal COMPLETE also recorded a SUCCESS terminal and ran the
    // post-offload policy for a task that ended in an abort. The waiter is
    // released at the abort boundary now (DrainController.onTaskTerminal), so
    // the exemption's one job is gone.
    if (session.historyStuckActive) {
      session.stuckMarkersDropped++;
      if (session.stuckMarkersDropped == 1) {
        _log(
          '[SYNC] history is terminal (Stuck) for this connection — dropping '
          'the re-offered marker without validating or aborting again. '
          'Further re-offers are silent; the band keeps its checkpoint and a '
          'later connection resumes from it.',
        );
      }
      return;
    }
    // Same shape for any task that ended through the abort boundary: its
    // stragglers (duplicate HISTORY_END, a late START, a stray COMPLETE) must
    // not re-open the task, re-arm the watchdog, record a terminal or send
    // anything. The latch clears when the next task is claimed, so this never
    // blocks a later explicit refresh.
    if (session.historyTaskEnded) {
      session.endedMarkersDropped++;
      if (session.endedMarkersDropped == 1) {
        _log(
          '[SYNC] history task already ended (abort sent) — dropping the '
          'straggler marker; further ones are silent until a new task is '
          'claimed.',
        );
      }
      return;
    }
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
      // The task's first burst is declared — HISTORY_END and data frames are
      // live traffic from here.
      _historyAwaitingFirstStart = false;
      _burstDroppedAtStart = _recordGate.dropped;
      d?.rearm();
      // The one place a new burst is really declared — the only safe point to
      // clear the discarded-burst poison (see DrainController.beginBurst).
      // The validation-failure counter deliberately SURVIVES this: a failed
      // burst is re-offered behind a replacement HISTORY_START, and resetting
      // on it meant a stuck checkpoint never reached the terminal attempt.
      d?.beginBurst();
      _setOffloadActive(true);
      return;
    }
    if (m.sub == SyncMeta.historyEnd && m.token != null) {
      final d = _drain;
      if (d == null) return;
      // Doc 05: Running with no active burst ⇒ a HISTORY_END is a duplicate —
      // drop it, no ACK, no validation. Between claiming a task (opcode 22)
      // and its first HISTORY_START the only legitimate markers are that
      // START and HISTORY_COMPLETE, so a late END straggling in from the
      // previous task must not be judged as part of this one.
      if (_dropPreStartHistory) {
        session.preStartHistoryEndsDropped++;
        if (session.preStartHistoryEndsDropped == 1) {
          _log(
            '[SYNC] HISTORY_END before this task\'s first HISTORY_START — '
            'duplicate from a previous task; dropping without ACK.',
          );
        }
        return;
      }
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
      // see RecordGate.admit) DO reach onUndecodableRecord as
      // kGateDroppedReason archives, but that path deliberately skips the
      // burst count for them, so they never entered currentBurstPacketCount.
      final droppedThisBurst = _recordGate.dropped - _burstDroppedAtStart;
      // Read before validateBurst, which zeroes the counter on a pass — this is
      // the attempt number, and the slack, the gate actually judged this burst
      // under.
      final failuresBefore = d.consecutiveValidationFailures;
      // The count-gate membership rules and the failure-result retry cycle
      // are pinned on gen5 hardware only. On gen4 the gap between expected
      // and actual varies run to run with no fixed offset, and a hard gate
      // turns that into a permanent stall (15 failures → abort → Stuck) on a
      // band whose count semantics nothing has pinned — so gen4 keeps the
      // advisory-only behaviour until a gen4 capture settles it. That is the
      // whole content of [BandEntry.burstCountGateEnforced]; do not flip it.
      final gateEnforced = session.entry.burstCountGateEnforced;
      final validated = expected == null ||
          !gateEnforced ||
          d.validateBurst(
            expectedPacketCount: expected,
            droppedThisBurst: droppedThisBurst,
          );
      // The band computed `expected` for the window that just closed; count
      // members arriving after this marker (re-offer-cycle chatter) must not
      // inflate the tally a re-validation of this same burst judges.
      d.closeBurstTally();
      // How far short of the band's count this burst is, on the SAME all-types
      // tally the gate above just used (`currentBurstTrafficCount` and
      // `currentBurstPacketCount` are one number, not two counters). The gate
      // is one-sided WITH slack; this is the raw gap without it, so the only
      // case where the two differ is a burst that passed on slack — which is
      // exactly what the log below reports. Positive means member frames the
      // band counted and we did not.
      final shortfall = expected == null
          ? 0
          : burstPacketShortfall(
              expectedPacketCount: expected,
              receivedTrafficCount: d.currentBurstTrafficCount,
              droppedThisBurst: droppedThisBurst,
            );
      // THE COUNT GATE. A short burst must NOT be acknowledged.
      //
      // This was advisory-only because the band's count semantics were unknown,
      // and the previous attempt at a gate caused a "fail forever" loop. Both
      // problems are now solved rather than avoided:
      //
      //  * SEMANTICS. The strap reports `data_pkt_cnt + event_pkt_cnt`, and each
      //    complete type-47/48/50/53/54/55 frame counts exactly once (type 49
      //    metadata never does). Types 53/54/55 were counted NOWHERE here until
      //    now, which alone made any burst carrying them look short.
      //  * NO INFINITE LOOP. A failure is not a discard: the records stay
      //    buffered and durable, the strap re-offers the SAME burst unchanged,
      //    and the sequence is bounded — the 15th consecutive failure aborts the
      //    session instead of retrying forever. The strap also drops its own
      //    burst size from 50 to 10 after five negative results.
      //
      // Why refusing is the safe direction: an ACK makes the band TRIM the
      // acknowledged pages from flash. Acknowledging a burst we only partly
      // received deletes the missing records from the only place they exist.
      // Refusing costs a re-delivery; acknowledging costs the data permanently.
      if (!validated) {
        _burstMismatchTotal++;
        _burstMismatchStreak++;
        _log(
          '[SYNC] Burst packet-count SHORT — refusing the trim ACK '
          '(attempt ${d.consecutiveValidationFailures}, '
          'streak=$_burstMismatchStreak): expected=$expected, '
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
            'dropped_this_burst': droppedThisBurst,
            'historical_burst_packets': d.currentBurstHistoricalPacketCount,
            'traffic_burst_packets': d.currentBurstTrafficCount,
            'burst_validation_failures': d.consecutiveValidationFailures,
            'burst_breakdown': d.currentBurstBreakdown,
            'burst_shortfall': shortfall,
          },
        ));
        await _refuseHistoryEndOnShortCount(
          d: d,
          session: session,
          taskGen: taskGen,
          tokenHex: tokenHex,
          batchId: m.batchId,
          expected: expected,
          droppedThisBurst: droppedThisBurst,
        );
        return;
      } else if (gateEnforced) {
        _burstMismatchStreak = 0;
      } else if (shortfall != 0) {
        // gen4: advisory only — record the mismatch for observability, keep
        // ACKing exactly as the proven flow always has.
        _burstMismatchTotal++;
        _burstMismatchStreak++;
        _log(
          '[SYNC] burst packet-count mismatch (ADVISORY, gen4): '
          'expected=$expected counted=${d.currentBurstTrafficCount} '
          'dropped_this_burst=$droppedThisBurst short_by=$shortfall — '
          'ACKing as always; the gen4 count semantics are unpinned.',
        );
        await _bestEffortLedgerWrite(() => LocalDb.upsertSyncLedgerEntry(
              status: 'validated_with_mismatch',
              lastError: 'burst_packet_mismatch_advisory',
              metaPatch: {
                'expected_burst_packets': expected,
                'dropped_this_burst': droppedThisBurst,
                'traffic_burst_packets': d.currentBurstTrafficCount,
                'burst_shortfall': shortfall,
              },
            ));
      } else {
        _burstMismatchStreak = 0;
      }
      // Reaching here means the gate PASSED. A positive shortfall therefore
      // means it passed on the doc-05 slack (2 from the 4th attempt) rather
      // than on a complete burst — worth one line, because the ACK below trims
      // flash for frames we never tallied.
      //
      // This used to be logged as a separate "burst completeness would-flag"
      // with its own missing/CRC-loss story, which read like a SECOND
      // completeness counter disagreeing with the gate. It never was one: both
      // lines have always come from the same all-types tally, and the only
      // difference is the slack. In the on-air behaviour that produced this
      // change, its "potential loss" reading was wrong too — the missing frames
      // were the burst's own event/console members, counted into a different
      // burst window by the ordering bug this commit fixes, not lost on air.
      if (gateEnforced && shortfall > 0) {
        _log(
          '[SYNC] burst passed the count gate ON SLACK: expected=$expected '
          'counted=${d.currentBurstTrafficCount} '
          'dropped_this_burst=$droppedThisBurst short_by=$shortfall '
          '(attempt ${failuresBefore + 1}, slack '
          '${burstCountSlack(failuresBefore)}) — committing '
          'and ACKing; the band will trim frames we did not count.',
        );
      }
      final r = d.bufferedRecTsRange;
      final droppedThisBurstForLog = droppedThisBurst;
      // Banked records, plus archives that are NOT plausibility drops.
      //
      // Counting EVERY archive makes blockedNoDurableProgress unfireable in the
      // one case it exists for — a drop-only burst archives too, so the band
      // would be cleared to trim flash we never read. Counting NO archive wedges
      // a burst that is entirely records we cannot decode (a gen4 R10
      // historical has its own decoder and is not in kKnownRecordVersions) into
      // being re-delivered forever. Hence the split, not a bare record count.
      //
      // This only decides whether the band may TRIM. Archives are committed in
      // the same transaction regardless — except on the no-progress path, which
      // returns before commit precisely because there is nothing to bank.
      final hadDurableRows =
          d.bufferedRecords > 0 || d.bufferedProgressArchives > 0;
      _log(
        '[SYNC] HistoryEnd batch=${m.batchId} records=${d.records} '
        'expected=${m.expectedPacketCount} '
        'historical=${d.currentBurstHistoricalPacketCount} '
        'traffic=${d.currentBurstTrafficCount} token=$tokenHex '
        'dropped_this_burst=$droppedThisBurstForLog '
        'durable_buffered=${d.bufferedRecords}+${d.bufferedArchives} '
        'recTs=${r == null ? "none" : "${r.$1}..${r.$2}"}',
      );
      // Non-trimmable wiring (no onCommit): unbuffered fire-and-forget cannot
      // prove durability before ACK. Production always sets onCommitBatch.
      if (!d.supportsSafeTrim) {
        _log(
          '[SYNC] HISTORY_END token=$tokenHex refused — drain has no onCommit '
          '(non-trimmable / test-only wiring); band keeps the chunk.',
        );
        return;
      }
      // NO-PROGRESS GATE: refuse trim when this burst banked nothing durable
      // but the RecordGate dropped samples. Echoing would delete flash we
      // never stored (and used to also flip lastTrimAdvanced, feeding
      // auto-continue while the cursor stayed frozen).
      final progressVerdict = TrimAckPolicy.evaluate(
        sessionCurrent: !_sessionIsStale(session),
        burstDiscarded: d.burstDiscarded,
        commitDurable: true,
        hadDurableRows: hadDurableRows,
        droppedThisBurst: droppedThisBurst,
      );
      if (progressVerdict != TrimAckVerdict.send) {
        await _refuseHistoryEndTrim(
          progressVerdict,
          d: d,
          session: session,
          tokenHex: tokenHex,
          batchId: m.batchId,
        );
        return;
      }
      _successfulBursts++;
      _mergeValidatedBurst(d);
      // SAFE-TRIM INVARIANT: persist decoded+raw AND the continuation cursor
      // DURABLY (one transaction) BEFORE the ACK. The band trims its flash only
      // once the ACK is link-layer confirmed, so a crash before the ACK
      // re-delivers the chunk. Echo the 8-byte slice the band acks verbatim —
      // a mangled echo is the "Groundhog Day" re-flood bug.
      final durable = await d.commit(m.token); // raw+samples+cursor, atomic
      // The task ended while the commit was parked (idle-watchdog abort above
      // all): the rows are durable — that is never undone — but this
      // continuation may not ACK for a task that is over. The band was told to
      // abort and re-delivers the chunk on a later task; dedup-safe.
      if (_historyTaskGen != taskGen) return;
      // RE-GATE after the await. commit() can take seconds on a large batch —
      // long enough for the link to die under us — and it now reports whether
      // the transaction actually became durable instead of swallowing the
      // exception. Either way the ACK is refused, which is the whole point:
      // the ACK is what makes the band trim its flash.
      final verdict = TrimAckPolicy.evaluate(
        sessionCurrent: !_sessionIsStale(session),
        burstDiscarded: d.burstDiscarded,
        commitDurable: durable,
        hadDurableRows: hadDurableRows,
        droppedThisBurst: droppedThisBurst,
        // The count gate already refused a short burst (failure result
        // + band re-offer) before this point, so the one-shot shortfall
        // refusal is never spent here.
        shortfallRetry: false,
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
      if (!await _writeAckVerified(ack, session, taskGen: taskGen)) {
        // False for one of three reasons: the writes genuinely exhausted, the
        // session died, or the TASK ended under the retries. Only the first is
        // this continuation's to handle — a stale one must not touch the
        // failure ledger, quarantine state or the abort boundary.
        if (_sessionIsStale(session) || _historyTaskGen != taskGen) return;
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
        final quarantined = _chunkFailures.shouldQuarantine(tokenHex);
        if (quarantined) {
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
          // ESCALATE, don't keep bouncing. The quarantine row existed and
          // nothing read it, while the bounce below ran unconditionally and
          // indefinitely — the band re-delivered forever, the app reconnected
          // forever, the battery drained, and the only user-visible symptom
          // was a sync that never finished.
          if (!state.syncChunkQuarantined) {
            state.syncChunkQuarantined = true;
            onState(state);
          }
        }
        _log('[SYNC] BATCH-ACK FAILED after '
            '${ackRetryPolicy.maxAttempts} attempts (token=$tokenHex, '
            'failures_for_this_token=$failCount'
            '${quarantined ? ", token QUARANTINED" : ""}) — ending the '
            'history task; data is committed and the band re-delivers from '
            'its un-advanced checkpoint on a later task.');
        // The band-side task must be told it is over: without a result on the
        // wire it re-offers this HISTORY_END forever. One best-effort abort
        // through the common boundary — which no-ops on a stale session, so
        // _writeAckVerified returning false because the session died under it
        // can never abort (or previously: tear down) the replacement link.
        // Deliberately NO link bounce here any more: the reconnect loop is
        // what turned a persistently failing ACK write into a battery-draining
        // storm, and the committed rows are safe either way. Nothing is marked
        // acknowledged and no ACK/batch bookkeeping advances.
        await _endHistoryTaskWithAbort(
          session: session,
          kind: _HpsTerminalKind.resultWriteFailed,
          reason: 'ack_write_exhausted',
        );
        return;
      }
      _chunkFailures.recordSuccess(tokenHex);
      // A trimmed chunk proves the strap IS draining, so the abort→retry
      // budget is about a stall that has since cleared, not this session.
      session.historicalRetries = 0;
      if (state.syncChunkQuarantined) {
        // A token finally ACKed — whatever was wrong with the write path has
        // cleared, so the flag must not stick around as a permanent scare.
        state.syncChunkQuarantined = false;
        onState(state);
      }
      // A trim ACK is the only real proof the no-durable-progress condition is
      // over — records were banked and the band may advance.
      _noDurableProgress.trimAcked();
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
      // After a Stuck abort the offload flag is already down by design — that
      // is not an out-of-band COMPLETE, so don't record it as one.
      if (!_offloadActive && !session.historyStuckActive) {
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
        // the records buffered, so the next commit re-attempts them: the next
        // burst's HISTORY_END, or awaitComplete's flush when the drain stops.
        // NOT a teardown flush — teardown drops the buffer on purpose (see the
        // blockedCommitFailed bounce), and the band still holds the chunk.
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
      await _onOffloadFinished();
    }
  }

  // ── post-offload policy: empty-sync, stuck-strap, auto-continue ──────────────
  /// Reached from the HISTORY_COMPLETE branch only — a drain that ends any
  /// other way (link down, idle watchdog) records its own terminal and never
  /// gets here. This used to take a `complete` flag that its single call site
  /// always passed as `true`, so both arms guarded by it were dead: the
  /// empty-sync block below always ran, and a `_HpsTerminalKind.timeout` arm at
  /// the bottom never did (the watchdog abort now records that terminal where
  /// the timeout actually happens).
  Future<void> _onOffloadFinished() async {
    final d = _drain;
    if (d == null) return;
    final banked = d.recordsThisOffload > 0;
    _emptyStreak = banked ? 0 : (_emptyStreak + 1);

    // Records arrived ⇒ both "the band is not handing anything over" flags are
    // over. Their detectors self-reset, but the flags themselves were set-only,
    // so once tripped they described the rest of the process. Now that they are
    // rendered, a stale one is a permanent scare about a band that is working.
    // Cleared BEFORE the detectors below, so a fresh trip in this same pass
    // still wins.
    if (banked && (state.syncClockLost || state.strapNeedsReboot)) {
      state.syncClockLost = false;
      state.strapNeedsReboot = false;
      onState(state);
      _log('[SYNC] records banked — clearing syncClockLost/strapNeedsReboot.');
    }

    // Empty-sync: ≥3 consecutive console-only completed offloads ⇒ RTC lost.
    // Completed only, deliberately: an aborted drain proves nothing about the
    // strap's RTC, which is why the tracker's method is `recordCompletedSync`.
    // `_emptyStreak` above carries the same completed-only semantics for the
    // same reason.
    if (_emptySync.recordCompletedSync(
      bankedSensorRecords: banked,
      consoleOnly: !banked,
    )) {
      state.syncClockLost = true;
      onState(state);
      _log('[SYNC] empty-sync tripped — strap RTC likely lost.');
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
      // fromMarkerHandler: this runs inside the HISTORY_COMPLETE handler —
      // waiting on _historyMarkerInFlight here would deadlock on our own
      // future, and the handler is already past every controller-mutating
      // await.
      await _triggerBackfill(
        BackfillTrigger.autoContinue,
        fromMarkerHandler: true,
      );
    } else {
      _autoContinue.end();
      // nothing left to continue - this offload cycle is genuinely done
      // either way (clean completion or not), so maintenance traffic
      // (heartbeat/keepalive/RTC re-verify/live re-arm/battery poll) can
      // resume. this used to only clear on a `!complete` sub-case that no call
      // site could reach, so an ordinary clean completion with no more backlog
      // left maintenance traffic silently paused for the rest of the connection.
      _setOffloadActive(false);
    }
  }

  /// The record counter out of a historical record's inner payload. Where it
  /// sits is registry data; 0 is the too-short fallback, not a real counter.
  int _counterFromInner(Uint8List inner) {
    final at = (_session?.entry ?? kWhoopGen4).innerCounterOffset;
    return inner.length >= at + 4 ? u32(inner, at) : 0;
  }
  static const _hexDigits = '0123456789abcdef';
  // Called once per stored record, once per archived record and once per live
  // frame, so it runs ~50k times in an offload on the UI isolate. The obvious
  // `map(toRadixString).join()` allocates a String per byte plus a List plus
  // the join: ~146 ms/50k at 120 bytes, and ~1.2 s/50k at v21's 1232.
  String _innerHex(Uint8List inner) {
    final out = Uint8List(inner.length * 2);
    for (var i = 0; i < inner.length; i++) {
      final b = inner[i];
      out[i * 2] = _hexDigits.codeUnitAt(b >> 4);
      out[i * 2 + 1] = _hexDigits.codeUnitAt(b & 0x0F);
    }
    return String.fromCharCodes(out);
  }

  /// Send the gen5 "R22" 16-flag SET_CONFIG enable sequence
  /// (protocol's `buildR22EnableSequence`/`kGen5R22EnableFlags`), unlocking
  /// the v20 (optical)/v21 (IMU)/v26 (PPG) deep-buffer historical records.
  /// Sequential, ~40ms apart (same spacing discipline as the gen4 5-packet
  /// INIT). Not sent unless [gen5DeepBuffersEnabled] opts in (see the
  /// constructor doc). UNTESTED on physical hardware. No-op on a gen4 link.
  ///
  /// Written directly via [_write] (not [_send]) because the pre-built
  /// frames already carry their own sequence numbers — going through `_send`
  /// would double-allocate from [_seq] for no benefit. SET_FF_VALUE (120) is
  /// in `dangerousCmds` (a persistent config write survives a reboot), so this
  /// is the ONE call site that passes `allowDangerous: true` — a named,
  /// reviewed opt-in rather than the structural bypass it used to be, now that
  /// the block sits on `_write` itself.
  Future<void> enableGen5DeepBuffers() async {
    if (!(_session?.band.isGen5 ?? false)) return;
    final frames = buildR22EnableSequence(startSeq: _seq.nextLive());
    _log('Sending gen5 R22 deep-buffer enable sequence (${frames.length} '
        'flags)…');
    for (final frame in frames) {
      // The ONE audited `allowDangerous`. SET_FF_VALUE is in `dangerousCmds`
      // because a persistent config write survives a reboot; this sequence is
      // opt-in and ships a restore-defaults companion, which is exactly the
      // carve-out the block-list doc describes.
      await _write(frame, allowDangerous: true);
      await Future.delayed(const Duration(milliseconds: 40));
    }
    _log('gen5 R22 deep-buffer enable sequence sent.');
  }

  // ── high-level flows ─────────────────────────────────────────────────────────────
  /// [drain] false sends the first FOUR packets only: seq4 is
  /// SEND_HISTORICAL_DATA (the flash drain), and it is skipped when the phone
  /// clock is suspect — see _doConnect and [ClockPolicy.phoneClockSuspect].
  /// Returns whether EVERY INIT packet was written. Callers that pre-arm
  /// offload state around it need to know: seq4 is SEND_HISTORICAL_DATA, so a
  /// failed write means no history was ever requested, and leaving
  /// `_offloadActive` set behind it wedges every later refresh on the
  /// already-transmitting guard.
  Future<bool> sendInit({bool drain = true}) async {
    // Every INIT write is pinned to the session current when INIT began — a
    // link swap mid-sequence must stop the tail from landing on the
    // replacement (`_write(owner:)`) and report the INIT as not written.
    final session = _session;
    if (session == null) {
      // No link, so nothing can be written — but the setup boost must still
      // end here, exactly as the `finally` blocks below guarantee on every
      // other exit from this method.
      if (_connectSetup) {
        _connectSetup = false;
        unawaited(_applyLinkPriority());
      }
      return false;
    }
    final band = session.band;
    if (band.isGen5) {
      // gen5 handshake: a single CLIENT_HELLO (GET_HELLO 0x91) written
      // with-response opens the just-works bond, then the offload is driven by
      // GET_DATA_RANGE + SEND_HISTORICAL_DATA with EMPTY payloads (gen4 sends a
      // 0x00). The HISTORY_END ACK is byte-structured identically (handled in
      // the metadata path). NOTE: untested on physical hardware — pending a
      // WHOOP 5 device; the gen4 path below is unchanged.
      //
      // [drain] is honoured here for the same reason it exists on gen4: the
      // drain must not start while the phone clock is suspect, or the records
      // it pulls get stamped against a clock we do not trust.
      // No CLIENT_HELLO here any more: the connect path sends and AWAITS it
      // during setup, before the clock decision, which is the pinned order
      //. Re-sending it at INIT would be a second identity exchange
      // after the point every consumer of it has already run.
      _log('Sending gen5 offload…');
      var ok = false;
      // try/finally for the same reason the gen4 loop below has one: other
      // paths rely on `_connectSetup` being cleared here, and a throw anywhere
      // above the clear leaves the link pinned at setup priority for the whole
      // connection with `_applyLinkPriority` early-returning forever.
      try {
        ok = true; // hello already completed during connect setup
        // Opt-in deep-buffer sequence, BEFORE the offload trigger (SET_CONFIG
        // flags must land before SEND_HISTORICAL_DATA to take effect for this
        // drain). Default OFF — see [gen5DeepBuffersEnabled].
        if (gen5DeepBuffersEnabled()) {
          await enableGen5DeepBuffers();
        }
        // Same band-aware helpers the refresh/backfill/retry paths use, so the
        // gen5 offload command format is identical everywhere.
        //
        // Stop at the first failure, exactly as the gen4 loop below does — and
        // here for a second reason. The caller pre-arms `_offloadActive` and
        // rolls it back when this returns false, which is only sound while
        // "false" implies the drain trigger never went out. Firing
        // SEND_HISTORICAL_DATA after an earlier write failed breaks that: the
        // band floods while the caller clears `_offloadActive`, so link priority
        // steps back down mid-drain, maintenance traffic resumes, and the
        // offload branches all take the not-offloading path.
        if (ok) {
          ok = await _sendGetDataRange(owner: session);
          await Future.delayed(const Duration(milliseconds: 120));
        }
        if (!drain) {
          _log('gen5 INIT: skipping the drain (phone clock suspect).');
        } else if (ok) {
          ok = await _sendHistoricalData(owner: session);
        }
        if (!ok) {
          _log('gen5 INIT write failed — abandoning the remaining packets.');
        }
      } finally {
        if (_connectSetup) {
          _connectSetup = false;
          unawaited(_applyLinkPriority());
        }
      }
      return ok;
    }
    final pkts =
        drain ? initPackets : initPackets.take(initPackets.length - 1).toList();
    _log('Sending ${pkts.length}-packet INIT…');
    var allWritten = true;
    try {
      for (final pkt in pkts) {
        if (!await _write(pkt, owner: session)) {
          // Stop at the first failure: the packets are a sequence, and the
          // strap will not act on the tail of one whose head never arrived.
          allWritten = false;
          _log('INIT write failed — abandoning the remaining packets.');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      // Setup is over. The flood INIT triggers raises the link on its own via
      // `_setOffloadActive`, so from here the ordinary rules apply — and an
      // idle link stops paying for the fast interval.
      if (_connectSetup) {
        _connectSetup = false;
        unawaited(_applyLinkPriority());
      }
    }
    return allWritten;
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
    // Captured BEFORE awaitComplete: if a replacement task claims this
    // controller while we're parked in the await, drain.taskGeneration moves
    // on and this waiter's own generation is what tells the difference below.
    final waiterGen = drain.taskGeneration;
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
    // Only the task this waiter belonged to may release the offload claim —
    // a replacement task has already pre-armed `_offloadActive` for its own
    // drain by the time a superseded waiter's tick resolves.
    if (!report.complete && drain.taskGeneration == waiterGen) {
      _setOffloadActive(false);
    }
    // OUTBOUND automation event (Android only — see TaskerBridge.emitEvent for
    // why iOS gets no equivalent). Only on a COMPLETE offload: "sync finished"
    // must mean the strap actually drained, not that a link dropped mid-drain.
    // Un-awaited and rate-limited inside the bridge; a broadcast that cannot be
    // sent must never hold up the sync path.
    if (report.complete) {
      unawaited(TaskerBridge.emitSyncComplete(records: report.records));
    }
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
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    final sec = ms ~/ 1000;
    final subsec = ((ms % 1000) * 32768) ~/ 1000; // 0..32767, 1/32768 s units
    // SET_CLOCK(10) with the 8-byte <u32 sec><u32 subsec> body is the real
    // command on BOTH generations. It used to send opcode 146 ("Maverick
    // clock") on gen5 — not an established WHOOP opcode, and one nothing has
    // ever watched latch an RTC. The real gen5 contract is opcode 10,
    // hardware-confirmed: a WHOOP 5 answers GET_CLOCK(11) with a usable time
    // and returns SUCCESS for this exact 8-byte SET form.
    //
    // This matters beyond tidiness: a rejected clock write is SILENT. The RTC
    // simply never latches, and every absolute timestamp afterwards — alarms
    // above all — is armed against a clock that was never set.
    final isGen5 = _session?.band.isGen5 ?? false;
    await _send(Cmd.setClock, <int>[
      sec & 0xff,
      (sec >> 8) & 0xff,
      (sec >> 16) & 0xff,
      (sec >> 24) & 0xff,
      subsec & 0xff,
      (subsec >> 8) & 0xff,
      0,
      0,
    ]);
    _log('SET_CLOCK${isGen5 ? " (gen5)" : ""} → sec=$sec subsec=$subsec.');
    // Read the RTC back so the GET_CLOCK response handler can confirm it latched
    // (and re-issue SET_CLOCK if the strap clock is still off — see _onDecoded).
    await getClock();
  }

  /// Read the strap RTC. The response carries `clock_epoch`, handled where we
  /// verify drift and re-correlate the strap-RTC ↔ wall clock.
  ///
  /// GET_CLOCK(11) with an EMPTY body on both generations — physically
  /// confirmed on a WHOOP 5 (see [setClock] for the evidence and for why the
  /// gen5-exclusive opcode 147 was dropped). The reply body is the same
  /// `[u32 sec][u32 subsec]` shape on both.
  Future<void> getClock() => _send(Cmd.getClock, const <int>[]);
  /// Apply a strap clock reading: phone-suspect verdict, correlation, and the
  /// bounded SET_CLOCK correction. Extracted so the gen5 HELLO timestamp and a
  /// GET_CLOCK reply reach IDENTICAL logic — the pinned gen5 path takes its
  /// clock from hello and never sends GET_CLOCK, so without this the two
  /// sources would drift apart in behaviour.
  void _absorbClockEpoch(int dev) {
      final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Assess phone-clock trust from the RAW read, before the alarm-safety gate
      // below diverts a future reading. A plausible strap RTC that reads > 1 day
      // ahead of the phone means the phone clock is likely slow — history offload
      // then DEFERS (see _startHistoricalRefresh) instead of dropping the strap's
      // real records as "future" and trimming them off the band. Cleared the
      // moment a read agrees (the phone almost always self-corrects via NTP).
      final wasSuspect = _phoneClockSuspect;
      _phoneClockSuspect = ClockPolicy.phoneClockSuspect(dev, wall);
      if (_phoneClockSuspect && !wasSuspect) {
        _phoneClockSuspectSince = _monotonicSecs();
      } else if (!_phoneClockSuspect) {
        _phoneClockSuspectSince = null;
      }
      // The read gate is released above, on the reply itself, not here.
      //
      // UNCORRELATED either way: any GET_CLOCK reply releases the waiter,
      // including one answering setClock()'s read-back or the keep-alive poll.
      // Telling them apart needs the echoed request seq, which the pinned
      // protocol does not surface — see the pin note in pubspec.yaml and
      // OpenStrap/protocol#28. The reply that lands is still a real strap read
      // from this session, so the verdict is fresh; it may just answer a
      // request a few hundred ms older than ours.
      if (_phoneClockSuspect != wasSuspect) {
        _log(_phoneClockSuspect
            ? '[SYNC] Phone clock appears wrong: strap RTC=$dev is > 1 day ahead '
                'of phone wall=$wall — DEFERRING history offload until they agree.'
            : '[SYNC] Phone/strap clocks agree again (strap=$dev wall=$wall) — '
                'history offload may resume.');
      }
      // SANITY GATE, mirroring the one `range_newest` gets below. An
      // implausibly far-future `clock_epoch` yields a large NEGATIVE driftSec,
      // and setAlarm arms at `when - driftSec` — years out, where the alarm
      // silently never fires — while the bounded SET_CLOCK retry budget is
      // spent chasing a value that was never real. Reject the read: with no
      // correlation the alarm falls back to the raw wall epoch. connect()
      // already issues an unconditional SET_CLOCK, and the periodic re-verify
      // re-reads, so a genuinely-wrong RTC still gets corrected.
      if (dev < kMinPlausibleUnix) {
        // UNSET RTC. This read is now surfaced instead of swallowed by the
        // decoder (see [_maybeAugmentClockEpoch]) so the SET_CLOCK correction
        // below can finally fire for it — but it must NOT become a ClockRef:
        // correlating a factory-epoch clock yields a drift of decades, and
        // `AlarmPayloads.toStrapFrame` would arm every alarm that far in the
        // past.
        _log(
          '[SYNC] GET_CLOCK clock_epoch=$dev is below the plausible floor — '
          'the strap RTC was never set. NOT correlating; SET_CLOCK below is '
          'the fix.',
        );
      } else if (!ClockPolicy.acceptsClockRead(dev, wall)) {
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
      }
      // CORRECTION RUNS ON THE RAW READ, outside the correlation gate above.
      //
      // It used to be nested inside the accepted-read branch, which quietly
      // made a fast strap RTC unfixable: `acceptsClockRead` rejects anything
      // past `wall + kFutureMargin` and `phoneClockSuspect` trips past that
      // SAME margin, so the one reading that means "the strap clock is ahead"
      // could never reach the one code path that fixes it. History would
      // un-defer at grace expiry — having concluded the STRAP is the fast one —
      // straight back onto an uncorrected fast RTC, where the record gate
      // rejects every future-stamped record and the offload can never bank
      // anything.
      //
      // Rejecting the read for CORRELATION is still right (a junk value would
      // arm alarms years out). Rejecting it for CORRECTION never was: SET_CLOCK
      // writes real wall time, which is the correct outcome whether the read
      // was junk or the RTC is genuinely ahead, and the retry budget is bounded
      // at 3 either way.
      if (ClockPolicy.shouldSetClock(dev, wall)) {
        if (_deferForClock) {
          // While the phone is still the suspect party, writing our wall clock
          // onto a strap that may well be RIGHT corrupts a correct RTC and
          // destroys the evidence — the read-back then "agrees" forever. Hold
          // off until the phone corrects (gate clears) or the grace expires
          // (the strap is the fast one, and the branch below fixes it).
          _log(
            'Clock drift over policy but the PHONE clock is the suspect one '
            '(strap=$dev wall=$wall) — NOT writing SET_CLOCK yet.',
          );
        } else if (_bootstrapClockWrite) {
          // The bootstrap's own clock step is the single writer for this
          // connect. Writing here too sent a
          // factory-fresh band TWO corrections back to back — the
          // duplicate-persistent-write hazard. The retry budget is untouched:
          // the read-back after the bootstrap write lands once this window is
          // closed, and a still-wrong RTC re-corrects here as before.
          _log('Clock drift over policy — leaving the write to the bootstrap '
              'clock step (one SET_CLOCK per connect).');
        } else if (_clockCorrectTries < 3) {
          // BOUND the retries: setClock() reads the clock back and this handler
          // re-issues on drift, so an unbounded loop would spin
          // SET_CLOCK/GET_CLOCK forever on firmware that never latches.
          // Historical records carry their own embedded unix time regardless,
          // so giving up after a few tries is safe.
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


  /// GET_CLOCK, awaited to the *response* rather than to the write.
  ///
  /// Both clock gates (the connect-path SET_CLOCK decision and the history
  /// drain in [_startHistoricalRefresh]) used to send GET_CLOCK, sleep a fixed
  /// 120 ms, then read [_phoneClockSuspect]. That flag is cross-session state,
  /// so a reply slower than the sleep — routine on a busy link mid-offload —
  /// let the gate answer with the PREVIOUS connection's verdict, or with the
  /// process default (`false`) on the very first connect. Both directions are
  /// wrong: a stale `false` permits the drain-and-trim the gate exists to
  /// prevent, and a stale `true` blocks a link whose clocks now agree.
  ///
  /// Returns whether a fresh reply landed. A timeout deliberately does NOT
  /// change either gate's decision: an unanswered GET_CLOCK is not evidence
  /// about the phone, and failing closed would mean a strap whose reply we
  /// never see is a strap we never SET_CLOCK (it ships RTC-unset) and never
  /// sync. Callers proceed on the last known verdict; the log line is the
  /// signal that the read never landed.
  /// Send the gen5 `GET_HELLO(0x91)` and wait for its reply.
  ///
  /// This runs BEFORE any clock work, which is the pinned order:
  /// hello carries the strap's own timestamp, identity, battery, charge and
  /// on-body state, and the pinned flow feeds that timestamp straight into
  /// the clock decision rather than spending a GET_CLOCK round trip. Sending it
  /// late — as this app used to, inside INIT — meant the clock had already been
  /// read and written by then, so hello's timestamp could never be used and its
  /// identity fields arrived after everything that wanted them.
  ///
  /// Returns whether a terminal successful, PARSED hello landed. Anything
  /// else — write failure, timeout, terminal FAILURE, UNSUPPORTED, a success
  /// whose body never parsed — is a failed exchange: counted by
  /// [_noteHelloFailure], and the caller fails the CONNECTION (hello is
  /// mandatory; there is no GET_CLOCK fallback on the gen5 path). A completed
  /// write is NOT success — only the terminal response plus a parsed hello
  /// object count.
  /// Correlated through the [CommandAwaiter]: the reply must echo THIS hello's
  /// sequence and opcode 145. GET_HELLO is also one of the two commands whose
  /// `PENDING` is not terminal, so a deferred reply keeps the await
  /// open for the real result instead of reporting the strap as answered.
  /// The timeout is applied exactly once, with no automatic resend.
  Future<bool> _readGen5Hello() async {
    final out = await _sendAwaited(
      Cmd.getHello,
      const [0x01],
      timeout: _helloTimeout,
      frameBuilder: (seq) => gen5ClientHello(seq: seq),
    );
    if (!out.written) {
      _log('[HELLO gen5] write failed.');
      await _noteHelloFailure('write failed');
      return false;
    }
    final resp = await out.response;
    if (resp == null) {
      _log('[HELLO gen5] no reply in ${_helloTimeout.inSeconds}s.');
      await _noteHelloFailure('no reply');
      return false;
    }
    // A non-success result leaves the body unpopulated, and an unparseable
    // body leaves `_gen5Hello` null — either way there is no identity, no
    // timestamp and nothing for the clock decision, which is the
    // "missing or failed hello".
    final hello = _gen5Hello;
    if (!resp.success || hello == null) {
      _log('[HELLO gen5] reply status=${resp.status} '
          'body=${hello == null ? 'unparsed' : 'parsed'} — treating as a '
          'failed hello.');
      await _noteHelloFailure('status=${resp.status}');
      return false;
    }
    _noteHelloSuccess(hello);
    return true;
  }

  /// Matches the standard 5-second command timeout.
  static const Duration _helloTimeout = Duration(seconds: 5);

  /// Record the identity verdict of a terminal successful hello. Enforcement
  /// happens in [_gen5PostHelloGates] (a failed verdict fails the
  /// connection). The accumulated hello-FAILURE count is deliberately NOT
  /// cleared here: a hello object arriving is not a completed bootstrap — the
  /// counter clears only when the connection reaches READY
  /// ([_finishConnect]), so a link that keeps dying between hello and READY
  /// still reaches the five-failure bond reset.
  void _noteHelloSuccess(Gen5HelloInfo h) {
    // The pinned parser reads serial/cpuHex at revision-1 offsets REGARDLESS
    // of `helloRevision` (it doesn't gate on the byte). For an unknown
    // revision those bytes may not be identity at all, so evaluating them
    // would invent a verdict — and a bad one could fail the alphanumeric gate
    // in _gen5PostHelloGates and reject a connection the clock contract
    // (which already treats an unknown revision as "must still connect")
    // would otherwise allow. Only revision 1 gets a real identity verdict;
    // any other revision is unverified-but-not-a-rejection.
    _helloIdentity = h.helloRevision == 1
        ? HelloIdentity.evaluate(
            serial: h.serial,
            cpuHex: h.cpuHex,
            eepromFailureSignal: h.serialLooksEepromFailure,
          )
        : const HelloIdentity(
            serialOk: true,
            cpuOk: true,
            eepromFailureSignal: false,
          );
  }

  /// record the failure, and at the fifth
  /// one reset the counter and remove the platform bond before starting over.
  Future<void> _noteHelloFailure(String why) async {
    _helloFailures++;
    _log('[HELLO gen5] failure $_helloFailures/$kHelloFailuresBeforeBondReset '
        '($why) — counted across reconnect attempts.');
    if (_helloFailures < kHelloFailuresBeforeBondReset) return;
    _helloFailures = 0;
    await _removePlatformBond();
  }

  /// Injectable bond remover — production removes the OS bond via
  /// flutter_blue_plus; tests inject a counter so the exactly-once semantics
  /// of the fifth-failure reset are assertable off-device.
  @visibleForTesting
  Future<void> Function()? debugBondRemover;

  /// Drop the OS-level bond so the next attempt re-pairs from scratch. The
  /// attempt itself belongs to the existing reconnect owner — this NEVER
  /// starts a nested reconnect.
  ///
  /// Android only: iOS gives no API for removing a pairing, so there the user
  /// has to forget the device in Settings — say so in the log rather than
  /// pretending the reset happened.
  Future<void> _removePlatformBond() async {
    final device = _session?.device;
    final remover = debugBondRemover;
    if (remover == null && !Platform.isAndroid) {
      _log('[HELLO gen5] $kHelloFailuresBeforeBondReset failed hellos — a bond '
          'reset is due, but this platform cannot remove a bond '
          'programmatically; the user must forget the device manually.');
      return;
    }
    if (remover == null && device == null) {
      _log('[HELLO gen5] bond reset due but there is no device to unbond.');
      return;
    }
    try {
      await (remover != null ? remover() : device!.removeBond());
      _log('[HELLO gen5] $kHelloFailuresBeforeBondReset failed hellos — '
          'platform bond removed; the next attempt re-pairs.');
    } catch (e) {
      _log('[HELLO gen5] bond removal failed: $e');
    }
  }

  Future<bool> _readClock() async {
    // Correlated on (sequence, opcode 11): the periodic RTC re-verify and the
    // read-back inside setClock() both put GET_CLOCK replies on this link, and
    // before correlation any of them could release this gate — including one
    // belonging to the PREVIOUS request.
    //
    // The 3 s ceiling is kept rather than the generic 5 s: this read sits
    // in the connect path and in the drain gate, and its timeout is a
    // proceed-on-the-last-verdict fallback, not a failure.
    final out = await _sendAwaited(
      Cmd.getClock, // band-correct opcode + body; gen4 sent to gen5 is silence
      const <int>[],
      timeout: _clockReadTimeout,
    );
    final resp = await out.response;
    if (resp != null) {
      // Whether gen4 firmware echoes the originating sequence is unproven; a
      // reply landing via the seq-zero fallback is the tell that it does not,
      // and one line per connect is the cheapest way to find out from the
      // field before anything is gated harder on the echo.
      if (resp.viaSeqZeroFallback) {
        _log(
          '[SYNC] GET_CLOCK reply matched via the seq-zero fallback — this '
          'band does not echo the originating sequence.',
        );
      }
      return true;
    }
    _log(
      out.written
          ? '[SYNC] GET_CLOCK went unanswered for '
              '${_clockReadTimeout.inSeconds}s — clock verdict is UNVERIFIED '
              'for this read; proceeding on the last known state '
              '(phone_clock_suspect=$_phoneClockSuspect).'
          : '[SYNC] GET_CLOCK was never written — clock verdict is UNVERIFIED '
              'for this read; proceeding on the last known state '
              '(phone_clock_suspect=$_phoneClockSuspect).',
    );
    return false;
  }

  /// How long [_readClock] waits for its correlated reply. A connected-link
  /// round trip
  /// is tens of milliseconds; this is sized to survive a burst of historical
  /// frames queued ahead of the response, not to be a plausible steady state.
  static const Duration _clockReadTimeout = Duration(seconds: 3);

  /// On-device wake alarm (SET_ALARM_TIME = 0x42), band-generation aware via
  /// [AlarmPayloads.setPayloadForBand]:
  ///
  /// WHOOP 4 — the REV-1 9-byte form the firmware actually EXECUTES:
  /// ```
  ///   [0]      0x01              rev-1 form marker
  ///   [1..5]   u32 epoch-sec LE  the wake time
  ///   [5..7]   u16 subsec  LE    (millis % 1000) * 32768 ~/ 1000 (1/32768 s units)
  ///   [7..9]   u16 haptic-mode   0 = the stock wake buzz
  /// ```
  /// This is what the official WHOOP app sends (btsnoop wire capture), and on
  /// our band (fw 41.17.4, 2026-08-19/20) it fired autonomously at the armed
  /// second (HAPTICS_FIRED 60 + STRAP_DRIVEN_ALARM_EXECUTED 57, then
  /// auto-disable 59) while the rich 0x04 form previously armed here latched
  /// (event 56) without executing. Execution of the rich form is
  /// firmware-dependent — at least one other WHOOP 4 executes it (see
  /// [AlarmPayloads]). The 7-byte short form ([setAlarmSimple]) is rev-1
  /// minus the haptic-mode u16 — the same bytes on the wire once padded, not
  /// a distinct form.
  ///
  /// WHOOP 5 — the rich 21-byte slot-1 body, unchanged (#194; index 0 is
  /// rejected with `arm info is invalid, error 0xb`).
  ///
  /// The strap confirms via event 56 and reports firing via 57/58 + 60 —
  /// delivered through the band's history stream (typically the NEXT sync),
  /// not necessarily live.
  ///
  /// Returns the wall-clock instant armed, or null when the strap did not take
  /// the alarm — so the caller never persists a phantom alarm. Null means one
  /// of two things, both of them "there is no alarm on that band":
  ///
  ///  * the write never left the phone, or
  ///  * the strap answered and REFUSED it — a FAILURE/UNSUPPORTED outer result,
  ///    or an alarm-status byte from the input-rejection family.
  ///    That byte is "in addition to" the outer result and the doc says to
  ///    check both — a strap can answer SUCCESS and still report `invalid
  ///    alarm time`. The `arm info is invalid, error 0xb` seen when arming slot
  ///    0 on a WHOOP 5 is precisely status 11, `invalid_alarm_id`, arriving
  ///    through this byte.
  ///
  /// An UNANSWERED arm is deliberately NOT a refusal: it returns [when] as
  /// before. Correlation is new here and unproven on every strap; failing an
  /// arm because a read-back never came back would break wake alarms on any
  /// band that does not echo the originating sequence. The log line is the
  /// signal that the arm went out unconfirmed.
  Future<DateTime?> setAlarm(
    DateTime when, {
    int index = 0,
    List<int>? haptics,
  }) async {
    final isGen5 = _session?.band.isGen5 ?? false;
    if (isGen5) {
      // Official WHOOP app SET_CLOCKs before SET_ALARM; refresh RTC drift first.
      await setClock();
      await Future.delayed(const Duration(milliseconds: 120));
    }
    // Arm in the STRAP's RTC frame. The strap fires the wake alarm autonomously
    // on its OWN clock, so if that clock is offset from wall time (SET_CLOCK not
    // latched / drift) the raw wall epoch fires at the wrong strap-time — or
    // never (a raw wall epoch is decades ahead of a strap clock still near its
    // factory epoch). (Historical note: drift was once blamed for the gen4
    // silent alarm, and later the payload form — which held on fw 41.17.4 but
    // is firmware-dependent, see the doc above. The shift stays either way:
    // it is correct for a genuinely offset RTC.) Fall back to
    // the raw epoch when we have no correlation yet (e.g. just after a
    // reconnect, before this session's GET_CLOCK reply). Frame conversion +
    // generation dispatch live in the pure [AlarmPayloads]; the gen4 rev-1
    // byte layout itself is sourced from `openstrap_protocol`.
    final ref = _clockRef;
    final driftSec = ref?.driftSec ?? 0;
    final armWhen = AlarmPayloads.toStrapFrame(when, driftSec);
    final payload = AlarmPayloads.setPayloadForBand(
      armWhen,
      isGen5: isGen5,
      index: index,
      haptics: haptics,
    );
    final out = await _sendAwaited(Cmd.setAlarmTime, payload);
    // rev-1 has no slot byte — payload[1] there is an epoch byte, so only the
    // gen5 rich body logs an idx.
    _log(
      'SET_ALARM_TIME (${isGen5 ? "gen5 rich index1" : "rev1"} ${payload.length}B) '
      '→ wallSec=${when.millisecondsSinceEpoch ~/ 1000} '
      'strapSec=${armWhen.millisecondsSinceEpoch ~/ 1000} drift=${driftSec}s '
      'correlated=${ref != null} subsec=${AlarmPayloads.subsecOf(armWhen)} '
      '${isGen5 && payload.length >= 2 ? 'idx=${payload[1]} ' : ''}'
      'write=${out.written ? 'ok' : 'FAILED'}',
    );
    if (!out.written) return null;
    // Worst case here is the awaiter's single 5 s timeout, applied once, with
    // no resend — arming is a user-facing action, not a background poll, and a
    // duplicate SET after a slow-but-successful one would rewrite the strap's
    // stored deadline.
    final resp = await out.response;
    if (resp == null) {
      _log('[ALARM] arm UNCONFIRMED — no correlated SET_ALARM_TIME reply. '
          'Treating the write as the arm (the strap may not echo the '
          'originating sequence); verify with getAlarm().');
      return when;
    }
    final code = (resp.fields['alarm_status'] as num?)?.toInt();
    final name = resp.fields['alarm_status_name'] as String?;
    final rejected = resp.failed ||
        resp.unsupported ||
        (code != null && AlarmStatus.isInputRejection(code));
    if (rejected) {
      _log('[ALARM] arm REJECTED by the strap — result=${resp.status} '
          'alarm_status=$code ($name). NOT recording an alarm: there is '
          'nothing armed on the band.');
      return null;
    }
    _log('[ALARM] arm accepted — result=${resp.status} '
        'alarm_status=${code ?? 'absent'} (${name ?? 'no status byte'}).');
    return when;
  }

  /// Time-only alarm (SET_ALARM_TIME = 0x42), SHORT 7-byte form:
  /// `[0x01][u32 epoch-sec LE][u16 subsec LE]`. Kept for diagnostics/parity —
  /// it is the rev-1 form minus the trailing haptic-mode u16 and pads to the
  /// identical frame when that u16 is 0, so it is not a distinct wire form.
  /// Use [setAlarm], which also converts to the strap's RTC frame; this sends
  /// the raw epoch.
  Future<void> setAlarmSimple(DateTime when) async {
    await _send(Cmd.setAlarmTime, AlarmPayloads.simple(when));
    _log('SET_ALARM_TIME (simple 7B) → '
        'sec=${when.millisecondsSinceEpoch ~/ 1000}');
  }

  /// Read the armed alarm back. Body is band-specific (see
  /// [AlarmPayloads.getPayloadForBand]) — gen5 rejects gen4's operand-less
  /// revision-1 body.
  Future<void> getAlarm({int? id}) {
    final isGen5 = _session?.band.isGen5 ?? false;
    return _send(
      Cmd.getAlarmTime,
      AlarmPayloads.getPayloadForBand(
        isGen5: isGen5,
        id: id ?? AlarmPayloads.gen5Slot,
      ),
    );
  }

  /// Fire the alarm haptics IMMEDIATELY — a "test buzz" so the user can confirm
  /// the strap actually fires before trusting the scheduled wake.
  ///
  /// WHOOP 4: RUN_ALARM (0x44) `[0x01]`.
  /// WHOOP 5: RUN_ALARM does not buzz on hardware we tested; use the same
  /// Maverick `0x13` short pulse as Find-band. Do NOT STOP_HAPTICS first —
  /// on gen5 that can race and swallow the buzz.
  Future<void> runAlarm() async {
    if (_session?.band.isGen5 ?? false) {
      await _send(
        Cmd.runHapticPatternMaverick,
        AlarmPayloads.gen5MaverickBuzz(),
      );
      return;
    }
    await _send(Cmd.runAlarm, AlarmPayloads.runNow);
  }

  /// Cancel the on-device alarm (DISABLE_ALARM = 0x45). gen4 body `[0x01]`
  /// (the earlier `[0x00]` body was ACKed but did not clear the alarm); gen5
  /// needs revision 2 plus the alarm id, defaulting to "all slots" — see
  /// [AlarmPayloads.disableForBand].
  Future<void> disableAlarm({int? id}) {
    final isGen5 = _session?.band.isGen5 ?? false;
    return _send(
      Cmd.disableAlarm,
      AlarmPayloads.disableForBand(
        isGen5: isGen5,
        id: id ?? AlarmPayloads.gen5AllSlots,
      ),
    );
  }

  /// Read the strap's advertising name. gen5 does not implement gen4's
  /// advertising-name opcodes at all — it has its own pair, which is why the
  /// opcode AND the body come from the band's command table.
  Future<void> getStrapName() {
    final c = (_session?.entry ?? kWhoopGen4).commands;
    return _send(c.getAdvertisingName, c.getAdvertisingNameBody);
  }

  /// Rename the strap. Payload: [0x01][name length u8][ASCII name bytes][u32 0].
  /// Same body on both generations; only the opcode differs.
  Future<void> setStrapName(String name) async {
    // Cap at 20 ASCII chars (matches the reference + the GET decoder's length
    // assumption); the length byte then always stays < 0x20.
    final ascii = name.codeUnits
        .where((c) => c >= 0x20 && c < 0x7f)
        .take(20)
        .toList();
    final payload = <int>[0x01, ascii.length, ...ascii, 0, 0, 0, 0];
    await _send(
      (_session?.entry ?? kWhoopGen4).commands.setAdvertisingName,
      payload,
    );
    _log('SET_ADVERTISING_NAME → "$name"');
  }

  // main's throttled poll (a raw send here was 2,880 round-trips a day), and
  // the branch's gen5 HELLO, which is a different opcode on Maverick.
  Future<void> getBattery() => _pollBatteryIfDue(force: true);
  Future<void> getHello() {
    final c = (_session?.entry ?? kWhoopGen4).commands;
    return _send(c.hello, c.helloBody);
  }
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
        AlarmPayloads.gen5MaverickBuzz(),
      );
    }
    return _send(Cmd.runHapticsPattern, [pattern, 0, 0, 0, 0]);
  }

  // ── live HR / IMU ownership reconciler (#287) ───────────────────────────────

  /// Recompute the owners' intent and walk this link's applied streams towards
  /// it. Safe to call at any time from any state transition; a no-op when not
  /// connected. The returned future completes when the pass that will observe
  /// the caller's change has finished (a caller that coalesces behind a
  /// running pass awaits that pass — it re-reads the owners before it ends).
  Future<void> reconcileLiveStreams() => _reconcileLive();

  /// An explicit foreground user action whose feature needs the 100 Hz stream
  /// (a workout start): clear the sticky marginal-radio fallback and reconcile.
  /// The fallback protects a struggling radio from the high-rate flood but
  /// never resets on its own, so once tripped every later workout counted 0
  /// steps for the rest of the process lifetime. Here the flood is the point,
  /// and if the radio genuinely cannot sustain it the detectors re-trip (and
  /// re-downgrade) within seconds.
  Future<void> clearRadioFallbackAndReconcile() {
    if (state.standardHrFallback) {
      _log('Radio fallback: cleared by explicit user action — retrying the '
          'full live set.');
      state.standardHrFallback = false;
      _marginalRadio.reset();
      _frameCorruption.reset();
      onState(state);
    }
    return _reconcileLive();
  }

  /// Tests only: the keep-alive's re-arm request, without the rest of the
  /// tick (its liveness fuse would bounce a fake link with no inbound traffic).
  @visibleForTesting
  Future<void> debugReassertLiveStreams() {
    _liveReassert = true;
    return _liveRun?.future ?? _reconcileLive();
  }

  /// Tests only: an OS-style link drop — the non-intentional teardown plus
  /// the `idle` phase [_onLinkDown] surfaces afterwards.
  @visibleForTesting
  Future<void> debugDropLink() async {
    await _teardownSession(intentional: false);
    _setPhase(BleConnState.idle);
  }

  LiveStreamIntent _desiredLive() {
    if (_liveShutdown) return LiveStreamIntent.off;
    return desiredLiveStreams(
      liveOwners?.call() ?? LiveStreamOwners.none,
      gen5: _session?.band.isGen5 ?? false,
      standardHrFallback: state.standardHrFallback,
    );
  }

  /// True once [session] is no longer the link we started a write on.
  bool _liveStale(_Session session, int generation) =>
      generation != _linkGeneration ||
      !identical(_session, session) ||
      !session.connected ||
      session.closing;

  /// The ONLY writer of the realtime-HR toggle (opcode 3) and the high-rate
  /// bundle (gen5: IMU opcode 106; gen4: R10/R11 + IMU + optical).
  ///
  /// SERIALIZED and COALESCING, same shape as [_applyLinkPriority]: desired is
  /// recomputed inside the loop after every await, one transition is written
  /// per iteration, applied moves only after that write succeeded and only if
  /// the link it was written to is still the live one, and the loop runs until
  /// applied equals the NEWEST desired. A failed write marks its bit dirty
  /// (the strap may be in either state) and ends the pass — the keep-alive
  /// tick retries; spinning here against a refusing radio would hammer it.
  Future<void> _reconcileLive() {
    final running = _liveRun;
    if (running != null) {
      _liveRestale = true;
      return running.future;
    }
    final run = _liveRun = Completer<void>();
    () async {
      // gen4's OFF-tail head (`03(1)`) belongs to the old HR-only downgrade,
      // i.e. to a bundle OFF on a link whose HR was ALREADY on; a pass that
      // armed HR itself moments ago must not send it twice.
      var hrArmedThisPass = false;
      try {
        do {
          _liveRestale = false;
          final session = _session;
          // Physically connected is not enough: `connected` is true from the
          // moment the link is up, before discovery, bonding, the subscribes
          // and INIT. A stale pass that loops onto a replacement session — or
          // an owner nudge landing mid-bootstrap — must not put live toggles
          // into that sequence. Only a LISTENING (post-READY) link is written
          // to; the app's post-connect reconcile applies the intent after.
          if (session == null ||
              !session.connected ||
              session.closing ||
              _phase != BleConnState.listening ||
              !_liveReady) {
            return;
          }
          final want = _desiredLive();
          final gen5 = session.band.isGen5;
          final step = nextLiveStreamStep(
            applied: _liveApplied,
            desired: want,
            imuFresh: _imuFresh && !gen5,
            imuDirty: _imuDirty,
            hrDirty: _hrDirty,
          );
          final generation = _linkGeneration;
          if (step == null) {
            if (_liveReassert) {
              _liveReassert = false;
              await _reassertLive(session, generation);
            }
            continue;
          }
          // The fast interval is earned by the flood: ask BEFORE it starts.
          if (step == LiveStreamStep.imuOn) unawaited(_applyLinkPriority());
          final r = await _writeLiveStep(
            step,
            session,
            generation,
            hrHead: want.hr && !hrArmedThisPass,
          );
          if (r == _LiveWrite.stale || _liveStale(session, generation)) {
            // Do not record it against the dead link (teardown already reset
            // its state); loop once more so a replacement session, if there is
            // one, gets its own pass.
            _log('Live stream step ${step.name} completed after teardown — '
                'discarded.');
            _liveRestale = true;
            continue;
          }
          if (r == _LiveWrite.failed) {
            if (step.isImu) {
              _imuDirty = true;
            } else {
              _hrDirty = true;
            }
            _log('Live stream step ${step.name} failed — will retry on the '
                'next keep-alive tick.');
            // A nudge that arrived during the failed write (a new owner, or
            // disconnect()'s shutdown intent) is still honoured: recompute
            // once more. Only a quiet failure exits. Bounded, because restale
            // is only ever set by an external nudge, never by this loop.
            if (!_liveRestale) break;
            continue;
          }
          _liveApplied = applyLiveStreamStep(_liveApplied, step);
          if (step == LiveStreamStep.hrOn) hrArmedThisPass = true;
          if (step.isImu) {
            _imuFresh = false;
            _imuDirty = false;
          } else {
            _hrDirty = false;
          }
          if (step == LiveStreamStep.imuOff) _armTime = null;
          if (step == LiveStreamStep.hrOff) {
            state.liveHr = null;
            onState(state);
          }
          _log('Live streams: ${step.name} applied → '
              'hr=${_liveApplied.hr} imu=${_liveApplied.imu}.');
          unawaited(_applyLinkPriority()); // the live consumer set changed
          _liveRestale = true; // recompute until applied == newest desired
        } while (_liveRestale);
      } catch (e) {
        // Never poison the shared future: nudges are fired unawaited from
        // state transitions, so an error here would surface as an uncaught
        // zone error in whoever happened to be awaiting. Log; the next nudge
        // or keep-alive tick converges.
        _log('Live stream reconcile failed: $e');
      } finally {
        _liveRun = null;
        run.complete();
      }
    }();
    return run.future;
  }

  /// One transition on the wire. Every write is pinned to [session] and the
  /// link is re-checked after every await (writes AND delays), so a gen4
  /// bundle interrupted by a teardown can never continue onto a replacement
  /// link. `ok` only when every sub-write succeeded.
  ///
  /// gen5 sequences: HR `03(1)` / `03(0)`; IMU `6A(rev1,1)` / `6A(rev1,0)`.
  /// Optical opcodes 107/108 are never written on gen5 — 0x6B is the
  /// SAVE-to-history toggle there and 0x6C's role is unconfirmed on hardware.
  ///
  /// gen4 sequences are byte-for-byte what the old enable / HR-only / disable
  /// methods wrote, including the spacing, so nothing changes for gen4 users:
  ///   ON   `03(1)` · 100 ms · `3F(1)` · 100 ms · `6A(1)` · 100 ms · `6B(rev1,1)`
  ///   OFF  [`03(1)` when HR stays on and was not just armed by this pass —
  ///        the old HR-only downgrade's head, see [hrHead]] ·
  ///        `6C(rev1,0)` · 60 · `6B(rev1,0)` · 60 · `3F(0)` · 60 · `6A(0)` · 60
  ///   then `03(0)` · 60 when HR goes off too.
  /// R10/R11 OFF persists across reconnects on gen4, which is why a fresh
  /// gen4 link replays the OFF tail defensively (see `nextLiveStreamStep`).
  Future<_LiveWrite> _writeLiveStep(
    LiveStreamStep step,
    _Session session,
    int generation, {
    required bool hrHead,
  }) async {
    final c = session.entry.commands;
    // A band with the R10/R11 opcode carries the legacy high-rate bundle
    // (gen4); a band without it (gen5) rides the IMU toggle alone.
    final r10 = c.r10R11Realtime;
    Future<bool> gap(int ms) async {
      await Future<void>.delayed(Duration(milliseconds: ms));
      return true;
    }

    Future<bool> Function() send(int opcode, List<int> body) =>
        () => _send(opcode, body, owner: session);
    final ops = <Future<bool> Function()>[];
    switch (step) {
      case LiveStreamStep.hrOn:
        ops.add(send(Cmd.toggleRealtimeHr, const [0x01]));
      case LiveStreamStep.hrOff:
        ops
          ..add(send(Cmd.toggleRealtimeHr, const [0x00]))
          ..add(() => gap(60));
      case LiveStreamStep.imuOn:
        // marginal-radio detector measures arm→drop latency of the flood
        _armTime = DateTime.now();
        ops.add(() => gap(100));
        if (r10 != null) {
          ops
            ..add(send(r10, const [0x01]))
            ..add(() => gap(100));
        }
        ops
          ..add(() => _sendToggleImu(true, owner: session))
          ..add(() => gap(100));
        // Only where ENABLE_OPTICAL_DATA is the LIVE toggle (gen4). On gen5 it
        // is the SAVE-to-history toggle, next door to the persistent-optical
        // footgun that leaves the LEDs on and drains the battery.
        if (c.opticalDataIsLiveToggle) {
          ops.add(send(Cmd.enableOpticalData, const [revision1, 0x01]));
        }
      case LiveStreamStep.imuOff:
        if (r10 != null) {
          if (hrHead) ops.add(send(Cmd.toggleRealtimeHr, const [0x01]));
          ops
            ..add(send(Cmd.toggleOpticalMode, const [revision1, 0x00]))
            ..add(() => gap(60))
            ..add(send(Cmd.enableOpticalData, const [revision1, 0x00]))
            ..add(() => gap(60))
            ..add(send(r10, const [0x00]))
            ..add(() => gap(60));
        }
        ops
          ..add(() => _sendToggleImu(false, owner: session))
          ..add(() => gap(60));
    }
    // ponytail: "ok" means the GATT write-with-response was delivered, as the
    // old methods judged it; a toggle's own correlated reply is not awaited.
    // Correlating 0x03/0x6A replies (`_sendAwaited`) is the upgrade once the
    // strap's reply behaviour for these toggles is confirmed on hardware.
    var ok = true;
    for (final op in ops) {
      if (!await op()) ok = false;
      if (_liveStale(session, generation)) return _LiveWrite.stale;
    }
    return ok ? _LiveWrite.ok : _LiveWrite.failed;
  }

  /// The keep-alive's re-arm, run only from a CONVERGED pass: the band's live
  /// toggles can silently die, so what is applied is re-sent. The high-rate
  /// re-arm is unconditional (a flowing HR stream is no proof the IMU stream
  /// is alive; it runs only while something owns the flood); the HR re-arm is
  /// evidence-gated — sent only when no valid reading has arrived for 60 s,
  /// because blindly re-sending it every 30 s was ~2,880 write-with-response
  /// round trips a day whose payload was a no-op. Results are ignored: this is
  /// a re-assert, not a transition, so applied and dirty are untouched.
  Future<void> _reassertLive(_Session session, int generation) async {
    if (_liveApplied.imu) {
      final r10 = session.entry.commands.r10R11Realtime;
      if (r10 == null) {
        await _sendToggleImu(true, owner: session);
      } else {
        await _send(r10, const [0x01], owner: session);
      }
      if (_liveStale(session, generation)) return;
    }
    if (_liveApplied.hr) {
      final hrAtMs = state.liveHrAt;
      final hrDelivering = hrAtMs != null &&
          DateTime.now().millisecondsSinceEpoch - hrAtMs < 60 * 1000;
      if (!hrDelivering) {
        await _send(Cmd.toggleRealtimeHr, const [0x01], owner: session);
      }
    }
  }

  /// Idempotent, intentional teardown. Safe to call repeatedly.
  Future<void> disconnect() => _locked(() async {
    // Desired is forced to OFF for the shutdown reconcile AND the teardown, so
    // an owner change cannot re-arm the closing link in either await window.
    // Not gated on `liveEnabled`: an ON may be in flight with applied still
    // off. Cleared in `finally` — a throwing subscription cancel must not
    // leave the latch stuck and every later connection silent.
    _liveShutdown = true;
    try {
      if (_session?.connected == true) {
        await _reconcileLive(); // a real barrier: awaits the in-flight pass
      }
      if (_session?.connected == true && _highFreqModeRequested) {
        try {
          await _disableHighFreqSync(reason: 'intentional_disconnect');
        } catch (_) {}
      }
      await _teardownSession(intentional: true);
    } finally {
      _liveShutdown = false;
    }
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
    // SYNCHRONOUSLY, before any await: see `_Session.closing`.
    session.closing = true;
    // Live arming is per-connection: applied clears now, the owners' intent
    // survives and is re-applied on the next link's first reconcile. A fresh
    // link's high-rate bundle is unknown again (gen4's R10/R11 OFF persists on
    // the strap), and nothing is dirty on a link that no longer exists.
    _liveApplied = LiveStreamIntent.off;
    _liveReady = false;
    _imuFresh = true;
    _imuDirty = false;
    _hrDirty = false;
    // Per-link state: Android resets the connection interval on every new GATT
    // connection, so a remembered priority would make the next link skip its
    // request. The battery stamp resets too — a fresh session should read the
    // level once rather than inheriting the last link's 5-minute cooldown.
    _appliedPriority = null;
    _lastBatteryPollAt = null;
    _lastLinkValidAt = null;
    // Every failure exit in `_doConnect` between setting this and `sendInit`
    // skips the clear in sendInit's finally, which would leave the target
    // pinned at `high` for the life of the process.
    _connectSetup = false;
    // Nothing outstanding can be answered by a link that is going away, and a
    // caller parked on a 5 s await through a teardown delays whatever the
    // reconnect wants to do next. Resolve them all as unanswered now.
    _awaiter.failAll();
    _linkGeneration++;
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
    // `_armTime` used to survive teardown, so the marginal-radio detector
    // measured the NEXT session's drop against the PREVIOUS session's arm and
    // permanently downgraded live streams on the evidence of a session that
    // never armed the raw flood.
    _armTime = null;
    // ALWAYS drop the radio link, not just on an intentional disconnect. Every
    // self-initiated bounce (liveness fuse, ACK-exhausted, commit-failed) tears
    // the session down non-intentionally and expects a NEW GATT connection —
    // but FBP treats connect() on a still-connected device as a no-op, so the
    // reconnect re-ran setup over the same zombie link and the fuse just fired
    // again 120 s later, forever. On an OS-driven drop this is a harmless
    // no-op.
    try {
      await device.disconnect();
    } catch (_) {}
  }

  void _setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    // An offload is the one thing that genuinely needs the fast interval; as
    // soon as it ends the link steps back down (issue #200).
    unawaited(_applyLinkPriority());
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

  /// Make sure a GET_CLOCK reply always carries a `clock_epoch` — INCLUDING an
  /// implausible one.
  ///
  /// `parseCommandResponse` decodes the field for both generations now, but it
  /// emits it only when the value already looks like a real wall-clock time.
  /// That silently disabled the whole point of [ClockPolicy.shouldSetClock],
  /// which exists to detect a strap whose RTC was never set (a 1970s value):
  /// the one reading that proves the fault produced no field at all, so the
  /// policy could never fire and the RTC was never corrected. Read the field at
  /// its documented offset and pass it through verbatim; judging it is the
  /// policy's job, not the decoder's.
  Decoded _maybeAugmentClockEpoch(Frame frame, Decoded decoded) {
    if (decoded.kind != 'cmd_response') return decoded;
    final op = decoded.fields['opcode'];
    final isGen5Clock = op == Cmd.getClockGen5;
    if (!isGen5Clock && op != Cmd.getClock) return decoded;
    if (decoded.fields.containsKey('clock_epoch')) return decoded;
    // The strap answers every command with a status byte. A failure or an
    // unimplemented-opcode reply leaves the body unpopulated, so reading an
    // epoch out of it hands ClockPolicy a stale value from whatever the buffer
    // held last — and this path deliberately forwards implausible clocks so the
    // unset-RTC case is reachable, which means nothing downstream would filter
    // it back out.
    final status = decoded.fields['cmd_status'];
    if (status != null && status != 1) return decoded;
    final inner = frame.inner;
    final payload =
        inner.length > 3 ? Uint8List.sublistView(inner, 3) : Uint8List(0);
    // Reply body starts at payload[2] (payload[0] = echoed request seq,
    // payload[1] = status). gen5 leads the body with a revision byte and puts
    // the u32 seconds at payload[3]; gen4 has them at payload[2].
    final at = isGen5Clock ? 3 : 2;
    if (payload.length < at + 4) return decoded;
    final v = u32(payload, at);
    // Only the UNSET-RTC case is worth surfacing. Protocol already emits
    // clock_epoch for anything inside the plausible window, so everything that
    // reaches here is outside it — below the floor (the low strap counter this
    // augmenter exists for) or above the ceiling, which is a corrupt reply and
    // ~4% of u32 space. Forwarding the high side sets `_phoneClockSuspect` off
    // a garbage reading, and that defers the history refresh AND skips the very
    // SET_CLOCK that would repair the strap.
    if (v >= kMinPlausibleUnix) return decoded;
    return Decoded(decoded.kind, <String, dynamic>{
      ...decoded.fields,
      'clock_epoch': v,
    });
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
  }) {
    // Safe-trim requires the atomic commit sink: onRecordsBatch alone cannot
    // persist archives or the trim cursor. Production always wires onCommit;
    // forbid the latent hole where archive-only chunks would ACK and trim
    // flash that was never stored.
    if (onRecordsBatch != null && onCommit == null) {
      throw ArgumentError(
        'DrainController: onRecordsBatch without onCommit cannot persist '
        'archives or the trim cursor — buffered historical drains require '
        'onCommit',
      );
    }
  }

  /// Whether HISTORY_END may be ACKed under the safe-trim invariant.
  ///
  /// Only [onCommit] can bank raws + archives + cursor in one transaction.
  /// Both-sinks-null (unbuffered / test-only) fire-and-forgets via [onRecord]
  /// and must not trim.
  bool get supportsSafeTrim => onCommit != null;

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
  int get bufferedArchives => _archives.length;

  /// Archives that represent real forward progress, i.e. everything EXCEPT the
  /// plausibility drops. A burst of records we simply cannot decode has still
  /// been preserved and may be trimmed; a burst we merely distrusted has not.
  int get bufferedProgressArchives =>
      _archives.where((a) => a.reason != kGateDroppedReason).length;
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
  // whose 8-byte token differs from the last one means the cursor moved — but
  // only when the burst also banked durable rows. An empty token-only ACK
  // (console / drop-only) used to flip this true and feed auto-continue while
  // the durable frontier stayed frozen.
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

  /// Buffer only when the atomic commit path exists. Unbuffered mode
  /// (test-only) must not look like it banked durable rows for trim.
  bool get _buffering => onCommit != null;
  /// Every frame received this burst, ALL types. There used to be a second
  /// getter, `currentBurstPacketCount`, with the identical body — one
  /// measurement presented in the mismatch log and in the sync ledger under two
  /// labels as if the two were independent.
  int get currentBurstTrafficCount => burstStats.totalTrafficPacketCount;
  int get currentBurstHistoricalPacketCount => burstStats.historicalPacketCount;
  String get currentBurstBreakdown => burstStats.breakdownString;

  /// [revision] is the record version byte the ingest path already read off
  /// the frame (-1 when the frame was too short to have one).
  void onHistoricalRecord(RawRecord raw, Sample? sample, int revision) {
    records++;
    recordsThisOffload++;
    _lastProgressAt = DateTime.now();
    // The tally covers the marker-to-marker window only ([closeBurstTally]) —
    // the record itself is still banked either way.
    if (!_burstTallyClosed) {
      burstStats.onHistoricalData(raw.packetType, raw.counter, revision);
    }
    if (_buffering) {
      _raws.add(raw);
      _samples.add(sample);
    } else {
      // Unbuffered fire-and-forget: production never takes this branch
      // (`onCommitBatch` is always set, and this wiring is documented as
      // non-trimmable / test-only), but an un-handled async error here would
      // lose the record AND surface as an unhandled-error crash rather than a
      // log line. Nothing else can catch a throw off an `unawaited` future.
      unawaited(onRecord(sample, raw).catchError(
        (Object e) => log('[SYNC] unbuffered record persist failed: $e'),
      ));
    }
  }

  /// An undecodable historical record (unknown/unsupported version, or a decode
  /// that failed). Buffered for archival in the next atomic commit — never dropped,
  /// never ACKed away before it is durably set aside.
  void onUndecodableRecord(ArchiveRecord a) {
    // A plausibility-gated drop is NOT progress, in either counter.
    //
    // `recordsThisOffload` feeds `banked` at the HISTORY_COMPLETE terminal: a
    // strap with a wandered RTC can drop every record and still reach COMPLETE,
    // and counting those resets the empty-sync streak so `syncClockLost` never
    // fires and the RTC remedy never surfaces. `records` is not diagnostics
    // either — `report.records > 0` schedules a derive pass and sets the sync
    // ledger to `partial`, so counting drops there means a 50k-record offload
    // that banked NOTHING still triggers a full derive, every backfill, forever.
    //
    // A record we merely could not DECODE is different: it is archived
    // durably and is genuinely ACKable progress, so it counts in both.
    //
    // `_lastProgressAt` always bumps — frames really are arriving, and it drives
    // the 60 s idle watchdog, which must not fire mid-burst.
    if (a.reason != kGateDroppedReason) {
      records++;
      recordsThisOffload++;
      // The band's expected count tallies every type-47 frame it TRANSMITTED,
      // decodable or not. The gen5
      // deep buffers (v20/v21/v26/v22) and any future firmware's revisions all
      // arrive through this path, so leaving them uncounted makes every burst
      // that carries one permanently short at the count gate. Same counter the
      // decoded path uses, so the breakdown line stays truthful (V22=…,
      // unknown=…). Gate-dropped archives stay excluded: validateBurst adds
      // them back via droppedThisBurst, and counting them here too would
      // double-count.
      if (a.packetType == PacketType.historicalData && !_burstTallyClosed) {
        // The revision moved to the caller when the decoded path started
        // carrying one. An archive has no decoded record, so read it off the
        // frame the same way the callee used to: inner[1]. A frame too short
        // to have one passes -1, which the callee buckets as unknown.
        final inner = hexToBytes(a.hex);
        burstStats.onHistoricalData(
          a.packetType,
          a.counter,
          inner.length < 2 ? -1 : inner[1],
        );
      }
    }
    _lastProgressAt = DateTime.now();
    if (_buffering) {
      _archives.add(a);
    } else {
      // Same unbuffered-branch reasoning as onHistoricalRecord above.
      unawaited((onArchive?.call(a) ?? Future<void>.value()).catchError(
        (Object e) => log('[SYNC] unbuffered archive persist failed: $e'),
      ));
    }
  }

  void noteBatchAcked() => batches++;

  void onBurstEvent() {
    if (!_burstTallyClosed) burstStats.onEvent();
  }

  void onBurstConsole() {
    if (!_burstTallyClosed) burstStats.onConsole();
  }

  /// [droppedThisBurst] = records the plausibility gate rejected during this
  /// same burst (stale/wandering-clock block) — never tallied into
  /// [currentBurstTrafficCount] (they're never stored), but the band's own
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
      receivedTrafficCount: currentBurstTrafficCount,
      droppedThisBurst: droppedThisBurst,
      consecutiveFailedValidations: consecutiveValidationFailures,
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

  /// The engine's task-ending abort boundary fired: this offload is over
  /// WITHOUT a HISTORY_COMPLETE. Releases any [awaitComplete] waiter with an
  /// incomplete report on its next tick — no HISTORY_COMPLETE is coming (the
  /// terminal latch drops every post-terminal marker), and without this the
  /// waiter sat out the 60 s idle window or its full timeout against a drain
  /// that had already ended.
  void onTaskTerminal() {
    _taskTerminal = true;
  }

  bool _taskTerminal = false;

  /// The task a waiter belongs to. Bumped by [startFreshTask] so a waiter
  /// armed for task N resolves the moment task N+1 is claimed — even when the
  /// claim lands BETWEEN the task's end and the waiter's next once-a-second
  /// tick, which would otherwise reset the completion/terminal state under
  /// the old waiter and leave it parked against the replacement task.
  int _taskGeneration = 0;

  /// The current task's generation — so a caller holding a waiter's own
  /// generation (captured before [awaitComplete]) can tell whether the task
  /// it waited on is still the live one before acting on the outcome.
  int get taskGeneration => _taskGeneration;

  /// Outcome of each superseded task, by its generation: true when it had
  /// reached HISTORY_COMPLETE when the next claim took over (the immediate
  /// auto-continue case), false when it ended in a terminal or simply never
  /// completed. Without this a successful offload superseded before the
  /// waiter's next tick was reported as `complete=false`. Pruned to the last
  /// few generations — a waiter outlives its task by at most one tick.
  final Map<int, bool> _supersededTaskComplete = <int, bool>{};

  /// Re-arm for a fresh offload over the same connection (clears the COMPLETE flag
  /// so a new awaitComplete() blocks until the next HISTORY_COMPLETE).
  ///
  /// Does NOT clear the poison latch (see [beginBurst]) and does NOT clear
  /// the task-terminal flag ([startFreshTask] owns that): rearm also runs on
  /// every HISTORY_START, and a burst boundary must never be able to swallow
  /// a pending terminal out from under a parked waiter.
  void rearm() {
    _complete = false;
    _linkDown = false;
    _lastProgressAt = DateTime.now();
    burstStats.reset();
    _burstTallyClosed = false;
  }

  /// The band declared a new burst (HISTORY_START) — clear the poison latch.
  ///
  /// This used to live in [rearm], which conflated "we are asking for another
  /// offload" with "the band started a new burst". The abort→retry path re-arms
  /// 3 s after the idle watchdog threw a chunk away, while the abandoned burst's
  /// HISTORY_END is still in flight — so the terminal landed on a clean guard
  /// and its token was echoed, trimming exactly the records we dropped. Frames
  /// arrive in order, so a HISTORY_START proves the previous burst's terminal
  /// has already been handled (or is never coming) and the latch may clear.
  ///
  /// Deliberately does NOT touch [consecutiveValidationFailures]. A failed
  /// validation makes the band re-offer the SAME checkpoint, and that re-offer
  /// arrives WITH a replacement HISTORY_START — doc 05: a replacement START
  /// inside a running task discards the partial accumulator but KEEPS the
  /// failure counter. Resetting here meant a genuinely repeated bad checkpoint
  /// could never reach the terminal 15th attempt, and the counter's real
  /// boundary — the TASK — is [startFreshTask]. Marker-only re-offers (no
  /// START) accumulate the same way.
  void beginBurst() {
    _trimGuard.beginBurst();
    _burstTallyClosed = false;
  }

  /// A genuinely NEW history task has been claimed — called by the engine
  /// after the task claim succeeds and before opcode 22 asks the band to
  /// transmit. Doc 05: slack is based on failures within the CURRENT task and
  /// must never be inherited by a later one.
  ///
  /// The three lifecycle boundaries, which must not be conflated again:
  ///  * [startFreshTask] — US claiming a new task: the consecutive
  ///    validation-failure counter starts fresh (a fresh connection gets the
  ///    same effect from its brand-new controller).
  ///  * [rearm] — US re-arming for another offload on the same controller:
  ///    completion latch + burst tally only. Never the failure counter, never
  ///    the poison latch.
  ///  * [beginBurst] — the BAND declaring a burst boundary (HISTORY_START):
  ///    poison latch + tally. Never the failure counter.
  /// The one in-task reset stays where the contract puts it: a SUCCESSFUL
  /// validation ([validateBurst]).
  ///
  /// Also the waiter boundary: the outgoing task's outcome is recorded FIRST
  /// (so an [awaitComplete] waiter superseded before its next tick still
  /// reports whether ITS task completed or aborted), then the generation
  /// advances, the terminal flag clears, and the controller [rearm]s — one
  /// call is the whole claim, so no caller can order the outcome snapshot
  /// after the state it snapshots has been wiped.
  void startFreshTask() {
    _supersededTaskComplete[_taskGeneration] = _complete && !_taskTerminal;
    _supersededTaskComplete.removeWhere((g, _) => g + 8 < _taskGeneration);
    consecutiveValidationFailures = 0;
    _taskTerminal = false;
    _taskGeneration++;
    rearm();
  }

  /// A HISTORY_END closes the burst's wire window: the band computed its
  /// `expected` for the frames BETWEEN the markers, so members arriving after
  /// the terminal — console/event chatter during the ~2.5 s re-offer cycle
  /// above all — belong to no burst and must not push a short tally over the
  /// line into an ACK. A new HISTORY_START ([beginBurst]) reopens counting.
  void closeBurstTally() => _burstTallyClosed = true;
  bool _burstTallyClosed = false;

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
  /// is cleared only by [beginBurst] — a fresh HISTORY_START from the band.
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
    final raws = List<RawRecord>.from(_raws);
    final samples = List<Sample?>.from(_samples);
    final archives = List<ArchiveRecord>.from(_archives);
    final hadDurable = raws.isNotEmpty || archives.isNotEmpty;
    // Token changed AND we actually banked something — empty ACKs must not
    // look like cursor progress to auto-continue / stuck-strap.
    lastTrimAdvanced =
        tokenHex != null && tokenHex != _lastAckedToken && hadDurable;
    if (tokenHex != null) _lastAckedToken = tokenHex;
    _raws.clear();
    _samples.clear();
    _archives.clear();
    try {
      // Defense in depth (constructor already rejects onRecordsBatch-only):
      // never report durable success for buffered content without onCommit.
      if (raws.isNotEmpty || archives.isNotEmpty || tokenHex != null) {
        final commit = onCommit;
        if (commit == null) {
          throw StateError(
            'DrainController.commit requires onCommit to persist buffered '
            'rows / archives / trim cursor (had raws=${raws.length}, '
            'archives=${archives.length}, token=${tokenHex != null})',
          );
        }
        await commit(raws, samples, tokenHex, archives: archives);
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

  /// Resolve once the current offload reaches HISTORY_COMPLETE, the task ends
  /// through the abort boundary ([onTaskTerminal]), the link drops, or
  /// [timeout] elapses. Pure waiting — NO abort is ever sent (cutting the offload
  /// short is exactly what stalled the cursor). Polls the lightweight stop-evaluator
  /// every second.
  Future<SyncReport> awaitComplete({
    required bool Function() isLinkUp,
    Duration timeout = const Duration(seconds: 600),
  }) async {
    final evaluator = DrainStopEvaluator(timeout: timeout);
    final start = DateTime.now();
    final waiterGen = _taskGeneration;
    final done = Completer<SyncReport>();
    Timer.periodic(const Duration(seconds: 1), (t) async {
      if (done.isCompleted) {
        t.cancel();
        return;
      }
      // Terminal flag, OR this waiter's task was superseded by a new claim
      // (which resets the flags) before this once-a-second tick got to see
      // it. Either way the awaited offload is over; a superseded task
      // reports the outcome it actually reached — a COMPLETE immediately
      // followed by an auto-continue claim is a SUCCESS, not a failure.
      if (_taskTerminal || _taskGeneration != waiterGen) {
        final complete = _taskGeneration != waiterGen &&
            (_supersededTaskComplete[waiterGen] ?? false);
        t.cancel();
        // Deliberately NO flush here. A superseded waiter's task is over and
        // the REPLACEMENT task owns this controller's buffer: a tokenless
        // commit fired from the stale waiter would snapshot the
        // replacement's open-burst rows and could overlap its HISTORY_END
        // token commit — letting the ACK go out before those rows are
        // durable, which is THE commit-before-ACK violation. The terminal
        // case needs no flush either: every abort path commits or discards
        // its buffer before crossing the terminal boundary.
        log('[SYNC] await stop=${complete ? 'supersededComplete' : 'taskTerminal'}'
            ' — this offload ended ${complete ? 'complete (a new task claimed '
            'immediately after HISTORY_COMPLETE)' : 'without completing (abort '
            'boundary)'}.');
        done.complete(SyncReport(records, batches, complete));
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

  /// [revision] is the record version byte (inner[1]), which the caller has
  /// already read off the frame. This used to take the record's hex and parse
  /// the whole thing back into bytes to reach that one byte — a throwaway
  /// buffer per record, on every record of every offload.
  void onHistoricalData(int packetType, int counter, int revision) {
    if (packetType != PacketType.historicalData) return;
    if (revision < 0) {
      _unknownCount++;
      return;
    }
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
