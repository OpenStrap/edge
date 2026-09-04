// The const table of bands this build can see.
//
// Dart AOT has no runtime code loading, no `dart:mirrors`, and lazy static
// initialisation defeats import-for-side-effects registration (ASSUMPTIONS
// E4), so this is a hand-maintained `const` list. Adding a band is a source
// edit here and nothing else. Revisit past ~50 entries.
//
// SCOPE — this file is the IDENTITY half only. The session seam now exists in
// `adapter.dart` (`BandAdapter` / `BandLink` / `BandEvent`) and an adapter
// points BACK at its entry here rather than restating a service UUID that the
// iOS AccessorySetupKit plist is generated from. Two declarations of one UUID
// is one declaration too many.
//
// This file holds the facts `ble_engine.dart` used to hardcode:
//
//   • which service UUIDs the scan filters on            (D1)
//   • which characteristics a link must expose to connect (D2)
//   • where the inner-record fields sit                   (D3)
//
// `run(BandLink)`, `BandEvent` and `InputSignal` live in `adapter.dart` /
// `signals.dart`. There are — per MULTIBAND_PLAN §3.1 — no capability
// booleans here or there, ever: an adapter declares the INPUT signals a device
// physically emits, never a `supportsX()` claim about our own features.
//
// WHAT THE FIRST NON-WHOOP ENTRY PROVED (D10, the `0x180D` strap below).
// The identity half of this type held: id, label, service UUID and
// `requiredCharacteristics` describe a generic heart-rate strap exactly, and
// `requiredCharacteristics` had already been made a field for precisely this.
// Two halves did NOT hold, and both are recorded here rather than papered over:
//
//   1. The WIRE half is WHOOP-shaped by construction. [GattProfile] is six
//      named command/notify characteristics and [BandProfile] is a framed
//      envelope over a CLOSED `DeviceType {gen4, gen5}` enum — neither can
//      express one service with one notify characteristic and no envelope, and
//      `protocol` is SEALED so neither can be widened there. So both are
//      NULLABLE now: null means "not a framed WHOOP-family band", and
//      [isFramed] is the predicate every WHOOP-only consumer filters on.
//   2. There was no SESSION half at all — a [BandEntry] DESCRIBES a band, it
//      cannot DRIVE one. CLOSED by `adapter.dart`: the `0x180D` strap is now a
//      `BandAdapter` whose whole session is one `run(BandLink)`, and this
//      entry is what that adapter points at for its identity. gen4 and gen5
//      still run through `ble_engine._doConnect`; moving them behind the seam
//      is the next wave, and until then `isFramed` remains the predicate that
//      tells the two worlds apart.

import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'signals.dart';

/// GATT Heart Rate Service and its Heart Rate Measurement characteristic.
/// Written out in full 128-bit form rather than the 16-bit shorthand: the
/// shorthand's expansion is a platform detail we should not depend on.
const String kHeartRateServiceUuid = '0000180d-0000-1000-8000-00805f9b34fb';
const String kHeartRateMeasurementUuid = '00002a37-0000-1000-8000-00805f9b34fb';

/// The DaFit/MOYOUNG-V2 clone-watch family's GATT service — an otherwise
/// generic Nordic UART Service. Shared by the whole cluster of unbranded
/// boards this build recognizes (M6/M4/LH716/Sunset 6/Watch7/Fit1900-style),
/// sold under many storefront names but all speaking the same envelope.
const String kDafitService = '6e400001-b5a3-f393-e0a9-e50e24dcca9d';

/// Host to band. Every command frame and ack is written here, with response.
const String kDafitWriteChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9d';

/// Band to host. Every reply, ack and unsolicited frame arrives here.
const String kDafitNotifyChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9d';

/// The Oura ring's GATT service, identical across the generations seen so far.
const String kOuraService = '98ed0001-a541-11e4-b6a0-0002a5d5c51b';

/// Host to ring. Every Oura command is written here, with response.
const String kOuraCommandChar = '98ed0002-a541-11e4-b6a0-0002a5d5c51b';

/// Ring to host. Command replies, asynchronous notifications and every history
/// event share this one characteristic — there is no separate data pipe.
const String kOuraNotifyChar = '98ed0003-a541-11e4-b6a0-0002a5d5c51b';

