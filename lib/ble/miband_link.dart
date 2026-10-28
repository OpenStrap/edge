// THE HOST for a paired Mi Band 2 or 3: hold the pairing key, pair it,
// forget it, and bank whatever [MiBand234Adapter] hands back — the stored
// minute history (HR samples, daily steps, the band's sleep) and the raw
// optional channels — keeping the `miband_since` resume cursor.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns one (owner
// ruling R6), so not one byte of this path has been exercised against a real
// unit. The registry entry stays EXPERIMENTAL and what it banks reaches a
// metric only behind the default-off `wearable_enabled:miband234` flag, and
// only while it is the active wearable (`compute/inputs/canonical.dart`).
// That is correct behaviour for an uncalibrated decoder, not a limitation to
// route around.
//
// THE PAIRING PRECONDITION IS THE OURA RING'S, RESTATED. The band holds
// exactly one 16-byte key and will only accept a new one while it holds
// none — a factory-reset unit, or one that has never been paired to anything.
// A band already bound to Mi Fit or Zepp refuses or silently ignores the
// install, so it has to be unpaired from that app FIRST. There is no state in
// which both work; say that before the user commits, not after.
//
// THE KEY IS OURS AND IT NEVER LEAVES THE PHONE. Generated here by
// `Random.secure()`, no vendor server anywhere in the handshake, no Mi Fit or
// Zepp account needed. Losing it costs another factory reset (or an unpair
// from whichever app currently holds it), nothing more.
//
// THE ORDER IS INSTALL, THEN PROVE, same shape as `oura_link.dart`'s pairing
// flow: the key install is unauthenticated (it has to be — it is what creates
// the credential), so it goes out first. The full challenge/response round
// trip after it is not required by the protocol; it is here because "the
// band acknowledged the write" and "the band will now let us in" are
// different claims, and a pairing that only checks the first hands the user a
// `device` row that can never authenticate again.

import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/miband234.dart';
import '../sync/reset_gate.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// `sync_cursor` name for one band's activity resume point (Unix seconds).
String _sinceItem(String deviceId) => 'miband_since:$deviceId';

/// Keychain item name for one band's pairing key. Suffixed with the MINTED
/// device id, never the BLE remote id — that rotates.
String _keyItem(String deviceId) => 'miband234_pairing_key:$deviceId';

/// FIRST-UNLOCK, not the plugin's default WHEN-UNLOCKED, for the same reason
/// `oura_link.dart` picks it: a background relaunch routinely happens while
/// the phone is locked, and a `whenUnlocked` item cannot be read then.
const IOSOptions _kApple = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);
const MacOsOptions _kMacos = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

const FlutterSecureStorage _secure = FlutterSecureStorage();

/// THE ORDER IS THE WHOLE MESSAGE, same as the ring's own wording. A band only
/// accepts a new key while it holds none, so freeing it from Mi Fit/Zepp comes
/// FIRST and pairing here comes second.
const String _kUnpairFirst =
    'The band would not take a new key. It only accepts one while it holds '
    'none, so unpair it from Mi Fit or Zepp first (or use a factory-reset '
    'unit), then pair here.';

