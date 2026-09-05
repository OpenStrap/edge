// The SESSION seam: what it takes to DRIVE a band, not merely describe one.
//
// `_registry.dart` gave three bands a shared identity — id, label, service
// UUID, required characteristics. What it could not give them was shared
// PLUMBING: SET_CLOCK, INIT, the drain, `RecordGate`, the batch ACK and the
// liveness fuse were all hardcoded in `ble_engine._doConnect`, so a band that
// did not speak that exact sequence still needed ~200 lines of its own. This
// file is the interface that closes that gap (MULTIBAND_PLAN §3.1).
//
// FIVE MEMBERS, and the shape of each one is a decision with a reason:
//
//  * No separate `handshake()`. `run()` is `async*`, so authentication is
//    simply the statements before the first `yield`. A second lifecycle method
//    is a second place to get the ordering wrong.
//  * No `tier` field on an event. Tier is a property of a DERIVATION and
//    `Metric.tier` already carries it; an adapter claiming a tier would be
//    claiming something about analytics it cannot know.
//  * No capability booleans, EVER. See `signals.dart`.
//  * Offload is ONE callback. Four models reduce to "the host has committed
//    durably; now do the band-specific thing that lets the band forget".
//  * `ephemeral` exists because a live frame must never reach `raw_records`.
//
// DELIBERATELY EXCLUDED — named here so nobody adds them speculatively:
// typed resumption cursors; progress/ETA models; gap detection and partial
// re-request (gen4-specific policy, which lives INSIDE the gen4 adapter, not
// at the seam); OTA; a cross-band command abstraction; per-sample cross-device
// fusion; and any waveform channel.
//
// WHAT A CONTRIBUTOR NEVER TOUCHES, and cannot reach from here: the
// `flutter_blue_plus` API, bonding, CoreBluetooth restoration, iOS
// AccessorySetupKit provisioning, Android permission blockers, the
// process-wide band lock, connection priority, MTU negotiation, `sqflite`, any
// schema migration, `kAlgoVersion`, `Substrate`, any analytics function, the
// derivation engine or scheduler, and any widget, card, screen or golden. If a
// change to this file would expose one of those, the change is wrong.

import 'dart:async';
import 'dart:typed_data';

import '../../data/observation.dart' show Observation;
import '_registry.dart';
import 'signals.dart';

/// The radio, as an adapter is allowed to see it.
///
/// This is the smallest surface that serves BOTH a framed, authenticated,
/// offloading band (three notify characteristics, one write characteristic, a
/// flash to trim) and a one-characteristic notify sensor with no clock and
/// nothing stored. Everything a band-agnostic host must own — discovery,
/// connect, bond, MTU, priority, restoration, the band lock — happens ABOVE
/// this and is not reachable through it.
///
/// LIFETIME. A link is valid for exactly one connection. When the link drops,
/// the host cancels the [BandAdapter.run] subscription; the `async*` body's
/// `finally` is where an adapter cancels its own timers. There is no `close()`
/// here for the adapter to call — an adapter does not get to hang up.
abstract class BandLink {
  /// Subscribe to a characteristic and receive its notifications, each paired
  /// with the wall-clock second it ARRIVED at this phone.
  ///
  /// The arrival second is on the packet rather than read from a clock inside
  /// the adapter for one reason: it is the only honest anchor a source with no
  /// clock of its own has, and putting it here means it can be replayed
  /// deterministically from a fixture ([ReplayBandLink]) instead of depending
  /// on `DateTime.now()` inside adapter code. A band that stamps its own
  /// records IGNORES it and uses the epoch it decoded.
  ///
  /// Yields nothing at all for a characteristic this peripheral does not
  /// expose — an adapter that requires one should have declared it in its
  /// [BandEntry.requiredCharacteristics], where the connect aborts loudly.
  Stream<(int atSec, List<int> value)> notify(String characteristicUuid);

