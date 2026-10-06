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

/// A Polar optical sensor's PMD (measurement data) service. Plain GATT — no
/// encryption, no key exchange, no bonding requirement at this layer.
const String kPolarPmdService = 'fb005c80-02e7-f387-1cad-8acd2d8df0c8';

/// Write-with-response, indicate. Every PMD command goes here; its indicate
/// reply carries the command's outcome.
const String kPolarPmdControlChar = 'fb005c81-02e7-f387-1cad-8acd2d8df0c8';

/// Notify. Every measurement stream this service can carry shares this one
/// data characteristic — see `polar_pmd.dart` (adapter) for why only the PPI
/// stream is decoded.
const String kPolarPmdDataChar = 'fb005c82-02e7-f387-1cad-8acd2d8df0c8';

/// Polar's 16-bit service, advertised beside 0x180D. The PMD service itself
/// is not in a Polar advertisement, so these two are what a scan can hear.
const String kPolarAdvertisedHint = '0000feee-0000-1000-8000-00805f9b34fb';

/// The Oura ring's GATT service, identical across the generations seen so far.
const String kOuraService = '98ed0001-a541-11e4-b6a0-0002a5d5c51b';

/// Host to ring. Every Oura command is written here, with response.
const String kOuraCommandChar = '98ed0002-a541-11e4-b6a0-0002a5d5c51b';

/// Ring to host. Command replies, asynchronous notifications and every history
/// event share this one characteristic — there is no separate data pipe.
const String kOuraNotifyChar = '98ed0003-a541-11e4-b6a0-0002a5d5c51b';

/// The vendor 128-bit service a Coros watch exposes alongside the standard
/// SIG services below. Its base ends `...77656c6f6f70` ("weloop"), a vendor
/// UUID family — NOT the Nordic UART service (`...e50e24dcca9e`), though it
/// shares the `6e40000x` prefix. It is this entry's GATT identity, checked
/// after connect; the watch is not known to advertise it, so the scan finds
/// a Coros by name instead (see [kCoros]). A bare `0000180d` would collide
/// with [kBleHrs].
const String kCorosService = '6e400001-b5a3-f393-e0a9-77656c6f6f70';

/// Standard Battery Service characteristic, read+notify, one byte 0-100.
const String kBatteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';

/// Standard Device Information Service characteristics — read-only UTF-8
/// strings, no notify property.
const String kModelNumberUuid = '00002a24-0000-1000-8000-00805f9b34fb';
const String kSerialNumberUuid = '00002a25-0000-1000-8000-00805f9b34fb';
const String kFirmwareRevisionUuid = '00002a26-0000-1000-8000-00805f9b34fb';

/// Software Revision String. A Coros PACE 3 carries its firmware version
/// here ("V 3.0808.0") and has no Firmware Revision characteristic at all.
const String kSoftwareRevisionUuid = '00002a28-0000-1000-8000-00805f9b34fb';

/// Garmin's Multi-Link service — one characteristic pair carries every
/// logical service (GFDI, the numbered real-time streams) this device family
/// speaks, routed by a handle byte. See `protocol`'s `garmin.dart`.
const String kGarminService = '6a4e2800-667b-11e3-949a-0800200c9a66';

/// Host to watch: the usual write twin of [kGarminNotifyChar]. Every ML
/// control frame and every GFDI/COBS chunk is written to the session's write
/// characteristic, with response. A watch may use any data characteristic
/// 6A4E2810..6A4E2819 with its 282x twin, or write on the data one itself —
/// `garminMlPair` picks.
const String kGarminWriteChar = '6a4e2820-667b-11e3-949a-0800200c9a66';

/// Watch to host: the lowest multi-link data characteristic. Every ML
/// control reply and every GFDI/COBS chunk arrives on the session's data
/// characteristic — there is no separate data pipe.
const String kGarminNotifyChar = '6a4e2810-667b-11e3-949a-0800200c9a66';

/// How a Garmin watch advertises itself: manufacturer data under company id
/// 0x0087 (some watches put it byte-swapped, 0x8700), and service data under
/// these 16-bit UUIDs. It need not advertise [kGarminService] at all.
const List<int> kGarminCompanyIds = <int>[0x0087, 0x8700];
const List<String> kGarminServiceDataUuids = <String>[
  '0000fe1f-0000-1000-8000-00805f9b34fb',
  '00003e10-0000-1000-8000-00805f9b34fb',
  '00002401-0000-1000-8000-00805f9b34fb',
];