/// Status 0x02: the band was in the wrong state for the command. Not a
/// refusal of the key, so not [_kUnpairFirst]'s remedy.
const String _kBandBusy =
    'The band was not ready for pairing. Restart it (or put it on the charger '
    'for a moment), keep it next to the phone, and try again.';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int>? _unhex(String s) {
  if (s.length.isOdd || s.isEmpty) return null;
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    final v = int.tryParse(s.substring(i, i + 2), radix: 16);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// Why a Mi Band session ended before it could read anything.
enum MiBand234SyncFailure {
  /// The band answered the handshake with a refusal: the wrong key, or a
  /// band still bound to another one. Re-pairing installs a key it accepts.
  keyRejected,

  /// The band stopped answering partway through the handshake.
  authUnanswered,
}

/// The live link to a paired Mi Band. One instance; a second concurrent band
/// is not a thing anyone asked for.
///
/// ONE CURSOR: `miband_since`, where the next history fetch starts. The
/// adapter reports it after each round and it is written in the SAME
/// transaction as that round's rows ([BandHost]'s `extraCursors`), so a
/// commit that fails leaves it where it was. [sync] connects, authenticates,
/// fetches history from the cursor, collects the optional channels inside a
/// bounded window, and disconnects.
class MiBand234Link {
  MiBand234Link._();
  static final MiBand234Link instance = MiBand234Link._();

  /// The `device` row for the paired band, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kMiBand234.id) return r;
    }
    return null;
  }

  /// Every stored pairing key, for "delete everything", which removes the
  /// `device` rows [forgetBand] would need and so must drop the keys itself.
  ///
  /// Also sweeps every stored key of this family by its item prefix: a key
  /// orphaned by a crash mid-pair has no `device` row, so the row ids alone
  /// would leave it behind. False when any key may remain — the keychain was
  /// unreadable or a delete threw — so the reset can say it was incomplete
  /// instead of reporting a clean wipe with a pairing secret still stored.
  static Future<bool> dropStoredKeys(Iterable<String> deviceIds) async {
    final prefix = _keyItem('');
    final items = {for (final id in deviceIds) _keyItem(id)};
    var complete = true;
    try {
      final all = await _secure.readAll(iOptions: _kApple, mOptions: _kMacos);
      items.addAll(all.keys.where((k) => k.startsWith(prefix)));
    } catch (e) {
      complete = false;
      debugPrint('[miband234] could not list stored keys: $e');
    }
    for (final item in items) {
      try {
        await _secure.delete(key: item, iOptions: _kApple, mOptions: _kMacos);
      } catch (e) {
        complete = false;
        debugPrint('[miband234] could not drop a stored key: $e');
      }
    }
    return complete;
  }

  /// Delete the stored 16-byte pairing key for [deviceId], best-effort.
  ///
  /// Two callers, one problem: a pairing secret must not outlive the thing it
  /// was for. [pairMiBand234] writes the key BEFORE the band proves it (see
  /// that function's own header) so a crash mid-pair leaves an orphaned key
  /// with no `device` row pointing at it; forgetting a paired band later
  /// leaves the same kind of orphan if only the row goes. Swallows a locked
  /// keychain/keystore exactly as reading one does — there is nothing for the
  /// user to redo, and a delete that cannot run now costs nothing left behind
  /// that this app itself can read.
  static Future<void> _dropKey(String deviceId) async {
    try {
      await _secure.delete(
        key: _keyItem(deviceId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
    } catch (e) {
      debugPrint('[miband234] could not drop the stored key: $e');
    }
  }

  static Future<List<int>?> _readKey(String deviceId) async {
    try {
      final hex = await _secure.read(
        key: _keyItem(deviceId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
      return hex == null ? null : _unhex(hex);
    } catch (e) {
      debugPrint('[miband234] the keychain was unavailable: $e');
      return null;
    }
  }

  /// Forget a paired band: drop its key, drop its `device` row.
  ///
  /// THE ORDER IS THE OPPOSITE OF PAIRING'S, on purpose — see
  /// `oura_link.dart`'s [OuraLink.forgetRing] for the identical reasoning: a
  /// crash between the two here would rather leave a `device` row whose key is
  /// already gone (which just fails the next connect visibly) than a key
  /// outliving the row that was its only reason to exist.
  static Future<bool> forgetBand(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[miband234] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await _dropKey(id);
    await LocalDb.deleteDevice(id);
    // Nothing resumes from a forgotten id's cursor: a re-pair of the same
    // band after a forget mints a new id.
    await LocalDb.deleteCursor(_sinceItem(id));
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that stops a write
  /// the adapter queued before teardown from landing on a LATER connection to
  /// the same band.
  GattBandLink? _link;

  /// The session driving [MiBand234Adapter] over [_link].
  BandHost? _host;

  /// `device.id` of the paired band. Never [LocalDb.kPrimaryDeviceId]: `''` is
  /// the primary band, permanently (ASSUMPTIONS A1).
  String? _deviceId;

  /// Wall-clock now, in Unix seconds. A field so a replay is deterministic.
  int Function() _now = () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool _busy = false;

  /// Connect to the paired band, fetch its stored history from the cursor,
  /// collect whatever the optional channels offer, all within [window], then
  /// disconnect.
  ///
  /// Returns false when nothing is paired, the key is unreadable, or the
  /// connect failed. SERIALISED: a second call while one is in flight is a
  /// no-op rather than a second radio session over the same peripheral.
  Future<bool> sync({Duration window = const Duration(seconds: 90)}) {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync(window).whenComplete(() => _busy = false);
  }

  Future<bool> _sync(Duration window) async {
    // Read before the first await: a "delete everything" that lands while
    // this sync is parked on the link slot or still connecting must find it
    // here. The host refuses every write once a reset has run since.
    final resetGen = ResetGate.generation;
    lastSyncFailure = null;
    final row = await pairedRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[miband234] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    final key = await _readKey(deviceId);
    if (key == null) {
      debugPrint('[miband234] paired, but the pairing key could not be '
          'read. Nothing is written and nothing is re-keyed.');
      return false;
    }
    _deviceId = deviceId;
    try {
      return await withSecondaryLinkSlot(() async {
        // A forget that landed while this sync was parked on the slot has
        // already stopped it (nulling `_deviceId`) and deleted the row. The
        // ids captured above would otherwise still connect to the forgotten
        // device and bank its history under a row that no longer exists.
        if (_deviceId != deviceId || ResetGate.changedSince(resetGen)) {
          return false;
        }
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kMiBand234,
            services: services,
            onLog: (m) => debugPrint('[miband234] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kMiBand234.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[miband234] ${kMiBand234.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          _pendingSince = null;
          final host = _makeHost(
              deviceId,
              resetGeneration: resetGen,
              MiBand234Adapter(
                key: key,
                sinceSec: await LocalDb.getCursorInt(_sinceItem(deviceId)),
                nowSeconds: _now,
              ));
          _host = host;
          // `run()` never completes on its own — the optional channels have
          // no end-of-data signal, unlike the Oura ring's exhausted drain —
          // so this is bounded by [window] rather than awaited to
          // completion.
          final done = host.run(link);
          await Future.any(
              [done, Future<void>.delayed(window)]);
        } finally {
          await stop();
        }
        // Read only after [stop]: the note rides the host's vendor-write
        // chain, which stop drains.
        return lastSyncFailure == null;
      });
    } catch (e) {
      debugPrint('[miband234] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session collected, disconnect. Safe to
  /// call when nothing is connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  /// Build this session's [BandHost]. One place, so [_sync] and
  /// [ingestForTest] cannot drift on what each callback does.
  BandHost _makeHost(String deviceId, MiBand234Adapter adapter,
          {int? resetGeneration}) =>
      BandHost(
        resetGeneration: resetGeneration,
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[miband234] $m'),
        buildArchive: _buildArchiveRow,
        // The cursor moves past days only once their steps and nights are
        // banked: a failed vendor write holds it where it was.
        notesAfterVendorWrites: true,
        onNote: (key, value) {
          if (key == 'miband_since' && value is int) _pendingSince = value;
          if (key == kMiBandAuthFailedNote) {
            lastSyncFailure = value is int && value != 0x01
                ? MiBand234SyncFailure.keyRejected
                : MiBand234SyncFailure.authUnanswered;
          }
        },
        // Read at commit time: the cursor lands with the rows it covers, or
        // not at all.
        extraCursors: () {
          final since = _pendingSince;
          return since == null ? const {} : {_sinceItem(deviceId): '$since'};
        },
        nowSeconds: _now,
      );

  /// The newest `miband_since` the adapter reported, not yet committed.
  int? _pendingSince;

  /// Why the last session ended without authenticating, or null. A refused
  /// handshake ends the adapter's stream quietly, so without this a band that
  /// rejects the key reads as a sync that worked, and the remedy (re-pair)
  /// never reaches the user. Cleared at the start of every session.
  MiBand234SyncFailure? lastSyncFailure;

  /// Bank one optional-channel notification verbatim, undecoded (owner
  /// rulings R1-R3). The leading byte is [MiBand234Adapter]'s own archive
  /// tag — never transmitted, stripped back off here so `hex` is exactly
  /// what the radio sent, and read only to pick [ArchiveRecord.reason] and
  /// `packetType`.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    final tag = bytes[0];
    final reason = switch (tag) {
      kMiBand234ArchiveBattery => 'miband234_battery',
      kMiBand234ArchiveSteps => 'miband234_steps',
      kMiBand234ArchiveHr => 'miband234_hr',
      kMiBand234ArchiveActivity => 'miband234_activity',
      _ => 'miband234_raw',
    };
    return ArchiveRecord(
      // NULL, not 0 — this band has no flash-record counter, and a constant 0
      // would make every one of its frames exempt from thinning by accident
      // (`thinRawArchiveBefore` samples on this column). Same reasoning as
      // `oura_link.dart`'s identical NULL.
      counter: null,
      hex: _hex(bytes.sublist(1)),
      packetType: tag,
      // NULL: none of these channels carry a decodable timestamp.
      recTs: null,
      capturedAt: capturedAtMs,
      reason: reason,
    );
  }

  /// Replay a scripted band through the REAL [MiBand234Adapter] and the real
  /// write path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path.
  ///
  /// [reply] answers each write on the auth characteristic the way the band
  /// would. [extra] is fed to the link BEFORE the drive starts — battery,
  /// steps or heart-rate frames with no corresponding write to key off —
  /// `ReplayBandLink`'s channels buffer, so a frame fed before the adapter
  /// has subscribed is not dropped.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<int> key,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    List<(String uuid, List<int> value)> extra = const [],
    List<(String uuid, List<int> value)> Function(String uuid, List<int> value)?
        history,
    bool needsKeyWrite = false,
    int Function()? nowSeconds,
    Duration window = const Duration(milliseconds: 200),
  }) async {
    _now = nowSeconds ?? _now;
    _deviceId = deviceId;
    _pendingSince = null;
    lastSyncFailure = null;
    final link = ReplayBandLink();
    for (final (uuid, v) in extra) {
      link.feed(uuid, v, atSec: _now());
    }
    final host = _makeHost(
      deviceId,
      MiBand234Adapter(
        key: key,
        needsKeyWrite: needsKeyWrite,
        replyTimeout: const Duration(milliseconds: 50),
        fetchTimeout: const Duration(milliseconds: 50),
        sinceSec: await LocalDb.getCursorInt(_sinceItem(deviceId)),
        nowSeconds: _now,
      ),
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < window && !finished) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        final (char, value) = link.writes[served];
        if (char == kHuami234AuthChar) {
          for (final f in reply(served, value)) {
            link.feed(kHuami234AuthChar, f, atSec: _now());
          }
        } else {
          final answers = history?.call(char, value) ??
              const <(String, List<int>)>[];
          for (final (u, f) in answers) {
            link.feed(u, f, atSec: _now());
          }
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    await host.stop();
    _host = null;
    _deviceId = null;
    return link;
  }
}

/// The id a re-pair keeps, or null to mint one: the id of the Mi Band row
/// already paired to [remoteId], never the primary band's.
///
/// A device_id is the storage key for everything this band banks and for its
/// `miband_since` cursor, and every reader resolves "the Mi Band" as the first
/// row with this adapter. Minting a fresh id on each pairing left the old row
/// behind: syncs went to the new id while the active-wearable cursor, which
/// only moves when its row disappears, kept naming the old one, and the stale
/// row held one of the two secondary-sensor slots.
///
/// ONLY THE SAME BAND REUSES ITS ROW. The id names a stored key, and pairing
/// writes the new key under it before the band has proved it. A different
/// band reusing a working band's id would, on any failure after it took the
/// key, leave the working band's row pointing at a key that band never had.
/// A different band gets a fresh id, and its pairing forgets the old row only
/// once it succeeds.
String? miBandReusableDeviceId(
    Iterable<Map<String, Object?>> rows, String remoteId) {
  for (final r in rows) {
    final id = r['id'];
    if (r['adapter_id'] == kMiBand234.id &&
        id is String &&
        id != LocalDb.kPrimaryDeviceId &&
        r['remote_id'] == remoteId) {
      return id;
    }
  }
  return null;
}

/// What a failed pairing does with the key stored under its device id.
enum MiBandFailedPairKey {
  /// A freshly minted id's key: an orphan, nothing points at it.
  drop,

  /// The same band's previous key, read before this attempt overwrote it:
  /// the band never took the new one, so the old pairing still works.
  restore,

  /// The same band already acknowledged the new key and answers to nothing
  /// else, so the new key stays.
  keep,
}

/// The decision behind [pairMiBand234]'s failure path. [reused] is true only
/// when the id came from [miBandReusableDeviceId], so the band that took the
/// key is the band the row points at.
MiBandFailedPairKey miBandFailedPairKey({
  required bool reused,
  required bool keyInstalled,
  required bool hadPriorKey,
}) {
  if (!reused) return MiBandFailedPairKey.drop;
  if (keyInstalled) return MiBandFailedPairKey.keep;
  return hadPriorKey ? MiBandFailedPairKey.restore : MiBandFailedPairKey.drop;
}

/// Mi Band rows other than [keepId]: duplicates an earlier pairing left
/// behind before re-pairs reused the id. Never the primary band's row.
List<String> staleMiBandRowIds(
        Iterable<Map<String, Object?>> rows, String keepId) =>
    [
      for (final r in rows)
        if (r['adapter_id'] == kMiBand234.id &&
            r['id'] is String &&
            r['id'] != keepId &&
            r['id'] != LocalDb.kPrimaryDeviceId)
          r['id'] as String,
    ];

/// Pair [device] as this phone's Mi Band 2 or 3. Null on success, or a
/// sentence the user can act on.
///
/// FACTORY RESET (OR A NEVER-PAIRED UNIT) IS A PRECONDITION, NOT A
/// CONSEQUENCE — see this file's own header. Say that BEFORE the user
/// commits; this function is the point of no return, not the warning.
///
/// STILL HARDWARE-UNVERIFIED, like everything else on this path (R6).
Future<String?> pairMiBand234(BluetoothDevice device) async {
  final rnd = Random.secure();
  final key = List<int>.generate(16, (_) => rnd.nextInt(256));
  final reusedId =
      miBandReusableDeviceId(await LocalDb.deviceRows(), device.remoteId.str);
  final deviceId = reusedId ??
      'miband234-${_hex(List<int>.generate(4, (_) => rnd.nextInt(256)))}';
  // The key the working pairing depends on, read before this attempt
  // overwrites it (the new key is stored before the band proves it), so a
  // failed re-pair can put it back. A read that fails stops here rather than
  // overwrite a key this run could not see.
  List<int>? priorKey;
  if (reusedId != null) {
    try {
      final hex = await _secure.read(
        key: _keyItem(reusedId),
        iOptions: _kApple,
        mOptions: _kMacos,
      );
      priorKey = hex == null ? null : _unhex(hex);
    } catch (e) {
      debugPrint('[miband234 pair] the keychain was unavailable: $e');
      return 'The phone’s keychain is locked. Unlock the phone and try again.';
    }
  }
  // Set once the band acknowledged the new key: from then on it answers to
  // nothing else, so the old key is worth nothing to restore.
  var keyInstalled = false;
  GattBandLink? link;
  // Set true only on the one path that writes the `device` row. Every OTHER
  // exit — a refused command, a silent band, a caught exception, even the
  // early `missingCharacteristics` return before the key is written at all —
  // leaves this false, and the `finally` below drops whatever key the phone
  // has stored for [deviceId] so a failed pairing never outlives itself as an
  // orphaned secret with no row pointing at it.
  var paired = false;
  try {
    // A cap on concurrent SECONDARY links (never the primary band's own
    // connect — see `ble_state.dart`'s `kMaxConcurrentSecondaryLinks` doc).
    // This pairing flow's connect and disconnect both complete inside this one
    // call, so the simple scoped form is correct here.
    //
    // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately, and THE WAIT IS
    // BOUNDED, both for the same reasons `pairOuraRing` gives: a person is
    // holding the band against the phone with a spinner in front of them.
    return await withSecondaryLinkSlot<String?>(
      timeout: const Duration(seconds: 30),
      onTimeout: () => 'Another sensor is using this phone’s Bluetooth right '
          'now. Try pairing again in a moment.',
      () async {
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final localLink = GattBandLink(
            entry: kMiBand234,
            services: services,
            onLog: (m) => debugPrint('[miband234 pair] $m'),
          );
          link = localLink;
          final missing = localLink
              .missingCharacteristics(kMiBand234.requiredCharacteristics);
          if (missing.isNotEmpty) {
            return 'That device does not expose the service this app '
                'speaks for a Mi Band 2 or 3.';
          }

          // Install, then prove — over the real auth characteristic and
          // nothing else.
          //
          // ONE subscription and a growing list, rather than a `firstWhere`
          // per reply: `BandLink.notify` is single-subscription, so a second
          // `firstWhere` would throw "already listened to" after the first
          // reply had been consumed.
          // ponytail: a 20 ms poll over the list is the smallest correct
          // thing here — the alternative is a second copy of
          // `miband234.dart`'s private `_Inbox`, for three replies, once,
          // during pairing.
          final inbox = <List<int>>[];
          final sub = localLink.notify(kHuami234AuthChar).listen((rec) {
            inbox.add(rec.$2);
          });
          var read = 0;
          Future<List<int>?> waitFor(bool Function(List<int>) matches,
              {Duration within = const Duration(seconds: 10)}) async {
            final elapsed = Stopwatch()..start();
            while (elapsed.elapsed < within) {
              while (read < inbox.length) {
                final f = inbox[read++];
                if (matches(f)) return f;
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            return null;
          }

          try {
            // THE KEY IS STORED BEFORE IT IS SENT, and the order is
            // deliberate — see `oura_link.dart`'s identical reasoning. A crash
            // between the write and the store leaves the band holding a key
            // this phone does not have, unrecoverable except by another
            // factory reset. A stored key with no band behind it costs
            // nothing: nothing looks at it until a `device` row points to it.
            await _secure.write(
              key: _keyItem(deviceId),
              value: _hex(key),
              iOptions: _kApple,
              mOptions: _kMacos,
            );
            if (!await localLink
                .write(kHuami234AuthChar, miBand234KeyInstall(key))) {
              return 'The band would not accept a command. Try again with '
                  'it on the charger and next to the phone.';
            }
            // Up to 30 s: the band may wait for a tap to confirm the install.
            final installed = await waitFor(
                (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x01,
                within: const Duration(seconds: 30));
            if (installed != null &&
                installed[2] == kMiBand234AuthInvalidState) {
              return _kBandBusy;
            }
            // SILENCE IS A REFUSAL, NOT CONSENT — same as the ring: a band
            // that already holds a key does not necessarily answer at all,
            // and minting a `device` row on the strength of a quiet band is
            // how a user spends a factory reset and ends up with nothing
            // working.
            if (installed == null || installed[2] != 0x01) {
              return _kUnpairFirst;
            }
            keyInstalled = true;
            List<int>? challengeFrame;
            for (final request in kMiBand234ChallengeRequests) {
              if (!await localLink.write(kHuami234AuthChar, request)) {
                return 'The band would not accept a command. Try again with '
                    'it on the charger and next to the phone.';
              }
              final f = await waitFor(
                  (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x02);
              if (f != null && f.length >= 19 && f[2] == 0x01) {
                challengeFrame = f;
                break;
              }
            }
            if (challengeFrame == null) {
              return 'The band stopped answering part-way through pairing. '
                  'Put it on the charger, keep it next to the phone, and try '
                  'again.';
            }
            final answer = miBand234AuthResponse(
                key, challengeFrame.sublist(3, 19));
            if (!await localLink
                .write(kHuami234AuthChar, miBand234AuthAnswer(answer))) {
              return 'The band would not accept the pairing answer.';
            }
            final result = await waitFor(
                (f) => f.length >= 3 && f[0] == 0x10 && f[1] == 0x03);
            if (result == null) {
              return 'The band stopped answering part-way through pairing. '
                  'Put it on the charger, keep it next to the phone, and try '
                  'again.';
            }
            // 0x01 is the only success code; 0x02 (wrong state) can clear
            // on a retry; 0x04 (wrong key, or still bound elsewhere) and
            // anything else share the unpair-first remedy.
            if (result[2] == kMiBand234AuthInvalidState) return _kBandBusy;
            if (result[2] != 0x01) {
              return _kUnpairFirst;
            }
          } finally {
            await sub.cancel();
          }

          // The `device` row LAST, because it is what makes the band
          // reachable: a row that exists is a band this app will try to
          // reconnect to, so it is only written once the key is stored AND
          // the band has proved it accepts it.
          await LocalDb.upsertDevice(
            id: deviceId,
            adapterId: kMiBand234.id,
            remoteId: device.remoteId.str,
            label: cleanDeviceLabel(device.platformName) ?? kMiBand234.label,
            // `tier` is left unset on purpose — it means MEASUREMENT QUALITY,
            // and this band's sparse HR is unverified (it derives only behind
            // the default-off `wearable_enabled:miband234` flag), so there is
            // no quality to rank. NULL is a refusal, not a default.
          );
          paired = true;
          // Any other Mi Band row: one an older pairing left behind, or the
          // band this one replaces (one Mi Band syncs at a time). Best effort:
          // the band is paired either way.
          try {
            for (final id
                in staleMiBandRowIds(await LocalDb.deviceRows(), deviceId)) {
              await MiBand234Link.forgetBand(id);
            }
          } catch (e) {
            debugPrint('[miband234 pair] could not drop a stale row: $e');
          }
          return null;
        } finally {
          link?.close();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      },
    );
  } catch (e) {
    debugPrint('[miband234 pair] failed: $e');
    return 'Could not connect to that device.';
  } finally {
    // Touches no radio, so it stays outside the slot.
    //
    // A freshly minted id's key is an orphan once pairing failed. A reused
    // id (always the same band) had a key the working pairing depends on, so
    // it is put back, unless the band already took the new key, in which
    // case the new one is the only key it will answer to.
    if (!paired) {
      switch (miBandFailedPairKey(
        reused: reusedId != null,
        keyInstalled: keyInstalled,
        hadPriorKey: priorKey != null,
      )) {
        case MiBandFailedPairKey.drop:
          await MiBand234Link._dropKey(deviceId);
        case MiBandFailedPairKey.keep:
          break;
        case MiBandFailedPairKey.restore:
          try {
            await _secure.write(
              key: _keyItem(deviceId),
              value: _hex(priorKey!),
              iOptions: _kApple,
              mOptions: _kMacos,
            );
          } catch (e) {
            debugPrint('[miband234 pair] could not restore the prior key: $e');
          }
      }
    }
  }
}
