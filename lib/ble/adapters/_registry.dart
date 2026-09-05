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

/// A generic white-label smart ring's GATT service ("R11M"/"R10M", also sold
/// as "TK5") — NOT the Colmi R11/R12, a different, unrelated product on a
/// different protocol.
const String kRing11mService = 'be940000-7333-be46-b7ae-689e71722bd5';

/// Host to ring. Every command is written here, with response, and direct
/// replies arrive on it too.
const String kRing11mCommandChar = 'be940001-7333-be46-b7ae-689e71722bd5';

/// Ring to host. Bulk history blocks stream here.
const String kRing11mHistoryChar = 'be940003-7333-be46-b7ae-689e71722bd5';

/// Withings Steel HR / Activité's GATT service. One characteristic, both
/// directions: commands are written to it, every reply arrives as a
/// notification on the same UUID.
const String kWithingsSteelHrService = '00000020-5749-5448-0037-000000000000';
const String kWithingsWriteChar = '00000024-5749-5448-0037-000000000000';

/// The DaFit/MOYOUNG-V2 clone-watch family's GATT service — an otherwise
/// generic Nordic UART Service. Shared by the whole cluster of unbranded
/// boards this build recognizes (M6/M4/LH716/Sunset 6/Watch7/Fit1900-style),
/// sold under many storefront names but all speaking the same envelope.
const String kDafitService = '6e400001-b5a3-f393-e0a9-e50e24dcca9d';

/// Host to band. Every command frame and ack is written here, with response.
const String kDafitWriteChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9d';

/// Band to host. Every reply, ack and unsolicited frame arrives here.
const String kDafitNotifyChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9d';

/// Device Information Service's System ID characteristic — an 8-byte EUI-64.
/// Standard GATT, not band-specific; RingConn is the first entry that needs
/// to read it (its own BLE MAC has to come from somewhere, and there is no
/// vendor server to ask — see `ringconn.dart`'s `ringConnMacFromSystemId`).
const String kSystemIdUuid = '00002a23-0000-1000-8000-00805f9b34fb';

/// The Fossil/Skagen Q Hybrid's GATT service. NOT the encrypted Hybrid HR /
/// Gen 6 sibling, which advertises this same UUID — see [kQHybrid]'s own doc.
const String kQHybridService = '3dda0001-957f-7d4a-34a6-74696673696d';

/// Host-to-watch control characteristic: write + notify, flat
/// `[type, cmdId, ...payload]` request / `[3, cmdId, ...payload]` response,
/// no CRC, no envelope.
const String kQHybridControlChar = '3dda0002-957f-7d4a-34a6-74696673696d';

/// File-download notify characteristics. A separate, undecoded chunking
/// sub-protocol — banked raw only.
const String kQHybridFileChar1 = '3dda0003-957f-7d4a-34a6-74696673696d';
const String kQHybridFileChar2 = '3dda0004-957f-7d4a-34a6-74696673696d';

/// A third notify characteristic in the same service — also used for a
/// vibrate/find-my-watch write on the real device. Undecoded — banked raw
/// only, same as the two above.
const String kQHybridAuxChar = '3dda0005-957f-7d4a-34a6-74696673696d';

/// Button-press notify characteristic. Fixed 11-byte frames — banked raw only.
const String kQHybridButtonChar = '3dda0006-957f-7d4a-34a6-74696673696d';

/// File-upload-ack notify characteristic — banked raw only.
const String kQHybridUploadAckChar = '3dda0007-957f-7d4a-34a6-74696673696d';

/// Casio's "2C/2D all-features" GATT service — shared across the current
/// G-Shock/smartwatch line (GBX100, GW-B5600, GMW-B5000, ECB-S100/Edifice and
/// later models speaking the same profile). NOT the older `KEY_CONTAINER`-only
/// scheme (e.g. GB-6900), a different and incompatible wire scheme that is out
/// of scope here.
const String kCasioService = '26eb000d-b012-49a8-b1f8-394fb2032b0f';

/// Host to watch: a one- or two-byte feature-request tag, write-with-response.
const String kCasioReadRequestChar = '26eb002c-b012-49a8-b1f8-394fb2032b0f';

/// Watch to host: every feature reply and setting notification shares this one
/// characteristic — `[featureTag, ...payload]`, the first byte echoing the
/// request. Reads and writes for settings both land here too; this adapter
/// only ever reads.
const String kCasioAllFeaturesChar = '26eb002d-b012-49a8-b1f8-394fb2032b0f';

/// The Oura ring's GATT service, identical across the generations seen so far.
const String kOuraService = '98ed0001-a541-11e4-b6a0-0002a5d5c51b';

/// RingConn's one data service — Gen 2, Gen 2 Air and Gen 3 all speak the
/// identical service, characteristics, framing and opcode set.
const String kRingConnService = '8327ad99-2d87-4a22-a8ce-6dd7971c0437';

/// Host to ring. Every RingConn command is written here, with response.
const String kRingConnCommandChar = '8327ad98-2d87-4a22-a8ce-6dd7971c0437';

/// Ring to host. Every status reply and every history page share this one
/// characteristic — there is no separate data pipe.
const String kRingConnNotifyChar = '8327ad97-2d87-4a22-a8ce-6dd7971c0437';

/// Host to ring. Every Oura command is written here, with response.
const String kOuraCommandChar = '98ed0002-a541-11e4-b6a0-0002a5d5c51b';

/// Ring to host. Command replies, asynchronous notifications and every history
/// event share this one characteristic — there is no separate data pipe.
const String kOuraNotifyChar = '98ed0003-a541-11e4-b6a0-0002a5d5c51b';

