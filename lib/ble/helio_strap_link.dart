// The HOST for a paired Amazfit Helio Strap: hold the `device` row, connect,
// drive [HelioStrapAdapter] over the link, commit what it decodes and bank
// every reply verbatim, disconnect.
//
// THE SHAPE IS `ColmiLink`'s: no drain cursor (the adapter re-walks a rolling
// window every connect), no pairing key built here (the auth key is read
// from secure storage by the adapter itself — see `helio_strap.dart`'s file
// header). One-shot [HelioStrapLink.sync]: read the `device` row, connect by
// `remote_id`, discover, check [GattBandLink.missingCharacteristics], drive
// `run()`, commit, disconnect.
//
// EXPERIMENTAL (ASSUMPTIONS R6): nobody on this project has run this against
// a physical strap.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../compute/inputs/canonical.dart' show pairedRowOf;
import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/helio_strap.dart';
import 'adapters/host.dart' show BandHost;
import '../sync/reset_gate.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const FlutterSecureStorage _pairSecure = FlutterSecureStorage();

/// Bounded wait for Bluetooth to actually be reported ON before a connect
/// is attempted. Same reasoning and same shape as `oura_link.dart`'s own
/// `_awaitAdapterOn` (duplicated, not shared, for the same reason as
/// `_Inbox` above): a connect issued while the adapter state is still
/// settling can throw a generic, confusing error on a phone whose
/// Bluetooth is genuinely on; this lets pairing say "Bluetooth is off"
/// instead. Returns false when the adapter never reported ON within the
/// bound.
Future<bool> _awaitAdapterOn() async {
  final s = await FlutterBluePlus.adapterState
      .firstWhere((s) => s == BluetoothAdapterState.on)
      .timeout(const Duration(seconds: 10),
          onTimeout: () => BluetoothAdapterState.unknown);
  return s == BluetoothAdapterState.on;
}

/// Pair [device] with a 16-byte auth key the user already has, from
/// wherever they obtained it — this function only VERIFIES and STORES one,
/// it never attempts to acquire one (that is a separate, unbuilt flow; see
/// `helio_strap.dart`'s file header). Null on success, or a sentence the
/// user can act on.
///
/// READ-ONLY ON THE STRAP: only the auth handshake runs ([runHelioHandshake],
/// shared with [HelioStrapAdapter.run] so the two can never drift on how the
/// handshake is actually driven) — nothing is written to the strap's own
/// flash, so a wrong key costs a refusal and nothing else.
///
/// THE KEY IS STORED ONLY AFTER THE STRAP HAS PROVEN IT ACCEPTS IT. A
/// failed attempt leaves whatever was in secure storage before completely
/// untouched — there is no install step here that could leave an unproven
/// secret behind the way Oura's fresh-key path has to guard against.
///
/// THE DEVICE ID IS REUSED on a re-pair, same reasoning as every other
/// link's pairing function: `device_id` is the storage key for
/// `decoded_onehz`/`observation`, so minting a fresh one on every pairing
/// would fork one physical strap into N identities with the earlier one's
/// history orphaned under an id nothing reads.
Future<String?> pairHelioStrapWithTypedKey(
        BluetoothDevice device, String raw) =>
    _pairZeppOsWithTypedKey(device, raw, kHelioStrap);

/// The typed-key pairing function for [adapterId] when it is one of this
/// family's devices (Helio Strap, Mi Band 7, the Zepp OS watches), else
/// null. Same handshake and verify-then-store rules for each, under the
/// device's own key slot and its own `device` row.
Future<String?> Function(BluetoothDevice, String)? zeppOsTypedKeyPairFor(
    String adapterId) {
  final link = HelioStrapLink.forId(adapterId);
  if (link == null) return null;
  return (device, raw) => _pairZeppOsWithTypedKey(device, raw, link.entry);
}

