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
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/db.dart';
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'accessory_setup.dart';
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/ble_hrs.dart';
import 'adapters/gatt_link.dart';
import 'ble_state.dart'
    show BleBlocker, BleUnavailableException, classifyBleBlocker, withScanLock;
import 'oura_link.dart' show OuraLink;

/// One arrival second's worth of notifications.
class _Second {
  int? hr;
  final List<int> rr = [];
}

/// One peripheral a pairing scan heard, in the shape a picker needs.
///
/// [label] is the advertised name AFTER `cleanDeviceLabel`, and it stays
/// nullable: plenty of sensors advertise no name at all, and a made-up
/// "Unknown device" would be a value where there is none. The screen shows the
/// band's own label instead.
typedef BandCandidate = ({BluetoothDevice device, String? label, int rssi});

/// What a paired sensor is saying RIGHT NOW. Display only — see
/// [HrsLink.reading].
class HrsReading {
  /// The last bpm the sensor reported, or null while the link is up and
  /// nothing has arrived yet. A strap takes seconds to find a signal, and that
  /// is a real state; it is never rendered as a zero. The parser already
  /// refuses 0 bpm, so a non-null value here was measured.
  final int? bpm;

  /// Arrival second of [bpm] — `TimeAnchor.arrival`, same caveat as every
  /// other timestamp on this path. Null with [bpm].
  final int? atSec;

  const HrsReading({this.bpm, this.atSec});
}

/// The live link to a paired heart-rate sensor. One instance; a second
/// concurrent sensor is not a thing anyone asked for.
class HrsLink {
  HrsLink._();
  static final HrsLink instance = HrsLink._();

  /// Flush cadence for the write buffer. A sensor notifies ~1 Hz, and one
  /// transaction per beat on the UI isolate is the mistake `commitSyncBatch`
  /// already chunks around.
  static const Duration _flushEvery = Duration(seconds: 15);

  BluetoothDevice? _device;

  /// Kept only so [disarm] can [GattBandLink.close] it. Closing is what stops a
  /// write the adapter queued before the teardown from landing on a LATER
  /// connection to the same strap — see the field's own doc.
  GattBandLink? _link;
  StreamSubscription<BandEvent>? _runSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Completer<void>? _runDone;
  Timer? _flushTimer;

  /// Arrival second -> that second's readings. Keyed by second because that is
  /// the key `decoded_onehz` / `decoded_rr` are written under: accumulating
  /// per second is what stops two notifications landing in the same second
  /// from REPLACE-ing each other's beat 0.
  final Map<int, _Second> _pending = {};

  /// `device.id` of the paired sensor — the `device_id` every row it writes
  /// carries. Never [LocalDb.kPrimaryDeviceId]: `''` is the primary band,
  /// permanently (ASSUMPTIONS A1).
  String? _deviceId;

  bool _armed = false;

  /// What the sensor is saying right now, or null when none is armed.
  ///
  /// THE DISPLAY PATH, AND ONLY THAT. [_flush] stays the single writer into
  /// `decoded_*`; this notifier persists nothing and is read by nothing that
  /// derives. A second write path built on the live number is exactly how a
  /// displayed value and a stored value start disagreeing with no way to tell
  /// which one a metric used.
  ///
  /// A [ValueListenable] rather than a stream because there is one current
  /// reading and every consumer wants the latest one — a late listener on a
  /// broadcast stream would render nothing until the next beat.
  ValueListenable<HrsReading?> get reading => _reading;
  final ValueNotifier<HrsReading?> _reading = ValueNotifier(null);

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

  /// True between `startScan` resolving and the scan window closing, for THIS
  /// file's scan and nothing else.
  ///
  /// The pairing screen has to be able to end its own scan early — the lock
  /// is held for the whole 15 s window and a dismissed screen should not make
  /// the next caller wait it out. What it must NOT do is call a bare
  /// `FlutterBluePlus.stopScan()`: the radio has one scanner, every holder
  /// awaits `isScanning == false`, and a stop issued by anyone satisfies
  /// everyone's await. A screen whose scan is still QUEUED behind the lock
  /// would end the RUNNING holder's scan instead of its own, which reports
  /// "found nothing" with no error anywhere.
  static bool _scanRunning = false;

