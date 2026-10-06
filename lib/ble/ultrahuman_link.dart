// The HOST for the Ultrahuman Ring Air: hold the drain cursor, connect, drive
// [UltrahumanAdapter] over the link, and bank what comes back.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6), so not one byte of this path has been exercised against one. The
// registry entry stays EXPERIMENTAL, and `UltrahumanAdapter.signals` declares
// only sparse HR (`hrSparse`, 5 min), none of which becomes a derived number:
// its rows carry `source = 'ultrahuman'`, `kDerivableSources` does not name
// it, and every derive/export read filters `source IS NULL`.
//
// SIMPLER THAN OURA'S HOST, and for two real reasons rather than one:
//
//  1. NO SECRET. This wire has no auth at all, so there is no key to keep in
//     the keychain and no factory-reset precondition to explain before the
//     user commits.
//  2. NO TIME ANCHOR. Oura's ring stamps an undocumented decisecond-uptime
//     counter and needs a measured `(ds, unix)` bridge carried across
//     sessions (`TimeAnchor.arrival` on the *reading*, until an anchor
//     exists). This ring's record carries ITS OWN unix-second timestamp —
//     [TimeAnchor.measured] — so there is nothing here for the host to seed,
//     measure or persist beyond the drain cursor.
//
// THE SHAPE IS OURA'S OTHERWISE: a one-shot [UltrahumanLink.sync] — connect,
// drain to the end of history, tear down — rather than an arm/disarm pair,
// because this is a fetch-by-index store, not a live workout session.
//
// THE DESTRUCTIVE COMMANDS ARE UNREACHABLE FROM HERE. `GattBandLink`'s
// dangerous-opcode block does not cover an unframed band (ASSUMPTIONS I1) —
// this file's own defense is that `protocol`'s `ultrahuman.dart` has no
// builder for any of the ring's destructive opcodes (device reset / shipping
// mode 0x17, software reset 0x98, airplane mode, power saving and the rest
// listed there), and this file writes nothing it did not get from a builder
// there.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/ultrahuman.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// `sync_cursor` name for one ring's drain bookmark. Per-device: two rings are
/// not a thing anyone asked for, but a second one must not silently inherit
/// the first's bookmark.
String _cursorItem(String deviceId) => 'ultrahuman_cursor:$deviceId';

/// The live link to a paired Ultrahuman ring. One instance; a second
/// concurrent ring is not a thing anyone asked for.
class UltrahumanLink {
  UltrahumanLink._();
  static final UltrahumanLink instance = UltrahumanLink._();