/// The Ultrahuman Ring Air's command/response service. The primary service —
/// `BandEntry.notify` points at this one, not the device-state service below.
const String kUltrahumanCommandService = '86f65000-f706-58a0-95b2-1fb9261e4dc7';

/// Host to ring. The ring is written without response; `GattBandLink.write`
/// does so whenever this characteristic declares only that write kind. No
/// write here bonds; see `UltrahumanLink` for the one bond step.
const String kUltrahumanWriteChar = '86f65001-f706-58a0-95b2-1fb9261e4dc7';

/// Ring to host. Every command reply and every history batch.
const String kUltrahumanNotifyChar = '86f65002-f706-58a0-95b2-1fb9261e4dc7';

/// Battery/temperature notify characteristic on a SEPARATE service. Optional —
/// not in [kUltrahuman]'s required characteristics — so a ring that does not
/// answer on it still pairs and drains.
const String kUltrahumanDeviceStateChar = '86f61001-f706-58a0-95b2-1fb9261e4dc7';

/// The Mi Band 2/3 family's own GATT service. Standard SIG 128-bit base.
/// Mi Band 1/1A/1S's `fee0` service is an older, different protocol — not
/// this family, and this build never scans for it.
const String kHuami234Service = '0000fee1-0000-1000-8000-00805f9b34fb';

/// Write + notify. The only characteristic authentication needs, and the
/// only one this registry entry requires — see [kMiBand234]'s own doc.
const String kHuami234AuthChar = '00000009-0000-3512-2118-0009af100700';

/// Optional, best-effort. Never required to connect.
const String kHuami234BatteryChar = '00000006-0000-3512-2118-0009af100700';
const String kHuami234StepsChar = '00000007-0000-3512-2118-0009af100700';

/// Pebble 2 / Pebble 2 SE's scan-filter service. Older Pebbles are out of
/// reach of a client-only host (Classic SPP, or a BLE path that needs the
/// phone to run its own local GATT server) — see `pebble.dart`'s header.
const String kPebbleServiceUuid = '0000fed9-0000-1000-8000-00805f9b34fb';

/// Notify. Connectivity state.
const String kPebbleConnectivityUuid = '00000001-328e-0fbb-c642-1aa6699bdada';

/// Write. Triggers standard OS-level BLE bonding — no app-layer key exchange.
const String kPebblePairingTriggerUuid = '00000002-328e-0fbb-c642-1aa6699bdada';

/// Notify. MTU.
const String kPebbleMtuUuid = '00000003-328e-0fbb-c642-1aa6699bdada';

/// A separate service, discovered post-connect rather than scan-filtered:
/// PPoGATT ("Pebble Protocol over GATT"), the reliable byte-transport.
const String kPebblePpogattServiceUuid = '30000003-328e-0fbb-c642-1aa6699bdada';

/// Read/notify. Every PPoGATT packet the watch sends arrives here.
const String kPebblePpogattReadUuid = '30000004-328e-0fbb-c642-1aa6699bdada';

/// Write. Every ACK and control reply this host sends goes here.
const String kPebblePpogattWriteUuid = '30000006-328e-0fbb-c642-1aa6699bdada';

/// Colmi smart ring family's primary command/notify service ("Service A").
/// A second service ("Service B", `de5bf728…`) carries the sleep, SpO2 and
/// temperature "big data" replies — see `colmi.dart`'s header.
const String kColmiService = '6e40fff0-b5a3-f393-e0a9-e50e24dcca9e';

/// Service B, host to ring: big-data requests. Optional — a firmware without
/// it still syncs HR, HRV, stress and steps over Service A. The ring expects
/// these writes WITHOUT response; `GattBandLink.write` picks the write kind
/// from the characteristic's declared properties, so one that declares only
/// write-without-response gets exactly that.
const String kColmiCommandChar = 'de5bf72a-d711-4e47-af26-65e3012a5dc7';

/// Service B, ring to host: big-data replies, possibly split across several
/// notifications.
const String kColmiBigNotifyChar = 'de5bf729-d711-4e47-af26-65e3012a5dc7';