  /// End this file's scan early if one is actually running. No-op otherwise —
  /// including when the caller's own scan is still queued behind the lock.
  ///
  /// ponytail: a queued scan is not cancellable, so a dismissed screen can
  /// still hold the lock for its full window doing nothing. That costs a
  /// wait, never a wrong answer, which is the direction to fail in. Give
  /// `withScanLock` a cancellation token only if a real flow needs the lock
  /// back sooner.
  static void stopScanIfRunning() {
    if (!_scanRunning) return;
    unawaited(FlutterBluePlus.stopScan());
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
  static Future<void> scanFor(
    BandEntry entry, {
    required void Function(List<BandCandidate>) onResults,
    Duration timeout = _scanWindow,
  }) {
    assert(!entry.isFramed,
        '${entry.id} is a framed band — pair it through BleEngine.scan.');
    // Process-wide, because the radio has ONE scanner and the band's own scan
    // shares it. Without this, whichever scan called `stopScan` first ended
    // the other one having seen nothing, with no error to say why.
    return withScanLock(() => _scanFor(entry, onResults, timeout));
  }

  static Future<void> _scanFor(
    BandEntry entry,
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
        final now = (device: r.device, label: label, rssi: r.rssi);
        if (was == null || was.rssi != now.rssi || was.label != now.label) {
          changed = true;
        }
        seen[id] = now;
      }
      if (changed) onResults(_ranked(seen));
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(entry.service)],
        timeout: timeout,
      );
      _scanRunning = true;
      // The scan's own timeout is what stops it; this waits that out.
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      // Android reports a missing runtime permission by throwing HERE rather
      // than through the adapter state, so the pre-check above cannot see it.
      final blocker = classifyBleBlocker(error: e);
      if (blocker != null) throw BleUnavailableException(blocker);
      debugPrint('[hrs] scan error: $e');
    } finally {
      _scanRunning = false;
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
    return 'Your WHOOP is not paired yet. Searching for a sensor now starts '
        'Bluetooth in a way that hides the system WHOOP pairing sheet until '
        'you restart the app — so pair the WHOOP first, or expect to restart '
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
  /// [tier] defaults to the strap's, and a band whose measurement quality
  /// differs must say so rather than inherit it — the tier is what decides
  /// precedence between two sources, so a wrong one is a silent wrong number.
  ///
  /// Nothing is written unless the peripheral passed the characteristic check:
  /// a row pointing at a device that cannot answer is a sensor that appears
  /// paired and never produces a beat.
  static Future<String?> pairNotifySensor(
    BandEntry entry,
    BluetoothDevice device, {
    String? label,
    String tier = 'beatToBeat',
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
      link.close();
      if (missing.isNotEmpty) {
        return 'That device answered, but it does not expose the '
            '${entry.label} data this needs '
            '(missing ${missing.map((u) => u.substring(0, 8)).join(", ")}). '
            'Nothing was saved.';
      }
      await LocalDb.upsertDevice(
        id: mintDeviceId(entry, device.remoteId.str),
        adapterId: entry.id,
        remoteId: device.remoteId.str,
        label: label,
        tier: tier,
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
  /// DISPATCHES ON `adapter_id` BEFORE TOUCHING ANYTHING. An Oura row carries
  /// a secret this class knows nothing about — [OuraLink.forgetRing] drops the
  /// stored key and the row together, and calling `disarm()` on it here would
  /// leave that key behind while looking like a complete forget.
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
    // Before the row goes, not after: a live session would keep writing rows
    // under an id nothing can explain any more.
    await instance.disarm();
    await LocalDb.deleteDevice(id);
  }

  /// Connect to the paired sensor and start logging.
  /// No-op (returns false) when nothing is paired — this is opt-in hardware.
  ///
  /// Never scans: it connects straight to the stored remote id, so arming a
  /// workout cannot contend with the band's scan.
  ///
  /// SERIALISED, because every caller fires it `unawaited` and the body awaits
  /// a database read, a 12 s connect and service discovery before it publishes
  /// anything. A second call used to sail past the `_armed` check while the
  /// first was still connecting and overwrite `_device`, `_link`, `_runSub` and
  /// `_flushTimer` — the first one's timer and subscription then ran forever
  /// with nothing holding them.
  Future<bool> arm() {
    if (_armed) return Future.value(true);
    return _arming ??= _arm().whenComplete(() => _arming = null);
  }

  /// The in-flight [arm], or null. See [arm].
  Future<bool>? _arming;

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
    _deviceId = deviceId;
    try {
      final device = BluetoothDevice.fromId(remoteId);
      _device = device;
      await device.connect(timeout: const Duration(seconds: 12));
      // Connect, bond, MTU and discovery are HOST work and stay on this side
      // of the seam. The adapter is handed the result and nothing else.
      final services = await device.discoverServices();
      // A `disarm()` that landed WHILE this was connecting has already torn the
      // session down — it nulls `_device` and `_deviceId`. Publishing on top of
      // it would set `_armed = true` over no device and no `_deviceId`, so
      // `_flush` would discard every second and every later `arm()` would
      // short-circuit on `_armed`: the sensor stays dead for the rest of the
      // process. Reachable by the most ordinary thing a user does — start a
      // workout and stop it inside twelve seconds.
      if (_disarms != disarmsAtStart) {
        debugPrint('[hrs] arm abandoned: it was disarmed while connecting.');
        try {
          await device.disconnect();
        } catch (_) {/* already gone */}
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
        await disarm();
        return false;
      }
      _startRun(link);
      // A sensor that walks out of range mid-session ends the log there rather
      // than leaving the link claiming to be armed when it is gone.
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) unawaited(disarm());
      });
      _flushTimer = Timer.periodic(_flushEvery, (_) => unawaited(_flush()));
      _armed = true;
      // "Live, nothing yet" — a distinct state from "no sensor", and the one
      // a surface shows for the seconds a strap spends finding a signal.
      _reading.value = const HrsReading();
      return true;
    } catch (_) {
      await disarm();
      return false;
    }
  }

  /// Stop logging, flush the tail and drop the link. Safe to call when not
  /// armed. AWAIT it before a finish screen reads the session back — an
  /// unawaited stop is how the last buffered batch goes missing.
  Future<void> disarm() async {
    _disarms++;
    _flushTimer?.cancel();
    _flushTimer = null;
    // Before the run subscription is cancelled: an adapter's `finally` can
    // still write on the way out, and that write must not reach the radio.
    _link?.close();
    _link = null;
    await _stopRun();
    await _connSub?.cancel();
    _connSub = null;
    await _flush(all: true);
    final d = _device;
    _device = null;
    _deviceId = null;
    _armed = false;
    // Null, not the last reading: a number left on screen after the link died
    // is the one lie this surface can tell.
    _reading.value = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  /// Drive the adapter over [link]. Cancelling [_runSub] is the ONLY way the
  /// session ends from this side — an adapter does not get to hang up, so
  /// every timer and buffer it owns dies with its `async*` body.
  void _startRun(BandLink link) {
    final done = Completer<void>();
    _runDone = done;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _runSub = kBleHrsAdapter.run(link).listen(
      _onEvent,
      onDone: finish,
      onError: (Object e) {
        debugPrint('[hrs] session ended on error: $e');
        finish();
        // ponytail: `setNotifyValue` is now awaited inside the link's stream
        // rather than inside [arm], so a rejected subscribe surfaces HERE
        // instead of propagating out of `arm()` as a `false`. The ceiling is
        // that `arm()` can briefly answer true for a session that is already
        // dying; the callers all ignore its result. Tearing down here is what
        // stops the link sitting "armed" over a dead stream. Give `arm()` back
        // its answer only if a caller ever starts reading it.
        if (_armed) unawaited(disarm());
      },
      cancelOnError: true,
    );
  }

  Future<void> _stopRun() async {
    await _runSub?.cancel();
    _runSub = null;
    _runDone = null;
  }

  void _onEvent(BandEvent e) {
    switch (e) {
      case SampleBatch(:final samples, :final ephemeral):
        // EPHEMERAL IS NEVER PERSISTED, and the check is the HOST's, not the
        // adapter's promise. This band always sends false; the line exists so
        // the one place that decides what reaches the database is the one
        // place that reads the flag.
        if (ephemeral) return;
        for (final s in samples) {
          final slot = _pending.putIfAbsent(s.tsEpoch, _Second.new);
          // Last notification in the second wins.
          if (s.hr != null) slot.hr = s.hr;
          slot.rr.addAll(s.rrMs);
          // The live surface, updated from the SAME sample that was just
          // buffered so the two can never disagree. It is below the
          // `ephemeral` guard on purpose: no adapter emits an ephemeral batch
          // today, and if one ever does, this publish moves ABOVE the guard —
          // display-only is precisely what ephemeral means — while the guard
          // itself stays where it is, deciding what reaches the database.
          if (s.hr != null) {
            _reading.value = HrsReading(bpm: s.hr, atSec: s.tsEpoch);
          }
        }
      case OffloadCheckpoint():
        // A sensor with no flash cannot have anything to forget. If this ever
        // fires, the adapter grew a store and this host has no
        // commit-then-confirm path to honour the safe-trim invariant with —
        // so it must NOT be confirmed. Dropping it stalls; confirming it would
        // authorise a delete of data we never banked.
        assert(false, 'ble_hrs emitted an OffloadCheckpoint; it stores nothing');
      case BandNote(:final key, :final value):
        debugPrint('[hrs] $key = $value');
    }
  }

  /// Feed raw notification bytes as if a sensor with [deviceId] were armed,
  /// and write them. The only way in: the real entry point is a BLE
  /// notification and `flutter_blue_plus` has no simulator path, so without
  /// this seam nothing below the parser could be exercised at all.
  ///
  /// It replays through the SAME [BleHrsAdapter.run] the radio drives, over a
  /// [ReplayBandLink]. A test seam that skipped the adapter would prove the
  /// wrong thing.
  ///
  /// [reading] is LEFT SET when this returns, exactly as a real session leaves
  /// its last beat on screen — call [disarm] if a test needs it back at null.
  @visibleForTesting
  Future<void> ingestForTest(
    String deviceId,
    List<(int, List<int>)> arrivals,
  ) async {
    _deviceId = deviceId;
    final link = ReplayBandLink();
    _startRun(link);
    for (final (sec, value) in arrivals) {
      link.feed(kHeartRateMeasurementUuid, value, atSec: sec);
    }
    // Close, then wait for `run()` to actually finish, rather than guessing at
    // a delay: the adapter's `await for` is asynchronous and a flush racing it
    // would silently drop the tail.
    await link.close();
    await _runDone?.future;
    await _flush(all: true);
    await _stopRun();
    _deviceId = null;
  }

  /// Write out every second that can no longer receive more notifications.
  ///
  /// The CURRENT second is held back unless [all]: a second written twice
  /// would restart `beat_index` at 0 and REPLACE the beats already stored for
  /// it. `disarm` passes `all: true` because nothing more is coming.
  Future<void> _flush({bool all = false}) async {
    final deviceId = _deviceId;
    if (_pending.isEmpty) return;
    if (deviceId == null) {
      _pending.clear();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ready = _pending.keys.where((s) => all || s < now).toList()..sort();
    if (ready.isEmpty) return;
    // Taken out of the buffer BEFORE the await: losing a batch to a failed
    // write is better than replaying it under a later second's beat indices.
    final batchRows = [for (final s in ready) (s, _pending.remove(s)!)];
    // `beat_ts_ms` is deliberately absent from every row below. It means "where
    // the beat actually was", and for an arrival-anchored source we do not know
    // — anchor-minus-durations would be a measured claim we cannot make. NULL
    // is the column's own word for "not kept".
    assert(kBleHrsAdapter.entry.timeAnchor == TimeAnchor.arrival);
    // Its own transaction, NOT `commitSyncBatch`: that path is the ACK-gating
    // commit, it raises `synchronous` for the duration and it refuses a
    // non-primary `device_id` outright (the `sync_cursor` namespace is global).
    // Nothing here trims a band's flash, so none of the safe-trim invariant is
    // in play — this only has to queue politely behind a drain on the shared
    // connection, which sqflite does.
    try {
      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        final b = txn.batch();
        for (final (sec, slot) in batchRows) {
          b.insert(
            'decoded_onehz',
            {
              'device_id': deviceId,
              'ts_ms': sec * 1000,
              'rec_ts': sec,
              // ponytail: `counter` is NOT NULL and is a WHOOP flash-record
              // number this sensor does not have. 0 for every row is a
              // constant, not a measurement, and nothing reads the column
              // except `ORDER BY rec_ts, counter`. Make it nullable when
              // db.dart is next open.
              'counter': 0,
              'hr': slot.hr,
              'device_family': kBleHrsAdapter.id,
              'source': kBleHrsAdapter.id,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          // CLEAR THE SECOND BEFORE REINSERTING, exactly as `_queueRrBeats`
          // does on the band path and for the same reason: REPLACE only
          // overwrites `beat_index` 0..n-1, so a second that once carried more
          // beats keeps the stale tail and reports beats the sensor never sent.
          // Within one armed session a second is written once (`_pending`
          // removes it), but re-arming inside the same second is not — and the
          // 15 s flush cadence means the second on either side of a stop is
          // exactly the one at risk. Scoped to THIS device, so it can never
          // reach the band's beats for the same second.
          b.rawDelete(
            'DELETE FROM decoded_rr WHERE device_id = ? AND ts_ms = ?',
            [deviceId, sec * 1000],
          );
          for (var i = 0; i < slot.rr.length; i++) {
            b.insert(
              'decoded_rr',
              {
                'device_id': deviceId,
                'ts_ms': sec * 1000,
                'rec_ts': sec,
                'beat_index': i,
                'rr_ts_ms': sec * 1000,
                'rr_ms': slot.rr[i],
                'device_family': kBleHrsAdapter.id,
                'source': kBleHrsAdapter.id,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
        await b.commit(noResult: true);
      });
    } catch (e) {
      // Losing a buffered batch is better than throwing out of a timer on the
      // UI isolate; the next flush carries on.
      debugPrint('[hrs] flush failed, ${batchRows.length} second(s) lost: $e');
    }
  }
}