  /// The `device` row for the paired ring, or null.
  ///
  /// `id` is MINTED at pairing (`HrsLink.mintDeviceId`), never the BLE remote
  /// id — see `oura_link.dart`'s identical doc for why.
  static Future<Map<String, Object?>?> pairedRingRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kUltrahuman.id) return r;
    }
    return null;
  }

  /// Stop this ring's live session (if it is the one running) and forget it.
  /// No secret to drop — this protocol has none — so, unlike
  /// `OuraLink.forgetRing`, only the session and the `device` row need to go.
  static Future<bool> forgetRing(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[ultrahuman] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) {
      await instance.stop();
    }
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// The most recent battery reading the ring reported, or null. NOT written
  /// to `band_battery` — same reasoning as `OuraLink.batteryPct`'s own doc: a
  /// ring cell's voltage does not belong in the WHOOP band's pack-health
  /// series.
  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it.
  GattBandLink? _link;

  /// The session driving [UltrahumanAdapter] over [_link].
  BandHost? _host;

  /// `device.id` of the paired ring. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  /// Wall-clock now, in Unix seconds. Only [BandHost]'s flush cadence reads
  /// this — the adapter itself never calls `DateTime.now()`, since every
  /// record carries its own measured timestamp.
  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Cursor writes, in arrival order, so teardown can wait for them. See
  /// `oura_link.dart`'s identical field for why this is serialised and
  /// awaited rather than fire-and-forget.
  Future<void> _cursorWrites = Future.value();

  void _writeCursor(int index) {
    _cursorWrites =
        _cursorWrites.then((_) => _persistCursor(index)).catchError((_) {});
  }

  bool _busy = false;

  /// Connect to the paired ring, drain its history to the end, disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final row = await pairedRingRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[ultrahuman] refusing to sync: the ring row claims the '
          'primary device id — re-pair it with a minted id.');
      return false;
    }

    _deviceId = deviceId;
    final cursor = await LocalDb.getCursorInt(_cursorItem(deviceId)) ??
        kUltrahumanFirstIndex;

    try {
      // A cap on concurrent SECONDARY links — see `ble_state.dart`'s
      // `kMaxConcurrentSecondaryLinks` doc. This offload sync's connect, drain
      // and disconnect all complete inside this one call, so the simple
      // scoped form is correct, same as `OuraLink._sync`.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          // 247 is the MTU the ring is built around (seven 32-byte records
          // per notification). Android only; iOS negotiates its own.
          await device.connect(
              timeout: const Duration(seconds: 20), mtu: 247);
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kUltrahuman,
            services: services,
            onLog: (m) => debugPrint('[ultrahuman] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kUltrahuman.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[ultrahuman] ${kUltrahuman.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          // Enable the reply notification HERE, where an auth failure can
          // still be seen: `GattBandLink.notify` swallows it, and the drain
          // would then end with nothing and report success, every sync.
          final notifyChar = services
              .expand((s) => s.characteristics)
              .firstWhere((c) =>
                  c.uuid == Guid(kUltrahumanNotifyChar));
          await enableNotifyWithBondRetry(
            () => notifyChar.setNotifyValue(true),
            device.createBond,
            isAndroid: Platform.isAndroid,
          );
          final host = _makeHost(
            deviceId,
            UltrahumanAdapter(startIndex: cursor),
          );
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[ultrahuman] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect. Safe
  /// to call when nothing is connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    await _cursorWrites;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  BandHost _makeHost(String deviceId, UltrahumanAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[ultrahuman] $m'),
        onNote: _handleNote,
        buildArchive: _buildArchiveRow,
        nowSeconds: _now,
      );

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'ultrahuman_cursor':
        // Emitted only AFTER the host confirmed, which is only after the
        // commit landed — same ordering guarantee as Oura's cursor note.
        if (value is int) _writeCursor(value);
      case 'battery':
        if (value is int) _batteryPct = value;
      default:
        debugPrint('[ultrahuman] $key = $value');
    }
  }

  /// Bank one 32-byte record verbatim, decoded or not (owner rulings R1-R3).
  /// Every field, decoded or not (both HRV bytes, the quality bytes, the
  /// ambient temperature, activity), is in here — the bytes are banked now so
  /// a decoder checked against a real ring can be run over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.length != kUltrahumanRecordLen) return null;
    // The record's own timestamp, if it parses — this ring measures its own
    // clock, unlike Oura, so there is a real `recTs` to keep rather than a
    // permanent null.
    final rec = parseUltrahumanRecord(bytes, 0);
    return ArchiveRecord(
      hex: _hex(bytes),
      // Bytes 30-31: the ring's own u16-LE record index. Informational here;
      // archive thinning only touches `undecodable_rec_v20`.
      counter: rec?.index,
      // The opcode whose response this record came from — every archived
      // record shares one, since there is only one kind.
      packetType: kUltrahumanOpGetRecordings,
      recTs: rec?.tsA,
      capturedAt: capturedAtMs,
      // NOT in `LocalDb.redrivableArchiveReasons`, deliberately and
      // permanently — same as Oura's `oura_evt_*` reasons: replaying this hex
      // through the WHOOP R24 chain would run the wrong decoder over the
      // right bytes.
      reason: 'ultrahuman_record',
    );
  }

  /// Replay a scripted ring through the REAL [UltrahumanAdapter], the real
  /// host and the real cursor persistence. `flutter_blue_plus` has no
  /// simulator path, so this is the only way in. Same shape as
  /// `ColmiLink.ingestForTest`.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    required int Function() nowSeconds,
    Duration timeout = const Duration(milliseconds: 100),
  }) async {
    _deviceId = deviceId;
    final cursor = await LocalDb.getCursorInt(_cursorItem(deviceId)) ??
        kUltrahumanFirstIndex;
    final link = ReplayBandLink();
    final host = BandHost(
      adapter: UltrahumanAdapter(
        startIndex: cursor,
        replyTimeout: timeout,
        confirmTimeout: const Duration(seconds: 5),
        nowSeconds: nowSeconds,
      ),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[ultrahuman] $m'),
      onNote: _handleNote,
      buildArchive: _buildArchiveRow,
      nowSeconds: nowSeconds,
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kUltrahumanNotifyChar, f, atSec: nowSeconds());
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    await _cursorWrites;
    _host = null;
    _deviceId = null;
    return link;
  }

  /// GATT statuses that mean "this link must be encrypted first":
  /// insufficient authentication / authorization / encryption, auth failure.
  static const Set<int> _kAuthErrors = {5, 8, 15, 137};

  /// Run [enable]; when Android refuses it for lack of a bond, [bond] and
  /// try exactly once more. A second failure, or any other error, throws and
  /// fails the sync. iOS pairs on its own, so there it never retries.
  @visibleForTesting
  static Future<void> enableNotifyWithBondRetry(
    Future<Object?> Function() enable,
    Future<void> Function() bond, {
    required bool isAndroid,
  }) async {
    try {
      await enable();
    } on FlutterBluePlusException catch (e) {
      if (!isAndroid || !_kAuthErrors.contains(e.code)) rethrow;
      debugPrint('[ultrahuman] notify refused (${e.code}); bonding once.');
      await bond();
      await enable();
    }
  }

  Future<void> _persistCursor(int index) async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    // NOT MONOTONIC, and it must not be — see `oura_link.dart`'s identical
    // note on why 0 arriving here is the recoverable case, not a bug.
    await LocalDb.setCursor(_cursorItem(deviceId), '$index');
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