/// One of the Nordic-UART-shaped 128-bit services a Coros watch exposes
/// alongside the standard SIG services below — used here only as the scan
/// filter, since a bare `0000180d` (heart rate) would collide with
/// [kBleHrs] and get shadowed by it (that entry is matched first). NOT
/// independently confirmed against a real advertisement payload (post-connect
/// service enumeration is documented; the advertised UUID list is not) — see
/// `coros.dart`'s own header before trusting this against real hardware.
const String kCorosService = '6e400001-b5a3-f393-e0a9-77656c6f6f70';

/// Standard Battery Service characteristic, read+notify, one byte 0-100.
const String kBatteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';

/// Standard Device Information Service characteristics — read-only UTF-8
/// strings, no notify property.
const String kModelNumberUuid = '00002a24-0000-1000-8000-00805f9b34fb';
const String kSerialNumberUuid = '00002a25-0000-1000-8000-00805f9b34fb';
const String kFirmwareRevisionUuid = '00002a26-0000-1000-8000-00805f9b34fb';

/// Garmin's Multi-Link service — one characteristic pair carries every
/// logical service (GFDI, the numbered real-time streams) this device family
/// speaks, routed by a handle byte. See `protocol`'s `garmin.dart`.
const String kGarminService = '6a4e2800-667b-11e3-949a-0800200c9a66';

/// Host to watch. Every ML control frame and every GFDI/COBS chunk is
/// written here, with response.
const String kGarminWriteChar = '6a4e2820-667b-11e3-949a-0800200c9a66';

/// Watch to host. Every ML control reply and every GFDI/COBS chunk arrives
/// here — there is no separate data pipe.
const String kGarminNotifyChar = '6a4e2810-667b-11e3-949a-0800200c9a66';

/// The Ultrahuman Ring Air's command/response service. The primary service —
/// `BandEntry.notify` points at this one, not the device-state service below.
const String kUltrahumanCommandService = '86f65000-f706-58a0-95b2-1fb9261e4dc7';

/// Host to ring. Write-with-response, which is also what triggers bonding.
const String kUltrahumanWriteChar = '86f65001-f706-58a0-95b2-1fb9261e4dc7';

/// Ring to host. Every command reply and every history batch.
const String kUltrahumanNotifyChar = '86f65002-f706-58a0-95b2-1fb9261e4dc7';

/// Battery/temperature notify characteristic on a SEPARATE service. Optional —
/// not in [kUltrahuman]'s required characteristics — so a ring that does not
/// answer on it still pairs and drains.
const String kUltrahumanDeviceStateChar = '86f61001-f706-58a0-95b2-1fb9261e4dc7';

/// Nordic's UART Service — a public vendor spec used as a generic
/// serial-over-BLE pipe, not a protocol any one product owns. NOT unique to
/// Bangle.js: Puck.js, Pixl.js, MDBT42Q and any other Espruino/Nordic dev
/// board answers the same UUID, and nothing in the notify-class pairing scan
/// narrows on a name — [kBangleJs] pairs whatever advertises this service.
/// [kBangleJs]'s own doc, and the pairing blurb a user actually sees, say so
/// plainly rather than imply a precision this entry does not have.
const String kNordicUartService = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

/// Host writes here ("RX" on the peripheral side). Plain text, no envelope,
/// no length field, no CRC.
const String kNordicUartRxChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// Peripheral notifies here ("TX" on the peripheral side). Plain text — a
/// line is only `\n`-terminated when something on the watch decides to print
/// one, which this adapter never assumes.
const String kNordicUartTxChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// The Mi Band 2/3/4 family's own GATT service. Standard SIG 128-bit base.
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

/// The Makibes HR3's service — the standard Nordic UART Service, reused by
/// large numbers of unrelated gadgets, not a fingerprint on its own.
const String kMakibesHr3Service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

/// Host to band. Every command this board answers is written here.
const String kMakibesHr3ControlChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// Band to host, notify. Every reply and every unprompted push share this
/// one characteristic.
const String kMakibesHr3ReportChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// The ID115's service.
const String kId115Service = '00000af0-0000-1000-8000-00805f9b34fb';

/// Host to band, general channel (settings, notifications, bind/unbind).
const String kId115WriteNormalChar = '00000af6-0000-1000-8000-00805f9b34fb';

/// Band to host, general channel — command replies and unprompted pushes.
const String kId115NotifyNormalChar = '00000af7-0000-1000-8000-00805f9b34fb';

/// Host to band, the SEPARATE health-data channel (today's activity fetch).
const String kId115WriteHealthChar = '00000af1-0000-1000-8000-00805f9b34fb';

/// Band to host, the health-data channel's own replies.
const String kId115NotifyHealthChar = '00000af2-0000-1000-8000-00805f9b34fb';

/// The SMA-Q2-OSS watch's service — a board-specific UUID, not the standard
/// Nordic UART Service its numbering resembles.
const String kSmaq2ossService = '51be0001-c182-4f3a-9359-21337bce51f6';

/// Host to watch. Every command this board answers is written here.
const String kSmaq2ossWriteChar = '51be0002-c182-4f3a-9359-21337bce51f6';

/// Watch to host, notify. Every reply and every unprompted push share this
/// one characteristic.
const String kSmaq2ossNotifyChar = '51be0003-c182-4f3a-9359-21337bce51f6';

/// The XWatch's service — the generic `0xfff0` custom-service pattern many
/// unrelated boards reuse, not a fingerprint on its own.
const String kXWatchService = '0000fff0-0000-1000-8000-00805f9b34fb';

/// Host to watch. Every command this board answers is written here.
const String kXWatchWriteChar = '0000fff6-0000-1000-8000-00805f9b34fb';

/// Watch to host, notify. Every reply and every unprompted push share this
/// one characteristic.
const String kXWatchNotifyChar = '0000fff7-0000-1000-8000-00805f9b34fb';

/// The Watch9's service.
const String kWatch9Service = '0000a800-0000-1000-8000-00805f9b34fb';