/// What a stored timestamp actually IS for a given band.
///
/// The distinction is load-bearing and it is not cosmetic. A WHOOP record
/// carries the instant the band itself stamped on the reading; a `0x2A37`
/// strap carries beat-to-beat DURATIONS and no clock at all, so the only time
/// we can attach is the moment the notification reached this phone — which
/// BLE delivery jitter and stack batching move by tens of milliseconds.
///
/// RMSSD, pNN50 and everything else computed off the durations stay correct on
/// [arrival]. Lomb-Scargle, `cvhr_per_hour`, `spanSec` and anything else that
/// reads the time AXIS must refuse on it (MULTIBAND_PLAN §3.2, §5.3). This
/// enum is what lets that refusal be code instead of a doc note.
enum TimeAnchor {
  /// The source stamped the reading itself. Every WHOOP record.
  measured,

  /// The instant the sample reached the phone. Approximate, and never to be
  /// written into a column that means "where the beat was".
  arrival,
}

/// The two OBSERVED client delays in the WHOOP 5 bootstrap: 600 ms between the
/// bond completing and notification registration, and 500 ms between the last
/// CCC write and the first command (on a captured link GET_HELLO went out
/// 585 ms after it). The firmware rationale is not documented anywhere, which
/// is exactly why they are per-band values and not a global settle: WHOOP 4's
/// flow is proven without them, and perturbing it for a reason nobody can state
/// is how a working band stops working.
const Duration kGen5PreRegistrationDelay = Duration(milliseconds: 600);
const Duration kGen5PostRegistrationDelay = Duration(milliseconds: 500);

/// The command table for one framed band.
///
/// Every field here was an `if (session.band.isGen5)` in `ble_engine.dart` that
/// chose a VALUE — an opcode, a body, a wire fact. Each is transcribed verbatim
/// from the arm it replaces (`band_registry_test.dart` pins them), and the code
/// around it is now unconditional.
///
/// What is deliberately NOT here: anything that chooses a different SEQUENCE of
/// operations — the gen5 HELLO step, the advertising-name read, the battery-pack
/// follow-up, the deep-buffer unlock, the two INIT state machines, the gen5
/// alarm pre-arm, the historical decoder. Those are behaviour; they stay in the
/// engine where the order can be read top to bottom (ASSUMPTIONS G1-G4 — the
/// `run(BandLink)` move was declined, so there is nowhere else for them to go).
///
/// It is a TABLE, not a policy: no field is computed, and no field decides
/// WHETHER something happens except by being absent ([r10R11Realtime]).
class BandWireCommands {
  /// GET_HELLO and its body. WHOOP 5 does not implement the Harvard opcode.
  final int hello;
  final List<int> helloBody;

  /// GET_ADVERTISING_NAME and its body — a different opcode pair on each
  /// generation, and gen5's takes a revision byte where gen4 takes 0x00.
  final int getAdvertisingName;
  final List<int> getAdvertisingNameBody;

  /// SET_ADVERTISING_NAME. Only the opcode differs; the body
  /// (`[0x01][len][ascii][u32 0]`) is identical on both and stays at the call
  /// site that builds it.
  final int setAdvertisingName;

  /// SEND_R10_R11 (0x3F), the high-rate raw live-stream toggle — or NULL on a
  /// band that does not implement the opcode (a WHOOP 5 console answers
  /// Unknown/Unhandled). Null is what the four live-stream paths read to skip
  /// the toggle; it is an absent command, not a capability claim.
  final int? r10R11Realtime;

  /// Whether ENABLE_OPTICAL_DATA is this band's LIVE optical toggle.
  ///
  /// A wire-semantics fact and a safety boundary, not a preference: on WHOOP 5
  /// the same opcode is the SAVE-to-history toggle, so arming it for a live
  /// stream would write a persistent save-enable that leaves the LEDs on.
  final bool opticalDataIsLiveToggle;

  /// Body of the offload commands (GET_DATA_RANGE, SEND_HISTORICAL_DATA).
  /// gen4 sends a single 0x00; gen5 sends an EMPTY body.
  final List<int> offloadBody;