  /// Write with response, which is also what triggers bonding. Returns whether
  /// the GATT write was confirmed; false covers a missing characteristic, a
  /// dead link, a timeout and a refused opcode alike.
  ///
  /// The dangerous-opcode block lives in the IMPLEMENTATION of this method,
  /// not in adapter code, so no adapter can reach FORCE_TRIM, REBOOT or
  /// POWER_CYCLE by any path.
  Future<bool> write(String characteristicUuid, List<int> value);

  /// One line into the engine log the user can already see and export.
  void log(String message);
}

/// One sample, in the vocabulary of the substrate rather than of any band.
///
/// This is NOT a third name for `Substrate` and it is not a copy of protocol's
/// `Sample`. It is the adapter-facing shape of ONE `decoded_onehz` row plus
/// the `decoded_rr` beats belonging to that row, which is the real
/// contributor-facing contract (MULTIBAND_PLAN §3.6): it already encodes
/// absence as null, and it is the only place a band's bytes become neutral.
///
/// ABSENT IS NULL, NEVER ZERO. A notification that carried no heart rate
/// leaves [hr] null; it does not report 0 bpm, which the substrate reads as
/// the off-skin sentinel. A zero anywhere here is a measurement claim.
///
/// The field list is the `decoded_onehz` COLUMN SET, and it is deliberately
/// only as wide as something currently emits. Adding a nullable field later is
/// free — every constructor argument is named and optional — so a band that
/// brings accelerometer, optical or thermistor channels widens this class in
/// its own wave rather than having them declared here in advance.
class NeutralSample {
  /// What [tsEpoch] actually IS. Load-bearing, not cosmetic: RMSSD, pNN50 and
  /// SDNN stay correct on [TimeAnchor.arrival] because they are computed from
  /// the durations, while Lomb-Scargle, `cvhr_per_hour`, `spanSec` and
  /// `night_hrv_shape` read the time AXIS and must REFUSE on it.
  final TimeAnchor anchor;

  /// Whole seconds since the Unix epoch. Seconds, not milliseconds, because
  /// `decoded_onehz` is keyed at one row per second and `ts_ms` is exactly
  /// `rec_ts * 1000` (ASSUMPTIONS A2).
  final int tsEpoch;

  /// Beats per minute, or null when this sample carries no heart rate. Never 0
  /// — the substrate treats 0 as the off-skin sentinel.
  final int? hr;

  /// Beat-to-beat DURATIONS in milliseconds, in the order the band sent them.
  /// Empty means "not reported", never "no beats".
  final List<int> rrMs;

  /// Skin temperature in ABSOLUTE degrees Celsius, or null.
  ///
  /// It lands in `decoded_onehz.skin_temp_c` and NEVER in `skin_temp_raw`,
  /// which is a relative ADC count on the bands that have one. They are
  /// different quantities: a raw count is only meaningful against a per-family
  /// calibration, a Celsius reading is meaningful on its own, and putting one
  /// in the other's column would give every consumer of that column a number in
  /// the wrong units with no way to tell.
  ///
  /// There is deliberately no [InputSignal] for it — I8 names the raw-ADC input
  /// specifically — so a band supplying this declares no signal for it and no
  /// metric is claimed on its behalf.
  final double? skinTempC;

  /// Anything the band emitted that we do not have a column for, under the
  /// band's OWN name for it (owner rulings R1-R3: capture everything, decide
  /// what to do with it later). Never an input to a derivation, never in a
  /// baseline, and never sharing a key with a number we compute ourselves.
  final Map<String, Object?> vendor;

  const NeutralSample({
    required this.anchor,
    required this.tsEpoch,
    this.hr,
    this.rrMs = const <int>[],
    this.skinTempC,
    this.vendor = const <String, Object?>{},
  });
}

/// Everything an adapter can tell the host. Sealed: adding a fourth kind is a
/// deliberate decision that breaks every host switch, which is the point.
sealed class BandEvent {
  const BandEvent();
}