/// The ONE characteristic this board answers on. Both directions share it —
/// a command written here gets its reply back on the same UUID — and the
/// three sibling characteristics its GATT table advertises (`…a802`
/// `…a803` `…a804`) are read by no known client at all.
const String kWatch9Char = '0000a801-0000-1000-8000-00805f9b34fb';

/// The NO1-family service, shared byte-for-byte by the TLW64 and the F1 —
/// same service, same control/notify pair, same command bytes for every
/// function the two have in common. The F1 additionally answers a few
/// opcodes (realtime steps, realtime/fetch heart rate) the TLW64's firmware
/// does not, which is a superset relationship, not a different protocol.
const String kNo1Service = '000055ff-0000-1000-8000-00805f9b34fb';

/// Host to band, one command byte per write, no length field and no
/// checksum.
const String kNo1ControlChar = '000033f1-0000-1000-8000-00805f9b34fb';

/// Band to host. Every reply and every unprompted push share this one
/// characteristic.
const String kNo1NotifyChar = '000033f2-0000-1000-8000-00805f9b34fb';

/// The Wellue O2Ring's GATT service (Viatom's pulse-oximeter ring family).
const String kO2RingService = '14839ac4-7d7e-415c-9a42-167340cf2339';

/// Host to ring. Every command is written here.
const String kO2RingWriteChar = '8b00ace7-eb0b-49b0-bbe9-9aee0a26e1a3';

/// Ring to host. Every command reply arrives here.
const String kO2RingNotifyChar = '0734594a-a8e7-4b1a-a6b1-cd5243059a57';

/// MyKronoz ZeTime's base command service. A second service two digits up
/// (`00007006-…`) carries one more characteristic this project does not use —
/// the four here are the whole of what a device-fact probe needs.
const String kZeTimeService = '00006006-0000-1000-8000-00805f9b34fb';

/// Host to watch. Every command frame is written here.
const String kZeTimeWriteChar = '00008001-0000-1000-8000-00805f9b34fb';

/// Written with the fixed token `kZeTimeAckToken` after every write to
/// [kZeTimeWriteChar] — the watch's own acknowledgement handshake, not a
/// second command channel.
const String kZeTimeAckChar = '00008002-0000-1000-8000-00805f9b34fb';

/// Watch to host, synchronous command replies. Not read by this build — every
/// reply it wants arrives on [kZeTimeNotifyChar] instead — but still in
/// [kZeTime]'s required-characteristic set: a watch missing it is not
/// considered paired.
const String kZeTimeReplyChar = '00008003-0000-1000-8000-00805f9b34fb';

/// Watch to host, asynchronous notifications. Every reply this build decodes
/// arrives here.
const String kZeTimeNotifyChar = '00008004-0000-1000-8000-00805f9b34fb';

/// The service a WearFit-family band advertises for discovery. It carries no
/// characteristics of its own — the write/notify pair below live on a
/// separate, otherwise-generic Nordic UART Service the band exposes once
/// connected. Shared by every Howear-branded model this build recognizes
/// (HK8 Ultra, HK8 Pro Max and the like), which all speak the same envelope.
const String kWearFitScanService = '0000fee7-0000-1000-8000-00805f9b34fb';

/// Host to band, on the Nordic UART Service. Write-with-response, same as
/// every other band's command characteristic.
const String kWearFitWriteChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// Band to host. Every reply and every unsolicited frame arrives here.
const String kWearFitNotifyChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// The DT78/DT92/DT66 family's service — a Nordic UART Service instance, and
/// NOT a fingerprint: this exact triple is reused by unrelated gadgets (see
/// `kDt78`'s own doc comment below).
const String kDt78Service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

/// Host to watch, write-without-response in both reference clients.
const String kDt78WriteChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// Watch to host, notify. Every reply and every unprompted push share this
/// one characteristic.
const String kDt78NotifyChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// The Lefun-protocol family's GATT service. One shared write/notify pair
/// covers battery, firmware info and every historical report code alike —
/// there is no separate command channel the way Oura's ring has.
const String kLefunService = '000018d0-0000-1000-8000-00805f9b34fb';
const String kLefunWriteChar = '00002d01-0000-1000-8000-00805f9b34fb';
const String kLefunNotifyChar = '00002d00-0000-1000-8000-00805f9b34fb';

/// The HPlus reference GATT service — one service shared across a whole
/// family of low-cost wrist bands, not one product.
const String kHPlusService = '14701820-620a-3973-7c78-9cfff0876abd';

/// Host to band. Every HPlus command is written here, plaintext, no
/// response required by the device.
const String kHPlusControlChar = '14702856-620a-3973-7c78-9cfff0876abd';

/// Band to host. Every notification — realtime stats, firmware version,
/// sleep and day-summary records — shares this one characteristic.
const String kHPlusMeasureChar = '14702853-620a-3973-7c78-9cfff0876abd';

/// A Jyou/Y5-class band's GATT service. No auth, no envelope, no ambiguity
/// with either rebrand's own service UUID (BFH16, Teclast H30 — a separate,
/// unbuilt PR), so no scan-time name fallback is needed here.
const String kJyouService = '000056ff-0000-1000-8000-00805f9b34fb';

/// Host to band, write-with-response. Fixed 10-byte command frames.
const String kJyouControlChar = '000033f3-0000-1000-8000-00805f9b34fb';

/// Band to host. Variable-length frames tagged by their first byte.
const String kJyouMeasureChar = '000033f4-0000-1000-8000-00805f9b34fb';

/// A PineTime's motion service. Vendor-custom 128-bit uuid — its own GATT
/// identity, distinct from the SIG heart-rate service this same watch also
/// answers on (see [kHeartRateServiceUuid]).
const String kPineTimeMotionService = '00030000-78fc-48fe-8e23-433b3a1942d0';