  const BandWireCommands({
    required this.hello,
    required this.helloBody,
    required this.getAdvertisingName,
    required this.getAdvertisingNameBody,
    required this.setAdvertisingName,
    required this.r10R11Realtime,
    required this.opticalDataIsLiveToggle,
    required this.offloadBody,
  });
}

/// One band the app can discover and connect to.
///
/// The wire format itself stays in `protocol` ([BandProfile] = header length,
/// size-field offset, direction markers; [GattProfile] = the UUID map). This
/// type carries the edge-side facts that live above the codec — discovery and
/// the inner-record field offsets — following the same "it is data, not a
/// branch" pattern rather than inventing a parallel one.
class BandEntry {
  /// Stable identifier. Stamped into `DeviceState.generation` and, downstream,
  /// `device_family` and `decoded_*.source` — so it is a storage key: never
  /// rename a shipped one.
  final String id;

  /// Human label for logs and (later) the pairing UI.
  final String label;

  /// GATT UUID map for this band. NULL for a band that is not a WHOOP-family
  /// six-characteristic link — see the header note.
  final GattProfile? gatt;

  /// Frame envelope profile — header length, size-field offset, header CRC.
  /// NULL means this band sends no envelope at all, which is also what
  /// [isFramed] reports and what the offload engine filters on.
  final BandProfile? wire;

  /// What [TimeAnchor] this band's stored timestamps carry.
  final TimeAnchor timeAnchor;

  final String? _service;

  /// The characteristics a link MUST expose or the connect aborts.
  ///
  /// Defaults to this entry's own four command/notify characteristics, which
  /// is what a WHOOP link genuinely needs. It is a FIELD and not a constant
  /// because demanding four unconditionally is why a second, parallel BLE
  /// stack had to exist at all: a generic HRS device exposes one notify
  /// characteristic and nothing else.
  final List<String>? _requiredCharacteristics;

  /// Offset of the opcode byte within the inner payload
  /// (`[pktType, seq, opcode, body…]`). Framed entries only.
  final int innerOpcodeOffset;

  /// Offset of the record-version byte within a historical record's inner
  /// payload. Framed entries only.
  final int innerVersionOffset;

  /// Offset of the u32-LE record counter within a historical record's inner
  /// payload. Framed entries only.
  final int innerCounterOffset;

  final BandWireCommands? _commands;

  /// This band's command table. Framed entries only — a notify-only sensor has
  /// no command channel at all, which is why this throws rather than answering
  /// with a plausible-looking WHOOP default.
  BandWireCommands get commands => _commands!;

  /// Pause between the bond completing and notification registration, and
  /// between the last CCC write and the first command. [Duration.zero] means
  /// "no pause", which is what every band does unless it has evidence for one.
  final Duration preRegistrationDelay;
  final Duration postRegistrationDelay;

  /// Whether the bootstrap SET_CLOCK is gated on measured drift
  /// (`BootstrapClockGate`) rather than written unconditionally.
  ///
  /// FALSE ON WHOOP 4 ON PURPOSE, and it is not an oversight to be tidied: its
  /// unconditional write is the proven flow, and the WHOOP 5 bootstrap is where
  /// the evidence for gating lives. Flipping it changes a band that works.
  final bool setClockDriftGated;

  /// Whether a burst's declared `expectedPacketCount` is trustworthy enough to
  /// GATE the burst, or is advisory only.
  ///
  /// FALSE ON WHOOP 4 ON PURPOSE. The gap between expected and actual varies
  /// run to run there with no fixed offset, so a hard gate becomes a permanent
  /// stall — 15 validation failures, abort, terminal Stuck — on a band whose
  /// count semantics nothing has pinned. False is also the SAFE default for a
  /// band nobody has measured.
  final bool burstCountGateEnforced;

  /// Whether this band's decoded `console_log` frames are echoed into the
  /// engine log. Debug visibility only — never persisted, never gated on.
  ///
  /// It is per-band because the value of the noise is: WHOOP 5's handshake and
  /// offload are the untested ones, so its console is worth reading. Note that
  /// `protocol` decodes a console frame on BOTH bands, so false here means a
  /// WHOOP 4 that emits one is silently dropped on the floor.
  final bool logsConsoleOutput;