Future<String?> _pairZeppOsWithTypedKey(
    BluetoothDevice device, String raw, BandEntry entry) async {
  final hex = raw.trim().replaceFirst(RegExp('^0x', caseSensitive: false), '');
  if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
    return 'That is not a valid key: it must be exactly 32 hex characters.';
  }
  final key = Uint8List.fromList(
      [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  final keySlot = zeppOsKeySlot(entry);
  final tag = '[${entry.id} pair]';

  // Read BEFORE the first await: a "delete everything" that lands while
  // this reads the old row, the keychain, waits on the slot or runs the
  // handshake must not find a fresh key and device row behind it, nor a
  // device id minted from the wiped store.
  // A pairing begun DURING a reset would capture the already-raised
  // generation and pass every check once that reset ends.
  if (ResetGate.active) return kHelioPairResetText;
  final resetGen = ResetGate.generation;
  final priorRow = await pairedRowOf(entry.id);
  // Only the SAME device keeps its id: a different one under the old one's
  // history id would write its readings over the old one's at matching
  // seconds. The app holds one key per family, so a second device is refused
  // until the first is forgotten.
  if (priorRow != null && priorRow['remote_id'] != device.remoteId.str) {
    return 'Another ${entry.label} is already paired. Forget it on its device '
        'page first, then pair this one.';
  }
  final rnd = Random.secure();
  final idPrefix = entry.id == kHelioStrap.id ? 'helio' : entry.id;
  final deviceId = (priorRow?['id'] as String?) ??
      '$idPrefix-${_hex(List<int>.generate(4, (_) => rnd.nextInt(256)))}';

  // What the keychain held before this attempt touched it, so a failure
  // AFTER the write below (the device-row upsert throwing, say) can be
  // rolled back to it rather than leave an unproven key sitting where a
  // working one used to be — same discipline `oura_link.dart`'s pairing
  // function uses, for the same reason.
  String? priorHex;
  try {
    priorHex = await _pairSecure.read(
      key: keySlot,
      iOptions: kHelioStrapIosKeyOptions,
      mOptions: kHelioStrapMacosKeyOptions,
    );
  } catch (e) {
    return 'The phone’s keychain is locked. Unlock the phone and try again.';
  }

  return withSecondaryLinkSlot<String?>(
    timeout: const Duration(seconds: 30),
    onTimeout: () => 'Another sensor is using this phone’s Bluetooth right '
        'now. Try pairing again in a moment.',
    () async {
      GattBandLink? link;
      try {
        // NOT a key verdict: Bluetooth being off says nothing about the key
        // typed — it ends the attempt and is reported as itself, matching
        // `oura_link.dart`'s own pairing function.
        if (!await _awaitAdapterOn()) {
          return 'Bluetooth is off. Turn it on and try again.';
        }
        await device.connect(timeout: const Duration(seconds: 20));
        final services = await device.discoverServices();
        link = GattBandLink(
          entry: entry,
          services: services,
          onLog: (m) => debugPrint('$tag $m'),
        );
        final missing =
            link.missingCharacteristics(entry.requiredCharacteristics);
        if (missing.isNotEmpty) {
          return 'This device is missing something this app needs — it may '
              'not be a ${entry.label}, or its firmware answered differently '
              'than expected.';
        }

        final result = await runHelioHandshake(link, key,
            timeout: const Duration(seconds: 10));
        if (result is HelioHandshakeFailed) {
          return switch (result.reason) {
            'wrong_key' => 'The device rejected this key. Double-check it '
                'and try again.',
            'timeout' => 'The device didn’t answer. Make sure it’s close by '
                'and try again.',
            _ => 'Pairing failed (${result.reason}).',
          };
        }

        return await persistHelioPairing(
          deviceId: deviceId,
          remoteId: device.remoteId.str,
          hex: hex,
          priorHex: priorHex,
          resetGen: resetGen,
          entry: entry,
        );
      } catch (e) {
        return 'Could not connect: $e';
      } finally {
        // Drop the link and DISCONNECT before the slot is released — same
        // ordering `HelioStrapLink._sync` and `ColmiLink._sync` both use,
        // and for the same reason: held in an OUTER finally (after this
        // closure returns) this would run after the slot had already been
        // released, letting the next queued link connect while this one
        // was still disconnecting.
        await link?.close();
        try {
          await device.disconnect();
        } catch (_) {/* already gone */}
      }
    },
  );
}

/// The text a pairing interrupted by "delete everything" ends with.
const String kHelioPairResetText =
    'Pairing was interrupted by a reset. Pair the strap again.';

/// The reset ended the pairing but its own undo failed: say what may be
/// left, so the user can run "delete everything" again.
const String kHelioPairResetLeftoverText =
    'Pairing was interrupted by a reset, and the strap\'s key or device '
    'entry may remain on this phone. Run "Delete everything" again, then '
    'pair the strap again.';

/// Store a key the strap has just ACCEPTED, then its device row: the one
/// place a pairing persists, so its reset rules are tested in one place.
/// [resetGen] is [ResetGate.generation] read before the pairing's FIRST
/// await. Three rules:
///  * nothing is written once a reset has run since [resetGen];
///  * a reset that lands during either write is undone after it (key and
///    row deleted): a check before a write cannot see a reset that starts
///    inside the write, a check after it can;
///  * a failed row write restores [priorHex] only when no reset ran: after
///    one, the wiped keychain stays wiped.
@visibleForTesting
Future<String?> persistHelioPairing({
  required String deviceId,
  required String remoteId,
  required String hex,
  required String? priorHex,
  required int resetGen,
  BandEntry entry = kHelioStrap,
}) async {
  final keySlot = zeppOsKeySlot(entry);
  Future<bool> dropKey() async {
    try {
      await _pairSecure.delete(
        key: keySlot,
        iOptions: kHelioStrapIosKeyOptions,
        mOptions: kHelioStrapMacosKeyOptions,
      );
      return true;
    } catch (_) {
      return false; // keychain unavailable: the caller says a key may remain
    }
  }

  if (ResetGate.changedSince(resetGen)) return kHelioPairResetText;
  try {
    await _pairSecure.write(
      key: keySlot,
      value: hex,
      iOptions: kHelioStrapIosKeyOptions,
      mOptions: kHelioStrapMacosKeyOptions,
    );
  } catch (e) {
    return 'The phone’s keychain is locked. Unlock the phone and try again.';
  }
  if (ResetGate.changedSince(resetGen)) {
    return await dropKey() ? kHelioPairResetText : kHelioPairResetLeftoverText;
  }
  try {
    await LocalDb.upsertDevice(
      id: deviceId,
      adapterId: entry.id,
      remoteId: remoteId,
      label: entry.label,
    );
  } catch (e) {
    // The row never landed. Restore what the keychain held before this
    // attempt, unless a reset wiped it meanwhile: then it stays wiped.
    if (priorHex == null || ResetGate.changedSince(resetGen)) {
      if (!await dropKey() && ResetGate.changedSince(resetGen)) {
        return kHelioPairResetLeftoverText;
      }
    } else {
      try {
        await _pairSecure.write(
          key: keySlot,
          value: priorHex,
          iOptions: kHelioStrapIosKeyOptions,
          mOptions: kHelioStrapMacosKeyOptions,
        );
      } catch (_) {}
    }
    return 'Could not save the pairing: $e';
  }
  if (ResetGate.changedSince(resetGen)) {
    // The wipe ran while the row was written: take both back out, row
    // first. If the row stays, keep its key with it (a row with no key is
    // a strap that silently never syncs) and say both may remain.
    try {
      await LocalDb.deleteDevice(deviceId);
    } catch (_) {
      return kHelioPairResetLeftoverText;
    }
    return await dropKey() ? kHelioPairResetText : kHelioPairResetLeftoverText;
  }
  return null;
}

/// The live link to one paired device of this protocol family. One instance
/// per device family ([instance] for the Helio Strap, [miBand7] for the
/// Xiaomi / Mi Smart Band 7); a second concurrent device of the same family
/// is not a thing anyone asked for (same call as `ColmiLink`).
class HelioStrapLink {
  HelioStrapLink._(this.entry);
  static final HelioStrapLink instance = HelioStrapLink._(kHelioStrap);
  static final HelioStrapLink miBand7 = HelioStrapLink._(kMiBand7);
  static final HelioStrapLink gtr3 = HelioStrapLink._(kAmazfitGtr3);
  static final HelioStrapLink gtr3Pro = HelioStrapLink._(kAmazfitGtr3Pro);
  static final HelioStrapLink gts3 = HelioStrapLink._(kAmazfitGts3);

  /// Every link of this family, so app-wide stop / background sync loop over
  /// them instead of naming each device.
  static final List<HelioStrapLink> all = [instance, miBand7, gtr3, gtr3Pro, gts3];

  /// The link driving [adapterId], or null when it is not this family.
  static HelioStrapLink? forId(Object? adapterId) {
    for (final l in all) {
      if (l.entry.id == adapterId) return l;
    }
    return null;
  }

  /// The family this link drives.
  final BandEntry entry;

  String get _tag => '[${entry.id}]';

  /// The `device` row for the paired strap, or null.
  static Future<Map<String, Object?>?> pairedHelioStrapRow() =>
      instance.pairedRow();

  /// The `device` row for this link's paired device, or null.
  Future<Map<String, Object?>?> pairedRow() => pairedRowOf(entry.id);

  /// Forget a paired strap — [forget] on the Helio link.
  static Future<bool> forgetStrap(String id) => instance.forget(id);

  /// Forget a paired device: stop any live session, drop its `device` row.
  /// No stored pairing-key row to drop here — the auth key lives in secure
  /// storage under this family's slot (`zeppOsKeySlot` in
  /// `helio_strap.dart`); dropping the `device` row is the whole story for
  /// this link, same as `ColmiLink`.
  Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('$_tag refusing to forget the primary band from here.');
      return false;
    }
    // Before the first await: a sync still reading the row has no
    // `_deviceId` yet for the check below to match.
    _forgets++;
    if (_deviceId == id) await stop();
    await LocalDb.deleteDevice(id);
    // The key outlives nothing once its device row is gone — a re-pair
    // mints a fresh key anyway (first bind always goes through the real
    // Zepp app), so leaving the old one in the keychain only means a
    // factory-reset-and-forgotten strap's secret sits around unused
    // forever. Same cleanup `OuraLink.forgetRing` does for its own key.
    try {
      await _pairSecure.delete(
        key: zeppOsKeySlot(entry),
        iOptions: kHelioStrapIosKeyOptions,
        mOptions: kHelioStrapMacosKeyOptions,
      );
    } catch (_) {/* keychain unavailable; the device row is gone regardless */}
    return true;
  }

  /// "Delete everything": drop the strap's pairing key, whatever device it
  /// was for. False when the keychain refused, so the reset can say a key
  /// was left behind.
  static Future<bool> dropStoredKey() async {
    try {
      await _pairSecure.delete(
        key: kHelioStrapSecureStorageKey,
        iOptions: kHelioStrapIosKeyOptions,
        mOptions: kHelioStrapMacosKeyOptions,
      );
      return true;
    } catch (e) {
      debugPrint('[helio_strap] could not drop the stored key: $e');
      return false;
    }
  }

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;

  /// Bumped by every forget. A sync that saw it move since it started
  /// does not connect, whatever its `_deviceId` says.
  int _forgets = 0;
  bool _busy = false;

  /// How many syncs got past the slot wait to a connect attempt. Under a test
  /// `connect()` has no plugin and fails, so the return value alone cannot
  /// tell a cancelled sync from one that tried the radio.
  @visibleForTesting
  int get connectAttemptsForTest => _connectAttempts;
  int _connectAttempts = 0;

  @visibleForTesting
  String? get deviceIdForTest => _deviceId;

  /// The session's clock, read once (Unix seconds): what the adapter's
  /// `kHelioFetchWindow` lookback is counted from, and the anchor stamped on
  /// every raw reply's `rec_ts`.
  int? _anchorSec;

  /// Connect to the paired strap, walk its rolling fetch window, disconnect.
  ///
  /// Returns false when nothing is paired, the connect failed, there was no
  /// auth key, the handshake failed, or no required characteristic was
  /// found. SERIALISED: a second call while one is in flight is a no-op
  /// rather than a second radio session over the same peripheral.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    // Read before the first await: a "delete everything" that lands while
    // this sync is parked on the link slot or still connecting must find it
    // here. The host refuses every write once a reset has run since.
    final resetGen = ResetGate.generation;
    final forgets = _forgets;
    lastSyncFailed = false;
    final row = await pairedRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('$_tag refusing to sync: the strap row claims the '
          'primary device id — re-pair it with a minted id.');
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
        // A forget during the row lookup above found no `_deviceId` to stop.
        if (_forgets != forgets) return false;
        _connectAttempts++;
        BandHost? host;
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          // Best-effort only here (unlike pairing, which treats the result
          // as a reportable verdict) — same as `OuraLink._sync`'s own use
          // of this wait: a connect issued while the adapter state is
          // still settling can throw a confusing error on a phone whose
          // Bluetooth is genuinely on.
          await _awaitAdapterOn();
          // The same checks as on entering the slot: a forget during the
          // wait above found no host to stop, so nothing else would keep
          // this sync off the forgotten strap.
          if (_deviceId != deviceId ||
              _forgets != forgets ||
              ResetGate.changedSince(resetGen)) {
            return false;
          }
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          // Again after discovery: a forget during it found no link or host
          // to stop, so this is the last point the session can still back
          // off before running against a deleted row.
          if (_deviceId != deviceId ||
              _forgets != forgets ||
              ResetGate.changedSince(resetGen)) {
            return false;
          }
          final link = GattBandLink(
            entry: entry,
            services: services,
            onLog: (m) => debugPrint('$_tag $m'),
          );
          _link = link;
          final missing = link
              .missingCharacteristics(entry.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('$_tag ${entry.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final anchor = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          _anchorSec = anchor;
          final h = host = BandHost(
            resetGeneration: resetGen,
            adapter: HelioStrapAdapter(entry: entry, nowSeconds: () => anchor),
            deviceId: deviceId,
            onLog: (m) => debugPrint('$_tag $m'),
            onNote: _handleNote,
            buildArchive: _buildArchiveRow,
          );
          _host = h;
          await h.run(link);
        } finally {
          // Drop the link and DISCONNECT before the slot is released — same
          // ordering `ColmiLink._sync` uses and for the same reason: held in
          // an outer `finally` this would run after the slot had already
          // been released, letting the next queued link connect while this
          // one was still disconnecting.
          await stop();
        }
        // A connect alone is not a sync: a strap with no key, a rejected
        // handshake, or a session the host flagged failed, all end the
        // session as quietly as one that answered nothing.
        // Read only after [stop], which makes the session's final flush.
        return !lastSyncFailed && !host.sessionFailed;
      });
    } catch (e) {
      debugPrint('$_tag sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    try {
      await _host?.stop();
    } finally {
      // A host whose final flush throws still leaves the link torn down and
      // the strap disconnected; the error then reaches the caller.
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
  }

  /// The last session ended via [kHelioNoKeyNote] (no auth key stored yet)
  /// or [kHelioAuthFailedNote] (handshake rejected/timed out). Cleared at the
  /// start of every session.
  bool lastSyncFailed = false;

  void _handleNote(String key, Object? value) {
    if (key == kHelioNoKeyNote ||
        key == kHelioAuthFailedNote ||
        key == kHelioIncompleteNote) {
      lastSyncFailed = true;
    }
  }

  /// Bank one reply verbatim (owner rulings R1-R3): a chunked-transport
  /// handshake frame or a plaintext fetch-channel frame. `counter` stays
  /// NULL — this protocol has no flash-record counter comparable to WHOOP's.
  /// The time a round belongs to is derived from the round's own
  /// `roundStart`, not carried per frame, so every raw frame from this
  /// session is stamped with the session's [_anchorSec] (the clock its fetch
  /// window counts back from).
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      counter: null,
      hex: _hex(bytes),
      packetType: bytes[0],
      recTs: _anchorSec,
      capturedAt: capturedAtMs,
      // ONE REASON PER PACKET TYPE, so a re-decode finds its frames by name.
      // Deliberately not in `LocalDb.redrivableArchiveReasons` — that list
      // replays a row's `hex` through the WHOOP R24 chain, which would run
      // the wrong decoder over a Helio frame.
      reason: '${entry.id}_0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted strap through the REAL [HelioStrapAdapter] and the
  /// real write path. The only way in: the entry point is a BLE notification
  /// and `flutter_blue_plus` has no simulator path. Same shape as
  /// `ColmiLink.ingestForTest`, except [reply] names the notify channel for
  /// each frame it returns — unlike Colmi's single command/notify pair, this
  /// protocol answers one write (the fetch "send data" trigger) with frames
  /// pushed across two different channels (control end-status, then data).
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<(String char, List<int> bytes)> Function(
            int writeIndex, String writeChar, List<int> value)
        reply, {
    int Function()? nowSeconds,
    Future<Uint8List?> Function()? authKeyReader,
    Duration firstReplyTimeout = const Duration(milliseconds: 100),
    Duration quietTimeout = const Duration(milliseconds: 20),
  }) async {
    _deviceId = deviceId;
    lastSyncFailed = false;
    final link = ReplayBandLink();
    final now = nowSeconds ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _anchorSec = now();
    final host = BandHost(
      adapter: HelioStrapAdapter(
        entry: entry,
        nowSeconds: now,
        authKeyReader: authKeyReader,
        firstReplyTimeout: firstReplyTimeout,
        quietTimeout: quietTimeout,
      ),
      deviceId: deviceId,
      onLog: (m) => debugPrint('$_tag $m'),
      onNote: _handleNote,
      buildArchive: _buildArchiveRow,
      nowSeconds: now,
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    // A walk with no reply genuinely waits out its timeout in REAL wall-clock
    // time, so this spin has to let that time pass rather than just yield
    // microtasks.
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        final (char, value) = link.writes[served];
        for (final (notifyChar, bytes) in reply(served, char, value)) {
          link.feed(notifyChar, bytes, atSec: now());
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    _host = null;
    _deviceId = null;
    return link;
  }
}