/// Host to ring. Every command frame is written here.
const String kColmiWriteChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// Ring to host. Every reply — including an unprompted battery push — arrives
/// here, tagged by the same command id the request went out under.
const String kColmiNotifyChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

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

  /// True for a band that may not advertise its service at all, so the
  /// notify-class scan (`HrsLink._scanForEntries`) runs WITHOUT the OS-level
  /// service filter whenever this entry is in it, and keeps only results
  /// that match a service or a [nameMatcher]. The GATT service is still
  /// checked after connect.
  final bool scanByName;

  /// Extra advertised service UUIDs added to the notify-class scan's
  /// OS-level filter for this entry. A HINT, not an identity: a result that
  /// carried only a hint (and none of the entries' own services) is kept only
  /// when a [nameMatcher] claims it; a hint alone never confirms an entry,
  /// but this entry's name on an advertisement carrying its hint does, ahead
  /// of another entry's service (`HrsLink.hintedNameMatch`). For
  /// a band whose advertisement carries a shared 16-bit UUID rather than the
  /// GATT service it is checked against after connect.
  final List<String> scanHints;

  /// Advertisement identities that NAME this entry in the notify-class scan,
  /// beside its service: a manufacturer-data company id, or a 16-bit
  /// service-data UUID. Both become OS-level scan filters (OR'd with the
  /// services) and a result carrying one is matched to this entry. For a
  /// band whose advertisement does not carry the GATT service it is checked
  /// against after connect.
  final List<int> scanCompanyIds;
  final List<String> scanServiceData;

  /// Characteristic a notify-class sensor needs written to (any value, WITH
  /// response) to move the OS into bonded state before it will do anything
  /// else — see `kPebblePairingTriggerUuid`'s doc comment. Null for every
  /// band that either needs no bonding or bonds through `ble_engine`'s own
  /// `createBond()` path (every framed entry).
  final String? bondTriggerCharacteristic;

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
        scanByName = false,
        scanHints = const <String>[],
        scanCompanyIds = const <int>[],
        scanServiceData = const <String>[],
        _service = null,
        bondTriggerCharacteristic = null,
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
    this.bondTriggerCharacteristic,
    this.nameMatcher,
    this.scanByName = false,
    this.scanHints = const <String>[],
    this.scanCompanyIds = const <int>[],
    this.scanServiceData = const <String>[],
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

/// A Polar optical sensor (Verity Sense, OH1) speaking the PMD service, PPI
/// stream only.
///
/// Plain unencrypted GATT — a control-point write plus a data notify, no
/// bonding requirement at this layer, same shape as [kBleHrs] with one
/// addition: streaming has to be switched on with a control-point write
/// before the data characteristic says anything, and the adapter is what does
/// that (see `polar_pmd.dart`).
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). It pairs, connects,
/// and streams decoded beats; `kDerivableSources` stays empty until someone
/// has actually held one.
///
/// FOUND BY NAME, CHECKED BY ITS GATT. A Polar advertises its name
/// (`Polar <model> <id>`) with 0x180D and 0xFEEE, never the PMD service, so
/// those two are
/// [scanHints] and [nameMatcher] names it; a hinted name match outranks
/// [kBleHrs]'s service match in a multi-entry scan. The H-series chest straps
/// (H7/H9/H10) are left to [kBleHrs]: they are ECG straps without PPI.
/// Pairing confirms the PMD characteristics and the PPI feature bit.
const BandEntry kPolarPmd = BandEntry.notify(
  id: 'polar_pmd',
  label: 'Polar sensor',
  service: kPolarPmdService,
  characteristics: <String>[kPolarPmdControlChar, kPolarPmdDataChar],
  // The frame's own timestamp is not used; beats are stamped on arrival.
  // See [TimeAnchor].
  timeAnchor: TimeAnchor.arrival,
  nameMatcher: _looksLikePolarPpi,
  scanHints: <String>[kHeartRateServiceUuid, kPolarAdvertisedHint],
);

bool _looksLikePolarPpi(String lowercaseName) =>
    lowercaseName.startsWith('polar ') && !lowercaseName.startsWith('polar h');