  /// Extra scan-time name match for a band that advertises its name but not
  /// (reliably) its service UUID. Null for a band with no such fallback.
  ///
  /// This is the per-entry replacement for the `name.contains('whoop')`
  /// literal `scan()` used to carry directly — see `transport.dart`. Takes
  /// the ALREADY-LOWERCASED platform name.
  final bool Function(String lowercaseName)? nameMatcher;

  /// A framed WHOOP-family band: an envelope, a command characteristic, and a
  /// flash the offload engine trims.
  const BandEntry.framed({
    required this.id,
    required this.label,
    required GattProfile this.gatt,
    required BandProfile this.wire,
    required this.innerOpcodeOffset,
    required this.innerVersionOffset,
    required this.innerCounterOffset,
    required BandWireCommands commands,
    List<String>? requiredCharacteristics,
    this.preRegistrationDelay = Duration.zero,
    this.postRegistrationDelay = Duration.zero,
    this.setClockDriftGated = false,
    this.burstCountGateEnforced = false,
    this.logsConsoleOutput = false,
    this.nameMatcher,
  })  : _requiredCharacteristics = requiredCharacteristics,
        _commands = commands,
        _service = null,
        timeAnchor = TimeAnchor.measured;

  /// A notify-only sensor: one service, one or more notify characteristics, no
  /// envelope, no commands, no stored history to offload.
  ///
  /// The record offsets are -1 on purpose. They describe a position inside a
  /// framed payload this band never sends, and a plausible-looking 2/1/3 would
  /// read the wrong byte in silence — which is the exact failure the registry
  /// exists to prevent. -1 throws.
  const BandEntry.notify({
    required this.id,
    required this.label,
    required String service,
    required List<String> characteristics,
    required this.timeAnchor,
  })  : _service = service,
        _requiredCharacteristics = characteristics,
        gatt = null,
        wire = null,
        // No envelope, no command channel: [commands] throws for the same
        // reason the offsets are -1.
        _commands = null,
        preRegistrationDelay = Duration.zero,
        postRegistrationDelay = Duration.zero,
        setClockDriftGated = false,
        burstCountGateEnforced = false,
        logsConsoleOutput = false,
        nameMatcher = null,
        innerOpcodeOffset = -1,
        innerVersionOffset = -1,
        innerCounterOffset = -1;

  /// True when this band speaks a framed envelope, i.e. the offload engine can
  /// drive it. The one predicate every WHOOP-only consumer filters on.
  bool get isFramed => wire != null;

  /// Service UUID to advertise-filter the scan on.
  String get service => gatt?.service ?? _service!;

  /// 32-bit prefix used to match this band's service from a scan result or a
  /// discovered service list (case-insensitive `startsWith`).
  String get servicePrefix => service.substring(0, 8);

  List<String> get requiredCharacteristics =>
      _requiredCharacteristics ??
      <String>[gatt!.cmdTo, gatt!.cmdFrom, gatt!.events, gatt!.data];

  /// Index of the opcode byte in a fully-framed packet. Framed entries only —
  /// this is the byte the dangerous-opcode block reads, and a band with no
  /// envelope has no such byte to read.
  int get frameOpcodeIndex => wire!.headerLen + innerOpcodeOffset;
}

bool _nameContainsWhoop(String lowercaseName) => lowercaseName.contains('whoop');

/// WHOOP 4 ("Harvard", 6108xxxx).
///
/// Every value below is the gen4 arm of an `isGen5` branch that used to live in
/// `ble_engine.dart`, transcribed unchanged. The four session flags are written
/// out rather than left to their defaults because this is a table, and a table
/// that says nothing about a band is not evidence that the band does nothing.
const BandEntry kWhoopGen4 = BandEntry.framed(
  id: 'gen4',
  label: 'WHOOP 4',
  gatt: GattProfile.gen4,
  wire: BandProfile.gen4,
  innerOpcodeOffset: 2,
  innerVersionOffset: 1,
  innerCounterOffset: 3,
  preRegistrationDelay: Duration.zero,
  postRegistrationDelay: Duration.zero,
  setClockDriftGated: false,
  burstCountGateEnforced: false,
  logsConsoleOutput: false,
  // A gen4 sometimes advertises its name but not a matchable service UUID —
  // see `transport.dart`'s scan(). WHOOP 5 has no such fallback: its `fd4b`
  // member UUID is reliable.
  nameMatcher: _nameContainsWhoop,
  commands: BandWireCommands(
    hello: Cmd.getHelloHarvard,
    helloBody: <int>[0x00],
    getAdvertisingName: Cmd.getAdvertisingNameHarvard,
    getAdvertisingNameBody: <int>[0x00],
    setAdvertisingName: Cmd.setAdvertisingNameHarvard,
    r10R11Realtime: Cmd.sendR10R11Realtime,
    opticalDataIsLiveToggle: true,
    offloadBody: <int>[0x00],
  ),
);

