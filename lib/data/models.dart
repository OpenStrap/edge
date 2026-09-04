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

  // ── Fields only a gen5 band sends (all null on gen4) ───────────────────────
  // NULL means "this band never reported it", and that is NOT the same as zero:
  // a fabricated 0-step day or a 0 °C skin temperature reads as real data
  // downstream. Every one of these stays nullable end to end, into the DB.

  /// Cumulative step count from the band's own pedometer, which runs whether or
  /// not the app is connected. Monotonic — it does NOT reset at midnight, so a
  /// day's steps are a difference between two records, never the value itself.
  final int? stepCount;

  /// The band's own cadence for this second (steps/min).
  final int? stepCadence;

  /// The band's own activity class: 0 = not committed to a class yet (NOT
  /// "still" — do not count it as sedentary), 1 = walk, 2 = run. Null when the
  /// band reported no valid class at all; a class is never invented from an
  /// out-of-range code.
  final int? activityClass;

  /// Calibrated skin temperature in °C, as computed by the band. Unlike
  /// [skinTempRaw] (an uncalibrated ADC count that needs days of personal
  /// baseline before it means anything) this is usable on its first second.
  final double? skinTempC;

  /// The band's own on-wrist determination for this second, if a decoder can
  /// ever honestly supply one. **Nothing supplies it today** — gen4 has no such
  /// field, and the gen5 v18 bits once read as wear (body 60 bits 0-1) are the
  /// primary-flags bit-8 snapshot, disproven as a wear signal. Wear truth lives
  /// in the HELLO body, the wrist on/off events and the wear-gated streams, not
  /// in a per-second column. Do not re-wire those bits here; see
  /// `sampleFromGen5Historical`.
  final int? onWrist;

  /// The band's own "HR and RR are valid this second" flag, if a decoder can
  /// ever honestly supply one. **Nothing supplies it today** — gen5 v18's
  /// body-15 bit7 was disproven as a validity flag on 1.59M retained records
  /// (it toggles ~50/50 independently of HR presence). HR presence is read off
  /// [hr] itself (the decoders already gate it to 25..230, and readers use
  /// `hr > 0`), never from this column.
  final bool? hrValid;

  /// A second heart-rate byte the band reports alongside [hr]. It CORROBORATES
  /// [hr] (agreement runs ~58-75%); it is not a substitute heart rate and must
  /// never be displayed as one.
  final int? hrAlt;

  /// Ambient-light ADC count — GEN4 ONLY (gen5 sends no per-second equivalent).
  ///
  /// Relative, on the user's own scale, forever: never lux, never a daylight
  /// goal. It measures what the WRIST saw, so the signal is one-sided — bright
  /// means bright, dark means nothing (a sleeve, a duvet or an arm under the
  /// pillow reads dark in a floodlit room).
  ///
  /// 0 means ABSENT, not dark: the decoder emits 0 for any record version it
  /// has not confirmed the optical block on. The DB write maps 0 → NULL so an
  /// unconfirmed record never lands as a real reading of total darkness.
  final int? ambientRaw;

  /// The gen5 record's SECOND and THIRD temperature channels, °C — GEN5 ONLY.
  ///
  /// NOT NAMED AFTER A BODY PART, on purpose and permanently. protocol calls
  /// their semantics loose; they may be ambient, board, die or battery. Naming
  /// one of them "core" or "ambient" before anyone has checked is exactly how
  /// gen4's `skinTempRaw` ended up feeding readiness as a skin temperature.
  /// Nothing reads these yet — persisting them claims nothing, which is the
  /// point: it is what makes it possible to find out later whether they mean
  /// anything at all. Dual-heat-flux core temperature is assumed UNAVAILABLE.
  final double? tempCh2C;
  final double? tempCh3C;

  /// The band's own per-second signal-quality figure (log-variance) — GEN5 ONLY.
  ///
  /// The band's own scale, so it can only ever be a within-night RANK or a
  /// weight. Never a percentage, never a bar, never "HRV confidence: 82%".
  final double? signalQualityLogVar;

  /// Gravity-removed motion magnitude for this second, in g — GEN5 ONLY.
  ///
  /// The band's own scalar (protocol: `dynamicAccelerationG`, f32, null when
  /// the bytes are not a finite in-full-scale value). It is NOT our ENMO and
  /// must not be substituted for one: we do not know the band's window, its
  /// filter, or whether it is a mean, an RMS or a peak, so the two are on
  /// different scales and a swap would move every motion number silently.
  ///
  /// Persisting it claims nothing — same contract as [tempCh2C]. It is stored
  /// so that a later comparison against our own ENMO on the same seconds is
  /// possible at all; nothing reads it today.
  final double? dynAccelG;

  /// The record's SUB-SECOND, in units of 1/32768 s — the strap's 32 kHz RTC
  /// crystal. BOTH GENERATIONS SEND IT (gen4 R24 at inner[11], gen5 v18 at the
  /// same offset), both decoders have always read it, and until now nothing in
  /// this app carried it past the decoder: every record was pinned to a whole
  /// second and every beat inside one shared a millisecond.
  ///
  /// It is a real, live field, not padding — measured on the only gen4 frames
  /// this app still keeps the bytes of (28,395 archived v25 records, which
  /// share the header): uniformly spread over its whole range, and stepping by
  /// a stable ~1,268 ticks from one record to the next rather than wandering.
  /// A coherent clock. NOTE the scope of that measurement: it says the FIELD is
  /// live and monotone, and it says nothing about any particular record
  /// version's cadence — a v25 burst record's period is its own.
  ///
  /// Null means the record carried none (the gen4 R10-lite path, and any
  /// external sensor), never zero — 0 is a legitimate sub-second.
  final int? tsSubsec;

  /// The band's own coarse wake/sleep state for this second — GEN5/MG ONLY.
  /// Stored as protocol's raw 2-bit code: 0 wake, 1 still, 2 sleep, 3 up.
  ///
  /// CORROBORATION, NEVER A STAGE. protocol is explicit that it is an ENVELOPE:
  /// deep, light and REM all read `sleep`, so it carries no in-sleep structure
  /// and cannot improve a hypnogram. It also lags true onset by roughly ten
  /// minutes — the band wants a sustained stretch of stillness before it
  /// commits — so it must never be differenced against our own onset and read
  /// as an error.
  ///
  /// WHAT IT IS FOR is the one thing this stack has never had: an OUTSIDE
  /// OPINION on sleep. Staging here is single-source, and when our window and
  /// the band's disagree there is currently no way to even see it.
  ///
  /// THE EVIDENCE THAT IT IS REAL. Decoded off 1,035 archived gen5 records: all
  /// four codes occur (wake 1,003, sleep 20, up 8, still 4), so it is neither
  /// constant nor a sentinel; median heart rate orders wake 119 > up 90 >
  /// still 82 > sleep 70, which is the physiological ordering the codes claim
  /// rather than an arbitrary one; and the transitions respect the documented
  /// topology — `still` appears only between wake and sleep, `up` only after
  /// sleep. (Those records are the ARCHIVE, a biased sample, so the counts are
  /// not a population; the ordering is the claim.)
  ///
  /// Nothing reads it. Persisting it claims nothing — same contract as
  /// [tempCh2C] and [dynAccelG].
  final int? bandSleepState;

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
    this.stepCount,
    this.stepCadence,
    this.activityClass,
    this.skinTempC,
    this.onWrist,
    this.hrValid,
    this.hrAlt,
    this.ambientRaw,
    this.tempCh2C,
    this.tempCh3C,
    this.signalQualityLogVar,
    this.dynAccelG,
    this.tsSubsec,
    this.bandSleepState,
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
    stepCount: stepCount,
    stepCadence: stepCadence,
    activityClass: activityClass,
    skinTempC: skinTempC,
    onWrist: onWrist,
    hrValid: hrValid,
    hrAlt: hrAlt,
    ambientRaw: ambientRaw,
    tempCh2C: tempCh2C,
    tempCh3C: tempCh3C,
    signalQualityLogVar: signalQualityLogVar,
    dynAccelG: dynAccelG,
    tsSubsec: tsSubsec,
    bandSleepState: bandSleepState,
  );

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

  /// One `decoded_onehz` row → [Sample]. Missing/NULL columns stay null (a gen4
  /// row carries none of the band-computed fields), never 0.
  factory Sample.fromDecodedRow(Map<String, Object?> m) {
    final valid = (m['hr_valid'] as num?)?.toInt();
    return Sample(
      tsEpoch: (m['rec_ts'] as num).toInt(),
      counter: (m['counter'] as num?)?.toInt() ?? 0,
      hr: (m['hr'] as num?)?.toInt() ?? 0,
      stepCount: (m['step_count'] as num?)?.toInt(),
      stepCadence: (m['step_cadence'] as num?)?.toInt(),
      activityClass: (m['activity_class'] as num?)?.toInt(),
      skinTempC: (m['skin_temp_c'] as num?)?.toDouble(),
      onWrist: (m['on_wrist'] as num?)?.toInt(),
      hrValid: valid == null ? null : valid != 0,
      hrAlt: (m['hr_alt'] as num?)?.toInt(),
      // Already 0-mapped-to-NULL on the way in, so a stored value is a reading.
      ambientRaw: (m['ambient_raw'] as num?)?.toInt(),
      tempCh2C: (m['temp_ch2_c'] as num?)?.toDouble(),
      tempCh3C: (m['temp_ch3_c'] as num?)?.toDouble(),
      signalQualityLogVar: (m['signal_quality_logvar'] as num?)?.toDouble(),
      dynAccelG: (m['dyn_accel_g'] as num?)?.toDouble(),
      tsSubsec: (m['ts_subsec'] as num?)?.toInt(),
      bandSleepState: (m['band_sleep_state'] as num?)?.toInt(),
    );
  }
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
/// [ArchiveRecord.reason] for a record the plausibility gate refused.
///
/// Load-bearing, not a label: three separate decisions branch on it — whether
/// the burst counts as offload progress, whether the band may be told to trim,
/// and whether a derive pass is scheduled. A typo in any one of them either
/// wedges the offload or lets the band erase data we distrusted, so the string
/// exists once.
const String kGateDroppedReason = 'gate_dropped';

