// Data models shared across the app.

/// One decoded 1 Hz record (type-24 / R10): timestamp + counter + HR, plus the
/// sensor fields (RR beats, accel, SpO₂ raw, skin-temp raw) decoded ON-DEVICE
/// via proto.parseR24 — the app is local-first and owns the full sensor decode
/// (see LocalDb._queueDecodedOneHz); raw hex is kept as the replay ledger.
class Sample {
  final int tsEpoch;
  final int counter;
  final int hr; // 0 = off-wrist (never display as a heart rate)
  final List<int> rrIntervalsMs;
  final double? ax;
  final double? ay;
  final double? az;
  final int? spo2RedRaw;
  final int? spo2IrRaw;
  final int? skinTempRaw;

  Sample({
    required this.tsEpoch,
    required this.counter,
    required this.hr,
    this.rrIntervalsMs = const [],
    this.ax,
    this.ay,
    this.az,
    this.spo2RedRaw,
    this.spo2IrRaw,
    this.skinTempRaw,
  });

  /// Copy with an overridden [tsEpoch] — used by the clock-offset salvage path
  /// (a wandering/unset strap RTC offsets every record by the same amount, so a
  /// corrected+grid-snapped time is stamped back onto the decoded sample). All
  /// other decoded fields are preserved.
  Sample copyWith({int? tsEpoch}) => Sample(
    tsEpoch: tsEpoch ?? this.tsEpoch,
    counter: counter,
    hr: hr,
    rrIntervalsMs: rrIntervalsMs,
    ax: ax,
    ay: ay,
    az: az,
    spo2RedRaw: spo2RedRaw,
    spo2IrRaw: spo2IrRaw,
    skinTempRaw: skinTempRaw,
  );

  bool get wristOn => hr > 0;
  bool get hasDecodedOneHz =>
      ax != null &&
      ay != null &&
      az != null &&
      spo2RedRaw != null &&
      spo2IrRaw != null &&
      skinTempRaw != null;

  Map<String, dynamic> toDbMap() => {
    'ts': tsEpoch,
    'counter': counter,
    'hr': hr,
  };

  factory Sample.fromDbMap(Map<String, dynamic> m) => Sample(
    tsEpoch: m['ts'] as int,
    counter: m['counter'] as int,
    hr: m['hr'] as int,
  );
}

/// A raw historical record exactly as it came off the band — the source of truth.
/// We keep this even when decode succeeds so the cloud can re-decode opaque bytes.
class RawRecord {
  final int
  counter; // u32 @[3:7] for header records; 0 for counter-less live packets
  final int packetType; // inner[0]: 0x2F historical, 0x2B/0x28/0x33 live
  final String hex; // full inner bytes, hex — the idempotency key
  final int
  capturedAt; // epoch ms we received it (STORAGE age — used for pruning)
  final bool uploaded;
  // The record's REAL device timestamp, epoch SECONDS. This — not capturedAt —
  // is what the DerivationEngine buckets/windows days by, so a multi-day flash
  // backfill (all received in one sync, one capturedAt≈now) still splits into the
  // correct per-real-day buckets. Null here means "decode at insert / fall back to
  // capturedAt/1000"; the DB column is always non-null.
  final int? recTs;

  RawRecord({
    required this.counter,
    this.packetType = 0,
    required this.hex,
    required this.capturedAt,
    this.uploaded = false,
    this.recTs,
  });
}

/// A historical record we RECEIVED off the band but could NOT decode (an
/// unknown/unsupported record version that also failed the physiological
/// fallback). Rather than silently dropping it — which would lose a future
/// firmware's records forever while the UI still showed a clean sync — we
/// archive the raw bytes durably (never pruned) so they can be re-decoded once
/// the format is understood. Archived as part of the SAME durable commit that
/// runs BEFORE the HISTORY_END ACK, so the safe-trim invariant holds.
class ArchiveRecord {
  final int counter;
  final String hex; // full inner bytes, hex
  final int packetType; // inner[0]: 0x2F historical (the only archived kind)
  final int? recTs; // decoded record time if any survived; usually null
  final int capturedAt; // epoch ms we received it
  final String reason; // e.g. 'undecodable_v<version>'

  ArchiveRecord({
    required this.counter,
    required this.hex,
    required this.packetType,
    required this.capturedAt,
    required this.reason,
    this.recTs,
  });
}

/// Live, in-memory device state (not persisted; rebuilt each connection).
class DeviceState {
  String? address;
  String? serial;
  double? batteryPct;
  bool? charging;
  bool? wristOn;
  int? liveHr; // latest live HR from the foreground stream
  int? liveHrAt; // epoch ms
  int?
  alarmEpoch; // current strap alarm (unix sec) from GET_ALARM_TIME, if read
  String?
  strapName; // strap advertising name (editable via SET_ADVERTISING_NAME)
  String connection; // 'disconnected' | 'scanning' | 'connecting' | 'connected'

  // ── resumable-sync / reconnect-health flags ──────────────────────────────────
  /// MarginalRadioDetector tripped: the BT radio can't sustain the R10/R11 raw
  /// stream — next connect should stick to standard HR only.
  bool standardHrFallback = false;
  /// PostBondTimeoutLoopDetector tripped (#617): bond-then-instant-timeout loop —
  /// surface the re-pair guide to the user.
  bool needsRepairGuide = false;
  /// Monotonic count of bond REFUSALS this process (the createBond call the band
  /// rejects — link reachable but encryption denied). AppState feeds the delta
  /// into a BondRefusalGiveUp policy so a band that keeps refusing pauses the
  /// auto-reconnect loop instead of hammering the radio + draining battery.
  int bondRefusals = 0;
  /// BondRefusalGiveUp tripped: too many consecutive bond refusals in a row — the
  /// auto-reconnect loop is PAUSED (it would just pin the radio + drain the
  /// battery on a band that will never accept the bond). A manual user connect /
  /// re-pair still runs createBond and clears this on a successful bond.
  bool autoReconnectPaused = false;
  /// EmptySyncTracker tripped: ≥3 consecutive console-only offloads — the strap's
  /// RTC has likely lost sync.
  bool syncClockLost = false;
  /// StuckStrapDetector tripped: frontier frozen while the strap is ahead — a
  /// defensive reboot/clock-reset was attempted.
  bool strapNeedsReboot = false;
  /// Strap's own banked-data window from GET_DATA_RANGE (unix sec), for the
  /// session-relative plausibility gate + the UI's "history available" readout.
  int? dataRangeOldest;
  int? dataRangeNewest;

  /// Last GET_BODY_LOCATION_AND_STATUS (0x54) response, user-triggered only
  /// (never sent automatically). Raw ints — the UI resolves [bodyLocationRaw]
  /// via openstrap_protocol's GarmentDeviceLocation.fromValue. Confidence and
  /// status are raw firmware bytes with no confirmed scale/enum yet (APK
  /// ground-truth only surfaced the command + field layout, not their exact
  /// semantics) — shown as-is, never re-interpreted into a fabricated label.
  int? bodyLocationRevision;
  int? bodyLocationRaw;
  int? bodyLocationConfidence;
  int? bodyLocationStatus;
  int? bodyLocationCheckedAt; // epoch sec of the last successful read

  DeviceState({this.connection = 'disconnected'});
}