/// WHOOP 5 / MG ("fd4b"). Same inner payload layout as gen4 — only the
/// envelope differs, which is exactly what [BandProfile] models.
const BandEntry kWhoopGen5 = BandEntry.framed(
  id: 'gen5',
  label: 'WHOOP 5',
  gatt: GattProfile.gen5,
  wire: BandProfile.gen5,
  innerOpcodeOffset: 2,
  innerVersionOffset: 1,
  innerCounterOffset: 3,
  preRegistrationDelay: kGen5PreRegistrationDelay,
  postRegistrationDelay: kGen5PostRegistrationDelay,
  setClockDriftGated: true,
  burstCountGateEnforced: true,
  logsConsoleOutput: true,
  commands: BandWireCommands(
    hello: Cmd.getHello,
    helloBody: <int>[0x01],
    getAdvertisingName: Cmd.getCustomAdvertisingName,
    getAdvertisingNameBody: <int>[revision1],
    setAdvertisingName: Cmd.setCustomAdvertisingName,
    // 0x3F answers Unknown/Unhandled on a WHOOP 5 console.
    r10R11Realtime: null,
    // ENABLE_OPTICAL_DATA is the SAVE-to-history toggle here, not the realtime
    // stream (the realtime one is the next opcode up) — arming it for live
    // would write a persistent save-enable on every live-stream start.
    opticalDataIsLiveToggle: false,
    offloadBody: <int>[],
  ),
);

/// Any standard Bluetooth heart-rate sensor — the SIG's Heart Rate Service.
/// Chest straps, optical armbands, some rings, and a WHOOP in broadcast mode.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one yet, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). It IS reachable
/// now — `PairSensorScreen` writes the `device` row `HrsLink.arm` reads — but
/// reachable is not verified, and `kDerivableSources` stays empty: a strap
/// captures beats, and nothing derives from them until someone has held one.
const BandEntry kBleHrs = BandEntry.notify(
  id: 'ble_hrs',
  label: 'Bluetooth heart rate sensor',
  service: kHeartRateServiceUuid,
  characteristics: <String>[kHeartRateMeasurementUuid],
  // The strap reports durations and has no clock. See [TimeAnchor].
  timeAnchor: TimeAnchor.arrival,
);

/// The Oura ring, a fetch-by-cursor band with a challenge-response handshake.
///
/// NOT framed, and the three fields a framed entry carries would each be wrong
/// here: the length is a u8 that counts payload only, there is no CRC anywhere
/// in the protocol, and there is no inner opcode byte to find. `isFramed ==
/// false` keeps it out of [kFramedBands], which is what keeps it out of the
/// offload engine's scan filter and out of the iOS AccessorySetupKit plist —
/// both of which are about the primary band that holds a link and gets trimmed.
///
/// [TimeAnchor.arrival] is the conservative half of a two-clock situation, not
/// a claim that the ring has no clock. See `oura.dart`.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns a ring, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). It is also not
/// yet reachable — there is no pairing screen and nothing constructs the
/// adapter.
const BandEntry kOura = BandEntry.notify(
  id: 'oura',
  label: 'Oura Ring',
  service: kOuraService,
  // Both, and the command characteristic is genuinely required: unlike a
  // heart-rate strap this band answers nothing until it has been written to.
  characteristics: <String>[kOuraCommandChar, kOuraNotifyChar],
  timeAnchor: TimeAnchor.arrival,
);