/// The Oura ring, a fetch-by-cursor band with a challenge-response handshake.
///
/// NOT framed, and the three fields a framed entry carries would each be wrong
/// here: the length is a u8 that counts payload only, there is no CRC anywhere
/// in the protocol, and there is no inner opcode byte to find. `isFramed ==
/// false` keeps it out of [kFramedBands], which is what keeps it out of the
/// offload engine's scan filter and out of the band half of the iOS
/// AccessorySetupKit plist — both of which are about the primary band that
/// holds a link and gets trimmed. It IS in [kAskPickerSensors], which gives it
/// a picker of its own on iOS 18+.
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

/// A Coros sports watch (Pace/Apex/Vertix series). A PACE 3 on 2025 firmware
/// answered every standard GATT service on a plain connect, no pairing or
/// bonding, but only while it was not connected to the COROS phone app.
/// COROS has since shipped patches (no firmware version named), so newer
/// firmware may require pairing; Apex/Vertix are unverified.
///
/// FOUND BY NAME, CHECKED BY ITS GATT. The advertisement carries the shared
/// 16-bit 0xFEE7 (a scan hint, never an identity) and the watch's name, not
/// [kCorosService]; [nameMatcher] picks it out and pairing confirms
/// [kCorosService] after connect.
///
/// NOT framed: no envelope, no command channel, no offload — see the header
/// note on why activity/sleep/step history stays out of scope entirely.
///
/// `characteristics` IS BATTERY ALONE, deliberately. The Bluetooth SIG's
/// Device Information Service marks model/serial/firmware as OPTIONAL —
/// gating the connect on any of them is how a real watch that simply omits
/// one string fails `missingCharacteristics` and never connects at all.
/// `CorosAdapter._readString` already answers null for a characteristic that
/// is not there; the honest gate is the one characteristic every watch in
/// scope should answer. Heart rate is read via [kHeartRateMeasurementUuid]
/// directly in `coros.dart` and is equally NOT required here, for the same
/// reason: a watch that answers battery and identity but not heart rate
/// should still connect.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}`-equivalent territory for anything but the generic HR parse —
/// `kDerivableSources` stays empty regardless, same as every other band here.
const BandEntry kCoros = BandEntry.notify(
  id: 'coros',
  label: 'Coros watch',
  service: kCorosService,
  characteristics: <String>[kBatteryLevelUuid],
  timeAnchor: TimeAnchor.arrival,
  nameMatcher: _looksLikeCoros,
  scanHints: <String>[kColmiAdvertisedHint],
);

bool _looksLikeCoros(String lowercaseName) =>
    lowercaseName.startsWith('coros');

/// A Garmin sports watch (GFDI v2), paired through the watch's own
/// Settings -> Sensors & Accessories -> Phone -> Pair Phone menu.
///
/// NOT framed: there is a frame length and a CRC, but they sit inside a COBS
/// byte stream carried on a Multi-Link handle rather than directly on the
/// characteristic the way [BandProfile] models — a different reassembly
/// shape [innerOpcodeOffset] etc. could not describe. See `protocol`'s
/// `garmin.dart` for the wire format itself.
///
/// FOUND BY ITS ADVERTISEMENT, CHECKED BY ITS GATT. A watch is matched in the
/// scan by company id or service data ([kGarminCompanyIds],
/// [kGarminServiceDataUuids]); [kGarminService] is what is checked after
/// connect, together with at least one multi-link data characteristic
/// (`garminMlPair`). `characteristics` is empty because which data
/// characteristic a watch exposes varies, so the generic check cannot name
/// one.
///
/// THAT ADVERTISEMENT MATCH IS ANDROID'S. On iOS the AccessorySetupKit sensor
/// picker builds its descriptor from [kGarminService] alone, and Core
/// Bluetooth only reaches accessories approved there, so a watch that does
/// not advertise that service still cannot be found on iOS. Declaring the
/// company id ([kAskSensorCompanyIds]) does not change the descriptor's
/// service requirement. A service-data descriptor is not tried: it has not
/// been checked against ASK's descriptor validation, whose failures trap.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns a Garmin
/// watch, so not a byte of this path has met hardware (ASSUMPTIONS R6).
/// This id is absent from `kDerivableSources`: the watch's health FIT files
/// are downloaded and decoded into sparse HR (`hrSparse`, outside
/// derivation) and attributed vendor observations.
const BandEntry kGarmin = BandEntry.notify(
  id: 'garmin',
  label: 'Garmin watch',
  service: kGarminService,
  characteristics: <String>[],
  scanCompanyIds: kGarminCompanyIds,
  scanServiceData: kGarminServiceDataUuids,
  // No clock this build reads back; the watch's own GFDI clock is what
  // CURRENT_TIME_REQUEST answers, not something read into a stored sample.
  timeAnchor: TimeAnchor.arrival,
);

