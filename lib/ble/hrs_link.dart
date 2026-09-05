// The HOST for a standard Bluetooth heart-rate sensor: connect it, drive
// [BleHrsAdapter] over the link, and write what comes back into the substrate.
//
// WHAT MOVED, AND WHY IT MATTERS. The decode and the session used to be in
// this file. They are now `adapters/ble_hrs.dart` — a 40-line
// `Stream<BandEvent> run(BandLink)` — and everything left here is host work a
// contributor must never see: `flutter_blue_plus`, the paired-device row,
// `sqflite`, the per-second write buffer, `device_id` discipline. The seam
// between the two halves is `adapters/adapter.dart`, and this is its first
// caller.
//
// WHAT IT IS NOT.
//  * NOT a background source. Armed by a workout, disarmed when the workout
//    ends — the same rule GPS follows, for the same reason: a second GATT link
//    held open all day is a battery cost and a scan/connect fight with the
//    band's own link.
//  * NOT better than the band overnight. A chest strap is better at exercise
//    HR and beat timing; that is the whole of the claim.
//  * NOT baseline input, and not yet input to anything. Its rows land in
//    `decoded_onehz` / `decoded_rr` — the real substrate, not a side table —
//    stamped `source = 'ble_hrs'`, and every derive/export read filters
//    `source IS NULL`. Resting HR from a chest strap and from wrist PPG differ
//    systematically, and merging them quietly is how a step change lands in
//    every long-horizon number with no visible cause.
//  * REACHABLE NOW, and it was not. [scanFor] finds a sensor and
//    [pairNotifySensor] writes the `device` row [HrsLink.arm] reads, so
//    arming stops being a no-op the moment a user picks one.
//    `lib/ui2/profile/pair_sensor.dart` is the screen that drives both.
//  * NOT hardware-verified. Nobody on this project owns a strap. Everything
//    below is verified by the SIG spec, the fixtures in
//    `test/hrs_link_test.dart` and the compiler. It ships EXPERIMENTAL
//    (ASSUMPTIONS R6).
//
// BEAT TIME. A 0x2A37 strap reports beat-to-beat DURATIONS and carries no
// clock. The durations are exact and land in `decoded_rr.rr_ms`; the only time
// we can attach is the arrival of the notification, which BLE delivery jitter
// and stack batching move by tens of milliseconds. That anchor goes in
// `rr_ts_ms` (the whole-second column, which is what it is) and `beat_ts_ms` —
// the column that means "where the beat actually WAS" — stays NULL, because we
// do not know. `TimeAnchor.arrival` on the registry entry is the machine-
// readable form of that sentence: RMSSD and pNN50 are correct on it,
// Lomb-Scargle / `cvhr_per_hour` / `spanSec` must refuse on it.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'accessory_setup.dart';
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/ble_hrs.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost, HrsReading;
import 'ble_state.dart'
    show
        BleBlocker,
        BleUnavailableException,
        classifyBleBlocker,
        withScanLock,
        acquireSecondaryLinkSlot,
        releaseSecondaryLinkSlot;
import 'banglejs_link.dart' show BangleJsLink;
import 'colmi_link.dart' show ColmiLink;
import 'coros_link.dart' show CorosLink;
import 'dafit_link.dart' show DafitLink;
import 'garmin_link.dart' show GarminLink;
import 'hplus_link.dart' show HPlusLink;
import 'lefun_link.dart' show LefunLink;
import 'miband_link.dart' show MiBand234Link;
import 'o2ring_link.dart' show O2RingLink;
import 'oura_link.dart' show OuraLink;
import 'pebble_link.dart' show PebbleLink;
import 'polar_pmd_link.dart' show PolarPmdLink;
import 'qhybrid_link.dart' show QHybridLink;
import 'ring11m_link.dart' show Ring11mLink;
import 'ringconn_link.dart' show RingConnLink;
import 'ultrahuman_link.dart' show UltrahumanLink;
import 'watch9_link.dart' show Watch9Link;
import 'wearfit_link.dart' show WearFitLink;
import 'withings_steel_hr_link.dart' show WithingsSteelHrLink;

export 'adapters/host.dart' show HrsReading;

/// One peripheral a pairing scan heard, in the shape a picker needs.
///
/// [label] is the advertised name AFTER `cleanDeviceLabel`, and it stays
/// nullable: plenty of sensors advertise no name at all, and a made-up
/// "Unknown device" would be a value where there is none. The screen shows the
/// band's own label instead.
typedef BandCandidate = ({
  BluetoothDevice device,
  String? label,
  int rssi,
  // Which registry entry's service this result matched. Only meaningful when
  // a scan covers more than one entry at once (`scanForAny`); a single-entry
  // scan (`scanFor`) always stamps its own id, so existing callers reading
  // `.label`/`.device`/`.rssi` are unaffected by this field's addition.
  String entryId,
});

/// The live link to a paired heart-rate sensor. One instance; a second
/// concurrent sensor is not a thing anyone asked for.
class HrsLink {
  HrsLink._();
  static final HrsLink instance = HrsLink._();

  BluetoothDevice? _device;

  /// Kept only so [disarm] can [GattBandLink.close] it. Closing is what stops a
  /// write the adapter queued before the teardown from landing on a LATER
  /// connection to the same strap — see the field's own doc.
  GattBandLink? _link;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  /// The session driving [kBleHrsAdapter] over [_link] — see `adapters/host.dart`.
  /// Null when nothing is armed. Carries the paired sensor's `device_id`
  /// (never [LocalDb.kPrimaryDeviceId] — `''` is the primary band,
  /// permanently, ASSUMPTIONS A1).
  BandHost? _host;

  bool _armed = false;

  /// True while this instance holds a secondary-link slot (acquired before
  /// connect in [_arm], released exactly once from [disarm]). Guards against
  /// a double-release, which would hand a slot to two connects at once.
  bool _holdsSecondaryLinkSlot = false;

  /// What the sensor is saying right now, or null when none is armed.
  ///
  /// A [ValueListenable] rather than a stream because there is one current
  /// reading and every consumer wants the latest one — a late listener on a
  /// broadcast stream would render nothing until the next beat. Mirrors
  /// [BandHost.reading] rather than exposing it directly, so this listenable's
  /// IDENTITY stays stable across an arm/disarm cycle — a widget holding a
  /// reference to it does not need to notice a new host underneath.
  ValueListenable<HrsReading?> get reading => _reading;
  final ValueNotifier<HrsReading?> _reading = ValueNotifier(null);