/// Step count, notify. The only motion-service characteristic subscribed here
/// — the same service's raw tri-axial characteristic is a separate, less
/// settled read on real firmware, so nothing here touches it.
const String kPineTimeStepCountChar = '00030001-78fc-48fe-8e23-433b3a1942d0';

/// Colmi smart ring family's primary command/notify service. A second,
/// separate service (sleep + SpO2 "big data") coexists on the same ring and
/// is untouched by this build — see `colmi.dart`'s header.
const String kColmiService = '6e40fff0-b5a3-f393-e0a9-e50e24dcca9e';

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

/// A generic white-label smart ring, sold as "R11M"/"R10M"/"TK5" under many
/// storefront names — NOT the Colmi R11/R12, a different, unrelated product.
///
/// NOT framed: the wire has a group/command/length/CRC header but no inner
/// opcode byte the framed machinery's offsets could describe — see
/// `ring11m.dart` in `protocol`.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired ring
/// negotiates, archives every frame it sends, and surfaces no health signal
/// at all.
const BandEntry kRing11m = BandEntry.notify(
  id: 'ring11m',
  label: 'Smart ring (R11M/R10M)',
  service: kRing11mService,
  characteristics: <String>[kRing11mCommandChar, kRing11mHistoryChar],
  // No clock this build reads back from a history record — every frame is
  // stamped on arrival, same as the generic HRS strap.
  timeAnchor: TimeAnchor.arrival,
);

/// A Coros sports watch (Pace/Apex/Vertix series): every standard GATT
/// service answers a plain connect, no pairing or bonding enforced.
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
);