/// The Ultrahuman Ring Air. A fetch-by-index band with no auth and no
/// envelope: a bare `[opcode, ...body]` request and a
/// `[opcode, result, count, payload…, trailer(2)]` response, both on ONE
/// notify characteristic.
///
/// [TimeAnchor.measured]: unlike Oura's undocumented decisecond-uptime
/// counter, this ring's record carries its own unix-second timestamp — three
/// of them, independently — so a record IS its own clock and needs no
/// cross-session anchor.
///
/// NOT framed. There is no CRC anywhere in this protocol, no inner opcode byte
/// inside an envelope (there is no envelope), and the ring never trims on our
/// say-so — `0x04` fetches by record index, so a re-read is idempotent
/// exactly the way Oura's fetch-by-cursor is (`OffloadCheckpoint`'s own
/// "fetch-by-range" row).
///
/// EXPERIMENTAL: the decoder has not met a physical ring (ASSUMPTIONS R6), so
/// `kDerivableSources` does not name this id. Each 32-byte record is banked
/// verbatim and decoded into sparse HR (`source = 'ultrahuman'`, outside
/// derivation) plus daily vendor observations — see `ultrahuman.dart`.
///
/// FOUND BY NAME. The ring is not required to advertise its 128-bit service,
/// and it names itself `UH_…` (or `UP_…`), so this entry sets [scanByName]:
/// its scan runs without the OS-level service filter and [nameMatcher] picks
/// the ring out. The command service is still required after connect.
/// The iOS AccessorySetupKit picker cannot match on a name alone (it needs
/// the service UUID beside any name substring), so there it is still found
/// by service only.
const BandEntry kUltrahuman = BandEntry.notify(
  id: 'ultrahuman',
  label: 'Ultrahuman Ring Air',
  service: kUltrahumanCommandService,
  characteristics: <String>[kUltrahumanWriteChar, kUltrahumanNotifyChar],
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeUltrahuman,
  scanByName: true,
);

bool _looksLikeUltrahuman(String lowercaseName) =>
    lowercaseName.contains('uh_') || lowercaseName.contains('up_');

/// Mi Band 2 and 3 — the shared "Huami legacy" GATT protocol. The registry
/// id stays `miband234`: it is a storage key (`device_family`), never renamed.
///
/// A locally-generated AES-128 challenge/response: no cloud, no vendor
/// account. MI BAND 4 IS NOT COVERED: it only accepts a key issued through
/// the vendor's own pairing, which this app does not use.
///
/// After auth the host sets the band's clock and reads its stored activity
/// (one record per minute: activity kind incl. light/deep sleep, steps, HR)
/// — see `miband234.dart`. The band's drop-acknowledgement is never sent.
///
/// FOUND BY NAME. The band is not known to advertise [kHuami234Service], so
/// this entry sets [scanByName]: its scan runs without the OS-level service
/// filter and [nameMatcher] picks the band out. The service is still
/// required after connect.
///
/// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project owns one, so
/// `kDerivableSources` does not name it. HR lands as sparse samples outside
/// derivation; sleep as the band's own hypnogram; steps as observations.
const BandEntry kMiBand234 = BandEntry.notify(
  id: 'miband234',
  label: 'Mi Band 2/3',
  service: kHuami234Service,
  characteristics: <String>[kHuami234AuthChar],
  // The host sets the band's clock; stored minutes are stamped against it.
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeMiBand23,
  scanByName: true,
);

/// The names Mi Band 2 and Mi Band 3 advertise.
bool _looksLikeMiBand23(String lowercaseName) => const {
      'mi band 2',
      'mi2',
      'mi band 3',
      'xiaomi band 3',
    }.contains(lowercaseName);