  /// The armed sensor's `device_id`, or null when nothing is armed.
  ///
  /// What a consumer of [reading] needs to attribute a beat: a reading with no
  /// device behind it cannot enter a per-device trace (`AppState`'s), and the
  /// minted id is the only name this sensor has. NULL BEFORE [reading] CLEARS
  /// — [disarm] drops the host first — so a consumer that must name the device
  /// it is ending has to remember it.
  String? get deviceId => _host?.deviceId;

  /// The `device` row for the paired heart-rate sensor, or null.
  ///
  /// The `device` table (schema 49) IS the pairing store now — this is what
  /// replaced `PairedHrSensor`'s two SharedPreferences scalars, which could
  /// hold one sensor, could not be joined to the rows it wrote, and had no
  /// writer anyway. A pairing screen creates the row with
  /// `LocalDb.upsertDevice(id: mintedId, adapterId: 'ble_hrs', remoteId:
  /// bleId, label: advertisedName, tier: 'beatToBeat')`.
  ///
  /// `id` must be MINTED at pairing (e.g. `hrs-0a1b2c3d`), not the BLE remote
  /// id: a remote id is a per-app CBPeripheral UUID on iOS and a rotating RPA
  /// on Android, and letting one become the storage key fragments one strap
  /// into N identities. `remote_id` is the column that may change under the
  /// same row, and that is what this reads to connect.
  static Future<Map<String, Object?>?> pairedSensorRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kBleHrsAdapter.id) return r;
    }
    return null;
  }

  // ── pairing: scan ─────────────────────────────────────────────────────────

  /// How long a pairing scan runs. Longer than the engine's 12 s because this
  /// scan does NOT stop at the first hit — the whole window is the list the
  /// user chooses from, and a strap that has just been put on can take several
  /// seconds to start advertising.
  static const Duration _scanWindow = Duration(seconds: 15);

  /// Same bound, and for the same reason, as `BleEngine._blockerProbe`:
  /// `unknown` is CoreBluetooth's pre-init value, never a verdict.
  static const Duration _blockerProbe = Duration(seconds: 2);

  static const Duration _connectTimeout = Duration(seconds: 12);

  /// WHOSE scan is running right now — the `owner` token its caller passed —
  /// or null between them, for THIS file's scans and nothing else.
  ///
  /// The pairing screen has to be able to end its own scan early: the lock is
  /// held for the whole 15 s window and a dismissed screen should not make the
  /// next caller wait it out. What it must NOT do is call a bare
  /// `FlutterBluePlus.stopScan()`: the radio has one scanner, every holder
  /// awaits `isScanning == false`, and a stop issued by anyone satisfies
  /// everyone's await.
  ///
  /// A BOOL WAS NOT ENOUGH, and it is what this replaced. "A scan of ours is
  /// running" is not "MY scan is running" — with two pairing surfaces alive at
  /// once (the picker pushes `PairSensorScreen` while its own 15 s scan is
  /// still going, which is one tap) the queued screen's `dispose` read the
  /// RUNNING screen's flag and ended its scan, which then reports "found
  /// nothing" with no error anywhere. Exactly the bug the paragraph above was
  /// written to prevent, arrived at from the other side.
  static Object? _scanOwner;

  /// How long to wait for a stop to actually land before giving up on it. A
  /// stop that will not finish must not be able to hang a pairing tap.
  static const Duration _stopScanTimeout = Duration(seconds: 3);

  /// End [owner]'s scan early if it is the one actually running. No-op
  /// otherwise — when someone else holds the radio, and when [owner]'s own
  /// scan is still queued behind the lock.
  ///
  /// AWAIT THIS BEFORE CONNECTING. The returned future completes only once the
  /// radio has really stopped scanning: `flutter_blue_plus`'s own `stopScan`
  /// flips `isScanning` false and awaits the platform call, and it takes the
  /// same "scan" mutex `startScan` does, so awaiting it also covers a stop
  /// issued in the sliver before a start has engaged. Fire-and-forget — which
  /// this used to be — begins the connect with the scan still tearing down,
  /// and a connect racing a live scan is the classic Android GATT-133.
  /// `dispose` has nothing to await with and does not need to: nothing follows
  /// it onto the radio.
  ///
  /// ponytail: a queued scan is still not cancellable, so a dismissed screen
  /// can hold the lock for its full window doing nothing. That costs a wait,
  /// never a wrong answer, which is the direction to fail in. Give
  /// `withScanLock` a cancellation token only if a real flow needs the lock
  /// back sooner.
  static Future<void> stopScanIfRunning(Object owner) async {
    if (!identical(_scanOwner, owner)) return;
    try {
      await FlutterBluePlus.stopScan().timeout(_stopScanTimeout);
    } catch (e) {
      // A stop that throws or will not land is not worth failing a pair over —
      // the connect that follows is the thing the user asked for, and the scan
      // window closes on its own timeout regardless.
      debugPrint('[hrs] stopScan did not land: $e');
    }
  }

  /// Scan for peripherals advertising [entry]'s service and report them as
  /// they are heard.
  ///
  /// NOT `BleEngine.scan`, and not a copy of it either. That one filters on
  /// every FRAMED band's service and stops dead on the first match, because it
  /// answers "where is MY band" — one answer, no choice. This answers a
  /// different question: "what is in the room", for a class of device the user
  /// has to pick out of a list of several. So it filters on ONE entry's
  /// service, runs the whole window, and reports every distinct peripheral.
  ///
  /// [kFramedBands] is deliberately not consulted: a notify-class entry is
  /// excluded from it on purpose (see the comment on `kFramedBands`), and a
  /// framed band matched here would be handed to a pairing path that has no
  /// handshake. Hence the assert.
  ///
  /// Generic over [entry] rather than pinned to [kBleHrs]: the next
  /// notify-class band needs exactly this scan and a different pairing step,
  /// and a second copy of this function is how the two drift apart.
  ///
  /// [onResults] is called with the whole ranked list each time it changes —
  /// strongest signal first, which is very nearly "the one on your chest".
  /// Throws [BleUnavailableException] when the phone's own stack is the
  /// problem; see [scanHeldBackReason] for the iOS case that is not an error.
  ///
  /// [owner] is whatever the caller passes to [stopScanIfRunning] to end this
  /// scan early — a screen's `State`, in practice. It is compared by identity
  /// and never stored beyond the scan.
  static Future<void> scanFor(
    BandEntry entry, {
    required Object owner,
    required void Function(List<BandCandidate>) onResults,
    Duration timeout = _scanWindow,
  }) {
    assert(!entry.isFramed,
        '${entry.id} is a framed band — pair it through BleEngine.scan.');
    // Process-wide, because the radio has ONE scanner and the band's own scan
    // shares it. Without this, whichever scan called `stopScan` first ended
    // the other one having seen nothing, with no error to say why.
    return withScanLock(() => _scanForEntries([entry], owner, onResults, timeout));
  }

  /// Like [scanFor], swept across every entry in [entries] at once — the
  /// unified device picker's "nearby" section, which does not make the user
  /// pick a category before it can even look. Each result is tagged with
  /// which entry's service it matched (`BandCandidate.entryId`), so the
  /// picker can still route a tap to the right pairing step.
  ///
  /// A THIRD copy of the scan loop, not a second: [scanFor] is kept as its
  /// own entry point (rather than a 1-element call to this one hidden behind
  /// the name) because its assert message and doc are about ONE band, and
  /// callers pairing a specific already-chosen entry should keep saying so.
  static Future<void> scanForAny(
    List<BandEntry> entries, {
    required Object owner,
    required void Function(List<BandCandidate>) onResults,
    Duration timeout = _scanWindow,
  }) {
    assert(entries.isNotEmpty, 'scanForAny needs at least one entry.');
    assert(entries.every((e) => !e.isFramed),
        'a framed band has no notify-class scan to join.');
    return withScanLock(() => _scanForEntries(entries, owner, onResults, timeout));
  }

  static Future<void> _scanForEntries(
    List<BandEntry> entries,
    Object owner,
    void Function(List<BandCandidate>) onResults,
    Duration timeout,
  ) async {
    // A phone-level blocker is NOT "nothing answered" — the same lesson
    // `BleEngine._scanLocked` learned. Returning an empty list for a revoked
    // Bluetooth permission tells the user to move closer to a sensor that was
    // never the problem.
    final pre = await _detectBlocker();
    if (pre != null) throw BleUnavailableException(pre);
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    final serviceGuids = [for (final e in entries) Guid(e.service)];
    // Which entry a matched service belongs to, or NULL when this particular
    // advertisement did not carry one of them. Services are each entry's own
    // GATT identity, so a collision here would mean two registry rows sharing
    // one service — a registry bug, not a runtime ambiguity to resolve softly.
    //
    // NULLABLE ON PURPOSE, and the whole point of the split with the caller
    // below. `withServices` filters on the SCAN, not on the payload: an
    // Android advertisement can match the filter and still arrive with an
    // empty or truncated `serviceUuids` (the 31-byte advertising packet is
    // full, and the rest is in a scan response that has not landed yet). A
    // fallback returned from in here was indistinguishable from a real match,
    // so the caller cached a guess and never looked again.
    // [lowercaseName] is the belt-and-suspenders fallback: `BandEntry
    // .nameMatcher` is the same per-entry escape hatch `transport.dart` uses
    // for a framed band whose advertisement carries its name but not a
    // matchable service UUID. It cannot rescue a device the OS-level
    // `withServices` filter below already excluded from the scan entirely —
    // only a real scan against real hardware settles whether that filter
    // ever does.
    // Split from the genuine service match on purpose: a name match is the
    // same kind of guess the comment above already warns about, and caching
    // it into `confirmed` would make it permanent the same way. Only
    // [serviceMatchFor] is safe to lock in — a peripheral's GATT identity
    // does not change mid-scan, but its advertised name matching a pattern
    // is not proof of anything and gets re-tried every advertisement instead.
    String? serviceMatchFor(List<Guid> advertised) {
      for (final g in advertised) {
        for (final e in entries) {
          if (g == Guid(e.service)) return e.id;
        }
      }
      return null;
    }

    String? nameMatchFor(String lowercaseName) {
      for (final e in entries) {
        if (e.nameMatcher?.call(lowercaseName) ?? false) return e.id;
      }
      return null;
    }

    // Remote ids whose entry is CONFIRMED by an advertisement that actually
    // carried the service. Everything else is shown under `entries.first`
    // until a real match lands — correct by construction for a single-entry
    // scan ([scanFor]), a placeholder that corrects itself for [scanForAny].
    final confirmed = <String, String>{};

    // Keyed by remote id: a scan re-reports the same peripheral several times
    // a second, and a list that grows a row per advertisement is not a picker.
    final seen = <String, BandCandidate>{};
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      var changed = false;
      for (final r in results) {
        final id = r.device.remoteId.str;
        final was = seen[id];
        // The ADVERTISED name first. `platformName` is the OS's cached name
        // for a peripheral it has seen before, which can be stale or empty;
        // the advertisement is what this sensor is saying now. Both go through
        // `cleanDeviceLabel`, and null survives as null rather than becoming a
        // placeholder. A name that drops out of a later advertisement keeps
        // the one we already had — losing it mid-scan would make the row the
        // user is reaching for change under their finger.
        final label = cleanDeviceLabel(r.advertisementData.advName) ??
            cleanDeviceLabel(r.device.platformName) ??
            was?.label;
        // Re-attempted on EVERY advertisement until one confirms, then fixed:
        // a confirmed match cannot change (a peripheral does not swap GATT
        // identity mid-scan) and re-reading it would only add work.
        final svcMatch = serviceMatchFor(r.advertisementData.serviceUuids);
        if (svcMatch != null) confirmed[id] = svcMatch;
        final match = confirmed[id] ??
            svcMatch ??
            nameMatchFor((r.advertisementData.advName.isNotEmpty
                    ? r.advertisementData.advName
                    : r.device.platformName)
                .toLowerCase());
        final now = (
          device: r.device,
          label: label,
          rssi: r.rssi,
          entryId: match ?? entries.first.id,
        );
        if (was == null ||
            was.rssi != now.rssi ||
            was.label != now.label ||
            was.entryId != now.entryId) {
          changed = true;
        }
        seen[id] = now;
      }
      if (changed) onResults(_ranked(seen));
    });
    try {
      // CLAIMED BEFORE THE START, not after it. `startScan` flips the radio on
      // partway through its own body and only THEN returns, so an owner set on
      // the line after it leaves a window where the scan is live and
      // [stopScanIfRunning] cannot see whose it is — a screen dismissed in that
      // window held the radio for the full 15 s doing nothing. Claiming it
      // first cannot fail the other way either: `flutter_blue_plus` serialises
      // `startScan`/`stopScan` through one mutex, so a stop issued in the
      // window queues behind this start and takes effect on the way out.
      _scanOwner = owner;
      await FlutterBluePlus.startScan(
        withServices: serviceGuids,
        timeout: timeout,
      );
      // The scan's own timeout is what stops it; this waits that out.
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      // Android reports a missing runtime permission by throwing HERE rather
      // than through the adapter state, so the pre-check above cannot see it.
      final blocker = classifyBleBlocker(error: e);
      if (blocker != null) throw BleUnavailableException(blocker);
      debugPrint('[hrs] scan error: $e');
    } finally {
      // Identity-guarded for the same reason `_disarming` is: only the scan
      // that claimed the radio may release the claim.
      if (identical(_scanOwner, owner)) _scanOwner = null;
      await sub.cancel();
    }
    onResults(_ranked(seen));
  }

  static List<BandCandidate> _ranked(Map<String, BandCandidate> seen) =>
      seen.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));

  /// Why the phone's own stack cannot scan, or null when it can.
  ///
  /// A deliberate second copy of `BleEngine._detectBlocker`: that one is
  /// private on an engine INSTANCE this file has no reference to and must not
  /// grow one — the point of the sensor link is that it never routes through
  /// the band's engine. The classifier itself ([classifyBleBlocker]) is
  /// shared, which is the half that has to stay in one place.
  static Future<BleBlocker?> _detectBlocker() async {
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

  /// One sentence saying why a scan should not be STARTED on this phone yet,
  /// or null when it may run. Not an error — a warning the screen shows before
  /// it does something it cannot take back within this app launch.
  ///
  /// THE iOS PROBLEM (ASSUMPTIONS I9), and it is real on this build. Verified
  /// rather than assumed, because the whole question is whether a
  /// `CBCentralManager` already exists by the time anyone reaches the pairing
  /// screen — if one does, this scan changes nothing and the guard is theatre:
  ///
  ///  * `flutter_blue_plus_darwin` creates its central lazily, on the first
  ///    method call that needs one — but `setLogLevel` and `setOptions` return
  ///    BEFORE that init block, so `main()`'s two startup calls do not create
  ///    one. Every other entry point (`getAdapterState`, `startScan`,
  ///    `connect`) passes through it, so the first of those wins.
  ///  * `AppState._initSteps` reaches flutter_blue_plus only under
  ///    `if (isPaired)`.
  ///
  /// So on a phone with no WHOOP paired, no central exists, and starting one
  /// here would make `AccessorySetup.showPicker()` fail with "CBManager is
  /// active with global permissions" for the rest of the process. It is not
  /// permanent — the next launch starts with no central — which is exactly
  /// what the sentence has to say, because the alternative is a WHOOP that
  /// silently cannot be paired and no way to guess why.
  ///
  /// Gated on `provisionedId() == null` and not on "is a band paired": once
  /// ASK has provisioned the WHOOP the picker is not needed again, and a phone
  /// that already has a live session already has a central anyway.
  static Future<String?> scanHeldBackReason() async {
    if (!Platform.isIOS) return null;
    if (!await AccessorySetup.isSupported()) return null;
    if (await AccessorySetup.provisionedId() != null) return null;
    return 'Your main band is not paired yet. Searching for a sensor now starts '
        'Bluetooth in a way that hides the system pairing sheet until you '
        'restart the app — so pair your main band first, or expect to restart '
        'the app before you can.';
  }

  // ── pairing: the device row ───────────────────────────────────────────────

  /// The `device.id` to store a peripheral under.
  ///
  /// MINTED, never the BLE remote id: that is a per-app CBPeripheral UUID on
  /// iOS and a rotating RPA on Android, and letting one become the primary key
  /// fragments one sensor into N identities whose rows can never be rejoined.
  /// Never [LocalDb.kPrimaryDeviceId] either — `''` is the primary band,
  /// permanently — which the `${entry.id}-` prefix makes structurally
  /// impossible.
  ///
  /// DERIVED from the remote id rather than random, so re-pairing the same
  /// sensor on the same phone lands back on its own row and its own history
  /// instead of minting a stranger. When the remote id does rotate, the stored
  /// one no longer connects either, so a new row is the truth: we cannot tell
  /// it is the same strap.
  static String mintDeviceId(BandEntry entry, String remoteId) =>
      '${entry.id}-${_fnv1a(remoteId).toRadixString(16).padLeft(8, '0')}';

  /// FNV-1a, 32-bit. `String.hashCode` is deliberately not used: Dart only
  /// promises it is consistent within ONE run, and this value is a primary key
  /// that has to name the same sensor after a restart.
  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h = (h ^ unit) & 0xffffffff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  /// Connect to [device], check it really exposes what [entry] requires, and
  /// write the `device` row that makes it reachable. Returns null on success,
  /// or a user-facing sentence on failure.
  ///
  /// The default pairing step for a notify-class band, which is the whole of
  /// what a heart-rate strap needs: no handshake, no key, no clock. A band
  /// that DOES need a key exchange supplies its own step to the screen and
  /// never calls this.
  ///
  /// [tier] defaults to null and is only worth passing explicitly when a
  /// caller knows better than the entry's own declared signals. Left null, it
  /// is derived from [declaredSignals]: `'beatToBeat'` for a strap that
  /// actually declares one (today, only [kBleHrs]), null for anything that
  /// declares none — same "NULL is a refusal, not a default" rule
  /// `oura_link.dart` states for its own row. A band whose measurement
  /// quality differs from that must say so rather than inherit it — the tier
  /// is what decides precedence between two sources, so a wrong one is a
  /// silent wrong number.
  ///
  /// Nothing is written unless the peripheral passed the characteristic check:
  /// a row pointing at a device that cannot answer is a sensor that appears
  /// paired and never produces a beat.
  ///
  /// Pulled out of [pairNotifySensor] so the derivation itself — the part a
  /// future adapter can get wrong — is reachable by a test that has no
  /// `BluetoothDevice` to connect.
  @visibleForTesting
  static String? deriveTier(String? explicit, String adapterId) =>
      explicit ?? (declaredSignals(adapterId).isEmpty ? null : 'beatToBeat');

  static Future<String?> pairNotifySensor(
    BandEntry entry,
    BluetoothDevice device, {
    String? label,
    String? tier,
  }) async {
    try {
      await device.connect(timeout: _connectTimeout);
    } catch (e) {
      debugPrint('[hrs] pair connect failed: $e');
      return 'That sensor did not answer. It may have gone back to sleep, or '
          'it may already be connected to another phone or app.';
    }
    try {
      final services = await device.discoverServices();
      final link = GattBandLink(
        entry: entry,
        services: services,
        onLog: (m) => debugPrint('[hrs] pair: $m'),
      );
      final missing =
          link.missingCharacteristics(entry.requiredCharacteristics);
      if (missing.isNotEmpty) {
        link.close();
        return 'That device answered, but it does not expose the '
            '${entry.label} data this needs '
            '(missing ${missing.map((u) => u.substring(0, 8)).join(", ")}). '
            'Nothing was saved.';
      }
      // Some notify-class bands (Pebble) gate everything past this point on
      // OS-level bonding, triggered by a write here rather than by an
      // app-layer key — see `BandEntry.bondTriggerCharacteristic`.
      final bondChar = entry.bondTriggerCharacteristic;
      if (bondChar != null && !await link.write(bondChar, const [0x01])) {
        link.close();
        return 'That device did not accept Bluetooth pairing. Nothing was '
            'saved.';
      }
      link.close();
      await LocalDb.upsertDevice(
        id: mintDeviceId(entry, device.remoteId.str),
        adapterId: entry.id,
        remoteId: device.remoteId.str,
        label: label,
        tier: deriveTier(tier, entry.id),
      );
      return null;
    } catch (e) {
      debugPrint('[hrs] pair setup failed: $e');
      return 'That sensor disconnected before it could be set up. Nothing was '
          'saved.';
    } finally {
      // The pairing connection is not the session. `arm()` opens its own when
      // a workout starts, and holding this one would be a second GATT link
      // nobody asked for.
      try {
        await device.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  /// Forget a paired sensor. Generic over WHICH adapter paired it — this is
  /// the one entry point the UI calls for any non-band row.
  ///
  /// THE PROMISE IS "this removes the source, not the data". The `device` row
  /// goes; every second and beat it wrote keeps its `device_id` in
  /// `decoded_onehz` / `decoded_rr`, so the history stays attributable and a
  /// re-pair of the same sensor ([mintDeviceId] is derived) finds it again.
  ///
  /// Refuses [LocalDb.kPrimaryDeviceId] outright: that row is the band, and
  /// unpairing the band is a different flow with a different promise.
  ///
  /// DISPATCHES ON `adapter_id` BEFORE TOUCHING ANYTHING. Every adapter with
  /// its own dedicated `*Link` class and session needs its own case here —
  /// falling through to the generic branch below disarms the completely
  /// unrelated `instance` (the ble_hrs chest-strap session) instead of the
  /// session that actually owns this device. An Oura or Mi Band row carries a
  /// secret this class knows nothing about — [OuraLink.forgetRing] and
  /// [MiBand234Link.forgetBand] drop the stored key and the row together, and
  /// calling `disarm()` on either here would leave that key behind while
  /// looking like a complete forget. A Withings row has no secret to lose,
  /// but [WithingsSteelHrLink.forgetDevice] still owns stopping ITS OWN live
  /// session before the row goes — `disarm()` here only knows about this
  /// class's own connection, not that one. An O2Ring row carries no secret,
  /// but [O2RingLink.forgetRing] still tears down a live session before the
  /// row goes — the same reason this dispatch exists at all. A RingConn row
  /// carries no such secret either, but still needs [RingConnLink.forgetRing]
  /// rather than this class's own `disarm()` — that call tears down a live
  /// WORKOUT sensor session, not a RingConn `sync()` that may be mid-drain. An
  /// HPlus row similarly has no secret, but its live connection is
  /// [HPlusLink.instance], a separate singleton from this class's own
  /// chest-strap session — `disarm()` here would tear down the wrong link and
  /// leave the real one (and its `BandHost`'s flush timer) running against a
  /// deleted device id. A Watch9 row is the same shape as HPlus:
  /// [Watch9Link.instance] owns its own live connection, separate from this
  /// class's chest-strap session.
  static Future<void> forgetDevice(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[hrs] refusing to forget the primary band from here.');
      return;
    }
    final row = (await LocalDb.deviceRows())
        .where((r) => r['id'] == id)
        .firstOrNull;
    if (row?['adapter_id'] == kOura.id) {
      await OuraLink.forgetRing(id);
      return;
    }
    if (row?['adapter_id'] == kRing11m.id) {
      await Ring11mLink.forget(id);
      return;
    }
    if (row?['adapter_id'] == kCoros.id) {
      await CorosLink.forget(id);
      return;
    }
    if (row?['adapter_id'] == kGarmin.id) {
      await GarminLink.forget(id);
      return;
    }
    if (row?['adapter_id'] == kUltrahuman.id) {
      await UltrahumanLink.forgetRing(id);
      return;
    }
    if (row?['adapter_id'] == kWithingsSteelHr.id) {
      await WithingsSteelHrLink.forgetDevice(id);
      return;
    }
    if (row?['adapter_id'] == kMiBand234.id) {
      await MiBand234Link.forgetBand(id);
      return;
    }
    if (row?['adapter_id'] == kPebble.id) {
      await PebbleLink.forgetPebble(id);
      return;
    }
    if (row?['adapter_id'] == kWatch9.id) {
      // Stop its own session before the row goes — same reasoning as the
      // generic branch below, aimed at the link that actually owns this
      // device instead of the unrelated ble_hrs singleton.
      await Watch9Link.instance.stop();
      await LocalDb.deleteDevice(id);
      return;
    }
    if (row?['adapter_id'] == kDafit.id) {
      await DafitLink.forget(id);
      return;
    }
    if (row?['adapter_id'] == kO2Ring.id) {
      await O2RingLink.forgetRing(id);
      return;
    }
    if (row?['adapter_id'] == kWearFit.id) {
      await WearFitLink.forgetDevice(id);
      return;
    }
    if (row?['adapter_id'] == kRingConn.id) {
      await RingConnLink.forgetRing(id);
      return;
    }
    if (row?['adapter_id'] == kLefun.id) {
      // No secret to drop — the envelope this device speaks has no key
      // exchange — so this is a plain stop-and-delete, same shape as Oura's
      // forget minus the keychain half. GATED ON THE LIVE SESSION ACTUALLY
      // BEING THIS ROW: `LefunLink` is a singleton over potentially several
      // paired rows, so stopping it unconditionally would drop a DIFFERENT
      // Lefun device's in-flight sync if one happened to be live when this
      // one was forgotten.
      if (LefunLink.instance.currentDeviceId == id) {
        await LefunLink.instance.stop();
      }
      await LocalDb.deleteDevice(id);
      return;
    }
    if (row?['adapter_id'] == kHPlus.id) {
      // HPlusLink.instance owns this band's live connection, not HrsLink's
      // own chest-strap session — stopping the wrong one would leave the
      // real link (and its BandHost's flush timer) running against a
      // device_id that no longer exists.
      await HPlusLink.instance.stop();
      await LocalDb.deleteDevice(id);
      return;
    }
    if (row?['adapter_id'] == kQHybrid.id) {
      await QHybridLink.forget(id);
      return;
    }
    if (row?['adapter_id'] == kColmi.id) {
      await ColmiLink.forgetRing(id);
      return;
    }
    if (row?['adapter_id'] == kBangleJs.id) {
      await BangleJsLink.forget(id);
      return;
    }
    // Before the row goes, not after: a live session would keep writing rows
    // under an id nothing can explain any more. Every live-session link
    // capable of writing under this id gets disarmed, not just this class's
    // own — a Polar row's live sensor is `PolarPmdLink`, not `instance`. GATED
    // ON THE ROW BEING THE ARMED HRS SENSOR for the `instance` branch, not
    // called unconditionally — this fallback used to run for ANY adapter
    // without its own branch above, which would tear down a live chest-strap
    // session while forgetting an unrelated device (e.g. a Lefun ring paired
    // alongside one).
    if (row?['adapter_id'] == kPolarPmd.id) {
      await PolarPmdLink.instance.disarm();
    } else if (row?['adapter_id'] == kBleHrsAdapter.id) {
      await instance.disarm();
    }
    await LocalDb.deleteDevice(id);
  }

  /// Connect to the paired sensor and start logging.
  /// No-op (returns false) when nothing is paired — this is opt-in hardware.
  ///
  /// Never scans: it connects straight to the stored remote id, so arming a
  /// workout cannot contend with the band's scan.
  ///
  /// WHAT IS ACTUALLY GUARANTEED — and every caller fires this `unawaited`,
  /// while the body awaits a database read, a 12 s connect and service
  /// discovery before it publishes anything:
  ///
  ///  * TWO CONCURRENT CALLS ARE ONE ATTEMPT, and get the same future. A
  ///    second call used to sail past the `_armed` check while the first was
  ///    still connecting and overwrite `_device`, `_link` and `_host` — the
  ///    first one's session then ran forever with nothing holding it.
  ///  * A CALL DURING A TEARDOWN WAITS IT OUT AND THEN ARMS. `_armed` stays
  ///    TRUE through every await in [disarm] — `_host.stop()`'s final flush,
  ///    the subscription cancel, the disconnect — so a call landing in that
  ///    window used to hit the `_armed` fast path, answer "already armed" and
  ///    start nothing; the teardown then finished underneath it, leaving no
  ///    session, no error, and a caller holding `true` with no reason to
  ///    retry. Ordinary sequence — stop a workout, start another inside the
  ///    same second. It waits out a teardown that FAILS too: only "it is
  ///    over" matters here, and [_disarm]'s `finally` leaves "not armed" true
  ///    whichever way it ended.
  ///  * AN ATTEMPT A [disarm] CANCELLED IS NEVER HANDED OUT AGAIN, because
  ///    `disarm` clears `_arming`. So `arm() → disarm() → arm()` inside one
  ///    connect window gives the LAST call a fresh attempt that can still
  ///    succeed. It used to be handed the first call's future, which the
  ///    disarm had already doomed: both callers got `false`, nothing was
  ///    armed, and the second call had never even tried. The same reason
  ///    [_arm]'s failure paths are generation-aware — a cancelled attempt
  ///    that called the full [disarm] on its way out would cancel the fresh
  ///    one instead.
  ///
  /// WHAT IS NOT GUARANTEED is that the answer is `true`. A cancelled or
  /// failed attempt answers `false` — never a half-armed state, and never a
  /// throw — and the caller retries or does not.
  ///
  /// Setting `_armed = false` at the top of [disarm] would NOT fix any of it.
  /// That only moves the race: the arm would then start a fresh session and
  /// the disarm still running behind it would tear that one down instead.
  Future<bool> arm() {
    final teardown = _disarming;
    // Recursive rather than a single await: a second [disarm] can land while
    // we wait, and the answer to "is anything armed" is only true after the
    // LAST one has finished. Identity of the returned future is deliberately
    // not preserved across a teardown — there is nothing yet to be identical
    // to — but the no-teardown path below still hands back the same `_arming`
    // to every caller, which is what dedupes the ordinary double-arm.
    if (teardown != null) return _armAfter(teardown);
    if (_armed) return Future.value(true);
    final existing = _arming;
    if (existing != null) return existing;
    late final Future<bool> mine;
    // Identity-guarded on the way out for the same reason `_disarming` and
    // `_scanOwner` are: a [disarm] may have cleared this slot and a LATER arm
    // filled it, and a cancelled attempt completing must not null out the
    // live one's memo.
    mine = _arm().whenComplete(() {
      if (identical(_arming, mine)) _arming = null;
    });
    return _arming = mine;
  }

  /// Arm once [teardown] is over, whether it succeeded or THREW. Its error
  /// belongs to whoever called that [disarm] — the rule `_disarmAfter`
  /// already follows — and letting it through here would break this chain:
  /// `arm()` would never run and a caller that only asked to be armed would
  /// get a thrown future instead of `false`.
  Future<bool> _armAfter(Future<void> teardown) async {
    try {
      await teardown;
    } catch (_) {/* the disarm caller's error, not ours */}
    return arm();
  }

  /// The in-flight [arm], or null — cleared by [disarm], which is what makes a
  /// cancelled attempt un-reusable. See [arm].
  Future<bool>? _arming;

  /// The in-flight [disarm] chain, or null when nothing is being torn down.
  /// [arm] waits on it; see its doc for what goes wrong otherwise.
  Future<void>? _disarming;

  /// How many times [disarm] has run. An [arm] whose count moved under it has
  /// been cancelled and must not publish — see the check in [_arm].
  int _disarms = 0;

  Future<bool> _arm() async {
    final disarmsAtStart = _disarms;
    final row = await pairedSensorRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. A sensor writing under it would
      // interleave its seconds with the band's in one REPLACE-keyed table.
      debugPrint('[hrs] refusing to arm: the sensor row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    // Declared OUT here so the catch can reach it: `_device` is not a
    // substitute, because the whole point of the cleanup below is the case
    // where a [disarm] has already nulled it (or a fresher arm has replaced
    // it) and only this frame still knows which peripheral it opened.
    final device = BluetoothDevice.fromId(remoteId);
    try {
      _device = device;
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). Acquired
      // before connect, released only when the link tears down in [disarm]
      // — a live GATT connection is the resource being capped, not the act
      // of opening one.
      await acquireSecondaryLinkSlot();
      if (_disarms != disarmsAtStart) {
        // Disarmed while queued for a slot — release it and bail without
        // ever connecting.
        releaseSecondaryLinkSlot();
        return false;
      }
      _holdsSecondaryLinkSlot = true;
      await device.connect(timeout: const Duration(seconds: 12));
      // Connect, bond, MTU and discovery are HOST work and stay on this side
      // of the seam. The adapter is handed the result and nothing else.
      final services = await device.discoverServices();
      // A `disarm()` that landed WHILE this was connecting has already torn
      // the session down — it nulls `_device`. Publishing on top of it would
      // set `_armed = true` over no device, so every later `arm()` would
      // short-circuit on `_armed`: the sensor stays dead for the rest of the
      // process. Reachable by the most ordinary thing a user does — start a
      // workout and stop it inside twelve seconds.
      if (_disarms != disarmsAtStart) {
        debugPrint('[hrs] arm abandoned: it was disarmed while connecting.');
        await _disconnectAbandoned(device);
        return false;
      }
      final link = GattBandLink(
        entry: kBleHrsAdapter.entry,
        services: services,
        onLog: (m) => debugPrint('[hrs] $m'),
      );
      _link = link;
      final missing =
          link.missingCharacteristics(kBleHrsAdapter.entry.requiredCharacteristics);
      if (missing.isNotEmpty) {
        debugPrint('[hrs] ${kBleHrsAdapter.label}: missing required '
            'characteristic(s) ${missing.map((u) => u.substring(0, 8)).join(", ")}.');
        await _teardownQuietly();
        return false;
      }
      final host = BandHost(
        adapter: kBleHrsAdapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[hrs] $m'),
      );
      _host = host;
      host.reading.addListener(() => _reading.value = host.reading.value);
      // A SESSION THAT ENDS ON ITS OWN MUST STILL RELEASE. `BandHost.run`
      // completes when the adapter's stream ends OR errors — it turns an
      // adapter error into normal completion and cancels only its own flush
      // timer. Nothing else noticed: `_armed` stayed true and the
      // secondary-link slot stayed held for the life of the process, so the
      // strap could never be armed again and one of two slots was gone.
      //
      // Gated on the disarm counter, not on `_host == host`: when it is
      // `disarm()` ITSELF that ended the run (via `_host.stop()`), `_host` is
      // still this host — disarm nulls it only after that await returns — so
      // an identity check would re-enter disarm from inside its own teardown.
      // The counter has already moved by then, because `disarm` increments it
      // synchronously. A host left over from an earlier arm generation is
      // excluded by the same test.
      unawaited(host.run(link).whenComplete(() {
        if (_disarms != disarmsAtStart) return;
        debugPrint('[hrs] session ended on its own — releasing the link.');
        unawaited(disarm());
      }));
      // A sensor that walks out of range mid-session ends the log there rather
      // than leaving the link claiming to be armed when it is gone.
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) unawaited(disarm());
      });
      _armed = true;
      // "Live, nothing yet" — a distinct state from "no sensor", and the one
      // a surface shows for the seconds a strap spends finding a signal.
      _reading.value = const HrsReading();
      return true;
    } catch (e) {
      // GENERATION-AWARE, and it has to be. A [disarm] that landed while this
      // attempt was connecting has ALREADY torn the shared state down, and a
      // fresher [arm] may own it by now: calling the full [disarm] here would
      // increment `_disarms` and cancel THAT one, which is how
      // `arm() → disarm() → arm()` inside one connect window ended with
      // nothing armed even once the memo was fixed. Ours to clean up is only
      // the connection nobody else has a reference to.
      if (_disarms != disarmsAtStart) {
        debugPrint('[hrs] arm failed after it was already disarmed: $e');
        await _disconnectAbandoned(device);
      } else {
        await _teardownQuietly();
      }
      return false;
    }
  }

  /// Tear down after a failed [_arm], swallowing the teardown's own failure.
  ///
  /// [_arm] is already answering `false`; a flush that threw on the way out
  /// must not turn that into a THROWN `arm()`, which — with every caller
  /// firing it `unawaited` — would land as an unhandled async error while the
  /// caller still never learns it is not armed. [_disarm]'s `finally` leaves
  /// "not armed" true either way, which is what makes swallowing it safe.
  Future<void> _teardownQuietly() async {
    try {
      await disarm();
    } catch (e) {
      debugPrint('[hrs] teardown after a failed arm threw: $e');
    }
  }

  /// Disconnect [device] on behalf of an arm generation that has been
  /// cancelled — but only when no NEWER one has claimed the radio.
  ///
  /// A cancelled arm usually has nothing left to close: the [disarm] that
  /// cancelled it disconnects whatever `_device` held, which is this same
  /// peripheral. It has something to close when its own `connect()` landed
  /// AFTER that disconnect — nobody else holds a reference to it, so skipping
  /// this would leak a live GATT connection for the life of the process.
  ///
  /// What it must NOT do is disconnect a peripheral a LATER [arm] has since
  /// connected. `BluetoothDevice.fromId` mints a fresh object per call and
  /// `flutter_blue_plus` connections are per PERIPHERAL, not per object, so a
  /// blind disconnect here kills that session — and the strap it kills is the
  /// one the user just asked for. `_device` identity is the discriminator:
  /// null means nobody owns the radio, a different object means someone
  /// newer does.
  ///
  /// [identical], NOT `==`: `BluetoothDevice.==` compares remote ids, and both
  /// generations connect to the SAME sensor, so `==` reads every generation as
  /// the current one and this guard would never fire.
  Future<void> _disconnectAbandoned(BluetoothDevice device) async {
    if (_device != null && !identical(_device, device)) return;
    try {
      await device.disconnect();
    } catch (_) {/* already gone */}
  }

  /// Stop logging, flush the tail and drop the link. Safe to call when not
  /// armed. AWAIT it before a finish screen reads the session back — an
  /// unawaited stop is how the last buffered batch goes missing.
  ///
  /// SERIALISED against itself and against [arm]. Two teardowns in flight at
  /// once each called `_host.stop()` on the same host and could land a
  /// `disconnect()` on the peripheral a later [arm] had just reconnected.
  Future<void> disarm() {
    // Synchronous, before anything is awaited and before the chain below:
    // `_arm` reads this counter to notice it has been cancelled mid-connect,
    // and an increment deferred behind a queued future would let an in-flight
    // arm publish a session on top of this teardown.
    _disarms++;
    // AND THE MEMO GOES WITH IT. The attempt that future belongs to has just
    // been cancelled by the counter above — it can only answer `false` now —
    // so leaving it in place would hand it to the next [arm] as if it were a
    // live attempt. `arm()` identity-guards its own clear, so this cannot
    // strand a LATER attempt's memo.
    _arming = null;
    final prev = _disarming;
    late final Future<void> mine;
    mine = _disarmAfter(prev).whenComplete(() {
      // Only the LAST teardown clears the gate; an earlier link in the chain
      // completing must not tell `arm()` the queue is empty.
      if (identical(_disarming, mine)) _disarming = null;
    });
    return _disarming = mine;
  }

  /// [prev] is awaited but its failure is SWALLOWED — it belongs to whoever
  /// called that disarm, and one teardown that threw must not wedge the chain
  /// (the same reason `withScanLock` swallows its body's error).
  Future<void> _disarmAfter(Future<void>? prev) async {
    if (prev != null) {
      try {
        await prev;
      } catch (_) {/* the previous caller's error, not ours */}
    }
    await _disarm();
  }

  /// A FAILED TEARDOWN STILL LEAVES "NOT ARMED" TRUE — that is what the
  /// `finally` is for, and it is not theoretical: `_host.stop()` awaits
  /// `_commit(all: true)`, a database write, and a throw there used to skip
  /// every line below it. `_armed` stayed TRUE over a dead session, so the
  /// next [arm] answered "already armed" and started nothing; the
  /// secondary-link slot stayed held for the life of the process; and the
  /// last reading stayed on screen. The error still propagates — a caller
  /// that awaited a flush before reading the session back must learn it
  /// failed — it just no longer takes the state with it.
  Future<void> _disarm() async {
    final d = _device;
    try {
      // Before the host's run subscription is cancelled: an adapter's
      // `finally` can still write on the way out, and that write must not
      // reach the radio.
      _link?.close();
      failTeardownForTest?.call();
      await _host?.stop();
    } finally {
      // Cancelled here, unconditionally, and BEFORE the disconnect below —
      // not chained after `_host?.stop()` inside the `try`. A throw there
      // used to skip this line entirely: the reference was nulled but the
      // subscription stayed live, so `d.disconnect()` a few lines down could
      // still fire this listener's own `disarm()` call — un-generation-gated,
      // able to tear down whatever session started in the meantime.
      await _connSub?.cancel();
      _link = null;
      _host = null;
      _connSub = null;
      _device = null;
      _armed = false;
      // The link tears down here, not at the connect call site — see
      // acquireSecondaryLinkSlot's doc comment for why the two are split.
      if (_holdsSecondaryLinkSlot) {
        _holdsSecondaryLinkSlot = false;
        releaseSecondaryLinkSlot();
      }
      // Null, not the last reading: a number left on screen after the link
      // died is the one lie this surface can tell.
      _reading.value = null;
      // In the `finally` too, and captured before it: a peripheral left
      // connected because the flush threw is a leaked GATT link, and the
      // throw is exactly when nobody is coming back for it.
      if (d != null) {
        try {
          await d.disconnect();
        } catch (_) {/* already gone */}
      }
    }
  }

  /// Forced failure inside [_disarm]'s body, for the test that proves a
  /// teardown which throws still leaves the sensor cleanly NOT armed. The real
  /// thrower is `BandHost.stop()` → `_commit(all: true)` → a `sqflite` write,
  /// which no test can make fail on demand without a fake host — and a fake
  /// host would prove the fake, not this `finally`.
  @visibleForTesting
  static void Function()? failTeardownForTest;

  /// Feed raw notification bytes as if a sensor with [deviceId] were armed,
  /// and write them. The only way in: the real entry point is a BLE
  /// notification and `flutter_blue_plus` has no simulator path, so without
  /// this seam nothing below the parser could be exercised at all.
  ///
  /// It replays through the SAME [BandHost] the radio drives, over a
  /// [ReplayBandLink]. A test seam that skipped the host would prove the
  /// wrong thing.
  @visibleForTesting
  Future<void> ingestForTest(
    String deviceId,
    List<(int, List<int>)> arrivals,
  ) async {
    final host = BandHost(
      adapter: kBleHrsAdapter,
      deviceId: deviceId,
      onLog: (m) => debugPrint('[hrs] $m'),
    );
    // As `_arm` does, and for a reason a test can see: [deviceId] is how a
    // consumer of [reading] attributes a beat, so a seam that left it null
    // would prove the parser and nothing about attribution.
    _host = host;
    final link = ReplayBandLink();
    final done = host.run(link);
    for (final (sec, value) in arrivals) {
      link.feed(kHeartRateMeasurementUuid, value, atSec: sec);
    }
    // Close, then wait for `run()` to actually finish, rather than guessing at
    // a delay: the adapter's `await for` is asynchronous and a flush racing it
    // would silently drop the tail.
    await link.close();
    await done;
    // Captured BEFORE stop(), which clears the host's own reading: a real
    // session leaves its last beat on screen until disarm() is called, and
    // ingestForTest has to leave the same thing true for a test to observe.
    _reading.value = host.reading.value;
    await host.stop();
    _host = null;
  }
}