/// Decoded samples, and optionally the bytes they came from.
class SampleBatch extends BandEvent {
  final List<NeutralSample> samples;

  /// The verbatim frames these samples were decoded from, for `raw_archive` —
  /// the never-pruned store of bytes we could not decode or do not yet
  /// understand. Null when the band has no envelope worth keeping (a `0x2A37`
  /// notification IS the sample; archiving it stores the same numbers twice).
  final List<Uint8List>? raw;

  /// TRUE = this batch is a live stream, and NOTHING here may be persisted.
  ///
  /// Not a nicety. A band's 100 Hz live frames arriving in `raw_records` is a
  /// database-size failure that has already happened once, and the second
  /// implementation that justifies the field is a strap that emits a live
  /// stream AND a recorded file covering the same wall-clock span — where
  /// "which of these two identical-looking batches is durable" cannot be
  /// answered by the host from the bytes.
  final bool ephemeral;

  const SampleBatch(this.samples, {this.raw, this.ephemeral = false});
}

/// The band is holding data it will only forget once told to.
///
/// The host commits durably FIRST and calls [confirm] second. That ordering is
/// the safe-trim invariant and it is not negotiable: confirming before the
/// commit lets a band delete records that exist nowhere. It stays host-side
/// precisely so no adapter can get it backwards.
///
/// THE VERDICT IS SPLIT, AND NEITHER HALF CAN OVERRIDE THE OTHER. Emitting a
/// checkpoint at all is the ADAPTER's half — it is what knows a burst was
/// abandoned mid-transfer, or came up short against a declared packet count,
/// and it withholds the event rather than passing a veto flag. Calling
/// [confirm] is the HOST's half — it is what knows whether the commit landed
/// and whether anything durable was in it. An adapter that never emits, and a
/// host that never calls, both mean "the band keeps its flash", which is
/// always the safe outcome.
///
/// | model                    | what `confirm()` does                    |
/// |--------------------------|------------------------------------------|
/// | trim-on-ack (WHOOP)      | writes the batch ACK; the band trims     |
/// | fetch-by-range           | advances the adapter's own cursor        |
/// | file transfer            | deletes the transferred file             |
/// | live-only (chest strap)  | never emitted; the host flushes on its own |
class OffloadCheckpoint extends BandEvent {
  /// Called by the host AFTER its durable commit, and only then.
  ///
  /// Returns whether the band actually accepted it. NOT `Future<void>`: on a
  /// trim-on-ack band a silently-swallowed ACK failure means the band never
  /// trims and re-floods the same chunk forever, and the shipped remedy is for
  /// the HOST to bounce the link — which it cannot decide to do if the result
  /// is thrown away. Retry policy is the adapter's; bouncing is the host's.
  final Future<bool> Function() confirm;

  /// Roughly how much the band still holds, when it says. Advisory only —
  /// there is deliberately no progress or ETA model at this seam.
  final int? remaining;

  const OffloadCheckpoint(this.confirm, {this.remaining});
}

/// A fact about the band that is not a sample: battery, firmware, serial, an
/// alarm confirmation, a strap event.
///
/// Open key/value on purpose (R1: an unrecognised field is stored under its
/// own name, not dropped). It is NOT a command channel — the host reacts to
/// notes, an adapter cannot make it act.
class BandNote extends BandEvent {
  final String key;
  final Object? value;
  const BandNote(this.key, [this.value]);
}

/// Numbers the band computed ITSELF — its own RMSSD, its own sleep score.
/// Declared as `InputSignal.vendorScalars` and stored in `observation`,
/// attributed to the vendor, never an input to one of our derivations and
/// never in a baseline.
class VendorScalars extends BandEvent {
  const VendorScalars(this.rows);