/// Pebble 2 / Pebble 2 SE. Pure client, no envelope, no command channel —
/// PPoGATT is banked verbatim and nothing is decoded past it. `pebble_link.dart`'s
/// `PebbleLink` drives [PebbleAdapter.run] on a periodic bounded window; see
/// `pebble.dart`'s header for both that shape and why every older Pebble
/// model is out of reach.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6).
const BandEntry kPebble = BandEntry.notify(
  id: 'pebble',
  label: 'Pebble',
  service: kPebbleServiceUuid,
  characteristics: <String>[
    kPebblePairingTriggerUuid,
    kPebbleConnectivityUuid,
    kPebbleMtuUuid,
    kPebblePpogattReadUuid,
    kPebblePpogattWriteUuid,
  ],
  // No clock of its own reaches this layer — every banked chunk is stamped by
  // arrival, same as every other notify-class entry with no measured origin.
  timeAnchor: TimeAnchor.arrival,
  // See `kPebblePairingTriggerUuid`'s doc comment — a write here is what
  // moves the watch into bonded state, and PPoGATT never authenticates
  // without it.
  bondTriggerCharacteristic: kPebblePairingTriggerUuid,
);

/// This ring family is found BY NAME: `R01`-`R06` or `R09` followed by
/// anything (`R02_1A2B`, `R05`), `COLMI R07_*` / `COLMI R10_*` /
/// `COLMI R12_*`, or `Qore*` (the same ring platform). The
/// ring's own pairing flow matches a bare name prefix, with no underscore
/// required, so neither is this. The advertisement is not known to carry
/// `6e40fff0…` (that is the GATT service checked after connect); what it
/// does carry is the shared 16-bit `0xFEE7` ([kColmiAdvertisedHint]), and a
/// result that came in on that alone is kept only when this matches. Takes
/// the already-lowercased name.
bool _looksLikeColmi(String lowercaseName) =>
    RegExp(r'^r0[1-69]').hasMatch(lowercaseName) ||
    RegExp(r'^colmi r(?:07|10|12)_').hasMatch(lowercaseName) ||
    lowercaseName.startsWith('qore');

/// 16-bit service `0xFEE7` this ring family advertises. SHARED by many
/// unrelated wearables, so it only widens the scan filter
/// ([BandEntry.scanHints]) and never identifies a ring on its own.
const String kColmiAdvertisedHint = '0000fee7-0000-1000-8000-00805f9b34fb';

/// Colmi smart ring family (advertised as `R01`-`R06`/`R09` + anything,
/// `COLMI R07_*`, `COLMI R10_*`, `COLMI R12_*`, and `Qore*`,
/// all on the same firmware platform). Checksummed command/notify
/// frames plus a second "big data" service, no encryption and no handshake —
/// connect, discover, subscribe, write.
///
/// [TimeAnchor.measured]: the host sets the ring's clock at the start of
/// every session and every history slot is stamped by the ring against it.
///
/// Required characteristics are Service A's only; Service B's are optional
/// (see [kColmiCommandChar]).
///
/// EXPERIMENTAL: the decoders have not met a physical ring (ASSUMPTIONS R6),
/// so `kDerivableSources` does not name this id — its HR rows are banked
/// with `source = 'colmi'` and stay out of derivation.
const BandEntry kColmi = BandEntry.notify(
  id: 'colmi',
  label: 'Colmi ring',
  service: kColmiService,
  characteristics: <String>[kColmiWriteChar, kColmiNotifyChar],
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeColmi,
  scanHints: <String>[kColmiAdvertisedHint],
);

/// A Bluetooth SIG Health Thermometer (service 0x1809) — the Femometer Vinca 2
/// basal thermometer, and any other compliant thermometer. No auth: the host
/// sets the clock (Current Time, optional) and reads indicated readings.
///
/// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project owns one. Readings
/// become attributed `body_temp` observations; nothing derives from them.
const BandEntry kThermometer = BandEntry.notify(
  id: 'thermometer',
  label: 'Bluetooth thermometer',
  service: kHtpService,
  characteristics: <String>[kHtpTemperatureMeasurement],
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeThermometer,
);

bool _looksLikeThermometer(String lowercaseName) =>
    lowercaseName.startsWith('bm-vinca');

