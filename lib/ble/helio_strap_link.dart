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
    BluetoothDevice device, String raw) async {
  final hex = raw.trim().replaceFirst(RegExp('^0x', caseSensitive: false), '');
  if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
    return 'That is not a strap key: it must be exactly 32 hex characters.';
  }
  final key = Uint8List.fromList(
      [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

  final priorRow = await HelioStrapLink.pairedHelioStrapRow();
  final rnd = Random.secure();
  final deviceId = (priorRow?['id'] as String?) ??
      'helio-${_hex(List<int>.generate(4, (_) => rnd.nextInt(256)))}';

  // What the keychain held before this attempt touched it, so a failure
  // AFTER the write below (the device-row upsert throwing, say) can be
  // rolled back to it rather than leave an unproven key sitting where a
  // working one used to be — same discipline `oura_link.dart`'s pairing
  // function uses, for the same reason.
  String? priorHex;
  try {
    priorHex = await _pairSecure.read(
      key: kHelioStrapSecureStorageKey,
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
          entry: kHelioStrap,
          services: services,
          onLog: (m) => debugPrint('[helio_strap pair] $m'),
        );
        final missing =
            link.missingCharacteristics(kHelioStrap.requiredCharacteristics);
        if (missing.isNotEmpty) {
          return 'This strap is missing something this app needs — it may '
              'not be a Helio Strap, or its firmware answered differently '
              'than expected.';
        }

        final result = await runHelioHandshake(link, key,
            timeout: const Duration(seconds: 10));
        if (result is HelioHandshakeFailed) {
          return switch (result.reason) {
            'wrong_key' => 'The strap rejected this key. Double-check it '
                'and try again.',
            'timeout' => 'The strap didn’t answer. Make sure it’s close by '
                'and try again.',
            _ => 'Pairing failed (${result.reason}).',
          };
        }

        try {
          await _pairSecure.write(
            key: kHelioStrapSecureStorageKey,
            value: hex,
            iOptions: kHelioStrapIosKeyOptions,
            mOptions: kHelioStrapMacosKeyOptions,
          );
        } catch (e) {
          return 'The phone’s keychain is locked. Unlock the phone and try '
              'again.';
        }
        try {
          await LocalDb.upsertDevice(
            id: deviceId,
            adapterId: kHelioStrap.id,
            remoteId: device.remoteId.str,
            label: kHelioStrap.label,
          );
        } catch (e) {
          // The row never landed — restore whatever the keychain held
          // before this attempt rather than leave an unproven key behind
          // with no row pointing at it.
          if (priorHex == null) {
            await _pairSecure.delete(
              key: kHelioStrapSecureStorageKey,
              iOptions: kHelioStrapIosKeyOptions,
              mOptions: kHelioStrapMacosKeyOptions,
            );
          } else {
            await _pairSecure.write(
              key: kHelioStrapSecureStorageKey,
              value: priorHex,
              iOptions: kHelioStrapIosKeyOptions,
              mOptions: kHelioStrapMacosKeyOptions,
            );
          }
          return 'Could not save the pairing: $e';
        }
        return null;
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

/// The live link to a paired Helio Strap. One instance; a second concurrent
/// strap is not a thing anyone asked for (same call as `ColmiLink`).
class HelioStrapLink {
  HelioStrapLink._();
  static final HelioStrapLink instance = HelioStrapLink._();

  /// The `device` row for the paired strap, or null.
  static Future<Map<String, Object?>?> pairedHelioStrapRow() =>
      pairedRowOf(kHelioStrap.id);

  /// Forget a paired strap: stop any live session, drop its `device` row.
  /// No stored pairing-key row to drop here — the auth key lives in secure
  /// storage, keyed by device id-independent constant, same as the adapter
  /// reads it (`_kSecureStorageKey` in `helio_strap.dart`); dropping the
  /// `device` row is the whole story for this link, same as `ColmiLink`.
  static Future<bool> forgetStrap(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[helio_strap] refusing to forget the primary band from here.');
      return false;
    }
    // Before the first await: a sync still reading the row has no
    // `_deviceId` yet for the check below to match.
    instance._forgets++;
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    // The key outlives nothing once its device row is gone — a re-pair
    // mints a fresh key anyway (first bind always goes through the real
    // Zepp app), so leaving the old one in the keychain only means a
    // factory-reset-and-forgotten strap's secret sits around unused
    // forever. Same cleanup `OuraLink.forgetRing` does for its own key.
    try {
      await _pairSecure.delete(
        key: kHelioStrapSecureStorageKey,
        iOptions: kHelioStrapIosKeyOptions,
        mOptions: kHelioStrapMacosKeyOptions,
      );
    } catch (_) {/* keychain unavailable; the device row is gone regardless */}
    return true;
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
    final row = await pairedHelioStrapRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[helio_strap] refusing to sync: the strap row claims the '
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
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kHelioStrap,
            services: services,
            onLog: (m) => debugPrint('[helio_strap] $m'),
          );
          _link = link;
          final missing = link
              .missingCharacteristics(kHelioStrap.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[helio_strap] ${kHelioStrap.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final anchor = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          _anchorSec = anchor;
          final h = host = BandHost(
            resetGeneration: resetGen,
            adapter: HelioStrapAdapter(nowSeconds: () => anchor),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[helio_strap] $m'),
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
      debugPrint('[helio_strap] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
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

  /// The last session ended via [kHelioNoKeyNote] (no auth key stored yet)
  /// or [kHelioAuthFailedNote] (handshake rejected/timed out). Cleared at the
  /// start of every session.
  bool lastSyncFailed = false;

  void _handleNote(String key, Object? value) {
    if (key == kHelioNoKeyNote || key == kHelioAuthFailedNote) {
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
      reason: 'helio_strap_0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
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
        nowSeconds: now,
        authKeyReader: authKeyReader,
        firstReplyTimeout: firstReplyTimeout,
        quietTimeout: quietTimeout,
      ),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[helio_strap] $m'),
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