  /// `data/observation.dart`'s type. `key` for a comparable quantity,
  /// `vendorKey` for a proprietary composite — the split is the rule that
  /// stops "readiness" meaning three algorithms.
  final List<Observation> rows;
}

/// One band, driven.
///
/// Five members. Discovery is NOT restated here — it is [entry], the registry
/// row that already carries the service UUID and the required characteristic
/// set, and which the iOS AccessorySetupKit plist is generated from. A second
/// declaration of a service UUID is a second thing to get out of sync.
abstract class BandAdapter {
  const BandAdapter();

  /// This band's registry row: id, label, service UUID, required
  /// characteristics, and (for a framed band) its envelope profile.
  BandEntry get entry;

  /// Stamped into `device_family` and `decoded_*.source`, so it is a storage
  /// key: never rename a shipped one.
  String get id => entry.id;

  String get label => entry.label;

  /// What this band SUPPLIES, at what cadence. Not decorative: it is the input
  /// to the cadence refusal guard, and a mandatory test asserts that every
  /// signal declared here actually appears in an emitted sample at roughly
  /// this rate.
  ///
  /// A declared-but-absent signal is WORSE than a missing one — it turns a
  /// card that should have deleted itself into one that is permanently empty.
  Map<InputSignal, Duration> get signals;

  /// Handshake, session and decode, as one stream.
  ///
  /// Ends when the band's data ends or the host cancels. Timers, reassemblers
  /// and any per-session state belong in the body of this method (a `finally`
  /// is where they die), not on the adapter instance — an adapter is const and
  /// a session is not.
  Stream<BandEvent> run(BandLink link);
}

/// A [BandLink] fed from recorded bytes instead of a radio.
///
/// `flutter_blue_plus` has no simulator path, so without this there is no way
/// to exercise an adapter at all. It is the link a contributor's
/// `test/adapters/<id>_test.dart` replays a captured fixture through, and it
/// is also what drives `HrsLink.ingestForTest` — two callers, which is why it
/// is a shared type here rather than a fake copied into each test.
class ReplayBandLink implements BandLink {
  final Map<String, StreamController<(int, List<int>)>> _channels = {};

  /// Every write an adapter attempted, in order. Assert against this rather
  /// than mocking: a wrong ACK payload is a band that never trims its flash.
  final List<(String uuid, List<int> value)> writes = [];

  final List<String> logs = [];

  /// What [write] returns. Set false to exercise an adapter's failure path.
  bool writeSucceeds = true;

  /// Single-subscription on purpose: it BUFFERS, so a fixture may be fed
  /// before the adapter has got around to subscribing and nothing is dropped.
  /// A second `notify()` of the same characteristic throws, which is correct —
  /// an adapter subscribing twice to one characteristic is a bug.
  StreamController<(int, List<int>)> _channel(String uuid) =>
      _channels.putIfAbsent(uuid, StreamController<(int, List<int>)>.new);

  @override
  Stream<(int, List<int>)> notify(String characteristicUuid) =>
      _channel(characteristicUuid).stream;

  @override
  Future<bool> write(String characteristicUuid, List<int> value) async {
    writes.add((characteristicUuid, value));
    return writeSucceeds;
  }

  @override
  void log(String message) => logs.add(message);

  /// Deliver one notification, stamped as having arrived at [atSec].
  void feed(String characteristicUuid, List<int> value, {required int atSec}) {
    _channel(characteristicUuid).add((atSec, value));
  }

  /// End every channel, which ends `run()`. Await the run subscription's
  /// `done` after this rather than guessing at a delay.
  Future<void> close() async {
    for (final c in _channels.values) {
      await c.close();
    }
    _channels.clear();
  }

  /// End one channel while the others stay open — for an adapter test that
  /// needs to reproduce "one channel ends while another still has a frame
  /// in flight" rather than a full teardown.
  Future<void> closeChannel(String uuid) async {
    final c = _channels.remove(uuid);
    if (c != null) await c.close();
  }
}