/// The Xiaomi Mi Body Composition Scale ("MIBCS" / "MIBFS"): weight and
/// bio-impedance over the standard Body Composition service, plus a stored
/// history the host reads back. No auth.
///
/// The scale carries its service UUID as advertised SERVICE DATA, which an
/// OS-level service filter does not match, so it is also named there
/// ([BandEntry.scanServiceData]).
///
/// EXPERIMENTAL (ASSUMPTIONS R6). Weight becomes a `weight` observation and
/// impedance a vendor observation; nothing derives from either.
const BandEntry kMiScaleComposition = BandEntry.notify(
  id: 'miscale_bc',
  label: 'Mi Body Composition Scale',
  service: kMiScaleBodyCompositionService,
  characteristics: <String>[kMiScaleBodyCompositionChar],
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeMiCompositionScale,
  scanServiceData: <String>[kMiScaleBodyCompositionService],
);

bool _looksLikeMiCompositionScale(String lowercaseName) =>
    lowercaseName == 'mibcs' || lowercaseName == 'mibfs';

/// The Xiaomi Mi Smart Scale 2 ("MI SCALE2"): weight over the standard Weight
/// Scale service, plus a stored history the host can read back. No auth.
/// Its service UUID is advertised as service data too, like
/// [kMiScaleComposition]'s.
///
/// EXPERIMENTAL (ASSUMPTIONS R6). Readings become `weight` observations.
const BandEntry kMiScale2 = BandEntry.notify(
  id: 'miscale2',
  label: 'Mi Smart Scale 2',
  service: kMiScaleWeightService,
  characteristics: <String>[kMiScaleWeightChar],
  timeAnchor: TimeAnchor.measured,
  nameMatcher: _looksLikeMiScale2,
  scanServiceData: <String>[kMiScaleWeightService],
);

bool _looksLikeMiScale2(String lowercaseName) => lowercaseName == 'mi scale2';

/// Every band this build can see. Order is match order during discovery.
const List<BandEntry> kBandRegistry = <BandEntry>[
  kWhoopGen4,
  kWhoopGen5,
  kBleHrs,
  kOura,
  kPolarPmd,
  kCoros,
  kUltrahuman,
  kMiBand234,
  kPebble,
  kColmi,
  kGarmin,
  kThermometer,
  kMiScaleComposition,
  kMiScale2,
];

/// The bands the OFFLOAD ENGINE can drive, and the bands iOS provisions
/// through the AccessorySetupKit picker — the same set, for the same reason:
/// both are about the primary band that holds a link, keeps a flash and gets
/// trimmed. A notify-only sensor is connected straight from its stored remote
/// id during a workout, so putting it in the ASK plist would only add chest
/// straps to the WHOOP pairing picker.
final List<BandEntry> kFramedBands =
    kBandRegistry.where((e) => e.isFramed).toList(growable: false);

/// Notify-class entries that iOS 18+ pairs through the AccessorySetupKit
/// picker instead of a CoreBluetooth scan.
///
/// WHY A SCAN IS NOT ENOUGH ON iOS. Info.plist declares
/// `NSAccessorySetupKitSupports`, so the app never receives the standard
/// Bluetooth authorization — Settings → Apps → Edge has no Bluetooth row at
/// all. Core Bluetooth then only reaches accessories the user approved in the
/// ASK picker, and a plain `startScan` for anything else returns nothing, with
/// no error (issues #371/#372). A sensor listed here gets its own ASK
/// descriptor, and its pairing screen shows the picker filtered to its service
/// alone, so the WHOOP picker never offers it (the plist marks these services
/// under `OSAskSensorServices`, which `AccessorySetup.swift` excludes from the
/// band picker).
///
/// MEMBERSHIP: a notify-class entry whose ADVERTISED service is the one its
/// picker filters on, one per service UUID in Info.plist's
/// `OSAskSensorServices` (kept in sync by `test/ios_ask_plist_test.dart`).
/// Each entry adds one more row the picker can show. [kBleHrs] qualifies:
/// the Heart Rate Service has a heart-rate sensor advertise 0x180D.
///
/// [kPolarPmd] and [kCoros] are NOT listed, deliberately: neither advertises
/// the service it is identified by (PMD; the Coros vendor service), and the
/// UUIDs they do advertise (0x180D, 0xFEE7) are shared with other entries, so
/// a picker filtered on them would hand back another sensor's approval. On
/// iOS 18+ they cannot be paired yet; `PairSensorScreen` says so.
///
/// [kMiBand234], [kMiScaleComposition] and [kMiScale2] are listed although
/// they break the rule above: the band is not known to advertise FEE1, and
/// the scales carry 181B / 181D as service DATA, not in the service list.
/// Whether the picker matches either is untested, so on iOS 18+ they may not
/// be found at all. They stay listed because outside this list they have no
/// iOS 18+ path whatever, and none of their UUIDs is shared with another
/// entry, so the picker cannot hand back another sensor's approval.
const List<BandEntry> kAskPickerSensors = <BandEntry>[
  kBleHrs,
  kOura,
  kColmi,
  kUltrahuman,
  kMiBand234,
  kPebble,
  kGarmin,
  kThermometer,
  kMiScaleComposition,
  kMiScale2,
];