class ArchiveRecord {
  // Nullable since M1: a band with no flash-record counter (Oura) needs a
  // real NULL here, not a 0 — `thinRawArchiveBefore` samples on this column
  // and a constant 0 would make every one of that band's frames `0 % 60 ==
  // 0`, i.e. permanently exempt from thinning, which is accidental policy.
  final int? counter;
  final String hex; // full inner bytes, hex
  final int packetType; // inner[0]: 0x2F historical (the only archived kind)
  final int? recTs; // decoded record time if any survived; usually null
  final int capturedAt; // epoch ms we received it
  final String reason; // e.g. 'undecodable_v<version>'

  ArchiveRecord({
    this.counter,
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

  /// Strap timestamp (unix sec) of the chargingOn/chargingOff EVENT that last
  /// set [charging] — null when unknown.
  ///
  /// [charging] alone cannot distinguish "the puck just went on" from "the strap
  /// replayed a chargingOn out of its flash backlog hours later" (see
  /// charge_alert_policy.dart). It is deliberately kept beside the flag rather
  /// than folded into it: the flag is still the LATEST KNOWN charging state and
  /// the UI should show it, while anything that treats the transition as a live
  /// event (notifications) has to check the age first.
  int? chargingTs;

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
  /// PostBondTimeoutLoopDetector tripped (#617), or a createBond() refusal:
  /// surface the re-pair guide to the user. Cleared by the first command the
  /// band actually answers — the direct contradiction of "encryption is
  /// blocking traffic". It used to be clearable only inside
  /// refreshAutoReconnectPause, i.e. only when the bond refusals had ALSO
  /// paused auto-reconnect, so in every other case a working band kept telling
  /// the user to forget the bond for the rest of the process.
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
  /// A HISTORY_END batch token has failed its ACK write enough times ACROSS
  /// reconnects to be quarantined. The data is safe (committed before the ACK
  /// was ever attempted); what this means is that the band has not been told it
  /// may trim, so it re-delivers the same batch. The link is no longer bounced
  /// on that token — bouncing forever was the "Groundhog Day" signature: the
  /// band re-delivers, the app reconnects, the battery drains, and the user saw
  /// a sync that never finished with no explanation.
  bool syncChunkQuarantined = false;
  /// Strap's own banked-data window from GET_DATA_RANGE (unix sec), for the
  /// session-relative plausibility gate + the UI's "history available" readout.
  int? dataRangeOldest;
  int? dataRangeNewest;
  /// Which WHOOP generation this connection is speaking — `'gen4'` or
  /// `'gen5'`, set once at service discovery (see `BleEngine._doConnect`'s
  /// `session.applyBand`). Null until a link has been established at least
  /// once this process. Lets the UI show "WHOOP 5 connected" and gate any
  /// gen5-only controls (e.g. a deep-buffer opt-in toggle) without reaching
  /// into the transport layer.
  String? generation;

  DeviceState({this.connection = 'disconnected'});

  /// Back to "no band has ever connected this process".
  ///
  /// The engine holds ONE of these for its whole life, so without this a
  /// forget leaves the old strap's serial, name, generation and battery in
  /// place — and a re-pair with a different band then shows them until the new
  /// link happens to overwrite each one. `generation` is the one that is not
  /// cosmetic: it is the key every sensor-dependent metric looks its constants
  /// up under, and the device page states it as a calibration fact.
  ///
  /// The bond/radio verdicts go too. They are findings about the band that was
  /// forgotten — an `autoReconnectPaused` left standing would silently pause
  /// the reconnect loop for the NEXT band as well.
  void reset() {
    address = null;
    serial = null;
    batteryPct = null;
    charging = null;
    chargingTs = null;
    wristOn = null;
    liveHr = null;
    liveHrAt = null;
    alarmEpoch = null;
    strapName = null;
    generation = null;
    connection = 'disconnected';
    standardHrFallback = false;
    needsRepairGuide = false;
    bondRefusals = 0;
    autoReconnectPaused = false;
    syncClockLost = false;
    strapNeedsReboot = false;
    syncChunkQuarantined = false;
    dataRangeOldest = null;
    dataRangeNewest = null;
  }
}
