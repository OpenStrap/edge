// The HOST for a paired RingConn ring: connect by stored `remote_id`,
// discover, drive [RingConnAdapter] over the link, bank what comes back,
// disconnect.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a ring (owner
// ruling R6), so not one byte of this path has been exercised against one.
// `kRingConn` stays EXPERIMENTAL, `RingConnAdapter.signals` stays `const {}`,
// and nothing this file writes becomes a number: its rows carry a non-null
// `source`, and every derive/export read filters `source IS NULL`.
//
// SIMPLER THAN `oura_link.dart`, FOR A REAL REASON. There is no pairing key to
// mint or store in the keychain (the handshake is a keyed hash over the
// ring's own MAC, read openly off a standard characteristic — see
// `ringconn.dart`), and no `sync_cursor`/`sync_anchor` to persist: the ring
// tracks its own resume position per channel, so this host always opens both
// channels at "now" rather than resuming a bookmark. One-shot [sync] —
// connect, drain, disconnect — same shape as `OuraLink.sync`.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/ringconn.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired RingConn ring. One instance; a second concurrent
/// ring is not a thing anyone asked for.
class RingConnLink {
  RingConnLink._();
  static final RingConnLink instance = RingConnLink._();

  /// The `device` row for the paired ring, or null.
  static Future<Map<String, Object?>?> pairedRingRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kRingConn.id) return r;
    }
    return null;
  }

  /// Forget a paired ring: drop its `device` row. Unlike Oura there is no
  /// stored secret to drop alongside it — nothing this handshake needs is
  /// persisted host-side at all (see this file's own header).
  static Future<bool> forgetRing(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[ringconn] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) {
      await instance.stop();
    }
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same ring.
  GattBandLink? _link;

  /// The session driving [RingConnAdapter] over [_link] — see
  /// `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired ring — the `device_id` every row it writes
  /// carries. Never [LocalDb.kPrimaryDeviceId]: `''` is the primary band,
  /// permanently (ASSUMPTIONS A1).
  String? _deviceId;

  /// Wall-clock now, in Unix seconds. A field so a replay is deterministic.
  int Function() _now = () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool _busy = false;

  /// Connect to the paired ring, drain both history channels, disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op rather than a second
  /// radio session over the same peripheral.
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
      // The primary band's id, permanently. A ring writing under it would
      // interleave its seconds with the band's in one REPLACE-keyed table.
      debugPrint('[ringconn] refusing to sync: the ring row claims the '
          'primary device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;

    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately — see
      // `oura_link.dart`'s identical comment: held in an outer `finally` it
      // ran AFTER the slot had already been released, letting the next
      // queued link connect while this one was still disconnecting.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kRingConn,
            services: services,
            onLog: (m) => debugPrint('[ringconn] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kRingConn.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[ringconn] ${kRingConn.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(deviceId, RingConnAdapter(nowSeconds: _now));
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[ringconn] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect.
  /// Safe to call when nothing is connected.
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

  /// Build this session's [BandHost]. One place, so `_sync()` and
  /// [ingestForTest] cannot drift on what each callback does.
  BandHost _makeHost(String deviceId, RingConnAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[ringconn] $m'),
        buildArchive: _buildArchiveRow,
        nowSeconds: _now,
      );

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3): every
  /// field inside a bulk-page record is undecoded, and the bytes are banked
  /// now so a decoder written when someone owns a ring can be run over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final f = parseRingConnFrame(bytes);
    if (f == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This band has no flash-record counter, and `counter` is
      // what `thinRawArchiveBefore` samples on — a 0 for every row would make
      // every RingConn frame `0 % 60 == 0`, i.e. permanently exempt, which is
      // accidental policy (verbatim the same reasoning as `oura_link.dart`).
      counter: null,
      // The reply tag. `packet_type` is documented as a WHOOP inner[0], and
      // this is the same thing one layer over.
      packetType: f.respid,
      // NULL, and it stays NULL. This ring tracks its own resume position;
      // this host stamps no timestamp of its own onto any frame.
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER TAG, so a decoder written later finds its records by
      // name instead of re-scanning the table. NOT in
      // `LocalDb.redrivableArchiveReasons`, deliberately and permanently — see
      // `oura_link.dart`'s identical note: replaying this hex through the
      // WHOOP R24 chain would run the wrong decoder over the right bytes.
      reason: 'ringconn_resp_0x${f.respid.toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted ring through the REAL [RingConnAdapter] and the real
  /// write path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path.
  ///
  /// [reply] answers each write the way the ring would, exactly as
  /// `ringconn_adapter_test.dart` scripts it.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<int> systemId,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    int Function()? nowSeconds,
    Duration timeouts = const Duration(milliseconds: 50),
  }) async {
    _now = nowSeconds ?? _now;
    _deviceId = deviceId;
    final link = ReplayBandLink()..readValues[kSystemIdUuid] = systemId;
    final host = _makeHost(
      deviceId,
      RingConnAdapter(nowSeconds: _now, replyTimeout: timeouts),
    );
    _host = host;
    // `host.run` does not resolve until the session ends, but this loop has
    // to react to each write WHILE the session is still open — so track
    // completion alongside it rather than awaiting it here.
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    for (var spin = 0; spin < 800 && !finished; spin++) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kRingConnNotifyChar, f, atSec: _now());
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