/// A Garmin sports watch (GFDI v2), paired through the watch's own
/// Settings -> Sensors & Accessories -> Phone -> Pair Phone menu.
///
/// NOT framed: there is a frame length and a CRC, but they sit inside a COBS
/// byte stream carried on a Multi-Link handle rather than directly on the
/// characteristic the way [BandProfile] models — a different reassembly
/// shape [innerOpcodeOffset] etc. could not describe. See `protocol`'s
/// `garmin.dart` for the wire format itself.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns a Garmin
/// watch, so not a byte of this path has met hardware (ASSUMPTIONS R6).
/// `signals` is `const {}` and this id is absent from `kDerivableSources` —
/// a paired watch answers a device-info push and one battery request, and
/// surfaces no health signal at all.
const BandEntry kGarmin = BandEntry.notify(
  id: 'garmin',
  label: 'Garmin watch',
  service: kGarminService,
  characteristics: <String>[kGarminWriteChar, kGarminNotifyChar],
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
/// EXPERIMENTAL, and it stays that way: nobody on this project owns a ring, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and `kDerivableSources` never gets this id — every field in the
/// 32-byte record is banked to `raw_archive` verbatim and none of it becomes a
/// number until someone has held one.
///
/// NO NAME-MATCHER SCAN FALLBACK, unlike gen4's. `BandEntry.notify` has no
/// such field at all — a notify-class entry's scan (`HrsLink.scanForAny`)
/// matches purely on the advertised service uuid, and only the FRAMED
/// constructor's [nameMatcher] plugs into anything (WHOOP's own
/// `transport.dart` scan). Adding one here would mean widening the seam for a
/// single band rather than using what it already offers.
const BandEntry kUltrahuman = BandEntry.notify(
  id: 'ultrahuman',
  label: 'Ultrahuman Ring Air',
  service: kUltrahumanCommandService,
  characteristics: <String>[kUltrahumanWriteChar, kUltrahumanNotifyChar],
  timeAnchor: TimeAnchor.measured,
);

/// Bangle.js: no byte-level record protocol at all. It exposes Nordic's UART
/// Service, a generic serial-over-BLE pipe, behind which runs a full Espruino
/// JavaScript REPL — the phone writes JS source text, the watch executes it
/// and prints text back. There is no auth, no crypto, no envelope, no CRC, no
/// length field and no opcode byte: a "record" here is whatever the currently
/// running JS app decides to print, terminated (or not) by `\n`.
///
/// Activity/HR/notification data only exists as JSON lines a user has to
/// separately install a third-party JS app to emit — that app's message
/// schema is not a firmware-level fact, it is a moving target owned by a
/// different, independently-versioned project a given watch may or may not be
/// running. So this entry pairs, connects and banks raw bytes only; see
/// `banglejs.dart` for the adapter.
///
/// [kNordicUartService] is not unique to Bangle.js — see its own doc. This
/// entry pairs anything advertising it, with no name-based narrowing; the
/// pairing screen's blurb says so to the user rather than implying a
/// precision this entry does not have.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). `kDerivableSources`
/// stays empty — decodable later only against firmware-level facts someone
/// with real hardware has verified, never against the companion app's JSON.
const BandEntry kBangleJs = BandEntry.notify(
  id: 'banglejs',
  label: 'Bangle.js',
  service: kNordicUartService,
  characteristics: <String>[kNordicUartRxChar, kNordicUartTxChar],
  // No clock readback path exists over this pipe; every chunk is stamped on
  // arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// Withings Steel HR / Activité. A challenge-response session gate, never
/// payload encryption — see `withings_steel_hr.dart` for the handshake and
/// [WithingsSteelHrAdapter.firstConnect] for why a fresh pairing skips it.
/// Matched by advertised name (`startsWith('steel')` or `startsWith(
/// 'activite')`, case-insensitive) is a pairing-UI concern, not a scan
/// filter — the custom service UUID above is already unambiguous.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one yet,
/// so not a byte of this path has met hardware (ASSUMPTIONS R6). It pairs,
/// connects and banks every reply raw; `kDerivableSources` stays empty until
/// someone has actually held one.
const BandEntry kWithingsSteelHr = BandEntry.notify(
  id: 'withings_steel_hr',
  label: 'Withings Steel HR',
  service: kWithingsSteelHrService,
  characteristics: <String>[kWithingsWriteChar],
  // Nothing here decodes a signal, let alone one with a clock of its own;
  // every archived frame is stamped on arrival like every other unproven
  // notify-class band.
  timeAnchor: TimeAnchor.arrival,
);

/// Mi Band 2, 3 and 4 — the shared "Huami legacy" GATT protocol, subclassed
/// unchanged across all three generations.
///
/// A locally-generated AES-128 challenge/response, same shape as [kOura]'s:
/// no cloud, no vendor account, no closed key material. AUTH is the only
/// REQUIRED characteristic — battery, steps and standard heart rate are
/// optional and best-effort (plain Mi Band 2 has no HR sensor at all; 2 HRX,
/// 3 and 4 do), same reasoning [BandEntry.notify]'s own doc gives for a
/// generic sensor.
///
/// Deliberately excluded from this generation's scope: Mi Band 5/6/7+ and Mi
/// Band 6's optional "new protocol" toggle, which negotiate real per-session
/// AES-CTR link encryption — a materially different, harder-to-verify crypto
/// path this entry does not claim.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). It pairs, connects
/// and banks battery/steps/HR raw; `kDerivableSources` stays empty until
/// someone has actually held one.
const BandEntry kMiBand234 = BandEntry.notify(
  id: 'miband234',
  label: 'Mi Band 2/3/4',
  service: kHuami234Service,
  characteristics: <String>[kHuami234AuthChar],
  // No clock in any channel this adapter reads; every frame is stamped on
  // arrival.
  timeAnchor: TimeAnchor.arrival,
);

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

/// The Makibes HR3, an unbranded OEM board sold under that one storefront
/// name.
///
/// NOT framed: no CRC and no inner-record layout the framed machinery's
/// [BandEntry.innerOpcodeOffset] etc. could describe — see
/// `makibeshr3.dart`. The service is the standard Nordic UART Service, which
/// on its own matches large numbers of unrelated gadgets — see
/// [kMakibesHr3Service]'s own doc.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired
/// board holds a session and archives every frame it sends, and surfaces no
/// health signal at all.
const BandEntry kMakibesHr3 = BandEntry.notify(
  id: 'makibeshr3',
  label: 'Makibes HR3',
  service: kMakibesHr3Service,
  characteristics: <String>[kMakibesHr3ControlChar, kMakibesHr3ReportChar],
  // No clock this build reads back — every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// The ID115, an unbranded OEM board sold under that one storefront name.
///
/// NOT framed: no CRC and no inner-record layout the framed machinery's
/// [BandEntry.innerOpcodeOffset] etc. could describe — see `id115.dart`.
/// TWO INDEPENDENT CHANNELS, not one: the general channel and the
/// health-data channel are a separate write/notify pair each, so both notify
/// characteristics are required — see `id115.dart`'s own header.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired
/// board holds a session and archives every frame it sends, and surfaces no
/// health signal at all.
const BandEntry kId115 = BandEntry.notify(
  id: 'id115',
  label: 'ID115',
  service: kId115Service,
  characteristics: <String>[
    kId115WriteNormalChar,
    kId115NotifyNormalChar,
    kId115WriteHealthChar,
    kId115NotifyHealthChar,
  ],
  // No clock this build reads back — every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// The SMA-Q2-OSS, an open-hardware smartwatch.
///
/// NOT framed: no CRC and no inner-record layout the framed machinery's
/// [BandEntry.innerOpcodeOffset] etc. could describe — see `smaq2oss.dart`.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired
/// watch holds a session and archives every frame it sends, and surfaces no
/// health signal at all.
const BandEntry kSmaq2oss = BandEntry.notify(
  id: 'smaq2oss',
  label: 'SMA-Q2-OSS',
  service: kSmaq2ossService,
  characteristics: <String>[kSmaq2ossWriteChar, kSmaq2ossNotifyChar],
  // No clock this build reads back — every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// The XWatch, an unbranded OEM board sold under that one storefront name.
///
/// NOT framed: no CRC and no inner-record layout the framed machinery's
/// [BandEntry.innerOpcodeOffset] etc. could describe — see `xwatch.dart`.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired
/// board holds a session and archives every frame it sends, and surfaces no
/// health signal at all.
const BandEntry kXWatch = BandEntry.notify(
  id: 'xwatch',
  label: 'XWatch',
  service: kXWatchService,
  characteristics: <String>[kXWatchWriteChar, kXWatchNotifyChar],
  // No clock this build reads back — every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// The Watch9, an unbranded OEM board sold under that one storefront name.
///
/// NOT framed: a real envelope exists (header/sequence/checksum) but there
/// is no CRC and no inner-record layout the framed machinery's
/// [BandEntry.innerOpcodeOffset] etc. could describe — see `watch9.dart`.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired
/// board holds a session and archives every frame it sends, and surfaces no
/// health signal at all.
const BandEntry kWatch9 = BandEntry.notify(
  id: 'watch9',
  label: 'Watch9',
  service: kWatch9Service,
  characteristics: <String>[kWatch9Char],
  // No clock this build reads back — every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// The NO1-family control board: the TLW64 smartwatch and the F1 wristband,
/// one entry for both since they answer the same service with the same
/// command bytes (see [kNo1Service]'s own doc).
///
/// NOT framed: no envelope, no CRC, one command byte per write. EXPERIMENTAL
/// and it stays that way — nobody on this project owns either device
/// (ASSUMPTIONS R6). `signals` is `const {}` and this id is absent from
/// `kDerivableSources`: this family readably exposes steps, sleep and (on the
/// F1) heart rate, and none of it is decoded — see `tlw64.dart`.
const BandEntry kNo1Band = BandEntry.notify(
  id: 'tlw64',
  label: 'TLW64 / NO1 F1',
  service: kNo1Service,
  characteristics: <String>[kNo1ControlChar, kNo1NotifyChar],
  // Neither device's client reads its clock back to confirm it, so there is
  // no measured origin to anchor a reading to.
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

/// The Wellue O2Ring, a pulse-oximeter ring with no authentication handshake
/// at all — the whole session is a plain command/reply pair.
///
/// NOT framed, for the same three reasons [kOura] is not: the length field is
/// a u16 that counts payload only, the trailing CRC is a single byte with no
/// header/payload split the way [BandProfile] models one, and there is no
/// inner opcode byte at a fixed offset the way a WHOOP record has one.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). See
/// `o2ring.dart`'s own header for what is and is not implemented — the file
/// commands that would drain a stored recording are deliberately absent,
/// because the only public documentation for them disagrees with itself on
/// where the reply fields land.
const BandEntry kO2Ring = BandEntry.notify(
  id: 'o2ring',
  label: 'Wellue O2Ring',
  service: kO2RingService,
  characteristics: <String>[kO2RingWriteChar, kO2RingNotifyChar],
  // No clock command exists in what this build speaks (INFO only), so there
  // is nothing to anchor against. Arrival is the honest, conservative answer
  // — same reasoning as `kOura`'s own doc comment.
  timeAnchor: TimeAnchor.arrival,
);

/// MyKronoz ZeTime. A framed command/reply protocol — preamble, command,
/// action, length, payload, end marker — but not a WHOOP-shaped one: four
/// characteristics under one service and no CRC, which is exactly what
/// [BandEntry.notify] is for (see the header note on why [BandEntry.framed]'s
/// [GattProfile]/[BandProfile] cannot express this).
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is empty
/// and `kAdapterSignals` below carries no entry with anything in it — this
/// band may pair, connect and bank raw bytes; it decodes a battery level as a
/// device fact and nothing else.
const BandEntry kZeTime = BandEntry.notify(
  id: 'zetime',
  label: 'MyKronoz ZeTime',
  service: kZeTimeService,
  characteristics: <String>[
    kZeTimeWriteChar,
    kZeTimeAckChar,
    kZeTimeReplyChar,
    kZeTimeNotifyChar,
  ],
  // No clock decoded here (see `zetime.dart`'s own doc on what this file
  // deliberately does not touch), so the conservative half of a two-clock
  // situation — same call Oura's entry makes for the same reason.
  timeAnchor: TimeAnchor.arrival,
);

/// A Howear-branded band (HK8 Ultra, HK8 Pro Max and the like), paired
/// through the WearFit / WearFit 2.0 / WearFit Pro companion app family.
///
/// NOT framed: the envelope has a length byte and an opcode but no CRC and no
/// inner-record layout the framed machinery's [innerOpcodeOffset] etc. could
/// describe — see `wearfit.dart` in `protocol` for the wire format itself.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and this id is absent from `kDerivableSources` — a paired band
/// captures its own battery report and archives everything else it sends,
/// and surfaces no health signal at all.
const BandEntry kWearFit = BandEntry.notify(
  id: 'wearfit',
  label: 'WearFit band',
  service: kWearFitScanService,
  characteristics: <String>[kWearFitWriteChar, kWearFitNotifyChar],
  // No clock of its own that this build reads back; every frame is stamped
  // on arrival, same as the generic HRS strap.
  timeAnchor: TimeAnchor.arrival,
);

/// RingConn (Gen 2, Gen 2 Air, Gen 3) — one service, a challenge-response
/// handshake keyed by the ring's own BLE MAC, and two independent history
/// channels the ring resumes on its own (this build persists no cursor for
/// either — see `ringconn.dart` and `ringconn_link.dart`).
///
/// A REAL, UNRESOLVED RISK: the ring is not reliably known to advertise
/// [kRingConnService] in its foreground scan advertisement — only its name
/// (`RingConn Gen2-XXXX` etc). `nameMatcher` is left null here rather than
/// guessed at: if the service prefix alone turns out not to find the ring on
/// a live scan, this is where a name fallback belongs (see
/// [BandEntry.framed]'s own use of one for WHOOP 4's own unreliable service
/// ad), not something to wire blind against a ring nobody here owns.
///
/// [kSystemIdUuid] is listed as required rather than left to a plain GATT
/// read against "whatever the peripheral happens to expose": the handshake's
/// MAC recovery has nothing to fall back to without it.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns a ring,
/// so not a byte of this path has met hardware (ASSUMPTIONS R6).
/// [TimeAnchor.arrival] is the conservative default for a band that decodes
/// nothing into a timestamped sample yet — see `RingConnAdapter.signals`.
///
/// It is `pick: null` in `kPairableSensors` even so: `RingConnAdapter.signals`
/// is `const {}`, so `HrsLink.deriveTier` (which looks up `declaredSignals`
/// for the pairing `adapter_id`) resolves this band's tier to null rather
/// than inheriting [kBleHrs]'s `'beatToBeat'` — same reasoning as Oura's own
/// pairing, same reason a wrong tier here is silent.
const BandEntry kRingConn = BandEntry.notify(
  id: 'ringconn',
  label: 'RingConn',
  service: kRingConnService,
  characteristics: <String>[
    kRingConnCommandChar,
    kRingConnNotifyChar,
    kSystemIdUuid,
  ],
  timeAnchor: TimeAnchor.arrival,
);

/// DT78 / DT92 / DT66 and the wider tail of WearFit-2.0-compatible OEM clones
/// that share this exact service — one Nordic UART instance, no envelope, no
/// checksum, no auth (`dt78.dart`'s own header has the worked byte examples).
///
/// The service/characteristic UUIDs are the generic Nordic UART reference
/// triple, reused by large numbers of unrelated gadgets across many
/// unaffiliated device families — so unlike gen4's `nameMatcher` there is no
/// reliable advertised name to key on across resellers. The scan matches on
/// service only; the picker surfaces a hit by its advertised name and lets
/// the user confirm.
///
/// [TimeAnchor.arrival]: nothing in either reference client reads this
/// watch's clock back, so there is no measured origin to anchor a reading to.
///
/// EXPERIMENTAL: nobody on this project owns one (ASSUMPTIONS R6). `signals`
/// is `const {}` and `kDerivableSources` never gets this id — heart rate,
/// SpO2, blood pressure, steps and sleep are all readable at fixed opcodes
/// and none of it is decoded.
const BandEntry kDt78 = BandEntry.notify(
  id: 'dt78',
  label: 'DT78 / DT92 / DT66',
  service: kDt78Service,
  characteristics: <String>[kDt78WriteChar, kDt78NotifyChar],
  timeAnchor: TimeAnchor.arrival,
);

/// A Lefun-protocol OEM ring or band — the shared reference design behind a
/// long list of storefront names, not one branded product. Plain, unencrypted
/// GATT: no key, no nonce, no challenge/response anywhere in the envelope.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). Only the
/// envelope and its checksum, plus the battery report, are decoded with any
/// confidence — steps, sleep and PPG all ride the same envelope under their
/// own report codes and have no decoder here, so `signals` is `const {}` and
/// nothing this device writes becomes a metric.
const BandEntry kLefun = BandEntry.notify(
  id: 'lefun',
  label: 'Smart ring/band (Lefun protocol)',
  service: kLefunService,
  characteristics: <String>[kLefunWriteChar, kLefunNotifyChar],
  // No clock in the envelope this file decodes. See [TimeAnchor].
  timeAnchor: TimeAnchor.arrival,
);

/// The HPlus reference profile — HPlus itself and every OEM re-skin sharing
/// its firmware (same service, same two characteristics, same command byte).
///
/// Plaintext vendor command channel: no bonding, no encryption, no key
/// material anywhere in the protocol. Unlike every other notify-only entry
/// above, this band does not answer at all until a short init sequence has
/// been written to it; see `hplus.dart` for what that sequence is and the one
/// thing about it nobody has confirmed.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). It pairs, connects,
/// and banks every reply raw; `kDerivableSources` stays empty until someone
/// has actually held one.
const BandEntry kHPlus = BandEntry.notify(
  id: 'hplus',
  label: 'HPlus HR band',
  service: kHPlusService,
  characteristics: <String>[kHPlusControlChar, kHPlusMeasureChar],
  // No clock in any channel this adapter reads; every frame is stamped on
  // arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// A Jyou/Y5-class band: fixed 10-byte write commands, tag-byte notify
/// frames, no auth and no envelope. One product family of three that share
/// this opcode/checksum scheme over different GATT service sets — this entry
/// is the base Y5 device ONLY; the BFH16 and Teclast H30 rebrands each layer
/// their own service UUIDs on top and are a separate, unbuilt PR.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). Every decoded
/// field — HR, steps, blood pressure, SpO2 — is a proprietary on-device
/// estimate with no accuracy spec behind it, so `kDerivableSources` stays
/// empty. See `jyou.dart`.
const BandEntry kJyou = BandEntry.notify(
  id: 'jyou',
  label: 'Jyou Band',
  service: kJyouService,
  characteristics: <String>[kJyouControlChar, kJyouMeasureChar],
  // No frame carries the band's own clock; every chunk is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// A PineTime running its open firmware. No auth, no write of any kind — two
/// independent notify characteristics on two different services: this
/// watch's own motion service, and the SIG heart-rate service [kBleHrs] also
/// answers on.
///
/// [kPineTimeMotionService] is the scan-filter service (a vendor uuid unique
/// to this entry — the heart-rate service is [kBleHrs]'s own scan filter, and
/// two registry rows filtering on the same service is the collision
/// `HrsLink.scanForAny` treats as a registry bug, not a runtime ambiguity).
/// Both notify characteristics are still required: `GattBandLink` matches a
/// characteristic across every service the peripheral discovers, not only
/// the scan-filter one.
///
/// EXPERIMENTAL, and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). `signals` is
/// `const {}` and `kDerivableSources` never gets this id — step count and
/// heart rate are both readable and neither is decoded.
const BandEntry kPineTime = BandEntry.notify(
  id: 'pinetime',
  label: 'PineTime',
  service: kPineTimeMotionService,
  characteristics: <String>[kPineTimeStepCountChar, kHeartRateMeasurementUuid],
  timeAnchor: TimeAnchor.arrival,
);

/// Fossil/Skagen's original "hybrid" smartwatch line — models like `HW.0.0`,
/// `HL.0.0`, `DN.1.0`. NOT the encrypted Hybrid HR / Gen 6 line, a different
/// sibling protocol that happens to advertise the same service UUID.
///
/// Plain unencrypted GATT, no crypto handshake, no pairing key: standard
/// platform BLE bonding is the whole of what "pairing" means here, same as
/// [kBleHrs]. A live scan match on the service UUID alone cannot tell this
/// watch apart from its encrypted sibling before connecting, so the adapter
/// self-confirms with a harmless battery-level probe before banking anything
/// — see `qhybrid.dart`.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so
/// not a byte of this path has met hardware (ASSUMPTIONS R6). It pairs,
/// connects, confirms itself, and banks every notification raw;
/// `kDerivableSources` stays empty until someone has actually held one.
const BandEntry kQHybrid = BandEntry.notify(
  id: 'qhybrid',
  label: 'Fossil/Skagen Hybrid Smartwatch',
  service: kQHybridService,
  characteristics: <String>[
    kQHybridControlChar,
    kQHybridFileChar1,
    kQHybridFileChar2,
    kQHybridAuxChar,
    kQHybridButtonChar,
    kQHybridUploadAckChar,
  ],
  // No clock in the wire format at all; every frame is stamped on arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// This ring family advertises a stable name — `R0\d_*` (R02/R03/R06/R09) or
/// `COLMI R10_*` — so matching on it is a fallback for whatever an
/// advertising payload's service list drops. Whether a real ring's 31-byte
/// advertising payload also carries `6e40fff0…` is unconfirmed without
/// hardware, so this is belt-and-suspenders alongside the service filter, the
/// same role `_nameContainsWhoop` plays for WHOOP 4. Takes the
/// already-lowercased name.
bool _looksLikeColmi(String lowercaseName) =>
    RegExp(r'^(?:r02_|r03_|r06_|r09_)').hasMatch(lowercaseName) ||
    lowercaseName.startsWith('colmi r10_');

/// Colmi smart ring family (advertised as `R02_*`, `R03_*`, `R06_*`, `R09_*`,
/// `COLMI R10_*`). A fixed 16-byte checksummed command/notify protocol with no
/// encryption and no handshake of any kind — connect, discover, subscribe,
/// write.
///
/// [TimeAnchor.arrival]: there is no command in this protocol that reads the
/// ring's clock back, so nothing here is a measured origin.
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns a Colmi
/// ring, so not a byte of this path has met hardware (ASSUMPTIONS R6). It
/// pairs, connects and banks raw bytes; `kDerivableSources` stays empty.
const BandEntry kColmi = BandEntry.notify(
  id: 'colmi',
  label: 'Colmi ring',
  service: kColmiService,
  characteristics: <String>[kColmiWriteChar, kColmiNotifyChar],
  timeAnchor: TimeAnchor.arrival,
  nameMatcher: _looksLikeColmi,
);

/// A Casio G-Shock / current-generation Casio smartwatch speaking the 2C/2D
/// "all-features" GATT scheme (GBX100, GW-B5600, GMW-B5000, ECB-S100/Edifice
/// and later models sharing the profile).
///
/// Plain unencrypted GATT, tagged request/response by a one-byte feature id —
/// no envelope, no CRC, no counter, no crypto handshake anywhere in the
/// connect flow. Standard platform BLE bonding is the whole of what "pairing"
/// means here, same as [kBleHrs].
///
/// EXPERIMENTAL and it stays that way: nobody on this project owns one, so not
/// a byte of this path has met hardware (ASSUMPTIONS R6). It pairs, connects,
/// and banks every feature reply raw; `kDerivableSources` stays empty until
/// someone has actually held one.
const BandEntry kCasio = BandEntry.notify(
  id: 'casio',
  label: 'Casio G-Shock',
  service: kCasioService,
  characteristics: <String>[kCasioReadRequestChar, kCasioAllFeaturesChar],
  // No clock in the wire format this adapter reads; every frame is stamped on
  // arrival.
  timeAnchor: TimeAnchor.arrival,
);

/// Every band this build can see. Order is match order during discovery.
const List<BandEntry> kBandRegistry = <BandEntry>[
  kWhoopGen4,
  kWhoopGen5,
  kBleHrs,
  kOura,
  kCoros,
  kUltrahuman,
  kWithingsSteelHr,
  kMiBand234,
  kPebble,
  kMakibesHr3,
  kId115,
  kSmaq2oss,
  kXWatch,
  kNo1Band,
  kDafit,
  kO2Ring,
  kZeTime,
  kWearFit,
  kRingConn,
  kDt78,
  kLefun,
  kHPlus,
  kPineTime,
  kQHybrid,
  kColmi,
  kCasio,
  kJyou,
  kWatch9,
  kBangleJs,
  kGarmin,
  kRing11m,
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
/// `ble_hrs.dart`'s `BleHrsAdapter.signals`, `oura.dart`'s
/// `OuraAdapter.signals`, `ultrahuman.dart`'s `UltrahumanAdapter.signals`,
/// `o2ring.dart`'s `O2RingAdapter.signals`,
/// `zetime.dart`'s `ZeTimeAdapter.signals`, `ringconn.dart`'s
/// `RingConnAdapter.signals`, `dt78.dart`'s `Dt78Adapter.signals` and
/// `pinetime.dart`'s `PineTimeAdapter.signals`, since importing those back
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
  'ring11m': <InputSignal, Duration>{},
  'coros': {
    InputSignal.hrSparse: Duration(seconds: 1),
    InputSignal.rrIntervals: Duration(seconds: 1),
  },
  'ultrahuman': <InputSignal, Duration>{},
  'withings_steel_hr': <InputSignal, Duration>{},
  'miband234': <InputSignal, Duration>{},
  'pebble': <InputSignal, Duration>{},
  'makibeshr3': <InputSignal, Duration>{},
  'id115': <InputSignal, Duration>{},
  'smaq2oss': <InputSignal, Duration>{},
  'xwatch': <InputSignal, Duration>{},
  'tlw64': <InputSignal, Duration>{},
  'dafit': <InputSignal, Duration>{},
  'o2ring': <InputSignal, Duration>{},
  'zetime': <InputSignal, Duration>{},
  'wearfit': <InputSignal, Duration>{},
  'ringconn': <InputSignal, Duration>{},
  'dt78': <InputSignal, Duration>{},
  'lefun': <InputSignal, Duration>{},
  'hplus': <InputSignal, Duration>{},
  'pinetime': <InputSignal, Duration>{},
  'qhybrid': <InputSignal, Duration>{},
  'colmi': <InputSignal, Duration>{},
  'casio': <InputSignal, Duration>{},
  'jyou': <InputSignal, Duration>{},
  'watch9': <InputSignal, Duration>{},
  'banglejs': <InputSignal, Duration>{},
  'garmin': <InputSignal, Duration>{},
};

/// The signals one adapter declares, or empty for an id this build has no
/// entry for — mirrors `bandLabelFor`'s null-is-honest shape
/// (`devices.dart:122-127`): an unknown device is never quietly filed under
/// the nearest one we know.
Set<InputSignal> declaredSignals(String? adapterId) =>
    kAdapterSignals[adapterId]?.keys.toSet() ?? const {};