/// A DaFit/MOYOUNG-V2 clone-watch: an unbranded OEM board, paired through
/// the DaFit or MOYOUNG companion app family and sold under many storefront
/// names (M6/M4/LH716/Sunset 6/Watch7/Fit1900-style).
////// NOT framed: there is a length field and a command byte but no CRC and no
/// inner-record layout the framed machinery's [innerOpcodeOffset] etc. could
/// describe — see `dafit.dart` in `protocol` for the wire format itself.
////// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired band
/// holds a session and archives every frame it sends, and surfaces no health
/// signal at all.
const BandEntry kDafit = BandEntry.notify(
  id: 'dafit',
  label: 'DaFit / MOYOUNG watch',
  service: kDafitService,
  characteristics: <String>[kDafitWriteChar, kDafitNotifyChar],
  // No clock this build reads back — every frame is stamped on arrival, same
  // as the generic HRS strap.
  timeAnchor: TimeAnchor.arrival,
);

/// Every band this build can see. Order is match order during discovery.
const List<BandEntry> kBandRegistry = <BandEntry>[
  kWhoopGen4,
  kWhoopGen5,
  kBleHrs,
  kOura,
  kDafit,
];

/// The bands the OFFLOAD ENGINE can drive, and the bands iOS provisions
/// through the AccessorySetupKit picker — the same set, for the same reason:
/// both are about the primary band that holds a link, keeps a flash and gets
/// trimmed. A notify-only sensor is connected straight from its stored remote
/// id during a workout, so putting it in the ASK plist would only add chest
/// straps to the WHOOP pairing picker.
final List<BandEntry> kFramedBands =
    kBandRegistry.where((e) => e.isFramed).toList(growable: false);

/// The entry speaking [wire]. Used by the engine's test seam, which is handed
/// a [BandProfile] rather than an entry.
BandEntry bandEntryFor(BandProfile wire) =>
    kBandRegistry.firstWhere((e) => e.wire?.type == wire.type);

/// `BandAdapter.signals`, by `device.adapter_id` — what M6's per-device
/// filter (final-plan §6.1, §6.5) reads with no query at all.
///
/// DRIFT FROM THE OBVIOUS `Map<String, BandAdapter>` SHAPE (M1 did not add
/// this — verified via grep, zero matches — so M6 adds it here per §1's own
/// fallback instruction). `WhoopFramedAdapter` needs a live `BleEngine` to
/// construct (`whoop_gen4.dart`) and there is no such instance at this
/// static, top-level scope; `OuraAdapter` needs a pairing key. Every adapter's
/// `signals` getter is a plain literal with no computed dependency, so this
/// maps straight to the declared signals instead of a constructed instance —
/// KEPT IN SYNC BY HAND with `whoop_gen4.dart`'s `kWhoopGen4Signals`,
/// `ble_hrs.dart`'s `BleHrsAdapter.signals` and `oura.dart`'s
/// `OuraAdapter.signals`, since importing those three back into this file
/// (each of which already imports THIS file for its `BandEntry`) would be a
/// needless import cycle for three lines of data.
///
/// gen5 reuses gen4's map: `kWhoopGen5`'s own doc comment states "same inner
/// payload layout as gen4 — only the envelope differs", so gen4's declared
/// signal set is the verified fact for gen5 too, not a guess.
const Map<String, Map<InputSignal, Duration>> kAdapterSignals =
    <String, Map<InputSignal, Duration>>{
  'gen4': {
    InputSignal.hr1Hz: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
    InputSignal.accel1Hz: Duration(seconds: 1),
    InputSignal.ppgRedIr: Duration(seconds: 1),
    InputSignal.skinTempRaw: Duration(seconds: 1),
  },
  'gen5': {
    InputSignal.hr1Hz: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
    InputSignal.accel1Hz: Duration(seconds: 1),
    InputSignal.ppgRedIr: Duration(seconds: 1),
    InputSignal.skinTempRaw: Duration(seconds: 1),
  },
  'ble_hrs': {
    InputSignal.hrSparse: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
  },
  'oura': <InputSignal, Duration>{},
  'dafit': <InputSignal, Duration>{},
};

/// The signals one adapter declares, or empty for an id this build has no
/// entry for — mirrors `bandLabelFor`'s null-is-honest shape
/// (`devices.dart:122-127`): an unknown device is never quietly filed under
/// the nearest one we know.
Set<InputSignal> declaredSignals(String? adapterId) =>
    kAdapterSignals[adapterId]?.keys.toSet() ?? const {};