/// A service UUID as Core Bluetooth spells it: a Bluetooth-base UUID
/// (`0000XXXX-0000-1000-8000-00805F9B34FB`) collapses to its 16-bit `XXXX`,
/// which is what `CBUUID.uuidString` returns and what AccessorySetup.swift
/// compares against; a vendor 128-bit UUID stays whole. Info.plist declares
/// services in this form and `AccessorySetup.showSensorPicker` sends them in
/// it, so the Swift subset check and label lookup match.
String plistUuid(String service) {
  final u = service.toUpperCase();
  final m = RegExp(r'^0000([0-9A-F]{4})-0000-1000-8000-00805F9B34FB$')
      .firstMatch(u);
  return m == null ? u : m.group(1)!;
}

/// The Bluetooth SIG company identifier each [kAskPickerSensors] entry puts in
/// its advertisement's manufacturer data, by entry id. Declared in Info.plist's
/// `NSAccessorySetupBluetoothCompanyIdentifiers` and NOWHERE ELSE.
///
/// WHY IT HAS TO BE DECLARED. A device whose advertisement carries
/// manufacturer data was not found by the ASK picker while only its service
/// was declared ("No accessory found"); with its company identifier declared
/// as well, the same picker found it (iPhone, iOS 27, Oura ring advertising
/// `ff b2 02 …`). This matches an Apple developer-forum report for the same
/// symptom.
///
/// WHY IT IS NOT ON THE DESCRIPTOR. Setting `bluetoothCompanyIdentifier` on
/// the ASDiscoveryDescriptor trapped on iOS 27 ("'NSAccessorySetupBluetooth
/// CompanyIdentifiers' has no item '2b2' in Info.plist"), whatever spelling
/// the plist used. The declaration alone is what made discovery work.
const Map<String, int> kAskSensorCompanyIds = <String, int>{
  'oura': 0x02B2, // Oura Health Oy
  'garmin': 0x0087, // Garmin International
};

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
/// `ble_hrs.dart`'s `BleHrsAdapter.signals`, `oura.dart`'s
/// `OuraAdapter.signals` and `ultrahuman.dart`'s `UltrahumanAdapter.signals`
/// (and each remaining adapter's own `signals`), since importing those back
/// into this file (each of which already imports THIS file for its
/// `BandEntry`) would be a needless import cycle for a handful of lines of
/// data.
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
  'polar_pmd': {
    InputSignal.hrSparse: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
  },
  'coros': {
    InputSignal.hrSparse: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
  },
  'ultrahuman': {InputSignal.hrSparse: Duration(minutes: 5)},
  'miband234': {InputSignal.hrSparse: Duration(minutes: 1)},
  'pebble': {InputSignal.hrSparse: Duration(minutes: 1)},
  'colmi': {InputSignal.hrSparse: Duration(minutes: 5)},
  'thermometer': <InputSignal, Duration>{},
  'miscale_bc': <InputSignal, Duration>{},
  'miscale2': <InputSignal, Duration>{},
  'garmin': {InputSignal.hrSparse: Duration(minutes: 1)},
};

/// The signals one adapter declares, or empty for an id this build has no
/// entry for — mirrors `bandLabelFor`'s null-is-honest shape
/// (`devices.dart:122-127`): an unknown device is never quietly filed under
/// the nearest one we know.
Set<InputSignal> declaredSignals(String? adapterId) =>
    kAdapterSignals[adapterId]?.keys.toSet() ?? const {};
